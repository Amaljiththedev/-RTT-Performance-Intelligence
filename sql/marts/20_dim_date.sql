-- Month spine for the RTT marts.
--
-- Built as a generated spine rather than SELECT DISTINCT off the fact, so a month
-- with no submissions still exists as a row. A gap that shows as zero is a finding;
-- a gap that shows as a missing row is an invisible bug in every trend line.
--
-- Grain: one row per calendar month covering the data range plus headroom.
-- RTT is a monthly publication, so there is no need for a day-level spine.

DROP TABLE IF EXISTS marts.dim_date CASCADE;

CREATE TABLE marts.dim_date AS
WITH bounds AS (
    SELECT
        date_trunc('month', MIN(period))::date AS first_period,
        -- 12 months of headroom so forward-looking calculations have somewhere to land
        (date_trunc('month', MAX(period)) + interval '12 months')::date AS last_period
    FROM staging.stg_rtt_totals
),
spine AS (
    SELECT generate_series(first_period, last_period, interval '1 month')::date AS period
    FROM bounds
)
SELECT
    -- Integer surrogate in YYYYMM form: readable in a query, compact in the fact,
    -- and naturally sortable without a join.
    (EXTRACT(YEAR FROM period) * 100 + EXTRACT(MONTH FROM period))::int AS date_sk,
    period,
    (period + interval '1 month - 1 day')::date          AS period_end,
    EXTRACT(YEAR  FROM period)::int                      AS calendar_year,
    EXTRACT(MONTH FROM period)::int                      AS calendar_month,
    TO_CHAR(period, 'Mon')                               AS month_short,
    TO_CHAR(period, 'Month')                             AS month_name,
    TO_CHAR(period, 'Mon YYYY')                          AS month_label,
    EXTRACT(QUARTER FROM period)::int                    AS calendar_quarter,

    -- NHS financial year runs April to March. Reported as "2025/26", which is how
    -- every trust and ICB refers to it, so the report should not invent its own form.
    CASE WHEN EXTRACT(MONTH FROM period) >= 4
         THEN EXTRACT(YEAR FROM period)::int
         ELSE EXTRACT(YEAR FROM period)::int - 1
    END                                                  AS financial_year_start,
    CASE WHEN EXTRACT(MONTH FROM period) >= 4
         THEN EXTRACT(YEAR FROM period)::int || '/' ||
              RIGHT((EXTRACT(YEAR FROM period)::int + 1)::text, 2)
         ELSE (EXTRACT(YEAR FROM period)::int - 1) || '/' ||
              RIGHT(EXTRACT(YEAR FROM period)::text, 2)
    END                                                  AS financial_year,
    CASE WHEN EXTRACT(MONTH FROM period) >= 4
         THEN EXTRACT(MONTH FROM period)::int - 3
         ELSE EXTRACT(MONTH FROM period)::int + 9
    END                                                  AS financial_month_no,

    -- Marks months that actually carry submissions, so a report can distinguish
    -- "no data yet" from "zero pathways".
    EXISTS (
        SELECT 1 FROM staging.stg_rtt_totals t WHERE t.period = spine.period
    )                                                    AS has_data
FROM spine;

ALTER TABLE marts.dim_date ADD PRIMARY KEY (date_sk);
CREATE UNIQUE INDEX dim_date_period_uq ON marts.dim_date (period);
