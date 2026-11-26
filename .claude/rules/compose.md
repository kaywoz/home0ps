---
paths:
  - "docker-compose/**"
  - "config-files/mos/*-stack.sh"
---

# Docker Compose stacks

Moved from `CLAUDE.md` unchanged, except one cross-reference.

- **Host layout:** `/srv/docker/compose.yaml` — one file, all services
  inline, no `include:` — plus one data subfolder per service. Host-level
  config lives in this repo (`config-files/`), not in `/srv/docker`.
  **Exception — homenas** (MOS, kaywoz 2026-11-17): one compose file per
  stack (`docker-compose/homenas/<stack>/compose.yaml`), each one MOS
  stack, because MOS starts, stops and autostarts per stack.
- **Networks:** one bridge per app, `proxy-<app>`; `internal: true` only when
  the container needs no egress **and** publishes no ports.
- **Container standard:** non-root `user`, `read_only` + `tmpfs`,
  `cap_drop: [ALL]`, `no-new-privileges`, `mem_limit`, `cpus`, `pids_limit`,
  healthcheck where the image allows, ports on `127.0.0.1` only, secrets as
  files (`600`, owned by the container's remapped host UID), never in git.
- **Docker socket:** only `tecnativa/docker-socket-proxy` mounts it
  (`POST=0`); consumers use `DOCKER_HOST=tcp://…:2375`. Exceptions:
  Dockhand-home on its own VM and the Hawser agents it manages, until
  they retire (see CLAUDE.md §8, Dockhand), and Arcane on the homenas.
- **`cpus`** (kaywoz, 2026-11-26): every service sets a CPU limit, sized
  from the host's real `nproc` like `mem_limit` (MISTAKES.md, Ollama CPU
  limit), never a figure from chat.
- **Lint gate** (kaywoz, 2026-11-26): `compose-lint` (pinned, hash-locked in
  `.github/compose-lint/`) lints every stack with the `.compose-lint.yml`
  beside its `compose.yaml`. CI (`lint-compose.yml`) fails on high or
  critical; the Claude hook (`.claude/hooks/compose-lint.sh`) reports
  medium and up after each edit, so fix them in the same change. A
  suppression needs a reason that points to its record (CLAUDE.md §8 or
  the homenas exception register); add both in the same change.
  `:latest` and digest rules (CL-0004, CL-0019) are off by §8.
