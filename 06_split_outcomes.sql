-- ============================================================
-- 06_split_outcomes.sql
-- Build the datasets behind the regression models and reproduce
-- the checks that led to splitting the outcome.
--
-- WHY THIS SCRIPT EXISTS: the pooled high_risk flag (script 04)
-- mixes two different events -- OOS violations (inspection file)
-- and injury/fatal crashes (crash file) -- that have very
-- different base rates. Rather than model the pooled flag, each
-- outcome is modeled on the population where it can actually be
-- observed:
--
--   Model 1 (control): pooled high_risk with a data_source control
--   Model 2: oos_any among carriers with inspection records
--   Model 3: severe_crash among carriers with crash records
--
-- The regressions themselves were run as linear probability
-- models in Excel's Analysis ToolPak on exports of the tables
-- built below. Requires script 04 (data_source, oos_any,
-- severe_crash columns).
-- ============================================================

-- ------------------------------------------------------------
-- Check 1: why the mileage-excluded carriers look "riskier"
-- Carriers excluded for bad mileage are flagged high_risk more
-- often than the regression sample, but the excluded group is
-- overwhelmingly crash-only carriers (high base rate), so this is
-- a composition effect, not a sign that bad mileage predicts risk.
-- ------------------------------------------------------------
SELECT
    CASE
        WHEN MCS150_MILEAGE IS NULL OR MCS150_MILEAGE = 0 THEN 'missing_or_zero'
        WHEN MCS150_MILEAGE <= 1000 THEN 'under_1000'
        WHEN MCS150_MILEAGE >= 10000000 THEN 'over_10M'
        ELSE 'valid'
    END AS mileage_status,
    COUNT(*) AS n,
    ROUND(AVG(high_risk), 3) AS pct_high_risk,
    SUM(total_inspections IS NOT NULL) AS has_inspections,
    SUM(total_crashes IS NOT NULL) AS has_crashes
FROM carrier_scorecard
GROUP BY mileage_status;

-- ------------------------------------------------------------
-- Regression sample: carriers with valid mileage (1,000 to 10M)
-- ------------------------------------------------------------
DROP TABLE IF EXISTS regression_sample_pooled;

CREATE TABLE regression_sample_pooled AS
SELECT
    DOT_NUMBER,
    high_risk,
    data_source,
    POWER_UNITS / 100                         AS fleet_100s,
    MCS150_MILEAGE / 1000000.0                AS miles_millions,
    CASE WHEN CARRIER_OPERATION = 'C' THEN 1 ELSE 0 END AS op_c,
    CASE WHEN SAFETY_RATING IN ('C','S','U') THEN 1 ELSE 0 END AS rated,
    CASE WHEN SAFETY_RATING = 'C' THEN 1 ELSE 0 END AS rating_c,
    CASE WHEN SAFETY_RATING = 'S' THEN 1 ELSE 0 END AS rating_s,
    CASE WHEN SAFETY_RATING = 'U' THEN 1 ELSE 0 END AS rating_u,
    CASE WHEN data_source = 'inspection_only' THEN 1 ELSE 0 END AS insp_only,
    CASE WHEN data_source = 'both' THEN 1 ELSE 0 END AS both_sources,
    oos_any,
    severe_crash
FROM carrier_scorecard
WHERE MCS150_MILEAGE > 1000
  AND MCS150_MILEAGE < 10000000;

-- Expect 1,081 carriers.
SELECT COUNT(*) AS n_regression_sample FROM regression_sample_pooled;

-- ------------------------------------------------------------
-- Check 2: the source-mix problem inside the regression sample.
-- Expect roughly: crash_only 652 (~57% high_risk, ~70% rated),
-- inspection_only 420 (~21%, ~19% rated), both 9 (~89%).
-- Rated carriers are mostly crash-only carriers, which is why a
-- pooled model made safety rating look like a strong predictor.
-- ------------------------------------------------------------
SELECT
    data_source,
    COUNT(*)                   AS n_carriers,
    ROUND(AVG(high_risk), 3)   AS pct_high_risk,
    ROUND(AVG(rated), 3)       AS pct_rated
FROM regression_sample_pooled
GROUP BY data_source;

-- ------------------------------------------------------------
-- Model 1 (control): pooled outcome, WITH source control
-- Export regression_sample_pooled to CSV.
--   Y: high_risk
--   X: fleet_100s, miles_millions, op_c, rating_c, rating_s,
--      rating_u, insp_only, both_sources
-- Result: R-squared about 0.14; insp_only is the dominant effect
-- (about -35 points); safety rating and fleet size are not
-- significant once the source is controlled for.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- Model 2: OOS risk among inspected carriers
-- ------------------------------------------------------------
DROP TABLE IF EXISTS model_oos_inspected;

CREATE TABLE model_oos_inspected AS
SELECT DOT_NUMBER, oos_any, fleet_100s, miles_millions, op_c, rated
FROM regression_sample_pooled
WHERE data_source IN ('inspection_only', 'both');

-- Expect 429 carriers, base rate about 0.207.
SELECT COUNT(*) AS n, ROUND(AVG(oos_any), 3) AS base_rate FROM model_oos_inspected;
-- Export to CSV.  Y: oos_any   X: fleet_100s, miles_millions, op_c, rated
-- Result: nothing significant; R-squared about 0.01.

-- ------------------------------------------------------------
-- Model 3: crash severity among crashed carriers
-- ------------------------------------------------------------
DROP TABLE IF EXISTS model_severe_crashed;

CREATE TABLE model_severe_crashed AS
SELECT DOT_NUMBER, severe_crash, fleet_100s, miles_millions, op_c, rated
FROM regression_sample_pooled
WHERE data_source IN ('crash_only', 'both');

-- Expect 661 carriers, base rate about 0.578.
SELECT COUNT(*) AS n, ROUND(AVG(severe_crash), 3) AS base_rate FROM model_severe_crashed;
-- Export to CSV.  Y: severe_crash   X: fleet_100s, miles_millions, op_c, rated
-- Result: intrastate non-hazmat (op_c) about +19.5 points (significant);
-- rated about +8.5 points (borderline); R-squared about 0.01.
