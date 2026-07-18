#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
WHITE='\033[0m'

RISH_HOME="${RISH_HOME:-/root/rish}"

source "${RISH_HOME}/windows.sh"

SITE_PATH="${1:-}"
SITE_NAME="${2:-}"
JOOMLA_VERSION="${3:-}"
PHP_BIN="${4:-}"
SITE_USER="${5:-}"
CAN_CHECK_UPDATES=0

wait_for_enter() {
  vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
}

wait_for_audit_action() {
  local -a items=("Вернуться")

  if ((CAN_CHECK_UPDATES)); then
    items+=("Проверить обновления расширений")
  fi
  items+=("Отфильтровать по строке")

  vertical_menu "current" 2 0 35 nomouse "${items[@]}"
}

fail() {
  echo -e "$1"
  wait_for_enter
  exit 1
}

php_config_value() {
  local name="$1"
  local config_file="$2"

  sed -nE "s/^[[:space:]]*(public[[:space:]]+)?\\\$${name}[[:space:]]*=[[:space:]]*'([^']*)'.*/\\2/p" "$config_file" |
    head -n 1
}

joomla_major_to_baseline() {
  local version="$1"

  case "${version%%.*}" in
    3) printf '%s' "3.10" ;;
    4) printf '%s' "4.4" ;;
    5) printf '%s' "5.4" ;;
    6) printf '%s' "6.1" ;;
    *) return 1 ;;
  esac
}

client_label() {
  case "$1" in
    0) printf '%s' "site" ;;
    1) printf '%s' "administrator" ;;
    2) printf '%s' "api" ;;
    *) printf '%s' "client-$1" ;;
  esac
}

extension_group() {
  local type="$1"
  local folder="$2"
  local client_id="$3"

  case "$type" in
    plugin)
      printf '%s/%s' "$type" "$folder"
      ;;
    module | template)
      printf '%s/%s' "$type" "$(client_label "$client_id")"
      ;;
    *)
      printf '%s' "$type"
      ;;
  esac
}

truncate_cell() {
  local value="$1"
  local width="$2"

  if ((${#value} > width)); then
    printf '%s' "${value:0:$((width - 3))}..."
  else
    printf '%s' "$value"
  fi
}

TABLE_TOP="┌─────┬──────────────────┬──────────────────────────────┬──────────────────────────────┬────────────┬─────────────────────┬───┐"
TABLE_HEADER="├─────┼──────────────────┼──────────────────────────────┼──────────────────────────────┼────────────┼─────────────────────┼───┤"
TABLE_BOTTOM="└─────┴──────────────────┴──────────────────────────────┴──────────────────────────────┴────────────┴─────────────────────┴───┘"

print_row() {
  local number="$1"
  local type="$2"
  local element="$3"
  local name="$4"
  local version="$5"
  local date="$6"
  local status="$7"
  local highlight="${8:-0}"

  number="$(truncate_cell "$number" 3)"
  type="$(truncate_cell "$type" 16)"
  element="$(truncate_cell "$element" 28)"
  name="$(truncate_cell "$name" 28)"
  version="$(truncate_cell "$version" 10)"
  date="$(truncate_cell "$date" 19)"

  printf '│ %3s │ ' "$number"
  print_text_cell "$type" 16 "$highlight"
  printf ' │ '
  print_text_cell "$element" 28 "$highlight"
  printf ' │ '
  print_text_cell "$name" 28 "$highlight"
  printf ' │ '
  print_text_cell "$version" 10 0
  printf ' │ '
  print_text_cell "$date" 19 0
  printf ' │ %b │\n' "$status"
}

print_audit_rows() {
  local filter="${1:-}"
  local filter_lower="${filter,,}"
  local row
  local group
  local element
  local name
  local version
  local date
  local status
  local highlight
  local searchable

  display_found=0
  display_unwanted_found=0

  echo "$TABLE_TOP"
  print_row "#" "Type" "Element" "Name" "Version" "Date" "S"
  echo "$TABLE_HEADER"
  for row in "${AUDIT_ROWS[@]}"; do
    IFS=$'\037' read -r group element name version date status highlight searchable <<< "$row"
    if [[ -n "$filter_lower" && "${searchable,,}" != *"$filter_lower"* ]]; then
      continue
    fi
    display_found=$((display_found + 1))
    ((highlight)) && display_unwanted_found=1
    print_row "$display_found" "$group" "$element" "$name" "$version" "$date" "$status" "$highlight"
  done
  echo "$TABLE_BOTTOM"
}

print_audit_footer() {
  local filter="${1:-}"

  if ((display_unwanted_found)); then
    echo
    echo -e "${YELLOW}Жёлтым${WHITE} выделены расширения из списка нежелательных."
  fi

  if ((display_found == 0)); then
    if [[ -n "$filter" ]]; then
      echo -e "Совпадений по строке ${YELLOW}${filter}${WHITE} не найдено."
    else
      echo -e "${GREEN}Нестандартные расширения не найдены.${WHITE}"
    fi
  elif [[ -n "$filter" ]]; then
    echo
    echo -e "Найдено совпадений: ${YELLOW}${display_found}${WHITE}"
  else
    echo
    echo -e "Найдено нестандартных расширений: ${YELLOW}${display_found}${WHITE}"
  fi
}

filter_audit_rows() {
  local pattern

  echo -e "Введите строку для фильтра расширений (пустая строка для выхода): ${GREEN}"
  read -r -e pattern
  echo -e -n "${WHITE}"
  if [[ -z "$pattern" ]]; then
    echo "Фильтр отменен."
    return
  fi

  echo
  echo -e "Фильтр расширений по строке: ${GREEN}${pattern}${WHITE}"
  echo
  print_audit_rows "$pattern"
  print_audit_footer "$pattern"
}

UPDATE_TABLE_TOP="┌─────┬──────────────────┬──────────────────────────────┬──────────────────────────────┬────────────┬────────────┐"
UPDATE_TABLE_HEADER="├─────┼──────────────────┼──────────────────────────────┼──────────────────────────────┼────────────┼────────────┤"
UPDATE_TABLE_BOTTOM="└─────┴──────────────────┴──────────────────────────────┴──────────────────────────────┴────────────┴────────────┘"

print_update_row() {
  local number="$1"
  local type="$2"
  local element="$3"
  local name="$4"
  local installed="$5"
  local available="$6"

  number="$(truncate_cell "$number" 3)"
  type="$(truncate_cell "$type" 16)"
  element="$(truncate_cell "$element" 28)"
  name="$(truncate_cell "$name" 28)"
  installed="$(truncate_cell "$installed" 10)"
  available="$(truncate_cell "$available" 10)"

  printf '│ %3s │ ' "$number"
  print_text_cell "$type" 16 0
  printf ' │ '
  print_text_cell "$element" 28 0
  printf ' │ '
  print_text_cell "$name" 28 0
  printf ' │ '
  print_text_cell "$installed" 10 0
  printf ' │ '
  print_text_cell "$available" 10 0
  printf ' │\n'
}

show_extension_updates() {
  local cli_output
  local cli_pid=""
  local cli_running=1
  local cli_status
  local can_track_progress=1
  local check_interrupted=0
  local check_started_at
  local completed_sites=0
  local current_second
  local elapsed=0
  local lock_file
  local lock_key
  local progress_output
  local progress_row
  local reported_count
  local site_id
  local site_name
  local tracking_error=""
  local tracking_warning_shown=0
  local query_output
  local row
  local key
  local type
  local folder
  local element
  local client_id
  local name
  local manifest_cache
  local available
  local installed
  local group
  local found=0
  local updates_table
  local update_sites_table
  local update_query
  local update_lock_fd
  local total_sites=0
  local -A reported_sites=()
  local -a progress_rows=()
  local -a update_rows=()

  echo
  echo "Проверка обновлений расширений Joomla"
  echo
  echo -e "Сайт: ${GREEN}${SITE_NAME:-${SITE_PATH}}${WHITE}"
  echo -e "Joomla: ${GREEN}${JOOMLA_VERSION}${WHITE}"
  echo "Проверяем серверы обновлений..."
  echo

  if ! command -v flock > /dev/null 2>&1; then
    echo -e "Не удалось запустить проверку: команда ${RED}flock не найдена${WHITE}."
    wait_for_enter
    return
  fi

  lock_key="$(printf '%s' "$SITE_PATH" | sha256sum)"
  lock_key="${lock_key%% *}"
  lock_file="/run/lock/rish-joomla-update-${lock_key}.lock"
  if ! exec {update_lock_fd}> "$lock_file"; then
    echo -e "Не удалось ${RED}создать блокировку${WHITE} проверки обновлений."
    wait_for_enter
    return
  fi
  chmod 600 "$lock_file"
  if ! flock -n "$update_lock_fd"; then
    echo -e "Для этого сайта уже выполняется ${YELLOW}проверка обновлений${WHITE}."
    exec {update_lock_fd}>&-
    wait_for_enter
    return
  fi

  update_sites_table="$(sql_escape_identifier "${DB_PREFIX}update_sites")"
  if ! total_sites=$(
    mariadb --defaults-extra-file="$TMP_DEFAULTS" --batch --raw --skip-column-names \
      "$DB_NAME" -e "SELECT COUNT(*) FROM \`${update_sites_table}\` WHERE enabled = 1;" 2>&1
  ); then
    tracking_error="$total_sites"
    can_track_progress=0
    total_sites=0
  fi
  if [[ ! "$total_sites" =~ ^[0-9]+$ ]]; then
    if [[ -z "$tracking_error" ]]; then
      tracking_error="MariaDB вернула некорректное количество серверов обновлений: ${total_sites}"
    fi
    can_track_progress=0
    total_sites=0
  fi

  : > "$CLI_OUTPUT_FILE"
  current_second="$(date +%s)"
  check_started_at=$((current_second + 1))
  while (($(date +%s) < check_started_at)); do
    sleep 0.05
  done
  trap 'check_interrupted=129; [[ -z "$cli_pid" ]] || kill -TERM "$cli_pid" 2>/dev/null' HUP
  trap 'check_interrupted=130; [[ -z "$cli_pid" ]] || kill -TERM "$cli_pid" 2>/dev/null' INT
  trap 'check_interrupted=131; [[ -z "$cli_pid" ]] || kill -TERM "$cli_pid" 2>/dev/null' QUIT
  trap 'check_interrupted=143; [[ -z "$cli_pid" ]] || kill -TERM "$cli_pid" 2>/dev/null' TERM
  (
    cd "$SITE_PATH" || exit 1
    exec timeout --kill-after=5s 120s runuser -u "$SITE_USER" -- \
      "$PHP_BIN" cli/joomla.php update:extensions:check
  ) > "$CLI_OUTPUT_FILE" 2>&1 &
  cli_pid=$!
  if ((check_interrupted)); then
    kill -TERM "$cli_pid" 2>/dev/null
  fi

  while true; do
    ((check_interrupted)) && break
    if kill -0 "$cli_pid" 2>/dev/null; then
      cli_running=1
    else
      cli_running=0
    fi

    if ((can_track_progress)); then
      if ! progress_output=$(
        mariadb --defaults-extra-file="$TMP_DEFAULTS" --batch --raw --skip-column-names \
          "$DB_NAME" -e "
SELECT CONCAT(
  update_site_id,
  CHAR(31),
  COALESCE(name, '-')
)
FROM \`${update_sites_table}\`
WHERE enabled = 1
  AND last_check_timestamp >= ${check_started_at}
ORDER BY last_check_timestamp, update_site_id;
" 2>&1
      ); then
        tracking_error="$progress_output"
        can_track_progress=0
      else
        progress_rows=()
        if [[ -n "$progress_output" ]]; then
          mapfile -t progress_rows <<< "$progress_output"
        fi
        completed_sites="${#progress_rows[@]}"

        for progress_row in "${progress_rows[@]}"; do
          IFS=$'\037' read -r site_id site_name <<< "$progress_row"
          if [[ ! "$site_id" =~ ^[0-9]+$ ]]; then
            tracking_error="MariaDB вернула некорректный update_site_id: ${site_id}"
            can_track_progress=0
            break
          fi
          if [[ -n "${reported_sites[$site_id]+x}" ]]; then
            continue
          fi

          site_name="$(printf '%s' "$site_name" | LC_ALL=C tr -d '\000-\037\177')"
          [[ -n "$site_name" ]] || site_name="-"
          site_name="$(truncate_cell "$site_name" 60)"
          reported_sites["$site_id"]=1
          reported_count="${#reported_sites[@]}"
          printf '\033[2K\r[%s/%s] Обработан: %s\n' \
            "$reported_count" "$total_sites" "$site_name"
        done
      fi
    fi

    if ((!can_track_progress && !tracking_warning_shown)); then
      tracking_error="${tracking_error//$'\n'/ }"
      tracking_error="${tracking_error//$'\r'/ }"
      tracking_error="${tracking_error//$'\t'/ }"
      tracking_error="$(printf '%s' "$tracking_error" | LC_ALL=C tr -d '\000-\037\177')"
      tracking_error="$(truncate_cell "$tracking_error" 140)"
      printf '\033[2K\r'
      echo -e "${YELLOW}Названия серверов обновлений недоступны; проверка продолжается без них.${WHITE}"
      if [[ -n "$tracking_error" ]]; then
        echo "MariaDB: ${tracking_error}"
      fi
      echo
      tracking_warning_shown=1
    fi
    elapsed=$(($(date +%s) - check_started_at))

    ((cli_running)) || break

    if ((can_track_progress)); then
      printf '\033[2K\rОбработано серверов: %s из %s | %s сек.' \
        "$completed_sites" "$total_sites" "$elapsed"
    else
      printf '\033[2K\rПроверка выполняется | %s сек.' "$elapsed"
    fi
    sleep 1
  done

  wait "$cli_pid"
  cli_status=$?
  if ((check_interrupted)); then
    while kill -0 "$cli_pid" 2>/dev/null; do
      wait "$cli_pid" 2>/dev/null
    done
  fi
  trap - HUP INT QUIT TERM
  exec {update_lock_fd}>&-
  cli_output="$(< "$CLI_OUTPUT_FILE")"
  elapsed=$(($(date +%s) - check_started_at))
  printf '\033[2K\r'

  if ((check_interrupted == 129 || check_interrupted == 131 || check_interrupted == 143)); then
    exit "$check_interrupted"
  elif ((check_interrupted)); then
    echo -e "Проверка обновлений ${YELLOW}прервана${WHITE}."
    wait_for_enter
    return
  elif ((cli_status == 0 && can_track_progress)); then
    echo "Обработано серверов: ${total_sites} из ${total_sites} | ${elapsed} сек."
    echo
  elif ((cli_status == 0)); then
    echo "Проверка серверов завершена | ${elapsed} сек."
    echo
  fi

  if ((cli_status != 0)); then
    if ((cli_status == 124 || cli_status == 137)); then
      echo -e "Проверка обновлений ${RED}превысила лимит 120 секунд и была остановлена${WHITE}."
    else
      echo -e "Не удалось ${RED}проверить обновления расширений Joomla${WHITE}."
    fi
    if [[ -n "$cli_output" ]]; then
      echo
      printf '%s\n' "$cli_output"
    fi
    wait_for_enter
    return
  fi

  updates_table="$(sql_escape_identifier "${DB_PREFIX}updates")"
  update_query="
SELECT
  CONCAT(
    CONCAT(e.type, '|', e.folder, '|', e.element, '|', e.client_id),
    CHAR(31), e.type,
    CHAR(31), e.folder,
    CHAR(31), e.element,
    CHAR(31), e.client_id,
    CHAR(31), e.name,
    CHAR(31), e.manifest_cache,
    CHAR(31), u.version
  ) AS row_data
FROM \`${updates_table}\` AS u
INNER JOIN \`${EXTENSIONS_TABLE}\` AS e ON e.extension_id = u.extension_id
INNER JOIN \`${update_sites_table}\` AS us
  ON us.update_site_id = u.update_site_id AND us.enabled = 1
WHERE e.type <> 'language'
  AND NOT (e.type = 'package' AND e.element REGEXP '^pkg_[a-z]{2,3}-[A-Z]{2}$')
ORDER BY e.type, e.folder, e.element, e.client_id;
"

  if ! query_output=$(
    mariadb --defaults-extra-file="$TMP_DEFAULTS" --batch --raw --skip-column-names \
      "$DB_NAME" -e "$update_query" 2>&1
  ); then
    echo -e "Проверка Joomla завершена, но ${RED}не удалось прочитать найденные обновления${WHITE}."
    if [[ -n "$query_output" ]]; then
      echo
      printf '%s\n' "$query_output"
    fi
    wait_for_enter
    return
  fi

  if [[ -n "$query_output" ]]; then
    mapfile -t update_rows <<< "$query_output"
  fi

  echo -e "Проверка обновлений ${GREEN}завершена${WHITE}."
  echo
  echo "Доступные обновления нестандартных расширений"
  echo
  echo "$UPDATE_TABLE_TOP"
  print_update_row "#" "Type" "Element" "Name" "Installed" "Available"
  echo "$UPDATE_TABLE_HEADER"

  for row in "${update_rows[@]}"; do
    IFS=$'\037' read -r key type folder element client_id name manifest_cache available <<< "$row"
    [[ -n "$key" ]] || continue
    if [[ -n "${CORE_EXTENSIONS[$key]:-}" ]]; then
      continue
    fi

    found=$((found + 1))
    group="$(extension_group "$type" "$folder" "$client_id")"
    installed="$(manifest_field "$manifest_cache" "version")"
    [[ -n "$available" ]] || available="-"
    print_update_row "$found" "$group" "$element" "$name" "$installed" "$available"
  done

  echo "$UPDATE_TABLE_BOTTOM"
  echo
  if ((found == 0)); then
    echo -e "${GREEN}Joomla не обнаружила доступных обновлений нестандартных расширений.${WHITE}"
  else
    echo -e "Найдено доступных обновлений: ${YELLOW}${found}${WHITE}"
  fi
}

audit_action_menu() {
  local choice

  while true; do
    wait_for_audit_action
    choice=$?
    case "$choice" in
      0 | 255)
        return
        ;;
    esac

    if ((CAN_CHECK_UPDATES)); then
      case "$choice" in
        1) show_extension_updates ;;
        2) filter_audit_rows ;;
      esac
    elif ((choice == 1)); then
      filter_audit_rows
    fi
  done
}

print_text_cell() {
  local value="$1"
  local width="$2"
  local highlight="$3"
  local padding=$((width - ${#value}))

  if ((highlight)); then
    printf '%b%s%b' "$YELLOW" "$value" "$WHITE"
  else
    printf '%s' "$value"
  fi
  if ((padding > 0)); then
    printf '%*s' "$padding" ''
  fi
}

manifest_field() {
  local manifest="$1"
  local field="$2"
  local value

  value="$(
    jq -r --arg field "$field" 'if type == "object" then (.[$field] // "-") else "-" end' <<< "$manifest" 2>/dev/null
  )"
  if [[ -z "$value" || "$value" == "null" ]]; then
    printf '%s' "-"
  else
    printf '%s' "$value"
  fi
}

sql_escape_identifier() {
  local value="$1"

  value="${value//\`/\`\`}"
  printf '%s' "$value"
}

[[ -n "$SITE_PATH" ]] || fail "${RED}Не указан путь к Joomla.${WHITE}"
[[ -d "$SITE_PATH" ]] || fail "Папка Joomla не найдена: ${RED}${SITE_PATH}${WHITE}"

CONFIG_FILE="${SITE_PATH}/configuration.php"
VERSION_FILE="${SITE_PATH}/administrator/manifests/files/joomla.xml"
[[ -f "$CONFIG_FILE" ]] || fail "Файл Joomla configuration.php не найден: ${RED}${CONFIG_FILE}${WHITE}"
[[ -f "$VERSION_FILE" ]] || fail "Файл версии Joomla не найден: ${RED}${VERSION_FILE}${WHITE}"

if [[ -z "$JOOMLA_VERSION" ]]; then
  JOOMLA_VERSION=$(
    sed -nE 's@.*<version>[[:space:]]*([0-9]+(\.[0-9]+)+)[[:space:]]*</version>.*@\1@p' "$VERSION_FILE" |
      head -n 1
  )
fi
[[ -n "$JOOMLA_VERSION" ]] || fail "${RED}Не удалось определить версию Joomla.${WHITE}"

if [[ "${JOOMLA_VERSION%%.*}" =~ ^[0-9]+$ ]] &&
  ((10#${JOOMLA_VERSION%%.*} >= 4)) &&
  [[ -x "$PHP_BIN" ]] &&
  [[ -n "$SITE_USER" ]] &&
  id -u "$SITE_USER" > /dev/null 2>&1 &&
  [[ -f "${SITE_PATH}/cli/joomla.php" ]]; then
  CAN_CHECK_UPDATES=1
fi

BASELINE_VERSION="$(joomla_major_to_baseline "$JOOMLA_VERSION")" ||
  fail "Для Joomla ${RED}${JOOMLA_VERSION}${WHITE} нет baseline расширений."
BASELINE_FILE="${RISH_HOME}/templates/extensions-joomla-${BASELINE_VERSION}.json"
UNWANTED_FILE="${RISH_HOME}/templates/extensions-joomla-unwanted.json"
[[ -f "$BASELINE_FILE" ]] || fail "Baseline не найден: ${RED}${BASELINE_FILE}${WHITE}"

command -v jq >/dev/null 2>&1 || fail "${RED}jq не найден.${WHITE} Невозможно прочитать baseline JSON."
command -v mariadb >/dev/null 2>&1 || fail "${RED}mariadb не найден.${WHITE} Невозможно прочитать список расширений."

DB_NAME="$(php_config_value "db" "$CONFIG_FILE")"
DB_USER="$(php_config_value "user" "$CONFIG_FILE")"
DB_PASS="$(php_config_value "password" "$CONFIG_FILE")"
DB_HOST="$(php_config_value "host" "$CONFIG_FILE")"
DB_PREFIX="$(php_config_value "dbprefix" "$CONFIG_FILE")"

[[ -n "$DB_NAME" ]] || fail "${RED}Не удалось прочитать имя базы данных из configuration.php.${WHITE}"
[[ -n "$DB_USER" ]] || fail "${RED}Не удалось прочитать пользователя базы данных из configuration.php.${WHITE}"
[[ -n "$DB_HOST" ]] || DB_HOST="localhost"
[[ "$DB_PREFIX" =~ ^[A-Za-z0-9_]+$ ]] || fail "Некорректный dbprefix Joomla: ${RED}${DB_PREFIX}${WHITE}"

declare -A CORE_EXTENSIONS=()
while IFS= read -r key; do
  [[ -n "$key" ]] && CORE_EXTENSIONS["$key"]=1
done < <(jq -r '.extensions[].key' "$BASELINE_FILE")

UNWANTED_RULES=()
if [[ -f "$UNWANTED_FILE" ]]; then
  while IFS=$'\t' read -r match value; do
    [[ -n "$match" && -n "$value" ]] && UNWANTED_RULES+=("${match}"$'\t'"${value}")
  done < <(jq -r '.extensions[] | [.match, .value] | @tsv' "$UNWANTED_FILE")
fi

is_unwanted_extension() {
  local element="$1"
  local name="$2"
  local rule
  local match
  local value
  local element_lower="${element,,}"
  local name_lower="${name,,}"

  for rule in "${UNWANTED_RULES[@]}"; do
    IFS=$'\t' read -r match value <<< "$rule"
    case "$match" in
      element)
        [[ "$element" == "$value" ]] && return 0
        ;;
      element_contains)
        [[ "$element_lower" == *"${value,,}"* ]] && return 0
        ;;
      name)
        [[ "$name" == "$value" ]] && return 0
        ;;
      name_contains)
        [[ "$name_lower" == *"${value,,}"* ]] && return 0
        ;;
    esac
  done

  return 1
}

TMP_DEFAULTS="$(mktemp /tmp/rish-joomla-audit.XXXXXX)" ||
  fail "${RED}Не удалось создать временный файл для подключения к БД.${WHITE}"
CLI_OUTPUT_FILE="$(mktemp /tmp/rish-joomla-update.XXXXXX)" || {
  rm -f "$TMP_DEFAULTS"
  fail "${RED}Не удалось создать временный файл для вывода проверки обновлений.${WHITE}"
}
trap 'rm -f "$TMP_DEFAULTS" "$CLI_OUTPUT_FILE"' EXIT
chmod 600 "$TMP_DEFAULTS" "$CLI_OUTPUT_FILE"
{
  echo "[client]"
  echo "user=${DB_USER}"
  echo "password=${DB_PASS}"
  echo "host=${DB_HOST}"
} > "$TMP_DEFAULTS"

EXTENSIONS_TABLE="$(sql_escape_identifier "${DB_PREFIX}extensions")"
QUERY="
SELECT
  CONCAT(
    CONCAT(type, '|', folder, '|', element, '|', client_id),
    CHAR(31), type,
    CHAR(31), folder,
    CHAR(31), element,
    CHAR(31), client_id,
    CHAR(31), name,
    CHAR(31), enabled,
    CHAR(31), manifest_cache
  ) AS row_data
FROM \`${EXTENSIONS_TABLE}\`
WHERE type <> 'language'
  AND NOT (type = 'package' AND element REGEXP '^pkg_[a-z]{2,3}-[A-Z]{2}$')
ORDER BY type, folder, element, client_id;
"

mapfile -t EXTENSION_ROWS < <(
  mariadb --defaults-extra-file="$TMP_DEFAULTS" --batch --raw --skip-column-names "$DB_NAME" -e "$QUERY" 2>/dev/null
)
if ((${#EXTENSION_ROWS[@]} == 0)); then
  fail "${RED}Не удалось получить список расширений Joomla из базы данных.${WHITE}"
fi

echo "Список расширений, не входящих в стандартную поставку Joomla"
echo
echo -e "Сайт: ${GREEN}${SITE_NAME:-${SITE_PATH}}${WHITE}"
echo -e "Joomla: ${GREEN}${JOOMLA_VERSION}${WHITE}"
echo -e "Эталон для проверки: ${GREEN}Joomla ${BASELINE_VERSION}${WHITE} ($(basename "$BASELINE_FILE"))"
echo -e "Status: ${GREEN}✓${WHITE} enabled, ${RED}×${WHITE} disabled"
echo

AUDIT_ROWS=()
for row in "${EXTENSION_ROWS[@]}"; do
  IFS=$'\037' read -r key type folder element client_id name enabled manifest_cache <<< "$row"
  [[ -n "$key" ]] || continue
  [[ "$type" == "language" ]] && continue
  [[ "$type" == "package" && "$element" =~ ^pkg_[a-z]{2,3}-[A-Z]{2}$ ]] && continue
  if [[ -n "${CORE_EXTENSIONS[$key]:-}" ]]; then
    continue
  fi

  group="$(extension_group "$type" "$folder" "$client_id")"
  status="${RED}×${WHITE}"
  [[ "$enabled" == "1" ]] && status="${GREEN}✓${WHITE}"
  version="$(manifest_field "$manifest_cache" "version")"
  date="$(manifest_field "$manifest_cache" "creationDate")"
  highlight=0
  if is_unwanted_extension "$element" "$name"; then
    highlight=1
  fi
  searchable="${group} ${element} ${name} ${version} ${date}"
  AUDIT_ROWS+=("${group}"$'\037'"${element}"$'\037'"${name}"$'\037'"${version}"$'\037'"${date}"$'\037'"${status}"$'\037'"${highlight}"$'\037'"${searchable}")
done

print_audit_rows
print_audit_footer

audit_action_menu
