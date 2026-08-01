#!/usr/bin/env bash
# 02-organise.sh
# Verify canonical YYYY/YYYY-MM structure. Optionally separate Live Photo MOVs.
# Set KEEP_LIVE_PHOTO_MOVS=0 to move MOVs into a separate live_photos/ tree.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_mount
KEEP_LIVE_PHOTO_MOVS="${KEEP_LIVE_PHOTO_MOVS:-1}"
MANIFEST="$TARGET_ROOT/manifests/02-organise.csv"
LOG_FILE="$TARGET_ROOT/logs/02-organise-$(date -u +%Y%m%dT%H%M%SZ).log"

echo "action,source,destination,timestamp" > "$MANIFEST"

BEFORE=$(corpus_count "$TARGET_ROOT/originals")
log "Auditing folder structure, $BEFORE files in scope"

# corpus_find already drops AppleDouble and .DS_Store noise, which exFAT produces
# in bulk and which would otherwise all read as non-conforming.
NON_CONFORMING=$(corpus_find "$TARGET_ROOT/originals" \
    ! -path "$TARGET_ROOT/originals/[0-9][0-9][0-9][0-9]/[0-9][0-9][0-9][0-9]-[0-9][0-9]/*" \
    | tr '\0' '\n')

if [[ -n "$NON_CONFORMING" ]]; then
    log "WARN: files outside canonical structure:"
    echo "$NON_CONFORMING" | tee -a "$LOG_FILE"
    log "Halting for user review. Move these manually or extend this script."
    exit 1
fi

log "All files sit within canonical folder structure"

if [[ "$KEEP_LIVE_PHOTO_MOVS" == "0" ]]; then
    log "Separating Live Photo MOVs into live_photos/ tree"
    LIVE_ROOT="$TARGET_ROOT/live_photos"
    mkdir -p "$LIVE_ROOT"

    # exFAT is case-insensitive, so match companions without assuming .HEIC vs .heic.
    shopt -s nocaseglob nullglob

    while IFS= read -r -d '' mov; do
        rel="${mov#"$TARGET_ROOT/originals/"}"
        parent="$(dirname "$mov")"
        base="$(basename "$mov")"
        stem="${base%.*}"
        stem="${stem%_HEVC}"

        companions=("$parent/$stem".heic "$parent/$stem".heif "$parent/$stem".jpg "$parent/$stem".jpeg)
        if (( ${#companions[@]} > 0 )); then
            dest="$LIVE_ROOT/$rel"
            mkdir -p "$(dirname "$dest")"
            mv "$mov" "$dest"
            echo "move_live_mov,\"$mov\",\"$dest\",$(ts)" >> "$MANIFEST"
        fi
    done < <(corpus_find "$TARGET_ROOT/originals" -iname '*.mov')

    shopt -u nocaseglob nullglob

    MOVED=$(grep -c "^move_live_mov" "$MANIFEST" || true)
    log "Moved $MOVED Live Photo MOVs"
else
    log "Keeping Live Photo MOVs in place (KEEP_LIVE_PHOTO_MOVS=1)"
fi

TOTAL=$(corpus_count "$TARGET_ROOT/originals")
LIVE_TOTAL=0
[[ -d "$TARGET_ROOT/live_photos" ]] && LIVE_TOTAL=$(corpus_count "$TARGET_ROOT/live_photos")
log "Final file count in originals/: $TOTAL, live_photos/: $LIVE_TOTAL"

if (( TOTAL + LIVE_TOTAL != BEFORE )); then
    die "File count changed from $BEFORE to $((TOTAL + LIVE_TOTAL)). Files were lost, halting."
fi
log "Phase 2 complete, no files lost"
