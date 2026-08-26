# Docker Apps Backup

Backup and restore scripts for Docker app folders with integrity checks, remote rotation, and restore validation.

**[ Intended for my personal use only. No issues or PRs are accepted. ]**

## Directory structure example:

```text
/home/starry/docker-apps/
├─ audiobookshelf/
│ ├─ docker-compose.yml
│ └─ data/
├─ navidrome/
│ ├─ docker-compose.yml
│ └─ data/
```

## Features

- **Smart Container Management:** Automatically detects stateful Docker stacks and safely stops only them, leaving your stateless apps running without interruption.
- **Auto-Recovery:** Remembers which containers were active and automatically restarts them, even if the backup fails or is manually aborted.
- **Custom Exclusions:** Allows you to explicitly blacklist specific projects from being auto-started or managed by the script.
- **High-Speed Compression:** Uses multithreaded Zstandard (`zstd`) for blazing-fast, highly compressed archives that utilize all available CPU cores.
- **Bulletproof Integrity:** Generates portable SHA256 checksums and uses `rclone check` to guarantee your cloud backup exactly matches the local data.
- **Cloud-Optimized Uploads:** Leverages `rclone` with tunable buffer and chunk sizes for fast, reliable transfers to any supported remote storage.
- **Automated Remote Retention:** Automatically prunes the oldest archives and checksums from the cloud to strictly enforce your maximum backup limit.
- **Concurrency Guards:** Uses strict error handling (`set -uo pipefail`) and atomic lockfiles to prevent overlapping backups or silent failures.
- **Rich Notifications:** Sends real-time alerts for backup milestones, final size/integrity summaries, and detailed error reports via Telegram or ntfy.sh (select with `NOTIFY_HANDLER`).

## Restore Features

- **Two Restore Modes:** Restore the latest archive from an `rclone` remote or restore directly from a local `.tar.zst` archive.
- **Optional Local Checksum:** Local restores can verify a provided `.sha256` file and will auto-discover `<archive>.sha256` when it exists next to the archive.
- **Remote Checksum Enforcement:** Remote restores require the matching checksum file to exist before the restore proceeds.
- **Archive Inspection:** Shows archive size, entry count, and archive root information to help confirm you are restoring the expected backup.
- **Safe Destination Checks:** Refuses dangerous restore paths, creates the destination when missing, and warns before writing into a non-empty directory.
- **Flexible Extraction Layout:** Preserves the archive root by default and supports `--flatten` when you want the archive contents extracted directly into the target path.
- **Integrity Verification:** Verifies checksum data when available and always tests the archive structure before extraction.
- **Compose Validation:** After restore, scans restored app folders for compose files and runs `docker compose config` or `docker-compose config` when available, without pulling or starting containers.
- **Restore Summary:** Prints detected compose projects after extraction so you can quickly confirm which app stacks were restored.

## Requirements

### Backup

- `docker compose`
- `rclone`
- `zstd`
- Optional: `NOTIFY_HANDLER=telegram` with bot token and chat ID, or `NOTIFY_HANDLER=ntfy` with an ntfy topic, for notifications

### Restore

- `zstd`
- `rclone` for remote restore mode only
- Optional: `docker compose` or `docker-compose` for post-restore compose validation

## Backup Setup

### Configuration

Use an environment file to set the required source path and rclone destination, plus any optional tuning or notification values.

Example file: [conf-example.env](conf-example.env)

Copy it to your real environment file and edit the values for your setup.

### Manual backup run

```bash
./docker-apps-backup.sh
```

### Systemd Service

```ini
[Unit]
Description=Backup docker apps folder to Google Drive

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-apps-backup.sh
EnvironmentFile=/home/starry/ssd/bots/docker-backup.env
```

### Systemd Timer

```ini
[Unit]
Description=Run docker apps backup every odd day (~48h)

[Timer]
OnCalendar=*-*-1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31 02:00:00
Persistent=true
Unit=docker-apps-backup.service

[Install]
WantedBy=timers.target
```

Enable it with:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now docker-apps-backup.timer
```

Check status with:

```bash
systemctl status docker-apps-backup.timer
systemctl status docker-apps-backup.service
```

## Restore Usage

### Remote restore

Restores the latest `docker-apps-*.tar.zst` archive from an `rclone` remote.

```bash
./docker-apps-restore.sh \
	--remote gdrive:docker-backups \
	--restore-path /home/starry/ssd
```

Optional:

```bash
./docker-apps-restore.sh \
	--remote gdrive:docker-backups \
	--restore-path /home/starry/ssd \
	--rclone-config /path/to/rclone.conf
```

### Local restore

Restores directly from a local archive file.

```bash
./docker-apps-restore.sh \
	--archive /path/to/docker-apps-2024-01-01T120000.tar.zst \
	--restore-path /home/starry/ssd
```

Optional checksum:

```bash
./docker-apps-restore.sh \
	--archive /path/to/docker-apps-2024-01-01T120000.tar.zst \
	--checksum /path/to/docker-apps-2024-01-01T120000.tar.zst.sha256 \
	--restore-path /home/starry/ssd
```

### Flatten restore

By default, extraction preserves the top-level archive directory, so restoring to `/home/starry/ssd` produces `/home/starry/ssd/docker-apps/...`.

Use `--flatten` to extract the archive contents directly into the target path:

```bash
./docker-apps-restore.sh \
	--archive /path/to/docker-apps-2024-01-01T120000.tar.zst \
	--restore-path /home/starry/ssd/docker-apps \
	--flatten
```

## License

```text
DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
Version 2, December 2004

Copyright (C) 2024 Stɑrry Shivɑm <touka.krs@gmail.com>

Everyone is permitted to copy and distribute verbatim or modified
copies of this license document, and changing it is allowed as long
as the name is changed.

DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION

0. You just DO WHAT THE FUCK YOU WANT TO.
```
