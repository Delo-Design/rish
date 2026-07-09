#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
WHITE='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RISH_HOME="${RISH_HOME:-/root/rish}"
DNS_RUNTIME_DIR="${DNS_RUNTIME_DIR:-/root/rish/dns}"
DNS_PROVIDER_ERROR=""
DNS_RECORD_CACHE_LOADED=0
DNS_RECORD_MENU_LIMIT=248
DNS_RECORD_MENU_TOTAL_ROWS=0
DNS_RECORD_MENU_TRUNCATED=0
DNS_MENU_DEFAULT_INDEX=0
LAST_DNS_MENU_Y=0
LAST_DNS_MENU_ACTION_X=0
LAST_DNS_MENU_RIGHT_X=0
LAST_DNS_SELECTED_ROW=0

if [[ -f "${RISH_HOME}/windows.sh" ]]; then
  source "${RISH_HOME}/windows.sh"
else
  source "${SCRIPT_DIR}/../../windows.sh"
fi

source "${SCRIPT_DIR}/zonefile.sh"

rish_read_input() {
  local result_var="$1"
  local prompt="$2"
  local default_value="${3-}"
  local input_value
  local readline_prompt

  readline_prompt=$'\001\033[0m\002'"${prompt}"$'\001\033[0;32m\002'
  if (($# >= 3)); then
    read -r -e -p "$readline_prompt" -i "$default_value" input_value
  else
    read -r -e -p "$readline_prompt" input_value
  fi
  echo -en "${WHITE}"
  printf -v "$result_var" '%s' "$input_value"
}

rish_read_visible_secret() {
  local result_var="$1"
  local prompt="$2"
  local input_value
  local readline_prompt

  readline_prompt=$'\001\033[0m\002'"${prompt}"$'\001\033[0;32m\002'
  read -r -e -p "$readline_prompt" input_value
  printf '\033[1A\033[2K'
  echo -en "${WHITE}"
  printf -v "$result_var" '%s' "$input_value"
}

wait_for_enter() {
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}

dns_menu_available_height() {
  local used_rows="${1:-3}"
  local fallback_height=22
  local size
  local lines
  local height

  size="$(stty size 2>/dev/null)" || {
    printf '%s' "$fallback_height"
    return
  }
  lines="${size% *}"
  [[ "$lines" =~ ^[0-9]+$ ]] || {
    printf '%s' "$fallback_height"
    return
  }

  height=$((lines - used_rows - 2))
  if ((height < 1)); then
    height=1
  fi
  printf '%s' "$height"
}

fail() {
  echo -e "$1" >&2
  wait_for_enter
  exit 1
}

show_dns_status() {
  local message="$1"

  clear
  echo -e "DNS: ${GREEN}${DNS_DOMAIN}${WHITE}"
  echo -e "Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}"
  echo
  echo -e "$message"
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Команда ${command_name} не найдена."
  fi
}

validate_domain() {
  local domain="$1"

  [[ "$domain" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]
}

site_is_created() {
  local directory="$1"
  local domain="$2"
  local site_path="${directory%/}/${domain}"

  [[ "$directory" =~ ^/var/www/[^/]+/www$ ]] || return 1
  validate_domain "$domain" || return 1
  [[ -d "$site_path" ]] || return 1
  [[ -f "/etc/httpd/conf.d/${domain}.conf" ]]
}

dns_fqdn() {
  local name="$1"

  name="${name%.}"
  printf '%s.' "$name"
}

dns_record_type_allowed() {
  case "$1" in
    A | AAAA | CNAME | MX | TXT | NS | CAA)
      return 0
      ;;
  esac

  return 1
}

server_ipv4() {
  command -v ip >/dev/null 2>&1 || return 1

  ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

ipv4_is_private() {
  local ip="$1"
  local first
  local second

  IFS=. read -r first second _ _ <<< "$ip"
  case "$first" in
    0 | 10 | 127)
      return 0
      ;;
    100)
      [[ "$second" =~ ^[0-9]+$ && "$second" -ge 64 && "$second" -le 127 ]] && return 0
      ;;
    169)
      [[ "$second" == "254" ]] && return 0
      ;;
    172)
      [[ "$second" =~ ^[0-9]+$ && "$second" -ge 16 && "$second" -le 31 ]] && return 0
      ;;
    192)
      [[ "$second" == "168" ]] && return 0
      ;;
  esac

  return 1
}

dns_config_dir() {
  local domain="$1"

  printf '%s/domains/%s' "$DNS_RUNTIME_DIR" "$domain"
}

dns_config_file() {
  local domain="$1"

  printf '%s/config.sh' "$(dns_config_dir "$domain")"
}

dns_provider_config_file() {
  local domain="$1"
  local provider="$2"

  printf '%s/%s.sh' "$(dns_config_dir "$domain")" "$provider"
}

shell_quote() {
  local value="$1"

  printf '%q' "$value"
}

save_domain_config() {
  local domain="$1"
  local config_dir
  local config_file

  config_dir="$(dns_config_dir "$domain")"
  config_file="$(dns_config_file "$domain")"
  mkdir -p "$config_dir" || return 1
  {
    echo "# RISH DNS runtime config. Secrets are stored locally on this server."
    echo "DNS_PROVIDER=$(shell_quote "$DNS_PROVIDER")"
    echo "DNS_DOMAIN=$(shell_quote "$DNS_DOMAIN")"
    echo "DNS_ZONE_NAME=$(shell_quote "$DNS_ZONE_NAME")"
    echo "DNS_ZONE_ID=$(shell_quote "$DNS_ZONE_ID")"
    echo "DNS_DEFAULT_TTL=$(shell_quote "${DNS_DEFAULT_TTL:-3600}")"
    echo
    provider_write_config
  } > "$config_file"
  chmod 600 "$config_file" 2>/dev/null || true
  archive_active_domain_config "$domain"
}

load_domain_config() {
  local domain="$1"
  local config_file

  config_file="$(dns_config_file "$domain")"
  [[ -f "$config_file" ]] || return 1
  source "$config_file"
  DNS_DOMAIN="${DNS_DOMAIN:-$domain}"
  DNS_DEFAULT_TTL="${DNS_DEFAULT_TTL:-3600}"
}

archive_active_domain_config() {
  local domain="$1"
  local config_file
  local provider_config_file

  config_file="$(dns_config_file "$domain")"
  [[ -f "$config_file" && -n "${DNS_PROVIDER:-}" ]] || return 0
  provider_config_file="$(dns_provider_config_file "$domain" "$DNS_PROVIDER")"
  mkdir -p "$(dns_config_dir "$domain")" || return 1
  cp "$config_file" "$provider_config_file" || return 1
  chmod 600 "$provider_config_file" 2>/dev/null || true
}

activate_saved_provider_config() {
  local domain="$1"
  local provider="$2"
  local config_file
  local provider_config_file

  config_file="$(dns_config_file "$domain")"
  provider_config_file="$(dns_provider_config_file "$domain" "$provider")"
  [[ -f "$provider_config_file" ]] || return 1
  mkdir -p "$(dns_config_dir "$domain")" || return 1
  cp "$provider_config_file" "$config_file" || return 1
  chmod 600 "$config_file" 2>/dev/null || true
}

load_provider() {
  local provider="$1"
  local provider_file="${SCRIPT_DIR}/providers/${provider}.sh"

  if [[ ! -f "$provider_file" ]]; then
    fail "Provider ${provider} не найден."
  fi
  source "$provider_file"
}

restore_active_domain_config() {
  local domain="$1"

  load_domain_config "$domain" || return 1
  load_provider "$DNS_PROVIDER"
}

normalize_record_name() {
  local input="$1"
  local domain="$2"

  input="${input:-@}"
  if [[ "$input" == "@" ]]; then
    dns_fqdn "$domain"
  elif [[ "$input" == *"." ]]; then
    printf '%s' "$input"
  else
    dns_fqdn "${input}.${domain}"
  fi
}

record_value_label() {
  local value="$1"

  if ((${#value} > 72)); then
    printf '%s...' "${value:0:69}"
  else
    printf '%s' "$value"
  fi
}

record_menu_row_label() {
  local type="$1"
  local name="$2"
  local value="$3"

  if ((${#name} > DNS_RECORD_NAME_WIDTH)); then
    name="${name:0:$((DNS_RECORD_NAME_WIDTH - 3))}..."
  fi
  printf "%-${DNS_RECORD_TYPE_WIDTH}s │ %-${DNS_RECORD_NAME_WIDTH}s │ %s" "$type" "$name" "$(record_value_label "$value")"
}

has_cname_conflict() {
  local name="$1"
  local type="$2"
  local mode="${3:-create}"
  local i
  local existing_type
  local existing_name

  load_records_cache || return 2

  for i in "${!DNS_RECORD_TYPES[@]}"; do
    existing_type="${DNS_RECORD_TYPES[$i]}"
    existing_name="${DNS_RECORD_NAMES[$i]}"
    [[ "$existing_name" == "$name" ]] || continue
    if [[ "$mode" == "update" && "$existing_type" == "$type" ]]; then
      continue
    fi
    if [[ "$type" == "CNAME" || "$existing_type" == "CNAME" ]]; then
      return 0
    fi
  done

  return 1
}

provider_prepare() {
  if ! provider_auth; then
    return 1
  fi
  if ! provider_zone_ready; then
    provider_find_zone "$DNS_DOMAIN" >/dev/null || return 1
  fi
}

show_connect_provider_menu() {
  local domain="$1"
  local choice

  clear
  echo -e "DNS для домена ${GREEN}${domain}${WHITE}"
  echo "Provider еще не подключен."
  echo
  vertical_menu "current" 2 0 20 "Подключить Selectel" "Подключить ClouDNS" "Выйти"
  choice=$?
  case "$choice" in
    0)
      connect_provider "$domain" "selectel"
      ;;
    1)
      connect_provider "$domain" "cloudns"
      ;;
    *)
      exit 0
      ;;
  esac
}

connect_provider() {
  local domain="$1"
  local provider="$2"
  local zone_info

  clear
  DNS_PROVIDER="$provider"
  DNS_DOMAIN="$domain"
  DNS_ZONE_ID=""
  DNS_ZONE_NAME=""
  DNS_DEFAULT_TTL="3600"

  load_provider "$DNS_PROVIDER"
  echo -e "Подключение DNS-провайдера ${GREEN}${DNS_PROVIDER}${WHITE} для ${GREEN}${domain}${WHITE}"
  echo
  provider_setup_config "$domain" || return 1

  echo
  echo -e "Проверяем доступ и ищем DNS-зону ${GREEN}$(dns_fqdn "$domain")${WHITE}..."
  provider_auth || {
    wait_for_enter
    return 1
  }
  zone_info="$(provider_find_zone "$domain")" || {
    wait_for_enter
    return 1
  }
  DNS_ZONE_ID="${zone_info%%$'\t'*}"
  DNS_ZONE_NAME="${zone_info#*$'\t'}"
  echo -e "Доступ к DNS-провайдеру ${GREEN}${DNS_PROVIDER}${WHITE} подтвержден."
  echo -e "DNS-зона найдена: ${GREEN}${DNS_ZONE_NAME}${WHITE}"

  if save_domain_config "$domain"; then
    echo -e "Настройки сохранены: ${YELLOW}$(dns_config_file "$domain")${WHITE}"
    echo -e "DNS-провайдер ${GREEN}${DNS_PROVIDER}${WHITE} подключен к ${GREEN}${domain}${WHITE}."
  else
    echo -e "Не удалось сохранить настройки DNS." >&2
    wait_for_enter
    return 1
  fi
  wait_for_enter
  return 0
}

switch_dns_provider_menu() {
  local domain="$1"
  local choice
  local selected_action
  local selected_provider
  local saved_selectel=0
  local saved_cloudns=0
  local -a labels=()
  local -a actions=()
  local -a providers=()

  archive_active_domain_config "$domain" || {
    echo -e "Не удалось сохранить текущее подключение." >&2
    wait_for_enter
    return 1
  }

  while true; do
    labels=("Подключить Selectel" "Подключить ClouDNS")
    actions=("connect" "connect")
    providers=("selectel" "cloudns")
    saved_selectel=0
    saved_cloudns=0

    if [[ -f "$(dns_provider_config_file "$domain" "selectel")" ]]; then
      labels+=("Выбрать сохраненный Selectel")
      actions+=("select")
      providers+=("selectel")
      saved_selectel=1
    fi
    if [[ -f "$(dns_provider_config_file "$domain" "cloudns")" ]]; then
      labels+=("Выбрать сохраненный ClouDNS")
      actions+=("select")
      providers+=("cloudns")
      saved_cloudns=1
    fi
    labels+=("Назад")
    actions+=("back")
    providers+=("")

    clear
    echo -e "Смена DNS-провайдера для ${GREEN}${domain}${WHITE}"
    echo -e "Текущий provider: ${YELLOW}${DNS_PROVIDER}${WHITE}"
    echo
    if ((saved_selectel || saved_cloudns)); then
      echo "Сохраненные подключения можно выбрать без повторного ввода доступов."
      echo
    fi

    vertical_menu "current" 2 0 32 "${labels[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#labels[@]})); then
      return 1
    fi

    selected_action="${actions[$choice]}"
    selected_provider="${providers[$choice]}"
    case "$selected_action" in
      connect)
        connect_provider "$domain" "$selected_provider" || return 1
        return 0
        ;;
      select)
        if activate_saved_provider_config "$domain" "$selected_provider"; then
          echo -e "Активировано сохраненное подключение ${GREEN}${selected_provider}${WHITE}."
          wait_for_enter
          return 0
        fi
        echo -e "Не удалось выбрать сохраненное подключение ${YELLOW}${selected_provider}${WHITE}." >&2
        wait_for_enter
        return 1
        ;;
      back)
        return 1
        ;;
    esac
  done
}

load_records_cache() {
  if [[ "$DNS_RECORD_CACHE_LOADED" -eq 1 ]]; then
    return 0
  fi

  DNS_RECORD_TYPES=()
  DNS_RECORD_TTLS=()
  DNS_RECORD_NAMES=()
  DNS_RECORD_VALUES=()
  DNS_RECORD_REFS=()
  DNS_RECORD_LABELS=()
  DNS_RECORD_MENU_INDEXES=()
  DNS_RECORD_VALUE_INDEXES=()
  DNS_RECORD_ROW_VALUES=()
  DNS_RECORD_VALUE_REFS=()
  DNS_RECORD_MENU_TOTAL_ROWS=0
  DNS_RECORD_MENU_TRUNCATED=0
  DNS_RECORD_TYPE_WIDTH=4
  DNS_RECORD_NAME_WIDTH=0

  local type
  local ttl
  local name
  local records_json
  local refs_json
  local records_tmp
  local value
  local value_ref
  local i
  local first_value
  local value_index

  records_tmp="$(mktemp)" || return 1
  if ! provider_list_records "$DNS_ZONE_ID" > "$records_tmp"; then
    rm -f "$records_tmp"
    return 1
  fi

  while IFS=$'\t' read -r type ttl name records_json refs_json; do
    [[ -n "$type" ]] || continue
    refs_json="${refs_json:-[]}"
    if ! jq -e 'type == "array"' <<< "$records_json" >/dev/null 2>&1; then
      rm -f "$records_tmp"
      echo -e "Провайдер вернул некорректные значения для ${YELLOW}${type} ${name}${WHITE}." >&2
      return 1
    fi
    if ! jq -e 'type == "array"' <<< "$refs_json" >/dev/null 2>&1; then
      rm -f "$records_tmp"
      echo -e "Провайдер вернул некорректные идентификаторы для ${YELLOW}${type} ${name}${WHITE}." >&2
      return 1
    fi
    DNS_RECORD_TYPES+=("$type")
    DNS_RECORD_TTLS+=("$ttl")
    DNS_RECORD_NAMES+=("$name")
    DNS_RECORD_VALUES+=("$records_json")
    DNS_RECORD_REFS+=("$refs_json")
    if ((${#type} > DNS_RECORD_TYPE_WIDTH)); then
      DNS_RECORD_TYPE_WIDTH=${#type}
    fi
    if ((${#name} > DNS_RECORD_NAME_WIDTH)); then
      DNS_RECORD_NAME_WIDTH=${#name}
    fi
  done < "$records_tmp"
  rm -f "$records_tmp"

  if ((DNS_RECORD_NAME_WIDTH < 8)); then
    DNS_RECORD_NAME_WIDTH=8
  elif ((DNS_RECORD_NAME_WIDTH > 32)); then
    DNS_RECORD_NAME_WIDTH=32
  fi

  for i in "${!DNS_RECORD_TYPES[@]}"; do
    first_value=1
    value_index=0
    while IFS= read -r value; do
      value_ref="$(jq -r --argjson index "$value_index" '.[$index] // ""' <<< "${DNS_RECORD_REFS[$i]}")"
      DNS_RECORD_LABELS+=("$(record_menu_row_label "${DNS_RECORD_TYPES[$i]}" "${DNS_RECORD_NAMES[$i]}" "$value")")
      first_value=0
      DNS_RECORD_MENU_INDEXES+=("$i")
      DNS_RECORD_VALUE_INDEXES+=("$value_index")
      DNS_RECORD_ROW_VALUES+=("$value")
      DNS_RECORD_VALUE_REFS+=("$value_ref")
      value_index=$((value_index + 1))
    done < <(jq -r '.[]' <<< "${DNS_RECORD_VALUES[$i]}")
    if ((first_value)); then
      DNS_RECORD_LABELS+=("$(record_menu_row_label "${DNS_RECORD_TYPES[$i]}" "${DNS_RECORD_NAMES[$i]}" "нет значений")")
      DNS_RECORD_MENU_INDEXES+=("$i")
      DNS_RECORD_VALUE_INDEXES+=("-1")
      DNS_RECORD_ROW_VALUES+=("")
      DNS_RECORD_VALUE_REFS+=("")
    fi
  done

  DNS_RECORD_MENU_TOTAL_ROWS="${#DNS_RECORD_LABELS[@]}"
  if ((DNS_RECORD_MENU_TOTAL_ROWS > DNS_RECORD_MENU_LIMIT)); then
    DNS_RECORD_LABELS=("${DNS_RECORD_LABELS[@]:0:DNS_RECORD_MENU_LIMIT}")
    DNS_RECORD_MENU_INDEXES=("${DNS_RECORD_MENU_INDEXES[@]:0:DNS_RECORD_MENU_LIMIT}")
    DNS_RECORD_VALUE_INDEXES=("${DNS_RECORD_VALUE_INDEXES[@]:0:DNS_RECORD_MENU_LIMIT}")
    DNS_RECORD_ROW_VALUES=("${DNS_RECORD_ROW_VALUES[@]:0:DNS_RECORD_MENU_LIMIT}")
    DNS_RECORD_VALUE_REFS=("${DNS_RECORD_VALUE_REFS[@]:0:DNS_RECORD_MENU_LIMIT}")
    DNS_RECORD_MENU_TRUNCATED=1
  fi

  DNS_RECORD_CACHE_LOADED=1
}

invalidate_records_cache() {
  DNS_RECORD_CACHE_LOADED=0
}

choose_record_type() {
  local choice
  local -a types=(A AAAA CNAME MX TXT)

  echo "Выберите тип записи:"
  vertical_menu "current" 2 0 10 "${types[@]}" "Отмена"
  choice=$?
  if ((choice == 255 || choice == ${#types[@]})); then
    return 1
  fi

  printf '\033[1A\033[2K'
  SELECTED_RECORD_TYPE="${types[$choice]}"
}

read_record_value() {
  local type="$1"
  local result_var="$2"
  local current="${3:-}"
  local priority="10"
  local server=""

  if [[ "$type" == "MX" ]]; then
    if [[ "$current" =~ ^([0-9]+)[[:space:]]+(.+)$ ]]; then
      priority="${BASH_REMATCH[1]}"
      server="${BASH_REMATCH[2]}"
    else
      server="$current"
    fi

    rish_read_input priority "Приоритет MX: " "$priority"
    rish_read_input server "Сервер MX: " "$server"
    if [[ ! "$priority" =~ ^[0-9]+$ ]]; then
      echo -e "Приоритет MX должен быть числом." >&2
      return 1
    fi
    if [[ -z "$server" ]]; then
      echo -e "Не задан сервер MX." >&2
      return 1
    fi
    if [[ "$server" != *"." ]]; then
      server="${server}."
    fi

    printf -v "$result_var" '%s %s' "$priority" "$server"
    return
  fi

  rish_read_input "$result_var" "Значение записи: " "$current"
}

create_record() {
  local type
  local name_input
  local name
  local value
  local ttl

  clear
  echo -e "Создание DNS-записи для ${GREEN}${DNS_DOMAIN}${WHITE}"
  choose_record_type || return
  type="$SELECTED_RECORD_TYPE"

  rish_read_input name_input "Имя записи (@, www или полное имя): " "@"
  read_record_value "$type" value || {
    wait_for_enter
    return
  }
  rish_read_input ttl "TTL: " "${DNS_DEFAULT_TTL:-3600}"

  name="$(normalize_record_name "$name_input" "$DNS_DOMAIN")"
  if [[ ! "$ttl" =~ ^[0-9]+$ ]]; then
    echo -e "TTL должен быть числом." >&2
    wait_for_enter
    return
  fi
  if [[ -z "$value" ]]; then
    echo -e "Не задано значение записи." >&2
    wait_for_enter
    return
  fi
  has_cname_conflict "$name" "$type" "create"
  case $? in
    0)
      echo -e "Конфликт CNAME: на имени ${YELLOW}${name}${WHITE} уже есть несовместимая запись." >&2
      wait_for_enter
      return
      ;;
    2)
      echo -e "Не удалось проверить конфликт CNAME: DNS-записи не загружены." >&2
      wait_for_enter
      return
      ;;
  esac

  if provider_add_record_value "$DNS_ZONE_ID" "$name" "$type" "$ttl" "$value"; then
    invalidate_records_cache
    echo -e "Запись ${GREEN}${type} ${name}${WHITE} создана."
  else
    echo >&2
    echo -e "Не удалось создать запись." >&2
  fi
  wait_for_enter
}

edit_record() {
  local index="$1"
  local value_index="$2"
  local value_ref="$3"
  local type="${DNS_RECORD_TYPES[$index]}"
  local name="${DNS_RECORD_NAMES[$index]}"
  local ttl="${DNS_RECORD_TTLS[$index]}"
  local current_value
  local new_value
  local new_ttl

  current_value="$(jq -r --argjson index "$value_index" '.[$index]' <<< "${DNS_RECORD_VALUES[$index]}")"
  clear
  echo "Редактирование DNS-записи"
  echo
  echo -e "Тип записи: ${GREEN}${type}${WHITE}"
  echo -e "Имя записи: ${GREEN}${name}${WHITE}"
  read_record_value "$type" new_value "$current_value" || {
    wait_for_enter
    return
  }
  rish_read_input new_ttl "TTL: " "$ttl"

  if [[ ! "$new_ttl" =~ ^[0-9]+$ ]]; then
    echo -e "TTL должен быть числом." >&2
    wait_for_enter
    return
  fi
  if [[ -z "$new_value" ]]; then
    echo -e "Не задано значение записи." >&2
    wait_for_enter
    return
  fi
  has_cname_conflict "$name" "$type" "update"
  case $? in
    0)
      echo -e "Конфликт CNAME: на имени ${YELLOW}${name}${WHITE} уже есть несовместимая запись." >&2
      wait_for_enter
      return
      ;;
    2)
      echo -e "Не удалось проверить конфликт CNAME: DNS-записи не загружены." >&2
      wait_for_enter
      return
      ;;
  esac

  if provider_update_record_value "$DNS_ZONE_ID" "$name" "$type" "$current_value" "$new_value" "$new_ttl" "$value_ref"; then
    invalidate_records_cache
    echo -e "Запись ${GREEN}${type} ${name}${WHITE} обновлена."
  else
    echo >&2
    echo -e "Не удалось обновить запись." >&2
  fi
  wait_for_enter
}

set_a_record_to_server_ip() {
  local index="$1"
  local value_index="$2"
  local value_ref="$3"
  local ip_address="${4:-}"
  local name="${DNS_RECORD_NAMES[$index]}"
  local ttl="${DNS_RECORD_TTLS[$index]}"
  local current_value
  local choice

  current_value="$(jq -r --argjson index "$value_index" '.[$index]' <<< "${DNS_RECORD_VALUES[$index]}")"
  if [[ -z "$ip_address" ]]; then
    ip_address="$(server_ipv4)"
  fi

  clear
  if [[ ! "$ip_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo -e "Не удалось определить IPv4-адрес сервера." >&2
    wait_for_enter
    return
  fi
  if ipv4_is_private "$ip_address"; then
    echo -e "Определен непубличный IPv4-адрес: ${YELLOW}${ip_address}${WHITE}." >&2
    vertical_menu "current" 2 0 12 "Отмена" "Установить"
    choice=$?
    if ((choice != 1)); then
      echo "Запись не изменена."
      wait_for_enter
      return
    fi
  fi

  echo -e "IPv4 сервера: ${GREEN}${ip_address}${WHITE}"
  if provider_update_record_value "$DNS_ZONE_ID" "$name" "A" "$current_value" "$ip_address" "$ttl" "$value_ref"; then
    invalidate_records_cache
    echo -e "Запись ${GREEN}A ${name}${WHITE} обновлена."
  else
    echo >&2
    echo -e "Не удалось обновить запись." >&2
  fi
  wait_for_enter
}

delete_record() {
  local index="$1"
  local value_index="$2"
  local value_ref="$3"
  local type="${DNS_RECORD_TYPES[$index]}"
  local name="${DNS_RECORD_NAMES[$index]}"
  local value
  local choice

  value="$(jq -r --argjson index "$value_index" '.[$index]' <<< "${DNS_RECORD_VALUES[$index]}")"
  clear
  echo -e "Удалить ${RED}${type} ${name}${WHITE}?"
  echo -e "Значение: ${YELLOW}${value}${WHITE}"
  vertical_menu "current" 2 0 5 "Нет" "Да"
  choice=$?
  if ((choice != 1)); then
    echo "Запись не удалена."
    wait_for_enter
    return
  fi

  if provider_delete_record_value "$DNS_ZONE_ID" "$name" "$type" "$value" "$value_ref"; then
    invalidate_records_cache
    echo -e "Запись ${GREEN}${type} ${name}${WHITE} удалена."
  else
    echo >&2
    echo -e "Не удалось удалить запись." >&2
  fi
  wait_for_enter
}

show_record_info() {
  local index="$1"
  local value_index="$2"
  local value
  local mx_priority
  local mx_server

  value="$(jq -r --argjson index "$value_index" '.[$index]' <<< "${DNS_RECORD_VALUES[$index]}")"

  clear
  echo "DNS-запись"
  echo
  echo -e "Тип записи: ${GREEN}${DNS_RECORD_TYPES[$index]}${WHITE}"
  echo -e "Имя записи: ${GREEN}${DNS_RECORD_NAMES[$index]}${WHITE}"
  echo -e "TTL: ${YELLOW}${DNS_RECORD_TTLS[$index]}${WHITE}"
  if [[ "${DNS_RECORD_TYPES[$index]}" == "MX" && "$value" =~ ^([0-9]+)[[:space:]]+(.+)$ ]]; then
    mx_priority="${BASH_REMATCH[1]}"
    mx_server="${BASH_REMATCH[2]}"
    echo -e "Приоритет MX: ${YELLOW}${mx_priority}${WHITE}"
    echo -e "Сервер MX: ${YELLOW}${mx_server}${WHITE}"
  else
    echo -e "Значение: ${YELLOW}${value}${WHITE}"
  fi
  wait_for_enter
}

draw_dns_action_connector() {
  local from_x="$LAST_DNS_MENU_RIGHT_X"
  local to_x="$LAST_DNS_MENU_ACTION_X"
  local row="$LAST_DNS_SELECTED_ROW"
  local length

  length=$((to_x - from_x))
  if ((length <= 1)); then
    return
  fi

  cursor_to "$row" "$from_x"
  printf "├"
  repl "─" "$((length - 1))"
}

record_actions_menu() {
  local index="$1"
  local value_index="$2"
  local value_ref="$3"
  local type="${DNS_RECORD_TYPES[$index]}"
  local choice
  local action_menu_y
  local server_ip
  local has_server_ip=0

  while true; do
    server_ip=""
    has_server_ip=0
    if [[ "$type" == "A" ]]; then
      server_ip="$(server_ipv4)"
      if [[ "$server_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        has_server_ip=1
      fi
    fi

    action_menu_y=$((LAST_DNS_SELECTED_ROW - 1))
    draw_dns_action_connector
    if [[ "$type" == "A" && "$has_server_ip" -eq 1 ]]; then
      vertical_menu "$action_menu_y" "$LAST_DNS_MENU_ACTION_X" 0 24 "Инфо: TTL ${DNS_RECORD_TTLS[$index]}" "Установить ${server_ip}" "Редактировать" "Удалить" "Назад"
    else
      vertical_menu "$action_menu_y" "$LAST_DNS_MENU_ACTION_X" 0 20 "Инфо: TTL ${DNS_RECORD_TTLS[$index]}" "Редактировать" "Удалить" "Назад"
    fi
    choice=$?
    if [[ "$type" == "A" && "$has_server_ip" -eq 1 ]]; then
      case "$choice" in
        0)
          show_record_info "$index" "$value_index"
          return
          ;;
        1)
          set_a_record_to_server_ip "$index" "$value_index" "$value_ref" "$server_ip"
          return
          ;;
        2)
          edit_record "$index" "$value_index" "$value_ref"
          return
          ;;
        3)
          delete_record "$index" "$value_index" "$value_ref"
          return
          ;;
        4 | 255)
          return
          ;;
      esac
    else
      case "$choice" in
        0)
          show_record_info "$index" "$value_index"
          return
          ;;
        1)
          edit_record "$index" "$value_index" "$value_ref"
          return
          ;;
        2)
          delete_record "$index" "$value_index" "$value_ref"
          return
          ;;
        3 | 255)
          return
          ;;
      esac
    fi
  done
}

import_zone_file_menu() {
  local zone_file
  local type
  local ttl
  local name
  local records_json
  local record
  local imported=0
  local failed=0
  local records_tmp

  clear
  echo -e "Импорт zone file для ${GREEN}${DNS_DOMAIN}${WHITE}"
  rish_read_input zone_file "Путь к zone file: "
  [[ -n "$zone_file" ]] || return

  records_tmp="$(mktemp)" || {
    echo -e "Не удалось создать временный файл для импорта." >&2
    wait_for_enter
    return
  }
  if ! parse_zonefile "$zone_file" "$DNS_DOMAIN" > "$records_tmp"; then
    rm -f "$records_tmp"
    wait_for_enter
    return
  fi

  while IFS=$'\t' read -r type ttl name records_json; do
    [[ -n "$type" ]] || continue
    while IFS= read -r record; do
      [[ -n "$record" ]] || continue
      if provider_add_record_value "$DNS_ZONE_ID" "$name" "$type" "$ttl" "$record"; then
        imported=$((imported + 1))
      else
        failed=$((failed + 1))
        echo -e "Не удалось импортировать ${YELLOW}${type} ${name}${WHITE}." >&2
      fi
    done < <(jq -r '.[]' <<< "$records_json")
  done < "$records_tmp"
  rm -f "$records_tmp"

  echo -e "Импортировано записей: ${GREEN}${imported}${WHITE}"
  if ((imported > 0)); then
    invalidate_records_cache
  fi
  if ((failed > 0)); then
    echo -e "Ошибок: ${RED}${failed}${WHITE}"
  fi
  wait_for_enter
}

dns_domain_menu() {
  local domain="$1"
  local choice
  local menu_height
  local menu_used_rows

  DNS_DOMAIN="$domain"
  require_command curl
  require_command jq

  if ! load_domain_config "$domain"; then
    show_connect_provider_menu "$domain"
  fi

  load_domain_config "$domain" || fail "Настройки DNS для ${domain} не найдены."
  load_provider "$DNS_PROVIDER"

  show_dns_status "Подключаемся к DNS-провайдеру..."
  provider_prepare || {
    wait_for_enter
    return
  }

  while true; do
    clear
    echo -e "DNS: ${GREEN}${DNS_DOMAIN}${WHITE}"
    echo -e "Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}"
    echo

    if [[ "$DNS_RECORD_CACHE_LOADED" -eq 0 ]]; then
      show_dns_status "Получаем DNS-записи..."
    fi
    if ! load_records_cache; then
      echo -e "Не удалось получить список DNS-записей." >&2
      wait_for_enter
      return
    fi

    clear
    echo -e "DNS: ${GREEN}${DNS_DOMAIN}${WHITE}"
    echo -e "Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}"
    echo
    menu_used_rows=3
    if ((DNS_RECORD_MENU_TRUNCATED)); then
      echo -e "Внимание: показаны первые ${YELLOW}${DNS_RECORD_MENU_LIMIT}${WHITE} строк DNS-записей из ${YELLOW}${DNS_RECORD_MENU_TOTAL_ROWS}${WHITE}; список обрезан."
      echo
      menu_used_rows=5
    fi

    menu_height="$(dns_menu_available_height "$menu_used_rows")"
    vertical_menu "current_noclear" 2 "$menu_height" 42 "default=${DNS_MENU_DEFAULT_INDEX}" "Создать запись" "${DNS_RECORD_LABELS[@]}" "Сменить DNS-провайдера" "Импорт zone file" "Выйти"
    choice=$?
    LAST_DNS_MENU_Y="$VERTICAL_MENU_LAST_Y"
    LAST_DNS_MENU_ACTION_X="$(vertical_menu_next_x 2)"
    LAST_DNS_MENU_RIGHT_X="$VERTICAL_MENU_LAST_RIGHT_X"
    LAST_DNS_SELECTED_ROW=$((LAST_DNS_MENU_Y + VERTICAL_MENU_LAST_VISIBLE_SELECTED + 1))

    if ((choice == 255 || choice == ${#DNS_RECORD_LABELS[@]} + 3)); then
      exit 0
    elif ((choice == 0)); then
      DNS_MENU_DEFAULT_INDEX=0
      create_record
    elif ((choice == ${#DNS_RECORD_LABELS[@]} + 1)); then
      DNS_MENU_DEFAULT_INDEX="$choice"
      if switch_dns_provider_menu "$domain"; then
        DNS_MENU_DEFAULT_INDEX=0
        invalidate_records_cache
        restore_active_domain_config "$domain" || fail "Настройки DNS для ${domain} не найдены."
        show_dns_status "Подключаемся к DNS-провайдеру..."
        provider_prepare || {
          wait_for_enter
          return
        }
      else
        restore_active_domain_config "$domain" || fail "Настройки DNS для ${domain} не найдены."
        echo -e "Смена DNS-провайдера не выполнена. Восстановлено прежнее подключение ${GREEN}${DNS_PROVIDER}${WHITE}."
        wait_for_enter
      fi
    elif ((choice == ${#DNS_RECORD_LABELS[@]} + 2)); then
      DNS_MENU_DEFAULT_INDEX="$choice"
      import_zone_file_menu
    else
      DNS_MENU_DEFAULT_INDEX="$choice"
      record_actions_menu "${DNS_RECORD_MENU_INDEXES[$((choice - 1))]}" "${DNS_RECORD_VALUE_INDEXES[$((choice - 1))]}" "${DNS_RECORD_VALUE_REFS[$((choice - 1))]}"
    fi
  done
}

dns_menu_from_mc() {
  local directory="$1"
  local name="$2"
  local domain
  local site_path

  directory="${directory%/}"
  domain="$name"
  site_path="${directory}/${name}"

  if [[ -z "$directory" || -z "$name" ]]; then
    fail "Не переданы параметры Midnight Commander."
  fi
  if [[ ! "$directory" =~ ^/var/www/[^/]+/www$ ]]; then
    fail "DNS доступен из папки ${YELLOW}/var/www/<user>/www${WHITE}."
  fi
  if ! validate_domain "$domain"; then
    fail "Имя выбранной папки ${YELLOW}${domain}${WHITE} не похоже на домен."
  fi
  if ! site_is_created "$directory" "$domain"; then
    fail "Папка ${YELLOW}${domain}${WHITE} не является созданным сайтом RISH."
  fi

  dns_domain_menu "$domain"
}

dns_import_zone_command() {
  local domain="$1"
  local zone_file="$2"
  local type
  local ttl
  local name
  local records_json
  local record
  local records_tmp

  require_command curl
  require_command jq
  validate_domain "$domain" || fail "Некорректный домен ${domain}."
  load_domain_config "$domain" || fail "Настройки DNS для ${domain} не найдены."
  load_provider "$DNS_PROVIDER"
  provider_prepare || exit 1

  records_tmp="$(mktemp)" || exit 1
  if ! parse_zonefile "$zone_file" "$domain" > "$records_tmp"; then
    rm -f "$records_tmp"
    exit 1
  fi

  while IFS=$'\t' read -r type ttl name records_json; do
    [[ -n "$type" ]] || continue
    while IFS= read -r record; do
      [[ -n "$record" ]] || continue
      provider_add_record_value "$DNS_ZONE_ID" "$name" "$type" "$ttl" "$record" || exit 1
    done < <(jq -r '.[]' <<< "$records_json")
  done < "$records_tmp"
  rm -f "$records_tmp"
}

main() {
  local command="${1:-menu-from-mc}"

  case "$command" in
    menu-from-mc)
      dns_menu_from_mc "${2:-}" "${3:-}"
      ;;
    menu)
      validate_domain "${2:-}" || fail "Некорректный домен ${2:-}."
      dns_domain_menu "$2"
      ;;
    import-zone)
      dns_import_zone_command "${2:-}" "${3:-}"
      ;;
    *)
      dns_menu_from_mc "${1:-}" "${2:-}"
      ;;
  esac
}

if [[ "${DNS_SKIP_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
