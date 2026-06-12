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
export MARIABACKUP_TYPE=base

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
export LOG_FILE=${LOG_DIR}/mdbBackupBase.log
export MARIABACKUP_LOCKFILE=/tmp/mariabackup.lock
export MARIABACKUP_STATEFILE=${BASE_BACKUP_DIR}/${TS}/mariabackup.state
export MARIABACKUP_ERRORFILE=${LOG_DIR}/mdbBackupBase.err

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
test ! -d "${TARGET_BACKUP_DIR}" && mkdir -p "${TARGET_BACKUP_DIR}" && chown -R mysql:mysql "${TARGET_BACKUP_DIR}"
test -d "${TARGET_BACKUP_DIR}"   && rm -f "${TARGET_BACKUP_DIR}"/*

export NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo -n "Start:${NOW}" >> "$LOG_FILE"

# RUN FULL BACKUP
getLockOrDie

echo "$(date) - Set vm.drop_caches to 3" >> "$MARIABACKUP_ERRORFILE"
echo 3 > /proc/sys/vm/drop_caches

echo "$(date) - Starting full backup" >> "$MARIABACKUP_ERRORFILE"
mariabackup \
  --backup \
  --extra-lsndir="${TARGET_BACKUP_DIR}" \
  --stream=xbstream | gzip > "${TARGET_BACKUP_DIR}/backup.stream.gz"

export RESULT=${PIPESTATUS[0]}
export NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo -n ", End:${NOW}" >> "$LOG_FILE"

if [ "$RESULT" -eq 0 ]; then
  echo ", Exit:${RESULT}. DONE" >> "$LOG_FILE"
  echo "$(date) - Backup completed" >> "$MARIABACKUP_ERRORFILE"
  echo "${MARIABACKUP_TYPE},${TS}" >> "$MARIABACKUP_STATEFILE"
  releaseLockAndExitWithCode 0
else
  echo ", Exit:${RESULT}. ERROR" >> "$LOG_FILE"
  echo "$(date) - Backup failed" >> "$MARIABACKUP_ERRORFILE"
  releaseLockAndExitWithCode 1
fi

echo "$(date) - Revert vm.drop_caches to 0" >> "$MARIABACKUP_ERRORFILE"
echo 0 > /proc/sys/vm/drop_caches

chown -R mysql:mysql "${TARGET_BACKUP_DIR}"

exit 0
