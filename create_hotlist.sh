#!/usr/bin/env bash
function create_hotlist() {
  local hotlist_file="${1:-${HOME}/.config/mc/hotlist}"
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
  mkdir -p "$(dirname "$hotlist_file")"
  mapfile -t sites < <(find "/var/www" -mindepth 3 -maxdepth 3 -type d -path "/var/www/*/www/*" -printf '%f\t%p\n' | sort)
  for site_entry in "${sites[@]}"; do
    site_name="${site_entry%%$'\t'*}"
    if (( ${#site_name} > max_site_name_length )); then
      max_site_name_length=${#site_name}
    fi
  done
  echo 'GROUP "Список сайтов"' >"$hotlist_file"
  for site_entry in "${sites[@]}"; do
    site_name="${site_entry%%$'\t'*}"
    site_path="${site_entry#*$'\t'}"
    site_user="${site_path#/var/www/}"
    site_user="${site_user%%/*}"
    printf -v site_padding "%*s" "$((max_site_name_length - ${#site_name}))" ""
    site_padding="${site_padding// / }"
    site_label="${site_name}${site_padding}  (${site_user})"
    echo 'ENTRY "'${site_label}'" URL "'${site_path}'"' >>"$hotlist_file"
  done
  cat >>"$hotlist_file" <<EOF
ENDGROUP
ENTRY "/etc" URL "/etc"
ENTRY "RISH – /root/rish" URL "/root/rish"
EOF
  if [[ -d /root/rish/credentials && ! -L /root/rish/credentials ]]; then
    echo 'ENTRY "Учетные данные – /root/rish/credentials" URL "/root/rish/credentials"' >>"$hotlist_file"
  fi
  cat >>"$hotlist_file" <<EOF
ENTRY "Ключи SFTP – /etc/ssh/authorized_keys" URL "/etc/ssh/authorized_keys"
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
    echo 'ENTRY "Путь к пулам '${installed}' /etc/opt/remi/'${installed}'/php-fpm.d" URL "/etc/opt/remi/'${installed}'/php-fpm.d"' >>"$hotlist_file"
    echo 'ENTRY "Путь к php.ini '${installed}' /etc/opt/remi/'${installed}'" URL "/etc/opt/remi/'${installed}'"' >>"$hotlist_file"
  done
  echo "ENDGROUP" >>"$hotlist_file"
  mapfile -t users < <(find "/var/www" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -vE "^(cgi-bin|html)$" | sort)
  for user in "${users[@]}"; do
    echo 'ENTRY "Путь к сайтам '${user}' /var/www/'${user}'/www" URL "/var/www/'${user}'/www"' >>"$hotlist_file"
  done
}
