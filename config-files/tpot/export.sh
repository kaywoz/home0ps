#!/usr/bin/env bash
##############################################################################
# Export the T-Pot LLM honeypot logs (Beelzebub SSH, Galah HTTP) to the admin
# Mac and write a summary. Run it before every rebuild or teardown: a rebuild
# wipes the disk.
#
#   config-files/tpot/export.sh <ssh-destination>
#   e.g. export.sh tpot            (Host entry from config-files/tpot/README.md)
#        export.sh <admin user>@<tpot_ipv4>
#
# Output: $TPOT_EXPORT_DIR (default ~/tpot-exports)/<UTC timestamp>/
#   raw.tar.gz       logs as copied from the host (rotated .gz files included)
#   raw/             the same, unpacked (attacker-controlled data, never run it)
#   summary.md       overview, top commands, credentials, HTTP paths, URLs
#   commands.csv     every distinct SSH command with counts and first/last seen
#   credentials.csv  every username/password pair tried
#   http.csv         every distinct HTTP method + path with counts
#
# The export holds attacker data (IPs, credentials, payloads). Keep it out of
# git; the directory is created 700.
#
# Extra ssh options: TPOT_SSH_OPTS (default: port 64295, the dedicated key via
# the 1Password agent, IdentitiesOnly, BatchMode).
##############################################################################
set -euo pipefail

DEST=${1:?usage: export.sh <ssh-destination>}
SSH_OPTS=${TPOT_SSH_OPTS:-"-p 64295 -i $HOME/.ssh/tpot.pub -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15"}
BASE=${TPOT_EXPORT_DIR:-$HOME/tpot-exports}
HERE=$(cd "$(dirname "$0")" && pwd)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$BASE/$STAMP"

umask 077
mkdir -p "$OUT/raw"
T=$(mktemp "$OUT/.raw.XXXXXX")
trap 'rm -f "$T"' EXIT

echo "export: pulling logs from $DEST -> $OUT"
# shellcheck disable=SC2086  # SSH_OPTS is a list of options on purpose
ssh $SSH_OPTS "$DEST" 'cd ~/tpotce/data && tar -czf - beelzebub/log galah/log' > "$T"
[ -s "$T" ] || { echo "export: FAIL: empty archive" >&2; exit 1; }
gzip -t "$T" || { echo "export: FAIL: archive is corrupt" >&2; exit 1; }
mv "$T" "$OUT/raw.tar.gz"
trap - EXIT

# Unpack into its own directory; no absolute paths or .. allowed in the archive.
if tar -tzf "$OUT/raw.tar.gz" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
  echo "export: FAIL: archive contains unsafe paths" >&2; exit 1
fi
tar -xzf "$OUT/raw.tar.gz" -C "$OUT/raw"

python3 -I "$HERE/summarize.py" "$OUT/raw" "$OUT"

echo "export: sha256 $(shasum -a 256 "$OUT/raw.tar.gz" | cut -d' ' -f1)  raw.tar.gz"
echo "export: done -> $OUT/summary.md"
