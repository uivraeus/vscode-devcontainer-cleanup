# Prune the Dev Containers VS Code server volume

`prune-vscode-volume.sh` removes old VS Code Server bundles from the shared
Docker volume named `vscode`. Dev Containers stores bundles under
`vscode-server/bin/<platform>/<commit>` in this volume, which can grow over
time.

The script runs on the host and uses a locally available `vsc-` image as a
temporary helper container. It uses `--pull=never` and does not need network
access. It exits with an error if a running container is using the volume, so
run it only when the relevant devcontainers are stopped. It keeps the newest
bundle by directory modification time for each platform; timestamp-suffixed
partial-install directories are always removed.

It also prunes the extension download cache (`vscode-server/extensionsCache`),
which accumulates one package per extension version and can be larger than the
server bundles. Entries are grouped generically by parsing
`<id>-<version>[-<target platform>]` (companion `.sigzip` files go with their
version), and the newest versions by version number are kept. Names that
cannot be parsed are skipped. Use `--no-extensions` to leave the cache alone.

## Usage

From this repository:

```sh
# Inspect what would be removed
./prune-vscode-volume.sh --dry-run

# Prune, keeping the latest bundle for each platform
./prune-vscode-volume.sh
```

Options:

| Option | Default | Description |
| --- | --- | --- |
| `-n`, `--dry-run` | off | Report planned deletions without changing the volume. |
| `-k`, `--keep N` | `1` | Number to retain: server bundles per platform, and cached versions per extension (minimum 1). |
| `-E`, `--no-extensions` | off | Do not prune the extension download cache. |
| `-p`, `--pattern STR` | `vsc-` | Substring used to choose a local helper image. |
| `-v`, `--volume NAME` | `vscode` | Docker volume to inspect and prune. |
| `-h`, `--help` | | Show help. |

The script prints volume and `bin/` sizes before and after pruning, plus each
bundle's or cached extension's size and disposition. Review the dry-run output before the first
prune. Other VS Code instances may need to download/install a server bundle
again if they later require a commit that was removed.

## Run automatically at host startup with systemd

This is a system service because it needs access to the Docker socket. The
unit runs the script directly from this repository (no installation), once
after Docker starts. Run the following from the repository root; `$PWD` is
expanded when the unit file is written, so the unit contains the absolute path
(systemd does not expand `~` or `$HOME`):

```sh
sudo tee /etc/systemd/system/prune-vscode-volume.service >/dev/null <<EOF
[Unit]
Description=Prune old VS Code Server bundles from the Dev Containers volume
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=$PWD/prune-vscode-volume.sh

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable prune-vscode-volume.service
```

Moving or deleting the repository breaks the service, and edits to the script
take effect on the next run. The script must stay executable.

To try it immediately, use `sudo systemctl start prune-vscode-volume.service`;
check output with `sudo journalctl -u prune-vscode-volume.service`.

The service depends on Docker being available, but `After=docker.service` does
not guarantee that the volume is unused. If any container has already started
with the volume mounted, the script deliberately fails without pruning; check
the journal and run it again after stopping that container. Under WSL, systemd
services run when the WSL distribution is running, not when it is shut down.

## Background

VS Code's `dev.containers.cacheVolume` setting controls whether Dev Containers
uses a Docker volume to cache the server; it does not expose a retention
setting. Reports of old bundles accumulating despite the built-in cleanup
include:

- [Old bin folders are not cleaned up, wasting free space (#7542)](https://github.com/microsoft/vscode-remote-release/issues/7542)
- [The `.vscode-server/bin` directory is always growing in time with no auto cleanup (#8846)](https://github.com/microsoft/vscode-remote-release/issues/8846)

The VS Code CLI's own server cache
([`download_cache.rs`](https://github.com/microsoft/vscode/blob/main/cli/src/download_cache.rs))
has a hard-coded limit of 5 entries (`KEEP_LRU`), tracked in an `lru.json`
file. It is internal code, not a command you can run, and it is not
configurable. It appears not to manage the Dev Containers volume, which would
explain the accumulation, but this has not been verified.
