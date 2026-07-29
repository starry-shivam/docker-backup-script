#!/usr/bin/env bash
#
# Copyright (C) 2024 Stɑrry Shivɑm <touka.krs@gmail.com>
#
# Everyone is permitted to copy and distribute verbatim or modified
# copies of this license document, and changing it is allowed as long
# as the name is changed.
#
# DO WHAT THE FUCK YOU WANT TO PUBLIC LICENSE
# TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION
#
# 0. You just DO WHAT THE FUCK YOU WANT TO.

set -Eeuo pipefail

REMOTE="starrygd:backups"
DEST="$HOME/Documents/Important-Stuffs/server-bak"

# Function to send desktop notification
notify_desktop() {
    local message="$1"
    
    # Check if notify-send is available
    if ! command -v notify-send &> /dev/null; then
        echo "[$(date)] WARNING: notify-send command not found" >&2
        return 0
    fi
    
    # Check if DISPLAY is set
    if [[ -z "${DISPLAY:-}" ]]; then
        echo "[$(date)] WARNING: DISPLAY not set, skipping notification" >&2
        return 0
    fi
    
    # Try to send notification, log any errors
    if ! notify-send "Server Backup Sync" "$message" 2>&1; then
        echo "[$(date)] WARNING: Failed to send notification: $message" >&2
    fi
}

mkdir -p "$DEST"
cd "$DEST"

echo "[$(date)] Checking remote backups..."

latest=$(
    rclone lsf "$REMOTE" |
    grep '\.tar\.zst$' |
    sort |
    tail -n1
)

if [[ -z "$latest" ]]; then
    echo "No backup files found."
    exit 1
fi

latest_sha="${latest}.sha256"

echo "Latest remote backup: $latest"

# Skip if latest backup already exists locally and verifies
if [[ -f "$latest" && -f "$latest_sha" ]]; then
    echo "Latest backup already exists locally."

    if sha256sum -c "$latest_sha" >/dev/null 2>&1; then
        echo "Local copy already verified."
        notify_desktop "Download skipped - latest backup already exists and is verified"

        find . -maxdepth 1 -type f -name 'docker-apps-*.tar.zst' \
            ! -name "$latest" -delete

        find . -maxdepth 1 -type f -name 'docker-apps-*.tar.zst.sha256' \
            ! -name "$latest_sha" -delete

        exit 0
    fi

    echo "Existing local copy failed verification. Re-downloading."
fi

tmp_backup="${latest}.tmp"
tmp_sha="${latest_sha}.tmp"

rm -f "$tmp_backup" "$tmp_sha"

echo "Downloading backup..."
notify_desktop "Updating latest file from remote server..."
rclone copyto \
    "$REMOTE/$latest" \
    "$tmp_backup"

echo "Downloading checksum..."
rclone copyto \
    "$REMOTE/$latest_sha" \
    "$tmp_sha"

checksum_value=$(awk '{print $1}' "$tmp_sha")

echo "${checksum_value}  ${tmp_backup}" | sha256sum -c -

echo "Checksum verified."

mv -f "$tmp_backup" "$latest"
mv -f "$tmp_sha" "$latest_sha"

echo "Cleaning old backups..."

find . -maxdepth 1 -type f -name 'docker-apps-*.tar.zst' \
    ! -name "$latest" -delete

find . -maxdepth 1 -type f -name 'docker-apps-*.tar.zst.sha256' \
    ! -name "$latest_sha" -delete

echo "Backup sync complete."
notify_desktop "Updated local backup copy with latest archive"
