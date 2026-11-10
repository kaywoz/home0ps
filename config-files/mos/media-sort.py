#!/usr/bin/env python3
"""media-sort.py — the media mover on the MOS host (kaywoz/home0ps#260).

Moves new downloads from the download remote into the libraries on the library remote, as decided
by the media classifier on the apps VM (names in, library out). This host keeps all remote
credentials; the classifier never sees them. Nothing in a library is ever deleted or overwritten:
no `sync`, no `purge`, no `delete` against library folders. Every job is a dry run until its
RUN_* switch is 1 in the settings file. All data-moving rclone calls carry -P (CLAUDE.md §8).

Cron (as root on MOS; via python3: /boot doesn't allow executing files directly):
  0 * * * *   python3 /boot/config/home0ps/media-sort.py sort
  30 4 * * *  python3 /boot/config/home0ps/media-sort.py junk
  45 4 * * *  python3 /boot/config/home0ps/media-sort.py holding

Jobs:
  sort     list the download remote, ask the classifier, `rclone moveto` each item into
           <library>/<Title (Year)>[/Season NN]/; duplicates and collisions go to a dated holding
           folder (_sort/dupes/YYYY-MM-DD/). The download remote is emptied item by item; an item
           leaves it only through a successful moveto.
  junk     delete OS metadata files (._*, .DS_Store, Thumbs.db) on the library remote.
  holding  delete dated holding folders (_sort/<area>/YYYY-MM-DD) older than HOLDING_DAYS. The date
           is the folder name (the day it was parked), never the files' modtime: moved files keep
           their original modtime, so --min-age would delete freshly parked items.
  check    print the settings and the plan for `sort` without moving anything (same as dry run).

Settings: /boot/config/home0ps/media-sort.env (override with MEDIA_SORT_ENV=<file>); see
media-sort.env.example. Healthchecks: one ping per run with a summary as the ping body
(/fail on errors), so the last run's report is visible in Healthchecks.
"""
import datetime, fcntl, json, os, re, subprocess, sys, time, urllib.request

ENV_FILE = os.environ.get("MEDIA_SORT_ENV", "/boot/config/home0ps/media-sort.env")
JUNK = ["._*", ".DS_Store", "Thumbs.db"]
DATED = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def load_env(path):
    env = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


try:
    E = load_env(ENV_FILE)
except OSError:
    sys.exit(f"settings file {ENV_FILE} missing (see media-sort.env.example)")
RCLONE = [E.get("RCLONE_BIN", "rclone"), "--config", E["RCLONE_CONFIG"]]
SRC = E["SRC"].rstrip("/")                                   # e.g. putio:
LIB = E["LIB_REMOTE"]                                        # e.g. filen-crypt:
LIBS = dict(p.split("=", 1) for p in E["LIBRARIES"].split(";") if "=" in p)  # name=path
HOLD = E.get("HOLDING", "_sort").strip("/")
LOG_FILE = E["LOG_FILE"]
MIN_AGE = int(E.get("MIN_AGE_MIN", "15")) * 60
LOG_LINES = []


def log(msg):
    line = f"{datetime.datetime.now():%F %T} media-sort: {msg}"
    LOG_LINES.append(line)
    print(line, flush=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")
    subprocess.run(["logger", "-t", "media-sort", msg], check=False)


def src_path(name=""):
    return SRC + name if SRC.endswith(":") else f"{SRC}/{name}" if name else SRC


def lib_path(p):
    return LIB + p.strip("/")


def rclone(*args, progress=False, check=True):
    cmd = RCLONE + list(args) + (["-P", "--stats", "2s"] if progress else [])
    r = subprocess.run(cmd, capture_output=not progress, text=True)
    if check and r.returncode:
        raise RuntimeError(f"rclone {' '.join(args[:2])} failed ({r.returncode}): {(r.stderr or '')[-300:]}")
    return r


def exists(path):
    return rclone("lsjson", "--stat", path, check=False).returncode == 0


def ping(ok, body):
    url = E.get("PING_URL", "").rstrip("/")
    if not url:
        return
    try:
        urllib.request.urlopen(urllib.request.Request(url + ("" if ok else "/fail"), body.encode()[-90000:]),
                               timeout=10)
    except Exception as e:
        log(f"healthchecks ping failed: {e}")


def guard():
    # MOS's rootfs is RAM: never log there (MISTAKES 2026-11-10, media mount cache)
    d = os.path.dirname(LOG_FILE)
    os.makedirs(d, exist_ok=True)
    if os.stat(d).st_dev == os.stat("/").st_dev:
        sys.exit(f"{d} is on the root filesystem (RAM) — put LOG_FILE on the pool")


def classify(items, existing):
    token = open(E["TOKEN_FILE"]).read().strip()
    body = json.dumps({"items": items, "existing": existing}).encode()
    req = urllib.request.Request(E["CLASSIFIER_URL"].rstrip("/") + "/classify", body,
                                 {"Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.load(r)["results"]


def job_sort(run):
    now = time.time()
    entries = json.loads(rclone("lsjson", "--max-depth", "1", src_path()).stdout or "[]")
    items = []
    for e in entries:
        name = e["Name"]
        if any(re.fullmatch(p.replace(".", r"\.").replace("*", ".*"), name) for p in JUNK):
            continue
        mt = datetime.datetime.fromisoformat(e["ModTime"].replace("Z", "+00:00")).timestamp()
        if now - mt < MIN_AGE:
            log(f"skip (younger than {MIN_AGE // 60} min): {name}")
            continue
        it = {"name": name, "is_dir": e["IsDir"]}
        if e["IsDir"]:
            files = rclone("lsf", "-R", "--files-only", src_path(name)).stdout.splitlines()
            it["files"] = files[:500]
        items.append(it)
    if not items:
        log("nothing to sort")
        return 0, ["nothing to sort"]
    existing = {}
    for lib, path in LIBS.items():
        if lib.startswith("_"):
            continue
        existing[lib] = [n.rstrip("/") for n in rclone("lsf", "--max-depth", "1", lib_path(path)).stdout.splitlines()]
    results = classify(items, existing)
    today = f"{datetime.date.today():%F}"
    report, errors = [], 0
    for it, r in zip(items, results):
        name = it["name"]
        src = src_path(name)
        why = f"[{r.get('source')}, {r.get('confidence')}] {r.get('reason')}"
        if r.get("duplicate_of"):
            dst = lib_path(f"{HOLD}/dupes/{today}/{name}")
            what = f"DUPLICATE of {r['duplicate_of']} -> {HOLD}/dupes/{today}/"
        else:
            path = LIBS.get(r["library"])
            if path is None:
                log(f"ERROR unknown library '{r['library']}' for {name}; left on the download remote")
                errors += 1
                continue
            if r["library"].startswith("_"):                  # unsorted: keep the original name
                dst = lib_path(f"{path}/{name}")
            elif it["is_dir"]:
                dst = lib_path(f"{path}/{r['target']}")
            elif r.get("kind") == "episode":
                season = int(r.get("season") or 1)
                dst = lib_path(f"{path}/{r['target']}/Season {season:02d}/{name}")
            else:
                dst = lib_path(f"{path}/{r['target']}/{name}")
            what = f"-> {dst[len(LIB):]}"
            if exists(dst):                                     # never overwrite: park instead
                what = f"COLLISION with {dst[len(LIB):]} -> {HOLD}/dupes/{today}/"
                dst = lib_path(f"{HOLD}/dupes/{today}/{name}")
        line = f"{name} {what} {why}"
        report.append(line)
        if not run:
            log("PLAN " + line)
            continue
        log("MOVE " + line)
        try:
            rclone("moveto", src, dst, progress=True)
            if not exists(dst):
                raise RuntimeError("destination missing after move")
            if it["is_dir"]:                                  # only empty folders are left behind
                rclone("rmdirs", src, check=False)
        except Exception as e:
            errors += 1
            log(f"ERROR {name}: {e}")
    return errors, report


def job_junk(run):
    args = ["delete", LIB] + sum((["--include", p] for p in JUNK), [])
    if not run:
        args.append("--dry-run")
    log(f"junk cleanup on {LIB} ({'run' if run else 'dry run'})")
    r = rclone(*args, progress=True, check=False)
    return (1 if r.returncode else 0), [f"junk cleanup {'done' if run else 'dry run'} (rc {r.returncode})"]


def job_holding(run):
    days = int(E.get("HOLDING_DAYS", "30"))
    cutoff = datetime.date.today() - datetime.timedelta(days=days)
    report, errors = [], 0
    areas = [a.rstrip("/") for a in rclone("lsf", "--dirs-only", "--max-depth", "1", lib_path(HOLD)).stdout.splitlines()]
    for area in areas:
        for d in rclone("lsf", "--max-depth", "1", lib_path(f"{HOLD}/{area}")).stdout.splitlines():
            name = d.rstrip("/")
            if not (d.endswith("/") and DATED.match(name)):
                report.append(f"undated, left alone: {HOLD}/{area}/{name}")
                continue
            if datetime.date.fromisoformat(name) > cutoff:
                continue
            target = lib_path(f"{HOLD}/{area}/{name}")
            line = f"{'DELETE' if run else 'PLAN delete'} {HOLD}/{area}/{name} (parked {name}, > {days} days)"
            log(line)
            report.append(line)
            if run:
                r = rclone("purge", target, progress=True, check=False)
                errors += 1 if r.returncode else 0
    return errors, report or ["nothing older than the holding period"]


def main():
    job = sys.argv[1] if len(sys.argv) > 1 else "check"
    if job not in ("sort", "junk", "holding", "check"):
        sys.exit("usage: media-sort.py sort|junk|holding|check")
    if os.geteuid() != 0:
        sys.exit("run as root")
    guard()
    lock = open(E.get("LOCK_FILE", "/run/media-sort.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another run is active, skipping")
        return
    run = job != "check" and E.get(f"RUN_{job.upper()}", "0") == "1"
    fn = {"sort": job_sort, "check": job_sort, "junk": job_junk, "holding": job_holding}[job]
    log(f"start {job} ({'run' if run else 'dry run'})")
    try:
        errors, report = fn(run)
    except Exception as e:
        errors, report = 1, [f"ERROR {e}"]
        log(f"ERROR {e}")
    summary = f"{job} ({'run' if run else 'dry run'}): {len(report)} line(s), {errors} error(s)\n" + "\n".join(report)
    log(f"done {job}: {errors} error(s)")
    if job != "check":
        ping(errors == 0, summary)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
