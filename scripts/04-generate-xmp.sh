#!/usr/bin/env bash
# 04-generate-xmp.sh
# Apply the copyright/creator preset so Lightroom Classic picks it up on import.
#
# Lightroom Classic only reads adjacent .xmp sidecars for proprietary raw formats.
# For HEIC, JPEG, TIFF and PNG it reads metadata embedded in the file and ignores
# any sidecar, so an iPhone library written sidecar-only would import with no
# copyright at all. This script therefore splits the corpus:
#   raw  -> .xmp sidecar
#   rest -> embedded XMP/IPTC, image data untouched
# Set EMBED_METADATA=0 to skip embedding and apply copyright via an LRC import
# preset instead, if you would rather not write to the originals.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_mount
LOG_FILE="$TARGET_ROOT/logs/04-generate-xmp-$(date -u +%Y%m%dT%H%M%SZ).log"
MANIFEST="$TARGET_ROOT/manifests/04-generate-xmp.csv"
EMBED_METADATA="${EMBED_METADATA:-1}"
XMP_FORCE="${XMP_FORCE:-0}"

COPYRIGHT_YEAR="$(date +%Y)"
COPYRIGHT_NOTICE="Copyright ${COPYRIGHT_YEAR} ${CREATOR}. All rights reserved."

log "Applying metadata preset"
log "Creator: $CREATOR"
log "Copyright: $COPYRIGHT_NOTICE"

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
[[ -n "$RIGHTS_URL" ]] && TAGS+=(-XMP-xmpRights:WebStatement="$RIGHTS_URL")

RAW_ARGS=(); for e in "${RAW_EXTS[@]}"; do RAW_ARGS+=(-ext "$e"); done
EMBED_ARGS=(); for e in "${EMBED_EXTS[@]}"; do EMBED_ARGS+=(-ext "$e"); done

# -P keeps the filesystem timestamp, -m tolerates minor tag errors across a
# corpus this size, -overwrite_original prevents 850 GB of _original backups.
COMMON=(-r -P -m -overwrite_original)

# ---------------------------------------------------------------------------
# Raw formats: sidecar
# ---------------------------------------------------------------------------
log "Writing .xmp sidecars for raw formats: ${RAW_EXTS[*]}"
set +e
exiftool "${COMMON[@]}" "${RAW_ARGS[@]}" \
    -tagsfromfile @ \
    -o %d%f.xmp \
    "${TAGS[@]}" \
    "$TARGET_ROOT/originals" 2>&1 | tee -a "$LOG_FILE"
set -e

# ---------------------------------------------------------------------------
# Everything else: embedded
# ---------------------------------------------------------------------------
if [[ "$EMBED_METADATA" == "1" ]]; then
    log "Embedding metadata for: ${EMBED_EXTS[*]}"
    GUARD=()
    # Re-runs skip files already carrying the notice, which matters on HDD.
    [[ "$XMP_FORCE" == "1" ]] || GUARD=(-if 'not $XMP:Rights')
    set +e
    exiftool "${COMMON[@]}" "${EMBED_ARGS[@]}" \
        "${GUARD[@]}" \
        "${TAGS[@]}" \
        "$TARGET_ROOT/originals" 2>&1 | tee -a "$LOG_FILE"
    set -e
else
    log "EMBED_METADATA=0, skipping embedded write. Apply copyright via an LRC import preset."
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
raw_find=(); for e in "${RAW_EXTS[@]}"; do raw_find+=(-o -iname "*.$e"); done
RAW_COUNT=$(corpus_count "$TARGET_ROOT/originals" \( "${raw_find[@]:1}" \))
XMP_COUNT=$(corpus_count "$TARGET_ROOT/originals" -iname '*.xmp')

embed_find=(); for e in "${EMBED_EXTS[@]}"; do embed_find+=(-o -iname "*.$e"); done
EMBED_COUNT=$(corpus_count "$TARGET_ROOT/originals" \( "${embed_find[@]:1}" \))

{
    echo "category,files,sidecars,timestamp"
    echo "raw,$RAW_COUNT,$XMP_COUNT,$(ts)"
    echo "embedded,$EMBED_COUNT,n/a,$(ts)"
} > "$MANIFEST"

log "Raw files: $RAW_COUNT, XMP sidecars: $XMP_COUNT"
log "Embedded-metadata files: $EMBED_COUNT"

if (( XMP_COUNT < RAW_COUNT )); then
    log "WARN: $((RAW_COUNT - XMP_COUNT)) raw files have no sidecar. Investigate before LRC import."
fi
