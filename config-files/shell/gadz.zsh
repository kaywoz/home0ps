#!/usr/bin/env zsh
# gadz — ephemeral remote shell. Carries your shell config + plugins into an SSH
# session with no footprint, cleans up on exit. Arch-proof: it ships scripts, not
# binaries, so an Apple-Silicon client works against x86_64 Linux hosts.
#
# Usage:   gadz [--ro] [--copy-id] [--reset] [--lan] [ssh-args] user@host
#   --ro        forensic/no-trace mode: HISTFILE=/dev/null on the remote, a red
#               [FORENSIC] prompt marker, and a local timestamped transcript
#               under ~/gadz-logs/ (chain-of-custody friendly).
#   --copy-id   run ssh-copy-id first (push your key), then connect.
#   --reset     close the reused connection first. Needed after the remote
#               account's groups change (e.g. added to `docker`): a reused
#               connection keeps the groups it was opened with.
#   --lan       don't switch to the tailnet address (see Tailnet below).
#   -h|--help   usage.
#
# Tailnet: when the Tailscale CLI is installed and the host is a tailnet peer,
# gadz connects to its tailnet address (ssh -o HostName=100.x, so ~/.ssh/config
# Host blocks still match). Tailscale SSH answers there on hosts that enable it;
# its periodic re-auth prompt shows because the connection is opened in the
# terminal before anything is captured.
#
# Behaviour by host:
#   host has zsh  -> zsh: prompt, aliases, Dracula LS_COLORS, history, atuin
#                    (if present), autosuggestions + syntax-highlighting.
#   bash only     -> bash: same, plus ble.sh (autosuggestions + highlighting for
#                    bash). ble.sh is fetched once into ~/.cache/gadz and shipped.
#
# Transport: a staging tar is piped to the host over a multiplexed SSH
# ControlMaster connection (so repeat connects are instant + one auth), extracted
# to a temp dir, and the shell is launched pointing at it. Removed on exit.
#
# Client prereqs: ssh, tar, curl, brew. zsh plugins auto-installed via brew if
# absent. Targets assumed Linux (GNU tar). Install: config-files/shell/install.sh

gadz() {
  emulate -L zsh
  local forensic=0 copyid=0 reset=0 lan=0
  while [[ "$1" == -* ]]; do
    case "$1" in
      --ro|--forensic) forensic=1; shift ;;
      --copy-id)       copyid=1;   shift ;;
      --reset)         reset=1;    shift ;;
      --lan)           lan=1;      shift ;;
      -h|--help) echo "usage: gadz [--ro] [--copy-id] [--reset] [--lan] [ssh-args] user@host" >&2; return 0 ;;
      --) shift; break ;;
      *) break ;;   # pass through ssh flags like -p, -i, -J
    esac
  done
  [[ $# -eq 0 ]] && { echo "usage: gadz [--ro] [--copy-id] [--reset] [--lan] [ssh-args] user@host" >&2; return 1; }

  # --- client prereqs ---
  local c miss=()
  for c in ssh tar curl brew; do command -v "$c" >/dev/null 2>&1 || miss+=("$c"); done
  if (( ${#miss[@]} )); then
    echo "gadz: missing required client tools: ${miss[*]}" >&2
    [[ " ${miss[*]} " == *" brew "* ]] && echo "  install Homebrew first: https://brew.sh" >&2
    return 1
  fi
  local share; share="$(brew --prefix)/share"
  if [[ ! -d "$share/zsh-autosuggestions" || ! -d "$share/zsh-syntax-highlighting" ]]; then
    echo "gadz: installing shipped zsh plugins via brew (one-time)…" >&2
    brew install zsh-autosuggestions zsh-syntax-highlighting || return 1
  fi

  # --- ble.sh: fetch + cache once (pure bash, arch-proof) ---
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/gadz"   # NB: separate locals —
  local blesh="$cache/blesh"                            # zsh won't see $cache if combined
  if [[ ! -f "$blesh/ble.sh" ]]; then
    echo "gadz: fetching ble.sh (one-time)…" >&2
    mkdir -p "$cache"
    local tgz="$cache/ble-nightly.tar.xz"
    # download to a file first (piping curl|tar can SIGPIPE curl mid-stream),
    # then copy the extracted dir's CONTENTS into blesh (robust vs. rename).
    if curl -fsSL https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz -o "$tgz" && tar xJf "$tgz" -C "$cache"; then
      rm -rf "$blesh"; mkdir -p "$blesh"
      cp -R "$cache"/ble-nightly*/. "$blesh"/ 2>/dev/null
      rm -rf "$cache"/ble-nightly* "$tgz"
    fi
    [[ -f "$blesh/ble.sh" ]] || echo "gadz: ble.sh unavailable — bash hosts won't get highlighting" >&2
  fi

  # --- tailnet address: Tailscale SSH answers there (HostName override keeps ssh_config matching) ---
  local ts="" host tip
  if (( ! lan )); then
    if command -v tailscale >/dev/null 2>&1; then ts=tailscale
    elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale; fi
  fi
  if [[ -n "$ts" ]]; then
    host="${@[-1]##*@}"
    tip=$("$ts" ip -4 "$host" 2>/dev/null | head -1)
    if [[ "$tip" == 100.* ]]; then
      set -- -o HostName="$tip" "$@"
      echo "gadz: $host -> $tip (tailnet)" >&2
    else
      echo "gadz: $host isn't a tailnet peer; connecting as given" >&2
    fi
  fi

  # --- optional: push key first ---
  if (( copyid )); then ssh-copy-id "$@" || return 1; fi

  # --- build staging dir (plugins + ble.sh + rc files) ---
  local stg; stg="$(mktemp -d)"
  tar -C "$share" -chf - zsh-autosuggestions zsh-syntax-highlighting | tar -xf - -C "$stg"
  [[ -f "$blesh/ble.sh" ]] && cp -R "$blesh" "$stg/blesh"

  local lscolors='di=1;34:ln=1;36:so=1;35:pi=33:ex=1;32:bd=1;33:cd=1;33:su=37;41:sg=30;43:tw=30;42:ow=34;42:*.tar=1;31:*.gz=1;31:*.tgz=1;31:*.zip=1;31:*.xz=1;31:*.jpg=1;35:*.png=1;35:*.gif=1;35:*.mp4=1;35:*.mp3=36:*.log=33:*.md=37'

  cat > "$stg/.zshrc" <<ZEOF
export TERM=xterm-256color
export LS_COLORS='$lscolors'
if [[ -n \$GADZ_RO ]]; then HISTFILE=/dev/null; SAVEHIST=0; _m='%F{red}[FORENSIC]%f '; else HISTFILE=~/.zsh_history; SAVEHIST=100000; _m=''; fi
HISTSIZE=100000; setopt INC_APPEND_HISTORY SHARE_HISTORY INTERACTIVE_COMMENTS
autoload -Uz compinit && compinit -u 2>/dev/null
alias ll='ls -lahF --color=auto' la='ls -A --color=auto' grep='grep --color=auto'
PROMPT="\${_m}%F{magenta}%n@%m%f:%F{blue}%~%f %# "
source \$ZDOTDIR/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
command -v atuin >/dev/null && eval "\$(atuin init zsh)"
source \$ZDOTDIR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null
ZEOF

  cat > "$stg/bashrc" <<BEOF
export TERM=xterm-256color
export LS_COLORS='$lscolors'
if [ -n "\$GADZ_RO" ]; then HISTFILE=/dev/null; _m='\[\e[1;31m\][FORENSIC]\e[0m\] '; else HISTFILE=~/.bash_history; HISTFILESIZE=200000; _m=''; fi
HISTSIZE=100000; shopt -s histappend
alias ll='ls -lahF --color=auto'; alias la='ls -A --color=auto'; alias grep='grep --color=auto'
PS1="\${_m}\[\e[1;35m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\] \\\$ "
command -v atuin >/dev/null && eval "\$(atuin init bash)"
[ -f "\$GADZ_DIR/blesh/ble.sh" ] && source "\$GADZ_DIR/blesh/ble.sh" 2>/dev/null
BEOF

  # --- ControlMaster (multiplex: repeat connects reuse one auth) ---
  mkdir -p "$HOME/.ssh"
  local cm=(-o ControlMaster=auto -o ControlPath="$HOME/.ssh/cm-gadz-%r@%h:%p" -o ControlPersist=10m)
  if (( reset )); then ssh "${cm[@]}" -O exit "$@" 2>/dev/null && echo "gadz: closed the reused connection" >&2; fi
  # Open the shared connection in the terminal first, so auth prompts (password,
  # Tailscale SSH re-auth URL) are visible; phase 1 below captures its output.
  if ! ssh "${cm[@]}" -O check "$@" 2>/dev/null; then
    ssh "${cm[@]}" -fN "$@" || { rm -rf "$stg"; echo "gadz: connection failed" >&2; return 1; }
  fi

  # --- phase 1: push staging over the connection, capture remote temp dir ---
  local rd
  rd=$(tar -C "$stg" -czf - . | ssh "${cm[@]}" "$@" 'd=$(mktemp -d); tar -xzf - -C "$d" >/dev/null 2>&1; printf "GADZDIR=%s\n" "$d"' | sed -n 's/^GADZDIR=//p')
  rm -rf "$stg"
  if [[ -z "$rd" ]]; then echo "gadz: failed to stage on remote" >&2; return 1; fi

  # --- phase 2: interactive shell, reusing the master connection ---
  local env="" ; (( forensic )) && env="GADZ_RO=1 "
  local rcmd="if command -v zsh >/dev/null 2>&1; then ${env}ZDOTDIR=$rd exec zsh; else ${env}GADZ_DIR=$rd exec bash --rcfile $rd/bashrc; fi"
  if (( forensic )); then
    local log="$HOME/gadz-logs/$(date +%Y%m%d-%H%M%S).log"; mkdir -p "$HOME/gadz-logs"
    script -q "$log" ssh -t "${cm[@]}" "$@" "$rcmd"
    echo "gadz: transcript saved to $log" >&2
  else
    ssh -t "${cm[@]}" "$@" "$rcmd"
  fi

  # --- cleanup: remove remote temp dir (master lingers per ControlPersist) ---
  ssh "${cm[@]}" "$@" "rm -rf $rd" 2>/dev/null
}
