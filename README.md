# Docker Apps Backup

Backup script for Docker app folders with integrity checks and remote rotation.

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
- **Rich Telegram Alerts:** Sends real-time notifications for backup milestones, final size/integrity summaries, and detailed error reports.

## Requirements

- `bash`
- `docker compose`
- `rclone`
- `zstd`
- Optional: Telegram bot token and chat ID for notifications

## Configuration

Use an environment file to set the required source path and rclone destination, plus any optional tuning or notification values.

Example file: [docker-backup-example.env](docker-backup-example.env)

Copy it to your real environment file and edit the values for your setup.

## Systemd Service

```ini
[Unit]
Description=Backup docker apps folder to Google Drive

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-apps-backup.sh
EnvironmentFile=/home/starry/ssd/bots/docker-backup.env
```

## Systemd Timer

```ini
[Unit]
Description=Run docker apps backup every 72h (3 days)

[Timer]
OnCalendar=*-*-1,4,7,10,13,16,19,22,25,28 02:00:00
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
