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
