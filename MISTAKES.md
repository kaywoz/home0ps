# MISTAKES.md

A running log of mistakes made while planning/building/PR'ing changes to this
repo — wrong assumptions, misread requirements, failed CI, broken applies,
anything kaywoz had to correct. Read this file in full before starting new
work. Add a new entry any time something turns out to have been based on a
misunderstanding.

## Entry format

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
mistakes, not a diary.

---

### 2026-10-03 — tailscale-acl (migration plan)

- **Trigger:** wrong assumption
- **What happened:** the first migration plan told kaywoz to "switch from an
  API key to an OAuth client" and to port a healthcheck ping. The old
  `kaywoz/tailscale` workflow already authenticates with an OAuth client
  (`TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` / `TS_TAILNET`) and notifies via a
  Slack webhook, not a healthcheck.
- **Root cause:** described the old pipeline from how such pipelines usually
  look instead of reading `.github/workflows/tailscale.yml` first; the
  healthcheck detail was carried over from the unrelated `terraform-cloudflare`
  repo.
- **Fix applied:** read the actual workflow; task list corrected to reuse the
  existing secret names, replace the old OAuth client with a fresh
  policy-file-scoped one, and port the Slack notification.
- **Rule going forward:** CLAUDE.md §2 — read the actual current
  pipeline/config file before describing or planning around it; never borrow
  details from a different repo.

### 2026-10-03 — tailscale-acl (workflow names)

- **Trigger:** wrong assumption
- **What happened:** the Tailscale plan said to add an exclusion to
  `deploy-iac.yml`. No such workflow exists; the main IaC pipeline is
  `deploy-s3.yml`, which runs on every push to `main` with no path filter.
- **Root cause:** took the workflow name from the earlier Cloudflare planning
  doc instead of listing `.github/workflows/` first — the same failure as the
  entry above, repeated within the same task.
- **Fix applied:** listed the real workflows, added `paths-ignore` to
  `deploy-s3.yml`, corrected CLAUDE.md §1.
- **Rule going forward:** CLAUDE.md §1/§2 — list `.github/workflows/` and the
  target directory from the live repo before naming any file in a plan;
  planning docs are not a source of truth for file names.

### 2026-10-03 — hetzner-restructure (backend key)

- **Trigger:** wrong assumption
- **What happened:** the restructure plan said "same bucket + same state key →
  no state migration". The old `iac/backend.tf` state `key` was not a path but
  a string that looks like an S3 access key ID, committed to a public repo.
  I didn't see it because my own inspection command pattern-redacted anything
  named `key`, so I planned around a value I never looked at.
- **Root cause:** redacted on the way *in* (when reading files to plan)
  instead of only on the way *out* (when quoting into chat).
- **Fix applied:** read the file unredacted; moved Hetzner to a fresh key
  `hetzner/terraform.tfstate`; flagged the value for kaywoz to verify and
  rotate if it is a real access key ID.
- **Rule going forward:** CLAUDE.md §4 — read config files in full when
  planning; redact only what gets echoed back. Never claim "same/unchanged
  value" for something not actually viewed.

### 2026-10-03 — cloudflare (provider version drift)

- **Trigger:** wrong assumption — plan showed 40 unexpected in-place changes
- **What happened:** a PR meant to destroy 3 records planned
  `0 to add, 40 to change, 3 to destroy`. Every remaining record gained
  `include_shadow_metadata = false`, because the runner installed Cloudflare
  provider v5.27.0 while state was written by v5.25.0.
- **Root cause:** the original Cloudflare plan pinned `~> 5.0` and committed
  no `.terraform.lock.hcl`, so each run silently took the newest 5.x.
- **Fix applied:** exact pin `5.25.0` plus a committed lock file
  (linux_amd64 + darwin_arm64 hashes) in the same PR; the upgrade to 5.27.0
  becomes its own PR where the 40 cosmetic changes are expected.
- **Rule going forward:** CLAUDE.md §3 — every root module pins providers
  exactly and commits `.terraform.lock.hcl`; provider upgrades are separate
  PRs whose plan is reviewed for schema-only changes.

### 2026-10-03 — tailscale-acl (local account name)

- **Trigger:** misjudgement corrected by kaywoz
- **What happened:** the policy review called the local unix account in the
  Tailscale `ssh` rules "acceptable" because it isn't a login identity.
  kaywoz ruled that such account names are to be treated as PII and moved to
  GitHub secrets.
- **Root cause:** applied §4 PII rule narrowly (login identities only)
  instead of following "Unsure? Treat it as PII".
- **Fix applied:** account replaced with `${LOCAL_UNIX_ACCOUNT}`, filled from the
  `LOCAL_UNIX_ACCOUNT` secret by `deploy-tailscale-acl.yml` (kaywoz/home0ps#52).
- **Rule going forward:** CLAUDE.md §4 — local OS/unix account names in
  committed files are findings; replace with `${LOCAL_UNIX_ACCOUNT}` (or a
  similarly named placeholder for other accounts)
  filled from a GitHub secret.

### 2026-10-03 — tailscale-acl (resource name in PR)

- **Trigger:** misjudgement corrected by kaywoz
- **What happened:** a Tailscale PR description named a specific device by
  its hostname. kaywoz ruled that resource and account names must not be
  mirrored into PRs.
- **Root cause:** copied the name from the chat request into the PR text
  instead of describing the resource generically; §4 only covered PII, not
  infrastructure names.
- **Fix applied:** PR description edited to generic wording ("the storage
  resource").
- **Rule going forward:** CLAUDE.md §4/§5 — PR titles/bodies, commit
  messages and code comments use generic terms (`targetaccount`, `resource`,
  `storage`, `hypervisor`, ...), never real hostnames, device or account
  names.

### 2026-10-03 — docs (MISTAKES.md rename incomplete)

- **Trigger:** something wrong after merge
- **What happened:** the rename commit in kaywoz/home0ps#56 only contained
  the file rename. The `CLAUDE.md` reference updates and the file heading
  stayed uncommitted in the working tree, while the PR description said
  they were included. `main` pointed at a file name that no longer existed.
- **Root cause:** committed with `git commit -m` (no `-a`, no explicit
  paths) after editing tracked files, and didn't check `git show --stat`
  before pushing; macOS's case-insensitive filesystem then carried the
  leftover edits into the next branch.
- **Fix applied:** references and heading committed in a follow-up PR.
- **Rule going forward:** CLAUDE.md §5 — after every commit, check
  `git show --stat HEAD` against the PR description, and `git status` must
  be clean before switching branches.

### 2026-10-04 — cloudflare (device names in DNS data)

- **Trigger:** misjudgement corrected by kaywoz
- **What happened:** while implementing the internal-proxy wildcard records,
  device names were stripped from `proxies.yaml`, the record `comment` and
  the README table. kaywoz ruled that naming the host is fine inside DNS
  record data/docs, because the records describe those services; the ban
  applies everywhere outside that scope.
- **Root cause:** applied the §4 "no resource names" rule to all committed
  content without checking its scope; the rule only listed PRs, commit
  messages and code comments, and did not say where names are allowed.
- **Fix applied:** host names restored in the DNS data files; still kept out
  of the branch name, commit message and PR text.
- **Rule going forward:** CLAUDE.md §4 — device/host names are allowed only
  in DNS record definitions and their docs (`iac/cloudflare/`); nowhere else.

### 2026-10-04 — cloudflare (possible overwrite of an uncommitted edit)

- **Trigger:** misunderstood request / lost work
- **What happened:** an untracked draft (`proxies.yaml`) was rewritten in full
  with Write after it had been read via `cat` some minutes earlier. kaywoz
  reported editing the ID scheme in the meantime; that edit is not in any file
  on disk.
- **Root cause:** full-file rewrite of a user-owned draft based on a stale
  read, with no check that the file hadn't changed in between.
- **Fix applied:** stopped before commit; kaywoz re-applied the ID scheme,
  which was then re-read and copied verbatim into the README.
- **Rule going forward:** CLAUDE.md §2 — re-read a user-provided file
  immediately before editing it, and prefer targeted edits over full
  rewrites of drafts kaywoz may still be changing.

### 2026-10-04 — ci (setup steps assumed gh token permissions)

- **Trigger:** wrong assumption — setup command failed for kaywoz
- **What happened:** the setup steps for the weekly README workflow told
  kaywoz to run `gh secret set`. It failed with HTTP 403: the local `gh`
  login is a fine-grained PAT without the Secrets (or Actions settings)
  permission.
- **Root cause:** gave a `gh` command that needs a specific token permission
  without probing for it first; the earlier note "scopes couldn't be read"
  was not followed through.
- **Fix applied:** probed `actions/secrets/public-key` and
  `actions/permissions/workflow` (both 403); gave the web UI path instead and
  kept the PAT least-privilege.
- **Rule going forward:** CLAUDE.md §5 — before handing kaywoz a `gh`/API
  command, probe the endpoint read-only with the current token; if it 403s,
  give the web UI path, don't suggest widening the token.

### 2026-10-04 — docs (project board token scopes)

- **Trigger:** wrong assumption, plus a misjudgement corrected by kaywoz
- **What happened:** told kaywoz a classic token with only `project` would
  let Claude write to the board. `gh project` refused it client-side,
  wanting `read:org` + `read:discussion` too, so kaywoz had to edit the
  token a second time. Earlier, I had also hedged about widening the token
  at all, citing the previous entry. kaywoz ruled that a task that needs
  more access is a reason to widen it.
- **Root cause:** read the API's scope requirements, not the CLI's own scope
  check; treated "don't suggest widening" as absolute. The §5 rule from the
  previous entry had also never been added to CLAUDE.md.
- **Fix applied:** scopes added by kaywoz; writes go through
  `.claude/gh-project.sh` (Keychain token); the §5 rule added with the
  corrected wording.
- **Rule going forward:** CLAUDE.md §5 — probe a command with the real
  client before relying on it; when access is missing and needed, state the
  smallest working set and let kaywoz decide.

### 2026-10-10 — tailscale-acl (generic alias treated as device name)

- **Trigger:** misjudgement corrected by kaywoz
- **What happened:** a requested policy snippet used a `hosts` alias and a
  Tailscale IP. I flagged the alias as a device name and the IP as
  sensitive, and proposed a secret-backed placeholder. kaywoz clarified the
  alias is generic (real device names end in `-y`) and Tailscale IPs are
  not secrets.
- **Root cause:** applied the §4 "no device names" rule without a way to
  tell real device names from generic aliases, and extended the PII/secret
  rules to Tailscale IPs without basis.
- **Fix applied:** snippet committed verbatim (kaywoz/home0ps#81).
- **Rule going forward:** CLAUDE.md §4 — real device names end in `-y`;
  generic aliases and Tailscale IPs may be committed. If a name fits
  neither pattern, ask.

### 2026-10-18 — tailscale-acl (Dozzle agent advice for the storage host)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** recommended a Dozzle **agent** on the storage host,
  suggested reading Docker through a socket proxy "if MOS makes it easy",
  and gave an example mounting `docker.sock:ro`. A grant for the agent port
  (7007) was merged. Dozzle's docs say agents can't be used with a socket
  proxy in the agent stack; the socket-proxy pattern kaywoz already uses is
  Dozzle's *remote host* mode. And `:ro` on a socket bind mount doesn't
  restrict the Docker API at all.
- **Root cause:** answered from general knowledge of Dozzle instead of
  reading its agent and remote-host guides first; treated `:ro` on a socket
  as a permission control.
- **Fix applied:** read both guides; laid out agent vs. socket proxy (remote
  host) for kaywoz to choose; any grant change follows that choice.
- **Rule going forward:** CLAUDE.md §2 — before recommending how an app
  connects or authenticates, read the app's own docs for that mode and say
  which page was used. Never present `:ro` on `docker.sock` as a
  restriction; only a socket proxy with `POST=0` limits the API.

### 2026-10-18 — tailscale-services (Kopia serve target)

- **Trigger:** wrong assumption — `svc:kopia` returned 502
- **What happened:** the storage-host `tailscale serve` commands pointed
  Kopia at `https+insecure://127.0.0.1:51515`, assuming Kopia's server uses
  its own TLS. A probe showed it speaks plain HTTP (401 on `http://`, no
  answer on `https://`).
- **Root cause:** guessed the backend protocol instead of probing the port
  before writing the command — the same "read/verify the app first" gap as
  the entry above.
- **Fix applied:** target changed to `http://127.0.0.1:51515`.
- **Rule going forward:** CLAUDE.md §2 (app-docs rule) — before giving a
  proxy/serve target, check the backend's protocol (`curl http://` vs
  `https://`) when the port is reachable, or say it's unverified.

### 2026-10-18 — monitoring (live compose assumed to match the repo)

- **Trigger:** wrong assumption — kaywoz hit a YAML error and empty values
- **What happened:** after merging the `DOZZLE_REMOTE_AGENT` change, I told
  kaywoz to set the variable in `.env` and recreate Dozzle. The live
  `/srv/docker/compose.yaml` was an older hand-edited copy (host name
  hard-coded, no `${DOZZLE_REMOTE_AGENT}`), so the value had to be typed
  into the file (wrong `=` syntax → YAML error). Once the repo file was
  copied in, four `.env` variables turned out to be missing, and the
  debugging output put rendered secrets into the conversation.
- **Root cause:** treated "merged in the repo" as "deployed on the host";
  issue #98 already said the two had drifted.
- **Fix applied:** live compose replaced with the repo version, `.env`
  completed, stack recreated; exposed secrets added to #114.
- **Rule going forward:** CLAUDE.md §2 — before giving host steps that rely
  on a repo change, have kaywoz confirm the host runs the repo version
  (e.g. `diff` or `grep` for the changed line), and give the
  empty-value check (`docker compose config 2>/dev/null | grep -nE ': ""$'`)
  rather than plain `docker compose config`, which prints secrets.

### 2026-10-19 — ci (weekly README auto-merge left its branch)

- **Trigger:** wrong assumption — branch not deleted after the first auto-merge
- **What happened:** kaywoz/home0ps#146 made the weekly README workflow merge
  its own PR and said GitHub would delete the branch because "Automatically
  delete head branches" is on. The first run (kaywoz/home0ps#147) merged
  fine but left `chore/readme-weekly-*` behind.
- **Root cause:** assumed the repo setting applies to every merge; merges
  made with the workflow's `GITHUB_TOKEN` don't trigger it. Not verified
  before writing it into the PR.
- **Fix applied:** `gh pr merge --delete-branch` in the workflow; leftover
  branch deleted.
- **Rule going forward:** CLAUDE.md §2 — state what a repo/GitHub setting
  does only after checking it applies to the actor in question (user, PAT,
  `GITHUB_TOKEN`, app); otherwise make the behaviour explicit in the code.

### 2026-10-19 — config (package availability claimed from a loose check)

- **Trigger:** wrong assumption — `apt-get install tldr` failed on a host
  ("no installation candidate")
- **What happened:** I told kaywoz `htop` and `tldr` "are in Ubuntu's
  repositories" and put `tldr` in `baseline.sh`. The check behind that was a
  grep over packages.ubuntu.com search results that only showed the name
  appeared somewhere, not that the package is installable on the host's
  release. On the host, `tldr` had no candidate, and the whole run aborted.
- **Root cause:** a check that couldn't fail was treated as verification;
  no allowance for the package set differing between Ubuntu releases.
- **Fix applied:** `baseline.sh` now takes alternatives (`tealdeer|tldr`,
  first installable wins), checks `apt-cache policy` for a candidate, and
  reports a missing package instead of aborting.
- **Rule going forward:** CLAUDE.md §2 — before stating a package exists,
  check the specific release's package page (or `apt-cache policy` on the
  host) and say which releases were checked; scripts installing packages on
  more than one release must tolerate a missing one.

### 2026-10-19 — config (`grep -q` after a pipe under `pipefail`)

- **Trigger:** CI-less script bug, then a wrong diagnosis — `baseline.sh`
  reported `unzip` and `tealdeer|tldr` as "no installable package" on a
  26.04 host where both are installable
- **What happened:** the candidate check was
  `apt-cache policy … | grep -q 'Candidate: …'` in a `set -o pipefail`
  script. `grep -q` exits on the first match, `apt-cache` gets SIGPIPE and
  exits non-zero, and `pipefail` makes the check false exactly when it
  matched. I first blamed a non-English locale and logged that; kaywoz's
  `apt-cache policy` output (English) disproved it.
- **Root cause:** `grep -q` behind a pipe with `pipefail`; the stub tests
  printed three lines, too short to trigger SIGPIPE. The locale guess was
  stated as the cause without checking it on the host first.
- **Fix applied:** every `… | grep -q` in `config-files/ubuntu/` became
  `… | grep … >/dev/null` (reads all input); `LC_ALL=C` kept as hygiene.
- **Rule going forward:** CLAUDE.md §2 — in `pipefail` scripts never pipe
  into `grep -q`; and before naming a cause, check it on the affected host
  (one command) rather than reasoning from a hint like a mirror name.

### 2026-10-23 — host ops (ad-hoc disk load test without cleanup)

- **Trigger:** something broke during use — load kept running with no logging
- **What happened:** the `dd` thermal test I gave in chat hard-coded sensors
  for two NVMe controllers. One had no sysfs sensor, so the temperature
  logger died on its first line while the CPU loops and `dd` kept going.
  My stop advice then killed `dd` and the CPU-heavy subshells, but missed
  the low-CPU loop around `dd`, which kept starting new writes.
- **Root cause:** a long-running ad-hoc script with no prerequisite checks
  before applying load and no single way to stop it (no `trap`, no process
  group); stop advice targeted symptoms (`dd`, high CPU) instead of the
  process tree.
- **Fix applied:** corrected script auto-detects sensors and aborts before
  any load if the tested drive has none; stop via the `dd` processes'
  parents.
- **Rule going forward:** CLAUDE.md §2 — scripts that apply load or run in
  the background: check prerequisites first (abort before load), and add a
  `trap` that kills the whole process group on exit/Ctrl-C; give stop
  instructions as one command for the group (`kill -- -<PGID>`).

### 2026-10-24 — design (media credentials in the exposed guest)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** the storage-consolidation design (kaywoz/home0ps#174)
  put the media Filen login and the rclone mount inside the Jellyfin/Komga
  guest, "so the storage host never sees them", and used that as the main
  reason for an LXC. kaywoz pointed out the storage host should own the
  cloud connection. Correct threat model: the media apps are the most
  exposed component; credentials next to them mean a compromised app can
  delete the whole media account, while a host-side read-only mount gives
  it read-only files and no credentials.
- **Root cause:** optimised for "keep secrets off the most important host"
  instead of "keep secrets away from the most exposed process"; didn't ask
  what an attacker in each component would get.
- **Fix applied:** #174 updated: rclone mount on the MOS host
  (`--read-only`, `--allow-other`), media apps get a read-only bind mount and
  no credentials; container vs. LXC now hinges only on MOS's Docker user
  namespacing.
- **Rule going forward:** for any secret placement, write down per
  component "if this is compromised, the attacker gets …" and put
  credentials with the least exposed component that needs them, handing
  exposed apps only the narrowest artefact (read-only files, scoped token).

### 2026-10-25 — design (systemd/journald assumed on the MOS host)

- **Trigger:** wrong assumption — kaywoz: MOS is built on Devuan
- **What happened:** the consolidation plan (kaywoz/home0ps#174) had the MOS
  host start the rclone mount "via systemd" and run jobs as systemd timers,
  and the logging convention ("journald everywhere") was assumed to cover
  it. Devuan has no systemd, so no journald either.
- **Root cause:** planned the host from the Ubuntu hosts' conventions
  without checking which OS/init the appliance OS uses.
- **Fix applied:** #174 updated: init scripts / MOS mechanisms, cron, syslog
  files as the log source; the MOS host recorded as an exception to
  "journald everywhere".
- **Rule going forward:** CLAUDE.md §2 — before planning services, timers
  or logging on a host, confirm its base OS and init system
  (`/etc/os-release`, `cat /proc/1/comm`) and say which was checked.

### 2026-10-25 — design (Xen Orchestra placement misread)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** kaywoz said the infra VM sits on VLAN 21 "(currently
  only Xen Orchestra is planned there)". I wrote into #174 that VLAN 21
  *also holds* Xen Orchestra as a separate system, with a firewall rule for
  it. kaywoz meant the infra VM itself runs Xen Orchestra as a container.
- **Root cause:** filled an ambiguous half-sentence with an assumption and
  wrote it into the plan instead of asking.
- **Fix applied:** #174 corrected: XO runs in the infra VM; new decision
  item on co-locating XO (lab-facing) with Dockhand (home control).
- **Rule going forward:** when a placement or ownership detail is
  ambiguous ("X is planned there"), ask in one line before writing it into
  an issue or design.

### 2026-10-26 — tailscale (port flag invented)

- **Trigger:** wrong assumption, found before kaywoz acted on it
- **What happened:** #190 and a comment on it told kaywoz to fix the
  Tailscale UDP port with `tailscale up --port 41641` / `tailscale set
  --port=41641` / `TS_PORT`. None of these exist: the port is a `tailscaled`
  daemon flag (`--port`), set via `PORT` in `/etc/default/tailscaled` on
  Linux packages, `TS_TAILSCALED_EXTRA_ARGS` in the container image, and
  `tailscaled-env.txt` on Windows.
- **Root cause:** wrote CLI flags from memory instead of checking the
  Tailscale docs/source before putting them into an issue.
- **Fix applied:** #190 body and comment corrected, with the sources
  (Tailscale KB 1082 + 1278, `cmd/tailscaled/tailscaled.defaults`).
- **Rule going forward:** CLAUDE.md §2 already requires reading the app's
  own docs before recommending how it connects; that includes CLI flags and
  config keys. Name the doc page or source file next to any command written
  into an issue.

### 2026-10-30 — media (host guessed)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** kaywoz named the host running the media rclone mount.
  I couldn't place the name, wrote "the storage host" into #197 and #191,
  and added a follow-up to move the mount to the MOS host later. The host
  already is the MOS host.
- **Root cause:** mapped a device name to a role by guessing instead of
  asking; "storage host" was also ambiguous next to the old storage host.
- **Fix applied:** #197 and #191 now say MOS host; the move follow-up was
  replaced by the read-only bind mount into the media LXC.
- **Rule going forward:** when a device name in chat doesn't map to a known
  role, ask in one line before writing it into an issue. In issues, name the
  role precisely (MOS host / old storage host), never a bare "storage host".

### 2026-10-30 — mos (VM vs LXC mixed up)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** #174, #191 and draft #183 called the MOS guests "VM"
  in some places and "LXC" in others, and recorded "infra + apps as LXCs"
  as decided. kaywoz: XCP-ng runs VMs only (some with Docker); on MOS only
  the media guest is an LXC (needs `/dev/dri`); infra and apps are still
  open, LXC or VM.
- **Root cause:** edited the plan section by section as decisions moved and
  never re-read it end to end for terms; turned a tested option (Docker in
  an LXC works) into a decision.
- **Fix applied:** #174 has a "Guest types" note at the top; infra/apps are
  "infra guest"/"apps guest" with the LXC-vs-VM decision reopened; #191 and
  #183 updated to match.
- **Rule going forward:** use "VM" or "LXC" only where the type is decided,
  "guest" otherwise. After changing a decision in a plan issue, grep the
  whole issue for the old term before saving.

### 2026-10-31 — network (uplink limit misread)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** from a switch screenshot showing the gateway uplink
  at GbE, I concluded every inter-VLAN flow tops out at 1 Gbit/s and
  planned ports around that. The gateway's port is 2.5 GbE; the uplink only
  negotiated 1G because it sits on a 1G switch port.
- **Root cause:** treated a negotiated link speed as a device limit without
  checking both ends of the link.
- **Fix applied:** port plan redone with the uplink on a 2.5G switch port.
- **Rule going forward:** a link speed is the slower of its two ends; check
  both ports' capabilities before calling a speed a hardware limit.

### 2026-11-02 — planning (stale next-steps list)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** a "next steps" list told kaywoz to rotate the exposed
  monitoring secrets and webhook (#114) as "still overdue". #114 was already
  closed with every item ticked.
- **Root cause:** the list was built from earlier session notes, not from
  the current state of each issue/PR it named.
- **Fix applied:** item dropped from the list.
- **Rule going forward:** CLAUDE.md §2 — before giving a next-steps or
  status list, check the current state of every issue and PR it names
  (`gh issue view N --json state`, `gh pr view N --json state`); never list
  a closed item as open.

### 2026-11-02 — mos (guest NIC name guessed)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** after a VM's passthrough NIC was renamed, the fix
  handed over was `sed 's/enp1s0/enp2s0/'`, copied from the other VM. The
  old name in that VM's `/etc/network/interfaces` was `enp3s0`, so the
  command would have changed nothing.
- **Root cause:** reused the previous VM's old interface name instead of
  reading the affected VM's config first.
- **Fix applied:** read the old name from the VM's `/etc/network/interfaces`,
  then rename that one.
- **Rule going forward:** before giving a command that rewrites a name,
  address or path in a host's config, have kaywoz show the current value on
  that host (`grep`) and build the command from it — never from another
  host.

### 2026-11-03 — hosts (dysk release asset by position)

- **Trigger:** script failed on a host
- **What happened:** `baseline.sh` downloaded the dysk release's *first*
  asset and unzipped it. dysk v3.8.2 changed its release to one tarball
  per target; the first asset became a macOS `.tar.gz`, its digest still
  matched, and `unzip` failed on the first VM.
- **Root cause:** the asset was chosen by list position, an assumption about
  an upstream layout the project never promised.
- **Fix applied:** asset picked by exact name for the host's target
  (`dysk-<tag>-<arch>.tar.gz`, old zip as fallback); aborts with a FAIL
  check if no match (PR 210).
- **Rule going forward:** when a script fetches a third-party release,
  select the asset by exact name for the target, never by index, and fail
  closed when it's missing.

### 2026-11-03 — hosts (Tailscale SSH switch over a tailnet session)

- **Trigger:** script failed on a host; claim corrected by the CLI
- **What happened:** the rollout note said an SSH session open while
  Tailscale SSH is switched on "survives". In fact `tailscale set --ssh`
  refuses (no change, non-zero exit) when the shell came in over
  Tailscale, and `set -e` ended `baseline.sh` before its verify step on
  the apps VM.
- **Root cause:** stated the CLI's behaviour without checking it, and the
  script treated an expected refusal as fatal.
- **Fix applied:** both host scripts warn and print
  `tailscale set --ssh --accept-risk=lose-ssh` as the last manual step
  (PR 215).
- **Rule going forward:** before asserting what a CLI does to the session
  it runs in (network, SSH, firewall changes), check its docs or source; in
  scripts, any step that can drop the operator's own connection is printed
  as a final manual step, never run mid-script.

### 2026-11-03 — hosts (sshd on the tailnet address offered)

- **Trigger:** wrong assumption
- **What happened:** PR 217 offered "bind sshd to the tailnet address" as
  a way to keep LXC sshd off the IoT VLAN; kaywoz chose it. With Tailscale
  SSH on (decided the same day), tailscaled takes port 22 on the tailnet
  address, so an sshd bound there would never receive a connection. Bound
  to a not-yet-up 100.x address, it would also fail to start at boot.
- **Root cause:** offered an option without checking it against the
  Tailscale SSH decision made earlier in the same session.
- **Fix applied:** option withdrawn before anything was built; the
  alternatives went back to kaywoz.
- **Rule going forward:** before offering an option, check it against the
  decisions already made for the same component (here: who owns port 22 on
  the tailnet address).

### 2026-11-03 — workflow (commits pushed to an already-merged PR)

- **Trigger:** script ran without changes that were "in the PR"
- **What happened:** follow-up commits were pushed to the branches of PR 210
  and PR 217 after kaywoz had merged them. The pushes succeeded, but the
  commits never reached `main`. The media LXC then ran the merged first
  version: no account prompt, sshd installed in the LXC, SSH checks failing.
- **Root cause:** assumed an open PR was still open because it was earlier
  in the session; didn't check its state before pushing.
- **Fix applied:** the lost commits were cherry-picked onto a new branch
  from `main` (PR 220).
- **Rule going forward:** before adding a commit to an existing PR branch,
  check `gh pr view N --json state`; if it isn't `OPEN`, branch from `main`
  and open a new PR. A `git push` that prints "Create a pull request for …"
  means the branch has no open PR — stop.

### 2026-11-07 — mos (lock fd inherited by daemons)

- **Trigger:** script failed on the host
- **What happened:** `media-mount.sh` took an `flock` on fd 9 and then started
  the rclone daemon and `lxc-start`. Both inherited fd 9 and kept the lock,
  so every later run, including the cron watchdog, reported "another run is
  active" and did nothing.
- **Root cause:** a lock held through an open fd lives as long as any
  process holds that fd; long-lived children weren't considered.
- **Fix applied:** fd 9 is closed (`9>&-`) for the rclone daemon and
  `lxc-start` (PR 224).
- **Rule going forward:** in scripts that lock with `flock` on an fd, close
  that fd for every child that outlives the script (daemons, monitors,
  `&` jobs).

### 2026-11-07 — compose (Dozzle host label)

- **Trigger:** misunderstood request
- **What happened:** the host steps for Dozzle remote hosts labelled the media
  LXC `media` in `DOZZLE_REMOTE_HOST`; kaywoz's convention is each host's
  MagicDNS name, `<hostname>.<tailnet>.ts.net`.
- **Root cause:** carried the git rule "role names, not device names" over to
  a host-local `.env` value, where it doesn't apply, and `.env.example` said
  only `<label>`.
- **Fix applied:** `.env.example` and the compose comment say the label is the
  host's MagicDNS name; the host's `.env` was corrected.
- **Rule going forward:** display names in host-local config (`.env`, UIs)
  use the host's MagicDNS name (`<hostname>.<tailnet>.ts.net`); the role-name rule
  applies only to what goes into git, where the tailnet name stays a placeholder.

### 2026-11-08 — compose (container instance numbers)

- **Trigger:** kaywoz had to correct it
- **What happened:** the media LXC's socket proxy was named
  `kr-ccp-socketproxy-0101` in its compose (PR 230), the same name as the
  monitoring host's. The storage host's proxy was deployed as
  `kr-ccp-dockerproxy-0101` (wrong service name, number taken) because the
  MOS deploy settings (PR 234) gave no container name at all.
- **Root cause:** copied the name from the monitoring compose without
  checking which instance numbers were used; no register of names existed.
- **Fix applied:** `docker-compose/CONTAINERS.md` registers every container
  per host role; media → `-0201`, storage host → `-0301`, storage Beszel
  agent → `kr-ccp-beszelagent-0201`; MOS deploy settings and the onboarding
  runbook name the container. Along the way the suffix was first read as a
  counter, then as individual + group; after discussing readability kaywoz
  settled on **group, then member** (GGMM) and a written standard,
  `NAMING.md`, covering devices too.
- **Rule going forward:** before naming a new container, look up the next
  free group in `docker-compose/CONTAINERS.md` and add the new container
  there in the same change; deploy instructions always state the container
  name. Don't infer a naming scheme from one example — ask what each part
  means.

### 2026-11-08 — compose (infra Beszel agent)

- **Trigger:** wrong assumption
- **What happened:** the infra stack (PR 236) added a containerised Beszel
  agent, but the infra VM (and the apps VM) already run Beszel's agent
  natively as a systemd service. Two agents would fight over port 45876 and
  show up twice in the hub.
- **Root cause:** didn't check the host for an existing agent before writing
  the stack; `security/apps.md` already hinted at a running agent.
- **Fix applied:** container agent removed from the infra stack; the native
  agent is documented, with its hardening planned; the onboarding runbook
  checks for a native agent first.
- **Rule going forward:** before adding an agent or service to a host, check
  what already runs there (`systemctl list-units`, `docker ps -a`, listening
  ports) — not only the containers.

### 2026-11-08 — ubuntu (beszel-agent.sh verify)

- **Trigger:** script check failed on the host
- **What happened:** `beszel-agent.sh --verify` failed "listens on:
  nothing" on the infra VM although the agent was healthy.
- **Root cause:** assumed the agent always listens on 45876; it only runs
  its SSH server while the WebSocket to the hub is down and stops it once
  connected (`agent/connection_manager.go`). The storage host's log had
  shown this order (WebSocket failed → SSH server started).
- **Fix applied:** the check accepts no listener or the tailnet IP only, and
  confirms "WebSocket connected" in the log.
- **Rule going forward:** before writing a check for an app's behaviour,
  read how the app actually behaves (source or docs) — including states
  where it legitimately does nothing.

### 2026-11-08 — compose (Dozzle host list)

- **Trigger:** host setup broke (Dozzle missing a host)
- **What happened:** `DOZZLE_REMOTE_HOST` ended up with duplicate entries
  (storage host, infra VM) and the apps VM under the infra VM's IP, so
  Dozzle dropped it as a duplicate.
- **Root cause:** the first append one-liner had no duplicate guard, and
  the later one took `IP` from a shell variable typed by hand — a value left
  over from the previous host was reused. Placeholders like `<apps-ip>` in
  commands also got run literally.
- **Fix applied:** the runbook rebuilds the whole line from a list of
  hostnames and looks each IP up with `tailscale ip -4 <host>`; rerunnable,
  writes nothing if a host doesn't resolve.
- **Rule going forward:** commands for kaywoz derive values on the host
  (lookups) instead of asking for them to be typed; any edit to a list in
  a config file is a full, idempotent rebuild, not an append.


### 2026-11-09 — host steps (compose download)

- **Trigger:** host command failed
- **What happened:** the infra VM fetch `curl … -o /tmp/compose.yaml && diff …; sudo cp /tmp/compose.yaml /srv/docker/compose.yaml`
  failed with curl (23): a `/tmp/compose.yaml` left by an earlier step was owned by another user, and
  `fs.protected_regular` stops even root from opening it. The `;` after `diff` then let `cp` run anyway,
  which can overwrite the live compose file with that stale copy.
- **Root cause:** fixed, shared `/tmp` filename reused across steps and users; `;` used where only
  success should continue (because `diff` exits 1 on any change).
- **Fix applied:** recovery with a fresh `mktemp` file, a check of the live file, then copy only after
  a successful download.
- **Rule going forward:** host download commands use `T=$(mktemp)`, never a fixed `/tmp` name, and
  every step that writes a live file is chained with `&&` on a successful download (`diff … || true`
  for the diff, not `;`).

### 2026-11-09 — compose (Dockhand user setup)

- **Trigger:** container crash-looped on first start
- **What happened:** Dockhand-home was set up with `PUID`/`PGID` and `cap_drop: [ALL]` + `CHOWN`/`SETUID`/`SETGID`.
  The entrypoint then deletes and recreates its `dockhand` user and group as root; that failed
  (`addgroup: group 'dockhand' in use`) and `set -e` restarted the container in a loop.
- **Root cause:** the capability set was chosen from the manual's description, not from the
  entrypoint script (`docker-entrypoint-node.sh`), which has a separate non-root mode for `user:`.
- **Fix applied:** `user: "2101:2101"` + `group_add` docker GID, no `PUID`/`PGID`, no added
  capabilities (kaywoz/home0ps#249).
- **Rule going forward:** before setting `cap_drop`/`cap_add` or uid variables for an image, read its
  entrypoint script; prefer an image's own `user:` (non-root) mode over root-then-drop setups.

### 2026-11-09 — compose (Hawser scope)

- **Trigger:** misunderstood request
- **What happened:** for "do hawser next" I drafted a Hawser agent for the storage host too, with a new
  mos-templates template (opened as kaywoz/mos-templates#9), because the earlier plan and CLAUDE.md §8
  listed the MOS host as managed by Dockhand-home. kaywoz: Hawser is not a MOS template, and agents go to
  the infra VM, apps VM or media LXC only unless he says otherwise.
- **Root cause:** carried the storage host over from the planning text without confirming the host list
  when the build started; a new MOS template was created without being asked for.
- **Fix applied:** mos-templates#9 closed; storage host removed from the Hawser PR, CLAUDE.md §8,
  `security/infra.md` and `security/storage.md`; the policy grant to the storage host is removed in its
  own PR.
- **Rule going forward:** new containers go to the infra VM, apps VM or media LXC; the storage host (MOS)
  and new MOS templates only when kaywoz names them for that service (CLAUDE.md §8).

### 2026-11-10 — compose (Ollama CPU limit)

- **Trigger:** apply broke something (`docker compose up` refused the service)
- **What happened:** the Ollama service set `cpus: 3` "of 4" because kaywoz mentioned 4 cores; the apps VM has 2 vCPUs, so Docker rejected the limit ("range of CPUs is from 0.01 to 2.00"). The same check then showed 3 GB RAM against an 8 GB `mem_limit` sized from "16gb" in chat.
- **Root cause:** took a resource figure from chat as the VM's size instead of checking the host (`nproc`, `free -g`) or the VM definition.
- **Fix applied:** kaywoz raised the apps VM to 4 vCPUs and 16 GB RAM; `cpus: 3` and `mem_limit: 8g` kept, with the comment stating the VM's real size.
- **Rule going forward:** before setting `cpus`/`mem_limit`, get the host's actual `nproc` and `free -g` (ask kaywoz to run them if unknown) and size limits below those.

### 2026-11-10 — host (media mount cache in RAM)

- **Trigger:** something broke after deploy (a VM could not start)
- **What happened:** the media mount's VFS cache was configured on the storage host's RAM rootfs (`/mnt/rclone/...`) instead of the pool; it grew to 30 GB, filled the 32 GB rootfs, and libvirt could no longer write a VM's key file at start.
- **Root cause:** `media-mount.sh` documented "cache on the pool — never on MOS's RAM rootfs" but didn't enforce it, and the host-local env file was never checked against that rule.
- **Fix applied:** cache cleared and moved to the pool by kaywoz; `media-mount.sh` now aborts when `CACHE_DIR` or the log directory is on the root filesystem.
- **Rule going forward:** a script that documents a placement rule for host-local paths enforces it (compare `stat -c %d` with `/`), and host steps for such scripts include a check of the env file's paths.

### 2026-11-10 — host steps (mktemp file modes)

- **Trigger:** apply broke something (the classifier container restart-looped, exit 2)
- **What happened:** the verified-download one-liner (`mktemp` → `sha256sum -c` → `cp`) installed the classifier's code as mode 600 root, because `mktemp` creates 0600 files and `cp` keeps the mode for new files. The image copied them as-is and the non-root process couldn't read its own script.
- **Root cause:** the download pattern was written for root-only config files and reused for files a non-root process must read; the Dockerfile didn't set modes on `COPY`.
- **Fix applied:** Dockerfile `COPY --chmod=644`; on the host `chmod 644` on the code files.
- **Rule going forward:** host download one-liners for files read by non-root processes end with an explicit `chmod` (e.g. `install -m 644`), and Dockerfiles set `--chmod` on `COPY` when the image runs as a non-root `user`.

### 2026-11-11 — hetzner (SSH key fingerprint formats)

- **Trigger:** wrong assumption — a needless rebuild was proposed
- **What happened:** SSH to the new honeypot failed. kaywoz compared the key's fingerprint in Hetzner's console with the one in 1Password, and they didn't match. I took that to mean the secret held the wrong key and proposed replacing the key and the server. The rerun showed the key unchanged: it had been right all along. The real cause was that the 1Password agent didn't serve the key's vault.
- **Root cause:** I asked for a fingerprint comparison without checking that both sides used the same format. Hetzner's console shows MD5, 1Password and `ssh-keygen -l` show SHA256. Before calling the key wrong, I also didn't check which keys the agent offered: the `ssh -v` log only listed other keys.
- **Fix applied:** no rebuild. The vault was added to `agent.toml`. The host steps now say how to compare fingerprints in one format (`ssh-keygen -l -E md5`) and use an `IdentitiesOnly` host entry.
- **Rule going forward:** when comparing key fingerprints across tools, state the format and give the command for it. Before blaming the server's key, check in `ssh -v` that the intended key was offered at all.

### 2026-11-11 — hetzner (T-Pot reserved username)

- **Trigger:** script failed on the host
- **What happened:** the host steps had kaywoz create a non-root admin user named `tpot` for running T-Pot's installer. T-Pot rejects that name, because its installer creates its own `tpot` system user and group (uid/gid 2000, `installer/install/tpot.yml`).
- **Root cause:** I picked the account name from the product name without reading what the installer creates. I had read only the README.
- **Fix applied:** kaywoz used a different name. The host steps now take any name except `tpot` as `<admin user>` and keep it out of git (§4).
- **Rule going forward:** before naming a user, group or path for a third-party installer, grep its install scripts/playbooks for the users, groups and uids it creates.

### 2026-11-11 — hetzner (empty key file from a failed redirect)

- **Trigger:** command failed on the admin Mac
- **What happened:** I handed over `op item get … > ~/.ssh/tpot.pub && ssh-keygen -lf …`. `op` wasn't installed, but zsh still created the redirect target, so the file was empty. Later `ssh -i ~/.ssh/tpot.pub` matched no agent key and fell back to a password prompt.
- **Root cause:** a `>` redirect truncates or creates its target before the command runs, so a failed command still leaves a file behind. Chaining with `&&` doesn't prevent that.
- **Fix applied:** the file was rewritten from the 1Password agent (`ssh-add -L | grep …`) and the fingerprint checked against the agent.
- **Rule going forward:** commands for kaywoz that write a file from another command's output write to `T=$(mktemp)`, check that it isn't empty (`[ -s "$T" ]`), then `mv` it into place.

### 2026-11-11 — tpot (idempotency check matched a comment)

- **Trigger:** apply broke something (Galah exited with "API key is required")
- **What happened:** the compose patch for T-Pot ran `grep -q 'LLM_API_KEY: ${GALAH_LLM_API_KEY}' || sed … a\ LLM_API_KEY…`. Upstream already had that line commented out (`# LLM_API_KEY: …`), so the grep matched the comment, the line was never added, and Galah started without a key.
- **Root cause:** the "already present?" check didn't anchor to uncommented lines. I hadn't read the target file's existing lines before writing the patch.
- **Fix applied:** the commented line was uncommented on the host. The host steps' patch now anchors every check (`^\s+KEY:`), uncomments an existing commented line before adding one, and ends with a length-only check of the rendered variables.
- **Rule going forward:** idempotency checks in config patches match only active lines (anchor `^\s*` without `#`). Before patching a third-party file, read its current lines for the keys being added, including commented ones.

### 2026-11-11 — workflow (pushed to a merged PR again)

- **Trigger:** commit missed `main` (repeat of 2026-11-03, "commits pushed to an already-merged PR")
- **What happened:** a follow-up commit for PR 298 was pushed after kaywoz had merged it. My command ran `gh pr view 298 --json state` but carried on when it printed `MERGED`, so the commit landed only on the dead branch.
- **Root cause:** the state check printed the state but didn't gate the push. I ran the check without acting on its result.
- **Fix applied:** the commit was cherry-picked onto a new branch from `main` with a new PR.
- **Rule going forward:** the state check is a gate in the same command: `[ "$(gh pr view N --json state --jq .state)" = OPEN ] && git push …`. A non-`OPEN` state stops the push.

### 2026-11-16 — compose (stack scope decided alone)

- **Trigger:** misunderstood request
- **What happened:** the stack proposal (PR 321) was asked to pick apps from the earlier short list. I moved Kopia, Time Machine and the S3 store into "a separate proposal" and parked Immich, without asking, and added Pocket ID and Ollama. kaywoz set the stacks: media (Jellyfin, Komga, Homey), infra (cloudflared), apps (mediasort, paperless-ngx, FileBrowser Quantum, Immich), and a fourth, storage (Kopia, Time Machine, RustFS).
- **Root cause:** treated "pick from the earlier discussion" as licence to narrow the scope by my own placement rules (a deployer and storage services "don't belong in a stack") instead of putting the cut to kaywoz.
- **Fix applied:** PR 321 reworked to the four stacks kaywoz named.
- **Rule going forward:** when a request says to build from an earlier list, every item on it is in scope unless kaywoz drops it; an item I'd leave out or move goes to him as a one-line question before the draft, not as a decision in the draft.

### 2026-11-16 — compose ("risky workload" misread)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** the stack proposal (PR 321) called ArchiveTeam Warrior a "risky workload" under CLAUDE.md §8, because it runs project code it fetches at run time, and asked whether it belongs in the lab. kaywoz: a risky workload means security work (malware, analysis, forensics and similar), not an app that runs third-party code.
- **Root cause:** read "risky" in §8 by its everyday meaning instead of asking what kaywoz meant by it; the lab placement in an earlier long list was taken as support.
- **Fix applied:** the Warrior stays in the apps stack; the lab question was dropped from the proposal. Its real gaps (no read-only root, UI without auth by default) are handled as a registered exception with mitigations.
- **Rule going forward:** "risky workloads go to the lab" (CLAUDE.md §8) means security tooling: malware, analysis, forensics and similar. Don't move ordinary apps to the lab on that rule; flag their specific gaps instead.

### 2026-11-17 — compose (pushed to a merged PR, third time)

- **Trigger:** commit missed `main` (repeat of 2026-11-03 and 2026-11-11)
- **What happened:** the userns-remap update for the storage stacks was pushed to PR 321's branch after kaywoz had merged it and the branch was deleted. The push recreated the branch, and the merged PR's description was edited to describe a change it doesn't contain.
- **Root cause:** a long session that had pushed to the same open draft PR several times; the state was assumed, not checked. The 2026-11-11 gate wasn't used.
- **Fix applied:** the merged PR's description was restored; the commit was cherry-picked onto a new branch from `main` with a new PR; the recreated branch was deleted.
- **Rule going forward:** unchanged from 2026-11-11, and it applies to every push and every `gh pr edit`, also in long sessions: `[ "$(gh pr view N --json state --jq .state)" = OPEN ] && …`.

### 2026-11-16 — mos (`btrfs device stats` with two paths)

- **Trigger:** command failed on the host
- **What happened:** a diagnostics block for the candidate storage host ran `btrfs device stats` with two mount paths. It failed with "exactly 1 argument expected", so the error counters weren't shown.
- **Root cause:** the command's usage wasn't checked; I assumed it takes several paths like `df`.
- **Fix applied:** loop over `findmnt -t btrfs -n -o TARGET`, one `btrfs device stats` per mount.
- **Rule going forward:** for any CLI not used before in this repo, check its usage line (`<cmd> --help` or the man page) before handing it over; one path per call unless the usage says otherwise.

### 2026-11-16 — mos (soak script aborted on `smartctl`'s exit code)

- **Trigger:** script bug on the host
- **What happened:** the soak script (`set -euo pipefail`) aborted early because `smartctl -A` exits non-zero when a drive's error log has entries, even though the read succeeded.
- **Root cause:** assumed exit 0 means "read OK" for `smartctl`; its exit status is a bitmask that also reports drive state.
- **Fix applied:** `smartctl … || true` in the reader, plus an `ERR` trap that prints the failing line.
- **Rule going forward:** in `set -e` scripts, check the exit-code semantics of every monitoring tool (`smartctl`, `nvme`, `ipmitool`, …) and tolerate the non-fatal codes explicitly; add an `ERR` trap that names the line.

### 2026-11-16 — mos (`<placeholder>` read as a redirect)

- **Trigger:** command failed on the host
- **What happened:** a soak start command contained the placeholder `<old-host-ip>`. It was run unedited, bash read `<` as a redirect, and the soak never started (an empty test folder was left behind).
- **Root cause:** placeholders written with angle brackets, which are shell syntax.
- **Fix applied:** folder removed, command re-sent with a placeholder without brackets.
- **Rule going forward:** placeholders in commands handed to kaywoz never use `<>` (or other shell metacharacters); use plain words such as `OLD_HOST_IP`.

### 2026-11-17 — mos (remap checked before Docker was up)

- **Trigger:** wrong diagnosis
- **What happened:** the first runtime test of Docker `userns-remap` was reported as failed ("no socket"). The check ran right after `/etc/init.d/docker restart`, but the init script starts `dockerd` in the background, so it wasn't up yet.
- **Root cause:** assumed the init script returns once the daemon is ready.
- **Fix applied:** wait loop (`docker info` until it answers, max 60 s) before any check.
- **Rule going forward:** after starting or restarting a daemon, poll for readiness (socket/API answers) before checking its state; never treat the first failed probe as a result.

### 2026-11-17 — mos (watchdog lock inherited by `dockerd`)

- **Trigger:** script bug on the host
- **What happened:** `docker-userns.sh` held a `flock` on fd 9 and then restarted Docker. `dockerd` inherited fd 9 and held the lock for its lifetime, so every later run, including `--check`, exited silently.
- **Root cause:** an open lock fd is inherited by every process the script starts, including long-running daemons.
- **Fix applied:** the init script is called with `9>&-`; `--check` takes no lock (#325).
- **Rule going forward:** scripts that hold a lock close the lock fd for every child that may outlive them (`9>&-`), and read-only modes take no lock.

### 2026-11-17 — mos (`docker_options` tested through the wrong path)

- **Trigger:** wrong conclusion
- **What happened:** I concluded that MOS ignores `docker_options` in `docker.json` and drafted a bug report saying so. The test had restarted Docker with `/etc/init.d/docker` directly, which doesn't read the key; `mos-start` and the UI do pass it at start. The UI also has a field for it, which I said didn't exist.
- **Root cause:** tested a shortcut path instead of the path the OS uses at boot, and didn't read `mos-start` before concluding.
- **Fix applied:** read `mos-start`, confirmed with a harmless flag through the UI, corrected the bug report and #310.
- **Rule going forward:** test a setting through the same path the platform uses (boot script or UI), and read that path's code before saying a setting has no effect.

### 2026-11-17 — mos (remap user restored without its group)

- **Trigger:** apply broke something (Docker didn't start after a reboot)
- **What happened:** after a Samba-only user was created in the MOS UI, MOS saved its user list, `dockremap` included, to `/boot/config/system/passwd`, but not the group. At the next boot the user came back without its group; `docker-userns.sh` only created the user when it was missing, so it skipped, and `dockerd` refused to start.
- **Root cause:** the hook treated user and group as one unit and assumed nothing else in MOS touches `/etc/passwd`.
- **Fix applied:** `groupadd` by hand on the host; the hook now checks user and group separately and `--check` reports a missing group (#341).
- **Rule going forward:** a hook that recreates RAM `/etc` state checks every piece it depends on (user, group, subuid, subgid, config) on its own, and after any change in the MOS UI that touches users, reboot-test before relying on it.

### 2026-11-17 — homenas (design drifted past need and proportionality)

- **Trigger:** kaywoz had to redirect after hours of troubleshooting
- **What happened:** the homenas Docker plan stacked daemon-wide userns-remap (boot hook, cron guard, re-owned appdata, five exemptions), per-VLAN macvlan zones, per-zone Tailscale sidecars, and an infra stack owning every network. Each layer was defended on its own; together they produced a chain of MOS-specific failures (RAM `/etc`, a missing group, Docker running on RAM after an out-of-band restart) and test after test, for a home NAS that appliance vendors run with none of it.
- **Root cause:** each control was judged by whether it reduced some risk, not by whether the risk was worth its cost on a homelab box (CLAUDE.md §8 proportionality), and nobody compared the design with what comparable NAS platforms do by default.
- **Fix applied:** consolidation of the design against need and proportionality, with a smaller baseline proposed to kaywoz.
- **Rule going forward:** before adding a control that needs platform workarounds (boot hooks, patched OS state, exemptions), state the concrete threat, what the per-container defaults already cover, and what comparable appliances do; propose it only if the residual risk is clearly worth the upkeep, and ask kaywoz first.

### 2026-11-12 — planning (hardware role swap misread)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** kaywoz asked "what if I keep the CWWK but replace [the monitoring host] with it?". I read "it" as the new F4 SSD and planned the F4 as the new monitoring host. kaywoz meant: the F4 SSD runs MOS as the storage host, the CWWK (today's storage host) becomes the monitoring host, and the Pi 5 retires.
- **Root cause:** I resolved an ambiguous pronoun to the most recently discussed object, without restating the mapping before a long answer.
- **Fix applied:** the plan was redone with the correct roles before anything was changed.
- **Rule going forward:** when a request moves hardware between roles, restate the full mapping (box → role, for every box involved) in one line and get it confirmed before planning around it.

### 2026-11-13 — planning (management portal rule paraphrased as "one Cockpit per host")

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** when listing what CLAUDE.md §8 covers, I wrote "one Cockpit per host". kaywoz's rule is one hardware management portal per host, which can be Cockpit or the MOS UI.
- **Root cause:** I took the bullet heading ("Cockpit: one per host") as the rule. I didn't read it together with the proportionality line ("one admin UI per host").
- **Fix applied:** corrected in chat; §8 reworded in kaywoz/home0ps#313 to "one host management portal per host" (the native OS portal: Cockpit, the MOS UI or similar), with logical management portals allowed to span hosts within the other axioms.
- **Rule going forward:** when summarizing a CLAUDE.md rule, quote its wording, not a heading. If two bullets overlap, state the broader one.

### 2026-11-19 — board (issue closed by number in the wrong repo)

- **Trigger:** wrong assumption
- **What happened:** during board triage, kaywoz said "won't do" for board item #17 (a theme upgrade in the blog repo). I ran `gh issue close 17` in this repo and closed kaywoz/home0ps#17, an unrelated issue. I reopened it with a comment within minutes.
- **Root cause:** the board holds items from more than one repo, and I listed them by number only, dropping `content.repository`. `gh issue close N` resolves N against the current repo.
- **Fix applied:** home0ps#17 reopened; the intended item is closed in its own repo with `-R`.
- **Rule going forward:** when acting on board items, list them as `owner/repo#N` (from `content.repository`) and pass `-R owner/repo` to every `gh issue` write; before closing, check the issue's title matches the board item's title.

### 2026-11-19 — docs (acknowledgements credited companies)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** for "acknowledgements always go to the owner of a repo for a service I use", I credited the GitHub owner of every upstream repo, including companies (Cloudflare, Redis, Ollama, Tecnativa, Finsys, RustFS), a foundation project and a closed-source product. kaywoz meant the people behind open-source projects, not corporations.
- **Root cause:** I read "owner of a repo" as the GitHub account field, not as the people who make the project.
- **Fix applied:** kaywoz/home0ps#362 now lists only creators, main maintainers or volunteer communities, and CLAUDE.md §8's rule says so.
- **Rule going forward:** when a rule names an owner or author, credit the people behind the work. If an owner is a company, foundation or closed-source vendor, leave it out, or ask.

### 2026-11-19 — compose (host steps written as a doc instead of a script)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** for phase 1 of the homenas apps stack I wrote `BUILD.md`, a page of commands to copy one by one. Earlier host work (the infra VM, the MOS NIC watchdog, the Docker host layer) was delivered as scripts with `--dry-run` and `--verify`. kaywoz asked why it wasn't done the same way.
- **Root cause:** I followed the README's "deploy procedure" style instead of checking how host steps had been handed over before.
- **Fix applied:** `config-files/mos/apps-stack.sh` replaces `BUILD.md`: it creates folders and secrets, checks the unverified image facts, renders the stack's `.env`, serves the Services and verifies the result. Only the MOS UI steps and the first-start logins stay manual.
- **Rule going forward:** host steps are a re-runnable script in `config-files/<platform>/` with `--dry-run` and `--verify` (now in CLAUDE.md §8 "Host layout"). A doc lists only what can't be scripted (UI clicks, first logins).

### 2026-11-19 — mos (stack script files put on the boot stick)

- **Trigger:** misunderstanding corrected by kaywoz
- **What happened:** `apps-stack.sh` kept its settings, rendered `.env` and `compose.yaml` under `/boot/config/home0ps/`, copied from `nic-watchdog.sh`. kaywoz asked why they weren't with MOS's Docker data.
- **Root cause:** I copied a convention without its reason: the watchdog lives on the stick because it must run while the pool or the NIC is in trouble. The stack script needs Docker and the pool anyway.
- **Fix applied:** everything moved to `<mos-docker>/home0ps/` (kaywoz/home0ps#365).
- **Rule going forward:** on MOS, files go on the boot stick only when they must work before or without the pool (boot, network recovery). Docker-related files live under MOS's Docker folder.
