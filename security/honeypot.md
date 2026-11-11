# Honeypot security design (T-Pot, Hetzner Cloud)

Hetzner Cloud server `he-all-tpot-0101`, Debian 13, **T-Pot LLM edition** (Beelzebub SSH, Galah HTTP, OpenAI backend), kaywoz/home0ps#291. **Untrusted by design:** it invites attacks, so assume it gets compromised. It is not a home0ps host. It doesn't follow the home baseline in [`SECURITY.md`](../SECURITY.md) (no Tailscale, no Fluent Bit, no container standard). This file lists what applies instead.

Build: [`iac/hetzner/server_vm.tf`](../iac/hetzner/server_vm.tf); host steps: [`config-files/tpot/README.md`](../config-files/tpot/README.md).

**Status legend:** controls without a marker are in place and verified; *(planned)* items are tracked in the linked issue; *(untested)* items are configured but not yet confirmed on the host.

## Isolation

| Risk | Control |
|---|---|
| Compromise spreads to home0ps | No Tailscale and no grants. Nothing in home0ps trusts or reaches it, and it holds no credentials that work elsewhere. Admin only from the Mac |
| Reused SSH key | A key used only for this host (`~/.ssh/tpot`), public half from the `TPOT_SSH_PUBLIC_KEY` secret |
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
| SSH | Key only; root login off after install *(planned)*; non-root `tpot` user |
| Web UI | T-Pot's nginx basic auth (`WEB_USER`), set interactively so it stays out of the shell history *(planned)* |

## LLM backend

| Risk | Control |
|---|---|
| Denial of wallet (attackers drive API calls) | A separate OpenAI project and key on **prepaid credits, auto-recharge off**, so spend ends when the credits run out. Galah caches answers for 24 h. Beelzebub rate limit on *(untested)* |
| API key stolen from the host | Assumed to happen. The key works only for that project and is bounded by its credits. Rotate it after any sign of compromise |

## Accepted risks

- `cpx22` is below T-Pot's 8 GB guidance (kaywoz, 2026-11-11). Expect slow Elasticsearch/Kibana, and resize when the load shows it's needed.
- Captured data goes to T-Pot's community backend (ewsposter, opted in).
- Upstream `llm.yml` needs local edits for API keys, and `update.sh` may undo them.
- The home public IPv4 sits in the Hetzner firewall and in OpenTofu state (marked `sensitive`, so it isn't shown in plan output).

## Open issues

- Host install, LLM wiring and verification — kaywoz/home0ps#291
