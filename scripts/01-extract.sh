#!/usr/bin/env bash
# 01-extract.sh
# Asterward Lumen Sync, Phase 1.
# Extract originals from iCloud Photos. Resume-safe. Designed to run overnight.
# Prompts for the Apple ID password and 2FA code when the cached session is
# missing or expired. A valid session lasts roughly 2 to 4 weeks.
#
# Sample run: RECENT=100 limits the run to the 100 most recent assets. Use it
# with a test TARGET_ROOT before committing to the full library.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

: "${APPLE_ID:?ERROR: run 00-prereqs.sh first to create config/migration.env}"
# Append, never prepend: whatever is already first on PATH keeps priority,
# which also lets the test suite substitute a stub icloudpd.
export PATH="$PATH:$HOME/.local/bin"
RECENT="${RECENT:-}"

require_mount
[[ -d "$TARGET_ROOT/originals" ]] || die "Run 00-prereqs.sh first"
check_free_space "${EXTRACT_MIN_FREE_GB:-100}"

LOG_FILE="$TARGET_ROOT/logs/01-extract-$(date -u +%Y%m%dT%H%M%SZ).log"

BEFORE_COUNT=$(corpus_count "$TARGET_ROOT/originals")
log "Starting iCloud extraction to $TARGET_ROOT/originals"
log "Apple ID: $APPLE_ID"
log "Files already present: $BEFORE_COUNT"
log "Log: $LOG_FILE"

if [[ -n "$RECENT" ]]; then
    [[ "$RECENT" =~ ^[0-9]+$ ]] || die "RECENT must be a whole number, got '$RECENT'"
fi

# icloudpd's option set drifts between releases. Build the argument list against
# the help output captured in Phase 0 so an unknown flag cannot abort a long run.
ensure_icloudpd_help
build_icloudpd_args
ARGS=("${ICLOUDPD_ARGS[@]}")
if [[ -n "$RECENT" ]]; then
    ARGS+=(--recent "$RECENT")
    log "SAMPLE MODE: limited to the $RECENT most recent assets"
fi
# No --skip-created-before. Assets with a missing or bogus creation date would be
# silently dropped, and completeness matters more than tidiness here.
# No --threads-num either. icloudpd deprecated it and pins concurrency to 1.

log "icloudpd args: ${ARGS[*]}"

# Always authenticate in the foreground first. It is quick when the cached
# session is still valid, and when it has expired the password and 2FA prompts
# appear here, on screen. Previously this only ran when the cache folder was
# empty, so an EXPIRED session prompted inside the captured smoke test below
# and the script appeared to hang with no visible prompt.
AUTH_ARGS=(
    --username "$APPLE_ID"
    --directory "$TARGET_ROOT/originals"
    --cookie-directory "$TARGET_ROOT/.icloudpd-cache"
    --auth-only
)
if [[ "$ADP_WEB_ACCESS" == "1" ]]; then AUTH_ARGS+=(--adp-web-access); fi
log "Checking iCloud session. Enter password and 2FA code if prompted."
set +e
icloudpd "${AUTH_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
AUTH_RC=${PIPESTATUS[0]}
set -e
if (( AUTH_RC != 0 )) || grep -qE 'ACCESS_DENIED|private db access disabled|Invalid email/password|Failed to (log ?in|authenticate)' "$LOG_FILE"; then
    die "iCloud authentication failed (exit $AUTH_RC). See $LOG_FILE"
fi

# Run with `caffeinate -dimsu -w $$` in a second terminal to prevent sleep.
# Do not background this process, the interactive 2FA prompt needs the foreground.

# icloudpd 1.32 printed argument errors and still exited 0, so a bad flag looked
# like a clean run that downloaded nothing. Smoke test the args first.
log "Smoke testing arguments with --dry-run --recent 1"
SMOKE=$(icloudpd "${ARGS[@]}" --dry-run --recent 1 2>&1 < /dev/null) || true
echo "$SMOKE" >> "$LOG_FILE"
if grep -qE 'is incorrect|^usage:|unrecognized arguments|No such option|Error: ' <<<"$SMOKE"; then
    echo "$SMOKE"
    die "icloudpd rejected the arguments. Fix them before starting the real run."
fi
if grep -qE 'ACCESS_DENIED|private db access disabled' <<<"$SMOKE"; then
    echo "$SMOKE"
    die "iCloud denied private database access. Enable 'Access iCloud Data on the Web', and either turn Advanced Data Protection off or set ADP_WEB_ACCESS=1, then retry."
fi
if grep -qE '^[0-9-]+ [0-9:]+ ERROR|Password provider|Two-step|two-factor' <<<"$SMOKE"; then
    echo "$SMOKE"
    die "icloudpd reported an error or asked for credentials during the smoke test. Not starting the full run."
fi
log "Arguments accepted, API reachable"

# Apple throttles long runs with HTTP 503 ("temporary refusing to serve").
# The session stays valid, so wait and resume rather than stopping for the
# night. Waits double from EXTRACT_BACKOFF_MIN up to 2 hours. An expired
# session or a 2FA request needs a person, so that is never retried.
EXTRACT_RETRIES="${EXTRACT_RETRIES:-12}"
EXTRACT_BACKOFF_MIN="${EXTRACT_BACKOFF_MIN:-15}"
RETRY_RE='temporary refusing|Service Unavailable|Connection (aborted|reset)|Read timed out|Max retries exceeded|RemoteDisconnected'
AUTH_RE='Two-step|two-factor|Authentication required|Password provider|Invalid email/password'
attempt=1
wait_min="$EXTRACT_BACKOFF_MIN"
while :; do
    # Count lines written by THIS attempt, not the auth, smoke or earlier attempts.
    RUN_START_LINE=$(( $(wc -l < "$LOG_FILE") + 1 ))
    set +e
    icloudpd "${ARGS[@]}" < /dev/null 2>&1 | tee -a "$LOG_FILE"
    EXIT_CODE=${PIPESTATUS[0]}
    set -e
    log "icloudpd exit code: $EXIT_CODE (attempt $attempt of $EXTRACT_RETRIES)"
    (( EXIT_CODE == 0 )) && break
    SEGMENT="$(tail -n +"$RUN_START_LINE" "$LOG_FILE")"
    if grep -qE "$AUTH_RE" <<<"$SEGMENT"; then
        log "iCloud wants to sign in again. Run: bin/lumen-sync auth, then this script."
        break
    fi
    if (( attempt >= EXTRACT_RETRIES )) || ! grep -qE "$RETRY_RE" <<<"$SEGMENT"; then
        break
    fi
    log "Apple is throttling or the connection dropped. Files so far: $(corpus_count "$TARGET_ROOT/originals"). Waiting $wait_min min, then resuming."
    sleep $(( wait_min * 60 ))
    attempt=$(( attempt + 1 ))
    wait_min=$(( wait_min * 2 > 120 ? 120 : wait_min * 2 ))
done

ERR_RE='is incorrect|^usage:|CRITICAL|Failed to download|ACCESS_DENIED|private db access disabled'
if tail -n +"$RUN_START_LINE" "$LOG_FILE" | grep -qE "$ERR_RE"; then
    log "WARN: error patterns found in the log, treating this run as failed"
    tail -n +"$RUN_START_LINE" "$LOG_FILE" | grep -nE "$ERR_RE" | head -20
    EXIT_CODE=1
fi

# Post-run integrity check
TOTAL_FILES=$(corpus_count "$TARGET_ROOT/originals")
ZERO_BYTE=$(corpus_count "$TARGET_ROOT/originals" -size 0)
TOTAL_SIZE_GB=$(size_gb "$TARGET_ROOT/originals")

log "Total files: $TOTAL_FILES (was $BEFORE_COUNT before this run)"
log "Zero-byte files: $ZERO_BYTE"
log "Total size on disk: ${TOTAL_SIZE_GB} GB"

# Size-suffixed names (IMG_1234-2345678.HEIC) mean icloudpd found a local file
# whose size no longer matches iCloud, usually because something rewrote it.
SUFFIXED=$(corpus_count "$TARGET_ROOT/originals" -regex '.*-[0-9][0-9][0-9][0-9]*\.[A-Za-z0-9]*$')
if (( SUFFIXED > 0 )); then
    log "NOTE: $SUFFIXED files carry an icloudpd size suffix (IMG_1234-<bytes>.JPG). Most are distinct photos that share a name. Exact copies are caught by Phase 3."
fi

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

exit "$EXIT_CODE"
