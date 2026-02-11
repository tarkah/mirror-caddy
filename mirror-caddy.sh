#!/usr/bin/env bash
set -euo pipefail

# ── Option parsing ──────────────────────────────────────────────────────────

VERBOSE=0
BASE_URL=""
DOWNLOAD_DIR=""
SHOW_HELP=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -v*)
            opt="${1#-}"
            if [[ ! "$opt" =~ ^v+$ ]]; then
                echo "Unknown option: $1" >&2
                exit 1
            fi
            VERBOSE=${#opt}
            shift
            ;;
        --verbose)
            ((VERBOSE++))
            shift
            ;;
        -h|--help)
            SHOW_HELP=1
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$BASE_URL" ]]; then
                BASE_URL="$1"
            elif [[ -z "$DOWNLOAD_DIR" ]]; then
                DOWNLOAD_DIR="$1"
            else
                echo "Too many arguments" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# ── Configuration ───────────────────────────────────────────────────────────

DOWNLOAD_DIR="${DOWNLOAD_DIR:-.}"
METADATA_DIR="${DOWNLOAD_DIR}/.metadata"
PARALLEL_JOBS="${PARALLEL_JOBS:-8}"
BASE_URL="${BASE_URL%/}"

TEMP_FILE_LIST=$(mktemp "/tmp/mirror-caddy.XXXXXX")
RESULTS_FILE=$(mktemp "/tmp/mirror-caddy-results.XXXXXX")

# ── Colors ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;96m'
NC='\033[0m'

# ── Logging ─────────────────────────────────────────────────────────────────

info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }

debug() {
    [[ $VERBOSE -ge 1 ]] || return 0
    printf '\r\033[K' >&2
    echo -e "${MAGENTA}[DEBUG]${NC} $*" >&2
}

trace() {
    [[ $VERBOSE -ge 2 ]] || return 0
    printf '\r\033[K' >&2
    echo -e "${CYAN}[TRACE]${NC} $*" >&2
}

# ── Spinner ─────────────────────────────────────────────────────────────────

SPINNER_PID=""
SPINNER_SENTINEL=""

start_spinner() {
    [[ $VERBOSE -eq 0 ]] || return 0
    local count_file="$1"
    SPINNER_SENTINEL=$(mktemp "/tmp/mirror-caddy-spinner.XXXXXX")
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while [[ -f "$SPINNER_SENTINEL" ]]; do
            local count=0
            [[ -f "$count_file" ]] && count=$(wc -l < "$count_file" 2>/dev/null || echo 0)
            printf "\r${GREEN}[INFO]${NC} %s Enumerating files... %d found" "${frames[$i]}" "$count" >&2
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
        done
        printf '\r\033[K' >&2
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    [[ -n "$SPINNER_PID" ]] || return 0
    rm -f "$SPINNER_SENTINEL"
    wait "$SPINNER_PID" 2>/dev/null
    SPINNER_PID=""
    SPINNER_SENTINEL=""
}

# ── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: ${0##*/} [options] <base-url> [download-dir]

Mirror files from a Caddy file server with browse enabled.

Arguments:
  base-url       URL of the Caddy file server
  download-dir   Local directory to save files (default: .)

Options:
  -v             Debug output (-vv for trace with curl details)
  --verbose      Increment verbosity level
  -h, --help     Show this help

Environment:
  PARALLEL_JOBS  Number of parallel jobs (default: 8)

Examples:
  ${0##*/} https://example.com ./mirror
  ${0##*/} -v https://example.com ./mirror
  ${0##*/} -vv https://example.com ./mirror
  PARALLEL_JOBS=16 ${0##*/} https://example.com ./mirror
EOF
    exit 0
}

# ── Utilities ───────────────────────────────────────────────────────────────

check_dependency() {
    if ! command -v "$1" &>/dev/null; then
        error "$1 is required but not installed. Please install $1 and try again."
        exit 1
    fi
}

run_curl() {
    trace "curl $(printf '%q ' "$@")"
    curl "$@"
}

# ── Validation ──────────────────────────────────────────────────────────────

[[ $SHOW_HELP -eq 1 ]] && usage
[[ -n "$BASE_URL" ]] || usage

check_dependency jq
check_dependency curl

mkdir -p "$DOWNLOAD_DIR" "$METADATA_DIR"

# ── Cleanup ─────────────────────────────────────────────────────────────────

cleanup() {
    stop_spinner
    rm -f "$TEMP_FILE_LIST" "$RESULTS_FILE"
}
trap cleanup EXIT

# ── Caching ─────────────────────────────────────────────────────────────────

save_headers() {
    local file_path="$1" etag="$2" last_modified="$3"
    local metadata_file="${METADATA_DIR}/${file_path}.meta"
    mkdir -p "$(dirname "$metadata_file")"
    printf 'etag=%s\nlast_modified=%s\n' "$etag" "$last_modified" > "$metadata_file"
}

# ── Enumeration ─────────────────────────────────────────────────────────────

enumerate_files() {
    local url="${1%/}/" path_prefix="$2"

    debug "Fetching directory listing: $url"

    local json_response
    if ! json_response=$(run_curl -sf -H "Accept: application/json" "$url"); then
        error "Failed to fetch directory listing from $url"
        return 1
    fi

    local dirs=()

    # Single jq pass: extract type, name, and url for each entry
    while IFS=$'\t' read -r is_dir name url_path; do
        url_path="${url_path#./}"
        name="${name%/}"
        local full_path="${path_prefix}${name}"

        if [[ "$is_dir" == "true" ]]; then
            dirs+=("${url}${url_path}" "${full_path}/")
        else
            debug "Found file: ${full_path} -> ${url}${url_path}"
            printf '%s\t%s\n' "$full_path" "${url}${url_path}"
        fi
    done < <(echo "$json_response" | jq -r '.[] | select(.name != "." and .name != "..") | [(.is_dir | tostring), .name, .url] | @tsv')

    # Recurse into directories in parallel
    if [[ ${#dirs[@]} -gt 0 ]]; then
        printf '%s\0' "${dirs[@]}" | xargs -0 -n2 -P "$PARALLEL_JOBS" bash -c 'enumerate_files "$1" "$2"' _
    fi
}

# ── Download ────────────────────────────────────────────────────────────────

download_file() {
    local file_path="$1" url="$2"
    local local_file="${DOWNLOAD_DIR}/${file_path}"
    local temp_file="${local_file}.tmp"
    local metadata_file="${METADATA_DIR}/${file_path}.meta"

    mkdir -p "$(dirname "$local_file")"

    # Headers to stdout (-D -), body to temp file (-o)
    local curl_args=(-sf -D - -o "$temp_file")

    # Add conditional request headers from cache
    if [[ -f "$metadata_file" ]]; then
        local cached_etag cached_last_modified
        cached_etag=$(grep '^etag=' "$metadata_file" | cut -d= -f2-)
        cached_last_modified=$(grep '^last_modified=' "$metadata_file" | cut -d= -f2-)

        if [[ -n "$cached_etag" && "$cached_etag" != "null" ]]; then
            curl_args+=(-H "If-None-Match: $cached_etag")
        fi
        if [[ -n "$cached_last_modified" && "$cached_last_modified" != "null" ]]; then
            curl_args+=(-H "If-Modified-Since: $cached_last_modified")
        fi
    fi

    local headers http_code
    if headers=$(run_curl "${curl_args[@]}" "$url"); then
        http_code=$(echo "$headers" | grep -i '^HTTP/' | tail -n1 | awk '{print $2}')

        if [[ $VERBOSE -ge 2 ]]; then
            trace "HTTP $http_code for $file_path"
            while IFS= read -r line; do
                [[ -n "$line" ]] && trace "  $line"
            done <<< "$headers"
        fi

        if [[ "$http_code" == "304" ]]; then
            rm -f "$temp_file"
            echo skipped >> "$RESULTS_FILE"
            local progress
            progress=$(wc -l < "$RESULTS_FILE" 2>/dev/null || echo '?')
            info "[${progress}/${TOTAL_FILES}] ⏭️  ${MAGENTA}Unmodified${NC}: $file_path"
            return 0
        fi

        mv -f "$temp_file" "$local_file"

        # Extract and cache headers (preserve values as-is, only trim whitespace)
        local etag last_modified
        etag=$(echo "$headers" | sed -n 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//p' | tr -d '\r')
        last_modified=$(echo "$headers" | sed -n 's/^[Ll]ast-[Mm]odified:[[:space:]]*//p' | tr -d '\r')

        save_headers "$file_path" "$etag" "$last_modified"

        echo downloaded >> "$RESULTS_FILE"
        local progress
        progress=$(wc -l < "$RESULTS_FILE" 2>/dev/null || echo '?')
        info "[${progress}/${TOTAL_FILES}] ⬇️  ${GREEN}Downloaded${NC}: $file_path"
    else
        rm -f "$temp_file"
        echo failed >> "$RESULTS_FILE"
        local progress
        progress=$(wc -l < "$RESULTS_FILE" 2>/dev/null || echo '?')
        error "[${progress}/${TOTAL_FILES}] Failed to download: $file_path"
        return 1
    fi
}

# ── Exports for subshells ──────────────────────────────────────────────────

export -f enumerate_files download_file save_headers run_curl
export -f info error warn debug trace
export BASE_URL DOWNLOAD_DIR METADATA_DIR PARALLEL_JOBS RESULTS_FILE
export GREEN RED YELLOW MAGENTA CYAN NC VERBOSE

# ── Main ────────────────────────────────────────────────────────────────────

info "Starting mirror from $BASE_URL to $DOWNLOAD_DIR"

start_spinner "$TEMP_FILE_LIST"
enumerate_files "${BASE_URL}/" "" > "$TEMP_FILE_LIST"
stop_spinner

TOTAL_FILES=$(wc -l < "$TEMP_FILE_LIST")
export TOTAL_FILES

info "Found $TOTAL_FILES files to process"

if [[ $TOTAL_FILES -eq 0 ]]; then
    info "No files to download"
    exit 0
fi

info "Downloading $TOTAL_FILES files with $PARALLEL_JOBS parallel jobs..."

awk -F'\t' '{printf "%s\0%s\0", $1, $2}' "$TEMP_FILE_LIST" \
    | xargs -0 -n2 -P "$PARALLEL_JOBS" bash -c 'download_file "$1" "$2"' _ \
    || true

# Summary
downloaded=$(grep -c '^downloaded$' "$RESULTS_FILE" 2>/dev/null || echo 0)
skipped=$(grep -c '^skipped$' "$RESULTS_FILE" 2>/dev/null || echo 0)
failed=$(grep -c '^failed$' "$RESULTS_FILE" 2>/dev/null || echo 0)

info "Mirror complete: $downloaded downloaded, $skipped unchanged, $failed failed"

[[ "$failed" -eq 0 ]]
