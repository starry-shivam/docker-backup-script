#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE="starrygd:backups"
DEST="$HOME/Documents/Important-Stuffs/server-bak"

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
