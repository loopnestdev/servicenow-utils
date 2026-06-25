# Changelog

All notable changes to this project will be documented in this file.

## [v0.1.0] — 2026-06-12

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — full ServiceNow deployment script for RHEL 9 / Rocky Linux 9
  - Installs OS dependencies, tunes system parameters, creates `servicenow` user/group
  - JDK installation from a local tarball (auto-detects JDK major version for JVM overrides)
  - Extracts glide base and deploys one or more SNC instances via the SNC installer JAR
  - Writes `glide.db.properties`, `glide.properties`, and JDK override property files per instance
  - Systemd service unit generation, enable, and start per instance
  - Clean-install mode (`--clean_install=true`): deploys instance 1 only, polls MariaDB
    `sys_upgrade_history` until schema initialisation completes (up to 9 hours), inserts
    `glide.war` version record, then deploys remaining instances
  - Idempotent re-run support: skips JDK extraction, glide base extraction, and instance
    installation if already present
  - HAProxy and nginx reverse proxy support with 1:1 frontend-per-instance topology
  - TLS support for DB connections: configurable minimum version (`TLSv1.2` or `TLSv1.3`)
    with separate JDBC and OpenSSL cipher lists written to both the JDBC URL and
    `/etc/my.cnf.d/mariadb-client.cnf`
  - MariaDB master monitor cron job (`mdb_master_check.sh`) for HA failover detection
  - Backup cron via `sncBackup.sh`, logrotate config for SNC and HAProxy logs
- `snow-backup.sh` — ServiceNow node backup script

#### MariaDB (`mariadb/`)

- `mariadb-deploy.sh` — MariaDB deployment script
- `config/mariadb.cnf`, `server.cnf`, `mariadb-client.cnf`, `mariabackup.cnf` — server and client configuration templates
- `scripts/mariadb-backup-full.sh` — full backup script using Mariabackup
- `scripts/mariadb-backup-incr.sh` — incremental backup script
- `scripts/mariadb-cleanup.sh` — backup retention cleanup script
- `.mariadb.env.sample` — sample environment variable file

#### Utilities (`utilities/`)

- `ca-custom.sh` — custom Certificate Authority setup script

## [v0.1.1] — 2026-06-13

### Fixed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — multi-node deployment fixes:
  - **Auto node-role detection** (`--clean_install=auto`, now default): queries `information_schema.tables`
    on startup to determine whether the DB is empty (first node — run clean install + wait) or already
    initialised (subsequent node — join cluster directly). Log output from the detection function is
    redirected to stderr so the mode word is cleanly captured by the caller.
  - **`wait_for_db_init` idempotency**: checks `sys_upgrade_history` at entry and returns immediately
    if schema initialisation is already complete, preventing a re-run from re-entering the 9-hour wait.
  - **`insert_glide_war` idempotency**: changed `INSERT INTO` to `INSERT IGNORE INTO` so re-runs do
    not fail on a duplicate `glide.war` key in `sys_properties`.
  - **MariaDB TLS cipher fix**: removed TLS 1.3 cipher names (`TLS_AES_*`) from the `ssl-cipher`
    directive in `/etc/my.cnf.d/mariadb-client.cnf`. The `ssl-cipher` field only accepts TLS 1.2
    OpenSSL-format names; TLS 1.3 ciphers are auto-negotiated when `tls-version` includes `TLSv1.3`.
    The `ssl-cipher` line is omitted entirely when `--db_tls_min=TLSv1.3`.
  - **`--clean_install` validation**: added guard rejecting values other than `auto`, `true`, or `false`.

## [v0.1.2] — 2026-06-14

### Changed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — DB client package is now conditional on `--db_type`:
  - `mariadb` (default) installs the `mariadb` client package
  - `postgresql` installs `postgresql15` instead

## [v0.1.3] — 2026-06-14

### Added

#### ServiceNow (`servicenow/`)

- `haproxy-migrate.sh` — ad-hoc script to migrate an existing VM from the old
  per-instance HAProxy topology to the new single-frontend design without
  rerunning the full deployment. Auto-detects SSL, backs up the old config,
  writes and validates the new config, and does a graceful reload with automatic
  rollback on syntax error.

### Changed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — proxy topology redesign:
  - **HAProxy**: replaced per-instance frontends (one port per instance) with a
    single `frontend snc-frontend` on `0.0.0.0:443` backed by all instances in
    one `backend snc-backend` pool. Load balancing algorithm changed from
    `roundrobin` to `leastconn`. Added HAProxy-managed `SERVERID` cookie for
    session persistence (required by ServiceNow). Added full set of
    ServiceNow-recommended LB headers: `X-Forwarded-Host`, `X-Forwarded-Proto`,
    HSTS (`max-age=63072000; includeSubDomains`), `HttpOnly`/`Secure` flags on
    all response cookies, `Location` http→https rewrite.
  - **nginx**: same single-upstream topology — one `upstream snc_backend` block
    with `least_conn` and all instances, served by a single `server` block on
    `:443`. Added `X-Forwarded-Host/Proto`, HSTS header, `proxy_redirect`
    http→https, and `proxy_cookie_flags` for all ServiceNow cookies
    (Secure/HttpOnly) per ServiceNow nginx guidance.
  - **`glide.properties`**: added `glide.servlet.host = 127.0.0.1` so SNC
    instances bind to loopback only, with HAProxy as the sole client.
  - Removed `PROXY_PORT_START` default and `proxy_frontend_port()` helper —
    both obsolete with the single-frontend design.

## [v0.1.4] — 2026-06-15

### Added

#### ServiceNow (`servicenow/`)

- `install-jdk.sh` — standalone JDK installation script extracted from
  `snow-deploy.sh`. Accepts `--jdk_tarball`, `--install_dir`, and
  `--media_dir` parameters. Extracts the tarball, flattens the nested
  directory, writes `JAVA_HOME` and `PATH` to `/etc/profile.d/`, and is
  idempotent (skips extraction if `bin/java` already exists). Intended for
  installing OpenJDK on extra component VMs that don't run a full SNC
  deployment.

## [v0.1.5] — 2026-06-15

### Changed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — two new parameterised arguments:
  - `--svc_prefix=<prefix>` (default: `snc`) — systemd service name prefix;
    instances are named `<prefix>01`, `<prefix>02`, etc. Previously hardcoded
    to `snc-01`, `snc-02`, ...
  - `--snc_user=<user>` (default: `servicenow`) — OS user and group created
    for the SNC process. Applied to `groupadd`/`useradd`, the systemd unit
    `User=`/`Group=` directives, and all `chown` calls.

## [v0.1.6] — 2026-06-17

### Fixed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — PostgreSQL compatibility for DB query functions:
  - Added `db_query()` helper that dispatches to `mysql` (MariaDB) or `psql`
    (PostgreSQL) based on `--db_type`, handling SSL, credentials, and
    header-free output for each engine.
  - `wait_for_db_init`: uses `db_query()`; PostgreSQL omits the database
    prefix in the table reference (connected directly to the target DB).
  - `detect_install_mode`: uses `db_query()`; PostgreSQL counts user tables
    via `table_catalog = current_database()` instead of `table_schema =
    '<dbname>'` which is MariaDB-specific.
  - `insert_glide_war`: uses `db_query()`; PostgreSQL uses
    `ON CONFLICT DO NOTHING` instead of `INSERT IGNORE`.
  - All three functions previously hardcoded `--ssl` regardless of
    `--db_ssl`; now conditional via `db_query()`.

## [v0.1.7] — 2026-06-18

### Fixed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — two correctness fixes:
  - `glide.db.rdbms` in `glide.db.properties` was hardcoded to `mysql`
    regardless of `--db_type`; now correctly writes `postgresql` when
    `--db_type=postgresql` and `mysql` otherwise.
  - JVM heap ceiling raised from 2 GB to 4 GB (`-Xmx4096m`) in
    `51-memory.properties` for both JDK 8/11 and JDK 17 override blocks.

## [v0.1.8] — 2026-06-18

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — JDK 21 support for Australia release (KB2833352):
  - Added `21)` branch to `write_jdk_overrides()` with all required property
    files per ServiceNow KB2833352.
  - `51-memory.properties`: `-Xms2048m -Xmx4096m` with
    `-XX:-UseAdaptiveSizePolicy`.
  - `86-security.properties` (new): `-Djava.security.manager=allow`.
  - `88-xmldefault.properties` (new): DTM manager and XML stream factory
    defaults required by JDK 21.
  - `92-access.properties`: two additional `--add-opens` entries
    (`java.base/java.lang.module`, `java.base/jdk.internal.module`).
  - `93-legacy-jdk.properties`: retained for JDK 21 (KB mandates it).
  - `98-general.properties`: `-XX:+ParallelRefProcEnabled` retained per KB.
  - Unsupported version error message updated to include `21`.

## [v0.1.9] — 2026-06-18

### Fixed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — PostgreSQL JDBC URL now uses `sslmode=require` /
  `sslmode=disable` instead of the deprecated
  `ssl=true&sslfactory=org.postgresql.ssl.NonValidatingFactory`. The old
  `NonValidatingFactory` class is unavailable in newer JDBC drivers bundled
  with Australia release, causing connections to silently drop SSL and be
  rejected by `pg_hba.conf` with "no encryption".

## [v0.1.10] — 2026-06-18

### Fixed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — `wait_for_db_init()` no longer logs spurious psql errors
  while polling. `sys_upgrade_history` does not exist until ServiceNow creates
  it during schema initialisation; psql errors are now suppressed with
  `2>/dev/null` and the periodic progress log no longer prints the raw error
  text.

## [v0.1.11] — 2026-06-18

### Fixed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — unified DB queries for `wait_for_db_init()` and
  `detect_install_mode()` across both engines. PostgreSQL treats `${DB_NAME}`
  as the schema name (ServiceNow creates tables in a schema matching the DB
  name), so `table_schema='${DB_NAME}'` and `${DB_NAME}.sys_upgrade_history`
  work identically for both MariaDB and PostgreSQL — the per-engine conditionals
  were removed.

## [v0.1.12] — 2026-06-22

### Added

#### ServiceNow (`servicenow/`)

- `snap-deploy.sh` — new deployment script for ServiceNow SNAP Server on RHEL 9.
  Supports three modes (`--mode=snap|haproxy|all`; default: `all`):

  - **snap** — installs JDK (from tarball), Apache Tomcat (from tarball), SNAP WAR
    (`snap.tar.gz`), and ClamAV. Tomcat binds exclusively to `127.0.0.1:PORT`
    and is managed as a parameterised systemd service (`--tomcat_svc`,
    `--tomcat_user`).
  - **haproxy** — installs and configures HAProxy as a TLSv1.3-only frontend
    (KB1632909: HSTS, `X-Forwarded-*` headers, `Location` rewrite, secure
    cookie flags, `leastconn` balance, `SNAPSERVERID` session cookie).
  - **all** — both of the above on the same VM; intended for GCP Layer-4 TCP
    load balancer topology where each VM runs HAProxy `:443` → `127.0.0.1:SNAP_PORT`.

  Key parameters: `--jdk_dir`, `--tomcat_dir`, `--port`, `--media_dir`,
  `--jdk_tarball`, `--tomcat_tarball`, `--snap_war`, `--cert_file`, `--key_file`,
  `--java_heap_xmx`, `--clamav_dir`, `--clamav_version`, `--freshclam_mirror`,
  `--haproxy_bind_port`, `--haproxy_stat_port`, `--tomcat_svc`, `--tomcat_user`,
  `--skip_deps` (offline environments), `--skip_selinux`.

  ClamAV: `clamd` and `clamav-freshclam` run as systemd services. The freshclam
  drop-in override clears the default `ExecStart`, adds `ExecStartPre` to release
  any stale log-file lock, and points both services at the custom config under
  `${CLAMAV_DIR}/conf/`. `clamav-scan` and `clamav-reputation` are not configured.

  The script is fully idempotent: JDK, Tomcat, SNAP WAR, firewall rules, and
  ClamAV are each skipped on re-run if already present.

## [v0.1.13] — 2026-06-23

### Added

#### ServiceNow (`servicenow/`)

- `snap-deploy.sh` — offline ClamAV database support via two new arguments:
  - `--skip_freshclam` — skips starting `clamav-freshclam` and the database
    download wait. Instead copies `main.cvd`, `daily.cvd`, and `bytecode.cvd`
    from the source directory into `${CLAMAV_DIR}/data/`. `clamd` is still
    started normally. The `clamav-freshclam` active-service check in
    `verify_clamav()` is also skipped in this mode.
  - `--clamav_db_src=<path>` — source directory for the CVD files
    (default: `/var/lib/clamav`, installed by the `clamav-data` package).
    Only used when `--skip_freshclam` is set.

  Typical offline invocation: `--skip_deps --skip_freshclam`

## [v0.1.14] — 2026-06-24

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — BCFKS keystore conversion for Australia+ release
  (KB0997653):
  - `convert_cacerts_bcfks()` function converts the default Java `cacerts`
    trust store from JKS to BCFKS format, required for outbound TLS connections
    (app store, integrations, etc.) on Rome or later releases.
  - `bc-fips-*.jar` is located dynamically from the installed node's
    `lib/jsw/` directory — handles version differences across SNC releases.
  - `05-cacerts.properties` written per instance in the JDK 21 branch pointing
    SNC to the converted `cacerts.bcfks` trust store.
  - Conversion runs automatically in `install_instance()` after JDK overrides
    are written and before the systemd service starts.
  - Idempotent: skips if `cacerts.bcfks` already exists; silently skips on
    pre-Australia releases where bc-fips jar is absent.

## [v0.1.15] — 2026-06-24

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — daily cron job to purge SNC pre-compressed log files
  older than 3 days. Runs at 02:00 via `/etc/cron.d/snccor` targeting
  `${INSTALL_DIR}/nodes/*/logs/*.gz` across all instances on the VM.

## [v0.1.16] — 2026-06-24

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — `--skip_deps` flag to bypass `install_deps()`. Useful for
  offline or pre-provisioned environments where OS packages are already
  installed. No value required; presence of the flag sets the behaviour.

## [v0.1.17] — 2026-06-24

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — SELinux port labeling via new `configure_selinux()`
  function, called after proxy setup:
  - Labels each SNC instance HTTP port (`PORT_START` … `PORT_START+INSTANCES-1`)
    and the HAProxy stats port (`HAPROXY_STATPORT`) as `http_port_t`.
  - Port 443 is skipped — already labeled by default on RHEL.
  - Silently no-ops when SELinux is `Disabled` or `getenforce` is absent.
  - `--skip_selinux` flag bypasses the function entirely (offline or
    Trellix-managed environments).

## [v0.1.18] — 2026-06-24

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — KMF (Key Management Framework) keystore setup via new
  `configure_kmf()` function, called per instance before service start:
  - First VM, instance 1: creates `keystorekmf.bcfks` via `keytool -genseckey`
    using the bc-fips jar bundled with the node, then saves a copy to
    `media_dir` for distribution.
  - First VM, instances 2–4 and all subsequent VMs: copies `keystorekmf.bcfks`
    from `media_dir` (operator must pre-place the file from the first VM on
    subsequent VMs).
  - Writes `glide.kmf.keystore.properties` per instance pointing to the
    keystore with the configured password and alias.
  - Idempotent: skips keystore creation/copy if `keystorekmf.bcfks` already
    exists; always rewrites the properties file.
  - New arguments: `--kmf_password=<password>` (default: `changeit`),
    `--kmf_alias=<alias>` (default: `256bitkey`), `--skip_kmf`.

## [v0.1.19] — 2026-06-24

### Changed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — PostgreSQL SSL configuration migrated from JDBC URL
  parameters to ServiceNow-native Glide properties (per `ssldb.md` /
  KB2253117):
  - JDBC URL is now bare (`jdbc:postgresql://host:port/db`) — no inline SSL
    params.
  - New `write_postgresql_ssl_properties()` function writes
    `conf/overrides.d/99-jdbc-tls.properties` per instance when
    `--db_type=postgresql` and `--db_ssl=true`, containing:
    - `glide.db.postgresql.jdbc.ssl=true`
    - `glide.db.postgresql.jdbc.sslmode=require`
    - `glide.db.postgresql.jdbc.sslfactory=org.postgresql.ssl.NonValidatingFactory`
  - `sslfactory=NonValidatingFactory` is required for reliable reconnection
    after DB failover behind a GCP Layer 4 LB. Without it, adding
    `sslrootcert` causes JDBC to upgrade to `verify-ca` validation; under
    BCFKS/FIPS mode this triggers an SSL handshake failure ("Something
    unusual") on every reconnect attempt to the new primary.
  - New `--db_ssl_ca=<file>` argument (filename in `media_dir`) enables
    production cert validation: when set, writes `verify-ca` +
    `DefaultJavaSSLFactory` to `99-jdbc-tls.properties` and imports the DB
    CA cert into the instance's `cacerts.bcfks` truststore (alias `db-ca`).
    `DefaultJavaSSLFactory` routes validation through the JVM's SSL
    machinery using the BCFKS provider — FIPS-compatible and reliable on
    failover. When `--db_ssl_ca` is omitted, falls back to `require` +
    `NonValidatingFactory` (encrypt only, no cert check).
  - `host.crt`, `host.key` (proxy SSL certificate/key), and `snow-backup.sh`
    moved from `config/` to `media_dir`. All deployment artefacts are now
    sourced from the single shared distribution directory. The `config/`
    directory and `CONFIG_DIR` variable are no longer used and have been
    removed from the script.

## [v0.1.20] — 2026-06-24

### Changed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — updated argument defaults to match target environment:
  - `--db_tls_min` default changed from `TLSv1.2` to `TLSv1.3`
  - `--media_dir` default changed from `/data/snow_media` to `/glide/media`
  - `--backup_dir` default changed from `/mnt/backup` to `/glide/backup`

## [v0.1.21] — 2026-06-24

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — three additional TCP kernel parameters in `tune_system()`:
  - `net.ipv4.tcp_tw_reuse = 1` — allow reuse of TIME_WAIT sockets for new connections
  - `net.ipv4.tcp_fin_timeout = 30` — reduce FIN_WAIT2 timeout from the 60 s kernel default
  - `net.ipv4.tcp_syn_retries = 3` — limit SYN retransmit attempts before failing a new connection
  Each parameter is written idempotently (updates existing entry or appends) and applied immediately via `sysctl -w`.

## [v0.1.22] — 2026-06-24

### Added

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — `configure_fresh_install_db()` function, called on the
  first node immediately after `insert_glide_war`, covering steps from
  `fresh_install_db.sh.j2` that were missing from the shell script conversion:
  - Sets `instance_id` (`sys_properties`) to the MD5 hash of `--cluster_name`
  - Sets `instance_name` (`sys_properties`) to the value of `--cluster_name`
  - Clears email credentials: `glide.email.server`, `glide.email.username`,
    `glide.email.user_password`, `glide.pop3.server`, `glide.pop3.user`,
    `glide.pop3.password`
  - Disables email and replication: `glide.email.read.active`,
    `glide.email.smtp.active`, `glide.db.replicate_master` all set to `false`
  - Nulls `sys_trigger.system_id` to disassociate scheduler jobs from the
    source cluster node
  - Truncates `sys_ha_database`, `sys_cluster_state`, and `sys_status`
    (each skipped with a log message if the table does not exist in the
    deployed release)

## [v0.1.24] — 2026-06-25

### Added

#### ServiceNow (`servicenow/`)

- `parexport-deploy.sh` — new deployment script for ServiceNow PARExport Server
  on RHEL 9. Supports three modes (`--mode=parexport|haproxy|all`; default: `all`):

  - **parexport** — drives the vendor `.bin` installer non-interactively (pipes
    `Install/yes/yes` to auto-answer prompts), configures
    `/etc/sysconfig/parexport` with `HTTPS_ENABLED=false` (TLS terminated at
    HAProxy), and starts the `parexport` systemd service. Idempotent: skips
    re-installation if the `par-export-server` binary is already present.
  - **haproxy** — installs and configures HAProxy as a TLSv1.3-only frontend
    (KB1632909: HSTS, `X-Forwarded-*` headers, `Location` rewrite, secure cookie
    flags, `leastconn` balance, `PAREXPORTID` session cookie). Health check via
    `GET /ping` (expects `PONG`).
  - **all** — both of the above on the same VM; intended for GCP Layer-4 TCP load
    balancer topology where each VM runs HAProxy `:443` → `127.0.0.1:PAR_PORT`.

  Key parameters: `--parexport_bin`, `--install_dir`, `--port`, `--media_dir`,
  `--cert_file`, `--key_file`, `--haproxy_bind_port`, `--haproxy_stat_port`,
  `--par_user`, `--par_svc`, `--skip_deps`, `--skip_selinux`.

  PARExport port is not opened in firewalld; HAProxy proxies to `localhost:PORT`
  internally. Configure ServiceNow via `glide.par.export.host`.

## [v0.1.23] — 2026-06-24

### Fixed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — HAProxy stats frontend `bind` directive was hardcoded to
  port `14567` instead of using `${HAPROXY_STATPORT}`; now uses the variable.

### Changed

#### ServiceNow (`servicenow/`)

- `snow-deploy.sh` — `--haproxy_statport` default changed from `14567` to `8000`
- `snap-deploy.sh` — `--haproxy_stat_port` default changed from `9998` to `8000`
