# GHCP Kickoff Prompt: Asterward Lumen Sync

Copy the block below and paste it into GitHub Copilot Chat in **agent mode** with **Claude Opus** selected as the model. Do this once. From that point the agent understands the workflow and you can just say "run phase 1" or "resume" for subsequent sessions.

---

## Copy from here

You are the executing agent for Asterward Lumen Sync, an iCloud Photos to Lightroom Classic migration on macOS. Read `.github/copilot-instructions.md`, `README.md`, and `ghcp-agent-prompt.md` in this workspace before doing anything else. These define your operating rules, phase execution model, and success criteria. Follow them exactly.

Your first task is a preflight check, not any migration work. Do the following in order and report back with a single status table:

1. Confirm the target drive is mounted: `test -d /Volumes/TOSHIBA_AK && echo "mounted" || echo "NOT MOUNTED"`
2. Report free space: `df -g /Volumes/TOSHIBA_AK 2>/dev/null | awk 'NR==2 {print $4" GB free"}'`
3. Confirm config exists and is populated: `cat config/migration.env 2>/dev/null || echo "no config, run 00-prereqs.sh"`
4. Confirm no phase has been run yet by checking whether `/Volumes/TOSHIBA_AK/iCloud_Import/logs/` exists and listing any log files
5. Confirm which tools are present: `command -v icloudpd; command -v exiftool; command -v fdupes; command -v caffeinate`
6. Report `icloudpd --version`. The scripts are verified against 1.33.0.

Produce a preflight table with columns: check | result | action required.

After the table, recommend which phase to start with. Do not run any script yet. Wait for me to say "start phase N".

There are no env vars to export. `00-prereqs.sh` writes `config/migration.env` and every script sources it through `scripts/lib/common.sh`.

If the target drive is not mounted, halt.

## Stop copying here

---

## Session patterns

After the initial kickoff, you can resume in any new VS Code session with short messages. The agent picks up context from the log files and manifests.

**Start Phase 1 for the first time**
> Start phase 1. Verify caffeinate is running before you kick off icloudpd. Expect 2FA prompt on first run.

**Resume Phase 1 after overnight interruption**
> Resume phase 1. Check the last extraction log to see where we stopped, confirm no zero-byte files from the interrupted run, then re-invoke the script.

**Move to next phase**
> Approved. Start phase 2.

**Something went wrong**
> Phase 3 reported errors. Read the log and tell me what happened, do not attempt to fix.

**Check overall status**
> Give me a full migration status: which phases are complete, current file count under originals/, disk usage, and any errors in the last 24 hours.

**Install ongoing sync**
> Phase 7. Install the launchd plist and verify it's loaded. Do not attempt a manual delta sync yet.

## When to reset the agent context

If Copilot Chat gets confused (unusual after a fresh session), start a new chat and paste the kickoff prompt again. The ambient `.github/copilot-instructions.md` handles most context automatically once you're in the workspace.
