# Build Plan — 2.5 weeks

Each phase ends with something demonstrable. Do not start the next phase until the previous one's
check passes.

## Phase 0 — Foundations (0.5 day)
- `git init`, `.gitignore`, `.env.example` (no secrets committed).
- PostgreSQL locally via Docker Compose; `raw` / `staging` / `marts` schemas created by `sql/00_init.sql`.
- Python env: `pandas`, `requests`, `sqlalchemy`, `psycopg2-binary`, `pytest`, `python-dotenv`.
- **Check:** `docker compose up` and a connection test succeeds.

## Phase 1 — Ingestion (2 days)
- `ingest/discover.py` — resolve NHS England RTT publication URLs by month.
- `ingest/download.py` — fetch, hash, cache to `data/raw/` (gitignored).
- `ingest/load_raw.py` — load to `raw.*` all-text with lineage columns; idempotent on file hash.
- Write to `etl_ingest_log` on every run.
- Target ~24 months so there is a 12-month backtest plus history.
- **Check:** rerunning ingestion twice produces no duplicate rows.

## Phase 2 — Staging (2 days)
- Unpivot wait bands; type-cast; preserve suppression as a flag.
- Normalise specialty codes across years into one lookup.
- Build `provider_lineage` from ODS successor data.
- **Check:** staging row totals reconcile to the published national totals per month, within the
  documented suppression allowance. Record any gap in the data-quality log.

## Phase 3 — Marts (2 days)
- Date spine, dimensions (SCD2 on provider), then the fact.
- CTEs for the pathway build; window functions for running clearance and period-over-period.
- **Check:** all assertion tests in `/tests` pass — grain uniqueness, non-negative waits,
  referential integrity, row-count reconciliation to source.

## Phase 4 — Breach risk + backtest (2 days)
- `fact_breach_risk` built in SQL, arithmetic exactly as in `docs/data-model.md`.
- Backtest harness: for each of the last 12 months, flag as at month *m*, compare to actual
  52-week breaches at *m+1*. Output precision, recall, confusion matrix per month.
- **Check:** metrics written to `docs/evaluation.md`, reported as they are. If precision is poor,
  say so and say what you would need to fix it.

## Phase 5 — Power BI (3 days)
- Import mode over `marts` only. Save as `.pbip` so it is diffable in git.
- Pages: Executive · Specialty drill-down · Breach-risk watchlist · Data quality.
- Measures in DAX, not calculated columns, except where a column is needed for slicing.
- Row-level security role by provider.
- Incremental refresh partitioned by month; freshness card on every page.
- **Check:** RLS tested with "View as role"; a provider-scoped user sees only their trust.

## Phase 6 — Automation and docs (1.5 days)
- GitHub Actions cron for monthly ingestion; alert if the source publication is late.
- `docs/semantic-model.md`, `docs/exec-brief.pdf`, `docs/data-quality-log.md`.
- README: problem → audience → screenshot → live link → three findings → how the model is built →
  data-quality issues found → limitations → how to run.
- Three-minute walkthrough recorded as if presenting to the operations manager.

## Repo layout
```
/ingest              Python ingestion
/sql/raw             schema + raw DDL
/sql/staging         typed, unpivoted
/sql/marts           star schema + breach risk
/tests               SQL assertions + pytest
/powerbi             .pbip, source-controlled
/docs                brief, data model, semantic model, DQ log, evaluation
/config              source URLs, specialty mappings
/.github/workflows   ingestion cron
```

## Risks
- **NHSE file shape changes between years.** Mitigation: schema check on load, fail loudly.
- **Backtest looks weak.** That is a finding, not a failure — report it and discuss what a
  four-week horizon can and cannot do.
- **Power BI Service publishing needs a licence.** Fallback: publish to a free workspace or ship a
  `.pbix` download plus screenshots, and say which was used.
