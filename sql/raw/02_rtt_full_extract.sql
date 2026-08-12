-- Landing table for the NHS England RTT monthly full extract.
--
-- Every source column is text, without exception. The wait-band columns carry
-- '*' where a small number has been suppressed; typing them as integer would
-- either fail the load or coerce the marker to null, destroying the difference
-- between "withheld" and "zero". Casting happens in staging, where it is
-- visible and testable.
--
-- No primary key, no constraints, no indexes. Raw is append-only and
-- deliberately unvalidated -- constraints here would reject exactly the
-- malformed rows that most need to be seen. Validation belongs in staging.
--
-- Column names are snake-cased from the published header, with the redundant
-- "SUM 1" suffix dropped from the band columns. Generated from the real
-- May 2026 extract; the loader re-checks the header on every file and fails
-- loudly if the column set has drifted.

CREATE TABLE IF NOT EXISTS raw.rtt_full_extract (
    -- descriptive: 13 columns
    period_label                            text,
    provider_parent_org_code                text,
    provider_parent_name                    text,
    provider_org_code                       text,
    provider_org_name                       text,
    commissioner_parent_org_code            text,
    commissioner_parent_name                text,
    commissioner_org_code                   text,
    commissioner_org_name                   text,
    rtt_part_type                           text,
    rtt_part_description                    text,
    treatment_function_code                 text,
    treatment_function_name                 text,

    -- wait bands: 104 bounded weekly bands plus one open-ended band.
    -- gt_104_weeks has no upper bound, so a true mean wait cannot be
    -- computed from this data. Noted in the limitations section.
    gt_00_to_01_weeks                       text,
    gt_01_to_02_weeks                       text,
    gt_02_to_03_weeks                       text,
    gt_03_to_04_weeks                       text,
    gt_04_to_05_weeks                       text,
    gt_05_to_06_weeks                       text,
    gt_06_to_07_weeks                       text,
    gt_07_to_08_weeks                       text,
    gt_08_to_09_weeks                       text,
    gt_09_to_10_weeks                       text,
    gt_10_to_11_weeks                       text,
    gt_11_to_12_weeks                       text,
    gt_12_to_13_weeks                       text,
    gt_13_to_14_weeks                       text,
    gt_14_to_15_weeks                       text,
    gt_15_to_16_weeks                       text,
    gt_16_to_17_weeks                       text,
    gt_17_to_18_weeks                       text,
    gt_18_to_19_weeks                       text,
    gt_19_to_20_weeks                       text,
    gt_20_to_21_weeks                       text,
    gt_21_to_22_weeks                       text,
    gt_22_to_23_weeks                       text,
    gt_23_to_24_weeks                       text,
    gt_24_to_25_weeks                       text,
    gt_25_to_26_weeks                       text,
    gt_26_to_27_weeks                       text,
    gt_27_to_28_weeks                       text,
    gt_28_to_29_weeks                       text,
    gt_29_to_30_weeks                       text,
    gt_30_to_31_weeks                       text,
    gt_31_to_32_weeks                       text,
    gt_32_to_33_weeks                       text,
    gt_33_to_34_weeks                       text,
    gt_34_to_35_weeks                       text,
    gt_35_to_36_weeks                       text,
    gt_36_to_37_weeks                       text,
    gt_37_to_38_weeks                       text,
    gt_38_to_39_weeks                       text,
    gt_39_to_40_weeks                       text,
    gt_40_to_41_weeks                       text,
    gt_41_to_42_weeks                       text,
    gt_42_to_43_weeks                       text,
    gt_43_to_44_weeks                       text,
    gt_44_to_45_weeks                       text,
    gt_45_to_46_weeks                       text,
    gt_46_to_47_weeks                       text,
    gt_47_to_48_weeks                       text,
    gt_48_to_49_weeks                       text,
    gt_49_to_50_weeks                       text,
    gt_50_to_51_weeks                       text,
    gt_51_to_52_weeks                       text,
    gt_52_to_53_weeks                       text,
    gt_53_to_54_weeks                       text,
    gt_54_to_55_weeks                       text,
    gt_55_to_56_weeks                       text,
    gt_56_to_57_weeks                       text,
    gt_57_to_58_weeks                       text,
    gt_58_to_59_weeks                       text,
    gt_59_to_60_weeks                       text,
    gt_60_to_61_weeks                       text,
    gt_61_to_62_weeks                       text,
    gt_62_to_63_weeks                       text,
    gt_63_to_64_weeks                       text,
    gt_64_to_65_weeks                       text,
    gt_65_to_66_weeks                       text,
    gt_66_to_67_weeks                       text,
    gt_67_to_68_weeks                       text,
    gt_68_to_69_weeks                       text,
    gt_69_to_70_weeks                       text,
    gt_70_to_71_weeks                       text,
    gt_71_to_72_weeks                       text,
    gt_72_to_73_weeks                       text,
    gt_73_to_74_weeks                       text,
    gt_74_to_75_weeks                       text,
    gt_75_to_76_weeks                       text,
    gt_76_to_77_weeks                       text,
    gt_77_to_78_weeks                       text,
    gt_78_to_79_weeks                       text,
    gt_79_to_80_weeks                       text,
    gt_80_to_81_weeks                       text,
    gt_81_to_82_weeks                       text,
    gt_82_to_83_weeks                       text,
    gt_83_to_84_weeks                       text,
    gt_84_to_85_weeks                       text,
    gt_85_to_86_weeks                       text,
    gt_86_to_87_weeks                       text,
    gt_87_to_88_weeks                       text,
    gt_88_to_89_weeks                       text,
    gt_89_to_90_weeks                       text,
    gt_90_to_91_weeks                       text,
    gt_91_to_92_weeks                       text,
    gt_92_to_93_weeks                       text,
    gt_93_to_94_weeks                       text,
    gt_94_to_95_weeks                       text,
    gt_95_to_96_weeks                       text,
    gt_96_to_97_weeks                       text,
    gt_97_to_98_weeks                       text,
    gt_98_to_99_weeks                       text,
    gt_99_to_100_weeks                      text,
    gt_100_to_101_weeks                     text,
    gt_101_to_102_weeks                     text,
    gt_102_to_103_weeks                     text,
    gt_103_to_104_weeks                     text,
    gt_104_weeks                            text,

    -- source totals: the publisher's own arithmetic, kept as the
    -- reconciliation check. total = sum of bands;
    -- total_all = total + patients_with_unknown_clock_start_date.
    total                                   text,
    patients_with_unknown_clock_start_date  text,
    total_all                               text,

    -- lineage: added by the loader, not present in the source
    member_sha256                           text        NOT NULL,
    period                                  date        NOT NULL,
    source_row_number                       bigint      NOT NULL,
    ingested_at                             timestamptz NOT NULL DEFAULT now()
);

-- The loader deletes by member_sha256 before inserting, so that a rerun of an
-- interrupted load cannot leave duplicates behind. This index makes that delete
-- cheap; it is not a uniqueness claim.
CREATE INDEX IF NOT EXISTS rtt_full_extract_member_ix
    ON raw.rtt_full_extract (member_sha256);
