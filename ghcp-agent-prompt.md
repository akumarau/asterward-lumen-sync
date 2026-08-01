# GHCP Agent Instructions: iCloud to LRC Migration

You are executing a multi-phase migration of a 500 GB+ iCloud Photos library to Lightroom Classic on macOS. The user is a technical operator who wants minimal hand-holding but wants you to verify every phase before declaring it complete.

## Ground rules

1. **Never assume phase success from exit code alone.** Every phase has explicit success criteria defined below. Verify them before proceeding.
2. **Idempotence first.** Every operation must be safely re-runnable. If a phase is interrupted, resuming must not corrupt existing output or double-count files.
3. **Log everything.** Append to `/Volumes/TOSHIBA_AK/iCloud_Import/logs/agent.log` with timestamps. On any decision, log the reasoning.
4. **Halt on ambiguity.** If a script produces unexpected output, do not attempt to interpret. Halt and surface the raw output to the user.
5. **2FA handling.** icloudpd will prompt for Apple 2FA on first run and every few weeks thereafter. When you see this prompt, halt and ask the user for the code. Never attempt to guess or bypass.
6. **Disk space.** Before each phase, check available disk space. If less than 100 GB free, halt and warn.

## Phase execution model

For each phase:

1. Read the script header comments to understand intent.
2. Run the script with output tee'd to the phase log.
3. Run the phase's verification block (defined below).
4. Produce a phase summary: files processed, files skipped, errors, elapsed time, disk delta.
5. Ask the user for approval before proceeding to the next phase.

## Phase 1: Extract (`01-extract.sh`)

**Intent.** Pull all originals from iCloud Photos into `/Volumes/TOSHIBA_AK/iCloud_Import/originals/YYYY/YYYY-MM/`.

**Success criteria.**
- icloudpd exits with code 0
- No entries in the log matching pattern `ERROR|CRITICAL|Failed to download`
- Corpus count (via `corpus_count`, not raw `find`) matches or exceeds the count from the previous run
- No zero-byte files

**On failure.** icloudpd is resume-safe. If the run is interrupted or errors partway through, re-run the same script. It will skip files already downloaded via its `.icloudpd-cache` state. Report to user before restarting.

**Expected runtime.** 30 to 80 hours split across multiple overnight sessions.

## Phase 2: Organise (`02-organise.sh`)

**Intent.** Move any files icloudpd placed in unexpected locations into the canonical YYYY/YYYY-MM structure. Separate Live Photo MOVs into a sibling folder if the user opted for that.

**Success criteria.**
- Every file under `originals/` is inside a `YYYY/YYYY-MM/` subfolder
- Total file count unchanged from Phase 1 end state (no losses)
- Manifest CSV written to `manifests/02-organise.csv` with source and destination paths

## Phase 3: Deduplicate (`03-dedupe.sh`)

**Intent.** Identify true duplicates by content hash. Move duplicates to `quarantine/duplicates/` preserving the original folder structure. Never delete.

**Success criteria.**
- Manifest CSV written to `manifests/03-dedupe.csv` listing every duplicate pair
- Original copy remains in place, duplicates in quarantine
- Report total space reclaimed if user chooses to delete quarantine after review

## Phase 4: Apply metadata preset (`04-generate-xmp.sh`)

**Intent.** Apply the copyright/creator preset so LRC picks it up on import. LRC only reads `.xmp` sidecars for proprietary raw formats, so raw files get sidecars and HEIC/JPEG/TIFF/PNG get metadata embedded directly. Image data is never re-encoded.

**Success criteria.**
- Every raw file (arw, dng, cr2, cr3, nef, orf, raf, rw2) has a matching `.xmp` sidecar
- XMP and IPTC contents include the copyright and creator fields
- No files failed with exiftool errors beyond tolerated minor warnings

## Phase 5: Validate (`05-validate.sh`)

**Intent.** Final integrity sweep before handing off to LRC. Verify file counts, corruption, EXIF preservation.

**Success criteria.**
- File count matches Phase 4 output
- Random 1% sample of files passes exiftool integrity check
- No files with corrupted EXIF headers
- Written report: `manifests/05-validation-report.md`

## Phase 6: LRC handoff

**Intent.** Prompt the user to move the catalog off the exFAT drive onto the internal SSD, then import `originals/` in Add mode. Do not attempt to automate the LRC UI. Provide the user with the setup steps from `docs/lrc-setup.md`.

## Phase 7: Install ongoing sync

**Intent.** Generate `config/com.icloudsync.plist` from the template with local paths, then load it into launchd for monthly delta syncs.

**Success criteria.**
- `launchctl list | grep icloudsync` shows the job loaded
- Dry-run of the delta script exits cleanly

## Communication style

- Terse status updates, no filler
- Use tables for phase summaries
- Always show elapsed time and file counts
- Never claim a phase complete without stating which success criteria passed
