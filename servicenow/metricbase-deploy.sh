#!/bin/bash
# Deploy ServiceNow MetricBase (Clotho) on RHEL 9 / Rocky Linux 9.
#
# The installer creates <install_dir>/<node_name>_<port>/ (e.g. /glide/clotho/mydb_3400/).
# All MetricBase files (startup.sh, conf/, data/, logs/) live under that node directory.
# Optionally configures HA replication with a peer node, creates initial
# admin and backup users, and schedules backup cron jobs:
#   - Weekly full backup  (Sunday 02:00)
#   - Differential backup every N hours (configurable, default 6)
#
# Reference KB: KB0677442 – MetricBase Installation Instructions
set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
INSTALL_DIR="/glide/clotho"
JAVA_DIR="/glide/java"
MEDIA_DIR="/glide/media"
FULL_BACKUP_DIR="/glide/backup/metricbase/full"
DIFF_BACKUP_DIR="/glide/backup/metricbase/diff"
DIFF_INTERVAL="6"
DIST_ZIP=""
JDK_TARBALL=""
NODE_NAME=""
PORT="3400"
CLOTHO_USER="clotho"
MB_ADMIN_USER="admin"
MB_ADMIN_PASSWORD=""
MB_BACKUP_USER="dbi_backup"
MB_BACKUP_PASSWORD=""
HEAP_SIZE="8"
PEER_HOST=""
PEER_PORT=""
REPLICATION_USER="repuser"
REPLICATION_PASSWORD=""
ENABLE_HAPROXY="false"
CERT_FILE=""
KEY_FILE=""
HAPROXY_BIND_PORT="443"
HAPROXY_STAT_PORT="8000"
SKIP_DEPS="false"
SKIP_SELINUX="false"

# Derived — set in validate_args / runtime
MB_VERSION=""
NODE_DIR=""
SYSTEMD_UNIT_CHANGED="false"

# ── USAGE ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOUSAGE

  USAGE: $0 [OPTIONS]

  Required:
    --dist_zip=<file>               clotho-dist-<version>-dist.zip filename in media_dir
    --jdk_tarball=<file>            JDK 17 tarball filename in media_dir
    --mb_admin_password=<password>  Initial MetricBase admin user password
    --mb_backup_password=<password> MetricBase backup user password

  Optional:
    --install_dir=<path>            MetricBase install directory           (default: /glide/clotho)
    --media_dir=<path>              Directory containing installer and JDK (default: /glide/media)
    --full_backup_dir=<path>        Full backup destination                (default: /glide/backup/metricbase/full)
    --diff_backup_dir=<path>        Differential backup destination        (default: /glide/backup/metricbase/diff)
    --diff_interval=<hours>         Differential backup interval in hours  (default: 6)
    --node_name=<name>              MetricBase server name                 (default: hostname -s)
    --port=<port>                   MetricBase listener port               (default: 3400)
    --mb_admin_user=<user>          Admin username                         (default: admin)
    --mb_backup_user=<user>         Backup username                        (default: dbi_backup)
    --heap_size=<GB>                Max JVM heap in GB                     (default: 8)
    --peer_host=<host>              HA peer hostname or IP (enables HA replication when set)
    --peer_port=<port>              HA peer MetricBase port                (default: same as --port)
    --replication_user=<user>       Replication account username           (default: repuser)
    --replication_password=<pw>     Replication account password           (required if --peer_host set)
    --enable_haproxy                 Install and configure HAProxy TLSv1.3 frontend
    --cert_file=<file>              TLS certificate filename (PEM) in media_dir (required if --enable_haproxy)
    --key_file=<file>               TLS private key filename (PEM) in media_dir  (required if --enable_haproxy)
    --haproxy_bind_port=<port>      HAProxy HTTPS frontend port                  (default: 443)
    --haproxy_stat_port=<port>      HAProxy stats page port (loopback)           (default: 8000)
    --skip_deps                     Skip OS dependency installation
    --skip_selinux                  Skip SELinux port labeling
    --help                          Show this help

  Prerequisites in --media_dir (default: /glide/media):
    - clotho-dist-<version>.zip         MetricBase distribution zip
    - <jdk_tarball>                     JDK 17 tarball (e.g. jdk-17.0.x_linux-x64_bin.tar.gz)
    - metricbase-backup.sh              Backup script (installed to <node_dir>/bin/)
    - <cert_file> + <key_file>          TLS cert/key PEM files (required if --enable_haproxy)

  Notes:
    - Must be run as root
    - Target OS: RHEL 9 / Rocky Linux 9
    - Node directory: <install_dir>/<node_name>_<port>/ (e.g. /glide/clotho/mydb_3400/)
    - For HA, run this script on both nodes pointing --peer_host at the other
    - HAProxy terminates TLS on :443; MetricBase runs plain HTTP on localhost:<port>

  Example (standalone, no TLS):
    $0 --dist_zip=clotho-dist-25.1.0.15.zip \\
       --jdk_tarball=jdk-17.0.11_linux-x64_bin.tar.gz \\
       --mb_admin_password=S3cur3Admin! \\
       --mb_backup_password=BackupP4ss!

  Example (with HAProxy TLS frontend):
    $0 --dist_zip=clotho-dist-25.1.0.15.zip \\
       --jdk_tarball=jdk-17.0.11_linux-x64_bin.tar.gz \\
       --mb_admin_password=S3cur3Admin! \\
       --mb_backup_password=BackupP4ss! \\
       --enable_haproxy \\
       --cert_file=metricbase.crt --key_file=metricbase.key

  Example (HA node A, peer is node-b, with HAProxy):
    $0 --dist_zip=clotho-dist-25.1.0.15.zip \\
       --jdk_tarball=jdk-17.0.11_linux-x64_bin.tar.gz \\
       --mb_admin_password=S3cur3Admin! \\
       --mb_backup_password=BackupP4ss! \\
       --peer_host=node-b --replication_password=ReplP4ss! \\
       --enable_haproxy \\
       --cert_file=metricbase.crt --key_file=metricbase.key

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

require_root() {
  [ "$(id -u)" -eq 0 ] || die "This script must be run as root."
}

# ── ARGUMENT PARSING ──────────────────────────────────────────────────────────
parse_args() {
  if [ $# -eq 0 ]; then
    usage
    exit 1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --install_dir=*)           INSTALL_DIR="${1#*=}" ;;
      --media_dir=*)             MEDIA_DIR="${1#*=}" ;;
      --full_backup_dir=*)       FULL_BACKUP_DIR="${1#*=}" ;;
      --diff_backup_dir=*)       DIFF_BACKUP_DIR="${1#*=}" ;;
      --diff_interval=*)         DIFF_INTERVAL="${1#*=}" ;;
      --dist_zip=*)              DIST_ZIP="${1#*=}" ;;
      --jdk_tarball=*)           JDK_TARBALL="${1#*=}" ;;
      --node_name=*)             NODE_NAME="${1#*=}" ;;
      --port=*)                  PORT="${1#*=}" ;;
      --mb_admin_user=*)         MB_ADMIN_USER="${1#*=}" ;;
      --mb_admin_password=*)     MB_ADMIN_PASSWORD="${1#*=}" ;;
      --mb_backup_user=*)        MB_BACKUP_USER="${1#*=}" ;;
      --mb_backup_password=*)    MB_BACKUP_PASSWORD="${1#*=}" ;;
      --heap_size=*)             HEAP_SIZE="${1#*=}" ;;
      --peer_host=*)             PEER_HOST="${1#*=}" ;;
      --peer_port=*)             PEER_PORT="${1#*=}" ;;
      --replication_user=*)      REPLICATION_USER="${1#*=}" ;;
      --replication_password=*)  REPLICATION_PASSWORD="${1#*=}" ;;
      --enable_haproxy)          ENABLE_HAPROXY="true" ;;
      --cert_file=*)             CERT_FILE="${1#*=}" ;;
      --key_file=*)              KEY_FILE="${1#*=}" ;;
      --haproxy_bind_port=*)     HAPROXY_BIND_PORT="${1#*=}" ;;
      --haproxy_stat_port=*)     HAPROXY_STAT_PORT="${1#*=}" ;;
      --skip_deps)               SKIP_DEPS="true" ;;
      --skip_selinux)            SKIP_SELINUX="true" ;;
      --help)                    usage; exit 0 ;;
      *) die "Unknown argument: $1. Run $0 --help for usage." ;;
    esac
    shift
  done
}

validate_args() {
  [ -n "${DIST_ZIP}" ]           || die "--dist_zip is required."
  [ -n "${JDK_TARBALL}" ]        || die "--jdk_tarball is required."
  [ -n "${MB_ADMIN_PASSWORD}" ]  || die "--mb_admin_password is required."
  [ -n "${MB_BACKUP_PASSWORD}" ] || die "--mb_backup_password is required."

  [ -f "${MEDIA_DIR}/${DIST_ZIP}" ]          || die "Distribution zip not found: ${MEDIA_DIR}/${DIST_ZIP}"
  [ -f "${MEDIA_DIR}/${JDK_TARBALL}" ]       || die "JDK tarball not found: ${MEDIA_DIR}/${JDK_TARBALL}"
  [ -f "${MEDIA_DIR}/metricbase-backup.sh" ] || die "metricbase-backup.sh not found: ${MEDIA_DIR}/metricbase-backup.sh"

  if [ -n "${PEER_HOST}" ]; then
    [ -n "${REPLICATION_PASSWORD}" ] \
      || die "--replication_password is required when --peer_host is set."
    [ -z "${PEER_PORT}" ] && PEER_PORT="${PORT}"
  fi

  [ -z "${NODE_NAME}" ] && NODE_NAME="$(hostname -s)"

  # Extract version from zip filename: clotho-dist-<version>.zip
  MB_VERSION=$(echo "${DIST_ZIP}" | sed 's/clotho-dist-\(.*\)\.zip/\1/')
  [ "${MB_VERSION}" = "${DIST_ZIP}" ] \
    && die "Cannot parse version from dist zip name: ${DIST_ZIP}. Expected: clotho-dist-<version>.zip"

  NODE_DIR="${INSTALL_DIR}/${NODE_NAME}_${PORT}"

  if [ "${ENABLE_HAPROXY}" = "true" ]; then
    [ -n "${CERT_FILE}" ] || die "--cert_file is required when --enable_haproxy is set."
    [ -n "${KEY_FILE}" ]  || die "--key_file is required when --enable_haproxy is set."
    [ -f "${MEDIA_DIR}/${CERT_FILE}" ] || die "Certificate file not found: ${MEDIA_DIR}/${CERT_FILE}"
    [ -f "${MEDIA_DIR}/${KEY_FILE}" ]  || die "Key file not found: ${MEDIA_DIR}/${KEY_FILE}"
  fi

  log "Resolved: version=${MB_VERSION}, node_dir=${NODE_DIR}"
}

# ── STEP 1: OS DEPENDENCIES ───────────────────────────────────────────────────
install_deps() {
  if [ "${SKIP_DEPS}" = "true" ]; then
    log "Skipping OS dependency installation (--skip_deps set)."
    return 0
  fi

  log "Installing OS dependencies..."
  dnf install -y curl glibc glibc.i686 libgcc
  [ "${ENABLE_HAPROXY}" = "true" ] && dnf install -y haproxy
  log "OS dependencies installed."
}

# ── STEP 2: INSTALL JDK ───────────────────────────────────────────────────────
install_jdk() {
  if [ -x "${JAVA_DIR}/bin/java" ]; then
    log "JDK already present at ${JAVA_DIR}, skipping extraction."
    export JAVA_HOME="${JAVA_DIR}"
    return 0
  fi

  log "Installing JDK from tarball: ${JDK_TARBALL}..."

  rm -rf "${JAVA_DIR:?}"
  mkdir -p "${JAVA_DIR}"
  tar -xf "${MEDIA_DIR}/${JDK_TARBALL}" -C "${JAVA_DIR}"

  local extracted_dir
  extracted_dir=$(ls -1 "${JAVA_DIR}" | head -1)

  if [ -n "${extracted_dir}" ] && [ -d "${JAVA_DIR}/${extracted_dir}" ]; then
    cp -r "${JAVA_DIR}/${extracted_dir}/." "${JAVA_DIR}/"
    rm -rf "${JAVA_DIR:?}/${extracted_dir}"
  fi

  echo "export JAVA_HOME=${JAVA_DIR}" > /etc/profile.d/jdk_JAVA_HOME.sh
  echo "export PATH=\$PATH:${JAVA_DIR}/bin" >> /etc/profile.d/jdk_JAVA_HOME.sh
  export JAVA_HOME="${JAVA_DIR}"

  log "JDK installed: $("${JAVA_DIR}/bin/java" -version 2>&1 | head -1)"
}

# ── STEP 3: OS SERVICE ACCOUNT ────────────────────────────────────────────────
create_user_group() {
  log "Ensuring ${CLOTHO_USER} service account exists..."
  getent group "${CLOTHO_USER}" >/dev/null 2>&1 \
    || groupadd --system "${CLOTHO_USER}"
  id -u "${CLOTHO_USER}" >/dev/null 2>&1 \
    || useradd --system --no-create-home \
               --gid "${CLOTHO_USER}" \
               --home-dir "${INSTALL_DIR}" \
               --shell /sbin/nologin \
               "${CLOTHO_USER}"
  log "Service account ready."
}

# ── STEP 4: INSTALL METRICBASE ────────────────────────────────────────────────
install_metricbase() {
  if [ -f "${NODE_DIR}/startup.sh" ]; then
    log "MetricBase already installed at ${NODE_DIR}, skipping installation."
    return 0
  fi

  log "Installing MetricBase ${MB_VERSION} as node '${NODE_NAME}' on port ${PORT}..."

  mkdir -p "${INSTALL_DIR}"

  # KB instructs: cd to the parent install dir; installer creates <node_name>_<port>/ inside it
  ( cd "${INSTALL_DIR}" && \
    "${JAVA_DIR}/bin/java" -jar "${MEDIA_DIR}/${DIST_ZIP}" \
      -m install \
      -n "${NODE_NAME}" \
      -p "${PORT}" )

  [ -f "${NODE_DIR}/startup.sh" ] \
    || die "Installation failed: startup.sh not found at ${NODE_DIR}."

  log "MetricBase installed at ${NODE_DIR}."
}

# ── STEP 5: FIX WRAPPER.CONF ──────────────────────────────────────────────────
fix_wrapper_conf() {
  local wrapper_conf="${NODE_DIR}/conf/wrapper.conf"

  [ -f "${wrapper_conf}" ] || { log "wrapper.conf not found, skipping fix."; return 0; }

  if grep -q "^wrapper.java.additional.*Djava.endorsed.dirs" "${wrapper_conf}"; then
    log "Commenting out -Djava.endorsed.dirs in wrapper.conf (not supported on JDK 17+)..."
    sed -i 's/^\(wrapper\.java\.additional.*Djava\.endorsed\.dirs.*\)/#\1/' "${wrapper_conf}"
    log "wrapper.conf patched."
  else
    log "wrapper.conf: -Djava.endorsed.dirs not present or already commented out."
  fi
}

# ── STEP 6: CONFIGURE JVM HEAP ────────────────────────────────────────────────
configure_heap() {
  local overrides_dir="${NODE_DIR}/conf/overrides.d"
  local mem_props="${overrides_dir}/92-memory.properties"

  mkdir -p "${overrides_dir}"

  if [ -f "${mem_props}" ] && grep -q "\-Xmx${HEAP_SIZE}G" "${mem_props}"; then
    log "Heap already set to ${HEAP_SIZE}G, skipping."
    return 0
  fi

  log "Setting max JVM heap to ${HEAP_SIZE}G..."

  if [ -f "${mem_props}" ]; then
    sed -i "s/-Xmx[0-9]*[gGmM]/-Xmx${HEAP_SIZE}G/" "${mem_props}"
  else
    cat > "${mem_props}" <<EOF
java.opts.snippet.nodeconfig.mem=-Xms128m -Xmx${HEAP_SIZE}G -XX:MaxMetaspaceSize=400m
EOF
  fi

  log "Heap configured: max ${HEAP_SIZE}G."
}

# ── STEP 7: CREATE METRICBASE USERS ───────────────────────────────────────────
create_mb_user() {
  local username="$1" password="$2" roles="$3"
  local passwd_file="${NODE_DIR}/conf/passwd"
  local add_user_script="${NODE_DIR}/scripts/add_app_user.sh"

  [ -f "${add_user_script}" ] || die "add_app_user.sh not found: ${add_user_script}"

  if grep -q "^${username}=" "${passwd_file}" 2>/dev/null; then
    log "MetricBase user '${username}' already exists in conf/passwd, skipping."
    return 0
  fi

  log "Creating MetricBase user '${username}' with roles: ${roles}..."
  printf '%s\n%s\n' "${password}" "${password}" \
    | "${add_user_script}" -u "${username}" -r "${roles}" >> "${passwd_file}"
  log "User '${username}' created."
}

create_metricbase_users() {
  create_mb_user "${MB_ADMIN_USER}" "${MB_ADMIN_PASSWORD}" "admin,monitor,user"
  create_mb_user "${MB_BACKUP_USER}" "${MB_BACKUP_PASSWORD}" "backup"
  if [ -n "${PEER_HOST}" ]; then
    create_mb_user "${REPLICATION_USER}" "${REPLICATION_PASSWORD}" "replication"
  fi
}

# ── STEP 8: HA REPLICATION ────────────────────────────────────────────────────
configure_ha() {
  [ -n "${PEER_HOST}" ] || return 0

  local overrides_dir="${NODE_DIR}/conf/overrides.d"
  local repl_props="${overrides_dir}/97-replication.properties"

  mkdir -p "${overrides_dir}"

  if [ -f "${repl_props}" ] && grep -q "clotho.replication.master=http://${PEER_HOST}:${PEER_PORT}" "${repl_props}"; then
    log "HA replication already configured for ${PEER_HOST}:${PEER_PORT}, skipping."
    return 0
  fi

  log "Configuring HA replication: peer=${PEER_HOST}:${PEER_PORT}..."

  cat > "${repl_props}" <<EOF
system.property.startup.clotho.read_only=false
system.property.startup.clotho.replication.active=true
system.property.startup.clotho.replication.master=http://${PEER_HOST}:${PEER_PORT}/replication
system.property.startup.clotho.replication.username=${REPLICATION_USER}
system.property.startup.clotho.replication.password=${REPLICATION_PASSWORD}
EOF

  chmod 640 "${repl_props}"
  log "Replication config written: ${repl_props}"
}

# ── STEP 9: SYSTEMD SERVICE ───────────────────────────────────────────────────
write_systemd_service() {
  local svc="metricbase"
  local svc_file="/etc/systemd/system/${svc}.service"
  local tmp_file; tmp_file=$(mktemp)

  cat > "${tmp_file}" <<EOF
[Unit]
Description=ServiceNow MetricBase (Clotho) - ${NODE_NAME}:${PORT}
After=syslog.target network.target

[Service]
Environment=JAVA_HOME=${JAVA_DIR}
Type=forking
ExecStart=${NODE_DIR}/startup.sh
ExecStop=${NODE_DIR}/shutdown.sh
User=${CLOTHO_USER}
Group=${CLOTHO_USER}
UMask=0007
TimeoutStartSec=120
TimeoutStopSec=60
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF

  if [ -f "${svc_file}" ] && diff -q "${svc_file}" "${tmp_file}" >/dev/null 2>&1; then
    log "Systemd service unchanged, skipping."
    rm -f "${tmp_file}"
    return 0
  fi

  mv "${tmp_file}" "${svc_file}"
  log "Systemd service written: ${svc_file}"
  SYSTEMD_UNIT_CHANGED="true"
}

# ── STEP 10: SELINUX PORT LABEL ───────────────────────────────────────────────
configure_selinux() {
  if [ "${SKIP_SELINUX}" = "true" ]; then
    log "Skipping SELinux configuration (--skip_selinux set)."
    return 0
  fi

  if ! command -v getenforce >/dev/null 2>&1 || [ "$(getenforce)" = "Disabled" ]; then
    return 0
  fi

  log "SELinux enforcing — labeling TCP/${PORT} as http_port_t..."

  label_port() {
    local p=$1 desc=$2
    if semanage port -l | grep -E "^http_port_t\s" | grep -qw "${p}"; then
      log "  TCP/${p} (${desc}) already labeled."
    else
      semanage port -a -t http_port_t -p tcp "${p}" \
        || semanage port -m -t http_port_t -p tcp "${p}"
      log "  Labeled TCP/${p} as http_port_t (${desc})."
    fi
  }

  label_port "${PORT}" "MetricBase"
  [ "${ENABLE_HAPROXY}" = "true" ] && [ "${HAPROXY_BIND_PORT}" != "443" ] \
    && label_port "${HAPROXY_BIND_PORT}" "HAProxy HTTPS"
}

# ── STEP 11: BACKUP SETUP ─────────────────────────────────────────────────────
setup_backup() {
  local password_file="${NODE_DIR}/conf/mb_backup_password.txt"
  local backup_script="${NODE_DIR}/bin/metricbase-backup.sh"
  local cron_file="/etc/cron.d/metricbase"

  if [ ! -f "${password_file}" ]; then
    log "Writing backup password file: ${password_file}..."
    echo "${MB_BACKUP_PASSWORD}" > "${password_file}"
    chmod 640 "${password_file}"
  else
    log "Backup password file already exists, skipping."
  fi

  mkdir -p "${NODE_DIR}/bin"
  if ! diff -q "${MEDIA_DIR}/metricbase-backup.sh" "${backup_script}" >/dev/null 2>&1; then
    log "Installing metricbase-backup.sh to ${NODE_DIR}/bin/..."
    cp "${MEDIA_DIR}/metricbase-backup.sh" "${backup_script}"
    chmod 755 "${backup_script}"
  else
    log "metricbase-backup.sh already up to date, skipping."
  fi

  mkdir -p "${FULL_BACKUP_DIR}" "${DIFF_BACKUP_DIR}"

  # Build cron hour list from interval (e.g. 6 → "0,6,12,18")
  local diff_hours=""
  local h=0
  while [ "${h}" -lt 24 ]; do
    diff_hours="${diff_hours:+${diff_hours},}${h}"
    h=$(( h + DIFF_INTERVAL ))
  done

  log "Configuring backup crons (full: weekly Sunday 02:00 | diff: every ${DIFF_INTERVAL}h)..."
  cat > "${cron_file}" <<EOF
MAILTO=""

# Weekly full MetricBase backup — Sunday at 02:00
0 2 * * 0 ${CLOTHO_USER} ${backup_script} --node_dir=${NODE_DIR} --port=${PORT} --password_file=${password_file} --type=full --full_backup_dir=${FULL_BACKUP_DIR} --diff_backup_dir=${DIFF_BACKUP_DIR} --log_dir=${NODE_DIR}/logs >> ${NODE_DIR}/logs/metricbase-backup.log 2>&1

# Differential MetricBase backup — every ${DIFF_INTERVAL} hours
0 ${diff_hours} * * * ${CLOTHO_USER} ${backup_script} --node_dir=${NODE_DIR} --port=${PORT} --password_file=${password_file} --type=diff --full_backup_dir=${FULL_BACKUP_DIR} --diff_backup_dir=${DIFF_BACKUP_DIR} --log_dir=${NODE_DIR}/logs >> ${NODE_DIR}/logs/metricbase-backup.log 2>&1
EOF

  chmod 644 "${cron_file}"
  log "Backup crons configured: ${cron_file}"
}

# ── STEP 12: FILE OWNERSHIP ───────────────────────────────────────────────────
set_ownership() {
  log "Setting ownership of ${NODE_DIR} to ${CLOTHO_USER}:${CLOTHO_USER}..."
  chown -R "${CLOTHO_USER}:${CLOTHO_USER}" "${NODE_DIR}"
  chmod -R 750 "${NODE_DIR}"
  log "Ownership set."
}

# ── STEP 13: ENABLE AND START ─────────────────────────────────────────────────
enable_start_service() {
  local svc="metricbase"

  systemctl daemon-reload
  systemctl enable "${svc}"

  if systemctl is-active --quiet "${svc}"; then
    if [ "${SYSTEMD_UNIT_CHANGED}" = "true" ]; then
      log "Restarting ${svc} service (unit file changed)..."
      systemctl restart "${svc}"
      log "${svc} service restarted."
    else
      log "${svc} service already running, no unit change — skipping restart."
    fi
  else
    log "Starting ${svc} service..."
    systemctl start "${svc}"
    log "${svc} service started."
  fi
}

# ── STEP 14: VERIFY ───────────────────────────────────────────────────────────
verify_service() {
  log "Waiting for MetricBase to respond on 127.0.0.1:${PORT}..."
  local attempt=0 max=24

  until curl -sf -o /dev/null -w "%{http_code}" \
      "http://127.0.0.1:${PORT}/" 2>/dev/null | grep -qE "^[2-4]"; do
    attempt=$(( attempt + 1 ))
    [ "${attempt}" -ge "${max}" ] \
      && die "MetricBase did not respond after $(( max * 10 ))s. Check: journalctl -u metricbase"
    if [ $(( attempt % 3 )) -eq 0 ]; then
      log "  Waiting for MetricBase... $(( attempt * 10 ))s elapsed."
    fi
    sleep 10
  done

  log "MetricBase is up on 127.0.0.1:${PORT}."
}

# ── STEP 15: HAPROXY (OPTIONAL) ───────────────────────────────────────────────
setup_haproxy_cert() {
  local cfg_dir="/etc/haproxy"
  log "Building combined PEM for HAProxy..."
  cat "${MEDIA_DIR}/${CERT_FILE}" "${MEDIA_DIR}/${KEY_FILE}" > "${cfg_dir}/metricbase-server.pem"
  chmod 600 "${cfg_dir}/metricbase-server.pem"
  log "Combined PEM written to ${cfg_dir}/metricbase-server.pem."
}

configure_haproxy() {
  local cfg_file="/etc/haproxy/haproxy.cfg"
  local ncpus; ncpus=$(nproc)
  local nbthread=$(( ncpus > 1 ? ncpus / 2 : 1 ))

  log "Configuring HAProxy (TLSv1.3 :${HAPROXY_BIND_PORT} → 127.0.0.1:${PORT})..."

  setup_haproxy_cert

  if [ -f "${cfg_file}" ]; then
    cp "${cfg_file}" "${cfg_file}.bak.$(date '+%Y%m%d%H%M%S')"
    log "Existing HAProxy config backed up."
  fi

  cat > "${cfg_file}" <<EOF
global
  nbthread              ${nbthread}
  cpu-map               auto:1/1-${nbthread} 0-$(( nbthread - 1 ))
  maxconn               50000
  log                   127.0.0.1 local2
  chroot                /var/lib/haproxy
  user                  haproxy
  group                 haproxy
  daemon
  tune.ssl.cachesize    100000
  tune.maxrewrite       4096
  stats                 socket /var/lib/haproxy/stats

  # Hardening: TLSv1.3 only, ECDHE ciphersuites
  ssl-default-bind-curves         secp384r1:secp521r1:prime256v1
  ssl-default-bind-options        ssl-min-ver TLSv1.3
  ssl-default-bind-ciphersuites   TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256
  ssl-default-server-options      ssl-min-ver TLSv1.3
  ssl-default-server-ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256

defaults
  mode                  http
  log                   global
  option                dontlognull
  option                http-server-close
  option                redispatch
  retries               3
  timeout http-request  30s
  timeout queue         1m
  timeout connect       5s
  timeout client        60s
  timeout server        300s
  timeout http-keep-alive 120s
  timeout check         10s
  timeout tunnel        10m
  timeout client-fin    10s
  timeout server-fin    10s

frontend stats
  bind                  127.0.0.1:${HAPROXY_STAT_PORT}
  mode                  http
  stats                 enable
  stats                 hide-version
  stats                 realm HAProxy\ Statistics
  stats                 show-node
  stats                 uri /stats
  stats                 refresh 30s

frontend metricbase-frontend
  bind                  0.0.0.0:${HAPROXY_BIND_PORT} ssl crt /etc/haproxy/metricbase-server.pem
  option                httplog
  option                forwardfor

  unique-id-format %[uuid()]
  unique-id-header X-Unique-ID
  log-tag metricbase
  log-format {\"timestamp\":\"%tr\",\"application\":\"metricbase\",\"client_ip\":\"%ci\",\"fe_name\":\"%f\",\"fe_ip\":\"%fi\",\"fe_port\":\"%fp\",\"fe_conn\":\"%fc\",\"be_name\":\"%b\",\"server_name\":\"%s\",\"server_ip\":\"%si\",\"server_port\":\"%sp\",\"srv_conn\":\"%sc\",\"http_method\":\"%HM\",\"http_proto\":\"https\",\"host\":\"%hrl\",\"http_uri\":\"%HU\",\"status_code\":\"%ST\",\"response_time\":\"%Tr\",\"bytes_read\":\"%B\",\"termination_state\":\"%ts\",\"active_conn\":\"%ac\",\"x-unique-id\":\"%ID\"}

  # LB health check endpoint answered directly by HAProxy
  acl is_be_healthy   path /hello
  acl backends_down   nbsrv(metricbase-backend) lt 1
  http-request return status 503 content-type "text/plain" string "down" if is_be_healthy backends_down
  http-request return status 200 content-type "text/plain" string "ok"   if is_be_healthy

  http-request          set-header X-Forwarded-Host  %[req.hdr(host)]
  http-request          set-header X-Forwarded-Proto https if { ssl_fc }
  http-request          set-header X-Forwarded-Proto http  if !{ ssl_fc }

  http-after-response   set-header Strict-Transport-Security "max-age=63072000; includeSubDomains;"
  http-after-response   replace-header Set-Cookie '(^((?!(?i)httponly).)*$)' "\1; HttpOnly"
  http-after-response   replace-header Set-Cookie '(^((?!(?i)secure).)*$)'   "\1; Secure"
  http-response         replace-header Location ^http://(.*)$ https://\1

  default_backend       metricbase-backend

backend metricbase-backend
  mode                  http
  balance               leastconn
  cookie                MBSERVERID insert indirect nocache httponly secure
  option                httpchk GET /
  server                metricbase1 127.0.0.1:${PORT} check cookie metricbase1

EOF

  log "Validating HAProxy configuration..."
  haproxy -c -f "${cfg_file}" || {
    local backup; backup=$(ls -t "${cfg_file}.bak."* 2>/dev/null | head -1 || true)
    [ -n "${backup}" ] && cp "${backup}" "${cfg_file}" && log "Config rolled back to ${backup}."
    die "HAProxy config invalid. Fix errors and re-run."
  }

  configure_rsyslog_haproxy
  configure_logrotate_haproxy

  systemctl restart rsyslog
  systemctl enable  haproxy
  systemctl restart haproxy

  log "HAProxy configured and started."
}

configure_rsyslog_haproxy() {
  cat > /etc/rsyslog.d/30-haproxy.conf <<'RSYSLOG'
module(load="imudp")
input(type="imudp" port="514")

$template HAProxyFmt,"%syslogtag%%msg:::drop-last-lf%\n"
$template TraditionalFmt,"%pri-text%: %timegenerated% %syslogtag%%msg:::drop-last-lf%\n"

local2.=info     /var/log/haproxy/access.log;HAProxyFmt
local2.notice    /var/log/haproxy/status.log;TraditionalFmt
local2.error     /var/log/haproxy/error.log;TraditionalFmt
local2.*         stop
RSYSLOG

  mkdir -p /var/log/haproxy
}

configure_logrotate_haproxy() {
  cat > /etc/logrotate.d/haproxy-metricbase <<'LOGROTATE'
/var/log/haproxy/*.log {
  daily
  rotate 30
  missingok
  notifempty
  compress
  sharedscripts
  postrotate
    /bin/kill -HUP $(cat /var/run/rsyslogd.pid 2>/dev/null) 2>/dev/null || true
  endscript
}
LOGROTATE
}

verify_haproxy() {
  log "Verifying HAProxy stats endpoint..."
  local attempt=0 max=6

  until curl -sf "http://127.0.0.1:${HAPROXY_STAT_PORT}/stats" >/dev/null 2>&1; do
    attempt=$(( attempt + 1 ))
    [ "${attempt}" -ge "${max}" ] \
      && die "HAProxy stats not reachable after $(( max * 5 ))s. Check: journalctl -u haproxy"
    sleep 5
  done

  log "HAProxy stats reachable at http://127.0.0.1:${HAPROXY_STAT_PORT}/stats"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  require_root
  validate_args

  log "============================================================"
  log "MetricBase Deployment"
  log "  Host        : $(hostname -f)"
  log "  Version     : ${MB_VERSION}"
  log "  Node name   : ${NODE_NAME}"
  log "  Port        : ${PORT}"
  log "  Node dir    : ${NODE_DIR}"
  log "  JDK         : ${JDK_TARBALL}"
  log "  Heap        : ${HEAP_SIZE}G"
  if [ -n "${PEER_HOST}" ]; then
    log "  HA peer     : ${PEER_HOST}:${PEER_PORT} (replication user: ${REPLICATION_USER})"
  else
    log "  HA peer     : none (standalone)"
  fi
  log "  Full backup : ${FULL_BACKUP_DIR} (weekly Sunday 02:00)"
  log "  Diff backup : ${DIFF_BACKUP_DIR} (every ${DIFF_INTERVAL}h)"
  if [ "${ENABLE_HAPROXY}" = "true" ]; then
    log "  HAProxy TLS : enabled (bind :${HAPROXY_BIND_PORT} → 127.0.0.1:${PORT})"
  fi
  log "============================================================"

  [ "${SKIP_DEPS}" = "true" ] && log "Skipping OS dependency installation (--skip_deps)." || install_deps
  install_jdk
  create_user_group
  install_metricbase
  fix_wrapper_conf
  configure_heap
  create_metricbase_users
  configure_ha
  write_systemd_service
  set_ownership
  configure_selinux
  setup_backup
  enable_start_service
  verify_service

  if [ "${ENABLE_HAPROXY}" = "true" ]; then
    configure_haproxy
    verify_haproxy
  fi

  log "============================================================"
  log "Deployment complete on $(hostname -f)"
  if [ "${ENABLE_HAPROXY}" = "true" ]; then
    log "  MetricBase URL : https://$(hostname -f):${HAPROXY_BIND_PORT}/"
    log "  HAProxy stats  : http://127.0.0.1:${HAPROXY_STAT_PORT}/stats"
  else
    log "  MetricBase URL : http://$(hostname -f):${PORT}/"
  fi
  log "  Admin info     : http://$(hostname -f):${PORT}/admin/info"
  log "  Service        : systemctl status metricbase"
  log "  Logs           : ${NODE_DIR}/logs/"
  if [ -n "${PEER_HOST}" ]; then
    log "  HA status      : http://$(hostname -f):${PORT}/replication"
  fi
  log ""
  log "  Next steps:"
  log "    1. Connect ServiceNow to this MetricBase endpoint via"
  log "       MetricBase → MetricBase Configuration → New"
  log "    2. Test connection using the 'Test Connection' link"
  if [ -n "${PEER_HOST}" ]; then
    log "    3. Verify HA replication at /replication (status should be 'streaming')"
  fi
  log "============================================================"
}

main "$@"
