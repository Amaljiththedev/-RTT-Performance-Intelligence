CREATE TABLE IF NOT EXISTS raw.etl_ingest_log (
    ingest_id bigserial PRIMARY KEY, 
    run_id uuid NOT NULL,
    period date NOT NULL,

    -- provenance 
    source_url text NOT NULL,
    original_filename text,
    bundle_sha256 text, 
    member_filename text, 
    member_sha256 text,
    member_kind text,

    -- outcome
    bytes bigint CHECK (bytes >= 0),
    etag text,
    last_modified text,
    status text NOT NULL CHECK (status IN ('started', 'downloaded', 'skipped_unchanged', 'loaded', 'failed', 'revised')),
    rows_read bigint CHECK (rows_read >= 0),
    rows_loaded bigint CHECK (rows_loaded >= 0),
    error_type text,
    error_message text,

    -- timing
    started_at timestamp with time zone NOT NULL DEFAULT now(),
    finished_at timestamp with time zone,
    source_published_at date,

    CONSTRAINT check_rows_loaded_limit CHECK (rows_loaded <= rows_read)
);

-- Indexes for performance and idempotency
CREATE UNIQUE INDEX IF NOT EXISTS etl_ingest_log_unique_member_sha256 
ON raw.etl_ingest_log (member_sha256) 
WHERE status = 'loaded';

CREATE INDEX IF NOT EXISTS etl_ingest_log_period_idx 
ON raw.etl_ingest_log (period);

CREATE INDEX IF NOT EXISTS etl_ingest_log_run_id_idx 
ON raw.etl_ingest_log (run_id);
