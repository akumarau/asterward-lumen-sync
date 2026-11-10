#!/usr/bin/env bash
# 07-copy-new.sh
# Asterward Lumen Sync, Phase 7.
# Copy the files Phase 6 marked new (tier 5) into the master library tree,
# DEST_LIBRARY/YYYY/YYYY-MM/YYYY-MM-DD, ready for a Lightroom Add import.
#
# Copies, never moves: originals/ stays a complete icloudpd mirror, so later
# extract and delta runs do not download anything again. Never overwrites: a
# different file with the same name gets a __icloud1 suffix, an identical one
# is recorded as already present. Every copy is verified by SHA-256.
# Resume-safe: files already copied are skipped on a re-run.
#
# COPY_TIERS=5 by default. COPY_TIERS=4,5 also copies the review tier.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_mount
: "${DEST_LIBRARY:?Set DEST_LIBRARY in $CONFIG_FILE, for example /Volumes/TOSHIBA_AK/Photo Library}"
COPY_TIERS="${COPY_TIERS:-5}"
COPY_MIN_FREE_GB="${COPY_MIN_FREE_GB:-100}"
FORCE="${FORCE:-0}"
MATCH="$TARGET_ROOT/manifests/06-match.csv"
MANIFEST="$TARGET_ROOT/manifests/07-copy-new.csv"
LOG_FILE="$TARGET_ROOT/logs/07-copy-new-$(date -u +%Y%m%dT%H%M%SZ).log"

[[ -d "$DEST_LIBRARY" ]] || die "Destination not found: $DEST_LIBRARY"
[[ -s "$MATCH" ]] || die "Run Phase 6 (lumen-sync match) first."

# Copying from a half-finished download would leave gaps. Phase 1 logs this
# line when icloudpd has walked the whole library.
LAST_EXTRACT="$(ls -t "$TARGET_ROOT"/logs/01-extract-*.log 2>/dev/null | head -n1 || true)"
if [[ "$FORCE" != "1" ]]; then
    # The smoke test prints the same "All ... downloaded" line, so only count
    # it after the smoke test passed, and require a clean exit code.
    full_pass() {
        awk '/Arguments accepted/ {a=1} a && /All photos and videos have been downloaded/ {d=1}
             /icloudpd exit code: 0/ {z=1} END {exit !(d && z)}' "$1"
    }
    if [[ -z "$LAST_EXTRACT" ]] || ! full_pass "$LAST_EXTRACT" || grep -q "SAMPLE MODE" "$LAST_EXTRACT"; then
        die "The latest extract did not finish a full pass. Finish Phase 1 first, or set FORCE=1."
    fi
fi
if [[ "$FORCE" != "1" && -n "$LAST_EXTRACT" && "$MATCH" -ot "$LAST_EXTRACT" ]]; then
    die "06-match.csv is older than the latest extract. Run lumen-sync match again, or set FORCE=1."
fi

log "Copying tiers $COPY_TIERS to $DEST_LIBRARY"
set +e
python3 "$PROJECT_ROOT/scripts/lib/match.py" copy "$MATCH" "$TARGET_ROOT/originals" "$DEST_LIBRARY" \
    "$MANIFEST" "$COPY_TIERS" "$COPY_MIN_FREE_GB" 2>&1 | tee -a "$LOG_FILE"
RC=${PIPESTATUS[0]}
set -e
log "Manifest: $MANIFEST"
(( RC == 0 )) || die "Some files failed to copy. See $MANIFEST"
log "Phase 7 complete. Next: back up the catalogue, then import from $DEST_LIBRARY in Lightroom (see docs/lrc-setup.md)."
