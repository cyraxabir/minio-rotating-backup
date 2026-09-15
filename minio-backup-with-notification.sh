#!/usr/bin/env bash

set -u

# ============================================================
# MinIO 2-Day Rotating Backup
#
# Source:
#   MinIO alias: minio-231-backup
#
# Destination:
#   /MINIO-BACKUP/YYYY-MM-DD/<bucket>
#
# Strategy:
#   1. Keep two backup directories.
#   2. Find the oldest backup directory.
#   3. Mirror current MinIO data into that directory.
#   4. Individual object failures do NOT stop the backup.
#   5. Continue processing all buckets.
#   6. Rename the backup directory to today's date.
#   7. Retry every failed object ONCE after the main backup.
#   8. Report successful and permanently failed retries.
#   9. If any objects are still failed after retry, notify a
#      Discord webhook with the failure count and log path.
#
# IMPORTANT:
#   Object-level failures are treated as warnings, not
#   whole-backup failures.
#
#   Infrastructure failures still cause the script to exit 1:
#   - mc missing
#   - MinIO alias unavailable
#   - bucket list unavailable
#   - backup directory rename failure
# ============================================================

# -----------------------------
# Configuration
# -----------------------------
MINIO_ALIAS="minio-231-backup"
BACKUP_ROOT="/MINIO-BACKUP"
LOG_DIR="${BACKUP_ROOT}/logs"
LOCK_FILE="/tmp/minio-backup.lock"

# Discord webhook URL for failure notifications.
# Leave empty to disable notifications entirely.
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/XXXXXXXXXX/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

TODAY="$(date '+%Y-%m-%d')"
LOG_FILE="${LOG_DIR}/backup-${TODAY}.log"

# -----------------------------
# Prepare directories
# -----------------------------
mkdir -p "$BACKUP_ROOT"
mkdir -p "$LOG_DIR"

# -----------------------------
# Temporary working directory
# -----------------------------
TMP_DIR="$(mktemp -d "${BACKUP_ROOT}/.backup-tmp-XXXXXX")"

FAILED_OBJECTS_FILE="${TMP_DIR}/failed_objects.txt"
RETRY_SUCCESS_FILE="${TMP_DIR}/retry_success.txt"
RETRY_FAILED_FILE="${TMP_DIR}/retry_failed.txt"
BUCKET_ERRORS_FILE="${TMP_DIR}/bucket_errors.txt"

touch "$FAILED_OBJECTS_FILE"
touch "$RETRY_SUCCESS_FILE"
touch "$RETRY_FAILED_FILE"
touch "$BUCKET_ERRORS_FILE"

cleanup() {
    rm -rf -- "$TMP_DIR"
}

trap cleanup EXIT

# -----------------------------
# Discord notification
#
# Sends a message to the configured Discord webhook.
# Failures to notify are logged but never abort the backup.
# -----------------------------
send_discord_notification() {
    local MESSAGE="$1"

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        echo "NOTICE: DISCORD_WEBHOOK_URL is not set, skipping notification."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "WARNING: curl not found, cannot send Discord notification."
        return 1
    fi

    local PAYLOAD
    PAYLOAD=$(printf '{"content": %s}' "$(
        printf '%s' "$MESSAGE" |
        python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null
    )")

    # Fallback if python3 is unavailable: minimal manual JSON escaping.
    if [ -z "$PAYLOAD" ] || [ "$PAYLOAD" = '{"content": }' ]; then
        local ESCAPED
        ESCAPED=$(printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
        PAYLOAD="{\"content\": \"${ESCAPED}\"}"
    fi

    if curl -fsS -X POST \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1; then

        echo "NOTICE: Discord notification sent."
    else
        echo "WARNING: Failed to send Discord notification."
    fi
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

# ============================================================
# Get bucket list
# ============================================================

echo
echo "Getting bucket list..."

BUCKET_LIST=$(
    mc ls "$MINIO_ALIAS" 2>/dev/null |
    awk '{print $NF}' |
    sed 's:/$::'
)

if [ -z "$BUCKET_LIST" ]; then
    echo "ERROR: No buckets found or unable to list buckets."
    exit 1
fi

echo "Buckets:"
echo "$BUCKET_LIST"

# ============================================================
# Find backup directories
# Only YYYY-MM-DD directories
# ============================================================

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

        TARGET_DIR="${BACKUP_ROOT}/${TODAY}"

        echo
        echo "Today's backup already exists."
        echo "Resuming backup: $TARGET_DIR"

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

    # If today's backup already exists, resume it.
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
# Counters
# ============================================================

BUCKET_COUNT=0
BUCKET_SUCCESS=0
BUCKET_WARNING=0
FAILED_OBJECT_COUNT=0
RETRY_SUCCESS_COUNT=0
RETRY_FAILED_COUNT=0

# ============================================================
# Mirror every bucket
# ============================================================

while IFS= read -r BUCKET; do

    [ -z "$BUCKET" ] && continue

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

    # --------------------------------------------------------
    # Run mirror
    #
    # Output is captured first so that failed object paths
    # can be extracted reliably.
    # --------------------------------------------------------

    mc mirror \
        --remove \
        --overwrite \
        "${MINIO_ALIAS}/${BUCKET}/" \
        "$DEST/" \
        >"$BUCKET_OUTPUT" 2>&1

    MIRROR_RC=$?

    # Write normal mc output to main log.
    cat "$BUCKET_OUTPUT"

    # --------------------------------------------------------
    # Extract object-level copy failures.
    #
    # Expected format:
    #   mc: <ERROR> Failed to copy `https://.../bucket/object`
    # --------------------------------------------------------

    while IFS= read -r FAILED_SOURCE; do

        [ -z "$FAILED_SOURCE" ] && continue

        # Avoid duplicate failed objects.
        if ! grep -Fqx "$FAILED_SOURCE" "$FAILED_OBJECTS_FILE"; then

            printf '%s\n' "$FAILED_SOURCE" >> "$FAILED_OBJECTS_FILE"

            FAILED_OBJECT_COUNT=$((FAILED_OBJECT_COUNT + 1))

            echo "WARNING: Failed object queued for retry:"
            echo "  $FAILED_SOURCE"
        fi

    done < <(
        sed -n \
            's/.*Failed to copy `\([^`]*\)`.*/\1/p' \
            "$BUCKET_OUTPUT"
    )

    # --------------------------------------------------------
    # Bucket result
    #
    # IMPORTANT:
    # A non-zero mc mirror exit code does NOT automatically
    # mean the whole backup failed.
    # --------------------------------------------------------

    if [ "$MIRROR_RC" -eq 0 ]; then

        echo "SUCCESS: Bucket completed successfully."
        BUCKET_SUCCESS=$((BUCKET_SUCCESS + 1))

    else

        BUCKET_WARNING=$((BUCKET_WARNING + 1))

        printf '%s\t%s\n' "$BUCKET" "$MIRROR_RC" \
            >> "$BUCKET_ERRORS_FILE"

        echo
        echo "WARNING: mc mirror returned exit code $MIRROR_RC"
        echo "WARNING: Bucket backup processing will continue."
        echo "WARNING: Any failed objects have been added to the retry queue."

    fi

done <<< "$BUCKET_LIST"

# ============================================================
# Main backup completed
# ============================================================

echo
echo "============================================================"
echo "MAIN BACKUP PROCESS COMPLETED"
echo "============================================================"

echo "Buckets processed          : $BUCKET_COUNT"
echo "Buckets fully successful   : $BUCKET_SUCCESS"
echo "Buckets with warnings      : $BUCKET_WARNING"
echo "Failed objects queued      : $FAILED_OBJECT_COUNT"
echo

echo "All buckets have been processed."
echo "The backup directory will now be finalized."

# ============================================================
# Rename reused directory to today's date
# ============================================================

FINAL_DIR="${BACKUP_ROOT}/${TODAY}"
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
# Retry failed objects ONCE
#
# NOTE:
#   mc cp does not reliably restore an object into a MinIO
#   bucket destination, so the retry pass reuses the same
#   command as the main backup pass: mc mirror.
# ============================================================

echo
echo "============================================================"
echo "FAILED OBJECT RETRY PASS"
echo "============================================================"

if [ ! -s "$FAILED_OBJECTS_FILE" ]; then

    echo "No failed objects require retry."

else

    while IFS= read -r SOURCE_URL; do

        [ -z "$SOURCE_URL" ] && continue

        echo
        echo "------------------------------------------------------------"
        echo "Retrying failed object:"
        echo "  $SOURCE_URL"
        echo "------------------------------------------------------------"

        # ----------------------------------------------------
        # Convert:
        #
        # https://host/bucket/path/to/object
        #
        # into:
        #
        # bucket = bucket
        # object = path/to/object
        # ----------------------------------------------------

        SOURCE_REST="${SOURCE_URL#*://}"
        SOURCE_PATH="${SOURCE_REST#*/}"

        SOURCE_BUCKET="${SOURCE_PATH%%/*}"
        OBJECT_PATH="${SOURCE_PATH#*/}"

        # If the URL did not contain an object path, skip it.
        if [ -z "$SOURCE_BUCKET" ] || [ -z "$OBJECT_PATH" ]; then

            echo "ERROR: Could not determine bucket/object from:"
            echo "  $SOURCE_URL"

            printf '%s\n' "$SOURCE_URL" >> "$RETRY_FAILED_FILE"

            RETRY_FAILED_COUNT=$((RETRY_FAILED_COUNT + 1))

            continue
        fi

        # ----------------------------------------------------
        # Decode common URL-encoded characters.
        #
        # Examples:
        #   %20 -> space
        #   %2F -> /
        #   %40 -> @
        #
        # Bash printf handles \xHH sequences.
        # ----------------------------------------------------

        DECODED_OBJECT_PATH="$(
            printf '%b' "${OBJECT_PATH//%/\\x}" 2>/dev/null
        )"

        if [ -z "$DECODED_OBJECT_PATH" ]; then
            DECODED_OBJECT_PATH="$OBJECT_PATH"
        fi

        RETRY_DEST="${FINAL_DIR}/${SOURCE_BUCKET}/${DECODED_OBJECT_PATH}"

        mkdir -p "$(dirname "$RETRY_DEST")"

        echo "Retry destination:"
        echo "  $RETRY_DEST"

        # ----------------------------------------------------
        # Retry once, using the same command as the main
        # backup pass (mc mirror), not mc cp.
        # ----------------------------------------------------

        if mc mirror \
            --overwrite \
            "$SOURCE_URL" \
            "$RETRY_DEST"; then

            echo "RETRY SUCCESS:"
            echo "  $SOURCE_URL"

            printf '%s\n' "$SOURCE_URL" >> "$RETRY_SUCCESS_FILE"

            RETRY_SUCCESS_COUNT=$((RETRY_SUCCESS_COUNT + 1))

        else

            echo "RETRY FAILED:"
            echo "  $SOURCE_URL"

            printf '%s\n' "$SOURCE_URL" >> "$RETRY_FAILED_FILE"

            RETRY_FAILED_COUNT=$((RETRY_FAILED_COUNT + 1))
        fi

    done < "$FAILED_OBJECTS_FILE"

fi

# ============================================================
# Current backups
#
# NOTE:
#   No retention deletion is performed here. Renaming the
#   oldest backup directory to today's date (above) already
#   retires the older snapshot's contents as buckets are
#   re-mirrored into it, so there is nothing left to delete.
# ============================================================

echo
echo "============================================================"
echo "CURRENT BACKUPS"
echo "============================================================"

find "$BACKUP_ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -regextype posix-extended \
    -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    -printf '  %f\n' |
sort

# ============================================================
# FINAL ERROR / RETRY SUMMARY
# ============================================================

echo
echo
echo "============================================================"
echo "FINAL BACKUP ERROR / RETRY SUMMARY"
echo "============================================================"

echo
echo "Main backup:"
echo "  Buckets processed       : $BUCKET_COUNT"
echo "  Buckets fully successful: $BUCKET_SUCCESS"
echo "  Buckets with warnings   : $BUCKET_WARNING"
echo "  Objects initially failed: $FAILED_OBJECT_COUNT"

echo
echo "Retry results:"
echo "  Retry succeeded         : $RETRY_SUCCESS_COUNT"
echo "  Retry permanently failed: $RETRY_FAILED_COUNT"

# ------------------------------------------------------------
# Bucket-level warnings
# ------------------------------------------------------------

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

# ------------------------------------------------------------
# Initially failed objects
# ------------------------------------------------------------

if [ -s "$FAILED_OBJECTS_FILE" ]; then

    echo
    echo "------------------------------------------------------------"
    echo "OBJECTS THAT FAILED DURING MAIN BACKUP"
    echo "------------------------------------------------------------"

    while IFS= read -r FAILED_OBJECT; do
        echo "  $FAILED_OBJECT"
    done < "$FAILED_OBJECTS_FILE"

else

    echo
    echo "No object failures during main backup."
fi

# ------------------------------------------------------------
# Retry successes
# ------------------------------------------------------------

if [ -s "$RETRY_SUCCESS_FILE" ]; then

    echo
    echo "------------------------------------------------------------"
    echo "OBJECTS RECOVERED DURING RETRY"
    echo "------------------------------------------------------------"

    while IFS= read -r RETRY_OBJECT; do
        echo "  $RETRY_OBJECT"
    done < "$RETRY_SUCCESS_FILE"

else

    echo
    echo "No objects recovered during retry."
fi

# ------------------------------------------------------------
# Permanent failures
# ------------------------------------------------------------

if [ -s "$RETRY_FAILED_FILE" ]; then

    echo
    echo "------------------------------------------------------------"
    echo "OBJECTS STILL FAILED AFTER RETRY"
    echo "------------------------------------------------------------"

    while IFS= read -r PERMANENT_OBJECT; do
        echo "  $PERMANENT_OBJECT"
    done < "$RETRY_FAILED_FILE"

else

    echo
    echo "No objects remained failed after retry."
fi

# ============================================================
# Final status
# ============================================================

echo
echo "============================================================"

if [ "$RETRY_FAILED_COUNT" -gt 0 ]; then

    echo "MinIO Backup Completed With Object Warnings"

    # --------------------------------------------------------
    # Notify Discord: objects are still missing after retry.
    # --------------------------------------------------------

    DISCORD_MESSAGE=$(printf \
        ':warning: **MinIO Backup Warning** (%s)\n%s object(s) failed to back up even after retry.\nBackup directory: %s\nPlease check the script logs: %s' \
        "$TODAY" \
        "$RETRY_FAILED_COUNT" \
        "$FINAL_DIR" \
        "$LOG_FILE")

    send_discord_notification "$DISCORD_MESSAGE"

elif [ "$FAILED_OBJECT_COUNT" -gt 0 ]; then

    echo "MinIO Backup Completed Successfully"
    echo "All initially failed objects were recovered during retry"

else

    echo "MinIO Backup Completed Successfully"
fi

echo "Time: $(date)"
echo "============================================================"

# ------------------------------------------------------------
# IMPORTANT:
# Per-object failures do NOT make the whole backup exit 1.
# The backup is considered completed as long as the main
# backup process and directory finalization succeeded.
# ------------------------------------------------------------

exit 0