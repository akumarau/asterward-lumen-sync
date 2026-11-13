#!/usr/bin/env bash
# run-tests.sh
# Offline tests for Asterward Lumen Sync. No Apple account, no network, no
# Lightroom. icloudpd is replaced by a stub that records its arguments.
#
#   tests/run-tests.sh                    # uses bash from PATH
#   TEST_BASH=/bin/bash tests/run-tests.sh   # on macOS: test under bash 3.2,
#                                            # the shell launchd uses
#
# Needs: python3 (standard library only), exiftool, fdupes. shellcheck is optional.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SH="${TEST_BASH:-bash}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-tests.XXXXXX")"
trap "${KEEP_WORK:+:} rm -rf \"$WORK\"" EXIT

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
# Two true duplicate pairs: IMG_0003 across months, DSC00042 with a size suffix.
check "duplicates quarantined" '[[ $(find "$T/quarantine/duplicates" -type f ! -name "._*" | wc -l | tr -d " ") -eq 2 ]]'
check "keeper still in originals" '[[ -f "$T/originals/2024/2024-03/IMG_0003.JPG" ]]'
check "plain name kept over icloudpd size-suffixed copy" '[[ -f "$T/originals/2024/2024-04/DSC00042.JPG" && ! -f "$T/originals/2024/2024-04/DSC00042-691516.JPG" ]]'
check "AppleDouble files not treated as duplicates" '[[ -f "$T/originals/2024/2024-03/._IMG_0001.JPG" ]]'
check "manifest has two rows plus header" '[[ $(wc -l < "$T/manifests/03-dedupe.csv" | tr -d " ") -eq 3 ]]'
phase 03-dedupe.sh; rc=$?
check "re-run is idempotent" '[[ $rc -eq 0 && $(find "$T/quarantine/duplicates" -type f ! -name "._*" | wc -l | tr -d " ") -eq 2 ]]'

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
if [[ "\${STUB_MODE:-ok}" == "throttle" && " \$* " != *" --dry-run "* && " \$* " != *" --auth-only "* && ! -f "\$STUB_LOG.throttled" ]]; then
  touch "\$STUB_LOG.throttled"
  echo "2026-11-10 17:41:36 INFO     Apple iCloud is temporary refusing to serve icloudpd"; exit 1
fi
if [[ "\${STUB_MODE:-ok}" == pcs* && " \$* " != *" --dry-run "* && " \$* " != *" --auth-only "* ]]; then
  if [[ "\${STUB_MODE}" == "pcs_always" || ! -f "\$STUB_LOG.pcs" ]]; then
    touch "\$STUB_LOG.pcs"
    echo "2026-11-11 10:31:10 ERROR    could not decrypt pcs cookie (INTERNAL_ERROR)"; exit 1
  fi
fi
case " \$* " in
  *" --auth-only "*) echo "Authentication completed successfully"; exit 0 ;;
  *" --dry-run "*) echo "2026-11-10 10:00:00 INFO     Looking up all photos and videos..."; exit 0 ;;
esac
dir=""; prev=""
for a in "\$@"; do [[ "\$prev" == "--directory" ]] && dir="\$a"; prev="\$a"; done
python3 -I "$HERE/make-fixture.py" --download "\$dir"
echo "2026-11-10 10:00:01 INFO     All photos have been downloaded"
exit 0
STUB
chmod +x "$STUB_BIN/icloudpd"
export STUB_LOG="$WORK/stub.log"

# A decoy icloudpd where pipx installs the real one. If any script lets
# ~/.local/bin win over the stub, the decoy fails the run loudly instead of
# reaching Apple with the test account. HOME is redirected for every call.
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.local/bin"
printf '#!/usr/bin/env bash\necho "DECOY icloudpd was called"\nexit 97\n' > "$FAKE_HOME/.local/bin/icloudpd"
chmod +x "$FAKE_HOME/.local/bin/icloudpd"

new_target p1
: > "$STUB_LOG"
CONFIG_FILE="$CFG" RECENT=5 HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/01-extract.sh" > "$WORK/last.out" 2>&1; rc=$?
check "extract exits 0" '[[ $rc -eq 0 ]]'
check "stub icloudpd wins over ~/.local/bin" '! grep -q DECOY "$WORK/last.out"'
check "auth runs in the foreground before the smoke test" 'grep -n -- "--auth-only" "$STUB_LOG" | head -1 | grep -q "^[0-9]*:" && [[ $(grep -n -- "--auth-only" "$STUB_LOG" | head -1 | cut -d: -f1) -lt $(grep -n -- "--dry-run" "$STUB_LOG" | head -1 | cut -d: -f1) ]]'
check "sample mode passes --recent 5" 'grep -v -- "--dry-run" "$STUB_LOG" | grep -v -- "--auth-only" | grep -v -- "--help" | grep -q -- "--recent 5"'
check "verified flags are passed" 'grep -q -- "--size original" "$STUB_LOG" && grep -q -- "--folder-structure {:%Y/%Y-%m}" "$STUB_LOG"'
check "downloaded file landed" '[[ -f "$T/originals/2024/2024-05/IMG_0100.JPG" ]]'

new_target p1bad
CONFIG_FILE="$CFG" STUB_MODE=badargs HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/01-extract.sh" > "$WORK/last.out" 2>&1; rc=$?
check "rejected arguments stop the run" '[[ $rc -ne 0 ]] && grep -q "rejected the arguments" "$WORK/last.out"'

new_target p1throttle
rm -f "$STUB_LOG.throttled"
CONFIG_FILE="$CFG" STUB_MODE=throttle EXTRACT_BACKOFF_MIN=0 HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/01-extract.sh" > "$WORK/last.out" 2>&1; rc=$?
check "throttled download waits and resumes, then succeeds" '[[ $rc -eq 0 ]] && grep -q "Waiting 0 min, then resuming" "$WORK/last.out" && grep -q "attempt 2 of" "$WORK/last.out"'
check "resumed download landed" '[[ -f "$T/originals/2024/2024-05/IMG_0100.JPG" ]]'

new_target p1pcs
rm -f "$STUB_LOG.pcs"
CONFIG_FILE="$CFG" STUB_MODE=pcs EXTRACT_BACKOFF_MIN=0 HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/01-extract.sh" > "$WORK/last.out" 2>&1; rc=$?
check "one pcs cookie error is retried, then succeeds" '[[ $rc -eq 0 ]] && grep -q "Retrying once" "$WORK/last.out" && grep -q "attempt 2 of" "$WORK/last.out"'

new_target p1pcs2
rm -f "$STUB_LOG.pcs"
CONFIG_FILE="$CFG" STUB_MODE=pcs_always EXTRACT_BACKOFF_MIN=0 HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/01-extract.sh" > "$WORK/last.out" 2>&1; rc=$?
check "a second pcs cookie error stops and asks for auth" '[[ $rc -ne 0 ]] && grep -q "Run: bin/lumen-sync auth" "$WORK/last.out" && ! grep -q "attempt 3 of" "$WORK/last.out"'

new_target p1rec
CONFIG_FILE="$CFG" RECENT=abc HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/01-extract.sh" > "$WORK/last.out" 2>&1; rc=$?
check "non numeric RECENT is refused" '[[ $rc -ne 0 ]]'

# ---------------------------------------------------------------------------
echo "== Delta sync with a stub icloudpd"
new_target p99
: > "$STUB_LOG"
CONFIG_FILE="$CFG" HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/99-delta-sync.sh" > "$WORK/last.out" 2>&1; rc=$?
check "first delta run (no stamp yet) exits 0" '[[ $rc -eq 0 ]] && ! grep -q "unbound variable" "$WORK/last.out"'
check "stamp written" '[[ -f "$T/.last-delta" ]]'
check "new raw file gets a sidecar" '[[ -f "$T/originals/2024/2024-05/DSC_0101.xmp" ]]'
jpg_before="$(hash_tree "$T/originals/2024/2024-05")"
CONFIG_FILE="$CFG" HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" "$SH" "$ROOT/scripts/99-delta-sync.sh" > "$WORK/last.out" 2>&1; rc=$?
check "second delta run exits 0" '[[ $rc -eq 0 ]]'
check "delta never rewrites JPEG originals by default" '[[ "$jpg_before" == "$(hash_tree "$T/originals/2024/2024-05")" ]]'

# ---------------------------------------------------------------------------
echo "== Phase 6 and 7: catalogue match and copy"
new_target p6
O="$T/originals"; M1="$O/2024/2024-03"; M2="$O/2024/2024-04"
LIB="$WORK/p6/Photo Library"; mkdir -p "$LIB"
# iCloud side EXIF. Tier 2: camera JPEG of a catalogue ARW. Tier 3: Lightroom
# export of a catalogue ARW. Tier 1: identical name and moment. Tier 4: burst
# frame not in the catalogue. Tier 5: iPhone photo and its Live Photo video.
exiftool -q -overwrite_original -Model=ILCE-1 '-DateTimeOriginal=2026:05:10 10:00:00' -SubSecTimeOriginal=120 "$M2/DSC00042.JPG"
exiftool -q -overwrite_original -Model=ILCE-1 '-DateTimeOriginal=2026:05:10 11:00:00' -SubSecTimeOriginal=500 '-Software=Adobe Lightroom Classic 15.6 (Macintosh)' "$M1/IMG_0003.JPG"
exiftool -q -overwrite_original -Model=ILCE-1 '-DateTimeOriginal=2026:05:11 12:00:00' -SubSecTimeOriginal=050 "$M2/IMG_0003 copy.JPG"
exiftool -q -overwrite_original -Model=ILCE-1M2 '-DateTimeOriginal=2026:06:01 09:00:00' -SubSecTimeOriginal=300 "$M2/DSC00042-691516.JPG"
exiftool -q -overwrite_original '-Model=iPhone 16 Pro' '-DateTimeOriginal=2024:03:02 08:00:00' -SubSecTimeOriginal=001 "$M1/IMG_0001.JPG"
cp "$M1/IMG_0002.MOV" "$M2/C0001.MP4"; touch -t 202605121200 "$M2/C0001.MP4"
# Lightroom desktop exports rewrite the sub-second time. One with no camera
# name maps to the only frame in that second (tier 3). One naming a frame the
# catalogue does not hold stays in review (tier 4).
cp "$M2/Screenshot_0005.PNG" "$M2/AKP-7.PNG"
exiftool -q -overwrite_original -Model=ILCE-1M2 '-DateTimeOriginal=2026:07:15 18:56:16' -SubSecTimeOriginal=357 '-Software=Adobe Lightroom 9.4.1 (Macintosh)' "$M2/AKP-7.PNG"
cp "$M2/Screenshot_0005.PNG" "$M2/20260601-_DSC09002.PNG"
exiftool -q -overwrite_original -Model=ILCE-1M2 '-DateTimeOriginal=2026:06:01 09:00:00' -SubSecTimeOriginal=777 '-Software=Adobe Lightroom 9.6 (Macintosh)' "$M2/20260601-_DSC09002.PNG"
cp "$M2/Screenshot_0005.PNG" "$M2/20260601-DSC09001-Edit.PNG"
exiftool -q -overwrite_original -Model=ILCE-1M2 '-DateTimeOriginal=2026:06:01 09:00:00' -SubSecTimeOriginal=888 '-Software=Adobe Lightroom 9.6 (Macintosh)' "$M2/20260601-DSC09001-Edit.PNG"
python3 - "$WORK/p6/master.lrcat" <<'PYC'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE AgLibraryRootFolder(id_local INTEGER PRIMARY KEY, absolutePath TEXT);
CREATE TABLE AgLibraryFolder(id_local INTEGER PRIMARY KEY, pathFromRoot TEXT, rootFolder INTEGER);
CREATE TABLE AgLibraryFile(id_local INTEGER PRIMARY KEY, baseName TEXT, extension TEXT, folder INTEGER, sidecarExtensions TEXT, originalFilename TEXT);
CREATE TABLE Adobe_images(id_local INTEGER PRIMARY KEY, rootFile INTEGER, captureTime TEXT, fileFormat TEXT, masterImage INTEGER);
CREATE TABLE AgInternedExifCameraModel(id_local INTEGER PRIMARY KEY, value TEXT);
CREATE TABLE AgHarvestedExifMetadata(id_local INTEGER PRIMARY KEY, image INTEGER, cameraModelRef INTEGER);
INSERT INTO AgLibraryRootFolder VALUES(1,'/Volumes/X/Photo Library/');
INSERT INTO AgLibraryFolder VALUES(1,'2026/2026-05/2026-05-10/',1);
INSERT INTO AgInternedExifCameraModel VALUES(1,'ILCE-1'),(2,'ILCE-1M2');
""")
rows = [  # id, base, ext, capture, format, model
  (1,'DSC00042','ARW','2026-05-10T10:00:00.120','RAW',1),
  (2,'DSC00050','ARW','2026-05-10T11:00:00.500','RAW',1),
  (3,'IMG_0003 copy','JPG','2026-05-11T12:00:00.050','JPG',1),
  (4,'DSC09000','ARW','2026-06-01T09:00:00.100','RAW',2),
  (5,'DSC09001','ARW','2026-06-01T09:00:00.200','RAW',2),
  (6,'C0001','MP4','2026-05-12T09:00:00','VIDEO',None),
  (8,'DSC03464','ARW','2026-07-15T18:56:16.758','RAW',2),
]
for i, b, e, c, f, m in rows:
    db.execute("INSERT INTO AgLibraryFile VALUES(?,?,?,1,'',?)", (i, b, e, b + '.' + e))
    db.execute("INSERT INTO Adobe_images VALUES(?,?,?,?,NULL)", (i, i, c, f))
    if m: db.execute("INSERT INTO AgHarvestedExifMetadata VALUES(?,?,?)", (i, i, m))
# A virtual copy must not count as a second photo.
db.execute("INSERT INTO Adobe_images VALUES(7,1,'2026-05-10T10:00:00.120','RAW',1)")
db.commit()
PYC
{ printf 'MASTER_LRCAT=%q\n' "$WORK/p6/master.lrcat"; printf 'DEST_LIBRARY=%q\n' "$LIB"; echo 'COPY_MIN_FREE_GB=0'; } >> "$CFG"
before="$(hash_tree "$O")"
phase 06-match.sh; rc=$?
MC="$T/manifests/06-match.csv"
tier_of() { python3 -c 'import csv,sys
for r in csv.DictReader(open(sys.argv[1])):
    if r["relpath"].endswith(sys.argv[2]): print(r["tier"]); break' "$MC" "$1"; }
check "match exits 0" '[[ $rc -eq 0 && -s "$MC" ]]'
check "camera JPEG of a catalogue ARW is tier 2" '[[ "$(tier_of 2024-04/DSC00042.JPG)" == 2 ]]'
check "Lightroom export of a catalogue photo is tier 3" '[[ "$(tier_of 2024-03/IMG_0003.JPG)" == 3 ]]'
check "same name and moment is tier 1" '[[ "$(tier_of "2024-04/IMG_0003 copy.JPG")" == 1 ]]'
check "burst frame missing from catalogue is tier 4" '[[ "$(tier_of 2024-04/DSC00042-691516.JPG)" == 4 ]]'
check "iPhone photo is tier 5" '[[ "$(tier_of 2024-03/IMG_0001.JPG)" == 5 ]]'
check "Live Photo video of a new still is tier 5" '[[ "$(tier_of 2024-03/IMG_0001_HEVC.MOV)" == 5 ]]'
check "Lightroom export with rewritten sub-second maps to the only frame (tier 3)" '[[ "$(tier_of 2024-04/AKP-7.PNG)" == 3 ]]'
check "export naming a frame missing from the catalogue is tier 4" '[[ "$(tier_of 2024-04/20260601-_DSC09002.PNG)" == 4 ]]'
check "export naming a catalogue frame in a burst is tier 3" '[[ "$(tier_of 2024-04/20260601-DSC09001-Edit.PNG)" == 3 ]]'
check "catalogue video with same name and date is tier 2" '[[ "$(tier_of 2024-04/C0001.MP4)" == 2 ]]'
check "report written" '[[ -s "$T/manifests/06-match-report/index.html" ]]'
check "EXIF cache written" '[[ -s "$T/manifests/06-exif-cache.json" ]]'
check "match never changes originals" '[[ "$before" == "$(hash_tree "$O")" ]]'
phase 06-match.sh
check "second match run reads no EXIF again" 'grep -q "Reading EXIF for 0 of" "$WORK/last.out"'

phase 07-copy-new.sh; rc=$?
check "copy refuses without a finished extract" '[[ $rc -ne 0 ]] && grep -q "did not finish a full pass" "$WORK/last.out"'
sed 's/^COPY_MIN_FREE_GB=0$/COPY_MIN_FREE_GB=999999/' "$CFG" > "$CFG.floor"
CONFIG_FILE="$CFG.floor" FORCE=1 "$SH" "$ROOT/scripts/07-copy-new.sh" > "$WORK/last.out" 2>&1; rc=$?
check "copy stops and fails below the free space floor" '[[ $rc -ne 0 ]] && grep -q "STOP: less than" "$WORK/last.out" && [[ -z "$(find "$LIB" -type f)" ]]'
# A different file already sitting at the destination name must survive.
mkdir -p "$LIB/2024/2024-03/2024-03-02"; printf 'someone else' > "$LIB/2024/2024-03/2024-03-02/IMG_0001.JPG"
CONFIG_FILE="$CFG" FORCE=1 "$SH" "$ROOT/scripts/07-copy-new.sh" > "$WORK/last.out" 2>&1; rc=$?
check "copy exits 0" '[[ $rc -eq 0 ]]'
check "new photo copied into YYYY/YYYY-MM/YYYY-MM-DD by capture date" '[[ -f "$LIB/2024/2024-03/2024-03-02/IMG_0001__icloud1.JPG" ]]'
check "existing different file is not overwritten" '[[ "$(cat "$LIB/2024/2024-03/2024-03-02/IMG_0001.JPG")" == "someone else" ]]'
check "skipped tiers are not copied" '! find "$LIB" -name "DSC00042*" | grep -q . && ! find "$LIB" -name "C0001*" | grep -q .'
check "copy never changes originals" '[[ "$before" == "$(hash_tree "$O")" ]]'
check "copies match their source bytes" 'cmp -s "$M1/IMG_0001.JPG" "$LIB/2024/2024-03/2024-03-02/IMG_0001__icloud1.JPG"'
check "Live Photo video lands beside its still" '[[ -f "$LIB/2024/2024-03/2024-03-02/IMG_0001_HEVC.MOV" ]]'
n1=$(find "$LIB" -type f | wc -l | tr -d " ")
CONFIG_FILE="$CFG" FORCE=1 "$SH" "$ROOT/scripts/07-copy-new.sh" > "$WORK/last.out" 2>&1; rc=$?
check "copy re-run copies nothing new" '[[ $rc -eq 0 && $(find "$LIB" -type f | wc -l | tr -d " ") -eq $n1 ]] && grep -q "Copied: 0" "$WORK/last.out"'

# ---------------------------------------------------------------------------
echo "== Phase 6: extra catalogues"
# Two frames held only in another catalogue: a camera JPEG of one (skip) and a
# Lightroom export of the other, with the sub-second rewritten (review, copied).
M3="$O/2026/2026-08"; mkdir -p "$M3"
cp "$M1/IMG_0001.JPG" "$M3/DSC07001.JPG"
exiftool -q -overwrite_original -Model=ILCE-1 '-DateTimeOriginal=2026:08:01 10:00:00' -SubSecTimeOriginal=250 "$M3/DSC07001.JPG"
cp "$M1/IMG_0001.JPG" "$M3/20260801-DSC07002.JPG"
exiftool -q -overwrite_original -Model=ILCE-1 '-DateTimeOriginal=2026:08:01 10:00:01' -SubSecTimeOriginal=999 '-Software=Adobe Lightroom 9.6 (Macintosh)' "$M3/20260801-DSC07002.JPG"
python3 - "$WORK/p6/Studio.lrcat" <<'PYC'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE AgLibraryRootFolder(id_local INTEGER PRIMARY KEY, absolutePath TEXT);
CREATE TABLE AgLibraryFolder(id_local INTEGER PRIMARY KEY, pathFromRoot TEXT, rootFolder INTEGER);
CREATE TABLE AgLibraryFile(id_local INTEGER PRIMARY KEY, baseName TEXT, extension TEXT, folder INTEGER, sidecarExtensions TEXT, originalFilename TEXT);
CREATE TABLE Adobe_images(id_local INTEGER PRIMARY KEY, rootFile INTEGER, captureTime TEXT, fileFormat TEXT, masterImage INTEGER);
CREATE TABLE AgInternedExifCameraModel(id_local INTEGER PRIMARY KEY, value TEXT);
CREATE TABLE AgHarvestedExifMetadata(id_local INTEGER PRIMARY KEY, image INTEGER, cameraModelRef INTEGER);
INSERT INTO AgLibraryRootFolder VALUES(1,'/Volumes/X/Studio/');
INSERT INTO AgLibraryFolder VALUES(1,'2026-08-01/',1);
INSERT INTO AgInternedExifCameraModel VALUES(1,'ILCE-1');
INSERT INTO AgLibraryFile VALUES(1,'DSC07001','ARW',1,'','DSC07001.ARW'),(2,'DSC07002','ARW',1,'','DSC07002.ARW');
INSERT INTO Adobe_images VALUES(1,1,'2026-08-01T10:00:00.250','RAW',NULL),(2,2,'2026-08-01T10:00:01.400','RAW',NULL);
INSERT INTO AgHarvestedExifMetadata VALUES(1,1,1),(2,2,1);
""")
db.commit()
PYC
phase 06-match.sh; cp "$MC" "$WORK/p6/plain.csv"
check "without extra catalogues their frames are tier 5" '[[ "$(tier_of 2026-08/DSC07001.JPG)" == 5 && "$(tier_of 2026-08/20260801-DSC07002.JPG)" == 5 ]]'
{ cat "$CFG"; echo 'EXTRA_LRCATS='; } > "$CFG.empty"
CONFIG_FILE="$CFG.empty" "$SH" "$ROOT/scripts/06-match.sh" > "$WORK/last.out" 2>&1; rc=$?
check "empty EXTRA_LRCATS changes nothing" '[[ $rc -eq 0 ]] && cmp -s "$MC" "$WORK/p6/plain.csv"'
{ cat "$CFG"; printf 'EXTRA_LRCATS=%q\n' "$WORK/p6/nope.lrcat"; } > "$CFG.missing"
CONFIG_FILE="$CFG.missing" "$SH" "$ROOT/scripts/06-match.sh" > "$WORK/last.out" 2>&1; rc=$?
check "missing extra catalogue stops match" '[[ $rc -ne 0 ]] && grep -q "Extra catalogue not found" "$WORK/last.out" && cmp -s "$MC" "$WORK/p6/plain.csv"'
studio_sum="$(cksum < "$WORK/p6/Studio.lrcat")"
{ cat "$CFG"; printf 'EXTRA_LRCATS=%q\n' "$WORK/p6/Studio.lrcat"; } > "$CFG.extra"
CONFIG_FILE="$CFG.extra" "$SH" "$ROOT/scripts/06-match.sh" > "$WORK/last.out" 2>&1; rc=$?
check "match with an extra catalogue exits 0" '[[ $rc -eq 0 ]] && grep -q "Extra catalogue Studio: 2" "$WORK/last.out"'
check "camera JPEG of a frame in an extra catalogue is skipped (tier 2)" '[[ "$(tier_of 2026-08/DSC07001.JPG)" == 2 ]] && grep "DSC07001.JPG" "$MC" | grep -q "(in Studio)"'
check "edited export of a frame in an extra catalogue is review (tier 4)" '[[ "$(tier_of 2026-08/20260801-DSC07002.JPG)" == 4 ]] && grep "20260801-DSC07002.JPG" "$MC" | grep -q "photo in Studio"'
check "master matches are unchanged by an extra catalogue" '[[ "$(tier_of 2024-03/IMG_0003.JPG)" == 3 && "$(tier_of 2024-03/IMG_0001.JPG)" == 5 ]]'
check "extra catalogue is never modified" '[[ "$studio_sum" == "$(cksum < "$WORK/p6/Studio.lrcat")" ]]'

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
