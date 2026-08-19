"""Resolve NHS England RTT monthly publication URLs.

Discovery only. This module returns URLs and metadata; it never downloads the
payload and never touches the database. Kept separate because it is the part
most likely to break -- NHS England restructures its statistics pages without
notice, and when that happens only this file should need fixing.

Two sources, in order:
  1. Scrape the RTT statistics year pages for links to the full CSV zips.
  2. Fall back to config/sources.json, an explicit month -> URL list.

Scraped results are validated against the config where both know a month. A
mismatch raises rather than being silently preferred, because a changed URL for
a month we have already ingested usually means the file itself was revised.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, asdict
from datetime import date
from pathlib import Path

import requests

BASE = "https://www.england.nhs.uk"
STATS_ROOT = f"{BASE}/statistics/statistical-work-areas/rtt-waiting-times/"
CONFIG_PATH = Path(__file__).resolve().parents[1] / "config" / "sources.json"

USER_AGENT = (
    "rtt-performance-intelligence/0.1 "
    "(portfolio data project; contact via repository)"
)
TIMEOUT = 30

MONTH_ABBR = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
}

# Links to the full monthly CSV bundle. The wording has drifted over the years
# ("Full CSV data file", "Full-CSV-data-file"), so match loosely on the stem and
# require a .zip target.
_ZIP_LINK = re.compile(
    r'href="(?P<url>[^"]*?full[-\s]?csv[-\s]?data[-\s]?file[^"]*?\.zip)"',
    re.IGNORECASE,
)
# Month token inside the filename, e.g. "Mar25", "Mar-25", "March-2025".
_MONTH_TOKEN = re.compile(
    r"(?P<mon>jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*[-_]?(?P<yr>\d{2,4})",
    re.IGNORECASE,
)
_YEAR_PAGE = re.compile(
    r'href="(?P<url>[^"]*?/rtt-data-(?P<fy>\d{4}-\d{2})/?)"', re.IGNORECASE
)


@dataclass(frozen=True)
class Publication:
    """One monthly RTT publication."""

    period: date  # first day of the reporting month
    url: str
    source: str  # "scrape" or "config"

    @property
    def period_key(self) -> str:
        return self.period.strftime("%Y-%m")

    def to_dict(self) -> dict:
        d = asdict(self)
        d["period"] = self.period_key
        return d


class DiscoveryError(RuntimeError):
    """Raised when discovery cannot produce a trustworthy result."""


def _get(url: str) -> str:
    resp = requests.get(url, headers={"User-Agent": USER_AGENT}, timeout=TIMEOUT)
    resp.raise_for_status()
    return resp.text


def _absolute(url: str) -> str:
    if url.startswith("http"):
        return url
    return BASE + url if url.startswith("/") else f"{BASE}/{url}"


def _period_from_filename(url: str) -> date | None:
    """Pull the reporting month out of a publication filename.

    Returns None rather than guessing when the filename carries no month token;
    an unattributable file is worse than a missing one.
    """
    stem = url.rsplit("/", 1)[-1]
    match = _MONTH_TOKEN.search(stem)
    if not match:
        return None
    month = MONTH_ABBR[match.group("mon").lower()[:3]]
    raw_year = match.group("yr")
    year = int(raw_year) if len(raw_year) == 4 else 2000 + int(raw_year)
    return date(year, month, 1)


def _load_config() -> dict[str, str]:
    if not CONFIG_PATH.exists():
        return {}
    with CONFIG_PATH.open(encoding="utf-8") as fh:
        return json.load(fh).get("publications", {})


def find_year_pages(html: str | None = None) -> list[str]:
    """Year pages linked from the RTT statistics root, e.g. .../rtt-data-2024-25/."""
    html = html if html is not None else _get(STATS_ROOT)
    seen: dict[str, None] = {}
    for match in _YEAR_PAGE.finditer(html):
        seen.setdefault(_absolute(match.group("url")), None)
    return list(seen)


def scrape_publications(year_page_urls: list[str] | None = None) -> list[Publication]:
    """Scrape year pages for monthly CSV zip links."""
    pages = year_page_urls if year_page_urls is not None else find_year_pages()
    found: dict[str, Publication] = {}
    for page in pages:
        try:
            html = _get(page)
        except requests.RequestException:
            # One unreachable year page should not sink the whole run; the
            # config fallback and the completeness check below will catch a
            # genuinely missing month.
            continue
        for match in _ZIP_LINK.finditer(html):
            url = _absolute(match.group("url"))
            period = _period_from_filename(url)
            if period is None:
                continue
            found.setdefault(
                period.strftime("%Y-%m"), Publication(period, url, "scrape")
            )
    return sorted(found.values(), key=lambda p: p.period)


def discover(months: int | None = 24, allow_scrape: bool = True) -> list[Publication]:
    """Return the most recent `months` publications, newest last.

    Scrape results win where present; config fills gaps. Where both know a month
    and disagree on the URL, raise -- a changed URL for an already-ingested month
    normally signals a revised file, which is a decision for a human.
    """
    config = _load_config()
    scraped: list[Publication] = []
    if allow_scrape:
        try:
            scraped = scrape_publications()
        except requests.RequestException as exc:
            if not config:
                raise DiscoveryError(
                    f"scrape failed and no config fallback at {CONFIG_PATH}: {exc}"
                ) from exc

    merged: dict[str, Publication] = {}
    for key, url in config.items():
        year, month = (int(part) for part in key.split("-"))
        merged[key] = Publication(date(year, month, 1), url, "config")

    for pub in scraped:
        known = merged.get(pub.period_key)
        if known is not None and known.url != pub.url:
            raise DiscoveryError(
                f"URL mismatch for {pub.period_key}: config has {known.url!r}, "
                f"scrape found {pub.url!r}. The file may have been revised -- "
                "confirm and update config/sources.json before ingesting."
            )
        merged[pub.period_key] = pub

    if not merged:
        raise DiscoveryError(
            "no RTT publications discovered; the statistics page layout has "
            "probably changed. Check STATS_ROOT and the link patterns."
        )

    ordered = sorted(merged.values(), key=lambda p: p.period)
    return ordered[-months:] if months else ordered


def latest_expected_period(today: date | None = None) -> date:
    """The most recent month that should have been published by now.

    NHS England publishes RTT roughly six to eight weeks in arrears, on the
    second Thursday of the month. So for most of month M the newest available
    data covers M-3, and only after publication day does it become M-2. Being
    strict about M-2 raises a false "source is late" alarm every month between
    the 1st and publication day.
    """
    today = today or date.today()
    lag = 2 if today.day >= 15 else 3
    year, month = today.year, today.month - lag
    while month < 1:
        month += 12
        year -= 1
    return date(year, month, 1)


def check_freshness(pubs: list[Publication], today: date | None = None) -> str | None:
    """Return a warning string if the newest publication is behind schedule."""
    if not pubs:
        return "no publications discovered"
    expected = latest_expected_period(today)
    newest = pubs[-1].period
    if newest < expected:
        return (
            f"newest publication is {newest:%Y-%m} but {expected:%Y-%m} was "
            "expected; source may be late"
        )
    return None


if __name__ == "__main__":
    publications = discover()
    for publication in publications:
        print(f"{publication.period_key}  {publication.source:7}  {publication.url}")
    warning = check_freshness(publications)
    if warning:
        print(f"\nWARNING: {warning}")
