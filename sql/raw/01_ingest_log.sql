-- Operational log for the ingestion pipeline. One row per file per run.
--
-- Not part of the star schema and holds no RTT data. It lives in `raw` because
-- it belongs to the ingestion layer, but Power BI reads it for the freshness
-- indicator and the revision rate on the data-quality page.
--
-- No foreign keys, deliberately: the table must be able to record a failed load
-- where no data rows exist to point at.

CREATE TABLE IF NOT EXISTS raw.etl_ingest_log (
    ingest_id            bigserial PRIMARY KEY,
    run_id               uuid NOT NULL,
    period               date NOT NULL,

    -- provenance: where this file came from and how to recognise it again
    source_url           text NOT NULL,
    original_filename    text,
    bundle_sha256        text,
    member_filename      text,
    member_sha256        text,
    member_kind          text,
    bytes                bigint,
    etag                 text,
    last_modified        text,

    -- outcome
    status               text NOT NULL,
    rows_read            bigint,
    rows_loaded          bigint,
    error_type           text,
    error_message        text,

    -- timing
    started_at           timestamp with time zone NOT NULL DEFAULT now(),
    finished_at          timestamp with time zone,
    source_published_at  date,

    -- 'started' is written before work begins so an interrupted run leaves a
    -- visible open row rather than no trace at all.
    CONSTRAINT etl_ingest_log_status_ck CHECK (
        status IN ('started', 'downloaded', 'skipped_unchanged',
                   'revised', 'loaded', 'failed')
    ),

    -- A failure must say why; anything else must not carry a stale message.
    CONSTRAINT etl_ingest_log_error_ck CHECK (
        (status = 'failed' AND error_message IS NOT NULL)
        OR (status <> 'failed' AND error_message IS NULL)
    ),

    -- Reporting period is always the first of the month.
    CONSTRAINT etl_ingest_log_period_ck CHECK (
        period = date_trunc('month', period::timestamptz)::date
    ),

    CONSTRAINT etl_ingest_log_bytes_ck CHECK (bytes IS NULL OR bytes >= 0),

    CONSTRAINT etl_ingest_log_rows_read_ck CHECK (rows_read IS NULL OR rows_read >= 0),

    CONSTRAINT etl_ingest_log_rows_loaded_ck CHECK (rows_loaded IS NULL OR rows_loaded >= 0),

    -- Nulls pass a CHECK, so this only bites once both counts are populated.
    CONSTRAINT etl_ingest_log_rows_ck CHECK (
        rows_read IS NULL OR rows_loaded IS NULL OR rows_loaded <= rows_read
    ),

    -- A finished row must not claim to have finished before it started.
    CONSTRAINT etl_ingest_log_timing_ck CHECK (
        finished_at IS NULL OR finished_at >= started_at
    )
);

-- Idempotency. Partial, so a member may appear many times across attempts but
-- can only ever be 'loaded' once. This makes double-loading structurally
-- impossible rather than merely unlikely.
CREATE UNIQUE INDEX IF NOT EXISTS etl_ingest_log_loaded_member_uq
    ON raw.etl_ingest_log (member_sha256)
    WHERE status = 'loaded';

-- Freshness card: newest successfully loaded period.
CREATE INDEX IF NOT EXISTS etl_ingest_log_period_status_ix
    ON raw.etl_ingest_log (period, status);

-- "What did last night's run do."
CREATE INDEX IF NOT EXISTS etl_ingest_log_run_ix
    ON raw.etl_ingest_log (run_id);
