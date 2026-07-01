#!/bin/bash
set -euo pipefail

# ── DEFAULTS ──────────────────────────────────────────────────────────────────
JDK_TARBALL=""
INSTALL_DIR="/data/glide/java"
MEDIA_DIR="/data/snow_media"

# ── USAGE ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOUSAGE

  USAGE: $0
      --jdk_tarball=<file>     JDK tarball filename in media_dir         (required)
      --install_dir=<path>     Directory to extract JDK into             (default: /data/glide/java)
      --media_dir=<path>       Directory containing the JDK tarball      (default: /data/snow_media)
      --help                   Show this help

  Example:
      $0 --jdk_tarball=jdk8u252-b09.tar.gz
      $0 --jdk_tarball=jdk-17.0.11+9.tar.gz --install_dir=/opt/java --media_dir=/mnt/media

EOUSAGE
}

# ── HELPERS ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ── ARGUMENT PARSING ──────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
  usage
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --jdk_tarball=*)  JDK_TARBALL="${1#*=}" ;;
    --install_dir=*)  INSTALL_DIR="${1#*=}" ;;
    --media_dir=*)    MEDIA_DIR="${1#*=}" ;;
    --help)           usage; exit 0 ;;
    *) die "Unknown argument: $1. Run $0 --help for usage." ;;
  esac
  shift
done

# ── VALIDATE ──────────────────────────────────────────────────────────────────
[ -n "${JDK_TARBALL}" ] || die "--jdk_tarball is required."
[ -f "${MEDIA_DIR}/${JDK_TARBALL}" ] || die "JDK tarball not found: ${MEDIA_DIR}/${JDK_TARBALL}"

# ── INSTALL ───────────────────────────────────────────────────────────────────
if [ -x "${INSTALL_DIR}/bin/java" ]; then
  log "JDK already present at ${INSTALL_DIR}, skipping extraction."
  log "Version: $(${INSTALL_DIR}/bin/java -version 2>&1 | head -1)"
  exit 0
fi

log "Installing JDK from tarball: ${JDK_TARBALL} → ${INSTALL_DIR}..."

rm -rf "${INSTALL_DIR:?}"
mkdir -p "${INSTALL_DIR}"
tar -xf "${MEDIA_DIR}/${JDK_TARBALL}" -C "${INSTALL_DIR}"

extracted_dir=$(ls -1 "${INSTALL_DIR}" | head -1)
if [ -n "${extracted_dir}" ] && [ -d "${INSTALL_DIR}/${extracted_dir}" ]; then
  cp -r "${INSTALL_DIR}/${extracted_dir}/." "${INSTALL_DIR}/"
  rm -rf "${INSTALL_DIR:?}/${extracted_dir}"
fi

[ -x "${INSTALL_DIR}/bin/java" ] || die "Extraction completed but ${INSTALL_DIR}/bin/java not found."

echo "export JAVA_HOME=${INSTALL_DIR}" > /etc/profile.d/jdk_JAVA_HOME.sh
echo "export PATH=\$PATH:${INSTALL_DIR}/bin" > /etc/profile.d/jdk_PATH.sh

log "JDK installed: $(${INSTALL_DIR}/bin/java -version 2>&1 | head -1)"
log "JAVA_HOME=${INSTALL_DIR} written to /etc/profile.d/jdk_JAVA_HOME.sh"
