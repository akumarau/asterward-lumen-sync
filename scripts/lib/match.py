#!/usr/bin/env python3
"""Asterward Lumen Sync: match iCloud downloads against a Lightroom catalogue.

Standard library only. Reads a COPY of the .lrcat (opened read only) and EXIF
data that exiftool wrote as JSON. Never writes to the catalogue and never
touches files under originals/.

Subcommands
  match   ORIGINALS LRCAT EXIF_JSON OUT_CSV
          Tier every iCloud file against the catalogue.
  report  MATCH_CSV OUT_DIR
          Write a local HTML page summarising the tiers (thumbnails are added
          by the shell wrapper, which owns exiftool).
  copy    MATCH_CSV ORIGINALS DEST MANIFEST TIERS MIN_FREE_GB
          Copy files in the chosen tiers into DEST/YYYY/YYYY-MM/YYYY-MM-DD,
          verify each copy by SHA-256, never overwrite.

Tiers
  1 same_file     catalogue holds a file with the same name and capture time
  2 same_shot     same camera and the same capture moment, different file
  3 edited_export tier 2, and the iCloud file was written by Lightroom or Photoshop
  4 review        a near match that a person should look at
  5 new           not in the catalogue
"""

import csv
import hashlib
import html
import json
import os
import re
import shutil
import sqlite3
import sys
from collections import defaultdict
from datetime import datetime, timedelta

VIDEO_EXT = {"mov", "mp4", "m4v", "avi", "mts", "m2ts", "3gp"}
SIZE_SUFFIX = re.compile(r"-[0-9]{3,}$")
EDITORS = re.compile(r"lightroom|photoshop|camera raw", re.I)
# Camera file name inside an export name, e.g. 20261017-_DSC4016-Edit -> _DSC4016
CAMERA_STEM = re.compile(r"(?:^|[^A-Z0-9])(_?DSC[0-9]{4,5}|C[0-9]{4})(?![0-9])")
TIER_NAMES = {1: "same_file", 2: "same_shot", 3: "edited_export", 4: "review", 5: "new"}


# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------
def ms3(sub):
    """Normalise a sub-second string to 3 digits, or None."""
    if sub is None:
        return None
    digits = re.sub(r"\D", "", str(sub))
    if not digits:
        return None
    return (digits + "000")[:3]


def parse_lr_time(value):
    """Lightroom captureTime, e.g. 2026-07-26T16:27:01.349 -> (second, ms)."""
    if not value:
        return None, None
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?", value)
    if not m:
        return None, None
    sec = "%s-%s-%sT%s:%s:%s" % m.groups()[:6]
    return sec, ms3(m.group(7))


def parse_exif_time(value, sub=None):
    """EXIF 2026:07:26 16:27:01[.349][+10:00] -> (second, ms). Local time, offset ignored."""
    if not value or not isinstance(value, str):
        return None, None
    m = re.match(r"(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?", value)
    if not m or m.group(1) == "0000":
        return None, None
    sec = "%s-%s-%sT%s:%s:%s" % m.groups()[:6]
    return sec, ms3(m.group(7)) or ms3(sub)


def norm_model(model):
    return re.sub(r"\s+", " ", str(model or "")).strip().upper()


def plain_stem(name):
    stem = os.path.splitext(os.path.basename(name))[0]
    return SIZE_SUFFIX.sub("", stem).upper()


def ext_of(name):
    return os.path.splitext(name)[1][1:].lower()


# ---------------------------------------------------------------------------
# Catalogue index
# ---------------------------------------------------------------------------
def load_catalogue(lrcat):
    db = sqlite3.connect("file:%s?mode=ro" % lrcat, uri=True)
    rows = db.execute(
        """
        SELECT r.absolutePath || fo.pathFromRoot, f.baseName, f.extension,
               COALESCE(f.sidecarExtensions, ''), i.captureTime, i.fileFormat,
               COALESCE(cm.value, '')
        FROM Adobe_images i
        JOIN AgLibraryFile f ON i.rootFile = f.id_local
        JOIN AgLibraryFolder fo ON f.folder = fo.id_local
        JOIN AgLibraryRootFolder r ON fo.rootFolder = r.id_local
        LEFT JOIN AgHarvestedExifMetadata e ON e.image = i.id_local
        LEFT JOIN AgInternedExifCameraModel cm ON cm.id_local = e.cameraModelRef
        WHERE i.masterImage IS NULL
        """
    ).fetchall()
    by_shot = defaultdict(list)      # (model, second) -> [(ms, record)]
    by_name = defaultdict(list)      # (stem, ext) -> [record]
    videos_by_stem = defaultdict(list)
    for folder, base, ext, sidecars, capture, fmt, model in rows:
        sec, ms = parse_lr_time(capture)
        rec = {
            "path": folder + base + "." + ext,
            "stem": base.upper(),
            "ext": ext.lower(),
            "second": sec,
            "ms": ms,
            "model": norm_model(model),
            "format": fmt,
        }
        if sec and rec["model"]:
            by_shot[(rec["model"], sec)].append(rec)
        by_name[(rec["stem"], rec["ext"])].append(rec)
        for side in sidecars.split(","):
            side = side.strip().lower()
            if side and side != "xmp":
                by_name[(rec["stem"], side)].append(rec)
        if fmt == "VIDEO" or rec["ext"] in VIDEO_EXT:
            videos_by_stem[rec["stem"]].append(rec)
    return {"by_shot": by_shot, "by_name": by_name, "videos": videos_by_stem, "count": len(rows)}


# ---------------------------------------------------------------------------
# Tiering
# ---------------------------------------------------------------------------
def exif_capture(entry):
    """Best capture time from an exiftool JSON entry."""
    for key, sub in (
        ("SubSecDateTimeOriginal", None),
        ("DateTimeOriginal", entry.get("SubSecTimeOriginal")),
        ("SubSecCreateDate", None),
        ("CreateDate", entry.get("SubSecTimeDigitized")),
    ):
        sec, ms = parse_exif_time(entry.get(key), sub)
        if sec:
            return sec, ms
    return None, None


def tier_photo(entry, cat):
    name = entry["FileName"]
    stem, ext = plain_stem(name), ext_of(name)
    sec, ms = exif_capture(entry)
    model = norm_model(entry.get("Model"))
    software = str(entry.get("Software") or "")

    if sec and model:
        candidates = cat["by_shot"].get((model, sec), [])
        if candidates:
            same_frame = [c for c in candidates if ms and c["ms"] and c["ms"] == ms]
            unknown_ms = not ms or all(not c["ms"] for c in candidates)
            if same_frame or (unknown_ms and len(candidates) == 1):
                hit = (same_frame or candidates)[0]
                if hit["stem"] == stem and hit["ext"] == ext:
                    return 1, "same name and capture time", hit["path"]
                if EDITORS.search(software):
                    return 3, "export of a catalogue photo (%s)" % software.strip(), hit["path"]
                return 2, "same camera and capture moment", hit["path"]
            if EDITORS.search(software):
                # Lightroom desktop and mobile exports rewrite the sub-second
                # time, so for edited files match on the second and use the
                # camera file name embedded in the export name, if any.
                named = CAMERA_STEM.search(stem)
                if named:
                    same_stem = [c for c in candidates if c["stem"].lstrip("_") == named.group(1).lstrip("_")]
                    if same_stem:
                        return 3, "export of a catalogue photo (%s)" % software.strip(), same_stem[0]["path"]
                    return 4, "export of %s, which is not in the catalogue (culled frame?)" % named.group(1), candidates[0]["path"]
                if len(candidates) == 1:
                    return 3, "export of a catalogue photo, sub-second rewritten (%s)" % software.strip(), candidates[0]["path"]
                return 4, "export, %d catalogue frames in the same second" % len(candidates), candidates[0]["path"]
            if unknown_ms:
                return 4, "%d catalogue frames in the same second, no sub-second time to pick one" % len(candidates), candidates[0]["path"]
            return 4, "same second, different frame (burst frame not in catalogue?)", candidates[0]["path"]

    # No usable EXIF. Fall back to an exact name match with the same day if known.
    named = cat["by_name"].get((stem, ext), [])
    if named:
        if sec and any(n["second"] and n["second"][:10] == sec[:10] for n in named):
            return 4, "same file name and day, camera or time missing", named[0]["path"]
        if not sec:
            return 4, "same file name, no capture time to compare", named[0]["path"]
    return 5, "no catalogue match", ""


def tier_video(entry, cat, mtime_day):
    stem = plain_stem(entry["FileName"])
    candidates = cat["videos"].get(stem, [])
    if not candidates:
        return 5, "no catalogue video with this name", ""
    sec, _ = exif_capture(entry)
    day = (sec or "")[:10] or mtime_day
    for c in candidates:
        if c["second"] and day:
            d1 = datetime.strptime(c["second"][:10], "%Y-%m-%d")
            d2 = datetime.strptime(day, "%Y-%m-%d")
            if abs(d1 - d2) <= timedelta(days=1):
                return 2, "catalogue video with the same name and date", c["path"]
    return 4, "catalogue video with the same name, different date", candidates[0]["path"]


def cmd_match(originals, lrcat, exif_json, out_csv):
    cat = load_catalogue(lrcat)
    with open(exif_json, encoding="utf-8") as fh:
        entries = json.load(fh)
    rows = []
    for e in entries:
        src = e.get("SourceFile", "")
        rel = os.path.relpath(src, originals)
        if rel.startswith(".."):
            continue
        e.setdefault("FileName", os.path.basename(src))
        ext = ext_of(e["FileName"])
        if ext == "xmp":
            continue
        try:
            st = os.stat(src)
            size, mtime = st.st_size, st.st_mtime
        except OSError:
            size, mtime = e.get("FileSize", ""), None
        mtime_day = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d") if mtime else ""
        if ext in VIDEO_EXT:
            tier, reason, hit = tier_video(e, cat, mtime_day)
        else:
            tier, reason, hit = tier_photo(e, cat)
        sec, _ = exif_capture(e)
        capture_day = (sec or "")[:10] or mtime_day
        rows.append([rel, tier, TIER_NAMES[tier], reason, hit, capture_day, size,
                     norm_model(e.get("Model")), str(e.get("Software") or "").strip()])

    # A Live Photo video follows its still: never import a motion clip whose
    # photo was skipped, and never skip one whose photo is new.
    # It also takes the still's capture day, so the pair lands in one folder.
    stills = {}
    for r in rows:
        if ext_of(r[0]) not in VIDEO_EXT:
            stills[(os.path.dirname(r[0]), plain_stem(r[0]))] = r
    for r in rows:
        if ext_of(r[0]) in VIDEO_EXT:
            stem = plain_stem(r[0])
            key = (os.path.dirname(r[0]), stem[:-5] if stem.endswith("_HEVC") else stem)
            still = stills.get(key)
            if not still:
                continue
            r[5] = still[5] or r[5]
            if r[1] == 5 and still[1] in (1, 2, 3):
                r[1], r[2], r[3] = still[1], TIER_NAMES[still[1]], "Live Photo video of a skipped still"

    rows.sort(key=lambda r: (r[1], r[0]))
    with open(out_csv, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["relpath", "tier", "tier_name", "reason", "catalogue_match",
                    "capture_day", "size_bytes", "camera", "software"])
        w.writerows(rows)
    counts = defaultdict(int)
    for r in rows:
        counts[r[1]] += 1
    print("Catalogue images indexed: %d" % cat["count"])
    for t in sorted(TIER_NAMES):
        print("Tier %d %-14s %d" % (t, TIER_NAMES[t], counts[t]))
    print("Total iCloud files: %d" % len(rows))


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
def cmd_report(match_csv, out_dir, thumbs_json=None):
    with open(match_csv, encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    thumbs = {}
    if thumbs_json and os.path.exists(thumbs_json):
        with open(thumbs_json, encoding="utf-8") as fh:
            thumbs = json.load(fh)
    counts = defaultdict(int)
    for r in rows:
        counts[int(r["tier"])] += 1
    esc = html.escape
    out = ["<!doctype html><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>",
           "<title>Lumen Sync Match</title><style>",
           ":root{--bg:#fbfaf7;--fg:#1d1d1b;--mut:#6b6a66;--line:#e4e1da;--acc:#3b5bdb}",
           "@media (prefers-color-scheme:dark){:root{--bg:#161616;--fg:#ecebe8;--mut:#9a9893;--line:#2c2c2a;--acc:#91a7ff}}",
           "body{background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,system-ui,sans-serif;margin:0;padding:24px 16px;max-width:1100px;margin:auto}",
           "h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 8px}p{color:var(--mut);margin:0 0 12px}",
           "table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top;font-size:13px}",
           ".pair{display:flex;gap:6px}.pair img{width:120px;height:90px;object-fit:cover;border-radius:4px;background:var(--line)}",
           ".n{font-variant-numeric:tabular-nums;text-align:right}</style>",
           "<h1>Asterward Lumen Sync: catalogue match</h1>",
           "<p>Left thumbnail: iCloud file. Right: the catalogue photo it matched. Tiers 1 to 3 are skipped. Tier 4 needs your decision. Tier 5 is copied.</p>",
           "<table><tr><th>Tier</th><th>Meaning</th><th class=n>Files</th></tr>"]
    meaning = {1: "Same file already in catalogue", 2: "Same shot, different file", 3: "Export of an edited catalogue photo",
               4: "Near match, review", 5: "New, will be copied"}
    for t in sorted(TIER_NAMES):
        out.append("<tr><td>%d</td><td>%s</td><td class=n>%d</td></tr>" % (t, meaning[t], counts[t]))
    out.append("</table>")
    for t, limit in ((4, 400), (3, 80), (2, 80), (1, 40), (5, 120)):
        sel = [r for r in rows if int(r["tier"]) == t][:limit]
        if not sel:
            continue
        shown = " (first %d shown)" % limit if counts[t] > limit else ""
        out.append("<h2>Tier %d: %s%s</h2><table>" % (t, meaning[t], shown))
        for r in sel:
            imgs = ""
            pair = thumbs.get(r["relpath"], {})
            if pair:
                imgs = "<div class=pair>" + "".join(
                    "<img loading=lazy src='%s' alt=''>" % esc(pair[k]) for k in ("icloud", "catalogue") if pair.get(k)) + "</div>"
            out.append("<tr><td>%s</td><td>%s<br><small>%s</small></td><td>%s<br><small>%s %s</small></td></tr>" % (
                imgs, esc(r["relpath"]), esc(r["reason"]), esc(os.path.basename(r["catalogue_match"])),
                esc(r["capture_day"]), esc(r["camera"])))
        out.append("</table>")
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "index.html"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))
    print(os.path.join(out_dir, "index.html"))


# ---------------------------------------------------------------------------
# Copy
# ---------------------------------------------------------------------------
def sha256(path, buf=1024 * 1024):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(buf):
            h.update(chunk)
    return h.hexdigest()


def copy_file(src, dst):
    """Copy bytes and keep the modification time. exFAT cannot store POSIX
    permissions, so a failed chmod must not fail the copy."""
    shutil.copyfile(src, dst)
    st = os.stat(src)
    try:
        os.utime(dst, (st.st_atime, st.st_mtime))
    except OSError:
        pass


def free_gb(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 1024 ** 3


def cmd_copy(match_csv, originals, dest, manifest, tiers, min_free_gb):
    tiers = {int(t) for t in tiers.split(",") if t.strip()}
    with open(match_csv, encoding="utf-8") as fh:
        rows = [r for r in csv.DictReader(fh) if int(r["tier"]) in tiers]
    done = {}
    if os.path.exists(manifest):
        with open(manifest, encoding="utf-8") as fh:
            for r in csv.DictReader(fh):
                if r["status"] in ("copied", "already_present"):
                    done[r["relpath"]] = r
    new_manifest = not os.path.exists(manifest)
    fh = open(manifest, "a", newline="", encoding="utf-8")
    w = csv.writer(fh)
    if new_manifest:
        w.writerow(["relpath", "destination", "status", "sha256", "size_bytes", "timestamp"])
    copied = present = skipped = failed = 0
    stopped = False
    for r in rows:
        rel = r["relpath"]
        if rel in done:
            skipped += 1
            continue
        src = os.path.join(originals, rel)
        if not os.path.isfile(src):
            w.writerow([rel, "", "missing_source", "", "", datetime.now().isoformat()])
            failed += 1
            continue
        if free_gb(dest) < min_free_gb:
            print("STOP: less than %d GB free on the destination. Nothing more copied." % min_free_gb)
            stopped = True
            break
        day = r["capture_day"] or datetime.fromtimestamp(os.stat(src).st_mtime).strftime("%Y-%m-%d")
        folder = os.path.join(dest, day[:4], day[:7], day)
        os.makedirs(folder, exist_ok=True)
        target = os.path.join(folder, os.path.basename(rel))
        digest = sha256(src)
        n = 1
        status = "copied"
        while os.path.exists(target):
            if os.path.getsize(target) == os.path.getsize(src) and sha256(target) == digest:
                status = "already_present"
                break
            stem, ext = os.path.splitext(os.path.join(folder, os.path.basename(rel)))
            target = "%s__icloud%d%s" % (stem, n, ext)
            n += 1
        if status == "copied":
            tmp = target + ".lumen-tmp"
            copy_file(src, tmp)
            if sha256(tmp) != digest:
                os.replace(tmp, tmp + ".bad")
                w.writerow([rel, target, "hash_mismatch", digest, os.path.getsize(src), datetime.now().isoformat()])
                failed += 1
                continue
            os.replace(tmp, target)
            # Raw sidecar written by Phase 4 travels with its raw file.
            side = os.path.splitext(src)[0] + ".xmp"
            if os.path.isfile(side):
                copy_file(side, os.path.splitext(target)[0] + ".xmp")
            copied += 1
        else:
            present += 1
        w.writerow([rel, target, status, digest, os.path.getsize(src), datetime.now().isoformat()])
        fh.flush()
    fh.close()
    print("Copied: %d, already present: %d, done earlier: %d, failed: %d" % (copied, present, skipped, failed))
    return 1 if failed or stopped else 0


# ---------------------------------------------------------------------------
# Incremental EXIF cache
# ---------------------------------------------------------------------------
def cmd_exif_todo(file_list, cache_json, todo_out):
    """Write the NUL separated paths whose EXIF is missing or stale in the cache."""
    cache = {}
    if os.path.exists(cache_json):
        with open(cache_json, encoding="utf-8") as fh:
            cache = {e["SourceFile"]: e for e in json.load(fh)}
    with open(file_list, "rb") as fh:
        paths = [p.decode("utf-8", "surrogateescape") for p in fh.read().split(b"\0") if p]
    todo = []
    for p in paths:
        st = os.stat(p)
        e = cache.get(p)
        if not e or e.get("_size") != st.st_size or e.get("_mtime") != int(st.st_mtime):
            todo.append(p)
    with open(todo_out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(todo) + ("\n" if todo else ""))
    print(len(todo))


def cmd_exif_merge(file_list, cache_json, new_json):
    cache = {}
    if os.path.exists(cache_json):
        with open(cache_json, encoding="utf-8") as fh:
            cache = {e["SourceFile"]: e for e in json.load(fh)}
    if os.path.exists(new_json) and os.path.getsize(new_json) > 0:
        with open(new_json, encoding="utf-8") as fh:
            for e in json.load(fh):
                st = os.stat(e["SourceFile"])
                e["_size"], e["_mtime"] = st.st_size, int(st.st_mtime)
                cache[e["SourceFile"]] = e
    with open(file_list, "rb") as fh:
        live = {p.decode("utf-8", "surrogateescape") for p in fh.read().split(b"\0") if p}
    kept = [cache[p] for p in sorted(cache) if p in live]
    tmp = cache_json + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(kept, fh)
    os.replace(tmp, cache_json)
    print(len(kept))


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "exif-todo":
        cmd_exif_todo(*args)
    elif cmd == "exif-merge":
        cmd_exif_merge(*args)
    elif cmd == "match":
        cmd_match(*args)
    elif cmd == "report":
        cmd_report(*args)
    elif cmd == "copy":
        sys.exit(cmd_copy(args[0], args[1], args[2], args[3], args[4], float(args[5])))
    else:
        sys.exit(__doc__)
