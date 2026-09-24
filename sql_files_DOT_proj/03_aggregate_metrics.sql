-- ============================================================
-- 03_aggregate_metrics.sql
-- Aggregate inspection_file_regional and crash_file_regional
-- from event-level grain up to one row per carrier, so they can
-- be joined onto the carrier-level census.
-- ============================================================

DROP TABLE IF EXISTS carrier_inspection_metrics;
DROP TABLE IF EXISTS carrier_crash_metrics;

-- --- Inspection metrics ---
-- INSPECTION_FILE already provides pre-aggregated violation/OOS
-- counts per inspection, broken out by category (Driver,
-- Vehicle, Hazmat) -- no need to pivot a text category column.
CREATE TABLE carrier_inspection_metrics AS
SELECT
    DOT_NUMBER,
    COUNT(*)                                                       AS total_inspections,
    SUM(VIOL_TOTAL)                                                AS total_violations,
    SUM(OOS_TOTAL)                                                 AS total_oos_violations,

    -- inspections resulting in at least one OOS violation
    SUM(CASE WHEN OOS_TOTAL > 0 THEN 1 ELSE 0 END)                 AS inspections_with_oos,
    ROUND(SUM(CASE WHEN OOS_TOTAL > 0 THEN 1 ELSE 0 END) / COUNT(*), 4)
                                                                    AS oos_inspection_rate,

    -- share of all cited violations that were OOS-level
    ROUND(SUM(OOS_TOTAL) / NULLIF(SUM(VIOL_TOTAL), 0), 4)          AS oos_rate_of_violations,

    SUM(DRIVER_VIOL_TOTAL)                                         AS driver_violations,
    SUM(DRIVER_OOS_TOTAL)                                          AS driver_oos,
    ROUND(SUM(DRIVER_OOS_TOTAL) / NULLIF(SUM(DRIVER_VIOL_TOTAL), 0), 4) AS driver_oos_rate,

    SUM(VEHICLE_VIOL_TOTAL)                                        AS vehicle_violations,
    SUM(VEHICLE_OOS_TOTAL)                                         AS vehicle_oos,
    ROUND(SUM(VEHICLE_OOS_TOTAL) / NULLIF(SUM(VEHICLE_VIOL_TOTAL), 0), 4) AS vehicle_oos_rate,

    SUM(HAZMAT_VIOL_TOTAL)                                         AS hazmat_violations,
    SUM(HAZMAT_OOS_TOTAL)                                          AS hazmat_oos,
    ROUND(SUM(HAZMAT_OOS_TOTAL) / NULLIF(SUM(HAZMAT_VIOL_TOTAL), 0), 4) AS hazmat_oos_rate

FROM inspection_file_regional
GROUP BY DOT_NUMBER;

-- --- Crash metrics ---
-- Confirmed TOW_AWAY uses 'Y'/'N' values before writing this.
CREATE TABLE carrier_crash_metrics AS
SELECT
    DOT_NUMBER,
    COUNT(*)                                                    AS total_crashes,
    SUM(COALESCE(FATALITIES, 0))                                AS total_fatalities,
    SUM(COALESCE(INJURIES, 0))                                  AS total_injuries,
    SUM(CASE WHEN FATALITIES > 0 THEN 1 ELSE 0 END)             AS fatal_crashes,
    SUM(CASE WHEN INJURIES > 0 THEN 1 ELSE 0 END)               AS injury_crashes,
    SUM(CASE WHEN TOW_AWAY = 'Y' THEN 1 ELSE 0 END)             AS tow_away_crashes
FROM crash_file_regional
GROUP BY DOT_NUMBER;

-- Sanity checks: distinct carrier counts here should match the
-- distinct counts from inspection_file_regional / crash_file_regional.
SELECT COUNT(*) FROM carrier_inspection_metrics;
SELECT COUNT(*) FROM carrier_crash_metrics;
