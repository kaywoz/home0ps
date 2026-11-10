#!/usr/bin/env python3
"""Media classifier (kaywoz/home0ps#260): decides which library a new download goes to.

Stateless HTTP service on the apps VM. The mover on the storage host POSTs item names; this
service never sees files, file contents or remote credentials, and never moves or deletes.

  POST /classify   Authorization: Bearer <token>
       {"items": [{"name": "...", "is_dir": true, "files": ["a.mkv", ...]}],
        "existing": {"<library>": ["<top-level name>", ...]}}
  ->   {"results": [{"name", "kind", "title", "year", "season", "library", "target", "source",
                     "confidence", "rule_library", "llm_library", "disagreement", "reason",
                     "duplicate_of"}]}
       target = folder name in the library ("Title (Year)"); the mover puts a single episode file
       under target/Season NN/, everything else at target/ (a lone movie file inside target/).
  GET  /health     -> 200 "ok" (no auth)

The local LLM is the judge on every item; the rules (rules.json, in git) are tripwires:
  1. no video files                          -> unsorted (non-media), no LLM needed
  2. parse the name (guessit), TMDB metadata; no match -> the LLM cleans the name, search again
  3. duplicate of an existing library entry   -> duplicate_of set (the existing copy wins)
  4. the LLM judges: library + confidence + a one-line reason, from name, parse, metadata and
     the rules' suggestion
  5. a firm rule (x-genre, anime, series) disagrees -> the rule wins (x-side), logged
     low confidence                                -> the default library for the kind
     LLM error                                     -> the rule, else the default library
"""
import json, os, re, sys, time, unicodedata, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from guessit import guessit

RULES = json.load(open(os.environ.get("RULES_FILE", "/app/rules.json")))
TOKEN = open(os.environ.get("TOKEN_FILE", "/run/secrets/mediasort_token")).read().strip()
TMDB_TOKEN = open(os.environ.get("TMDB_TOKEN_FILE", "/run/secrets/tmdb_token")).read().strip()
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434")
MODEL = os.environ.get("OLLAMA_MODEL", "qwen3:4b-instruct")
NUM_THREAD = int(os.environ.get("OLLAMA_NUM_THREAD", "3"))  # = the Ollama container's cpus: (#261)
PORT = int(os.environ.get("PORT", "8089"))

VIDEO = {e.lower() for e in RULES["video_extensions"]}
_tmdb_cache, _key_cache = {}, {}


def log(**kv):
    print(json.dumps(kv, ensure_ascii=False), flush=True)


def norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "", re.sub(r"^(the|a|an)\s+", "", s))


def parse(name):
    g = guessit(name)
    kind = "episode" if g.get("type") == "episode" else "movie"
    title = g.get("title") or name
    if isinstance(title, list):
        title = " ".join(title)
    year = g.get("year")
    if isinstance(year, list):
        year = year[0]
    season = g.get("season")
    if isinstance(season, list):
        season = season[0]
    return kind, str(title), (int(year) if year else None), season


def key_of(name):
    if name not in _key_cache:
        try:
            _, t, y, _ = parse(name)
            _key_cache[name] = (norm(t), y)
        except Exception:
            _key_cache[name] = (norm(name), None)
    return _key_cache[name]


def tmdb(path, **params):
    url = "https://api.themoviedb.org/3" + path + "?" + urllib.parse.urlencode(params)
    if url in _tmdb_cache:
        return _tmdb_cache[url]
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TMDB_TOKEN,
                                               "Accept": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                data = json.load(r)
            _tmdb_cache[url] = data
            return data
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 2:      # docs: respect 429
                raise
            time.sleep(2 * (attempt + 1))


def metadata(kind, title, year):
    """Best TMDB match with genres, languages, countries and companies, or None."""
    if kind == "movie":
        params = {"query": title, "include_adult": "false"}
        if year:
            params["year"] = year
        hits = tmdb("/search/movie", **params).get("results", [])
        if not hits and year:
            hits = tmdb("/search/movie", query=title, include_adult="false").get("results", [])
        if not hits:
            return None
        d = tmdb(f"/movie/{hits[0]['id']}")
        date = d.get("release_date") or ""
    else:
        params = {"query": title, "include_adult": "false"}
        if year:
            params["first_air_date_year"] = year
        hits = tmdb("/search/tv", **params).get("results", [])
        if not hits:
            return None
        d = tmdb(f"/tv/{hits[0]['id']}")
        date = d.get("first_air_date") or ""
    return {
        "tmdb_id": d.get("id"),
        "title": d.get("title") or d.get("name") or title,
        "year": int(date[:4]) if date[:4].isdigit() else year,
        "genres": [g["name"] for g in d.get("genres", [])],
        "language": d.get("original_language"),
        "countries": d.get("origin_country") or [c.get("iso_3166_1") for c in d.get("production_countries", [])],
        "companies": [c["name"] for c in d.get("production_companies", [])],
        "overview": (d.get("overview") or "")[:400],
    }


def by_rules(kind, meta):
    """Tripwire: (library, reason) when a firm rule applies, else (None, reason)."""
    r = RULES
    if kind == "episode":
        return r["series_library"], "series"
    if meta is None:
        return None, "no metadata"
    genres = set(meta["genres"])
    hit = genres & set(r["x_genres"])
    if hit:
        return r["x_library"], "genre " + ", ".join(sorted(hit))
    if "Animation" in genres and meta["language"] in r["anime_languages"]:
        if set(meta["companies"]) & set(r["anime_exceptions"]):
            return r["plain_library"], "animation, excepted studio"
        return r["x_library"], "anime"
    return None, "no firm rule (genres " + (", ".join(sorted(genres)) or "none") + ")"


def ollama(prompt, schema, num_predict=160):
    body = {"model": MODEL, "prompt": prompt, "stream": False, "think": False, "format": schema,
            "options": {"temperature": 0, "num_predict": num_predict, "num_thread": NUM_THREAD}}
    req = urllib.request.Request(OLLAMA_URL + "/api/generate", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(json.load(r)["response"])


def llm_clean_name(name):
    """The parser and TMDB found nothing: let the LLM pull a clean title/year out of a messy name."""
    out = ollama(
        "Extract the real title of the film or TV series from this download name. Ignore site names, "
        "release groups, quality, codec and language tags.\n"
        f"Name: {name}",
        {"type": "object", "properties": {
            "title": {"type": "string"},
            "year": {"type": ["integer", "null"]},
            "kind": {"type": "string", "enum": ["movie", "episode"]}},
         "required": ["title", "year", "kind"]}, num_predict=64)
    return out.get("kind", "movie"), str(out.get("title") or "").strip(), out.get("year")


def llm_judge(name, kind, title, year, meta, rule_lib, rule_reason):
    """The verdict on every item: library, confidence and a one-line reason."""
    libs = [RULES["plain_library"], RULES["x_library"], RULES["series_library"]]
    facts = {"file_name": name, "parsed": {"kind": kind, "title": title, "year": year},
             "metadata": meta or "none found", "rule_suggestion": rule_lib or "none",
             "rule_reason": rule_reason}
    out = ollama(
        RULES["llm_instructions"] + "\n\n"
        f"Libraries: {', '.join(libs)}. Series and episodes always go to {RULES['series_library']}.\n"
        "Answer 'low' confidence when the metadata is missing, thin, or the film is borderline.\n"
        "Reason: one short sentence a person can read in a report.\n\n"
        "Facts: " + json.dumps(facts, ensure_ascii=False),
        {"type": "object", "properties": {
            "library": {"type": "string", "enum": libs},
            "confidence": {"type": "string", "enum": ["high", "low"]},
            "reason": {"type": "string"}},
         "required": ["library", "confidence", "reason"]})
    if out.get("library") not in libs:
        raise ValueError("LLM answered outside the allowed libraries")
    return out["library"], out.get("confidence", "low"), str(out.get("reason", ""))[:200]


def safe(s):
    return re.sub(r'[\\/:*?"<>|]+', " ", s).strip()


def classify(item, existing):
    name = item["name"]
    files = item.get("files") or ([name] if not item.get("is_dir") else [])
    res = {"name": name, "kind": None, "title": None, "year": None, "season": None, "library": None,
           "target": None, "source": None, "confidence": None, "rule_library": None,
           "llm_library": None, "disagreement": False, "reason": None, "duplicate_of": None}
    if not any(os.path.splitext(f)[1].lower() in VIDEO for f in files):
        res.update(library=RULES["unsorted_library"], target=name, source="rules",
                   confidence="high", reason="no video files")
        return res
    kind, title, year, season = parse(name)
    notes = []
    meta = None
    try:
        meta = metadata(kind, title, year)
    except Exception as e:
        notes.append(f"metadata error: {e}")
    if meta is None:                       # messy name? let the LLM clean it and search again
        try:
            k2, t2, y2 = llm_clean_name(name)
            if t2 and (norm(t2), y2) != (norm(title), year):
                notes.append(f"llm cleaned name to '{t2}' ({y2})")
                kind, title, year = (k2 if kind == "movie" else kind), t2, (y2 or year)
                meta = metadata(kind, title, year)
        except Exception as e:
            notes.append(f"name cleanup failed: {e}")
    if meta:
        title, year = meta["title"], meta["year"] or year
    res.update(kind=kind, title=title, year=year, season=season)
    res["target"] = safe(f"{title} ({year})" if year else title)

    # duplicate: same normalised title (+ year when both have one) anywhere in the libraries
    for lib, names in (existing or {}).items():
        for n in names:
            nt, ny = key_of(n)
            if nt == norm(title) and (ny is None or year is None or ny == year):
                res["duplicate_of"] = f"{lib}/{n}"
                break
        if res["duplicate_of"]:
            break

    rule_lib, rule_reason = by_rules(kind, meta)
    res["rule_library"] = rule_lib
    default = RULES["default_library"][kind]
    try:
        llm_lib, conf, why = llm_judge(name, kind, title, year, meta, rule_lib, rule_reason)
        res.update(llm_library=llm_lib, confidence=conf)
        if rule_lib and llm_lib != rule_lib:          # tripwire: a firm rule overrules the LLM
            res.update(disagreement=True, library=rule_lib, source="rules (llm disagreed)")
            notes.append(f"llm said {llm_lib}: {why}; rule: {rule_reason}")
        elif conf == "low":                           # unsure -> the default library
            res.update(library=default, source="fallback (llm unsure)")
            notes.append(f"llm (low confidence) said {llm_lib}: {why}")
        else:
            res.update(library=llm_lib, source="llm")
            notes.append(why)
    except Exception as e:
        res.update(library=rule_lib or default, source="rules" if rule_lib else "fallback",
                   confidence="low")
        notes.append(f"llm error: {e}; {rule_reason}")
    res["reason"] = "; ".join(n for n in notes if n)
    return res


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        data = obj.encode() if isinstance(obj, str) else json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json" if not isinstance(obj, str) else "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(200, "ok") if self.path == "/health" else self._send(404, "not found")

    def do_POST(self):
        if self.path != "/classify":
            return self._send(404, "not found")
        if self.headers.get("Authorization", "") != "Bearer " + TOKEN:
            return self._send(401, "unauthorized")
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n > 4_000_000:
                return self._send(413, "too large")
            req = json.loads(self.rfile.read(n))
            results = []
            for item in req.get("items", [])[:200]:
                r = classify(item, req.get("existing"))
                log(event="classified", **r)
                results.append(r)
            self._send(200, {"results": results})
        except Exception as e:
            log(event="error", error=str(e))
            self._send(500, {"error": str(e)})

    def log_message(self, fmt, *args):
        pass  # one JSON line per decision instead (journald via the Docker log driver)


if __name__ == "__main__":
    if len(sys.argv) > 1:  # local test: classifier.py "<name>" [...]  (no HTTP)
        for n in sys.argv[1:]:
            print(json.dumps(classify({"name": n, "is_dir": False}, {}), ensure_ascii=False))
        sys.exit(0)
    log(event="start", port=PORT, model=MODEL, num_thread=NUM_THREAD)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
