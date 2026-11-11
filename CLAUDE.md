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
| Step 1 test area | `/Volumes/TOSHIBA_AK/LumenSync_Test` (config `sample.env`), test catalogue `~/Pictures/Lightroom/LumenSync_Test/LumenSync_Test/` |

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

## Status (10 Nov 2026, evening)

- Step 1 (prove the code) is complete. The test import into a separate catalogue was verified: 232 of 232 files, previews, dates, map, MOV playback and copyright all confirmed.
- Phase 1 is running in a Terminal tab since 18:45. icloudpd reported 31,935 assets. About 4,400 files and 147 GB were on disk at the restart. Do not start a second extract while it runs.
- At 18:56 the run was at 4,515 files and 152 GB, about 17 files a minute. Rough finish: evening of 11 Nov, longer if Apple throttles.
- Next once the extract finishes cleanly: phases 2 to 7 on the live config, stopping after each with a status table. Then hand Anupam the import checklist.
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

- Merge branch `asterward-lumen-sync` to `main`, and rename the repo to `asterward-lumen-sync`.
- Delete `/Volumes/TOSHIBA_AK/LumenSync_Test` and the test catalogue. Deleting needs his approval in any case.
- Review `quarantine/duplicates` before anything there is removed.
- Open question: some tier 4 edits may come from frames kept in `Glam_Art` or `Studio`. `match` checks only the master today.

## Later (Step 3)

- Monthly delta sync with `bin/lumen-sync install-schedule` (launchd label `com.asterward.lumensync`). The first run from Terminal grants macOS access to the external drive.
- Each month: delta, then `match`, then `copy-new`, then a small Add import. Scope it with him first.

## Decisions already made

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
