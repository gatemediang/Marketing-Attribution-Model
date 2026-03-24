/* ============================================================================
   MARKETING ATTRIBUTION CAPSTONE — MASTER SQL SCRIPT
   Analyst  : Senior Data Analyst Portfolio Project
   Engine   : BigQuery SQL (ANSI-compatible; notes for SQL Server variants)
   Dataset  : marketing_attribution
   Tables   : touchpoints, customers, channel_spend
   ============================================================================ */


/* ============================================================================
   SECTION 0 — TABLE DEFINITIONS (BigQuery DDL)
   In SQL Server: replace FLOAT64→FLOAT, STRING→VARCHAR(255), BOOL→BIT
   ============================================================================ */

CREATE TABLE IF NOT EXISTS marketing_attribution.touchpoints (
    touchpoint_id       INT64,
    customer_id         STRING,
    channel             STRING,
    touchpoint_date     DATE,
    touchpoint_time     STRING,
    is_first_touch      BOOL,
    is_last_touch       BOOL,
    journey_position    INT64,
    journey_length      INT64,
    session_duration_sec INT64,
    page_views          INT64,
    cost_usd            FLOAT64,
    converted           BOOL,
    revenue_usd         FLOAT64,
    region              STRING,
    device              STRING,
    industry            STRING,
    product             STRING
);

CREATE TABLE IF NOT EXISTS marketing_attribution.customers (
    customer_id  STRING,
    region       STRING,
    device       STRING,
    industry     STRING,
    converted    BOOL,
    product      STRING,
    revenue      FLOAT64,
    acq_date     DATE
);

CREATE TABLE IF NOT EXISTS marketing_attribution.channel_spend (
    month      STRING,
    channel    STRING,
    spend_usd  FLOAT64
);


/* ============================================================================
   SECTION 1 — DATA QUALITY & PROFILING
   ============================================================================ */

-- 1.1  Row counts and basic health check
SELECT
    'touchpoints'   AS table_name,
    COUNT(*)        AS total_rows,
    COUNT(DISTINCT customer_id) AS unique_customers,
    SUM(CASE WHEN converted THEN 1 ELSE 0 END) AS total_conversions,
    ROUND(SUM(revenue_usd), 2)  AS total_revenue,
    ROUND(SUM(cost_usd), 2)     AS total_cost
FROM marketing_attribution.touchpoints

UNION ALL

SELECT
    'customers',
    COUNT(*),
    COUNT(DISTINCT customer_id),
    SUM(CASE WHEN converted THEN 1 ELSE 0 END),
    ROUND(SUM(revenue), 2),
    NULL
FROM marketing_attribution.customers;


-- 1.2  Channel coverage — touchpoints per channel with conversion rate
SELECT
    channel,
    COUNT(*)                                                    AS total_touchpoints,
    SUM(CASE WHEN converted THEN 1 ELSE 0 END)                 AS conversions,
    ROUND(100.0 * SUM(CASE WHEN converted THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                        AS conversion_rate_pct,
    ROUND(SUM(cost_usd), 2)                                    AS total_cost,
    ROUND(SUM(revenue_usd), 2)                                 AS attributed_revenue
FROM marketing_attribution.touchpoints
GROUP BY channel
ORDER BY total_touchpoints DESC;


-- 1.3  Journey length distribution
SELECT
    journey_length,
    COUNT(DISTINCT customer_id) AS customers,
    ROUND(100.0 * COUNT(DISTINCT customer_id) /
          SUM(COUNT(DISTINCT customer_id)) OVER (), 2) AS pct_of_customers
FROM marketing_attribution.touchpoints
GROUP BY journey_length
ORDER BY journey_length;


/* ============================================================================
   SECTION 2 — ATTRIBUTION MODEL 1: FIRST-TOUCH ATTRIBUTION
   Credit 100% of conversion to the first channel a customer interacted with
   ============================================================================ */

WITH first_touch AS (
    SELECT
        customer_id,
        channel             AS first_channel,
        revenue_usd,
        touchpoint_date     AS first_touch_date
    FROM marketing_attribution.touchpoints
    WHERE is_first_touch = TRUE
      AND converted = TRUE          -- only converters
)
SELECT
    first_channel                           AS channel,
    COUNT(*)                                AS conversions,
    ROUND(SUM(revenue_usd), 2)             AS attributed_revenue,
    ROUND(AVG(revenue_usd), 2)             AS avg_order_value,
    ROUND(100.0 * COUNT(*) /
          SUM(COUNT(*)) OVER (), 2)        AS revenue_share_pct
FROM first_touch
GROUP BY first_channel
ORDER BY attributed_revenue DESC;


/* ============================================================================
   SECTION 3 — ATTRIBUTION MODEL 2: LAST-TOUCH ATTRIBUTION
   Credit 100% to the final channel before conversion (default GA model)
   ============================================================================ */

WITH last_touch AS (
    SELECT
        customer_id,
        channel         AS last_channel,
        revenue_usd
    FROM marketing_attribution.touchpoints
    WHERE is_last_touch = TRUE
      AND converted = TRUE
)
SELECT
    last_channel                            AS channel,
    COUNT(*)                                AS conversions,
    ROUND(SUM(revenue_usd), 2)             AS attributed_revenue,
    ROUND(100.0 * COUNT(*) /
          SUM(COUNT(*)) OVER (), 2)        AS revenue_share_pct
FROM last_touch
GROUP BY last_channel
ORDER BY attributed_revenue DESC;


/* ============================================================================
   SECTION 4 — ATTRIBUTION MODEL 3: LINEAR ATTRIBUTION
   Divide conversion credit equally across all touchpoints in the journey
   ============================================================================ */

WITH converter_journeys AS (
    SELECT
        t.customer_id,
        t.channel,
        t.journey_length,
        c.revenue                           AS total_revenue
    FROM marketing_attribution.touchpoints t
    INNER JOIN marketing_attribution.customers c
        ON t.customer_id = c.customer_id
    WHERE c.converted = TRUE
),
linear_credit AS (
    SELECT
        customer_id,
        channel,
        ROUND(total_revenue / journey_length, 4) AS credited_revenue
    FROM converter_journeys
)
SELECT
    channel,
    COUNT(DISTINCT customer_id)             AS unique_customers,
    ROUND(SUM(credited_revenue), 2)        AS attributed_revenue,
    ROUND(100.0 * SUM(credited_revenue) /
          SUM(SUM(credited_revenue)) OVER (), 2) AS revenue_share_pct
FROM linear_credit
GROUP BY channel
ORDER BY attributed_revenue DESC;


/* ============================================================================
   SECTION 5 — ATTRIBUTION MODEL 4: TIME-DECAY ATTRIBUTION
   Touchpoints closer to conversion receive exponentially more credit
   Half-life = 7 days (configurable)
   ============================================================================ */

WITH converter_journeys AS (
    SELECT
        t.customer_id,
        t.channel,
        t.touchpoint_date,
        t.journey_position,
        t.journey_length,
        c.revenue           AS total_revenue,
        c.acq_date
    FROM marketing_attribution.touchpoints t
    INNER JOIN marketing_attribution.customers c
        ON t.customer_id = c.customer_id
    WHERE c.converted = TRUE
),
decay_calc AS (
    SELECT
        customer_id,
        channel,
        total_revenue,
        -- Days from touchpoint to conversion
        DATE_DIFF(acq_date, touchpoint_date, DAY) AS days_to_conversion,
        -- Exponential decay weight: 2^(-days/7) → half-life of 7 days
        POW(2, -1.0 * DATE_DIFF(acq_date, touchpoint_date, DAY) / 7.0) AS decay_weight
    FROM converter_journeys
),
normalised AS (
    SELECT
        customer_id,
        channel,
        total_revenue,
        decay_weight,
        SUM(decay_weight) OVER (PARTITION BY customer_id) AS total_decay_weight
    FROM decay_calc
),
time_decay_credit AS (
    SELECT
        customer_id,
        channel,
        ROUND(total_revenue * decay_weight / total_decay_weight, 4) AS credited_revenue
    FROM normalised
)
SELECT
    channel,
    COUNT(DISTINCT customer_id)                         AS unique_customers,
    ROUND(SUM(credited_revenue), 2)                    AS attributed_revenue,
    ROUND(100.0 * SUM(credited_revenue) /
          SUM(SUM(credited_revenue)) OVER (), 2)       AS revenue_share_pct
FROM time_decay_credit
GROUP BY channel
ORDER BY attributed_revenue DESC;


/* ============================================================================
   SECTION 6 — ATTRIBUTION MODEL 5: U-SHAPED (POSITION-BASED) ATTRIBUTION
   First touch: 40%  |  Last touch: 40%  |  Middle touches share: 20%
   ============================================================================ */

WITH converter_journeys AS (
    SELECT
        t.customer_id,
        t.channel,
        t.journey_position,
        t.journey_length,
        t.is_first_touch,
        t.is_last_touch,
        c.revenue AS total_revenue
    FROM marketing_attribution.touchpoints t
    INNER JOIN marketing_attribution.customers c
        ON t.customer_id = c.customer_id
    WHERE c.converted = TRUE
),
position_credit AS (
    SELECT
        customer_id,
        channel,
        total_revenue,
        journey_length,
        -- Middle touches: share the 20% equally among (journey_length - 2) positions
        CASE
            WHEN journey_length = 1
                THEN total_revenue                          -- solo touch gets 100%
            WHEN is_first_touch AND NOT is_last_touch
                THEN total_revenue * 0.40
            WHEN is_last_touch AND NOT is_first_touch
                THEN total_revenue * 0.40
            WHEN is_first_touch AND is_last_touch
                THEN total_revenue                          -- same channel first+last
            ELSE
                total_revenue * 0.20
                / NULLIF(journey_length - 2, 0)            -- split middle 20%
        END AS credited_revenue
    FROM converter_journeys
)
SELECT
    channel,
    COUNT(DISTINCT customer_id)                         AS unique_customers,
    ROUND(SUM(credited_revenue), 2)                    AS attributed_revenue,
    ROUND(100.0 * SUM(credited_revenue) /
          SUM(SUM(credited_revenue)) OVER (), 2)       AS revenue_share_pct
FROM position_credit
GROUP BY channel
ORDER BY attributed_revenue DESC;


/* ============================================================================
   SECTION 7 — ATTRIBUTION MODEL COMPARISON TABLE
   Joins all 5 models side by side for executive dashboard
   ============================================================================ */

WITH

-- First touch
ft AS (
    SELECT channel, ROUND(SUM(revenue_usd), 2) AS ft_revenue
    FROM marketing_attribution.touchpoints
    WHERE is_first_touch = TRUE AND converted = TRUE
    GROUP BY channel
),

-- Last touch
lt AS (
    SELECT channel, ROUND(SUM(revenue_usd), 2) AS lt_revenue
    FROM marketing_attribution.touchpoints
    WHERE is_last_touch = TRUE AND converted = TRUE
    GROUP BY channel
),

-- Linear (simplified inline)
lin AS (
    SELECT
        t.channel,
        ROUND(SUM(c.revenue / t.journey_length), 2) AS lin_revenue
    FROM marketing_attribution.touchpoints t
    JOIN marketing_attribution.customers c USING (customer_id)
    WHERE c.converted = TRUE
    GROUP BY t.channel
),

-- Time decay inline
td AS (
    SELECT
        t.channel,
        ROUND(SUM(
            c.revenue *
            POW(2, -1.0 * DATE_DIFF(c.acq_date, t.touchpoint_date, DAY) / 7.0) /
            SUM(POW(2, -1.0 * DATE_DIFF(c.acq_date, t.touchpoint_date, DAY) / 7.0))
                OVER (PARTITION BY t.customer_id)
        ), 2) AS td_revenue
    FROM marketing_attribution.touchpoints t
    JOIN marketing_attribution.customers c USING (customer_id)
    WHERE c.converted = TRUE
    GROUP BY t.channel
),

channel_list AS (
    SELECT DISTINCT channel FROM marketing_attribution.touchpoints
)

SELECT
    cl.channel,
    COALESCE(ft.ft_revenue,  0) AS first_touch_revenue,
    COALESCE(lt.lt_revenue,  0) AS last_touch_revenue,
    COALESCE(lin.lin_revenue, 0) AS linear_revenue,
    COALESCE(td.td_revenue,  0) AS time_decay_revenue,
    -- % variance between last-touch and time-decay (reveals reallocation need)
    ROUND(100.0 * (COALESCE(td.td_revenue, 0) - COALESCE(lt.lt_revenue, 0))
          / NULLIF(COALESCE(lt.lt_revenue, 0), 0), 1) AS lt_vs_td_variance_pct
FROM channel_list cl
LEFT JOIN ft  ON cl.channel = ft.channel
LEFT JOIN lt  ON cl.channel = lt.channel
LEFT JOIN lin ON cl.channel = lin.channel
LEFT JOIN td  ON cl.channel = td.channel
ORDER BY COALESCE(td.td_revenue, 0) DESC;


/* ============================================================================
   SECTION 8 — ROI & BUDGET EFFICIENCY ANALYSIS
   Spend vs revenue by channel — reveals the 40% reallocation opportunity
   ============================================================================ */

WITH channel_spend_total AS (
    SELECT
        channel,
        ROUND(SUM(spend_usd), 2) AS total_spend_18mo
    FROM marketing_attribution.channel_spend
    GROUP BY channel
),
td_revenue AS (
    SELECT
        t.channel,
        ROUND(SUM(
            c.revenue *
            POW(2, -1.0 * DATE_DIFF(c.acq_date, t.touchpoint_date, DAY) / 7.0) /
            SUM(POW(2, -1.0 * DATE_DIFF(c.acq_date, t.touchpoint_date, DAY) / 7.0))
                OVER (PARTITION BY t.customer_id)
        ), 2) AS td_attributed_revenue
    FROM marketing_attribution.touchpoints t
    JOIN marketing_attribution.customers c USING (customer_id)
    WHERE c.converted = TRUE
    GROUP BY t.channel
)
SELECT
    s.channel,
    s.total_spend_18mo,
    COALESCE(r.td_attributed_revenue, 0)                AS td_attributed_revenue,
    -- Marketing ROI = (Revenue - Spend) / Spend
    ROUND((COALESCE(r.td_attributed_revenue, 0) - s.total_spend_18mo)
          / NULLIF(s.total_spend_18mo, 0), 2)          AS marketing_roi,
    -- Revenue per $ spent
    ROUND(COALESCE(r.td_attributed_revenue, 0)
          / NULLIF(s.total_spend_18mo, 0), 2)          AS revenue_per_dollar_spent,
    -- Budget share
    ROUND(100.0 * s.total_spend_18mo /
          SUM(s.total_spend_18mo) OVER (), 1)          AS current_budget_share_pct,
    -- Optimal share based on time-decay attribution
    ROUND(100.0 * COALESCE(r.td_attributed_revenue, 0) /
          SUM(COALESCE(r.td_attributed_revenue, 0)) OVER (), 1) AS optimal_budget_share_pct,
    -- Delta = the reallocation signal
    ROUND(
        100.0 * COALESCE(r.td_attributed_revenue, 0) /
            SUM(COALESCE(r.td_attributed_revenue, 0)) OVER ()
        -
        100.0 * s.total_spend_18mo /
            SUM(s.total_spend_18mo) OVER ()
    , 1)                                               AS budget_delta_pp   -- pp = percentage points
FROM channel_spend_total s
LEFT JOIN td_revenue r ON s.channel = r.channel
ORDER BY marketing_roi DESC;


/* ============================================================================
   SECTION 9 — CHANNEL PATH ANALYSIS
   Most common 2-channel and 3-channel sequences leading to conversion
   ============================================================================ */

-- 9.1  Two-channel conversion paths
WITH ordered_touches AS (
    SELECT
        customer_id,
        channel,
        journey_position,
        journey_length
    FROM marketing_attribution.touchpoints
    WHERE customer_id IN (
        SELECT customer_id FROM marketing_attribution.customers WHERE converted = TRUE
    )
),
pairs AS (
    SELECT
        a.customer_id,
        a.channel AS channel_1,
        b.channel AS channel_2,
        a.journey_length
    FROM ordered_touches a
    JOIN ordered_touches b
        ON  a.customer_id    = b.customer_id
        AND b.journey_position = a.journey_position + 1
)
SELECT
    CONCAT(channel_1, ' → ', channel_2) AS channel_path,
    COUNT(DISTINCT customer_id)          AS conversions,
    ROUND(100.0 * COUNT(DISTINCT customer_id) /
          SUM(COUNT(DISTINCT customer_id)) OVER (), 2) AS pct_of_conversions
FROM pairs
GROUP BY channel_1, channel_2
ORDER BY conversions DESC
LIMIT 20;


-- 9.2  Three-channel conversion paths
WITH ordered_touches AS (
    SELECT customer_id, channel, journey_position
    FROM marketing_attribution.touchpoints
    WHERE customer_id IN (
        SELECT customer_id FROM marketing_attribution.customers WHERE converted = TRUE
    )
),
triples AS (
    SELECT
        a.customer_id,
        a.channel AS ch1,
        b.channel AS ch2,
        c.channel AS ch3
    FROM ordered_touches a
    JOIN ordered_touches b
        ON a.customer_id = b.customer_id AND b.journey_position = a.journey_position + 1
    JOIN ordered_touches c
        ON a.customer_id = c.customer_id AND c.journey_position = a.journey_position + 2
)
SELECT
    CONCAT(ch1, ' → ', ch2, ' → ', ch3) AS path,
    COUNT(DISTINCT customer_id)           AS conversions
FROM triples
GROUP BY ch1, ch2, ch3
ORDER BY conversions DESC
LIMIT 20;


/* ============================================================================
   SECTION 10 — TIME-SERIES MONTHLY PERFORMANCE
   For Power BI line chart: monthly revenue, spend, and ROAS trend
   ============================================================================ */

WITH monthly_revenue AS (
    SELECT
        FORMAT_DATE('%Y-%m', touchpoint_date) AS month,
        channel,
        ROUND(SUM(revenue_usd), 2)            AS revenue
    FROM marketing_attribution.touchpoints
    WHERE converted = TRUE
    GROUP BY month, channel
),
monthly_spend AS (
    SELECT month, channel, ROUND(SUM(spend_usd), 2) AS spend
    FROM marketing_attribution.channel_spend
    GROUP BY month, channel
)
SELECT
    r.month,
    r.channel,
    COALESCE(r.revenue, 0)                                      AS revenue,
    COALESCE(s.spend, 0)                                        AS spend,
    ROUND(COALESCE(r.revenue, 0) / NULLIF(COALESCE(s.spend, 0), 0), 2) AS roas
FROM monthly_revenue r
LEFT JOIN monthly_spend s
    ON r.month = s.month AND r.channel = s.channel
ORDER BY r.month, r.channel;


/* ============================================================================
   SECTION 11 — SEGMENT ANALYSIS
   Attribution by region, device, industry — for audience targeting insights
   ============================================================================ */

-- 11.1  By region
SELECT
    region,
    channel,
    COUNT(DISTINCT customer_id)                     AS converters,
    ROUND(SUM(revenue_usd), 2)                     AS revenue,
    ROUND(AVG(journey_length), 1)                  AS avg_journey_length
FROM marketing_attribution.touchpoints
WHERE converted = TRUE
GROUP BY region, channel
ORDER BY region, revenue DESC;


-- 11.2  By device
SELECT
    device,
    channel,
    COUNT(DISTINCT customer_id)                     AS converters,
    ROUND(SUM(revenue_usd), 2)                     AS revenue
FROM marketing_attribution.touchpoints
WHERE converted = TRUE
GROUP BY device, channel
ORDER BY device, revenue DESC;


-- 11.3  Average session quality by channel
SELECT
    channel,
    ROUND(AVG(session_duration_sec), 0)            AS avg_session_sec,
    ROUND(AVG(page_views), 1)                      AS avg_page_views,
    ROUND(AVG(journey_length), 1)                  AS avg_journey_length,
    SUM(CASE WHEN converted THEN 1 ELSE 0 END)     AS conversions,
    COUNT(*)                                        AS total_touchpoints
FROM marketing_attribution.touchpoints
GROUP BY channel
ORDER BY avg_session_sec DESC;


/* ============================================================================
   SECTION 12 — EXECUTIVE KPI SUMMARY VIEW
   Single-row KPIs suitable for Power BI card visuals
   ============================================================================ */

SELECT
    COUNT(DISTINCT customer_id)                         AS total_customers,
    SUM(CASE WHEN converted THEN 1 ELSE 0 END)
        AS total_conversions,
    ROUND(100.0 * SUM(CASE WHEN converted THEN 1 ELSE 0 END)
          / COUNT(DISTINCT customer_id), 1)             AS overall_conversion_rate_pct,
    ROUND(SUM(revenue_usd), 0)                         AS total_revenue,
    ROUND(SUM(cost_usd), 0)                            AS total_cost,
    ROUND(SUM(revenue_usd) / NULLIF(SUM(cost_usd),0), 2) AS blended_roas,
    ROUND(SUM(cost_usd) / NULLIF(
        SUM(CASE WHEN converted THEN 1 ELSE 0 END), 0
    ), 2)                                               AS cost_per_acquisition,
    ROUND(AVG(journey_length), 1)                      AS avg_journey_length,
    COUNT(DISTINCT channel)                             AS active_channels
FROM marketing_attribution.touchpoints
JOIN marketing_attribution.customers USING (customer_id);


/* ============================================================================
   SQL SERVER ADAPTATION NOTES
   ──────────────────────────────────────────────────────────────────────────
   Replace BigQuery-specific syntax as follows:

   | BigQuery                        | SQL Server                            |
   |─────────────────────────────────|───────────────────────────────────────|
   | DATE_DIFF(d1, d2, DAY)          | DATEDIFF(DAY, d2, d1)                 |
   | FORMAT_DATE('%Y-%m', col)       | FORMAT(col, 'yyyy-MM')                |
   | POW(base, exp)                  | POWER(base, exp)                      |
   | CONCAT(a,' → ',b)              | a + ' → ' + b   (or CONCAT())        |
   | BOOL                            | BIT                                   |
   | INT64                           | BIGINT                                |
   | FLOAT64                         | FLOAT                                 |
   | STRING                          | VARCHAR(255)                          |
   | TRUE / FALSE                    | 1 / 0                                 |
   | USING (customer_id)             | ON t.customer_id = c.customer_id      |
   ============================================================================ */
