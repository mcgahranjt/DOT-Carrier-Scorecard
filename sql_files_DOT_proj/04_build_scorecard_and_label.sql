-- ============================================================
-- 04_build_scorecard_and_label.sql
-- Join census + inspection metrics + crash metrics into one
-- carrier-level scorecard, then define the high_risk target.
-- ============================================================

DROP TABLE IF EXISTS carrier_scorecard;

CREATE TABLE carrier_scorecard AS
SELECT
    c.DOT_NUMBER,
    c.LEGAL_NAME,
    c.PHY_STATE,
    c.CARRIER_OPERATION,
    c.POWER_UNITS,
    c.MCS150_MILEAGE,
    c.SAFETY_RATING,

    i.total_inspections,
    i.total_violations,
    i.total_oos_violations,
    i.oos_inspection_rate,
    i.oos_rate_of_violations,
    i.driver_oos_rate,
    i.vehicle_oos_rate,
    i.hazmat_oos_rate,

    cr.total_crashes,
    cr.fatal_crashes,
    cr.injury_crashes,
    cr.tow_away_crashes,

    -- normalized rates -- see 05_outlier_cleanup_and_analysis.sql
    -- before trusting these; MCS150_MILEAGE contains data-quality
    -- issues (missing values, one integer-overflow value) that
    -- must be filtered before these columns are reliable.
    ROUND(cr.total_crashes / NULLIF(c.MCS150_MILEAGE / 1000000.0, 0), 4) AS crashes_per_million_miles,
    ROUND(cr.total_crashes / NULLIF(c.POWER_UNITS, 0), 4)                AS crashes_per_power_unit

FROM company_census_regional_final c
LEFT JOIN carrier_inspection_metrics i ON c.DOT_NUMBER = i.DOT_NUMBER
LEFT JOIN carrier_crash_metrics      cr ON c.DOT_NUMBER = cr.DOT_NUMBER;

-- Sanity checks
SELECT COUNT(*) FROM carrier_scorecard;

SELECT
    SUM(CASE WHEN total_inspections IS NOT NULL THEN 1 ELSE 0 END) AS carriers_with_inspections,
    SUM(CASE WHEN total_crashes IS NOT NULL THEN 1 ELSE 0 END) AS carriers_with_crashes
FROM carrier_scorecard;

-- ============================================================
-- Define the high_risk target.
--
-- ORIGINAL PLAN: a percentile-based cutoff on oos_inspection_rate.
-- ABANDONED: at even a loose reliability floor (>=5 inspections),
-- only 5 carriers in the regional dataset qualified -- nowhere
-- near enough to support a percentile split. INSPECTION_FILE is
-- a genuinely small dataset (141 rows nationally).
--
-- REVISED APPROACH: a binary "ever had an adverse event" flag,
-- combining OOS violations and serious crash outcomes. This uses
-- the carrier's full history rather than only the small subset
-- with enough inspections for a reliable rate, at the cost of
-- treating a single historical event the same as a repeated
-- pattern (see README limitations).
-- ============================================================

ALTER TABLE carrier_scorecard ADD COLUMN high_risk INT;

-- NOTE: if MySQL Workbench's "safe update mode" blocks this
-- UPDATE (Error 1175), it's because carrier_scorecard has no
-- primary key/index (it was built via CREATE TABLE ... AS
-- SELECT). Disabling safe mode for the session is simplest:
SET SQL_SAFE_UPDATES = 0;

UPDATE carrier_scorecard
SET high_risk = CASE
    WHEN total_oos_violations > 0
      OR fatal_crashes > 0
      OR injury_crashes > 0
    THEN 1
    ELSE 0
END
WHERE DOT_NUMBER IS NOT NULL;

-- Check class balance
-- Expect roughly 872 high_risk / 944 low_risk if built on a
-- properly deduplicated census (company_census_dedup_final, per
-- script 01/02). If your counts land noticeably higher on both
-- sides (e.g. ~917/974), your census join has duplicate carrier
-- rows sneaking through -- see the note in 02_regional_scope.sql.
SELECT high_risk, COUNT(*) FROM carrier_scorecard GROUP BY high_risk;
