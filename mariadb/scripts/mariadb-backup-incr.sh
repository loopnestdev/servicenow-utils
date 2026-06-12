#!/bin/bash

# USAGE INFO
usage() {
  cat <<EOUSAGE

  USAGE: $0
      [--backup_dir=backup_dir]
      [--number_of_mountpoint=1|2|4]
      [--log_dir=log_dir]
      [--replication_enabled=true|false]
      [--help]

EOUSAGE
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

# PARSE PARAMETERS
while [ $# -gt 0 ]; do
  case "$1" in
    --backup_dir=*)
      backup_dir="${1#*=}"
      ;;
    --number_of_mountpoint=*)
      number_of_mountpoint="${1#*=}"
      ;;
    --log_dir=*)
      log_dir="${1#*=}"
      ;;
    --replication_enabled=*)
      replication_enabled="${1#*=}"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
  esac
  shift
done

# VARIABLES
export NUM_OF_MOUNTPOINTS=${number_of_mountpoint:-1}
export WEEK_INDEX=$(date '+%U')
export BACKUP_INDEX=$(( WEEK_INDEX % NUM_OF_MOUNTPOINTS + 1 ))
export TS=$(date '+%YW%U')
export MARIABACKUP_TYPE=incr

# SET BASE BACKUP DIR
if [ "$NUM_OF_MOUNTPOINTS" -eq 1 ]; then
  export BASE_BACKUP_DIR=${backup_dir}
elif [ "$NUM_OF_MOUNTPOINTS" -gt 1 ]; then
  export BASE_BACKUP_DIR=${backup_dir}/backup${BACKUP_INDEX}
else
  export BASE_BACKUP_DIR=${backup_dir}
fi

export TARGET_BACKUP_DIR=${BASE_BACKUP_DIR}/${TS}/${MARIABACKUP_TYPE}
export LOG_DIR=${log_dir}
export LOG_FILE=${LOG_DIR}/mdbBackupIncr.log
export MARIABACKUP_LOCKFILE=/tmp/mariabackup.lock
export MARIABACKUP_STATEFILE=${BASE_BACKUP_DIR}/${TS}/mariabackup.state
export MARIABACKUP_ERRORFILE=${LOG_DIR}/mdbBackupIncr.err
export TS_INCR=$(date '+%F_%H')
export TARGET_DIR_INCR=${TARGET_BACKUP_DIR}/${TS_INCR}

echo "$(date) - NUM_OF_MOUNTPOINTS = $NUM_OF_MOUNTPOINTS" >> "$MARIABACKUP_ERRORFILE"
echo "$(date) - WEEK_INDEX = $WEEK_INDEX"                 >> "$MARIABACKUP_ERRORFILE"
echo "$(date) - BACKUP_INDEX = $BACKUP_INDEX"             >> "$MARIABACKUP_ERRORFILE"
echo "$(date) - BASE_BACKUP_DIR = $BASE_BACKUP_DIR"       >> "$MARIABACKUP_ERRORFILE"

releaseLockAndExitWithCode() {
  if rm -f "$MARIABACKUP_LOCKFILE"; then
    echo "$(date) - Lock file removed" >> "$MARIABACKUP_ERRORFILE"
  else
    echo "$(date) - Could not remove lock file" >> "$MARIABACKUP_ERRORFILE"
  fi
  exit "$1"
}

getLockOrDie() {
  if touch "$MARIABACKUP_LOCKFILE"; then
    echo "$(date) - Lock file created" >> "$MARIABACKUP_ERRORFILE"
  else
    echo "$(date) - Could not create lock file — is another backup running?" >> "$MARIABACKUP_ERRORFILE"
    exit 1
  fi
}

# PREPARING
test ! -d "${TARGET_DIR_INCR}" && mkdir -p "${TARGET_DIR_INCR}" && chown -R mysql:mysql "${TARGET_DIR_INCR}"
test -d "${TARGET_DIR_INCR}"   && rm -f "${TARGET_DIR_INCR}"/*

export NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo -n "Start:${NOW}" >> "$LOG_FILE"

# GET LAST SUCCESSFUL BACKUP
LAST_SUCCESS_BACKUPTYPE=$(tail -1 "$MARIABACKUP_STATEFILE" | cut -d',' -f1)
LAST_SUCCESS_BACKUPTS=$(tail -1 "$MARIABACKUP_STATEFILE" | cut -d',' -f2)

if [ "${LAST_SUCCESS_BACKUPTYPE}" = "base" ]; then
  echo "$(date) - Last successful backup type was full: ${LAST_SUCCESS_BACKUPTS}" >> "$MARIABACKUP_ERRORFILE"
  INCRBASEDIR=${BASE_BACKUP_DIR}/${TS}/base
else
  echo "$(date) - Last successful backup type was incremental: ${LAST_SUCCESS_BACKUPTS}" >> "$MARIABACKUP_ERRORFILE"
  INCRBASEDIR=${TARGET_BACKUP_DIR}/${LAST_SUCCESS_BACKUPTS}
fi

# RUN INCREMENTAL BACKUP
getLockOrDie

echo "$(date) - Starting incremental backup" >> "$MARIABACKUP_ERRORFILE"
mariabackup \
  --backup \
  --extra-lsndir="${TARGET_DIR_INCR}" \
  --incremental-basedir="${INCRBASEDIR}" \
  --stream=xbstream | gzip > "${TARGET_DIR_INCR}/backup.stream.gz"

export RESULT=${PIPESTATUS[0]}
export NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo -n ", End:${NOW}" >> "$LOG_FILE"

if [ "$RESULT" -eq 0 ]; then
  echo ", Exit:${RESULT}. DONE" >> "$LOG_FILE"
  echo "$(date) - Backup completed" >> "$MARIABACKUP_ERRORFILE"
  echo "${MARIABACKUP_TYPE},${TS_INCR}" >> "$MARIABACKUP_STATEFILE"
  releaseLockAndExitWithCode 0
else
  echo ", Exit:${RESULT}. ERROR" >> "$LOG_FILE"
  echo "$(date) - Backup failed" >> "$MARIABACKUP_ERRORFILE"
  releaseLockAndExitWithCode 1
fi

chown -R mysql:mysql "${TARGET_BACKUP_DIR}"

exit 0
