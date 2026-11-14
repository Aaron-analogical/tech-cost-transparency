# Part A — Methodology Note: Cost Transparency & Attribution

**Scope:** Meridian Technology Infrastructure, General Ledger for Q1 2025 (Jan to Mar), total base of $40.17M. This note explains how raw GL spend is attributed down to Product and Application and rolled up to Program and Funding Request, how the shared-overhead bucket is handled, the assumptions made, and the headline findings.

## Data model

The analytical layer is a star schema built in staged layers: raw CSV tables, cleaned staging, an intermediate allocation layer, and a final mart. The core fact, `FCT_FULLY_LOADED_COST`, is at grain of one row per `date x cost_pool x product x application`. Cost pool is deliberately kept in the grain (rather than collapsed) so that scenario analysis can act on individual pools. Two satellite facts share conformed dimensions: `VW_VARIANCE` (actual vs budget vs forecast at product grain) and the retained consumption fact (driver volumes, also the unit-cost denominator). Program and Funding Request are not native to any cost table; they are reached through a product-to-funding-request bridge derived from the budget/forecast data.

## Allocation methodology

Cost is attributed in two hops:

1. **Cost pool to product.** GL rows already tagged to a product (for example hardware depreciation) are treated as direct cost. Rows with no product (labour, cloud, data centre, vendor) are split across their target products using `FACT_ALLOCATION_MAP` for the rule and `FACT_CONSUMPTION` for the weights (each product's share of the relevant driver volume: vCPU-hours, GB stored, headcount, or tickets).
2. **Product to application.** Each product's cost is split across its applications in proportion to each application's share of that product's driver volume for the period.

The result rolls up cleanly to Program and Funding Request. Allocation reconciles to the GL to within rounding (allocated $40,171,993 vs GL $40,172,000, a difference of $7, or 0.00002%, from floating-point share arithmetic).

## Shared / unallocated overhead (CP99 / PR99)

The `CP99` "Shared / Unallocated Overhead" pool (carried on product `PR99`) is $3.2M, about 8% of the base. It has no allocation rule and no consumption meter, so it cannot be split by a driver. Policy adopted: **spread it pro-rata to each application's direct-plus-allocated cost, but carry it in its own column (`overhead_loading_usd`) separate from `fully_loaded_usd`.** Rationale: shared overhead tends to scale with the size of the operation it supports, and with no driver available, cost is the best proxy. Keeping it in a separate column means the loading is fully transparent and can be toggled off. Trade-off: pro-rata to cost makes large products absorb more overhead regardless of causation; headcount or an even split are defensible alternatives and are candidates for sensitivity testing.

## Key assumptions

1. **Mixed-driver pools (equal group weighting).** Labour (CP01) and Data Centre (CP04) each allocate across products measured in different units (for example CPU-hours and headcount), which are not directly comparable. Each driver group is given an equal share of the pool, then split within the group by measured volume. This is the single most influential assumption (see Findings).
2. **Carry-forward for missing driver feeds.** Where a product's usage feed is absent for a month, the most recent prior month's volume is used as the weight rather than dropping the cost. This is standard treatment for a late or missing feed and is why the model reconciles to the GL.
3. **Variance comparison basis.** Actual is compared to budget and forecast on a direct-plus-allocated (pre-overhead) basis, since budgets are not set with allocated overhead loaded. Overhead is reported separately.
4. **Funding-request mapping.** Product maps 1:1 to a single funding request in this dataset. `FR0004` is intentionally unmapped and is left as-is.

## Findings

- **Concentration.** Three cost pools drive ~70% of the base: Labour ($12.4M, 31%), Public Cloud ($9.3M, 23%), and HW Depreciation ($6.25M, 16%). By product, the top 3 are Compute ($20.1M), Database ($4.82M), and End-User ($3.79M) — Compute alone is almost exactly half of all fully-loaded cost.
- **All three top products decline through the quarter, not just Compute.** Compute: $8.00M (Jan) -> $6.22M (Feb, -22.3%) -> $5.86M (Mar, -5.8%). Database drops sharpest: $3.08M -> $1.04M (-66.3%) -> $0.70M (-32.4%). End-User is flat then drops: $1.35M -> $1.36M (+1.2%) -> $1.08M (-20.6%).
- **Compute is under budget and the gap is widening** (-9.8% Jan, -19.0% Feb, -21.2% Mar). As half the cost base, this dominates the aggregate and points to a reforecast or released-budget opportunity. Database shows the same pattern (-19.6% to -39.8%) — consistent with its actual cost also declining fastest of the three.
- **In aggregate, actual lands within ~1% of budget, but this masks large offsetting swings** (Compute and Database under, End-User and Security over). The composition, not the total, is where the risk sits.
- **End-User and Security show extreme positive variances (End-User +5,486.6% Jan / +5,815.8% Feb; Security +9,459.4% Jan). This is an artifact of the labour allocation, not operational overspend:** the equal-group rule routes ~50% of the $4.4M/month labour pool to the two headcount-driven products, against token budgets ($10k-$25k/month). It is disclosed as assumption-driven and is the primary sensitivity for Part B.
- **Cloud Platform (PR07) is over budget every month of the quarter** (+14.0% Jan, +9.8% Feb, +1.4% Mar) — the only product consistently over budget across all three months, though the overage is narrowing toward breakeven. Worth watching next quarter; not yet a red flag given the trend.
- **Data coverage gaps limit variance comparability for smaller products.** Network (PR04) has no actual cost or budget/forecast recorded at all for Feb 2025 — a genuine hole, not a rounding artifact. Storage, End-User, and Security also lose budget/forecast data in later months (nulls from Feb/Mar onward), so their variance can only be computed where a plan exists; this is disclosed rather than backfilled.

## Limitations and next steps

With more time: sensitivity-test the labour split under alternative bases; model the product-to-funding-request relationship as a weighted many-to-many (it is 1:1 here but often is not in practice); and add a backstop for any driver group with no history at all (none occurs in this dataset). The full period is only one quarter, so trend statements are directional.
