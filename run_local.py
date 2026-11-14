"""Run the whole model locally on DuckDB, no Snowflake account needed.

    pip install duckdb
    python run_local.py

Loads the CSVs in data/, runs the attribution SQL (01_attribution) and the
scenario SQL (02_scenarios) unchanged apart from the `USE SCHEMA` line,
checks that the allocation reconciles, and writes the scenario sensitivity
grid to 02_scenarios/S1_sensitivity_grid.csv.
"""
import re
import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).parent
TOL = 0.01  # dollars

ID_COLUMNS = {"date_key", "map_id", "bf_id", "gl_id", "consumption_id"}


def load_csvs(con):
    for f in sorted((ROOT / "data").glob("*.csv")):
        table = f.stem.upper()
        con.execute(
            f"CREATE OR REPLACE TABLE {table} AS "
            f"SELECT * FROM read_csv_auto('{f.as_posix()}', header=true, all_varchar=true)"
        )
        # Cast numeric columns; keep IDs (including date_key) as text, as in Snowflake.
        cols = con.execute(f"DESCRIBE {table}").fetchall()
        for name, *_ in cols:
            if name.endswith(("_usd", "_qty", "_weight")):
                con.execute(f"ALTER TABLE {table} ALTER {name} TYPE DOUBLE USING TRY_CAST(NULLIF({name}, '') AS DOUBLE)")
            elif name == "date_key":
                con.execute(f"ALTER TABLE {table} ALTER {name} TYPE INTEGER")
            else:
                con.execute(f"UPDATE {table} SET {name} = NULL WHERE {name} = ''")


def run_sql_file(con, path):
    sql = path.read_text(encoding="utf-8")
    sql = re.sub(r"(?im)^\s*USE SCHEMA .*?;\s*$", "", sql)
    # Strip comments, then run statement by statement.
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)
    sql = re.sub(r"--[^\n]*", "", sql)
    for stmt in (s.strip() for s in sql.split(";")):
        if stmt:
            con.execute(stmt)


def check(label, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {label}{(' - ' + detail) if detail else ''}")
    return ok


def main():
    con = duckdb.connect()
    load_csvs(con)
    run_sql_file(con, ROOT / "01_attribution" / "A_Attribution_Variance.sql")
    run_sql_file(con, ROOT / "02_scenarios" / "B_Scenario_Model.sql")

    q = lambda s: con.execute(s).fetchone()[0]
    results = []
    print("Checks")

    gl = q("SELECT SUM(AMOUNT_USD) FROM FACT_GL_COST")
    fl = q("SELECT SUM(fully_loaded_usd) FROM FCT_FULLY_LOADED_COST")
    results.append(check("Fully-loaded total reconciles to GL", abs(gl - fl) < TOL, f"GL ${gl:,.2f} vs allocated ${fl:,.2f}"))

    worst = q("""
        SELECT MAX(ABS(g.gl - COALESCE(f.fl, 0))) FROM
          (SELECT DATE_KEY, SUM(AMOUNT_USD) gl FROM FACT_GL_COST GROUP BY 1) g
          LEFT JOIN (SELECT DATE_KEY, SUM(fully_loaded_usd) fl FROM FCT_FULLY_LOADED_COST GROUP BY 1) f USING (DATE_KEY)""")
    results.append(check("Every month reconciles to GL", worst < TOL, f"worst gap ${worst:,.4f}"))

    worst_pool = q("""
        SELECT MAX(ABS(g.gl - COALESCE(f.da, 0))) FROM
          (SELECT DATE_KEY, COST_POOL_ID, SUM(AMOUNT_USD) gl FROM FACT_GL_COST WHERE COST_POOL_ID <> 'CP99' GROUP BY 1, 2) g
          LEFT JOIN (SELECT DATE_KEY, COST_POOL_ID, SUM(direct_and_alloc_usd) da FROM FCT_FULLY_LOADED_COST GROUP BY 1, 2) f
          USING (DATE_KEY, COST_POOL_ID)""")
    results.append(check("Every month x cost pool reconciles (no cost leaks in either hop)", worst_pool < TOL, f"worst gap ${worst_pool:,.4f}"))

    oh_gl = q("SELECT SUM(AMOUNT_USD) FROM FACT_GL_COST WHERE COST_POOL_ID = 'CP99'")
    oh = q("SELECT SUM(overhead_loading_usd) FROM FCT_FULLY_LOADED_COST")
    results.append(check("Shared overhead (CP99) fully spread", abs(oh_gl - oh) < TOL, f"${oh:,.0f} of ${oh_gl:,.0f}"))

    neg = q("SELECT COUNT(*) FROM FCT_FULLY_LOADED_COST WHERE fully_loaded_usd < 0")
    results.append(check("No negative allocations", neg == 0))

    cp06 = q("SELECT SUM(direct_and_alloc_usd) FROM FCT_FULLY_LOADED_COST WHERE COST_POOL_ID = 'CP06'")
    s2 = q("SELECT SUM(s2_delta) FROM VW_SCENARIO_BY_PRODUCT")
    # The scenario views round each product to the dollar, so allow a few dollars of drift.
    results.append(check("S2 delta = 8% x vendor pool", abs(s2 - 0.08 * cp06) < 10, f"${s2:,.0f} vs ${0.08 * cp06:,.0f}"))

    cp04 = q("SELECT SUM(direct_and_alloc_usd) FROM FCT_FULLY_LOADED_COST WHERE COST_POOL_ID = 'CP04'")
    s1 = q("SELECT SUM(s1_delta) FROM VW_SCENARIO_BY_PRODUCT")
    p = dict(con.execute("SELECT param_name, param_value FROM SCENARIO_PARAM WHERE scenario_id = 'S1'").fetchall())
    expected = cp04 * float(p["dc_migration_pct"]) * (float(p["cloud_cost_factor"]) - float(p["dc_avoidable_pct"]))
    results.append(check("S1 delta = DC pool x 15% x (cloud factor - avoidable share)", abs(s1 - expected) < 10, f"${s1:,.0f} vs ${expected:,.0f}"))

    # Sensitivity grid: cloud cost factor x share of migrated DC cost that is actually avoided.
    factors = [0.80, 0.90, 1.00, 1.10, 1.20]
    avoidable = [1.00, 0.75, 0.50, 0.25, 0.00]
    rows = []
    for a in avoidable:
        for f in factors:
            con.execute("UPDATE SCENARIO_PARAM SET param_value = ? WHERE param_name = 'cloud_cost_factor'", [f])
            con.execute("UPDATE SCENARIO_PARAM SET param_value = ? WHERE param_name = 'dc_avoidable_pct'", [a])
            rows.append((f, a, round(q("SELECT SUM(s1_delta) FROM VW_SCENARIO_BY_PRODUCT"))))
    out = ROOT / "02_scenarios" / "S1_sensitivity_grid.csv"
    out.write_text("cloud_cost_factor,dc_avoidable_pct,s1_delta_usd\n" + "".join(f"{f:.2f},{a:.2f},{d}\n" for f, a, d in rows))

    print(f"\nBaseline fully-loaded: ${fl:,.0f}")
    print(f"S1 cloud migration (default params): {s1:+,.0f}")
    print(f"S2 vendor +8%: {s2:+,.0f}")
    print(f"\nS1 sensitivity, $ delta (rows: share of migrated DC cost avoided; columns: cloud cost factor)")
    print("          " + "".join(f"{f:>10.2f}" for f in factors))
    for a in avoidable:
        print(f"{a:>8.0%}  " + "".join(f"{d:>+10,}" for f2, a2, d in rows if a2 == a))
    print(f"\nWrote {out.relative_to(ROOT)}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
