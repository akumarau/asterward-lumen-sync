#!/usr/bin/env bash
# 04-generate-xmp.sh
# Asterward Lumen Sync, Phase 4.
# Apply the copyright and creator preset so Lightroom Classic picks it up on import.
#
# Lightroom Classic reads an adjacent .xmp sidecar only for proprietary raw
# formats (ARW, CR2, CR3, NEF, ORF, RAF, RW2). For HEIC, JPEG, TIFF, PNG and DNG
# it reads metadata embedded in the file and ignores any sidecar.
#
#   raw   -> .xmp sidecar. A separate file, so the original is never touched.
#   other -> nothing by default. Apply copyright with an LRC import metadata
#            preset instead (docs/lrc-setup.md).
#
# EMBED_METADATA=1 writes into the HEIC/JPEG/PNG/TIFF/DNG originals. Avoid it.
# icloudpd decides "already downloaded" by comparing local size with iCloud
# size. Every embedded write changes the size, so any later extract or delta
# run downloads that asset AGAIN as IMG_1234-<bytes>.HEIC. Dedup cannot catch
# those copies because their bytes differ. Set EMBED_METADATA_I_UNDERSTAND=1 as
# well if you still want it, and never run 01-extract.sh or the delta sync
# against this tree afterwards.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_mount
LOG_FILE="$TARGET_ROOT/logs/04-generate-xmp-$(date -u +%Y%m%dT%H%M%SZ).log"
MANIFEST="$TARGET_ROOT/manifests/04-generate-xmp.csv"
XMP_FORCE="${XMP_FORCE:-0}"
EMBED_METADATA_I_UNDERSTAND="${EMBED_METADATA_I_UNDERSTAND:-0}"

if [[ "$EMBED_METADATA" == "1" && "$EMBED_METADATA_I_UNDERSTAND" != "1" ]]; then
    die "EMBED_METADATA=1 rewrites originals and makes icloudpd re-download them later. Set EMBED_METADATA_I_UNDERSTAND=1 to proceed anyway, or use an LRC import preset."
fi

build_metadata_tags
log "Applying metadata preset"
log "Creator: $CREATOR"
log "Copyright: $COPYRIGHT_NOTICE"

# Files are fed through corpus_find, never `exiftool -r`. A recursive exiftool
# walk also visits the AppleDouble ._ companions that exFAT creates beside
# every file, and each one fails as "Not a valid JPG/ARW".
# -m tolerates minor tag errors across a corpus this size.
COMMON=(-m)
ERRORS=0

# exiftool ends with a summary such as "3 files weren't updated due to errors".
count_exiftool_errors() {
    local n
    n=$(grep -oE "[0-9]+ (image )?files? (weren't|wasn't) (updated|created) due to errors" "$1" \
        | awk '{s += $1} END {print s + 0}')
    echo "$n"
}

# ---------------------------------------------------------------------------
# Raw formats: sidecar
# ---------------------------------------------------------------------------
# -o %d%f.xmp never overwrites. An existing sidecar is reported and skipped, so
# re-runs are cheap and never clobber edits LRC may have written back.
log "Writing .xmp sidecars for raw formats: ${RAW_EXTS[*]}"
RAW_OUT="$(mktemp "${TMPDIR:-/tmp}/lumen-raw.XXXXXX")"
EMB_OUT="$(mktemp "${TMPDIR:-/tmp}/lumen-embed.XXXXXX")"
trap 'rm -f "$RAW_OUT" "$EMB_OUT"' EXIT
set +e
ext_predicate "${RAW_EXTS[@]}"
corpus_find "$TARGET_ROOT/originals" "${EXT_PRED[@]}" \
    | xargs -0 exiftool "${COMMON[@]}" \
        -tagsfromfile @ \
        -o %d%f.xmp \
        "${TAGS[@]}" > "$RAW_OUT" 2>&1
set -e
tee -a "$LOG_FILE" < "$RAW_OUT"
# "already exists" on a re-run is expected, not an error.
RAW_ERR=$(grep -c -E '^Error' "$RAW_OUT" | tr -d ' ' || true)
RAW_EXISTS=$(grep -c -E '^Error: .*already exists' "$RAW_OUT" | tr -d ' ' || true)
ERRORS=$(( ERRORS + RAW_ERR - RAW_EXISTS ))

# ---------------------------------------------------------------------------
# Everything else: embedded, only when explicitly requested
# ---------------------------------------------------------------------------
if [[ "$EMBED_METADATA" == "1" ]]; then
    log "Embedding metadata into originals for: ${EMBED_EXTS[*]}"
    GUARD=()
    # Re-runs skip files already carrying the notice, which matters on HDD.
    # shellcheck disable=SC2016  # $XMP:Rights is an exiftool expression
    [[ "$XMP_FORCE" == "1" ]] || GUARD=(-if 'not $XMP:Rights')
    set +e
    # -P keeps the filesystem timestamp, -overwrite_original prevents
    # 850 GB of _original backups. The bash 3.2 safe expansion keeps an empty
    # GUARD from aborting under set -u.
    ext_predicate "${EMBED_EXTS[@]}"
    corpus_find "$TARGET_ROOT/originals" "${EXT_PRED[@]}" \
        | xargs -0 exiftool "${COMMON[@]}" -P -overwrite_original \
            ${GUARD[@]+"${GUARD[@]}"} \
            "${TAGS[@]}" > "$EMB_OUT" 2>&1
    set -e
    tee -a "$LOG_FILE" < "$EMB_OUT"
    ERRORS=$(( ERRORS + $(count_exiftool_errors "$EMB_OUT") ))
else
    log "EMBED_METADATA=0. Originals untouched. Apply copyright with an LRC import metadata preset."
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
ext_predicate "${RAW_EXTS[@]}"
RAW_COUNT=$(corpus_count "$TARGET_ROOT/originals" "${EXT_PRED[@]}")
XMP_COUNT=$(corpus_count "$TARGET_ROOT/originals" -iname '*.xmp')
ext_predicate "${EMBED_EXTS[@]}"
EMBED_COUNT=$(corpus_count "$TARGET_ROOT/originals" "${EXT_PRED[@]}")

# Count raw files whose own sidecar is missing, rather than comparing totals.
MISSING_SIDECARS=0
ext_predicate "${RAW_EXTS[@]}"
while IFS= read -r -d '' f; do
    [[ -f "${f%.*}.xmp" || -f "${f%.*}.XMP" ]] || MISSING_SIDECARS=$((MISSING_SIDECARS + 1))
done < <(corpus_find "$TARGET_ROOT/originals" "${EXT_PRED[@]}")

{
    echo "category,files,sidecars,missing_sidecars,embedded_written,errors,timestamp"
    echo "raw,$RAW_COUNT,$XMP_COUNT,$MISSING_SIDECARS,n/a,$ERRORS,$(ts)"
    echo "embedded,$EMBED_COUNT,n/a,n/a,$EMBED_METADATA,$ERRORS,$(ts)"
} > "$MANIFEST"

log "Raw files: $RAW_COUNT, XMP sidecars: $XMP_COUNT, raw files missing a sidecar: $MISSING_SIDECARS"
log "Embedded-metadata format files: $EMBED_COUNT (written: $EMBED_METADATA)"
log "exiftool errors: $ERRORS"

if (( MISSING_SIDECARS > 0 )); then
    log "WARN: $MISSING_SIDECARS raw files have no sidecar. Investigate before LRC import."
fi
if (( ERRORS > 0 || MISSING_SIDECARS > 0 )); then
    exit 1
fi
log "Phase 4 complete"
