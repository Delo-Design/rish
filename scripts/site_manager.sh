#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
WHITE='\033[0m'

source /root/rish/windows.sh

file_name="$1"
directory="$2"
directory="${directory%/}"
site_path="${directory}/${file_name}"
create_site_name="$file_name"

fail() {
  echo -e "$1"
  vertical_menu "current" 2 0 5 "Нажмите Enter"
  exit 1
}

is_valid_site_name() {
  local name="$1"

  [[ "$name" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]
}

site_is_created() {
  [[ "$directory" =~ ^/var/www/([^/]+)/www$ ]] || return 1
  is_valid_site_name "$file_name" || return 1
  [[ -d "$site_path" ]] || return 1
  [[ -f "/etc/httpd/conf.d/${file_name}.conf" ]]
}

vhost_exists() {
  is_valid_site_name "$file_name" || return 1
  [[ -f "/etc/httpd/conf.d/${file_name}.conf" ]]
}

clear

if [[ -z "$file_name" || -z "$directory" ]]; then
  fail "Не переданы параметры Midnight Commander."
fi

if [[ ! "$directory" =~ ^/var/www/[^/]+/www$ ]]; then
  fail "Создавать и удалять сайты можно только из папки ${YELLOW}/var/www/<user>/www${WHITE}."
fi

if site_is_created; then
  echo -e "Для сайта ${GREEN}${file_name}${WHITE} доступны действия:"
  vertical_menu "current" 2 0 32 "Удалить сайт" "Создать сайт с другим именем" "Выйти"
  choice=$?
  case "$choice" in
    0) bash /root/rish/scripts/delete_site.sh "$directory" "$file_name" ;;
    1) bash /root/rish/create_site.sh "$file_name" "$directory" ;;
    *) exit 0 ;;
  esac
else
  if [[ "$file_name" == "." || "$file_name" == ".." ]]; then
    create_site_name=""
    echo "Создание нового сайта."
  else
    echo -e "Для выбранной папки ${GREEN}${file_name}${WHITE} сайт еще не создан."
  fi
  if vhost_exists; then
    fail "Для имени ${YELLOW}${file_name}${WHITE} найден vhost, но папка сайта ${YELLOW}${site_path}${WHITE} не найдена."
  fi
  vertical_menu "current" 2 0 20 "Создать сайт" "Выйти"
  choice=$?
  case "$choice" in
    0) bash /root/rish/create_site.sh "$create_site_name" "$directory" ;;
    *) exit 0 ;;
  esac
fi
