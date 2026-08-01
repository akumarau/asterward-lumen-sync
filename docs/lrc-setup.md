# Lightroom Classic Setup

Images live on `/Volumes/TOSHIBA_AK`. The catalog must not.

## Move the catalog off the exFAT drive first

If your catalog sits on the exFAT drive, for example `/Volumes/YOUR_DRIVE/Lightroom Catalog/MyCatalog/MyCatalog.lrcat`, move it. An `.lrcat` is a SQLite database, and exFAT provides no reliable file locking, so a catalog stored there can corrupt on an unclean eject, a sleep event, or a USB dropout. Adobe does not support catalogs on removable or non-native volumes.

Do this before importing anything:

1. Quit Lightroom Classic.
2. Copy the whole catalog folder to `~/Pictures/Lightroom/`. Copy, do not move, so the original stays as a fallback.
3. Double-click the `.lrcat` inside `~/Pictures/Lightroom/` to open it.
4. Confirm your folders and previews resolve. The image paths on the HDD are unchanged, so nothing should show as missing.
5. Once you are satisfied, rename the copy on the HDD to `Lightroom Catalog OLD` so you cannot open it by accident.

Budget 20 to 60 GB of internal SSD for previews across 31k photos. Smart Previews cost more, only enable them if you edit away from the drive.

Why this matters. LRC stores image *paths* in the catalog, not the images themselves. All metadata edits, keywords, ratings, virtual copies, and preview thumbnails live in the catalog. Keeping it on internal SSD keeps browsing, filtering, and searching fast even when the underlying images sit on slower HDD storage, and keeps the database on a filesystem that can lock properly.

## Initial import of the migration batch

Do this once, after `05-validate.sh` passes.

1. Open Lightroom Classic. Confirm the SSD-hosted catalog is open.
2. File > Import Photos and Video (or Cmd+Shift+I).
3. Source panel (left): navigate to `/Volumes/TOSHIBA_AK/iCloud_Import/originals/`. Tick "Include Subfolders".
4. Top bar: select **Add**. This leaves files in place and only adds catalog entries.
5. Right panel:
   - **File Handling**: Build Previews = Standard, Build Smart Previews = off, Do Not Import Suspected Duplicates = on.
   - **Apply During Import > Metadata**: None. Phase 4 already wrote copyright into the raw sidecars and into the HEIC/JPEG files themselves.
   - **Apply During Import > Keywords**: `iCloud Migration, 2026` (optional, useful for later filtering).
   - **Destination**: not applicable in Add mode.
6. Click Import.

For 850 GB, expect the initial import to take 3 to 6 hours depending on catalog size. Preview generation continues in the background.

## Ongoing monthly imports

The delta sync drops new phone captures into `originals/YYYY/YYYY-MM/`. Two ways to get them into the catalog.

**Pattern B, recommended.** Skip Auto Import entirely. After each monthly delta sync, run File > Import, source `/Volumes/TOSHIBA_AK/iCloud_Import/originals/` with Include Subfolders on, Add mode, Do Not Import Suspected Duplicates on. Takes two minutes and cannot go wrong.

**Pattern A, only if you want daily automation.** LRC's Watched Folder does not recurse, so it cannot watch the dated tree directly. You would point it at a flat staging folder such as `/Volumes/TOSHIBA_AK/iCloud_Import/watch_inbox/`, modify `99-delta-sync.sh` to move new files there, and set Move To plus Subfolder `{yyyy}/{yyyy}-{MM}` so LRC files them. That is an extra moving step on a drive that is already the slow link, for a monthly cadence. Not worth it.

## Merging into the existing Photo Library

`/Volumes/TOSHIBA_AK/Photo Library/` already uses the same `YYYY/YYYY-MM` convention, so the two trees can be merged later with a plain copy. Do it only after Phase 5 passes and after you have reviewed `quarantine/`. Keeping the import separate until then is what stops dedup from ever touching your curated library.

## Recommended Smart Collections after import

Create these in the Library module for triage:

- `iCloud Migration - needs keywording`: Keywords contains `iCloud Migration`, no other keywords.
- `iCloud Migration - flagged for delete`: pick flag = rejected, source folder contains `iCloud_Import`.
- `iCloud Migration - ProRAW`: file type = DNG, camera model contains `iPhone`.
- `iCloud Migration - Live Photos`: camera model contains `iPhone`, has associated MOV (if you kept them).
