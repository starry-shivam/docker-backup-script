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

- Backs up Docker app folders to Google Drive with `rclone`.
- Uses a local staging directory for backup creation and verification.
- Compresses archives with `zstd`.
- Checks that the rclone destination is reachable before backup starts.
- Stops stateful stacks before backup and starts them again after.
- Verifies the uploaded backup and checksum on the remote.
- Rotates old remote backups and keeps only the latest copies.
- Uses a lock file to prevent concurrent runs.
- Cleans up staging files after a successful run.
- Restores containers and sends a failure alert if something goes wrong.
- Sends Telegram alerts when credentials are configured.

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
