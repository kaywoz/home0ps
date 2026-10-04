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
