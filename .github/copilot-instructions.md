# Copilot Instructions: iCloud → LRC Migration Workspace

This workspace runs a 500+ GB iCloud Photos migration to Lightroom Classic on macOS. You are the executing agent. Read this file as ambient context on every request.

## Operator context

- Technical user, terse communication preferred, no filler
- Wants explicit verification before advancing between phases
- Expects tables for status summaries, not prose
- Never use em dashes or en dashes as punctuation

## Environment assumptions

- OS: macOS (Apple Silicon likely, but code should not assume)
- External **HDD** (not SSD) mounted at `/Volumes/TOSHIBA_AK/`, formatted **exFAT** by deliberate operator choice for Windows interoperability
- Migration root: `/Volumes/TOSHIBA_AK/iCloud_Import/`
- Source library: ~850 GB, 31,689 files (30,310 photos + 1,379 videos)
- Shell: zsh or bash, POSIX-compatible scripts
- Homebrew present at `/opt/homebrew/bin` or `/usr/local/bin`, icloudpd installed via pipx at `~/.local/bin`
- Config lives in `config/migration.env`, written by `00-prereqs.sh` and sourced by `scripts/lib/common.sh`. Do not ask the user to export `APPLE_ID` or `TARGET_ROOT` by hand.
- **Photos.app state is irrelevant.** icloudpd uses the iCloud API directly. Do not suggest the user enable "Download Originals" or sync anything to Photos.app first.
- **Advanced Data Protection must stay OFF** for the duration. It blocks the private photo database entirely. If `ACCESS_DENIED: private db access disabled` appears, that is ADP or the "Access iCloud Data on the Web" toggle, not rate limiting. Do not advise waiting it out.

## exFAT constraints

The drive is exFAT on purpose. Never suggest reformatting. Instead:

- Never call bare `find -type f` on the corpus. Use `corpus_find` / `corpus_count` from `scripts/lib/common.sh`, which prune AppleDouble `._*`, `.DS_Store`, `.Spotlight-V100`, `$RECYCLE.BIN` and similar. A raw `find` can overcount by close to 2x and will feed junk into exiftool and fdupes.
- Assume case-insensitive filenames. Match extensions with `-iname`, and expect name collisions when moving files.
- No hardlinks, no POSIX permissions, no extended attributes.
- The Lightroom catalog must never live on this volume. SQLite plus exFAT locking equals corruption risk.

## HDD-specific performance notes

Post-processing phases that touch every file with random I/O are slower on HDD than SSD. Expect:
- Phase 3 (dedup): 3-6 hours instead of 1-2
- Phase 4 (XMP): 4-8 hours instead of 2-4
- Phase 5 (validate): 1-2 hours instead of 30 min

Do not attempt to parallelise these beyond the defaults in the scripts. HDD random-read contention makes higher parallelism slower, not faster.

icloudpd 1.32 deprecated `--threads-num` and pins downloads to a single thread, so Phase 1 throughput is fixed by iCloud and cannot be tuned. Do not add it back.

## Execution model

You execute one phase per invocation unless the user explicitly says "run through phase N". After each phase:

1. Run the phase's verification block from `ghcp-agent-prompt.md`
2. Produce a status table (template below)
3. Halt and ask for approval before moving to the next phase

Never attempt to reason past a failed script or missed success criterion. Halt and surface the raw output.

## Status template

Use this exact format at the end of each phase:

```
─── Phase N complete ───
Runtime: HH:MM:SS
Files processed: N
Files skipped: N
Errors: N
Disk delta: +N.N GB
Success criteria:
  [PASS/FAIL] criterion 1
  [PASS/FAIL] criterion 2

Approve moving to Phase N+1? (y/n)
```

## Hard rules

1. Do not delete files. Ever. Duplicates and problem files go to `quarantine/`, never `rm`.
2. Do not attempt to script the LRC UI. Hand off with the setup steps in `docs/lrc-setup.md`.
3. Do not guess Apple 2FA codes. When icloudpd prompts, halt and request the code from the user.
4. Do not proceed to the next phase without user approval.
5. Do not modify the scripts under `scripts/` without explicit user request.
6. Do not run destructive commands from `find ... -delete` or `rm -rf` under any circumstance. Move to quarantine instead.

## What each phase does

| # | Script | Purpose |
|---|---|---|
| 0 | `scripts/00-prereqs.sh` | Write config, install icloudpd/exiftool/fdupes, create folder tree. |
| 1 | `scripts/01-extract.sh` | icloudpd extraction. Resume-safe, multi-night. |
| 2 | `scripts/02-organise.sh` | Verify canonical folder structure. Optional Live Photo separation. |
| 3 | `scripts/03-dedupe.sh` | Content-hash dedup to quarantine. |
| 4 | `scripts/04-generate-xmp.sh` | Sidecars for raw, embedded XMP/IPTC for HEIC/JPEG/TIFF/PNG. |
| 5 | `scripts/05-validate.sh` | Integrity sample + markdown report. |
| 6 | (LRC handoff) | User configures import in LRC UI. |
| 7 | Install `config/com.icloudsync.plist.template` | Monthly delta sync via launchd. |

Full success criteria live in `ghcp-agent-prompt.md`.

## Resuming after interruption

All scripts are idempotent. If a phase was interrupted:
- Just re-run the same script
- icloudpd, exiftool, and fdupes all skip existing work
- Report to user before resuming, so they know the state

## Long-running commands

Phase 1 runs for many hours. When starting it:
1. Confirm `caffeinate -dimsu -w $$` is running in a separate terminal
2. Warn the user that VS Code must remain open
3. Suggest checking back in the morning

Do not attempt to background icloudpd via `nohup` or `&`. The interactive 2FA flow needs a foregrounded process.
