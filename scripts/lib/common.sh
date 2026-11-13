#!/usr/bin/env bash
# common.sh
# Shared helpers sourced by every Asterward Lumen Sync phase script.
# Centralises exFAT-safe file scanning, config loading, and logging.
#
# Compatibility: must run under macOS /bin/bash 3.2, which launchd uses.
# Under bash 3.2 with `set -u`, expanding an EMPTY array as "${arr[@]}" aborts
# with "unbound variable". Always expand arrays that can be empty with
# ${arr[@]+"${arr[@]}"}.

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

# icloudpd version the scripts were verified against. Its CLI and its
# existing-file matching both change between releases.
ICLOUDPD_VERSION="${ICLOUDPD_VERSION:-1.33.0}"

# Writing metadata INTO originals changes their size. icloudpd decides whether a
# file is already downloaded by comparing on-disk size with the iCloud size, so
# any later extract or delta run re-downloads every modified file under a new
# "-<bytes>" name. Off by default: apply copyright with an LRC import preset.
EMBED_METADATA="${EMBED_METADATA:-0}"

# Opt in to icloudpd --adp-web-access (icloudpd 1.33+) instead of turning
# Advanced Data Protection off. Untested against a live ADP account.
ADP_WEB_ACCESS="${ADP_WEB_ACCESS:-0}"

ts() { date -u +%FT%TZ; }

log() {
    local msg
    msg="[$(ts)] $*"
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
    # shellcheck disable=SC2016  # literal $RECYCLE.BIN, not a variable
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

# Formats where Lightroom Classic reads an adjacent .xmp sidecar.
# DNG is deliberately absent: LRC reads metadata embedded in a DNG, as it does
# for JPEG, so an iPhone ProRAW sidecar would be ignored.
# shellcheck disable=SC2034  # used by phase scripts
RAW_EXTS=(arw cr2 cr3 nef orf raf rw2)
# Formats where LRC ignores sidecars and only reads metadata embedded in the file.
# shellcheck disable=SC2034
EMBED_EXTS=(heic heif jpg jpeg tif tiff png dng)

# Build a find predicate group from extensions: \( -iname '*.a' -o ... \)
# Usage: ext_predicate "${RAW_EXTS[@]}"  -> sets EXT_PRED array.
ext_predicate() {
    local e first=1
    EXT_PRED=('(')
    for e in "$@"; do
        if (( first )); then first=0; else EXT_PRED+=(-o); fi
        EXT_PRED+=(-iname "*.$e")
    done
    EXT_PRED+=(')')
}

# Single source of truth for the copyright and creator tag set, shared by
# Phase 4 and the delta sync so the two can never drift apart.
build_metadata_tags() {
    local year="${1:-$(date +%Y)}"
    COPYRIGHT_NOTICE="Copyright ${year} ${CREATOR}. All rights reserved."
    TAGS=(
        -XMP-dc:Creator="$CREATOR"
        -XMP-dc:Rights="$COPYRIGHT_NOTICE"
        -XMP-photoshop:Credit="$CREATOR"
        -XMP-photoshop:AuthorsPosition="Photographer"
        -XMP-xmpRights:Marked=True
        -XMP-xmpRights:UsageTerms="All rights reserved"
        -XMP-iptcCore:CountryCode="$CREATOR_COUNTRY_CODE"
        -XMP-iptcCore:Location="$CREATOR_LOCATION"
        -IPTC:CopyrightNotice="$COPYRIGHT_NOTICE"
        -IPTC:By-line="$CREATOR"
    )
    if [[ -n "$RIGHTS_URL" ]]; then
        TAGS+=(-XMP-xmpRights:WebStatement="$RIGHTS_URL")
    fi
}

target_volume() {
    echo "$TARGET_ROOT" | cut -d/ -f1-3
}

# A directory test alone is not enough. After an unclean eject macOS can leave
# an empty /Volumes/<name> folder behind, and every write would then land on
# the internal disk. For targets under /Volumes, require a real mount point.
require_mount() {
    local vol mnt
    vol="$(target_volume)"
    [[ -d "$vol" ]] || die "Target volume $vol is not mounted."
    if [[ "$vol" == /Volumes/* ]]; then
        mnt="$(df -P "$vol" 2>/dev/null | awk 'NR==2 {for (i=6; i<=NF; i++) printf "%s%s", $i, (i<NF ? " " : "")}')"
        [[ "$mnt" == "$vol" ]] || die "$vol exists but is not a mounted volume (it resolves to '$mnt'). Reconnect the drive."
    fi
}

# exFAT is intentional here so the drive stays readable on Windows. Phases that
# assume case sensitivity or POSIX semantics must degrade gracefully instead.
detect_fs() {
    local vol
    vol="$(target_volume)"
    mount | awk -v v="$vol" '$3 == v {gsub(/[(),]/, "", $4); print $4; exit}'
}

# Portable size helpers. BSD and GNU df/du disagree on -g, so use POSIX -k.
free_gb() {
    df -Pk "$1" | awk 'NR==2 {printf "%d", $4 / 1048576}'
}

size_gb() {
    du -sk "$1" 2>/dev/null | awk '{printf "%d", $1 / 1048576}'
}

size_mb() {
    du -sk "$1" 2>/dev/null | awk '{printf "%d", $1 / 1024}'
}

check_free_space() {
    local need_gb="${1:-100}" free
    free=$(free_gb "$TARGET_ROOT")
    log "Free space on target: ${free} GB (minimum ${need_gb} GB)"
    (( free >= need_gb )) || die "Only ${free} GB free, need ${need_gb} GB."
}

# Arguments shared by the full extract and the delta sync.
# Sets ICLOUDPD_ARGS. Requires ICLOUDPD_HELP to hold `icloudpd --help` output.
icloudpd_supports() { grep -q -- "$1" "$ICLOUDPD_HELP" 2>/dev/null; }

build_icloudpd_args() {
    ICLOUDPD_ARGS=(
        --directory "$TARGET_ROOT/originals"
        --username "$APPLE_ID"
        --folder-structure "{:%Y/%Y-%m}"
        --cookie-directory "$TARGET_ROOT/.icloudpd-cache"
        --log-level info
    )
    if icloudpd_supports "--size"; then ICLOUDPD_ARGS+=(--size original); fi
    if icloudpd_supports "--set-exif-datetime"; then ICLOUDPD_ARGS+=(--set-exif-datetime); fi
    if icloudpd_supports "--live-photo-size"; then ICLOUDPD_ARGS+=(--live-photo-size original); fi
    if icloudpd_supports "--no-progress-bar"; then ICLOUDPD_ARGS+=(--no-progress-bar); fi
    if [[ "$ADP_WEB_ACCESS" == "1" ]]; then
        icloudpd_supports "--adp-web-access" || die "ADP_WEB_ACCESS=1 but this icloudpd has no --adp-web-access. Upgrade to $ICLOUDPD_VERSION."
        ICLOUDPD_ARGS+=(--adp-web-access)
    fi
}

ensure_icloudpd_help() {
    ICLOUDPD_HELP="$TARGET_ROOT/manifests/00-icloudpd-help.txt"
    if [[ ! -s "$ICLOUDPD_HELP" ]]; then
        icloudpd --help > "$ICLOUDPD_HELP" 2>&1 || true
    fi
}
