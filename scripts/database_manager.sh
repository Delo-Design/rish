#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
LRED='\033[1;31m'
WHITE='\033[0m'

source /root/rish/windows.sh

SITE_DATABASES_FILE="/root/rish/site_databases"
CALL_DIRECTORY="${1:-}"
CALL_NAME="${2:-}"
DEFAULT_SITE_PATH=""
DEFAULT_SITE_NAME=""
DEFAULT_USER=""
DEFAULT_DB_NAME=""
SELECTED_DATABASE=""
SELECTED_SYSTEM_USER=""
LAST_DATABASE_MENU_Y=0
LAST_DATABASE_MENU_ACTION_X=0
LAST_DATABASE_MENU_RIGHT_X=0
LAST_DATABASE_SELECTED_ROW=0
DATABASE_CACHE_LOADED=0
DATABASE_CACHE_NAMES=()
DATABASE_CACHE_GRANTEES=()
DATABASE_CACHE_LABELS=()
DATABASE_MENU_DEFAULT_INDEX=0

wait_for_enter() {
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}

validate_db_name() {
  local db_name="$1"

  [[ "$db_name" =~ ^[A-Za-z0-9_][A-Za-z0-9_\$.-]{0,63}$ ]]
}

validate_site_name() {
  local site_name="$1"

  [[ "$site_name" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]
}

sql_escape_string() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf '%s' "$value"
}

sql_escape_identifier() {
  local value="$1"

  value="${value//\`/\`\`}"
  printf '%s' "$value"
}

is_system_database() {
  local db_name="$1"

  case "$db_name" in
    information_schema | mysql | performance_schema | sys)
      return 0
      ;;
  esac

  return 1
}

db_exists() {
  local db_name="$1"
  local db_name_sql
  local found

  db_name_sql="$(sql_escape_string "$db_name")"
  found="$(mariadb -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${db_name_sql}';" 2>/dev/null)"
  [[ "$found" == "$db_name" ]]
}

get_database_grantees() {
  local db_name="$1"
  local db_name_sql
  local grantee
  local i
  local grantees=()

  db_name_sql="$(sql_escape_string "$db_name")"
  while IFS= read -r grantee; do
    [[ -n "$grantee" ]] || continue
    grantee="${grantee#\'}"
    grantee="${grantee%%\'@*}"
    grantees+=("$grantee")
  done < <(
    mariadb -N -B -e "SELECT DISTINCT GRANTEE FROM INFORMATION_SCHEMA.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA='${db_name_sql}' ORDER BY GRANTEE;" 2>/dev/null
  )

  if ((${#grantees[@]} == 0)); then
    printf '%s' "права не определены"
    return
  fi

  printf '%s' "${grantees[0]}"
  for ((i = 1; i < ${#grantees[@]}; i++)); do
    printf ', %s' "${grantees[$i]}"
  done
}

get_database_size_label() {
  local db_name="$1"
  local db_name_sql
  local size_mb

  db_name_sql="$(sql_escape_string "$db_name")"
  size_mb="$(mariadb -N -B -e "SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1024 / 1024, 1), 0) FROM information_schema.tables WHERE table_schema='${db_name_sql}';" 2>/dev/null)"
  if [[ -z "$size_mb" ]]; then
    printf '%s' "неизвестно"
    return
  fi

  printf '%s MB' "$size_mb"
}

show_database_info() {
  local db_name="$1"
  local db_name_sql
  local stats
  local table_count
  local data_mb
  local index_mb
  local total_mb
  local charset_name
  local collation_name

  db_name_sql="$(sql_escape_string "$db_name")"
  stats="$(
    mariadb -N -B -e "
      SELECT
        COUNT(*),
        COALESCE(ROUND(SUM(data_length) / 1024 / 1024, 1), 0),
        COALESCE(ROUND(SUM(index_length) / 1024 / 1024, 1), 0),
        COALESCE(ROUND(SUM(data_length + index_length) / 1024 / 1024, 1), 0)
      FROM information_schema.tables
      WHERE table_schema='${db_name_sql}';
      SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME
      FROM information_schema.SCHEMATA
      WHERE SCHEMA_NAME='${db_name_sql}';
    " 2>/dev/null
  )"

  table_count="$(printf '%s\n' "$stats" | sed -n '1p' | awk '{ print $1 }')"
  data_mb="$(printf '%s\n' "$stats" | sed -n '1p' | awk '{ print $2 }')"
  index_mb="$(printf '%s\n' "$stats" | sed -n '1p' | awk '{ print $3 }')"
  total_mb="$(printf '%s\n' "$stats" | sed -n '1p' | awk '{ print $4 }')"
  charset_name="$(printf '%s\n' "$stats" | sed -n '2p' | awk '{ print $1 }')"
  collation_name="$(printf '%s\n' "$stats" | sed -n '2p' | awk '{ print $2 }')"

  clear
  echo -e "База данных: ${GREEN}${db_name}${WHITE}"
  echo -e "Пользователь с доступом: ${YELLOW}$(get_database_grantees "$db_name")${WHITE}"
  echo -e "Размер базы: ${GREEN}${total_mb:-неизвестно} MB${WHITE}"
  echo -e "Таблиц: ${GREEN}${table_count:-0}${WHITE}"
  echo -e "Данные: ${GREEN}${data_mb:-0} MB${WHITE}"
  echo -e "Индексы: ${GREEN}${index_mb:-0} MB${WHITE}"
  echo -e "Кодировка: ${GREEN}${charset_name:-неизвестно}${WHITE}"
  echo -e "Сравнение: ${GREEN}${collation_name:-неизвестно}${WHITE}"
  wait_for_enter
}

load_database_cache() {
  local db_name
  local grantees
  local max_db_name_length=0
  local db_padding
  local i

  DATABASE_CACHE_NAMES=()
  DATABASE_CACHE_GRANTEES=()
  DATABASE_CACHE_LABELS=()

  while IFS= read -r db_name; do
    [[ -n "$db_name" ]] || continue
    is_system_database "$db_name" && continue
    DATABASE_CACHE_NAMES+=("$db_name")
    grantees="$(get_database_grantees "$db_name")"
    DATABASE_CACHE_GRANTEES+=("$grantees")
    if ((${#db_name} > max_db_name_length)); then
      max_db_name_length=${#db_name}
    fi
  done < <(mariadb -N -B -e "SHOW DATABASES;" 2>/dev/null)

  for i in "${!DATABASE_CACHE_NAMES[@]}"; do
    db_name="${DATABASE_CACHE_NAMES[$i]}"
    grantees="${DATABASE_CACHE_GRANTEES[$i]}"
    printf -v db_padding "%*s" "$((max_db_name_length - ${#db_name}))" ""
    DATABASE_CACHE_LABELS+=("${db_name}${db_padding}  (${grantees})")
  done

  DATABASE_CACHE_LOADED=1
}

invalidate_database_cache() {
  DATABASE_CACHE_LOADED=0
}

ensure_site_databases_file() {
  if [[ ! -f "$SITE_DATABASES_FILE" ]]; then
    {
      echo "# site_path;db_name"
    } > "$SITE_DATABASES_FILE"
    chmod 600 "$SITE_DATABASES_FILE" 2>/dev/null || true
  fi
}

normalize_site_path() {
  local site_path="$1"

  site_path="${site_path%/}"
  printf '%s' "$site_path"
}

set_site_db_mapping() {
  local site_path="$1"
  local db_name="$2"
  local normalized_path
  local tmp_file
  local line
  local updated=0

  normalized_path="$(normalize_site_path "$site_path")"
  ensure_site_databases_file
  tmp_file="$(mktemp "${SITE_DATABASES_FILE}.XXXXXX")" || return 1

  while IFS= read -r line; do
    if [[ -n "$line" && "$line" != \#* && "${line%%;*}" == "$normalized_path" ]]; then
      echo "${normalized_path};${db_name}" >> "$tmp_file"
      updated=1
    else
      echo "$line" >> "$tmp_file"
    fi
  done < "$SITE_DATABASES_FILE"

  if [[ "$updated" -eq 0 ]]; then
    echo "${normalized_path};${db_name}" >> "$tmp_file"
  fi

  mv -f "$tmp_file" "$SITE_DATABASES_FILE"
  chmod 600 "$SITE_DATABASES_FILE" 2>/dev/null || true
}

remove_site_db_mapping() {
  local site_path="$1"
  local normalized_path
  local tmp_file
  local line

  normalized_path="$(normalize_site_path "$site_path")"
  [[ -f "$SITE_DATABASES_FILE" ]] || return 0
  tmp_file="$(mktemp "${SITE_DATABASES_FILE}.XXXXXX")" || return 1

  while IFS= read -r line; do
    if [[ -n "$line" && "$line" != \#* && "${line%%;*}" == "$normalized_path" ]]; then
      continue
    fi
    echo "$line" >> "$tmp_file"
  done < "$SITE_DATABASES_FILE"

  mv -f "$tmp_file" "$SITE_DATABASES_FILE"
  chmod 600 "$SITE_DATABASES_FILE" 2>/dev/null || true
}

remove_db_mappings_by_db_name() {
  local db_name="$1"
  local tmp_file
  local line

  [[ -f "$SITE_DATABASES_FILE" ]] || return 0
  tmp_file="$(mktemp "${SITE_DATABASES_FILE}.XXXXXX")" || return 1

  while IFS= read -r line; do
    if [[ -n "$line" && "$line" != \#* && "${line#*;}" == "$db_name" ]]; then
      continue
    fi
    echo "$line" >> "$tmp_file"
  done < "$SITE_DATABASES_FILE"

  mv -f "$tmp_file" "$SITE_DATABASES_FILE"
  chmod 600 "$SITE_DATABASES_FILE" 2>/dev/null || true
}

detect_context() {
  local directory="$CALL_DIRECTORY"
  local name="$CALL_NAME"
  local candidate_path

  directory="${directory%/}"
  candidate_path="${directory}/${name}"

  if [[ "$directory" =~ ^/var/www/([^/]+)/www$ ]] && [[ -d "$candidate_path" ]] && validate_site_name "$name"; then
    DEFAULT_USER="${BASH_REMATCH[1]}"
    DEFAULT_SITE_NAME="$name"
    DEFAULT_SITE_PATH="$candidate_path"
    DEFAULT_DB_NAME="$name"
    return
  fi

  if [[ "$directory" =~ ^/var/www/([^/]+)(/|$) ]]; then
    DEFAULT_USER="${BASH_REMATCH[1]}"
  fi

}

select_system_user() {
  local default_user="$1"
  local choice
  local default_index=0
  local i
  local -a users=()

  mapfile -t users < <(awk -F: '$6 ~ /^\/home\// { print $1 }' /etc/passwd | sort)
  if ((${#users[@]} == 0)); then
    echo "В системе нет пользователей RISH."
    return 1
  fi

  if [[ -n "$default_user" ]]; then
    for i in "${!users[@]}"; do
      if [[ "${users[$i]}" == "$default_user" ]]; then
        default_index="$i"
        break
      fi
    done
  fi

  echo "Выберите пользователя, которому будут выданы права:"
  vertical_menu "current" 2 0 30 "default=${default_index}" "${users[@]}" "Выйти"
  choice=$?
  if ((choice == 255 || choice == ${#users[@]})); then
    return 1
  fi

  SELECTED_SYSTEM_USER="${users[$choice]}"
}

apply_site_db_mapping_after_create() {
  local db_name="$1"

  [[ -n "$DEFAULT_SITE_PATH" && -n "$DEFAULT_SITE_NAME" ]] || return 0

  if [[ "$db_name" == "$DEFAULT_SITE_NAME" ]]; then
    remove_site_db_mapping "$DEFAULT_SITE_PATH"
    return
  fi

  set_site_db_mapping "$DEFAULT_SITE_PATH" "$db_name"
}

create_database() {
  local db_name="$DEFAULT_DB_NAME"
  local db_name_ident
  local user_name
  local user_name_sql
  local choice

  echo -e "${WHITE}Введите имя базы данных (пустая строка для выхода): ${GREEN}"
  read -r -e -i "$db_name" db_name
  echo -en "${WHITE}"

  if [[ -z "$db_name" ]]; then
    echo "Создание базы данных отменено."
    return
  fi

  if ! validate_db_name "$db_name"; then
    echo -e "Имя базы данных ${RED}${db_name}${WHITE} некорректное."
    return
  fi

  if db_exists "$db_name"; then
    echo -e "База данных ${GREEN}${db_name}${WHITE} уже существует."
    return
  fi

  select_system_user "$DEFAULT_USER" || return
  user_name="$SELECTED_SYSTEM_USER"
  db_name_ident="$(sql_escape_identifier "$db_name")"
  user_name_sql="$(sql_escape_string "$user_name")"

  echo
  echo -e "Будет создана база: ${GREEN}${db_name}${WHITE}"
  echo -e "Права будут выданы пользователю: ${GREEN}${user_name}${WHITE}"
  if [[ -n "$DEFAULT_SITE_PATH" ]]; then
    echo -e "Сайт: ${GREEN}${DEFAULT_SITE_PATH}${WHITE}"
  fi
  vertical_menu "current" 2 0 5 "Да" "Нет"
  choice=$?
  if ((choice != 0)); then
    echo "База данных не была создана."
    return
  fi

  if ! mariadb -e "CREATE DATABASE \`${db_name_ident}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
    echo -e "Не удалось создать базу данных ${RED}${db_name}${WHITE}."
    return
  fi
  invalidate_database_cache

  if ! mariadb -e "GRANT ALL PRIVILEGES ON \`${db_name_ident}\`.* TO '${user_name_sql}'@'localhost'; FLUSH PRIVILEGES;"; then
    echo -e "База создана, но права пользователю ${RED}${user_name}${WHITE} выдать не удалось."
    echo "Проверьте пользователя MariaDB или выдайте права вручную."
    return
  fi

  if ! apply_site_db_mapping_after_create "$db_name"; then
    echo -e "База создана, но связь сайта с базой сохранить не удалось."
    return
  fi

  echo -e "База данных ${GREEN}${db_name}${WHITE} создана, права выданы пользователю ${GREEN}${user_name}${WHITE}."
}

select_database() {
  local choice

  if [[ "$DATABASE_CACHE_LOADED" -eq 0 ]]; then
    load_database_cache
  fi

  vertical_menu "current_noclear" 2 20 5 "default=${DATABASE_MENU_DEFAULT_INDEX}" "Создать базу данных" "${DATABASE_CACHE_LABELS[@]}" "Выйти"
  choice=$?
  LAST_DATABASE_MENU_Y="$VERTICAL_MENU_LAST_Y"
  LAST_DATABASE_MENU_ACTION_X="$(vertical_menu_next_x 2)"
  LAST_DATABASE_MENU_RIGHT_X="$VERTICAL_MENU_LAST_RIGHT_X"
  LAST_DATABASE_SELECTED_ROW=$((LAST_DATABASE_MENU_Y + VERTICAL_MENU_LAST_VISIBLE_SELECTED + 1))

  if ((choice == 255 || choice == ${#DATABASE_CACHE_NAMES[@]} + 1)); then
    return 1
  fi

  if ((choice == 0)); then
    DATABASE_MENU_DEFAULT_INDEX=0
    SELECTED_DATABASE=""
    return 2
  fi

  DATABASE_MENU_DEFAULT_INDEX="$choice"
  SELECTED_DATABASE="${DATABASE_CACHE_NAMES[$((choice - 1))]}"
}

delete_database() {
  local db_name="$1"
  local db_name_ident
  local choice

  echo -e "Вы хотите удалить базу данных ${LRED}${db_name}${WHITE}?"
  vertical_menu "current" 2 0 5 "Нет" "Да"
  choice=$?
  if ((choice != 1)); then
    echo "База данных не была удалена."
    return
  fi

  db_name_ident="$(sql_escape_identifier "$db_name")"
  if mariadb -e "DROP DATABASE \`${db_name_ident}\`;"; then
    remove_db_mappings_by_db_name "$db_name"
    invalidate_database_cache
    if ((DATABASE_MENU_DEFAULT_INDEX > 1)); then
      DATABASE_MENU_DEFAULT_INDEX=$((DATABASE_MENU_DEFAULT_INDEX - 1))
    else
      DATABASE_MENU_DEFAULT_INDEX=0
    fi
    echo -e "База данных ${GREEN}${db_name}${WHITE} удалена."
  else
    echo -e "При удалении базы данных ${RED}${db_name}${WHITE} произошли ${RED}ошибки${WHITE}."
  fi
}

draw_database_action_connector() {
  local from_x="$LAST_DATABASE_MENU_RIGHT_X"
  local to_x="$LAST_DATABASE_MENU_ACTION_X"
  local row="$LAST_DATABASE_SELECTED_ROW"
  local length

  length=$((to_x - from_x))
  if ((length <= 1)); then
    return
  fi

  cursor_to "$row" "$from_x"
  printf "├"
  repl "─" "$((length - 1))"
}

database_actions_menu() {
  local db_name="$1"
  local size_label
  local choice
  local action_menu_y

  size_label="$(get_database_size_label "$db_name")"
  while true; do
    action_menu_y=$((LAST_DATABASE_SELECTED_ROW - 1))
    draw_database_action_connector
    vertical_menu "$action_menu_y" "$LAST_DATABASE_MENU_ACTION_X" 0 5 "Инфо о базе: ${size_label}" "Удалить базу данных" "Назад"
    choice=$?

    case "$choice" in
      0)
        show_database_info "$db_name"
        return
        ;;
      1)
        clear
        echo
        echo -e "База данных: ${GREEN}${db_name}${WHITE}"
        echo -e "Пользователь с доступом: ${YELLOW}$(get_database_grantees "$db_name")${WHITE}"
        delete_database "$db_name"
        wait_for_enter
        return
        ;;
      2 | 255)
        return
        ;;
    esac
  done
}

database_manager_menu() {
  local select_result

  while true; do
    clear
    echo -e "Управление базами данных ${GREEN}RISH${WHITE}"
    if [[ -n "$DEFAULT_USER" ]]; then
      echo -e "Пользователь по умолчанию: ${GREEN}${DEFAULT_USER}${WHITE}"
    fi
    if [[ -n "$DEFAULT_DB_NAME" ]]; then
      echo -e "Имя базы по умолчанию: ${GREEN}${DEFAULT_DB_NAME}${WHITE}"
    fi
    echo

    select_database
    select_result=$?
    case "$select_result" in
      1)
        exit 0
        ;;
      2)
        clear
        create_database
        wait_for_enter
        ;;
      0)
        database_actions_menu "$SELECTED_DATABASE"
        ;;
    esac
  done
}

detect_context
database_manager_menu
