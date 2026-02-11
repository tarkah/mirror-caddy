#!/usr/bin/env python3
"""Mirror files from a Caddy file server with browse enabled."""

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

try:
    import aiohttp
except ImportError:
    print("Error: aiohttp is required. Install with: pip install aiohttp", file=sys.stderr)
    sys.exit(1)


# ── Terminal output ──────────────────────────────────────────────────────────

GREEN, RED, YELLOW, MAGENTA, CYAN, NC = (
    "\033[0;32m", "\033[0;31m", "\033[1;33m", "\033[0;35m", "\033[0;96m", "\033[0m",
)

_output_lock = asyncio.Lock()
_spinner_live = False
_verbose = 0


async def _emit(msg):
    async with _output_lock:
        if _spinner_live:
            sys.stderr.write("\r\033[K")
        sys.stderr.write(msg + "\n")
        sys.stderr.flush()


async def info(msg):
    await _emit(f"{GREEN}[INFO]{NC} {msg}")


async def error(msg):
    await _emit(f"{RED}[ERROR]{NC} {msg}")


async def debug(msg):
    if _verbose >= 1:
        await _emit(f"{MAGENTA}[DEBUG]{NC} {msg}")


async def trace(msg):
    if _verbose >= 2:
        await _emit(f"{CYAN}[TRACE]{NC} {msg}")


# ── Spinner ──────────────────────────────────────────────────────────────────

_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


async def _spin(counter, stop_event):
    global _spinner_live
    _spinner_live = True
    i = 0
    try:
        while not stop_event.is_set():
            async with _output_lock:
                sys.stderr.write(
                    f"\r{GREEN}[INFO]{NC} {_FRAMES[i % len(_FRAMES)]}"
                    f" Enumerating files... {counter.value} found"
                )
                sys.stderr.flush()
            i += 1
            await asyncio.sleep(0.1)
    finally:
        _spinner_live = False
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()


# ── Helpers ──────────────────────────────────────────────────────────────────


class Counter:
    """Thread-safe counter for asyncio (no lock needed - single threaded)."""
    def __init__(self):
        self._n = 0

    def add(self, n=1):
        self._n += n
        return self._n

    @property
    def value(self):
        return self._n


def read_metadata(path):
    """Read cached ETag/Last-Modified from metadata file."""
    meta = {}
    if path.exists():
        for line in path.read_text().splitlines():
            k, _, v = line.partition("=")
            if v and v != "null":
                meta[k] = v
    return meta


def save_metadata(path, etag, last_modified):
    """Save ETag/Last-Modified to metadata file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"etag={etag}\nlast_modified={last_modified}\n")


# ── Enumeration ──────────────────────────────────────────────────────────────


async def _fetch_dir(session, url, prefix):
    """Fetch one directory listing. Returns (files, subdirs) as (path, url) pairs."""
    url = url.rstrip("/") + "/"
    await debug(f"Fetching directory listing: {url}")
    await trace(f"GET {url} Accept: application/json")

    try:
        async with session.get(url, headers={"Accept": "application/json"}) as resp:
            resp.raise_for_status()
            entries = await resp.json()
    except Exception as e:
        await error(f"Failed to fetch directory listing from {url}: {e}")
        return [], []

    files, subdirs = [], []
    for entry in entries:
        name = entry.get("name", "").rstrip("/")
        url_path = entry.get("url", "")
        if name in (".", ".."):
            continue
        if url_path.startswith("./"):
            url_path = url_path[2:]

        full_path = f"{prefix}{name}"
        full_url = f"{url}{url_path}"

        if entry.get("is_dir"):
            subdirs.append((full_url, f"{full_path}/"))
        else:
            await debug(f"Found file: {full_path} -> {full_url}")
            files.append((full_path, full_url))

    return files, subdirs


async def enumerate_files(session, base_url, counter):
    """Recursive parallel enumeration with unlimited concurrency."""
    all_files = []

    async def _process(url, prefix):
        found, subdirs = await _fetch_dir(session, url, prefix)
        all_files.extend(found)
        counter.add(len(found))

        # Recurse into subdirectories concurrently
        if subdirs:
            await asyncio.gather(*[_process(sub_url, sub_prefix) for sub_url, sub_prefix in subdirs])

    await _process(f"{base_url}/", "")
    return all_files


# ── Download ─────────────────────────────────────────────────────────────────


async def download_file(session, file_path, url, download_dir, metadata_dir, progress, total):
    """Download one file with conditional caching. Returns result status string."""
    local_file = download_dir / file_path
    temp_file = local_file.with_name(local_file.name + ".tmp")
    meta_file = metadata_dir / f"{file_path}.meta"

    local_file.parent.mkdir(parents=True, exist_ok=True)

    headers = {}
    meta = read_metadata(meta_file)
    if meta.get("etag"):
        headers["If-None-Match"] = meta["etag"]
    if meta.get("last_modified"):
        headers["If-Modified-Since"] = meta["last_modified"]

    await trace(f"GET {url}" + "".join(f" {k}: {v}" for k, v in headers.items()))

    try:
        async with session.get(url, headers=headers) as resp:
            if resp.status == 304:
                temp_file.unlink(missing_ok=True)
                n = progress.add()
                await info(f"[{n}/{total}] ⏭️  {MAGENTA}Unmodified{NC}: {file_path}")
                return "skipped"

            resp.raise_for_status()

            # Write to temp file
            content = await resp.read()
            temp_file.write_bytes(content)
            temp_file.replace(local_file)

            etag = resp.headers.get("ETag", "")
            last_modified = resp.headers.get("Last-Modified", "")

            if _verbose >= 2:
                await trace(f"HTTP {resp.status} for {file_path}")
                for k, v in resp.headers.items():
                    await trace(f"  {k}: {v}")

            save_metadata(meta_file, etag, last_modified)

            n = progress.add()
            await info(f"[{n}/{total}] ⬇️  {GREEN}Downloaded{NC}: {file_path}")
            return "downloaded"

    except Exception as e:
        temp_file.unlink(missing_ok=True)
        n = progress.add()
        await error(f"[{n}/{total}] Failed to download {file_path}: {e}")
        return "failed"


# ── Main ─────────────────────────────────────────────────────────────────────


async def async_main():
    global _verbose, _output_lock

    parser = argparse.ArgumentParser(
        description="Mirror files from a Caddy file server with browse enabled.",
        epilog="Environment:\n  PARALLEL_JOBS  Max concurrent downloads (default: 50)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("base_url", metavar="base-url",
                        help="URL of the Caddy file server")
    parser.add_argument("download_dir", metavar="download-dir", nargs="?", default=".",
                        help="local directory to save files (default: .)")
    parser.add_argument("-v", "--verbose", action="count", default=0,
                        help="debug output (-vv for trace)")
    args = parser.parse_args()

    _verbose = args.verbose
    base_url = args.base_url.rstrip("/")
    download_dir = Path(args.download_dir)
    metadata_dir = download_dir / ".metadata"
    max_concurrent = int(os.environ.get("PARALLEL_JOBS", "50"))

    download_dir.mkdir(parents=True, exist_ok=True)
    metadata_dir.mkdir(parents=True, exist_ok=True)

    # Initialize async lock
    _output_lock = asyncio.Lock()

    await info(f"Starting mirror from {base_url} to {download_dir}")

    # ── Enumerate ────────────────────────────────────────────────────────────

    file_counter = Counter()
    spinner_task = None

    connector = aiohttp.TCPConnector(limit=max_concurrent, limit_per_host=max_concurrent)
    timeout = aiohttp.ClientTimeout(total=300, connect=60)

    async with aiohttp.ClientSession(
        connector=connector,
        timeout=timeout,
        headers={"User-Agent": "mirror-caddy/2.0-asyncio"}
    ) as session:

        if _verbose == 0:
            spinner_stop = asyncio.Event()
            spinner_task = asyncio.create_task(_spin(file_counter, spinner_stop))

        files = await enumerate_files(session, base_url, file_counter)

        if _verbose == 0:
            spinner_stop.set()
            await spinner_task

        total = len(files)
        await info(f"Found {total} files to process")

        if total == 0:
            await info("No files to download")
            return

        # ── Download ─────────────────────────────────────────────────────────────

        await info(f"Downloading {total} files with max {max_concurrent} concurrent requests...")

        progress = Counter()

        # Use semaphore to limit concurrent downloads
        sem = asyncio.Semaphore(max_concurrent)

        async def _download_with_limit(fp, url):
            async with sem:
                return await download_file(session, fp, url, download_dir, metadata_dir, progress, total)

        results = await asyncio.gather(*[_download_with_limit(fp, url) for fp, url in files])

        downloaded = results.count("downloaded")
        skipped = results.count("skipped")
        failed = results.count("failed")

        await info(f"Mirror complete: {downloaded} downloaded, {skipped} unchanged, {failed} failed")

        if failed > 0:
            sys.exit(1)


def main():
    try:
        asyncio.run(async_main())
    except KeyboardInterrupt:
        sys.stderr.write("\r\033[K")
        os._exit(130)


if __name__ == "__main__":
    main()
