-- Staging: unpivot the RTT full extract into one row per wait band.
--
-- Four things happen here, and each is a decision worth stating.
--
-- 1. UNPIVOT. The source holds 105 wait-band columns per row. They become rows so
--    the band can be a dimension rather than 105 near-identical measures.
--
-- 2. COMMISSIONER IS AGGREGATED AWAY. The source splits each provider-specialty by
--    commissioner. A pathway at 50 weeks breaches at 52 regardless of who commissioned
--    it, and the operations manager cannot act on that split, so it is summed out.
--    ICB analysis still works via provider_parent_org_code. The cost: this model
--    cannot answer "which commissioner's patients wait longest at this provider".
--
-- 3. ZERO BANDS ARE DROPPED. Most provider-specialty-band cells are empty. A missing
--    row means zero, which is lossless and keeps the table roughly an order of
--    magnitude smaller than a full cross product.
--
-- 4. Part_2A IS FLAGGED, NOT SUMMED. Incomplete pathways with a decision to admit are
--    a SUBSET of Part_2, not a sibling. Summing all pathway types double-counts them
--    and inflates the waiting list by roughly half. is_subset_of_total marks them so
--    every downstream total must make an explicit choice.

DROP TABLE IF EXISTS staging.stg_rtt_pathways;

CREATE TABLE staging.stg_rtt_pathways AS
WITH source AS (
    SELECT
        f.period,
        f.provider_org_code,
        f.provider_org_name,
        f.provider_parent_org_code,
        f.provider_parent_name,
        f.treatment_function_code,
        f.treatment_function_name,
        f.rtt_part_type,
        f.rtt_part_description,
        b.wait_band_lower,
        b.wait_band_upper,
        NULLIF(TRIM(b.raw_value), '') AS raw_value
    FROM raw.rtt_full_extract f
    CROSS JOIN LATERAL (
        VALUES
        (0, 1, f.gt_00_to_01_weeks),
        (1, 2, f.gt_01_to_02_weeks),
        (2, 3, f.gt_02_to_03_weeks),
        (3, 4, f.gt_03_to_04_weeks),
        (4, 5, f.gt_04_to_05_weeks),
        (5, 6, f.gt_05_to_06_weeks),
        (6, 7, f.gt_06_to_07_weeks),
        (7, 8, f.gt_07_to_08_weeks),
        (8, 9, f.gt_08_to_09_weeks),
        (9, 10, f.gt_09_to_10_weeks),
        (10, 11, f.gt_10_to_11_weeks),
        (11, 12, f.gt_11_to_12_weeks),
        (12, 13, f.gt_12_to_13_weeks),
        (13, 14, f.gt_13_to_14_weeks),
        (14, 15, f.gt_14_to_15_weeks),
        (15, 16, f.gt_15_to_16_weeks),
        (16, 17, f.gt_16_to_17_weeks),
        (17, 18, f.gt_17_to_18_weeks),
        (18, 19, f.gt_18_to_19_weeks),
        (19, 20, f.gt_19_to_20_weeks),
        (20, 21, f.gt_20_to_21_weeks),
        (21, 22, f.gt_21_to_22_weeks),
        (22, 23, f.gt_22_to_23_weeks),
        (23, 24, f.gt_23_to_24_weeks),
        (24, 25, f.gt_24_to_25_weeks),
        (25, 26, f.gt_25_to_26_weeks),
        (26, 27, f.gt_26_to_27_weeks),
        (27, 28, f.gt_27_to_28_weeks),
        (28, 29, f.gt_28_to_29_weeks),
        (29, 30, f.gt_29_to_30_weeks),
        (30, 31, f.gt_30_to_31_weeks),
        (31, 32, f.gt_31_to_32_weeks),
        (32, 33, f.gt_32_to_33_weeks),
        (33, 34, f.gt_33_to_34_weeks),
        (34, 35, f.gt_34_to_35_weeks),
        (35, 36, f.gt_35_to_36_weeks),
        (36, 37, f.gt_36_to_37_weeks),
        (37, 38, f.gt_37_to_38_weeks),
        (38, 39, f.gt_38_to_39_weeks),
        (39, 40, f.gt_39_to_40_weeks),
        (40, 41, f.gt_40_to_41_weeks),
        (41, 42, f.gt_41_to_42_weeks),
        (42, 43, f.gt_42_to_43_weeks),
        (43, 44, f.gt_43_to_44_weeks),
        (44, 45, f.gt_44_to_45_weeks),
        (45, 46, f.gt_45_to_46_weeks),
        (46, 47, f.gt_46_to_47_weeks),
        (47, 48, f.gt_47_to_48_weeks),
        (48, 49, f.gt_48_to_49_weeks),
        (49, 50, f.gt_49_to_50_weeks),
        (50, 51, f.gt_50_to_51_weeks),
        (51, 52, f.gt_51_to_52_weeks),
        (52, 53, f.gt_52_to_53_weeks),
        (53, 54, f.gt_53_to_54_weeks),
        (54, 55, f.gt_54_to_55_weeks),
        (55, 56, f.gt_55_to_56_weeks),
        (56, 57, f.gt_56_to_57_weeks),
        (57, 58, f.gt_57_to_58_weeks),
        (58, 59, f.gt_58_to_59_weeks),
        (59, 60, f.gt_59_to_60_weeks),
        (60, 61, f.gt_60_to_61_weeks),
        (61, 62, f.gt_61_to_62_weeks),
        (62, 63, f.gt_62_to_63_weeks),
        (63, 64, f.gt_63_to_64_weeks),
        (64, 65, f.gt_64_to_65_weeks),
        (65, 66, f.gt_65_to_66_weeks),
        (66, 67, f.gt_66_to_67_weeks),
        (67, 68, f.gt_67_to_68_weeks),
        (68, 69, f.gt_68_to_69_weeks),
        (69, 70, f.gt_69_to_70_weeks),
        (70, 71, f.gt_70_to_71_weeks),
        (71, 72, f.gt_71_to_72_weeks),
        (72, 73, f.gt_72_to_73_weeks),
        (73, 74, f.gt_73_to_74_weeks),
        (74, 75, f.gt_74_to_75_weeks),
        (75, 76, f.gt_75_to_76_weeks),
        (76, 77, f.gt_76_to_77_weeks),
        (77, 78, f.gt_77_to_78_weeks),
        (78, 79, f.gt_78_to_79_weeks),
        (79, 80, f.gt_79_to_80_weeks),
        (80, 81, f.gt_80_to_81_weeks),
        (81, 82, f.gt_81_to_82_weeks),
        (82, 83, f.gt_82_to_83_weeks),
        (83, 84, f.gt_83_to_84_weeks),
        (84, 85, f.gt_84_to_85_weeks),
        (85, 86, f.gt_85_to_86_weeks),
        (86, 87, f.gt_86_to_87_weeks),
        (87, 88, f.gt_87_to_88_weeks),
        (88, 89, f.gt_88_to_89_weeks),
        (89, 90, f.gt_89_to_90_weeks),
        (90, 91, f.gt_90_to_91_weeks),
        (91, 92, f.gt_91_to_92_weeks),
        (92, 93, f.gt_92_to_93_weeks),
        (93, 94, f.gt_93_to_94_weeks),
        (94, 95, f.gt_94_to_95_weeks),
        (95, 96, f.gt_95_to_96_weeks),
        (96, 97, f.gt_96_to_97_weeks),
        (97, 98, f.gt_97_to_98_weeks),
        (98, 99, f.gt_98_to_99_weeks),
        (99, 100, f.gt_99_to_100_weeks),
        (100, 101, f.gt_100_to_101_weeks),
        (101, 102, f.gt_101_to_102_weeks),
        (102, 103, f.gt_102_to_103_weeks),
        (103, 104, f.gt_103_to_104_weeks),
        (104, NULL, f.gt_104_weeks)
    ) AS b(wait_band_lower, wait_band_upper, raw_value)
),
typed AS (
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
        wait_band_lower,
        wait_band_upper,
        -- Guarded cast. Every value across all 24 months was numeric when checked,
        -- but a guard costs nothing and a silent failure later costs a great deal.
        CASE WHEN raw_value ~ '^-?[0-9]+$' THEN raw_value::bigint END AS pathway_count,
        (raw_value IS NOT NULL AND raw_value !~ '^-?[0-9]+$') AS is_non_numeric
    FROM source
    WHERE raw_value IS NOT NULL
)
SELECT
    period,
    provider_org_code,
    MIN(provider_org_name)          AS provider_org_name,
    provider_parent_org_code,
    MIN(provider_parent_name)       AS provider_parent_name,
    treatment_function_code,
    MIN(treatment_function_name)    AS treatment_function_name,
    rtt_part_type,
    MIN(rtt_part_description)       AS rtt_part_description,
    wait_band_lower,
    wait_band_upper,
    (wait_band_upper IS NULL)       AS is_open_ended_band,
    (wait_band_lower >= 18)         AS breaches_18_weeks,
    (wait_band_lower >= 52)         AS breaches_52_weeks,
    (rtt_part_type = 'Part_2A')     AS is_subset_of_total,

    -- C_999 "Total" is a pre-aggregated row across every specialty, not a specialty
    -- of its own. Including it counts the entire waiting list twice. X02-X06
    -- ("Other - Medical Services" and similar) ARE genuine categories, so this
    -- cannot be handled by pattern-matching odd-looking codes.
    (treatment_function_code = 'C_999') AS is_specialty_total,

    SUM(pathway_count)              AS pathway_count,
    COUNT(*) FILTER (WHERE is_non_numeric) AS non_numeric_source_values
FROM typed
GROUP BY
    period, provider_org_code, provider_parent_org_code,
    treatment_function_code, rtt_part_type,
    wait_band_lower, wait_band_upper
HAVING SUM(pathway_count) > 0;

CREATE INDEX stg_rtt_pathways_period_ix
    ON staging.stg_rtt_pathways (period, provider_org_code, treatment_function_code);

CREATE INDEX stg_rtt_pathways_band_ix
    ON staging.stg_rtt_pathways (wait_band_lower);
