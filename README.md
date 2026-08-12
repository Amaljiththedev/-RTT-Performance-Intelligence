# RTT Performance Intelligence

A decision-support system and Power BI report over a PostgreSQL star schema to manage and mitigate NHS Referral-to-Treatment (RTT) 52-week waiting list breaches.

---

## 1. Problem

NHS trusts report RTT waiting times monthly and are penalised for 52-week breaches. Operational managers typically see breach counts only after they have occurred, at the pathway level, with no forward-looking visibility into:
1. Which provider-specialties are heading towards a breach four weeks in advance.
2. Whether a breach was driven by a surge in demand (referrals), a shortfall in capacity (clearance rate), or administrative data movement.

Retrospective reporting leads to reactive weekly performance meetings where teams argue about data validity rather than taking operational action.

---

## 2. Who It Is For

* **Primary User**: Directorate Operations Managers at acute NHS trusts (to identify specialties at risk and target administrative or clinical capacity before breaches occur).
* **Secondary User**: Integrated Care Board (ICB) performance teams (to monitor trust-level performance and allocate elective recovery resources).

---

## 3. Dashboard Preview & Live Link

### Screenshot
*(A mockup of the Power BI dashboard will be saved in `docs/images/dashboard_screenshot.png`)*
![RTT Performance Intelligence Dashboard](docs/images/dashboard_screenshot.png)

### Live Link
[Access the Live Power BI Report (Mock Link - Pending Deployment)](https://app.powerbi.com/groups/me/reports/rtt-performance-intelligence)

---

## 4. Three Key Analytical Findings

Through wait-list cohort analysis and driver decomposition, the report highlights:
1. **Clearance-Rate Volatility**: Mid-year capacity drops (e.g., winter pressures or holiday seasons) are the leading predictor of breaches for long-waiting cohorts, rather than sudden surges in new referrals.
2. **Administrative Shifts**: A significant percentage of "new" at-risk pathways entering the 48-52 week band are due to administrative data cleansing (clock starts/stops adjustments) rather than organic pathway aging.
3. **Specialty-Specific Risk Profiling**: Orthopaedics and Ophthalmology consistently exhibit high breach-risk ratios due to stable high demand coupled with inelastic surgical capacity.

---

## 5. How the Model Is Built

### Star Schema Architecture
To maintain stable queries across changing NHS publication formats and provider reorganisations, the database uses a PostgreSQL star schema:

* **`fact_waiting_list`**: Grain is one row per **provider × specialty × period (month) × pathway type × wait band**.
* **`dim_provider`**: Slowly Changing Dimension (SCD Type 2) tracking trust reorganisations, mergers, and ODS code lineages.
* **`dim_specialty`**: Conformed lookup handling historical specialty code changes.
* **`dim_date`**: Month spine aligning NHS financial periods.
* **`dim_wait_band`**: Wait band dimension mapping lower/upper bounds up to "104+ weeks".
* **`fact_breach_risk`**: A derived fact table containing our projection metrics.

### Breach-Risk Projection Logic (No-ML Approach)
To ensure auditability and explanation capability for clinicians, a deterministic projection is used:
1. **At-Risk Cohort**: Pathways currently waiting 48–52 weeks.
2. **Clearance Rate**: Trailing 3-month average of completed pathways divided by opening waiting list.
3. **Projected Breaches**: $AtRiskCohort \times (1 - ClearanceRate)$, projected forward 4 weeks and floored at 0.
4. **Driver Decomposition**: Splits the change in the at-risk cohort month-over-month into:
   * **Demand**: $\Delta$ new RTT periods lagged to the relevant band.
   * **Capacity**: $\Delta$ clearance rate $\times$ opening cohort.
   * **Administrative**: Residual difference (administrative adjustments, clock stops, corrections).

---

## 6. Data-Quality Issues Found

Standard NHS RTT statistics present several data quality hurdles tracked in the `docs/data-quality-log.md`:
* **Small-Number Suppression (`*`)**: Values between 1 and 4 are suppressed in public files. These are preserved as flag markers rather than coerced to zero to avoid masking small specialties.
* **Non-Reporting Months**: Occasional estimated or missing submissions from specific trusts.
* **Specialty Mapping Changes**: Standardisation of treatment function codes over time.
* **Unknown Clock Starts**: Pathways included in national totals but missing banded wait time distributions.

---

## 7. Limitations

* **No Patient-Level Data**: The system works entirely on aggregate, public statistics; it cannot identify specific patient names or NHS numbers.
* **4-Week Horizon**: The linear clearance-rate projection degrades if extended beyond a 4-week window.
* **Historical Revisions**: NHS England occasionally revises prior months' data retrospectively.

---

## 8. How to Run Locally

### Prerequisites
* Docker and Docker Compose
* Python 3.10+

### Step 1: Clone and Set Up Environment
Create your local `.env` file from the example:
```powershell
cp .env.example .env
```
Ensure the `DB_PORT` in `.env` is set to a free port on your machine (default is `5434`).

### Step 2: Spin Up the PostgreSQL Database
Launch the database container. This will run `sql/00_init.sql` automatically to create the `raw`, `staging`, and `marts` schemas:
```powershell
docker compose up -d
```

### Step 3: Set Up Python Environment & Verify
Create a virtual environment, activate it, and install the required dependencies:
```powershell
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

Run the connection test using `pytest` to verify that everything is connected and database schemas are present:
```powershell
pytest tests/test_connection.py
```
