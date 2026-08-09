#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
LRED='\033[1;31m'
WHITE='\033[0m'

source /root/rish/windows.sh

fail() {
  echo -e "$1"
  vertical_menu "current" 2 0 5 "Нажмите Enter"
  exit 1
}

site_display_name() {
  local name="$1"
  local decoded_name

  if [[ "$name" =~ (xn\-\-) ]]; then
    decoded_name="$(idn2 -d "$name" 2>/dev/null)"
    if [[ -n "$decoded_name" && "$decoded_name" != "$name" ]]; then
      printf '%s (%s)' "$name" "$decoded_name"
      return 0
    fi
  else
    printf '%s' "$name"
    return 0
  fi

  printf '%s' "$name"
}

apache_vhost_directive_value() {
  local vhost_file="$1"
  local directive="$2"

  awk -v directive="$directive" '
    tolower($1)==tolower(directive) {print $2; exit}
  ' "$vhost_file"
}

find_other_vhost_certificate_reference() {
  local certificate_file="$1"
  local private_key_file="$2"
  local vhost_file

  for vhost_file in /etc/httpd/conf.d/*.conf; do
    [[ -f "$vhost_file" ]] || continue
    if awk -v certificate_file="$certificate_file" -v private_key_file="$private_key_file" '
      tolower($1)=="sslcertificatefile" && $2==certificate_file {found=1}
      tolower($1)=="sslcertificatekeyfile" && $2==private_key_file {found=1}
      END {exit !found}
    ' "$vhost_file"; then
      printf '%s' "$vhost_file"
      return 0
    fi
  done

  return 1
}

remove_site_from_backup_list() {
  local list_file="/root/rish/backup_list_all"
  local list_dir list_name temp_file removed_count

  [[ -e "$list_file" || -L "$list_file" ]] || return 0
  if [[ ! -f "$list_file" || -L "$list_file" ]]; then
    return 1
  fi

  removed_count="$(awk -F';' -v user="$user_name" -v site="$site_name" '
    $1 == user && $2 == site { count++ }
    END { print count + 0 }
  ' "$list_file")" || return 1
  [[ "$removed_count" =~ ^[0-9]+$ ]] || return 1
  ((removed_count > 0)) || return 0

  list_dir="$(dirname "$list_file")"
  list_name="$(basename "$list_file")"
  temp_file="$(mktemp "${list_dir}/.${list_name}.rish-tmp.XXXXXX")" || return 1
  if ! awk -F';' -v user="$user_name" -v site="$site_name" '
    $1 != user || $2 != site { print }
  ' "$list_file" > "$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi
  if ! chmod --reference="$list_file" "$temp_file" ||
    ! chown --reference="$list_file" "$temp_file" ||
    ! mv -f -- "$temp_file" "$list_file"; then
    rm -f -- "$temp_file"
    return 1
  fi

  echo -e "Сайт ${GREEN}${site_label}${WHITE} удалён из списка резервного копирования."
  return 0
}

directory="$1"
site_name="$2"
directory="${directory%/}"
site_path="${directory}/${site_name}"
delete_site_status=0

clear
if [[ ! "$directory" =~ ^/var/www/([^/]+)/www$ ]]; then
  fail "Удалять сайт можно только из папки /var/www/<пользователь>/www."
fi
user_name="${BASH_REMATCH[1]}"

if [[ ! "$site_name" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]; then
  fail "Имя выбранной папки ${YELLOW}${site_name}${WHITE} не является корректным именем сайта. Удаление прервано."
fi
if [[ "$site_name" =~ (^|\.)xn-- ]] && ! idn2 -d "$site_name" >/dev/null 2>&1; then
  fail "Имя выбранной папки ${YELLOW}${site_name}${WHITE} содержит некорректный punycode. Удаление прервано."
fi
site_label="$(site_display_name "$site_name")"

if [[ ! -d "$site_path" ]]; then
  fail "Это не является папкой сайта. Удаление прервано."
fi

if [[ ! -f "/etc/httpd/conf.d/${site_name}.conf" ]]; then
  fail "Для выбранной папки ${YELLOW}${site_path}${WHITE} не найден Apache vhost ${YELLOW}/etc/httpd/conf.d/${site_name}.conf${WHITE}. Удаление прервано."
fi

echo -e "Вы действительно хотите удалить сайт ${LRED}${site_label}${WHITE}?"
vertical_menu "current" 2 0 5 "Нет" "Да"
choice=$?
if [[ "$choice" == "255" || "$choice" == "0" ]]; then
  exit
fi

vhost_backup_dir="$(mktemp -d)" || {
  fail "Не удалось подготовить временную папку. Удаление сайта ${RED}прервано${WHITE}."
}
vhost_files=(
  "/etc/httpd/conf.d/${site_name}.conf"
  "/etc/httpd/conf.d/${site_name}-ssl.conf"
  "/etc/httpd/conf.d/${site_name}-le-ssl.conf"
)
selectel_vhost_file="/etc/httpd/conf.d/${site_name}-selectel-ssl.conf"
selectel_certificate_script="/root/rish/scripts/certificates/selectel.sh"
if [[ ! -f "$selectel_certificate_script" ]]; then
  selectel_certificate_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certificates/selectel.sh"
fi
selectel_lock_fd=""
selectel_cleanup_failed=0
if [[ -f "$selectel_vhost_file" ]] &&
  grep -Fqx '# Managed by RISH Selectel certificate integration.' "$selectel_vhost_file"; then
  if ! command -v flock >/dev/null 2>&1; then
    rmdir "$vhost_backup_dir" 2>/dev/null || true
    fail "Не найдена команда ${YELLOW}flock${WHITE}. Удаление сайта ${RED}прервано${WHITE}."
  fi
  exec {selectel_lock_fd}> /run/lock/rish-selectel-certificates.lock || {
    rmdir "$vhost_backup_dir" 2>/dev/null || true
    fail "Не удалось открыть lock-файл сертификатов Selectel. Удаление сайта ${RED}прервано${WHITE}."
  }
  if ! flock -n "$selectel_lock_fd"; then
    exec {selectel_lock_fd}>&-
    selectel_lock_fd=""
    rmdir "$vhost_backup_dir" 2>/dev/null || true
    fail "Сейчас выполняется синхронизация сертификатов Selectel. Повторите удаление сайта позже."
  fi
  vhost_files+=("$selectel_vhost_file")
fi

restore_vhosts() {
  local vhost_file

  shopt -s nullglob
  for vhost_file in "$vhost_backup_dir"/*; do
    mv -f "$vhost_file" /etc/httpd/conf.d/
  done
  shopt -u nullglob
  rmdir "$vhost_backup_dir"
}

trap restore_vhosts EXIT
for vhost_file in "${vhost_files[@]}"; do
  [[ -f "$vhost_file" ]] || continue
  if ! mv "$vhost_file" "$vhost_backup_dir/"; then
    trap - EXIT
    restore_vhosts
    fail "Не удалось временно переместить Apache vhost ${YELLOW}${vhost_file}${WHITE}. Удаление сайта ${RED}прервано${WHITE}."
  fi
done
if [[ -n "$(find "$vhost_backup_dir" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]]; then
  echo -e "Файлы виртуальных хостов ${GREEN}/etc/httpd/conf.d/${site_name}${WHITE} удалены."
else
  echo -e "Файлы виртуального хоста ${RED}удалить не удалось${WHITE}."
fi

if apachectl configtest && systemctl reload httpd; then
  echo "Сервер перезагружен."
else
  trap - EXIT
  restore_vhosts
  fail "Сервер не был перезагружен. ${RED}Ошибка${WHITE} в конфигурации апача. Удаление сайта ${RED}прервано${WHITE}."
fi

if rm -R "$site_path"; then
  echo -e "Папка сайта ${GREEN}${site_label}${WHITE} удалена"
else
  trap - EXIT
  restore_vhosts
  apachectl configtest && systemctl reload httpd
  fail "В процессе удаления папки сайта ${RED}${site_label}${WHITE} возникли проблемы. Apache vhost восстановлен."
fi
trap - EXIT

if ! remove_site_from_backup_list; then
  echo -e "Не удалось удалить сайт ${LRED}${site_label}${WHITE} из списка резервного копирования."
  echo -e "Проверьте файл ${YELLOW}/root/rish/backup_list_all${WHITE}."
  delete_site_status=1
fi

certbot_vhost_backup="${vhost_backup_dir}/${site_name}-le-ssl.conf"
certbot_fullchain_file=""
certbot_private_key_file=""
certbot_certificate_file=""
certbot_lineage_dir=""
certbot_lineage_name=""
if [[ -f "$certbot_vhost_backup" ]]; then
  certbot_fullchain_file="$(apache_vhost_directive_value "$certbot_vhost_backup" SSLCertificateFile)"
  certbot_private_key_file="$(apache_vhost_directive_value "$certbot_vhost_backup" SSLCertificateKeyFile)"
  if [[ "$certbot_fullchain_file" == /etc/letsencrypt/live/*/fullchain.pem ]]; then
    certbot_lineage_dir="${certbot_fullchain_file%/fullchain.pem}"
    certbot_lineage_name="${certbot_lineage_dir#/etc/letsencrypt/live/}"
  fi
  if [[ -z "$certbot_lineage_name" ||
    "$certbot_lineage_name" == */* ||
    "$certbot_private_key_file" != "${certbot_lineage_dir}/privkey.pem" ]]; then
    echo -e "Не удалось безопасно определить Certbot lineage из ${YELLOW}${certbot_vhost_backup}${WHITE}."
    echo "SSL-vhost сайта удалён, сертификат Certbot оставлен без изменений."
    delete_site_status=1
    certbot_lineage_dir=""
  else
    certbot_certificate_file="${certbot_lineage_dir}/cert.pem"
  fi
fi

selectel_vhost_backup="${vhost_backup_dir}/${site_name}-selectel-ssl.conf"
if [[ -f "$selectel_vhost_backup" ]]; then
  if [[ -f "$selectel_certificate_script" ]]; then
    if ! RISH_SELECTEL_CERT_LOCK_HELD=1 \
      bash "$selectel_certificate_script" cleanup-local-files "$selectel_vhost_backup"; then
      echo -e "Не удалось удалить локальные файлы сертификата Selectel для ${RED}${site_label}${WHITE}."
      selectel_cleanup_failed=1
      delete_site_status=1
    fi
  else
    echo -e "Не найден скрипт очистки сертификата Selectel. Локальные файлы для ${RED}${site_label}${WHITE} оставлены без изменений."
    selectel_cleanup_failed=1
    delete_site_status=1
  fi
fi

dns_domain_dir="/root/rish/dns/domains/${site_name}"
if [[ -e "$dns_domain_dir" || -L "$dns_domain_dir" ]]; then
  dns_cleanup_result=""
  if [[ ! -f "$selectel_certificate_script" ]]; then
    echo -e "Не удалось проверить использование DNS credentials Selectel. Настройки ${YELLOW}${dns_domain_dir}${WHITE} сохранены."
    delete_site_status=1
  elif [[ -n "$selectel_lock_fd" ]]; then
    if dns_cleanup_result="$(
      RISH_SELECTEL_CERT_LOCK_HELD=1 \
        bash "$selectel_certificate_script" cleanup-dns-if-unused "$dns_domain_dir"
    )"; then
      if [[ "$dns_cleanup_result" == "in-use" ]]; then
        echo -e "Локальные настройки DNS сохранены: их используют другие сертификаты Selectel для зоны ${GREEN}${site_label}${WHITE}."
      else
        echo -e "Локальные настройки DNS для ${GREEN}${site_label}${WHITE} удалены."
      fi
    else
      echo -e "Не удалось безопасно проверить и удалить локальные настройки DNS для ${RED}${site_label}${WHITE}. Настройки сохранены."
      delete_site_status=1
    fi
  else
    if dns_cleanup_result="$(
      bash "$selectel_certificate_script" cleanup-dns-if-unused "$dns_domain_dir"
    )"; then
      if [[ "$dns_cleanup_result" == "in-use" ]]; then
        echo -e "Локальные настройки DNS сохранены: их используют другие сертификаты Selectel для зоны ${GREEN}${site_label}${WHITE}."
      else
        echo -e "Локальные настройки DNS для ${GREEN}${site_label}${WHITE} удалены."
      fi
    else
      echo -e "Не удалось безопасно проверить и удалить локальные настройки DNS для ${RED}${site_label}${WHITE}. Настройки сохранены."
      delete_site_status=1
    fi
  fi
fi
if [[ -n "$selectel_lock_fd" ]]; then
  flock -u "$selectel_lock_fd"
  exec {selectel_lock_fd}>&-
fi

if [[ -n "$certbot_certificate_file" ]]; then
  certbot_other_vhost="$(
    find_other_vhost_certificate_reference \
      "$certbot_fullchain_file" \
      "$certbot_private_key_file"
  )" || certbot_other_vhost=""
  if [[ -n "$certbot_other_vhost" ]]; then
    echo -e "Certbot lineage ${YELLOW}${certbot_lineage_name}${WHITE} сохранён: его использует ${YELLOW}${certbot_other_vhost}${WHITE}."
  elif ! command -v certbot >/dev/null 2>&1; then
    echo -e "Не найдена команда ${RED}certbot${WHITE}. Lineage ${YELLOW}${certbot_lineage_name}${WHITE} не отозван."
    delete_site_status=1
  elif [[ ! -f "$certbot_certificate_file" ]]; then
    echo -e "Не найден сертификат Certbot: ${YELLOW}${certbot_certificate_file}${WHITE}."
    echo "Автоматический отзыв не выполнен."
    delete_site_status=1
  else
    echo -e "Отзываем и удаляем Certbot lineage ${GREEN}${certbot_lineage_name}${WHITE}."
    if ! certbot revoke \
      --cert-path "$certbot_certificate_file" \
      --delete-after-revoke \
      --non-interactive; then
      echo -e "Сайт удалён, но сертификат Certbot ${RED}не удалось отозвать и удалить${WHITE}."
      if [[ -f "$certbot_certificate_file" ]]; then
        echo -e "Локальный lineage оставлен в ${YELLOW}${certbot_lineage_dir}${WHITE} для повторной попытки."
      else
        echo "Файлы lineage уже удалены. Проверьте журнал Certbot, чтобы уточнить результат отзыва."
      fi
      delete_site_status=1
    fi
  fi
fi

if ((selectel_cleanup_failed == 1)); then
  for vhost_file in "$vhost_backup_dir"/*; do
    [[ -f "$vhost_file" && "$vhost_file" != "$selectel_vhost_backup" ]] || continue
    rm -f -- "$vhost_file"
  done
  echo -e "Данные для повторной очистки сохранены: ${YELLOW}${selectel_vhost_backup}${WHITE}"
  if [[ -f "$selectel_certificate_script" ]]; then
    echo "Повторная очистка: bash ${selectel_certificate_script} cleanup-local-files ${selectel_vhost_backup}"
  fi
else
  rm -rf "$vhost_backup_dir"
fi

rm -f \
  /var/www/"${user_name}"/logs/"${site_name}"-access-log* \
  /var/www/"${user_name}"/logs/"${site_name}"-error-log* &>/dev/null
if [[ $? -eq 0 ]]; then
  echo -e "Логи сайта ${GREEN}удалены${WHITE}."
else
  echo -e "Логи сайта ${RED}удалены не были${WHITE}."
fi

if [[ -n "$(mariadb -uroot -qfsBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${site_name}'" 2>&1)" ]]; then
  echo "У сайта есть база данных"
  if mariadb-admin -f -u root drop "$site_name"; then
    echo -e "База данных ${GREEN}${site_label}${WHITE} удалена"
  else
    echo -e "При удалении базы данных ${RED}${site_label}${WHITE} произошли ${RED}ошибки${WHITE}"
  fi
fi

local_ssl_key="/etc/pki/tls/private/${site_name}.key"
if [[ -f "$local_ssl_key" ]]; then
  if rm -f "$local_ssl_key"; then
    echo -e "Удален локальный SSL-ключ: ${YELLOW}${local_ssl_key}${WHITE}"
  else
    echo -e "Не удалось удалить локальный SSL-ключ: ${YELLOW}${local_ssl_key}${WHITE}"
  fi
fi

local_ssl_cert="/etc/pki/tls/certs/${site_name}.crt"
if [[ -f "$local_ssl_cert" ]]; then
  if rm -f "$local_ssl_cert"; then
    echo -e "Удален локальный SSL-сертификат: ${YELLOW}${local_ssl_cert}${WHITE}"
  else
    echo -e "Не удалось удалить локальный SSL-сертификат: ${YELLOW}${local_ssl_cert}${WHITE}"
  fi
fi

source /root/rish/create_hotlist.sh
create_hotlist

echo "Убедитесь что для сайта не установлены задания CRON."
echo "Удалить задания можно через пункт Управление CRON в меню MC."
echo
echo -e "CRON пользователя ${YELLOW}root${WHITE}:"
crontab -l -u root 2>&1
echo
echo -e "CRON пользователя ${YELLOW}${user_name}${WHITE}:"
crontab -l -u "$user_name" 2>&1
echo
echo "Нажмите Enter"
vertical_menu "current" 2 0 5 "Да"
exit "$delete_site_status"
