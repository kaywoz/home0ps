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
  0 8 * * *   python3 /boot/config/home0ps/media-sort.py digest

Jobs:
  sort     list the download remote, ask the classifier, `rclone moveto` each item into
           <library>/<Title (Year)>[/Season NN]/; duplicates and collisions go to a dated holding
           folder (_sort/dupes/YYYY-MM-DD/). The download remote is emptied item by item; an item
           leaves it only through a successful moveto.
  junk     delete OS metadata files (._*, .DS_Store, Thumbs.db) on the library remote.
  holding  delete dated holding folders (_sort/<area>/YYYY-MM-DD) older than HOLDING_DAYS. The date
           is the folder name (the day it was parked), never the files' modtime: moved files keep
           their original modtime, so --min-age would delete freshly parked items.
  digest   daily Slack message (incoming webhook, URL in a secret file) of the last 24 h from the
           log: sorted, parked, would-sort (dry runs), cleanup, errors. No message on a quiet day;
           RUN_DIGEST!=1 or no webhook file -> printed only.
  check    print the settings and the plan for `sort` without moving anything (same as dry run).

Stopping (Ctrl-C, kill, hangup): the running rclone gets one SIGINT and stops cleanly, the run logs
INTERRUPTED, pings Healthchecks /fail and exits 130; the lock is released by the OS. A move cut
short is recorded in STATE_FILE (on /boot, survives reboots) and finished first by the next real
sort run, so an item is never left split between the download remote and a library. A second
Ctrl-C kills rclone immediately.

Settings: /boot/config/home0ps/media-sort.env (override with MEDIA_SORT_ENV=<file>); see
media-sort.env.example. Healthchecks: one ping per run with a summary as the ping body
(/fail on errors), so the last run's report is visible in Healthchecks.
"""
import datetime, fcntl, json, os, re, signal, subprocess, sys, time, urllib.request

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
_missing = [k for k in ("RCLONE_CONFIG", "SRC", "LIB_REMOTE", "LIBRARIES", "LOG_FILE", "CLASSIFIER_URL",
                        "TOKEN_FILE") if not E.get(k)]
if _missing:
    sys.exit(f"{ENV_FILE} is missing: {', '.join(_missing)} (see media-sort.env.example)")
RCLONE = [E.get("RCLONE_BIN", "rclone"), "--config", E["RCLONE_CONFIG"]]
SRC = E["SRC"].rstrip("/")                                   # e.g. putio:
LIB = E["LIB_REMOTE"]                                        # e.g. filen-crypt:
LIBS = dict(p.split("=", 1) for p in E["LIBRARIES"].split(";") if "=" in p)  # name=path
HOLD = E.get("HOLDING", "_sort").strip("/")
LOG_FILE = E["LOG_FILE"]
MIN_AGE = int(E.get("MIN_AGE_MIN", "15")) * 60
LOG_LINES = []
STATE_FILE = E.get("STATE_FILE", "/boot/config/home0ps/media-sort.inprogress")  # survives reboots
CHILD = None          # the rclone process currently running (own process group)
STOP = None           # name of the signal that asked us to stop


class Interrupted(Exception):
    pass


def on_signal(signum, frame):
    """Ctrl-C / kill / hangup: let the running rclone stop cleanly, then unwind and clean up.
    rclone runs in its own process group, so only this handler forwards the signal to it, once."""
    global STOP
    if STOP:                                   # second signal: stop waiting for rclone
        if CHILD and CHILD.poll() is None:
            CHILD.kill()
        raise Interrupted(STOP)
    STOP = signal.Signals(signum).name
    print(f"\n{STOP} received: stopping after cleanup (again to force)", flush=True)
    if CHILD and CHILD.poll() is None:
        CHILD.send_signal(signal.SIGINT)       # rclone finishes or aborts its transfers cleanly
    else:
        raise Interrupted(STOP)


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
    global CHILD
    if STOP:
        raise Interrupted(STOP)
    cmd = RCLONE + list(args) + (["-P", "--stats", "2s"] if progress else [])
    pipe = None if progress else subprocess.PIPE
    CHILD = subprocess.Popen(cmd, stdout=pipe, stderr=pipe, text=True, start_new_session=True)
    try:
        out, err = CHILD.communicate()
    finally:
        rc, CHILD = CHILD.returncode, None
    r = subprocess.CompletedProcess(cmd, rc, out, err)
    if STOP:
        raise Interrupted(STOP)
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
    """The log may live in /var/log (MOS UI shows it), which is RAM: keep it capped at LOG_MAX_KB
    so it can never fill the rootfs (MISTAKES 2026-11-10, media mount cache). Trims to the newest
    half of the cap, at a line boundary. On the RAM rootfs the log is lost on reboot."""
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    cap = int(E.get("LOG_MAX_KB", "2048")) * 1024
    try:
        size = os.path.getsize(LOG_FILE)
    except OSError:
        return
    if size <= cap:
        return
    with open(LOG_FILE, "rb") as f:
        f.seek(size - cap // 2)
        tail = f.read()
    tail = tail[tail.find(b"\n") + 1:]
    tmp = LOG_FILE + ".tmp"
    with open(tmp, "wb") as f:
        f.write(tail)
    os.replace(tmp, LOG_FILE)


def classify(items, existing):
    token = open(E["TOKEN_FILE"]).read().strip()
    body = json.dumps({"items": items, "existing": existing}).encode()
    req = urllib.request.Request(E["CLASSIFIER_URL"].rstrip("/") + "/classify", body,
                                 {"Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.load(r)["results"]


def save_state(d):
    with open(STATE_FILE + ".tmp", "w") as f:
        json.dump(d, f)
    os.replace(STATE_FILE + ".tmp", STATE_FILE)


def clear_state():
    for f in (STATE_FILE, STATE_FILE + ".tmp"):
        try:
            os.remove(f)
        except FileNotFoundError:
            pass


def resume(run):
    """A move that was interrupted (signal, crash, reboot) is finished first: running the same
    `moveto` again moves what's left and skips what already arrived, so the item ends up whole."""
    try:
        st = json.load(open(STATE_FILE))
    except (OSError, ValueError):
        return 0
    if not run:
        log(f"interrupted move pending (resumes on the next real run): {st['line']}")
        return 0
    log(f"RESUME interrupted move: {st['line']}")
    src_left = rclone("lsjson", "--stat", st["src"], check=False).returncode == 0
    if src_left:
        rclone("moveto", st["src"], st["dst"], progress=True)
        if st["is_dir"]:
            rclone("rmdirs", st["src"], check=False)
    if not exists(st["dst"]):
        log(f"ERROR resume: {st['dst']} missing and nothing left at {st['src']}; check by hand")
        return 1
    clear_state()
    log(f"resumed: {st['name']} complete")
    return 0


def job_sort(run):
    now = time.time()
    if resume(run):
        return 1, ["ERROR resuming an interrupted move (see log)"]
    log(f"listing {src_path()} ...")
    entries = json.loads(rclone("lsjson", "--max-depth", "1", src_path()).stdout or "[]")
    log(f"found {len(entries)} entr{'y' if len(entries) == 1 else 'ies'} on the download remote")
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
            log(f"listed {name}: {len(files)} file(s)")
        items.append(it)
    if not items:
        log("nothing to sort")
        return 0, ["nothing to sort"]
    existing = {}
    for lib, path in LIBS.items():
        if lib.startswith("_"):
            continue
        existing[lib] = [n.rstrip("/") for n in rclone("lsf", "--max-depth", "1", lib_path(path)).stdout.splitlines()]
        log(f"library {lib}: {len(existing[lib])} entries")
    today = f"{datetime.date.today():%F}"
    report, errors = [], 0
    total = len(items)
    for i, it in enumerate(items, 1):                 # one classifier call per item: progress per item
        name = it["name"]
        src = src_path(name)
        log(f"[{i}/{total}] classifying {name} ...")
        t0 = time.time()
        try:
            r = classify([it], existing)[0]
        except Exception as e:
            errors += 1
            log(f"[{i}/{total}] ERROR classifier: {e}; {name} stays on the download remote")
            continue
        log(f"[{i}/{total}] {r.get('library')} ({r.get('source')}, {r.get('confidence')}) in {time.time() - t0:.1f} s")
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
        if not r.get("duplicate_of") and r.get("library") in existing:   # later items see this one
            existing[r["library"]].append(r.get("target") or name)
        if not run:
            log("PLAN " + line)
            continue
        log("MOVE " + line)
        try:
            save_state({"name": name, "src": src, "dst": dst, "is_dir": it["is_dir"], "line": line})
            rclone("moveto", src, dst, progress=True)
            if not exists(dst):
                raise RuntimeError("destination missing after move")
            if it["is_dir"]:                                  # only empty folders are left behind
                rclone("rmdirs", src, check=False)
            clear_state()
        except Interrupted:
            raise
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


def job_digest(run):
    """Daily Slack digest of the last 24 h from the log: sorted, parked, cleaned, errors."""
    since = datetime.datetime.now() - datetime.timedelta(hours=24)
    groups = {"Sorted": [], "Parked (duplicate / collision)": [], "Would sort (dry run)": [],
              "Cleanup": [], "Errors": []}
    try:
        lines = open(LOG_FILE).read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        m = re.match(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) media-sort: (.*)$", line)
        if not m or datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S") < since:
            continue
        msg = m.group(2)
        if msg.startswith("MOVE "):
            body = msg[5:]
            groups["Parked (duplicate / collision)" if (" DUPLICATE of " in body or " COLLISION with " in body)
                   else "Sorted"].append(body)
        elif msg.startswith("PLAN delete") or msg.startswith("DELETE ") or msg.startswith("junk cleanup"):
            groups["Cleanup"].append(msg)
        elif msg.startswith("PLAN "):
            groups["Would sort (dry run)"].append(msg[5:])
        elif msg.startswith("ERROR"):
            groups["Errors"].append(msg)
    total = sum(len(v) for k, v in groups.items() if k != "Cleanup")
    if not total and not groups["Cleanup"]:
        log("digest: nothing in the last 24 h, no message")
        return 0, ["nothing in the last 24 h"]
    parts = [f"*Media sorter, last 24 h* ({datetime.date.today():%F})"]
    for title, items in groups.items():
        if items:
            parts.append(f"*{title}* ({len(items)})\n" + "\n".join("• " + i[:300] for i in items[:60])
                         + (f"\n… and {len(items) - 60} more" if len(items) > 60 else ""))
    text = "\n\n".join(parts)[:35000]
    hook = E.get("SLACK_WEBHOOK_FILE", "")
    if not (run and hook and os.path.exists(hook)):
        print(text)
        log("digest printed only (RUN_DIGEST!=1 or no SLACK_WEBHOOK_FILE)")
        return 0, ["digest printed, not sent"]
    url = open(hook).read().strip()
    req = urllib.request.Request(url, json.dumps({"text": text}).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        ok = resp.status == 200
    log(f"digest sent to Slack ({total} item lines)" if ok else f"ERROR digest: Slack answered {resp.status}")
    return (0 if ok else 1), [f"digest {'sent' if ok else 'failed'}"]


def main():
    job = sys.argv[1] if len(sys.argv) > 1 else "check"
    if job not in ("sort", "junk", "holding", "digest", "check"):
        sys.exit("usage: media-sort.py sort|junk|holding|digest|check")
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
    guard()                                  # trim again at the start of each run
    fn = {"sort": job_sort, "check": job_sort, "junk": job_junk, "holding": job_holding,
          "digest": job_digest}[job]
    log(f"start {job} ({'run' if run else 'dry run'})")
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)
    try:
        errors, report = fn(run)
    except Interrupted as e:
        msg = f"INTERRUPTED by {e} during {job}"
        if os.path.exists(STATE_FILE):
            msg += f"; partial move recorded, the next real sort run finishes it: {json.load(open(STATE_FILE))['line']}"
        log(msg)
        for f in (LOG_FILE + ".tmp",):               # leftovers of an interrupted log trim
            if os.path.exists(f):
                os.remove(f)
        if job in ("sort", "junk", "holding"):
            ping(False, msg)
        sys.exit(130)
    except Exception as e:
        errors, report = 1, [f"ERROR {e}"]
        log(f"ERROR {e}")
    summary = f"{job} ({'run' if run else 'dry run'}): {len(report)} line(s), {errors} error(s)\n" + "\n".join(report)
    log(f"done {job}: {errors} error(s)")
    if job in ("sort", "junk", "holding"):
        ping(errors == 0, summary)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
