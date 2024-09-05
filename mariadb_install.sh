# shellcheck disable=SC3000-SC4000
mariadb_install() {

  Install "MariaDB-server MariaDB-client"
  systemctl start mariadb
  systemctl enable mariadb

  Up
  echo -e "Производим настройку безопасности ${GREEN}mysql_secure_installation${WHITE}"
  Down
  sed -i '/character-set-server=utf8/d' /etc/my.cnf.d/server.cnf
  sed -i "s/^\[mysqld\]/\[mysqld\]\ncharacter-set-server=utf8/" /etc/my.cnf.d/server.cnf

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
}