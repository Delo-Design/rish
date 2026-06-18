# shellcheck disable=SC3000-SC4000
mariadb_check_value() {
  local label expected actual query

  label="$1"
  expected="$2"
  query="$3"

  if ! actual="$(mariadb -uroot -NBe "$query" 2>/dev/null)"; then
    echo -e "Ошибка проверки MariaDB: ${RED}${label}${WHITE}"
    return 1
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo -e "Ошибка проверки MariaDB: ${label}: ожидалось ${GREEN}${expected}${WHITE}, получено ${RED}${actual}${WHITE}"
    return 1
  fi
}

mariadb_verify_installation() {
  mariadb_check_value "anonymous users удалены" "0" "SELECT COUNT(*) FROM mysql.user WHERE User='';" || return 1
  mariadb_check_value "test database удалена" "0" "SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='test';" || return 1
  mariadb_check_value "root доступен только локально" "0" "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" || return 1
  mariadb_check_value "server charset" "utf8mb4" "SELECT @@character_set_server;" || return 1
  mariadb_check_value "server collation" "utf8mb4_unicode_ci" "SELECT @@collation_server;" || return 1

  Up
  echo -e "Проверки MariaDB: ${GREEN}OK${WHITE}"
  Down
}

mariadb_install() {

  Install MariaDB-server MariaDB-client
  systemctl start mariadb
  systemctl enable mariadb

  Up
  echo -e "Производим настройку безопасности ${GREEN}mysql_secure_installation${WHITE}"
  Down
  sed -i '/character-set-server=/d' /etc/my.cnf.d/server.cnf
  sed -i '/collation-server=/d' /etc/my.cnf.d/server.cnf
  sed -i "s/^\[mysqld\]/\[mysqld\]\ncharacter-set-server=utf8mb4\ncollation-server=utf8mb4_unicode_ci/" /etc/my.cnf.d/server.cnf

  mariadb-secure-installation <<EOF

n
n
y
y
y
y

EOF
  # mysql -uroot  -e "ALTER USER root@localhost IDENTIFIED VIA mysql_native_password USING PASSWORD(\"${pass}\");"
  sed -i "s/^#bind-address.*$/bind-address=127.0.0.1/" /etc/my.cnf.d/server.cnf
  systemctl restart mariadb
  mariadb_verify_installation
}
