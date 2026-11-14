# Technology Infrastructure Cost Transparency

A three-day case study in Technology Business Management (TBM). The company, "Meridian Group", is fictional, and all data is synthetic.

Meridian's infrastructure costs sit in the General Ledger by cost pool (labour, hardware depreciation, licences, data centre, public cloud, managed services, network). Business owners see one fully-loaded number and can't tell what drives it or who consumes it. The work here attributes that $40.2M quarter down to products, applications, programs and funding requests, runs two what-if scenarios, and packages the result for a CFO.

**Stack:** Snowflake SQL, Power BI (PBIP / TMDL, DAX), dimensional modelling.

## Results (Q1 2025, $40.2M base)

- **Allocation reconciles to the GL within rounding.** GL cost pool → product → application, then rolled up to program and funding request.
- **Cost is concentrated.** Compute is about 50% of fully-loaded cost. Labour, Public Cloud and hardware depreciation drive about 70% of the base.
- **Budget variance nets to about 1%, but hides big offsets.** Compute runs 10% under budget in January and 21% under by March.
- **Vendor +8% scenario: +$204k**, landing on Database and Cloud Platform.
- **Cloud migration (15% of data centre) scenario: +$50k to +$555k.** The sign flips with the cloud unit-rate assumption, and the upper end applies if fixed data-centre cost doesn't shed when workload leaves.

## What's in the repo

| Folder | Contents |
|---|---|
| [`01_attribution/`](01_attribution) | ER diagram ([SVG](01_attribution/A_Data_Model.svg)), data model notes, allocation + variance SQL, methodology note |
| [`02_scenarios/`](02_scenarios) | Parameterised scenario SQL, assumptions table, results and sensitivity |
| [`03_powerbi/`](03_powerbi) | Semantic model diagram, DAX measures, what-if parameter design, [dashboard wireframes](https://aaron-analogical.github.io/tech-cost-transparency/03_powerbi/C_Dashboard_Wireframes.html) |
| [`04_executive_summary/`](04_executive_summary) | One-page summary for a non-technical CFO |
| [`presentation/`](presentation) | 17-slide deck |
| [`powerbi/`](powerbi) | Working Power BI project (PBIP) built on the Snowflake tables |
| [`data/`](data) | Synthetic source tables: 8 dimensions, 4 facts |

## Methodology choices

1. **Driver-based allocation.** `fact_allocation_map` says which consumption driver (vCPU-hours, GB stored, tickets, headcount) splits each pool; `fact_consumption` supplies the weights.
2. **Mixed-driver pools** (Labour, Data Centre) get equal weight per driver group. This choice explains the large End-User and Security figures, so the summary calls it out.
3. **Missing monthly driver feeds** carry forward the last known volume, which is why the model reconciles.
4. **Shared overhead** (CP99, about 8%) has no driver. It is spread pro-rata on direct-plus-allocated cost but kept in its own column, so it can be switched off.
5. **Variance** compares actuals to budget before overhead loading, matching how the budgets were set.

The full reasoning is in [`A_Methodology_Note.md`](01_attribution/A_Methodology_Note.md) and [`B_Scenario_Results.md`](02_scenarios/B_Scenario_Results.md).

## Running it

**Snowflake.** Load the CSVs in `data/` into a schema (the scripts use `CASE_STUDY.MERIDIAN`), then run `01_attribution/A_Attribution_Variance.sql` followed by `02_scenarios/B_Scenario_Model.sql`.

**Power BI.** Open `powerbi/TechCostTransparency.pbip` in Power BI Desktop. In each table's source, replace `<your-account>` with your Snowflake account identifier, then refresh.
