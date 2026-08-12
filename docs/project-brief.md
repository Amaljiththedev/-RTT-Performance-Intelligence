# RTT Performance Intelligence — Project Brief

## Problem
NHS trusts report referral-to-treatment (RTT) waiting times monthly and are penalised for 52-week
breaches. Managers see breach counts only after they have happened, at pathway level, with no view
of which specialties are heading for breach and no attribution of cause.

## Who it is for
Primary: Directorate Operations Manager at an acute trust.
Secondary: ICB performance team.

## What it does
A Power BI report over a PostgreSQL star schema that adds two things the published data does not give you:

1. **Four-week breach-risk indicator per provider-specialty** — derived from the waiting-list age
   distribution and the observed clearance rate, not a model.
2. **Driver decomposition** — splits the change in the at-risk cohort into demand (referral volume),
   capacity (clearance rate) and administrative (unknown-clock / data-quality movement) components.

## Why no ML
Deliberate. Roughly 20 monthly observations per provider-specialty, a strong structural signal
(a pathway waiting 48 weeks with a known clearance rate has a near-deterministic breach date), and a
clinical audience who must be able to check the arithmetic. A linear clearance-rate projection
degrades predictably and can be explained in one sentence. This is written up in
`docs/why-no-model.md` and the choice is defended, not hidden.

## Success measure
Backtest of the four-week flag against the following month's actuals over the last 12 months.
Report precision and recall as they land. Baseline for comparison: 100% of breaches are currently
"unforeseen" because no forward indicator exists.

## Data sources (all public, no DSA required)
| Source | Grain | Use |
|---|---|---|
| NHS England RTT waiting times statistics (monthly) | provider × specialty × wait band | Fact table |
| NHS England ODS / provider reference data | provider | `dim_provider`, SCD2 for reorganisations |
| ONS mid-year population estimates | ICB / LA | Catchment normalisation (rate per 100k) |
| HES summary tables | provider × specialty | Optional context on activity |

## Explicit non-goals
- No patient-level data. Everything is aggregate and already published.
- No API or backend service. Scheduled ingestion only.
- No forecasting beyond four weeks; the method does not support it.
