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

wait_for_enter() {
  vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
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
trap 'rm -f "$TMP_DEFAULTS"' EXIT
chmod 600 "$TMP_DEFAULTS"
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

found=0
unwanted_found=0
echo "$TABLE_TOP"
print_row "#" "Type" "Element" "Name" "Version" "Date" "S"
echo "$TABLE_HEADER"
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
    unwanted_found=1
  fi
  found=$((found + 1))
  print_row "$found" "$group" "$element" "$name" "$version" "$date" "$status" "$highlight"
done
echo "$TABLE_BOTTOM"

if ((unwanted_found)); then
  echo
  echo -e "${YELLOW}Жёлтым${WHITE} выделены расширения из списка нежелательных."
fi

if ((found == 0)); then
  echo -e "${GREEN}Нестандартные расширения не найдены.${WHITE}"
else
  echo
  echo -e "Найдено нестандартных расширений: ${YELLOW}${found}${WHITE}"
fi

wait_for_enter
