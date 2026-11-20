---
paths:
  - "iac/**"
  - ".github/workflows/deploy-*.yml"
---

# OpenTofu (`iac/`)

Moved from `CLAUDE.md` unchanged.

- OpenTofu backends use **partial configuration**: `endpoint` and `bucket`
  come from the `S3_ENDPOINT` / `S3_BUCKET` secrets via `-backend-config` at
  `tofu init`; only `key` (a state path like `<area>/terraform.tfstate`)
  stays in `backend.tf`. Never put credentials or bucket names in code.
- **Providers are pinned exactly** (`version = "x.y.z"`) and every root
  module commits its `.terraform.lock.hcl`. A provider upgrade is its own PR;
  never mix it with a content change, or schema noise hides the real diff.
- **Read the plan's summary line, not the job colour.** Green means it ran;
  the expected `N to add, N to change, N to destroy` is stated in the PR.
