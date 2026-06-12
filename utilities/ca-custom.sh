#/bin/bash

# USAGE INFO
usage() {
  cat <<EOUSAGE

  USAGE: $0
      [--base_dir=base_directory]   --> Optional (Default: /usr/local/etc/custom-ca)
      [--action=action]             --> Optional (Default: 'issue', can be 'remove')
      [--cert_purpose=purpose]      --> Optional (Default: 'serverAuth', can be 'serverAuth', 'clientAuth', or 'both')
      [--server_name=server_name]   --> Required (single hostname, or comma-separated FQDNs for multi-SAN certs)
      [--domain_name=domain_name]   --> Optional (Default: internal.local)
      [--server_keysize=keysize]    --> Optional (Default: 3072)
      [--help]

      INFO: This script sets up a custom Certificate Authority (CA) and generates server certificates.
      Note: 
        - If existing CA has already been created, use password from CUSTOMCAPASS (Azure Keyvault)
        - Ideally run on the first IDM server, as it will initialize the CA and store index in there
EOUSAGE
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

# Parse parameters
while [ $# -gt 0 ]; do
  case "$1" in
    --base_dir=*)
      base_dir="${1#*=}"
      ;;
    --action=*)
      action="${1#*=}"
      ;;
    --server_name=*)
      server_name="${1#*=}"
      ;;
    --domain_name=*)
      domain_name="${1#*=}"
      ;;
    --server_keysize=*)
      server_keysize="${1#*=}"
      ;;
    --cert_purpose=*)
      cert_purpose="${1#*=}"
      ;;
    --help=*)
      usage
      exit
      ;;
    *)
      usage
      exit 1
  esac
  shift
done


##### VARIABLES
export BASE_DIR=${base_dir:-/usr/local/etc/custom-ca}
export ACTION=${action:-issue}
export CERT_PURPOSE=${cert_purpose:-serverAuth}
export SERVER_NAME=${server_name}
export DOMAIN_NAME=${domain_name:-internal.local}
export OPENSSL_CA_CONF="${BASE_DIR}/conf/openssl-ca.cnf"
export CA_COMMONNAME="Self-Signed CA"
export CA_CERT_EXPIRY=3650
export SERVER_KEYSIZE=${server_keysize:-3072}
export SERVER_CERT_EXPIRY=730

# Normalize every entry: append DOMAIN_NAME to any entry that has no dot (bare hostname)
_normalized=""
IFS=',' read -ra _entries <<< "${SERVER_NAME}"
for _e in "${_entries[@]}"; do
  echo "${_e}" | grep -q '\.' || _e="${_e}.${DOMAIN_NAME}"
  _normalized="${_normalized:+${_normalized},}${_e}"
done
export SERVER_NAME="${_normalized}"

# If SERVER_NAME contains commas it is a comma-separated list of FQDNs; the first
# entry is used as the primary name (CN) and drives the output file names.
# If it is a single value it is treated as a plain hostname and DOMAIN_NAME is appended.
if echo "${SERVER_NAME}" | grep -q ','; then
  FIRST_FQDN=$(echo "${SERVER_NAME}" | awk -F',' '{print $1}')
  export CERT_NAME="${FIRST_FQDN%%.*}"
  export PRIMARY_FQDN="${FIRST_FQDN}"
  # SAN must be DNS:-prefixed entries separated by commas for OpenSSL
  export SAN=$(echo "${SERVER_NAME}" | sed 's/,/,DNS:/g; s/^/DNS:/')
else
  export CERT_NAME="${SERVER_NAME%%.*}"
  export PRIMARY_FQDN="${SERVER_NAME}"
  export SAN="DNS:${SERVER_NAME}"
fi

export OPENSSL_SERVER_CONF="${BASE_DIR}/conf/${CERT_NAME}.cnf"

export LOGFILE="${BASE_DIR}/log/custom-ca.log"


# FUNCTIONS
ts() {
  date +"%Y-%m-%d %H:%M:%S.%3N"
}


# PREPARING
mkdir -p ${BASE_DIR}/{certs,newcerts,private,csr,crl,conf,log}
chmod 700 ${BASE_DIR}/private
touch "${BASE_DIR}/index.txt"
if [ ! -f "${BASE_DIR}/serial" ]; then
  echo 1000 > "${BASE_DIR}/serial"
fi
cd "${BASE_DIR}"


# START LOGGING
exec > >(tee -a "$LOGFILE") 2>&1
echo "$(ts) Starting custom CA script"


# REMOVE EXISTING CERTIFICATE
if [ "${ACTION}" = "remove" ]; then
  echo "$(ts) Removing certificate for ${CERT_NAME}..."
  removed=0

  if [ -f "${BASE_DIR}/certs/${CERT_NAME}.crt" ]; then
    if [ -f "${BASE_DIR}/private/ca.key" ]; then
      echo "$(ts) Revoking certificate (will prompt for CA key password)..."
      openssl ca \
        -config "${OPENSSL_CA_CONF}" \
        -revoke "${BASE_DIR}/certs/${CERT_NAME}.crt"
    fi
    rm -f "${BASE_DIR}/certs/${CERT_NAME}.crt"
    echo "$(ts) Removed cert:   ${BASE_DIR}/certs/${CERT_NAME}.crt"
    removed=1
  fi

  for f in \
    "${BASE_DIR}/private/${CERT_NAME}.key" \
    "${BASE_DIR}/csr/${CERT_NAME}.csr" \
    "${BASE_DIR}/conf/${CERT_NAME}.cnf"; do
    if [ -f "${f}" ]; then
      rm -f "${f}"
      echo "$(ts) Removed file:   ${f}"
      removed=1
    fi
  done

  if [ "${removed}" -eq 0 ]; then
    echo "$(ts) No files found for ${CERT_NAME}, nothing to remove."
  else
    echo "$(ts) Removal complete for ${CERT_NAME}."
  fi
  exit 0
fi


# CREATE OPENSSL CONFIG IF IT DOES NOT EXIST
if [ ! -f "${OPENSSL_CA_CONF}" ]; then
  cat > "${OPENSSL_CA_CONF}" << EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = ${BASE_DIR}
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
private_key       = \$dir/private/ca.key
certificate       = \$dir/certs/ca.crt
default_md        = sha256
default_days      = 825
preserve          = no
policy            = policy_any
copy_extensions   = copy

[ policy_any ]
commonName              = supplied
organizationName        = optional
countryName             = optional

[ req ]
default_bits        = 4096
prompt              = no
default_md          = sha256
distinguished_name  = req_distinguished_name
x509_extensions     = v3_ca

[ req_distinguished_name ]
CN = ${CA_COMMONNAME}
OU = Platform
L = Sydney
ST = NSW
O = IT Group
C = AU

[ v3_ca ]
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
basicConstraints        = critical, CA:TRUE
keyUsage                = critical, keyCertSign, cRLSign

[ v3_server ]
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
basicConstraints        = CA:FALSE
keyUsage                = critical, digitalSignature, keyEncipherment
extendedKeyUsage        = serverAuth
subjectAltName          = \$ENV::SAN
EOF

else
  echo "$(ts) OpenSSL configuration already exists at ${OPENSSL_CA_CONF}"
fi


# GENERATE CA PRIVATE KEY - WILL PROMPT TO SET A PASSWORD IF IT DOES NOT EXIST ALREADY
if [ ! -f "${BASE_DIR}/private/ca.key" ]; then
  openssl genrsa -aes256 -out "${BASE_DIR}/private/ca.key" 4096
else
  echo "$(ts) CA private key already exists at ${BASE_DIR}/private/ca.key"
fi

# GENERATE CA SELF-SIGNED CERTIFICATE IF IT DOES NOT EXIST ALREADY
if [ ! -f "${BASE_DIR}/certs/ca.crt" ]; then
  openssl req -new -x509 \
    -days ${CA_CERT_EXPIRY} \
    -key "${BASE_DIR}/private/ca.key" \
    -out "${BASE_DIR}/certs/ca.crt" \
    -config "${OPENSSL_CA_CONF}"
else
  echo "$(ts) CA certificate already exists at ${BASE_DIR}/certs/ca.crt"
fi

# VERIFY CA CERT
echo "$(ts) Verifying CA certificate..."
openssl x509 -noout -text -in "${BASE_DIR}/certs/ca.crt" | grep -E "Subject:|Issuer:|CA:"


# GENERATE SERVER CERT AND KEY

# Build alt_names entries — loop when SERVER_NAME has multiple comma-separated FQDNs
if echo "${SERVER_NAME}" | grep -q ','; then
  ALT_NAMES_BLOCK=""
  i=1
  IFS=',' read -ra SAN_NAMES <<< "${SERVER_NAME}"
  for name in "${SAN_NAMES[@]}"; do
    ALT_NAMES_BLOCK+="DNS.${i} = ${name}"$'\n'
    i=$((i+1))
  done
else
  ALT_NAMES_BLOCK="DNS.1 = ${SERVER_NAME}"
fi

cat > "${OPENSSL_SERVER_CONF}" << EOF
[ req ]
default_bits        = ${SERVER_KEYSIZE}
prompt              = no
default_md          = sha256
distinguished_name  = req_distinguished_name
req_extensions      = v3_req

[ req_distinguished_name ]
CN = ${PRIMARY_FQDN}
OU = Platform
L = Sydney
ST = NSW
O = IT Group
C = AU

[ v3_req ]
basicConstraints    = CA:FALSE
keyUsage            = critical, digitalSignature, keyEncipherment
extendedKeyUsage    = ${CERT_PURPOSE:-serverAuth}
subjectAltName      = @alt_names

[ alt_names ]
${ALT_NAMES_BLOCK}
EOF


# GENERATE SERVER PRIVATE KEY (NO PASSWORD, SO APP CAN START WITHOUT PROMPT)
if [ ! -f "${BASE_DIR}/private/${CERT_NAME}.key" ]; then
  openssl genrsa -out "${BASE_DIR}/private/${CERT_NAME}.key" ${SERVER_KEYSIZE}
else
  echo "$(ts) Server private key already exists at ${BASE_DIR}/private/${CERT_NAME}.key"
fi


# GENERATE CSR
if [ ! -f "${BASE_DIR}/csr/${CERT_NAME}.csr" ]; then
  openssl req -new \
    -key "${BASE_DIR}/private/${CERT_NAME}.key" \
    -out "${BASE_DIR}/csr/${CERT_NAME}.csr" \
    -config "${OPENSSL_SERVER_CONF}"
else
  echo "$(ts) Server CSR already exists at ${BASE_DIR}/csr/${CERT_NAME}.csr"
fi


# VERIFY CSR - CONFIRM ONLY DNS SAN, NO OTHERNAME
echo "$(ts) Verifying CSR..."
openssl req -noout -text -in "${BASE_DIR}/csr/${CERT_NAME}.csr" | grep -A5 "Subject Alternative Name"


# SIGN THE CSR - WILL PROMPT FOR CA KEY PASSWORD
if [ -f "${BASE_DIR}/certs/${CERT_NAME}.crt" ]; then
  # Check if the certificate is still valid (not expired)
  if openssl x509 -checkend 0 -noout -in "${BASE_DIR}/certs/${CERT_NAME}.crt" 2>/dev/null; then
    echo "$(ts) Server certificate already exists and is still valid at ${BASE_DIR}/certs/${CERT_NAME}.crt, skipping signing."
  else
    echo "$(ts) Server certificate exists but has expired, re-signing..."
    openssl ca \
      -config "${OPENSSL_CA_CONF}" \
      -extensions v3_server \
      -days ${SERVER_CERT_EXPIRY} \
      -notext \
      -batch \
      -in "${BASE_DIR}/csr/${CERT_NAME}.csr" \
      -out "${BASE_DIR}/certs/${CERT_NAME}.crt"
  fi
else
  echo "$(ts) Server certificate does not exist, signing CSR..."
  # Increment serial number to avoid conflicts
  current_serial=$(cat "${BASE_DIR}/serial")
  echo $((current_serial + 1)) > "${BASE_DIR}/serial"
  openssl ca \
    -config "${OPENSSL_CA_CONF}" \
    -extensions v3_server \
    -days ${SERVER_CERT_EXPIRY} \
    -notext \
    -batch \
    -in "${BASE_DIR}/csr/${CERT_NAME}.csr" \
    -out "${BASE_DIR}/certs/${CERT_NAME}.crt"
fi


# VERIFY FINAL CERT HAS CLEAN SANS - NO KERBEROS/UPN OTHERNAME
echo "$(ts) Verifying final certificate..."
openssl x509 -noout -text -in "${BASE_DIR}/certs/${CERT_NAME}.crt" | grep -A5 "Subject Alternative Name"

# Expected output:
#X509v3 Subject Alternative Name:
#    DNS:hostname.domain.com    ← only this, nothing else

# Verify certificate chain
echo "$(ts) Verifying certificate chain..."
openssl verify -CAfile "${BASE_DIR}/certs/ca.crt" "${BASE_DIR}/certs/${CERT_NAME}.crt"
