# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Single-file bash script (`mirror-caddy.sh`) that mirrors files from Caddy file servers with `file_server { browse }` enabled. It enumerates directories via Caddy's JSON API, downloads leaf files in parallel, and caches ETag/Last-Modified headers for incremental updates (HTTP 304).

## Running

```bash
./mirror-caddy.sh https://example.com ./output       # basic usage
./mirror-caddy.sh -v https://example.com ./output     # debug logging
./mirror-caddy.sh -vv https://example.com ./output    # trace logging (curl details)
PARALLEL_JOBS=16 ./mirror-caddy.sh https://example.com ./output
```

## Testing

No test suite. Validate with `bash -n mirror-caddy.sh` for syntax, then test against a live Caddy server (e.g., `https://build.aerynos.dev`). Run twice to verify 304 caching behavior.

## Architecture

The script uses `export -f` to make functions available in `xargs -P` subshells for parallel execution. Key data flow:

1. **Enumerate** (`enumerate_files`) — Recursively fetches Caddy JSON listings, outputs tab-separated `path\turl` lines. Directories recurse in parallel via `xargs -0 -n2 -P`.
2. **Download** (`download_file`) — Downloads to `.tmp` file, moves into place on success. Sends `If-None-Match`/`If-Modified-Since` from cached `.metadata/*.meta` files.

All inter-process data is passed via NUL-delimited `xargs -0` to prevent shell injection. The spinner runs as a background process controlled by a sentinel file.

## Dependencies

`bash` (4+), `curl`, `jq`

## VCS

Uses jujutsu (`jj`) with git backend.
