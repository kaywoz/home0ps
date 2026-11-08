# MOS containers — deploy-time settings

Containers on the storage host are deployed from [MOS templates](https://github.com/kaywoz/mos-templates). The templates stay generic (upstream defaults); everything host-specific is added **when deploying** and recorded here. Secrets (keys, tokens) are entered in MOS only, never here. Security summary: [`security/storage.md`](../../security/storage.md).

Appdata on this host: `/var/mergerfs/merger-nvme/disk1/appdata/<app>/` (not the templates' `/mnt/cache/appdata` default).

## Docker Socket Proxy (`docker/docker-socket-proxy.json`)

Network **bridge** (never host: the proxy would listen on every interface). Variables as in the template (`CONTAINERS=1`, `INFO=1`, `EVENTS=1`, `POST=0`). No port entries; the binding is in the extra parameters:

```text
--restart=unless-stopped -p 127.0.0.1:2375:2375 --read-only --tmpfs /run --tmpfs /tmp --security-opt no-new-privileges:true --memory 64m --pids-limit 100
```

After deploying: `docker ps` must show `127.0.0.1:2375->2375/tcp`, then expose it on the tailnet — see [observed hosts](../../docker-compose/monitoring/observed-hosts.md).

## Beszel agent (`docker/beszel-agent.json`)

Network **host**. Remove the Docker socket path. Data folder owned by `65534:65534` before the first start.

```text
--restart=unless-stopped --user 65534:65534 --read-only --cap-drop ALL --security-opt no-new-privileges:true --memory 128m --pids-limit 50
```

| Variable | Value |
|---|---|
| `DOCKER_HOST` | `tcp://127.0.0.1:2375` |
| `LISTEN` | `<tailnet-ip>:45876` (`tailscale ip -4`) |
| `HUB_URL` | `https://beszel.<tailnet>.ts.net` |
| `KEY`, `TOKEN` | from the hub's "Add system" dialog (MOS only) |
| Agent Data path | `/var/mergerfs/merger-nvme/disk1/appdata/beszel/agent/` |
