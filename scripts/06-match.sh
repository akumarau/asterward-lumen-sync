#!/usr/bin/env bash
# 06-match.sh
# Asterward Lumen Sync, Phase 6.
# Compare every iCloud file with what the master Lightroom catalogue already
# holds, and sort each file into a tier. Read only on both sides: the catalogue
# is copied first and opened read only, and originals/ is never touched.
#
#   Tier 1 same_file      same name and capture time already in the catalogue
#   Tier 2 same_shot      same camera and capture moment, different file
#   Tier 3 edited_export  tier 2, written by Lightroom or Photoshop
#   Tier 4 review         near match, a person decides
#   Tier 5 new            copied by Phase 7
#
# Config: MASTER_LRCAT=/path/to/Catalog.lrcat in config/migration.env.
# Optional: EXTRA_LRCATS=/path/A.lrcat:/path/B.lrcat for other catalogues that
# also hold photos. A plain copy of one of their photos is skipped. An edited
# export of one goes to tier 4, so the edit is still copied into the master.
# Output: manifests/06-match.csv and manifests/06-match-report/index.html

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_mount
: "${MASTER_LRCAT:?Set MASTER_LRCAT in $CONFIG_FILE to your master catalogue .lrcat path}"
[[ -f "$MASTER_LRCAT" ]] || die "Catalogue not found: $MASTER_LRCAT"
EXTRAS=()
if [[ -n "${EXTRA_LRCATS:-}" ]]; then
    IFS=':' read -r -a EXTRAS <<< "$EXTRA_LRCATS"
    for x in "${EXTRAS[@]}"; do
        [[ -f "$x" ]] || die "Extra catalogue not found: $x"
    done
fi
MATCH_THUMBS="${MATCH_THUMBS:-1}"

LOG_FILE="$TARGET_ROOT/logs/06-match-$(date -u +%Y%m%dT%H%M%SZ).log"
MAN="$TARGET_ROOT/manifests"
PY="$PROJECT_ROOT/scripts/lib/match.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-match.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1. Snapshot the catalogue. Copy the WAL too, so edits Lightroom has not yet
#    checkpointed are included. The live catalogue is only ever read.
# ---------------------------------------------------------------------------
log "Copying catalogue snapshot: $MASTER_LRCAT"
cp "$MASTER_LRCAT" "$WORK/catalog.lrcat"
[[ -f "$MASTER_LRCAT-wal" ]] && cp "$MASTER_LRCAT-wal" "$WORK/catalog.lrcat-wal"
[[ -f "${MASTER_LRCAT%.lrcat}.lrcat.lock" ]] && log "NOTE: Lightroom has this catalogue open. The snapshot may miss changes made in the last few seconds."
EXTRA_ARGS=()
n=0
for x in ${EXTRAS[@]+"${EXTRAS[@]}"}; do
    n=$((n + 1))
    log "Copying extra catalogue snapshot: $x"
    cp "$x" "$WORK/extra$n.lrcat"
    [[ -f "$x-wal" ]] && cp "$x-wal" "$WORK/extra$n.lrcat-wal"
    EXTRA_ARGS+=("$(basename "$x" .lrcat)=$WORK/extra$n.lrcat")
done

# ---------------------------------------------------------------------------
# 2. EXIF for every iCloud file, read once and cached. Later runs only read
#    files that are new or changed, so the monthly run takes seconds.
# ---------------------------------------------------------------------------
corpus_find "$TARGET_ROOT/originals" ! -iname '*.xmp' > "$WORK/files.bin"
TOTAL=$(tr -cd '\0' < "$WORK/files.bin" | wc -c | tr -d ' ')
CACHE="$MAN/06-exif-cache.json"
TODO=$(python3 "$PY" exif-todo "$WORK/files.bin" "$CACHE" "$WORK/todo.txt")
log "Reading EXIF for $TODO of $TOTAL files (the rest are cached)"
if (( TODO > 0 )); then
    exiftool -j -fast -charset filename=utf8 \
        -FileName -Model -Software \
        -SubSecDateTimeOriginal -DateTimeOriginal -SubSecTimeOriginal \
        -SubSecCreateDate -CreateDate -SubSecTimeDigitized \
        -@ "$WORK/todo.txt" > "$WORK/new.json" 2>> "$LOG_FILE" || true
fi
python3 "$PY" exif-merge "$WORK/files.bin" "$CACHE" "$WORK/new.json" > /dev/null

# ---------------------------------------------------------------------------
# 3. Tier
# ---------------------------------------------------------------------------
python3 "$PY" match "$TARGET_ROOT/originals" "$WORK/catalog.lrcat" "$CACHE" "$MAN/06-match.csv" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} | tee -a "$LOG_FILE"

# ---------------------------------------------------------------------------
# 4. Report, with thumbnails for tiers 1 to 4 (capped) so a person can check
#    the matches by eye. Thumbnails come from the files' embedded previews.
# ---------------------------------------------------------------------------
REPORT="$MAN/06-match-report"
mkdir -p "$REPORT/thumbs"
THUMBS_JSON="$WORK/thumbs.json"
echo "{}" > "$THUMBS_JSON"
if [[ "$MATCH_THUMBS" == "1" ]]; then
    log "Extracting thumbnails for the report"
    python3 - "$MAN/06-match.csv" > "$WORK/thumb_jobs.tsv" <<'PYJ'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
caps = {"4": 400, "3": 80, "2": 80, "1": 40}
seen = {}
for r in rows:
    t = r["tier"]
    if t in caps and seen.get(t, 0) < caps[t]:
        seen[t] = seen.get(t, 0) + 1
        print("\t".join([r["relpath"], r["catalogue_match"]]))
PYJ
    n=0
    while IFS=$'\t' read -r rel match; do
        n=$((n + 1))
        a="thumbs/i$n.jpg"; b="thumbs/c$n.jpg"
        exiftool -b -ThumbnailImage "$TARGET_ROOT/originals/$rel" > "$REPORT/$a" 2>/dev/null || true
        [[ -s "$REPORT/$a" ]] || exiftool -b -PreviewImage "$TARGET_ROOT/originals/$rel" > "$REPORT/$a" 2>/dev/null || true
        if [[ -n "$match" && -f "$match" ]]; then
            exiftool -b -ThumbnailImage "$match" > "$REPORT/$b" 2>/dev/null || true
        fi
        printf '%s\t%s\t%s\n' "$rel" "$a" "$b" >> "$WORK/thumbs.tsv"
    done < "$WORK/thumb_jobs.tsv"
    if [[ -f "$WORK/thumbs.tsv" ]]; then
        python3 - "$WORK/thumbs.tsv" "$REPORT" > "$THUMBS_JSON" <<'PYT'
import json, os, sys
out = {}
for line in open(sys.argv[1], encoding="utf-8"):
    rel, a, b = line.rstrip("\n").split("\t")
    pair = {}
    if os.path.getsize(os.path.join(sys.argv[2], a)) > 0: pair["icloud"] = a
    if b and os.path.exists(os.path.join(sys.argv[2], b)) and os.path.getsize(os.path.join(sys.argv[2], b)) > 0: pair["catalogue"] = b
    out[rel] = pair
print(json.dumps(out))
PYT
    fi
fi
python3 "$PY" report "$MAN/06-match.csv" "$REPORT" "$THUMBS_JSON" > /dev/null
log "Report: $REPORT/index.html"
log "Phase 6 complete. Review tier 4 before running Phase 7."
