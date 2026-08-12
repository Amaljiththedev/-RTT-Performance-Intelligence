"""Load RTT full-extract CSVs from the downloaded bundles into raw.rtt_full_extract.

Streams each member straight out of its ZIP -- nothing is unpacked to disk -- and
uses COPY rather than row-by-row inserts, because a month is around 300k rows and
24 months is several million.

Everything lands as text. The wait-band columns contain '*' where a small number
has been suppressed, and coercing that to null here would destroy the difference
between "withheld" and "zero" before staging ever sees it.

Idempotency has two layers. The log's partial unique index means a member can
only ever be 'loaded' once, and the delete-before-insert inside the load
transaction means an interrupted run cannot leave half a file behind.
"""

from __future__ import annotations

import csv
import io
import json
import re
import uuid
import zipfile
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import psycopg2

from db import get_connection

DATA_ROOT = Path(__file__).resolve().parents[1] / "data" / "raw"
TARGET_TABLE = "raw.rtt_full_extract"
LINEAGE_COLUMNS = ("member_sha256", "period", "source_row_number")
# ingested_at is left to its column default.

# Deliberate departures from mechanical snake-casing. The source's "Period"
# holds a label ("RTT-May-2026"), not a date, and `period` is reserved for the
# date the loader parses from it -- keeping both means a parsing bug is
# detectable rather than invisible.
HEADER_RENAMES = {"period": "period_label"}

csv.field_size_limit(10 * 1024 * 1024)


class LoadError(RuntimeError):
    """Raised when a file cannot be loaded safely."""


class SchemaDriftError(LoadError):
    """Raised when a CSV's column set no longer matches the landing table."""


@dataclass
class LoadResult:
    period_key: str
    member_filename: str
    member_sha256: str
    status: str  # "loaded" | "skipped_already_loaded"
    rows_read: int = 0
    rows_loaded: int = 0


def snake(name: str) -> str:
    """Snake-case a published header, dropping the redundant 'SUM 1' suffix.

    Must stay in step with the naming used in sql/raw/02_rtt_full_extract.sql;
    the header check below is what enforces that.
    """
    stem = re.sub(r"\s+SUM\s+1$", "", name.strip(), flags=re.IGNORECASE)
    cleaned = re.sub(r"[^0-9a-zA-Z]+", "_", stem).strip("_").lower()
    return HEADER_RENAMES.get(cleaned, cleaned)


def _target_columns(conn) -> list[str]:
    """Source columns of the landing table, in order, excluding lineage."""
    with conn.cursor() as cur:
        schema, table = TARGET_TABLE.split(".")
        cur.execute(
            """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
            ORDER BY ordinal_position
            """,
            (schema, table),
        )
        columns = [row[0] for row in cur.fetchall()]
    if not columns:
        raise LoadError(f"{TARGET_TABLE} does not exist; run the migrations first")
    excluded = set(LINEAGE_COLUMNS) | {"ingested_at"}
    return [c for c in columns if c not in excluded]


def _check_header(header: list[str], expected: list[str], member: str) -> list[str]:
    """Compare a CSV header against the landing table, naming any drift."""
    actual = [snake(h) for h in header]
    if actual == expected:
        return actual

    missing = [c for c in expected if c not in actual]
    added = [c for c in actual if c not in expected]
    detail = []
    if missing:
        detail.append(f"missing {len(missing)}: {missing[:8]}")
    if added:
        detail.append(f"unexpected {len(added)}: {added[:8]}")
    if not detail:
        detail.append("same columns in a different order")
    raise SchemaDriftError(
        f"{member}: column set has drifted from {TARGET_TABLE} -- "
        + "; ".join(detail)
        + ". Inspect the file before widening the table."
    )


class _CopyStream(io.RawIOBase):
    """File-like CSV stream with lineage columns appended to every row.

    COPY is fast because it is dumb: it will not add the lineage columns for us.
    Re-emitting each row through csv keeps quoting and embedded commas correct,
    which naive string concatenation would not.
    """

    def __init__(self, reader, member_sha256: str, period: date):
        self._reader = reader
        self._sha = member_sha256
        self._period = period.isoformat()
        self._buffer = io.StringIO()
        self._writer = csv.writer(self._buffer, lineterminator="\n")
        self._pending = ""
        self._exhausted = False
        self.rows_read = 0

    def readable(self) -> bool:
        return True

    def _fill(self, size: int) -> None:
        while not self._exhausted and len(self._pending) < size:
            try:
                row = next(self._reader)
            except StopIteration:
                self._exhausted = True
                break
            self.rows_read += 1
            self._writer.writerow(row + [self._sha, self._period, self.rows_read])
            self._pending += self._buffer.getvalue()
            self._buffer.seek(0)
            self._buffer.truncate(0)

    def read(self, size: int = -1) -> bytes:  # type: ignore[override]
        if size is None or size < 0:
            size = 1 << 20
        self._fill(size)
        chunk, self._pending = self._pending[:size], self._pending[size:]
        return chunk.encode("utf-8")

    # csv-module callers expect readline; COPY only uses read().
    def readline(self, size: int = -1) -> bytes:  # type: ignore[override]
        return self.read(size if size and size > 0 else 1 << 16)


def _already_loaded(conn, member_sha256: str) -> bool:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM raw.etl_ingest_log "
            "WHERE member_sha256 = %s AND status = 'loaded' LIMIT 1",
            (member_sha256,),
        )
        return cur.fetchone() is not None


def _log_started(conn, run_id: uuid.UUID, manifest: dict, member: dict) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO raw.etl_ingest_log (
                run_id, period, source_url, original_filename,
                bundle_sha256, member_filename, member_sha256, member_kind,
                bytes, etag, last_modified, status
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'started')
            RETURNING ingest_id
            """,
            (
                str(run_id),
                _period_date(manifest["period_key"]),
                manifest["url"],
                manifest.get("original_filename"),
                manifest.get("sha256"),
                member["filename"],
                member["sha256"],
                member.get("pathway_type"),
                member.get("bytes"),
                manifest.get("etag"),
                manifest.get("last_modified"),
            ),
        )
        return cur.fetchone()[0]


def _log_finished(conn, ingest_id: int, status: str, rows_read: int, rows_loaded: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE raw.etl_ingest_log
               SET status = %s, rows_read = %s, rows_loaded = %s, finished_at = now()
             WHERE ingest_id = %s
            """,
            (status, rows_read, rows_loaded, ingest_id),
        )


def _log_failed(conn, ingest_id: int, exc: BaseException) -> None:
    """Record a failure on its own connection state, after a rollback."""
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE raw.etl_ingest_log
               SET status = 'failed', error_type = %s, error_message = %s,
                   finished_at = now()
             WHERE ingest_id = %s
            """,
            (type(exc).__name__, str(exc)[:2000], ingest_id),
        )


def _period_date(period_key: str) -> date:
    year, month = (int(part) for part in period_key.split("-"))
    return date(year, month, 1)


def iter_manifests() -> list[dict]:
    """Every downloaded bundle manifest, oldest first."""
    manifests = []
    for path in sorted(DATA_ROOT.glob("*/*.json")):
        with path.open(encoding="utf-8") as fh:
            manifests.append(json.load(fh))
    return sorted(manifests, key=lambda m: (m["period_key"], m.get("sha256") or ""))


def load_member(conn, run_id: uuid.UUID, manifest: dict, member: dict,
                expected: list[str]) -> LoadResult:
    """Load one CSV member. Skips cheaply if it has already been loaded."""
    sha = member["sha256"]
    period_key = manifest["period_key"]

    if _already_loaded(conn, sha):
        return LoadResult(period_key, member["filename"], sha, "skipped_already_loaded")

    archive_rel, _, inner = member["path"].partition("::")
    archive = DATA_ROOT / archive_rel
    if not archive.exists():
        raise LoadError(f"bundle missing from disk: {archive}")

    ingest_id = _log_started(conn, run_id, manifest, member)
    conn.commit()  # the 'started' row must survive a later rollback

    period = _period_date(period_key)
    column_list = ", ".join(expected + list(LINEAGE_COLUMNS))

    try:
        with zipfile.ZipFile(archive) as zf, zf.open(inner) as raw_member:
            text = io.TextIOWrapper(raw_member, encoding="utf-8-sig", newline="")
            reader = csv.reader(text)
            header = next(reader)
            _check_header(header, expected, member["filename"])

            stream = _CopyStream(reader, sha, period)
            with conn.cursor() as cur:
                # Same transaction as the insert, so an interrupted rerun cannot
                # leave duplicates behind.
                cur.execute(
                    f"DELETE FROM {TARGET_TABLE} WHERE member_sha256 = %s", (sha,)
                )
                cur.copy_expert(
                    f"COPY {TARGET_TABLE} ({column_list}) FROM STDIN WITH (FORMAT csv)",
                    stream,
                )
                rows_loaded = cur.rowcount

        _log_finished(conn, ingest_id, "loaded", stream.rows_read, rows_loaded)
        conn.commit()
    except BaseException as exc:
        conn.rollback()
        try:
            _log_failed(conn, ingest_id, exc)
            conn.commit()
        except psycopg2.Error:
            conn.rollback()
        raise

    if rows_loaded != stream.rows_read:
        raise LoadError(
            f"{member['filename']}: read {stream.rows_read} rows but loaded "
            f"{rows_loaded}. The load is committed and logged -- investigate "
            "before trusting this period."
        )

    return LoadResult(period_key, member["filename"], sha, "loaded",
                      stream.rows_read, rows_loaded)


def load_all(period_key: str | None = None) -> list[LoadResult]:
    run_id = uuid.uuid4()
    results: list[LoadResult] = []
    conn = get_connection()
    try:
        expected = _target_columns(conn)
        for manifest in iter_manifests():
            if period_key and manifest["period_key"] != period_key:
                continue
            for member in manifest["members"]:
                results.append(
                    load_member(conn, run_id, manifest, member, expected)
                )
    finally:
        conn.close()
    return results


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Load downloaded RTT extracts into raw.")
    parser.add_argument("--period", help="load a single month, e.g. 2026-05")
    args = parser.parse_args()

    outcomes = load_all(period_key=args.period)
    if not outcomes:
        raise SystemExit("nothing to load -- run download.py first")
    for outcome in outcomes:
        detail = (
            f"{outcome.rows_loaded:,} rows"
            if outcome.status == "loaded"
            else "already loaded"
        )
        print(f"{outcome.period_key}  {outcome.status:22}  {detail}")
