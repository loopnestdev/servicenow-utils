#!/bin/bash
# MetricBase (Clotho) backup script.
#
# Supports two backup types:
#   full  – full backup; saves a .positions.json sidecar alongside the tar
#           (positions are required to run a subsequent differential backup)
#   diff  – differential backup; reads positions from the latest full backup
#           sidecar written by a previous --type=full run
#
# Backup strategy (set up by metricbase-deploy.sh crons):
#   Weekly  (Sunday 02:00) – full backup → <full_backup_dir>/
#   Every N hours           – diff backup → <diff_backup_dir>/  (reads sidecar from full dir)
#
# Reference KB: KB0677442 – MetricBase Installation Instructions
set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
NODE_DIR=""
PORT=""
PASSWORD_FILE=""
BACKUP_TYPE=""
FULL_BACKUP_DIR="/glide/backup/metricbase/full"
DIFF_BACKUP_DIR="/glide/backup/metricbase/diff"
LOG_DIR="/glide/logs"
JAVA_HOME_OVERRIDE=""

# Derived
JAVA_BIN=""
BACKUP_JAR=""
DATA_DIR=""

# ── USAGE ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOUSAGE

  USAGE: $0 [OPTIONS]

  Required:
    --node_dir=<path>             MetricBase node directory
                                  e.g. /glide/clotho/mydb_3400
    --port=<port>                 MetricBase listener port
    --password_file=<path>        Path to file containing the backup user's password
    --type=<full|diff>            Backup type

  Optional:
    --full_backup_dir=<path>      Full backup destination          (default: /glide/backup/metricbase/full)
    --diff_backup_dir=<path>      Differential backup destination  (default: /glide/backup/metricbase/diff)
    --log_dir=<path>              Log directory                    (default: /glide/logs)
    --java_home=<path>            Override JAVA_HOME               (default: \$JAVA_HOME or /glide/java)
    --help                        Show this help

  Differential backup notes:
    A differential backup requires the positions JSON written alongside the
    last full backup (saved as <full_backup_dir>/latest.positions.json).
    Run a full backup at least once before scheduling differentials.

  Example:
    # Full backup
    $0 --node_dir=/glide/clotho/mydb_3400 --port=3400 \\
       --password_file=/glide/clotho/mydb_3400/conf/mb_backup_password.txt \\
       --type=full

    # Differential backup
    $0 --node_dir=/glide/clotho/mydb_3400 --port=3400 \\
       --password_file=/glide/clotho/mydb_3400/conf/mb_backup_password.txt \\
       --type=diff

EOUSAGE
}

# ── HELPERS ───────────────────────────────────────────────────────────────────
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "${msg}"
  echo "${msg}" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true
}

die() {
  echo "[ERROR] $*" >&2
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >> "${LOG_FILE:-/dev/null}" 2>/dev/null || true
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
      --node_dir=*)        NODE_DIR="${1#*=}" ;;
      --port=*)            PORT="${1#*=}" ;;
      --password_file=*)   PASSWORD_FILE="${1#*=}" ;;
      --type=*)            BACKUP_TYPE="${1#*=}" ;;
      --full_backup_dir=*) FULL_BACKUP_DIR="${1#*=}" ;;
      --diff_backup_dir=*) DIFF_BACKUP_DIR="${1#*=}" ;;
      --log_dir=*)         LOG_DIR="${1#*=}" ;;
      --java_home=*)       JAVA_HOME_OVERRIDE="${1#*=}" ;;
      --help)              usage; exit 0 ;;
      *) die "Unknown argument: $1. Run $0 --help for usage." ;;
    esac
    shift
  done
}

validate_args() {
  [ -n "${NODE_DIR}" ]      || die "--node_dir is required."
  [ -n "${PORT}" ]          || die "--port is required."
  [ -n "${PASSWORD_FILE}" ] || die "--password_file is required."
  [ -n "${BACKUP_TYPE}" ]   || die "--type is required (full or diff)."

  case "${BACKUP_TYPE}" in
    full|diff) ;;
    *) die "--type must be 'full' or 'diff'." ;;
  esac

  [ -d "${NODE_DIR}" ]        || die "Node directory not found: ${NODE_DIR}"
  [ -f "${PASSWORD_FILE}" ]   || die "Password file not found: ${PASSWORD_FILE}"

  # Resolve JAVA_HOME
  local java_home="${JAVA_HOME_OVERRIDE:-${JAVA_HOME:-/glide/java}}"
  JAVA_BIN="${java_home}/bin/java"
  [ -x "${JAVA_BIN}" ] || die "Java binary not found or not executable: ${JAVA_BIN}"

  # Locate backup jar dynamically
  BACKUP_JAR=$(find "${NODE_DIR}/bin" -name "clotho-backup-*.jar" 2>/dev/null | sort -V | tail -1)
  [ -n "${BACKUP_JAR}" ] || die "clotho-backup-*.jar not found under ${NODE_DIR}/bin/"
  [ -f "${BACKUP_JAR}" ] || die "Backup jar not found: ${BACKUP_JAR}"

  DATA_DIR="${NODE_DIR}/data"
  [ -d "${DATA_DIR}" ] || die "MetricBase data directory not found: ${DATA_DIR}"

  mkdir -p "${LOG_DIR}" "${FULL_BACKUP_DIR}"
  [ "${BACKUP_TYPE}" = "diff" ] && mkdir -p "${DIFF_BACKUP_DIR}"

  LOG_FILE="${LOG_DIR}/metricbase-backup.log"
}

# ── FULL BACKUP ───────────────────────────────────────────────────────────────
run_full_backup() {
  local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S')
  local backup_file="${FULL_BACKUP_DIR}/clotho_full_${timestamp}.tar"
  local positions_file="${FULL_BACKUP_DIR}/latest.positions.json"
  local stderr_file; stderr_file=$(mktemp)

  log "Starting full backup → ${backup_file}"
  log "  Jar  : ${BACKUP_JAR##*/}"
  log "  Data : ${DATA_DIR}"
  log "  Port : ${PORT}"

  local rc=0
  "${JAVA_BIN}" -jar "${BACKUP_JAR}" \
    -data "${DATA_DIR}" \
    -pfile "${PASSWORD_FILE}" \
    -port "${PORT}" \
    > "${backup_file}" 2> "${stderr_file}" || rc=$?

  # Capture positions JSON from stderr (Clotho prints transaction positions during backup)
  local positions
  positions=$(grep -oE '\{[^}]+:[0-9][^}]*\}' "${stderr_file}" | tail -1 || true)

  # Always log stderr output for diagnostics
  if [ -s "${stderr_file}" ]; then
    log "--- backup tool output ---"
    cat "${stderr_file}" >> "${LOG_FILE}" 2>/dev/null || true
    log "--- end backup tool output ---"
  fi
  rm -f "${stderr_file}"

  [ "${rc}" -eq 0 ] || { rm -f "${backup_file}"; die "Full backup failed (exit ${rc}). See ${LOG_FILE}"; }

  local size; size=$(du -sh "${backup_file}" 2>/dev/null | cut -f1)
  log "Full backup complete: ${backup_file} (${size})"

  # Save positions sidecar for subsequent differential backups
  if [ -n "${positions}" ]; then
    echo "${positions}" > "${positions_file}"
    log "Positions saved: ${positions_file}"
    log "  Positions: ${positions}"
  else
    log "WARNING: Could not extract positions from backup output."
    log "  Differential backups will not be possible until positions are known."
    log "  Check ${LOG_FILE} for raw backup tool output."
  fi

  # Remove latest symlink and create a fresh one pointing to this backup
  ln -sf "${backup_file}" "${FULL_BACKUP_DIR}/latest.tar"
}

# ── DIFFERENTIAL BACKUP ───────────────────────────────────────────────────────
run_diff_backup() {
  local positions_file="${FULL_BACKUP_DIR}/latest.positions.json"

  [ -f "${positions_file}" ] \
    || die "Positions file not found: ${positions_file}. Run a full backup first."

  local positions
  positions=$(cat "${positions_file}")
  [ -n "${positions}" ] \
    || die "Positions file is empty: ${positions_file}. Re-run a full backup."

  local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S')
  local backup_file="${DIFF_BACKUP_DIR}/clotho_diff_${timestamp}.tar"
  local stderr_file; stderr_file=$(mktemp)

  log "Starting differential backup → ${backup_file}"
  log "  Jar       : ${BACKUP_JAR##*/}"
  log "  Data      : ${DATA_DIR}"
  log "  Port      : ${PORT}"
  log "  Positions : ${positions}"

  local rc=0
  "${JAVA_BIN}" -jar "${BACKUP_JAR}" \
    -data "${DATA_DIR}" \
    -pfile "${PASSWORD_FILE}" \
    -port "${PORT}" \
    -type incremental \
    -positions "${positions}" \
    > "${backup_file}" 2> "${stderr_file}" || rc=$?

  if [ -s "${stderr_file}" ]; then
    log "--- backup tool output ---"
    cat "${stderr_file}" >> "${LOG_FILE}" 2>/dev/null || true
    log "--- end backup tool output ---"
  fi
  rm -f "${stderr_file}"

  [ "${rc}" -eq 0 ] || { rm -f "${backup_file}"; die "Differential backup failed (exit ${rc}). See ${LOG_FILE}"; }

  local size; size=$(du -sh "${backup_file}" 2>/dev/null | cut -f1)
  log "Differential backup complete: ${backup_file} (${size})"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  validate_args

  log "============================================================"
  log "MetricBase Backup"
  log "  Type      : ${BACKUP_TYPE}"
  log "  Node dir  : ${NODE_DIR}"
  log "  Port      : ${PORT}"
  log "  Jar       : ${BACKUP_JAR##*/}"
  log "  Full dir  : ${FULL_BACKUP_DIR}"
  [ "${BACKUP_TYPE}" = "diff" ] && log "  Diff dir  : ${DIFF_BACKUP_DIR}"
  log "============================================================"

  case "${BACKUP_TYPE}" in
    full) run_full_backup ;;
    diff) run_diff_backup ;;
  esac

  log "============================================================"
  log "Backup finished successfully."
  log "============================================================"
}

main "$@"
