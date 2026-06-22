# Local Backup Sync

This folder is for keeping a local copy of the latest remote server backup on another machine such as a laptop or desktop.

The goal is simple:

- keep one verified backup archive on your PC for redundancy
- make the latest backup available locally even when the remote is unavailable
- avoid filling the machine with older backup copies

This is useful if your main server uploads backups with `rclone` and you want your personal machine to always have the newest backup archive ready.

## What it does

The sync script:

1. checks the remote backup folder
2. finds the newest `docker-apps-*.tar.zst` archive
3. downloads that archive and its matching `.sha256` file
4. verifies the checksum before keeping the files
5. removes older local backup copies so only the newest verified backup remains

If the newest backup already exists locally and the checksum still matches, the script skips the download.

## Files

- `sync-server-backup.sh` downloads and verifies the latest backup from the remote
- `server-backup-sync.service` runs the script as a one-shot systemd service
- `server-backup-sync.timer` runs the service automatically on a schedule

## Requirements

- `rclone`
- `sha256sum`
- access to the configured `rclone` remote

## Current default paths

The script currently uses these values:

```bash
REMOTE="starrygd:backups"
DEST="$HOME/Documents/Important-Stuffs/server-bak"
```

Before using it on another machine, edit [sync-server-backup.sh](/home/starry/Documents/Coding/docker-backup-script/sync-local/sync-server-backup.sh) and set:

- `REMOTE` to your `rclone` remote backup location
- `DEST` to the local folder where you want the latest backup stored

## Manual usage

Run it directly:

```bash
./sync-server-backup.sh
```

After a successful run, the destination folder will contain:

- the latest `docker-apps-*.tar.zst` backup
- the matching `.sha256` file

## Systemd setup

The included systemd files are examples and should be adjusted for your machine.

### 1. Install the script

Copy the script somewhere stable, for example:

```bash
sudo cp sync-server-backup.sh /usr/local/bin/sync-server-backup.sh
sudo chmod +x /usr/local/bin/sync-server-backup.sh
```

### 2. Review the service file

The current service uses:

```ini
[Service]
Type=oneshot
User=starry
Group=starry
ExecStart=/usr/local/bin/sync-server-backup.sh
```

Change `User` and `Group` to the account that should own the local backup files.

### 3. Install the service and timer

```bash
sudo cp server-backup-sync.service /etc/systemd/system/
sudo cp server-backup-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now server-backup-sync.timer
```

### 4. Check status

```bash
systemctl status server-backup-sync.timer
systemctl status server-backup-sync.service
```

## Timer behavior

The included timer runs:

- 15 minutes after boot
- every 24 hours after the last successful run
- with `Persistent=true`, so missed runs are triggered after the machine comes back online

That makes it suitable for laptops and desktops that are not always powered on.

## Typical use case

1. your server creates and uploads backups to an `rclone` remote
2. your laptop or desktop runs this sync job daily
3. your PC always keeps the newest verified backup archive locally

This gives you both remote backup storage and a fresh local copy for quick access or recovery.
