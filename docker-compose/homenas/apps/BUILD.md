# Apps stack, phase 1: build on the homenas

Phase 1 (kaywoz, 2026-11-19) starts **mediasort, CannonCommander, Atuin, HedgeDoc, Filestash and RackPeek**. They use plain bridges only and start with fresh data. paperless, Immich and the archivers stay behind their compose profiles (`compose.yaml` header) until their prerequisites are done.

All commands run **on the homenas, as root** (MOS has no sudo). Nothing here prints a secret.

## 0. Before you start

- The Tailscale side is already on `main`: the Services in `iac/tailscale-services/services.tf`, auto-approval for `tag:storage` and the admin grant in `iac/tailscale/policy.hujson`.
- Docker was started by MOS (test (e) in the README): the data root is on the pool, not RAM.

Set the appdata path for this shell. It is the same as `APPDATA` in the stack's `.env`:

```bash
A=/var/mergerfs/merger-nvme/disk1/mos-docker/appdata
```

## 1. Folders and owners

```bash
install -d -m 700 -o 2104 -g 2104 $A/mediasort $A/mediasort/secrets
install -d -m 700 -o 2121 -g 2121 $A/atuin $A/atuin/config
install -d -m 700 -o 2123 -g 2123 $A/hedgedoc $A/hedgedoc/db $A/hedgedoc/uploads $A/hedgedoc/secrets
install -d -m 700 -o 1654 -g 1654 $A/rackpeek $A/rackpeek/config
```

CannonCommander runs as the Samba-only data user (README A-Q2). Use its uid and gid, the same values as `SHARE_UID` and `SHARE_GID` in `.env`:

```bash
install -d -m 700 -o <SHARE_UID> -g <SHARE_GID> $A/cannoncommander $A/cannoncommander/cache
```

Filestash runs as its image's own user. Check the uid first; the README expects 1000 (A-Q10):

```bash
docker run --rm --entrypoint id machines/filestash
```

```bash
install -d -m 700 -o <uid from above> -g <gid from above> $A/filestash $A/filestash/state
```

RackPeek's container port is unverified (the compose maps `127.0.0.1:8081` to container port 8080). Check it:

```bash
docker run --rm --entrypoint env aptacode/rackpeek | grep -E '^ASPNETCORE_(HTTP_)?(URLS|PORTS)='
```

If the port isn't 8080, tell Claude so `compose.yaml` gets fixed before you start the stack.

## 2. Secrets

**mediasort:** copy `token`, `tmdb` and `llm` from the apps VM's `/srv/docker/mediasort/secrets/` into `$A/mediasort/secrets/` (scp over the tailnet, or through the admin workstation). Then fix the owner and mode:

```bash
chown 2104:2104 $A/mediasort/secrets/* && chmod 600 $A/mediasort/secrets/*
```

**HedgeDoc session secret:**

```bash
(umask 077; openssl rand -hex 32 | tr -d '\n' > $A/hedgedoc/secrets/session_secret) && chown 2123:2123 $A/hedgedoc/secrets/session_secret
```

**CannonCommander `config.yaml`:** it holds the admin password, so the instance never starts without a sign-in. Read the password into a variable first; this block has one line only. No `"` or `\` in the password (it goes into a quoted YAML string):

```bash
read -rs -p 'CannonCommander admin password: ' CCPW; echo
```

Then write the config:

```bash
(umask 077; cat > $A/cannoncommander/config.yaml <<EOF
http:
  port: 8080
  baseURL: "/"
server:
  cacheDir: "/config/cache"
  logging:
    - levels: "info|error|warning"
  sources:
    - path: "/mnt/user"
      name: "Shares"
auth:
  methods:
    noauth: false
    password:
      enabled: true
      adminUsername: "admin"
      adminPassword: "$CCPW"
      minLength: 12
EOF
) && unset CCPW && chown -R <SHARE_UID>:<SHARE_GID> $A/cannoncommander
```

This is upstream's `_docker/config.yaml` with the port moved to 8080, the `/remotes` source dropped (no rclone remotes, A-Q2) and the admin password set (`auth.methods.password`, as in upstream's `config.generated.yaml`). CannonCommander resets the admin password to this value at every start, so change it here, not in the UI.

## 3. The stack's `.env`

Start from [`.env.example`](.env.example). Every key needs a value, **including those for the apps that stay off**: Compose fills in the whole file, and an empty path (`PHOTOS=`) fails even for a service that doesn't start. For the later apps, real values or placeholders both work; their networks and secrets aren't created until their profile is on.

- `COMPOSE_PROFILES=` stays empty: phase 1 only.
- `ATUIN_OPEN_REGISTRATION=true` **only for the first start** (step 5); then remove it.
- `TAILNET` = the tailnet's MagicDNS name (HedgeDoc builds its URL from it).

## 4. Create and start the stack (MOS UI)

1. Docker → Stacks → new stack `apps`. Paste `compose.yaml` from `main` and the filled-in `.env`.
2. Turn **autostart on**.
3. Start it. Expected: six containers (`kr-ccp-mediasort-0201`, `-cannoncommander-0101`, `-atuin-0101`, `-hedgedoc-0101`, `-filestash-0101`, `-rackpeek-0101`), each `healthy` where the image has a healthcheck.

Check what's running against the repo:

```bash
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'mediasort|cannoncommander|atuin|hedgedoc|filestash|rackpeek'
```

```bash
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -v '127.0.0.1' | grep -E 'mediasort|cannoncommander|atuin|hedgedoc|filestash|rackpeek'
```

The second command should print nothing: every port is on `127.0.0.1`.

**If a container won't start:** the README lists what's unverified. `read_only` is the usual suspect: for CannonCommander, HedgeDoc and Filestash, **drop `read_only`** for that service and note it in the README's Stack 3 table (no workarounds). The fallback for CannonCommander is E8 in the exception register. Tell Claude what failed, and the repo change goes in as its own PR.

## 5. First-start settings (right after step 4)

- **Filestash:** open `/admin/setup` through `svc:filestash` and set the admin password **immediately**. Until then the setup page is open to anyone who can reach the Service.
- **Atuin:** register your account from one client (`atuin register`, server `https://atuin.<tailnet>.ts.net`). Then remove `ATUIN_OPEN_REGISTRATION` from `.env` and restart the stack from the MOS UI.
- **HedgeDoc:** create your user (it prompts for the password):

```bash
docker exec -it kr-ccp-hedgedoc-0101 bin/manage_users --add <your login email>
```

- **CannonCommander:** sign in as `admin` with the password from step 2.
- **RackPeek:** it has no login. Only admins reach it, through the grant.

## 6. Tailscale Services

```bash
tailscale serve --service=svc:cannoncommander --https=443 127.0.0.1:8080
```

```bash
tailscale serve --service=svc:atuin --https=443 127.0.0.1:8888
```

```bash
tailscale serve --service=svc:hedgedoc --https=443 127.0.0.1:3000
```

```bash
tailscale serve --service=svc:filestash --https=443 127.0.0.1:8334
```

```bash
tailscale serve --service=svc:rackpeek --https=443 127.0.0.1:8081
```

mediasort gets no Service: the mover on this host calls `127.0.0.1:8089`.

Check that the box advertises them, and check again after the next reboot:

```bash
tailscale serve status
```

## 7. mediasort cutover

mediasort runs here now, but the mover keeps using the apps VM until its `CLASSIFIER_URL` changes. Do this when the mover runs on this box:

1. Set `CLASSIFIER_URL=http://127.0.0.1:8089` in the mover's env (`config-files/mos/media-sort.env.example`).
2. Run one dry run of the mover.
3. Stop mediasort on the apps VM.

## 8. Tell Claude when it's done

The repo follow-ups, each its own PR:

- `docker-compose/CONTAINERS.md`: move the six names into the main table, with today's date.
- Any `read_only` drops or port fixes from step 4, in the README's Stack 3 table.
- `security/homenas.md`: the six apps as built.
