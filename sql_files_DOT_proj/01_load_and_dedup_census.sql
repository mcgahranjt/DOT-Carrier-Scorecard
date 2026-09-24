-- ============================================================
-- 01_load_and_dedup_census.sql
-- Load COMPANY_CENSUS from raw CSV and deduplicate to one row
-- per carrier (DOT_NUMBER).
--
-- NOTE: the original census extract had been opened in Excel at
-- some point, which silently truncated it to Excel's row limit
-- (1,048,576 rows). Loading directly from the raw CSV via
-- LOAD DATA INFILE avoids this entirely -- never open FMCSA
-- source files in Excel before loading them into MySQL.
-- ============================================================

-- --- Load raw data directly from CSV (bypassing Excel) ---
-- Adjust file path, delimiter, and column list to match your
-- actual COMPANY_CENSUS.csv structure and column order.

LOAD DATA INFILE '/path/to/company_census.csv'
INTO TABLE COMPANY_CENSUS
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;

-- --- Sanity check: confirm full population loaded ---
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT DOT_NUMBER) AS distinct_carriers
FROM COMPANY_CENSUS;
-- Expect total_rows >> 1,048,576 if the Excel-truncation bug is fixed.
-- Expect distinct_carriers < total_rows, since carriers can have
-- multiple historical filings (see dedup below).

-- --- Add index on DOT_NUMBER before any large joins/filters ---
-- Without this, later queries against this multi-million-row
-- table will attempt full table scans and can crash a
-- resource-constrained local MySQL instance.
ALTER TABLE COMPANY_CENSUS ADD INDEX idx_dot (DOT_NUMBER);

-- ============================================================
-- Deduplicate to one row per carrier, keeping the most recent
-- filing by MCS150_DATE (format: YYYYMMDD, stored as text, with
-- some blank values). Falls back to ADD_DATE when MCS150_DATE
-- is missing, since ~13% of carriers have no valid filing date.
-- ============================================================

-- Step A: compute the "effective" most recent date per carrier.
-- Kept lightweight (2 columns only) to avoid timing out on the
-- full multi-million-row table.
CREATE TABLE census_effective_dates AS
SELECT
    DOT_NUMBER,
    COALESCE(
        MAX(STR_TO_DATE(NULLIF(MCS150_DATE, ''), '%Y%m%d')),
        MAX(STR_TO_DATE(CAST(ADD_DATE AS CHAR), '%Y%m%d'))
    ) AS effective_date
FROM COMPANY_CENSUS
GROUP BY DOT_NUMBER;

ALTER TABLE census_effective_dates ADD INDEX idx_dot (DOT_NUMBER);

-- Step B: join back to pull the winning full row per carrier.
CREATE TABLE company_census_dedup AS
SELECT c.*
FROM COMPANY_CENSUS c
INNER JOIN census_effective_dates e
    ON c.DOT_NUMBER = e.DOT_NUMBER
    AND (
        STR_TO_DATE(NULLIF(c.MCS150_DATE, ''), '%Y%m%d') = e.effective_date
        OR STR_TO_DATE(CAST(c.ADD_DATE AS CHAR), '%Y%m%d') = e.effective_date
    );

-- Check for remaining duplicates (ties on effective_date --
-- e.g. two filings on the exact same day). A small number of
-- these is expected and acceptable.
SELECT DOT_NUMBER, COUNT(*)
FROM company_census_dedup
GROUP BY DOT_NUMBER
HAVING COUNT(*) > 1;

-- Force exactly one row per carrier among any remaining ties.
-- Uses a relaxed GROUP BY (rather than a window function) since
-- ROW_NUMBER() timed out repeatedly on this table size in a
-- resource-constrained local environment -- see README for the
-- innodb_buffer_pool_size fix that ultimately resolved this
-- class of timeout for later, smaller-scale operations.
SET SESSION sql_mode = (SELECT REPLACE(@@sql_mode, 'ONLY_FULL_GROUP_BY', ''));

CREATE TABLE company_census_dedup_final AS
SELECT *
FROM company_census_dedup
GROUP BY DOT_NUMBER;

-- Final verification: these two counts must be equal.
SELECT COUNT(*) AS total_rows, COUNT(DISTINCT DOT_NUMBER) AS distinct_carriers
FROM company_census_dedup_final;

-- Re-index the final deduplicated table for downstream use.
ALTER TABLE company_census_dedup_final ADD INDEX idx_dot (DOT_NUMBER);
