```bash
#!/usr/bin/env bash

set -u

# ============================================================
# MinIO 2-Day Rotating Backup
#
# Source:
#   MinIO alias: <minio-alias-name>
#
# Destination:
#   /MINIO-BACKUP/YYYY-MM-DD/<bucket>
#
# Storage:
#   ~300 GB source
#   ~650 GB backup disk
#
# Strategy:
#   1. Keep two backup directories.
#   2. Find the oldest backup directory.
#   3. Mirror the current MinIO data INTO that directory.
#   4. Only after ALL buckets succeed, rename it to today's date.
#
# IMPORTANT:
#   No third 300 GB temporary backup is created.
# ============================================================

# -----------------------------
# Configuration
# -----------------------------
MINIO_ALIAS="<minio-alias>"
BACKUP_ROOT="/MINIO-BACKUP"
LOG_DIR="${BACKUP_ROOT}/logs"
LOCK_FILE="/tmp/minio-backup.lock"

TODAY="$(date '+%Y-%m-%d')"
LOG_FILE="${LOG_DIR}/backup-${TODAY}.log"

# -----------------------------
# Prepare directories
# -----------------------------
mkdir -p "$BACKUP_ROOT"
mkdir -p "$LOG_DIR"

# -----------------------------
# Logging
# -----------------------------
exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "============================================================"
echo "MinIO Backup Started: $(date)"
echo "============================================================"

# -----------------------------
# Prevent concurrent execution
# -----------------------------
exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "ERROR: Another MinIO backup process is already running."
    exit 1
fi

# -----------------------------
# Check mc
# -----------------------------
if ! command -v mc >/dev/null 2>&1; then
    echo "ERROR: mc command not found."
    exit 1
fi

# -----------------------------
# Check MinIO alias
# -----------------------------
if ! mc alias list "$MINIO_ALIAS" >/dev/null 2>&1; then
    echo "ERROR: MinIO alias '$MINIO_ALIAS' is not available."
    exit 1
fi

echo "MinIO alias : $MINIO_ALIAS"
echo "Backup root : $BACKUP_ROOT"
echo "Today's date: $TODAY"

# -----------------------------
# Get bucket list
# -----------------------------
echo
echo "Getting bucket list..."

BUCKET_LIST=$(mc ls "$MINIO_ALIAS" 2>/dev/null | awk '{print $NF}' | sed 's:/$::')

if [ -z "$BUCKET_LIST" ]; then
    echo "ERROR: No buckets found or unable to list buckets."
    exit 1
fi

echo "Buckets:"
echo "$BUCKET_LIST"

# -----------------------------
# Find backup directories
# Only YYYY-MM-DD directories
# -----------------------------
mapfile -t BACKUPS < <(
    find "$BACKUP_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -regextype posix-extended \
        -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' \
        -printf '%f\n' |
    sort
)

BACKUP_COUNT=${#BACKUPS[@]}

echo
echo "Existing backup directories: $BACKUP_COUNT"

for backup in "${BACKUPS[@]}"; do
    echo "  $backup"
done

# ============================================================
# Determine directory to reuse
# ============================================================

if [ "$BACKUP_COUNT" -eq 0 ]; then

    echo
    echo "No previous backup found."
    echo "Creating first backup: $TODAY"

    TARGET_DIR="${BACKUP_ROOT}/${TODAY}"

    mkdir -p "$TARGET_DIR"

elif [ "$BACKUP_COUNT" -eq 1 ]; then

    EXISTING="${BACKUPS[0]}"

    # If today's backup already exists, resume it.
    if [ "$EXISTING" = "$TODAY" ]; then
        echo
        echo "Today's backup already exists."
        echo "Resuming backup: $TARGET_DIR"

        TARGET_DIR="${BACKUP_ROOT}/${TODAY}"

    else
        echo
        echo "One previous backup exists: $EXISTING"
        echo "Reusing it for today's backup."

        TARGET_DIR="${BACKUP_ROOT}/${EXISTING}"
    fi

else

    # Two or more backups exist.
    # The oldest one will be reused.
    OLDEST="${BACKUPS[0]}"

    # If today's backup already exists, this usually means
    # a previous backup was partially completed.
    if [ -d "${BACKUP_ROOT}/${TODAY}" ]; then

        echo
        echo "Today's backup directory already exists."
        echo "Resuming: ${BACKUP_ROOT}/${TODAY}"

        TARGET_DIR="${BACKUP_ROOT}/${TODAY}"

    else

        echo
        echo "Oldest backup: $OLDEST"
        echo "This directory will be reused."

        TARGET_DIR="${BACKUP_ROOT}/${OLDEST}"
    fi
fi

echo
echo "Target directory:"
echo "  $TARGET_DIR"

# ============================================================
# Mirror every bucket
# ============================================================

BACKUP_FAILED=0

while IFS= read -r BUCKET; do

    [ -z "$BUCKET" ] && continue

    DEST="${TARGET_DIR}/${BUCKET}"

    echo
    echo "------------------------------------------------------------"
    echo "Bucket: $BUCKET"
    echo "Destination: $DEST"
    echo "Started: $(date)"
    echo "------------------------------------------------------------"

    mkdir -p "$DEST"

    if mc mirror \
        --remove \
        --overwrite \
        "${MINIO_ALIAS}/${BUCKET}/" \
        "$DEST/"; then

        echo "SUCCESS: $BUCKET"
    else

        echo "ERROR: Mirror failed for bucket: $BUCKET"
        BACKUP_FAILED=1
    fi

done <<< "$BUCKET_LIST"

# ============================================================
# Handle failure
# ============================================================

if [ "$BACKUP_FAILED" -ne 0 ]; then

    echo
    echo "============================================================"
    echo "BACKUP FAILED"
    echo "Time: $(date)"
    echo "============================================================"
    echo
    echo "The target directory has NOT been renamed."
    echo "This allows the next run to retry the backup."

    exit 1
fi

# ============================================================
# Rename reused directory to today's date
# ============================================================

FINAL_DIR="${BACKUP_ROOT}/${TODAY}"

# Find the actual directory name being reused.
CURRENT_NAME="$(basename "$TARGET_DIR")"

if [ "$CURRENT_NAME" != "$TODAY" ]; then

    if [ -e "$FINAL_DIR" ]; then
        echo
        echo "ERROR: Today's directory already exists:"
        echo "  $FINAL_DIR"
        echo
        echo "Refusing to overwrite it."

        exit 1
    fi

    echo
    echo "All buckets completed successfully."
    echo "Renaming:"
    echo "  $TARGET_DIR"
    echo "      ->"
    echo "  $FINAL_DIR"

    mv "$TARGET_DIR" "$FINAL_DIR"

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to rename backup directory."
        exit 1
    fi
fi

# ============================================================
# Remove backups older than the newest 2
# ============================================================

echo
echo "Checking backup retention..."

mapfile -t FINAL_BACKUPS < <(
    find "$BACKUP_ROOT" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -regextype posix-extended \
        -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' \
        -printf '%f\n' |
    sort
)

FINAL_COUNT=${#FINAL_BACKUPS[@]}

if [ "$FINAL_COUNT" -gt 2 ]; then

    DELETE_COUNT=$((FINAL_COUNT - 2))

    for ((i=0; i<DELETE_COUNT; i++)); do

        OLD_BACKUP="${BACKUP_ROOT}/${FINAL_BACKUPS[$i]}"

        echo "Removing old backup:"
        echo "  $OLD_BACKUP"

        rm -rf -- "$OLD_BACKUP"

        if [ $? -ne 0 ]; then
            echo "WARNING: Failed to remove $OLD_BACKUP"
        fi
    done
fi

# ============================================================
# Final status
# ============================================================

echo
echo "Current backups:"

find "$BACKUP_ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -regextype posix-extended \
    -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    -printf '  %f\n' |
sort

echo
echo "============================================================"
echo "MinIO Backup Completed Successfully"
echo "Time: $(date)"
echo "============================================================"

exit 0
```