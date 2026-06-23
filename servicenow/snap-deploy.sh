#!/bin/bash
# Deploy ServiceNow SNAP Server on RHEL 9.
# Supports three modes:
#   snap     – install SNAP + Tomcat + ClamAV (systemd, host-level; binds to localhost)
#   haproxy  – install/configure HAProxy (TLSv1.3) only
#   all      – install both on this VM (HAProxy :443 → localhost:SNAP_PORT)
#
# Deployment topology:
#   GCP Layer-4 load balancer (TCP passthrough)
#     ├─ VM 1: HAProxy :443 (TLSv1.3) → localhost:SNAP_PORT (Tomcat/SNAP)
#     └─ VM 2: HAProxy :443 (TLSv1.3) → localhost:SNAP_PORT (Tomcat/SNAP)
#
# SNAP runs as a WAR in Tomcat, which binds to 127.0.0.1 only.
# TLS is terminated at the co-located HAProxy.
# ClamAV (clamd + freshclam) runs as systemd services on each VM.
# The GCP L4 LB distributes TCP connections across the VM pool.
#
# Future: container/GKE support (set MODE=container, not yet implemented)
#
# Reference KBs:
#   KB1632909 – Load balancer considerations for Self-Hosted Instances
set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
JDK_DIR="/glide/java"                  # JDK installation directory
TOMCAT_INSTALL_DIR="/glide/tomcat"     # Tomcat installation root
SNAP_PORT="8080"                       # Tomcat HTTP port (127.0.0.1 only)
CERT_FILE=""
KEY_FILE=""
HAPROXY_BIND_PORT="443"
HAPROXY_STAT_PORT="9998"
BACKEND_NODES=""                       # resolved to 127.0.0.1:SNAP_PORT in validate_args
MODE="all"
SNAP_USER="snapserver"
SNAP_GROUP="snapserver"
SNAP_SVC="tomcat"
SNAP_HEALTH_PATH="/snap/healthcheck"   # Tomcat context path for health checks
MEDIA_DIR="/glide/media"
JDK_TARBALL=""
TOMCAT_TARBALL=""
SNAP_WAR=""                            # snap.tar.gz filename in MEDIA_DIR
JAVA_HEAP_XMX="2g"
CLAMAV_DIR="/glide/clamav"
CLAMAV_VERSION=""                      # optional; e.g. "1.0.7" installs clamav-1.0.7
FRESHCLAM_DB_MIRROR="database.clamav.net"
SKIP_DEPS="false"
SKIP_SELINUX="false"
SKIP_FRESHCLAM="false"
CLAMAV_DB_SRC="/var/lib/clamav"        # source dir when --skip_freshclam is set

# ── USAGE ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOUSAGE

  USAGE: $0 [OPTIONS]

  Required (mode=snap or mode=all):
    --jdk_tarball=<file>         JDK tarball filename in media_dir
    --tomcat_tarball=<file>      Tomcat tarball filename in media_dir
    --snap_war=<file>            SNAP WAR filename (snap.tar.gz) in media_dir
    --cert_file=<file>           TLS certificate filename (PEM) in media_dir
    --key_file=<file>            TLS private key filename (PEM) in media_dir
                                 (cert/key required for mode=haproxy or mode=all)

  Optional:
    --mode=<snap|haproxy|all>    Deployment mode                        (default: all)
    --jdk_dir=<path>             JDK installation directory             (default: /glide/java)
    --tomcat_dir=<path>          Tomcat installation directory          (default: /glide/tomcat)
    --port=<port>                Tomcat HTTP port (localhost only)      (default: 8080)
    --media_dir=<path>           Directory containing tarballs          (default: /glide/media)
    --java_heap_xmx=<size>       Tomcat JVM max heap (-Xmx)            (default: 2g)
    --clamav_dir=<path>          ClamAV data/config/log base directory (default: /glide/clamav)
    --clamav_version=<ver>       ClamAV package version suffix          (default: none)
    --freshclam_mirror=<url>     Freshclam database mirror URL          (default: database.clamav.net)
    --haproxy_bind_port=<port>   HAProxy HTTPS frontend port            (default: 443)
    --haproxy_stat_port=<port>   HAProxy stats page port (loopback)     (default: 9998)
    --tomcat_svc=<name>          Tomcat systemd service name            (default: tomcat)
    --tomcat_user=<name>         OS user and group that owns Tomcat     (default: snapserver)
    --skip_deps                  Skip dnf package installation          (default: false)
                                 Use in offline environments where packages are pre-installed
    --skip_selinux               Skip SELinux port labeling             (default: false)
    --skip_freshclam             Skip freshclam database download       (default: false)
                                 Copies main.cvd, daily.cvd, bytecode.cvd from clamav_db_src
                                 instead. Use in offline environments with clamav-data installed.
    --clamav_db_src=<path>       Source directory for CVD files         (default: /var/lib/clamav)
                                 Used only when --skip_freshclam is set
    --help                       Show this help

  Modes:
    snap     Install JDK, Tomcat + SNAP WAR, and ClamAV.
             Tomcat binds to 127.0.0.1 — not reachable externally.
    haproxy  Install/configure HAProxy TLSv1.3 frontend only.
             Routes to 127.0.0.1:PORT on the same VM.
    all      Install everything on this VM (standard deployment mode).
             HAProxy :${HAPROXY_BIND_PORT} (TLSv1.3) → 127.0.0.1:PORT (Tomcat)

  Notes:
    - Must be run as root
    - Target OS: RHEL 9
    - JDK extracted from tarball into <jdk_dir>/java (not the system JDK)
    - SNAP WAR (snap.tar.gz) is extracted into Tomcat's webapps/ directory
    - Tomcat binds to 127.0.0.1 only; SNAP port is NOT opened in firewalld
    - ClamAV: clamd and clamav-freshclam run as systemd services
    - clamav-scan and clamav-reputation are NOT configured by this script
    - SELinux port labels are applied when SELinux is enforcing
    - Run this script independently on each VM

  Deployment topology:
    GCP Layer-4 TCP load balancer distributes connections across VMs.
    Run this script (--mode=all) on every VM in the pool:

    $0 --mode=all \\
       --jdk_tarball=jdk-21.0.x_linux-x64_bin.tar.gz \\
       --tomcat_tarball=apache-tomcat-10.x.x.tar.gz \\
       --snap_war=snap.tar.gz \\
       --cert_file=/data/snap.crt --key_file=/data/snap.key \\
       --media_dir=/glide/media \\
       --clamav_dir=/glide/clamav \\
       --freshclam_mirror=https://mirror.example.com/clamav

    GCP L4 LB
      ├─ VM 1  HAProxy :${HAPROXY_BIND_PORT} → 127.0.0.1:8080 (Tomcat/SNAP) + ClamAV
      └─ VM 2  HAProxy :${HAPROXY_BIND_PORT} → 127.0.0.1:8080 (Tomcat/SNAP) + ClamAV

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
      --mode=*)               MODE="${1#*=}" ;;
      --jdk_dir=*)            JDK_DIR="${1#*=}" ;;
      --tomcat_dir=*)         TOMCAT_INSTALL_DIR="${1#*=}" ;;
      --port=*)               SNAP_PORT="${1#*=}" ;;
      --cert_file=*)          CERT_FILE="${1#*=}" ;;
      --key_file=*)           KEY_FILE="${1#*=}" ;;
      --media_dir=*)          MEDIA_DIR="${1#*=}" ;;
      --jdk_tarball=*)        JDK_TARBALL="${1#*=}" ;;
      --tomcat_tarball=*)     TOMCAT_TARBALL="${1#*=}" ;;
      --snap_war=*)           SNAP_WAR="${1#*=}" ;;
      --java_heap_xmx=*)      JAVA_HEAP_XMX="${1#*=}" ;;
      --clamav_dir=*)         CLAMAV_DIR="${1#*=}" ;;
      --clamav_version=*)     CLAMAV_VERSION="${1#*=}" ;;
      --freshclam_mirror=*)   FRESHCLAM_DB_MIRROR="${1#*=}" ;;
      --haproxy_bind_port=*)  HAPROXY_BIND_PORT="${1#*=}" ;;
      --haproxy_stat_port=*)  HAPROXY_STAT_PORT="${1#*=}" ;;
      --tomcat_svc=*)         SNAP_SVC="${1#*=}" ;;
      --tomcat_user=*)        SNAP_USER="${1#*=}"; SNAP_GROUP="${1#*=}" ;;
      --skip_deps)            SKIP_DEPS="true" ;;
      --skip_selinux)         SKIP_SELINUX="true" ;;
      --skip_freshclam)       SKIP_FRESHCLAM="true" ;;
      --clamav_db_src=*)      CLAMAV_DB_SRC="${1#*=}" ;;
      --help)                 usage; exit 0 ;;
      *) die "Unknown argument: $1. Run $0 --help for usage." ;;
    esac
    shift
  done
}

validate_args() {
  case "${MODE}" in
    snap|haproxy|all) ;;
    *) die "--mode must be 'snap', 'haproxy', or 'all'." ;;
  esac

  if [ "${MODE}" = "snap" ] || [ "${MODE}" = "all" ]; then
    [ -n "${JDK_TARBALL}" ]     || die "--jdk_tarball is required for mode=${MODE}."
    [ -f "${MEDIA_DIR}/${JDK_TARBALL}" ] \
      || die "JDK tarball not found: ${MEDIA_DIR}/${JDK_TARBALL}"

    [ -n "${TOMCAT_TARBALL}" ]  || die "--tomcat_tarball is required for mode=${MODE}."
    [ -f "${MEDIA_DIR}/${TOMCAT_TARBALL}" ] \
      || die "Tomcat tarball not found: ${MEDIA_DIR}/${TOMCAT_TARBALL}"

    [ -n "${SNAP_WAR}" ]        || die "--snap_war is required for mode=${MODE}."
    [ -f "${MEDIA_DIR}/${SNAP_WAR}" ] \
      || die "SNAP WAR not found: ${MEDIA_DIR}/${SNAP_WAR}"

    JAVA_DIR="${JDK_DIR}"
  fi

  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    [ -n "${CERT_FILE}" ] || die "--cert_file is required for mode=${MODE}."
    [ -f "${MEDIA_DIR}/${CERT_FILE}" ] || die "Certificate file not found: ${MEDIA_DIR}/${CERT_FILE}"
    [ -n "${KEY_FILE}" ]  || die "--key_file is required for mode=${MODE}."
    [ -f "${MEDIA_DIR}/${KEY_FILE}" ]  || die "Key file not found: ${MEDIA_DIR}/${KEY_FILE}"
  fi

  # HAProxy always routes to the co-located Tomcat instance on this VM.
  if [ -z "${BACKEND_NODES}" ]; then
    BACKEND_NODES="127.0.0.1:${SNAP_PORT}"
  fi
}

# ── STEP 1: OS DEPENDENCIES ───────────────────────────────────────────────────
install_deps() {
  if [ "${SKIP_DEPS}" = "true" ]; then
    log "Skipping dependency installation (--skip_deps set; assumes packages are pre-installed)."
    return 0
  fi

  log "Installing OS dependencies for RHEL 9..."

  # curl is needed for health checks; clamav packages come from EPEL
  dnf install -y curl

  if [ "${MODE}" = "snap" ] || [ "${MODE}" = "all" ]; then
    # ClamAV packages; version suffix applied when CLAMAV_VERSION is set
    local clam_suffix=""
    [ -n "${CLAMAV_VERSION}" ] && clam_suffix="-${CLAMAV_VERSION}"
    dnf install -y \
      "clamav${clam_suffix}" \
      "clamd${clam_suffix}" \
      "clamav-freshclam${clam_suffix}"
  fi

  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    dnf install -y haproxy
  fi

  log "OS dependencies installed."
}

# ── STEP 2: INSTALL JDK ───────────────────────────────────────────────────────
detect_jdk_major() {
  "${JAVA_DIR}/bin/java" -version 2>&1 | head -1 \
    | sed 's/.*version "\([0-9]*\)\..*/\1/;s/.*version "1\.\([0-9]*\)\..*/\1/'
}

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
  echo "export PATH=\$PATH:${JAVA_DIR}/bin" > /etc/profile.d/jdk_PATH.sh
  export JAVA_HOME="${JAVA_DIR}"

  log "JDK installed: $(${JAVA_DIR}/bin/java -version 2>&1 | head -1)"
}

# ── STEP 3: SERVICE ACCOUNT ───────────────────────────────────────────────────
create_user_group() {
  log "Ensuring ${SNAP_USER} service account exists..."
  getent group "${SNAP_GROUP}" >/dev/null 2>&1 \
    || groupadd --system "${SNAP_GROUP}"
  id -u "${SNAP_USER}" >/dev/null 2>&1 \
    || useradd --system --no-create-home \
               --gid "${SNAP_GROUP}" \
               --home-dir "${TOMCAT_INSTALL_DIR}" \
               --shell /sbin/nologin \
               "${SNAP_USER}"
  log "Service account ready."
}

# ── STEP 4: INSTALL TOMCAT ────────────────────────────────────────────────────
install_tomcat() {
  if [ -f "${TOMCAT_INSTALL_DIR}/bin/catalina.sh" ]; then
    log "Tomcat already present at ${TOMCAT_INSTALL_DIR}, skipping extraction."
    return 0
  fi

  log "Installing Tomcat from tarball: ${TOMCAT_TARBALL}..."

  rm -rf "${TOMCAT_INSTALL_DIR:?}"
  mkdir -p "${TOMCAT_INSTALL_DIR}"
  tar -xf "${MEDIA_DIR}/${TOMCAT_TARBALL}" -C "${TOMCAT_INSTALL_DIR}"

  local extracted_dir
  extracted_dir=$(ls -1 "${TOMCAT_INSTALL_DIR}" | head -1)
  if [ -n "${extracted_dir}" ] && [ -d "${TOMCAT_INSTALL_DIR}/${extracted_dir}" ]; then
    cp -r "${TOMCAT_INSTALL_DIR}/${extracted_dir}/." "${TOMCAT_INSTALL_DIR}/"
    rm -rf "${TOMCAT_INSTALL_DIR:?}/${extracted_dir}"
  fi

  chown -R "${SNAP_USER}:${SNAP_GROUP}" "${TOMCAT_INSTALL_DIR}"
  chmod +x "${TOMCAT_INSTALL_DIR}"/bin/*.sh

  log "Tomcat installed at ${TOMCAT_INSTALL_DIR}."
}

# ── STEP 5: DEPLOY SNAP WAR ───────────────────────────────────────────────────
deploy_snap_war() {
  local webapps="${TOMCAT_INSTALL_DIR}/webapps"
  mkdir -p "${webapps}"

  # Derive the context name: snap.tar.gz → snap, snap.war → snap
  local snap_basename
  snap_basename="$(basename "${SNAP_WAR}" .tar.gz)"
  snap_basename="$(basename "${snap_basename}" .war)"

  # Idempotency: skip if a .war file or an expanded app directory already exists.
  if [ -f "${webapps}/${snap_basename}.war" ] || [ -d "${webapps}/${snap_basename}" ]; then
    log "SNAP already deployed (${snap_basename}.war or ${snap_basename}/) — skipping."
    return 0
  fi

  log "Deploying SNAP from ${SNAP_WAR}..."

  # Extract into webapps/. Tomcat deploys both .war files and expanded directories
  # from this folder — no renaming or conversion required.
  tar -xf "${MEDIA_DIR}/${SNAP_WAR}" -C "${webapps}"

  if [ -f "${webapps}/${snap_basename}.war" ]; then
    log "Extracted ${snap_basename}.war — Tomcat will deploy it on startup."
  elif [ -d "${webapps}/${snap_basename}" ]; then
    log "Extracted expanded ${snap_basename}/ — Tomcat will deploy it on startup."
  else
    die "After extracting ${SNAP_WAR}, neither ${snap_basename}.war nor ${snap_basename}/ was found in ${webapps}. Verify the archive structure."
  fi

  chown -R "${SNAP_USER}:${SNAP_GROUP}" "${webapps}"
  log "SNAP deployed to ${webapps}."
}

# ── STEP 6: CONFIGURE TOMCAT ──────────────────────────────────────────────────
configure_tomcat() {
  log "Configuring Tomcat (binding to 127.0.0.1:${SNAP_PORT})..."

  local server_xml="${TOMCAT_INSTALL_DIR}/conf/server.xml"

  # Bind the HTTP Connector to localhost only and set the configured port.
  # Matches the default Connector stanza generated by any Tomcat 9/10/11 tarball.
  sed -i \
    "s|<Connector port=\"[0-9]*\" protocol=\"HTTP/1.1\"|<Connector address=\"127.0.0.1\" port=\"${SNAP_PORT}\" protocol=\"HTTP/1.1\"|" \
    "${server_xml}"

  log "Tomcat server.xml updated."

  # Create systemd unit
  cat > "/etc/systemd/system/${SNAP_SVC}.service" <<EOF
[Unit]
Description=Apache Tomcat (ServiceNow SNAP)
Documentation=https://support.servicenow.com
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=${SNAP_USER}
Group=${SNAP_GROUP}
Environment="JAVA_HOME=${JAVA_DIR}"
Environment="CATALINA_HOME=${TOMCAT_INSTALL_DIR}"
Environment="CATALINA_BASE=${TOMCAT_INSTALL_DIR}"
Environment="CATALINA_OPTS=-Xmx${JAVA_HEAP_XMX}"
ExecStart=${TOMCAT_INSTALL_DIR}/bin/startup.sh
ExecStop=${TOMCAT_INSTALL_DIR}/bin/shutdown.sh
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SNAP_SVC}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  log "Tomcat systemd unit written."
}

# ── STEP 7: CONFIGURE CLAMAV ──────────────────────────────────────────────────
configure_clamd() {
  log "Writing clamd configuration..."

  local conf_dir="${CLAMAV_DIR}/conf"
  local data_dir="${CLAMAV_DIR}/data"
  local log_dir="${CLAMAV_DIR}/log"

  mkdir -p \
    "${conf_dir}" \
    "${data_dir}/infected" \
    "${data_dir}/tmp" \
    "${log_dir}"

  # Determine the clamav user; packages normally create it, fall back to root.
  local clam_user="clamav"
  id -u "${clam_user}" >/dev/null 2>&1 || clam_user="root"

  chown -R "${clam_user}:${clam_user}" "${CLAMAV_DIR}"

  cat > "${conf_dir}/clamd.conf" <<EOF
# clamd.conf — managed by snap-deploy.sh; do not edit manually

LogFile ${log_dir}/clamav.log
LogTime yes
LogRotate yes
ExtendedDetectionInfo yes

PidFile /var/run/clamd.pid
TemporaryDirectory ${data_dir}/tmp
DatabaseDirectory ${data_dir}

# Listen on loopback TCP and a Unix socket
LocalSocket ${data_dir}/clamd.socket
TCPSocket 3310
TCPAddr 127.0.0.1

StreamMaxLength 100M
User ${clam_user}

HeuristicAlerts yes
AlertBrokenExecutables yes
AlertBrokenMedia yes
AlertEncrypted yes
AlertEncryptedArchive yes
AlertEncryptedDoc yes
AlertOLE2Macros yes
AlertPhishingSSLMismatch yes
AlertPartitionIntersection yes
ArchiveBlockEncrypted yes
MaxScanTime 240000

# Do not double memory use on database reload
ConcurrentDatabaseReload no

ExcludePath ^/proc/
ExcludePath ^/sys/
ExcludePath ^/var/lib/docker/
ExcludePath ^${data_dir}/infected/
ExcludePath ^/mnt/
EOF

  # Create a systemd unit for clamd pointing to our config
  cat > /etc/systemd/system/clamd.service <<EOF
[Unit]
Description=ClamAV Daemon (clamd)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/sbin/clamd --config-file=${conf_dir}/clamd.conf
PIDFile=/var/run/clamd.pid
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=clamd

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  log "clamd.conf and systemd unit written."
}

configure_freshclam() {
  log "Writing freshclam configuration..."

  local conf_dir="${CLAMAV_DIR}/conf"
  local data_dir="${CLAMAV_DIR}/data"
  local log_dir="${CLAMAV_DIR}/log"
  local clam_user="clamav"
  id -u "${clam_user}" >/dev/null 2>&1 || clam_user="root"

  cat > "${conf_dir}/freshclam.conf" <<EOF
# freshclam.conf — managed by snap-deploy.sh; do not edit manually

DatabaseDirectory ${data_dir}
UpdateLogFile ${log_dir}/freshclam.log
LogTime yes
LogVerbose yes
LogFileMaxSize 10M
LogRotate yes
PidFile /var/run/freshclam.pid

DatabaseOwner ${clam_user}
DNSDatabaseInfo no
DatabaseMirror ${FRESHCLAM_DB_MIRROR}

# Check for updates twice daily
Checks 12

# Notify clamd to reload after a database update
NotifyClamd ${conf_dir}/clamd.conf
EOF

  # Override the package-supplied freshclam service to use our config file.
  local override_dir="/etc/systemd/system/clamav-freshclam.service.d"
  mkdir -p "${override_dir}"
  cat > "${override_dir}/snap-config.conf" <<EOF
[Service]
ExecStartPre=/bin/bash -c 'lsof -t ${log_dir}/freshclam.log | xargs -r kill -9'
ExecStart=
ExecStart=/usr/bin/freshclam -d --foreground=true --config-file=${conf_dir}/freshclam.conf
EOF

  systemctl daemon-reload
  log "freshclam.conf and service override written."
}

# ── STEP 8: SELINUX PORT LABELS ───────────────────────────────────────────────
configure_selinux() {
  if [ "${SKIP_SELINUX}" = "true" ]; then
    log "Skipping SELinux configuration (--skip_selinux set)."
    return 0
  fi

  if ! command -v getenforce >/dev/null 2>&1 || [ "$(getenforce)" = "Disabled" ]; then
    return 0
  fi

  log "SELinux enforcing — labeling ports as http_port_t..."

  label_port() {
    local port=$1 desc=$2
    if semanage port -l | grep -E "^http_port_t\s" | grep -qw "${port}"; then
      log "  TCP/${port} (${desc}) already labeled."
    else
      semanage port -a -t http_port_t -p tcp "${port}" \
        || semanage port -m -t http_port_t -p tcp "${port}"
      log "  Labeled TCP/${port} as http_port_t (${desc})."
    fi
  }

  if [ "${MODE}" = "snap" ] || [ "${MODE}" = "all" ]; then
    label_port "${SNAP_PORT}" "Tomcat/SNAP"
  fi

  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    [ "${HAPROXY_BIND_PORT}" != "443" ] && label_port "${HAPROXY_BIND_PORT}" "HAProxy HTTPS"
  fi
}

# ── STEP 9: FIREWALL ──────────────────────────────────────────────────────────
configure_firewall() {
  if ! systemctl is-active --quiet firewalld 2>/dev/null; then
    log "firewalld not active — skipping firewall configuration."
    return 0
  fi

  log "Updating firewalld rules..."

  # SNAP_PORT is NOT opened externally — Tomcat binds to 127.0.0.1 only.
  # Only the HAProxy frontend port needs an external rule.
  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    if firewall-cmd --permanent --query-port="${HAPROXY_BIND_PORT}/tcp" &>/dev/null; then
      log "  TCP/${HAPROXY_BIND_PORT} (HAProxy HTTPS) already open, skipping."
    else
      firewall-cmd --permanent --add-port="${HAPROXY_BIND_PORT}/tcp"
      log "  Opened TCP/${HAPROXY_BIND_PORT} (HAProxy HTTPS)."
    fi
  fi

  firewall-cmd --reload
  log "Firewall updated."
}

# ── STEP 10: START AND VERIFY TOMCAT ──────────────────────────────────────────
enable_tomcat() {
  log "Enabling and starting ${SNAP_SVC} service..."
  systemctl daemon-reload
  systemctl enable "${SNAP_SVC}"
  systemctl restart "${SNAP_SVC}"
  log "${SNAP_SVC} service started."
}

verify_tomcat() {
  log "Waiting for Tomcat to accept connections on 127.0.0.1:${SNAP_PORT}..."
  local attempt=0 max=18

  # Use -s (silent) without -f so any HTTP response — including 4xx/5xx while
  # the SNAP WAR is still being deployed — counts as Tomcat being up.
  until curl -s --max-time 5 "http://127.0.0.1:${SNAP_PORT}/" -o /dev/null 2>&1; do
    attempt=$(( attempt + 1 ))
    [ "${attempt}" -ge "${max}" ] \
      && die "Tomcat did not respond after $(( max * 5 ))s. Check: journalctl -u ${SNAP_SVC}"
    log "  Attempt ${attempt}/${max} — waiting 5s..."
    sleep 5
  done

  log "Tomcat is up on 127.0.0.1:${SNAP_PORT}."
}

# ── STEP 11: START AND VERIFY CLAMAV ──────────────────────────────────────────
enable_clamav() {
  log "Enabling and starting ClamAV services..."

  local data_dir="${CLAMAV_DIR}/data"
  local clam_user="clamav"
  id -u "${clam_user}" >/dev/null 2>&1 || clam_user="root"

  if [ "${SKIP_FRESHCLAM}" = "true" ]; then
    log "Offline mode: copying ClamAV database from ${CLAMAV_DB_SRC}..."
    for cvd in main.cvd daily.cvd bytecode.cvd; do
      [ -f "${CLAMAV_DB_SRC}/${cvd}" ] \
        || die "${cvd} not found in ${CLAMAV_DB_SRC}. Install the clamav-data package first."
      cp "${CLAMAV_DB_SRC}/${cvd}" "${data_dir}/${cvd}"
      log "  Copied ${cvd}."
    done
    chown -R "${clam_user}:${clam_user}" "${data_dir}"
  else
    # Online: freshclam must populate the database before clamd can start.
    systemctl enable clamav-freshclam
    systemctl restart clamav-freshclam

    log "Waiting for freshclam to complete initial database download..."
    local attempt=0 max=24
    until [ -f "${data_dir}/main.cvd" ] || [ -f "${data_dir}/main.cld" ]; do
      attempt=$(( attempt + 1 ))
      [ "${attempt}" -ge "${max}" ] \
        && die "freshclam did not populate the database after $(( max * 10 ))s. Check: journalctl -u clamav-freshclam"
      log "  Waiting for virus database... (${attempt}/${max})"
      sleep 10
    done
  fi

  systemctl enable clamd
  systemctl restart clamd
  log "ClamAV services started."
}

verify_clamav() {
  log "Verifying ClamAV services are active..."

  if [ "${SKIP_FRESHCLAM}" = "false" ]; then
    systemctl is-active --quiet clamav-freshclam \
      || die "clamav-freshclam is not running. Check: journalctl -u clamav-freshclam"
    log "  clamav-freshclam: active"
  fi

  systemctl is-active --quiet clamd \
    || die "clamd is not running. Check: journalctl -u clamd"
  log "  clamd: active"

  log "ClamAV is up."
}

# ── STEP 12: HAPROXY ──────────────────────────────────────────────────────────
setup_haproxy_cert() {
  local cfg_dir="/etc/haproxy"
  log "Building combined PEM for HAProxy..."
  cat "${MEDIA_DIR}/${CERT_FILE}" "${MEDIA_DIR}/${KEY_FILE}" > "${cfg_dir}/snap-server.pem"
  chmod 600 "${cfg_dir}/snap-server.pem"
  log "Combined PEM written to ${cfg_dir}/snap-server.pem."
}

configure_haproxy() {
  local cfg_file="/etc/haproxy/haproxy.cfg"
  local ncpus; ncpus=$(nproc)
  local nbthread=$(( ncpus > 1 ? ncpus / 2 : 1 ))

  log "Configuring HAProxy (TLSv1.3 :${HAPROXY_BIND_PORT} → ${BACKEND_NODES})..."

  setup_haproxy_cert

  if [ -f "${cfg_file}" ]; then
    cp "${cfg_file}" "${cfg_file}.bak.$(date '+%Y%m%d%H%M%S')"
    log "Existing config backed up."
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

  # Hardening: disable older TLS versions and weak ciphers
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

# Stats available on loopback only
frontend stats
  bind                  127.0.0.1:${HAPROXY_STAT_PORT}
  mode                  http
  stats                 enable
  stats                 hide-version
  stats                 realm HAProxy\ Statistics
  stats                 show-node
  stats                 uri /stats
  stats                 refresh 30s

frontend snap-frontend
  bind                  0.0.0.0:${HAPROXY_BIND_PORT} ssl crt /etc/haproxy/snap-server.pem
  option                httplog
  option                forwardfor

  ### Transaction ID ###
  unique-id-format %[uuid()]
  unique-id-header X-Unique-ID
  log-tag snap
  log-format {\"timestamp\":\"%tr\",\"application\":\"snap\",\"client_ip\":\"%ci\",\"fe_name\":\"%f\",\"fe_ip\":\"%fi\",\"fe_port\":\"%fp\",\"fe_conn\":\"%fc\",\"be_name\":\"%b\",\"server_name\":\"%s\",\"server_ip\":\"%si\",\"server_port\":\"%sp\",\"srv_conn\":\"%sc\",\"http_method\":\"%HM\",\"http_proto\":\"https\",\"host\":\"%hrl\",\"http_uri\":\"%HU\",\"status_code\":\"%ST\",\"response_time\":\"%Tr\",\"bytes_read\":\"%B\",\"request_cookie\":\"%CC\",\"response_cookie\":\"%CS\",\"termination_state\":\"%ts\",\"active_conn\":\"%ac\",\"retries\":\"%rc\",\"srv_queue\":\"%sq\",\"backend_queue\":\"%bq\",\"x-unique-id\":\"%ID\"}


  # Inform SNAP/Tomcat of the original request context (KB1632909)
  http-request          set-header X-Forwarded-Host  %[req.hdr(host)]
  http-request          set-header X-Forwarded-Proto https if { ssl_fc }
  http-request          set-header X-Forwarded-Proto http  if !{ ssl_fc }

  # HSTS — configured at the load balancer (KB1632909)
  http-after-response   set-header Strict-Transport-Security "max-age=63072000; includeSubDomains;"

  # Add HttpOnly and Secure flags to cookies not already bearing them (KB1632909)
  http-after-response   replace-header Set-Cookie '(^((?!(?i)httponly).)*$)' "\1; HttpOnly"
  http-after-response   replace-header Set-Cookie '(^((?!(?i)secure).)*$)'   "\1; Secure"

  # Rewrite http→https in any Location redirects from SNAP (KB1632909)
  http-response         replace-header Location ^http://(.*)$ https://\1

  default_backend       snap-backend

backend snap-backend
  mode                  http
  balance               leastconn

  # Session persistence via load balancer cookie (KB1632909)
  cookie                SNAPSERVERID insert indirect nocache httponly secure

  option                httpchk GET ${SNAP_HEALTH_PATH}

EOF

  local idx=1
  IFS=',' read -ra _nodes <<< "${BACKEND_NODES}"
  for _node in "${_nodes[@]}"; do
    echo "  server  snap${idx}  ${_node}  check cookie snap${idx}" >> "${cfg_file}"
    idx=$(( idx + 1 ))
  done
  echo "" >> "${cfg_file}"

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
  cat > /etc/logrotate.d/haproxy-snap <<'LOGROTATE'
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

  until curl -s "http://127.0.0.1:${HAPROXY_STAT_PORT}/stats" >/dev/null 2>&1; do
    attempt=$(( attempt + 1 ))
    [ "${attempt}" -ge "${max}" ] \
      && die "HAProxy stats not reachable. Check: journalctl -u haproxy"
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
  log "SNAP Server Deployment"
  log "  Host            : $(hostname -f)"
  log "  Mode            : ${MODE}"
  if [ "${MODE}" = "snap" ] || [ "${MODE}" = "all" ]; then
    log "  JDK             : ${JDK_TARBALL} (→ ${JAVA_DIR})"
    log "  Tomcat          : ${TOMCAT_TARBALL} (→ ${TOMCAT_INSTALL_DIR})"
    log "  SNAP WAR        : ${SNAP_WAR}"
    log "  Tomcat port     : 127.0.0.1:${SNAP_PORT} (HTTP, TLS terminated at HAProxy)"
    log "  Heap (Xmx)      : ${JAVA_HEAP_XMX}"
    log "  ClamAV dir      : ${CLAMAV_DIR}"
    log "  Freshclam mirror: ${FRESHCLAM_DB_MIRROR}"
  fi
  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    log "  HAProxy frontend: 0.0.0.0:${HAPROXY_BIND_PORT} (TLSv1.3)"
    log "  Backend nodes   : ${BACKEND_NODES}"
    log "  Stats           : 127.0.0.1:${HAPROXY_STAT_PORT}"
  fi
  log "============================================================"

  install_deps

  if [ "${MODE}" = "snap" ] || [ "${MODE}" = "all" ]; then
    install_jdk
    create_user_group
    install_tomcat
    deploy_snap_war
    configure_tomcat
    configure_clamd
    configure_freshclam
  fi

  configure_selinux
  configure_firewall

  if [ "${MODE}" = "snap" ] || [ "${MODE}" = "all" ]; then
    enable_tomcat
    verify_tomcat
    enable_clamav
    verify_clamav
  fi

  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    configure_haproxy
    verify_haproxy
  fi

  log "============================================================"
  log "Deployment complete on $(hostname -f)"
  if [ "${MODE}" = "snap" ] || [ "${MODE}" = "all" ]; then
    log "  Tomcat/SNAP   : curl http://127.0.0.1:${SNAP_PORT}${SNAP_HEALTH_PATH}"
    log "  clamd         : systemctl status clamd"
    log "  freshclam     : systemctl status clamav-freshclam"
  fi
  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    log "  HAProxy HTTPS : https://$(hostname -f):${HAPROXY_BIND_PORT}"
    log "  HAProxy stats : http://127.0.0.1:${HAPROXY_STAT_PORT}/stats"
    log ""
    log "  Verify TLS 1.3 enforcement:"
    log "    openssl s_client -connect $(hostname -f):${HAPROXY_BIND_PORT} -tls1_3"
    log ""
    log "  Add this VM's IP to the GCP Layer-4 load balancer backend group"
    log "  on port ${HAPROXY_BIND_PORT} to include it in the pool."
  fi
  log "============================================================"
}

main "$@"
