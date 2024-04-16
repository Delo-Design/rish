# shellcheck disable=SC3000-SC4000
mariadb_install() {
  cd /etc/yum.repos.d/

  echo
  echo -e "${GREEN}MariaDB${WHITE} на данный момент имеет два релиза с долгосрочной поддержкой:"
  echo "10.6 со сроком поддержки до 6 июля 2026"
  echo "10.11 со сроком поддержки до 16 февраля 2028"
  echo
  echo "Какой релиз ставить?"
  if vertical_menu "current" 2 0 5 "MariaDB 10.11" "MariaDB 10.6"; then
    Maria_Version="10.11"
  else
    Maria_Version="10.6"
  fi
  echo -e "Выбрана версия ${GREEN}${Maria_Version}${WHITE}"

  if [[ ${CURRENT_OS} =~ "Fedora" ]]; then
    {
      echo "# MariaDB 10.11 Fedora repository list - created 2023-03-19 15:47 UTC"
      echo "# https://mariadb.org/download/"
      echo "[mariadb]"
      echo "name = MariaDB"
      echo "baseurl = https://rpm.mariadb.org/${Maria_Version}/fedora/\$releasever/\$basearch"
      echo "gpgkey= https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB"
      echo "gpgcheck=1"
    } >MariaDB.repo
  elif [[ ${OS_VERSION} == "8" ]]; then
    {
      echo "# MariaDB 10.11 RedHatEnterpriseLinux repository list - created 2023-03-19 16:07 UTC"
      echo "# https://mariadb.org/download/"
      echo "[mariadb]"
      echo "name = MariaDB"
      echo "# rpm.mariadb.org is a dynamic mirror if your preferred mirror goes offline. See https://mariadb.org/mirrorbits/ for details."
      echo "baseurl = https://rpm.mariadb.org/${Maria_Version}/rhel/\$releasever/\$basearch"
      echo "module_hotfixes = 1"
      echo "gpgkey = https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB"
      echo "gpgcheck = 1"
    } >MariaDB.repo
  else
    {
      echo "# MariaDB 10.11 RedHatEnterpriseLinux repository list - created 2023-03-19 16:07 UTC"
      echo "# https://mariadb.org/download/"
      echo "[mariadb]"
      echo "name = MariaDB"
      echo "# rpm.mariadb.org is a dynamic mirror if your preferred mirror goes offline. See https://mariadb.org/mirrorbits/ for details."
      echo "baseurl = https://rpm.mariadb.org/${Maria_Version}/rhel/\$releasever/\$basearch"
      echo "gpgkey = https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB"
      echo "gpgcheck = 1"
    } >MariaDB.repo
  fi
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