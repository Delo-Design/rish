#!/usr/bin/env bash
function create_hotlist() {
  cat >~/.config/mc/hotlist <<EOF
ENTRY "/etc" URL "/etc"
ENTRY "Путь к пользователям /var/www" URL "/var/www"
ENTRY "Путь к конфигам сайтов apache /etc/httpd/conf.d" URL "/etc/httpd/conf.d"
GROUP "Пути к настройкам php"
EOF
  local installed
  local installed_versions
  local users
  local user
  mapfile -t installed_versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
  for installed in "${installed_versions[@]}"; do
    echo 'ENTRY "Путь к пулам '${installed}' /etc/opt/remi/'${installed}'/php-fpm.d" URL "/etc/opt/remi/'${installed}'/php-fpm.d"' >>~/.config/mc/hotlist
    echo 'ENTRY "Путь к php.ini '${installed}' /etc/opt/remi/'${installed}'" URL "/etc/opt/remi/'${installed}'"' >>~/.config/mc/hotlist
  done
  echo "ENDGROUP" >>~/.config/mc/hotlist
  mapfile -t users < <(find "/var/www" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -vE "^(cgi-bin|html)$" | sort)
  for user in "${users[@]}"; do
    echo 'ENTRY "Путь к сайтам '${user}' /var/www/'${user}'/wwww" URL "/var/www/'${user}'/www"' >>~/.config/mc/hotlist
  done
}
