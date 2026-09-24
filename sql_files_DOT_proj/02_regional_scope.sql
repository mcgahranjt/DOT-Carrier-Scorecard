-- ============================================================
-- 02_regional_scope.sql
-- Scope INSPECTION_FILE, CRASH_FILE, and the census to the
-- NJ/NY/PA/DE/CT corridor.
--
-- IMPORTANT: filter by REPORT_STATE (where the inspection/crash
-- occurred), NOT by the carrier's home state (PHY_STATE).
-- Filtering by home state first was tried and produced too few
-- matched carriers (~80) to be usable -- most roadside
-- inspections/crashes involve carriers passing through a
-- region, not just carriers headquartered there. REPORT_STATE
-- better reflects a regional shipper's actual exposure anyway.
-- ============================================================

DROP TABLE IF EXISTS inspection_file_regional;
DROP TABLE IF EXISTS crash_file_regional;

CREATE TABLE inspection_file_regional AS
SELECT *
FROM INSPECTION_FILE
WHERE REPORT_STATE IN ('NJ','NY','PA','DE','CT');

CREATE TABLE crash_file_regional AS
SELECT *
FROM CRASH_FILE
WHERE REPORT_STATE IN ('NJ','NY','PA','DE','CT');

-- Sanity check: confirm the states you expect are actually
-- present in each source file (small source files can genuinely
-- lack rows for some states -- verify with:
--   SELECT DISTINCT REPORT_STATE FROM INSPECTION_FILE;
-- before assuming a zero-row result is an error).
SELECT COUNT(DISTINCT DOT_NUMBER) AS n_inspected_carriers FROM inspection_file_regional;
SELECT COUNT(DISTINCT DOT_NUMBER) AS n_crashed_carriers FROM crash_file_regional;

-- ============================================================
-- Build the regional census: only carriers that actually appear
-- in the regional inspection or crash files, regardless of
-- their home state (PHY_STATE).
--
-- Built as an indexed JOIN rather than WHERE DOT_NUMBER IN
-- (subquery UNION subquery) -- the IN/UNION form repeatedly
-- timed out against the multi-million-row census even with an
-- index present, likely due to how MySQL's optimizer plans
-- that query shape. The two-step lookup-table + JOIN form below
-- resolved it.
-- ============================================================

DROP TABLE IF EXISTS regional_dot_numbers;

CREATE TABLE regional_dot_numbers AS
SELECT DISTINCT DOT_NUMBER FROM inspection_file_regional
UNION
SELECT DISTINCT DOT_NUMBER FROM crash_file_regional;

ALTER TABLE regional_dot_numbers ADD INDEX idx_dot (DOT_NUMBER);

DROP TABLE IF EXISTS company_census_regional_final;

-- IMPORTANT: join against company_census_dedup_final (the fully
-- deduplicated table from script 01), NOT company_census_dedup.
-- Joining against the intermediate table -- the one that still
-- has ~36,600 unresolved ties on effective_date -- lets a small
-- number of duplicate carrier rows slip through into this table
-- and every downstream table built from it, silently inflating
-- carrier_scorecard counts and any average calculated from it.
CREATE TABLE company_census_regional_final AS
SELECT c.*
FROM company_census_dedup_final c
INNER JOIN regional_dot_numbers r ON c.DOT_NUMBER = r.DOT_NUMBER;

-- Confirm no duplicates made it through.
SELECT DOT_NUMBER, COUNT(*)
FROM company_census_regional_final
GROUP BY DOT_NUMBER
HAVING COUNT(*) > 1;

-- Final check: should be a small table (low thousands of rows).
SELECT COUNT(*) FROM company_census_regional_final;
