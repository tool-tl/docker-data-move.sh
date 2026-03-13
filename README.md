# docker-data-move.sh

An interactive helper for moving Docker's `data-root` to a larger disk safely.

It builds on the original `docker-data-move.sh` idea, but adds:

- automatic detection of the current Docker data directory
- automatic disk scanning and free-space comparison
- recommended target paths sorted by available space
- interactive selection or `--auto` mode
- safer pre-checks for free space, path nesting, and `daemon.json`
- backup of the old Docker data directory and Docker config

## Why this exists

A common production problem looks like this:

- `/home` or `/var` is full
- Docker overlay layers live under the full filesystem
- another mount such as `/data` still has hundreds of GB free

This script helps you move Docker data to the larger mount with less manual work.

## What it does

1. Detects Docker's current `data-root`
2. Calculates how much free space the migration target should have
3. Scans local filesystems and suggests the best candidate paths
4. Lets you choose a suggested path or enter a custom path
5. Stops Docker and `containerd`
6. Copies Docker data with `rsync`
7. Updates `/etc/docker/daemon.json`
8. Restarts Docker
9. Verifies the new `Docker Root Dir`

## Usage

Interactive mode:

```bash
sudo ./docker-data-move.sh
```

Specify a target path directly:

```bash
sudo ./docker-data-move.sh --path /data/docker-data
```

Auto-pick the best detected path:

```bash
sudo ./docker-data-move.sh --auto
```

Skip confirmation prompts:

```bash
sudo ./docker-data-move.sh --auto --yes
```

Allow using a non-empty target directory:

```bash
sudo ALLOW_NONEMPTY=1 ./docker-data-move.sh --path /data/docker-data
```

## Example

If your machine looks like:

```text
/home   100% used
/data   plenty of free space
```

the script will typically recommend a target like:

```text
/data/docker-data
```

## Requirements

- Linux
- Docker installed
- `rsync` available
- root privileges

Optional:

- `jq` for safer JSON updates to `/etc/docker/daemon.json`

## Notes

- The script avoids recommending the same filesystem that currently stores Docker data.
- It keeps a backup of the old Docker data directory as `...bak.TIMESTAMP`.
- If `daemon.json` already exists, it is backed up before modification.

## Suggested verification after migration

```bash
docker info | grep "Docker Root Dir"
docker ps
df -h
```

## Repository

- GitHub: [tool-tl/docker-data-move.sh](https://github.com/tool-tl/docker-data-move.sh)
