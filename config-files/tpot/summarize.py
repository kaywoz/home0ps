#!/usr/bin/env python3
"""Summarise T-Pot LLM honeypot logs (Beelzebub SSH + Galah HTTP).

Usage: python3 -I summarize.py <raw-dir> <out-dir>

<raw-dir> holds beelzebub/log/beelzebub.json* and galah/log/galah.json*
(plain or .gz, as T-Pot rotates them). Writes summary.md, commands.csv,
credentials.csv and http.csv into <out-dir>.

All log content is attacker-controlled: it is only ever parsed as JSON and
written out escaped. Nothing from the logs is executed or fetched.
"""
import collections
import csv
import gzip
import html
import json
import re
import sys
from pathlib import Path

TOP = 50
URL_RE = re.compile(r"""(?:https?|ftp|tftp)://[^\s'"`<>|;)]+""", re.I)
ERR_RE = re.compile(r"^Error ExecuteModel: (.*), (Post \"https?://\S+\": .*|no choices.*)$", re.S)


def read_lines(path):
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def files(raw, name):
    return sorted((raw / name / "log").glob(f"{name}.json*"))


def md(value, limit=160):
    """Escape for a Markdown table cell: no HTML, pipes, backticks or newlines."""
    s = "" if value is None else str(value)
    s = "".join(ch if ch.isprintable() or ch == "\n" else "�" for ch in s)
    s = s.replace("\r", "").replace("\n", "\\n")
    if len(s) > limit:
        s = s[: limit - 1] + "…"
    s = html.escape(s, quote=False).replace("|", "&#124;").replace("`", "&#96;")
    return s or "(empty)"


def defang(url):
    return url.replace("http", "hxxp", 1).replace("ftp", "fxp", 1).replace(".", "[.]")


class Seen:
    """Count, distinct sessions/sources and first/last timestamp per key."""

    def __init__(self):
        self.count = 0
        self.sessions = set()
        self.sources = set()
        self.first = None
        self.last = None

    def add(self, ts, session=None, src=None):
        self.count += 1
        if session:
            self.sessions.add(session)
        if src:
            self.sources.add(src)
        if ts:
            self.first = ts if self.first is None or ts < self.first else self.first
            self.last = ts if self.last is None or ts > self.last else self.last


def span(items):
    ts = [t for t in items if t]
    return (min(ts), max(ts)) if ts else ("-", "-")


def main(raw, out):
    raw, out = Path(raw), Path(out)

    # ---- Beelzebub (SSH) ------------------------------------------------
    ssh_status = collections.Counter()
    ssh_src = collections.Counter()
    commands = collections.defaultdict(Seen)
    command_kind = collections.defaultdict(collections.Counter)
    creds = collections.Counter()
    users = collections.Counter()
    session_users = collections.Counter()
    llm_errors = collections.Counter()
    llm_reasons = collections.Counter()
    ssh_ts = []
    sessions = {"inline": set(), "interactive": set()}
    clients = collections.Counter()

    for f in files(raw, "beelzebub"):
        for d in read_lines(f):
            ts = d.get("timestamp")
            msg = d.get("msg") or d.get("message") or ""
            status = d.get("status")
            src = d.get("src_ip")
            sess = d.get("session")
            if ts:
                ssh_ts.append(ts)
            if src:
                ssh_src[src] += 1
            m = ERR_RE.match(msg)
            if m:
                llm_errors[m.group(1)] += 1
                llm_reasons[re.sub(r'Post "[^"]*": ', '', m.group(2))[:80]] += 1
                ssh_status["LLM error"] += 1
                continue
            ssh_status[f"{status or '-'}: {msg}"] += 1
            if d.get("client_version"):
                clients[d["client_version"]] += 1
            # Only "Stateless / New SSH attempt" carries the password; session
            # starts carry the username they logged in with.
            if status == "Stateless" and d.get("username") is not None:
                users[d.get("username")] += 1
                creds[(d.get("username"), d.get("password"))] += 1
            elif status == "Start" and d.get("username") is not None:
                session_users[d.get("username")] += 1
            kind = None
            if status == "Start" and "Inline" in msg:
                kind = "inline"
            elif status == "Interaction":
                kind = "interactive"
            if status == "Start" and "Inline" not in msg and sess:
                sessions["interactive"].add(sess)
            if kind:
                if sess:
                    sessions[kind].add(sess)
                cmd = d.get("input")
                if cmd:
                    commands[cmd].add(ts, sess, src)
                    command_kind[cmd][kind] += 1

    # ---- Galah (HTTP) ---------------------------------------------------
    http = collections.defaultdict(Seen)
    http_gen = collections.defaultdict(collections.Counter)
    http_result = collections.Counter()
    http_src = collections.Counter()
    gen_total = collections.Counter()
    agents = collections.Counter()
    tags = collections.Counter()
    bodies = collections.Counter()
    http_ts = []

    for f in files(raw, "galah"):
        for d in read_lines(f):
            if "request.requestURI" not in d:
                continue
            ts = d.get("timestamp")
            if ts:
                http_ts.append(ts)
            src = d.get("src_ip")
            key = (d.get("request.method") or "-", d.get("request.requestURI") or "-")
            http[key].add(ts, d.get("session"), src)
            gen = d.get("response.metadata.generationSource") or "-"
            ok = d.get("msg") == "successfulResponse"
            http_gen[key][gen if ok else "failed"] += 1
            gen_total[gen if ok else "failed (" + (d.get("msg") or "-") + ")"] += 1
            http_result["ok" if ok else "failed"] += 1
            if src:
                http_src[src] += 1
            agents[d.get("request.userAgent") or "(none)"] += 1
            for t in (d.get("tags") or "").split(","):
                if t.strip():
                    tags[t.strip()] += 1
            if d.get("request.body"):
                bodies[d["request.body"]] += 1

    # ---- URLs seen in commands and request bodies (defanged) ------------
    urls = collections.Counter()
    for cmd, seen in commands.items():
        for u in URL_RE.findall(cmd):
            urls[u] += seen.count
    for body, n in bodies.items():
        for u in URL_RE.findall(body):
            urls[u] += n

    # ---- CSV outputs ----------------------------------------------------
    with open(out / "commands.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["command", "count", "inline", "interactive", "sessions", "sources", "first_seen", "last_seen"])
        for cmd, s in sorted(commands.items(), key=lambda kv: -kv[1].count):
            k = command_kind[cmd]
            w.writerow([cmd, s.count, k["inline"], k["interactive"], len(s.sessions), len(s.sources), s.first, s.last])
    with open(out / "credentials.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["username", "password", "count"])
        for (u, p), n in creds.most_common():
            w.writerow([u, p, n])
    with open(out / "http.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["method", "uri", "count", "sources", "llm", "cache", "static", "failed", "first_seen", "last_seen"])
        for (meth, uri), s in sorted(http.items(), key=lambda kv: -kv[1].count):
            g = http_gen[(meth, uri)]
            w.writerow([meth, uri, s.count, len(s.sources), g["llm"], g["cache"], g["static"], g["failed"], s.first, s.last])

    # ---- Markdown summary -----------------------------------------------
    L = []
    a, b = span(ssh_ts)
    c, e = span(http_ts)
    L += ["# T-Pot LLM honeypot export", "",
          "All values below are attacker-controlled and escaped; URLs are defanged.", "",
          "| | SSH (Beelzebub) | HTTP (Galah) |", "|---|---|---|",
          f"| First event | {a} | {c} |", f"| Last event | {b} | {e} |",
          f"| Events | {sum(ssh_status.values())} | {sum(http_result.values())} |",
          f"| Distinct sources | {len(ssh_src)} | {len(http_src)} |",
          f"| Distinct commands / paths | {len(commands)} | {len(http)} |", ""]

    L += ["## SSH", "",
          f"- Login attempts (username/password pairs): {sum(creds.values())}, distinct pairs: {len(creds)}",
          f"- Inline exec sessions: {len(sessions['inline'])}; interactive sessions: {len(sessions['interactive'])}",
          f"- Commands run: {sum(s.count for s in commands.values())} ({len(commands)} distinct)",
          f"- LLM call errors: {sum(llm_errors.values())}", ""]
    L += ["### Event types", "", "| Count | Status: message |", "|---:|---|"]
    L += [f"| {n} | {md(k, 100)} |" for k, n in ssh_status.most_common(15)] + [""]
    L += ["### Top sources", "", "| Events | Source |", "|---:|---|"]
    L += [f"| {n} | {md(k)} |" for k, n in ssh_src.most_common(15)] + [""]
    L += [f"### Top {TOP} commands (all in commands.csv)", "",
          "| Count | Inline | Interactive | Sessions | Sources | Last seen | Command |", "|---:|---:|---:|---:|---:|---|---|"]
    for cmd, s in sorted(commands.items(), key=lambda kv: -kv[1].count)[:TOP]:
        k = command_kind[cmd]
        L.append(f"| {s.count} | {k['inline']} | {k['interactive']} | {len(s.sessions)} | {len(s.sources)} | {s.last} | {md(cmd, 200)} |")
    L += ["", "### Top credentials (all in credentials.csv)", "", "| Count | Username | Password |", "|---:|---|---|"]
    L += [f"| {n} | {md(u, 40)} | {md(p, 40)} |" for (u, p), n in creds.most_common(25)] + [""]
    L += ["### Top usernames in login attempts", "", "| Count | Username |", "|---:|---|"]
    L += [f"| {n} | {md(u, 40)} |" for u, n in users.most_common(15)] + [""]
    L += ["### Usernames that opened a session (any password is accepted)", "", "| Sessions | Username |", "|---:|---|"]
    L += [f"| {n} | {md(u, 40)} |" for u, n in session_users.most_common(15)] + [""]
    L += ["### SSH client versions", "", "| Count | Client |", "|---:|---|"]
    L += [f"| {n} | {md(k, 80)} |" for k, n in clients.most_common(10)] + [""]
    if llm_reasons:
        L += ["### LLM error reasons", "", "| Count | Reason |", "|---:|---|"]
        L += [f"| {n} | {md(k, 100)} |" for k, n in llm_reasons.most_common(10)] + [""]
    if llm_errors:
        L += ["### Commands whose LLM call failed (top 15)", "", "| Count | Command |", "|---:|---|"]
        L += [f"| {n} | {md(k, 200)} |" for k, n in llm_errors.most_common(15)] + [""]

    L += ["## HTTP", "",
          f"- Requests: {sum(http_result.values())} (ok {http_result['ok']}, failed {http_result['failed']})", ""]
    L += ["### Response source", "", "| Count | Source |", "|---:|---|"]
    L += [f"| {n} | {md(k, 80)} |" for k, n in gen_total.most_common()] + [""]
    L += ["### Top sources", "", "| Requests | Source |", "|---:|---|"]
    L += [f"| {n} | {md(k)} |" for k, n in http_src.most_common(15)] + [""]
    L += [f"### Top {TOP} paths (all in http.csv)", "",
          "| Count | Sources | llm | cache | static | failed | Method | Path |", "|---:|---:|---:|---:|---:|---:|---|---|"]
    for (meth, uri), s in sorted(http.items(), key=lambda kv: -kv[1].count)[:TOP]:
        g = http_gen[(meth, uri)]
        L.append(f"| {s.count} | {len(s.sources)} | {g['llm']} | {g['cache']} | {g['static']} | {g['failed']} | {md(meth, 10)} | {md(uri, 160)} |")
    L += ["", "### Top user agents", "", "| Count | User-Agent |", "|---:|---|"]
    L += [f"| {n} | {md(k, 120)} |" for k, n in agents.most_common(15)] + [""]
    if tags:
        L += ["### Galah tags", "", "| Count | Tag |", "|---:|---|"]
        L += [f"| {n} | {md(k, 60)} |" for k, n in tags.most_common(15)] + [""]

    L += ["## URLs in commands and request bodies (defanged)", ""]
    if urls:
        L += ["| Count | URL |", "|---:|---|"]
        L += [f"| {n} | {md(defang(u), 200)} |" for u, n in urls.most_common(50)]
    else:
        L += ["None."]
    L.append("")

    (out / "summary.md").write_text("\n".join(L), encoding="utf-8")
    print(f"summarize: {sum(s.count for s in commands.values())} commands ({len(commands)} distinct), "
          f"{sum(creds.values())} login attempts, {sum(http_result.values())} HTTP requests -> {out}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: summarize.py <raw-dir> <out-dir>")
    main(sys.argv[1], sys.argv[2])
