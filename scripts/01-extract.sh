#!/usr/bin/env bash
# 01-extract.sh
# Extract all originals from iCloud Photos. Resume-safe. Designed to run overnight.
# On first execution, prompts for the Apple ID password and 2FA code interactively.
# Session cookies cached in .icloudpd-cache, valid for approx 2 to 4 weeks after that.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

: "${APPLE_ID:?ERROR: run 00-prereqs.sh first to create config/migration.env}"
export PATH="$HOME/.local/bin:$PATH"

require_mount
[[ -d "$TARGET_ROOT/originals" ]] || die "Run 00-prereqs.sh first"
check_free_space 100

LOG_FILE="$TARGET_ROOT/logs/01-extract-$(date -u +%Y%m%dT%H%M%SZ).log"

BEFORE_COUNT=$(corpus_count "$TARGET_ROOT/originals")
log "Starting iCloud extraction to $TARGET_ROOT/originals"
log "Apple ID: $APPLE_ID"
log "Files already present: $BEFORE_COUNT"
log "Log: $LOG_FILE"

# icloudpd's option set drifts between releases. Build the argument list against
# the help output captured in Phase 0 so an unknown flag cannot abort a long run.
ICLOUDPD_HELP="$TARGET_ROOT/manifests/00-icloudpd-help.txt"
[[ -s "$ICLOUDPD_HELP" ]] || icloudpd --help > "$ICLOUDPD_HELP" 2>&1 || true

supports() { grep -q -- "$1" "$ICLOUDPD_HELP" 2>/dev/null; }

ARGS=(
    --directory "$TARGET_ROOT/originals"
    --username "$APPLE_ID"
    --folder-structure "{:%Y/%Y-%m}"
    --cookie-directory "$TARGET_ROOT/.icloudpd-cache"
    --log-level info
)
if supports "--size"; then ARGS+=(--size original); fi
if supports "--set-exif-datetime"; then ARGS+=(--set-exif-datetime); fi
if supports "--live-photo-size"; then ARGS+=(--live-photo-size original); fi
if supports "--no-progress-bar"; then ARGS+=(--no-progress-bar); fi
# No --skip-created-before. Assets with a missing or bogus creation date would be
# silently dropped, and completeness matters more than tidiness here.
# No --threads-num either, icloudpd 1.32 deprecated it and pins concurrency to 1.

log "icloudpd args: ${ARGS[*]}"

# Authenticate first so the 2FA prompt appears immediately rather than buried in
# a multi-hour run. Cookies then last a few weeks.
if [[ -z "$(ls -A "$TARGET_ROOT/.icloudpd-cache" 2>/dev/null)" ]]; then
    log "No cached session found, authenticating first. Expect a 2FA prompt."
    icloudpd --username "$APPLE_ID" \
        --directory "$TARGET_ROOT/originals" \
        --cookie-directory "$TARGET_ROOT/.icloudpd-cache" \
        --auth-only 2>&1 | tee -a "$LOG_FILE"
fi

# Run with `caffeinate -dimsu -w $$` in a second terminal to prevent sleep.
# Do not background this process, the interactive 2FA prompt needs the foreground.

# icloudpd 1.32 prints argument errors and still exits 0, so a bad flag looks
# like a clean run that downloaded nothing. Smoke test the args first.
log "Smoke testing arguments with --dry-run --recent 1"
SMOKE=$(icloudpd "${ARGS[@]}" --dry-run --recent 1 2>&1) || true
if grep -qE 'is incorrect|^usage:|unrecognized arguments|No such option' <<<"$SMOKE"; then
    echo "$SMOKE" | tee -a "$LOG_FILE"
    die "icloudpd rejected the arguments. Fix them before starting the real run."
fi
if grep -qE 'ACCESS_DENIED|private db access disabled' <<<"$SMOKE"; then
    echo "$SMOKE" | tee -a "$LOG_FILE"
    die "iCloud denied private database access. Check that 'Access iCloud Data on the Web' is enabled and Advanced Data Protection is off, then retry."
fi
if grep -qE '^[0-9-]+ [0-9:]+ ERROR' <<<"$SMOKE"; then
    echo "$SMOKE" | tee -a "$LOG_FILE"
    die "icloudpd reported an error during the smoke test. Not starting the full run."
fi
log "Arguments accepted, API reachable"

set +e
icloudpd "${ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

log "icloudpd exit code: $EXIT_CODE"

if grep -qE 'is incorrect|^usage:|CRITICAL|Failed to download|ACCESS_DENIED|private db access disabled' "$LOG_FILE"; then
    log "WARN: error patterns found in the log, treating this run as failed"
    grep -nE 'is incorrect|^usage:|CRITICAL|Failed to download|ACCESS_DENIED|private db access disabled' "$LOG_FILE" | head -20
    EXIT_CODE=1
fi

# Post-run integrity check
TOTAL_FILES=$(corpus_count "$TARGET_ROOT/originals")
ZERO_BYTE=$(corpus_count "$TARGET_ROOT/originals" -size 0)
TOTAL_SIZE_GB=$(du -sg "$TARGET_ROOT/originals" | awk '{print $1}')

log "Total files: $TOTAL_FILES (was $BEFORE_COUNT before this run)"
log "Zero-byte files: $ZERO_BYTE"
log "Total size on disk: ${TOTAL_SIZE_GB} GB"

# Leftovers here mean a run was interrupted mid-download. Re-running clears them.
PARTIALS=$(find "$TARGET_ROOT/originals" -type f -name '*.part' | wc -l | tr -d ' ')
if (( PARTIALS > 0 )); then
    log "NOTE: $PARTIALS incomplete .part files present, excluded from counts"
fi

if (( TOTAL_FILES < BEFORE_COUNT )); then
    log "WARN: file count went down. Investigate before re-running."
fi

if (( ZERO_BYTE > 0 )); then
    log "WARN: found $ZERO_BYTE zero-byte files, listing:"
    corpus_find "$TARGET_ROOT/originals" -size 0 | tr '\0' '\n' | tee -a "$LOG_FILE"
    log "Re-run this script to attempt re-download of these files"
fi

exit $EXIT_CODE
