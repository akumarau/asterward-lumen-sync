#!/usr/bin/env bash
# 99-delta-sync.sh
# Asterward Lumen Sync, monthly delta sync.
# Downloads only new items, then writes sidecars for new raw files.
# Invoked by launchd through macOS /bin/bash 3.2, so keep it 3.2 compatible.
# Also safe to run manually.
#
# Needs a valid cached iCloud session. launchd has no terminal, so when the
# session expires the run fails and logs it. Run `lumen-sync auth` to renew.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

: "${APPLE_ID:?ERROR: run 00-prereqs.sh first to create config/migration.env}"
# Append, never prepend. launchd already supplies these via the plist PATH.
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
DELTA_RECENT="${DELTA_RECENT:-500}"

require_mount
LOG_FILE="$TARGET_ROOT/logs/delta-$(date -u +%Y%m%dT%H%M%SZ).log"
STAMP="$TARGET_ROOT/.last-delta"

ensure_icloudpd_help
build_icloudpd_args
# icloudpd skips files already on disk. --recent caps how far back it looks,
# keeping the scheduled run fast rather than re-walking the whole library.
ARGS=("${ICLOUDPD_ARGS[@]}" --recent "$DELTA_RECENT")

log "Delta sync started, last $DELTA_RECENT assets"

# stdin from /dev/null: a password or 2FA prompt fails fast instead of hanging.
set +e
icloudpd "${ARGS[@]}" < /dev/null 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

if grep -qE 'CRITICAL|Failed to download|ACCESS_DENIED|private db access disabled|Two-step|two-factor|Password provider' "$LOG_FILE"; then
    log "WARN: icloudpd reported an error or needs re-authentication. Run: lumen-sync auth"
    EXIT_CODE=1
fi

if [[ $EXIT_CODE -eq 0 ]]; then
    NEWER=()
    [[ -f "$STAMP" ]] && NEWER=(-newer "$STAMP")

    build_metadata_tags
    ext_predicate "${RAW_EXTS[@]}"
    RAW_PRED=("${EXT_PRED[@]}")
    ext_predicate "${EMBED_EXTS[@]}"
    EMBED_PRED=("${EXT_PRED[@]}")

    # ${NEWER[@]+...} keeps the first ever run (no stamp yet) from aborting
    # under bash 3.2 with set -u.
    NEW_RAW=$(corpus_count "$TARGET_ROOT/originals" ${NEWER[@]+"${NEWER[@]}"} "${RAW_PRED[@]}")
    NEW_EMBED=$(corpus_count "$TARGET_ROOT/originals" ${NEWER[@]+"${NEWER[@]}"} "${EMBED_PRED[@]}")
    log "New since last delta: $NEW_RAW raw, $NEW_EMBED embedded-metadata format files"

    if (( NEW_RAW > 0 )); then
        corpus_find "$TARGET_ROOT/originals" ${NEWER[@]+"${NEWER[@]}"} "${RAW_PRED[@]}" \
            | xargs -0 exiftool -m -tagsfromfile @ -o %d%f.xmp "${TAGS[@]}" \
            2>&1 | tee -a "$LOG_FILE" || true
    fi
    # Embedding into originals makes the NEXT delta re-download them, so it is
    # only done when the operator has explicitly accepted that.
    if (( NEW_EMBED > 0 )) && [[ "$EMBED_METADATA" == "1" && "${EMBED_METADATA_I_UNDERSTAND:-0}" == "1" ]]; then
        corpus_find "$TARGET_ROOT/originals" ${NEWER[@]+"${NEWER[@]}"} "${EMBED_PRED[@]}" \
            | xargs -0 exiftool -P -m -overwrite_original "${TAGS[@]}" \
            2>&1 | tee -a "$LOG_FILE" || true
    fi

    touch "$STAMP"
fi

log "Delta sync exit: $EXIT_CODE"
exit "$EXIT_CODE"
