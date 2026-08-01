# iCloud Photos to Lightroom Classic Migration

Target scale: ~850 GB (31,689 files), macOS, external HDD, driven by GitHub Copilot agent mode with Claude Opus.

## What this bundle does

Pulls originals from iCloud Photos, organises them into a dated folder tree on an external drive, deduplicates, applies your metadata preset, then hands the folder off to Lightroom Classic as an Add-mode import. After the initial migration, a scheduled launchd job keeps new phone captures flowing in monthly.

Hands-off percentage: 85 to 90%. The residual manual work is Apple 2FA (roughly once every few weeks after the initial login) and a two-minute Add import in LRC each month.

## Prerequisites

1. External drive mounted at `/Volumes/TOSHIBA_AK`. At least 1.1 TB free for a ~850 GB source library.
2. Drive is exFAT, deliberately, so it stays readable on Windows and macOS. The scripts compensate for what exFAT lacks. See "exFAT notes" below.
3. Direct USB 3.0+ or Thunderbolt connection, not through a hub. External drive sleep disabled: `sudo pmset -a disksleep 0` while the migration runs.
4. Homebrew installed. If not: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
5. Lightroom Classic installed and licensed.
6. **Advanced Data Protection must be OFF** on the Apple Account, and **Access iCloud Data on the Web** must be ON. ADP end-to-end encrypts iCloud Photos, so no third-party client can read the library. The symptom is `ACCESS_DENIED: private db access disabled for this account`, which reads like throttling but never clears. Upstream tracking issue is icloudpd #687, still open. Turn ADP back on once the migration finishes.

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
| 2 | `scripts/01-extract.sh` | 12 to 24 hours (network-bound) | 2FA on first run |
| 3 | `scripts/02-organise.sh` | 30 min | No |
| 4 | `scripts/03-dedupe.sh` | 3 to 6 hours | No |
| 5 | `scripts/04-generate-xmp.sh` | 4 to 8 hours | No |
| 6 | `scripts/05-validate.sh` | 1 to 2 hours | Review report |
| 7 | LRC catalog move + initial import | 30 min | Yes, one time |
| 8 | Install launchd job for ongoing sync | 2 min | Yes, one time |

Total elapsed: roughly 1 to 2 weekends. Extraction dominates and is bound by iCloud throughput, not the HDD.

## How to run this with GHCP

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
└── .icloudpd-cache/    Session cookies, download state
```

This mirrors the `YYYY/YYYY-MM` convention already used by `/Volumes/TOSHIBA_AK/Photo Library/`. The import stays in its own root until Phase 5 passes, so dedup and quarantine can never touch the existing curated library. Merging into `Photo Library/` is a deliberate step taken afterwards.

## Metadata handling

Lightroom Classic only reads an adjacent `.xmp` sidecar for proprietary raw formats. For HEIC, JPEG, TIFF and PNG it reads metadata embedded in the file and ignores sidecars entirely. An iPhone library is almost all HEIC and JPEG, so `04-generate-xmp.sh` splits the corpus: sidecars for raw, embedded XMP/IPTC for everything else. Image data is never re-encoded. Set `EMBED_METADATA=0` to skip the embedded write and apply copyright through an LRC import preset instead.
