#!/usr/bin/env bash

RISH_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
export RISH_HOME

# These color globals are used by the sourced user-management modules.
# shellcheck disable=SC2034
GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
VIOLET='\033[0;35m'
WHITE='\033[0m'
# Used by scripts/delete_user.sh loaded below.
# shellcheck disable=SC2034
YELLOW='\033[0;33m'
CURSORUP='\033[1A'

source "${RISH_HOME}/windows.sh"
source "${RISH_HOME}/create_hotlist.sh"
source "${RISH_HOME}/scripts/ssh_authentication.sh"
source "${RISH_HOME}/scripts/user_credentials.sh"
source "${RISH_HOME}/scripts/create_user.sh"
source "${RISH_HOME}/scripts/delete_user.sh"

USER_MENU_DEFAULT_INDEX=0
SELECTED_SERVER_USER=""
LAST_USER_MENU_ACTION_X=0
LAST_USER_MENU_RIGHT_X=0
LAST_USER_SELECTED_ROW=0
SERVER_USERS=()
USER_WWW_DIRECTORIES=()
USER_WWW_FILES=()
USER_WWW_LINK_NAMES=()
USER_WWW_LINK_TARGETS=()
USER_WWW_OTHER_OBJECTS=()
USER_WWW_ERROR=""
USER_PHP_VERSIONS=()
USER_PHP_POOL_ERRORS=()

# shellcheck disable=SC2154
get_context_rish_user() {
  local current_directory="$1"
  local selected_name="$2"
  local path
  local user
  local -a paths=()

  if [[ -n "$selected_name" && "$selected_name" != ".." && -d "${current_directory%/}/${selected_name}" ]]; then
    paths+=("${current_directory%/}/${selected_name}")
  fi
  paths+=("$current_directory")

  for path in "${paths[@]}"; do
    case "$path" in
    /var/www/*)
      user="${path#/var/www/}"
      user="${user%%/*}"
      if [[ -n "$user" ]] && get_sftp_users | grep -Fxq "$user"; then
        printf '%s\n' "$user"
        return 0
      fi
      ;;
    esac
  done

  return 1
}

wait_for_user_menu() {
  vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
}

load_user_www_entries() {
  local user="$1"
  local www_dir="/var/www/${user}/www"
  local entry
  local name
  local target

  USER_WWW_DIRECTORIES=()
  USER_WWW_FILES=()
  USER_WWW_LINK_NAMES=()
  USER_WWW_LINK_TARGETS=()
  USER_WWW_OTHER_OBJECTS=()
  USER_WWW_ERROR=""

  if [[ ! -e "$www_dir" && ! -L "$www_dir" ]]; then
    USER_WWW_ERROR="каталог отсутствует: ${www_dir}"
    return 1
  fi
  if [[ ! -d "$www_dir" || -L "$www_dir" ]]; then
    USER_WWW_ERROR="путь имеет неверный тип: ${www_dir}"
    return 1
  fi

  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    if [[ -L "$entry" ]]; then
      target="$(readlink -- "$entry" 2>/dev/null || true)"
      USER_WWW_LINK_NAMES+=("$name")
      USER_WWW_LINK_TARGETS+=("${target:-не удалось прочитать цель}")
    elif [[ -d "$entry" ]]; then
      USER_WWW_DIRECTORIES+=("$name")
    elif [[ -f "$entry" ]]; then
      USER_WWW_FILES+=("$name")
    else
      USER_WWW_OTHER_OBJECTS+=("$name")
    fi
  done < <(find "$www_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z)
}

get_user_info_menu_label() {
  local user="$1"
  local label

  if ! load_user_www_entries "$user"; then
    printf '%s' "Инфо: ошибка каталога www"
    return
  fi

  label="Инфо: каталогов ${#USER_WWW_DIRECTORIES[@]}, файлов ${#USER_WWW_FILES[@]}"
  if ((${#USER_WWW_LINK_NAMES[@]} > 0)); then
    label+=", ссылок ${#USER_WWW_LINK_NAMES[@]}"
  fi
  if ((${#USER_WWW_OTHER_OBJECTS[@]} > 0)); then
    label+=", прочих ${#USER_WWW_OTHER_OBJECTS[@]}"
  fi
  printf '%s' "$label"
}

get_user_database_names() {
  local user="$1"
  local user_sql

  user_sql="${user//\\/\\\\}"
  user_sql="${user_sql//\'/\\\'}"
  mariadb -N -B -e "
    SELECT DISTINCT granted_objects.DATABASE_NAME
    FROM (
      SELECT TABLE_SCHEMA AS DATABASE_NAME
      FROM INFORMATION_SCHEMA.SCHEMA_PRIVILEGES
      WHERE GRANTEE = CONCAT(CHAR(39), '${user_sql}', CHAR(39), '@', CHAR(39), 'localhost', CHAR(39))
      UNION ALL
      SELECT TABLE_SCHEMA AS DATABASE_NAME
      FROM INFORMATION_SCHEMA.TABLE_PRIVILEGES
      WHERE GRANTEE = CONCAT(CHAR(39), '${user_sql}', CHAR(39), '@', CHAR(39), 'localhost', CHAR(39))
      UNION ALL
      SELECT TABLE_SCHEMA AS DATABASE_NAME
      FROM INFORMATION_SCHEMA.COLUMN_PRIVILEGES
      WHERE GRANTEE = CONCAT(CHAR(39), '${user_sql}', CHAR(39), '@', CHAR(39), 'localhost', CHAR(39))
      UNION ALL
      SELECT Db AS DATABASE_NAME
      FROM mysql.procs_priv
      WHERE User = '${user_sql}' AND Host = 'localhost'
    ) AS granted_objects
    INNER JOIN INFORMATION_SCHEMA.SCHEMATA AS existing_schemas
      ON existing_schemas.SCHEMA_NAME = granted_objects.DATABASE_NAME
    ORDER BY granted_objects.DATABASE_NAME;
  " 2>/dev/null
}

load_user_php_pools() {
  local user="$1"
  local pool_file
  local version
  local -a pool_files=()

  USER_PHP_VERSIONS=()
  USER_PHP_POOL_ERRORS=()

  shopt -s nullglob
  pool_files=(/etc/opt/remi/php[0-9][0-9]/php-fpm.d/"${user}.conf")
  shopt -u nullglob

  for pool_file in "${pool_files[@]}"; do
    version="${pool_file#/etc/opt/remi/}"
    version="${version%%/*}"
    if [[ -f "$pool_file" && ! -L "$pool_file" ]]; then
      if [[ -x "/opt/remi/${version}/root/usr/sbin/php-fpm" ]]; then
        USER_PHP_VERSIONS+=("$version")
      else
        USER_PHP_POOL_ERRORS+=("${pool_file}: отсутствует /opt/remi/${version}/root/usr/sbin/php-fpm")
      fi
    elif [[ -e "$pool_file" || -L "$pool_file" ]]; then
      USER_PHP_POOL_ERRORS+=("${pool_file}: объект имеет неожиданный тип")
    fi
  done
}

format_user_info_items() {
  local item

  if (($# == 0)); then
    printf '%s' "нет"
    return
  fi

  printf '%s' "$1"
  shift
  for item in "$@"; do
    printf ', %s' "$item"
  done
}

print_user_table_border() {
  local left="$1"
  local middle="$2"
  local right="$3"
  local type_width="$4"
  local name_width="$5"
  local target_width="$6"
  local show_target_column="$7"

  printf '%s' "$left"
  repl "─" "$((type_width + 2))"
  printf '%s' "$middle"
  repl "─" "$((name_width + 2))"
  if ((show_target_column)); then
    printf '%s' "$middle"
    repl "─" "$((target_width + 2))"
  fi
  printf '%s\n' "$right"
}

print_user_table_header() {
  local type_width="$1"
  local name_width="$2"
  local target_width="$3"
  local show_target_column="$4"
  local type_header="Тип"
  local name_header="Имя"
  local target_header="Назначение"

  printf '│ %s' "$type_header"
  repl " " "$((type_width - ${#type_header} + 1))"
  printf '│ %s' "$name_header"
  repl " " "$((name_width - ${#name_header} + 1))"
  if ((show_target_column)); then
    printf '│ %s' "$target_header"
    repl " " "$((target_width - ${#target_header} + 1))"
  fi
  printf '│\n'
}

print_user_table_row() {
  local type="$1"
  local name="$2"
  local target="$3"
  local type_width="$4"
  local name_width="$5"
  local target_width="$6"
  local show_target_column="$7"
  local name_offset=0
  local target_offset=0
  local first_line=1
  local type_chunk
  local name_chunk
  local target_chunk

  while ((first_line || name_offset < ${#name} || (show_target_column && target_offset < ${#target}))); do
    if ((first_line)); then
      type_chunk="$type"
    else
      type_chunk=""
    fi
    name_chunk="${name:name_offset:name_width}"
    if ((show_target_column)); then
      target_chunk="${target:target_offset:target_width}"
    else
      target_chunk=""
    fi

    printf '│ %s' "$type_chunk"
    repl " " "$((type_width - ${#type_chunk} + 1))"
    printf '│ %b%s%b' "$GREEN" "$name_chunk" "$WHITE"
    repl " " "$((name_width - ${#name_chunk} + 1))"
    if ((show_target_column)); then
      printf '│ %b%s%b' "$GREEN" "$target_chunk" "$WHITE"
      repl " " "$((target_width - ${#target_chunk} + 1))"
    fi
    printf '│\n'

    name_offset=$((name_offset + name_width))
    if ((show_target_column)); then
      target_offset=$((target_offset + target_width))
    fi
    first_line=0
  done
}

print_user_www_table() {
  local item
  local escaped_item
  local escaped_target
  local i
  local type_header="Тип"
  local name_header="Имя"
  local target_header="Назначение"
  local type_width=${#type_header}
  local name_width=${#name_header}
  local target_width=${#target_header}
  local show_target_column=0
  local terminal_size
  local terminal_columns
  local max_table_width
  local available_value_width
  local minimum_name_width=${#name_header}
  local minimum_target_width=${#target_header}
  local natural_name_width
  local natural_target_width
  local -a types=()
  local -a names=()
  local -a targets=()

  for item in "${USER_WWW_DIRECTORIES[@]}"; do
    printf -v escaped_item '%q' "$item"
    types+=("Каталог")
    names+=("$escaped_item")
    targets+=("")
  done
  for item in "${USER_WWW_FILES[@]}"; do
    printf -v escaped_item '%q' "$item"
    types+=("Файл")
    names+=("$escaped_item")
    targets+=("")
  done
  for i in "${!USER_WWW_LINK_NAMES[@]}"; do
    printf -v escaped_item '%q' "${USER_WWW_LINK_NAMES[$i]}"
    printf -v escaped_target '%q' "${USER_WWW_LINK_TARGETS[$i]}"
    types+=("Ссылка")
    names+=("$escaped_item")
    targets+=("$escaped_target")
  done
  if ((${#USER_WWW_LINK_NAMES[@]} > 0)); then
    show_target_column=1
  fi
  for item in "${USER_WWW_OTHER_OBJECTS[@]}"; do
    printf -v escaped_item '%q' "$item"
    types+=("Прочее")
    names+=("$escaped_item")
    targets+=("")
  done

  if ((${#types[@]} == 0)); then
    types+=("Пусто")
    names+=("нет")
    targets+=("")
  fi

  for i in "${!types[@]}"; do
    if ((${#types[$i]} > type_width)); then
      type_width=${#types[$i]}
    fi
    if ((${#names[$i]} > name_width)); then
      name_width=${#names[$i]}
    fi
    if ((${#targets[$i]} > target_width)); then
      target_width=${#targets[$i]}
    fi
  done

  terminal_size="$(stty size 2>/dev/null || true)"
  terminal_columns="${terminal_size##* }"
  if [[ ! "$terminal_columns" =~ ^[0-9]+$ ]] || ((terminal_columns < 24)); then
    terminal_columns=120
  fi
  max_table_width=$((terminal_columns - 1))
  natural_name_width=$name_width
  natural_target_width=$target_width

  if ((show_target_column)); then
    if ((max_table_width < type_width + minimum_name_width + minimum_target_width + 10)); then
      max_table_width=$((type_width + minimum_name_width + minimum_target_width + 10))
    fi
    available_value_width=$((max_table_width - type_width - 10))
    if ((name_width + target_width > available_value_width)); then
      name_width=$((available_value_width / 2))
      target_width=$((available_value_width - name_width))
      if ((name_width < minimum_name_width)); then
        name_width=$minimum_name_width
        target_width=$((available_value_width - name_width))
      fi
      if ((target_width < minimum_target_width)); then
        target_width=$minimum_target_width
        name_width=$((available_value_width - target_width))
      fi
      if ((natural_name_width < name_width)); then
        name_width=$natural_name_width
        target_width=$((available_value_width - name_width))
      elif ((natural_target_width < target_width)); then
        target_width=$natural_target_width
        name_width=$((available_value_width - target_width))
      fi
    fi
  else
    if ((max_table_width < type_width + minimum_name_width + 7)); then
      max_table_width=$((type_width + minimum_name_width + 7))
    fi
    available_value_width=$((max_table_width - type_width - 7))
    if ((name_width > available_value_width)); then
      name_width=$available_value_width
    fi
  fi

  print_user_table_border "┌" "┬" "┐" "$type_width" "$name_width" "$target_width" "$show_target_column"
  print_user_table_header "$type_width" "$name_width" "$target_width" "$show_target_column"
  print_user_table_border "├" "┼" "┤" "$type_width" "$name_width" "$target_width" "$show_target_column"
  for i in "${!types[@]}"; do
    print_user_table_row "${types[$i]}" "${names[$i]}" "${targets[$i]}" "$type_width" "$name_width" "$target_width" "$show_target_column"
  done
  print_user_table_border "└" "┴" "┘" "$type_width" "$name_width" "$target_width" "$show_target_column"
}

show_user_info() {
  local user="$1"
  local i
  local uid
  local home_dir
  local user_root="/var/www/${user}"
  local sites_dir="/var/www/${user}/www"
  local www_status
  local database_output
  local database_status
  local cron_output
  local cron_status
  local cron_task_count=0
  local cron_label
  local cron_color="$GREEN"
  local key_file="${RISH_SFTP_AUTHORIZED_KEYS_DIR}/${user}"
  local key_count=0
  local key_label
  local key_permissions
  local key_directory_permissions
  local key_color="$GREEN"
  local credentials_file
  local credentials_label
  local credentials_color="$GREEN"
  local -a databases=()

  uid="$(id -u "$user" 2>/dev/null || true)"
  home_dir="$(getent passwd "$user" | awk -F: '{ print $6 }')"
  load_user_www_entries "$user"
  www_status=$?

  database_output="$(get_user_database_names "$user")"
  database_status=$?
  if ((database_status == 0)) && [[ -n "$database_output" ]]; then
    mapfile -t databases <<< "$database_output"
  fi

  load_user_php_pools "$user"

  cron_output="$(LC_ALL=C crontab -l -u "$user" 2>&1)"
  cron_status=$?
  if ((cron_status == 0)); then
    cron_task_count="$(printf '%s\n' "$cron_output" | awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }')"
    if ((cron_task_count == 0)); then
      cron_label="заданий нет (crontab пуст)"
    else
      cron_label="настроен, заданий: ${cron_task_count}"
    fi
    cron_color="$GREEN"
  elif grep -Fqi "no crontab for" <<< "$cron_output"; then
    cron_label="заданий нет (crontab не создан)"
    cron_color="$GREEN"
  else
    cron_label="не удалось проверить"
    cron_color="$RED"
  fi

  if [[ -f "$key_file" && ! -L "$key_file" ]]; then
    key_count="$(awk '!/^[[:space:]]*($|#)/ { count++ } END { print count + 0 }' "$key_file" 2>/dev/null)"
    key_permissions="$(stat -c '%U:%G %a' "$key_file" 2>/dev/null || true)"
    key_directory_permissions="$(stat -c '%U:%G %a' "$RISH_SFTP_AUTHORIZED_KEYS_DIR" 2>/dev/null || true)"
    if [[ "$key_permissions" == "root:root 644" && "$key_directory_permissions" == "root:root 755" ]]; then
      key_label="${key_count}"
      key_color="$GREEN"
    else
      key_label="${key_count}; небезопасные права: файл ${key_permissions:-неизвестно}, каталог ${key_directory_permissions:-неизвестно}"
      key_color="$RED"
    fi
  elif [[ -e "$key_file" || -L "$key_file" ]]; then
    key_label="файл имеет небезопасный тип"
    key_color="$RED"
  else
    key_label="файл отсутствует"
    key_color="$YELLOW"
  fi

  credentials_file="$(rish_credentials_file "$user" 2>/dev/null || true)"
  if [[ -n "$credentials_file" ]] && validate_user_credentials "$user"; then
    credentials_label="корректен"
    credentials_color="$GREEN"
  elif [[ -n "$credentials_file" && (-e "$credentials_file" || -L "$credentials_file") ]]; then
    credentials_label="повреждён или имеет небезопасные права"
    credentials_color="$RED"
  else
    credentials_label="отсутствует"
    credentials_color="$YELLOW"
  fi

  clear
  echo -e "Пользователь: ${GREEN}${user}${WHITE}"
  echo -e "UID: ${GREEN}${uid:-неизвестно}${WHITE}"
  echo -e "Домашний каталог: ${GREEN}${home_dir:-неизвестно}${WHITE}"
  echo -e "Каталог данных: ${GREEN}${user_root}${WHITE}"
  echo
  echo -e "Содержимое ${GREEN}${sites_dir}${WHITE}:"
  if ((www_status == 0)); then
    print_user_www_table
  else
    echo -e "${RED}Ошибка:${WHITE} ${USER_WWW_ERROR}"
  fi
  echo
  if ((database_status == 0)); then
    echo -e "Базы MariaDB (${#databases[@]}): ${GREEN}$(format_user_info_items "${databases[@]}")${WHITE}"
  else
    echo -e "Базы MariaDB: ${RED}не удалось проверить${WHITE}"
  fi
  if ((${#USER_PHP_POOL_ERRORS[@]} > 0)); then
    echo -e "Корректные PHP-FPM-пулы: ${GREEN}$(format_user_info_items "${USER_PHP_VERSIONS[@]}")${WHITE}"
    for i in "${!USER_PHP_POOL_ERRORS[@]}"; do
      echo -e "Проблемный PHP-FPM-пул: ${RED}${USER_PHP_POOL_ERRORS[$i]}${WHITE}"
    done
  else
    echo -e "PHP-FPM-пулы: ${GREEN}$(format_user_info_items "${USER_PHP_VERSIONS[@]}")${WHITE}"
  fi
  echo -e "CRON: ${cron_color}${cron_label}${WHITE}"
  echo -e "Публичные ключи SFTP: ${key_color}${key_label}${WHITE}"
  echo -e "Файл учётных данных: ${credentials_color}${credentials_label}${WHITE}"
  wait_for_user_menu
}

select_server_user() {
  local choice
  local max_user_index

  mapfile -t SERVER_USERS < <(get_sftp_users | sort)
  max_user_index=${#SERVER_USERS[@]}
  if ((USER_MENU_DEFAULT_INDEX > max_user_index)); then
    USER_MENU_DEFAULT_INDEX="$max_user_index"
  fi

  vertical_menu "current_noclear" 2 20 30 "default=${USER_MENU_DEFAULT_INDEX}" "Создать пользователя" "${SERVER_USERS[@]}" "Выйти"
  choice=$?
  LAST_USER_MENU_ACTION_X="$(vertical_menu_next_x 2)"
  LAST_USER_MENU_RIGHT_X="$VERTICAL_MENU_LAST_RIGHT_X"
  LAST_USER_SELECTED_ROW=$((VERTICAL_MENU_LAST_Y + VERTICAL_MENU_LAST_VISIBLE_SELECTED + 1))

  if ((choice == 255 || choice == ${#SERVER_USERS[@]} + 1)); then
    return 1
  fi
  if ((choice == 0)); then
    USER_MENU_DEFAULT_INDEX=0
    SELECTED_SERVER_USER=""
    return 2
  fi

  USER_MENU_DEFAULT_INDEX="$choice"
  SELECTED_SERVER_USER="${SERVER_USERS[$((choice - 1))]}"
}

draw_user_action_connector() {
  local from_x="$LAST_USER_MENU_RIGHT_X"
  local to_x="$LAST_USER_MENU_ACTION_X"
  local row="$LAST_USER_SELECTED_ROW"
  local length

  length=$((to_x - from_x))
  if ((length <= 1)); then
    return
  fi

  cursor_to "$row" "$from_x"
  printf "├"
  repl "─" "$((length - 1))"
}

user_actions_menu() {
  local user="$1"
  local info_label
  local choice
  local action_menu_y

  info_label="$(get_user_info_menu_label "$user")"
  while true; do
    action_menu_y=$((LAST_USER_SELECTED_ROW - 1))
    draw_user_action_connector
    vertical_menu "$action_menu_y" "$LAST_USER_MENU_ACTION_X" 0 24 "$info_label" "Удалить пользователя" "Назад"
    choice=$?

    case "$choice" in
      0)
        show_user_info "$user"
        return
        ;;
      1)
        clear
        DeleteUser "$user"
        wait_for_user_menu
        return 3
        ;;
      2 | 255)
        return
        ;;
    esac
  done
}

UserManagementMenu() {
  local current_directory="$1"
  local selected_name="$2"
  local context_user
  local select_result
  local action_result
  local preserve_deletion_output=0
  local i

  context_user="$(get_context_rish_user "$current_directory" "$selected_name" 2>/dev/null || true)"
  if [[ -n "$context_user" ]]; then
    mapfile -t SERVER_USERS < <(get_sftp_users | sort)
    for i in "${!SERVER_USERS[@]}"; do
      if [[ "${SERVER_USERS[$i]}" == "$context_user" ]]; then
        USER_MENU_DEFAULT_INDEX=$((i + 1))
        break
      fi
    done
  fi

  while true; do
    if ((preserve_deletion_output)); then
      echo
      preserve_deletion_output=0
    else
      clear
    fi
    echo "Пользователи сервера:"
    echo

    select_server_user
    select_result=$?
    case "$select_result" in
      1)
        clear
        break
        ;;
      2)
        clear
        CreateUser ""
        wait_for_user_menu
        ;;
      0)
        user_actions_menu "$SELECTED_SERVER_USER"
        action_result=$?
        if ((action_result == 3)); then
          preserve_deletion_output=1
        fi
        ;;
    esac
  done
}

UserManagementMenu "${1:-}" "${2:-}"
