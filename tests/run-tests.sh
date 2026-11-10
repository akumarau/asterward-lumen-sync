#!/usr/bin/env bash
# run-tests.sh
# Offline tests for Asterward Lumen Sync. No Apple account, no network, no
# Lightroom. icloudpd is replaced by a stub that records its arguments.
#
#   tests/run-tests.sh                    # uses bash from PATH
#   TEST_BASH=/bin/bash tests/run-tests.sh   # on macOS: test under bash 3.2,
#                                            # the shell launchd uses
#
# Needs: python3 with Pillow, exiftool, fdupes. shellcheck is optional.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SH="${TEST_BASH:-bash}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "Shell under test: $SH ($("$SH" -c 'echo $BASH_VERSION'))"

hash_tree() {
    # sha256 of every non-sidecar file, relative path first, sorted.
    (cd "$1" && find . -type f ! -iname '*.xmp' -print0 | sort -z | xargs -0 shasum -a 256 2>/dev/null \
        || find . -type f ! -iname '*.xmp' -print0 | sort -z | xargs -0 sha256sum)
}

# Fresh target with config. $1 = name, rest = extra config lines.
new_target() {
    local name="$1"; shift
    T="$WORK/$name/target"
    CFG="$WORK/$name/migration.env"
    mkdir -p "$T"/{originals,logs,manifests,quarantine/duplicates,quarantine/junk,.icloudpd-cache}
    python3 -I "$HERE/make-fixture.py" "$T/originals"
    {
        printf 'APPLE_ID=%q\n' "tester@example.com"
        printf 'TARGET_ROOT=%q\n' "$T"
        printf 'CREATOR=%q\n' "Test O'Creator"
        printf 'CREATOR_LOCATION=%q\n' "Sydney, Australia"
        echo 'MIN_FREE_GB=1'
        echo 'EXTRACT_MIN_FREE_GB=1'
        local line; for line in "$@"; do echo "$line"; done
    } > "$CFG"
}

phase() { CONFIG_FILE="$CFG" "$SH" "$ROOT/scripts/$1" > "$WORK/last.out" 2>&1; }

# ---------------------------------------------------------------------------
echo "== Static checks"
for f in "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/common.sh "$ROOT"/bin/lumen-sync; do
    "$SH" -n "$f" || bad "syntax $f"
done
ok "all scripts parse under $SH"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x -S warning "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/common.sh "$ROOT"/bin/lumen-sync > "$WORK/sc.out" 2>&1; then
        ok "shellcheck clean at warning level"
    else
        bad "shellcheck warnings (see below)"; cat "$WORK/sc.out"
    fi
fi

# ---------------------------------------------------------------------------
echo "== Phase 2: organise, Live Photo split"
new_target p2 'KEEP_LIVE_PHOTO_MOVS=0'
phase 02-organise.sh; rc=$?
check "phase 2 exits 0" '[[ $rc -eq 0 ]]'
check "Live Photo MOV moved to live_photos/" '[[ -f "$T/live_photos/2024/2024-03/IMG_0001_HEVC.MOV" ]]'
check "standalone video stays in originals/" '[[ -f "$T/originals/2024/2024-03/IMG_0002.MOV" ]]'
check "manifest records exactly one move" '[[ $(grep -c "^move_live_mov" "$T/manifests/02-organise.csv") -eq 1 ]]'

new_target p2keep 'KEEP_LIVE_PHOTO_MOVS=1'
phase 02-organise.sh; rc=$?
check "phase 2 with KEEP_LIVE_PHOTO_MOVS=1 moves nothing" '[[ $rc -eq 0 && ! -d "$T/live_photos" ]]'

# ---------------------------------------------------------------------------
echo "== Phase 3: dedupe"
new_target p3
phase 03-dedupe.sh; rc=$?
check "phase 3 exits 0" '[[ $rc -eq 0 ]]'
check "one duplicate quarantined" '[[ $(find "$T/quarantine/duplicates" -type f ! -name "._*" | wc -l | tr -d " ") -eq 1 ]]'
check "keeper still in originals" '[[ -f "$T/originals/2024/2024-03/IMG_0003.JPG" ]]'
check "AppleDouble files not treated as duplicates" '[[ -f "$T/originals/2024/2024-03/._IMG_0001.JPG" ]]'
check "manifest has one row plus header" '[[ $(wc -l < "$T/manifests/03-dedupe.csv" | tr -d " ") -eq 2 ]]'
phase 03-dedupe.sh; rc=$?
check "re-run is idempotent" '[[ $rc -eq 0 && $(find "$T/quarantine/duplicates" -type f ! -name "._*" | wc -l | tr -d " ") -eq 1 ]]'

# ---------------------------------------------------------------------------
echo "== Phase 4: metadata (default, originals untouched)"
new_target p4
before="$(hash_tree "$T/originals")"
phase 04-generate-xmp.sh; rc=$?
after="$(hash_tree "$T/originals")"
check "phase 4 exits 0" '[[ $rc -eq 0 ]]'
check "raw file gets a sidecar" '[[ -f "$T/originals/2024/2024-04/DSC_0004.xmp" ]]'
check "sidecar carries the creator, apostrophe intact" 'exiftool -s3 -XMP-dc:Creator "$T/originals/2024/2024-04/DSC_0004.xmp" | grep -q "Test O'"'"'Creator"'
check "no original file changed (sha256)" '[[ "$before" == "$after" ]]'
check "no sidecar written for JPEG or PNG" '[[ $(find "$T/originals" -iname "*.xmp" | wc -l | tr -d " ") -eq 1 ]]'
phase 04-generate-xmp.sh; rc=$?
check "re-run exits 0 (existing sidecar is not an error)" '[[ $rc -eq 0 ]]'

new_target p4embed 'EMBED_METADATA=1'
phase 04-generate-xmp.sh; rc=$?
check "EMBED_METADATA=1 without acknowledgement is refused" '[[ $rc -ne 0 ]] && grep -q "EMBED_METADATA_I_UNDERSTAND" "$WORK/last.out"'

new_target p4force 'EMBED_METADATA=1' 'EMBED_METADATA_I_UNDERSTAND=1' 'XMP_FORCE=1'
phase 04-generate-xmp.sh; rc=$?
check "embed path with empty GUARD runs under set -u" '[[ $rc -eq 0 ]] && ! grep -q "unbound variable" "$WORK/last.out"'
check "AppleDouble files never reach exiftool" '! grep -q "Not a valid" "$WORK/last.out"'
check "no sidecar created for an AppleDouble file" '[[ ! -e "$T/originals/2024/2024-04/._DSC_0004.xmp" ]]'

# ---------------------------------------------------------------------------
echo "== Phase 5: validate"
new_target p5
phase 04-generate-xmp.sh >/dev/null
phase 05-validate.sh; rc=$?
check "validate passes on a clean corpus" '[[ $rc -eq 0 ]] && grep -q "^PASS" "$T/manifests/05-validation-report.md"'
: > "$T/originals/2024/2024-04/EMPTY_0007.JPG"
phase 05-validate.sh; rc=$?
check "validate fails on a zero byte file" '[[ $rc -ne 0 ]]'

# ---------------------------------------------------------------------------
echo "== Phase 1: extract with a stub icloudpd"
STUB_BIN="$WORK/stubbin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/icloudpd" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "\$STUB_LOG"
case " \$* " in
  *" --help "*) cat "$HERE/fixtures/icloudpd-1.33.0-help.txt"; exit 0 ;;
  *" --version "*) echo "version:1.33.0"; exit 0 ;;
esac
if [[ "\${STUB_MODE:-ok}" == "badargs" && " \$* " == *" --dry-run "* ]]; then
  echo "Error: No such option: --bogus"; exit 2
fi
case " \$* " in
  *" --auth-only "*) echo "Authentication completed successfully"; exit 0 ;;
  *" --dry-run "*) echo "2026-11-10 10:00:00 INFO     Looking up all photos and videos..."; exit 0 ;;
esac
dir=""; prev=""
for a in "\$@"; do [[ "\$prev" == "--directory" ]] && dir="\$a"; prev="\$a"; done
mkdir -p "\$dir/2024/2024-05"
python3 -c "from PIL import Image; Image.new('RGB',(8,8),(1,2,3)).save('\$dir/2024/2024-05/IMG_0100.JPG','JPEG')"
python3 -c "from PIL import Image; Image.new('RGB',(8,8),(4,5,6)).save('\$dir/2024/2024-05/DSC_0101.ARW','TIFF')"
echo "2026-11-10 10:00:01 INFO     All photos have been downloaded"
exit 0
STUB
chmod +x "$STUB_BIN/icloudpd"
export STUB_LOG="$WORK/stub.log"

new_target p1
: > "$STUB_LOG"
CONFIG_FILE="$CFG" RECENT=5 PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/01-extract.sh" > "$WORK/last.out" 2>&1; rc=$?
check "extract exits 0" '[[ $rc -eq 0 ]]'
check "auth runs in the foreground before the smoke test" 'grep -n -- "--auth-only" "$STUB_LOG" | head -1 | grep -q "^[0-9]*:" && [[ $(grep -n -- "--auth-only" "$STUB_LOG" | head -1 | cut -d: -f1) -lt $(grep -n -- "--dry-run" "$STUB_LOG" | head -1 | cut -d: -f1) ]]'
check "sample mode passes --recent 5" 'grep -v -- "--dry-run" "$STUB_LOG" | grep -v -- "--auth-only" | grep -v -- "--help" | grep -q -- "--recent 5"'
check "verified flags are passed" 'grep -q -- "--size original" "$STUB_LOG" && grep -q -- "--folder-structure {:%Y/%Y-%m}" "$STUB_LOG"'
check "downloaded file landed" '[[ -f "$T/originals/2024/2024-05/IMG_0100.JPG" ]]'

new_target p1bad
CONFIG_FILE="$CFG" STUB_MODE=badargs PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/01-extract.sh" > "$WORK/last.out" 2>&1; rc=$?
check "rejected arguments stop the run" '[[ $rc -ne 0 ]] && grep -q "rejected the arguments" "$WORK/last.out"'

new_target p1rec
CONFIG_FILE="$CFG" RECENT=abc PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/01-extract.sh" > "$WORK/last.out" 2>&1; rc=$?
check "non numeric RECENT is refused" '[[ $rc -ne 0 ]]'

# ---------------------------------------------------------------------------
echo "== Delta sync with a stub icloudpd"
new_target p99
: > "$STUB_LOG"
CONFIG_FILE="$CFG" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/99-delta-sync.sh" > "$WORK/last.out" 2>&1; rc=$?
check "first delta run (no stamp yet) exits 0" '[[ $rc -eq 0 ]] && ! grep -q "unbound variable" "$WORK/last.out"'
check "stamp written" '[[ -f "$T/.last-delta" ]]'
check "new raw file gets a sidecar" '[[ -f "$T/originals/2024/2024-05/DSC_0101.xmp" ]]'
jpg_before="$(hash_tree "$T/originals/2024/2024-05")"
CONFIG_FILE="$CFG" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/99-delta-sync.sh" > "$WORK/last.out" 2>&1; rc=$?
check "second delta run exits 0" '[[ $rc -eq 0 ]]'
check "delta never rewrites JPEG originals by default" '[[ "$jpg_before" == "$(hash_tree "$T/originals/2024/2024-05")" ]]'

# ---------------------------------------------------------------------------
echo "== CLI"
out="$("$SH" "$ROOT/bin/lumen-sync" help)"
check "lumen-sync help names the product" 'grep -q "Asterward Lumen Sync" <<<"$out"'
out="$("$SH" "$ROOT/bin/lumen-sync" version)"
check "lumen-sync version" 'grep -qE "Asterward Lumen Sync [0-9]+\.[0-9]+\.[0-9]+" <<<"$out"'
check "unknown command exits 2" '"$SH" "$ROOT/bin/lumen-sync" nonsense >/dev/null 2>&1; [[ $? -eq 2 ]]'
new_target cli
out="$(CONFIG_FILE="$CFG" "$SH" "$ROOT/bin/lumen-sync" status)"; rc=$?
check "lumen-sync status runs" '[[ $rc -eq 0 ]] && grep -q "Files in originals/" <<<"$out"'

echo
echo "Result: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
