# POWER BI IMPLEMENTATION GUIDE
# Marketing Attribution Capstone — Dashboard Specification
# ============================================================

# ── DATA MODEL ─────────────────────────────────────────────────────────────────

# Import these CSV files into Power BI Desktop:
#   1. touchpoints.csv       — Fact table (grain: one row per touchpoint)
#   2. customers.csv         — Customer dimension
#   3. channel_spend.csv     — Monthly spend by channel
#   4. attribution_comparison.csv — Pre-computed model outputs
#   5. roi_analysis.csv      — ROI and budget reallocation
#   6. monthly_trend.csv     — Time-series for trend charts

# RELATIONSHIPS:
#   touchpoints[customer_id]  → customers[customer_id]   (Many-to-One)
#   touchpoints[channel]      → channel_spend[channel]    (Many-to-Many — bridge by month)


# ── DAX MEASURES ───────────────────────────────────────────────────────────────

# Paste these into the DAX measure editor in Power BI

Total Revenue = SUM(touchpoints[revenue_usd])

Total Spend = SUM(channel_spend[spend_usd])

Total Conversions = COUNTROWS(FILTER(touchpoints, touchpoints[converted] = TRUE()))

Conversion Rate % = 
DIVIDE(
    COUNTROWS(FILTER(touchpoints, touchpoints[converted] = TRUE())),
    DISTINCTCOUNT(touchpoints[customer_id]),
    0
) * 100

Blended ROAS = 
DIVIDE([Total Revenue], [Total Spend], 0)

Cost Per Acquisition = 
DIVIDE([Total Spend], [Total Conversions], 0)

Avg Journey Length = 
AVERAGEX(
    VALUES(touchpoints[customer_id]),
    CALCULATE(MAX(touchpoints[journey_length]))
)

# Time-Decay Revenue (simplified — use pre-computed column from Python output)
TD Attributed Revenue = SUM(roi_analysis[time_decay_revenue])

# Budget Delta (reallocation signal)
Budget Delta pp = 
SUM(roi_analysis[budget_delta_pp])

# Reallocation Flag
Reallocation Flag = 
IF(
    SUM(roi_analysis[budget_delta_pp]) > 5, "⬆ INCREASE",
    IF(SUM(roi_analysis[budget_delta_pp]) < -5, "⬇ REDUCE", "→ HOLD")
)

# MoM Revenue Growth
MoM Revenue Growth % = 
VAR CurrentMonth = MAX(monthly_trend[month])
VAR PriorMonth = 
    CALCULATE(
        MAX(monthly_trend[month]),
        FILTER(ALL(monthly_trend), monthly_trend[month] < CurrentMonth)
    )
VAR CurrentRev = 
    CALCULATE([Total Revenue], monthly_trend[month] = CurrentMonth)
VAR PriorRev = 
    CALCULATE([Total Revenue], monthly_trend[month] = PriorMonth)
RETURN
    DIVIDE(CurrentRev - PriorRev, PriorRev, 0) * 100


# ── PAGE 1: EXECUTIVE OVERVIEW ─────────────────────────────────────────────────

# VISUALS:
# [Card]  Total Revenue          → [Total Revenue] measure
# [Card]  Total Spend            → [Total Spend] measure  
# [Card]  Blended ROAS           → [Blended ROAS] measure
# [Card]  Conversion Rate        → [Conversion Rate %] measure
# [Card]  Cost Per Acquisition   → [Cost Per Acquisition] measure
# [Card]  Reallocation Opp.      → Static text "44.1% / $3.6M" or calculated

# [Clustered Bar Chart]
#   Title: "Time-Decay vs Last-Touch Attribution Revenue"
#   Axis (Y): channel (from roi_analysis)
#   Values: time_decay_revenue, last_touch_revenue
#   Sort: time_decay_revenue descending
#   Colors: Navy (#0D1B4B) = Time-Decay | Light Blue (#A8CEFF) = Last-Touch

# [Donut Chart]
#   Title: "Current Budget Distribution"
#   Values: total_spend (from roi_analysis)
#   Legend: channel
#   Colors: Use navy-to-blue gradient per channel

# [Table/Matrix]
#   Title: "Budget Reallocation Signals"
#   Rows: channel
#   Columns: current_budget_share, optimal_budget_share, budget_delta_pp, marketing_roi
#   Conditional formatting on budget_delta_pp:
#     > +5  → Green background
#     < -5  → Red background
#     else  → Amber background

# SLICER: Date range (touchpoint_date)
# SLICER: Region (multi-select)
# SLICER: Device (multi-select)


# ── PAGE 2: ATTRIBUTION MODEL DEEP DIVE ───────────────────────────────────────

# [100% Stacked Bar Chart]
#   Title: "Revenue Share by Attribution Model"
#   Axis: channel
#   Values: first_touch_share_pct, last_touch_share_pct, linear_share_pct,
#           time_decay_share_pct, u_shaped_share_pct
#   Source table: attribution_comparison.csv

# [Line Chart]
#   Title: "Attribution Model Variance — How Models Disagree"
#   Axis (X): channel
#   Lines: first_touch_revenue, last_touch_revenue, linear_revenue,
#          time_decay_revenue, u_shaped_revenue
#   Marker: Yes | Smooth: Yes

# [Scatter Chart]
#   Title: "Spend vs Time-Decay Revenue by Channel"
#   X-Axis: total_spend
#   Y-Axis: time_decay_revenue
#   Values (bubble size): marketing_roi
#   Legend: channel
#   Reference line at X=Y (Diagonal) to show over/underfunded channels
#   Quadrant labels: 
#     Top-left   = "Hidden Gems (High Return, Low Spend)"
#     Bottom-right = "Budget Drains (Low Return, High Spend)"

# [Funnel Chart]
#   Title: "Journey Length Distribution"
#   Category: journey_length
#   Values: count of customers


# ── PAGE 3: TREND & SEGMENT ANALYSIS ──────────────────────────────────────────

# [Line Chart]
#   Title: "Monthly Revenue & Spend Trend (Jan 2024 – Jun 2025)"
#   Axis (X): month (from monthly_trend)
#   Lines: SUM(revenue), SUM(spend_usd)
#   Secondary Y-axis: roas
#   Reference line: Average ROAS

# [Clustered Column Chart]
#   Title: "Revenue by Channel and Region"
#   Axis (X): channel
#   Legend: region
#   Values: SUM(revenue_usd) from by_region.csv

# [Matrix]
#   Title: "Channel Performance by Device"
#   Rows: device
#   Columns: channel
#   Values: SUM(revenue_usd)
#   Conditional formatting: Data bars

# [Bar Chart — Horizontal]
#   Title: "Top 15 Conversion Paths"
#   Axis (Y): channel_path (from channel_paths.csv)
#   Values: conversions
#   Sort: Descending

# [Card Row — Page KPIs]
#   Avg Session Duration | Avg Page Views | Top Converting Region | Top Converting Device


# ── THEME & FORMATTING ─────────────────────────────────────────────────────────

# Apply this custom theme JSON in Power BI:
# View → Themes → Customize Current Theme

POWERBI_THEME = {
    "name": "Marketing Attribution Dark",
    "dataColors": [
        "#0D1B4B",  # Navy
        "#0066CC",  # Neon Blue
        "#A8CEFF",  # Light Blue
        "#1A7A4A",  # Green
        "#C0392B",  # Red
        "#D68910",  # Amber
        "#5B2C6F",  # Purple
        "#1F618D",  # Steel Blue
        "#148F77"   # Teal
    ],
    "background": "#FFFFFF",
    "foreground": "#0D1B4B",
    "tableAccent": "#0066CC",
    "visualStyles": {
        "*": {
            "*": {
                "fontFamily": [{"value": "Arial"}],
                "fontSize":   [{"value": 10}]
            }
        }
    }
}

# Page canvas: 1920 x 1080 (widescreen)
# Navigation: Bookmark-based page navigation buttons (top right)
# Header banner: Rectangle shape, fill Navy, white text title + subtitle


# ── DEPLOYMENT ─────────────────────────────────────────────────────────────────

# 1. Publish to Power BI Service (app.powerbi.com)
# 2. Schedule Data Refresh: Daily (if connected to BigQuery)
# 3. Create App workspace: "Marketing Analytics"
# 4. Share dashboard link for portfolio — use Publish to Web for public portfolio
# 5. Export PDF snapshot for CV/LinkedIn attachment
