# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Mirrors files from Caddy file servers with `file_server { browse }` enabled. Two implementations: `mirror-caddy.sh` (bash) and `mirror-caddy.py` (Python asyncio). Both enumerate directories via Caddy's JSON API, download files in parallel, and cache ETag/Last-Modified headers for incremental updates (HTTP 304).

## Running

```bash
# Bash version
./mirror-caddy.sh https://example.com ./output
./mirror-caddy.sh -v https://example.com ./output       # debug
./mirror-caddy.sh -vv https://example.com ./output      # trace

# Python version
./mirror-caddy.py https://example.com ./output
./mirror-caddy.py -v https://example.com ./output
./mirror-caddy.py -vv https://example.com ./output

PARALLEL_JOBS=16 ./mirror-caddy.sh https://example.com ./output
```

## Testing

No test suite. Validate syntax (`bash -n mirror-caddy.sh` / `python3 -m py_compile mirror-caddy.py`), then test against a live Caddy server (e.g., `https://build.aerynos.dev`). Run twice to verify 304 caching behavior.

## Architecture

Both implementations share the same two-phase data flow:

1. **Enumerate** (`enumerate_files`) — Recursively fetches Caddy JSON listings. Uses DFS ordering so files from deep directories appear quickly (important for user feedback). Parallelized across directories.
2. **Download** (`download_file`) — Downloads to `.tmp` file, moves into place on success. Sends `If-None-Match`/`If-Modified-Since` from cached `.metadata/*.meta` files.

**Bash**: Uses `export -f` + `xargs -0 -n2 -P` for parallelism. NUL-delimited data prevents shell injection.

**Python**: Uses `asyncio` with `aiohttp` for high-concurrency I/O. Single-threaded event loop avoids GIL overhead. Concurrent enumeration via `asyncio.gather()`, downloads limited by semaphore (default 50 concurrent).

## Dependencies

- Bash version: `bash` (4+), `curl`, `jq`
- Python version: Python 3.7+, `aiohttp` (`pip install aiohttp`)

## VCS

Uses jujutsu (`jj`) with git backend.
