# T-Pot honeypot (LLM edition): host steps

Server `he-all-tpot-0101` on Hetzner Cloud, created by `iac/hetzner/server_vm.tf` (kaywoz/home0ps#291). T-Pot itself is installed by hand with its own installer. Security summary: [`security/honeypot.md`](../../security/honeypot.md).

**This host is untrusted.** Connect to it only from the Mac, with its own key from 1Password. Never put it on the tailnet, and never give it credentials that work anywhere else.

Upstream docs: T-Pot `README.md` and `env.example` on `master` (github.com/telekom-security/tpotce), plus Galah's `README.md` (github.com/0x4D31/galah).

## 1. Before the PR's plan runs

The key and IP come from GitHub secrets, never git.

The key lives in 1Password (its own item, used for nothing else). The 1Password SSH agent serves only the vaults listed in `~/.config/1Password/ssh/agent.toml`, so add this item there if it isn't in Private.

Mac (public half to a file, picked from the agent by the item name):

```bash
T=$(mktemp) && SSH_AUTH_SOCK=~/.1password/agent.sock ssh-add -L | grep "<1Password item name>" > "$T" && [ -s "$T" ] && install -m 600 "$T" ~/.ssh/tpot.pub && rm "$T" && ssh-keygen -lf ~/.ssh/tpot.pub
```

Mac:

```bash
gh secret set TPOT_SSH_PUBLIC_KEY -R kaywoz/home0ps < ~/.ssh/tpot.pub
```

Mac, `~/.ssh/config`. Pointing `IdentityFile` at the public key while `IdentitiesOnly` is on makes the agent offer only this key:

```text
Host tpot
  HostName <tpot_ipv4 from the apply log>
  User root
  IdentityFile ~/.ssh/tpot.pub
  IdentitiesOnly yes
```

After step 4, change it to `User <admin user>` and add `Port 64295`.

To check the key on the server, compare fingerprints in the **same format**. Hetzner's console shows MD5 (`aa:bb:…`), while 1Password and `ssh-keygen -l` show SHA256 by default. Use this for MD5:

```bash
ssh-keygen -l -E md5 -f ~/.ssh/tpot.pub
```

Mac (home public IPv4; if it changes, set it again and re-run `deploy-hetzner.yml`):

```bash
curl -4 -s https://ifconfig.me | gh secret set HOME_PUBLIC_IPV4 -R kaywoz/home0ps
```

## 2. OpenAI

- Create a separate OpenAI project with its own API key, used only for this host.
- Pay with **prepaid credits, auto-recharge off**. Spend stops when the credits run out. That is the cap, because the key has to be assumed leaked once the host is compromised.

## 3. Base OS (after apply, before T-Pot)

Until the installer runs, OpenSSH listens on tcp/22 for the world (key only). Do this step and step 4 in one go.

Mac. After a rebuild, Hetzner may hand out the same IPv4, so clear the old host keys first:

```bash
ssh-keygen -R <tpot_ipv4> && ssh-keygen -R '[<tpot_ipv4>]:64295'
```

Mac (until the install, as root on port 22):

```bash
ssh -p 22 -i ~/.ssh/tpot.pub -o IdentitiesOnly=yes root@<tpot_ipv4>
```

T-Pot host (root). The image allows password logins, so turn them off first:

```bash
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/10-keys-only.conf && sshd -t && systemctl reload ssh && sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication)'
```

T-Pot host (root). The installer must run as a non-root user. Don't name it `tpot`: the installer creates its own `tpot` system user and group (uid/gid 2000, `installer/install/tpot.yml`). Pick any other name; it stays out of git (CLAUDE.md §4).

T-Pot host (root). `adduser` asks for a password, which `sudo` needs during the install, so store it in 1Password. Group and home are looked up, not assumed:

```bash
U=<admin user> && apt-get update && apt-get -y install sudo git curl && adduser --gecos "" "$U" && usermod -aG sudo "$U" && G=$(id -gn "$U") && H=$(getent passwd "$U" | cut -d: -f6) && install -d -m 700 -o "$U" -g "$G" "$H/.ssh" && install -m 600 -o "$U" -g "$G" /root/.ssh/authorized_keys "$H/.ssh/authorized_keys" && id "$U" && ls -l "$H/.ssh/authorized_keys"
```

Expect `uid=1000(<admin user>) gid=1000(<admin user>)` with `27(sudo)`, and `authorized_keys` owned by the admin user.

Mac. Check the key login before installing; `BatchMode` never falls back to a password prompt:

```bash
ssh -p 22 -i ~/.ssh/tpot.pub -o IdentitiesOnly=yes -o BatchMode=yes <admin user>@<tpot_ipv4> true && echo OK
```

## 4. T-Pot install

T-Pot host (as the admin user: `su - <admin user>`). Run it interactively, pick **(L)LM**, and set the web user when asked. That keeps the web password out of the shell history.

```bash
cd ~ && git clone https://github.com/telekom-security/tpotce && cd tpotce && ./install.sh
```

The installer moves OpenSSH to **tcp/64295**. Reboot when it asks. From then on, from the Mac:

```bash
ssh tpot
```

(with `User <admin user>` and `Port 64295` in the host entry), or directly:

```bash
ssh -p 64295 -i ~/.ssh/tpot.pub -o IdentitiesOnly=yes <admin user>@<tpot_ipv4>
```

On port 22 you now reach the SSH honeypot: a host-key warning or a password prompt there means wrong port. Never type a real password there.

The web UI is at `https://<tpot_ipv4>:64297`. The certificate is self-signed. Both ports are open to the home IP only.

T-Pot host (root): with the admin user's login working, turn off root SSH:

```bash
printf 'PermitRootLogin no\n' > /etc/ssh/sshd_config.d/10-no-root.conf && sshd -t && systemctl reload ssh && sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication)'
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
