"""Draw the S1 sensitivity heatmap from S1_sensitivity_grid.csv (written by run_local.py).

    python plot_sensitivity.py           # README version, with title
    python plot_sensitivity.py --slide   # deck version: slide background, no title
"""
import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap, TwoSlopeNorm
from matplotlib.patches import Rectangle

HERE = Path(__file__).parent
rows = list(csv.DictReader(open(HERE / "S1_sensitivity_grid.csv")))
factors = sorted({float(r["cloud_cost_factor"]) for r in rows})
avoid = sorted({float(r["dc_avoidable_pct"]) for r in rows}, reverse=True)
val = {(float(r["cloud_cost_factor"]), float(r["dc_avoidable_pct"])): int(r["s1_delta_usd"]) for r in rows}
grid = [[val[(f, a)] for f in factors] for a in avoid]

SLIDE = "--slide" in sys.argv
INK, INK2 = "#0b0b0b", "#52514e"
SURFACE = "#f4f7fb" if SLIDE else "#fcfcfb"
# Diverging: blue (saving) <- neutral gray -> red (extra cost)
cmap = LinearSegmentedColormap.from_list("div", ["#1c5cab", "#86b6ef", "#f0efec", "#ee9a99", "#b42f2e"])
vmax = max(abs(v) for v in val.values())
norm = TwoSlopeNorm(vmin=-vmax, vcenter=0, vmax=vmax)  # symmetric, so colour depth = dollar size

plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11})
fig, ax = plt.subplots(figsize=(8.6, 5.2), dpi=200)
fig.patch.set_facecolor(SURFACE)
ax.set_facecolor(SURFACE)

for i, row in enumerate(grid):
    for j, v in enumerate(row):
        ax.add_patch(Rectangle((j + 0.03, i + 0.03), 0.94, 0.94, facecolor=cmap(norm(v)), edgecolor="none"))
        r, g, b, _ = cmap(norm(v))
        light = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5
        label = r"\$0" if v == 0 else f"{'+' if v > 0 else '−'}\\${abs(v) / 1000:,.0f}k"
        ax.text(j + 0.5, i + 0.5, label, ha="center", va="center", fontsize=11.5,
                color=INK if light else "white", fontweight="bold" if (factors[j], avoid[i]) in {(1.10, 1.0), (1.10, 0.0)} else "normal")

# Outline the base case and the stranded-cost case
for (f, a), tag in {(1.10, 1.0): "base case", (1.10, 0.0): "fully stranded"}.items():
    j, i = factors.index(f), avoid.index(a)
    ax.add_patch(Rectangle((j + 0.03, i + 0.03), 0.94, 0.94, fill=False, edgecolor=INK, linewidth=2))

ax.set_xlim(0, len(factors)); ax.set_ylim(len(avoid), 0)
ax.set_xticks([j + 0.5 for j in range(len(factors))])
ax.set_xticklabels([f"{f:.2f}\n({'+' if f > 1 else ''}{(f - 1) * 100:.0f}%)" if f != 1 else "1.00\n(parity)" for f in factors], color=INK2)
ax.set_yticks([i + 0.5 for i in range(len(avoid))])
ax.set_yticklabels([f"{a:.0%}" for a in avoid], color=INK2)
ax.tick_params(length=0)
for s in ax.spines.values():
    s.set_visible(False)
ax.set_xlabel("Cloud unit cost vs owned data centre", color=INK2, labelpad=8)
ax.set_ylabel("Share of migrated data-centre\ncost actually shed", color=INK2, labelpad=8)
if SLIDE:
    fig.set_size_inches(8.6, 4.4)
    fig.subplots_adjust(left=0.2, right=0.97, top=0.98, bottom=0.2)
    out = HERE.parent / "presentation" / "_slide_heatmap.png"
else:
    fig.suptitle("Moving 15% of the data centre to cloud: change in quarterly cost", x=0.05, y=0.975, ha="left", fontsize=13.5, color=INK, fontweight="bold")
    fig.text(0.05, 0.905, "It only saves money if cloud is cheaper and the data-centre cost really goes away (blue = saving).\n"
             r"Outlined: base case (+\$50k) and fully stranded data centre (+\$555k).",
             fontsize=10, color=INK2, ha="left", va="top", linespacing=1.5)
    fig.subplots_adjust(left=0.2, right=0.97, top=0.80, bottom=0.17)
    out = HERE / "S1_sensitivity_heatmap.png"
fig.savefig(out, facecolor=SURFACE)
print("wrote", out)
