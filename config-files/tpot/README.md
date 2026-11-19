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

Read from the running image (2026-11-11):

- **Beelzebub** is built from a pinned fork commit (`t3chn0m4g3/beelzebub@0b9aba53`, `docker/beelzebub/Dockerfile`). `llmModel` accepts only `"ollama"` or `"gpt4-o"`. With `"gpt4-o"` it calls `api.openai.com` with the model fixed at `gpt-4o`. The SSH decoy built into the image (`configurations/services/ssh-22.yaml`) has `#openAISecretKey: ${OPENAISECRETKEY}` commented out, accepts any password, and has no rate limit.
- **Galah** takes `LLM_API_KEY`, but T-Pot's compose has that line commented out.

T-Pot host (as the admin user). Edit `~/tpotce/.env` with an editor, keeping its `KEY: "value"` style with no leading space, so keys never land on a command line:

```text
BEELZEBUB_LLM_MODEL: "gpt4-o"
BEELZEBUB_OPENAISECRETKEY: "<key from step 2>"
GALAH_LLM_PROVIDER: "openai"
GALAH_LLM_MODEL: "<a small OpenAI model>"
GALAH_LLM_API_KEY: "<key from step 2>"
```

T-Pot host (as the admin user). Lock down `.env`, which the installer leaves group- and world-readable:

```bash
chmod 600 ~/tpotce/.env
```

T-Pot host (as the admin user). Copy Beelzebub's SSH decoy out of the image with the key line switched on. The file holds only the `${OPENAISECRETKEY}` placeholder, not the key:

```bash
cd ~/tpotce && T=$(mktemp) && docker cp beelzebub:/opt/beelzebub/configurations/services/ssh-22.yaml - | tar -xO | sed 's/^  #openAISecretKey:/  openAISecretKey:/' > "$T" && [ -s "$T" ] && grep -q '^  openAISecretKey: \${OPENAISECRETKEY}' "$T" && install -D -m 644 "$T" data/beelzebub/config/ssh-22.yaml && rm "$T" && tail -4 data/beelzebub/config/ssh-22.yaml
```

T-Pot host (as the admin user). Patch the compose file. Each check matches only uncommented lines, and a commented-out line gets uncommented:

```bash
cd ~/tpotce && cp -n docker-compose.yml docker-compose.yml.orig && { grep -qE '^\s+OPENAISECRETKEY: \$\{BEELZEBUB_OPENAISECRETKEY\}' docker-compose.yml || sed -i '/^\s*OLLAMA_MODEL: \${BEELZEBUB_OLLAMA_MODEL}/a\      OPENAISECRETKEY: ${BEELZEBUB_OPENAISECRETKEY}' docker-compose.yml; } && { grep -qE '^\s+- .*beelzebub/config/ssh-22.yaml' docker-compose.yml || sed -i '\#^\s*- \${TPOT_DATA_PATH}/beelzebub/log:/opt/beelzebub/configurations/log#a\     - ${TPOT_DATA_PATH}/beelzebub/config/ssh-22.yaml:/opt/beelzebub/configurations/services/ssh-22.yaml:ro' docker-compose.yml; } && sed -i -E 's/^(\s*)# ?(LLM_API_KEY: \$\{GALAH_LLM_API_KEY\})/\1\2/' docker-compose.yml && { grep -qE '^\s+LLM_API_KEY: \$\{GALAH_LLM_API_KEY\}' docker-compose.yml || sed -i '/^\s*LLM_MODEL: \${GALAH_LLM_MODEL}/a\      LLM_API_KEY: ${GALAH_LLM_API_KEY}' docker-compose.yml; } && diff docker-compose.yml.orig docker-compose.yml; docker compose config --quiet && echo compose-ok
```

T-Pot host (as the admin user). Check that every variable arrives, printing lengths only and never values:

```bash
cd ~/tpotce && docker compose config 2>/dev/null | awk '/^  (galah|beelzebub):/{s=$1} /^  [a-z_]+:$/&&!/^  (galah|beelzebub):/{s=""} s&&/(LLM_|OPENAI)/{v=$0; sub(/^[^:]*:[[:space:]]*/,"",v); gsub(/"/,"",v); split($0,a,":"); print s, a[1], "len=" length(v)}'
```

The `LLM_API_KEY` and `OPENAISECRETKEY` lengths must not be 0. A blank `LLM_HOST` or `LLM_SERVER_URL` is fine, because those are only used for Ollama.

T-Pot host (as the admin user). Recreate the two containers, which needs no `sudo`. Then test from the host, so the admin IP stays out of the logs and the community feed:

```bash
cd ~/tpotce && docker compose up -d --no-deps --force-recreate galah beelzebub && sleep 20 && curl -s -m 60 -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" http://127.0.0.1/wp-login.php && docker logs --since 1m galah 2>&1 | grep -E "source: (llm|cache)|error"
```

Galah should log `source: llm` for the first request (a few seconds) and serve the same path from cache afterwards.

For Beelzebub, log in from the host with any password and run a command. The reply comes from gpt-4o after a few seconds:

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22 root@127.0.0.1
```

`update.sh` may overwrite `docker-compose.yml`. Re-run the compose patch and the length check after every update.

## 6. Community data

Opted in (kaywoz, 2026-11-11): leave the `ewsposter` service as installed.

## 7. Export logs before a rebuild or teardown

A rebuild (`replace=hcloud_server.honeypot`) or deletion wipes the disk. Export the honeypot logs to the Mac first.

Mac (repo checkout), from the Host entry in §1 or as `<admin user>@<tpot_ipv4>`:

```bash
config-files/tpot/export.sh tpot
```

It pulls `~/tpotce/data/{beelzebub,galah}/log` (rotated `.gz` files included) as one archive and checks it isn't empty or corrupt. It unpacks it into its own directory, refusing absolute or `..` paths, and runs `summarize.py`.

Results go to `~/tpot-exports/<UTC timestamp>/` (mode `700`):
- `summary.md`: overview, event types, top sources, top 50 commands, credentials, LLM error reasons, HTTP paths and response sources, user agents, and defanged URLs
- `commands.csv`, `credentials.csv`, `http.csv`: the full lists

The export is attacker data (IPs, credentials, payloads), so it **never goes into git**. `summarize.py` only parses the logs as JSON and escapes everything it writes. Open the raw files with care: they can contain terminal escape sequences.

**If the box is overloaded and SSH stalls:** power-cycle it in the Hetzner console and win the race after boot. Retry SSH every 2 s, and as soon as it answers stop the containers (`cd ~/tpotce && docker compose stop -t 5`, no `sudo` needed). Then run the export.

```bash
until ssh -p 64295 -i ~/.ssh/tpot.pub -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=4 <admin user>@<tpot_ipv4> 'cd ~/tpotce && docker compose stop -t 5'; do sleep 2; done && config-files/tpot/export.sh <admin user>@<tpot_ipv4>
```

