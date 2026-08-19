-- Staging: row-level totals per provider, specialty, month and pathway type.
--
-- Companion to stg_rtt_pathways. That table holds the wait-band detail; this one
-- holds the publisher's own totals, and exists for three reasons.
--
-- 1. Part_3 (New RTT Periods) carries NO wait-band data at all -- every band column
--    is empty and only total_all is populated. The band unpivot therefore drops it
--    entirely, which would silently remove referral demand from the model. Demand is
--    one of the three drivers in the decomposition, so it has to come from here.
--
-- 2. The `total` and `total_all` columns do not mean the same thing across pathway
--    types. Only Part_1A and Part_1B populate `total`; Part_2, Part_2A and Part_3
--    leave it blank and use `total_all`. A reconciliation test that assumes one
--    column works everywhere produces false failures, so both are kept, typed and
--    named for what they actually are.
--
-- 3. Patients with an unknown clock start are excluded from the banded counts but
--    are real people on a real list. Dropping them understates the waiting list;
--    silently folding them into a band would be worse.
--
-- Commissioner is summed away here for the same reason as in stg_rtt_pathways.

DROP TABLE IF EXISTS staging.stg_rtt_totals;

CREATE TABLE staging.stg_rtt_totals AS
WITH typed AS (
    SELECT
        period,
        provider_org_code,
        provider_org_name,
        provider_parent_org_code,
        provider_parent_name,
        treatment_function_code,
        treatment_function_name,
        rtt_part_type,
        rtt_part_description,
        -- Guarded casts: a value that is not an integer becomes NULL rather than
        -- failing the load, and is counted below so it cannot pass unnoticed.
        CASE WHEN total ~ '^-?[0-9]+$' THEN total::bigint END AS banded_total,
        CASE WHEN total_all ~ '^-?[0-9]+$' THEN total_all::bigint END AS reported_total,
        CASE WHEN patients_with_unknown_clock_start_date ~ '^-?[0-9]+$'
             THEN patients_with_unknown_clock_start_date::bigint END AS unknown_clock_start,
        (NULLIF(TRIM(total), '') IS NOT NULL AND total !~ '^-?[0-9]+$')
            OR (NULLIF(TRIM(total_all), '') IS NOT NULL AND total_all !~ '^-?[0-9]+$')
            AS is_non_numeric
    FROM raw.rtt_full_extract
)
SELECT
    period,
    provider_org_code,
    MIN(provider_org_name)       AS provider_org_name,
    provider_parent_org_code,
    MIN(provider_parent_name)    AS provider_parent_name,
    treatment_function_code,
    MIN(treatment_function_name) AS treatment_function_name,
    rtt_part_type,
    MIN(rtt_part_description)    AS rtt_part_description,

    -- Part_2A is a SUBSET of Part_2, not a sibling. Summing every pathway type
    -- double-counts roughly half the incomplete list.
    (rtt_part_type = 'Part_2A')  AS is_subset_of_total,

    -- C_999 "Total" is a pre-aggregated row across every specialty, not a specialty
    -- of its own. Summing all treatment function codes therefore counts the entire
    -- waiting list exactly twice: 14,368,466 becomes 7,184,233 once it is excluded,
    -- and 7.18m is the figure NHS England publishes. Note that X02-X06 ("Other -
    -- Medical Services" and similar) ARE genuine categories, so this cannot be done
    -- by pattern-matching odd-looking codes.
    (treatment_function_code = 'C_999') AS is_specialty_total,

    -- Part_3 is a flow measure (new clock starts in the month), not a stock. It must
    -- never be added to the waiting-list count; it is the demand side of it.
    (rtt_part_type = 'Part_3')   AS is_demand_measure,

    SUM(banded_total)            AS banded_total,
    SUM(reported_total)          AS reported_total,
    SUM(unknown_clock_start)     AS unknown_clock_start,
    COUNT(*)                     AS source_rows,
    COUNT(*) FILTER (WHERE is_non_numeric) AS non_numeric_source_values
FROM typed
GROUP BY
    period, provider_org_code, provider_parent_org_code,
    treatment_function_code, rtt_part_type;

CREATE INDEX stg_rtt_totals_period_ix
    ON staging.stg_rtt_totals (period, provider_org_code, treatment_function_code);

CREATE INDEX stg_rtt_totals_part_ix
    ON staging.stg_rtt_totals (rtt_part_type);
