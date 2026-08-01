#!/usr/bin/env bash
# 99-delta-sync.sh
# Monthly delta sync. Downloads only new items since the last successful run.
# Invoked by launchd on a schedule. Also safe to run manually.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

: "${APPLE_ID:?ERROR: run 00-prereqs.sh first to create config/migration.env}"
export PATH="$HOME/.local/bin:$PATH"

require_mount
LOG_FILE="$TARGET_ROOT/logs/delta-$(date -u +%Y%m%dT%H%M%SZ).log"
STAMP="$TARGET_ROOT/.last-delta"

ICLOUDPD_HELP="$TARGET_ROOT/manifests/00-icloudpd-help.txt"
[[ -s "$ICLOUDPD_HELP" ]] || icloudpd --help > "$ICLOUDPD_HELP" 2>&1 || true
supports() { grep -q -- "$1" "$ICLOUDPD_HELP" 2>/dev/null; }

# icloudpd is inherently delta-safe. --recent caps how far back it looks, keeping
# the scheduled run fast rather than re-walking the whole library every month.
ARGS=(
    --directory "$TARGET_ROOT/originals"
    --username "$APPLE_ID"
    --folder-structure "{:%Y/%Y-%m}"
    --cookie-directory "$TARGET_ROOT/.icloudpd-cache"
    --log-level info
    --recent 500
)
if supports "--size"; then ARGS+=(--size original); fi
if supports "--set-exif-datetime"; then ARGS+=(--set-exif-datetime); fi
if supports "--live-photo-size"; then ARGS+=(--live-photo-size original); fi
if supports "--no-progress-bar"; then ARGS+=(--no-progress-bar); fi

set +e
icloudpd "${ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    NEWER=()
    [[ -f "$STAMP" ]] && NEWER=(-newer "$STAMP")

    COPYRIGHT_NOTICE="Copyright $(date +%Y) ${CREATOR}. All rights reserved."
    TAGS=(
        -XMP-dc:Creator="$CREATOR"
        -XMP-dc:Rights="$COPYRIGHT_NOTICE"
        -IPTC:CopyrightNotice="$COPYRIGHT_NOTICE"
        -IPTC:By-line="$CREATOR"
    )

    raw_find=(); for e in "${RAW_EXTS[@]}"; do raw_find+=(-o -iname "*.$e"); done
    embed_find=(); for e in "${EMBED_EXTS[@]}"; do embed_find+=(-o -iname "*.$e"); done

    NEW_RAW=$(corpus_count "$TARGET_ROOT/originals" "${NEWER[@]}" \( "${raw_find[@]:1}" \))
    NEW_EMBED=$(corpus_count "$TARGET_ROOT/originals" "${NEWER[@]}" \( "${embed_find[@]:1}" \))
    log "New since last delta: $NEW_RAW raw, $NEW_EMBED embedded-metadata files"

    if (( NEW_RAW > 0 )); then
        corpus_find "$TARGET_ROOT/originals" "${NEWER[@]}" \( "${raw_find[@]:1}" \) \
            | xargs -0 exiftool -P -m -overwrite_original -tagsfromfile @ -o %d%f.xmp "${TAGS[@]}" \
            2>&1 | tee -a "$LOG_FILE" || true
    fi
    if (( NEW_EMBED > 0 )); then
        corpus_find "$TARGET_ROOT/originals" "${NEWER[@]}" \( "${embed_find[@]:1}" \) \
            | xargs -0 exiftool -P -m -overwrite_original "${TAGS[@]}" \
            2>&1 | tee -a "$LOG_FILE" || true
    fi

    touch "$STAMP"
fi

log "Delta sync exit: $EXIT_CODE"
exit $EXIT_CODE
