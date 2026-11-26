#!/usr/bin/env python3
"""Fail when a compose file uses a Docker named volume (.claude/rules/compose.md: bind mounts only).

Usage: no-named-volumes.py compose.yaml [...]   exit 1 and one line per finding, else exit 0.
A mount is a bind mount when its source is a path: ./ ../ / ~ or a ${VAR} (interpolated host path).
Anything else (a bare name, `type: volume`, a top-level `volumes:`) is a named volume. tmpfs is fine.
"""
import sys

import yaml

PATH_PREFIXES = ("./", "../", "/", "~", "$")


def findings(path):
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    out = []
    if "volumes" in doc:
        out.append(f"{path}: top-level `volumes:` declares named volumes {sorted((doc['volumes'] or {}).keys())}")
    for name, svc in (doc.get("services") or {}).items():
        for v in (svc or {}).get("volumes") or []:
            if isinstance(v, dict):
                kind, src = v.get("type", "volume"), str(v.get("source", ""))
                if kind == "volume" or (kind == "bind" and not src.startswith(PATH_PREFIXES)):
                    out.append(f"{path}: service {name}: named volume {src or '(anonymous)'} (type: {kind})")
            else:
                src = str(v).split(":", 1)[0]
                if ":" not in str(v) or not src.startswith(PATH_PREFIXES):
                    out.append(f"{path}: service {name}: named or anonymous volume '{v}'")
    return out


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    bad = [line for p in argv[1:] for line in findings(p)]
    for line in bad:
        print(line)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
