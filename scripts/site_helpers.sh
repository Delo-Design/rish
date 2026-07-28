#!/usr/bin/env bash

GREEN="${GREEN:-$'\033[0;32m'}"
RED="${RED:-$'\033[0;31m'}"
WHITE="${WHITE:-$'\033[0m'}"
YELLOW="${YELLOW:-$'\033[0;33m'}"

RISH_HOME="${RISH_HOME:-/root/rish}"
source "${RISH_HOME}/scripts/user_credentials.sh"

function normalize_relative_document_root() {
  local document_root="$1"

  document_root="${document_root#/}"
  if [[ -n "$document_root" ]]; then
    if [[ "$document_root" == "." || "$document_root" == ".." || "$document_root" == *"/../"* || "$document_root" == "../"* || "$document_root" == *"/.." ]]; then
      echo -e "DocumentRoot ${RED}некорректный${WHITE}: ${document_root}" >&2
      return 1
    fi
  fi

  printf '%s' "$document_root"
}

function validate_site_name() {
  local name="$1"

  echo "$name" | grep -Eq '^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$' || return 1

  if [[ "$name" =~ (^|\.)xn-- ]]; then
    idn2 -d "$name" > /dev/null 2>&1 || return 1
  fi

  return 0
}

function rish_get_site_document_root() {
  local site_name="$1"
  local vhost_file="/etc/httpd/conf.d/${site_name}.conf"
  local document_root

  validate_site_name "$site_name" || return 1
  [[ -f "$vhost_file" ]] || return 1

  document_root="$(awk '$1 == "DocumentRoot" { print $2; exit }' "$vhost_file")"
  document_root="$(realpath -e -- "$document_root" 2>/dev/null)" || return 1
  [[ -d "$document_root" ]] || return 1
  [[ "$document_root" == /var/www/* ]] || return 1

  printf '%s\n' "$document_root"
}

function rish_get_site_user() {
  local site_path="$1"
  local user
  local user_id
  local user_home
  local credentials_file

  if [[ "$site_path" =~ ^/var/www/([^/]+)/www(/.*)?$ ]]; then
    user="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  user_id="$(id -u "$user" 2>/dev/null)" || return 1
  [[ "$user_id" =~ ^[0-9]+$ ]] || return 1
  ((user_id > 0)) || return 1

  if ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sftp; then
    return 1
  fi

  user_home="$(getent passwd "$user" | awk -F: '{ print $6; exit }')"
  [[ "$user_home" == "/home/${user}" && -d "$user_home" && ! -L "$user_home" ]] || return 1

  credentials_file="$(rish_credentials_file "$user")" || return 1
  rish_credentials_file_is_secure "$credentials_file" || return 1

  printf '%s\n' "$user"
}

function db_exists() {
  local dbname="$1"
  local found

  found="$(mariadb -N -e "SHOW DATABASES LIKE '${dbname}'" 2>/dev/null)"
  [[ "$found" == "$dbname" ]]
}

function create_database_for_user() {
  local dbname="$1"
  local user="$2"

  if db_exists "$dbname"; then
    echo -e "База данных ${GREEN}${dbname}${WHITE} уже существует."
  else
    echo -e "Создаем базу данных ${GREEN}${dbname}${WHITE}."
    if ! mariadb -e "CREATE DATABASE \`${dbname}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
      echo -e "Не удалось создать базу данных ${RED}${dbname}${WHITE}."
      return 1
    fi
  fi

  echo -e "Выдаем права на базу ${GREEN}${dbname}${WHITE} пользователю ${GREEN}${user}${WHITE}."
  if ! mariadb -e "GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${user}'@'localhost';"; then
    echo -e "Не удалось выдать права на базу ${RED}${dbname}${WHITE} пользователю ${RED}${user}${WHITE}."
    return 1
  fi
  mariadb -e "FLUSH PRIVILEGES;"
}

function import_database_file() {
  local file="$1"
  local dbname="$2"
  local -a import_cmd=(mariadb)

  if [[ ! -f "$file" ]]; then
    echo -e "Файл дампа базы не найден: ${RED}${file}${WHITE}"
    return 1
  fi

  if mariadb --help | grep -q -- "--sandbox"; then
    import_cmd+=(--sandbox)
  fi
  import_cmd+=("$dbname")

  echo -e "Импортируем базу ${GREEN}${dbname}${WHITE} из файла ${GREEN}$(basename "$file")${WHITE}."

  if [[ "$file" == *.gz ]]; then
    if ! gzip -t "$file"; then
      echo -e "Файл ${RED}$(basename "$file")${WHITE} поврежден или не является gzip-архивом."
      return 1
    fi
    if ! (set -o pipefail; gunzip -c "$file" | "${import_cmd[@]}"); then
      echo -e "Произошла ${RED}ошибка${WHITE} при импорте базы ${RED}${dbname}${WHITE}."
      return 1
    fi
  else
    if ! "${import_cmd[@]}" < "$file"; then
      echo -e "Произошла ${RED}ошибка${WHITE} при импорте базы ${RED}${dbname}${WHITE}."
      return 1
    fi
  fi

  echo -e "База данных ${GREEN}${dbname}${WHITE} успешно импортирована."
}

function fix_joomla_configuration() {
  local site_path="$1"
  local site_name="$2"
  local db_name="${3:-$site_name}"

  local config_file="${site_path}/${site_name}/configuration.php"
  local site_full_path="${site_path}/${site_name}"

  echo -e "Настройка файла ${GREEN}configuration.php${WHITE}..."

  local user="${site_path#/var/www/}"
  user="${user%%/*}"

  local database_pass=""
  local credentials_file

  credentials_file="$(rish_credentials_file "$user")" || return 1
  if ! database_pass="$(read_user_credential "$user" "MariaDB" "Password")" || [[ -z "$database_pass" ]]; then
    echo -e "${RED}Не удалось прочитать пароль базы данных:${WHITE} ${credentials_file}"
    return 1
  fi

  sed -i "s|\$password.*$|\$password = '${database_pass}';|" "$config_file"
  echo -e "Пароль базы данных обновлен."

  sed -i "s|\$user.*$|\$user = '${user}';|" "$config_file"
  echo -e "Имя пользователя БД: ${GREEN}${user}${WHITE}"

  sed -i "s|\$db .*$|\$db = '${db_name}';|" "$config_file"
  echo -e "Имя базы данных: ${GREEN}${db_name}${WHITE}"

  sed -i "s|\$log_path .*$|\$log_path = '${site_full_path}/administrator/logs';|" "$config_file"
  echo -e "log_path: ${GREEN}${site_full_path}/administrator/logs${WHITE}"

  sed -i "s|\$tmp_path .*$|\$tmp_path = '${site_full_path}/tmp';|" "$config_file"
  echo -e "tmp_path: ${GREEN}${site_full_path}/tmp${WHITE}"

  sed -i "s|\$host.*$|\$host = 'localhost';|" "$config_file"
  echo -e "Хост базы данных установлен в: ${GREEN}localhost${WHITE}"

  local live_site_line=""
  local live_site_value=""

  live_site_line="$(grep -m 1 '^[[:space:]]*\(public[[:space:]]\+\)\?\$live_site[[:space:]]*=' "$config_file" || true)"
  if [[ -z "$live_site_line" ]]; then
    echo -e "Строка ${YELLOW}live_site${WHITE} не найдена."
  elif printf '%s\n' "$live_site_line" | grep -q "^[[:space:]]*\\(public[[:space:]]\\+\\)\\?\\\$live_site[[:space:]]*=[[:space:]]*''"; then
    echo -e "${YELLOW}live_site${WHITE} пустой, сброс не требуется."
  else
    live_site_value="$(printf '%s\n' "$live_site_line" | sed -n "s/^[[:space:]]*\\(public[[:space:]]\\+\\)\\?\\\$live_site[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\2/p")"
    if ! sed -i "s|\$live_site[[:space:]]*=.*$|\$live_site = '';|" "$config_file"; then
      echo -e "Не удалось сбросить ${RED}live_site${WHITE}."
      return 1
    fi
    if [[ -n "$live_site_value" ]]; then
      echo -e "${YELLOW}live_site${WHITE} сброшен: ${GREEN}${live_site_value}${WHITE} -> пусто."
    else
      echo -e "${YELLOW}live_site${WHITE} сброшен."
    fi
  fi
}

function fix_site_configuration() {
  local site_path="$1"
  local site_name="$2"
  local full_path="${site_path}/${site_name}"

  if [[ -f "$full_path/configuration.php" ]]; then
    echo
    echo -e "CMS определена как ${GREEN}Joomla${WHITE} - выполняем настройку..."
    fix_joomla_configuration "$site_path" "$site_name"
    return
  fi

  echo -e "CMS config для автоматической настройки не найден в ${YELLOW}${full_path}${WHITE}."
}
