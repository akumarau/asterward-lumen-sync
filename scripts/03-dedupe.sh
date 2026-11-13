#!/usr/bin/env bash
# 03-dedupe.sh
# Asterward Lumen Sync, Phase 3.
# Identify true content duplicates via fdupes, confirm with SHA-256, move to quarantine.
# Never deletes. User can inspect quarantine and delete manually after review.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_mount
MANIFEST="$TARGET_ROOT/manifests/03-dedupe.csv"
LOG_FILE="$TARGET_ROOT/logs/03-dedupe-$(date -u +%Y%m%dT%H%M%SZ).log"
QUARANTINE="$TARGET_ROOT/quarantine/duplicates"
RAW_LIST="$TARGET_ROOT/manifests/03-fdupes-raw.txt"

mkdir -p "$QUARANTINE"

echo "kept,duplicate_moved_to,sha256,size_bytes,timestamp" > "$MANIFEST"

BEFORE=$(corpus_count "$TARGET_ROOT/originals")
log "Building content hash index over $BEFORE files (3 to 6 hours on HDD)"

# No -S here. That flag prepends a "N bytes each:" header to every group, which
# the group parser below would read as a file path.
fdupes -r "$TARGET_ROOT/originals" > "$RAW_LIST" 2>>"$LOG_FILE" || true

DUPE_GROUPS=$(awk 'BEGIN{c=0} /^$/{c++} END{print c}' "$RAW_LIST")
log "Identified $DUPE_GROUPS candidate duplicate groups"

# For each duplicate group, keep the plain-named copy icloudpd expects, move the rest.
python3 - "$RAW_LIST" "$QUARANTINE" "$MANIFEST" "$TARGET_ROOT" 2>&1 <<'PY' | tee -a "$LOG_FILE"
import sys, os, re, csv, shutil, hashlib
from datetime import datetime, timezone

raw, quarantine, manifest, root = sys.argv[1:5]
originals = os.path.join(root, "originals")


def is_junk(path):
    name = os.path.basename(path)
    return name.startswith("._") or name in {".DS_Store", ".localized"}


SIZE_SUFFIX = re.compile(r"-[0-9]{3,}$")


def keeper_rank(path):
    stem = os.path.splitext(os.path.basename(path))[0]
    return (1 if SIZE_SUFFIX.search(stem) else 0, len(os.path.basename(path)), path)


def sha256(path, buf=1024 * 1024):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(buf):
            h.update(chunk)
    return h.hexdigest()


groups, current = [], []
with open(raw, encoding="utf-8", errors="surrogateescape") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            if current:
                groups.append(current)
                current = []
        else:
            current.append(line)
    if current:
        groups.append(current)

moved = skipped = 0
with open(manifest, "a", newline="", encoding="utf-8") as fh:
    writer = csv.writer(fh)
    for grp in groups:
        # A group is only actionable if every member is a real, non-empty file
        # that still exists. Anything else means fdupes output drifted from disk.
        files = [p for p in sorted(grp)
                 if os.path.isfile(p) and not is_junk(p) and os.path.getsize(p) > 0]
        if len(files) < 2:
            skipped += 1
            continue

        # Keep the copy icloudpd will look for next time: the plain name, not a
        # "-<bytes>" suffixed one. icloudpd checks the plain name first. If the
        # plain file were quarantined, every later extract or delta run would
        # download it again, and this phase would move it again, forever.
        files.sort(key=keeper_rank)
        keeper = files[0]
        digest = sha256(keeper)
        size = os.path.getsize(keeper)

        for dup in files[1:]:
            if sha256(dup) != digest:
                print(f"SKIP hash mismatch: {dup}")
                skipped += 1
                continue
            rel = os.path.relpath(dup, originals)
            dest = os.path.join(quarantine, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            # exFAT is case-insensitive, so distinct source names can collide here.
            stem, ext = os.path.splitext(dest)
            n = 1
            while os.path.exists(dest):
                dest = f"{stem}__dup{n}{ext}"
                n += 1
            shutil.move(dup, dest)
            writer.writerow([keeper, dest, digest, size,
                             datetime.now(timezone.utc).isoformat()])
            moved += 1

print(f"Duplicate groups processed: {len(groups)}, moved: {moved}, skipped: {skipped}")
PY

AFTER=$(corpus_count "$TARGET_ROOT/originals")
MOVED=$(( BEFORE - AFTER ))
RECLAIMED_MB=$(size_mb "$QUARANTINE")
log "originals/ went from $BEFORE to $AFTER files"
log "Moved $MOVED duplicates to quarantine, ${RECLAIMED_MB} MB reclaimable after your review"
