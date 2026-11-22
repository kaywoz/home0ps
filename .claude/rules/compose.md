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
  `cap_drop: [ALL]`, `no-new-privileges`, `mem_limit`, `pids_limit`,
  healthcheck where the image allows, ports on `127.0.0.1` only, secrets as
  files (`600`, owned by the container's remapped host UID), never in git.
- **Docker socket:** only `tecnativa/docker-socket-proxy` mounts it
  (`POST=0`); consumers use `DOCKER_HOST=tcp://…:2375`. Exceptions:
  Dockhand-home on its own VM and the Hawser agents it manages, until
  they retire (see CLAUDE.md §8, Dockhand), and Arcane on the homenas.
