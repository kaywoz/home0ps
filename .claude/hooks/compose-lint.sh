#!/usr/bin/env bash
# compose-lint.sh -- Claude Code PostToolUse hook for home0ps (.claude/rules/compose.md, "Lint gate").
#
# After an Edit/Write to docker-compose/**/compose.yaml, lints that file with compose-lint and the
# stack's .compose-lint.yml. Findings at medium or above go back to Claude (exit 2, report on stderr) so
# they are fixed in the same change. PostToolUse cannot undo the edit; CI is the gate.
#
# Uses `compose-lint` on PATH, else `uvx` with the pinned version. Neither present: note on stderr,
# exit 0 (CI still lints). homenas stacks run with --allow-partial-coverage: their .env is
# host-only, so ${VAR} mounts are graded in CI from .env.example instead.
# Portable to macOS (bash 3.2). Usage: hook reads JSON on stdin.

set -Euo pipefail
trap 'echo "compose-lint hook: internal error on line $LINENO" >&2; exit 0' ERR

VERSION="1.8.2"
input=$(cat)

if command -v jq >/dev/null 2>&1; then
  path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
elif command -v python3 >/dev/null 2>&1; then
  path=$(printf '%s' "$input" | python3 -I -c 'import sys,json; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))')
else
  exit 0
fi

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
case "$path" in
  "$root"/docker-compose/*/compose.yaml|"$root"/docker-compose/homenas/*/compose.yaml) ;;
  docker-compose/*/compose.yaml|docker-compose/homenas/*/compose.yaml) path="$root/$path" ;;
  *) exit 0 ;;
esac
[ -f "$path" ] || exit 0

if command -v compose-lint >/dev/null 2>&1; then
  lint=(compose-lint)
elif command -v uvx >/dev/null 2>&1; then
  lint=(uvx --quiet --from "compose-lint==$VERSION" compose-lint)
else
  echo "compose-lint hook: compose-lint and uvx not found; skipped (CI lints)" >&2
  exit 0
fi

extra=()
case "$path" in */docker-compose/homenas/*) extra=(--allow-partial-coverage) ;; esac

# `|| rc=$?` keeps a lint failure out of the ERR trap.
rc=0
out=$(cd "$root" && "${lint[@]}" check --strict-config \
  --fail-on medium --skip-suppressed -q ${extra[@]+"${extra[@]}"} "$path" 2>&1) || rc=$?

case "$rc" in
  0) exit 0 ;;
  1) printf 'compose-lint: findings at medium or above in %s. Fix them, or add a recorded exception to .compose-lint.yml beside it.\n%s\n' "${path#"$root"/}" "$out" >&2
     exit 2 ;;
  *) printf 'compose-lint: could not lint %s (exit %s):\n%s\n' "${path#"$root"/}" "$rc" "$out" >&2
     exit 2 ;;
esac
