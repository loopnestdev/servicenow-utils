#!/bin/bash
# Deploy ServiceNow PARExport Server on RHEL 8 or RHEL 9.
# Supports three modes:
#   parexport  – install PARExport via vendor .bin or RPM (systemd, host-level)
#   haproxy    – install/configure HAProxy (TLSv1.3) only
#   all        – install both on this VM (HAProxy :443 → localhost:PAR_PORT)
#
# Deployment topology:
#   GCP Layer-4 load balancer (TCP passthrough)
#     ├─ VM 1: HAProxy :443 (TLSv1.3) → localhost:PAR_PORT (PARExport)
#     └─ VM 2: HAProxy :443 (TLSv1.3) → localhost:PAR_PORT (PARExport)
#
# PARExport install method: --parexport_bin (default, works on RHEL 8/9) or
# --parexport_rpm (RPM, native RHEL 8). TLS terminated at HAProxy.
#
# Reference KBs:
#   KB1632909 – Load balancer considerations for Self-Hosted Instances
#   KB0996068 – PARExport Server deployment guide
set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
# Fixed by the vendor package — not configurable
readonly INSTALL_DIR="/opt/par-export"
readonly PAR_USER="parexport"
readonly PAR_GROUP="parexport"
readonly PAR_SVC="parexport"

PAR_PORT="9999"                        # PARExport HTTP port
CERT_FILE=""
KEY_FILE=""
HAPROXY_BIND_PORT="443"
HAPROXY_STAT_PORT="8000"
BACKEND_NODES=""                       # resolved to 127.0.0.1:PAR_PORT in validate_args
MODE="all"
MEDIA_DIR="/glide/media"
PAREXPORT_BIN=""                       # .bin installer filename in MEDIA_DIR (default method)
PAREXPORT_RPM=""                       # RPM filename in MEDIA_DIR (alternative method)
SKIP_DEPS="false"
SKIP_SELINUX="false"

# ── USAGE ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOUSAGE

  USAGE: $0 [OPTIONS]

  Required (mode=parexport or mode=all) — choose one install method:
    --parexport_bin=<file>          PARExport .bin installer filename in media_dir (default)
    --parexport_rpm=<file>          PARExport RPM filename in media_dir (alternative)

  Required (mode=haproxy or mode=all):
    --cert_file=<file>              TLS certificate filename (PEM) in media_dir
    --key_file=<file>               TLS private key filename (PEM) in media_dir

  Optional:
    --mode=<parexport|haproxy|all>  Deployment mode                      (default: all)
    --port=<port>                   PARExport HTTP port                   (default: 9999)
    --media_dir=<path>              Directory containing installer        (default: /glide/media)
    --haproxy_bind_port=<port>      HAProxy HTTPS frontend port           (default: 443)
    --haproxy_stat_port=<port>      HAProxy stats page port (loopback)    (default: 8000)
    --skip_deps                     Skip dnf package installation         (default: false)
                                    Use in offline environments where packages are pre-installed
    --skip_selinux                  Skip SELinux port labeling            (default: false)
    --help                          Show this help

  Install methods:
    --parexport_bin   Runs the vendor .bin installer non-interactively. Temporarily
                      overrides /etc/redhat-release to RHEL 8 to bypass the installer's
                      OS check (RHEL 8/9 binaries are identical). Default method.
    --parexport_rpm   Installs the vendor RPM via dnf. Use on RHEL 8 where the RPM
                      is compatible without any OS override. Mutually exclusive with
                      --parexport_bin.

  Modes:
    parexport  Install PARExport only.
               PARExport binds to 0.0.0.0:PORT but that port is NOT opened
               in firewalld — HAProxy proxies internally via localhost.
    haproxy    Install/configure HAProxy TLSv1.3 frontend only.
               Routes to 127.0.0.1:PORT on the same VM.
    all        Install everything on this VM (standard deployment mode).
               HAProxy :${HAPROXY_BIND_PORT} (TLSv1.3) → 127.0.0.1:PORT (PARExport)

  Notes:
    - Must be run as root
    - Target OS: RHEL 8 or RHEL 9
    - PARExport install dir, OS user, and systemd service are fixed by the vendor package (/opt/par-export, parexport)
    - TLS is terminated at HAProxy; PARExport itself runs plain HTTP
    - PARExport port is NOT opened in firewalld (HAProxy proxies internally)
    - SELinux port labels are applied when SELinux is enforcing
    - Run this script independently on each VM

  Deployment topology:
    GCP Layer-4 TCP load balancer distributes connections across VMs.
    Run this script (--mode=all) on every VM in the pool:

    $0 --mode=all \\
       --parexport_bin=par-export-4.x.x-xxxxxxxx.bin \\   # or --parexport_rpm=<file>
       --cert_file=parexport.crt --key_file=parexport.key \\
       --media_dir=/glide/media

    GCP L4 LB
      ├─ VM 1  HAProxy :${HAPROXY_BIND_PORT} → 127.0.0.1:9999 (PARExport)
      └─ VM 2  HAProxy :${HAPROXY_BIND_PORT} → 127.0.0.1:9999 (PARExport)

  ServiceNow configuration (after deployment):
    glide.par.export.host = https://<load-balancer-host>:${HAPROXY_BIND_PORT}

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
      --port=*)               PAR_PORT="${1#*=}" ;;
      --cert_file=*)          CERT_FILE="${1#*=}" ;;
      --key_file=*)           KEY_FILE="${1#*=}" ;;
      --media_dir=*)          MEDIA_DIR="${1#*=}" ;;
      --parexport_bin=*)      PAREXPORT_BIN="${1#*=}" ;;
      --parexport_rpm=*)      PAREXPORT_RPM="${1#*=}" ;;
      --haproxy_bind_port=*)  HAPROXY_BIND_PORT="${1#*=}" ;;
      --haproxy_stat_port=*)  HAPROXY_STAT_PORT="${1#*=}" ;;
      --skip_deps)            SKIP_DEPS="true" ;;
      --skip_selinux)         SKIP_SELINUX="true" ;;
      --help)                 usage; exit 0 ;;
      *) die "Unknown argument: $1. Run $0 --help for usage." ;;
    esac
    shift
  done
}

validate_args() {
  case "${MODE}" in
    parexport|haproxy|all) ;;
    *) die "--mode must be 'parexport', 'haproxy', or 'all'." ;;
  esac

  if [ "${MODE}" = "parexport" ] || [ "${MODE}" = "all" ]; then
    [ -n "${PAREXPORT_BIN}" ] || [ -n "${PAREXPORT_RPM}" ] \
      || die "Either --parexport_bin or --parexport_rpm is required for mode=${MODE}."
    [ -z "${PAREXPORT_BIN}" ] || [ -z "${PAREXPORT_RPM}" ] \
      || die "--parexport_bin and --parexport_rpm are mutually exclusive."
    if [ -n "${PAREXPORT_BIN}" ]; then
      [ -f "${MEDIA_DIR}/${PAREXPORT_BIN}" ] \
        || die "PARExport installer not found: ${MEDIA_DIR}/${PAREXPORT_BIN}"
    else
      [ -f "${MEDIA_DIR}/${PAREXPORT_RPM}" ] \
        || die "PARExport RPM not found: ${MEDIA_DIR}/${PAREXPORT_RPM}"
    fi
  fi

  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    [ -n "${CERT_FILE}" ] || die "--cert_file is required for mode=${MODE}."
    [ -f "${MEDIA_DIR}/${CERT_FILE}" ] || die "Certificate file not found: ${MEDIA_DIR}/${CERT_FILE}"
    [ -n "${KEY_FILE}" ]  || die "--key_file is required for mode=${MODE}."
    [ -f "${MEDIA_DIR}/${KEY_FILE}" ]  || die "Key file not found: ${MEDIA_DIR}/${KEY_FILE}"
  fi

  if [ -z "${BACKEND_NODES}" ]; then
    BACKEND_NODES="127.0.0.1:${PAR_PORT}"
  fi
}

# ── STEP 1: OS DEPENDENCIES ───────────────────────────────────────────────────
install_deps() {
  if [ "${SKIP_DEPS}" = "true" ]; then
    log "Skipping dependency installation (--skip_deps set; assumes packages are pre-installed)."
    return 0
  fi

  log "Installing OS dependencies for RHEL 9..."

  dnf install -y curl

  if [ "${MODE}" = "parexport" ] || [ "${MODE}" = "all" ]; then
    # Required by PARExport's bundled Chromium for headless rendering
    dnf install -y \
      at-spi2-atk \
      gtk3 \
      libXScrnSaver \
      alsa-lib \
      mesa-libgbm \
      libxshmfence \
      libX11-xcb \
      nspr \
      nss \
      google-noto-sans-cjk-ttc-fonts
  fi

  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    dnf install -y haproxy
  fi

  log "OS dependencies installed."
}

# ── STEP 2: SERVICE ACCOUNT ───────────────────────────────────────────────────
create_user_group() {
  log "Ensuring ${PAR_USER} service account exists..."
  getent group "${PAR_GROUP}" >/dev/null 2>&1 \
    || groupadd --system "${PAR_GROUP}"
  id -u "${PAR_USER}" >/dev/null 2>&1 \
    || useradd --system --no-create-home \
               --gid "${PAR_GROUP}" \
               --home-dir "${INSTALL_DIR}" \
               --shell /sbin/nologin \
               "${PAR_USER}"
  log "Service account ready."
}

# ── STEP 3: INSTALL PAREXPORT ─────────────────────────────────────────────────
install_parexport() {
  if [ -f "${INSTALL_DIR}/par-export-server" ]; then
    log "PARExport already installed at ${INSTALL_DIR}, skipping."
    return 0
  fi

  if [ -n "${PAREXPORT_RPM}" ]; then
    _install_parexport_rpm
  else
    _install_parexport_bin
  fi

  [ -f "${INSTALL_DIR}/par-export-server" ] \
    || die "PARExport binary not found at ${INSTALL_DIR}/par-export-server after installation."

  log "PARExport installed at ${INSTALL_DIR}."
}

_install_parexport_rpm() {
  log "Installing PARExport from RPM: ${PAREXPORT_RPM}..."
  dnf install -y "${MEDIA_DIR}/${PAREXPORT_RPM}"
}

_install_parexport_bin() {
  log "Installing PARExport from .bin: ${PAREXPORT_BIN}..."

  local bin_path="${MEDIA_DIR}/${PAREXPORT_BIN}"
  chmod +x "${bin_path}"

  # Both the outer .bin wrapper and the inner .sh script read /etc/redhat-release
  # and reject RHEL 9 (allowlist covers "release 7" and "release 8" only).
  # The binaries are RHEL 9 compatible. Override the release file for the duration
  # of the install, restoring it before any error handling.
  local release_file="/etc/redhat-release"
  local orig_release
  orig_release=$(cat "${release_file}" 2>/dev/null || true)
  echo "Red Hat Enterprise Linux release 8.10 (Ootpa)" > "${release_file}"

  local install_rc=0
  printf 'Install\nyes\nyes\n' | "${bin_path}" || install_rc=$?

  if [ -n "${orig_release}" ]; then
    echo "${orig_release}" > "${release_file}"
  else
    rm -f "${release_file}"
  fi

  [ "${install_rc}" -eq 0 ] \
    || die "PARExport installer exited with code ${install_rc}. Check output above."
}

# ── STEP 4: CONFIGURE PAREXPORT ───────────────────────────────────────────────
configure_parexport() {
  log "Configuring /etc/sysconfig/parexport..."

  local sysconfig="/etc/sysconfig/parexport"
  [ -f "${sysconfig}" ] || touch "${sysconfig}"

  # Update existing key or append if absent. HAProxy terminates TLS so
  # HTTPS_ENABLED is false on the PARExport side.
  for kv in "IS_SNOWK8S=false" "PRODUCTION=true" "HTTPS_ENABLED=false"; do
    local key="${kv%%=*}" val="${kv#*=}"
    if grep -q "^${key}[[:space:]]*=" "${sysconfig}"; then
      sed -i "s|^${key}[[:space:]]*=.*|${key}=${val}|" "${sysconfig}"
    else
      echo "${key}=${val}" >> "${sysconfig}"
    fi
  done

  log "sysconfig configured (HTTPS_ENABLED=false; TLS terminated at HAProxy)."
}

# ── STEP 5: SELINUX PORT LABELS ───────────────────────────────────────────────
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

  if [ "${MODE}" = "parexport" ] || [ "${MODE}" = "all" ]; then
    label_port "${PAR_PORT}" "PARExport"
  fi

  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    [ "${HAPROXY_BIND_PORT}" != "443" ] && label_port "${HAPROXY_BIND_PORT}" "HAProxy HTTPS"
  fi
}

# ── STEP 6: FIREWALL ──────────────────────────────────────────────────────────
configure_firewall() {
  if ! systemctl is-active --quiet firewalld 2>/dev/null; then
    log "firewalld not active — skipping firewall configuration."
    return 0
  fi

  log "Updating firewalld rules..."

  # PAR_PORT is NOT opened externally — PARExport is reachable only via HAProxy.
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

# ── STEP 7: START AND VERIFY PAREXPORT ────────────────────────────────────────
enable_parexport() {
  log "Enabling and starting ${PAR_SVC} service..."
  systemctl daemon-reload
  systemctl enable "${PAR_SVC}"
  systemctl restart "${PAR_SVC}"
  log "${PAR_SVC} service started."
}

verify_parexport() {
  log "Waiting for PARExport to respond on 127.0.0.1:${PAR_PORT}/ping..."
  local attempt=0 max=12

  until curl -s --max-time 5 "http://127.0.0.1:${PAR_PORT}/ping" 2>/dev/null | grep -q "PONG"; do
    attempt=$(( attempt + 1 ))
    [ "${attempt}" -ge "${max}" ] \
      && die "PARExport did not respond after $(( max * 5 ))s. Check: journalctl -u ${PAR_SVC}"
    log "  Attempt ${attempt}/${max} — waiting 5s..."
    sleep 5
  done

  log "PARExport is up on 127.0.0.1:${PAR_PORT}."
}

# ── STEP 8: HAPROXY ───────────────────────────────────────────────────────────
setup_haproxy_cert() {
  local cfg_dir="/etc/haproxy"
  log "Building combined PEM for HAProxy..."
  cat "${MEDIA_DIR}/${CERT_FILE}" "${MEDIA_DIR}/${KEY_FILE}" > "${cfg_dir}/parexport-server.pem"
  chmod 600 "${cfg_dir}/parexport-server.pem"
  log "Combined PEM written to ${cfg_dir}/parexport-server.pem."
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
  tune.ssl.default-dh-param 2048
  tune.maxrewrite       4096
  stats                 socket /var/lib/haproxy/stats

  # Restrict to TLS 1.3 only (KB1632909); ECDHE-only ciphers as TLS 1.2 fallback
  ssl-default-bind-options   no-sslv3 no-tlsv10 no-tlsv11 no-tlsv12
  ssl-default-bind-ciphers   ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305

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
  stats                 uri /stats
  stats                 refresh 30s

frontend parexport-frontend
  bind                  0.0.0.0:${HAPROXY_BIND_PORT} ssl crt /etc/haproxy/parexport-server.pem
  option                httplog
  option                forwardfor
  option                http-server-close

  unique-id-format %[uuid()]
  unique-id-header X-Unique-ID
  log-tag parexport
  log-format {"timestamp":"%tr","application":"parexport","client_ip":"%ci","fe_name":"%f","fe_port":"%fp","be_name":"%b","server_name":"%s","server_ip":"%si","server_port":"%sp","http_method":"%HM","http_proto":"https","host":"%hrl","http_uri":"%HU","status_code":"%ST","response_time":"%Tr","bytes_read":"%B","termination_state":"%ts","active_conn":"%ac","x-unique-id":"%ID"}

  # GCP Layer-4 LB health check endpoint — HAProxy answers /hello directly
  # without touching the backend (monitor-uri is available since HAProxy 1.4)
  monitor-uri             /hello
  acl backends_down       nbsrv(parexport-backend) lt 1
  monitor fail            if backends_down

  # Inform PARExport of the original request context (KB1632909)
  http-request          set-header X-Forwarded-Host  %[req.hdr(host)]
  http-request          set-header X-Forwarded-Proto https if { ssl_fc }
  http-request          set-header X-Forwarded-Proto http  if !{ ssl_fc }

  # HSTS — configured at the load balancer (KB1632909)
  http-after-response   set-header Strict-Transport-Security "max-age=63072000; includeSubDomains;"

  # Add HttpOnly and Secure flags to cookies not already bearing them (KB1632909)
  http-after-response   replace-header Set-Cookie '(^((?!(?i)httponly).)*$)' "\1; HttpOnly"
  http-after-response   replace-header Set-Cookie '(^((?!(?i)secure).)*$)'   "\1; Secure"

  # Rewrite http→https in any Location redirects from PARExport (KB1632909)
  http-response         replace-header Location ^http://(.*)$ https://\1

  default_backend       parexport-backend

backend parexport-backend
  mode                  http
  balance               leastconn

  # Session persistence via load balancer cookie (KB1632909)
  cookie                PAREXPORTID insert indirect nocache httponly secure

  option                httpchk GET /ping

EOF

  local idx=1
  IFS=',' read -ra _nodes <<< "${BACKEND_NODES}"
  for _node in "${_nodes[@]}"; do
    echo "  server  parexport${idx}  ${_node}  check cookie parexport${idx}" >> "${cfg_file}"
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
  cat > /etc/logrotate.d/haproxy-parexport <<'LOGROTATE'
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
  log "PARExport Server Deployment"
  log "  Host            : $(hostname -f)"
  log "  Mode            : ${MODE}"
  if [ "${MODE}" = "parexport" ] || [ "${MODE}" = "all" ]; then
    if [ -n "${PAREXPORT_RPM}" ]; then
      log "  Installer       : ${PAREXPORT_RPM} (RPM)"
    else
      log "  Installer       : ${PAREXPORT_BIN} (.bin)"
    fi
    log "  Install dir     : ${INSTALL_DIR}"
    log "  PARExport port  : 127.0.0.1:${PAR_PORT} (HTTP, TLS terminated at HAProxy)"
  fi
  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    log "  HAProxy frontend: 0.0.0.0:${HAPROXY_BIND_PORT} (TLSv1.3)"
    log "  Backend nodes   : ${BACKEND_NODES}"
    log "  Stats           : 127.0.0.1:${HAPROXY_STAT_PORT}"
  fi
  log "============================================================"

  install_deps

  if [ "${MODE}" = "parexport" ] || [ "${MODE}" = "all" ]; then
    create_user_group
    install_parexport
    configure_parexport
  fi

  configure_selinux
  configure_firewall

  if [ "${MODE}" = "parexport" ] || [ "${MODE}" = "all" ]; then
    enable_parexport
    verify_parexport
  fi

  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    configure_haproxy
    verify_haproxy
  fi

  log "============================================================"
  log "Deployment complete on $(hostname -f)"
  if [ "${MODE}" = "parexport" ] || [ "${MODE}" = "all" ]; then
    log "  PARExport health : curl http://127.0.0.1:${PAR_PORT}/ping"
    log "  Service          : systemctl status ${PAR_SVC}"
  fi
  if [ "${MODE}" = "haproxy" ] || [ "${MODE}" = "all" ]; then
    log "  HAProxy HTTPS    : https://$(hostname -f):${HAPROXY_BIND_PORT}"
    log "  HAProxy stats    : http://127.0.0.1:${HAPROXY_STAT_PORT}/stats"
    log ""
    log "  Verify TLS 1.3 enforcement:"
    log "    openssl s_client -connect $(hostname -f):${HAPROXY_BIND_PORT} -tls1_3"
    log ""
    log "  Configure ServiceNow to point to the load balancer:"
    log "    sys_properties: glide.par.export.host = https://<lb-host>:${HAPROXY_BIND_PORT}"
    log ""
    log "  Add this VM's IP to the GCP Layer-4 load balancer backend group"
    log "  on port ${HAPROXY_BIND_PORT} to include it in the pool."
  fi
  log "============================================================"
}

main "$@"
