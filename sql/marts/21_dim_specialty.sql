-- Specialty (treatment function) dimension.
--
-- Small and stable: 24 codes across two years. Type 1 -- names are corrected in
-- place rather than versioned, because a renamed specialty is the same specialty.
--
-- The important column here is is_specialty_total. C_999 "Total" is a
-- pre-aggregated row across every other code, not a specialty. Summing all codes
-- counts the entire waiting list twice (14,368,466 against a true 7,184,233 for
-- May 2026). Holding that fact in the dimension means every downstream query can
-- exclude it by a named flag rather than by remembering a magic string.
--
-- Note X02-X06 ("Other - Medical Services" and similar) ARE genuine categories.
-- The totals row cannot be identified by pattern-matching unusual-looking codes.

DROP TABLE IF EXISTS marts.dim_specialty CASCADE;

CREATE TABLE marts.dim_specialty AS
WITH observed AS (
    SELECT
        treatment_function_code,
        -- Names can drift between publications; take the most recent spelling.
        (ARRAY_AGG(treatment_function_name ORDER BY period DESC))[1] AS treatment_function_name,
        MIN(period) AS first_seen,
        MAX(period) AS last_seen
    FROM staging.stg_rtt_totals
    GROUP BY treatment_function_code
)
SELECT
    ROW_NUMBER() OVER (ORDER BY treatment_function_code)::int AS specialty_sk,
    treatment_function_code,
    treatment_function_name,

    -- Strip the trailing "Service" that NHSE appends to every name; it adds nothing
    -- to a chart axis and costs horizontal space in every visual.
    TRIM(REGEXP_REPLACE(treatment_function_name, '\s+Service$', '')) AS specialty_name,

    (treatment_function_code = 'C_999') AS is_specialty_total,
    (treatment_function_code LIKE 'X%') AS is_other_category,

    CASE
        WHEN treatment_function_code = 'C_999' THEN 'Total'
        WHEN treatment_function_code IN
             ('C_100','C_101','C_110','C_120','C_130','C_140','C_150','C_160',
              'C_170','C_502') THEN 'Surgical'
        WHEN treatment_function_code IN
             ('C_300','C_301','C_320','C_330','C_340','C_400','C_410','C_430')
             THEN 'Medical'
        ELSE 'Other'
    END AS specialty_group,

    first_seen,
    last_seen
FROM observed;

ALTER TABLE marts.dim_specialty ADD PRIMARY KEY (specialty_sk);
CREATE UNIQUE INDEX dim_specialty_code_uq
    ON marts.dim_specialty (treatment_function_code);
