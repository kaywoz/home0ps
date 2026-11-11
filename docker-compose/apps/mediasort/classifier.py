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
  4. films: the LLM answers one question (dark / cult / surreal / transgressive / arthouse /
     genre-adjacent?) yes / no / unsure + a one-line reason; yes or unsure -> xmovies, no -> movies.
     Series go to the series library without asking.
  5. a firm rule (x-genre, anime, series) disagrees -> the rule wins (x-side), logged
     low confidence                                -> the default library for the kind
     LLM error                                     -> the rule, else the default library
"""
import hmac, json, os, re, sys, time, unicodedata, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from guessit import guessit

RULES = json.load(open(os.environ.get("RULES_FILE", "/app/rules.json")))
TOKEN_FILE = os.environ.get("TOKEN_FILE", "/run/secrets/mediasort_token")


def token():
    """Read on every request, so a rotated token works without restarting the container."""
    return open(TOKEN_FILE).read().strip()
TMDB_TOKEN = open(os.environ.get("TMDB_TOKEN_FILE", "/run/secrets/tmdb_token")).read().strip()
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama:11434")
MODEL = os.environ.get("OLLAMA_MODEL", "qwen3:4b-instruct")
NUM_THREAD = int(os.environ.get("OLLAMA_NUM_THREAD", "3"))  # = the Ollama container's cpus: (#261)
# LLM provider: "openai" or "anthropic" (cloud APIs, key from a secret file) or "ollama" (local, #261)
LLM_PROVIDER = os.environ.get("LLM_PROVIDER", "ollama")
OPENAI_MODEL = os.environ.get("OPENAI_MODEL", "gpt-6-luna")
_openai = None
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-haiku-5-5")
# one key file for whichever cloud provider is selected: switching provider = swap the key
LLM_KEY_FILE = os.environ.get("LLM_KEY_FILE", "/run/secrets/llm_key")
_anthropic = None
# cloud rate limits: minimum seconds between LLM calls (e.g. 6.5 for 10 requests/minute), and after a
# 429 no further calls until the provider's retry time (at least 60 s): those items are deferred
LLM_MIN_INTERVAL = float(os.environ.get("LLM_MIN_INTERVAL", "0"))
_llm_last, _llm_blocked_until = 0.0, 0.0


class TransientLLMError(Exception):
    """Rate limit, timeout, connection or server error: try the item again on a later run."""


# the provider's rate limits as last reported in its response headers (OpenAI: x-ratelimit-*,
# Anthropic: anthropic-ratelimit-*); GET /limits shows them, the mover logs them per run
LIMITS = {"provider": None, "model": None, "seen_at": None, "requests": {}, "tokens": {}}


def _duration(v):
    """OpenAI reset format ("1s", "6m0s", "17ms", "1h2m3s") or an RFC 3339 time -> seconds."""
    if not v:
        return None
    m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m(?!s))?(?:(\d+(?:\.\d+)?)s)?(?:(\d+)ms)?", v.strip())
    if m and any(m.groups()):
        h, mi, se, ms = m.groups()
        return int(h or 0) * 3600 + int(mi or 0) * 60 + float(se or 0) + int(ms or 0) / 1000
    try:
        import datetime as _dt
        return max(0.0, (_dt.datetime.fromisoformat(v.replace("Z", "+00:00"))
                         - _dt.datetime.now(_dt.timezone.utc)).total_seconds())
    except ValueError:
        return None


def note_limits(headers, provider, model):
    """Record rate-limit headers; when no requests are left, pause until the reset."""
    global _llm_blocked_until
    if headers is None:
        return
    h = {k.lower(): v for k, v in dict(headers).items()}
    pre = "x-ratelimit-" if provider == "openai" else "anthropic-ratelimit-"
    new = {}
    for kind in ("requests", "tokens"):
        if provider == "openai":
            vals = {f: h.get(f"{pre}{f}-{kind}") for f in ("limit", "remaining", "reset")}
        else:
            vals = {f: h.get(f"{pre}{kind}-{f}") for f in ("limit", "remaining", "reset")}
        if any(vals.values()):
            new[kind] = vals
    if not new:
        return
    changed = any(LIMITS.get(k) != v for k, v in new.items())
    LIMITS.update(new, provider=provider, model=model, seen_at=time.strftime("%Y-%m-%dT%H:%M:%S"))
    if changed:
        log(event="ratelimits", provider=provider, model=model, **new)
    req = new.get("requests", {})
    if req.get("remaining") == "0":
        wait = _duration(req.get("reset"))
        if wait:
            _llm_blocked_until = max(_llm_blocked_until, time.time() + wait)


def _retry_after(e):
    try:
        return float(e.response.headers.get("retry-after", "60"))
    except Exception:
        return 60.0
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


def is_junk(name):
    """OS metadata (._*, .DS_Store, Thumbs.db) in a library listing is not a copy of anything."""
    return name.startswith("._") or name in (".DS_Store", "Thumbs.db")


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


def claude(prompt, schema, max_tokens):
    """Claude API with a JSON-schema answer (structured outputs). Low effort: a short
    classification. The key is read from its file on first use (never an env var)."""
    global _anthropic, _llm_blocked_until
    import anthropic
    if _anthropic is None:
        _anthropic = anthropic.Anthropic(api_key=open(LLM_KEY_FILE).read().strip(),
                                         timeout=60.0, max_retries=2)
    try:
        raw = _anthropic.messages.with_raw_response.create(
            model=ANTHROPIC_MODEL, max_tokens=max_tokens,
            output_config={"effort": "low",
                           "format": {"type": "json_schema", "schema": dict(schema, additionalProperties=False)}},
            messages=[{"role": "user", "content": prompt}])
        note_limits(raw.headers, "anthropic", ANTHROPIC_MODEL)
        resp = raw.parse()
    except anthropic.RateLimitError as e:
        note_limits(getattr(e.response, "headers", None), "anthropic", ANTHROPIC_MODEL)
        _llm_blocked_until = time.time() + max(60.0, _retry_after(e))
        raise TransientLLMError(f"rate limited: {e}")
    except (anthropic.APIConnectionError, anthropic.InternalServerError) as e:
        raise TransientLLMError(str(e))
    if resp.stop_reason == "refusal":
        raise RuntimeError("Claude declined the request")
    if resp.stop_reason == "max_tokens":
        raise RuntimeError("Claude ran out of tokens before answering")
    return json.loads(next(b.text for b in resp.content if b.type == "text"))


def gpt(prompt, schema):
    """OpenAI Responses API with a strict JSON-schema answer (structured outputs), low reasoning
    effort. The key is read from its file on first use (never an env var)."""
    global _openai, _llm_blocked_until
    import openai
    if _openai is None:
        _openai = openai.OpenAI(api_key=open(LLM_KEY_FILE).read().strip(), timeout=60.0, max_retries=2)
    try:
        raw = _openai.responses.with_raw_response.create(
            model=OPENAI_MODEL, input=prompt, reasoning={"effort": "low"}, store=False,
            text={"format": {"type": "json_schema", "name": "answer", "strict": True,
                             "schema": dict(schema, additionalProperties=False)}})
        note_limits(raw.headers, "openai", OPENAI_MODEL)
        resp = raw.parse()
    except openai.RateLimitError as e:
        note_limits(getattr(e.response, "headers", None), "openai", OPENAI_MODEL)
        _llm_blocked_until = time.time() + max(60.0, _retry_after(e))
        raise TransientLLMError(f"rate limited: {e}")
    except (openai.APIConnectionError, openai.InternalServerError) as e:
        raise TransientLLMError(str(e))
    for item in resp.output:                      # a refusal comes back as a content part, not JSON
        for part in getattr(item, "content", None) or []:
            if getattr(part, "type", "") == "refusal":
                raise RuntimeError("OpenAI declined the request")
    if not resp.output_text:
        raise RuntimeError(f"OpenAI returned no answer (status {resp.status})")
    return json.loads(resp.output_text)


def llm(prompt, schema, num_predict=160):
    """The configured LLM. TransientLLMError -> the item is deferred; other errors -> the caller
    falls back to the rules / default library."""
    global _llm_last
    if time.time() < _llm_blocked_until:
        raise TransientLLMError(f"rate limited for another {int(_llm_blocked_until - time.time())} s")
    wait = _llm_last + LLM_MIN_INTERVAL - time.time()
    if wait > 0:
        time.sleep(wait)
    _llm_last = time.time()
    if LLM_PROVIDER == "openai":
        return gpt(prompt, schema)
    if LLM_PROVIDER == "anthropic":
        return claude(prompt, schema, max_tokens=2048)    # room for adaptive thinking at low effort
    return ollama(prompt, schema, num_predict)


def ollama(prompt, schema, num_predict=160):
    body = {"model": MODEL, "prompt": prompt, "stream": False, "think": False, "format": schema,
            "options": {"temperature": 0, "num_predict": num_predict, "num_thread": NUM_THREAD}}
    req = urllib.request.Request(OLLAMA_URL + "/api/generate", json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(json.load(r)["response"])
    except (urllib.error.URLError, TimeoutError) as e:
        raise TransientLLMError(f"local LLM unreachable: {e}")


def llm_clean_name(name):
    """The parser and TMDB found nothing: let the LLM pull a clean title/year out of a messy name."""
    out = llm(
        "Extract the real title of the film or TV series from this download name. Ignore site names, "
        "release groups, quality, codec and language tags.\n"
        f"Name: {name}",
        {"type": "object", "properties": {
            "title": {"type": "string"},
            "year": {"type": "integer", "description": "0 if unknown"},
            "kind": {"type": "string", "enum": ["movie", "episode"]}},
         "required": ["title", "year", "kind"]}, num_predict=64)
    return out.get("kind", "movie"), str(out.get("title") or "").strip(), (out.get("year") or None)


def llm_judge(name, kind, title, year, meta, rule_lib, rule_reason):
    """The verdict on every film: one yes/no/unsure question, which small models answer far more
    reliably than "which library" (kaywoz, 2026-11-10). yes or unsure -> xmovies, no -> movies."""
    facts = {"file_name": name, "title": title, "year": year, "metadata": meta or "none found"}
    out = llm(
        RULES["llm_question"] + "\n\n"
        "Reason: one short sentence a person can read in a report.\n\n"
        "Facts: " + json.dumps(facts, ensure_ascii=False),
        {"type": "object", "properties": {
            "answer": {"type": "string", "enum": ["yes", "no", "unsure"]},
            "reason": {"type": "string"}},
         "required": ["answer", "reason"]}, num_predict=96)
    ans = out.get("answer")
    if ans not in ("yes", "no", "unsure"):
        raise ValueError("LLM answered outside yes/no/unsure")
    lib = RULES["plain_library"] if ans == "no" else RULES["x_library"]
    return lib, ("low" if ans == "unsure" else "high"), f"{ans}: " + str(out.get("reason", ""))[:200]


def safe(s):
    return re.sub(r'[\\/:*?"<>|]+', " ", s).strip()


def classify(item, existing):
    name = item["name"]
    files = item.get("files") or ([name] if not item.get("is_dir") else [])
    res = {"name": name, "kind": None, "title": None, "year": None, "season": None, "library": None,
           "target": None, "source": None, "confidence": None, "rule_library": None,
           "llm_library": None, "disagreement": False, "reason": None, "duplicate_of": None,
           "deferred": False}
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
    cleanup_deferred = None
    if meta is None:                       # messy name? let the LLM clean it and search again
        try:
            k2, t2, y2 = llm_clean_name(name)
            if t2 and (norm(t2), y2) != (norm(title), year):
                notes.append(f"llm cleaned name to '{t2}' ({y2})")
                kind, title, year = (k2 if kind == "movie" else kind), t2, (y2 or year)
                meta = metadata(kind, title, year)
        except TransientLLMError as e:
            cleanup_deferred = str(e)
            notes.append(f"name cleanup deferred: {e}")
        except Exception as e:
            notes.append(f"name cleanup failed: {e}")
    titles, years = {norm(title)}, {year} - {None}
    if meta:
        titles.add(norm(meta["title"]))
        if meta["year"]:
            years.add(meta["year"])
        # the file's own year wins for the folder name: TMDB's date can be a later release
        title, year = meta["title"], year or meta["year"]
    res.update(kind=kind, title=title, year=year, season=season)
    res["target"] = safe(f"{title} ({year})" if year else title)

    # duplicate: same title (parsed or TMDB) anywhere in the libraries, year within one either way
    for lib, names in (existing or {}).items():
        for n in names:
            if is_junk(n):
                continue
            nt, ny = key_of(n)
            if nt in titles and (ny is None or not years or any(abs(ny - y) <= 1 for y in years)):
                res["duplicate_of"] = f"{lib}/{n}"
                break
        if res["duplicate_of"]:
            break

    rule_lib, rule_reason = by_rules(kind, meta)
    res["rule_library"] = rule_lib
    default = RULES["default_library"][kind]
    if kind == "episode":                             # series: one library, nothing to judge
        res.update(library=rule_lib, source="rules", confidence="high")
        res["reason"] = "; ".join(n for n in notes + [rule_reason] if n)
        return res
    if res["duplicate_of"]:                           # parked anyway: don't spend an LLM call on it
        res.update(library=rule_lib or default, source="duplicate", confidence="high")
        res["reason"] = "; ".join(n for n in notes + ["duplicate, no verdict needed"] if n)
        return res
    if cleanup_deferred and not res["duplicate_of"]:  # without a clean name we may miss metadata
        res.update(deferred=True, source="deferred",
                   reason="; ".join(notes + ["deferred to a later run"]))
        return res
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
    except TransientLLMError as e:
        if res["duplicate_of"]:                       # parked anyway: the verdict doesn't matter
            res.update(library=rule_lib or default, source="rules" if rule_lib else "fallback",
                       confidence="low")
            notes.append(f"llm deferred ({e}); duplicate, parked anyway")
        else:
            res.update(deferred=True, source="deferred")
            notes.append(f"llm unavailable ({e}); deferred to a later run")
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
        if self.path == "/health":
            return self._send(200, "ok")
        if self.path.split("?")[0] != "/limits":
            return self._send(404, "not found")
        if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token()):
            return self._send(401, "unauthorized")
        # ?probe=1: one minimal LLM call (counts against the quota) to read fresh headers
        probe_error = None
        if "probe=1" in self.path and LLM_PROVIDER in ("openai", "anthropic"):
            try:
                llm("Answer ok.", {"type": "object", "properties": {"ok": {"type": "string"}},
                                   "required": ["ok"]}, num_predict=8)
            except Exception as e:
                probe_error = str(e)[:300]
        out = dict(LIMITS, provider=LIMITS["provider"] or LLM_PROVIDER,
                   paused_for_s=max(0, int(_llm_blocked_until - time.time())))
        if probe_error:
            out["probe_error"] = probe_error
        self._send(200, out)

    def do_POST(self):
        if self.path != "/classify":
            return self._send(404, "not found")
        if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token()):
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
    log(event="start", port=PORT, provider=LLM_PROVIDER,
        model={"openai": OPENAI_MODEL, "anthropic": ANTHROPIC_MODEL}.get(LLM_PROVIDER, MODEL))
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
