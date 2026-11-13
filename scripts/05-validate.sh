#!/usr/bin/env bash
# 05-validate.sh
# Asterward Lumen Sync, Phase 5.
# Final integrity sweep before LRC import.
# Random 1% sample gets exiftool verification. Full corpus gets file-count and zero-byte checks.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_mount
LOG_FILE="$TARGET_ROOT/logs/05-validate-$(date -u +%Y%m%dT%H%M%SZ).log"
REPORT="$TARGET_ROOT/manifests/05-validation-report.md"

TOTAL_FILES=$(corpus_count "$TARGET_ROOT/originals" ! -iname '*.xmp')
TOTAL_XMP=$(corpus_count "$TARGET_ROOT/originals" -iname '*.xmp')
TOTAL_SIZE_GB=$(size_gb "$TARGET_ROOT/originals")
ZERO_BYTE=$(corpus_count "$TARGET_ROOT/originals" ! -iname '*.xmp' -size 0)
JUNK=$(find "$TARGET_ROOT/originals" -type f \( -name '._*' -o -name '.DS_Store' \) | wc -l | tr -d ' ')

(( TOTAL_FILES > 0 )) || die "No files under originals/. Run Phase 1 first."

SAMPLE_SIZE=$((TOTAL_FILES / 100))
(( SAMPLE_SIZE < 100 )) && SAMPLE_SIZE=100
(( SAMPLE_SIZE > TOTAL_FILES )) && SAMPLE_SIZE=$TOTAL_FILES
SAMPLE_FAILS=0

log "Sampling $SAMPLE_SIZE of $TOTAL_FILES files for exiftool integrity check"

SAMPLE_LIST="$(mktemp "${TMPDIR:-/tmp}/validate-sample.XXXXXX")"
trap 'rm -f "$SAMPLE_LIST"' EXIT

# macOS ships no `shuf`, so sample with python3 rather than GNU coreutils.
corpus_find "$TARGET_ROOT/originals" ! -iname '*.xmp' \
    | python3 -c '
import sys, random
data = sys.stdin.buffer.read().split(b"\0")
paths = [p for p in data if p]
k = min(int(sys.argv[1]), len(paths))
sys.stdout.buffer.write(b"\0".join(random.sample(paths, k)))
' "$SAMPLE_SIZE" > "$SAMPLE_LIST"

while IFS= read -r -d '' f; do
    if ! exiftool -s -s -s -FileType "$f" >/dev/null 2>&1; then
        SAMPLE_FAILS=$((SAMPLE_FAILS + 1))
        echo "FAIL: $f" >> "$LOG_FILE"
    fi
done < "$SAMPLE_LIST"

RAW_COUNT=0
for e in "${RAW_EXTS[@]}"; do
    RAW_COUNT=$(( RAW_COUNT + $(corpus_count "$TARGET_ROOT/originals" -iname "*.$e") ))
done

cat > "$REPORT" <<EOF
# Migration Validation Report

Generated: $(date -u +"%Y-%m-%d %H:%M UTC")
Target: $TARGET_ROOT
Filesystem: $(detect_fs)

## Corpus stats

| Metric | Value |
|---|---|
| Media files in originals/ | $TOTAL_FILES |
| Raw files needing sidecars | $RAW_COUNT |
| XMP sidecars | $TOTAL_XMP |
| Total size on disk | ${TOTAL_SIZE_GB} GB |
| Zero-byte files | $ZERO_BYTE |
| macOS metadata files ignored | $JUNK |

## Sample integrity check

| Metric | Value |
|---|---|
| Files sampled | $SAMPLE_SIZE |
| Sample failures | $SAMPLE_FAILS |
| Sample pass rate | $(awk "BEGIN {printf \"%.2f\", ($SAMPLE_SIZE-$SAMPLE_FAILS)/$SAMPLE_SIZE*100}")% |

## Verdict

EOF

if (( ZERO_BYTE == 0 && SAMPLE_FAILS == 0 && TOTAL_XMP >= RAW_COUNT )); then
    echo "PASS. Corpus is ready for LRC import." >> "$REPORT"
    log "PASS. Corpus ready for LRC import."
    exit 0
else
    echo "FAIL. Investigate zero-byte files, sample failures, and missing sidecars in the log." >> "$REPORT"
    log "FAIL. See $REPORT"
    exit 1
fi
