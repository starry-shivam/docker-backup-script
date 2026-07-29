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

# ============================================================
# Docker Apps Restore Script
# Restores a docker-apps backup from an rclone remote or a
# local archive file.
# ============================================================

readonly SCRIPT_NAME="$(basename "$0")"

MODE="remote"   # remote | local

# Remote mode
RCLONE_REMOTE=""
RCLONE_CONFIG=""

# Local mode
LOCAL_ARCHIVE_PATH=""
LOCAL_CHECKSUM_PATH=""

RESTORE_PATH=""
FLATTEN_RESTORE="false"
LOCAL_STAGING="/tmp/.docker-apps-restore"

# Set by find_latest_backup (remote) or derived from --archive (local)
ARCHIVE=""
CHECKSUM=""
ARCHIVE_SIZE=""
ARCHIVE_ROOT=""
FILE_COUNT=""
# Directory where the archive file lives (LOCAL_STAGING in remote, dirname of --archive in local)
ARCHIVE_DIR=""
COMPOSE_CMD=""
DETECTED_PROJECTS=()

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

log() {
    echo "[$(date '+%F %T')] $*"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    cleanup_staging
}

cleanup_staging() {
    # Only remove staging files in remote mode — in local mode the files
    # belong to the user and must not be deleted.
    [[ "$MODE" == "remote" && -n "$ARCHIVE_DIR" ]] || return 0

    rm -f "$ARCHIVE_DIR/$ARCHIVE" \
          "$ARCHIVE_DIR/$CHECKSUM" \
          2>/dev/null || true

    rmdir "$ARCHIVE_DIR" 2>/dev/null || true
}

trap cleanup EXIT

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

usage() {
cat <<EOF
Usage (remote mode — fetch latest backup from rclone remote):

  $SCRIPT_NAME \\
    --remote gdrive:docker-backups \\
        --restore-path /home/starry/ssd

  Optional:
    --rclone-config /path/to/rclone.conf
        --flatten

Usage (local mode — restore from a local archive file):

  $SCRIPT_NAME \\
    --archive /path/to/docker-apps-2024-01-01T120000.tar.zst \\
        --restore-path /home/starry/ssd

  Optional:
    --checksum /path/to/docker-apps-2024-01-01T120000.tar.zst.sha256
        --flatten

Default behavior preserves the archive root directory, so restoring to
    /home/starry/ssd
produces:
    /home/starry/ssd/docker-apps/...

Use --flatten to restore the archive contents directly into --restore-path.

EOF
}

rclone_cmd() {
    if [[ -n "$RCLONE_CONFIG" ]]; then
        rclone --config "$RCLONE_CONFIG" "$@"
    else
        rclone "$@"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 \
        || die "'$1' is required but not installed"
}

detect_compose_command() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        die "Could not detect a compose command. Install 'docker compose' or 'docker-compose'."
    fi
}

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

validate_local_archive() {
    local path="$1"

    [[ "$path" == /* ]] \
        || die "--archive path must be absolute"

    [[ -f "$path" ]] \
        || die "Archive file not found: $path"

    [[ "$path" == *.tar.zst ]] \
        || die "Archive must be a .tar.zst file"
}

validate_local_checksum() {
    local path="$1"

    [[ "$path" == /* ]] \
        || die "--checksum path must be absolute"

    [[ -f "$path" ]] \
        || die "Checksum file not found: $path"
}

validate_restore_path() {
    local path="$1"

    [[ "$path" == /* ]] \
        || die "Restore path must be absolute"

    case "$path" in
        "/"|"/home"|"/root"|"/etc"|"/usr"|"/var"|"/tmp")
            die "Refusing dangerous restore path: $path"
            ;;
    esac

    return 0
}

validate_remote() {
    log "Checking remote access..."

    rclone_cmd lsf "$RCLONE_REMOTE" --max-depth 1 >/dev/null \
        || die "Cannot access remote: $RCLONE_REMOTE"

    log "Remote accessible"
}

# ------------------------------------------------------------
# Find latest backup
# ------------------------------------------------------------

find_latest_backup() {

    log "Searching latest backup archive..."

    local remote_listing
    remote_listing="$(rclone_cmd lsf "$RCLONE_REMOTE" --files-only)"

    ARCHIVE="$(
        echo "$remote_listing" \
            | grep '^docker-apps-.*\.tar\.zst$' \
            | sort \
            | tail -n1
    )"

    [[ -n "$ARCHIVE" ]] \
        || die "No backup archives found"

    CHECKSUM="${ARCHIVE}.sha256"

    # Verify the checksum file exists on the remote before proceeding
    echo "$remote_listing" | grep -Fxq "$CHECKSUM" \
        || die "Checksum file missing on remote: $CHECKSUM"

    # Fetch archive size for confirmation screen
    ARCHIVE_SIZE="$(
        rclone_cmd ls "$RCLONE_REMOTE/$ARCHIVE" \
            | awk '{print $1}'
    )"

    log "Latest archive:"
    log "  $ARCHIVE  ($ARCHIVE_SIZE bytes)"
}

# ------------------------------------------------------------
# Confirmation screen
# ------------------------------------------------------------

confirm_restore() {

    if [[ "$MODE" == "remote" ]]; then
cat <<EOF

==================================================
RESTORE CONFIRMATION
==================================================

Mode:          remote
Remote:        $RCLONE_REMOTE
Rclone Config: ${RCLONE_CONFIG:-<default>}

Archive:       $ARCHIVE
Size:          $ARCHIVE_SIZE bytes
Entries:       ${FILE_COUNT:-<determined after download>}
Archive Root:  ${ARCHIVE_ROOT:-<determined after download>}
Checksum:      $CHECKSUM

Restore Path:  $RESTORE_PATH
Flatten:       $FLATTEN_RESTORE

==================================================

EOF
    else
cat <<EOF

==================================================
RESTORE CONFIRMATION
==================================================

Mode:          local
Archive:       $LOCAL_ARCHIVE_PATH
Entries:       $FILE_COUNT
Archive Root:  $ARCHIVE_ROOT
Checksum:      ${LOCAL_CHECKSUM_PATH:-<not provided — skipping verification>}

Restore Path:  $RESTORE_PATH
Flatten:       $FLATTEN_RESTORE

==================================================

EOF
    fi

    read -rp "Proceed with restore? (yes/no): " answer

    [[ "$answer" == "yes" ]] \
        || die "Restore cancelled"
}

# ------------------------------------------------------------
# Download files
# ------------------------------------------------------------

download_backup() {

    mkdir -p "$LOCAL_STAGING"

    log "Downloading archive..."

    rclone_cmd copyto \
        "$RCLONE_REMOTE/$ARCHIVE" \
        "$LOCAL_STAGING/$ARCHIVE"

    log "Downloading checksum..."

    rclone_cmd copyto \
        "$RCLONE_REMOTE/$CHECKSUM" \
        "$LOCAL_STAGING/$CHECKSUM"
}

# ------------------------------------------------------------
# Verify integrity
# ------------------------------------------------------------

verify_checksum() {

    # In local mode without a checksum file, skip verification
    if [[ "$MODE" == "local" && -z "$LOCAL_CHECKSUM_PATH" ]]; then
        log "No checksum file provided — skipping verification"
        return 0
    fi

    log "Verifying checksum..."

    (
        cd "$ARCHIVE_DIR"
        sha256sum --check "$CHECKSUM"
    ) || die "Checksum verification FAILED"

    log "Checksum verified successfully"
}

# ------------------------------------------------------------
# Verify archive integrity (catches corrupt tar/zstd even without checksum)
# ------------------------------------------------------------

verify_archive_integrity() {

    log "Testing archive integrity..."

    tar --zstd -tf "$ARCHIVE_DIR/$ARCHIVE" >/dev/null \
        || die "Archive integrity test failed — archive may be corrupted or incomplete"

    log "Archive integrity test passed"
}

inspect_archive_root() {

    local first_entry

    ARCHIVE_ROOT=""
    FILE_COUNT=0

    while IFS= read -r entry; do
        if [[ -z "$first_entry" ]]; then
            first_entry="$entry"
            ARCHIVE_ROOT="${entry%%/*}"
        fi
        ((FILE_COUNT += 1))
    done < <(tar --zstd -tf "$ARCHIVE_DIR/$ARCHIVE")

    [[ -n "$ARCHIVE_ROOT" ]] \
        || die "Could not determine archive root"

    (( FILE_COUNT > 0 )) \
        || die "Could not determine archive entry count"
}

# ------------------------------------------------------------
# Prepare destination
# ------------------------------------------------------------

prepare_destination() {

    if [[ ! -d "$RESTORE_PATH" ]]; then
        log "Creating restore directory:"
        log "  $RESTORE_PATH"

        mkdir -p "$RESTORE_PATH" \
            || die "Failed to create restore directory"
    fi

    if [[ -n "$(find "$RESTORE_PATH" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        echo
        echo "WARNING:"
        echo "  Restore path is not empty:"
        echo "  $RESTORE_PATH"
        echo

        read -rp "Continue and overwrite existing files? (yes/no): " answer

        [[ "$answer" == "yes" ]] \
            || die "Restore cancelled"
    fi
}

# ------------------------------------------------------------
# Extract
# ------------------------------------------------------------

extract_archive() {

    log "Extracting backup..."

    if [[ "$FLATTEN_RESTORE" == "true" ]]; then
        tar \
            --zstd \
            --strip-components=1 \
            -xpf "$ARCHIVE_DIR/$ARCHIVE" \
            -C "$RESTORE_PATH"
    else
        tar \
            --zstd \
            -xpf "$ARCHIVE_DIR/$ARCHIVE" \
            -C "$RESTORE_PATH"
    fi

    log "Extraction completed"
}

restored_apps_dir() {
    if [[ "$FLATTEN_RESTORE" == "true" ]]; then
        echo "$RESTORE_PATH"
    else
        echo "$RESTORE_PATH/$ARCHIVE_ROOT"
    fi
}

validate_restored_compose_projects() {
    local apps_dir
    local project_dir
    local project_name
    local compose_file
    local compose_validation_available="true"

    DETECTED_PROJECTS=()

    if ! command -v docker >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        log "Docker/Compose not installed, skipping compose validation"
        compose_validation_available="false"
    else
        detect_compose_command
    fi

    apps_dir="$(restored_apps_dir)"

    [[ -d "$apps_dir" ]] \
        || die "Restored apps directory not found: $apps_dir"

    log "Validating restored compose files under: $apps_dir"

    mapfile -t compose_files < <(
        find "$apps_dir" -maxdepth 2 -type f \( \
            -name 'docker-compose.yml' -o \
            -name 'docker-compose.yaml' -o \
            -name 'compose.yml' -o \
            -name 'compose.yaml' \
        \) | sort
    )

    if (( ${#compose_files[@]} == 0 )); then
        log "No compose files found to validate"
        return 0
    fi

    for compose_file in "${compose_files[@]}"; do
        project_dir="$(dirname "$compose_file")"
        project_name="$(basename "$project_dir")"
        DETECTED_PROJECTS+=("$project_name")

        if [[ "$compose_validation_available" == "true" ]]; then
            log "Validating compose project: $project_name"
            (
                cd "$project_dir"
                $COMPOSE_CMD -f "$(basename "$compose_file")" config >/dev/null
            ) \
                || die "Compose validation failed for project '$project_name'"
        fi
    done

    if [[ "$compose_validation_available" == "true" ]]; then
        log "Compose validation completed successfully"
    fi
}

print_detected_projects_summary() {
    local project_name

    echo
    echo "Detected Compose Projects"
    echo

    if (( ${#DETECTED_PROJECTS[@]} == 0 )); then
        echo "none"
        echo
        echo "Total: 0"
        return 0
    fi

    for project_name in "${DETECTED_PROJECTS[@]}"; do
        echo "OK $project_name"
    done

    echo
    echo "Total: ${#DETECTED_PROJECTS[@]}"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {

    while [[ $# -gt 0 ]]; do
        case "$1" in

            --remote)
                RCLONE_REMOTE="$2"
                shift 2
                ;;

            --restore-path)
                RESTORE_PATH="$2"
                shift 2
                ;;

            --rclone-config)
                RCLONE_CONFIG="$2"
                shift 2
                ;;

            --archive)
                LOCAL_ARCHIVE_PATH="$2"
                MODE="local"
                shift 2
                ;;

            --checksum)
                LOCAL_CHECKSUM_PATH="$2"
                shift 2
                ;;

            --flatten)
                FLATTEN_RESTORE="true"
                shift
                ;;

            -h|--help)
                usage
                exit 0
                ;;

            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    [[ -n "$RESTORE_PATH" ]] \
        || die "--restore-path required"

    require_command sha256sum
    require_command tar
    require_command zstd

    validate_restore_path "$RESTORE_PATH"

    if [[ "$MODE" == "local" ]]; then
        # ── Local mode ──────────────────────────────────────────────
        [[ -n "$LOCAL_ARCHIVE_PATH" ]] \
            || die "--archive required in local mode"

        validate_local_archive "$LOCAL_ARCHIVE_PATH"

        # Auto-discover checksum file if not explicitly provided
        if [[ -z "$LOCAL_CHECKSUM_PATH" && -f "${LOCAL_ARCHIVE_PATH}.sha256" ]]; then
            LOCAL_CHECKSUM_PATH="${LOCAL_ARCHIVE_PATH}.sha256"
            log "Auto-discovered checksum file: $LOCAL_CHECKSUM_PATH"
        fi

        [[ -z "$LOCAL_CHECKSUM_PATH" ]] \
            || validate_local_checksum "$LOCAL_CHECKSUM_PATH"

        ARCHIVE_DIR="$(dirname "$LOCAL_ARCHIVE_PATH")"
        ARCHIVE="$(basename "$LOCAL_ARCHIVE_PATH")"
        CHECKSUM="$(basename "${LOCAL_CHECKSUM_PATH:-}")"

        inspect_archive_root
        confirm_restore
        verify_checksum
        verify_archive_integrity
        prepare_destination
        extract_archive
        validate_restored_compose_projects
        print_detected_projects_summary

    else
        # ── Remote mode ─────────────────────────────────────────────
        [[ -n "$RCLONE_REMOTE" ]] \
            || die "--remote required (or use --archive for local mode)"

        require_command rclone

        validate_remote
        find_latest_backup

        ARCHIVE_DIR="$LOCAL_STAGING"

        confirm_restore
        download_backup
        inspect_archive_root
        verify_checksum
        verify_archive_integrity
        prepare_destination
        extract_archive
        validate_restored_compose_projects
        print_detected_projects_summary

        # Free staging space immediately — don't wait for EXIT trap
        cleanup_staging
    fi

    echo
    echo "===================================="
    echo "RESTORE COMPLETED SUCCESSFULLY"
    echo "===================================="
    echo
    echo "Archive : $ARCHIVE"
    echo "Target  : $RESTORE_PATH"
    echo
}

main "$@"