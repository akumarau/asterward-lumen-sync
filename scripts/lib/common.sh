#!/usr/bin/env bash
# common.sh
# Shared helpers sourced by every phase script.
# Centralises exFAT-safe file scanning, config loading, and logging.

# Resolve project root from this file's location, regardless of caller cwd.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_LIB_DIR/../.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config/migration.env}"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

TARGET_ROOT="${TARGET_ROOT:-/Volumes/TOSHIBA_AK/iCloud_Import}"
CREATOR="${CREATOR:-Your Name}"
CREATOR_LOCATION="${CREATOR_LOCATION:-City, Country}"
CREATOR_COUNTRY_CODE="${CREATOR_COUNTRY_CODE:-AUS}"
RIGHTS_URL="${RIGHTS_URL:-}"

ts() { date -u +%FT%TZ; }

log() {
    local msg="[$(ts)] $*"
    echo "$msg"
    if [[ -n "${LOG_FILE:-}" && -d "$(dirname "$LOG_FILE")" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
    if [[ -d "$TARGET_ROOT/logs" ]]; then
        echo "$msg" >> "$TARGET_ROOT/logs/agent.log"
    fi
}

die() { log "ERROR: $*"; exit 1; }

# macOS and Windows both litter exFAT volumes with metadata files. AppleDouble
# (._*) companions are created for any file carrying extended attributes, so a
# naive `find -type f` overcounts the corpus by up to 2x and feeds junk into
# exiftool and fdupes. icloudpd also leaves *.part files for in-flight or
# interrupted downloads, which are not corpus members either.
# Every phase must scan through this wrapper.
corpus_find() {
    local root="$1"; shift
    find "$root" \
        \( -name '.Spotlight-V100' -o -name '.fseventsd' -o -name '.Trashes' \
           -o -name '.TemporaryItems' -o -name '.DocumentRevisions-V100' \
           -o -name '$RECYCLE.BIN' -o -name 'System Volume Information' \) -prune -o \
        -type f \
        ! -name '._*' ! -name '.DS_Store' ! -name '.localized' ! -name '.apDisk' \
        ! -name '*.part' \
        "$@" -print0
}

# Counts NUL separators rather than lines, so filenames containing newlines
# cannot skew the totals that phase success criteria depend on.
corpus_count() {
    corpus_find "$@" | tr -cd '\0' | wc -c | tr -d ' '
}

IMAGE_EXT_FIND=(
    -iname '*.heic' -o -iname '*.heif' -o -iname '*.jpg' -o -iname '*.jpeg'
    -o -iname '*.arw' -o -iname '*.dng' -o -iname '*.cr2' -o -iname '*.cr3'
    -o -iname '*.nef' -o -iname '*.orf' -o -iname '*.raf' -o -iname '*.rw2'
    -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.png' -o -iname '*.gif'
)

# Formats where Lightroom Classic reads an adjacent .xmp sidecar.
RAW_EXTS=(arw dng cr2 cr3 nef orf raf rw2)
# Formats where LRC ignores sidecars and only reads metadata embedded in the file.
EMBED_EXTS=(heic heif jpg jpeg tif tiff png)

require_mount() {
    local vol
    vol="$(echo "$TARGET_ROOT" | cut -d/ -f1-3)"
    [[ -d "$vol" ]] || die "Target volume $vol is not mounted."
}

# exFAT is intentional here so the drive stays readable on Windows. Phases that
# assume case sensitivity or POSIX semantics must degrade gracefully instead.
detect_fs() {
    local vol
    vol="$(echo "$TARGET_ROOT" | cut -d/ -f1-3)"
    mount | awk -v v="$vol" '$3 == v {gsub(/[(),]/, "", $4); print $4; exit}'
}

check_free_space() {
    local need_gb="${1:-100}" free_gb
    free_gb=$(df -g "$TARGET_ROOT" | awk 'NR==2 {print $4}')
    log "Free space on target: ${free_gb} GB (minimum ${need_gb} GB)"
    (( free_gb >= need_gb )) || die "Only ${free_gb} GB free, need ${need_gb} GB."
}
