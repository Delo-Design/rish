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

directory="$1"
site_name="$2"
directory="${directory%/}"
site_path="${directory}/${site_name}"

clear
if [[ ! "$directory" =~ ^/var/www/([^/]+)/www$ ]]; then
  fail "Удалять сайт можно только из папки /var/www/<пользователь>/www."
fi
user_name="${BASH_REMATCH[1]}"

if [[ ! "$site_name" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]; then
  fail "Имя выбранной папки ${YELLOW}${site_name}${WHITE} не является корректным именем сайта. Удаление прервано."
fi

if [[ ! -d "$site_path" ]]; then
  fail "Это не является папкой сайта. Удаление прервано."
fi

if [[ ! -f "/etc/httpd/conf.d/${site_name}.conf" ]]; then
  fail "Для выбранной папки ${YELLOW}${site_path}${WHITE} не найден Apache vhost ${YELLOW}/etc/httpd/conf.d/${site_name}.conf${WHITE}. Удаление прервано."
fi

echo -e "Вы действительно хотите удалить сайт ${LRED}${site_name}${WHITE}?"
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
  echo -e "Папка сайта ${GREEN}${site_name}${WHITE} удалена"
else
  trap - EXIT
  restore_vhosts
  apachectl configtest && systemctl reload httpd
  fail "В процессе удаления папки сайта ${RED}${site_name}${WHITE} возникли проблемы. Apache vhost восстановлен."
fi
trap - EXIT
rm -rf "$vhost_backup_dir"

echo "Проверяем наличие сертификата у сайта"
if command -v certbot >/dev/null 2>&1; then
  if certbot certificates --cert-name "$site_name" | grep "$site_name" &>/dev/null; then
    echo "У сайта есть SSL сертификат"
    echo "Производим отзыв сертификата"
    certbot revoke --cert-path "/etc/letsencrypt/live/${site_name}/cert.pem"
  else
    echo "У сайта нет SSL сертификата"
  fi
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
    echo -e "База данных ${GREEN}${site_name}${WHITE} удалена"
  else
    echo -e "При удалении базы данных ${RED}${site_name}${WHITE} произошли ${RED}ошибки${WHITE}"
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
