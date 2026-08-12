"""Fetch NHS England RTT monthly ZIPs and unpack the CSVs inside.

URL in, files on disk. This module does not choose what to fetch (discover.py)
and does not touch the database (load_raw.py).

Layout produced::

    data/raw/2026-01/a1b2c3d4e5f6.zip          the bundle as published
    data/raw/2026-01/a1b2c3d4e5f6/*.csv        its members, unpacked
    data/raw/2026-01/a1b2c3d4e5f6.json         manifest: url, etag, hashes, members

Files are addressed by the SHA-256 of their content, not by the published
filename. NHS England reissues months in place -- several are already on their
second revision -- so keying on the name would let a revision silently overwrite
the version an earlier analysis was built on. Content addressing keeps both, and
makes "this month was revised" an observable fact rather than a lost one.

Manifests double as the conditional-request cache: a rerun sends the stored
ETag and gets a cheap 304 back for anything unchanged.
"""

from __future__ import annotations

import hashlib
import json
import re
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

import requests

from discover import Publication, USER_AGENT, discover

DATA_ROOT = Path(__file__).resolve().parents[1] / "data" / "raw"

TIMEOUT = 120  # bundles are a few MB; generous, but not unbounded
CHUNK = 1 << 16
POLITE_DELAY = 1.0  # seconds between downloads
MAX_ATTEMPTS = 3
MAX_BYTES = 200 * 1024 * 1024  # refuse anything absurd rather than filling the disk

# Member kinds, matched against the CSV filename. Current bundles ship a single
# "full extract" holding every pathway type, distinguished by the RTT Part Type
# column rather than by file -- so splitting by pathway happens in staging, not
# here. The per-pathway patterns are kept for older bundles that did split by
# file. Order matters: non-admitted must be tested before admitted, because
# "non-admitted" contains "admitted".
_MEMBER_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("full_extract", re.compile(r"full[-_\s]?extract", re.IGNORECASE)),
    ("completed_non_admitted", re.compile(r"non[-_\s]?admitted", re.IGNORECASE)),
    ("completed_admitted", re.compile(r"admitted", re.IGNORECASE)),
    ("incomplete_with_dta", re.compile(r"incomplete.*dta|dta.*incomplete", re.IGNORECASE)),
    ("incomplete", re.compile(r"incomplete", re.IGNORECASE)),
    ("new_rtt_periods", re.compile(r"new[-_\s]?rtt|new[-_\s]?periods", re.IGNORECASE)),
]


class DownloadError(RuntimeError):
    """Raised when a bundle cannot be fetched or unpacked safely."""


@dataclass
class Member:
    """One CSV unpacked from a bundle."""

    filename: str
    pathway_type: str
    sha256: str
    bytes: int
    path: str  # relative to DATA_ROOT, so manifests survive a move


@dataclass
class DownloadResult:
    period_key: str
    url: str
    status: str  # "downloaded" | "skipped_unchanged" | "revised"
    sha256: str | None = None
    bytes: int = 0
    original_filename: str | None = None
    etag: str | None = None
    last_modified: str | None = None
    members: list[Member] = field(default_factory=list)

    def to_dict(self) -> dict:
        data = self.__dict__.copy()
        data["members"] = [member.__dict__ for member in self.members]
        return data


def _period_dir(period_key: str) -> Path:
    return DATA_ROOT / period_key


def _manifests(period_key: str) -> list[dict]:
    directory = _period_dir(period_key)
    if not directory.exists():
        return []
    out = []
    for path in sorted(directory.glob("*.json")):
        try:
            with path.open(encoding="utf-8") as fh:
                out.append(json.load(fh))
        except (OSError, json.JSONDecodeError):
            continue  # a corrupt manifest just means we re-fetch
    return out


def _cached_validators(period_key: str, url: str) -> tuple[str | None, str | None]:
    """ETag and Last-Modified from the newest manifest for this month and URL."""
    for manifest in reversed(_manifests(period_key)):
        if manifest.get("url") == url:
            return manifest.get("etag"), manifest.get("last_modified")
    return None, None


def _known_hashes(period_key: str) -> set[str]:
    return {m["sha256"] for m in _manifests(period_key) if m.get("sha256")}


def classify_member(filename: str) -> str:
    """Map a CSV filename to a member kind.

    Unrecognised members raise. A silently skipped file is a silently missing
    pathway type in the marts, which is much harder to notice later.
    """
    stem = Path(filename).name
    for kind, pattern in _MEMBER_PATTERNS:
        if pattern.search(stem):
            return kind
    raise DownloadError(
        f"cannot classify {stem!r} against known member kinds. The bundle "
        "layout may have changed -- inspect it and extend _MEMBER_PATTERNS."
    )


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def _stream_to_temp(url: str, destination: Path) -> tuple[str, int, requests.Response]:
    """Download to a .part file, hashing as it goes. Returns hash, size, response."""
    headers = {"User-Agent": USER_AGENT}
    temp = destination.with_suffix(destination.suffix + ".part")
    last_error: Exception | None = None

    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with requests.get(
                url, headers=headers, timeout=TIMEOUT, stream=True
            ) as response:
                response.raise_for_status()
                digest = hashlib.sha256()
                size = 0
                with temp.open("wb") as fh:
                    for chunk in response.iter_content(CHUNK):
                        if not chunk:
                            continue
                        size += len(chunk)
                        if size > MAX_BYTES:
                            raise DownloadError(
                                f"{url} exceeded {MAX_BYTES} bytes; refusing"
                            )
                        digest.update(chunk)
                        fh.write(chunk)
                return digest.hexdigest(), size, response
        except (requests.RequestException, OSError) as exc:
            last_error = exc
            temp.unlink(missing_ok=True)
            if attempt < MAX_ATTEMPTS:
                time.sleep(2**attempt)

    raise DownloadError(f"failed to download {url} after {MAX_ATTEMPTS} attempts: {last_error}")


def _inspect_members(archive: Path) -> list[Member]:
    """Catalogue and hash the CSVs inside a bundle without unpacking them.

    The full extract is around 76 MB of text per month; unpacking 24 of those
    would leave nearly 2 GB on disk to no purpose, since the loader can stream
    members straight out of the ZIP. So we hash in place and record where each
    member lives, rather than writing it out.
    """
    members: list[Member] = []
    archive_rel = str(archive.relative_to(DATA_ROOT)).replace("\\", "/")

    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            if info.is_dir() or not info.filename.lower().endswith(".csv"):
                continue
            digest = hashlib.sha256()
            with zf.open(info) as src:
                while chunk := src.read(CHUNK):
                    digest.update(chunk)
            members.append(
                Member(
                    filename=Path(info.filename).name,
                    pathway_type=classify_member(info.filename),
                    sha256=digest.hexdigest(),
                    bytes=info.file_size,
                    path=f"{archive_rel}::{info.filename}",
                )
            )

    if not members:
        raise DownloadError(f"no CSV members found in {archive.name}")
    return members


def fetch(publication: Publication, force: bool = False) -> DownloadResult:
    """Fetch one publication. Cheap and side-effect-free when nothing changed."""
    period_key = publication.period_key
    directory = _period_dir(period_key)
    directory.mkdir(parents=True, exist_ok=True)

    etag, last_modified = _cached_validators(period_key, publication.url)
    if not force and (etag or last_modified):
        conditional = {"User-Agent": USER_AGENT}
        if etag:
            conditional["If-None-Match"] = etag
        if last_modified:
            conditional["If-Modified-Since"] = last_modified
        try:
            probe = requests.head(
                publication.url, headers=conditional, timeout=TIMEOUT, allow_redirects=True
            )
            if probe.status_code == 304:
                return DownloadResult(
                    period_key=period_key,
                    url=publication.url,
                    status="skipped_unchanged",
                    etag=etag,
                    last_modified=last_modified,
                )
        except requests.RequestException:
            pass  # a failed probe is not a failed download; fall through and fetch

    seen_before = _known_hashes(period_key)
    staging_path = directory / "incoming.zip"
    sha, size, response = _stream_to_temp(publication.url, staging_path)

    final_zip = directory / f"{sha[:12]}.zip"
    temp = staging_path.with_suffix(staging_path.suffix + ".part")

    if final_zip.exists():
        # Identical content already on disk; drop the temp copy and reuse it.
        temp.unlink(missing_ok=True)
    else:
        temp.replace(final_zip)

    members = _inspect_members(final_zip)

    result = DownloadResult(
        period_key=period_key,
        url=publication.url,
        status="revised" if seen_before and sha not in seen_before else "downloaded",
        sha256=sha,
        bytes=size,
        original_filename=publication.url.rsplit("/", 1)[-1],
        etag=response.headers.get("ETag"),
        last_modified=response.headers.get("Last-Modified"),
        members=members,
    )

    manifest_path = directory / f"{sha[:12]}.json"
    with manifest_path.open("w", encoding="utf-8") as fh:
        json.dump(result.to_dict(), fh, indent=2)

    return result


def fetch_all(
    publications: list[Publication] | None = None, force: bool = False
) -> list[DownloadResult]:
    """Fetch every publication, pausing between requests."""
    publications = publications if publications is not None else discover()
    results: list[DownloadResult] = []

    for index, publication in enumerate(publications):
        result = fetch(publication, force=force)
        results.append(result)
        if result.status != "skipped_unchanged" and index < len(publications) - 1:
            time.sleep(POLITE_DELAY)

    return results


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Download RTT monthly bundles.")
    parser.add_argument("--months", type=int, default=24)
    parser.add_argument("--force", action="store_true", help="ignore cached validators")
    parser.add_argument("--period", help="fetch a single month, e.g. 2026-01")
    args = parser.parse_args()

    pubs = discover(months=args.months)
    if args.period:
        pubs = [p for p in pubs if p.period_key == args.period]
        if not pubs:
            raise SystemExit(f"{args.period} not found in the discovered publications")

    for outcome in fetch_all(pubs, force=args.force):
        detail = (
            f"{outcome.bytes / 1e6:.1f} MB, {len(outcome.members)} CSVs"
            if outcome.members
            else "no change"
        )
        print(f"{outcome.period_key}  {outcome.status:18}  {detail}")
