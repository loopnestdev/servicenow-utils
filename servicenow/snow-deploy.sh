#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# ── DEFAULTS ──────────────────────────────────────────────────────────────────
INSTALL_DIR="/glide"
APP_VERSION=""
GLIDEBASE_VERSION="glide-base-20240329.tar.gz"
JDK_TARBALL=""
DB_HOST=""
DB_USER="snc"
DB_PASSWORD=""
DB_TYPE="mariadb"
DB_PORT=""
DB_SSL="true"
DB_TLS_MIN="TLSv1.2"
DB_NAME="snccor"
INSTANCES=4
CLUSTER_NAME=""
SNC_SSL="true"
PORT_START=16001
PROXY="haproxy"
SNC_CLEAN_INSTALL="auto"
SVC_PREFIX="snc"
SNC_USER="servicenow"
MEDIA_DIR="/data/snow_media"
BACKUP_DIR="/mnt/backup"
HAPROXY_STATPORT=14567
SKIP_DEPS="false"
SKIP_SELINUX="false"
SKIP_KMF="false"
KMF_PASSWORD="changeit"
KMF_ALIAS="256bitkey"
DB_SSL_CA=""

# ── USAGE ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOUSAGE

  USAGE: $0 [OPTIONS]

  Required:
    --app_version=<zip>           ServiceNow application zip filename
                                  e.g. glide-washingtondc-12-20-2023__patch2-03-27-2024.zip
    --db_host=<host>              Database hostname or IP
    --db_password=<password>      Database user password
    --cluster_name=<name>         ServiceNow cluster name

  Optional:
    --install_dir=<path>          SNC root installation directory    (default: /glide)
    --glidebase_version=<file>    Glide base tarball filename        (default: glide-base-20240329.tar.gz)
    --jdk_tarball=<file>          JDK tarball filename in media_dir  (required)
    --clean_install=<auto|true|false>
                                  auto  – detect from DB: empty DB = first node (init + wait),
                                          tables present = subsequent node (join directly) (default)
                                  true  – force first-node mode regardless of DB state
                                  false – force subsequent-node mode (skip DB init wait)
    --db_type=<mariadb|postgresql> Database engine type             (default: mariadb)
    --db_user=<user>              Database username                  (default: snc)
    --db_port=<port>              Database port (3306 mariadb / 5432 postgresql)
    --db_name=<name>              Database name                      (default: snccor)
    --db_ssl=<true|false>         Enable SSL for DB connection       (default: true)
    --db_ssl_ca=<file>            DB CA cert filename in media_dir (e.g. cacert.pem). When set,
                                  uses verify-ca + DefaultJavaSSLFactory (FIPS-compatible cert
                                  validation + reliable failover). Omit to use require +
                                  NonValidatingFactory (encrypted, no cert validation).
    --db_tls_min=<TLSv1.2|TLSv1.3> Minimum TLS version for DB SSL   (default: TLSv1.2)
    --instances=<count>           Number of SNC instances per VM     (default: 4)
    --svc_prefix=<prefix>         Systemd service name prefix        (default: snc)
                                  Services will be named <prefix>01, <prefix>02, ...
    --snc_user=<user>             OS user and group for SNC process  (default: servicenow)
    --snc_ssl=<true|false>        Enable SSL on proxy frontend       (default: true)
    --port_start=<port>           SNC HTTP port for first instance   (default: 16001)
    --proxy=<haproxy|nginx>       Reverse proxy to install          (default: haproxy)
    --media_dir=<path>            Directory for downloaded media     (default: /data/snow_media)
    --backup_dir=<path>           Backup destination directory       (default: /mnt/backup)
    --skip_deps                   Skip OS dependency installation (offline/pre-provisioned environments)
    --skip_selinux                Skip SELinux port labeling
    --skip_kmf                    Skip KMF keystore configuration
    --kmf_password=<password>     KMF keystore and key entry password    (default: changeit)
    --kmf_alias=<alias>           KMF key alias inside the keystore      (default: 256bitkey)
    --help                        Show this help

  Prerequisites in --media_dir (default: /data/snow_media):
    - ${GLIDEBASE_VERSION}         Glide base tarball
    - <app_version zip>            SNC patch zip
    - <jdk_tarball>                JDK tarball (e.g. jdk8u252-b09.tar.gz)
    - snow-backup.sh               Backup script
    - host.crt + host.key          SSL certificate/key (required if --snc_ssl=true)
    - <db_ssl_ca>                  DB CA cert PEM (required if --db_ssl_ca is set)

  Notes:
    - Database must be provisioned and reachable before running this script
    - SSL is terminated at the proxy level; SNC instances run plain HTTP
    - Run this script sequentially on each VM: first VM first, then the next

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

node_name() {
  echo "$(hostname -s)"
}

instance_node() {
  local seq=$1
  printf "%s-%02d" "$(node_name)" "${seq}"
}

instance_svc() {
  local seq=$1
  printf "%s%02d" "${SVC_PREFIX}" "${seq}"
}

instance_path() {
  local seq=$1
  echo "${INSTALL_DIR}/nodes/$(instance_node "${seq}")"
}

instance_http_port() {
  local seq=$1
  echo $(( PORT_START + seq - 1 ))
}

# ── ARGUMENT PARSING ──────────────────────────────────────────────────────────
parse_args() {
  if [ $# -eq 0 ]; then
    usage
    exit 1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --install_dir=*)      INSTALL_DIR="${1#*=}" ;;
      --app_version=*)      APP_VERSION="${1#*=}" ;;
      --glidebase_version=*) GLIDEBASE_VERSION="${1#*=}" ;;
      --jdk_tarball=*)      JDK_TARBALL="${1#*=}" ;;
      --clean_install=*)    SNC_CLEAN_INSTALL="${1#*=}" ;;
      --db_host=*)          DB_HOST="${1#*=}" ;;
      --db_user=*)          DB_USER="${1#*=}" ;;
      --db_password=*)      DB_PASSWORD="${1#*=}" ;;
      --db_type=*)          DB_TYPE="${1#*=}" ;;
      --db_port=*)          DB_PORT="${1#*=}" ;;
      --db_name=*)          DB_NAME="${1#*=}" ;;
      --db_ssl=*)           DB_SSL="${1#*=}" ;;
      --db_ssl_ca=*)        DB_SSL_CA="${1#*=}" ;;
      --db_tls_min=*)       DB_TLS_MIN="${1#*=}" ;;
      --instances=*)        INSTANCES="${1#*=}" ;;
      --svc_prefix=*)       SVC_PREFIX="${1#*=}" ;;
      --snc_user=*)         SNC_USER="${1#*=}" ;;
      --cluster_name=*)     CLUSTER_NAME="${1#*=}" ;;
      --snc_ssl=*)          SNC_SSL="${1#*=}" ;;
      --port_start=*)       PORT_START="${1#*=}" ;;
      --proxy=*)            PROXY="${1#*=}" ;;
      --media_dir=*)        MEDIA_DIR="${1#*=}" ;;
      --backup_dir=*)       BACKUP_DIR="${1#*=}" ;;
      --skip_deps)          SKIP_DEPS="true" ;;
      --skip_selinux)       SKIP_SELINUX="true" ;;
      --skip_kmf)           SKIP_KMF="true" ;;
      --kmf_password=*)     KMF_PASSWORD="${1#*=}" ;;
      --kmf_alias=*)        KMF_ALIAS="${1#*=}" ;;
      --help)               usage; exit 0 ;;
      *) die "Unknown argument: $1. Run $0 --help for usage." ;;
    esac
    shift
  done
}

validate_args() {
  [ -n "${APP_VERSION}" ]   || die "--app_version is required."
  [ -n "${DB_HOST}" ]       || die "--db_host is required."
  [ -n "${DB_PASSWORD}" ]   || die "--db_password is required."
  [ -n "${CLUSTER_NAME}" ]  || die "--cluster_name is required."
  [ -n "${JDK_TARBALL}" ]   || die "--jdk_tarball is required."

  case "${DB_TYPE}" in
    mariadb|postgresql) ;;
    *) die "--db_type must be 'mariadb' or 'postgresql'." ;;
  esac

  case "${PROXY}" in
    haproxy|nginx) ;;
    *) die "--proxy must be 'haproxy' or 'nginx'." ;;
  esac

  case "${DB_TLS_MIN}" in
    TLSv1.2|TLSv1.3) ;;
    *) die "--db_tls_min must be 'TLSv1.2' or 'TLSv1.3'." ;;
  esac

  case "${SNC_CLEAN_INSTALL}" in
    auto|true|false) ;;
    *) die "--clean_install must be 'auto', 'true', or 'false'." ;;
  esac

  if [ -z "${DB_PORT}" ]; then
    [ "${DB_TYPE}" = "postgresql" ] && DB_PORT=5432 || DB_PORT=3306
  fi

  [ -f "${MEDIA_DIR}/${GLIDEBASE_VERSION}" ] \
    || die "Glide base not found: ${MEDIA_DIR}/${GLIDEBASE_VERSION}"
  [ -f "${MEDIA_DIR}/${APP_VERSION}" ] \
    || die "App version zip not found: ${MEDIA_DIR}/${APP_VERSION}"
  [ -f "${MEDIA_DIR}/${JDK_TARBALL}" ] \
    || die "JDK tarball not found: ${MEDIA_DIR}/${JDK_TARBALL}"
  [ -f "${MEDIA_DIR}/snow-backup.sh" ] \
    || die "snow-backup.sh not found: ${MEDIA_DIR}/snow-backup.sh"

  if [ "${SNC_SSL}" = "true" ]; then
    [ -f "${MEDIA_DIR}/host.crt" ] || die "SSL cert not found: ${MEDIA_DIR}/host.crt"
    [ -f "${MEDIA_DIR}/host.key" ] || die "SSL key not found: ${MEDIA_DIR}/host.key"
  fi

  if [ -n "${DB_SSL_CA}" ]; then
    [ -f "${MEDIA_DIR}/${DB_SSL_CA}" ] || die "DB CA cert not found: ${MEDIA_DIR}/${DB_SSL_CA}"
  fi

  JAVA_DIR="${INSTALL_DIR}/java"

  if [ "${DB_SSL}" = "true" ]; then
    if [ "${DB_TLS_MIN}" = "TLSv1.3" ]; then
      DB_TLS_PROTOCOLS="TLSv1.3"
      DB_TLS_CIPHERS_JDBC="TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256"
      DB_TLS_CIPHERS_OPENSSL=""   # TLS 1.3 ciphers are auto-negotiated; ssl-cipher is TLS 1.2 only
    else
      DB_TLS_PROTOCOLS="TLSv1.3,TLSv1.2"
      DB_TLS_CIPHERS_JDBC="TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
      DB_TLS_CIPHERS_OPENSSL="ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256"
    fi
  fi

  if [ "${DB_TYPE}" = "mariadb" ]; then
    if [ "${DB_SSL}" = "true" ]; then
      JDBC_URL="jdbc:mariadb://${DB_HOST}:${DB_PORT}/${DB_NAME}?useSSL=true&trustServerCertificate=true&enabledSslProtocolSuites=${DB_TLS_PROTOCOLS}&enabledSSLCipherSuites=${DB_TLS_CIPHERS_JDBC}"
    else
      JDBC_URL="jdbc:mariadb://${DB_HOST}:${DB_PORT}/${DB_NAME}?useSSL=false"
    fi
  else
    JDBC_URL="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}"
  fi
}

# ── STEP 1: OS DEPENDENCIES ───────────────────────────────────────────────────
install_deps() {
  log "Installing OS dependencies..."

  dnf remove -y mysql-common 2>/dev/null || true

  dnf install -y \
    glibc \
    libgcc \
    rng-tools

  if [ "${DB_TYPE}" = "mariadb" ]; then
    dnf install -y mariadb
  else
    dnf install -y postgresql15
  fi

  if [ "${PROXY}" = "haproxy" ]; then
    dnf install -y haproxy
  else
    dnf install -y nginx
  fi

  log "OS dependencies installed."
}

# ── STEP 2: SYSTEM TUNING ─────────────────────────────────────────────────────
tune_system() {
  log "Tuning system parameters..."

  grep -q '^vm.swappiness' /etc/sysctl.conf \
    && sed -i 's/^vm.swappiness.*/vm.swappiness = 1/' /etc/sysctl.conf \
    || echo 'vm.swappiness = 1' >> /etc/sysctl.conf
  sysctl -w vm.swappiness=1

  cat >> /etc/security/limits.conf <<'LIMITS'
* soft nproc  10240
* soft nofile 16000
* hard nofile 16000
* hard stack  10240
LIMITS

  log "System tuning complete."
}

# ── STEP 3: OS USER AND GROUP ─────────────────────────────────────────────────
create_user_group() {
  log "Creating ${SNC_USER} user and group..."
  getent group "${SNC_USER}"  > /dev/null 2>&1 || groupadd "${SNC_USER}"
  id -u "${SNC_USER}"         > /dev/null 2>&1 || useradd -M -g "${SNC_USER}" "${SNC_USER}"
  log "User and group ready."
}

# ── STEP 4: DIRECTORIES ───────────────────────────────────────────────────────
create_directories() {
  log "Creating directories..."
  mkdir -p "${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}/java"
  mkdir -p "${INSTALL_DIR}/bin"
  mkdir -p "${INSTALL_DIR}/logs"
  mkdir -p "${INSTALL_DIR}/nodes"
  mkdir -p "${MEDIA_DIR}"
  log "Directories created."
}

# ── STEP 5: INSTALL JDK ───────────────────────────────────────────────────────
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

# ── STEP 6: EXTRACT GLIDE BASE ────────────────────────────────────────────────
extract_glidebase() {
  # Detect any directory in INSTALL_DIR that we did not create (java/bin/logs/nodes)
  if find "${INSTALL_DIR}" -maxdepth 1 -mindepth 1 -type d \
      ! -name java ! -name bin ! -name logs ! -name nodes | grep -q .; then
    log "Glide base already extracted to ${INSTALL_DIR}, skipping."
    return 0
  fi
  log "Extracting glide base to ${INSTALL_DIR}..."
  tar -xf "${MEDIA_DIR}/${GLIDEBASE_VERSION}" -C "${INSTALL_DIR}"
  log "Glide base extracted."
}

# ── STEP 8: WRITE CONFIG FILES PER INSTANCE ───────────────────────────────────
write_glide_db_properties() {
  local inst_path=$1
  mkdir -p "${inst_path}/conf"

  cat > "${inst_path}/conf/glide.db.properties" <<EOF
glide.db.name = ${DB_NAME}
glide.db.rdbms = $( [ "${DB_TYPE}" = "postgresql" ] && echo "postgresql" || echo "mysql" )
glide.db.url = ${JDBC_URL}
glide.db.user = ${DB_USER}
glide.db.password = ${DB_PASSWORD}
glide.db.password.encrypt=true
glide.db.pooler.connections=64
glide.db.pooler.connections.max=64
glide.sys.schedulers = 8
EOF
}

write_postgresql_ssl_properties() {
  local inst_path=$1
  [ "${DB_TYPE}" != "postgresql" ] && return 0
  [ "${DB_SSL}" != "true" ] && return 0
  mkdir -p "${inst_path}/conf/overrides.d"

  if [ -n "${DB_SSL_CA}" ]; then
    cat > "${inst_path}/conf/overrides.d/99-jdbc-tls.properties" <<EOF
glide.db.postgresql.jdbc.ssl=true
glide.db.postgresql.jdbc.sslmode=verify-ca
glide.db.postgresql.jdbc.sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory
EOF
  else
    cat > "${inst_path}/conf/overrides.d/99-jdbc-tls.properties" <<EOF
glide.db.postgresql.jdbc.ssl=true
glide.db.postgresql.jdbc.sslmode=require
glide.db.postgresql.jdbc.sslfactory=org.postgresql.ssl.NonValidatingFactory
EOF
  fi
}

write_glide_properties() {
  local inst_path=$1
  local http_port=$2
  local node=$3

  cat > "${inst_path}/conf/glide.properties" <<EOF
glide.servlet.host = 127.0.0.1
glide.servlet.port = ${http_port}
glide.cluster.node_name = ${node}

glide.monitor.url = localhost
glide.self.monitor.fast_stats = false
glide.self.monitor.checkin.interval = 86400000
glide.self.monitor.server_stats.interval = 86400000
glide.self.monitor.fast_server_stats.interval = 86400000

glide.usageanalytics.central_instance=https://disabled.service-now.com
glide.ua.downloader.central_instance=
EOF
}

write_jdk_overrides() {
  local inst_path=$1
  local jdk_major
  jdk_major=$(detect_jdk_major)
  mkdir -p "${inst_path}/conf/overrides.d"

  case "${jdk_major}" in
    8|11)
      cat > "${inst_path}/conf/overrides.d/51-memory.properties" <<'EOF'
glide.java.opts.snippet.nodeconfig.mem=-Xms128m -Xmx4096m -XX:ReservedCodeCacheSize=240m -XX:MaxDirectMemorySize=256m -XX:MaxMetaspaceSize=352m
EOF
      cat > "${inst_path}/conf/overrides.d/93-legacy-jdk.properties" <<'EOF'
glide.system.property.startup.jdk.io.permissionsUseCanonicalPath=true
glide.system.property.startup.java.locale.providers=JRE,SPI
glide.system.property.startup.sun.reflect.inflationThreshold=100000
glide.system.property.startup.jdk.nio.maxCachedBufferSize=262144
glide.system.property.startup.sun.io.useCanonCaches=false
glide.system.property.startup.sun.io.useCanonPrefixCache=false
EOF
      ;;
    17)
      cat > "${inst_path}/conf/overrides.d/51-memory.properties" <<'EOF'
glide.java.opts.snippet.nodeconfig.mem=-Xms1024m -Xmx4096m -XX:MaxMetaspaceSize=640m -XX:ReservedCodeCacheSize=240m -XX:MaxDirectMemorySize=256m
EOF
      cat > "${inst_path}/conf/overrides.d/92-access.properties" <<'EOF'
# https://support.servicenow.com/kb?id=kb_article_view&sysparm_article=KB1362432
glide.java.opts.snippet.nodeconfig.access=\
--add-opens=java.base/java.lang=ALL-UNNAMED \
--add-opens=java.base/java.time=ALL-UNNAMED \
--add-opens=java.base/java.util=ALL-UNNAMED \
--add-opens=java.base/java.util.regex=ALL-UNNAMED \
--add-opens=java.base/jdk.internal.perf=ALL-UNNAMED \
--add-opens=java.base/com.sun.crypto.provider=ALL-UNNAMED \
--add-opens=java.base/sun.reflect.annotation=ALL-UNNAMED \
--add-opens=java.base/sun.security.pkcs12=ALL-UNNAMED \
--add-opens=java.base/sun.security.provider=ALL-UNNAMED \
--add-opens=java.base/sun.security.util=ALL-UNNAMED \
--add-opens=java.base/sun.security.x509=ALL-UNNAMED \
--add-opens=java.naming/com.sun.jndi.ldap=ALL-UNNAMED \
--add-opens=java.xml.crypto/org.jcp.xml.dsig.internal.dom=ALL-UNNAMED \
--add-opens=java.management/sun.management=ALL-UNNAMED \
--add-exports=java.management/sun.management=ALL-UNNAMED
EOF
      cat > "${inst_path}/conf/overrides.d/93-legacy-jdk.properties" <<'EOF'
glide.system.property.startup.jdk.io.permissionsUseCanonicalPath=true
glide.system.property.startup.java.locale.providers=JRE,SPI
glide.system.property.startup.sun.reflect.inflationThreshold=100000
glide.system.property.startup.jdk.nio.maxCachedBufferSize=262144
glide.system.property.startup.sun.io.useCanonCaches=false
glide.system.property.startup.sun.io.useCanonPrefixCache=false
EOF
      cat > "${inst_path}/conf/overrides.d/98-general.properties" <<'EOF'
glide.java.opts.snippet.nodeconfig.general=-server -Xshare:off
glide.java.opts.snippet.nodeconfig.gc=-XX:+UseParallelGC -XX:ParallelGCThreads=15 -XX:+ParallelRefProcEnabled
glide.java.opts.snippet.nodeconfig.extra=-XX:CICompilerCount=12
EOF
      ;;
    21)
      cat > "${inst_path}/conf/overrides.d/05-cacerts.properties" <<EOF
glide.java.opts.snippet.1=-Djavax.net.ssl.trustStore=${inst_path}/conf/overrides.d/cacerts.bcfks -Djavax.net.ssl.trustStorePassword=changeit -Djava.net.preferIPv4Stack=true
EOF
      cat > "${inst_path}/conf/overrides.d/51-memory.properties" <<'EOF'
glide.java.opts.snippet.nodeconfig.mem=-Xms2048m -Xmx4096m -XX:MaxMetaspaceSize=640m -XX:ReservedCodeCacheSize=240m -XX:MaxDirectMemorySize=256m -XX:-UseAdaptiveSizePolicy
EOF
      cat > "${inst_path}/conf/overrides.d/86-security.properties" <<'EOF'
glide.java.opts.snippet.nodeconfig.security=-Djava.security.manager=allow
EOF
      cat > "${inst_path}/conf/overrides.d/88-xmldefault.properties" <<'EOF'
glide.system.property.startup.org.apache.xml.dtm.DTMManager=org.apache.xml.dtm.ref.DTMManagerDefault
glide.system.property.startup.javax.xml.stream.XMLInputFactory=com.ctc.wstx.stax.WstxInputFactory
glide.system.property.startup.javax.xml.stream.XMLOutputFactory=com.ctc.wstx.stax.WstxOutputFactory
EOF
      cat > "${inst_path}/conf/overrides.d/92-access.properties" <<'EOF'
# https://support.servicenow.com/kb?id=kb_article_view&sysparm_article=KB1362432
glide.java.opts.snippet.nodeconfig.access=\
--add-opens=java.base/java.lang=ALL-UNNAMED \
--add-opens=java.base/java.lang.module=ALL-UNNAMED \
--add-opens=java.base/java.time=ALL-UNNAMED \
--add-opens=java.base/java.util=ALL-UNNAMED \
--add-opens=java.base/java.util.regex=ALL-UNNAMED \
--add-opens=java.base/jdk.internal.module=ALL-UNNAMED \
--add-opens=java.base/jdk.internal.perf=ALL-UNNAMED \
--add-opens=java.base/com.sun.crypto.provider=ALL-UNNAMED \
--add-opens=java.base/sun.reflect.annotation=ALL-UNNAMED \
--add-opens=java.base/sun.security.pkcs12=ALL-UNNAMED \
--add-opens=java.base/sun.security.provider=ALL-UNNAMED \
--add-opens=java.base/sun.security.util=ALL-UNNAMED \
--add-opens=java.base/sun.security.x509=ALL-UNNAMED \
--add-opens=java.naming/com.sun.jndi.ldap=ALL-UNNAMED \
--add-opens=java.xml.crypto/org.jcp.xml.dsig.internal.dom=ALL-UNNAMED \
--add-opens=java.management/sun.management=ALL-UNNAMED \
--add-exports=java.management/sun.management=ALL-UNNAMED
EOF
      cat > "${inst_path}/conf/overrides.d/93-legacy-jdk.properties" <<'EOF'
glide.system.property.startup.jdk.io.permissionsUseCanonicalPath=true
glide.system.property.startup.java.locale.providers=JRE,SPI
glide.system.property.startup.sun.reflect.inflationThreshold=100000
glide.system.property.startup.jdk.nio.maxCachedBufferSize=262144
glide.system.property.startup.sun.io.useCanonCaches=false
glide.system.property.startup.sun.io.useCanonPrefixCache=false
EOF
      cat > "${inst_path}/conf/overrides.d/98-general.properties" <<'EOF'
glide.java.opts.snippet.nodeconfig.general=-server -Xshare:off
glide.java.opts.snippet.nodeconfig.gc=-XX:+UseParallelGC -XX:ParallelGCThreads=15 -XX:+ParallelRefProcEnabled
glide.java.opts.snippet.nodeconfig.extra=-XX:CICompilerCount=12
EOF
      ;;
    *)
      die "Unsupported JDK major version detected: ${jdk_major}. Supported: 8, 11, 17, 21"
      ;;
  esac
}

write_systemd_service() {
  local svc=$1
  local inst_path=$2

  cat > "/etc/systemd/system/${svc}.service" <<EOF
[Unit]
Description=ServiceNow Tomcat Container (${svc})
After=syslog.target network.target

[Service]
Environment=JAVA_HOME=${JAVA_DIR}
Environment=MALLOC_ARENA_MAX=1
Type=forking
ExecStart=${inst_path}/startup.sh
ExecStop=${inst_path}/shutdown.sh
User=${SNC_USER}
Group=${SNC_USER}
UMask=0007

[Install]
WantedBy=multi-user.target
EOF
}

convert_cacerts_bcfks() {
  local inst_path=$1
  local dest="${inst_path}/conf/overrides.d/cacerts.bcfks"

  [ -f "${dest}" ] && return 0

  local bc_fips_jar
  bc_fips_jar=$(find "${inst_path}/lib/jsw" -name "bc-fips-*.jar" 2>/dev/null | sort -V | tail -1)
  [ -z "${bc_fips_jar}" ] && return 0

  log "Converting cacerts JKS to BCFKS (${bc_fips_jar##*/})..."
  "${JAVA_DIR}/bin/keytool" \
    -importkeystore \
    -srckeystore "${JAVA_DIR}/lib/security/cacerts" \
    -srcstoretype JKS \
    -srcstorepass changeit \
    -destkeystore "${dest}" \
    -deststoretype BCFKS \
    -deststorepass changeit \
    -provider org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath "${bc_fips_jar}" \
    -noprompt
  log "cacerts BCFKS keystore written: ${dest}"
}

import_db_ssl_ca() {
  local inst_path=$1
  [ "${DB_TYPE}" != "postgresql" ] && return 0
  [ "${DB_SSL}" != "true" ] && return 0
  [ -z "${DB_SSL_CA}" ] && return 0

  local dest="${inst_path}/conf/overrides.d/cacerts.bcfks"
  [ -f "${dest}" ] || { log "cacerts.bcfks not found, skipping DB CA import."; return 0; }

  local bc_fips_jar
  bc_fips_jar=$(find "${inst_path}/lib/jsw" -name "bc-fips-*.jar" 2>/dev/null | sort -V | tail -1)
  [ -z "${bc_fips_jar}" ] && return 0

  if "${JAVA_DIR}/bin/keytool" -list -alias db-ca \
      -keystore "${dest}" -storetype BCFKS -storepass changeit \
      -provider org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
      -providerpath "${bc_fips_jar}" 2>/dev/null; then
    log "DB CA cert already in cacerts.bcfks, skipping import."
    return 0
  fi

  log "Importing DB CA cert into cacerts.bcfks (${MEDIA_DIR}/${DB_SSL_CA})..."
  "${JAVA_DIR}/bin/keytool" \
    -importcert \
    -alias db-ca \
    -file "${MEDIA_DIR}/${DB_SSL_CA}" \
    -keystore "${dest}" \
    -storetype BCFKS \
    -storepass changeit \
    -provider org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
    -providerpath "${bc_fips_jar}" \
    -noprompt
  log "DB CA cert imported into cacerts.bcfks."
}

configure_kmf() {
  local inst_path=$1
  local seq=$2

  [ "${SKIP_KMF}" = "true" ] && return 0

  local dest_keystore="${inst_path}/conf/overrides.d/keystorekmf.bcfks"
  local dest_props="${inst_path}/conf/overrides.d/glide.kmf.keystore.properties"
  local src_keystore="${MEDIA_DIR}/keystorekmf.bcfks"

  if [ ! -f "${dest_keystore}" ]; then
    if [ -f "${src_keystore}" ]; then
      log "Copying KMF keystore from ${src_keystore}..."
      cp "${src_keystore}" "${dest_keystore}"
    elif [ "${seq}" -eq 1 ]; then
      local bc_fips_jar
      bc_fips_jar=$(find "${inst_path}/lib/jsw" -name "bc-fips-*.jar" 2>/dev/null | sort -V | tail -1)
      [ -z "${bc_fips_jar}" ] && die "bc-fips jar not found in ${inst_path}/lib/jsw — cannot create KMF keystore."

      log "Creating KMF keystore (${bc_fips_jar##*/})..."
      "${JAVA_DIR}/bin/keytool" \
        -genseckey \
        -alias "${KMF_ALIAS}" \
        -keyalg aes \
        -keysize 256 \
        -providername BCFIPS \
        -providerclass org.bouncycastle.jcajce.provider.BouncyCastleFipsProvider \
        -providerpath "${bc_fips_jar}" \
        -keystore "${dest_keystore}" \
        -storetype bcfks \
        -storepass "${KMF_PASSWORD}" \
        -keypass "${KMF_PASSWORD}"

      cp "${dest_keystore}" "${src_keystore}"
      log "KMF keystore saved to ${src_keystore} for distribution to other instances and VMs."
    else
      die "KMF keystore not found in ${MEDIA_DIR}. Copy keystorekmf.bcfks from the first VM before running this script."
    fi
  fi

  cat > "${dest_props}" <<EOF
kmf.file.keystore.enabled=true
kmf.file.keystore.path=conf/overrides.d
kmf.file.keystore.name=keystorekmf.bcfks
kmf.file.keystore.type=BCFKS
kmf.file.keystore.password=${KMF_PASSWORD}
kmf.file.keystore.imk.alias=${KMF_ALIAS}
kmf.file.key.entry.password=${KMF_PASSWORD}
EOF

  log "KMF configuration written: ${dest_props}"
}

# ── STEP 9: INSTALL ONE SNC INSTANCE ─────────────────────────────────────────
install_instance() {
  local seq=$1
  local node; node="$(instance_node "${seq}")"
  local svc;  svc="$(instance_svc "${seq}")"
  local inst; inst="$(instance_path "${seq}")"
  local port; port="$(instance_http_port "${seq}")"

  if [ -d "${inst}" ] && [ -f "/etc/systemd/system/${svc}.service" ]; then
    log "Instance ${seq} (${svc}) already deployed, skipping installation."
    systemctl is-active --quiet "${svc}" || systemctl start "${svc}"
    return 0
  fi

  log "Installing instance ${seq}: ${node} on port ${port}..."

  "${JAVA_DIR}/bin/java" \
    -jar "${MEDIA_DIR}/${APP_VERSION}" \
    --dst-dir "${inst}" \
    install -n "${node}" -p "${port}"

  write_glide_db_properties "${inst}"
  write_glide_properties          "${inst}" "${port}" "${node}"
  write_jdk_overrides             "${inst}"
  write_postgresql_ssl_properties "${inst}"
  convert_cacerts_bcfks           "${inst}"
  import_db_ssl_ca                "${inst}"
  configure_kmf                   "${inst}" "${seq}"
  write_systemd_service      "${svc}"  "${inst}"

  chown -R "${SNC_USER}:${SNC_USER}" "${inst}"
  chmod -R 755 "${inst}"

  systemctl daemon-reload
  systemctl enable "${svc}"
  systemctl start  "${svc}"

  log "Instance ${seq} (${svc}) started."
}

db_query() {
  # Execute a SQL query against the configured DB engine.
  # Credentials come from /etc/my.cnf.d (MariaDB) or PGPASSWORD env var (PostgreSQL).
  local query="$1"
  if [ "${DB_TYPE}" = "postgresql" ]; then
    local pgssl="disable"
    [ "${DB_SSL}" = "true" ] && pgssl="require"
    PGPASSWORD="${DB_PASSWORD}" PGSSLMODE="${pgssl}" \
      psql --host="${DB_HOST}" --port="${DB_PORT}" --username="${DB_USER}" \
           --dbname="${DB_NAME}" --tuples-only --no-align \
           --command="${query}"
  else
    local ssl_flag=""
    [ "${DB_SSL}" = "true" ] && ssl_flag="--ssl"
    mysql --host="${DB_HOST}" --port="${DB_PORT}" --user="${DB_USER}" \
      ${ssl_flag} --skip-column-names -e "${query}"
  fi
}

wait_for_db_init() {
  local query="SELECT summary_complete_status FROM ${DB_NAME}.sys_upgrade_history ORDER BY upgrade_started DESC LIMIT 1;"

  # Idempotency: skip wait if schema initialisation already completed
  local current
  current=$(db_query "${query}" 2>/dev/null || true)
  if echo "${current}" | grep -q "complete"; then
    log "DB schema already initialised, skipping wait."
    return 0
  fi

  log "Waiting for DB schema initialisation (can take 4-9 hours)..."

  local attempt=0
  local max_attempts=1620  # 9 hours at 20s intervals

  until db_query "${query}" 2>/dev/null | grep -q "complete"; do
    attempt=$(( attempt + 1 ))
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      die "DB initialisation did not complete after $(( max_attempts * 20 / 3600 )) hours."
    fi
    if [ $(( attempt % 90 )) -eq 0 ]; then
      log "Still waiting for DB init... $(( attempt * 20 / 60 )) min elapsed."
    fi
    sleep 20
  done

  log "DB schema initialisation complete."
}

insert_glide_war() {
  log "Inserting glide.war version into sys_properties..."
  local query
  if [ "${DB_TYPE}" = "postgresql" ]; then
    query="INSERT INTO sys_properties(name,type,is_private,description,value)
           VALUES ('glide.war','string',1,'Current version','${APP_VERSION}')
           ON CONFLICT DO NOTHING;"
  else
    query="INSERT IGNORE INTO ${DB_NAME}.sys_properties(name,type,is_private,description,value)
           VALUES ('glide.war','string',1,'Current version','${APP_VERSION}');"
  fi
  db_query "${query}"
  log "glide.war inserted."
}

detect_install_mode() {
  local query="SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';"

  local result
  if ! result=$(db_query "${query}" 2>&1); then
    die "Cannot connect to DB ${DB_HOST}:${DB_PORT} to detect node role: ${result}"
  fi

  local table_count
  table_count=$(echo "${result}" | tr -d '[:space:]')

  if [ "${table_count:-0}" -eq 0 ] 2>/dev/null; then
    log "DB has no tables — first node (clean install)." >&2
    echo "first"
  else
    log "DB has ${table_count} table(s) — subsequent node (join cluster)." >&2
    echo "subsequent"
  fi
}

install_all_instances() {
  local mode="${SNC_CLEAN_INSTALL}"

  if [ "${mode}" = "auto" ]; then
    mode=$(detect_install_mode)
  fi

  if [ "${mode}" = "true" ] || [ "${mode}" = "first" ]; then
    log "First node: deploying instance 1 for DB initialisation..."
    install_instance 1

    wait_for_db_init
    insert_glide_war

    if [ "${INSTANCES}" -gt 1 ]; then
      log "DB ready. Deploying remaining $(( INSTANCES - 1 )) instance(s) on this node..."
      local seq
      for seq in $(seq 2 "${INSTANCES}"); do
        install_instance "${seq}"
      done
    fi
  else
    log "Subsequent node: deploying ${INSTANCES} instance(s) and joining cluster..."
    local seq
    for seq in $(seq 1 "${INSTANCES}"); do
      install_instance "${seq}"
    done
  fi

  log "All instances on $(hostname -s) installed."
}

# ── STEP 10: PROXY ────────────────────────────────────────────────────────────
setup_ssl_cert_haproxy() {
  local cfg_path=/etc/haproxy

  log "Preparing SSL certificates for HAProxy..."
  cat "${MEDIA_DIR}/host.crt" "${MEDIA_DIR}/host.key" > "${cfg_path}/host.pem"
  chmod 600 "${cfg_path}/host.pem"

  if [ ! -f "${cfg_path}/dhparam-2048.pem" ]; then
    log "Generating DH parameters (this may take a few minutes)..."
    openssl dhparam -out "${cfg_path}/dhparam-2048.pem" 2048
  fi
}

setup_ssl_cert_nginx() {
  local ssl_dir=/etc/nginx/ssl

  log "Preparing SSL certificates for nginx..."
  mkdir -p "${ssl_dir}"
  cp "${MEDIA_DIR}/host.crt" "${ssl_dir}/host.crt"
  cp "${MEDIA_DIR}/host.key" "${ssl_dir}/host.key"
  chmod 600 "${ssl_dir}/host.key"
}

install_haproxy() {
  local cfg_path=/etc/haproxy
  local ncpus; ncpus=$(nproc)
  local nbthread=$(( ncpus / 4 ))
  [ "${nbthread}" -lt 1 ] && nbthread=1

  log "Configuring HAProxy (${INSTANCES} instance(s), single frontend on :443)..."

  [ "${SNC_SSL}" = "true" ] && setup_ssl_cert_haproxy

  # global + defaults
  cat > "${cfg_path}/haproxy.cfg" <<EOF
global
  nbthread              ${nbthread}
  cpu-map               auto:1/1-${nbthread} 0-$(( nbthread - 1 ))
  maxconn               100000
  log                   127.0.0.1 local2
  chroot                /var/empty
  user                  haproxy
  group                 haproxy
  daemon
  tune.ssl.cachesize    1000000
  tune.maxrewrite       4096
  stats                 socket 127.0.0.1:${HAPROXY_STATPORT}
EOF

  if [ "${SNC_SSL}" = "true" ]; then
    cat >> "${cfg_path}/haproxy.cfg" <<EOF

  # Hardening: disable older TLS versions and weak ciphers
  ssl-default-bind-curves         secp384r1:secp521r1:prime256v1
  ssl-default-bind-options        ssl-min-ver TLSv1.3
  ssl-default-bind-ciphersuites   TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256
  ssl-default-server-options      ssl-min-ver TLSv1.3
  ssl-default-server-ciphersuites TLS_AES_256_GCM_SHA384:TLS_AES_128_GCM_SHA256
  ssl-dh-param-file     ${cfg_path}/dhparam-2048.pem

EOF
  fi

  cat >> "${cfg_path}/haproxy.cfg" <<'EOF'
defaults
  mode                  http
  log                   global
  option                dontlognull
  option                http-server-close
  option                redispatch
  retries               3
  timeout http-request  15s
  timeout queue         1m
  timeout connect       5s
  timeout client        60s
  timeout server        301s
  timeout http-keep-alive 120s
  timeout check         10s
  timeout tunnel        10m
  timeout client-fin    10s
  timeout server-fin    10s

frontend stats
  bind                  *:14567
  mode                  http
  stats                 enable
  stats                 hide-version
  stats                 realm HAProxy\ Statistics
  stats                 uri /stats
  stats                 refresh 30s

EOF

  # Single frontend on :443 → single backend pool of all instances
  local bind_line
  if [ "${SNC_SSL}" = "true" ]; then
    bind_line="bind 0.0.0.0:443 ssl crt ${cfg_path}/host.pem"
  else
    bind_line="bind 0.0.0.0:443"
  fi

  cat >> "${cfg_path}/haproxy.cfg" <<EOF
frontend snc-frontend
  ${bind_line}
  option                httplog
  option                forwardfor
  option                http-server-close

  ### Transaction ID ###
  unique-id-format %[uuid()]
  unique-id-header X-Unique-ID
  log-tag snow
  log-format {\"timestamp\":\"%tr\",\"application\":\"snow\",\"client_ip\":\"%ci\",\"fe_name\":\"%f\",\"fe_ip\":\"%fi\",\"fe_port\":\"%fp\",\"fe_conn\":\"%fc\",\"be_name\":\"%b\",\"server_name\":\"%s\",\"server_ip\":\"%si\",\"server_port\":\"%sp\",\"srv_conn\":\"%sc\",\"http_method\":\"%HM\",\"http_proto\":\"https\",\"host\":\"%hrl\",\"http_uri\":\"%HU\",\"status_code\":\"%ST\",\"response_time\":\"%Tr\",\"bytes_read\":\"%B\",\"request_cookie\":\"%CC\",\"response_cookie\":\"%CS\",\"termination_state\":\"%ts\",\"active_conn\":\"%ac\",\"retries\":\"%rc\",\"srv_queue\":\"%sq\",\"backend_queue\":\"%bq\",\"x-unique-id\":\"%ID\"}

 acl is_be_healthy path /hello
    acl backends_down   nbsrv(snc-backend) lt 1
    http-request return status 503 content-type "text/plain" string "down" if is_be_healthy backends_down
    http-request return status 200 content-type "text/plain" string "ok"   if is_be_healthy

  # Inform backend of original protocol and host
  http-request          set-header X-Forwarded-Host %[req.hdr(host)]
  http-request          set-header X-Forwarded-Proto https if { ssl_fc }
  http-request          set-header X-Forwarded-Proto http if !{ ssl_fc }

  # HSTS and secure cookie flags (per ServiceNow LB guidance)
  http-after-response   set-header Strict-Transport-Security "max-age=63072000; includeSubDomains;"
  http-after-response   replace-header Set-Cookie '(^((?!(?i)httponly).)*$)' '\1; HttpOnly'
  http-after-response   replace-header Set-Cookie '(^((?!(?i)secure).)*$)' '\1; Secure'

  # Rewrite http→https in Location redirects from SNC
  http-response         replace-header Location ^http://(.*)$ https://\1

  default_backend       snc-backend

backend snc-backend
  mode                  http
  balance               leastconn
  option                httpchk
  http-check send       meth GET uri /stats.do
  # HAProxy-managed session cookie for connection persistence (required by ServiceNow)
  cookie                SERVERID insert indirect nocache

EOF

  local seq
  for seq in $(seq 1 "${INSTANCES}"); do
    local node;      node="$(instance_node "${seq}")"
    local http_port; http_port="$(instance_http_port "${seq}")"
    cat >> "${cfg_path}/haproxy.cfg" <<EOF
  server                ${node} 127.0.0.1:${http_port} check cookie ${node}
EOF
  done
  echo "" >> "${cfg_path}/haproxy.cfg"

  # rsyslog + logrotate for haproxy
  mkdir -p /var/log/haproxy

  cat > /etc/rsyslog.d/30-haproxy.conf <<'EOF'
module(load="imudp")
input(type="imudp" port="514")

$template HAProxy,"%syslogtag%%msg:::drop-last-lf%\n"
$template TraditionalFormatWithPRI,"%pri-text%: %timegenerated% %syslogtag%%msg:::drop-last-lf%\n"

local2.=info     /var/log/haproxy/access.log;HAProxy
local2.=notice;local2.=warning /var/log/haproxy/status.log;TraditionalFormatWithPRI
local2.error     /var/log/haproxy/error.log;TraditionalFormatWithPRI
local2.* stop
EOF

  cat > /etc/logrotate.d/haproxy <<'EOF'
/var/log/haproxy/*.log {
  daily
  rotate 7
  missingok
  notifempty
  compress
  sharedscripts
  postrotate
    /bin/kill -HUP $(cat /var/run/rsyslogd.pid 2>/dev/null) 2>/dev/null || true
  endscript
}
EOF

  systemctl restart rsyslog
  systemctl enable  haproxy
  systemctl restart haproxy

  log "HAProxy configured and started."
}

install_nginx() {
  local ssl_dir=/etc/nginx/ssl
  local conf_dir=/etc/nginx/conf.d

  log "Configuring nginx (${INSTANCES} instance(s), single frontend on :443)..."

  [ "${SNC_SSL}" = "true" ] && setup_ssl_cert_nginx

  rm -f "${conf_dir}/default.conf"

  # Build upstream block dynamically from all instances
  {
    echo "upstream snc_backend {"
    echo "  least_conn;"
    local seq
    for seq in $(seq 1 "${INSTANCES}"); do
      local http_port; http_port="$(instance_http_port "${seq}")"
      echo "  server 127.0.0.1:${http_port};"
    done
    echo "}"
    echo ""
  } > "${conf_dir}/snc.conf"

  local listen_line
  if [ "${SNC_SSL}" = "true" ]; then
    listen_line="listen 443 ssl http2;"
  else
    listen_line="listen 443;"
  fi

  cat >> "${conf_dir}/snc.conf" <<EOF
server {
  ${listen_line}
  server_name _;

EOF

  if [ "${SNC_SSL}" = "true" ]; then
    cat >> "${conf_dir}/snc.conf" <<EOF
  ssl_certificate          ${ssl_dir}/host.crt;
  ssl_certificate_key      ${ssl_dir}/host.key;
  ssl_protocols            TLSv1.2 TLSv1.3;
  ssl_ciphers              ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256;
  ssl_prefer_server_ciphers on;

  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;

EOF
  fi

  cat >> "${conf_dir}/snc.conf" <<'EOF'
  location / {
    proxy_pass              http://snc_backend;
    proxy_http_version      1.1;
    proxy_set_header        Host              $host;
    proxy_set_header        X-Real-IP         $remote_addr;
    proxy_set_header        X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header        X-Forwarded-Host  $host;
    proxy_set_header        X-Forwarded-Proto $scheme;
    proxy_set_header        Upgrade           $http_upgrade;
    proxy_set_header        Connection        "upgrade";
    proxy_read_timeout      300s;
    proxy_send_timeout      300s;

    # Rewrite http→https in Location redirects from SNC
    proxy_redirect          http://$host/ https://$host/;

    # Mark SNC cookies as Secure (per ServiceNow LB guidance)
    proxy_cookie_flags      JSESSIONID secure;
    proxy_cookie_flags      glide_user secure;
    proxy_cookie_flags      glide_user_route secure;
    proxy_cookie_flags      glide_user_session secure;
    proxy_cookie_flags      glide_session_store secure;
    proxy_cookie_flags      glide_user_activity secure;
    proxy_cookie_flags      BAYEUX_BROWSER HttpOnly secure;
  }

  access_log /var/log/nginx/snc-access.log;
  error_log  /var/log/nginx/snc-error.log;
}
EOF
  log "nginx config written (single frontend :443 → upstream pool of ${INSTANCES} instance(s))"

  cat > /etc/logrotate.d/nginx-snc <<'EOF'
/var/log/nginx/snc-access.log /var/log/nginx/snc-error.log {
  daily
  rotate 30
  missingok
  notifempty
  compress
  sharedscripts
  postrotate
    nginx -s reopen 2>/dev/null || true
  endscript
}
EOF

  nginx -t || die "nginx configuration test failed."
  systemctl enable  nginx
  systemctl restart nginx

  log "nginx configured and started."
}

install_proxy() {
  if [ "${PROXY}" = "haproxy" ]; then
    install_haproxy
  else
    install_nginx
  fi
}

# ── STEP 11: MARIADB CLIENT CONFIG ────────────────────────────────────────────
configure_mariadb_client() {
  [ "${DB_TYPE}" = "mariadb" ] || return 0

  log "Writing MariaDB client config..."
  mkdir -p /etc/my.cnf.d

  if [ "${DB_SSL}" = "true" ]; then
    if [ -n "${DB_TLS_CIPHERS_OPENSSL}" ]; then
      cat > /etc/my.cnf.d/mariadb-client.cnf <<EOF
[client]
user        = ${DB_USER}
password    = ${DB_PASSWORD}
ssl
ssl-cipher  = ${DB_TLS_CIPHERS_OPENSSL}
tls-version = ${DB_TLS_PROTOCOLS}

[mysqldump]
user        = ${DB_USER}
password    = ${DB_PASSWORD}
ssl
ssl-cipher  = ${DB_TLS_CIPHERS_OPENSSL}
tls-version = ${DB_TLS_PROTOCOLS}
EOF
    else
      cat > /etc/my.cnf.d/mariadb-client.cnf <<EOF
[client]
user        = ${DB_USER}
password    = ${DB_PASSWORD}
ssl
tls-version = ${DB_TLS_PROTOCOLS}

[mysqldump]
user        = ${DB_USER}
password    = ${DB_PASSWORD}
ssl
tls-version = ${DB_TLS_PROTOCOLS}
EOF
    fi
  else
    cat > /etc/my.cnf.d/mariadb-client.cnf <<EOF
[client]
user     = ${DB_USER}
password = ${DB_PASSWORD}

[mysqldump]
user     = ${DB_USER}
password = ${DB_PASSWORD}
EOF
  fi

  chmod 640 /etc/my.cnf.d/mariadb-client.cnf
  log "MariaDB client config written."
}

# ── STEP 12: BACKUP SCRIPT ────────────────────────────────────────────────────
configure_backup() {
  log "Configuring backup..."

  cp "${MEDIA_DIR}/snow-backup.sh" "${INSTALL_DIR}/bin/snow-backup.sh"
  chown "${SNC_USER}:${SNC_USER}" "${INSTALL_DIR}/bin/snow-backup.sh"
  chmod 755                       "${INSTALL_DIR}/bin/snow-backup.sh"

  echo 'CRONARGS=-m off' > /etc/sysconfig/crond

  cat > /etc/cron.d/snccor <<EOF
MAILTO=""

0 */12 * * * root ${INSTALL_DIR}/bin/snow-backup.sh --src_dir=${INSTALL_DIR}/nodes --des_dir=${BACKUP_DIR} --log_dir=${INSTALL_DIR}/logs
EOF

  chmod 600 /etc/cron.d/snccor
  systemctl enable crond
  systemctl restart crond

  log "Backup cron configured."
}

# ── STEP 13: LOGROTATE ────────────────────────────────────────────────────────
configure_logrotate() {
  log "Configuring logrotate for ServiceNow logs..."

  cat > /etc/logrotate.d/snow <<EOF
${INSTALL_DIR}/logs/*.log {
  rotate 7
  daily
  compress
  missingok
  dateext
}
EOF

  cat >> /etc/cron.d/snow <<EOF

# Delete SNOW post-compressed logs older than 3 days
0 2 * * * root find ${INSTALL_DIR}/nodes/*/logs -name "*.gz" -mtime +3 -delete 2>/dev/null
EOF

  log "Logrotate configured."
}

# ── STEP 14: SELINUX PORT LABELS ─────────────────────────────────────────────
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

  local seq
  for seq in $(seq 1 "${INSTANCES}"); do
    label_port "$(instance_http_port "${seq}")" "SNC instance ${seq}"
  done

  label_port "${HAPROXY_STATPORT}" "HAProxy stats"
}

# ── STEP 15: MARIADB MASTER MONITOR ──────────────────────────────────────────
configure_mariadb_monitoring() {
  [ "${DB_TYPE}" = "mariadb" ] || return 0

  log "Configuring MariaDB master monitor..."
  mkdir -p "${INSTALL_DIR}/logs"

  cat > "${INSTALL_DIR}/bin/mdb_master_check.sh" <<'SCRIPT'
#!/bin/bash
shopt -s expand_aliases
alias now='date "+%F %T.%3N %Z"'

usage() {
  cat <<EOUSAGE
  USAGE: $0
    [--db_vipname=<hostname>]   VIP/DNS name for DB master
    [--db_ips=<ip1,ip2,...>]    Comma-separated DB node IPs
    [--log_dir=<path>]          Log directory
    [--help]
EOUSAGE
}

[ $# -eq 0 ] && { usage; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --db_vipname=*) db_vipname="${1#*=}" ;;
    --db_ips=*)     db_ips="${1#*=}" ;;
    --log_dir=*)    log_dir="${1#*=}" ;;
    --help)         usage; exit 0 ;;
    *)              usage; exit 1 ;;
  esac
  shift
done

LOG_FILE="${log_dir}/mariadbMasterCheck.log"
LOG_MDBMASTER="${log_dir}/mariadbMasterHistory.log"

checkMariaDBRole() {
  http_code=$(curl --connect-timeout 5 -s -o /dev/null -w '%{http_code}' "http://$1:8888/")
  echo "$http_code"
}

determineMariaDBRole() {
  for dbip in $(echo "${db_ips}" | sed "s/,/ /g"); do
    amimaster=$(checkMariaDBRole "${dbip}")
    if [ "${amimaster}" = "200" ]; then
      echo "$(now) INFO - Master: ${dbip}" >> "${LOG_MDBMASTER}"
      currentMasterIp="${dbip}"
      break
    fi
  done
}

checkAndUpdateHostsFile() {
  if ! grep -qE "${currentMasterIp}\s+${db_vipname}" /etc/hosts; then
    echo "$(now) WARNING - Updating ${db_vipname} → ${currentMasterIp}" >> "${LOG_FILE}"
    sed -i "s/.*${db_vipname}/${currentMasterIp} ${db_vipname}/g" /etc/hosts
  else
    echo "$(now) INFO - ${db_vipname} already points to ${currentMasterIp}" >> "${LOG_FILE}"
  fi
}

currentMasterIp=""
determineMariaDBRole

if [ -z "${currentMasterIp}" ]; then
  echo "$(now) ERROR - No master detected." >> "${LOG_FILE}"
  exit 0
fi

checkAndUpdateHostsFile
SCRIPT

  chmod 755 "${INSTALL_DIR}/bin/mdb_master_check.sh"
  chown root:root "${INSTALL_DIR}/bin/mdb_master_check.sh"

  cat >> /etc/cron.d/snccor <<EOF

*/2 * * * * root ${INSTALL_DIR}/bin/mdb_master_check.sh --db_vipname=${DB_HOST} --db_ips=${DB_HOST} --log_dir=${INSTALL_DIR}/logs
EOF

  log "MariaDB monitor configured."
}

# ── STEP 15: WAIT FOR SNC INSTANCES ──────────────────────────────────────────
wait_for_snc() {
  log "Waiting for ServiceNow instances to become available..."

  local seq
  for seq in $(seq 1 "${INSTANCES}"); do
    local port; port="$(instance_http_port "${seq}")"
    local node; node="$(instance_node "${seq}")"
    local attempt=0
    local max_attempts=180

    log "Polling instance ${seq} (${node}) on port ${port}..."
    until curl -s -o /dev/null -w "%{http_code}" \
        "http://127.0.0.1:${port}/stats.do" 2>/dev/null | grep -q "200"; do
      attempt=$(( attempt + 1 ))
      if [ "${attempt}" -ge "${max_attempts}" ]; then
        die "Instance ${seq} did not become healthy after $(( max_attempts * 30 ))s."
      fi
      sleep 30
    done

    log "Instance ${seq} (${node}) is up."
  done

  log "All instances are up."
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  require_root
  validate_args

  log "============================================================"
  log "ServiceNow Deployment"
  log "  Host        : $(hostname -f)"
  log "  Install dir : ${INSTALL_DIR}"
  log "  App version : ${APP_VERSION}"
  log "  JDK         : ${JDK_TARBALL}"
  log "  Node mode    : ${SNC_CLEAN_INSTALL} (auto=detect from DB)"
  log "  DB host     : ${DB_HOST}:${DB_PORT} (${DB_TYPE})"
  log "  Instances   : ${INSTANCES} (ports ${PORT_START}-$(( PORT_START + INSTANCES - 1 )))"
  log "  Proxy       : ${PROXY} (:443, SSL=${SNC_SSL}, leastconn, SERVERID cookie)"
  log "  Cluster     : ${CLUSTER_NAME}"
  log "============================================================"

  [ "${SKIP_DEPS}" = "true" ] && log "Skipping OS dependency installation (--skip_deps)." || install_deps
  tune_system
  create_user_group
  create_directories
  install_jdk
  extract_glidebase
  configure_mariadb_client
  install_all_instances
  install_proxy
  configure_selinux
  configure_backup
  configure_logrotate
  configure_mariadb_monitoring
  wait_for_snc

  log "============================================================"
  log "Deployment complete on $(hostname -f)"
  log "Proxy :443 → backend pool:"
  local seq
  for seq in $(seq 1 "${INSTANCES}"); do
    log "  $(instance_svc "${seq}") → 127.0.0.1:$(instance_http_port "${seq}")"
  done
  log "============================================================"
}

main "$@"
