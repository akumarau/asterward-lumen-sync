# Asterward Lumen Sync: working notes for Claude Code

Moves Anupam's iCloud Photos library into his master Lightroom Classic catalogue without duplicating photos the catalogue already holds. Read `README.md` and `docs/lrc-setup.md` for the full design. This file is the state of play and the rules.

## Operator

- Anupam. Sydney, macOS, metric, AUD.
- Writing style: direct, short sentences, tables for status. No em dashes, no semicolons.
- Workflow: for any substantive new task, state the improved request and scope, then wait for APPROVE. Commands: APPROVE, MODIFY, REJECT, SCOPE ONLY, STOP.
- He types his own Apple password and 2FA codes. Never enter credentials.

## Paths

| Item | Path |
|---|---|
| Repo | `~/Desktop/asterward-lumen-sync`, branch `asterward-lumen-sync` |
| Live config | `config/migration.env` (gitignored, already filled in) |
| iCloud mirror | `/Volumes/TOSHIBA_AK/iCloud_Import/originals` (exFAT HDD) |
| Master catalogue | `~/Pictures/Lightroom/Anupam_Photo_Library/Anupam_Photo_Library.lrcat` |
| Destination library | `/Volumes/TOSHIBA_AK/Photo Library/YYYY/YYYY-MM/YYYY-MM-DD` |

## Phases

| # | Command | Notes |
|---|---|---|
| 1 | `caffeinate -dimsu bin/lumen-sync extract` | Long. Waits and resumes on Apple HTTP 503 throttling. Asks for 2FA only if the session expired. |
| 2 | `bin/lumen-sync organise` | Read only check of `YYYY/YYYY-MM` layout |
| 3 | `bin/lumen-sync dedupe` | Moves exact copies to `quarantine/duplicates`, keeps the plain name |
| 4 | `bin/lumen-sync metadata` | Writes `.xmp` sidecars for ARW only. Never modifies originals. |
| 5 | `bin/lumen-sync validate` | Integrity sample, must report PASS |
| 6 | `bin/lumen-sync match` | Tiers every file against a catalogue snapshot. Report: `iCloud_Import/manifests/06-match-report/index.html` |
| 7 | `bin/lumen-sync copy-new` | Copies tiers 4 and 5 (`COPY_TIERS=4,5`) to the destination library. Refuses until a full extract pass finished. |
| 8 | Lightroom import | Anupam does this by hand. Never script the Lightroom UI. |
| 9 | Reconcile | Read a **copy** of the catalogue with sqlite3 and compare with `manifests/07-copy-new.csv` |

Run `tests/run-tests.sh` (or `TEST_BASH=/bin/bash tests/run-tests.sh`) after any code change. 71 tests, all must pass. Shellcheck is optional.

## Status (12 Nov 2026, evening): Step 2 migration complete

- Step 1 (prove the code) is complete. The test import into a separate catalogue was verified: 232 of 232 files.
- Phase 1 finished 11 Nov 14:21 with exit 0: 33,229 files, 742 GB in `originals/`.
- Phases 2 to 6 passed. Phase 7 copied 32,416 files (780 GB) into `Photo Library` with 0 failures and 0 name collisions.
- Phase 8 import done 12 Nov. 256 files that were already in `Photo Library` but never catalogued came in with it (listed in `manifests/08-existing-not-in-catalogue.txt`). Anupam removed them from the catalogue (Remove, not delete). They are still on disk.
- `2026-11-10/Ramya_SilentContract_4K.mp4` was skipped as a duplicate of the copy in `Ramya_Reel`. It was re-imported on its own after `Ramya_Reel` was removed.
- Phase 9 reconcile passed: catalogue 59,175 photos (26,838 before + 32,337 new). 78 iCloud JPGs are paired with their raw. `2026-07-03/DSC00042.JPG` is not catalogued because its ARW already is. Keyword `iCloud Migration 2026` is on exactly the 32,337 new photos.
- Pre-import catalogue snapshot (10 Nov state): `~/Pictures/Lightroom/Pre-Import Snapshot 2026-11-10/`. Lightroom backups 8 Nov and 12 Nov sit in the catalogue folder.
- Optional review done 13 Nov (catalogue copies only):
  - Tier 4, 7 files: none are in `Glam_Art` or `Studio`. Each is an export of a burst frame whose neighbours (same second, 33 to 67 ms apart) are in the master. The tier 4 label is correct.
  - Tier 5 Sony, 79 JPGs: 77 have no raw in any catalogue. 2 are exports of raws kept only in other catalogues: `2026-09/20260906-_DSC9194.JPG` (`_DSC9194.ARW` in `Glam_Art`) and `2026-09/20260916-_DSC0219.JPG` (`Studio Session - 16-9-2026-019.ARW` in `Studio`). Both are now in the master.
  - Odd dates: `2000-02-16` holds two Nikon D5200 HEICs with the camera year unset. The day and an IST clock fit 16 Feb 2022 about 11:45 AEDT. `2011` and `2012` are Picasa collages with plausible dates. `2013-03-14` holds two Photoshop 25.3 exports with no camera data and the same second, date unproven. Fixing a date is his job in Lightroom (Edit Capture Time).
- Anupam is away 15 Nov to 1 Dec. Do not start `copy-new` or anything long unattended in that window unless he asks. Anything unfinished resumes when he returns.

## Environment

- exiftool, fdupes, pipx and python3 are in `/opt/homebrew/bin`. icloudpd is pinned to 1.33.0 in `~/.local/bin`.
- The iCloud session was renewed with 2FA on 10 Nov 2026 at about 17:00. It usually lasts 2 to 4 weeks, so it may expire while he is away. Renew with `bin/lumen-sync auth` (he types the 2FA code).
- Lightroom may still have the test catalogue open. Before the real import, he switches back to the master catalogue with File > Open Recent. `match` snapshots the catalogue file, so Lightroom being open is fine for that step.

## Do not touch

- `~/Desktop/icloud-to-lightroom`: his older clone on branch `agent/repair-repository`, with uncommitted local edits.
- `/Volumes/TOSHIBA_AK/Lightroom Catalog OLD`: an old catalogue copy plus a backup zip, renamed on purpose.
- Other catalogues: `Glam_Art`, `Studio` and `Lightroom Catalog.lrcat` under `~/Pictures`. Only `Anupam_Photo_Library` is the master.

## Pending decisions (need Anupam's explicit yes)

- Keep or remove from the master the 2 tier 5 JPGs whose raws live in `Glam_Art` and `Studio` (see Status). He does it in Lightroom if he wants.
- Before Step 3: `match` reads only the master. `Glam_Art` (101 photos, 6 Sep 2026) and `Studio` (67 photos, 16 Sep to 21 Oct 2026) share no photos with the master, so their exports in iCloud land in tier 5. Decide whether `match` should also read copies of those catalogues.

## Later (Step 3)

- Monthly delta sync with `bin/lumen-sync install-schedule` (launchd label `com.asterward.lumensync`). The first run from Terminal grants macOS access to the external drive.
- Each month: delta, then `match`, then `copy-new`, then a small Add import. Scope it with him first.

## Decisions already made

- 13 Nov 2026: PR #1 merged to `main` (merge commit `0cdcfba`) and the repo renamed to `akumarau/asterward-lumen-sync`. The old URL redirects. The branch `asterward-lumen-sync` stays as the working branch.
- 13 Nov 2026: Anupam approved moving the 66 files in `quarantine/duplicates` to the macOS Bin, a one-time exception to hard rule 1. All 66 were re-checked by SHA-256 against their kept twin in `originals/` first. Log: `manifests/03-dedupe-removed.csv`. Both Bins were emptied on 13 Nov at about 20:35, not by Claude.
- 13 Nov 2026: Anupam approved removing the Step 1 test area `/Volumes/TOSHIBA_AK/LumenSync_Test` (7.3 GB) and the test catalogue `~/Pictures/Lightroom/LumenSync_Test` (282 MB). Both were moved to the Bin, since emptied. A catalogue copy showed the master had no folders there. `config/sample.env` stays in the repo.
- Option A: `originals` stays a pure icloudpd mirror. New files are copied, never moved.
- Tier 4 (edits of frames culled from the catalogue) is imported, as well as tier 5.
- `--set-exif-datetime` stays on, for consistency with files downloaded in August.
- Raw + JPEG pairs stay paired in Lightroom (the default).
- Lightroom import: source the new day folders in `Photo Library`, Add mode, keyword `iCloud Migration 2026`, metadata preset `Asterward Copyright`, Do Not Import Suspected Duplicates on. Back up the catalogue first. "Automatically write changes into XMP" stays off.

## Hard rules

1. Never delete files. Duplicates go to `quarantine/`.
2. Never write to a `.lrcat`. Read a copy only.
3. Never modify files under `originals/`. icloudpd matches existing files by size, so any rewrite causes a re-download.
4. Never set `EMBED_METADATA=1`.
5. Never import from `iCloud_Import/` or its parent. It would pull in `quarantine/`.
6. Push only to branch `asterward-lumen-sync`. Merging to `main` or renaming the repo needs Anupam's explicit yes.

## Known facts from real data

- Master catalogue: 26,838 items, Oct 2024 to Nov 2026, almost all Sony ARW (ILCE-1, ILCE-1M2, 7RM6, 7RM5, 7M5) plus 251 videos. No iPhone photos.
- Sony file counters repeat across bodies, so `match` uses camera model plus capture time, never the file name alone.
- Lightroom desktop and mobile exports rewrite the sub-second time. `match` handles this.
- 155 files carry an icloudpd size suffix. Most are distinct photos sharing a name.
