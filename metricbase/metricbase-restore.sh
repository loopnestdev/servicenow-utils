#!/bin/bash
# MetricBase (Clotho) restore script.
#
# Restore modes:
#   full only   – pass --full_backup only
#   full + diff – pass --full_backup and --diff_backups (comma-separated, chronological order)
#
# The restore jar is discovered dynamically under --node_dir/bin/.
# MetricBase must be stopped before running a restore.
#
# Reference KB: KB0677442 – MetricBase Installation Instructions
set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
NODE_DIR=""
FULL_BACKUP=""
DIFF_BACKUPS=""
TARGET_DIR=""
JAVA_HOME_OVERRIDE=""
FORCE="false"

# Derived
JAVA_BIN=""
RESTORE_JAR=""

# ── USAGE ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOUSAGE

  USAGE: $0 [OPTIONS]

  Required:
    --node_dir=<path>             MetricBase node directory
                                  e.g. /glide/clotho/mydb_3400
                                  (used to locate the clotho-restore jar)
    --full_backup=<path>          Path to the full backup tar file
    --target_dir=<path>           Target data directory for the restore
                                  e.g. /glide/clotho/mydb_3400/data

  Optional:
    --diff_backups=<path,...>     Comma-separated differential backup tar files
                                  in chronological order (oldest first)
    --java_home=<path>            Override JAVA_HOME               (default: \$JAVA_HOME or /glide/java)
    --force                       Skip the pre-restore confirmation prompt
    --help                        Show this help

  Notes:
    - MetricBase must be STOPPED before running a restore
    - The target data directory will be populated by the restore; ensure it is
      empty or that you have a separate backup of its current contents
    - For differential restore, pass all diff tars in the order they were taken;
      the full backup must always be listed first (via --full_backup)

  Example (full restore only):
    $0 --node_dir=/glide/clotho/mydb_3400 \\
       --full_backup=/glide/backup/metricbase/full/clotho_full_20250601_020000.tar \\
       --target_dir=/glide/clotho/mydb_3400/data

  Example (full + differential restore):
    $0 --node_dir=/glide/clotho/mydb_3400 \\
       --full_backup=/glide/backup/metricbase/full/clotho_full_20250601_020000.tar \\
       --diff_backups=/glide/backup/metricbase/diff/clotho_diff_20250601_060000.tar,/glide/backup/metricbase/diff/clotho_diff_20250601_120000.tar \\
       --target_dir=/glide/clotho/mydb_3400/data

EOUSAGE
}

# ── HELPERS ───────────────────────────────────────────────────────────────────
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

# ── ARGUMENT PARSING ──────────────────────────────────────────────────────────
parse_args() {
  if [ $# -eq 0 ]; then
    usage
    exit 1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --node_dir=*)       NODE_DIR="${1#*=}" ;;
      --full_backup=*)    FULL_BACKUP="${1#*=}" ;;
      --diff_backups=*)   DIFF_BACKUPS="${1#*=}" ;;
      --target_dir=*)     TARGET_DIR="${1#*=}" ;;
      --java_home=*)      JAVA_HOME_OVERRIDE="${1#*=}" ;;
      --force)            FORCE="true" ;;
      --help)             usage; exit 0 ;;
      *) die "Unknown argument: $1. Run $0 --help for usage." ;;
    esac
    shift
  done
}

validate_args() {
  [ -n "${NODE_DIR}" ]    || die "--node_dir is required."
  [ -n "${FULL_BACKUP}" ] || die "--full_backup is required."
  [ -n "${TARGET_DIR}" ]  || die "--target_dir is required."

  [ -d "${NODE_DIR}" ]    || die "Node directory not found: ${NODE_DIR}"
  [ -f "${FULL_BACKUP}" ] || die "Full backup file not found: ${FULL_BACKUP}"

  # Validate differential backup files if provided
  if [ -n "${DIFF_BACKUPS}" ]; then
    IFS=',' read -ra _diffs <<< "${DIFF_BACKUPS}"
    for _diff in "${_diffs[@]}"; do
      [ -f "${_diff}" ] || die "Differential backup file not found: ${_diff}"
    done
  fi

  # Resolve JAVA_HOME
  local java_home="${JAVA_HOME_OVERRIDE:-${JAVA_HOME:-/glide/java}}"
  JAVA_BIN="${java_home}/bin/java"
  [ -x "${JAVA_BIN}" ] || die "Java binary not found or not executable: ${JAVA_BIN}"

  # Locate restore jar dynamically
  RESTORE_JAR=$(find "${NODE_DIR}/bin" -name "clotho-restore-*.jar" 2>/dev/null | sort -V | tail -1)
  [ -n "${RESTORE_JAR}" ] || die "clotho-restore-*.jar not found under ${NODE_DIR}/bin/"
  [ -f "${RESTORE_JAR}" ] || die "Restore jar not found: ${RESTORE_JAR}"
}

# ── PRE-RESTORE CHECKS ────────────────────────────────────────────────────────
check_service_stopped() {
  if systemctl is-active --quiet metricbase 2>/dev/null; then
    die "MetricBase service is still running. Stop it first: systemctl stop metricbase"
  fi
  log "MetricBase service is not running — safe to proceed."
}

confirm_restore() {
  [ "${FORCE}" = "true" ] && return 0

  echo ""
  echo "  WARNING: This will populate ${TARGET_DIR} with restored data."
  echo "  Any existing data in that directory may be overwritten."
  echo ""
  echo "  Full backup  : ${FULL_BACKUP}"
  if [ -n "${DIFF_BACKUPS}" ]; then
    echo "  Diff backups : ${DIFF_BACKUPS}"
  fi
  echo "  Target dir   : ${TARGET_DIR}"
  echo ""
  printf "  Proceed? [yes/N]: "
  read -r answer
  [ "${answer}" = "yes" ] || { echo "Restore cancelled."; exit 0; }
}

# ── BUILD ARCHIVE LIST ────────────────────────────────────────────────────────
build_archive_list() {
  # clotho-restore.jar accepts -archives as a comma-separated list:
  # full.tar[,diff1.tar,diff2.tar,...]
  local archives="${FULL_BACKUP}"

  if [ -n "${DIFF_BACKUPS}" ]; then
    archives="${archives},${DIFF_BACKUPS}"
  fi

  echo "${archives}"
}

# ── RESTORE ───────────────────────────────────────────────────────────────────
run_restore() {
  local archives; archives=$(build_archive_list)

  mkdir -p "${TARGET_DIR}"

  log "Starting restore..."
  log "  Jar      : ${RESTORE_JAR##*/}"
  log "  Archives : ${archives}"
  log "  Target   : ${TARGET_DIR}"

  "${JAVA_BIN}" -jar "${RESTORE_JAR}" \
    -archives "${archives}" \
    -target "${TARGET_DIR}"

  log "Restore complete. Data written to: ${TARGET_DIR}"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  validate_args

  local mode="full"
  [ -n "${DIFF_BACKUPS}" ] && mode="full + differential"

  log "============================================================"
  log "MetricBase Restore"
  log "  Mode         : ${mode}"
  log "  Node dir     : ${NODE_DIR}"
  log "  Full backup  : ${FULL_BACKUP}"
  [ -n "${DIFF_BACKUPS}" ] && log "  Diff backups : ${DIFF_BACKUPS}"
  log "  Target dir   : ${TARGET_DIR}"
  log "  Restore jar  : ${RESTORE_JAR##*/}"
  log "============================================================"

  check_service_stopped
  confirm_restore
  run_restore

  log "============================================================"
  log "Restore finished successfully."
  log ""
  log "  Next steps:"
  log "    1. Verify restored data in ${TARGET_DIR}"
  log "    2. Start MetricBase: systemctl start metricbase"
  log "    3. Check logs: ${NODE_DIR}/logs/"
  log "============================================================"
}

main "$@"
