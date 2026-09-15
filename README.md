# MinIO Full Backup Script — Workflow

This script performs daily backups of all buckets from a MinIO server to a local filesystem.

The workflow is designed to:

* Back up all MinIO buckets.
* Synchronize the latest/current objects.
* Reuse existing dated backup directories on a 2-day rotation.
* Create as many date-based directories as required to support the rotation, using the format YYYY-MM-DD (e.g., 2026-09-15).
* Prevent multiple backup processes from running simultaneously.
* Record output in daily log files.
* Treat individual object failures as **warnings**, not fatal errors — the backup continues through all buckets.
* Retry only the failed objects, once each, after the main backup pass.
* Report a full summary of warnings, failures, and recovered objects.
* Send a Discord notification if any objects are still failed after the retry pass.

> **Key behavioural note:** object-level and bucket-level failures do **not** abort the backup. Only infrastructure failures do (see [Exit Behaviour](#exit-behaviour)).

---

## Workflow

### 1. Initialize Configuration

The script defines the MinIO alias, backup directory, log directory, and lock file.

```bash
MINIO_ALIAS="your-minio-alias"
BACKUP_ROOT="/MINIO-BACKUP"
LOG_DIR="${BACKUP_ROOT}/logs"
LOCK_FILE="/tmp/minio-backup.lock"
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
```

`DISCORD_WEBHOOK_URL` is used only if objects are still failed after the retry pass (see [step 16](#16-discord-failure-notification)). Leave it empty (`DISCORD_WEBHOOK_URL=""`) to disable notifications entirely.

It also generates the current date:

```bash
TODAY="$(date '+%Y-%m-%d')"
```

The daily log file is created using the current date:

```bash
LOG_FILE="${LOG_DIR}/backup-${TODAY}.log"
```

Example:

```text
/MINIO-BACKUP/logs/backup-2026-09-14.log
```

---

### 2. Create Backup and Log Directories

The script creates the required directories if they do not already exist.

```bash
mkdir -p "$BACKUP_ROOT"
mkdir -p "$LOG_DIR"
```

This ensures that the backup and logging locations are available before the process starts.

---

### 3. Create the Temporary Working Directory

A scratch directory is created to hold bookkeeping state for the duration of the run.

```bash
TMP_DIR="$(mktemp -d "${BACKUP_ROOT}/.backup-tmp-XXXXXX")"

FAILED_OBJECTS_FILE="${TMP_DIR}/failed_objects.txt"
RETRY_SUCCESS_FILE="${TMP_DIR}/retry_success.txt"
RETRY_FAILED_FILE="${TMP_DIR}/retry_failed.txt"
BUCKET_ERRORS_FILE="${TMP_DIR}/bucket_errors.txt"
```

These files track:

| File                  | Purpose                                                  |
| --------------------- | -------------------------------------------------------- |
| `failed_objects.txt`  | Object URLs that failed during the main mirror pass       |
| `retry_success.txt`   | Objects successfully recovered during the retry pass      |
| `retry_failed.txt`    | Objects that remained failed after the retry pass         |
| `bucket_errors.txt`   | Buckets whose `mc mirror` returned a non-zero exit code   |

Per-bucket `mc mirror` output is also captured here as `bucket-N.log`.

A trap removes this scratch directory when the script exits, for any reason:

```bash
cleanup() {
    rm -rf -- "$TMP_DIR"
}

trap cleanup EXIT
```

> This deletes **only** the temporary bookkeeping files. It never touches backup data or dated backup directories.

---

### 4. Enable Logging

The script redirects standard output and error output through `tee`.

```bash
exec > >(tee -a "$LOG_FILE") 2>&1
```

As a result:

* Output is displayed in the terminal.
* Output is also appended to the daily log file.
* Errors are recorded in the same log file.

---

### 5. Acquire a Backup Lock

The script creates a lock file and uses `flock` to prevent concurrent executions.

```bash
exec 200>"$LOCK_FILE"

if ! flock -n 200; then
    echo "ERROR: Another MinIO backup process is already running."
    exit 1
fi
```

If another backup process is already running, the new process exits.

This prevents:

* Multiple backup jobs running at the same time.
* Conflicts while writing to the same destination.
* Conflicts caused by the `--remove` option.
* Corruption caused by overlapping backup operations.

---

### 6. Validate the MinIO Client and Alias

The script checks whether the MinIO Client (`mc`) is installed.

```bash
if ! command -v mc >/dev/null 2>&1; then
    echo "ERROR: mc command not found."
    exit 1
fi
```

It then verifies that the configured MinIO alias is available.

```bash
if ! mc alias list "$MINIO_ALIAS" >/dev/null 2>&1; then
    echo "ERROR: MinIO alias '$MINIO_ALIAS' is not available."
    exit 1
fi
```

The backup process stops if:

* `mc` is not installed.
* The MinIO alias does not exist.
* The alias credentials are invalid.
* The MinIO server is unreachable.

---

### 7. Retrieve the MinIO Bucket List

The script lists all buckets from the configured MinIO server.

```bash
BUCKET_LIST=$(mc ls "$MINIO_ALIAS" 2>/dev/null | awk '{print $NF}' | sed 's:/$::')
```

The command extracts the bucket names and removes the trailing `/`.

Example:

```text
project-dev
project-prod
app-static-assets
staging-data
uat-service-a
uat-service-b
```

If no buckets are found, the script exits:

```text
ERROR: No buckets found or unable to list buckets.
```

---

### 8. Detect Existing Backup Directories

The script searches for existing backup directories under `/MINIO-BACKUP`.

Only directories using the following date format are considered:

```text
YYYY-MM-DD
```

Example:

```text
2026-09-10
2026-09-13
```

The `logs`, `lost+found`, and `.backup-tmp-*` directories are ignored because they do not match the date pattern.

The detected directories are sorted chronologically, from oldest to newest.

---

### 9. Select the Backup Target Directory

The script selects the directory where the current backup will be written.

#### If no previous backup exists

A new directory is created using today's date.

```text
/MINIO-BACKUP/2026-09-14
```

#### If one backup directory exists

* If it is today's directory, the script resumes it.
* If it is an older directory, the script reuses it.

#### If two or more backup directories exist

* If today's directory already exists, the script resumes it.
* Otherwise, the **oldest** dated directory is selected for reuse.

Example:

```text
Existing directories:
2026-09-10
2026-09-13
```

The script selects:

```text
/MINIO-BACKUP/2026-09-10
```

Reusing the oldest directory is what implements the 2-day rotation: the older snapshot is overwritten in place rather than a third directory being created.

---

### 10. Mirror Each MinIO Bucket

The script processes each bucket one by one.

For every bucket, it creates a local destination directory:

```bash
DEST="${TARGET_DIR}/${BUCKET}"
mkdir -p "$DEST"
```

It then runs:

```bash
mc mirror \
    --remove \
    --overwrite \
    "${MINIO_ALIAS}/${BUCKET}/" \
    "$DEST/" \
    >"$BUCKET_OUTPUT" 2>&1
```

#### Meaning of the options

| Option        | Description                                                  |
| ------------- | ------------------------------------------------------------ |
| `--remove`    | Removes destination files that no longer exist in the source |
| `--overwrite` | Overwrites destination files when required                   |
| Source        | MinIO bucket                                                 |
| Destination   | Local backup directory                                       |

Example:

```bash
mc mirror \
    --remove \
    --overwrite \
    "your-minio-alias/project-dev/" \
    "/MINIO-BACKUP/2026-09-10/project-dev/"
```

Output is captured to a per-bucket file first, then echoed to the main log. Capturing it allows failed object paths to be extracted reliably.

#### Extracting failed objects

Object-level failures are parsed out of the captured output:

```bash
sed -n 's/.*Failed to copy `\([^`]*\)`.*/\1/p' "$BUCKET_OUTPUT"
```

Each unique failed object URL is appended to the retry queue and logged:

```text
WARNING: Failed object queued for retry:
  https://host/project-dev/path/to/object
```

#### Bucket result

If `mc mirror` exits `0`:

```text
SUCCESS: Bucket completed successfully.
```

If `mc mirror` exits non-zero, the bucket is recorded as a **warning**, not a failure:

```text
WARNING: mc mirror returned exit code 1
WARNING: Bucket backup processing will continue.
WARNING: Any failed objects have been added to the retry queue.
```

The script continues processing the remaining buckets in every case.

---

### 11. Finalize the Backup Directory

After all buckets are processed, the reused directory is renamed to today's date.

Example:

```text
Old directory:
/MINIO-BACKUP/2026-09-10

New directory:
/MINIO-BACKUP/2026-09-14
```

* If the directory already carries today's date, no rename is needed.
* If a directory for today already exists while the target is a different directory, the script **refuses to overwrite it** and exits `1`.
* If the rename itself fails, the script exits `1`.

This rename is what retires the old snapshot — the stale date disappears as its contents are replaced by the freshly mirrored data.

---

### 12. Retry Failed Objects Once

Only the objects that failed during the main pass are retried, and each is retried exactly once. Objects that mirrored successfully are never touched again — the retry queue is built solely from `Failed to copy` lines, so nothing else can enter it.

If no objects failed, the whole pass is skipped:

```text
No failed objects require retry.
```

The source URL is parsed into its bucket and object path:

```text
https://host/bucket/path/to/object
   -> bucket = bucket
   -> object = path/to/object
```

Common URL-encoded characters (`%20`, `%2F`, `%40`, …) are decoded, and the retry destination is built under the finalized directory:

```bash
RETRY_DEST="${FINAL_DIR}/${SOURCE_BUCKET}/${DECODED_OBJECT_PATH}"
mkdir -p "$(dirname "$RETRY_DEST")"
```

The retry uses the **same command as the main backup pass**:

```bash
mc mirror \
    --overwrite \
    "$SOURCE_URL" \
    "$RETRY_DEST"
```

> `mc cp` is deliberately **not** used here — it does not reliably restore an object into a MinIO bucket destination. The retry pass reuses `mc mirror` for consistency with the main pass.

Each retry is recorded as either:

```text
RETRY SUCCESS:
  https://host/bucket/path/to/object
```

or:

```text
RETRY FAILED:
  https://host/bucket/path/to/object
```

If the bucket or object path cannot be determined from the URL, the object is counted as a permanent failure and skipped.

---

### 13. Display Current Backups

The script lists the dated backup directories that currently exist:

```bash
find "$BACKUP_ROOT" \
    -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended \
    -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    -printf '  %f\n' | sort
```

> **No retention deletion is performed.** Renaming the oldest directory to today's date (step 11) already retires the older snapshot as buckets are re-mirrored into it, so no directory ever needs to be removed. The script does not `rm` any backup folder.

---

### 14. Final Error / Retry Summary

The script prints a consolidated summary:

```text
Main backup:
  Buckets processed       : 6
  Buckets fully successful: 5
  Buckets with warnings   : 1
  Objects initially failed: 3

Retry results:
  Retry succeeded         : 2
  Retry permanently failed: 1
```

Followed by itemized sections:

* **BUCKET-LEVEL WARNINGS** — bucket name and `mc` exit code
* **OBJECTS THAT FAILED DURING MAIN BACKUP**
* **OBJECTS RECOVERED DURING RETRY**
* **OBJECTS STILL FAILED AFTER RETRY**

Each section prints a "none" message when empty.

---

### 15. Final Status

| Condition                                        | Message                                                                         |
| ------------------------------------------------ | ------------------------------------------------------------------------------- |
| Objects still failed after retry                 | `MinIO Backup Completed With Object Warnings`                                    |
| Objects failed initially but all recovered       | `MinIO Backup Completed Successfully` + all initially failed objects recovered   |
| No object failures at all                        | `MinIO Backup Completed Successfully`                                            |

---

### 16. Discord Failure Notification

If, after the retry pass, one or more objects are **still** failed (`RETRY_FAILED_COUNT > 0`), the script sends a message to the configured Discord webhook:

```bash
if [ "$RETRY_FAILED_COUNT" -gt 0 ]; then

    DISCORD_MESSAGE=$(printf \
        ':warning: **MinIO Backup Warning** (%s)\n%s object(s) failed to back up even after retry.\nBackup directory: %s\nPlease check the script logs: %s' \
        "$TODAY" "$RETRY_FAILED_COUNT" "$FINAL_DIR" "$LOG_FILE")

    send_discord_notification "$DISCORD_MESSAGE"
fi
```

The message includes:

* The date of the run.
* The number of objects that permanently failed.
* The finalized backup directory.
* The path to the day's log file, so the failure can be investigated directly.

No notification is sent when:

* All objects mirrored successfully, or
* All initially failed objects were recovered during the retry pass.

**Behaviour when notification itself fails or is disabled:**

| Condition                                  | Behaviour                                                        |
| ------------------------------------------- | ----------------------------------------------------------------- |
| `DISCORD_WEBHOOK_URL` is empty              | Notification is skipped; logged as a notice, script continues.    |
| `curl` is not installed                     | Notification is skipped with a warning; script continues.         |
| Webhook call fails (network, bad URL, etc.) | A warning is logged; script continues.                            |

A failed or skipped Discord notification never changes the script's exit code — it is a best-effort side effect, not part of the backup's success/failure logic.

---

## Exit Behaviour

| Condition                                    | Exit code |
| -------------------------------------------- | --------- |
| `mc` not installed                           | `1`       |
| MinIO alias unavailable                      | `1`       |
| Bucket list empty or unavailable             | `1`       |
| Another backup already running (lock held)   | `1`       |
| Today's directory already exists on rename   | `1`       |
| Backup directory rename failed               | `1`       |
| Bucket-level `mc mirror` warnings            | `0`       |
| Object-level failures (retried or permanent) | `0`       |
| Normal completion                            | `0`       |

Per-object failures do **not** make the whole backup exit `1`. The backup is considered complete as long as the main backup process and directory finalization succeeded.

---

## Scheduling (cron)

Run daily at 12:05 AM server-local time:

```cron
5 0 * * * /path/to/minio-backup.sh >> /MINIO-BACKUP/logs/cron.log 2>&1
```

Install with:

```bash
chmod +x /path/to/minio-backup.sh
crontab -e
```

Notes:

* Cron fields are `minute hour day month weekday`, so `5 0 * * *` is 00:05 daily.
* Cron uses the system's local timezone — no conversion needed if the server is already on `+06`.
* The script writes its own dated log; the `cron.log` redirect is a fallback for anything printed before logging is set up, or if cron cannot launch the script at all.
* If `mc` is not in cron's minimal `PATH`, add `PATH=/usr/local/bin:/usr/bin:/bin` above the cron entry or use an absolute path to `mc` in the script.

---

## Complete Workflow Diagram

```text
Start
  |
  v
Initialize configuration and current date
  |
  v
Create backup and log directories
  |
  v
Create temporary working directory (trap cleanup on exit)
  |
  v
Enable logging
  |
  v
Acquire backup lock
  |
  +-- Lock unavailable? ---> Exit 1
  |
  v
Check mc command
  |
  +-- mc missing? ---------> Exit 1
  |
  v
Check MinIO alias
  |
  +-- Alias unavailable? --> Exit 1
  |
  v
List MinIO buckets
  |
  +-- No buckets? ---------> Exit 1
  |
  v
Find existing dated backup directories
  |
  v
Select target directory (today's, or reuse oldest)
  |
  v
For each bucket:
  |
  +--> Run mc mirror --remove --overwrite
  |      |
  |      +-- Non-zero exit? --> Record bucket WARNING
  |      |
  |      +-- Parse "Failed to copy" --> Queue objects for retry
  |
  v
Continue through all buckets (no early abort)
  |
  v
Rename target directory to today's date
  |
  +-- Today's dir already exists? --> Exit 1
  +-- Rename failed? ---------------> Exit 1
  |
  v
Retry queue empty?
  |
  +-- Yes --> Skip retry pass entirely
  |
  v
Retry ONLY the failed objects, ONCE each (mc mirror --overwrite)
  |
  +--> Record retry success / permanent failure
  |
  v
Display current backups (no deletion)
  |
  v
Print final error / retry summary
  |
  v
Any objects still failed after retry?
  |
  +-- Yes --> Send Discord notification (count + log path)
  |             (failure to notify never changes exit code)
  |
  v
Exit 0
```

---

## Important Notes

* The script synchronizes the destination with the source.
* Because `mc mirror --remove` is used, files deleted from MinIO are also removed from the local backup directory.
* The backup directories are **not** immutable snapshots.
* The target directory is renamed to today's date regardless of object-level failures; only infrastructure failures prevent finalization.
* No backup directory is ever deleted by this script. The 2-day rotation happens by reusing and renaming the oldest directory.
* The temporary `.backup-tmp-*` directory is removed on exit; it holds only bookkeeping text files, never backup data.
* The retry pass uses `mc mirror`, not `mc cp`.
* A Discord notification is sent only when objects remain failed after retry; it requires `curl` and a valid `DISCORD_WEBHOOK_URL`, and never affects the script's exit code.