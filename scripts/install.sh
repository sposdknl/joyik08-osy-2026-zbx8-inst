#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

SECRETS_DIR="/var/db/zabbix-install"
DB_PASS_FILE="${SECRETS_DIR}/db-password"
ADMIN_PASS_FILE="${SECRETS_DIR}/admin-password"

echo "==> Příprava adresáře pro hesla..."
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

if [ ! -f "$DB_PASS_FILE" ]; then
  openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24 > "$DB_PASS_FILE"
  chmod 600 "$DB_PASS_FILE"
fi
DB_PASS=$(cat "$DB_PASS_FILE")

if [ ! -f "$ADMIN_PASS_FILE" ]; then
  openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c 20 > "$ADMIN_PASS_FILE"
  chmod 600 "$ADMIN_PASS_FILE"
fi

echo "==> Instalace základních nástrojů a MariaDB..."
apt-get update
apt-get install -y wget curl gnupg2 ca-certificates openssl python3 mariadb-server
systemctl enable --now mariadb

echo "==> a. Install Zabbix repository..."
if [ ! -f /etc/apt/sources.list.d/zabbix.list ] && [ ! -f /etc/apt/sources.list.d/zabbix.sources ]; then
  ZBX_HOST="repo.zabbix.com"
  ZBX_PATH="zabbix/8.0/release/debian/pool/main/z/zabbix-release"
  ZBX_FILE="zabbix-release_latest_8.0+debian13_all.deb"
  wget "https://${ZBX_HOST}/${ZBX_PATH}/${ZBX_FILE}" -O "/tmp/${ZBX_FILE}"
  dpkg -i "/tmp/${ZBX_FILE}"
  rm -f "/tmp/${ZBX_FILE}"
fi
apt-get update

echo "==> b. Install Zabbix server, frontend, agent..."
apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent

echo "==> c. Create initial database..."
mysql -uroot -e "CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;"
mysql -uroot -e "CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -uroot -e "ALTER USER 'zabbix'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -uroot -e "GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';"
mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 1;"
mysql -uroot -e "FLUSH PRIVILEGES;"

TABLE_COUNT=$(mysql -uroot -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'zabbix';")
if [ "$TABLE_COUNT" -eq 0 ]; then
  echo "==> Importuji výchozí Zabbix SQL schéma..."
  zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql --default-character-set=utf8mb4 -uzabbix -p"${DB_PASS}" zabbix
fi

mysql -uroot -e "SET GLOBAL log_bin_trust_function_creators = 0;"

echo "==> d. Configure the database for Zabbix server..."
sed -i "s/^#\? *DBPassword=.*/DBPassword=${DB_PASS}/" /etc/zabbix/zabbix_server.conf

echo "==> Konfigurace Zabbix Frontendu (bez nutnosti procházet PHP wizard)..."
cat <<EOF > /etc/zabbix/web/zabbix.conf.php
<?php
\$DB['TYPE']     = 'MYSQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = 'zabbix';
\$DB['USER']     = 'zabbix';
\$DB['PASSWORD'] = '${DB_PASS}';
\$DB['SCHEMA']   = '';
\$DB['ENCRYPTION'] = false;
\$DB['KEY_FILE']   = '';
\$DB['CERT_FILE']  = '';
\$DB['CA_FILE']    = '';
\$DB['VERIFY_HOST'] = false;
\$DB['CIPHER_LIST'] = '';
\$DB['FLOAT_DOUBLE'] = true;

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = 'vorisekm · Debian 13 · Zabbix 8';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
EOF
chown www-data:www-data /etc/zabbix/web/zabbix.conf.php
chmod 640 /etc/zabbix/web/zabbix.conf.php

echo "==> Nastavení vlastního UserParameter pro Zabbix agent..."
mkdir -p /usr/local/libexec/zabbix
cp /tmp/zbx-scripts/sposdk-cert-days.sh /usr/local/libexec/zabbix/sposdk-cert-days.sh
chmod 755 /usr/local/libexec/zabbix/sposdk-cert-days.sh

cat <<EOF > /etc/zabbix/zabbix_agentd.d/sposdk_cert.conf
UserParameter=sposdk.cert.days,/usr/local/libexec/zabbix/sposdk-cert-days.sh
EOF

echo "==> e. Start Zabbix server and agent processes..."
systemctl restart zabbix-server zabbix-agent apache2
systemctl enable zabbix-server zabbix-agent apache2

echo "==> Hotovo! Webové rozhraní běží na http://127.0.0"
