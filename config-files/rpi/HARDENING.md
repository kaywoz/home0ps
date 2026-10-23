# Monitoring host (Raspberry Pi 5) rebuild and hardening checklist

Raspberry Pi 5 (8 GB, 128 GB NVMe), Raspberry Pi OS Lite 64-bit. Observational-only monitoring box.
`harden-rpi5.sh` (next to this file) automates everything marked **[script]**. Run it with `sudo TS_TAILNET_DNS=<tailnet>.ts.net`, reboot, then run `sudo ./harden-rpi5.sh --verify`.

## 0. Before wiping

- [ ] Back up `/srv/docker` (configs, `.env`, secret files, app data): `sudo tar czf monitoring-srv-$(date +%F).tgz -C /srv docker`
- [ ] Remove the old node from the Tailscale admin console
- [ ] Remove any stale tagged nodes (tagged nodes never expire)

## 1. Network (UniFi)

- [ ] Switch port is an **access port** on the monitoring VLAN, tagged VLANs blocked (no trunk)
- [ ] DHCP reservation for the host
- [ ] Monitoring zone: internet-only egress, admin stations allowed in

## 2. Install

- [ ] Raspberry Pi Imager → Raspberry Pi OS Lite (64-bit) on the NVMe
- [ ] Imager settings: hostname `<hostname>`, user `${LOCAL_UNIX_ACCOUNT}`, SSH public key only, no Wi-Fi, locale set
- [ ] `sudo rpi-eeprom-update -a` and reboot

## 3. Host hardening [script]

- [ ] `/boot/firmware/config.txt` under `[all]`: `dtoverlay=disable-wifi-pi5`, `dtoverlay=disable-bt-pi5`, `enable_uart=0`
  - Pi 5 needs the `-pi5` overlay names; the generic `disable-wifi`/`disable-bt` don't work
- [ ] `/boot/firmware/config.txt` under `[all]`: `kernel=kernel8.img` (4K memory pages)
  - The Pi 5 default kernel (`kernel_2712.img`) uses 16K pages; software bundling jemalloc built for 4K pages fails ("Unsupported system page size", then "Cannot allocate memory"). Fluent Bit's arm64 packages are affected
  - Check after reboot: `getconf PAGESIZE` → `4096`
- [ ] `/boot/firmware/cmdline.txt`: append `cgroup_enable=memory` (single line), otherwise every `mem_limit` is silently ignored
- [ ] Purge `avahi-daemon`, `cups*`, `bluez`, `wpasupplicant`, `triggerhappy`
- [ ] Generate `en_US.UTF-8` (stops `setlocale` warnings over SSH)
- [ ] `unattended-upgrades` with Debian, Debian-Security **and** Raspberry Pi Foundation origins, auto reboot 04:00
- [ ] Sysctls: `kptr_restrict=2`, `dmesg_restrict=1`, `unprivileged_bpf_disabled=1`, `rp_filter=1`
- [ ] SSH drop-in: no root login, no passwords, no keyboard-interactive, no X11 or agent forwarding
- [ ] Boot order `BOOT_ORDER=0xf6` (NVMe only), applied only once NVMe boot is confirmed

## 4. Tailscale

- [ ] `tag:monitoring` exists in `tagOwners` (`iac/tailscale/policy.hujson`)
- [ ] Install [script], then `sudo tailscale up --advertise-tags=tag:monitoring`
  - No `--ssh`, no `--accept-routes`
- [ ] Verify the tag: `tailscale status --self --json | grep -A2 '"Tags"'`
- [ ] No grants from `tag:monitoring` until a flow needs one; add them one per flow

## 5. Cockpit [script]

- [ ] Socket moved to `127.0.0.1:9091` (systemd drop-in)
- [ ] `cockpit.conf`: `Origins` for `cockpit-janky.<tailnet>.ts.net`, `ProtocolHeader`, `AllowUnencrypted` (localhost leg only), `LoginTo = false`
- [ ] `root` in `/etc/cockpit/disallowed-users`; strong, unique password for `${LOCAL_UNIX_ACCOUNT}`
- [ ] `sudo tailscale serve --service=svc:cockpit-janky --https=443 127.0.0.1:9091`

## 6. Docker [script]

- [ ] Installed from Docker's repo; `${LOCAL_UNIX_ACCOUNT}` in the `docker` group
- [ ] `daemon.json`: `userns-remap`, `no-new-privileges`, `icc: false`, `userland-proxy: false`, `live-restore`, `journald` log driver tagged with the container name (no `max-size`: invalid with journald)
- [ ] `/srv/docker` owned by `${LOCAL_UNIX_ACCOUNT}`; one compose file, one subfolder per service

### userns-remap rules

- [ ] Subuid base is **100000** (`grep dockremap /etc/subuid`): container UID N writes as host UID **100000 + N**
  - Containers running as `65534` → `chown 165534:165534` their data directories
- [ ] Exempt only what must be exempt, with `userns_mode: host`:
  - **socket proxy**: must be real root to open `docker.sock`
  - **Beszel agent**: host networking requires the host user namespace; runs as real `65534`, so its data dir is `chown 65534:65534`

## 7. Container standard

- [ ] `read_only`, `cap_drop: [ALL]`, non-root `user`, `no-new-privileges`, `pids_limit`, `mem_limit`
- [ ] One bridge network per app; `internal: true` only where the container needs no egress **and** publishes no ports
  - Docker won't publish ports for a container that is only on internal networks
- [ ] Publish UIs on `127.0.0.1` only; expose them as Tailscale Services (`svc:<app>`) on 443
- [ ] Secrets as files (`chmod 600`, owned by the container's host UID, gitignored), never in compose or env vars
- [ ] A healthcheck on every image that can run one
- [ ] Docker socket only via the read-only socket proxy (`POST=0`), published on localhost only

## 8. Tailscale Services (`iac/tailscale-services/`, OpenTofu) and ACL (`iac/tailscale/policy.hujson`)

- [ ] `tailscale_service` per UI: `svc:gatus`, `svc:beszel`, `svc:cockpit-janky`, `svc:dozzle`, `svc:logtide`, `svc:logtide-api`, `svc:healthchecks`
- [ ] `autoApprovers.services` → `tag:monitoring` for each service
- [ ] Grant `autogroup:admin` → the `svc:*` list on `tcp:443` only
- [ ] ACL `tests` deny the old per-port paths on the node

## 9. App auth

- [ ] Gatus: basic auth via `gatus-set-password.sh` (`security.yaml`, bcrypt + base64)
  - Test with the API (`/api/v1/endpoints/statuses` → `401`); the page shell itself returns `200`
- [ ] Beszel: create the admin right after first start; self-registration off
- [ ] Cockpit: PAM login, `root` disallowed

## 10. Monitoring the monitor

- [ ] Healthchecks.io check (5 min period, 5 min grace) with the ping UUID in `gatus/config/heartbeat.yaml`
- [ ] Alert test: `docker compose stop gatus`, wait out the grace period, confirm the alert, start again

## 11. Verify

- [ ] `sudo ./harden-rpi5.sh --verify` passes
- [ ] `sudo ss -tlnp`: only `sshd` on `0.0.0.0:22`; everything else on `127.0.0.1`, the tailnet IP or `172.31.250.1`
- [ ] `docker compose ps`: every service with a healthcheck shows `(healthy)`
- [ ] Each `https://<svc>.<tailnet>.ts.net` loads from an admin device and asks for its own login

## 12. Log shipping (`config-files/log-shipping/`)

- [ ] Run `sudo ./setup-log-shipping.sh` from the repo (not from `/srv/docker`)
  - journald: persistent, 2 GB cap, 30 days, 10 GB kept free, rate limits relaxed, `Seal=yes`
  - The script flushes the journal first; `--setup-keys` fails if `/var/log/journal/<machine-id>` doesn't exist yet
- [ ] Store the **sealing verification key** in the password manager, never on the host; check with `journalctl --verify`
- [ ] `/etc/fluent-bit/logtide.env` (root 600): shared `LOGTIDE_API_KEY`; the monitoring host uses `127.0.0.1:8083` without TLS, other hosts `logtide-api.<tailnet>.ts.net:443` with TLS
- [ ] Fluent Bit runs as `fluentbit` (group `systemd-journal`), no capabilities, `ProtectSystem=strict`, disk buffer in `/var/lib/fluent-bit`
- [ ] Recreate containers after the driver change: `docker compose up -d --force-recreate`
- [ ] Verify: an SSH login shows up in LogTide with `metadata.host` set; no 4xx/5xx in `journalctl -u fluent-bit`

## Gotchas learned the hard way

- `-pi5` overlay names on the Pi 5
- The Pi 5's default 16K-page kernel breaks jemalloc-based binaries (Fluent Bit): use `kernel=kernel8.img`
- Memory cgroup is off by default on Raspberry Pi OS
- `userns-remap` breaks socket access and host networking unless exempted
- Internal-only networks can't publish ports
- Validate YAML before restarting: `python3 -c "import yaml; yaml.safe_load(open('compose.yaml'))"`
- Pasting multi-line commands that start with `read` swallows the next line as input
- Docker's `max-size` log option is invalid with the journald driver and stops dockerd from starting
- journald and Fluent Bit classic configs don't allow comments on the same line as a setting
- Tailscale Services auto-approval is evaluated when a host advertises the service: merge the policy PR (`autoApprovers.services`) **before** `tailscale serve --service=…`; otherwise toggle the service off and on, or approve it in the console. The "approval from an admin is required" message from `serve` is printed regardless; check the console or `tailscale status --json` (`CapMap."service-host"`)
- Fluent Bit treats HTTP `401` as permanent ("chunk will not be retried"): a wrong or rotated LogTide key **drops** logs instead of queueing them. Rotate senders before revoking the old key
- Shoutrrr URLs (Beszel notifications): Slack `slack://hook:A-B-C@webhook`, generic webhook `generic://host/path` (HTTPS by default)
