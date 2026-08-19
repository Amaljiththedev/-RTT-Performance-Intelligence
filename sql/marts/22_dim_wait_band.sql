-- Wait band dimension: one row per published weekly banding.
--
-- Generated from the banding itself rather than SELECT DISTINCT off the fact, so a
-- band nobody is currently waiting in still exists. An empty band should render as
-- a gap in a distribution chart, not vanish and silently shift every bar along.
--
-- 104 bounded weekly bands (0-1, 1-2, ... 103-104) plus one open-ended 104+ band.
-- The open band has no upper bound, which is why a true mean or median wait cannot
-- be computed from this source at all: a patient at 104 weeks and one at 300 weeks
-- are the same row. That limitation is a property of the data, so it is recorded
-- here rather than left for someone to rediscover.

DROP TABLE IF EXISTS marts.dim_wait_band CASCADE;

CREATE TABLE marts.dim_wait_band AS
WITH bands AS (
    SELECT
        w                          AS wait_band_lower,
        CASE WHEN w < 104 THEN w + 1 END AS wait_band_upper
    FROM generate_series(0, 104) AS w
)
SELECT
    wait_band_lower                                  AS wait_band_sk,
    wait_band_lower,
    wait_band_upper,
    (wait_band_upper IS NULL)                        AS is_open_ended,

    CASE WHEN wait_band_upper IS NULL
         THEN 'Over 104 weeks'
         ELSE wait_band_lower || '-' || wait_band_upper || ' weeks'
    END                                              AS wait_band_label,

    -- Sort order is the lower bound, so a chart axis orders correctly without
    -- relying on the alphabetical sort of the label ("10-11" before "2-3").
    wait_band_lower                                  AS sort_order,

    -- The two statutory thresholds. A pathway in the 18-19 band has passed 18 weeks.
    (wait_band_lower >= 18)                          AS breaches_18_weeks,
    (wait_band_lower >= 52)                          AS breaches_52_weeks,
    (wait_band_lower >= 65)                          AS breaches_65_weeks,
    (wait_band_lower >= 78)                          AS breaches_78_weeks,

    -- The cohort the four-week breach-risk indicator watches: already past 48 weeks
    -- and therefore within four weeks of a 52-week breach unless treated.
    (wait_band_lower >= 48 AND wait_band_lower < 52) AS is_breach_risk_cohort,

    -- Coarse grouping for reporting. Nobody wants 105 categories on an axis.
    CASE
        WHEN wait_band_lower < 18  THEN 'Within 18 weeks'
        WHEN wait_band_lower < 40  THEN '18-40 weeks'
        WHEN wait_band_lower < 52  THEN '40-52 weeks'
        WHEN wait_band_lower < 65  THEN '52-65 weeks'
        WHEN wait_band_lower < 78  THEN '65-78 weeks'
        ELSE '78+ weeks'
    END                                              AS wait_band_group,

    CASE
        WHEN wait_band_lower < 18 THEN 1
        WHEN wait_band_lower < 40 THEN 2
        WHEN wait_band_lower < 52 THEN 3
        WHEN wait_band_lower < 65 THEN 4
        WHEN wait_band_lower < 78 THEN 5
        ELSE 6
    END                                              AS wait_band_group_sort
FROM bands;

ALTER TABLE marts.dim_wait_band ADD PRIMARY KEY (wait_band_sk);
CREATE INDEX dim_wait_band_group_ix ON marts.dim_wait_band (wait_band_group_sort);
