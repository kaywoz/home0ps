# Honeypot security design (T-Pot, Hetzner Cloud)

Hetzner Cloud server `he-all-tpot-0101`, Debian 13, **T-Pot LLM edition** (Beelzebub SSH, Galah HTTP, OpenAI backend), kaywoz/home0ps#291. **Untrusted by design:** it invites attacks, so assume it gets compromised. It is not a home0ps host. It doesn't follow the home baseline in [`SECURITY.md`](../SECURITY.md) (no Tailscale, no Fluent Bit, no container standard). This file lists what applies instead.

> **Status 2026-11-12:** the Hetzner server is retired (logs exported first, see `config-files/tpot/README.md` §7). Its OpenTofu config is archived in [`archive/iac/hetzner-tpot/`](../archive/iac/hetzner-tpot/server_vm.tf). The honeypot is being rebuilt at HOSTKEY, and this file will be updated with that change. Until then the controls below describe the retired Hetzner setup.

Build (retired): [`archive/iac/hetzner-tpot/server_vm.tf`](../archive/iac/hetzner-tpot/server_vm.tf); host steps: [`config-files/tpot/README.md`](../config-files/tpot/README.md).

**Status legend:** controls without a marker are in place and verified; *(planned)* items are tracked in the linked issue; *(untested)* items are configured but not yet confirmed on the host.

## Isolation

| Risk | Control |
|---|---|
| Compromise spreads to home0ps | No Tailscale and no grants. Nothing in home0ps trusts or reaches it, and it holds no credentials that work elsewhere. Admin only from the Mac |
| Reused SSH key | A key used only for this host, kept in 1Password and served by its agent (`IdentitiesOnly` host entry); public half from the `TPOT_SSH_PUBLIC_KEY` secret |
| Cloud account abuse from the host | No Hetzner token on the host. Server, firewall and key are managed only by `deploy-hetzner.yml` |

## Network exposure

| Risk | Control |
|---|---|
| Admin ports reachable by attackers | Hetzner Cloud firewall: tcp/64295 (OpenSSH) and tcp/64297 (web UI) from the home IPv4 only (`HOME_PUBLIC_IPV4` secret); IPv6 gets no admin rule *(untested)* |
| Honeypot ports | tcp/udp 1–64000 and ICMP open to the world, as T-Pot recommends |
| Window before install | OpenSSH on tcp/22 is world-reachable, key only, until `install.sh` moves it. Install straight after apply |

## Authentication

| Risk | Control |
|---|---|
| SSH | OpenSSH on tcp/64295 only, key only: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no` as drop-ins in `/etc/ssh/sshd_config.d/`, which win over the main config's `prohibit-password` because sshd keeps the first value. Verified from outside 2026-11-11: root is refused with a valid key, the admin user gets in, and only `publickey` is offered. Non-root admin user (not `tpot`, which T-Pot reserves for its services) |
| Web UI | T-Pot's nginx basic auth (`WEB_USER`), set interactively during the install, so it stays out of the shell history. Unauthenticated requests get `401` (verified 2026-11-11) |

## LLM backend

| Risk | Control |
|---|---|
| Denial of wallet (attackers drive API calls) | A separate OpenAI project and key on **prepaid credits, auto-recharge off**, so spend ends when the credits run out; that is the only cap. Galah (OpenAI, small model) caches answers for 24 h. Both honeypots were verified answering through OpenAI on 2026-11-11 (Galah `source: llm` then a cache hit; Beelzebub answered `uname -a` over SSH). Beelzebub at T-Pot's pinned commit has **no rate limit**, a fixed `gpt-4o` model and accepts any SSH password, so every attacker command is one gpt-4o call |
| API key stolen from the host | Assumed to happen. The key works only for that project and is bounded by its credits. Rotate it after any sign of compromise |
| Key exposure on the host | `.env` set to `600` (the installer leaves it `664`). The key also sits in both containers' environment (`docker inspect`): accepted, because the host is assumed compromised anyway |

## Accepted risks

- `cpx32` (4 vCPU, 8 GB RAM, 80 GB disk kept from `cpx22`, so the server can still be resized back down) is below T-Pot's hive guidance of 16 GB RAM / 256 GB SSD (kaywoz, 2026-11-11). Watch Elasticsearch memory and disk use; logs persist 30 days (`TPOT_PERSISTENCE_CYCLES`).
- Captured data goes to T-Pot's community backend (ewsposter, opted in).
- Upstream `llm.yml` needs local edits for API keys (three compose lines, plus a Beelzebub SSH decoy config mounted over the one in the image), and `update.sh` may undo them.
- The home public IPv4 sits in the Hetzner firewall and in OpenTofu state (marked `sensitive`, so it isn't shown in plan output).

## Open issues

- IPv6: the admin ports have no IPv6 rule, so they should be closed over IPv6. That's untested, because the admin Mac has no IPv6.
- Parked (proposed 2026-11-11, not approved): off-host copies of the Galah/Beelzebub logs with a write-only token; a golden snapshot with a daily rebuild; a scheduled up/down that deletes and recreates the server, since a powered-off server is still billed
