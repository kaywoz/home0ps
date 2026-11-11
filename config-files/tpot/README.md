# T-Pot honeypot (LLM edition): host steps

Server `he-all-tpot-0101` on Hetzner Cloud, created by `iac/hetzner/server_vm.tf` (kaywoz/home0ps#291). T-Pot itself is installed by hand with its own installer. Security summary: [`security/honeypot.md`](../../security/honeypot.md).

**This host is untrusted.** Connect to it only from the Mac with its own key. Never put it on the tailnet, and never give it credentials that work anywhere else.

Upstream docs: T-Pot `README.md` and `env.example` on `master` (github.com/telekom-security/tpotce), plus Galah's `README.md` (github.com/0x4D31/galah).

## 1. Before the PR's plan runs

The key and IP come from GitHub secrets, never git.

Mac:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/tpot -C tpot
```

Mac:

```bash
gh secret set TPOT_SSH_PUBLIC_KEY < ~/.ssh/tpot.pub
```

Mac (home public IPv4; if it changes, set it again and re-run `deploy-hetzner.yml`):

```bash
curl -4 -s https://ifconfig.me | gh secret set HOME_PUBLIC_IPV4
```

## 2. OpenAI

- Create a separate OpenAI project with its own API key, used only for this host.
- Pay with **prepaid credits, auto-recharge off**. Spend stops when the credits run out. That is the cap, because the key has to be assumed leaked once the host is compromised.

## 3. Base OS (after apply, before T-Pot)

Until the installer runs, OpenSSH listens on tcp/22 for the world (key only). Do this step and step 4 in one go.

Mac:

```bash
ssh -i ~/.ssh/tpot root@<tpot_ipv4 from the apply log>
```

T-Pot host (root). The installer must run as a non-root user:

```bash
apt-get update && apt-get -y full-upgrade && apt-get -y install sudo curl git \
&& adduser --gecos "" tpot && usermod -aG sudo tpot \
&& install -d -m 700 -o tpot -g tpot /home/tpot/.ssh \
&& install -m 600 -o tpot -g tpot /root/.ssh/authorized_keys /home/tpot/.ssh/authorized_keys
```

## 4. T-Pot install

T-Pot host (as `tpot`: `su - tpot`). Run it interactively, pick **(L)LM**, and set the web user when asked. That keeps the web password out of the shell history.

```bash
cd ~ && git clone https://github.com/telekom-security/tpotce && cd tpotce && ./install.sh
```

The installer moves OpenSSH to **tcp/64295**. Reboot when it asks. From then on, from the Mac:

```bash
ssh -i ~/.ssh/tpot -p 64295 tpot@<tpot_ipv4>
```

The web UI is at `https://<tpot_ipv4>:64297`. The certificate is self-signed. Both ports are open to the home IP only.

T-Pot host (root): with the `tpot` login working, turn off root SSH:

```bash
printf 'PermitRootLogin no\n' > /etc/ssh/sshd_config.d/10-no-root.conf && sshd -t && systemctl reload ssh
```

## 5. LLM backend (OpenAI)

T-Pot's `compose/llm.yml` passes these variables through. Set them in `~/tpotce/.env`, which is `600` and never in git:

```text
BEELZEBUB_LLM_MODEL=<OpenAI model value Beelzebub accepts; env.example comments show "gpt4-o">
GALAH_LLM_PROVIDER=openai
GALAH_LLM_MODEL=<a small, cheap OpenAI model>
GALAH_LLM_API_KEY=<key from step 2>
BEELZEBUB_OPENAISECRETKEY=<key from step 2>
```

Two gaps in upstream `llm.yml`. Check both on the host before relying on them:

- **Galah:** the API key line is commented out. In `~/tpotce/docker-compose.yml`, under `galah:` → `environment:`, add `LLM_API_KEY: ${GALAH_LLM_API_KEY}`. Galah caches answers for 24 h by default (`--cache-duration`), which keeps repeat requests off the API.
- **Beelzebub:** no API key variable is passed at all, and how T-Pot's Beelzebub image reads its key is **unverified**. Look in the image's service config (`openAISecretKey`, `llmProvider`, `llmModel`, `rateLimit*` in upstream Beelzebub's YAML) before wiring it. Keep its rate limit on.

Apply the changes, then follow the logs:

```bash
sudo systemctl restart tpot && docker logs -f galah
```

`update.sh` may overwrite `docker-compose.yml`. Re-check both edits after every update.

## 6. Community data

Opted in (kaywoz, 2026-11-11): leave the `ewsposter` service as installed.
