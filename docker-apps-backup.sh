#!/bin/bash
#
# Copyright (C) 2024-Present Stɑrry Shivɑm <touka.krs@gmail.com>
# All Rights Reserved.
#
# Unauthorized copying of this file, via any medium is strictly prohibited.
# Proprietary and confidential.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# ======================= CONFIG START ======================= #
readonly SOURCE="${SOURCE:?SOURCE must be set}"
# Local staging directory for backup creation and verification
# NOTE: Do NOT use /tmp if it is tmpfs (RAM-backed) and backups may be large.
readonly LOCAL_DEST="${LOCAL_DEST:-/tmp/.backup-staging}"

# rclone remote destination
readonly RCLONE_DEST="${RCLONE_DEST:?RCLONE_DEST must be set}"
# Optional explicit rclone config path (useful for systemd services)
readonly RCLONE_CONFIG="${RCLONE_CONFIG:-}"
# rclone upload tuning
readonly RCLONE_STATS_INTERVAL="${RCLONE_STATS_INTERVAL:-10s}"
readonly RCLONE_DRIVE_CHUNK_SIZE="${RCLONE_DRIVE_CHUNK_SIZE:-64M}"
readonly RCLONE_BUFFER_SIZE="${RCLONE_BUFFER_SIZE:-32M}"

# Telegram bot credentials for notifications
readonly BOT_TOKEN="${BOT_TOKEN:-}"
readonly CHAT_ID="${CHAT_ID:-}"
# Optional HTTPS proxy for Telegram API requests (e.g. https://user:pass@proxy.example.com:8443)
readonly TELEGRAM_PROXY="${TELEGRAM_PROXY:-}"

# Timestamp for backup filenames (ISO 8601, filesystem-safe)
readonly TIMESTAMP=$(date +"%Y-%m-%dT%H%M%S")

# Number of backups to keep on remote
readonly MAX_KEEP="${MAX_KEEP:-4}"

# zstd compression level
# Valid values:
#   1-19  = normal compression levels
#   20-22 = ultra compression levels (slower, more RAM usage)
#
# Recommended:
#   3  = fastest (roughly default zstd behavior)
#   9  = good balance
#   19 = maximum practical compression
#   22 = absolute maximum compression
readonly ZSTD_LEVEL="${ZSTD_LEVEL:-9}"

# Graceful stop timeout in seconds for stateful stacks
readonly STOP_TIMEOUT="${STOP_TIMEOUT:-60}"

# List of project directory names that should NEVER be auto-started
# Example env value: NO_AUTOSTART_PROJECTS=oldapp,test-stack
readonly NO_AUTOSTART_PROJECTS_RAW="${NO_AUTOSTART_PROJECTS:-}"
NO_AUTOSTART_PROJECTS=()
if [[ -n "$NO_AUTOSTART_PROJECTS_RAW" ]]; then
    IFS=',' read -r -a NO_AUTOSTART_PROJECTS <<< "$NO_AUTOSTART_PROJECTS_RAW"
fi
readonly NO_AUTOSTART_PROJECTS

# Directory names that indicate a project contains mutable/persistent state.
# Projects containing any of these subdirectories will be stopped before backup.
readonly STATE_DIRS=(
    "data"
    "config"
    "db"
    "database"
    "postgres"
    "mysql"
    "redis"
)
# ======================== CONFIG END ======================== #



set -uo pipefail

readonly LOCK_FILE="/tmp/docker-apps-backup.lock"

# Initialised to safe defaults so the EXIT trap and fail() are always valid,
# even if the script exits before init() has a chance to run.
BACKUP_FILE=""
CHECKSUM_FILE=""
PROJECTS_TO_RESTART=()
SIZE=""

# ── Helper functions ──────────────────────────────────────────────────────── #

# Helper: check if a project (directory name) is in NO_AUTOSTART_PROJECTS
is_no_autostart_project() {
    local project="$1"
    for p in "${NO_AUTOSTART_PROJECTS[@]}"; do
        [[ "$p" == "$project" ]] && return 0
    done
    return 1
}

# Detect whether a project likely contains mutable/persistent state
project_needs_shutdown() {
    local project_dir="$1"

    for d in "${STATE_DIRS[@]}"; do
        if [[ -d "$project_dir/$d" ]]; then
            return 0
        fi
    done

    # Detect common database/WAL/state files
    if find "$project_dir" -maxdepth 3 -type f \( \
        -iname "*.db" -o \
        -iname "*.sqlite" -o \
        -iname "*.sqlite3" -o \
        -iname "*.db-wal" -o \
        -iname "*.db-shm" -o \
        -iname "*.wal" -o \
        -iname "*.mdb" \
    \) -print -quit | grep -q .; then
        return 0
    fi

    # No persistent state indicators found
    return 1
}

# Best-effort restart of previously running projects (used on failure too)
restart_containers_safely() {
    for compose_file in "${PROJECTS_TO_RESTART[@]}"; do
        # Ignore errors here – this is best-effort
        $COMPOSE_CMD -f "$compose_file" up -d >/dev/null 2>&1 || true
    done
}

# Telegram helper (no-op when credentials are not set)
send_telegram() {
    local msg="$1"

    [[ -z "${BOT_TOKEN:-}" || -z "${CHAT_ID:-}" ]] && return 0

    # Support optional proxy for Telegram API requests
    local proxy_args=()
    [[ -n "${TELEGRAM_PROXY:-}" ]] && proxy_args=(--proxy "$TELEGRAM_PROXY")

    curl -s \
        --connect-timeout 10 \
        --max-time 10 \
        --retry 3 \
        --retry-all-errors \
        "${proxy_args[@]}" \
        -X POST \
        "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$CHAT_ID" \
        --data-urlencode text="$msg" \
        >/dev/null 2>&1 || true
}

# Timestamped log helper for journal visibility.
log() {
    echo "[$(date '+%F %T')] $*"
}

# Remove temporary files for the current run on normal exit or failure.
cleanup_local_staging() {
    rm -f -- "$BACKUP_FILE" "$CHECKSUM_FILE" 2>/dev/null || true
}

# Failure handling
fail() {
    trap - INT TERM

    # Try to bring back anything we stopped
    restart_containers_safely

    local MESSAGE="❌ Docker Apps Backup FAILED
📅 $(date +"%Y-%m-%d %H:%M:%S")
Error: $1"

    send_telegram "$MESSAGE"

    exit 1
}

handle_interrupt() {
    # Clear signal traps inside fail() so interruption handling does not re-enter.
    fail "Interrupted"
}

# Run rclone, optionally with an explicit config file.
rclone_cmd() {
    if [[ -n "$RCLONE_CONFIG" ]]; then
        rclone --config "$RCLONE_CONFIG" "$@"
    else
        rclone "$@"
    fi
}

# rclone upload command with progress/statistics and Google Drive tuning.
rclone_upload_cmd() {
    if [[ -n "$RCLONE_CONFIG" ]]; then
        rclone --config "$RCLONE_CONFIG" \
            --stats "$RCLONE_STATS_INTERVAL" \
            --stats-one-line \
            --progress \
            --buffer-size "$RCLONE_BUFFER_SIZE" \
            --drive-chunk-size "$RCLONE_DRIVE_CHUNK_SIZE" \
            "$@"
    else
        rclone \
            --stats "$RCLONE_STATS_INTERVAL" \
            --stats-one-line \
            --progress \
            --buffer-size "$RCLONE_BUFFER_SIZE" \
            --drive-chunk-size "$RCLONE_DRIVE_CHUNK_SIZE" \
            "$@"
    fi
}

# Validate rclone destination access before doing disruptive work.
check_rclone_destination() {
    command -v rclone >/dev/null 2>&1 \
        || fail "rclone command not found"

    log "Checking rclone destination access"
    rclone_cmd lsf "$RCLONE_DEST" --max-depth 1 >/dev/null 2>&1 \
        || fail "Cannot access rclone destination '$RCLONE_DEST'. Set RCLONE_CONFIG if running under systemd."
}

# Verify that the uploaded backup and checksum match the local copies.
# This uses backend hashes when available; otherwise rclone falls back to
# the comparison methods supported by the remote.
verify_remote_upload() {
    log "Verifying remote upload integrity"
    rclone_cmd check "$LOCAL_DEST" "$RCLONE_DEST" \
        --include "$BACKUP_NAME" \
        --include "$CHECKSUM_NAME" \
        --one-way \
        || fail "Remote integrity verification failed after upload"
    log "Remote integrity verification passed"
}

# Rotate remote backups, keeping at most <keep> copies.
# Fetches the remote listing once and trims the oldest archives and checksums
# in a single pass, so pre- and post-upload retention share the same logic.
#
# Usage: rotate_remote_backups <keep>
#
# Called with (MAX_KEEP-1) before the new archive is uploaded so the total
# never exceeds MAX_KEEP; called again with MAX_KEEP after upload to handle
# any edge cases from parallel runs.
rotate_remote_backups() {
    local keep="$1"

    log "Rotating remote backups to keep at most $keep archives"
    # --format tp → "<mtime>;<filename>"; sort ascending = oldest first
    mapfile -t all_files < <(
        rclone_cmd lsf "$RCLONE_DEST" --files-only --format tp 2>/dev/null | sort || true
    )

    # Trim archives
    mapfile -t lines < <(
        printf '%s\n' "${all_files[@]}" | grep ';docker-apps-.*\.tar\.zst$' || true
    )
    local count=${#lines[@]}
    log "Found $count remote archives"
    if (( count > keep )); then
        local n=$(( count - keep ))
        for line in "${lines[@]:0:$n}"; do
            local f="${line#*;}"
            log "Deleting remote archive: $f"
            rclone_cmd deletefile "$RCLONE_DEST/$f" >/dev/null 2>&1 || true
        done
    fi

    # Trim checksum files
    mapfile -t lines < <(
        printf '%s\n' "${all_files[@]}" | grep ';docker-apps-.*\.tar\.zst\.sha256$' || true
    )
    count=${#lines[@]}
    log "Found $count remote checksum files"
    if (( count > keep )); then
        local n=$(( count - keep ))
        for line in "${lines[@]:0:$n}"; do
            local f="${line#*;}"
            log "Deleting remote checksum: $f"
            rclone_cmd deletefile "$RCLONE_DEST/$f" >/dev/null 2>&1 || true
        done
    fi
}

# --- Stop only stateful running compose stacks ---
stop_running_stacks() {
    # Find docker-compose.yml files under SOURCE (one level deep)
    log "Scanning for compose files under $SOURCE"
    mapfile -t compose_files < <(
        find "$SOURCE" -maxdepth 2 -type f \( \
            -name 'docker-compose.yml' -o \
            -name 'docker-compose.yaml' -o \
            -name 'compose.yml' -o \
            -name 'compose.yaml' \
        \) | sort
    )
    log "Found ${#compose_files[@]} compose files"

    for compose_file in "${compose_files[@]}"; do
        project_dir="$(dirname "$compose_file")"
        project_name="$(basename "$project_dir")"

        log "Inspecting project: $project_name"

        # Skip projects explicitly marked as "do not auto-start/manage"
        if is_no_autostart_project "$project_name"; then
            log "Skipping project marked no-autostart: $project_name"
            continue
        fi

        # Skip stateless/static projects
        if ! project_needs_shutdown "$project_dir"; then
            log "Skipping shutdown for stateless project: $project_name"
            continue
        fi

        # Check if anything is running in this project
        running_services="$($COMPOSE_CMD -f "$compose_file" ps --status running --services 2>/dev/null || true)"

        if [[ -n "$running_services" ]]; then
            log "Stopping stateful project: $project_name"

            # Stop containers for a clean, consistent backup
            log "Stopping compose stack with timeout ${STOP_TIMEOUT}s: $compose_file"
            $COMPOSE_CMD -f "$compose_file" stop -t "$STOP_TIMEOUT" \
                || fail "Failed to stop containers for project '$project_name'"

            # Remember to start this project again later
            PROJECTS_TO_RESTART+=("$compose_file")
            log "Queued for restart: $project_name"
        else
            log "No running services detected for: $project_name"
        fi
    done
}

# --- Restart previously running stacks ---
restart_stacks() {
    log "Restarting ${#PROJECTS_TO_RESTART[@]} previously running stacks"
    for compose_file in "${PROJECTS_TO_RESTART[@]}"; do
        project_dir="$(dirname "$compose_file")"
        project_name="$(basename "$project_dir")"

        # If user added it to NO_AUTOSTART_PROJECTS after the script ran, respect that
        if is_no_autostart_project "$project_name"; then
            log "Skipping restart due to no-autostart rule: $project_name"
            continue
        fi

        log "Starting compose stack: $project_name"
        $COMPOSE_CMD -f "$compose_file" up -d \
            || fail "Backup succeeded, but failed to restart project '$project_name'"
    done
}

# ── Phase functions ───────────────────────────────────────────────────────── #

acquire_lock() {
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        echo "Another backup instance is already running." >&2
        exit 1
    fi
}

init() {
    # Detect docker compose command
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        echo "ERROR: Could not detect a compose command. Install 'docker compose' or 'docker-compose'." >&2
        exit 1
    fi

    # Build zstd command
    if (( ZSTD_LEVEL <= 19 )); then
        ZSTD_CMD="zstd -${ZSTD_LEVEL} -T0"
    else
        ZSTD_CMD="zstd --ultra -${ZSTD_LEVEL} -T0"
    fi

    # Output filenames
    BACKUP_FILE="$LOCAL_DEST/docker-apps-$TIMESTAMP.tar.zst"
    CHECKSUM_FILE="$BACKUP_FILE.sha256"
    BACKUP_NAME="$(basename "$BACKUP_FILE")"
    CHECKSUM_NAME="$(basename "$CHECKSUM_FILE")"

    log "Creating local staging directory: $LOCAL_DEST"
    mkdir -p "$LOCAL_DEST" \
        || fail "Failed to create local staging directory '$LOCAL_DEST'"

    trap 'handle_interrupt' INT TERM
    trap 'cleanup_local_staging' EXIT
}

preflight_checks() {
    # Validate retention count
    if ! [[ "$MAX_KEEP" =~ ^[0-9]+$ ]]; then
        echo "ERROR: MAX_KEEP must be a positive integer." >&2
        exit 1
    fi

    if (( MAX_KEEP < 1 )); then
        echo "ERROR: MAX_KEEP must be at least 1." >&2
        exit 1
    fi

    # Validate zstd compression level
    if ! [[ "$ZSTD_LEVEL" =~ ^[0-9]+$ ]]; then
        echo "ERROR: ZSTD_LEVEL must be an integer between 1 and 22." >&2
        exit 1
    fi

    if (( ZSTD_LEVEL < 1 || ZSTD_LEVEL > 22 )); then
        echo "ERROR: ZSTD_LEVEL must be between 1 and 22." >&2
        exit 1
    fi

    # Validate graceful stop timeout
    if ! [[ "$STOP_TIMEOUT" =~ ^[0-9]+$ ]]; then
        echo "ERROR: STOP_TIMEOUT must be a non-negative integer (seconds)." >&2
        exit 1
    fi

    check_rclone_destination
}

send_start_notification() {
    local msg="🐋 Docker Apps Backup Started
📅 $(date +"%Y-%m-%d %H:%M:%S")"
    send_telegram "$msg"
    log "Sent Telegram start notification"
}

perform_backup() {
    # Pre-rotate so the total never exceeds MAX_KEEP once the new archive lands
    rotate_remote_backups $(( MAX_KEEP - 1 ))

    log "Stopping stateful Docker apps"
    stop_running_stacks

    if (( ${#PROJECTS_TO_RESTART[@]} > 0 )); then
        send_telegram "🛑 Containers stopped for backup
📅 $(date +"%Y-%m-%d %H:%M:%S")"
        log "Sent Telegram containers-stopped notification"
    fi

    # --- Create archive using zstd compression ---
    log "Creating archive: $BACKUP_FILE"
    tar -I "$ZSTD_CMD" -cf "$BACKUP_FILE" \
        -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")" \
        || fail "tar/zstd compression error"
    log "Archive created successfully"

    log "Generating checksum: $CHECKSUM_FILE"
    (cd "$LOCAL_DEST" && sha256sum "$BACKUP_NAME" > "$CHECKSUM_NAME") \
        || fail "Failed to generate SHA256 checksum"

    log "Verifying checksum"
    (cd "$LOCAL_DEST" && sha256sum --check "$CHECKSUM_NAME") \
        || fail "Integrity check failed! Backup corrupted."
    log "Checksum verification passed"

    log "Restarting stopped Docker apps"
    restart_stacks

    if (( ${#PROJECTS_TO_RESTART[@]} > 0 )); then
        send_telegram "✅ Containers back up after backup
📅 $(date +"%Y-%m-%d %H:%M:%S")"
        log "Sent Telegram containers-restarted notification"
    fi

    # Clear restart list since stacks are already running.
    # Prevent fail() from attempting duplicate restarts during upload/cleanup failures.
    PROJECTS_TO_RESTART=()
    log "Cleared restart queue after successful local restart"
}

perform_upload() {
    SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    log "Local backup size: $SIZE"

    local upload_start upload_end
    upload_start=$(date +%s)

    log "Uploading archive to rclone remote: $RCLONE_DEST/$BACKUP_NAME"
    rclone_upload_cmd copyto "$BACKUP_FILE" \
        "$RCLONE_DEST/$BACKUP_NAME" \
        || fail "Failed to upload backup archive to remote"

    log "Uploading checksum to rclone remote: $RCLONE_DEST/$CHECKSUM_NAME"
    rclone_upload_cmd copyto "$CHECKSUM_FILE" \
        "$RCLONE_DEST/$CHECKSUM_NAME" \
        || fail "Failed to upload checksum file to remote"

    upload_end=$(date +%s)
    log "Upload completed in $(( upload_end - upload_start ))s"

    verify_remote_upload

    # Final rotation to ensure EXACTLY MAX_KEEP remain (handles parallel runs)
    log "Running remote retention cleanup"
    rotate_remote_backups "$MAX_KEEP"
}

perform_cleanup() {
    log "Cleaning up local staging files"
    cleanup_local_staging
    if [[ -e "$BACKUP_FILE" || -e "$CHECKSUM_FILE" ]]; then
        fail "Uploaded successfully, but failed to clean up local staging files"
    fi
    trap - EXIT
    log "Local cleanup complete"
}

send_success_notification() {
    trap - INT TERM

    local msg="✅ Docker Apps Backup Completed (zstd)
📅 $(date +"%Y-%m-%d %H:%M:%S")
📦 Size: $SIZE
🔒 Integrity: Verified OK
☁️ Upload: rclone copy + check OK
🗂 Retention: Keeping last $MAX_KEEP backups on remote"

    send_telegram "$msg"
    log "Sent Telegram success notification"
}

# ── Entry point ───────────────────────────────────────────────────────────── #

main() {
    acquire_lock

    init

    preflight_checks

    send_start_notification

    perform_backup

    perform_upload

    perform_cleanup

    send_success_notification
}

main "$@"
