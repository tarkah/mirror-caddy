#!/usr/bin/env bash

set -euo pipefail

# Configuration
BASE_URL="${1:-}"
DOWNLOAD_DIR="${2:-.}"
METADATA_DIR="${DOWNLOAD_DIR}/.metadata"
PARALLEL_JOBS="${PARALLEL_JOBS:-8}"
TEMP_FILE_LIST="/tmp/mirror-caddy-files-$$.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

usage() {
    cat <<EOF
Usage: $0 <base-url> [download-dir]

Mirror files from a Caddy file server with browse enabled.

Arguments:
  base-url      Base URL of the Caddy file server (e.g., http://localhost:8080)
  download-dir  Local directory to download files to (default: current directory)

Environment:
  PARALLEL_JOBS Number of parallel downloads (default: 8)

Examples:
  $0 http://localhost:8080 ./mirror
  PARALLEL_JOBS=16 $0 http://example.com/files ./downloads
EOF
    exit 1
}

check_dependency() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        error "$cmd is required but not installed. Please install $cmd and try again."
        exit 1
    fi
}

# Check arguments
if [[ -z "$BASE_URL" ]]; then
    usage
fi

# Check dependencies
check_dependency jq

# Create directories
mkdir -p "$DOWNLOAD_DIR" "$METADATA_DIR"

# Clean up temp file on exit
trap 'rm -f "$TEMP_FILE_LIST"' EXIT

# Function to get cached headers for a file
get_cached_headers() {
    local file_path="$1"
    local metadata_file="${METADATA_DIR}/${file_path}.meta"

    if [[ -f "$metadata_file" ]]; then
        cat "$metadata_file"
    fi
}

# Function to save headers for a file
save_headers() {
    local file_path="$1"
    local etag="$2"
    local last_modified="$3"
    local metadata_file="${METADATA_DIR}/${file_path}.meta"

    mkdir -p "$(dirname "$metadata_file")"
    cat > "$metadata_file" <<EOF
etag=$etag
last_modified=$last_modified
EOF
}

# Function to recursively enumerate all files from a directory URL
enumerate_files() {
    local url="$1"
    local path_prefix="$2"

    log "Fetching directory listing: $url"

    # Fetch JSON listing from Caddy
    local json_response
    if ! json_response=$(curl -sf -H "Accept: application/json" "$url"); then
        error "Failed to fetch directory listing from $url"
        return 1
    fi

    # Parse JSON and process each entry
    echo "$json_response" | jq -r '.[] | @json' | while IFS= read -r entry; do
        local name=$(echo "$entry" | jq -r '.name')
        local is_dir=$(echo "$entry" | jq -r '.is_dir')
        local url_path=$(echo "$entry" | jq -r '.url')

        # Skip . and .. entries
        if [[ "$name" == "." || "$name" == ".." ]]; then
            continue
        fi

        # Normalize URL path by removing leading ./
        url_path="${url_path#./}"

        local full_path="${path_prefix}${name}"

        if [[ "$is_dir" == "true" ]]; then
            # Recursively process directory
            local dir_url="${url}${url_path}"
            enumerate_files "$dir_url" "${full_path}/"
        else
            # Output file path and URL (tab-separated)
            echo -e "${full_path}\t${url}${url_path}"
        fi
    done
}

# Function to download a single file with caching
download_file() {
    local file_path="$1"
    local url="$2"
    local local_file="${DOWNLOAD_DIR}/${file_path}"
    local metadata_file="${METADATA_DIR}/${file_path}.meta"

    # Create parent directory
    mkdir -p "$(dirname "$local_file")"

    # Prepare curl arguments
    local curl_args=(-sf -D /dev/stderr -o "$local_file")

    # Add cached headers if they exist
    if [[ -f "$metadata_file" ]]; then
        local cached_etag=$(grep '^etag=' "$metadata_file" | cut -d= -f2-)
        local cached_last_modified=$(grep '^last_modified=' "$metadata_file" | cut -d= -f2-)

        if [[ -n "$cached_etag" && "$cached_etag" != "null" ]]; then
            curl_args+=(-H "If-None-Match: $cached_etag")
        fi

        if [[ -n "$cached_last_modified" && "$cached_last_modified" != "null" ]]; then
            curl_args+=(-H "If-Modified-Since: $cached_last_modified")
        fi
    fi

    # Download file and capture headers
    local headers
    if headers=$(curl "${curl_args[@]}" "$url" 2>&1 >/dev/null); then
        local http_code=$(echo "$headers" | grep -i '^HTTP/' | tail -n1 | awk '{print $2}')

        if [[ "$http_code" == "304" ]]; then
            warn "Not modified: $file_path"
            return 0
        fi

        # Extract and save headers
        local etag=$(echo "$headers" | grep -i '^etag:' | cut -d: -f2- | tr -d '\r' | xargs)
        local last_modified=$(echo "$headers" | grep -i '^last-modified:' | cut -d: -f2- | tr -d '\r' | xargs)

        save_headers "$file_path" "$etag" "$last_modified"
        log "Downloaded: $file_path"
    else
        error "Failed to download: $file_path"
        return 1
    fi
}

# Export functions for use in subshells
export -f download_file save_headers log error warn
export BASE_URL DOWNLOAD_DIR METADATA_DIR GREEN RED YELLOW NC

# Main execution
log "Starting mirror from $BASE_URL to $DOWNLOAD_DIR"

# Enumerate all files
log "Enumerating files..."
enumerate_files "$BASE_URL/" "" > "$TEMP_FILE_LIST"

# Count files
file_count=$(wc -l < "$TEMP_FILE_LIST")
log "Found $file_count files to process"

if [[ $file_count -eq 0 ]]; then
    log "No files to download"
    exit 0
fi

# Download files in parallel
log "Downloading files with $PARALLEL_JOBS parallel jobs..."
cat "$TEMP_FILE_LIST" | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
    IFS=$'\''\t'\'' read -r file_path url <<< "{}"
    download_file "$file_path" "$url"
'

log "Mirror complete!"
