/* =====================================================================
   Meridian Technology Infrastructure - Part A: Attribution & Variance
   ---------------------------------------------------------------------
   Grain of output fact : one row per date_key x cost_pool_id x product_id x application_id (monthly)
   Inputs               : FACT_GL_COST, FACT_CONSUMPTION, FACT_ALLOCATION_MAP,
                          FACT_BUDGET_FORECAST, DIM_FUNDING_REQUEST, DIM_PROGRAM
                          (DIM_FUNDING_REQUEST/DIM_PROGRAM are build-time inputs
                          only - not related directly to the cost fact)
   Output               : FCT_FULLY_LOADED_COST, BRIDGE_PRODUCT_FUNDING_PROGRAM (tables),
                          VW_COST_BY_FUNDING_REQUEST, VW_VARIANCE (views)
   Key policies         : - driver-based allocation via consumption weights
                          - mixed-driver pools (CP01, CP04): equal weight per driver group
                          - missing monthly driver feed: carry forward last known volume
                          - shared overhead (CP99): spread pro-rata, kept as a separate column
   Reconciles to the GL within rounding.
   ===================================================================== */

USE SCHEMA CASE_STUDY.MERIDIAN;

/* ---------------------------------------------------------------------
   1) FULLY-LOADED COST FACT
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE FCT_FULLY_LOADED_COST AS
WITH
months AS (SELECT DISTINCT DATE_KEY FROM FACT_GL_COST),

-- Product-level driver volumes, with carry-forward for missing months
prod_actual AS (
    SELECT DATE_KEY, PRODUCT_ID, DRIVER_TYPE, SUM(DRIVER_QTY) AS qty
    FROM FACT_CONSUMPTION WHERE DRIVER_QTY IS NOT NULL
    GROUP BY DATE_KEY, PRODUCT_ID, DRIVER_TYPE
),
prod_combos AS (SELECT DISTINCT PRODUCT_ID, DRIVER_TYPE FROM prod_actual),
prod_grid AS (SELECT m.DATE_KEY, c.PRODUCT_ID, c.DRIVER_TYPE FROM months m CROSS JOIN prod_combos c),
prod_driver_totals AS (
    SELECT g.DATE_KEY, g.PRODUCT_ID, g.DRIVER_TYPE,
           COALESCE(a.qty,
             LAST_VALUE(a.qty IGNORE NULLS) OVER (
                 PARTITION BY g.PRODUCT_ID, g.DRIVER_TYPE
                 ORDER BY g.DATE_KEY ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           ) AS prod_qty
    FROM prod_grid g
    LEFT JOIN prod_actual a
      ON a.DATE_KEY = g.DATE_KEY AND a.PRODUCT_ID = g.PRODUCT_ID AND a.DRIVER_TYPE = g.DRIVER_TYPE
),

-- Application-level driver shares, with carry-forward
app_actual AS (
    SELECT DATE_KEY, PRODUCT_ID, APPLICATION_ID, DRIVER_TYPE, SUM(DRIVER_QTY) AS qty
    FROM FACT_CONSUMPTION WHERE DRIVER_QTY IS NOT NULL
    GROUP BY DATE_KEY, PRODUCT_ID, APPLICATION_ID, DRIVER_TYPE
),
app_combos AS (SELECT DISTINCT PRODUCT_ID, APPLICATION_ID, DRIVER_TYPE FROM app_actual),
app_grid AS (SELECT m.DATE_KEY, c.PRODUCT_ID, c.APPLICATION_ID, c.DRIVER_TYPE FROM months m CROSS JOIN app_combos c),
app_share AS (
    SELECT DATE_KEY, PRODUCT_ID, APPLICATION_ID,
           q / NULLIF(SUM(q) OVER (PARTITION BY DATE_KEY, PRODUCT_ID), 0) AS share
    FROM (
        SELECT g.DATE_KEY, g.PRODUCT_ID, g.APPLICATION_ID,
               COALESCE(a.qty,
                 LAST_VALUE(a.qty IGNORE NULLS) OVER (
                     PARTITION BY g.PRODUCT_ID, g.APPLICATION_ID, g.DRIVER_TYPE
                     ORDER BY g.DATE_KEY ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
               ) AS q
        FROM app_grid g
        LEFT JOIN app_actual a
          ON a.DATE_KEY = g.DATE_KEY AND a.PRODUCT_ID = g.PRODUCT_ID
         AND a.APPLICATION_ID = g.APPLICATION_ID AND a.DRIVER_TYPE = g.DRIVER_TYPE
    )
    WHERE q IS NOT NULL
),

-- HOP 1: cost pool -> product (equal weight per driver group, volume split within group)
pool_driver_groups AS (
    SELECT COST_POOL_ID, COUNT(DISTINCT DRIVER_TYPE) AS n_groups
    FROM FACT_ALLOCATION_MAP WHERE ALLOC_METHOD = 'DRIVER'
    GROUP BY COST_POOL_ID
),
allocated_to_product AS (
    SELECT g.DATE_KEY, g.COST_POOL_ID, m.PRODUCT_ID,
           g.AMOUNT_USD
             * ( pt.prod_qty / NULLIF(SUM(pt.prod_qty) OVER (PARTITION BY g.GL_ID, m.DRIVER_TYPE), 0) )
             * ( 1.0 / dg.n_groups ) AS amount_usd
    FROM FACT_GL_COST g
    JOIN FACT_ALLOCATION_MAP m
      ON m.COST_POOL_ID = g.COST_POOL_ID AND m.ALLOC_METHOD = 'DRIVER'
    JOIN prod_driver_totals pt
      ON pt.PRODUCT_ID = m.PRODUCT_ID AND pt.DRIVER_TYPE = m.DRIVER_TYPE AND pt.DATE_KEY = g.DATE_KEY
    JOIN pool_driver_groups dg
      ON dg.COST_POOL_ID = g.COST_POOL_ID
    WHERE g.PRODUCT_ID IS NULL AND g.COST_POOL_ID <> 'CP99'
),
cost_by_pool_product AS (
    SELECT DATE_KEY, COST_POOL_ID, PRODUCT_ID, AMOUNT_USD AS amount_usd
    FROM FACT_GL_COST
    WHERE PRODUCT_ID IS NOT NULL AND COST_POOL_ID <> 'CP99'   -- direct costs
    UNION ALL
    SELECT DATE_KEY, COST_POOL_ID, PRODUCT_ID, amount_usd FROM allocated_to_product
),

-- HOP 2: product -> application
cost_by_app AS (
    SELECT c.DATE_KEY, c.COST_POOL_ID, c.PRODUCT_ID, a.APPLICATION_ID,
           c.amount_usd * a.share AS direct_and_alloc_usd
    FROM cost_by_pool_product c
    JOIN app_share a ON a.DATE_KEY = c.DATE_KEY AND a.PRODUCT_ID = c.PRODUCT_ID
),

-- Shared overhead (CP99): spread pro-rata, kept as its own column
overhead AS (
    SELECT DATE_KEY, SUM(AMOUNT_USD) AS oh_amount
    FROM FACT_GL_COST WHERE COST_POOL_ID = 'CP99' GROUP BY DATE_KEY
)
SELECT
    c.DATE_KEY, c.COST_POOL_ID, c.PRODUCT_ID, c.APPLICATION_ID,
    c.direct_and_alloc_usd,
    o.oh_amount * c.direct_and_alloc_usd
      / NULLIF(SUM(c.direct_and_alloc_usd) OVER (PARTITION BY c.DATE_KEY), 0) AS overhead_loading_usd,
    c.direct_and_alloc_usd
      + o.oh_amount * c.direct_and_alloc_usd
        / NULLIF(SUM(c.direct_and_alloc_usd) OVER (PARTITION BY c.DATE_KEY), 0) AS fully_loaded_usd
FROM cost_by_app c
JOIN overhead o ON o.DATE_KEY = c.DATE_KEY;

/* Reconciliation: allocated total must equal the GL (expect difference ~ 0)
SELECT (SELECT SUM(fully_loaded_usd) FROM FCT_FULLY_LOADED_COST) AS allocated_total,
       (SELECT SUM(AMOUNT_USD)       FROM FACT_GL_COST)          AS gl_total,
       (SELECT SUM(fully_loaded_usd) FROM FCT_FULLY_LOADED_COST)
         - (SELECT SUM(AMOUNT_USD)   FROM FACT_GL_COST)          AS difference;
*/

/* ---------------------------------------------------------------------
   2) BRIDGE_PRODUCT_FUNDING_PROGRAM - rollup bridge: product -> funding request -> program
      Funding request and program are not native to any cost table, so this
      materializes the bridge: FUNDING_REQUEST_ID/NAME/PROGRAM_ID from
      DIM_FUNDING_REQUEST, joined to a deduplicated FACT_BUDGET_FORECAST to
      attach PRODUCT_ID (the only column linking a funding request to a
      product), and joined to DIM_PROGRAM to denormalize PROGRAM_NAME onto
      the bridge. DIM_FUNDING_REQUEST and DIM_PROGRAM are consumed here only
      as build-time inputs - once this table is built, neither is related
      directly to FCT_FULLY_LOADED_COST (DIM_FUNDING_REQUEST keeps one
      separate, live relationship to FACT_BUDGET_FORECAST). Assumes each
      product maps to exactly one funding request (1:1 in this data; FR0004
      intentionally unmapped).
   --------------------------------------------------------------------- */
CREATE OR REPLACE TABLE BRIDGE_PRODUCT_FUNDING_PROGRAM (
    FUNDING_REQUEST_ID   STRING,
    FUNDING_REQUEST_NAME STRING,
    PRODUCT_ID           STRING,
    PROGRAM_ID           STRING,
    PROGRAM_NAME         STRING
);

INSERT INTO BRIDGE_PRODUCT_FUNDING_PROGRAM (FUNDING_REQUEST_ID, FUNDING_REQUEST_NAME, PRODUCT_ID, PROGRAM_ID, PROGRAM_NAME)
SELECT
    a.FUNDING_REQUEST_ID,
    a.FUNDING_REQUEST_NAME,
    b.PRODUCT_ID,
    a.PROGRAM_ID,
    c.PROGRAM_NAME
FROM DIM_FUNDING_REQUEST a
JOIN (SELECT DISTINCT FUNDING_REQUEST_ID, PRODUCT_ID FROM FACT_BUDGET_FORECAST) b
  ON a.FUNDING_REQUEST_ID = b.FUNDING_REQUEST_ID
JOIN DIM_PROGRAM c
  ON a.PROGRAM_ID = c.PROGRAM_ID;

/* ---------------------------------------------------------------------
   3) ROLL-UP TO FUNDING REQUEST & PROGRAM
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW VW_COST_BY_FUNDING_REQUEST AS
SELECT
    f.DATE_KEY,
    r.FUNDING_REQUEST_ID,
    r.FUNDING_REQUEST_NAME,
    r.PROGRAM_ID,
    r.PROGRAM_NAME,
    SUM(f.fully_loaded_usd) AS fully_loaded_usd
FROM FCT_FULLY_LOADED_COST f
JOIN BRIDGE_PRODUCT_FUNDING_PROGRAM r
  ON r.PRODUCT_ID = f.PRODUCT_ID
GROUP BY f.DATE_KEY, r.FUNDING_REQUEST_ID, r.FUNDING_REQUEST_NAME, r.PROGRAM_ID, r.PROGRAM_NAME;

/* ---------------------------------------------------------------------
   4) VARIANCE: ACTUAL vs BUDGET vs FORECAST (pre-overhead comparison basis)
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW VW_VARIANCE AS
WITH actual AS (
    SELECT DATE_KEY, PRODUCT_ID,
           SUM(direct_and_alloc_usd) AS actual_usd,      -- comparison basis (pre-overhead)
           SUM(overhead_loading_usd) AS overhead_usd,
           SUM(fully_loaded_usd)     AS fully_loaded_usd
    FROM FCT_FULLY_LOADED_COST
    GROUP BY DATE_KEY, PRODUCT_ID
),
plan AS (
    SELECT DATE_KEY, PRODUCT_ID,
           SUM(BUDGET_USD)         AS budget_usd,
           SUM(FORECAST_USD)       AS forecast_usd,
           MAX(FUNDING_REQUEST_ID) AS funding_request_id
    FROM FACT_BUDGET_FORECAST
    GROUP BY DATE_KEY, PRODUCT_ID
)
SELECT
    COALESCE(a.DATE_KEY,   p.DATE_KEY)   AS date_key,
    COALESCE(a.PRODUCT_ID, p.PRODUCT_ID) AS product_id,
    p.funding_request_id,
    COALESCE(a.actual_usd, 0)       AS actual_usd,
    COALESCE(a.overhead_usd, 0)     AS overhead_usd,
    COALESCE(a.fully_loaded_usd, 0) AS fully_loaded_usd,
    p.budget_usd,
    p.forecast_usd,
    COALESCE(a.actual_usd,0) - p.budget_usd   AS var_vs_budget_usd,    -- positive = over budget
    COALESCE(a.actual_usd,0) - p.forecast_usd AS var_vs_forecast_usd,
    ROUND((COALESCE(a.actual_usd,0) / NULLIF(p.budget_usd,0) - 1) * 100, 1) AS var_vs_budget_pct
FROM actual a
FULL OUTER JOIN plan p
  ON p.DATE_KEY = a.DATE_KEY AND p.PRODUCT_ID = a.PRODUCT_ID;

/* ---------------------------------------------------------------------
   5) ANALYSIS: top cost drivers & notable variances
   --------------------------------------------------------------------- */
-- Top cost drivers by pool
SELECT COST_POOL_ID, ROUND(SUM(direct_and_alloc_usd)) AS cost
FROM FCT_FULLY_LOADED_COST GROUP BY COST_POOL_ID ORDER BY cost DESC;

-- Top cost drivers by product (fully-loaded)
SELECT PRODUCT_ID, ROUND(SUM(fully_loaded_usd)) AS fully_loaded
FROM FCT_FULLY_LOADED_COST GROUP BY PRODUCT_ID ORDER BY fully_loaded DESC;

-- Top 3 products by product AND period, with month-over-month trend
WITH product_totals AS (
    SELECT PRODUCT_ID, SUM(fully_loaded_usd) AS total_cost
    FROM FCT_FULLY_LOADED_COST
    GROUP BY PRODUCT_ID
),
top3_products AS (
    SELECT PRODUCT_ID FROM product_totals ORDER BY total_cost DESC LIMIT 3
)
SELECT
    f.PRODUCT_ID,
    f.DATE_KEY,
    ROUND(SUM(f.fully_loaded_usd)) AS fully_loaded,
    ROUND(SUM(f.fully_loaded_usd)
          - LAG(SUM(f.fully_loaded_usd)) OVER (PARTITION BY f.PRODUCT_ID ORDER BY f.DATE_KEY)) AS mom_delta_usd,
    ROUND(100.0 * (SUM(f.fully_loaded_usd)
          - LAG(SUM(f.fully_loaded_usd)) OVER (PARTITION BY f.PRODUCT_ID ORDER BY f.DATE_KEY))
          / NULLIF(LAG(SUM(f.fully_loaded_usd)) OVER (PARTITION BY f.PRODUCT_ID ORDER BY f.DATE_KEY), 0), 1) AS mom_pct
FROM FCT_FULLY_LOADED_COST f
JOIN top3_products t ON t.PRODUCT_ID = f.PRODUCT_ID
GROUP BY f.PRODUCT_ID, f.DATE_KEY
ORDER BY f.PRODUCT_ID, f.DATE_KEY;
-- Result (Q1 2025): PR01 Compute $8.00M -> $6.22M (-22.3%) -> $5.86M (-5.8%)
--                   PR03 Database $3.08M -> $1.04M (-66.3%) -> $0.70M (-32.4%)
--                   PR05 End-User $1.35M -> $1.36M (+1.2%)  -> $1.08M (-20.6%)
-- All three top products decline over the quarter; Database drops sharpest (-66% in Feb).

-- Largest budget variances
SELECT date_key, product_id, actual_usd, budget_usd, var_vs_budget_usd, var_vs_budget_pct
FROM VW_VARIANCE WHERE budget_usd IS NOT NULL
ORDER BY ABS(var_vs_budget_usd) DESC LIMIT 10;

-- Full variance surface, all products x periods (20 rows for Q1 2025)
SELECT * FROM VW_VARIANCE ORDER BY product_id, date_key;
-- Confirms: PR01 Compute -9.8% / -19.0% / -21.2% vs budget; PR03 Database -19.6% / -36.9% / -39.8%;
--           PR05 End-User +5486.6% (Jan) / +5815.8% (Feb); PR06 Security +9459.4% (Jan) - both
--           labour-allocation artifacts, not overspend (see methodology note).
-- New: PR07 Cloud Platform is over budget every month (+14.0% / +9.8% / +1.4%) - the only
--      product consistently over budget across the whole quarter, narrowing toward breakeven.
-- Data gap: PR04 Network has no row (no actual cost, no budget/forecast) for 202502.
--           PR02/PR05/PR06 also lose budget/forecast (nulls) in later months - variance is
--           only computable where a plan exists, and that gap is disclosed, not backfilled.
