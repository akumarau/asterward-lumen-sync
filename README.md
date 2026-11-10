# Asterward Lumen Sync

Move an iCloud Photos library into a Lightroom Classic ready folder tree, then keep it topped up each month.

Part of the Asterward toolset. Target scale: ~850 GB (31,689 files), macOS, external HDD. Run it from the `lumen-sync` command, or drive it with an agent.

```
bin/lumen-sync help
```

| Command | Phase |
|---|---|
| `lumen-sync prereqs` | 0. Config, tools, folders |
| `lumen-sync auth` | Renew the iCloud session |
| `lumen-sync extract` | 1. Download originals (`RECENT=100` for a sample) |
| `lumen-sync organise` | 2. Layout check, optional Live Photo split |
| `lumen-sync dedupe` | 3. Exact duplicates to quarantine |
| `lumen-sync metadata` | 4. Sidecars for raw files |
| `lumen-sync validate` | 5. Integrity sample and report |
| `lumen-sync delta` | Monthly delta sync |
| `lumen-sync status` | Counts, disk use, last verdict |
| `lumen-sync install-schedule` | Load the monthly launchd job |

## What this bundle does

Pulls originals from iCloud Photos, organises them into a dated folder tree on an external drive, deduplicates, writes sidecars for raw files, then hands the folder off to Lightroom Classic as an Add-mode import. It never writes to the Lightroom catalog, never deletes, and by default never modifies a downloaded original. After the initial migration, a scheduled launchd job keeps new phone captures flowing in monthly.

Hands-off percentage: 85 to 90%. The residual manual work is Apple 2FA (roughly once every few weeks after the initial login) and a two-minute Add import in LRC each month.

## Prerequisites

1. External drive mounted at `/Volumes/TOSHIBA_AK`. At least 1.1 TB free for a ~850 GB source library.
2. Drive is exFAT, deliberately, so it stays readable on Windows and macOS. The scripts compensate for what exFAT lacks. See "exFAT notes" below.
3. Direct USB 3.0+ or Thunderbolt connection, not through a hub. External drive sleep disabled: `sudo pmset -a disksleep 0` while the migration runs.
4. Homebrew installed. If not: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
5. Lightroom Classic installed and licensed.
6. **Access iCloud Data on the Web** must be ON. With **Advanced Data Protection** on, icloudpd sees `ACCESS_DENIED: private db access disabled for this account`, which reads like throttling but never clears. Two options:
   - Turn ADP off for the migration, then back on afterwards. Known to work.
   - Set `ADP_WEB_ACCESS=1` in `config/migration.env`. icloudpd 1.33.0 added `--adp-web-access`, which asks for web access consent through a notification on your Apple device. Not yet tested on this library.

**Note.** icloudpd talks to Apple's iCloud API directly. Your MacBook's Photos.app state (Sync this Mac on/off, Optimise Storage, Download Originals) does not affect this workflow at all. Do not try to sync the 850 GB down to Photos.app first, it wastes time and space.

## exFAT notes

exFAT is the right call for a drive that has to mount on both platforms. It costs three things, each handled in code:

| exFAT limitation | Consequence | Handling |
|---|---|---|
| No extended attributes | macOS writes an AppleDouble `._name` companion beside many files, inflating `find -type f` counts by up to 2x | All phases scan through `corpus_find` in `scripts/lib/common.sh`, which prunes AppleDouble, `.DS_Store`, `.Spotlight-V100`, `$RECYCLE.BIN` and friends |
| Case-insensitive | `IMG_1.HEIC` and `img_1.heic` collide, sidecar globs can miss | Case-insensitive matching throughout, collision-safe renaming when moving to quarantine |
| No POSIX permissions or hardlinks | Tools that dedupe by linking fail | Dedup moves files, never links, and never deletes |

**Do not put the Lightroom catalog on this drive.** An `.lrcat` is a SQLite database and exFAT has no reliable file locking, so a catalog there risks corruption on any unclean eject. There is one at `/Volumes/TOSHIBA_AK/Lightroom Catalog/` today. Move it to the internal SSD before the import. See `docs/lrc-setup.md`.

## Order of operations

Runtime estimates are calibrated for a ~850 GB library on external HDD.

| Step | Script | Runtime (HDD) | Attended |
|---|---|---|---|
| 1 | `scripts/00-prereqs.sh` | 5 min | Yes, one time |
| 2 | `scripts/01-extract.sh` | 30 to 80 hours over several nights (single thread, network bound) | 2FA on first run |
| 3 | `scripts/02-organise.sh` | 30 min | No |
| 4 | `scripts/03-dedupe.sh` | 3 to 6 hours | No |
| 5 | `scripts/04-generate-xmp.sh` | Minutes (raw sidecars only) | No |
| 6 | `scripts/05-validate.sh` | 1 to 2 hours | Review report |
| 7 | LRC catalog move + initial import | 30 min | Yes, one time |
| 8 | `lumen-sync install-schedule` | 2 min | Yes, one time |

Total elapsed: roughly 1 to 2 weeks. Extraction dominates and is bound by iCloud throughput, not the HDD.

## Start with a sample run

Prove the pipeline on 100 assets before the full library. Point a separate config at a test folder, so nothing touches the real target.

```
cp config/migration.env.example config/sample.env   # set TARGET_ROOT to a test folder, MIN_FREE_GB=20
export CONFIG_FILE=$PWD/config/sample.env
bin/lumen-sync prereqs
RECENT=100 bin/lumen-sync extract
bin/lumen-sync organise && bin/lumen-sync dedupe && bin/lumen-sync metadata && bin/lumen-sync validate
```

Then Add-import the test folder into a **copy** of your catalog and check previews, dates and GPS.

## Tests

`tests/run-tests.sh` runs 41 offline checks against a fixture library with a stubbed icloudpd. No Apple account or network needed. On macOS run it under the shell launchd uses:

```
TEST_BASH=/bin/bash tests/run-tests.sh
```

Needs python3, exiftool and fdupes. No Python packages.

## How to run this with an agent

Open the project folder in VS Code. Switch Copilot Chat to agent mode, select Claude Opus as the model, then paste the contents of `ghcp-agent-prompt.md` as your initial instruction. The agent will walk through each phase, invoke the scripts, verify success criteria, and log everything.

For overnight phases, run `caffeinate -dimsu -w $$` in a terminal alongside the agent to keep the Mac awake.

## File layout on target drive

```
/Volumes/TOSHIBA_AK/iCloud_Import/
├── originals/          Raw output from icloudpd, dated folders
│   ├── 2010/2010-03/
│   └── ... through 2026/
├── logs/               icloudpd and post-processing logs
├── manifests/          CSV audit trail per phase
├── quarantine/         Duplicates and problematic files, held for review
├── live_photos/        Live Photo MOVs, only if KEEP_LIVE_PHOTO_MOVS=0
└── .icloudpd-cache/    Session cookies, download state
```

This mirrors the `YYYY/YYYY-MM` convention already used by `/Volumes/TOSHIBA_AK/Photo Library/`. The import stays in its own root until Phase 5 passes, so dedup and quarantine can never touch the existing curated library. Merging into `Photo Library/` is a deliberate step taken afterwards.

## Metadata handling

Lightroom Classic reads an adjacent `.xmp` sidecar only for proprietary raw formats (ARW, CR2, CR3, NEF, ORF, RAF, RW2). For HEIC, JPEG, TIFF, PNG and DNG it reads metadata embedded in the file and ignores sidecars.

`lumen-sync metadata` writes sidecars for raw files only. Sidecars are separate files, so the originals stay byte for byte as downloaded.

For everything else, apply copyright with a Lightroom Classic **import metadata preset**. See `docs/lrc-setup.md`. This covers every file type, costs nothing on the HDD, and keeps the originals untouched.

**Why not embed into the originals?** icloudpd decides whether a file is already downloaded by comparing its size on disk with the size in iCloud. Writing metadata into a HEIC or JPEG changes its size. The next extract or delta run then downloads that asset again as `IMG_1234-<bytes>.HEIC`, and dedup cannot catch it because the bytes differ. `EMBED_METADATA=1` still exists for a one-off archive that will never be synced again, and it requires `EMBED_METADATA_I_UNDERSTAND=1`.
