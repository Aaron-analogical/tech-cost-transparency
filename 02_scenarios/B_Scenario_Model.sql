/* =====================================================================
   Meridian Technology Infrastructure - Part B: Scenario Modelling
   ---------------------------------------------------------------------
   Parameterised what-if model driven off a single parameter table.
   S1: migrate 15% of Data Centre (CP04) workload to public cloud at a
       justified cloud unit-cost factor (default 1.10 = 10% premium).
       Modelled as an actual pool re-tag: retained rows stay CP04 at 85%
       of cost, migrated rows are re-tagged CP05 at 15% * cloud_factor.
       dc_avoidable_pct is the share of the migrated slice's Data Centre
       cost that actually goes away (1.0 = fully avoidable; 0.0 = fully
       stranded, so the DC bill stays and cloud is paid on top).
   S2: +8% rate increase on Vendor / Managed Service (CP06). No pool
       change - it is a rate rise on the same vendor relationship.
   Overhead is re-spread onto each scenario's new base (total unchanged).
   Depends on FCT_FULLY_LOADED_COST (Part A).
   ===================================================================== */

USE SCHEMA CASE_STUDY.MERIDIAN;

/* 1) Parameter table - change one row and re-run to flex a scenario */
CREATE OR REPLACE TABLE SCENARIO_PARAM (
    scenario_id  VARCHAR,
    param_name   VARCHAR,
    param_value  DECIMAL(10,4)
);
INSERT INTO SCENARIO_PARAM VALUES
    ('S1','dc_migration_pct',     0.15),   -- share of Data Centre (CP04) workload moved to cloud
    ('S1','cloud_cost_factor',    1.10),   -- cloud unit cost vs on-prem: 1.10 = 10% premium
    ('S1','dc_avoidable_pct',     1.00),   -- share of the migrated DC cost actually shed (1 = no stranded cost)
    ('S2','vendor_rate_increase', 0.08);   -- +8% on Vendor / Managed Service (CP06)

/* 2a) S1 rows - CP04 split into a retained CP04 row and a migrated CP05 row
       per (date, product, application). Non-CP04 rows pass through unchanged. */
CREATE OR REPLACE VIEW VW_S1_ROWS AS
WITH p AS (
    SELECT
        MAX(CASE WHEN param_name='dc_migration_pct'  THEN param_value END) AS mig_pct,
        MAX(CASE WHEN param_name='cloud_cost_factor' THEN param_value END) AS cloud_factor,
        MAX(CASE WHEN param_name='dc_avoidable_pct'  THEN param_value END) AS avoidable
    FROM SCENARIO_PARAM WHERE scenario_id='S1'
),
base AS (
    SELECT DATE_KEY, COST_POOL_ID, PRODUCT_ID, APPLICATION_ID, direct_and_alloc_usd AS da
    FROM FCT_FULLY_LOADED_COST
),
split AS (
    -- pools other than CP04: untouched
    SELECT b.DATE_KEY, b.COST_POOL_ID, b.PRODUCT_ID, b.APPLICATION_ID, b.da
    FROM base b WHERE b.COST_POOL_ID <> 'CP04'
    UNION ALL
    -- CP04 retained portion: the 85% that stays, plus any stranded share of the migrated 15%
    SELECT b.DATE_KEY, 'CP04', b.PRODUCT_ID, b.APPLICATION_ID, b.da * (1 - p.mig_pct * p.avoidable)
    FROM base b CROSS JOIN p WHERE b.COST_POOL_ID = 'CP04'
    UNION ALL
    -- CP04 migrated portion (15%), re-tagged CP05 at the cloud cost factor
    SELECT b.DATE_KEY, 'CP05', b.PRODUCT_ID, b.APPLICATION_ID, b.da * p.mig_pct * p.cloud_factor
    FROM base b CROSS JOIN p WHERE b.COST_POOL_ID = 'CP04'
),
oh AS (SELECT DATE_KEY, SUM(overhead_loading_usd) AS oh_amount FROM FCT_FULLY_LOADED_COST GROUP BY DATE_KEY)
SELECT s.DATE_KEY, s.COST_POOL_ID, s.PRODUCT_ID, s.APPLICATION_ID,
    s.da,
    o.oh_amount * s.da / NULLIF(SUM(s.da) OVER (PARTITION BY s.DATE_KEY), 0) AS oh,
    s.da + o.oh_amount * s.da / NULLIF(SUM(s.da) OVER (PARTITION BY s.DATE_KEY), 0) AS fully_loaded
FROM split s JOIN oh o ON o.DATE_KEY = s.DATE_KEY;

/* 2b) S2 rows - flat +8% on CP06, no pool change, same row count as baseline */
CREATE OR REPLACE VIEW VW_S2_ROWS AS
WITH p AS (
    SELECT MAX(param_value) AS vendor_inc
    FROM SCENARIO_PARAM WHERE scenario_id='S2' AND param_name='vendor_rate_increase'
),
adj AS (
    SELECT f.DATE_KEY, f.COST_POOL_ID, f.PRODUCT_ID, f.APPLICATION_ID,
        CASE WHEN f.COST_POOL_ID = 'CP06'
             THEN f.direct_and_alloc_usd * (1 + p.vendor_inc)
             ELSE f.direct_and_alloc_usd END AS da
    FROM FCT_FULLY_LOADED_COST f CROSS JOIN p
),
oh AS (SELECT DATE_KEY, SUM(overhead_loading_usd) AS oh_amount FROM FCT_FULLY_LOADED_COST GROUP BY DATE_KEY)
SELECT a.DATE_KEY, a.COST_POOL_ID, a.PRODUCT_ID, a.APPLICATION_ID,
    a.da,
    o.oh_amount * a.da / NULLIF(SUM(a.da) OVER (PARTITION BY a.DATE_KEY), 0) AS oh,
    a.da + o.oh_amount * a.da / NULLIF(SUM(a.da) OVER (PARTITION BY a.DATE_KEY), 0) AS fully_loaded
FROM adj a JOIN oh o ON o.DATE_KEY = a.DATE_KEY;

/* 3) Before / after by PRODUCT */
CREATE OR REPLACE VIEW VW_SCENARIO_BY_PRODUCT AS
WITH base_agg AS (
    SELECT PRODUCT_ID, SUM(fully_loaded_usd) AS baseline_fl
    FROM FCT_FULLY_LOADED_COST GROUP BY PRODUCT_ID
),
s1_agg AS (SELECT PRODUCT_ID, SUM(fully_loaded) AS s1_fl FROM VW_S1_ROWS GROUP BY PRODUCT_ID),
s2_agg AS (SELECT PRODUCT_ID, SUM(fully_loaded) AS s2_fl FROM VW_S2_ROWS GROUP BY PRODUCT_ID)
SELECT b.PRODUCT_ID,
    ROUND(b.baseline_fl) AS baseline_fl,
    ROUND(s1.s1_fl)       AS s1_fully_loaded,
    ROUND(s2.s2_fl)       AS s2_fully_loaded,
    ROUND(s1.s1_fl - b.baseline_fl) AS s1_delta,
    ROUND(s2.s2_fl - b.baseline_fl) AS s2_delta
FROM base_agg b
JOIN s1_agg s1 ON s1.PRODUCT_ID = b.PRODUCT_ID
JOIN s2_agg s2 ON s2.PRODUCT_ID = b.PRODUCT_ID
ORDER BY b.baseline_fl DESC;

/* 3b) Before / after by APPLICATION (the "Product and Application" breakdown) */
CREATE OR REPLACE VIEW VW_SCENARIO_BY_APPLICATION AS
WITH base_agg AS (
    SELECT APPLICATION_ID, SUM(fully_loaded_usd) AS baseline_fl
    FROM FCT_FULLY_LOADED_COST GROUP BY APPLICATION_ID
),
s1_agg AS (SELECT APPLICATION_ID, SUM(fully_loaded) AS s1_fl FROM VW_S1_ROWS GROUP BY APPLICATION_ID),
s2_agg AS (SELECT APPLICATION_ID, SUM(fully_loaded) AS s2_fl FROM VW_S2_ROWS GROUP BY APPLICATION_ID)
SELECT b.APPLICATION_ID,
    ROUND(b.baseline_fl) AS baseline_fl,
    ROUND(s1.s1_fl)       AS s1_fully_loaded,
    ROUND(s2.s2_fl)       AS s2_fully_loaded,
    ROUND(s1.s1_fl - b.baseline_fl) AS s1_delta,
    ROUND(s2.s2_fl - b.baseline_fl) AS s2_delta
FROM base_agg b
JOIN s1_agg s1 ON s1.APPLICATION_ID = b.APPLICATION_ID
JOIN s2_agg s2 ON s2.APPLICATION_ID = b.APPLICATION_ID
ORDER BY ABS(ROUND(s2.s2_fl - b.baseline_fl)) DESC;

/* 3c) Before / after by POOL - proves the S1 migration actually moves CP04 -> CP05 */
CREATE OR REPLACE VIEW VW_SCENARIO_S1_BY_POOL AS
WITH base_agg AS (
    SELECT COST_POOL_ID, SUM(direct_and_alloc_usd) AS baseline_da
    FROM FCT_FULLY_LOADED_COST GROUP BY COST_POOL_ID
),
s1_agg AS (SELECT COST_POOL_ID, SUM(da) AS s1_da FROM VW_S1_ROWS GROUP BY COST_POOL_ID)
SELECT COALESCE(b.COST_POOL_ID, s1.COST_POOL_ID) AS pool_id,
    ROUND(COALESCE(b.baseline_da, 0)) AS baseline_da,
    ROUND(COALESCE(s1.s1_da, 0))      AS s1_da,
    ROUND(COALESCE(s1.s1_da, 0) - COALESCE(b.baseline_da, 0)) AS delta
FROM base_agg b
FULL OUTER JOIN s1_agg s1 ON s1.COST_POOL_ID = b.COST_POOL_ID
ORDER BY baseline_da DESC;

/* 4) Sensitivity: S1 delta = CP04 cost x mig_pct x (cloud_factor - dc_avoidable_pct)
   Flip the cloud factor to a discount, then restore:
UPDATE SCENARIO_PARAM SET param_value = 0.90 WHERE scenario_id='S1' AND param_name='cloud_cost_factor';
SELECT ROUND(SUM(s1_delta)) AS s1_total_at_0_90 FROM VW_SCENARIO_BY_PRODUCT;   -- expect approx -50,475
UPDATE SCENARIO_PARAM SET param_value = 1.10 WHERE scenario_id='S1' AND param_name='cloud_cost_factor';
   Fully stranded Data Centre cost (nothing shed), then restore:
UPDATE SCENARIO_PARAM SET param_value = 0.00 WHERE scenario_id='S1' AND param_name='dc_avoidable_pct';
SELECT ROUND(SUM(s1_delta)) AS s1_total_stranded FROM VW_SCENARIO_BY_PRODUCT;  -- expect approx +555,227
UPDATE SCENARIO_PARAM SET param_value = 1.00 WHERE scenario_id='S1' AND param_name='dc_avoidable_pct';
   The full grid is produced by run_local.py -> 02_scenarios/S1_sensitivity_grid.csv
*/
