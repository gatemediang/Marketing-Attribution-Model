"""
Marketing Attribution Capstone — Python Analysis Engine
Implements all 5 attribution models, computes ROI, and exports results
for Power BI and the Excel deliverable.
"""

import pandas as pd
import numpy as np

# ── LOAD DATA ──────────────────────────────────────────────────────────────────
tp  = pd.read_csv("/home/claude/marketing_attribution/data/touchpoints.csv",
                  parse_dates=["touchpoint_date"])
cus = pd.read_csv("/home/claude/marketing_attribution/data/customers.csv",
                  parse_dates=["acq_date"])
sp  = pd.read_csv("/home/claude/marketing_attribution/data/channel_spend.csv")

CHANNELS = sorted(tp["channel"].unique())

# ── MODEL 1: FIRST-TOUCH ───────────────────────────────────────────────────────
ft = (tp[tp["is_first_touch"] & tp["converted"]]
      .groupby("channel")["revenue_usd"].sum()
      .rename("first_touch_revenue"))

# ── MODEL 2: LAST-TOUCH ────────────────────────────────────────────────────────
lt = (tp[tp["is_last_touch"] & tp["converted"]]
      .groupby("channel")["revenue_usd"].sum()
      .rename("last_touch_revenue"))

# ── MODEL 3: LINEAR ────────────────────────────────────────────────────────────
converters = cus[cus["converted"]][["customer_id", "revenue"]]
tp_conv = tp.merge(converters, on="customer_id", how="inner")
tp_conv["linear_credit"] = tp_conv["revenue"] / tp_conv["journey_length"]
lin = tp_conv.groupby("channel")["linear_credit"].sum().rename("linear_revenue")

# ── MODEL 4: TIME-DECAY (half-life = 7 days) ───────────────────────────────────
tp_td = tp.merge(cus[["customer_id", "revenue", "acq_date"]], on="customer_id")
tp_td["days_to_conv"] = (tp_td["acq_date"] - tp_td["touchpoint_date"]).dt.days.clip(lower=0)
tp_td["decay_weight"] = 2 ** (-tp_td["days_to_conv"] / 7.0)
tp_td["total_decay"]  = tp_td.groupby("customer_id")["decay_weight"].transform("sum")
tp_td["td_credit"]    = tp_td["revenue"] * tp_td["decay_weight"] / tp_td["total_decay"]
td = tp_td.groupby("channel")["td_credit"].sum().rename("time_decay_revenue")

# ── MODEL 5: U-SHAPED (40/20/40) ──────────────────────────────────────────────
def u_shaped_credit(row):
    if row["journey_length"] == 1:
        return row["revenue"]
    elif row["is_first_touch"] and not row["is_last_touch"]:
        return row["revenue"] * 0.40
    elif row["is_last_touch"] and not row["is_first_touch"]:
        return row["revenue"] * 0.40
    elif row["is_first_touch"] and row["is_last_touch"]:
        return row["revenue"]
    else:
        middle_count = max(row["journey_length"] - 2, 1)
        return row["revenue"] * 0.20 / middle_count

tp_us = tp.merge(converters, on="customer_id", how="inner")
tp_us["us_credit"] = tp_us.apply(u_shaped_credit, axis=1)
us = tp_us.groupby("channel")["us_credit"].sum().rename("u_shaped_revenue")

# ── COMPILE ATTRIBUTION COMPARISON ────────────────────────────────────────────
attr = pd.DataFrame(index=CHANNELS)
attr = attr.join([ft, lt, lin, td, us]).fillna(0).round(2)
attr.index.name = "channel"

# Percentage shares
for col in attr.columns:
    attr[col.replace("_revenue", "_share_pct")] = (
        100 * attr[col] / attr[col].sum()
    ).round(2)

# ── ROI ANALYSIS ───────────────────────────────────────────────────────────────
spend_total = sp.groupby("channel")["spend_usd"].sum().rename("total_spend")
roi = attr[["time_decay_revenue"]].join(spend_total)
roi["marketing_roi"]           = ((roi["time_decay_revenue"] - roi["total_spend"])
                                   / roi["total_spend"]).round(2)
roi["revenue_per_dollar"]      = (roi["time_decay_revenue"]
                                   / roi["total_spend"]).round(2)
roi["current_budget_share"]    = (100 * roi["total_spend"]
                                   / roi["total_spend"].sum()).round(1)
roi["optimal_budget_share"]    = (100 * roi["time_decay_revenue"]
                                   / roi["time_decay_revenue"].sum()).round(1)
roi["budget_delta_pp"]         = (roi["optimal_budget_share"]
                                   - roi["current_budget_share"]).round(1)

# ── REALLOCATION OPPORTUNITY ───────────────────────────────────────────────────
# Channels where budget_delta_pp > 0  → underfunded relative to contribution
# Channels where budget_delta_pp < 0  → overfunded
total_budget_18mo = roi["total_spend"].sum()
underfunded  = roi[roi["budget_delta_pp"] > 0]["budget_delta_pp"].sum()
overfunded   = roi[roi["budget_delta_pp"] < 0]["budget_delta_pp"].abs().sum()
realloc_pct  = round(max(underfunded, overfunded), 1)
realloc_usd  = round(total_budget_18mo * realloc_pct / 100, 0)

print("=" * 60)
print("ATTRIBUTION MODEL REVENUE COMPARISON ($)")
print("=" * 60)
print(attr[["first_touch_revenue","last_touch_revenue",
            "linear_revenue","time_decay_revenue","u_shaped_revenue"]].to_string())

print("\n" + "=" * 60)
print("ROI & BUDGET ANALYSIS")
print("=" * 60)
print(roi[["total_spend","time_decay_revenue","marketing_roi",
           "revenue_per_dollar","current_budget_share",
           "optimal_budget_share","budget_delta_pp"]].to_string())

print(f"\n{'='*60}")
print(f"REALLOCATION OPPORTUNITY")
print(f"{'='*60}")
print(f"Total 18-month spend : ${total_budget_18mo:>12,.0f}")
print(f"Reallocation signal  : {realloc_pct}% of budget = ${realloc_usd:>,.0f}")
print(f"Confirmed ≥ 40%?     : {'✅ YES' if realloc_pct >= 40 else '⚠ Below 40% — check weights'}")

# ── MONTHLY TREND ──────────────────────────────────────────────────────────────
monthly = (tp[tp["converted"]]
           .assign(month=tp["touchpoint_date"].dt.to_period("M").astype(str))
           .groupby(["month","channel"])["revenue_usd"].sum()
           .reset_index(name="revenue"))

sp["month"] = sp["month"].astype(str)
monthly_spend = sp.groupby(["month","channel"])["spend_usd"].sum().reset_index()
monthly_full = monthly.merge(monthly_spend, on=["month","channel"], how="left").fillna(0)
monthly_full["roas"] = (monthly_full["revenue"] / monthly_full["spend_usd"].replace(0, np.nan)).round(2)

# ── CHANNEL PATH ANALYSIS ──────────────────────────────────────────────────────
conv_cust = set(cus[cus["converted"]]["customer_id"])
tp_paths = (tp[tp["customer_id"].isin(conv_cust)]
            .sort_values(["customer_id","journey_position"]))

# Build 2-step paths
paths_list = []
for cid, grp in tp_paths.groupby("customer_id"):
    channels = grp["channel"].tolist()
    for i in range(len(channels) - 1):
        paths_list.append(f"{channels[i]} → {channels[i+1]}")

path_counts = (pd.Series(paths_list)
               .value_counts()
               .head(20)
               .reset_index())
path_counts.columns = ["channel_path", "conversions"]

# ── SEGMENT BREAKDOWN ──────────────────────────────────────────────────────────
by_region = (tp[tp["converted"]]
             .groupby(["region","channel"])["revenue_usd"].sum()
             .reset_index())
by_device = (tp[tp["converted"]]
             .groupby(["device","channel"])["revenue_usd"].sum()
             .reset_index())

# ── EXECUTIVE KPIs ─────────────────────────────────────────────────────────────
kpis = {
    "Total Customers":          cus["customer_id"].nunique(),
    "Total Conversions":        int(cus["converted"].sum()),
    "Conversion Rate (%)":      round(100*cus["converted"].mean(), 1),
    "Total Revenue ($)":        int(cus["revenue"].sum()),
    "Total Spend ($)":          int(roi["total_spend"].sum()),
    "Blended ROAS":             round(cus["revenue"].sum() / roi["total_spend"].sum(), 2),
    "Cost Per Acquisition ($)": round(roi["total_spend"].sum() / cus["converted"].sum(), 2),
    "Avg Journey Length":       round(tp.groupby("customer_id")["journey_length"].max().mean(), 1),
    "Active Channels":          tp["channel"].nunique(),
    "Reallocation Opportunity": f"{realloc_pct}% (${realloc_usd:,.0f})"
}

# ── SAVE ALL OUTPUTS ────────────────────────────────────────────────────────────
OUT = "/home/claude/marketing_attribution/data"

attr.reset_index().to_csv(f"{OUT}/attribution_comparison.csv", index=False)
roi.reset_index().to_csv(f"{OUT}/roi_analysis.csv", index=False)
monthly_full.to_csv(f"{OUT}/monthly_trend.csv", index=False)
path_counts.to_csv(f"{OUT}/channel_paths.csv", index=False)
by_region.to_csv(f"{OUT}/by_region.csv", index=False)
by_device.to_csv(f"{OUT}/by_device.csv", index=False)
pd.DataFrame([kpis]).T.reset_index().rename(columns={"index":"kpi",0:"value"}).to_csv(
    f"{OUT}/kpis.csv", index=False)

print(f"\nAll outputs saved to {OUT}/")
