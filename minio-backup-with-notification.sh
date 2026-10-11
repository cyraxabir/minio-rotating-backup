#!/usr/bin/env bash

set -u
set -o pipefail

# ============================================================
# MinIO 2-Day Rotating Backup
#
# Main backup:
#   mc mirror --remove --overwrite --skip-errors
#
# Failed-object handling:
#   1. Capture every "Failed to copy" object reported by mc.
#   2. After ALL buckets finish, retry ONLY those objects with mc mirror.
#   3. The persistent retry-failed log contains ONLY objects that
#      still fail after the dedicated retry.
#
# Persistent logs:
#   /MINIO-BACKUP/logs/backup-YYYY-MM-DD.log
#   /MINIO-BACKUP/logs/backup-YYYY-MM-DD.retry-failed-objects.log
#
# No "find" scan of the millions of objects is used.
# No "mc cp" is used for backup or retry.
# ============================================================

# -----------------------------
# Configuration
# -----------------------------
MINIO_ALIAS="<alias-name>"
BACKUP_ROOT="/<backup-dir>"
LOG_DIR="${BACKUP_ROOT}/logs"
LOCK_FILE="/tmp/minio-backup.lock"

# Buckets to skip completely.
# Example:
# SKIP_BUCKETS=(
#     "test-bucket"
#     "temporary-bucket"
# )
SKIP_BUCKETS=(
     "<bucket-name-1>"
     "<bucket-name-2>"
)

# Optional Discord webhook.
# Set it in the environment, do not hard-code the secret:
# export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
# DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/************"
TODAY="$(date '+%Y-%m-%d')"
LOG_FILE="${LOG_DIR}/backup-${TODAY}.log"
FINAL_FAILED_FILE="${LOG_DIR}/backup-${TODAY}.retry-failed-objects.log"

# -----------------------------
# Prepare directories
# -----------------------------
mkdir -p "$BACKUP_ROOT" "$LOG_DIR"

# The final retry-failed list is the only second persistent log.
: > "$FINAL_FAILED_FILE"

# -----------------------------
# Temporary working files
# -----------------------------
TMP_DIR="$(mktemp -d "${BACKUP_ROOT}/.backup-tmp-XXXXXX")"

FAILED_RAW_FILE="${TMP_DIR}/failed-raw.txt"
FAILED_OBJECTS_FILE="${TMP_DIR}/failed-objects.txt"
RETRY_SUCCESS_FILE="${TMP_DIR}/retry-success.txt"
BUCKET_ERRORS_FILE="${TMP_DIR}/bucket-errors.txt"

: > "$FAILED_RAW_FILE"
: > "$FAILED_OBJECTS_FILE"
: > "$RETRY_SUCCESS_FILE"
: > "$BUCKET_ERRORS_FILE"

cleanup() {
    rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

# -----------------------------
# Discord notification
# -----------------------------
send_discord_notification() {
    local MESSAGE="$1"
    local PAYLOAD

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        echo "NOTICE: DISCORD_WEBHOOK_URL is not set; notification skipped."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "WARNING: curl not found; cannot send Discord notification."
        return 1
    fi

    PAYLOAD="$(
        python3 - "$MESSAGE" <<'PY'
import json
import sys
print(json.dumps({"content": sys.argv[1]}))
PY
    )"

    if curl -fsS -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1; then
        echo "NOTICE: Discord notification sent."
        return 0
    fi

    echo "WARNING: Failed to send Discord notification."
    return 1
}

# -----------------------------
# Helpers
# -----------------------------
is_skipped_bucket() {
    local bucket="$1"
    local skip_bucket

    for skip_bucket in "${SKIP_BUCKETS[@]}"; do
        if [ "$bucket" = "$skip_bucket" ]; then
            return 0
        fi
    done

    return 1
}

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
# Dependency checks
# -----------------------------
if ! command -v mc >/dev/null 2>&1; then
    echo "ERROR: mc command not found."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required."
    exit 1
fi

# Verify --skip-errors without using grep -q in a pipe.
# This script uses "set -o pipefail", and grep -q can close the pipe
# early and make a supported mc command appear to have failed.
MC_MIRROR_HELP="$(mc mirror --help 2>&1)" || {
    echo "ERROR: Unable to read 'mc mirror --help'."
    exit 1
}

if ! grep -Fq -- '--skip-errors' <<< "$MC_MIRROR_HELP"; then
    echo "ERROR: Installed mc does not support --skip-errors."
    echo "ERROR: Update mc before running this backup."
    exit 1
fi

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

BUCKET_LIST="$(
    mc ls "$MINIO_ALIAS" 2>/dev/null |
    awk '{print $NF}' |
    sed 's:/$::'
)"

if [ -z "$BUCKET_LIST" ]; then
    echo "ERROR: No buckets found or unable to list buckets."
    exit 1
fi

echo "Buckets:"
echo "$BUCKET_LIST"

# -----------------------------
# Find existing backup directories
# -----------------------------
# Shell glob checks only the backup root.
# It does not scan bucket/object contents.
# -----------------------------
mapfile -t BACKUPS < <(
    for path in "$BACKUP_ROOT"/????-??-??; do
        [ -d "$path" ] || continue
        printf '%s\n' "${path##*/}"
    done | sort
)

BACKUP_COUNT=${#BACKUPS[@]}

echo
echo "Existing backup directories: $BACKUP_COUNT"

for backup in "${BACKUPS[@]}"; do
    echo "  $backup"
done

# -----------------------------
# Determine target directory
# -----------------------------
if [ "$BACKUP_COUNT" -eq 0 ]; then
    TARGET_DIR="${BACKUP_ROOT}/${TODAY}"
    mkdir -p "$TARGET_DIR"

    echo
    echo "No previous backup found."
    echo "Creating first backup: $TARGET_DIR"

elif [ "$BACKUP_COUNT" -eq 1 ]; then
    EXISTING="${BACKUPS[0]}"

    if [ "$EXISTING" = "$TODAY" ]; then
        TARGET_DIR="${BACKUP_ROOT}/${TODAY}"
        echo
        echo "Today's backup already exists."
        echo "Resuming backup: $TARGET_DIR"
    else
        TARGET_DIR="${BACKUP_ROOT}/${EXISTING}"
        echo
        echo "One previous backup exists: $EXISTING"
        echo "Reusing it for today's backup."
    fi

else
    OLDEST="${BACKUPS[0]}"

    if [ -d "${BACKUP_ROOT}/${TODAY}" ]; then
        TARGET_DIR="${BACKUP_ROOT}/${TODAY}"
        echo
        echo "Today's backup directory already exists."
        echo "Resuming: $TARGET_DIR"
    else
        TARGET_DIR="${BACKUP_ROOT}/${OLDEST}"
        echo
        echo "Oldest backup: $OLDEST"
        echo "This directory will be reused."
    fi
fi

echo
echo "Target directory:"
echo "  $TARGET_DIR"

# -----------------------------
# Counters
# -----------------------------
BUCKET_COUNT=0
BUCKET_SUCCESS=0
BUCKET_WARNING=0
BUCKET_SKIPPED_COUNT=0
FAILED_OBJECT_COUNT=0
RETRY_SUCCESS_COUNT=0
RETRY_FAILED_COUNT=0

# ============================================================
# MAIN MIRROR
# ============================================================
echo
echo "============================================================"
echo "MAIN MIRROR"
echo "============================================================"
echo "Object failures will be skipped and collected for one retry pass."

while IFS= read -r BUCKET; do
    [ -z "$BUCKET" ] && continue

    if is_skipped_bucket "$BUCKET"; then
        echo
        echo "SKIPPED BUCKET: $BUCKET"
        BUCKET_SKIPPED_COUNT=$((BUCKET_SKIPPED_COUNT + 1))
        continue
    fi

    BUCKET_COUNT=$((BUCKET_COUNT + 1))

    DEST="${TARGET_DIR}/${BUCKET}"
    BUCKET_OUTPUT="${TMP_DIR}/bucket-${BUCKET_COUNT}.log"

    echo
    echo "------------------------------------------------------------"
    echo "Bucket: $BUCKET"
    echo "Destination: $DEST"
    echo "Started: $(date)"
    echo "------------------------------------------------------------"

    mkdir -p "$DEST"

    # --skip-errors is intentional:
    # one failed object does not stop processing the rest of the bucket.
    #
    # No --retry here. Retry is handled separately after ALL buckets.
    mc mirror \
        --remove \
        --overwrite \
        --skip-errors \
        "${MINIO_ALIAS}/${BUCKET}/" \
        "$DEST/" \
        >"$BUCKET_OUTPUT" 2>&1

    MIRROR_RC=$?

    # Keep all normal mc output in the main log.
    cat "$BUCKET_OUTPUT"

    # Current mc mirror reports source-object copy failures as:
    #   Failed to copy `SOURCE`
    #
    # Capture those failed object sources for the dedicated retry.
    awk '
        /Failed to copy `/ {
            line = $0
            sub(/^.*Failed to copy `/, "", line)
            sub(/`.*/, "", line)
            if (line != "") print line
            next
        }

        /Failed to copy / {
            line = $0
            sub(/^.*Failed to copy[[:space:]]+/, "", line)
            sub(/[[:space:]].*$/, "", line)
            gsub(/^`|`$/, "", line)
            if (line != "") print line
        }
    ' "$BUCKET_OUTPUT" >> "$FAILED_RAW_FILE"

    if [ "$MIRROR_RC" -eq 0 ]; then
        echo "SUCCESS: Bucket mirror completed."
        BUCKET_SUCCESS=$((BUCKET_SUCCESS + 1))
    else
        echo "WARNING: mc mirror returned exit code $MIRROR_RC."
        echo "WARNING: Bucket processing continues."

        printf '%s\t%s\n' "$BUCKET" "$MIRROR_RC" >> "$BUCKET_ERRORS_FILE"
        BUCKET_WARNING=$((BUCKET_WARNING + 1))
    fi

done <<< "$BUCKET_LIST"

# ============================================================
# BUILD UNIQUE FAILED-OBJECT LIST
# ============================================================
echo
echo "============================================================"
echo "COLLECTING FAILED OBJECTS"
echo "============================================================"

if [ -s "$FAILED_RAW_FILE" ]; then

    # Convert reported URLs/paths into:
    #   minio-231-backup/bucket/object
    python3 \
        "$FAILED_RAW_FILE" \
        "$FAILED_OBJECTS_FILE" \
        "$MINIO_ALIAS" <<'PY'
import sys
from urllib.parse import unquote, urlsplit

raw_file, out_file, alias = sys.argv[1:4]
seen = set()

with open(raw_file, "r", encoding="utf-8", errors="replace") as src, \
     open(out_file, "w", encoding="utf-8") as dst:

    for raw in src:
        value = raw.rstrip("\r\n")

        if not value:
            continue

        if "://" in value:
            parsed = urlsplit(value)
            path = unquote(parsed.path.lstrip("/"))
        else:
            path = value

        prefix = alias + "/"
        if path.startswith(prefix):
            path = path[len(prefix):]

        if "/" not in path:
            continue

        canonical = alias + "/" + path

        if canonical not in seen:
            seen.add(canonical)
            dst.write(canonical + "\n")
PY

    sort -u "$FAILED_OBJECTS_FILE" -o "$FAILED_OBJECTS_FILE"
fi

FAILED_OBJECT_COUNT="$(wc -l < "$FAILED_OBJECTS_FILE" | tr -d ' ')"

if [ -z "$FAILED_OBJECT_COUNT" ]; then
    FAILED_OBJECT_COUNT=0
fi

echo "Objects initially failed: $FAILED_OBJECT_COUNT"

if [ "$FAILED_OBJECT_COUNT" -gt 0 ]; then
    echo
    echo "Failed objects queued for dedicated retry:"
    while IFS= read -r FAILED_OBJECT; do
        [ -z "$FAILED_OBJECT" ] && continue
        echo "  $FAILED_OBJECT"
    done < "$FAILED_OBJECTS_FILE"
else
    echo "No object-level failures were reported by the main mirror."
fi

# ============================================================
# DEDICATED RETRY - ONLY FAILED OBJECTS
# ============================================================
echo
echo "============================================================"
echo "DEDICATED RETRY OF FAILED OBJECTS"
echo "============================================================"
echo "Retry uses mc mirror only. No mc cp is used."

if [ "$FAILED_OBJECT_COUNT" -eq 0 ]; then
    echo "No failed objects require retry."

else

    while IFS= read -r SOURCE_PATH; do
        [ -z "$SOURCE_PATH" ] && continue

        echo
        echo "------------------------------------------------------------"
        echo "Retrying:"
        echo "  $SOURCE_PATH"
        echo "------------------------------------------------------------"

        REL_PATH="${SOURCE_PATH#"${MINIO_ALIAS}/"}"
        SPLIT_BUCKET="${REL_PATH%%/*}"
        SPLIT_OBJECT="${REL_PATH#*/}"

        if [ -z "$SPLIT_BUCKET" ] || \
           [ -z "$SPLIT_OBJECT" ] || \
           [ "$SPLIT_OBJECT" = "$REL_PATH" ]; then

            echo "ERROR: Could not determine bucket/object:"
            echo "  $SOURCE_PATH"

            printf '%s\n' "$SOURCE_PATH" >> "$FINAL_FAILED_FILE"
            RETRY_FAILED_COUNT=$((RETRY_FAILED_COUNT + 1))
            continue
        fi

        RETRY_SOURCE="${MINIO_ALIAS}/${SPLIT_BUCKET}/${SPLIT_OBJECT}"

        case "$SPLIT_OBJECT" in
            */*)
                OBJECT_DIR="${SPLIT_OBJECT%/*}"
                RETRY_DEST_DIR="${TARGET_DIR}/${SPLIT_BUCKET}/${OBJECT_DIR}"
                ;;
            *)
                RETRY_DEST_DIR="${TARGET_DIR}/${SPLIT_BUCKET}"
                ;;
        esac

        mkdir -p "$RETRY_DEST_DIR"

        echo "Retry source:"
        echo "  $RETRY_SOURCE"
        echo "Retry destination:"
        echo "  $RETRY_DEST_DIR"

        # SOURCE may be an individual S3 object.
        # TARGET is the local directory for that object.
        if mc mirror \
            --overwrite \
            "$RETRY_SOURCE" \
            "$RETRY_DEST_DIR/"; then

            echo "RETRY SUCCESS: $SOURCE_PATH"
            printf '%s\n' "$SOURCE_PATH" >> "$RETRY_SUCCESS_FILE"
            RETRY_SUCCESS_COUNT=$((RETRY_SUCCESS_COUNT + 1))

        else

            echo "RETRY FAILED: $SOURCE_PATH"
            printf '%s\n' "$SOURCE_PATH" >> "$FINAL_FAILED_FILE"
            RETRY_FAILED_COUNT=$((RETRY_FAILED_COUNT + 1))
        fi

    done < "$FAILED_OBJECTS_FILE"
fi

# Final failed list must contain only objects that still failed.
if [ -s "$FINAL_FAILED_FILE" ]; then
    sort -u "$FINAL_FAILED_FILE" -o "$FINAL_FAILED_FILE"
    RETRY_FAILED_COUNT="$(wc -l < "$FINAL_FAILED_FILE" | tr -d ' ')"
else
    : > "$FINAL_FAILED_FILE"
    RETRY_FAILED_COUNT=0
fi

if [ -s "$RETRY_SUCCESS_FILE" ]; then
    sort -u "$RETRY_SUCCESS_FILE" -o "$RETRY_SUCCESS_FILE"
    RETRY_SUCCESS_COUNT="$(wc -l < "$RETRY_SUCCESS_FILE" | tr -d ' ')"
else
    RETRY_SUCCESS_COUNT=0
fi

# ============================================================
# SUMMARY
# ============================================================
echo
echo "============================================================"
echo "MAIN BACKUP + RETRY COMPLETED"
echo "============================================================"
echo "Buckets processed          : $BUCKET_COUNT"
echo "Buckets successful         : $BUCKET_SUCCESS"
echo "Buckets with warnings     : $BUCKET_WARNING"
echo "Buckets skipped            : $BUCKET_SKIPPED_COUNT"
echo "Objects initially failed  : $FAILED_OBJECT_COUNT"
echo "Objects recovered on retry: $RETRY_SUCCESS_COUNT"
echo "Objects still failed      : $RETRY_FAILED_COUNT"
echo
echo "Main log:"
echo "  $LOG_FILE"
echo
echo "Final retry-failed object list:"
echo "  $FINAL_FAILED_FILE"

if [ -s "$FINAL_FAILED_FILE" ]; then
    echo
    echo "------------------------------------------------------------"
    echo "OBJECTS STILL FAILED AFTER RETRY"
    echo "------------------------------------------------------------"

    while IFS= read -r PERMANENT_OBJECT; do
        [ -z "$PERMANENT_OBJECT" ] && continue
        echo "  $PERMANENT_OBJECT"
    done < "$FINAL_FAILED_FILE"
else
    echo
    echo "No objects remained failed after the dedicated retry."
fi

# ============================================================
# FINALIZE BACKUP DIRECTORY
# ============================================================
FINAL_DIR="${BACKUP_ROOT}/${TODAY}"
CURRENT_NAME="$(basename "$TARGET_DIR")"

if [ "$CURRENT_NAME" != "$TODAY" ]; then

    if [ -e "$FINAL_DIR" ]; then
        echo
        echo "ERROR: Today's directory already exists:"
        echo "  $FINAL_DIR"
        echo "Refusing to overwrite it."
        exit 1
    fi

    echo
    echo "Renaming backup directory:"
    echo "  $TARGET_DIR"
    echo "      ->"
    echo "  $FINAL_DIR"

    if mv -- "$TARGET_DIR" "$FINAL_DIR"; then
        TARGET_DIR="$FINAL_DIR"
        echo "SUCCESS: Backup directory renamed."
    else
        echo "ERROR: Failed to rename backup directory."
        exit 1
    fi

else

    echo
    echo "Backup directory already has today's date:"
    echo "  $FINAL_DIR"
fi

# ============================================================
# CURRENT BACKUPS
# ============================================================
echo
echo "============================================================"
echo "CURRENT BACKUPS"
echo "============================================================"

for path in "$BACKUP_ROOT"/????-??-??; do
    [ -d "$path" ] || continue
    printf '  %s\n' "${path##*/}"
done | sort

# ============================================================
# BUCKET-LEVEL WARNINGS
# ============================================================
if [ -s "$BUCKET_ERRORS_FILE" ]; then
    echo
    echo "------------------------------------------------------------"
    echo "BUCKET-LEVEL WARNINGS"
    echo "------------------------------------------------------------"

    while IFS=$'\t' read -r ERROR_BUCKET ERROR_RC; do
        echo "Bucket: $ERROR_BUCKET"
        echo "mc exit code: $ERROR_RC"
        echo
    done < "$BUCKET_ERRORS_FILE"

else
    echo
    echo "No bucket-level warnings."
fi

# ============================================================
# FINAL STATUS
# ============================================================
echo
echo "============================================================"

if [ "$RETRY_FAILED_COUNT" -gt 0 ]; then

    echo "MinIO Backup Completed With Object Warnings"

    DISCORD_MESSAGE="$(
        printf \
            ':warning: **MinIO Backup Warning** (%s)\n%s object(s) failed after dedicated mirror retry.\nBackup directory: %s\nRetry-failed object list: %s\nMain log: %s' \
            "$TODAY" \
            "$RETRY_FAILED_COUNT" \
            "$FINAL_DIR" \
            "$FINAL_FAILED_FILE" \
            "$LOG_FILE"
    )"

    send_discord_notification "$DISCORD_MESSAGE"

elif [ "$FAILED_OBJECT_COUNT" -gt 0 ]; then

    echo "MinIO Backup Completed Successfully"
    echo "All initially failed objects were recovered during the retry pass."

else

    echo "MinIO Backup Completed Successfully"
    echo "No object-level failures were reported."

fi

echo "Time: $(date)"
echo "============================================================"

# Object failures are warnings and are listed in the logs.
# Infrastructure failures exit with status 1 above.
exit 0