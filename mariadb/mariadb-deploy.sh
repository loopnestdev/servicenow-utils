#!/bin/bash
set -euo pipefail

# ─── USAGE ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOUSAGE

  USAGE: $0
      --env_file=<path>          path to deployment env file   (required)
      [--install_dir=<dir>]      base install directory        (default: /data/mdbcor)
      [--app_version=<ver>]      MariaDB version               (default: 10.6)
      [--db_port=<port>]         MariaDB listen port           (default: 3306)
      [--ssl_enabled=<bool>]     enable SSL/TLS                (default: true)
      [--backup_dir=<dir>]       backup mount point            (default: /mnt/backup)
      [--help]

  Example:
      $0 --env_file=mdb_deploy.env --install_dir=/data/mdbcor --ssl_enabled=true

EOUSAGE
}

# ─── DEFAULTS ─────────────────────────────────────────────────────────────────
ENV_FILE=
INSTALL_DIR=/data/mdbcor
APP_VERSION=10.6
DB_PORT=3306
SSL_ENABLED=true
BACKUP_DIR=/mnt/backup

# ─── PARSE PARAMETERS ─────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
  usage
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --env_file=*)    ENV_FILE="${1#*=}" ;;
    --install_dir=*) INSTALL_DIR="${1#*=}" ;;
    --app_version=*) APP_VERSION="${1#*=}" ;;
    --db_port=*)     DB_PORT="${1#*=}" ;;
    --ssl_enabled=*) SSL_ENABLED="${1#*=}" ;;
    --backup_dir=*)  BACKUP_DIR="${1#*=}" ;;
    --help)          usage; exit 0 ;;
    *)               usage; exit 1 ;;
  esac
  shift
done

# ─── PATHS ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

MARIADB_DATADIR="${INSTALL_DIR}/data"
MARIADB_BACKUPDIR="${INSTALL_DIR}/backup"
MARIADB_BINLOGDIR="${INSTALL_DIR}/binlog"
MARIADB_LOGDIR="${INSTALL_DIR}/log"
MARIADB_SSLDIR="${INSTALL_DIR}/ssl"
MARIADB_TEMPDIR="${INSTALL_DIR}/temp"
MARIADB_SCRIPTDIR="${INSTALL_DIR}/script"
MARIADB_DATADIR_DEFAULT=/var/lib/mysql
MARIADB_CONFIGDIR=/etc/my.cnf.d
SSL_CACERT="${MARIADB_SSLDIR}/ca.crt"
OS_MAXOPENFILES=132096

# ─── LOGGING ──────────────────────────────────────────────────────────────────
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

# ─── PRE-FLIGHT ───────────────────────────────────────────────────────────────
check_root() {
  [ "$(id -u)" -eq 0 ] || die "This script must be run as root."
}

load_env() {
  [ -n "$ENV_FILE" ] || die "--env_file is required."
  [ -f "$ENV_FILE" ] || die "Env file not found: $ENV_FILE"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
}

validate() {
  local required_vars=(
    MARIADBROOTPASS
    SNOWDBUSER
    SNOWDBPASS
    MARIADBBACKUPPASS
    MARIADBMONITORPASS
    MARIADBMETRICPASS
  )
  for var in "${required_vars[@]}"; do
    [ -n "${!var:-}" ] || die "Required variable '$var' is not set in $ENV_FILE"
  done

  # Apply defaults for optional vars
  MARIADB_USER_BACKUP="${MARIADB_USER_BACKUP:-backupuser}"
  MARIADB_USER_MONITOR="${MARIADB_USER_MONITOR:-monitoruser}"
  MARIADB_USER_METRIC="${MARIADB_USER_METRIC:-metricuser}"
  BACKUP_RETENTION="${BACKUP_RETENTION:-93}"

  # Verify config files exist
  for cfg in server.cnf mariadb.cnf mariabackup.cnf mariadb-client.cnf; do
    [ -f "${CONFIG_DIR}/${cfg}" ] || die "Config file not found: ${CONFIG_DIR}/${cfg}"
  done

  # Verify backup scripts exist
  for script in mdbBackupFull.sh mdbBackupIncr.sh mdbCleanup.sh; do
    [ -f "${SCRIPTS_DIR}/${script}" ] || die "Backup script not found: ${SCRIPTS_DIR}/${script}"
  done

  # Verify SSL certs exist if SSL is enabled
  if [ "$SSL_ENABLED" = "true" ]; then
    [ -f "${CONFIG_DIR}/ca.crt" ]   || die "SSL CA cert not found: ${CONFIG_DIR}/ca.crt"
    [ -f "${CONFIG_DIR}/host.crt" ] || die "SSL server cert not found: ${CONFIG_DIR}/host.crt"
    [ -f "${CONFIG_DIR}/host.key" ] || die "SSL server key not found: ${CONFIG_DIR}/host.key"
  fi

  log "Pre-flight validation passed."
}

# ─── SYSTEM CONFIGURATION ─────────────────────────────────────────────────────
configure_system() {
  log "Configuring PAM limits..."
  cat > /etc/security/limits.d/99-mariadb.conf <<EOF
*  soft  nofile  65535
*  hard  nofile  65535
*  soft  core    unlimited
*  hard  core    unlimited
EOF

  log "Configuring kernel parameters..."
  cat > /etc/sysctl.d/99-mariadb.conf <<EOF
net.ipv4.tcp_max_syn_backlog = 16384
net.core.somaxconn = 32768
vm.swappiness = 1
EOF
  sysctl -p /etc/sysctl.d/99-mariadb.conf
}

# ─── PACKAGE INSTALLATION ─────────────────────────────────────────────────────
install_packages() {
  log "Checking for MariaDB yum repo..."
  if ! dnf repolist enabled 2>/dev/null | grep -qi mariadb; then
    log "MariaDB repo not detected — configuring official MariaDB ${APP_VERSION} repo..."
    cat > /etc/yum.repos.d/mariadb.repo <<EOF
[mariadb]
name      = MariaDB ${APP_VERSION}
baseurl   = https://downloads.mariadb.com/MariaDB/mariadb-${APP_VERSION}/yum/rhel/\$releasever/\$basearch
gpgkey    = https://downloads.mariadb.com/MariaDB/RPM-GPG-KEY-MariaDB
gpgcheck  = 1
enabled   = 1
EOF
  fi

  log "Removing conflicting MySQL packages (if any)..."
  dnf remove -y mysql-community-common 2>/dev/null || true

  log "Installing MariaDB ${APP_VERSION} packages..."
  dnf install -y \
    MariaDB-client \
    MariaDB-server \
    MariaDB-backup \
    python3-PyMySQL
}

# ─── DIRECTORY CREATION ───────────────────────────────────────────────────────
create_directories() {
  log "Creating MariaDB directories under ${INSTALL_DIR}..."
  local dirs=(
    "$MARIADB_DATADIR"
    "$MARIADB_BACKUPDIR"
    "$MARIADB_BINLOGDIR"
    "$MARIADB_LOGDIR"
    "$MARIADB_SSLDIR"
    "$MARIADB_TEMPDIR"
    "$MARIADB_SCRIPTDIR"
    "$BACKUP_DIR"
  )
  for dir in "${dirs[@]}"; do
    mkdir -p "$dir"
    chown mysql:mysql "$dir"
    chmod 700 "$dir"
  done
}

# ─── SYSTEMD TUNING ───────────────────────────────────────────────────────────
setup_systemd() {
  log "Applying systemd resource limits for mariadb.service..."
  mkdir -p /etc/systemd/system/mariadb.service.d
  cat > /etc/systemd/system/mariadb.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=${OS_MAXOPENFILES}
EOF
  systemctl daemon-reload
}

# ─── CONFIG FILE DEPLOYMENT ───────────────────────────────────────────────────
deploy_configs() {
  log "Computing innodb_buffer_pool_size (70% of total RAM)..."
  local total_mem_kb
  total_mem_kb=$(awk '/MemTotal/ { print $2 }' /proc/meminfo)
  local total_mem_gb=$(( total_mem_kb / 1024 / 1024 ))
  local buffer_pool_gb=$(( (total_mem_gb * 7) / 10 ))
  [ "$buffer_pool_gb" -lt 1 ] && buffer_pool_gb=1
  local innodb_buffer_pool_size="${buffer_pool_gb}G"
  log "innodb_buffer_pool_size = ${innodb_buffer_pool_size} (from ${total_mem_gb}G total RAM)"

  log "Deploying MariaDB config files to ${MARIADB_CONFIGDIR}..."

  for cfg in server.cnf mariadb.cnf mariabackup.cnf mariadb-client.cnf; do
    sed \
      -e "s|%%MARIADB_PORT%%|${DB_PORT}|g" \
      -e "s|%%MARIADB_DATADIR%%|${MARIADB_DATADIR}|g" \
      -e "s|%%MARIADB_TEMPDIR%%|${MARIADB_TEMPDIR}|g" \
      -e "s|%%MARIADB_BINLOGDIR%%|${MARIADB_BINLOGDIR}|g" \
      -e "s|%%MARIADB_LOGDIR%%|${MARIADB_LOGDIR}|g" \
      -e "s|%%MARIADB_SSLDIR%%|${MARIADB_SSLDIR}|g" \
      -e "s|%%SSL_CACERT%%|${SSL_CACERT}|g" \
      -e "s|%%INNODB_BUFFER_POOL_SIZE%%|${innodb_buffer_pool_size}|g" \
      -e "s|%%MARIADB_USER_BACKUP%%|${MARIADB_USER_BACKUP}|g" \
      -e "s|%%MARIADBBACKUPPASS%%|${MARIADBBACKUPPASS}|g" \
      "${CONFIG_DIR}/${cfg}" > "${MARIADB_CONFIGDIR}/${cfg}"

    chown root:mysql "${MARIADB_CONFIGDIR}/${cfg}"
    chmod 640 "${MARIADB_CONFIGDIR}/${cfg}"
  done

  # Remove auth_gssapi config if present (no FreeIPA in this environment)
  rm -f "${MARIADB_CONFIGDIR}/auth_gssapi.cnf"
}

# ─── SSL SETUP ────────────────────────────────────────────────────────────────
setup_ssl() {
  if [ "$SSL_ENABLED" != "true" ]; then
    log "SSL disabled — skipping cert deployment."
    return
  fi

  log "Copying SSL certificates to ${MARIADB_SSLDIR}..."
  cp "${CONFIG_DIR}/ca.crt"   "${MARIADB_SSLDIR}/ca.crt"
  cp "${CONFIG_DIR}/host.crt" "${MARIADB_SSLDIR}/host.crt"
  cp "${CONFIG_DIR}/host.key" "${MARIADB_SSLDIR}/host.key"

  chown -R mysql:mysql "${MARIADB_SSLDIR}"
  chmod 644 "${MARIADB_SSLDIR}/ca.crt" "${MARIADB_SSLDIR}/host.crt"
  chmod 600 "${MARIADB_SSLDIR}/host.key"
}

# ─── DATABASE INITIALISATION ──────────────────────────────────────────────────
init_database() {
  log "Cleaning up default data directory if pre-populated..."
  if [ -d "${MARIADB_DATADIR_DEFAULT}/test" ]; then
    rm -rf "${MARIADB_DATADIR_DEFAULT:?}"/*
  fi

  log "Initialising MariaDB data directory..."
  mysql_install_db --user=mysql --datadir="${MARIADB_DATADIR}"

  log "Starting MariaDB service..."
  systemctl enable --now mariadb

  log "Waiting for MariaDB to accept connections on port ${DB_PORT}..."
  local timeout=60
  local elapsed=0
  until mysql -u root -e "SELECT 1" &>/dev/null; do
    sleep 2
    elapsed=$(( elapsed + 2 ))
    [ "$elapsed" -ge "$timeout" ] && die "MariaDB did not become ready within ${timeout}s."
  done

  log "Securing MariaDB installation..."
  mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MARIADBROOTPASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

  log "Configuring GTID (current_pos)..."
  mysql -u root -p"${MARIADBROOTPASS}" \
    -e "CHANGE MASTER TO MASTER_USE_GTID = current_pos;"
}

# ─── USER CREATION ────────────────────────────────────────────────────────────
mysql_exec() {
  mysql -u root -p"${MARIADBROOTPASS}" --batch -e "$1"
}

create_users() {
  log "Creating service account: ${MARIADB_USER_BACKUP} (localhost, backup)..."
  mysql_exec "
    CREATE USER IF NOT EXISTS '${MARIADB_USER_BACKUP}'@'localhost'
      IDENTIFIED BY '${MARIADBBACKUPPASS}';
    GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT
      ON *.* TO '${MARIADB_USER_BACKUP}'@'localhost';
    FLUSH PRIVILEGES;
  "

  log "Creating service account: ${MARIADB_USER_MONITOR} (%, SSL)..."
  mysql_exec "
    CREATE USER IF NOT EXISTS '${MARIADB_USER_MONITOR}'@'%'
      IDENTIFIED BY '${MARIADBMONITORPASS}' REQUIRE SSL;
    GRANT SELECT, SUPER, REPLICATION CLIENT, RELOAD, PROCESS, SHOW DATABASES, EVENT
      ON *.* TO '${MARIADB_USER_MONITOR}'@'%';
    FLUSH PRIVILEGES;
  "

  log "Creating service account: ${MARIADB_USER_METRIC} (localhost)..."
  mysql_exec "
    CREATE USER IF NOT EXISTS '${MARIADB_USER_METRIC}'@'localhost'
      IDENTIFIED BY '${MARIADBMETRICPASS}';
    GRANT USAGE ON *.* TO '${MARIADB_USER_METRIC}'@'localhost';
    FLUSH PRIVILEGES;
  "

  log "Creating ServiceNow application user: ${SNOWDBUSER} (%, SSL)..."
  mysql_exec "
    CREATE USER IF NOT EXISTS '${SNOWDBUSER}'@'%'
      IDENTIFIED BY '${SNOWDBPASS}' REQUIRE SSL;
    GRANT
      ALTER, ALTER ROUTINE, CREATE, CREATE TABLESPACE, CREATE TEMPORARY TABLES,
      CREATE VIEW, DELETE, DROP, EVENT, EXECUTE, INDEX, INSERT, LOCK TABLES,
      PROCESS, REFERENCES, RELOAD, SELECT, SHOW DATABASES, SHOW VIEW,
      TRIGGER, UPDATE
      ON *.* TO '${SNOWDBUSER}'@'%';
    FLUSH PRIVILEGES;
  "
}

# ─── BACKUP SCRIPTS ───────────────────────────────────────────────────────────
deploy_backup_scripts() {
  log "Deploying backup scripts to ${MARIADB_SCRIPTDIR}..."
  for script in mdbBackupFull.sh mdbBackupIncr.sh mdbCleanup.sh; do
    cp "${SCRIPTS_DIR}/${script}" "${MARIADB_SCRIPTDIR}/${script}"
    chown mysql:mysql "${MARIADB_SCRIPTDIR}/${script}"
    chmod 700 "${MARIADB_SCRIPTDIR}/${script}"
  done
}

# ─── CRON SETUP ───────────────────────────────────────────────────────────────
setup_cron() {
  log "Configuring backup cron jobs in /etc/cron.d/mdbcor..."
  cat > /etc/cron.d/mdbcor <<EOF
MAILTO=""
# Full backup — every Sunday at 00:01
1 0 * * Sun root ${MARIADB_SCRIPTDIR}/mdbBackupFull.sh --backup_dir=${BACKUP_DIR} --number_of_mountpoint=1 --log_dir=${MARIADB_LOGDIR} --replication_enabled=false
# Incremental backup — every hour Mon–Sat
1 1-23 * * * root ${MARIADB_SCRIPTDIR}/mdbBackupIncr.sh --backup_dir=${BACKUP_DIR} --number_of_mountpoint=1 --log_dir=${MARIADB_LOGDIR} --replication_enabled=false
# Cleanup — every Sunday at 00:45
45 0 * * Sun root ${MARIADB_SCRIPTDIR}/mdbCleanup.sh --backup_dir=${BACKUP_DIR} --log_dir=${MARIADB_LOGDIR} --days_to_keep=${BACKUP_RETENTION}
EOF
  chmod 600 /etc/cron.d/mdbcor
  systemctl restart crond
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
  check_root
  load_env
  validate

  log "Starting MariaDB ${APP_VERSION} standalone deployment."
  log "Install dir : ${INSTALL_DIR}"
  log "Port        : ${DB_PORT}"
  log "SSL         : ${SSL_ENABLED}"
  log "Backup dir  : ${BACKUP_DIR}"

  configure_system
  install_packages
  create_directories
  setup_systemd
  deploy_configs
  setup_ssl
  init_database
  create_users
  deploy_backup_scripts
  setup_cron

  log "Deployment complete. MariaDB ${APP_VERSION} is running on port ${DB_PORT}."
}

main
