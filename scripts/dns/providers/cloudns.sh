#!/usr/bin/env bash

CLOUDNS_API_BASE="${CLOUDNS_API_BASE:-https://api.cloudns.net}"

provider_setup_config() {
  local domain="$1"
  local auth_mode
  local server_ip

  server_ip="$(server_ipv4)"
  if [[ "$server_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo -e "IP адрес вашего сервера: ${GREEN}${server_ip}${WHITE}"
  else
    echo -e "IP адрес вашего сервера: ${YELLOW}не удалось определить${WHITE}"
  fi
  echo

  echo "Выберите тип API-доступа ClouDNS:"
  vertical_menu "current" 2 0 36 "Пользователь API (auth-id)" "Sub-user API (sub-auth-id)" "Sub-user API (sub-auth-user)" "Отмена"
  auth_mode=$?
  case "$auth_mode" in
    0)
      rish_read_input CLOUDNS_AUTH_ID "auth-id (Enter - отмена): "
      [[ -n "$CLOUDNS_AUTH_ID" ]] || {
        echo "Подключение отменено."
        return 1
      }
      CLOUDNS_SUB_AUTH_ID=""
      CLOUDNS_SUB_AUTH_USER=""
      ;;
    1)
      rish_read_input CLOUDNS_SUB_AUTH_ID "sub-auth-id (Enter - отмена): "
      [[ -n "$CLOUDNS_SUB_AUTH_ID" ]] || {
        echo "Подключение отменено."
        return 1
      }
      CLOUDNS_AUTH_ID=""
      CLOUDNS_SUB_AUTH_USER=""
      ;;
    2)
      rish_read_input CLOUDNS_SUB_AUTH_USER "sub-auth-user (Enter - отмена): "
      [[ -n "$CLOUDNS_SUB_AUTH_USER" ]] || {
        echo "Подключение отменено."
        return 1
      }
      CLOUDNS_AUTH_ID=""
      CLOUDNS_SUB_AUTH_ID=""
      ;;
    *)
      return 1
      ;;
  esac

  rish_read_visible_secret CLOUDNS_AUTH_PASSWORD "Пароль API (Enter - отмена): "
  [[ -n "$CLOUDNS_AUTH_PASSWORD" ]] || {
    echo "Подключение отменено."
    return 1
  }

  DNS_ZONE_NAME="${domain%.}"
}

provider_write_config() {
  echo "CLOUDNS_AUTH_ID=$(shell_quote "${CLOUDNS_AUTH_ID:-}")"
  echo "CLOUDNS_SUB_AUTH_ID=$(shell_quote "${CLOUDNS_SUB_AUTH_ID:-}")"
  echo "CLOUDNS_SUB_AUTH_USER=$(shell_quote "${CLOUDNS_SUB_AUTH_USER:-}")"
  echo "CLOUDNS_AUTH_PASSWORD=$(shell_quote "${CLOUDNS_AUTH_PASSWORD:-}")"
}

provider_zone_ready() {
  [[ -n "${DNS_ZONE_NAME:-}" ]]
}

provider_check_config() {
  local missing=0

  if [[ -z "${CLOUDNS_AUTH_PASSWORD:-}" ]]; then
    echo -e "Не задан ${YELLOW}CLOUDNS_AUTH_PASSWORD${WHITE}." >&2
    missing=1
  fi
  if [[ -z "${CLOUDNS_AUTH_ID:-}" && -z "${CLOUDNS_SUB_AUTH_ID:-}" && -z "${CLOUDNS_SUB_AUTH_USER:-}" ]]; then
    echo -e "Не задан ни один идентификатор ClouDNS API: ${YELLOW}CLOUDNS_AUTH_ID${WHITE}, ${YELLOW}CLOUDNS_SUB_AUTH_ID${WHITE} или ${YELLOW}CLOUDNS_SUB_AUTH_USER${WHITE}." >&2
    missing=1
  fi

  ((missing == 0))
}

provider_auth() {
  provider_check_config
}

cloudns_auth_args() {
  if [[ -n "${CLOUDNS_AUTH_ID:-}" ]]; then
    printf '%s\n' --data-urlencode "auth-id=${CLOUDNS_AUTH_ID}"
  elif [[ -n "${CLOUDNS_SUB_AUTH_ID:-}" ]]; then
    printf '%s\n' --data-urlencode "sub-auth-id=${CLOUDNS_SUB_AUTH_ID}"
  else
    printf '%s\n' --data-urlencode "sub-auth-user=${CLOUDNS_SUB_AUTH_USER}"
  fi
  printf '%s\n' --data-urlencode "auth-password=${CLOUDNS_AUTH_PASSWORD}"
}

cloudns_api() {
  local endpoint="$1"
  shift
  local response
  local status
  local description
  local -a curl_args
  local auth_arg

  curl_args=(-fsS -G)
  while IFS= read -r auth_arg; do
    curl_args+=("$auth_arg")
  done < <(cloudns_auth_args)
  while (($# > 0)); do
    curl_args+=(--data-urlencode "$1")
    shift
  done

  response="$(curl "${curl_args[@]}" "${CLOUDNS_API_BASE}/${endpoint}.json")" || {
    echo -e "Не удалось выполнить запрос к ${YELLOW}ClouDNS API${WHITE}." >&2
    return 1
  }

  status="$(jq -r '.status // empty' <<< "$response" 2>/dev/null)"
  if [[ "$status" == "Failed" ]]; then
    description="$(jq -r '.statusDescription // "unknown error"' <<< "$response")"
    echo -e "${YELLOW}ClouDNS API${WHITE}: ${description}" >&2
    return 1
  fi

  printf '%s' "$response"
}

provider_find_zone() {
  local domain="$1"
  local zone_name="${domain%.}"

  cloudns_api "dns/records" "domain-name=${zone_name}" "rows-per-page=10" "page=1" >/dev/null || {
    DNS_PROVIDER_ERROR="zone_not_found"
    echo -e "DNS-зона ${YELLOW}${zone_name}${WHITE} в ClouDNS не найдена или недоступна." >&2
    return 1
  }

  DNS_ZONE_ID=""
  DNS_ZONE_NAME="$zone_name"
  printf '\t%s\n' "$DNS_ZONE_NAME"
}

cloudns_records_json() {
  local zone_name="$1"

  cloudns_api "dns/records" "domain-name=${zone_name}" "rows-per-page=100" "page=1"
}

provider_list_records() {
  local zone_id="$1"
  local zone_name="${DNS_ZONE_NAME:-${DNS_DOMAIN%.}}"
  local records_json

  records_json="$(cloudns_records_json "$zone_name")" || return 1
  jq -r --arg zone "$(dns_fqdn "$zone_name")" '
    def fqdn($host):
      if $host == "" or $host == "@" then $zone
      elif ($host | endswith(".")) then $host
      else "\($host).\($zone)"
      end;
    def user_record:
      if .type == "MX" and ((.priority // "") | tostring) != "" and ((.record // "") | test("^[0-9]+[[:space:]]") | not) then
        "\((.priority // "") | tostring) \(.record // "")"
      else
        (.record // "")
      end;

    [
      to_entries[]
      | select(.value | type == "object")
      | {
          id: (.value.id // .key),
          type: (.value.type | ascii_upcase),
          ttl: ((.value.ttl // "3600") | tostring),
          name: fqdn(.value.host // "@"),
          record: (.value | {type: (.type | ascii_upcase), record, priority} | user_record)
        }
      | select(.type != "" and .record != "")
      | select(.type != "SOA")
    ]
    | group_by(.name + "\u0000" + .type)
    | .[]
    | "\(.[0].type)\t\(.[0].ttl)\t\(.[0].name)\t\([.[].record] | tojson)\t\([.[].id] | tojson)"
  ' <<< "$records_json"
}

cloudns_host_from_name() {
  local name="$1"
  local zone_name="${DNS_ZONE_NAME:-${DNS_DOMAIN%.}}"
  local zone_fqdn

  zone_fqdn="$(dns_fqdn "$zone_name")"
  if [[ "$name" == "$zone_fqdn" || "${name%.}" == "$zone_name" ]]; then
    return
  fi

  name="${name%.}"
  printf '%s' "${name%.$zone_name}"
}

cloudns_split_record() {
  local type="$1"
  local record="$2"
  local priority=""

  if [[ "$type" == "MX" && "$record" == *" "* ]]; then
    priority="${record%% *}"
    record="${record#* }"
  fi

  printf '%s\t%s\n' "$record" "$priority"
}

cloudns_add_single_record() {
  local name="$1"
  local type="$2"
  local ttl="$3"
  local record="$4"
  local host
  local record_value
  local priority
  local split
  local -a params

  host="$(cloudns_host_from_name "$name")"
  split="$(cloudns_split_record "$type" "$record")"
  record_value="${split%%$'\t'*}"
  priority="${split#*$'\t'}"

  params=(
    "domain-name=${DNS_ZONE_NAME:-${DNS_DOMAIN%.}}"
    "record-type=${type}"
    "host=${host}"
    "record=${record_value}"
    "ttl=${ttl}"
  )
  if [[ -n "$priority" && "$priority" != "$record_value" ]]; then
    params+=("priority=${priority}")
  fi

  cloudns_api "dns/add-record" "${params[@]}" >/dev/null
}

cloudns_modify_single_record() {
  local record_id="$1"
  local name="$2"
  local type="$3"
  local ttl="$4"
  local record="$5"
  local host
  local record_value
  local priority
  local split
  local -a params

  host="$(cloudns_host_from_name "$name")"
  split="$(cloudns_split_record "$type" "$record")"
  record_value="${split%%$'\t'*}"
  priority="${split#*$'\t'}"

  params=(
    "domain-name=${DNS_ZONE_NAME:-${DNS_DOMAIN%.}}"
    "record-id=${record_id}"
    "host=${host}"
    "record=${record_value}"
    "ttl=${ttl}"
  )
  if [[ -n "$priority" && "$priority" != "$record_value" ]]; then
    params+=("priority=${priority}")
  fi

  cloudns_api "dns/mod-record" "${params[@]}" >/dev/null
}

provider_create_record() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local ttl="$4"
  local records_json="$5"
  local record

  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    cloudns_add_single_record "$name" "$type" "$ttl" "$record" || return 1
  done < <(jq -r '.[]' <<< "$records_json")
}

provider_add_record_value() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local ttl="$4"
  local value="$5"

  cloudns_add_single_record "$name" "$type" "$ttl" "$value"
}

cloudns_find_record_ids() {
  local name="$1"
  local type="$2"
  local zone_name="${DNS_ZONE_NAME:-${DNS_DOMAIN%.}}"
  local records_json

  records_json="$(cloudns_records_json "$zone_name")" || return 1
  jq -r --arg zone "$(dns_fqdn "$zone_name")" --arg name "$name" --arg type "$type" '
    def fqdn($host):
      if $host == "" or $host == "@" then $zone
      elif ($host | endswith(".")) then $host
      else "\($host).\($zone)"
      end;

    to_entries[]
    | select(.value | type == "object")
    | select((.value.type | ascii_upcase) == $type and fqdn(.value.host // "@") == $name)
    | (.value.id // .key)
  ' <<< "$records_json"
}

cloudns_find_record_id() {
  local name="$1"
  local type="$2"
  local value="$3"
  local zone_name="${DNS_ZONE_NAME:-${DNS_DOMAIN%.}}"
  local records_json

  records_json="$(cloudns_records_json "$zone_name")" || return 1
  jq -r --arg zone "$(dns_fqdn "$zone_name")" --arg name "$name" --arg type "$type" --arg value "$value" '
    def fqdn($host):
      if $host == "" or $host == "@" then $zone
      elif ($host | endswith(".")) then $host
      else "\($host).\($zone)"
      end;
    def user_record:
      if .type == "MX" and ((.priority // "") | tostring) != "" and ((.record // "") | test("^[0-9]+[[:space:]]") | not) then
        "\((.priority // "") | tostring) \(.record // "")"
      else
        (.record // "")
      end;

    to_entries[]
    | select(.value | type == "object")
    | select((.value.type | ascii_upcase) == $type and fqdn(.value.host // "@") == $name and (.value | {type: (.type | ascii_upcase), record, priority} | user_record) == $value)
    | (.value.id // .key)
  ' <<< "$records_json" | head -n 1
}

provider_delete_rrset() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local record_id
  local found=0

  while IFS= read -r record_id; do
    [[ -n "$record_id" ]] || continue
    found=1
    cloudns_api "dns/delete-record" "domain-name=${DNS_ZONE_NAME:-${DNS_DOMAIN%.}}" "record-id=${record_id}" >/dev/null || return 1
  done < <(cloudns_find_record_ids "$name" "$type")

  if ((found == 0)); then
    DNS_PROVIDER_ERROR="record_not_found"
    echo -e "Запись ${YELLOW}${type} ${name}${WHITE} не найдена." >&2
    return 1
  fi
}

provider_update_rrset() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local ttl="$4"
  local records_json="$5"

  provider_delete_rrset "$zone_id" "$name" "$type" || return 1
  provider_create_record "$zone_id" "$name" "$type" "$ttl" "$records_json"
}

provider_update_record_value() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local old_value="$4"
  local new_value="$5"
  local ttl="$6"
  local record_id="${7:-}"

  if [[ -z "$record_id" ]]; then
    record_id="$(cloudns_find_record_id "$name" "$type" "$old_value")" || return 1
  fi
  if [[ -z "$record_id" ]]; then
    DNS_PROVIDER_ERROR="record_not_found"
    echo -e "Значение ${YELLOW}${old_value}${WHITE} в ${YELLOW}${type} ${name}${WHITE} не найдено." >&2
    return 1
  fi

  cloudns_modify_single_record "$record_id" "$name" "$type" "$ttl" "$new_value"
}

provider_delete_record_value() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local value="$4"
  local record_id="${5:-}"

  if [[ -z "$record_id" ]]; then
    record_id="$(cloudns_find_record_id "$name" "$type" "$value")" || return 1
  fi
  if [[ -z "$record_id" ]]; then
    DNS_PROVIDER_ERROR="record_not_found"
    echo -e "Значение ${YELLOW}${value}${WHITE} в ${YELLOW}${type} ${name}${WHITE} не найдено." >&2
    return 1
  fi

  cloudns_api "dns/delete-record" "domain-name=${DNS_ZONE_NAME:-${DNS_DOMAIN%.}}" "record-id=${record_id}" >/dev/null
}
