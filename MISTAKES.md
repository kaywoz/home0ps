# MISTAKES.md

A running log of mistakes made while planning/building/PR'ing changes to this
repo — wrong assumptions, misread requirements, failed CI, broken applies,
anything kaywoz had to correct. Read this file in full before starting new
work. Add a new entry any time something turns out to have been based on a
misunderstanding.

The full entries up to 2026-11-19 are in
[`archive/MISTAKES-2026.md`](archive/MISTAKES-2026.md). Their rules are either
already in `CLAUDE.md` (listed at the end) or condensed into the checklist
below, one line each, tagged with the entry's date and slug so the full entry
can be found. Open the archive only when a rule needs its context.

## Entry format

New entries go under "New entries" at the end of this file, in full:

```markdown
### YYYY-MM-DD — <area/slug>

- **Trigger:** wrong assumption / CI failed / apply broke something / misunderstood request / PR rejected
- **What happened:** one or two sentences, factual, no editorializing
- **Root cause:** why it happened — bad assumption, didn't read the source, wrong field, etc.
- **Fix applied:** what was changed to correct it
- **Rule going forward:** one concrete, checkable rule to add to CLAUDE.md
  (or a pointer to the CLAUDE.md section it was added to)
```

Keep entries short and specific. The goal is a checklist that prevents repeat
mistakes, not a diary. When the new entries grow long, move them to the
archive and condense their rules into the checklist.

---

## Checklist (from archived entries)

### Asking and scoping

- Ambiguous placement, ownership or pronoun ("X is planned there", "replace it with it"): ask in one line before writing it into a plan or issue. Hardware moving between roles: restate box → role for every box and get it confirmed. *(2026-10-25 Xen Orchestra placement; 2026-11-12 hardware role swap)*
- A device name that doesn't map to a known role: ask. In issues name the role precisely, never a bare "storage host". *(2026-10-30 host guessed)*
- "Build from the earlier list" means every item is in scope; anything I'd drop or move goes to kaywoz as a question first. *(2026-11-16 stack scope)*
- "Risky workloads go to the lab" (§8) means security tooling: malware, analysis, forensics. Ordinary apps stay; flag their gaps. *(2026-11-16 risky workload)*
- Summarising a CLAUDE.md rule: quote its wording, not its heading; if two bullets overlap, state the broader one. *(2026-11-13 management portal rule)*
- Credit the people behind a project, never a company, foundation or closed-source vendor; ask if unsure. *(2026-11-19 acknowledgements)*
- Don't infer a naming scheme from one example; ask what each part means. *(2026-11-08 container instance numbers)*

### Plans and designs

- Before offering an option, check it against decisions already made for the same component. *(2026-11-03 sshd on the tailnet address)*
- "VM" or "LXC" only where decided, "guest" otherwise; after changing a decision, grep the whole issue for the old term. *(2026-10-30 VM vs LXC)*
- Secret placement: per component, write "if this is compromised, the attacker gets …"; credentials go with the least exposed component, exposed apps get the narrowest artefact. *(2026-10-24 media credentials)*
- A control that needs platform workarounds: state the threat, what defaults already cover and what comparable appliances do; ask kaywoz first. *(2026-11-17 homenas proportionality)*
- Next-steps or status lists: check the current state of every issue/PR named; never list a closed item as open. *(2026-11-02 stale next-steps)*
- A link speed is the slower of its two ends; check both ports before calling it a hardware limit. *(2026-10-31 uplink limit)*

### Verify before asserting

- Proxy/serve targets: probe the backend's protocol (`http://` vs `https://`) or say it's unverified. *(2026-10-18 Kopia serve target)*
- A GitHub/repo setting: check it applies to the actor (user, PAT, `GITHUB_TOKEN`, app) or make the behaviour explicit in code. *(2026-10-19 weekly README auto-merge)*
- A package exists only after checking the specific release (`apt-cache policy` or the release's package page); multi-release install scripts tolerate a missing package. *(2026-10-19 package availability)*
- Before naming a cause, check it on the affected host with one command. *(2026-10-19 `grep -q` after a pipe)*
- Before planning services, timers or logging on a host, confirm base OS and init (`/etc/os-release`, `cat /proc/1/comm`). *(2026-10-25 systemd on the MOS host)*
- Before adding an agent or service, check what already runs on the host (`systemctl list-units`, `docker ps -a`, listening ports). *(2026-11-08 infra Beszel agent)*
- Checks of an app's behaviour follow its source/docs, including states where it legitimately does nothing. *(2026-11-08 beszel-agent.sh verify)*
- `cpus`/`mem_limit` sized from the host's real `nproc` and `free -g`, not a figure from chat. *(2026-11-10 Ollama CPU limit)*
- `cap_add`/`cap_drop`/uid variables: read the image's entrypoint first; prefer its own non-root `user:` mode. *(2026-11-09 Dockhand user setup)*
- Users, groups, uids or paths for a third-party installer: grep its install scripts for what it creates. *(2026-11-11 T-Pot reserved username)*
- A CLI not used before in this repo: check its usage line before handing it over. *(2026-11-16 `btrfs device stats`)*
- What a CLI does to the session it runs in (network, SSH, firewall): check docs/source; steps that can drop the operator's connection are a final manual step, never mid-script. *(2026-11-03 Tailscale SSH switch)*
- Test a setting through the path the platform uses (boot script or UI), and read that code before saying a setting has no effect. *(2026-11-17 `docker_options`)*
- After starting a daemon, poll for readiness before checking its state; a first failed probe is not a result. *(2026-11-17 remap checked before Docker was up)*
- Key fingerprints across tools: state the format (MD5 vs SHA256) and give the command; check in `ssh -v` that the intended key was offered. *(2026-11-11 SSH key fingerprint formats)*
- A secret handed to an app: enforce the app's own validation (policy, length, format) in the script. *(2026-11-19 Arcane admin password)*

### Commands handed to kaywoz

- Values that rewrite a host's config come from that host (`grep` the current value, `tailscale ip -4 HOST`), never from another host or typed by hand. *(2026-11-02 guest NIC name; 2026-11-08 Dozzle host list)*
- Edits to a list in a config file are a full, idempotent rebuild, not an append. *(2026-11-08 Dozzle host list)*
- Downloads and command output go to `T=$(mktemp)`, checked non-empty (`[ -s "$T" ]`), then moved into place; live files are written only after `&&` on success (`diff … || true`, never `;`). *(2026-11-09 compose download; 2026-11-11 empty key file)*
- Files a non-root process reads get an explicit mode (`install -m 644`); Dockerfiles use `COPY --chmod` for non-root images. *(2026-11-10 mktemp file modes)*
- Placeholders never use `<>` or other shell metacharacters; use plain words like `OLD_HOST_IP`. *(2026-11-16 placeholder read as a redirect)*
- Display names in host-local config (`.env`, UIs) are the host's MagicDNS name; the role-name rule applies to git only. *(2026-11-07 Dozzle host label)*

### Scripts

- `pipefail` scripts never pipe into `grep -q`; use `grep … >/dev/null`. *(2026-10-19 `grep -q` after a pipe)*
- `set -e` scripts: tolerate the non-fatal exit codes of monitoring tools (`smartctl`, `nvme`, …) explicitly, and add an `ERR` trap naming the line. *(2026-11-16 soak script and `smartctl`)*
- Load or background scripts: check prerequisites before load, `trap` that kills the process group, stop instructions as `kill -- -PGID`. *(2026-10-23 disk load test)*
- Third-party release assets are selected by exact name for the target, never by index; fail closed when missing. *(2026-11-03 dysk release asset)*
- Scripts holding an `flock` fd close it for every child that may outlive them (`9>&-`); read-only modes take no lock. *(2026-11-07 lock fd inherited; 2026-11-17 watchdog lock)*
- Idempotency checks in config patches match active lines only (anchor `^\s*` without `#`); read the target's current lines, commented ones included. *(2026-11-11 T-Pot idempotency check)*
- A documented placement rule for host-local paths is enforced in the script (`stat -c %d` vs `/`). *(2026-11-10 media mount cache in RAM)*
- Hooks that recreate RAM `/etc` state check every piece (user, group, subuid, subgid, config) on its own; reboot-test after MOS UI changes that touch users. *(2026-11-17 remap user without its group)*
- On MOS, files go on the boot stick only when they must work without the pool; Docker-related files live in appdata. *(2026-11-19 stack script files on the boot stick)*

### Git, PRs and the board

- **Every push and every `gh pr edit` to an existing PR is gated in the same command:** `[ "$(gh pr view N --json state --jq .state)" = OPEN ] && …`. Not `OPEN` → new branch from `main`, new PR. Repeated three times. *(2026-11-03, 2026-11-11, 2026-11-17 pushed to a merged PR)*
- Board items are `owner/repo#N` (from `content.repository`); every `gh issue` write takes `-R owner/repo`; check the title before closing. *(2026-11-19 issue closed in the wrong repo)*

### Rules already in CLAUDE.md

These archived entries are fully covered by the section named; no extra rule:
§1/§2 read the live file or workflow list (2026-10-03 migration plan, workflow names) ·
§2 re-read before editing (2026-10-04 overwrite) ·
§2 app docs, name the page (2026-10-18 Dozzle agent, 2026-10-26 port flag) ·
§2 merged is not deployed (2026-10-18 live compose) ·
§3 exact provider pins + lock file (2026-10-03 provider version drift) ·
§4 state keys, read unredacted (2026-10-03 backend key) ·
§4 PII, unix accounts, device names, DNS scope, `-y` names (2026-10-03 local account name, resource name in PR; 2026-10-04 device names in DNS data; 2026-10-10 generic alias) ·
§5 `git show --stat` (2026-10-03 rename incomplete) ·
§5 probe tokens, smallest scope set (2026-10-04 gh token permissions, board token scopes) ·
§8 container register (2026-11-08 container instance numbers) ·
§8 Hawser hosts (2026-11-09 Hawser scope) ·
§8 host steps as scripts (2026-11-19 doc instead of a script) ·
§8 acknowledgements (2026-11-19).

---

## New entries
