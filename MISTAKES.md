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
- "Risky workloads go to the lab" (§8) means security work that runs untrusted code or handles malware. Ordinary apps stay; flag their gaps. Log/telemetry analysis without code execution or malware stays home (§8). *(2026-11-16 risky workload; 2026-11-22 log analysis)*
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

### 2026-11-20 — docs (CLAUDE.md split over-estimated)

- **Trigger:** wrong assumption
- **What happened:** the approved split plan moved rclone `-P`, "host steps ship as a script" and the `:latest` rule into path-scoped rule files and promised about 35% less root CLAUDE.md. Those rules also govern commands and proposals given in chat, before any file is opened, so moving them would have dropped them there. Kept in root, the saving is about 13%.
- **Root cause:** sorted rules by the folder they mention, not by when they are needed (planning and chat vs. editing a file in that area).
- **Fix applied:** those rules stay in root CLAUDE.md; only file-editing rules moved; the PR states the smaller saving.
- **Rule going forward:** before moving a rule into a path-scoped file, check whether it also applies to chat output (commands handed over, proposals); if so, it stays in root CLAUDE.md.

### 2026-11-20 — docs (`/memory` check for rule files)

- **Trigger:** wrong assumption — the check didn't show what it was meant to
- **What happened:** the verification step for the path-scoped rules told kaywoz to run `/memory` and look for `.claude/rules/*.md`. `/memory` only lists CLAUDE.md files and the auto-memory folder, not rule files, so the check showed nothing either way.
- **Root cause:** described the menu from the memory docs page (part of which came back only as a summary) instead of confirming what `/memory` displays.
- **Fix applied:** verified instead in a cloud session on the PR branch, where reading `docker-compose/CONTAINERS.md` loaded `compose.md` and `readme.md` only; kaywoz got a check that asks the session itself.
- **Rule going forward:** before giving kaywoz a UI or slash-command check, confirm what that screen actually shows; if unconfirmed, say so and give a check whose output is certain.

### 2026-11-20 — chat (steps without a way to do them)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** to verify PR 377 I gave kaywoz steps like "pick the branch when you start the session" for claude.ai/code. The UI showed no branch picker, and I hadn't checked that one exists.
- **Root cause:** described a UI from assumption and wrote tasks as prose instead of commands or exact click paths.
- **Fix applied:** offered a route with no UI step (merge, then test on `main`, revert if it fails).
- **Rule going forward:** every step for kaywoz is a copy-paste command or an exact, checked click path. If I can't confirm a UI path, say so and give a route that needs no UI step.

### 2026-11-20 — docs (NAMING rule scoped to compose)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** the CLAUDE.md split (PR 377) moved the "Names" bullet into `.claude/rules/compose.md`, which loads only for `docker-compose/` files. NAMING.md covers everything logical (devices, LXCs, tools, containers), so the rule was missing for any other naming work.
- **Root cause:** sorted the bullet by its example (container register) instead of by its scope (every logical name).
- **Fix applied:** "Names" moved back into CLAUDE.md §8, unchanged.
- **Rule going forward:** before moving a rule into a path-scoped file, check that every case it covers lies under those paths; repo-wide standards (naming, PII, security summaries) stay in root CLAUDE.md.

### 2026-11-22 — homenas (Kopia UI user)

- **Trigger:** misunderstanding found on the host
- **What happened:** the storage setup and `storage-stack.sh` asked for any "Kopia UI user" for the htpasswd file. Kopia's web UI only admits the account named `kopia`; any other htpasswd user gets "UI Access denied".
- **Root cause:** relied on the `--htpasswd-file` flag description without checking how the UI authenticates; the rule is only in the maintainer's comment on kopia/kopia#880, not on kopia.io.
- **Fix applied:** htpasswd rewritten on the host with the user `kopia`; the script writes `kopia` and `--verify` checks it (PR 387).
- **Rule going forward:** before letting a script or step choose a login name for an app, check the app's issue tracker as well as its docs for constraints on that name; prefer a fixed, verified value over a prompt.

### 2026-11-22 — plans (log analysis placed in the lab)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** the plan for a local redaction tool with cloud LLM analysis put it in the XCP-ng lab as a "risky workload", because the checklist listed "forensics". kaywoz: the data (exported logs) isn't inherently risky; there's no code execution and no malware, so it can run at home.
- **Root cause:** matched the keyword "forensics" in the checklist instead of the reason for the rule (untrusted code, malware).
- **Fix applied:** §8 now defines "risky" (untrusted code or malware) and says log/telemetry analysis may run at home; the checklist line was updated.
- **Rule going forward:** CLAUDE.md §8, "Risky means …". Place a workload by what it executes or handles, not by its topic.

### 2026-11-23 — chat (guessed checkout path)

- **Trigger:** command failed on the host
- **What happened:** a board command for the admin Mac started with `cd ~/github/home0ps`. The checkout isn't under the home folder's `github`, so `cd` failed; the earlier, working command had used `cd home0ps` from kaywoz's `github` folder.
- **Root cause:** wrote an absolute path from assumption instead of reusing the path form that had already worked.
- **Fix applied:** re-issued the command with `cd home0ps`, run from the `github` folder.
- **Rule going forward:** paths in commands for kaywoz's machines come from a path that already worked in the session, or from a lookup on that machine; never an assumed absolute path.

### 2026-11-26 — compose (container groups chosen for kaywoz)

- **Trigger:** misunderstanding corrected by kaywoz ("no stop")
- **What happened:** asked how to resolve a container-name clash, Claude offered `kr-ccp-socketproxy-0201` and `kr-ccp-beszelagent-0201` as free, though the register still listed them for retired hosts. On finding that, Claude picked `0601`/`0301` itself and started rewriting the register. kaywoz stopped it: groups follow hosts and stacks (homenas `01`; on the monitoring host, services also on the homenas `02`, the rest `01`), and the retired hosts' rows no longer count.
- **Root cause:** read only part of the register before writing the option, then treated a naming decision as Claude's to make once the offered option failed.
- **Fix applied:** names and register follow kaywoz's scheme; retired rows moved to `archive/docker-compose/CONTAINERS-retired.md`.
- **Rule going forward:** container group numbers are kaywoz's decision (see the CONTAINERS.md rule). Read the whole register before proposing one; if a proposed option turns out wrong, stop and ask again instead of choosing.

### 2026-11-26 — chat (`newgrp` not on the host)

- **Trigger:** command failed on the host
- **What happened:** to pick up a new `docker` group in an open shell, Claude handed kaywoz `newgrp docker`. The monitoring host (Ubuntu 26.04) has no `newgrp`: `command not found`.
- **Root cause:** gave a command not used before in this repo without checking it exists on that host (repeat of the checklist rule "A CLI not used before in this repo: check its usage line").
- **Fix applied:** a fresh login shell instead (`exec sudo -iu "$USER"`, or reconnect), which reads the group list again.
- **Rule going forward:** a command not used before in this repo is checked for that host's OS and release (package contents or a `command -v` step in the handed-over block) before it is given to kaywoz.

### 2026-11-26 — chat (host label as a `#` line in zsh)

- **Trigger:** command failed on the host
- **What happened:** command blocks for the monitoring host started with a `# host, account` comment line. kaywoz's shell there is zsh without `INTERACTIVE_COMMENTS`, so pasting the block printed `zsh: command not found: #`.
- **Root cause:** assumed a pasted `#` line is a no-op in every shell; interactive zsh only treats it as a comment with that option set (`gadz.zsh` doesn't set it).
- **Fix applied:** proposed `setopt INTERACTIVE_COMMENTS` in `config-files/shell/gadz.zsh`; until then, host labels go on the line above the block.
- **Rule going forward:** in commands for kaywoz's shells, put the host label outside the code block unless the target shell is known to accept `#` lines interactively.

### 2026-11-26 — docs (`rpi` left in the README layout row)

- **Trigger:** wrong assumption
- **What happened:** the PR moving the monitoring host to the N305 archived `config-files/rpi/`, but `README.md` still lists `rpi` (with `HARDENING.md`) under `config-files/`.
- **Root cause:** searched for `config-files/rpi` and `Raspberry Pi 5`, not for the bare folder name.
- **Fix applied:** removed in the follow-up PR.
- **Rule going forward:** after moving a folder, grep for its bare name as well as its path (`git grep -nw NAME`).

### 2026-11-26 — monitoring (empty HC_SECRET_KEY after the deploy walkthrough)

- **Trigger:** apply broke something
- **What happened:** the monitoring deploy walkthrough copied `.env.example` to `.env` and said `hc-setup.sh` would generate `HC_SECRET_KEY`. The example holds an empty `HC_SECRET_KEY=` line; the script only checked that the key name exists, so it generated nothing. Healthchecks ran with an empty secret key and answered every request with 500.
- **Root cause:** described what the script does from its comment, not from its check; the walkthrough and the script's presence-only `grep` combined into the failure.
- **Fix applied:** `hc-setup.sh` treats an empty value as missing, replaces the line and fails if it is still empty; kaywoz got commands to set the key on the host.
- **Rule going forward:** when a walkthrough copies an example file, read every script check that later reads it; "key present" checks test for a value (`^KEY=..*`), not the key name.

### 2026-11-26 — tailscale (`tofu fmt` not run before push)

- **Trigger:** CI failed
- **What happened:** removing the longest key (`"cockpit-janky"`) from `iac/tailscale-services/services.tf` left the other keys in its group padded for it; the PR `plan` job failed at `tofu fmt -check`.
- **Root cause:** edited HCL in a session without `tofu` and pushed without formatting or checking the `=` alignment.
- **Fix applied:** realigned the group (`=` one space after the longest key in each group of consecutive lines).
- **Rule going forward:** after editing a `.tf` file, run `tofu fmt -check -diff` on it; without `tofu`, check `=` alignment per group of consecutive lines by script before pushing.

### 2026-11-26 — shell (gadz "reinstall" step)

- **Trigger:** command failed on the host
- **What happened:** after the gadz PR merged, Claude told kaywoz to reinstall gadz with `install.sh`. The installer only adds `source <checkout>/config-files/shell/gadz.zsh` to `~/.zshrc`, so the Mac kept loading the old file from the checkout's current branch; `gadz --reset` passed `--reset` to ssh (`illegal option`).
- **Root cause:** described what the installer does without reading it.
- **Fix applied:** steps to switch the checkout to `main` (or source the `main` version) and reload the shell.
- **Rule going forward:** before telling kaywoz how to pick up a change, read how it is installed (copied, linked or sourced from the checkout) and give the step that matches.

### 2026-11-26 — ubuntu (new host folders without checking precedent)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** the Kopia backup draft put its settings in `/etc/h0ps/kopia-backup.conf` and its state in `/var/lib/h0ps/kopia-backup/`. No script used these before: the homenas scripts keep `<script>.conf` and `<script>/` in `<appdata>/home0ps/` (CLAUDE.md §8 file names), and the only name on Ubuntu hosts is `home0ps` (`beszel-agent.service.d/home0ps.conf`). `h0ps-` is the prefix for tool names, not folders.
- **Root cause:** chose where a script reads and writes host files without grepping the repo for the existing convention (repeat of masque-ir's "where the tool reads data is kaywoz's decision").
- **Fix applied:** kaywoz chose `/etc/home0ps/<script>.conf` and `/var/lib/home0ps/<script>/` (CLAUDE.md §8 file names).
- **Rule going forward:** before a script gets a new host path, `git grep` the existing scripts for where theirs live and reuse that; if nothing fits, propose the path to kaywoz instead of choosing it.

### 2026-11-26 — ubuntu (Kopia account named backup@<role>)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** `kopia-backup.sh` connected as `backup@<role>`. kaywoz: an account that moves data is always `mover@<hostname>`.
- **Root cause:** named a new account myself instead of asking for the convention (none was written down).
- **Fix applied:** the script connects as `mover@<hostname>`, the hostname read on the host at run time; the convention is in CLAUDE.md §8 (Names).
- **Rule going forward:** new accounts follow CLAUDE.md §8 Names; if no rule covers the kind of account, ask before naming it.

### 2026-11-26 — compose (pinning offered against §8)

- **Trigger:** wrong assumption
- **What happened:** proposing compose-lint for home0ps from a masque-ir session, Claude asked kaywoz to decide between digest pinning and turning the `:latest` rule off. CLAUDE.md §8 already says images stay on `:latest` and not to propose pinning.
- **Root cause:** planned home0ps work without reading home0ps's CLAUDE.md, because the session started in another repo.
- **Fix applied:** CL-0004 and CL-0019 are off in every stack's `.compose-lint.yml`, with §8 as the reason.
- **Rule going forward:** before proposing anything for home0ps from another repo's session, read home0ps's CLAUDE.md and the matching `.claude/rules/` file (CLAUDE.md header).

### 2026-11-26 — planning (§8 "no extra boxes" read as "no extra VMs")

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** comparing secret stores, Claude ruled out a self-hosted vault (OpenBao, Infisical) as "a new box, against §8". kaywoz: §8's "no extra boxes" is about physical hardware; VMs are allowed.
- **Root cause:** read "boxes" as any new host, physical or virtual, without asking.
- **Fix applied:** CLAUDE.md §8 says "boxes" means physical hardware and that VMs are allowed.
- **Rule going forward:** §8 proportionality limits new physical hardware, not VMs; weigh a VM by its own cost (tier, backups, upkeep), not by §8.
