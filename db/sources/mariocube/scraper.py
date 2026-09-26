"""
MarioCube source plugin.

archive.mariocube.com serves a plain-text directory listing to curl-style
User-Agents. Strip ANSI colour, split into (size, filename), emit entries.
"""
import html
import re
import urllib.parse

from utils import cache_manager
from utils.scrape_utils import fetch_url, create_scraper_session
from utils.parse_utils import size_str_to_bytes, join_urls

from typing import Any, Generator
from core.contract import BuildContext, PlatformConfig, SourceManifest


HOST_NAME = 'MarioCube'

# Curl-like headers to get plain-text directory listing instead of HTML
CURL_HEADERS = {
    'User-Agent': 'curl/8.0',
    'Accept': '*/*'
}


def extract_entries(response: str, source: dict[str, Any], platform: str, base_url: str) -> list[dict[str, Any]]:
    """Extract entries from the ANSI-colored directory listing response."""
    entries = []

    for filename, size_str in parse_listing_lines(response):
        match = re.match(source['filter'], filename)
        if not match:
            continue

        title = match.group(1)
        encoded_link = urllib.parse.quote(filename)
        entries.append(create_entry(
            encoded_link, filename, title, size_str, source, platform, base_url))

    return entries


def create_entry(link: str, filename: str, title: str, size_str: str, source: dict[str, Any], platform: str, base_url: str) -> dict[str, Any]:
    """Create a dictionary representing a single entry."""
    name = html.unescape(title)
    size = size_str_to_bytes(size_str)
    url = join_urls(base_url, link)

    return {
        'title': name,
        'platform': platform,
        'regions': source['regions'],
        'links': [
            {
                'name': name,
                'type': source['type'],
                'format': source['format'],
                'url': url,
                'filename': filename,
                'host': HOST_NAME,
                'size': size,
                'size_str': size_str,
                'source_url': base_url
            }
        ]
    }


def parse_listing_lines(response: str) -> Generator[tuple[str, str], None, None]:
    """Yield filename and size pairs from the raw listing response."""
    for raw_line in response.splitlines():
        line = re.compile(r'\x1B\[[0-?]*[ -/]*[@-~]').sub('', raw_line).strip()
        if not line or line.startswith('#'):
            continue

        parts = line.split(maxsplit=2)
        if len(parts) < 3:
            continue

        _, size_str, filename = parts
        yield filename, size_str


def fetch_response(url: str, use_cached: bool, session: Any = None) -> str | None:
    """Fetch the response from a URL, optionally using a cached version."""
    url_stripped = url.rstrip('/')
    short_url = url_stripped.split('/')[-1][:50] if '/' in url_stripped else url_stripped[:50]

    if use_cached:
        response = cache_manager.get_cached_response(url)
        if response:
            print(f"      {short_url}... cached")
            return response

    # Fetch the URL directly if no cached response is available
    return fetch_url(url, session=session)


def scrape(source: dict[str, Any], platform: str, use_cached: bool = False) -> list[dict[str, Any]]:
    """Scrape entries from MarioCube based on the source configuration."""
    entries = []
    session = create_scraper_session(CURL_HEADERS)

    for url in source['urls']:
        # Fetch the response for each URL
        response = fetch_response(url, use_cached, session=session)
        if not response:
            print(f"Warning: Failed to get response from {url}, skipping...")
            continue

        # Extract entries from the response
        parsed_entries = extract_entries(response, source, platform, url)
        if not parsed_entries:
            print(f"Warning: No entries parsed from {url}, skipping...")
            continue

        entries.extend(parsed_entries)

    return entries


class MarioCubeSource:
    """Adapter from the plugin contract to the legacy scrape()."""

    def __init__(self, manifest: SourceManifest):
        self.manifest = manifest

    def scrape(
        self,
        platform: str,
        config: PlatformConfig,
        ctx: BuildContext,
    ) -> list[dict[str, Any]]:
        return scrape(config.to_legacy_dict(), platform, ctx.use_cached)


SOURCE = MarioCubeSource
