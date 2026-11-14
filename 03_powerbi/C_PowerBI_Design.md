# Part C — Power BI Solution: Semantic Model & DAX

## 1. Semantic model

A single-fact star schema with two satellite facts sharing conformed dimensions.

**Fact tables**

| Table | Grain | Key measures |
|---|---|---|
| FCT_FULLY_LOADED_COST | date x cost_pool x product x application (monthly) | direct_and_alloc_usd, overhead_loading_usd, fully_loaded_usd |
| FACT_CONSUMPTION | date x product x application x region x entity x driver | driver_qty (unit-cost denominator) |
| FACT_BUDGET_FORECAST | date x product | budget_usd, forecast_usd |

**Dimensions:** DIM_DATE, DIM_COST_POOL, DIM_PRODUCT, DIM_APPLICATION, and BRIDGE_PRODUCT_FUNDING_PROGRAM (rollup bridge: product → funding request → program, one row per product). DIM_FUNDING_REQUEST and DIM_PROGRAM are build-time inputs to the bridge only — they are not imported into the Power BI model and have no relationship to the fact.

**Relationships:** all one-to-many from dimension to fact, single-direction filtering.

| From (1) | To (many) |
|---|---|
| DIM_DATE | FCT_FULLY_LOADED_COST, FACT_CONSUMPTION, FACT_BUDGET_FORECAST |
| DIM_PRODUCT | FCT_FULLY_LOADED_COST, FACT_CONSUMPTION, FACT_BUDGET_FORECAST |
| DIM_APPLICATION | FCT_FULLY_LOADED_COST, FACT_CONSUMPTION |
| DIM_COST_POOL | FCT_FULLY_LOADED_COST |
| BRIDGE_PRODUCT_FUNDING_PROGRAM | FCT_FULLY_LOADED_COST (on product_id) |

**Design decisions**

- Single-direction one-to-many relationships keep filtering predictable and performant.
- Funding request and program reach the fact through BRIDGE_PRODUCT_FUNDING_PROGRAM rather than being flattened onto DIM_PRODUCT, so cost can be sliced by program and funding request without denormalizing that context onto the product dimension itself. The bridge assumes each product maps to exactly one funding request (1:1 in this data; FR0004 intentionally unmapped) — if that ever became many-to-many, the relationship would need to change from one-to-many to many-to-many (or a bridge with a distinct grain).
- Mixed grains are handled by shared dimensions. Budget is product-month, so budget measures return blank if sliced by application or cost pool. This is expected and is noted on the variance visual.
- The what-if parameter is a disconnected table feeding the scenario measure through SELECTEDVALUE.
- FACT_CONSUMPTION is the largest table and is a candidate for a user-defined aggregation in production.

## 2. DAX measures

```dax
Fully-Loaded Cost =
SUM ( FCT_FULLY_LOADED_COST[FULLY_LOADED_USD] )
```

```dax
Cost per vCPU-hour =
DIVIDE (
    [Fully-Loaded Cost],
    CALCULATE (
        SUM ( FACT_CONSUMPTION[DRIVER_QTY] ),
        FACT_CONSUMPTION[DRIVER_TYPE] = "vCPU_HOURS"
    )
)
```

```dax
Variance % vs Budget =
VAR ActualPreOverhead = SUM ( FCT_FULLY_LOADED_COST[DIRECT_AND_ALLOC_USD] )
VAR Budget = SUM ( FACT_BUDGET_FORECAST[BUDGET_USD] )
RETURN DIVIDE ( ActualPreOverhead - Budget, Budget )
```

```dax
Allocation % of Total =
DIVIDE (
    [Fully-Loaded Cost],
    CALCULATE ( [Fully-Loaded Cost], REMOVEFILTERS ( DIM_PRODUCT, DIM_APPLICATION ) )
)
```

```dax
Scenario Cloud Delta =
VAR MigPct = SELECTEDVALUE ( 'Cloud Migration %'[Cloud Migration %], 0.15 )
VAR CloudFactor = 1.10
VAR DCCost =
    CALCULATE (
        SUM ( FCT_FULLY_LOADED_COST[DIRECT_AND_ALLOC_USD] ),
        DIM_COST_POOL[COST_POOL_ID] = "CP04"
    )
RETURN DCCost * MigPct * ( CloudFactor - 1 )
```

```dax
Fully-Loaded Cost (Scenario) =
[Fully-Loaded Cost] + [Scenario Cloud Delta]
```

Consistency note: Variance % vs Budget compares on the pre-overhead basis (direct_and_alloc_usd), matching the Part A methodology, while Fully-Loaded Cost uses the loaded figure.

## 3. What-if parameter

Modeling tab, New parameter, Numeric range:

- Name: Cloud Migration %
- Min 0, Max 0.50, Increment 0.05, Default 0.15

Power BI generates a disconnected table and a value measure from that spec:

```dax
Cloud Migration % = GENERATESERIES ( 0, 0.5, 0.05 )
```

```dax
Cloud Migration % Value =
SELECTEDVALUE ( 'Cloud Migration %'[Cloud Migration %], 0.15 )
```

The auto-created slicer for this table is dropped onto the dashboard as a **parameter card** (the standard Power BI what-if visual: title, current value, and a slider bound to the table above). Moving the slider changes the selected value in the disconnected table, which `Scenario Cloud Delta` reads via `SELECTEDVALUE`, which in turn drives `Fully-Loaded Cost (Scenario)` — so a single slider move recalculates the cloud-migration impact live for live what-if questions. This mirrors the `SCENARIO_PARAM` table from Part B: one parameter, one measure, no report-level rewiring needed to flex it.

## 4. Dashboard wireframes

See accompanying wireframe screens (executive overview, cost transparency drill, scenario what-if). On the scenario screen, a bookmark toggle (or a disconnected field-parameter slicer, same pattern as the numeric what-if parameter) switches the product-breakdown visual between the two scenarios, so the CFO can flip from "what does cloud migration hit" to "what does the vendor increase hit" without both being drawn at once.
