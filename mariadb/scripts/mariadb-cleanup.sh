#!/bin/bash

# USAGE INFO
usage() {
  cat <<EOUSAGE

  USAGE: $0
      [--backup_dir=backup_dir]
      [--log_dir=log_dir]
      [--days_to_keep=days_to_keep]
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
    --log_dir=*)
      log_dir="${1#*=}"
      ;;
    --days_to_keep=*)
      days_to_keep="${1#*=}"
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
export LOG_DIR=${log_dir}
export LOG_FILE=${LOG_DIR}/mdbCleanup.log
export ERROR_FILE=${LOG_DIR}/mdbCleanup.err

export NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo -n "Start: ${NOW}" >> "$LOG_FILE"

# DELETE FILES AND DIRECTORIES OLDER THAN THRESHOLD
/usr/bin/find "$backup_dir" -type f -mtime +"$days_to_keep" -delete \
  -or -type d -empty -mtime +"$days_to_keep" -delete
export DELETE_RC=$?

if [ "$DELETE_RC" -ne 0 ]; then
  echo "$(date) - Error removing files and folders recursively" >> "$ERROR_FILE"
fi

export NOW=$(date '+%Y-%m-%d %H:%M:%S')
echo -n ", End: ${NOW}" >> "$LOG_FILE"
echo ", Exit: ${DELETE_RC}" >> "$LOG_FILE"

exit 0
