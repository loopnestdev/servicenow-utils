#!/bin/bash
# Deploy ServiceNow AI Search (AIS) Node on RHEL 8/9 / Rocky Linux 8/9.
#
# AI Search is a Tomcat-based Orbit application that provides modern search
# capabilities (NLP, Genius results, ML relevancy) for ServiceNow self-hosted.
#
# The installer creates <install_dir>/<instance_name>_<port>/ (e.g. /glide/aisnode_8000/).
# All AIS files (startup.sh, conf/, data/, logs/, webapps/) live under that node directory.
# TLS is terminated natively by AIS using PKCS12 keystores via Tomcat NIO:
#   - keystore.p12   — AIS node certificate and private key
#   - truststore.p12 — App node certificate(s) + optional custom CA trusted for mTLS
# All generated keystores and custom override properties files are placed under
# conf/overrides.d/ inside the node directory.
# Optionally configures HA replication with a paired AIS node and mTLS certificate
# allowlists for both App Nodes and AIS Node peers.
#
# Reference KB: KB0870874 – AI Search: Self-Hosted Installation and Configuration
set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
INSTALL_DIR="/glide"
JAVA_DIR="/glide/java"
MEDIA_DIR="/glide/media"
DIST_ZIP=""
JDK_TARBALL=""
INSTANCE_NAME="aisnode"
PORT="8000"
NODE_ID=""
ML_PREDICTION_URL="http://127.0.0.1:5000"
HEAP_SIZE="5"
CERT_FILE=""
KEY_FILE=""
APPNODE_CERT_FILE=""
CA_CERT_FILE=""
KEYSTORE_PASS="changeit"
TRUSTSTORE_PASS="changeit"
PEER_HOST=""
PEER_PORT=""
AIS_USER="aisearch"
SKIP_DEPS="false"
SKIP_SELINUX="false"

# Derived — set in validate_args / runtime
AIS_VERSION=""
NODE_DIR=""
SYSTEMD_UNIT_CHANGED="false"

# ── USAGE ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOUSAGE

  USAGE: $0 [OPTIONS]

  Required:
    --dist_zip=<file>             AIS release zip filename in media_dir
    --jdk_tarball=<file>          JDK tarball filename in media_dir (11, 17, or 21 depending on AIS version)
    --cert_file=<file>            AIS node TLS certificate filename (PEM) in media_dir
    --key_file=<file>             AIS node TLS private key filename (PEM) in media_dir
    --keystore_pass=<password>    Password for the AIS node keystore (keystore.p12)

  Optional:
    --install_dir=<path>          AIS install directory base              (default: /glide)
    --media_dir=<path>            Directory containing installer and JDK  (default: /glide/media)
    --instance_name=<name>        AIS instance/orbit name                 (default: aisnode)
    --port=<port>                 AIS listener port                       (default: 8000)
    --node_id=<id>                Unique AIS node identifier              (default: hostname -s)
    --ml_prediction_url=<url>     Base URL of the ML Predictor            (default: http://127.0.0.1:5000)
    --heap_size=<GB>              Max JVM heap in GB                      (default: 5)
    --appnode_cert_file=<file>    App node PEM bundle (cert + private key in one file) in media_dir
                                  for mTLS truststore and SHA-256 digest registration.
                                  Only the certificate portion is extracted and used on the AIS side;
                                  the private key in the bundle is not touched by this script.
    --ca_cert_file=<file>         CA certificate (PEM) in media_dir that issued the App node cert.
                                  Imported into the AIS truststore so Tomcat can validate the mTLS
                                  client certificate chain. Keep separate from --appnode_cert_file.
    --truststore_pass=<password>  Password for the mTLS truststore (truststore.p12) (default: changeit)
    --peer_host=<host>            HA paired AIS node hostname or IP (enables HA replication)
    --peer_port=<port>            HA paired AIS node port               (default: same as --port)
    --ais_user=<username>         OS service account name                 (default: aisearch)
    --skip_deps                   Skip OS dependency installation
    --skip_selinux                Skip SELinux port labeling
    --help                        Show this help

  JDK version requirements by AIS release:
    < 102.x   → OpenJDK 11
    102-104.x → OpenJDK 17
    ≥ 105.x   → OpenJDK 21

  Prerequisites in --media_dir (default: /glide/media):
    - <dist_zip>          AIS release zip (e.g. aisearch-1.0.0.300.zip)
    - <jdk_tarball>       JDK tarball (e.g. jdk-21.0.3_linux-x64_bin.tar.gz)
    - <cert_file>         AIS node TLS certificate PEM
    - <key_file>          AIS node TLS private key PEM
    - <appnode_cert_file> App node PEM bundle (cert + key, optional, enables mTLS)
    - <ca_cert_file>      CA certificate PEM that issued the App node cert (optional)

  Generated files under <node_dir>/conf/overrides.d/:
    - keystore.p12               — AIS node certificate and private key (server identity + mTLS client)
    - truststore.p12             — App node cert(s) + optional custom CA (trusted for mTLS)
    - 02-connector-secure.properties — Tomcat TLS connector configuration (TLSv1.3)
    - 10-aisearch.properties     — JVM heap and memory settings

  Notes:
    - Must be run as root
    - Target OS: RHEL 8/9 / Rocky Linux 8/9
    - Node directory: <install_dir>/<instance_name>_<port>/ (e.g. /glide/aisnode_8000/)
    - AIS serves HTTPS on --port via Tomcat NIO with TLSv1.3
    - For HA, run this script on both nodes pointing --peer_host at the other

  Example (standalone):
    $0 --dist_zip=aisearch-1.0.0.300.zip \\
       --jdk_tarball=jdk-21.0.3_linux-x64_bin.tar.gz \\
       --cert_file=aisnode.crt --key_file=aisnode.key \\
       --keystore_pass=KsP4ss!

  Example (with custom CA, mTLS, and HA):
    $0 --dist_zip=aisearch-1.0.0.300.zip \\
       --jdk_tarball=jdk-21.0.3_linux-x64_bin.tar.gz \\
       --cert_file=aisnode001.crt --key_file=aisnode001.key \\
       --keystore_pass=KsP4ss! --truststore_pass=TrP4ss! \\
       --appnode_cert_file=appnode-bundle.pem \\
       --ca_cert_file=internal-ca.crt \\
       --peer_host=aisnode002.company.com

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
      --install_dir=*)        INSTALL_DIR="${1#*=}" ;;
      --media_dir=*)          MEDIA_DIR="${1#*=}" ;;
      --dist_zip=*)           DIST_ZIP="${1#*=}" ;;
      --jdk_tarball=*)        JDK_TARBALL="${1#*=}" ;;
      --instance_name=*)      INSTANCE_NAME="${1#*=}" ;;
      --port=*)               PORT="${1#*=}" ;;
      --node_id=*)            NODE_ID="${1#*=}" ;;
      --ml_prediction_url=*)  ML_PREDICTION_URL="${1#*=}" ;;
      --heap_size=*)          HEAP_SIZE="${1#*=}" ;;
      --cert_file=*)          CERT_FILE="${1#*=}" ;;
      --key_file=*)           KEY_FILE="${1#*=}" ;;
      --appnode_cert_file=*)  APPNODE_CERT_FILE="${1#*=}" ;;
      --ca_cert_file=*)       CA_CERT_FILE="${1#*=}" ;;
      --keystore_pass=*)      KEYSTORE_PASS="${1#*=}" ;;
      --truststore_pass=*)    TRUSTSTORE_PASS="${1#*=}" ;;
      --peer_host=*)          PEER_HOST="${1#*=}" ;;
      --peer_port=*)          PEER_PORT="${1#*=}" ;;
      --ais_user=*)           AIS_USER="${1#*=}" ;;
      --skip_deps)            SKIP_DEPS="true" ;;
      --skip_selinux)         SKIP_SELINUX="true" ;;
      --help)                 usage; exit 0 ;;
      *) die "Unknown argument: $1. Run $0 --help for usage." ;;
    esac
    shift
  done
}

validate_args() {
  [ -n "${DIST_ZIP}" ]      || die "--dist_zip is required."
  [ -n "${JDK_TARBALL}" ]   || die "--jdk_tarball is required."
  [ -n "${CERT_FILE}" ]     || die "--cert_file is required."
  [ -n "${KEY_FILE}" ]      || die "--key_file is required."
  [ -n "${KEYSTORE_PASS}" ] || die "--keystore_pass is required."

  [ -f "${MEDIA_DIR}/${DIST_ZIP}" ]    || die "AIS zip not found: ${MEDIA_DIR}/${DIST_ZIP}"
  [ -f "${MEDIA_DIR}/${JDK_TARBALL}" ] || die "JDK tarball not found: ${MEDIA_DIR}/${JDK_TARBALL}"
  [ -f "${MEDIA_DIR}/${CERT_FILE}" ]   || die "Certificate file not found: ${MEDIA_DIR}/${CERT_FILE}"
  [ -f "${MEDIA_DIR}/${KEY_FILE}" ]    || die "Key file not found: ${MEDIA_DIR}/${KEY_FILE}"

  if [ -n "${APPNODE_CERT_FILE}" ]; then
    [ -f "${MEDIA_DIR}/${APPNODE_CERT_FILE}" ] \
      || die "App node certificate not found: ${MEDIA_DIR}/${APPNODE_CERT_FILE}"
  fi

  if [ -n "${CA_CERT_FILE}" ]; then
    [ -f "${MEDIA_DIR}/${CA_CERT_FILE}" ] \
      || die "CA certificate not found: ${MEDIA_DIR}/${CA_CERT_FILE}"
  fi

  [ -z "${PEER_PORT}" ] && PEER_PORT="${PORT}"

  # Default node_id to the short hostname — unique per server, stable across
  # re-runs, and human-readable in /v1/stats metrics. Override with --node_id
  # if a specific value (e.g. a UUID) is required by your environment.
  if [ -z "${NODE_ID}" ]; then
    NODE_ID=$(hostname -s)
    log "Defaulting node_id to hostname: ${NODE_ID}"
  fi

  # Parse version from zip filename (supports aisearch-X.Y.Z.W.zip or similar)
  AIS_VERSION=$(basename "${DIST_ZIP}" .zip | sed 's/^[^0-9]*//')
  [ -z "${AIS_VERSION}" ] && AIS_VERSION="unknown"

  NODE_DIR="${INSTALL_DIR}/${INSTANCE_NAME}_${PORT}"

  log "Resolved: version=${AIS_VERSION}, node_dir=${NODE_DIR}"
}

# ── STEP 1: OS TUNING ─────────────────────────────────────────────────────────
tune_os() {
  log "Tuning OS limits for AI Search..."

  # vm.max_map_count — required for AIS index memory mapping
  local sysctl_conf="/etc/sysctl.conf"
  if grep -q "^vm.max_map_count=" "${sysctl_conf}" 2>/dev/null; then
    log "  vm.max_map_count already set in ${sysctl_conf}, skipping."
  else
    echo "vm.max_map_count=262144" >> "${sysctl_conf}"
    sysctl -p >/dev/null
    log "  vm.max_map_count=262144 applied."
  fi

  # nofile ulimit — AIS opens many index files
  local limits_file="/etc/security/limits.d/aisearch-nofile.conf"
  if [ -f "${limits_file}" ]; then
    log "  nofile limits already configured (${limits_file}), skipping."
  else
    cat > "${limits_file}" <<EOF
*         soft     nofile    262144
*         hard     nofile    262144
EOF
    log "  nofile=262144 configured: ${limits_file}"
  fi
}

# ── STEP 2: OS DEPENDENCIES ───────────────────────────────────────────────────
install_deps() {
  if [ "${SKIP_DEPS}" = "true" ]; then
    log "Skipping OS dependency installation (--skip_deps set)."
    return 0
  fi

  log "Installing OS dependencies..."
  dnf install -y curl openssl java-headless 2>/dev/null \
    || yum install -y curl openssl 2>/dev/null \
    || log "  Warning: package manager install returned non-zero; proceeding."
  log "OS dependencies installed."
}

# ── STEP 3: INSTALL JDK ───────────────────────────────────────────────────────
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

  echo "export JAVA_HOME=${JAVA_DIR}" > /etc/profile.d/aisearch_JAVA_HOME.sh
  echo "export PATH=\$PATH:${JAVA_DIR}/bin" >> /etc/profile.d/aisearch_JAVA_HOME.sh
  export JAVA_HOME="${JAVA_DIR}"

  log "JDK installed: $("${JAVA_DIR}/bin/java" -version 2>&1 | head -1)"
}

# ── STEP 4: OS SERVICE ACCOUNT ────────────────────────────────────────────────
create_user_group() {
  log "Ensuring ${AIS_USER} service account exists..."
  getent group "${AIS_USER}" >/dev/null 2>&1 \
    || groupadd --system "${AIS_USER}"
  id -u "${AIS_USER}" >/dev/null 2>&1 \
    || useradd --system --no-create-home \
               --gid "${AIS_USER}" \
               --home-dir "${INSTALL_DIR}" \
               --shell /sbin/nologin \
               "${AIS_USER}"
  log "Service account ready."
}

# ── STEP 5: INSTALL AI SEARCH ─────────────────────────────────────────────────
install_aisearch() {
  if [ -f "${NODE_DIR}/startup.sh" ]; then
    log "AI Search already installed at ${NODE_DIR}, skipping installation."
    return 0
  fi

  log "Installing AI Search ${AIS_VERSION} as '${INSTANCE_NAME}' on port ${PORT}..."

  mkdir -p "${INSTALL_DIR}"

  # The orbit installer creates <instance_name>_<port>/ in CWD.
  # Some AIS versions exit non-zero due to a bug in the installer's own temp
  # directory cleanup (RuntimeException: refusing to delete directory that
  # doesn't look like a temporary directory). The installation files are written
  # correctly before the cleanup runs, so we capture the exit code separately
  # and treat startup.sh presence as the authoritative success indicator.
  local installer_rc=0
  ( cd "${INSTALL_DIR}" && \
    "${JAVA_DIR}/bin/java" \
      -Ddist-upgrade.deploy.java=false \
      -Ddist-upgrade.commandinstall.orbit=true \
      -jar "${MEDIA_DIR}/${DIST_ZIP}" \
      install \
      --instance-name "${INSTANCE_NAME}" \
      --port "${PORT}" \
      --extra-properties \
      "system.property.startup.aisearch.node.id=${NODE_ID},system.property.startup.ml.prediction_service.url=${ML_PREDICTION_URL}" ) || installer_rc=$?

  if [ ! -f "${NODE_DIR}/startup.sh" ]; then
    die "Installation failed: startup.sh not found at ${NODE_DIR} (installer exit code: ${installer_rc})."
  fi

  if [ "${installer_rc}" -ne 0 ]; then
    log "  Warning: installer exited ${installer_rc} (known temp-dir cleanup bug in some AIS versions); installation files verified present."
  fi

  log "AI Search installed at ${NODE_DIR}."
}

# ── STEP 6: CONFIGURE JVM HEAP ────────────────────────────────────────────────
configure_heap() {
  local overrides_dir="${NODE_DIR}/conf/overrides.d"
  local mem_props="${overrides_dir}/10-aisearch.properties"

  mkdir -p "${overrides_dir}"

  if [ -f "${mem_props}" ] && grep -q "\-Xmx${HEAP_SIZE}[gG]" "${mem_props}"; then
    log "Heap already set to ${HEAP_SIZE}G, skipping."
    return 0
  fi

  log "Setting max JVM heap to ${HEAP_SIZE}G..."

  if [ -f "${mem_props}" ]; then
    sed -i "s/-Xmx[0-9]*[gGmM]/-Xmx${HEAP_SIZE}g/" "${mem_props}"
  else
    cat > "${mem_props}" <<EOF
java.opts.snippet.nodeconfig.mem=-Xms128m
java.opts.snippet.nodeconfig.max.heap=-Xmx${HEAP_SIZE}g
java.opts.snippet.nodeconfig.max.metaspace=-XX:MaxMetaspaceSize=192m
EOF
  fi

  log "Heap configured: max ${HEAP_SIZE}G."
}

# ── STEP 7: SETUP TLS KEYSTORES ───────────────────────────────────────────────
setup_keystore() {
  local overrides_dir="${NODE_DIR}/conf/overrides.d"
  local keystore="${overrides_dir}/keystore.p12"

  mkdir -p "${overrides_dir}"

  if [ -f "${keystore}" ]; then
    log "Server keystore already exists (keystore.p12), skipping."
    return 0
  fi

  log "Building AIS node keystore (keystore.p12)..."

  openssl pkcs12 -export \
    -in    "${MEDIA_DIR}/${CERT_FILE}" \
    -inkey "${MEDIA_DIR}/${KEY_FILE}" \
    -out   "${keystore}" \
    -name  _identity_ \
    -passout "pass:${KEYSTORE_PASS}"

  chmod 640 "${keystore}"
  log "  AIS node keystore written: ${keystore}"
}

setup_truststore() {
  local overrides_dir="${NODE_DIR}/conf/overrides.d"
  local truststore="${overrides_dir}/truststore.p12"

  if [ -z "${APPNODE_CERT_FILE}" ] && [ -z "${CA_CERT_FILE}" ]; then
    log "No --appnode_cert_file or --ca_cert_file provided; mTLS truststore will not be created."
    log "  AIS will accept connections without client certificate verification."
    return 0
  fi

  mkdir -p "${overrides_dir}"

  if [ -f "${truststore}" ]; then
    log "Truststore already exists (truststore.p12), skipping."
    return 0
  fi

  log "Building mTLS truststore (truststore.p12)..."

  if [ -n "${APPNODE_CERT_FILE}" ]; then
    log "  Importing app node certificate: ${APPNODE_CERT_FILE}..."
    # Extract only the leaf certificate from the PEM bundle (ignores any private key present)
    local appnode_cert_only; appnode_cert_only=$(mktemp --suffix=.pem)
    openssl x509 -in "${MEDIA_DIR}/${APPNODE_CERT_FILE}" -out "${appnode_cert_only}"
    "${JAVA_DIR}/bin/keytool" -importcert \
      -storetype PKCS12 \
      -keystore  "${truststore}" \
      -storepass "${TRUSTSTORE_PASS}" \
      -alias     appnode \
      -file      "${appnode_cert_only}" \
      -noprompt
    rm -f "${appnode_cert_only}"
  fi

  if [ -n "${CA_CERT_FILE}" ]; then
    log "  Importing custom CA certificate: ${CA_CERT_FILE}..."
    "${JAVA_DIR}/bin/keytool" -importcert \
      -storetype PKCS12 \
      -keystore  "${truststore}" \
      -storepass "${TRUSTSTORE_PASS}" \
      -alias     custom-ca \
      -file      "${MEDIA_DIR}/${CA_CERT_FILE}" \
      -noprompt
  fi

  chmod 640 "${truststore}"
  log "  Truststore written: ${truststore}"
}

# ── STEP 8: CONFIGURE TLS CONNECTOR ──────────────────────────────────────────
setup_tls_properties() {
  local overrides_dir="${NODE_DIR}/conf/overrides.d"
  local tls_props="${overrides_dir}/02-connector-secure.properties"

  mkdir -p "${overrides_dir}"

  if [ -f "${tls_props}" ]; then
    log "TLS connector properties already exist (02-connector-secure.properties), skipping."
    return 0
  fi

  # Determine clientAuth setting — "want" if truststore was built, "false" otherwise
  local client_auth="false"
  [ -f "${overrides_dir}/truststore.p12" ] && client_auth="want"

  log "Writing TLS connector properties (TLSv1.3)..."

  {
    cat <<EOF
# Use HTTPS
tomcat.connector.main.scheme=https

# Mark all requests as secure
tomcat.connector.main.secure=true

# Enable SSL/TLS
tomcat.connector.main.SSLEnabled=true

# Client certificate: "want" enables mTLS while still allowing unauthenticated clients.
# Set to "false" when no truststore is configured.
tomcat.connector.main.clientAuth=${client_auth}

# Enforce TLSv1.3 exclusively
tomcat.connector.main.sslProtocol=TLSv1.3
tomcat.connector.main.sslEnabledProtocols=TLSv1.3

# Honour server cipher preference
tomcat.connector.main.honorCipherOrder=true

# TLSv1.3 cipher suites (JSSE names)
tomcat.connector.main.ciphers=TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256,TLS_CHACHA20_POLY1305_SHA256

# AIS node certificate alias in the keystore
tomcat.connector.main.keyAlias=_identity_

# Keystore (AIS node server certificate + private key)
tomcat.connector.main.keystoreType=PKCS12
tomcat.connector.main.keystoreFile=../conf/overrides.d/keystore.p12
tomcat.connector.main.keystorePass=${KEYSTORE_PASS}
EOF

    if [ -f "${overrides_dir}/truststore.p12" ]; then
      cat <<EOF

# Truststore (App node certificates + optional custom CA trusted for mTLS)
tomcat.connector.main.truststoreType=PKCS12
tomcat.connector.main.truststoreFile=../conf/overrides.d/truststore.p12
tomcat.connector.main.truststorePass=${TRUSTSTORE_PASS}
EOF
    fi
  } > "${tls_props}"

  log "  TLS properties written: ${tls_props}"
}

# ── STEP 9: CONFIGURE MTLS CERTIFICATE DIGESTS ────────────────────────────────
configure_mtls_digests() {
  local aisearch_props="${NODE_DIR}/conf/aisearch.properties"

  [ -f "${aisearch_props}" ] || { log "aisearch.properties not found, skipping mTLS digest config."; return 0; }

  # Compute SHA-256 digest of the AIS node's own certificate (REPLICATION role)
  local node_cert="${MEDIA_DIR}/${CERT_FILE}"
  local node_der; node_der=$(mktemp --suffix=.der)
  openssl x509 -inform pem -in "${node_cert}" -outform der -out "${node_der}"
  local node_digest
  node_digest=$(openssl dgst -sha256 < "${node_der}" | awk '{print $2}')
  rm -f "${node_der}"

  if grep -q "mtls.allowed.replication.sha256" "${aisearch_props}"; then
    log "mTLS replication digest already in aisearch.properties, skipping."
  else
    log "Writing AIS node replication certificate digest..."
    cat >> "${aisearch_props}" <<EOF

# AIS node certificate SHA-256 digest for replication role (ADMIN when cert matches keystore)
system.property.startup.mtls.allowed.replication.sha256=${node_digest}
EOF
    log "  Replication digest: ${node_digest}"
  fi

  # Compute SHA-256 digest of the App node certificate (USER role), if provided.
  # The input may be a PEM bundle (cert + private key); openssl x509 extracts only the leaf cert.
  if [ -n "${APPNODE_CERT_FILE}" ]; then
    local appnode_der; appnode_der=$(mktemp --suffix=.der)
    openssl x509 -inform pem -in "${MEDIA_DIR}/${APPNODE_CERT_FILE}" -outform der -out "${appnode_der}"
    local appnode_digest
    appnode_digest=$(openssl dgst -sha256 < "${appnode_der}" | awk '{print $2}')
    rm -f "${appnode_der}"

    if grep -q "mtls.allowed.app.sha256" "${aisearch_props}"; then
      log "mTLS app node digest already in aisearch.properties, skipping."
    else
      log "Writing App node certificate digest (USER role)..."
      cat >> "${aisearch_props}" <<EOF

# App node certificate SHA-256 digest for USER role (Glide app nodes)
system.property.startup.mtls.allowed.app.sha256=${appnode_digest}
EOF
      log "  App node digest: ${appnode_digest}"
    fi
  fi
}

# ── STEP 10: HA REPLICATION ───────────────────────────────────────────────────
configure_ha() {
  [ -n "${PEER_HOST}" ] || return 0

  local aisearch_props="${NODE_DIR}/conf/aisearch.properties"

  [ -f "${aisearch_props}" ] || die "aisearch.properties not found at ${NODE_DIR}/conf/"

  if grep -q "^system.property.startup.paired.node.host=${PEER_HOST}" "${aisearch_props}"; then
    log "HA replication already configured for ${PEER_HOST}:${PEER_PORT}, skipping."
    return 0
  fi

  log "Configuring HA replication: peer=${PEER_HOST}:${PEER_PORT}..."

  cat >> "${aisearch_props}" <<EOF

# HA replication — paired AIS node
system.property.startup.paired.node.host=${PEER_HOST}
system.property.startup.paired.node.port=${PEER_PORT}
system.property.startup.attivio.dev.pool.enabled=false
EOF

  log "  HA replication config appended to ${aisearch_props}"
}

# ── STEP 11: SYSTEMD SERVICE ──────────────────────────────────────────────────
write_systemd_service() {
  local svc="aisearch"
  local svc_file="/etc/systemd/system/${svc}.service"
  local tmp_file; tmp_file=$(mktemp)

  cat > "${tmp_file}" <<EOF
[Unit]
Description=ServiceNow AI Search Node - ${INSTANCE_NAME}:${PORT}
After=syslog.target network.target

[Service]
Environment=JAVA_HOME=${JAVA_DIR}
Type=forking
ExecStart=${NODE_DIR}/startup.sh
ExecStop=${NODE_DIR}/shutdown.sh
User=${AIS_USER}
Group=${AIS_USER}
UMask=0007
TimeoutStartSec=180
TimeoutStopSec=60
Restart=on-failure
RestartSec=15
$([ "${PORT}" -lt 1024 ] && echo "AmbientCapabilities=CAP_NET_BIND_SERVICE" || true)

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

# ── STEP 12: SELINUX PORT LABEL ───────────────────────────────────────────────
configure_selinux() {
  if [ "${SKIP_SELINUX}" = "true" ]; then
    log "Skipping SELinux configuration (--skip_selinux set)."
    return 0
  fi

  if ! command -v getenforce >/dev/null 2>&1 || [ "$(getenforce)" = "Disabled" ]; then
    return 0
  fi

  log "SELinux enforcing — labeling AIS port TCP/${PORT}..."
  if semanage port -l | grep -E "^http_port_t\s" | grep -qw "${PORT}"; then
    log "  TCP/${PORT} already labeled as http_port_t."
  else
    semanage port -a -t http_port_t -p tcp "${PORT}" \
      || semanage port -m -t http_port_t -p tcp "${PORT}"
    log "  Labeled TCP/${PORT} as http_port_t."
  fi
}

# ── STEP 13: FILE OWNERSHIP ───────────────────────────────────────────────────
set_ownership() {
  log "Setting ownership of ${NODE_DIR} to ${AIS_USER}:${AIS_USER}..."
  chown -R "${AIS_USER}:${AIS_USER}" "${NODE_DIR}"
  chmod -R 750 "${NODE_DIR}"
  # Keystores must be readable by the service account but not world-readable
  local overrides_dir="${NODE_DIR}/conf/overrides.d"
  [ -f "${overrides_dir}/keystore.p12"   ] && chmod 640 "${overrides_dir}/keystore.p12"
  [ -f "${overrides_dir}/truststore.p12" ] && chmod 640 "${overrides_dir}/truststore.p12"
  log "Ownership set."
}

# ── STEP 14: ENABLE AND START ─────────────────────────────────────────────────
enable_start_service() {
  local svc="aisearch"

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

# ── STEP 15: VERIFY ───────────────────────────────────────────────────────────
verify_service() {
  log "Waiting for AI Search to respond on 127.0.0.1:${PORT}..."
  local attempt=0 max=30

  until curl -sf -o /dev/null -w "%{http_code}" --insecure \
      "https://127.0.0.1:${PORT}/v1/stats" 2>/dev/null | grep -qE "^[2-4]"; do
    attempt=$(( attempt + 1 ))
    [ "${attempt}" -ge "${max}" ] \
      && die "AI Search did not respond after $(( max * 10 ))s. Check: journalctl -u aisearch"
    if [ $(( attempt % 3 )) -eq 0 ]; then
      log "  Waiting for AI Search... $(( attempt * 10 ))s elapsed."
    fi
    sleep 10
  done

  log "AI Search is up on 127.0.0.1:${PORT}."
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  require_root
  validate_args

  log "============================================================"
  log "AI Search Deployment"
  log "  Host              : $(hostname -f)"
  log "  Version           : ${AIS_VERSION}"
  log "  Instance name     : ${INSTANCE_NAME}"
  log "  Port              : ${PORT}"
  log "  Node ID           : ${NODE_ID}"
  log "  Node dir          : ${NODE_DIR}"
  log "  JDK               : ${JDK_TARBALL}"
  log "  Heap              : ${HEAP_SIZE}G"
  log "  ML Predictor URL  : ${ML_PREDICTION_URL}"
  log "  Service account   : ${AIS_USER}"
  log "  Server cert       : ${CERT_FILE}"
  if [ -n "${APPNODE_CERT_FILE}" ]; then
    log "  App node cert     : ${APPNODE_CERT_FILE} (mTLS enabled)"
  else
    log "  App node cert     : none (mTLS disabled)"
  fi
  if [ -n "${CA_CERT_FILE}" ]; then
    log "  Custom CA cert    : ${CA_CERT_FILE}"
  fi
  if [ -n "${PEER_HOST}" ]; then
    log "  HA peer           : ${PEER_HOST}:${PEER_PORT}"
  else
    log "  HA peer           : none (standalone)"
  fi
  log "============================================================"

  tune_os
  [ "${SKIP_DEPS}" = "true" ] && log "Skipping OS dependency installation (--skip_deps)." || install_deps
  install_jdk
  create_user_group
  install_aisearch
  configure_heap
  setup_keystore
  setup_truststore
  setup_tls_properties
  configure_mtls_digests
  configure_ha
  write_systemd_service
  set_ownership
  configure_selinux
  enable_start_service
  verify_service

  log "============================================================"
  log "Deployment complete on $(hostname -f)"
  log "  AI Search URL  : https://$(hostname -f):${PORT}/"
  log "  Stats API      : https://$(hostname -f):${PORT}/v1/stats"
  log "  Service        : systemctl status aisearch"
  log "  Logs           : ${NODE_DIR}/logs/"
  log ""
  log "────────────────────────────────────────────────────────────"
  log "  AIS NODE — post-install steps (run on THIS host)"
  log "────────────────────────────────────────────────────────────"
  log ""
  log "  1. Create an AIS partition:"
  log "       curl -k -XPOST -H 'Content-Type: application/json' \\"
  log "         -d '{\"id\":\"<partition-uuid>\",\"instance\":{\"customerInstanceId\":\"<instance-id>\",\"customerInstanceName\":\"<instance-name>\",\"customerInstanceGroup\":null}}' \\"
  log "         https://$(hostname -f):${PORT}/v1/mgmt/admin/partition"
  log ""
  log "  2. Set the partition state:"
  if [ -n "${PEER_HOST}" ]; then
    log "     Set ACTIVE on this node (primary):"
    log "       curl -k -XPUT https://$(hostname -f):${PORT}/v1/mgmt/admin/partition/<partition-uuid>/state/ACTIVE"
    log "     Set PASSIVE_ELIGIBLE on the peer (${PEER_HOST}) after running this script there:"
    log "       curl -k -XPUT https://${PEER_HOST}:${PEER_PORT}/v1/mgmt/admin/partition/<partition-uuid>/state/PASSIVE_ELIGIBLE"
  else
    log "       curl -k -XPUT https://$(hostname -f):${PORT}/v1/mgmt/admin/partition/<partition-uuid>/state/ACTIVE"
  fi
  log ""
  log "  3. Verify partition health:"
  log "       curl -k https://$(hostname -f):${PORT}/v1/mgmt/partition/<partition-uuid>/healthStatus"
  if [ -n "${PEER_HOST}" ]; then
    log "     Confirm replicationHealthy=true on both nodes before proceeding."
  fi
  log ""
  if [ -n "${PEER_HOST}" ]; then
    log "  4. Run this script on the peer node (${PEER_HOST}):"
    log "       --peer_host=$(hostname -f) --peer_port=${PORT} (swap active/passive as needed)"
    log ""
  fi
  log "────────────────────────────────────────────────────────────"
  log "  GLIDE APP NODES — steps to complete on each ServiceNow app node"
  log "────────────────────────────────────────────────────────────"
  log ""
  log "  These steps configure Glide to present a client certificate when"
  log "  connecting to AIS (mTLS). Glide connects directly to AIS — this"
  log "  is independent of HAProxy and the LB certificate."
  log ""
  log "  The App Node certificate is the cert whose SHA-256 digest was registered"
  log "  in AIS as mtls.allowed.app.sha256 (via --appnode_cert_file above)."
  log "  You can reuse your existing LB/HAProxy certificate if it has:"
  log "    keyUsage         = critical, digitalSignature, keyEncipherment"
  log "    extendedKeyUsage = clientAuth"
  log "  Verify with:"
  log "    openssl x509 -in appnode-bundle.pem -noout -text | grep -A3 'Extended Key'"
  log ""
  log "  The App Node PEM bundle contains both the certificate and the private key"
  log "  in a single file (externally issued — do not split them). The CA certificate"
  log "  that issued the App Node cert is kept separate and was already imported into"
  log "  the AIS truststore via --ca_cert_file; it does not belong in the bundle."
  log ""
  log "  On each Glide app node (as root):"
  log ""
  log "  a) Import App Node PEM bundle (cert + key) into a BCFKS keystore"
  log "     (locate the BouncyCastle FIPS jar in your Glide install first):"
  log ""
  log "     BCFIPS_JAR=\$(find <glide-dir>/lib -name 'bc-fips-*.jar' | sort -V | tail -1)"
  log ""
  log "     # Both cert and key are in one file; -in handles both"
  log "     openssl pkcs12 -export \\"
  log "       -in appnode-bundle.pem \\"
  log "       -out /tmp/appnode.p12 -name _identity_ -passout pass:changeit"
  log ""
  log "     keytool -importkeystore \\"
  log "       -srckeystore /tmp/appnode.p12 -srcstoretype PKCS12 -srcstorepass changeit \\"
  log "       -destkeystore <glide-dir>/conf/keystore.bcfks -deststoretype BCFKS \\"
  log "       -deststorepass changeit -destalias _identity_ \\"
  log "       -provider org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \\"
  log "       -providerpath \"\${BCFIPS_JAR}\" -noprompt"
  log ""
  log "     rm -f /tmp/appnode.p12"
  log ""
  log "  b) Import the AIS node certificate into a BCFKS truststore"
  log "     (so Glide trusts the AIS server certificate):"
  log ""
  log "     keytool -importcert \\"
  log "       -storetype BCFKS \\"
  log "       -keystore <glide-dir>/conf/truststore.bcfks -storepass changeit \\"
  log "       -alias aisnode -file aisnode.pem -noprompt \\"
  log "       -provider org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \\"
  log "       -providerpath \"\${BCFIPS_JAR}\""
  if [ -n "${PEER_HOST}" ]; then
    log ""
    log "     Also import the peer AIS node certificate (HA):"
    log "     keytool -importcert \\"
    log "       -storetype BCFKS \\"
    log "       -keystore <glide-dir>/conf/truststore.bcfks -storepass changeit \\"
    log "       -alias aisnode-peer -file aisnode-peer.pem -noprompt \\"
    log "       -provider org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \\"
    log "       -providerpath \"\${BCFIPS_JAR}\""
  fi
  log ""
  log "  c) Write <glide-dir>/conf/overrides.d/internal.services.properties:"
  log ""
  log "     glide.client.identity.key.path=../conf/keystore.bcfks"
  log "     glide.client.identity.key.password=changeit"
  log "     glide.client.identity.key.type=BCFKS"
  log "     glide.client.identity.trust.path=../conf/truststore.bcfks"
  log "     glide.client.identity.trust.password=changeit"
  log "     glide.client.identity.trust.type=BCFKS"
  log ""
  log "  d) Restart the Glide app node to pick up the new keystores."
  log ""
  log "────────────────────────────────────────────────────────────"
  log "  SERVICENOW INSTANCE — final configuration (as maint user)"
  log "────────────────────────────────────────────────────────────"
  log ""
  log "  1. Set system property glide.ais.partition_id to the AIS partition UUID."
  log "  2. Create two AI Search Connection records (ais_connection):"
  if [ -n "${PEER_HOST}" ]; then
    log "       Active  : https://$(hostname -f):${PORT}/"
    log "       Passive : https://${PEER_HOST}:${PEER_PORT}/"
  else
    log "       Active  : https://$(hostname -f):${PORT}/"
  fi
  log "  3. Click 'Test Connection' on each record to verify connectivity."
  log "  4. Click 'Enable AIS' to publish search profiles and trigger reindex."
  log "============================================================"
}

main "$@"
