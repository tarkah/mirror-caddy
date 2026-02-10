#!/usr/bin/env bash

set -euo pipefail

# Configuration
VERBOSE=0
BASE_URL=""
DOWNLOAD_DIR="."

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        -v*)
            # Count number of v's
            opt="${1#-}"
            VERBOSE=${#opt}
            shift
            ;;
        --verbose)
            ((VERBOSE++))
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$BASE_URL" ]]; then
                BASE_URL="$1"
            elif [[ "$DOWNLOAD_DIR" == "." ]]; then
                DOWNLOAD_DIR="$1"
            else
                echo "Too many arguments" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

METADATA_DIR="${DOWNLOAD_DIR}/.metadata"
PARALLEL_JOBS="${PARALLEL_JOBS:-8}"
TEMP_FILE_LIST="/tmp/mirror-caddy-files-$$.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;96m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

debug() {
    if [[ $VERBOSE -ge 1 ]]; then
        printf "\r\033[K" >&2  # Clear spinner line if active
        echo -e "${MAGENTA}[DEBUG]${NC} $*" >&2
    fi
}

trace() {
    if [[ $VERBOSE -ge 2 ]]; then
        printf "\r\033[K" >&2  # Clear spinner line if active
        echo -e "${CYAN}[TRACE]${NC} $*" >&2
    fi
}

# Spinner variables
SPINNER_ACTIVE=0
SPINNER_PID=""
SPINNER_FILE=""

# Start spinner that monitors file count in temp file
start_spinner() {
    local temp_file="$1"
    SPINNER_ACTIVE=1
    SPINNER_FILE="/tmp/spinner-$$-active.txt"
    touch "$SPINNER_FILE"

    # Background process to animate spinner
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while [[ -f "$SPINNER_FILE" ]]; do
            local count=0
            if [[ -f "$temp_file" ]]; then
                count=$(wc -l < "$temp_file" 2>/dev/null || echo "0")
            fi
            printf "\r${GREEN}[INFO]${NC} %s Enumerating files... %d found" "${frames[$i]}" "$count" >&2
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
        done
        printf "\r\033[K" >&2  # Clear line
    ) &
    SPINNER_PID=$!
}

# Stop spinner
stop_spinner() {
    if [[ $SPINNER_ACTIVE -eq 1 && -n "$SPINNER_PID" ]]; then
        rm -f "$SPINNER_FILE"
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_ACTIVE=0
        SPINNER_PID=""
    fi
}

usage() {
    cat <<EOF
Usage: $0 [options] <base-url> [download-dir]

Mirror files from a Caddy file server with browse enabled.

Arguments:
  base-url      Base URL of the Caddy file server (e.g., http://localhost:8080)
  download-dir  Local directory to download files to (default: current directory)

Options:
  -v, --verbose Enable verbose/debug output (use -vv for trace level with curl debugging)

Environment:
  PARALLEL_JOBS Number of parallel downloads (default: 8)

Examples:
  $0 http://localhost:8080 ./mirror
  $0 -v http://localhost:8080 ./mirror
  $0 -vv http://localhost:8080 ./mirror
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

# Wrapper function to execute curl with trace logging
run_curl() {
    trace "Executing: curl $(printf '%q ' "$@")"
    curl "$@" 2>&1
}

# Check arguments
if [[ -z "$BASE_URL" ]]; then
    usage
fi

# Check dependencies
check_dependency jq

# Create directories
mkdir -p "$DOWNLOAD_DIR" "$METADATA_DIR"

# Clean up on exit
cleanup() {
    stop_spinner
    rm -f "$TEMP_FILE_LIST"
}
trap cleanup EXIT INT TERM

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

    debug "Fetching directory listing: $url"

    # Fetch JSON listing from Caddy
    local json_response
    if ! json_response=$(run_curl -sf -H "Accept: application/json" "$url"); then
        error "Failed to fetch directory listing from $url"
        return 1
    fi

    # Process files (output immediately)
    echo "$json_response" | jq -r '.[] | select(.is_dir == false) | @json' | while IFS= read -r entry; do
        local name=$(echo "$entry" | jq -r '.name')
        local url_path=$(echo "$entry" | jq -r '.url')

        # Skip . and .. entries
        if [[ "$name" == "." || "$name" == ".." ]]; then
            continue
        fi

        # Normalize URL path by removing leading ./
        url_path="${url_path#./}"

        # Strip trailing slashes from name
        name="${name%/}"

        local full_path="${path_prefix}${name}"
        debug "Found file: ${full_path} -> ${url}${url_path}"
        echo -e "${full_path}\t${url}${url_path}"
    done

    # Process directories in parallel
    echo "$json_response" | jq -r '.[] | select(.is_dir == true) | @json' | while IFS= read -r entry; do
        local name=$(echo "$entry" | jq -r '.name')
        local url_path=$(echo "$entry" | jq -r '.url')

        # Skip . and .. entries
        if [[ "$name" == "." || "$name" == ".." ]]; then
            continue
        fi

        # Normalize URL path by removing leading ./
        url_path="${url_path#./}"

        # Strip trailing slashes from name
        name="${name%/}"

        local full_path="${path_prefix}${name}"
        local dir_url="${url}${url_path}"

        echo -e "${dir_url}\t${full_path}/"
    done | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
        IFS=$'\''\t'\'' read -r dir_url dir_path <<< "{}"
        enumerate_files "$dir_url" "$dir_path"
    '
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
            curl_args+=(-H "If-None-Match: \"$cached_etag\"")
        fi

        if [[ -n "$cached_last_modified" && "$cached_last_modified" != "null" ]]; then
            curl_args+=(-H "If-Modified-Since: $cached_last_modified")
        fi
    fi

    # Download file and capture headers
    local headers
    if headers=$(run_curl "${curl_args[@]}" "$url"); then
        local http_code=$(echo "$headers" | grep -i '^HTTP/' | tail -n1 | awk '{print $2}')

        if [[ $VERBOSE -ge 2 ]]; then
            trace "HTTP Status: $http_code"
            trace "Response Headers:"
            echo "$headers" | while IFS= read -r line; do
                [[ -n "$line" ]] && trace "  $line"
            done
        fi

        if [[ "$http_code" == "304" ]]; then
            info "⏭️  ${MAGENTA}Unmodified${NC}: $file_path"
            return 0
        fi

        # Extract and save headers
        local etag=$(echo "$headers" | grep -i '^etag:' | cut -d: -f2- | tr -d '\r' | xargs)
        local last_modified=$(echo "$headers" | grep -i '^last-modified:' | cut -d: -f2- | tr -d '\r' | xargs)

        save_headers "$file_path" "$etag" "$last_modified"
        info "⬇️  ${GREEN}Downloaded${NC}: $file_path"
    else
        error "Failed to download: $file_path"
        return 1
    fi
}

# Export functions for use in subshells
export -f enumerate_files download_file save_headers run_curl info error warn debug trace
export BASE_URL DOWNLOAD_DIR METADATA_DIR PARALLEL_JOBS GREEN RED YELLOW MAGENTA CYAN NC VERBOSE

# Main execution
info "Starting mirror from $BASE_URL to $DOWNLOAD_DIR"

if [[ $VERBOSE -eq 0 ]]; then
    start_spinner "$TEMP_FILE_LIST"
fi

# Enumerate all files
enumerate_files "$BASE_URL/" "" > "$TEMP_FILE_LIST"

if [[ $VERBOSE -eq 0 ]]; then
    stop_spinner
fi

# Count files
file_count=$(wc -l < "$TEMP_FILE_LIST")
info "Found $file_count files to process"

if [[ $file_count -eq 0 ]]; then
    info "No files to download"
    exit 0
fi

# Download files in parallel
info "Downloading files with $PARALLEL_JOBS parallel jobs..."
cat "$TEMP_FILE_LIST" | xargs -P "$PARALLEL_JOBS" -I {} bash -c '
    IFS=$'\''\t'\'' read -r file_path url <<< "{}"
    download_file "$file_path" "$url"
'

info "Mirror complete!"
