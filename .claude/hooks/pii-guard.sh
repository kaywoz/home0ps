#!/usr/bin/env bash
# pii-guard.sh -- Claude Code PreToolUse hook for home0ps (CLAUDE.md §4).
#
# Blocks a tool call (exit 2, reason on stderr) when what it would publish
# contains a device name (a word ending in -y), an email address, or a word
# from the local private list. Checked:
#   - Bash `git push`: added lines and messages of every commit being pushed
#   - Bash `gh pr ...` / `gh issue ...`: the command text
#   - GitHub MCP writes (matcher in .claude/settings.json): the tool input
# Allowed: -y names in DNS record files (iac/cloudflare/), Tailscale Service
# names (svc:<app>-<device>), noreply/example addresses, git@github.com.
#
# Private words (real names, local account names) never go into git. They
# come from `git config user.name/user.email` and, if present, one per line
# from ${XDG_CONFIG_HOME:-$HOME/.config}/home0ps/private-words.
#
# Portable to macOS (bash 3.2, BSD grep/sed). Any internal error blocks the
# call (fail closed). Usage: hook reads JSON on stdin; --self-test runs tests.

set -Euo pipefail
trap 'echo "pii-guard: internal error on line $LINENO; blocked to be safe. Ask kaywoz." >&2; exit 2' ERR

DEVICE_RE='(^|[^A-Za-z0-9_-])[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]-y([^A-Za-z0-9_-]|$)'
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

private_words() {
  local f="${XDG_CONFIG_HOME:-$HOME/.config}/home0ps/private-words"
  {
    git config --get user.name 2>/dev/null || true
    git config --get user.email 2>/dev/null || true
    if [ -f "$f" ]; then cat "$f"; fi
  } | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -viE '^(kaywoz|claude.*|github-actions.*|.*noreply.*)$' \
    | awk 'length($0) >= 3' || true
}

# Remove what is allowed everywhere: Service names, noreply/example/git addresses.
strip_allowed() {
  sed -E \
    -e 's/svc:[A-Za-z0-9-]+//g' \
    -e 's/[A-Za-z0-9._%+-]*noreply[A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+//g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]*noreply[A-Za-z0-9.-]*//g' \
    -e 's/[A-Za-z0-9._%+-]+@example\.(com|org|net)//g' \
    -e 's/git@github\.com//g'
}

# check TEXT -> prints reasons, one per line; empty output = clean.
check() {
  local text clean hit w
  text="$1"
  clean="$(printf '%s\n' "$text" | strip_allowed)"
  hit="$(printf '%s\n' "$clean" | grep -oE "$DEVICE_RE" | sed -E 's/^[^A-Za-z0-9]//; s/[^A-Za-z0-9]$//' | head -3 | tr '\n' ' ' || true)"
  if [ -n "$hit" ]; then echo "device name (word ending in -y): $hit"; fi
  hit="$(printf '%s\n' "$clean" | grep -oE "$EMAIL_RE" | head -3 | tr '\n' ' ' || true)"
  if [ -n "$hit" ]; then echo "email address: $hit"; fi
  while IFS= read -r w; do
    [ -z "$w" ] && continue
    if printf '%s\n' "$text" | grep -iF -- "$w" >/dev/null; then
      echo "a word from the private list (not shown)"
      break
    fi
  done <<EOF
$(private_words)
EOF
}

# Text published by `git push`: added lines outside iac/cloudflare/ plus
# commit messages, for commits not yet on the remote.
push_text() {
  local dir="$1" range
  if git -C "$dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    range='@{u}..HEAD'
  else
    range='origin/main..HEAD'
  fi
  git -C "$dir" log --format='%B' "$range"
  git -C "$dir" log -p --format='' "$range" -- . ':(exclude)iac/cloudflare' \
    | grep -E '^\+' | grep -vE '^\+\+\+ ' || true
}

block() {
  {
    echo "pii-guard blocked this call (CLAUDE.md §4, no PII or device names):"
    printf '%s\n' "$1" | sed 's/^/  - /'
    echo "Remove it and retry. If it is a false positive, stop and ask kaywoz."
  } >&2
  exit 2
}

run_hook() {
  local input tool body cmd dir reasons
  input="$(cat)"
  tool="$(printf '%s' "$input" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"
  # Drop session fields that hold local paths (home folder = account name).
  body="$(printf '%s' "$input" | sed -E \
    -e 's/"(cwd|transcript_path|session_id|permission_mode|tool_use_id)"[[:space:]]*:[[:space:]]*"[^"]*"//g')"

  if [ "$tool" = "Bash" ]; then
    cmd="$body"
    if printf '%s' "$cmd" | grep -E '(^|[^A-Za-z0-9_-])gh[[:space:]]+(pr|issue)[[:space:]]' >/dev/null; then
      reasons="$(check "$cmd")"
      [ -n "$reasons" ] && block "$reasons"
    fi
    if printf '%s' "$cmd" | grep -E '(^|[^A-Za-z0-9_-])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|"|$)' >/dev/null; then
      dir="$(printf '%s' "$cmd" | grep -oE '(cd|git[[:space:]]+-C)[[:space:]]+[^[:space:];&|"]+' | head -1 | sed -E 's/^(cd|git[[:space:]]+-C)[[:space:]]+//' || true)"
      dir="${dir/#\~/$HOME}"
      if [ -z "$dir" ]; then
        dir="$(printf '%s' "$input" | grep -oE '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"
      fi
      if [ -z "$dir" ] || ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        block "can't find the repository for this git push; run it as 'cd REPO && git push ...'"
      fi
      reasons="$(check "$(push_text "$dir")")"
      [ -n "$reasons" ] && block "$reasons"
    fi
    exit 0
  fi

  # Any other tool routed here by the matcher (GitHub MCP writes).
  reasons="$(check "$body")"
  [ -n "$reasons" ] && block "$reasons"
  exit 0
}

self_test() {
  local fails=0 out tmp D M
  # Test values are assembled at runtime so this file never contains them.
  D="fake""-y"; M="someone@mailhost"".test"
  t() { # expect(block|pass) name text
    out="$(check "$3")"
    if { [ "$1" = block ] && [ -n "$out" ]; } || { [ "$1" = pass ] && [ -z "$out" ]; }; then
      echo "ok   $2"
    else
      echo "FAIL $2 -> got: ${out:-clean}"; fails=$((fails + 1))
    fi
  }
  export XDG_CONFIG_HOME; XDG_CONFIG_HOME="$(mktemp -d)"
  mkdir -p "$XDG_CONFIG_HOME/home0ps"
  printf 'Testy Person\n' >"$XDG_CONFIG_HOME/home0ps/private-words"

  t block "device name in text"        "moved the stack to $D today"
  t block "device name in JSON body"   "{\"body\":\"see host $D\\n\"}"
  t pass  "Service name"               "serve svc:cockpit-$D on 443"
  t pass  "apt-get -y flag"            'apt-get install -y curl'
  t pass  "rule text about -y"         'real device names end in `-y` and never go into git'
  t block "email"                      "contact $M"
  t pass  "noreply attribution"        'Co-Authored-By: Claude <noreply@anthropic.com>'
  t pass  "GitHub bot address"         '41898282+github-actions[bot]@users.noreply.github.com'
  t pass  "example address"            'user@example.com'
  t pass  "git remote"                 'git@github.com:kaywoz/home0ps.git'
  t block "private word"               'thanks, testy person'
  t pass  "maintainer handle"          'kaywoz merged it'

  # git push: temporary repo with a remote, one clean and one dirty commit.
  tmp="$(mktemp -d)"
  (
    cd "$tmp" && git init -q -b main remote.git --bare && git init -q -b main work && cd work &&
    git config user.name kaywoz && git config user.email kaywoz@users.noreply.github.com &&
    git remote add origin ../remote.git &&
    echo base >f && git add f && git commit -qm base && git push -q origin main &&
    mkdir -p iac/cloudflare && echo "comment: runs on $D" >iac/cloudflare/proxies.yaml &&
    git add -A && git commit -qm "dns record"
  ) >/dev/null 2>&1
  if printf '{"tool_name":"Bash","tool_input":{"command":"cd %s/work && git push origin main"}}' "$tmp" \
      | (run_hook) 2>/dev/null; then echo "ok   push: -y name in iac/cloudflare allowed"
  else echo "FAIL push: -y name in iac/cloudflare allowed"; fails=$((fails + 1)); fi
  ( cd "$tmp/work" && echo "host: $D" >notes.md && git add -A && git commit -qm notes ) >/dev/null 2>&1
  if printf '{"tool_name":"Bash","tool_input":{"command":"cd %s/work && git push origin main"}}' "$tmp" \
      | (run_hook) 2>/dev/null; then echo "FAIL push: -y name elsewhere blocked"; fails=$((fails + 1))
  else echo "ok   push: -y name elsewhere blocked"; fi
  if printf "{\"tool_name\":\"mcp__github__create_pull_request\",\"tool_input\":{\"title\":\"move $D\"}}" \
      | (run_hook) 2>/dev/null; then echo "FAIL MCP PR title blocked"; fails=$((fails + 1))
  else echo "ok   MCP PR title blocked"; fi
  if printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | (run_hook) 2>/dev/null; then
    echo "ok   unrelated Bash call passes"
  else echo "FAIL unrelated Bash call passes"; fails=$((fails + 1)); fi
  rm -rf "$tmp" "$XDG_CONFIG_HOME"

  echo "$fails failure(s)"
  [ "$fails" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  trap - ERR
  set +e
  self_test
  exit $?
fi
run_hook
