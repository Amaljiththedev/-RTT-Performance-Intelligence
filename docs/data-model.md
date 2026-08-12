# Data Model

## Layering
- `raw` — as published. One table per source file, all columns text, plus `_source_file`,
  `_ingested_at`, `_file_hash`. Never edited, never deduplicated. This is the audit trail.
- `staging` — typed, renamed, unpivoted. Wait bands become rows. Suppression markers (`*`) are
  preserved as a flag, not silently coerced to zero.
- `marts` — the star schema the report reads.

## Grain
`fact_waiting_list` is one row per **provider × specialty × period (month) × pathway type × wait band**.

Pathway type ∈ {incomplete, completed_admitted, completed_non_admitted, new_rtt_periods}.
Wait band is the published banding (0–1, 1–2, … 103–104, 104+ weeks) held as a dimension so the
104+ open band is explicit rather than hidden in an average.

Why not one wide table: the published files change shape between years, providers merge, and the
breach measures need the same wait-band axis reused across three pathway types. A star keeps the
grain stable and lets Power BI compress the fact properly in import mode.

## Tables
| Table | Type | Key | Notes |
|---|---|---|---|
| `fact_waiting_list` | fact | surrogate; unique on the 5-part grain | `pathway_count`, `is_suppressed`, `is_estimated` |
| `dim_provider` | SCD2 | `provider_sk` | `provider_code`, `provider_name`, `icb_code`, `valid_from`, `valid_to`, `is_current` |
| `dim_specialty` | SCD1 | `specialty_sk` | treatment function code + name + grouping |
| `dim_date` | conformed | `date_sk` | month spine, NHS financial year, period end |
| `dim_wait_band` | SCD1 | `wait_band_sk` | lower/upper week bound, sort order, `is_breach_18w`, `is_breach_52w` |
| `fact_breach_risk` | derived fact | provider × specialty × period | flag, projected breach count, driver components |
| `etl_ingest_log` | ops | run id | source, file hash, rows in/out, status, timestamps |

## Provider mergers
Handled with SCD2 on `dim_provider` plus a `provider_lineage` mapping (successor code, effective
date). Trend queries join through lineage so a merged trust's history is continuous; the report
surfaces a footnote wherever lineage has been applied, because a manager will otherwise assume a
step change is real.

## Breach-risk method (the actual arithmetic)
For provider-specialty *p*, at month *m*:
- `at_risk_cohort` = pathways currently in bands 48–52 weeks (they breach within four weeks unless treated).
- `clearance_rate` = trailing 3-month mean of completed pathways ÷ opening waiting list.
- `projected_breaches` = at_risk_cohort × (1 − clearance_rate applied over 4 weeks), floored at 0.
- **Flag** = `projected_breaches > 0` and the cohort is not falling faster than trend.

Driver decomposition of the change in `at_risk_cohort` month over month:
- demand = Δ new RTT periods lagged to the relevant band
- capacity = Δ clearance rate × opening cohort
- administrative = residual, i.e. movement not explained by either (clock stops, reclassification,
  revision to prior submission). Naming the residual honestly is the point.

## Known data-quality issues to log in `docs/data-quality-log.md`
- Small-number suppression (`*`) — must not become zero.
- Providers with non-reporting months (estimated / excluded by NHSE).
- Retrospective revisions to prior months — track by re-hashing files and recording deltas.
- Specialty code changes across years.
- "Unknown clock start" pathways excluded from banded counts but present in totals.
