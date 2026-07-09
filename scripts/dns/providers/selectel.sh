#!/usr/bin/env bash

SELECTEL_DNS_API_BASE="${SELECTEL_DNS_API_BASE:-https://api.selectel.ru/domains/v2}"
SELECTEL_IDENTITY_URL="${SELECTEL_IDENTITY_URL:-https://cloud.api.selcloud.ru/identity/v3/auth/tokens}"
SELECTEL_TOKEN="${SELECTEL_TOKEN:-}"
SELECTEL_TOKEN_EXPIRES_EPOCH="${SELECTEL_TOKEN_EXPIRES_EPOCH:-0}"
SELECTEL_TOKEN_REFRESH_MARGIN="${SELECTEL_TOKEN_REFRESH_MARGIN:-60}"

provider_setup_config() {
  local domain="$1"
  local select_status

  DNS_PROVIDER_ERROR=""

  rish_read_input SELECTEL_USERNAME "Сервисный пользователь (Enter - отмена): "
  [[ -n "$SELECTEL_USERNAME" ]] || {
    echo "Подключение отменено."
    return 1
  }
  rish_read_visible_secret SELECTEL_PASSWORD "Пароль (Enter - отмена): "
  [[ -n "$SELECTEL_PASSWORD" ]] || {
    echo "Подключение отменено."
    return 1
  }
  rish_read_input SELECTEL_ACCOUNT_ID "Account ID (Enter - отмена): "
  [[ -n "$SELECTEL_ACCOUNT_ID" ]] || {
    echo "Подключение отменено."
    return 1
  }
  selectel_clear_cached_token

  selectel_choose_project
  select_status=$?
  case "$select_status" in
    0)
      ;;
    130)
      echo "Подключение отменено."
      return 1
      ;;
    11)
      return 1
      ;;
    2)
      selectel_read_project_name || return 1
      ;;
    *)
      if [[ "${DNS_PROVIDER_ERROR:-}" == "auth_failed" ]]; then
        return 1
      fi
      echo "Не удалось загрузить список проектов Selectel, введите проект вручную."
      selectel_read_project_name || return 1
      ;;
  esac

  selectel_clear_cached_token
  provider_auth || return 1

  selectel_choose_zone "$domain"
  select_status=$?
  case "$select_status" in
    0)
      ;;
    130)
      echo "Подключение отменено."
      return 1
      ;;
    2)
      selectel_read_zone_name "$domain" || return 1
      ;;
    *)
      echo "Не удалось загрузить список DNS-зон Selectel, введите зону вручную."
      selectel_read_zone_name "$domain" || return 1
      ;;
  esac
}

provider_write_config() {
  echo "SELECTEL_USERNAME=$(shell_quote "$SELECTEL_USERNAME")"
  echo "SELECTEL_PASSWORD=$(shell_quote "$SELECTEL_PASSWORD")"
  echo "SELECTEL_ACCOUNT_ID=$(shell_quote "$SELECTEL_ACCOUNT_ID")"
  echo "SELECTEL_PROJECT_NAME=$(shell_quote "$SELECTEL_PROJECT_NAME")"
}

provider_zone_ready() {
  [[ -n "${DNS_ZONE_ID:-}" && -n "${DNS_ZONE_NAME:-}" ]]
}

provider_check_config() {
  local missing=0

  if [[ -z "${SELECTEL_USERNAME:-}" ]]; then
    echo -e "Не задан ${YELLOW}SELECTEL_USERNAME${WHITE}." >&2
    missing=1
  fi
  if [[ -z "${SELECTEL_PASSWORD:-}" ]]; then
    echo -e "Не задан ${YELLOW}SELECTEL_PASSWORD${WHITE}." >&2
    missing=1
  fi
  if [[ -z "${SELECTEL_ACCOUNT_ID:-}" ]]; then
    echo -e "Не задан ${YELLOW}SELECTEL_ACCOUNT_ID${WHITE}." >&2
    missing=1
  fi
  if [[ -z "${SELECTEL_PROJECT_NAME:-}" ]]; then
    echo -e "Не задан ${YELLOW}SELECTEL_PROJECT_NAME${WHITE}." >&2
    missing=1
  fi

  ((missing == 0))
}

selectel_token_cache_file() {
  printf '%s/selectel-token.sh' "$(dns_config_dir "$DNS_DOMAIN")"
}

selectel_load_cached_token() {
  local token_file
  local now

  token_file="$(selectel_token_cache_file)"
  [[ -f "$token_file" ]] || return 1
  source "$token_file"
  [[ -n "${SELECTEL_TOKEN:-}" ]] || return 1
  [[ "${SELECTEL_TOKEN_EXPIRES_EPOCH:-}" =~ ^[0-9]+$ ]] || return 1
  [[ "${SELECTEL_TOKEN_USERNAME:-}" == "${SELECTEL_USERNAME:-}" ]] || return 1
  [[ "${SELECTEL_TOKEN_ACCOUNT_ID:-}" == "${SELECTEL_ACCOUNT_ID:-}" ]] || return 1
  [[ "${SELECTEL_TOKEN_PROJECT_NAME:-}" == "${SELECTEL_PROJECT_NAME:-}" ]] || return 1

  now="$(date +%s)"
  if ((SELECTEL_TOKEN_EXPIRES_EPOCH - now > SELECTEL_TOKEN_REFRESH_MARGIN)); then
    return 0
  fi

  SELECTEL_TOKEN=""
  return 1
}

selectel_save_cached_token() {
  local token_file

  [[ -n "${SELECTEL_TOKEN:-}" ]] || return 1
  [[ "${SELECTEL_TOKEN_EXPIRES_EPOCH:-}" =~ ^[0-9]+$ ]] || return 1

  token_file="$(selectel_token_cache_file)"
  mkdir -p "$(dirname "$token_file")" || return 1
  {
    echo "# RISH Selectel DNS token cache."
    echo "SELECTEL_TOKEN=$(shell_quote "$SELECTEL_TOKEN")"
    echo "SELECTEL_TOKEN_EXPIRES_EPOCH=$(shell_quote "$SELECTEL_TOKEN_EXPIRES_EPOCH")"
    echo "SELECTEL_TOKEN_USERNAME=$(shell_quote "$SELECTEL_USERNAME")"
    echo "SELECTEL_TOKEN_ACCOUNT_ID=$(shell_quote "$SELECTEL_ACCOUNT_ID")"
    echo "SELECTEL_TOKEN_PROJECT_NAME=$(shell_quote "$SELECTEL_PROJECT_NAME")"
  } > "$token_file"
  chmod 600 "$token_file" 2>/dev/null || true
}

selectel_clear_cached_token() {
  SELECTEL_TOKEN=""
  SELECTEL_TOKEN_EXPIRES_EPOCH=0
  rm -f "$(selectel_token_cache_file)" 2>/dev/null || true
}

selectel_identity_base() {
  local base="$SELECTEL_IDENTITY_URL"

  base="${base%/auth/tokens}"
  printf '%s' "$base"
}

selectel_auth_body() {
  local project_name="${1:-}"

  if [[ -n "$project_name" ]]; then
    jq -n \
      --arg username "$SELECTEL_USERNAME" \
      --arg password "$SELECTEL_PASSWORD" \
      --arg account_id "$SELECTEL_ACCOUNT_ID" \
      --arg project_name "$project_name" \
      '{
        auth: {
          identity: {
            methods: ["password"],
            password: {
              user: {
                name: $username,
                domain: {name: $account_id},
                password: $password
              }
            }
          },
          scope: {
            project: {
              name: $project_name,
              domain: {name: $account_id}
            }
          }
        }
      }'
    return
  fi

  jq -n \
    --arg username "$SELECTEL_USERNAME" \
    --arg password "$SELECTEL_PASSWORD" \
    --arg account_id "$SELECTEL_ACCOUNT_ID" \
    '{
      auth: {
        identity: {
          methods: ["password"],
          password: {
            user: {
              name: $username,
              domain: {name: $account_id},
              password: $password
            }
          }
        }
      }
    }'
}

selectel_fetch_token() {
  local project_name="${1:-}"
  local save_cache="${2:-0}"
  local headers_file
  local body_file
  local body
  local http_code
  local token
  local expires_at
  local expires_epoch

  headers_file="$(mktemp)" || return 1
  body_file="$(mktemp)" || {
    rm -f "$headers_file"
    return 1
  }
  body="$(selectel_auth_body "$project_name")" || {
    rm -f "$headers_file" "$body_file"
    return 1
  }

  http_code="$(curl -sS -D "$headers_file" -o "$body_file" -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$body" \
    "$SELECTEL_IDENTITY_URL")" || {
    rm -f "$headers_file" "$body_file"
    echo -e "Не удалось получить ${YELLOW}IAM token Selectel${WHITE}." >&2
    return 1
  }

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    rm -f "$headers_file" "$body_file"
    DNS_PROVIDER_ERROR="auth_failed"
    echo -e "Selectel не принял данные авторизации: проверьте ${YELLOW}service user${WHITE}, пароль и ${YELLOW}Account ID${WHITE}." >&2
    return 11
  fi
  if [[ ! "$http_code" =~ ^2 ]]; then
    echo -e "${YELLOW}Selectel Identity API${WHITE} вернул HTTP ${YELLOW}${http_code}${WHITE}." >&2
    if [[ -s "$body_file" ]]; then
      sed -n '1,20p' "$body_file" >&2
    fi
    rm -f "$headers_file" "$body_file"
    return 1
  fi

  token="$(
    awk 'BEGIN {IGNORECASE=1} /^X-Subject-Token:/ {sub(/\r$/, "", $0); print substr($0, index($0, ":") + 2)}' "$headers_file" | tail -n 1
  )"
  expires_at="$(jq -r '.token.expires_at // empty' "$body_file" 2>/dev/null)"
  rm -f "$headers_file" "$body_file"

  if [[ -z "$token" ]]; then
    echo -e "Ответ ${YELLOW}Selectel Identity API${WHITE} не содержит ${YELLOW}X-Subject-Token${WHITE}." >&2
    return 1
  fi

  if [[ "$save_cache" != "1" ]]; then
    printf '%s' "$token"
    return 0
  fi

  SELECTEL_TOKEN="$token"
  SELECTEL_TOKEN_EXPIRES_EPOCH=0
  expires_epoch=""
  if [[ -n "$expires_at" ]]; then
    expires_epoch="$(date -d "$expires_at" +%s 2>/dev/null || true)"
  fi
  if [[ "$expires_epoch" =~ ^[0-9]+$ ]]; then
    SELECTEL_TOKEN_EXPIRES_EPOCH="$expires_epoch"
    selectel_save_cached_token || true
  fi
}

provider_auth() {
  provider_check_config || return 1
  if selectel_load_cached_token; then
    return 0
  fi

  selectel_fetch_token "$SELECTEL_PROJECT_NAME" 1
}

selectel_identity_api_get() {
  local token="$1"
  local path="$2"

  curl -fsS \
    -H "X-Auth-Token: ${token}" \
    -H "Accept: application/json" \
    "$(selectel_identity_base)${path}"
}

selectel_read_project_name() {
  rish_read_input SELECTEL_PROJECT_NAME "Проект (Enter - отмена): "
  [[ -n "$SELECTEL_PROJECT_NAME" ]] || {
    echo "Подключение отменено."
    return 1
  }
}

selectel_choose_project() {
  local token
  local token_status
  local projects_json
  local selected_index
  local menu_limit=248
  local -a project_names
  local -a labels

  token="$(selectel_fetch_token "" 0)"
  token_status=$?
  if ((token_status == 11)); then
    return 11
  fi
  if ((token_status != 0)); then
    return 1
  fi
  projects_json="$(selectel_identity_api_get "$token" "/auth/projects")" || return 1
  mapfile -t project_names < <(
    jq -r '
      .projects[]?
      | select(.enabled != false)
      | .name // empty
    ' <<< "$projects_json" | awk 'NF'
  )
  ((${#project_names[@]} > 0)) || return 1
  if ((${#project_names[@]} > menu_limit)); then
    echo "Показаны первые ${menu_limit} проектов Selectel. Если нужного нет в списке, выберите ручной ввод."
    project_names=("${project_names[@]:0:$menu_limit}")
  fi

  labels=("${project_names[@]}" "Ввести вручную" "Отмена")
  echo "Выберите проект Selectel:"
  vertical_menu "current" 2 0 42 "${labels[@]}"
  selected_index=$?
  if ((selected_index == 255)); then
    return 130
  fi
  if ((selected_index < ${#project_names[@]})); then
    SELECTEL_PROJECT_NAME="${project_names[$selected_index]}"
    return 0
  fi
  if ((selected_index == ${#project_names[@]})); then
    return 2
  fi

  return 130
}

selectel_read_zone_name() {
  local domain="$1"
  local zone_name

  rish_read_input zone_name "DNS-зона (очистить и Enter - отмена): " "$(dns_fqdn "$domain")"
  [[ -n "$zone_name" ]] || {
    echo "Подключение отменено."
    return 1
  }

  DNS_ZONE_NAME="$(dns_fqdn "$zone_name")"
  DNS_ZONE_ID=""
}

selectel_choose_zone() {
  local domain="$1"
  local target_zone
  local zones_json
  local selected_index
  local default_index=0
  local menu_limit=248
  local truncated=0
  local zone_id
  local zone_name
  local -a zone_ids
  local -a zone_names
  local -a labels

  target_zone="$(dns_fqdn "$domain")"
  zones_json="$(selectel_api GET "/zones?limit=1000")" || return 1
  while IFS=$'\t' read -r zone_id zone_name; do
    [[ -n "$zone_id" && -n "$zone_name" ]] || continue
    if ((${#zone_names[@]} >= menu_limit)); then
      truncated=1
      continue
    fi
    zone_ids+=("$zone_id")
    zone_names+=("$zone_name")
    labels+=("$zone_name")
    if [[ "$zone_name" == "$target_zone" ]]; then
      default_index=$((${#zone_names[@]} - 1))
    fi
  done < <(
    jq -r '
      .result[]?
      | select(.id and .name)
      | [.id, .name]
      | @tsv
    ' <<< "$zones_json"
  )
  ((${#zone_names[@]} > 0)) || return 1
  if ((truncated)); then
    echo "Показаны первые ${menu_limit} DNS-зон Selectel. Если нужной нет в списке, выберите ручной ввод."
  fi

  labels+=("Ввести вручную" "Отмена")
  echo "Выберите DNS-зону Selectel:"
  vertical_menu "current" 2 0 42 "default=${default_index}" "${labels[@]}"
  selected_index=$?
  if ((selected_index == 255)); then
    return 130
  fi
  if ((selected_index < ${#zone_names[@]})); then
    DNS_ZONE_ID="${zone_ids[$selected_index]}"
    DNS_ZONE_NAME="${zone_names[$selected_index]}"
    return 0
  fi
  if ((selected_index == ${#zone_names[@]})); then
    return 2
  fi

  return 130
}

selectel_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local retry_auth="${4:-1}"
  local response_file
  local http_code
  local curl_args

  if [[ -z "$SELECTEL_TOKEN" ]]; then
    echo -e "${YELLOW}Selectel token${WHITE} не получен." >&2
    return 1
  fi

  response_file="$(mktemp)" || return 1
  curl_args=(
    -sS
    -o "$response_file"
    -w "%{http_code}"
    -X "$method"
    -H "X-Auth-Token: ${SELECTEL_TOKEN}"
    -H "Accept: application/json"
  )
  if [[ -n "$data" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "$data")
  fi

  http_code="$(curl "${curl_args[@]}" "${SELECTEL_DNS_API_BASE}${path}")"
  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    rm -f "$response_file"
    selectel_clear_cached_token
    if [[ "$retry_auth" == "1" ]]; then
      provider_auth || return 1
      selectel_api "$method" "$path" "$data" 0
      return
    fi
    DNS_PROVIDER_ERROR="auth_expired"
    echo -e "${YELLOW}Selectel API${WHITE} вернул ${YELLOW}${http_code}${WHITE}: нет доступа или token истек." >&2
    return 1
  fi
  if [[ ! "$http_code" =~ ^2 ]]; then
    echo -e "${YELLOW}Selectel API${WHITE} вернул HTTP ${YELLOW}${http_code}${WHITE}." >&2
    if [[ -s "$response_file" ]]; then
      sed -n '1,20p' "$response_file" >&2
    fi
    rm -f "$response_file"
    return 1
  fi

  cat "$response_file"
  rm -f "$response_file"
}

provider_find_zone() {
  local domain="$1"
  local zone_name
  local zones_json
  local zone_id

  if [[ -n "${DNS_ZONE_ID:-}" && -n "${DNS_ZONE_NAME:-}" ]]; then
    printf '%s\t%s\n' "$DNS_ZONE_ID" "$DNS_ZONE_NAME"
    return 0
  fi

  zone_name="${DNS_ZONE_NAME:-$(dns_fqdn "$domain")}"
  zone_name="$(dns_fqdn "$zone_name")"
  zones_json="$(selectel_api GET "/zones?filter=${zone_name}")" || return 1
  zone_id="$(
    jq -r --arg zone_name "$zone_name" '
      .result[]
      | select(.name == $zone_name)
      | .id
    ' <<< "$zones_json" | head -n 1
  )"

  if [[ -z "$zone_id" ]]; then
    DNS_PROVIDER_ERROR="zone_not_found"
    echo -e "DNS-зона ${YELLOW}${zone_name}${WHITE} в Selectel не найдена." >&2
    return 1
  fi

  DNS_ZONE_ID="$zone_id"
  DNS_ZONE_NAME="$zone_name"
  printf '%s\t%s\n' "$DNS_ZONE_ID" "$DNS_ZONE_NAME"
}

selectel_list_records_json() {
  local zone_id="$1"

  selectel_api GET "/zones/${zone_id}/rrset?limit=1000&sort_by=name.ascend&sort_by=type.ascend"
}

provider_list_records() {
  local zone_id="$1"
  local rrsets_json

  rrsets_json="$(selectel_list_records_json "$zone_id")" || return 1
  jq -r '
    def user_content($record_type):
      if $record_type == "TXT" and startswith("\"") and endswith("\"") then .[1:-1] else . end;

    .result[]
    | select(.type != "SOA")
    | .type as $record_type
    | "\(.type)\t\(.ttl | tostring)\t\(.name)\t\([.records[]? | select(.disabled != true) | (.content | user_content($record_type))] | tojson)"
  ' <<< "$rrsets_json"
}

selectel_get_rrset_json() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local rrsets_json

  rrsets_json="$(selectel_list_records_json "$zone_id")" || return 1
  jq -c --arg name "$name" --arg type "$type" '
    .result[]
    | select(.name == $name and .type == $type)
  ' <<< "$rrsets_json" | head -n 1
}

selectel_user_records_json() {
  local rrset_json="$1"

  jq -c '
    def user_content($record_type):
      if $record_type == "TXT" and startswith("\"") and endswith("\"") then .[1:-1] else . end;

    .type as $record_type
    | [.records[]? | select(.disabled != true) | (.content | user_content($record_type))]
  ' <<< "$rrset_json"
}

selectel_find_rrset_id() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local rrsets_json
  local rrset_id

  rrsets_json="$(selectel_list_records_json "$zone_id")" || return 1
  rrset_id="$(
    jq -r --arg name "$name" --arg type "$type" '
      .result[]
      | select(.name == $name and .type == $type)
      | .id // empty
    ' <<< "$rrsets_json" | head -n 1
  )"

  if [[ -z "$rrset_id" ]]; then
    DNS_PROVIDER_ERROR="record_not_found"
    echo -e "Запись ${YELLOW}${type} ${name}${WHITE} не найдена." >&2
    return 1
  fi

  printf '%s' "$rrset_id"
}

selectel_record_body() {
  local name="$1"
  local type="$2"
  local ttl="$3"
  local records_json="$4"

  jq -n \
    --arg name "$name" \
    --arg type "$type" \
    --argjson ttl "$ttl" \
    --argjson records "$records_json" \
    '{
      name: $name,
      type: $type,
      ttl: $ttl,
      records: (
        $records
        | map(if $type == "TXT" and (startswith("\"") | not) then "\"\(.)\"" else . end)
        | map({content: ., disabled: false})
      )
    }'
}

provider_create_record() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local ttl="$4"
  local records_json="$5"
  local body

  body="$(selectel_record_body "$name" "$type" "$ttl" "$records_json")" || return 1
  selectel_api POST "/zones/${zone_id}/rrset" "$body" >/dev/null
}

provider_add_record_value() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local ttl="$4"
  local value="$5"
  local rrset_json
  local rrset_id
  local records_json
  local body

  rrset_json="$(selectel_get_rrset_json "$zone_id" "$name" "$type")" || return 1
  if [[ -z "$rrset_json" ]]; then
    records_json="$(jq -cn --arg value "$value" '[$value]')" || return 1
    provider_create_record "$zone_id" "$name" "$type" "$ttl" "$records_json"
    return
  fi

  rrset_id="$(jq -r '.id' <<< "$rrset_json")"
  ttl="$(jq -r '.ttl' <<< "$rrset_json")"
  records_json="$(
    selectel_user_records_json "$rrset_json" |
      jq -c --arg value "$value" '
        (. + [$value]) as $items
        | reduce $items[] as $item ([]; if index($item) then . else . + [$item] end)
      '
  )" || return 1
  body="$(selectel_record_body "$name" "$type" "$ttl" "$records_json")" || return 1
  selectel_api PATCH "/zones/${zone_id}/rrset/${rrset_id}" "$body" >/dev/null
}

provider_update_rrset() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local ttl="$4"
  local records_json="$5"
  local rrset_id
  local body

  rrset_id="$(selectel_find_rrset_id "$zone_id" "$name" "$type")" || return 1
  body="$(selectel_record_body "$name" "$type" "$ttl" "$records_json")" || return 1
  selectel_api PATCH "/zones/${zone_id}/rrset/${rrset_id}" "$body" >/dev/null
}

provider_update_record_value() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local old_value="$4"
  local new_value="$5"
  local ttl="$6"
  local rrset_json
  local rrset_id
  local records_json
  local body

  rrset_json="$(selectel_get_rrset_json "$zone_id" "$name" "$type")" || return 1
  if [[ -z "$rrset_json" ]]; then
    DNS_PROVIDER_ERROR="record_not_found"
    echo -e "Запись ${YELLOW}${type} ${name}${WHITE} не найдена." >&2
    return 1
  fi

  rrset_id="$(jq -r '.id' <<< "$rrset_json")"
  records_json="$(
    selectel_user_records_json "$rrset_json" |
      jq -c --arg old_value "$old_value" --arg new_value "$new_value" '
        if index($old_value) == null then empty else map(if . == $old_value then $new_value else . end) end
      '
  )" || return 1
  if [[ -z "$records_json" ]]; then
    DNS_PROVIDER_ERROR="record_not_found"
    echo -e "Значение ${YELLOW}${old_value}${WHITE} в ${YELLOW}${type} ${name}${WHITE} не найдено." >&2
    return 1
  fi
  body="$(selectel_record_body "$name" "$type" "$ttl" "$records_json")" || return 1
  selectel_api PATCH "/zones/${zone_id}/rrset/${rrset_id}" "$body" >/dev/null
}

provider_delete_rrset() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local rrset_id

  rrset_id="$(selectel_find_rrset_id "$zone_id" "$name" "$type")" || return 1
  selectel_api DELETE "/zones/${zone_id}/rrset/${rrset_id}" >/dev/null
}

provider_delete_record_value() {
  local zone_id="$1"
  local name="$2"
  local type="$3"
  local value="$4"
  local rrset_json
  local rrset_id
  local ttl
  local records_json
  local body

  rrset_json="$(selectel_get_rrset_json "$zone_id" "$name" "$type")" || return 1
  if [[ -z "$rrset_json" ]]; then
    DNS_PROVIDER_ERROR="record_not_found"
    echo -e "Запись ${YELLOW}${type} ${name}${WHITE} не найдена." >&2
    return 1
  fi

  rrset_id="$(jq -r '.id' <<< "$rrset_json")"
  ttl="$(jq -r '.ttl' <<< "$rrset_json")"
  records_json="$(
    selectel_user_records_json "$rrset_json" |
      jq -c --arg value "$value" '
        if index($value) == null then empty else map(select(. != $value)) end
      '
  )" || return 1
  if [[ -z "$records_json" ]]; then
    DNS_PROVIDER_ERROR="record_not_found"
    echo -e "Значение ${YELLOW}${value}${WHITE} в ${YELLOW}${type} ${name}${WHITE} не найдено." >&2
    return 1
  fi
  if [[ "$(jq 'length' <<< "$records_json")" -eq 0 ]]; then
    selectel_api DELETE "/zones/${zone_id}/rrset/${rrset_id}" >/dev/null
    return
  fi

  body="$(selectel_record_body "$name" "$type" "$ttl" "$records_json")" || return 1
  selectel_api PATCH "/zones/${zone_id}/rrset/${rrset_id}" "$body" >/dev/null
}
