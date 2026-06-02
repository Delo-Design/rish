#!/usr/bin/env bash
function create_hotlist() {
  mkdir -p ~/.config/mc
  local installed
  local installed_versions
  local fpm_binary
  local max_site_name_length=0
  local sites
  local site_entry
  local site_label
  local site_name
  local site_padding
  local site_path
  local site_user
  local users
  local user
  mapfile -t sites < <(find "/var/www" -mindepth 3 -maxdepth 3 -type d -path "/var/www/*/www/*" -printf '%f\t%p\n' | sort)
  for site_entry in "${sites[@]}"; do
    site_name="${site_entry%%$'\t'*}"
    if (( ${#site_name} > max_site_name_length )); then
      max_site_name_length=${#site_name}
    fi
  done
  echo 'GROUP "Список сайтов"' >~/.config/mc/hotlist
  for site_entry in "${sites[@]}"; do
    site_name="${site_entry%%$'\t'*}"
    site_path="${site_entry#*$'\t'}"
    site_user="${site_path#/var/www/}"
    site_user="${site_user%%/*}"
    printf -v site_padding "%*s" "$((max_site_name_length - ${#site_name}))" ""
    site_padding="${site_padding// / }"
    site_label="${site_name}${site_padding}  (${site_user})"
    echo 'ENTRY "'${site_label}'" URL "'${site_path}'"' >>~/.config/mc/hotlist
  done
  cat >>~/.config/mc/hotlist <<EOF
ENDGROUP
ENTRY "/etc" URL "/etc"
ENTRY "/root" URL "/root"
ENTRY "Ключи SFTP тут – /home" URL "/home"
ENTRY "Путь к пользователям /var/www" URL "/var/www"
ENTRY "Путь к конфигам сайтов apache /etc/httpd/conf.d" URL "/etc/httpd/conf.d"
GROUP "Пути к настройкам php"
EOF
  mapfile -t installed_versions < <(
    shopt -s nullglob
    for fpm_binary in /opt/remi/php[0-9][0-9]/root/usr/sbin/php-fpm; do
      [[ -x "$fpm_binary" ]] || continue
      echo "$fpm_binary" | grep -oE 'php[0-9]{2}' | head -n 1
    done | sort -r | uniq
    shopt -u nullglob
  )
  for installed in "${installed_versions[@]}"; do
    echo 'ENTRY "Путь к пулам '${installed}' /etc/opt/remi/'${installed}'/php-fpm.d" URL "/etc/opt/remi/'${installed}'/php-fpm.d"' >>~/.config/mc/hotlist
    echo 'ENTRY "Путь к php.ini '${installed}' /etc/opt/remi/'${installed}'" URL "/etc/opt/remi/'${installed}'"' >>~/.config/mc/hotlist
  done
  echo "ENDGROUP" >>~/.config/mc/hotlist
  mapfile -t users < <(find "/var/www" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -vE "^(cgi-bin|html)$" | sort)
  for user in "${users[@]}"; do
    echo 'ENTRY "Путь к сайтам '${user}' /var/www/'${user}'/www" URL "/var/www/'${user}'/www"' >>~/.config/mc/hotlist
  done
}
