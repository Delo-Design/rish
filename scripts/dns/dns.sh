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
DNS_RECORD_MENU_LIMIT=247
DNS_RECORD_MENU_TOTAL_ROWS=0
DNS_RECORD_MENU_TRUNCATED=0
DNS_MENU_DEFAULT_INDEX=0
DNS_PROVIDER_CONNECTION_READY=0
LAST_DNS_MENU_Y=0
LAST_DNS_MENU_ACTION_X=0
LAST_DNS_MENU_RIGHT_X=0
LAST_DNS_SELECTED_ROW=0
DNS_RECORD_INFO_RESULT_DIR=""
DNS_RECORD_INFO_QUERY_PIDS=()
DNS_RECORD_INFO_PREVIOUS_INT_TRAP=""
DNS_RECORD_INFO_PREVIOUS_TERM_TRAP=""
DNS_RECORD_INFO_PREVIOUS_HUP_TRAP=""
DNS_RECORD_INFO_LEFT_WIDTH=50
DNS_RECORD_INFO_RIGHT_WIDTH=70

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
  local read_value
  local readline_prompt

  readline_prompt=$'\001\033[0m\002'"${prompt}"$'\001\033[0;32m\002'
  if (($# >= 3)); then
    read -r -e -p "$readline_prompt" -i "$default_value" read_value
  else
    read -r -e -p "$readline_prompt" read_value
  fi
  echo -en "${WHITE}"
  printf -v "$result_var" '%s' "$read_value"
}

rish_read_visible_secret() {
  local result_var="$1"
  local prompt="$2"
  local read_value
  local readline_prompt

  readline_prompt=$'\001\033[0m\002'"${prompt}"$'\001\033[0;32m\002'
  read -r -e -p "$readline_prompt" read_value
  printf '\033[1A\033[2K'
  echo -en "${WHITE}"
  printf -v "$result_var" '%s' "$read_value"
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
  echo -e "Сайт: ${GREEN}${DNS_DOMAIN}${WHITE}"
  echo -e "DNS-зона: ${GREEN}${DNS_ZONE_NAME}${WHITE}"
  echo -e "Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}"
  echo
  echo -e "$message"
}

build_dns_info_box_lines() {
  local result_var="$1"
  local title="$2"
  shift 2
  # shellcheck disable=SC2034
  local -n result_ref="$result_var"
  local -a lines=()
  local content_width="${DNS_INFO_BOX_MIN_WIDTH:-30}"
  local title_text=" ${title} "
  local title_len=${#title_text}
  local border_width
  local top_fill_len
  local line
  local pad_len
  local top_fill
  local bottom_fill

  for line in "$@"; do
    if ((${#line} > content_width)); then
      content_width=${#line}
    fi
  done
  if ((title_len > content_width + 2)); then
    content_width=$((title_len - 2))
  fi

  border_width=$((content_width + 2))
  top_fill_len=$((border_width - title_len))
  printf -v top_fill '%*s' "$top_fill_len" ''
  printf -v bottom_fill '%*s' "$border_width" ''
  lines+=("┌${title_text}${top_fill// /─}┐")

  for line in "$@"; do
    pad_len=$((content_width - ${#line}))
    ((pad_len < 0)) && pad_len=0
    printf -v line '│ %s%*s │' "$line" "$pad_len" ''
    lines+=("$line")
  done

  lines+=("└${bottom_fill// /─}┘")
  # shellcheck disable=SC2034
  result_ref=("${lines[@]}")
}

get_current_dns_nameservers() {
  local zone_name="$1"
  local result_var="$2"
  local -n nameservers_ref="$result_var"
  local dig_output
  local nameserver
  local -A seen_nameservers=()
  local -a sorted_nameservers=()

  nameservers_ref=()
  command -v dig >/dev/null 2>&1 || return 1
  if ! dig_output="$(dig +short +time=2 +tries=3 NS "$zone_name" 2>/dev/null)"; then
    return 1
  fi

  while IFS= read -r nameserver; do
    nameserver="${nameserver%.}"
    [[ -n "$nameserver" ]] || continue
    [[ -z "${seen_nameservers[$nameserver]+x}" ]] || continue
    seen_nameservers["$nameserver"]=1
    nameservers_ref+=("$nameserver")
  done <<< "$dig_output"

  if ((${#nameservers_ref[@]} > 1)); then
    mapfile -t sorted_nameservers < <(printf '%s\n' "${nameservers_ref[@]}" | LC_ALL=C sort)
    nameservers_ref=("${sorted_nameservers[@]}")
  fi

  ((${#nameservers_ref[@]} > 0))
}

print_dns_zone_summary() {
  local -a nameservers=()
  local -a left_content=(
    "Сайт: ${DNS_DOMAIN}"
    "DNS-зона: ${DNS_ZONE_NAME}"
    "Provider: ${DNS_PROVIDER}"
    "Записей: ${DNS_RECORD_MENU_TOTAL_ROWS}"
  )
  local -a right_content=()
  local -a left_lines=()
  local -a right_lines=()
  local nameserver_status=""
  local rows
  local column_width=0
  local i
  local right_index
  local left_value
  local right_value
  local line
  local terminal_columns="${COLUMNS:-0}"
  local terminal_size
  local needed_columns

  if terminal_size="$(stty size 2>/dev/null)"; then
    terminal_columns="${terminal_size#* }"
  fi

  if ! get_current_dns_nameservers "$DNS_ZONE_NAME" nameservers; then
    nameserver_status="не удалось получить"
  fi

  if ((${#nameservers[@]} > 0)); then
    for line in "${nameservers[@]}"; do
      ((${#line} > column_width)) && column_width=${#line}
    done
    rows=$(((${#nameservers[@]} + 1) / 2))
    for ((i = 0; i < rows; i++)); do
      right_index=$((i * 2))
      left_value="${nameservers[$right_index]}"
      right_value="${nameservers[$((right_index + 1))]:-}"
      printf -v line '%-*s   %s' "$column_width" "$left_value" "$right_value"
      right_content+=("$line")
    done
  else
    right_content+=("$nameserver_status")
  fi

  rows=${#left_content[@]}
  ((${#right_content[@]} > rows)) && rows=${#right_content[@]}
  while ((${#left_content[@]} < rows)); do left_content+=(""); done
  while ((${#right_content[@]} < rows)); do right_content+=(""); done

  build_dns_info_box_lines left_lines "Выбранная DNS-зона" "${left_content[@]}"
  build_dns_info_box_lines right_lines "Текущие публичные NS домена" "${right_content[@]}"

  for i in "${!right_lines[@]}"; do
    for line in "${nameservers[@]}"; do
      right_lines[$i]="${right_lines[$i]/$line/${GREEN}${line}${WHITE}}"
    done
  done

  needed_columns=$((1 + ${#left_lines[0]} + 2 + ${#right_lines[0]}))
  if [[ "$terminal_columns" =~ ^[0-9]+$ ]] && ((terminal_columns > 0 && needed_columns > terminal_columns)); then
    for line in "${left_lines[@]}"; do
      line="${line/Сайт: ${DNS_DOMAIN}/Сайт: ${GREEN}${DNS_DOMAIN}${WHITE}}"
      line="${line/DNS-зона: ${DNS_ZONE_NAME}/DNS-зона: ${GREEN}${DNS_ZONE_NAME}${WHITE}}"
      line="${line/Provider: ${DNS_PROVIDER}/Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}}"
      line="${line/Записей: ${DNS_RECORD_MENU_TOTAL_ROWS}/Записей: ${YELLOW}${DNS_RECORD_MENU_TOTAL_ROWS}${WHITE}}"
      printf ' %b\n' "$line"
    done
    echo
    for line in "${right_lines[@]}"; do
      printf ' %b\n' "$line"
    done
  else
    for i in "${!left_lines[@]}"; do
      line="${left_lines[$i]}"
      line="${line/Сайт: ${DNS_DOMAIN}/Сайт: ${GREEN}${DNS_DOMAIN}${WHITE}}"
      line="${line/DNS-зона: ${DNS_ZONE_NAME}/DNS-зона: ${GREEN}${DNS_ZONE_NAME}${WHITE}}"
      line="${line/Provider: ${DNS_PROVIDER}/Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}}"
      line="${line/Записей: ${DNS_RECORD_MENU_TOTAL_ROWS}/Записей: ${YELLOW}${DNS_RECORD_MENU_TOTAL_ROWS}${WHITE}}"
      printf ' %b  %b\n' "$line" "${right_lines[$i]}"
    done
  fi

  DNS_STATUS_SUMMARY_ROWS=$((rows + 2))
  if [[ "$terminal_columns" =~ ^[0-9]+$ ]] && ((terminal_columns > 0 && needed_columns > terminal_columns)); then
    DNS_STATUS_SUMMARY_ROWS=$((DNS_STATUS_SUMMARY_ROWS * 2 + 1))
  fi
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
    A | AAAA | ALIAS | CAA | CERT | CNAME | DNAME | DS | HINFO | HTTPS | LOC | MX | NAPTR | NS | OPENPGPKEY | PTR | RP | SMIMEA | SPF | SRV | SSHFP | SVCB | TLSA | TXT | WR)
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
  local zone_name="${DNS_ZONE_NAME:-$domain}"
  local input_name
  local input_lower
  local domain_lower
  local zone_lower

  input="${input:-@}"
  domain="${domain%.}"
  zone_name="${zone_name%.}"
  if [[ "$input" == "@" ]]; then
    dns_fqdn "$domain"
  elif [[ "$input" == *"." ]]; then
    printf '%s' "$input"
  else
    input_name="${input%.}"
    input_lower="${input_name,,}"
    domain_lower="${domain,,}"
    zone_lower="${zone_name,,}"
    if [[ "$input_lower" == "$domain_lower" || "$input_lower" == *".${domain_lower}" ||
          "$input_lower" == "$zone_lower" || "$input_lower" == *".${zone_lower}" ]]; then
      dns_fqdn "$input_name"
    else
      dns_fqdn "${input_name}.${domain}"
    fi
  fi
}

record_name_in_selected_zone() {
  local name="${1%.}"
  local zone_name="${DNS_ZONE_NAME:-$DNS_DOMAIN}"

  zone_name="${zone_name%.}"
  name="${name,,}"
  zone_name="${zone_name,,}"
  [[ "$name" == "$zone_name" || "$name" == *".${zone_name}" ]]
}

normalize_record_target_name() {
  local input="$1"
  local zone_name="${DNS_ZONE_NAME:-$DNS_DOMAIN}"

  if [[ "$input" == "@" ]]; then
    dns_fqdn "$zone_name"
  elif [[ "$input" == *"." ]]; then
    printf '%s' "$input"
  elif [[ "$input" == *"."* ]]; then
    dns_fqdn "$input"
  else
    dns_fqdn "${input}.${zone_name%.}"
  fi
}

dns_names_equal() {
  [[ "${1,,}" == "${2,,}" ]]
}

show_self_cname_error() {
  local name="$1"
  local value="$2"

  echo "Имя и значение CNAME указывают на один домен."
  echo
  echo -e "Имя записи: ${YELLOW}${name}${WHITE}"
  echo -e "Значение записи: ${YELLOW}${value}${WHITE}"
  echo
  echo "CNAME должен указывать на другой домен."
}

show_short_name_expansion() {
  local label="$1"
  local input="$2"
  local normalized="$3"
  local zone_name="${DNS_ZONE_NAME:-$DNS_DOMAIN}"

  echo
  echo -e "Введено короткое имя${label:+ ${label}}: ${YELLOW}${input}${WHITE}"
  echo
  echo -e "В DNS короткие имена относятся к текущей зоне ${GREEN}${zone_name%.}${WHITE},"
  echo -e "поэтому будет использовано полное имя: ${GREEN}${normalized}${WHITE}"
}

show_record_name_expansion() {
  local input="$1"
  local normalized="$2"

  echo
  echo -e "Введено относительное имя записи: ${YELLOW}${input}${WHITE}"
  echo
  echo -e "Имена записей без завершающей точки относятся к сайту ${GREEN}${DNS_DOMAIN%.}${WHITE},"
  echo -e "поэтому будет использовано полное имя: ${GREEN}${normalized}${WHITE}"
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
    dns_names_equal "$existing_name" "$name" || continue
    if [[ "$mode" == "update" && "$existing_type" == "$type" ]]; then
      continue
    fi
    if [[ "$type" == "CNAME" || "$existing_type" == "CNAME" ]]; then
      return 0
    fi
  done

  return 1
}

find_best_dns_zone() {
  local domain="$1"
  local configured_zone="${DNS_ZONE_NAME:-}"
  local tried_zone=""
  local candidate="${domain%.}"
  local candidate_fqdn
  local parent
  local result_file
  local error_file

  result_file="$(mktemp)" || return 1
  error_file="$(mktemp)" || {
    rm -f "$result_file"
    return 1
  }

  if [[ -n "$configured_zone" ]]; then
    tried_zone="$(dns_fqdn "$configured_zone")"
    DNS_PROVIDER_ERROR=""
    if provider_find_zone "$configured_zone" > "$result_file" 2> "$error_file"; then
      cat "$result_file"
      rm -f "$result_file" "$error_file"
      return 0
    fi
    if [[ "${DNS_PROVIDER_ERROR:-}" != "zone_not_found" ]]; then
      cat "$error_file" >&2
      rm -f "$result_file" "$error_file"
      return 1
    fi
  fi

  DNS_ZONE_ID=""
  DNS_ZONE_NAME=""
  while [[ "$candidate" == *.* ]]; do
    candidate_fqdn="$(dns_fqdn "$candidate")"
    if [[ "$candidate_fqdn" != "$tried_zone" ]]; then
      : > "$result_file"
      : > "$error_file"
      DNS_ZONE_ID=""
      DNS_ZONE_NAME=""
      DNS_PROVIDER_ERROR=""
      if provider_find_zone "$candidate" > "$result_file" 2> "$error_file"; then
        cat "$result_file"
        rm -f "$result_file" "$error_file"
        return 0
      fi
      if [[ "${DNS_PROVIDER_ERROR:-}" != "zone_not_found" ]]; then
        cat "$error_file" >&2
        rm -f "$result_file" "$error_file"
        return 1
      fi
    fi

    parent="${candidate#*.}"
    [[ "$parent" == *.* ]] || break
    candidate="$parent"
  done

  rm -f "$result_file" "$error_file"
  DNS_PROVIDER_ERROR="zone_not_found"
  echo -e "DNS-зона для ${YELLOW}${domain}${WHITE} или его родительских доменов у провайдера ${YELLOW}${DNS_PROVIDER}${WHITE} не найдена." >&2
  return 1
}

provider_prepare() {
  if ! provider_auth; then
    return 1
  fi
  find_best_dns_zone "$DNS_DOMAIN" >/dev/null || return 1
}

validate_provider_import_types() {
  local records_file="$1"
  local type
  local ttl
  local name
  local records_json
  local values_count
  local rrset_limit=""
  local existing_type
  local found
  local -a unsupported_types=()

  if declare -F provider_import_rrset_limit >/dev/null; then
    rrset_limit="$(provider_import_rrset_limit)" || return 1
    [[ "$rrset_limit" =~ ^[0-9]+$ ]] || {
      echo "Provider вернул некорректный лимит значений в группе DNS-записей." >&2
      return 1
    }
  fi

  while IFS=$'\t' read -r type ttl name records_json; do
    [[ -n "$type" ]] || continue
    if ! provider_import_type_supported "$type"; then
      found=0
      for existing_type in "${unsupported_types[@]}"; do
        if [[ "$existing_type" == "$type" ]]; then
          found=1
          break
        fi
      done
      ((found)) || unsupported_types+=("$type")
    fi

    if [[ -n "$rrset_limit" ]]; then
      values_count="$(jq -r 'length' <<< "$records_json" 2>/dev/null)"
      [[ "$values_count" =~ ^[0-9]+$ ]] || {
        echo -e "Некорректная группа ${YELLOW}${type} ${name}${WHITE} в файле DNS-зоны." >&2
        return 1
      }
      if ((values_count > rrset_limit)); then
        echo -e "Группа ${YELLOW}${type} ${name}${WHITE} содержит ${YELLOW}${values_count}${WHITE} значений." >&2
        echo -e "Provider ${YELLOW}${DNS_PROVIDER}${WHITE} поддерживает не больше ${YELLOW}${rrset_limit}${WHITE} значений в одной группе." >&2
        echo "Импорт остановлен до изменения текущей DNS-зоны." >&2
        return 1
      fi
    fi
  done < "$records_file"

  if ((${#unsupported_types[@]} == 0)); then
    return 0
  fi

  echo -e "Provider ${YELLOW}${DNS_PROVIDER}${WHITE} не поддерживает импорт типов: ${YELLOW}${unsupported_types[*]}${WHITE}." >&2
  echo "Импорт остановлен до изменения текущей DNS-зоны." >&2
  return 1
}

validate_provider_append_limits() {
  local records_file="$1"
  local rrset_limit
  local type
  local ttl
  local name
  local records_json
  local existing_records_json
  local combined_count
  local i

  declare -F provider_import_rrset_limit >/dev/null || return 0
  rrset_limit="$(provider_import_rrset_limit)" || return 1
  [[ "$rrset_limit" =~ ^[0-9]+$ ]] || {
    echo "Provider вернул некорректный лимит значений в группе DNS-записей." >&2
    return 1
  }

  while IFS=$'\t' read -r type ttl name records_json; do
    [[ -n "$type" ]] || continue
    existing_records_json='[]'
    for i in "${!DNS_RECORD_TYPES[@]}"; do
      if [[ "${DNS_RECORD_TYPES[$i]}" == "$type" && "${DNS_RECORD_NAMES[$i]}" == "$name" ]]; then
        existing_records_json="${DNS_RECORD_VALUES[$i]}"
        break
      fi
    done
    combined_count="$(
      jq -nr \
        --argjson existing "$existing_records_json" \
        --argjson imported "$records_json" \
        '$existing + $imported | unique | length'
    )" || return 1
    if ((combined_count > rrset_limit)); then
      echo -e "После добавления группа ${YELLOW}${type} ${name}${WHITE} будет содержать ${YELLOW}${combined_count}${WHITE} значений." >&2
      echo -e "Provider ${YELLOW}${DNS_PROVIDER}${WHITE} поддерживает не больше ${YELLOW}${rrset_limit}${WHITE} значений в одной группе." >&2
      echo "Импорт остановлен до изменения текущей DNS-зоны." >&2
      return 1
    fi
  done < "$records_file"
}

show_connect_provider_menu() {
  local domain="$1"
  local choice
  local selected_action
  local selected_provider
  local -a labels=()
  local -a actions=()
  local -a providers=()

  DNS_PROVIDER_CONNECTION_READY=0
  if [[ -f "$(dns_provider_config_file "$domain" "selectel")" ]]; then
    labels+=("Выбрать сохраненный Selectel")
    actions+=("select")
    providers+=("selectel")
  fi
  if [[ -f "$(dns_provider_config_file "$domain" "cloudns")" ]]; then
    labels+=("Выбрать сохраненный ClouDNS")
    actions+=("select")
    providers+=("cloudns")
  fi
  labels+=("Подключить Selectel" "Подключить ClouDNS" "Выйти")
  actions+=("connect" "connect" "exit")
  providers+=("selectel" "cloudns" "")

  clear
  echo -e "DNS для домена ${GREEN}${domain}${WHITE}"
  echo "Provider еще не подключен."
  if ((${#labels[@]} > 3)); then
    echo
    echo "Сохраненные подключения можно выбрать без повторного ввода доступов."
  fi
  echo
  vertical_menu "current" 2 0 32 "${labels[@]}"
  choice=$?
  if ((choice == 255 || choice >= ${#labels[@]})); then
    exit 0
  fi

  selected_action="${actions[$choice]}"
  selected_provider="${providers[$choice]}"
  case "$selected_action" in
    select)
      if activate_saved_provider_config "$domain" "$selected_provider"; then
        return 0
      fi
      echo -e "Не удалось выбрать сохраненное подключение ${YELLOW}${selected_provider}${WHITE}." >&2
      wait_for_enter
      return 1
      ;;
    connect)
      connect_provider "$domain" "$selected_provider"
      ;;
    exit)
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
  echo -e "Проверяем доступ и ищем DNS-зону для ${GREEN}$(dns_fqdn "$domain")${WHITE}..."
  provider_auth || {
    wait_for_enter
    return 1
  }
  zone_info="$(find_best_dns_zone "$domain")" || {
    wait_for_enter
    return 1
  }
  DNS_ZONE_ID="${zone_info%%$'\t'*}"
  DNS_ZONE_NAME="${zone_info#*$'\t'}"
  echo -e "Доступ к DNS-провайдеру ${GREEN}${DNS_PROVIDER}${WHITE} подтвержден."
  echo -e "Сайт: ${GREEN}${DNS_DOMAIN}${WHITE}"
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
  DNS_PROVIDER_CONNECTION_READY=1
  return 0
}

switch_dns_provider_menu() {
  local domain="$1"
  local pause_after_selection="${2:-1}"
  local choice
  local selected_action
  local selected_provider
  local saved_selectel=0
  local saved_cloudns=0
  local -a labels=()
  local -a actions=()
  local -a providers=()

  DNS_PROVIDER_CONNECTION_READY=0
  archive_active_domain_config "$domain" || {
    echo -e "Не удалось сохранить текущее подключение." >&2
    wait_for_enter
    return 1
  }

  while true; do
    labels=()
    actions=()
    providers=()
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
    labels+=("Подключить Selectel" "Подключить ClouDNS")
    actions+=("connect" "connect")
    providers+=("selectel" "cloudns")
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
          if ((pause_after_selection)); then
            wait_for_enter
          fi
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

change_dns_provider() {
  local domain="$1"
  local prepare_connection="${2:-1}"
  local pause_after_selection=1

  if ((!prepare_connection)); then
    pause_after_selection=0
  fi

  if switch_dns_provider_menu "$domain" "$pause_after_selection"; then
    DNS_MENU_DEFAULT_INDEX=0
    invalidate_records_cache
    restore_active_domain_config "$domain" || fail "Настройки DNS для ${domain} не найдены."
    if ((DNS_PROVIDER_CONNECTION_READY)); then
      DNS_PROVIDER_CONNECTION_READY=0
      return 0
    fi
    if ((!prepare_connection)); then
      return 2
    fi
    show_dns_status "Подключаемся к DNS-провайдеру..."
    if provider_prepare; then
      return 0
    fi
    wait_for_enter
    return 1
  fi

  restore_active_domain_config "$domain" || fail "Настройки DNS для ${domain} не найдены."
  if ((!prepare_connection)); then
    return 1
  fi
  echo -e "Смена DNS-провайдера не выполнена. Восстановлено прежнее подключение ${GREEN}${DNS_PROVIDER}${WHITE}."
  wait_for_enter
  return 1
}

delete_dns_provider_connection() {
  local domain="$1"
  local provider="${DNS_PROVIDER:-}"
  local config_file
  local provider_config_file
  local choice

  if [[ -z "$provider" ]]; then
    echo "Не удалось определить DNS-провайдера для удаления подключения." >&2
    wait_for_enter
    return 1
  fi

  config_file="$(dns_config_file "$domain")"
  provider_config_file="$(dns_provider_config_file "$domain" "$provider")"

  clear
  echo -e "Удаление подключения DNS-провайдера ${YELLOW}${provider}${WHITE} для ${GREEN}${domain}${WHITE}"
  echo
  echo "Будут удалены только локальные настройки подключения RISH."
  echo "DNS-зона и записи у провайдера останутся без изменений."
  echo
  vertical_menu "current" 2 0 42 "Отмена" "Удалить подключение к DNS-провайдеру"
  choice=$?
  if ((choice != 1)); then
    return 1
  fi

  if ! rm -f -- "$config_file" "$provider_config_file"; then
    echo -e "Не удалось удалить локальные настройки подключения ${YELLOW}${provider}${WHITE}." >&2
    wait_for_enter
    return 1
  fi

  invalidate_records_cache
  DNS_PROVIDER=""
  DNS_ZONE_ID=""
  DNS_ZONE_NAME=""
  echo -e "Подключение DNS-провайдера ${YELLOW}${provider}${WHITE} для ${GREEN}${domain}${WHITE} удалено."
  wait_for_enter
  return 0
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
  local records_invalid=0

  records_tmp="$(mktemp)" || return 1
  if ! provider_list_records "$DNS_ZONE_ID" > "$records_tmp"; then
    rm -f "$records_tmp"
    return 1
  fi

  while IFS=$'\t' read -r type ttl name records_json refs_json; do
    [[ -n "$type" ]] || continue
    refs_json="${refs_json:-[]}"
    if ! jq -e 'type == "array"' <<< "$records_json" >/dev/null 2>&1; then
      echo -e "Провайдер вернул некорректные значения для ${YELLOW}${type} ${name}${WHITE}." >&2
      records_invalid=1
      break
    fi
    if ! jq -e 'type == "array"' <<< "$refs_json" >/dev/null 2>&1; then
      echo -e "Провайдер вернул некорректные идентификаторы для ${YELLOW}${type} ${name}${WHITE}." >&2
      records_invalid=1
      break
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
  ((records_invalid == 0)) || return 1

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
  local input_value
  local original_value

  RECORD_VALUE_NAME_EXPANDED=false

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
    original_value="$server"
    server="$(normalize_record_target_name "$server")"
    if [[ "$original_value" != "@" && "$original_value" != *"."* ]]; then
      show_short_name_expansion "сервера" "$original_value" "$server"
      RECORD_VALUE_NAME_EXPANDED=true
    fi

    printf -v "$result_var" '%s %s' "$priority" "$server"
    return
  fi

  rish_read_input input_value "Значение записи: " "$current"
  if [[ "$type" == "CNAME" && -n "$input_value" ]]; then
    original_value="$input_value"
    input_value="$(normalize_record_target_name "$input_value")"
    if [[ "$original_value" != "@" && "$original_value" != *"."* ]]; then
      show_short_name_expansion "" "$original_value" "$input_value"
      RECORD_VALUE_NAME_EXPANDED=true
    fi
  fi
  printf -v "$result_var" '%s' "$input_value"
}

create_record() {
  local type
  local name_input
  local name
  local value
  local ttl
  local ttl_prompt="TTL: "

  clear
  echo -e "Создание DNS-записи для ${GREEN}${DNS_DOMAIN}${WHITE}"
  choose_record_type || return
  type="$SELECTED_RECORD_TYPE"
  echo -e "Тип записи: ${GREEN}${type}${WHITE}"

  rish_read_input name_input "Имя записи (@, www, selector._domainkey или полное имя): " "@"
  name_input="${name_input:-@}"
  if [[ "$name_input" == *"@"* && "$name_input" != "@" ]]; then
    echo -e "Некорректное имя DNS-записи: ${YELLOW}${name_input}${WHITE}"
    echo
    echo -e "${YELLOW}@${WHITE} означает сам домен ${GREEN}${DNS_DOMAIN%.}${WHITE} и не является частью имени."
    echo -e "Укажите либо ${YELLOW}@${WHITE}, либо имя без ${YELLOW}@${WHITE}, например ${GREEN}${name_input//@/}${WHITE}."
    wait_for_enter
    return
  fi
  name="$(normalize_record_name "$name_input" "$DNS_DOMAIN")"
  if ! record_name_in_selected_zone "$name"; then
    echo -e "Имя DNS-записи ${YELLOW}${name}${WHITE} находится вне выбранной зоны ${GREEN}${DNS_ZONE_NAME%.}${WHITE}." >&2
    echo "Укажите относительное имя без завершающей точки либо полное имя внутри выбранной зоны." >&2
    wait_for_enter
    return
  fi
  if [[ "$name_input" != "@" && "$name_input" != *"." ]] && ! dns_names_equal "$name" "$(dns_fqdn "$name_input")"; then
    show_record_name_expansion "$name_input" "$name"
  fi
  read_record_value "$type" value || {
    wait_for_enter
    return
  }
  if [[ "$RECORD_VALUE_NAME_EXPANDED" == true ]]; then
    ttl_prompt=$'\nTTL: '
  fi
  rish_read_input ttl "$ttl_prompt" "${DNS_DEFAULT_TTL:-3600}"

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
  if [[ "$type" == "CNAME" ]] && dns_names_equal "$name" "$value"; then
    show_self_cname_error "$name" "$value" >&2
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
  local ttl_prompt="TTL: "

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
  if [[ "$RECORD_VALUE_NAME_EXPANDED" == true ]]; then
    ttl_prompt=$'\nTTL: '
  fi
  rish_read_input new_ttl "$ttl_prompt" "$ttl"

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
  if [[ "$type" == "CNAME" ]] && dns_names_equal "$name" "$new_value"; then
    show_self_cname_error "$name" "$new_value" >&2
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
  echo -e "${RED}Удаление${WHITE} DNS-записи"
  echo
  echo -e "Тип записи: ${YELLOW}${type}${WHITE}"
  echo -e "Имя записи: ${YELLOW}${name}${WHITE}"
  echo -e "Значение записи: ${YELLOW}${value}${WHITE}"
  echo
  echo -e "${RED}Удалить${WHITE} запись?"
  vertical_menu "current" 2 0 5 "Нет" "Да"
  choice=$?
  if ((choice != 1)); then
    echo "Запись не удалена."
    wait_for_enter
    return
  fi

  if provider_delete_record_value "$DNS_ZONE_ID" "$name" "$type" "$value" "$value_ref"; then
    invalidate_records_cache
    echo "DNS-запись удалена."
    echo
    echo -e "Тип записи: ${YELLOW}${type}${WHITE}"
    echo -e "Имя записи: ${YELLOW}${name}${WHITE}"
    echo -e "Значение записи: ${YELLOW}${value}${WHITE}"
  else
    echo >&2
    echo -e "Не удалось удалить запись." >&2
  fi
  wait_for_enter
}

normalize_public_dns_txt_value() {
  local value="$1"
  local token
  local result=""
  local -a tokens=()

  mapfile -t tokens < <(zonefile_tokenize "$value")
  for token in "${tokens[@]}"; do
    result+="$(zonefile_unquote_token "$token")"
  done
  printf '%s' "$result"
}

normalize_ipv6_address() {
  local value="${1,,}"
  local original="$value"
  local ipv4
  local prefix
  local ipv4_groups
  local left
  local right
  local group
  local normalized=""
  local missing
  local octet
  local -a octets=()
  local -a left_groups=()
  local -a right_groups=()
  local -a groups=()

  if [[ "$value" == *.* ]]; then
    ipv4="${value##*:}"
    prefix="${value%:*}"
    IFS='.' read -r -a octets <<< "$ipv4"
    if ((${#octets[@]} != 4)); then
      printf '%s' "$original"
      return
    fi
    for octet in "${octets[@]}"; do
      if [[ ! "$octet" =~ ^[0-9]+$ ]] || ((10#$octet > 255)); then
        printf '%s' "$original"
        return
      fi
    done
    printf -v ipv4_groups '%x:%x' \
      "$((10#${octets[0]} * 256 + 10#${octets[1]}))" \
      "$((10#${octets[2]} * 256 + 10#${octets[3]}))"
    value="${prefix}:${ipv4_groups}"
  fi

  if [[ "$value" == *::* ]]; then
    if [[ "${value#*::}" == *::* ]]; then
      printf '%s' "$original"
      return
    fi
    left="${value%%::*}"
    right="${value#*::}"
    [[ -z "$left" ]] || IFS=':' read -r -a left_groups <<< "$left"
    [[ -z "$right" ]] || IFS=':' read -r -a right_groups <<< "$right"
    missing=$((8 - ${#left_groups[@]} - ${#right_groups[@]}))
    if ((missing < 1)); then
      printf '%s' "$original"
      return
    fi
    groups=("${left_groups[@]}")
    while ((missing > 0)); do
      groups+=(0)
      missing=$((missing - 1))
    done
    groups+=("${right_groups[@]}")
  else
    IFS=':' read -r -a groups <<< "$value"
    if ((${#groups[@]} != 8)); then
      printf '%s' "$original"
      return
    fi
  fi

  for group in "${groups[@]}"; do
    if [[ ! "$group" =~ ^[0-9a-f]{1,4}$ ]]; then
      printf '%s' "$original"
      return
    fi
    printf -v group '%x' "$((16#$group))"
    if [[ -n "$normalized" ]]; then
      normalized+=":"
    fi
    normalized+="$group"
  done
  printf '%s' "$normalized"
}

normalize_dns_value_for_comparison() {
  local type="$1"
  local value="$2"
  local first
  local second
  local third
  local target
  local params

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  case "$type" in
    AAAA)
      normalize_ipv6_address "$value"
      ;;
    ALIAS | CNAME | DNAME | NS | PTR)
      value="${value%.}"
      printf '%s' "${value,,}"
      ;;
    MX)
      if [[ "$value" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
        first="${BASH_REMATCH[1]}"
        target="${BASH_REMATCH[2]%.}"
        printf '%s %s' "$first" "${target,,}"
      else
        printf '%s' "$value"
      fi
      ;;
    SRV)
      if [[ "$value" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
        first="${BASH_REMATCH[1]}"
        second="${BASH_REMATCH[2]}"
        third="${BASH_REMATCH[3]}"
        target="${BASH_REMATCH[4]%.}"
        printf '%s %s %s %s' "$first" "$second" "$third" "${target,,}"
      else
        printf '%s' "$value"
      fi
      ;;
    HTTPS | SVCB)
      if [[ "$value" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)([[:space:]]+.*)?$ ]]; then
        first="${BASH_REMATCH[1]}"
        target="${BASH_REMATCH[2]%.}"
        params="${BASH_REMATCH[3]}"
        printf '%s %s%s' "$first" "${target,,}" "$params"
      else
        printf '%s' "$value"
      fi
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

get_public_dns_record_answers() {
  local name="$1"
  local type="$2"
  local values_var="$3"
  local ttls_var="$4"
  local resolver="${5:-}"
  # shellcheck disable=SC2034
  local -n values_ref="$values_var"
  # shellcheck disable=SC2034
  local -n ttls_ref="$ttls_var"
  local answer
  local owner
  local ttl
  local dns_class
  local answer_type
  local value
  local -a dig_args=(+noall +comments +answer +time=2 +tries=3)

  values_ref=()
  ttls_ref=()
  PUBLIC_DNS_QUERY_STATUS=""
  if [[ "$type" == "ALIAS" || "$type" == "WR" ]]; then
    PUBLIC_DNS_QUERY_STATUS="UNSUPPORTED"
    return 5
  fi
  command -v dig >/dev/null 2>&1 || return 2
  if [[ -n "$resolver" ]]; then
    dig_args+=("@${resolver}")
  fi
  if ! answer="$(dig "${dig_args[@]}" "$name" "$type" 2>/dev/null)"; then
    return 2
  fi

  if [[ "$answer" =~ status:[[:space:]]*([A-Z]+), ]]; then
    PUBLIC_DNS_QUERY_STATUS="${BASH_REMATCH[1]}"
  else
    PUBLIC_DNS_QUERY_STATUS="UNKNOWN"
    return 4
  fi
  case "$PUBLIC_DNS_QUERY_STATUS" in
    NOERROR) ;;
    NXDOMAIN) return 3 ;;
    *) return 4 ;;
  esac

  while read -r owner ttl dns_class answer_type value; do
    [[ "$dns_class" == "IN" && "$answer_type" == "$type" ]] || continue
    if [[ "$type" == "TXT" ]]; then
      value="$(normalize_public_dns_txt_value "$value")"
    fi
    values_ref+=("$value")
    ttls_ref+=("$ttl")
  done <<< "$answer"

  ((${#values_ref[@]} > 0))
}

query_public_dns_resolver_to_file() {
  local name="$1"
  local type="$2"
  local resolver="$3"
  local output_file="$4"
  local tmp_file="${output_file}.tmp"
  local result
  local i
  local -a values=()
  local -a ttls=()

  get_public_dns_record_answers "$name" "$type" values ttls "$resolver"
  result=$?
  {
    printf '%s\0%s\0' "$result" "${PUBLIC_DNS_QUERY_STATUS:-TRANSPORT}"
    for i in "${!values[@]}"; do
      printf '%s\0%s\0' "${ttls[$i]}" "${values[$i]}"
    done
  } > "$tmp_file"
  mv "$tmp_file" "$output_file"
}

wrap_dns_info_content() {
  local content_var="$1"
  local width="$2"
  local -n content_ref="$content_var"
  local -a wrapped=()
  local line
  local label
  local value
  local available
  local continuation_width
  local chunk

  for line in "${content_ref[@]}"; do
    if ((${#line} <= width)); then
      wrapped+=("$line")
      continue
    fi

    if [[ "$line" == *": "* ]]; then
      label="${line%%:*}: "
      value="${line#*: }"
      available=$((width - ${#label}))
      ((available < 1)) && available=1
      if ((${#value} > available)); then
        chunk="${value:0:available}"
        wrapped+=("${label}${chunk}")
        value="${value:available}"
        continuation_width=$((width - 2))
        ((continuation_width < 1)) && continuation_width=1
        while ((${#value} > continuation_width)); do
          wrapped+=("↳ ${value:0:continuation_width}")
          value="${value:continuation_width}"
        done
        wrapped+=("↳ ${value}")
      else
        wrapped+=("${label}${value}")
      fi
    else
      while ((${#line} > width)); do
        wrapped+=("${line:0:width}")
        line="${line:width}"
      done
      wrapped+=("$line")
    fi
  done
  content_ref=("${wrapped[@]}")
}

truncate_dns_info_value() {
  local value="$1"
  local max_length="${2:-40}"

  if ((${#value} > max_length)); then
    printf '%s…' "${value:0:max_length-1}"
  else
    printf '%s' "$value"
  fi
}

build_multi_resolver_public_content() {
  local result_var="$1"
  local type="$2"
  local name="$3"
  local selected_value="$4"
  local result_dir="$5"
  local states_var="$6"
  local -n public_content_ref="$result_var"
  local -n states_ref="$states_var"
  local -a labels=("Системный DNS" "Google" "Quad9 Secure")
  local -a details=()
  local -a separated_details=()
  local -a data=()
  local -a display_indices=()
  local normalized_selected
  local normalized_public
  local result
  local value_found
  local display_index
  local answer_count
  local displayed_count
  local display_number
  local display_value
  local display_value_found
  local value_label
  local value_max_length
  local max_display_values=4
  local available=0
  local checked=0
  local matched=0
  local unavailable=0
  local dns_errors=0
  local unsupported=0
  local nxdomain=0
  local pending=0
  local i
  local data_index
  local ttl
  local value
  local detail
  local resolver_status
  local summary

  normalized_selected="$(normalize_dns_value_for_comparison "$type" "$selected_value")"
  for i in "${!labels[@]}"; do
    case "${states_ref[$i]}" in
      pending)
        pending=$((pending + 1))
        details+=("${labels[$i]}: проверяем...")
        ;;
      timeout)
        unavailable=$((unavailable + 1))
        details+=("${labels[$i]}: нет ответа")
        ;;
      unsupported)
        unsupported=$((unsupported + 1))
        ;;
      done)
        data=()
        mapfile -d '' -t data < "${result_dir}/${i}.done"
        result="${data[0]:-2}"
        if [[ "$result" == "2" ]]; then
          unavailable=$((unavailable + 1))
          details+=("${labels[$i]}: нет ответа")
          continue
        fi
        if [[ "$result" == "4" ]]; then
          available=$((available + 1))
          dns_errors=$((dns_errors + 1))
          details+=("${labels[$i]}: ошибка ${data[1]:-UNKNOWN}")
          continue
        fi
        if [[ "$result" == "5" ]]; then
          unsupported=$((unsupported + 1))
          continue
        fi

        available=$((available + 1))
        checked=$((checked + 1))
        if [[ "$result" == "1" ]]; then
          details+=("${labels[$i]}: ответов нет")
          continue
        fi
        if [[ "$result" == "3" ]]; then
          nxdomain=$((nxdomain + 1))
          details+=("${labels[$i]}: имя не существует")
          continue
        fi

        value_found=0
        display_index=2
        display_indices=()
        answer_count=$(((${#data[@]} - 2) / 2))
        for ((data_index = 2; data_index + 1 < ${#data[@]}; data_index += 2)); do
          value="${data[$((data_index + 1))]}"
          normalized_public="$(normalize_dns_value_for_comparison "$type" "$value")"
          if [[ "$normalized_public" == "$normalized_selected" ]]; then
            value_found=1
            display_index="$data_index"
          fi
          if ((${#display_indices[@]} < max_display_values)); then
            display_indices+=("$data_index")
          fi
        done
        if ((value_found && answer_count > max_display_values)); then
          display_value_found=0
          for data_index in "${display_indices[@]}"; do
            if ((data_index == display_index)); then
              display_value_found=1
              break
            fi
          done
          if ((!display_value_found)); then
            display_indices[$((max_display_values - 1))]="$display_index"
          fi
        fi
        if ((value_found)); then
          matched=$((matched + 1))
          resolver_status="${labels[$i]}: видна"
        else
          resolver_status="${labels[$i]}: не совпадает"
        fi
        if ((answer_count > 1)); then
          resolver_status+=", записей: ${answer_count}"
        fi
        details+=("$resolver_status")
        if ((answer_count > 0)); then
          ttl="${data[2]}"
          details+=("TTL: ${ttl}")
          if ((answer_count == 1)); then
            value_label="Значение"
            value_max_length=$((DNS_RECORD_INFO_RIGHT_WIDTH - ${#value_label} - 2))
            value="$(truncate_dns_info_value "${data[3]}" "$value_max_length")"
            details+=("${value_label}: ${value}")
          else
            display_number=1
            for data_index in "${display_indices[@]}"; do
              value_label="Значение ${display_number}"
              value_max_length=$((DNS_RECORD_INFO_RIGHT_WIDTH - ${#value_label} - 2))
              display_value="$(truncate_dns_info_value "${data[$((data_index + 1))]}" "$value_max_length")"
              details+=("${value_label}: ${display_value}")
              display_number=$((display_number + 1))
            done
            displayed_count=${#display_indices[@]}
            if ((answer_count > displayed_count)); then
              details+=("Ещё записей: $((answer_count - displayed_count))")
            fi
          fi
        fi
        ;;
    esac
  done

  for detail in "${details[@]}"; do
    case "$detail" in
      "Системный DNS: "* | "Google: "* | "Quad9 Secure: "*)
        if ((${#separated_details[@]} > 0)); then
          separated_details+=("")
        fi
        ;;
    esac
    separated_details+=("$detail")
  done
  details=("${separated_details[@]}")

  if ((unsupported == ${#labels[@]})); then
    summary="проверка типа ${type} не поддерживается"
  elif ((pending > 0)); then
    summary="проверяем..."
  elif ((available == 0)); then
    summary="нет доступных резолверов"
  elif ((nxdomain == available)); then
    summary="имя отсутствует в публичном DNS"
  elif ((matched == 0 && dns_errors == 0)); then
    summary="выбранное значение не найдено"
  elif ((matched == 0)); then
    summary="значение не подтверждено доступными DNS"
  elif ((matched == checked && dns_errors == 0)); then
    summary="значение подтверждено всеми доступными DNS"
  else
    summary="значение совпадает у ${matched} из ${checked} проверенных"
  fi

  public_content_ref=("Тип: ${type}" "Имя: ${name}" "Итог: ${summary}")
  if ((unavailable > 0)); then
    public_content_ref+=("Без ответа: ${unavailable}")
  fi
  if ((dns_errors > 0)); then
    public_content_ref+=("DNS-ошибок: ${dns_errors}")
  fi
  public_content_ref+=("" "${details[@]}")
}

clear_dns_record_info_area() {
  local rows="$1"
  local i

  for ((i = 0; i < rows; i++)); do
    cursor_to "$((i + 1))" 1
    printf '\033[2K'
  done
  cursor_to 1 1
}

color_dns_box_content_line() {
  local lines_var="$1"
  local content_index="$2"
  local raw_content="$3"
  local colored_content="$4"
  local -n lines_ref="$lines_var"
  local line_index=$((content_index + 1))
  local pad_len
  local colored_line

  pad_len=$((${#lines_ref[$line_index]} - ${#raw_content} - 4))
  ((pad_len < 0)) && pad_len=0
  printf -v colored_line '│ %s%*s │' "$colored_content" "$pad_len" ''
  lines_ref[$line_index]="$colored_line"
}

cleanup_dns_record_info_queries() {
  local pid

  for pid in "${DNS_RECORD_INFO_QUERY_PIDS[@]}"; do
    terminate_dns_record_info_query_tree "$pid"
  done
  for pid in "${DNS_RECORD_INFO_QUERY_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  DNS_RECORD_INFO_QUERY_PIDS=()

  if [[ -n "$DNS_RECORD_INFO_RESULT_DIR" ]]; then
    rm -rf -- "$DNS_RECORD_INFO_RESULT_DIR"
    DNS_RECORD_INFO_RESULT_DIR=""
  fi
}

terminate_dns_record_info_query_tree() {
  local pid="$1"
  local child
  local -a children=()

  [[ "$pid" =~ ^[0-9]+$ ]] && ((pid > 1)) || return
  if command -v ps >/dev/null 2>&1; then
    mapfile -t children < <(ps -o pid= --ppid "$pid" 2>/dev/null)
  fi

  kill "$pid" 2>/dev/null || true
  for child in "${children[@]}"; do
    child="${child//[[:space:]]/}"
    [[ -n "$child" ]] || continue
    terminate_dns_record_info_query_tree "$child"
  done
}

restore_dns_record_info_traps() {
  if [[ -n "$DNS_RECORD_INFO_PREVIOUS_INT_TRAP" ]]; then
    eval "$DNS_RECORD_INFO_PREVIOUS_INT_TRAP"
  else
    trap - INT
  fi
  if [[ -n "$DNS_RECORD_INFO_PREVIOUS_TERM_TRAP" ]]; then
    eval "$DNS_RECORD_INFO_PREVIOUS_TERM_TRAP"
  else
    trap - TERM
  fi
  if [[ -n "$DNS_RECORD_INFO_PREVIOUS_HUP_TRAP" ]]; then
    eval "$DNS_RECORD_INFO_PREVIOUS_HUP_TRAP"
  else
    trap - HUP
  fi
  DNS_RECORD_INFO_PREVIOUS_INT_TRAP=""
  DNS_RECORD_INFO_PREVIOUS_TERM_TRAP=""
  DNS_RECORD_INFO_PREVIOUS_HUP_TRAP=""
}

handle_dns_record_info_signal() {
  local signal="$1"

  cleanup_dns_record_info_queries
  restore_dns_record_info_traps
  kill -s "$signal" "$$"

  # Если предыдущий обработчик вернул управление или игнорирует сигнал,
  # продолжаем работу со своими обработчиками.
  install_dns_record_info_traps
}

install_dns_record_info_traps() {
  DNS_RECORD_INFO_PREVIOUS_INT_TRAP="$(trap -p INT)"
  DNS_RECORD_INFO_PREVIOUS_TERM_TRAP="$(trap -p TERM)"
  DNS_RECORD_INFO_PREVIOUS_HUP_TRAP="$(trap -p HUP)"
  trap 'handle_dns_record_info_signal INT' INT
  trap 'handle_dns_record_info_signal TERM' TERM
  trap 'handle_dns_record_info_signal HUP' HUP
}

print_record_info_boxes() {
  local left_var="$1"
  local right_var="$2"
  local -n left_content_ref="$left_var"
  local -n right_content_ref="$right_var"
  local -a left_lines=()
  local -a right_lines=()
  local rows
  local projected_rows
  local i
  local line
  local terminal_columns="${COLUMNS:-0}"
  local terminal_lines="${LINES:-0}"
  local terminal_size
  local needed_columns
  local raw_content
  local label
  local content_value
  local content_color
  local -a compact_right_content=()
  local DNS_INFO_BOX_MIN_WIDTH
  local left_box_min_width="$DNS_RECORD_INFO_LEFT_WIDTH"
  local right_box_min_width="$DNS_RECORD_INFO_RIGHT_WIDTH"
  local stacked=0

  wrap_dns_info_content "$left_var" "$left_box_min_width"
  wrap_dns_info_content "$right_var" "$right_box_min_width"

  DNS_INFO_BOX_MIN_WIDTH="$left_box_min_width"
  build_dns_info_box_lines left_lines "Запись у провайдера" "${left_content_ref[@]}"
  DNS_INFO_BOX_MIN_WIDTH="$right_box_min_width"
  build_dns_info_box_lines right_lines "Запись в публичном DNS" "${right_content_ref[@]}"

  if terminal_size="$(stty size 2>/dev/null)"; then
    terminal_lines="${terminal_size% *}"
    terminal_columns="${terminal_size#* }"
  fi
  needed_columns=$((1 + ${#left_lines[0]} + 2 + ${#right_lines[0]}))
  if [[ "$terminal_columns" =~ ^[0-9]+$ ]] && ((terminal_columns > 0 && needed_columns > terminal_columns)); then
    stacked=1
    projected_rows=$((${#left_lines[@]} + 1 + ${#right_lines[@]}))
  else
    projected_rows=${#left_lines[@]}
    ((${#right_lines[@]} > projected_rows)) && projected_rows=${#right_lines[@]}
  fi

  if [[ "$terminal_lines" =~ ^[0-9]+$ ]] && ((terminal_lines > 0 && projected_rows >= terminal_lines)); then
    for line in "${right_content_ref[@]}"; do
      [[ -n "$line" ]] && compact_right_content+=("$line")
    done
    right_content_ref=("${compact_right_content[@]}")
    DNS_INFO_BOX_MIN_WIDTH="$right_box_min_width"
    build_dns_info_box_lines right_lines "Запись в публичном DNS" "${right_content_ref[@]}"

    if ((stacked)); then
      projected_rows=$((${#left_lines[@]} + 1 + ${#right_lines[@]}))
    else
      projected_rows=${#left_lines[@]}
      ((${#right_lines[@]} > projected_rows)) && projected_rows=${#right_lines[@]}
    fi
    if ((projected_rows >= terminal_lines)); then
      compact_right_content=()
      for line in "${right_content_ref[@]}"; do
        case "$line" in
          Значение\ [2-4]:\ * | "Ещё записей: "*) continue ;;
        esac
        compact_right_content+=("$line")
      done
      right_content_ref=("${compact_right_content[@]}")
      DNS_INFO_BOX_MIN_WIDTH="$right_box_min_width"
      build_dns_info_box_lines right_lines "Запись в публичном DNS" "${right_content_ref[@]}"
    fi
  fi

  if ((!stacked)); then
    rows=${#left_content_ref[@]}
    ((${#right_content_ref[@]} > rows)) && rows=${#right_content_ref[@]}
    while ((${#left_content_ref[@]} < rows)); do left_content_ref+=(""); done
    while ((${#right_content_ref[@]} < rows)); do right_content_ref+=(""); done
    DNS_INFO_BOX_MIN_WIDTH="$left_box_min_width"
    build_dns_info_box_lines left_lines "Запись у провайдера" "${left_content_ref[@]}"
    DNS_INFO_BOX_MIN_WIDTH="$right_box_min_width"
    build_dns_info_box_lines right_lines "Запись в публичном DNS" "${right_content_ref[@]}"
  fi

  content_color=""
  for i in "${!left_content_ref[@]}"; do
    raw_content="${left_content_ref[$i]}"
    if [[ "$raw_content" == "↳ "* ]]; then
      if [[ -n "$content_color" ]]; then
        color_dns_box_content_line left_lines "$i" "$raw_content" "↳ ${content_color}${raw_content#↳ }${WHITE}"
      fi
      continue
    fi
    [[ "$raw_content" == *": "* ]] || {
      content_color=""
      continue
    }
    label="${raw_content%%:*}: "
    content_value="${raw_content#*: }"
    case "$raw_content" in
      "Тип: "* | "Имя: "*) content_color="$GREEN" ;;
      "TTL: "* | "Значение: "*) content_color="$YELLOW" ;;
      *) content_color=""; continue ;;
    esac
    color_dns_box_content_line left_lines "$i" "$raw_content" "${label}${content_color}${content_value}${WHITE}"
  done

  content_color=""
  for i in "${!right_content_ref[@]}"; do
    raw_content="${right_content_ref[$i]}"
    if [[ "$raw_content" == "↳ "* ]]; then
      if [[ -n "$content_color" ]]; then
        color_dns_box_content_line right_lines "$i" "$raw_content" "↳ ${content_color}${raw_content#↳ }${WHITE}"
      fi
      continue
    fi
    [[ "$raw_content" == *": "* ]] || {
      content_color=""
      continue
    }
    label="${raw_content%%:*}: "
    content_value="${raw_content#*: }"
    case "$raw_content" in
      "Тип: "* | "Имя: "*) content_color="$GREEN" ;;
      "Итог: значение подтверждено всеми доступными DNS") content_color="$GREEN" ;;
      "Итог: нет доступных резолверов") content_color="$RED" ;;
      "Итог: имя отсутствует в публичном DNS") content_color="$RED" ;;
      "Итог: выбранное значение не найдено") content_color="$RED" ;;
      "Итог: значение не подтверждено доступными DNS") content_color="$RED" ;;
      "Итог: "* | "Без ответа: "*) content_color="$YELLOW" ;;
      "DNS-ошибок: "*) content_color="$RED" ;;
      *": видна"*) content_color="$GREEN" ;;
      *": нет ответа") content_color="$RED" ;;
      *": ошибка "*) content_color="$RED" ;;
      *": имя не существует") content_color="$RED" ;;
      "Системный DNS: "* | "Google: "* | "Quad9 Secure: "*) content_color="$YELLOW" ;;
      "TTL: "*) content_color="$YELLOW" ;;
      "Значение: "*) content_color="$GREEN" ;;
      Значение\ [0-9]*:\ *) content_color="$GREEN" ;;
      "Ещё записей: "*) content_color="$YELLOW" ;;
      *) content_color=""; continue ;;
    esac
    color_dns_box_content_line right_lines "$i" "$raw_content" "${label}${content_color}${content_value}${WHITE}"
  done

  if ((stacked)); then
    DNS_RECORD_INFO_RENDERED_ROWS=$((${#left_lines[@]} + 1 + ${#right_lines[@]}))
    printf ' %b\n' "${left_lines[@]}"
    echo
    printf ' %b\n' "${right_lines[@]}"
    return
  fi

  DNS_RECORD_INFO_RENDERED_ROWS=$((rows + 2))
  for i in "${!left_lines[@]}"; do
    printf ' %b  %b\n' "${left_lines[$i]}" "${right_lines[$i]}"
  done
}

show_full_dns_record_for_copy() {
  local type="$1"
  local name="$2"
  local ttl="$3"
  local value="$4"

  echo
  echo "Полная DNS-запись"
  echo "Выделите имя или значение мышью и скопируйте в буфер обмена."
  echo
  printf 'Тип: %b%s%b\n' "$GREEN" "$type" "$WHITE"
  printf 'TTL: %b%s%b\n\n' "$YELLOW" "$ttl" "$WHITE"
  printf 'Имя записи:\n%b%s%b\n\n' "$GREEN" "$name" "$WHITE"
  printf 'Значение записи:\n%b%s%b\n\n' "$YELLOW" "$value" "$WHITE"
  vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
}

show_record_info() {
  local index="$1"
  local value_index="$2"
  local type="${DNS_RECORD_TYPES[$index]}"
  local name="${DNS_RECORD_NAMES[$index]}"
  local display_name
  local value
  local result_dir=""
  local start_ms
  local deadline_ms
  local now_ms
  local pending
  local changed
  local choice
  local old_rendered_rows=0
  local i
  local -a resolver_addresses=("" "8.8.8.8" "9.9.9.9")
  local -a resolver_states=(pending pending pending)
  local -a resolver_pids=()
  local -a provider_content=()
  local -a public_content=()

  value="$(jq -r --argjson index "$value_index" '.[$index]' <<< "${DNS_RECORD_VALUES[$index]}")"
  display_name="$(truncate_dns_info_value "$name" 44)"
  provider_content=(
    "Тип: ${type}"
    "Имя: ${name}"
    "TTL: ${DNS_RECORD_TTLS[$index]}"
    "Значение: ${value}"
  )

  install_dns_record_info_traps

  if [[ "$type" == "ALIAS" || "$type" == "WR" ]]; then
    resolver_states=(unsupported unsupported unsupported)
  elif ! command -v dig >/dev/null 2>&1; then
    resolver_states=(timeout timeout timeout)
  elif result_dir="$(mktemp -d)"; then
    DNS_RECORD_INFO_RESULT_DIR="$result_dir"
    for i in "${!resolver_addresses[@]}"; do
      query_public_dns_resolver_to_file "$name" "$type" "${resolver_addresses[$i]}" "${result_dir}/${i}.done" &
      resolver_pids[$i]=$!
      DNS_RECORD_INFO_QUERY_PIDS+=("${resolver_pids[$i]}")
    done
  else
    resolver_states=(timeout timeout timeout)
  fi

  clear
  DNS_RECORD_INFO_RENDERED_ROWS=0
  build_multi_resolver_public_content public_content "$type" "$display_name" "$value" "$result_dir" resolver_states
  print_record_info_boxes provider_content public_content

  if ((${#resolver_pids[@]} > 0)); then
    start_ms="$(get_time_ms)"
    [[ "$start_ms" =~ ^[0-9]+$ ]] || start_ms=0
    deadline_ms=$((start_ms + 7000))

    while true; do
      changed=0
      pending=0
      for i in "${!resolver_states[@]}"; do
        if [[ "${resolver_states[$i]}" == "pending" ]]; then
          if [[ -f "${result_dir}/${i}.done" ]]; then
            resolver_states[$i]="done"
            changed=1
          else
            pending=$((pending + 1))
          fi
        fi
      done

      if ((changed)); then
        old_rendered_rows="$DNS_RECORD_INFO_RENDERED_ROWS"
        build_multi_resolver_public_content public_content "$type" "$display_name" "$value" "$result_dir" resolver_states
        clear_dns_record_info_area "$old_rendered_rows"
        print_record_info_boxes provider_content public_content
      fi
      ((pending > 0)) || break

      now_ms="$(get_time_ms)"
      [[ "$now_ms" =~ ^[0-9]+$ ]] || now_ms="$deadline_ms"
      if ((now_ms >= deadline_ms)); then
        for i in "${!resolver_states[@]}"; do
          if [[ "${resolver_states[$i]}" == "pending" ]]; then
            resolver_states[$i]="timeout"
            terminate_dns_record_info_query_tree "${resolver_pids[$i]}"
          fi
        done
        old_rendered_rows="$DNS_RECORD_INFO_RENDERED_ROWS"
        build_multi_resolver_public_content public_content "$type" "$display_name" "$value" "$result_dir" resolver_states
        clear_dns_record_info_area "$old_rendered_rows"
        print_record_info_boxes provider_content public_content
        break
      fi
      sleep 0.05
    done

  fi

  cleanup_dns_record_info_queries
  restore_dns_record_info_traps
  vertical_menu "current" 2 0 30 "Нажмите Enter" "Показать запись для копирования в буфер обмена"
  choice=$?
  if ((choice == 1)); then
    show_full_dns_record_for_copy "$type" "$name" "${DNS_RECORD_TTLS[$index]}" "$value"
  fi
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
  local can_edit=1
  local can_delete=1

  if [[ "$type" == "NS" || "$type" == "SOA" ]]; then
    can_edit=0
    can_delete=0
  elif declare -F provider_import_type_supported >/dev/null && ! provider_import_type_supported "$type"; then
    can_edit=0
  fi

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
    if [[ "$type" == "A" && "$has_server_ip" -eq 1 && "$can_edit" -eq 1 ]]; then
      vertical_menu "$action_menu_y" "$LAST_DNS_MENU_ACTION_X" 0 24 "Инфо: TTL ${DNS_RECORD_TTLS[$index]}" "Установить ${server_ip}" "Редактировать" "Удалить" "Назад"
    elif ((can_edit)); then
      vertical_menu "$action_menu_y" "$LAST_DNS_MENU_ACTION_X" 0 20 "Инфо: TTL ${DNS_RECORD_TTLS[$index]}" "Редактировать" "Удалить" "Назад"
    elif ((can_delete)); then
      vertical_menu "$action_menu_y" "$LAST_DNS_MENU_ACTION_X" 0 20 "Инфо: TTL ${DNS_RECORD_TTLS[$index]}" "Удалить" "Назад"
    else
      vertical_menu "$action_menu_y" "$LAST_DNS_MENU_ACTION_X" 0 20 "Инфо: TTL ${DNS_RECORD_TTLS[$index]}" "Назад"
    fi
    choice=$?
    if [[ "$type" == "A" && "$has_server_ip" -eq 1 && "$can_edit" -eq 1 ]]; then
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
    elif ((can_edit)); then
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
    elif ((can_delete)); then
      case "$choice" in
        0)
          show_record_info "$index" "$value_index"
          return
          ;;
        1)
          delete_record "$index" "$value_index" "$value_ref"
          return
          ;;
        2 | 255)
          return
          ;;
      esac
    else
      case "$choice" in
        0)
          show_record_info "$index" "$value_index"
          return
          ;;
        1 | 255)
          return
          ;;
      esac
    fi
  done
}

import_zone_file_menu() {
  local import_dir
  local import_parent_dir
  local import_domain_dir
  local choice
  local zone_file
  local existing_records
  local import_mode
  local zone_file_origin
  local target_origin
  local rewrite_origin=0
  local parse_status
  local type
  local ttl
  local name
  local records_json
  local record
  local total_records=0
  local current_record=0
  local values_count
  local imported=0
  local failed=0
  local records_tmp
  local -a import_files=()
  local -a import_labels=()
  local candidate
  local candidate_with_mtime

  clear
  echo -e "Импорт DNS-зоны из файла для сайта ${GREEN}${DNS_DOMAIN}${WHITE}"
  echo -e "DNS-зона: ${GREEN}${DNS_ZONE_NAME}${WHITE}"
  echo -e "Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}"
  echo
  import_dir="$(dns_config_dir "$DNS_DOMAIN")"
  import_parent_dir="${import_dir%/*}"
  import_domain_dir="${import_dir##*/}"
  echo "Файлы DNS-зоны для импорта ожидаются в папке DNS-настроек домена:"
  echo -e "${import_parent_dir}/${YELLOW}${import_domain_dir}${WHITE}"
  echo

  while IFS= read -r -d '' candidate_with_mtime; do
    candidate="${candidate_with_mtime#* }"
    import_files+=("$candidate")
    import_labels+=("${candidate##*/}")
  done < <(
    find "$import_dir" -maxdepth 1 -type f \
      \( -name '*.txt' -o -name '*.zone' -o -name '*.bind' -o -name '*.dns' \) \
      -printf '%T@ %p\0' | LC_ALL=C sort -z -nr
  )

  if ((${#import_files[@]} == 0)); then
    echo "Файлы DNS-зоны для импорта не найдены."
    echo -e "Поместите файл в: ${import_parent_dir}/${YELLOW}${import_domain_dir}${WHITE}"
    wait_for_enter
    return
  fi

  import_labels+=("Отмена")
  echo "Выберите файл DNS-зоны:"
  vertical_menu "current" 2 0 52 "${import_labels[@]}"
  choice=$?
  if ((choice == 255 || choice >= ${#import_labels[@]} - 1)); then
    return
  fi
  zone_file="${import_files[$choice]}"

  zone_file_origin="$(zonefile_detect_origin "$zone_file" "${DNS_ZONE_NAME%.}")" || {
    wait_for_enter
    return
  }
  target_origin="$(dns_fqdn "$DNS_ZONE_NAME")"
  if [[ "$zone_file_origin" != "$target_origin" ]]; then
    echo
    echo -e "В файле DNS-зоны указан origin ${YELLOW}${zone_file_origin}${WHITE}"
    echo -e "Текущая DNS-зона: ${GREEN}${target_origin}${WHITE}"
    echo "При импорте в другую зону можно заменить origin на текущую DNS-зону."
    vertical_menu "current" 2 0 44 "Отмена" "Заменить origin на текущую зону"
    choice=$?
    if ((choice != 1)); then
      return
    fi
    rewrite_origin=1
  fi

  records_tmp="$(mktemp)" || {
    echo -e "Не удалось создать временный файл для импорта." >&2
    wait_for_enter
    return
  }
  if ((rewrite_origin)); then
    ZONEFILE_REWRITE_SOURCE_ORIGIN="$zone_file_origin"
    ZONEFILE_REWRITE_TARGET_ORIGIN="$target_origin"
    parse_zonefile "$zone_file" "${DNS_ZONE_NAME%.}" > "$records_tmp"
    parse_status=$?
    ZONEFILE_REWRITE_SOURCE_ORIGIN=""
    ZONEFILE_REWRITE_TARGET_ORIGIN=""
  else
    parse_zonefile "$zone_file" "${DNS_ZONE_NAME%.}" > "$records_tmp"
    parse_status=$?
  fi
  if ((parse_status != 0)); then
    rm -f "$records_tmp"
    wait_for_enter
    return
  fi
  if ! validate_provider_import_types "$records_tmp"; then
    rm -f "$records_tmp"
    wait_for_enter
    return
  fi
  while IFS=$'\t' read -r type ttl name records_json; do
    [[ -n "$type" ]] || continue
    values_count="$(jq -r 'length' <<< "$records_json" 2>/dev/null)"
    [[ "$values_count" =~ ^[0-9]+$ ]] || values_count=0
    total_records=$((total_records + values_count))
  done < "$records_tmp"
  if ((total_records == 0)); then
    rm -f "$records_tmp"
    echo "В выбранном файле DNS-зоны нет записей для импорта."
    wait_for_enter
    return
  fi

  load_records_cache || {
    rm -f "$records_tmp"
    echo -e "Не удалось получить текущие DNS-записи перед импортом." >&2
    wait_for_enter
    return
  }

  existing_records="$(dns_user_records_count)"
  if ((existing_records > 0)); then
    echo
    echo -e "В текущей зоне найдено записей: ${YELLOW}${existing_records}${WHITE}"
    vertical_menu "current" 2 0 44 "Добавить к существующим" "Удалить текущие записи и импортировать" "Отмена"
    choice=$?
    case "$choice" in
      0)
        import_mode="append"
        ;;
      1)
        import_mode="replace"
        ;;
      *)
        rm -f "$records_tmp"
        return
        ;;
    esac

    if [[ "$import_mode" == "append" ]] && ! validate_provider_append_limits "$records_tmp"; then
      rm -f "$records_tmp"
      wait_for_enter
      return
    fi

    if [[ "$import_mode" == "replace" ]]; then
      echo
      echo "Перед импортом будут удалены текущие DNS-записи, кроме NS/SOA."
      echo "Если удаление или импорт прервется ошибкой, зона может остаться частично измененной."
      vertical_menu "current" 2 0 32 "Отмена" "Удалить и импортировать"
      choice=$?
      if ((choice != 1)); then
        rm -f "$records_tmp"
        return
      fi

      echo
      echo "Удаляем текущие DNS-записи..."
      if ! delete_dns_user_records; then
        rm -f "$records_tmp"
        wait_for_enter
        return
      fi
    fi
  fi

  while IFS=$'\t' read -r type ttl name records_json; do
    [[ -n "$type" ]] || continue
    while IFS= read -r record; do
      [[ -n "$record" || "$type" == "TXT" ]] || continue
      current_record=$((current_record + 1))
      printf '%b' "[${YELLOW}${current_record}${WHITE}/${YELLOW}${total_records}${WHITE}] ${GREEN}${type}${WHITE} ${name} "
      if provider_add_record_value "$DNS_ZONE_ID" "$name" "$type" "$ttl" "$record"; then
        imported=$((imported + 1))
        echo -e "${GREEN}OK${WHITE}"
      else
        failed=$((failed + 1))
        echo
        echo -e "${RED}Ошибка${WHITE}"
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

dns_export_record_name() {
  local name="$1"
  local origin="$2"
  local suffix=".$origin"

  if [[ "$name" == "$origin" ]]; then
    printf '@'
  elif [[ "$name" == *"$suffix" ]]; then
    printf '%s' "${name%"$suffix"}"
  else
    printf '%s' "$name"
  fi
}

dns_export_absolute_name() {
  local name="$1"

  if [[ "$name" == *"." ]]; then
    printf '%s' "$name"
  else
    printf '%s.' "$name"
  fi
}

dns_export_txt_value() {
  local value="$1"
  local remaining="$value"
  local chunk=""
  local char
  local char_bytes
  local chunk_bytes=0
  local first_chunk=1

  if [[ -z "$remaining" ]]; then
    printf '""'
    return
  fi

  while [[ -n "$remaining" ]]; do
    char="${remaining:0:1}"
    remaining="${remaining:1}"
    char_bytes="$(LC_ALL=C; printf '%s' "${#char}")"
    if ((chunk_bytes + char_bytes > 255)) && [[ -n "$chunk" ]]; then
      ((first_chunk)) || printf ' '
      chunk="${chunk//\\/\\\\}"
      chunk="${chunk//\"/\\\"}"
      printf '"%s"' "$chunk"
      first_chunk=0
      chunk=""
      chunk_bytes=0
    fi
    chunk+="$char"
    chunk_bytes=$((chunk_bytes + char_bytes))
  done

  ((first_chunk)) || printf ' '
  chunk="${chunk//\\/\\\\}"
  chunk="${chunk//\"/\\\"}"
  printf '"%s"' "$chunk"
}

dns_export_record_value() {
  local type="$1"
  local value="$2"
  local first
  local second
  local third
  local target
  local params

  case "$type" in
    TXT)
      dns_export_txt_value "$value"
      ;;
    ALIAS | CNAME | DNAME | NS | PTR)
      dns_export_absolute_name "$value"
      ;;
    MX)
      if [[ "$value" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
        first="${BASH_REMATCH[1]}"
        target="${BASH_REMATCH[2]}"
        printf '%s %s' "$first" "$(dns_export_absolute_name "$target")"
      else
        printf '%s' "$value"
      fi
      ;;
    SRV)
      if [[ "$value" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
        first="${BASH_REMATCH[1]}"
        second="${BASH_REMATCH[2]}"
        third="${BASH_REMATCH[3]}"
        target="${BASH_REMATCH[4]}"
        printf '%s %s %s %s' "$first" "$second" "$third" "$(dns_export_absolute_name "$target")"
      else
        printf '%s' "$value"
      fi
      ;;
    HTTPS | SVCB)
      if [[ "$value" =~ ^([^[:space:]]+)[[:space:]]+([^[:space:]]+)([[:space:]]+.*)?$ ]]; then
        first="${BASH_REMATCH[1]}"
        target="${BASH_REMATCH[2]}"
        params="${BASH_REMATCH[3]}"
        printf '%s %s%s' "$first" "$(dns_export_absolute_name "$target")" "$params"
      else
        printf '%s' "$value"
      fi
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

export_zone_file_menu() {
  local export_dir
  local export_parent_dir
  local export_domain_dir
  local export_file
  local timestamp
  local origin
  local i
  local type
  local ttl
  local name
  local export_name
  local value
  local export_value
  local exported=0
  local skipped=0
  local values_count
  local existing_type
  local found
  local -a unsupported_types=()

  clear
  echo -e "Экспорт DNS-зоны в файл для сайта ${GREEN}${DNS_DOMAIN}${WHITE}"
  echo -e "DNS-зона: ${GREEN}${DNS_ZONE_NAME}${WHITE}"
  echo -e "Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}"
  echo

  load_records_cache || {
    echo -e "Не удалось получить текущие DNS-записи." >&2
    wait_for_enter
    return
  }

  export_dir="$(dns_config_dir "$DNS_DOMAIN")"
  export_parent_dir="${export_dir%/*}"
  export_domain_dir="${export_dir##*/}"
  mkdir -p "$export_dir" || {
    echo -e "Не удалось создать папку экспорта: ${export_parent_dir}/${YELLOW}${export_domain_dir}${WHITE}" >&2
    wait_for_enter
    return
  }

  timestamp="$(date +%Y%m%d-%H%M%S)"
  export_file="${export_dir}/${DNS_ZONE_NAME%.}-export-${timestamp}.txt"
  origin="$(dns_fqdn "$DNS_ZONE_NAME")"

  {
    printf '$ORIGIN %s\n' "$origin"
    printf '$TTL %s\n' "${DNS_DEFAULT_TTL:-3600}"
    printf '\n'

    for i in "${!DNS_RECORD_TYPES[@]}"; do
      type="${DNS_RECORD_TYPES[$i]}"
      [[ "$type" != "SOA" ]] || continue
      ttl="${DNS_RECORD_TTLS[$i]:-${DNS_DEFAULT_TTL:-3600}}"
      name="${DNS_RECORD_NAMES[$i]}"
      export_name="$(dns_export_record_name "$name" "$origin")"

      if declare -F provider_export_type_supported >/dev/null && ! provider_export_type_supported "$type"; then
        found=0
        for existing_type in "${unsupported_types[@]}"; do
          if [[ "$existing_type" == "$type" ]]; then
            found=1
            break
          fi
        done
        ((found)) || unsupported_types+=("$type")
        values_count="$(jq -r 'length' <<< "${DNS_RECORD_VALUES[$i]}" 2>/dev/null)"
        [[ "$values_count" =~ ^[0-9]+$ ]] || values_count=1
        skipped=$((skipped + values_count))
        continue
      fi

      while IFS= read -r value; do
        [[ -n "$value" || "$type" == "TXT" ]] || continue
        export_value="$(dns_export_record_value "$type" "$value")"
        printf '%s %s IN %s %s\n' "$export_name" "$ttl" "$type" "$export_value"
        exported=$((exported + 1))
      done < <(jq -r '.[]' <<< "${DNS_RECORD_VALUES[$i]}")
    done
  } > "$export_file" || {
    echo -e "Не удалось сохранить export: ${YELLOW}${export_file}${WHITE}" >&2
    wait_for_enter
    return
  }

  chmod 600 "$export_file" 2>/dev/null || true

  if ((exported == 0)); then
    rm -f "$export_file"
    if ((skipped > 0)); then
      echo "Файл не создан: в зоне нет записей поддерживаемых типов для экспорта."
    else
      echo "В зоне нет записей для экспорта."
    fi
  else
    echo -e "Экспортировано записей: ${GREEN}${exported}${WHITE}"
    echo "Файл сохранен в папке DNS-настроек домена:"
    echo -e "${export_parent_dir}/${YELLOW}${export_domain_dir}${WHITE}/${YELLOW}${export_file##*/}${WHITE}"
  fi
  if ((skipped > 0)); then
    echo
    if ((exported > 0)); then
      echo -e "${YELLOW}Файл не является полной копией DNS-зоны:${WHITE}"
    fi
    echo -e "Записи типов ${YELLOW}${unsupported_types[*]}${WHITE} не экспортированы, поскольку их формат не поддерживается."
  fi
  wait_for_enter
}

dns_user_records_count() {
  local i
  local type
  local values_count
  local total=0

  for i in "${!DNS_RECORD_TYPES[@]}"; do
    type="${DNS_RECORD_TYPES[$i]}"
    [[ "$type" != "SOA" && "$type" != "NS" ]] || continue
    values_count="$(jq -r 'length' <<< "${DNS_RECORD_VALUES[$i]}" 2>/dev/null)"
    [[ "$values_count" =~ ^[0-9]+$ ]] || values_count=1
    total=$((total + values_count))
  done

  printf '%s' "$total"
}

delete_dns_user_records() {
  local i
  local type
  local name
  local deleted=0
  local failed=0
  local total=0
  local current=0

  for i in "${!DNS_RECORD_TYPES[@]}"; do
    type="${DNS_RECORD_TYPES[$i]}"
    [[ "$type" != "SOA" && "$type" != "NS" ]] || continue
    total=$((total + 1))
  done

  for i in "${!DNS_RECORD_TYPES[@]}"; do
    type="${DNS_RECORD_TYPES[$i]}"
    [[ "$type" != "SOA" && "$type" != "NS" ]] || continue
    name="${DNS_RECORD_NAMES[$i]}"
    current=$((current + 1))
    printf '%b' "[${YELLOW}${current}${WHITE}/${YELLOW}${total}${WHITE}] Удаляем ${GREEN}${type}${WHITE} ${name} "
    if provider_delete_rrset "$DNS_ZONE_ID" "$name" "$type" "${DNS_RECORD_REFS[$i]}"; then
      deleted=$((deleted + 1))
      echo -e "${GREEN}OK${WHITE}"
    else
      failed=$((failed + 1))
      echo
      echo -e "${RED}Ошибка${WHITE}"
      echo -e "Не удалось удалить ${YELLOW}${type} ${name}${WHITE}." >&2
    fi
  done

  echo -e "Удалено групп записей: ${GREEN}${deleted}${WHITE}"
  if ((deleted > 0)); then
    invalidate_records_cache
  fi
  if ((failed > 0)); then
    echo -e "Ошибок удаления: ${RED}${failed}${WHITE}" >&2
    return 1
  fi
}

clear_dns_zone_menu() {
  local existing_records
  local choice

  clear
  echo -e "Очистка DNS-зоны ${GREEN}${DNS_ZONE_NAME}${WHITE}"
  echo -e "Сайт: ${GREEN}${DNS_DOMAIN}${WHITE}"
  echo -e "Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}"
  echo

  load_records_cache || {
    echo -e "Не удалось получить текущие DNS-записи." >&2
    wait_for_enter
    return
  }

  existing_records="$(dns_user_records_count)"
  if ((existing_records == 0)); then
    echo "В зоне нет записей для удаления."
    wait_for_enter
    return
  fi

  echo -e "Будут удалены все DNS-записи, кроме ${YELLOW}NS/SOA${WHITE}."
  echo -e "Количество записей к удалению: ${YELLOW}${existing_records}${WHITE}"
  echo "Если удаление прервется ошибкой, зона может остаться частично измененной."
  echo
  vertical_menu "current" 2 0 22 "Отмена" "Очистить зону"
  choice=$?
  if ((choice != 1)); then
    echo "Очистка зоны отменена."
    wait_for_enter
    return
  fi

  echo
  echo "Удаляем DNS-записи..."
  delete_dns_user_records
  wait_for_enter
}

dns_domain_menu() {
  local domain="$1"
  local choice
  local change_status
  local menu_height
  local menu_used_rows

  DNS_DOMAIN="$domain"
  require_command curl
  require_command jq

  while ! load_domain_config "$domain"; do
    show_connect_provider_menu "$domain"
  done

  load_provider "$DNS_PROVIDER"

  while true; do
    if ((DNS_PROVIDER_CONNECTION_READY)); then
      DNS_PROVIDER_CONNECTION_READY=0
      break
    fi
    show_dns_status "Подключаемся к DNS-провайдеру..."
    if provider_prepare; then
      break
    fi

    echo
    vertical_menu "current" 2 0 42 "Повторить" "Сменить DNS-провайдера" "Удалить подключение к DNS-провайдеру" "Выйти"
    choice=$?
    case "$choice" in
      0)
        continue
        ;;
      1)
        change_dns_provider "$domain" 0
        change_status=$?
        if ((change_status == 0)); then
          break
        fi
        continue
        ;;
      2)
        if delete_dns_provider_connection "$domain"; then
          return
        fi
        continue
        ;;
      *)
        return
        ;;
    esac
  done

  while true; do
    clear
    echo -e "Сайт: ${GREEN}${DNS_DOMAIN}${WHITE}"
    echo -e "DNS-зона: ${GREEN}${DNS_ZONE_NAME}${WHITE}"
    echo -e "Provider: ${YELLOW}${DNS_PROVIDER}${WHITE}"
    echo

    if [[ "$DNS_RECORD_CACHE_LOADED" -eq 0 ]]; then
      show_dns_status "Получаем DNS-записи..."
    fi
    if ! load_records_cache; then
      echo -e "Не удалось получить список DNS-записей." >&2
      echo
      vertical_menu "current" 2 0 42 \
        "Повторить" \
        "Сменить DNS-провайдера" \
        "Удалить подключение к DNS-провайдеру" \
        "Выйти"
      choice=$?
      if ((choice == 0)); then
        invalidate_records_cache
        continue
      elif ((choice == 1)); then
        change_dns_provider "$domain"
        continue
      elif ((choice == 2)); then
        if delete_dns_provider_connection "$domain"; then
          return
        fi
        continue
      fi
      return
    fi

    clear
    print_dns_zone_summary
    menu_used_rows="$DNS_STATUS_SUMMARY_ROWS"
    if ((DNS_RECORD_MENU_TRUNCATED)); then
      echo -e "Внимание: показаны первые ${YELLOW}${DNS_RECORD_MENU_LIMIT}${WHITE} строк DNS-записей из ${YELLOW}${DNS_RECORD_MENU_TOTAL_ROWS}${WHITE}; список обрезан."
      echo
      menu_used_rows=$((menu_used_rows + 2))
    fi

    menu_height="$(dns_menu_available_height "$menu_used_rows")"
    vertical_menu "current_noclear" 2 "$menu_height" 42 "default=${DNS_MENU_DEFAULT_INDEX}" "Создать запись" "${DNS_RECORD_LABELS[@]}" "Сменить DNS-провайдера" "Удалить подключение к DNS-провайдеру" "Импорт DNS-зоны из файла" "Экспорт DNS-зоны в файл" "Очистить зону" "Выйти"
    choice=$?
    LAST_DNS_MENU_Y="$VERTICAL_MENU_LAST_Y"
    LAST_DNS_MENU_ACTION_X="$(vertical_menu_next_x 2)"
    LAST_DNS_MENU_RIGHT_X="$VERTICAL_MENU_LAST_RIGHT_X"
    LAST_DNS_SELECTED_ROW=$((LAST_DNS_MENU_Y + VERTICAL_MENU_LAST_VISIBLE_SELECTED + 1))

    if ((choice == 255 || choice == ${#DNS_RECORD_LABELS[@]} + 6)); then
      exit 0
    elif ((choice == 0)); then
      DNS_MENU_DEFAULT_INDEX=0
      create_record
    elif ((choice == ${#DNS_RECORD_LABELS[@]} + 1)); then
      DNS_MENU_DEFAULT_INDEX="$choice"
      change_dns_provider "$domain"
    elif ((choice == ${#DNS_RECORD_LABELS[@]} + 2)); then
      DNS_MENU_DEFAULT_INDEX="$choice"
      if delete_dns_provider_connection "$domain"; then
        return
      fi
    elif ((choice == ${#DNS_RECORD_LABELS[@]} + 3)); then
      DNS_MENU_DEFAULT_INDEX="$choice"
      import_zone_file_menu
    elif ((choice == ${#DNS_RECORD_LABELS[@]} + 4)); then
      DNS_MENU_DEFAULT_INDEX="$choice"
      export_zone_file_menu
    elif ((choice == ${#DNS_RECORD_LABELS[@]} + 5)); then
      DNS_MENU_DEFAULT_INDEX="$choice"
      clear_dns_zone_menu
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
  if ! parse_zonefile "$zone_file" "${DNS_ZONE_NAME%.}" > "$records_tmp"; then
    rm -f "$records_tmp"
    exit 1
  fi
  if ! validate_provider_import_types "$records_tmp"; then
    rm -f "$records_tmp"
    exit 1
  fi
  if declare -F provider_import_rrset_limit >/dev/null; then
    load_records_cache || {
      rm -f "$records_tmp"
      exit 1
    }
    if ! validate_provider_append_limits "$records_tmp"; then
      rm -f "$records_tmp"
      exit 1
    fi
  fi

  while IFS=$'\t' read -r type ttl name records_json; do
    [[ -n "$type" ]] || continue
    while IFS= read -r record; do
      [[ -n "$record" || "$type" == "TXT" ]] || continue
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
