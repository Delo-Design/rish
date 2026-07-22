#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2178

umask 077

CERTIFICATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RISH_HOME="${RISH_HOME:-/root/rish}"
DNS_SCRIPT="${RISH_HOME}/scripts/dns/dns.sh"

if [[ ! -f "$DNS_SCRIPT" ]]; then
  DNS_SCRIPT="${CERTIFICATE_SCRIPT_DIR}/../dns/dns.sh"
fi
if [[ ! -f "$DNS_SCRIPT" ]]; then
  echo "Не найден модуль управления DNS RISH." >&2
  exit 1
fi

DNS_SKIP_MAIN=1
source "$DNS_SCRIPT"

SELECTEL_LE_CERT_API_BASE="${SELECTEL_LE_CERT_API_BASE:-https://api.selectel.ru/certs/le}"
SELECTEL_CERT_API_BASE="${SELECTEL_CERT_API_BASE:-https://cloud.api.selcloud.ru/certificate-manager/v1}"
RISH_SELECTEL_CERT_CONFIG_DIR="${RISH_SELECTEL_CERT_CONFIG_DIR:-${RISH_HOME}/certificates/selectel}"
RISH_SELECTEL_CERT_STORAGE_DIR="${RISH_SELECTEL_CERT_STORAGE_DIR:-/etc/pki/tls/rish/selectel}"
SELECTEL_CERT_ZONE=""
SELECTEL_CERT_DNS_CONFIG=""
SELECTEL_CERT_SELECTED_JSON=""

selectel_cert_fail() {
  echo "$*" >&2
  return 1
}

selectel_cert_require_commands() {
  local command_name

  for command_name in "$@"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo -e "Не найдена необходимая команда ${YELLOW}${command_name}${WHITE}." >&2
      return 1
    fi
  done
}

selectel_cert_vhost_file() {
  local site_name="$1"

  printf '/etc/httpd/conf.d/%s-selectel-ssl.conf' "$site_name"
}

selectel_cert_metadata_file() {
  local zone="$1"

  printf '%s/%s.conf' "$RISH_SELECTEL_CERT_CONFIG_DIR" "$zone"
}

selectel_cert_storage_dir() {
  local zone="$1"

  printf '%s/%s' "$RISH_SELECTEL_CERT_STORAGE_DIR" "$zone"
}

selectel_cert_is_owned_vhost() {
  local vhost_file="$1"

  [[ -f "$vhost_file" ]] || return 1
  grep -Fqx '# Managed by RISH Selectel certificate integration.' "$vhost_file"
}

selectel_cert_is_owned_metadata() {
  local metadata_file="$1"

  [[ -f "$metadata_file" ]] || return 1
  grep -Fqx '# RISH Selectel certificate metadata. No credentials are stored here.' "$metadata_file"
}

selectel_cert_find_zone_config() {
  local site_name="$1"
  local candidate="${site_name%.}"
  local active_config
  local saved_config

  SELECTEL_CERT_ZONE=""
  SELECTEL_CERT_DNS_CONFIG=""

  while [[ -n "$candidate" && "$candidate" == *.* ]]; do
    active_config="${DNS_RUNTIME_DIR}/domains/${candidate}/config.sh"
    saved_config="${DNS_RUNTIME_DIR}/domains/${candidate}/selectel.sh"
    if [[ -f "$active_config" && -f "$saved_config" ]] && (
      unset DNS_PROVIDER
      source "$active_config" >/dev/null 2>&1 || exit 1
      [[ "${DNS_PROVIDER:-}" == "selectel" ]]
    ) && (
      unset DNS_PROVIDER SELECTEL_USERNAME SELECTEL_PASSWORD SELECTEL_ACCOUNT_ID SELECTEL_PROJECT_NAME
      source "$saved_config" >/dev/null 2>&1 || exit 1
      [[ "${DNS_PROVIDER:-}" == "selectel" ]]
      [[ -n "${SELECTEL_USERNAME:-}" ]]
      [[ -n "${SELECTEL_PASSWORD:-}" ]]
      [[ -n "${SELECTEL_ACCOUNT_ID:-}" ]]
      [[ -n "${SELECTEL_PROJECT_NAME:-}" ]]
    ); then
      SELECTEL_CERT_ZONE="$candidate"
      SELECTEL_CERT_DNS_CONFIG="$saved_config"
      return 0
    fi
    candidate="${candidate#*.}"
  done

  return 1
}

selectel_cert_prepare_provider() {
  local site_name="$1"

  if ! selectel_cert_find_zone_config "$site_name"; then
    echo -e "DNS-зона для ${YELLOW}${site_name}${WHITE} не подключена к Selectel в RISH." >&2
    echo "Сначала подключите Selectel в меню управления DNS." >&2
    return 1
  fi

  source "$SELECTEL_CERT_DNS_CONFIG" || return 1
  DNS_DOMAIN="$SELECTEL_CERT_ZONE"
  load_provider selectel
  provider_auth
}

selectel_cert_api_to_file() {
  local method="$1"
  local base_url="$2"
  local path="$3"
  local output_file="$4"
  local retry_auth="${5:-1}"
  local http_code

  http_code="$(curl -sS -o "$output_file" -w '%{http_code}' \
    -X "$method" \
    -H "X-Auth-Token: ${SELECTEL_TOKEN}" \
    -H 'Accept: application/json, application/x-pem-file, application/octet-stream' \
    "${base_url}${path}")" || {
      echo -e "Не удалось выполнить запрос к ${YELLOW}Selectel Certificate Manager API${WHITE}." >&2
      return 1
    }

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    if [[ "$retry_auth" == "1" ]]; then
      selectel_clear_cached_token
      provider_auth || {
        return 1
      }
      selectel_cert_api_to_file "$method" "$base_url" "$path" "$output_file" 0
      return
    fi
    echo -e "Selectel не разрешил работу с сертификатами: HTTP ${YELLOW}${http_code}${WHITE}." >&2
    return 1
  fi

  if [[ ! "$http_code" =~ ^2 ]]; then
    echo -e "${YELLOW}Selectel Certificate Manager API${WHITE} вернул HTTP ${YELLOW}${http_code}${WHITE}." >&2
    selectel_print_api_error_body "$output_file"
    return 1
  fi
}

selectel_cert_list_to_file() {
  local output_file="$1"

  selectel_cert_api_to_file GET "$SELECTEL_LE_CERT_API_BASE" / "$output_file"
}

selectel_cert_collect_vhost_names() {
  local source_vhost="$1"
  local result_var="$2"
  local -n names_ref="$result_var"
  local name
  local -a raw_names=()
  declare -A seen_names=()

  mapfile -t raw_names < <(awk '
    BEGIN {IGNORECASE=1}
    $1=="ServerName" && NF>1 {print $2}
    $1=="ServerAlias" {
      for (i=2; i<=NF; i++) {
        if ($i ~ /^#/) break
        print $i
      }
    }
  ' "$source_vhost")

  names_ref=()
  for name in "${raw_names[@]}"; do
    name="${name%.}"
    [[ -n "$name" ]] || continue
    if [[ -z "${seen_names[${name,,}]:-}" ]]; then
      names_ref+=("$name")
      seen_names["${name,,}"]=1
    fi
  done
}

selectel_cert_primary_vhost_name() {
  local source_vhost="$1"

  awk '
    BEGIN {IGNORECASE=1}
    $1=="ServerName" && NF>1 {
      sub(/[.]$/, "", $2)
      print $2
      exit
    }
  ' "$source_vhost"
}

selectel_cert_pattern_covers_host() {
  local pattern="${1,,}"
  local host="${2,,}"
  local suffix
  local prefix

  pattern="${pattern%.}"
  host="${host%.}"
  [[ "$pattern" == "$host" ]] && return 0
  [[ "$pattern" == \*.* ]] || return 1
  [[ "$host" != \*.* ]] || return 1

  suffix="${pattern#*.}"
  [[ "$host" == *."$suffix" ]] || return 1
  prefix="${host%."$suffix"}"
  [[ -n "$prefix" && "$prefix" != *.* ]]
}

selectel_cert_vhost_names_overlap() {
  local first="$1"
  local second="$2"

  selectel_cert_pattern_covers_host "$first" "$second" ||
    selectel_cert_pattern_covers_host "$second" "$first"
}

selectel_cert_json_covers_names() {
  local certificate_json="$1"
  local names_var="$2"
  local -n names_ref="$names_var"
  local host
  local pattern
  local covered
  local -a patterns=()

  mapfile -t patterns < <(jq -r '.domains[]? // empty' <<< "$certificate_json")
  ((${#patterns[@]} > 0)) || return 1

  for host in "${names_ref[@]}"; do
    covered=0
    for pattern in "${patterns[@]}"; do
      if selectel_cert_pattern_covers_host "$pattern" "$host"; then
        covered=1
        break
      fi
    done
    ((covered)) || return 1
  done
}

selectel_cert_json_covers_host() {
  local certificate_json="$1"
  local host="$2"
  local pattern

  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    if selectel_cert_pattern_covers_host "$pattern" "$host"; then
      return 0
    fi
  done < <(jq -r '.domains[]? // empty' <<< "$certificate_json")

  return 1
}

selectel_cert_print_uncovered_aliases() {
  local certificate_json="$1"
  local source_vhost="$2"
  local primary_name
  local name
  local uncovered=0
  local -a vhost_names=()

  primary_name="$(selectel_cert_primary_vhost_name "$source_vhost")"
  selectel_cert_collect_vhost_names "$source_vhost" vhost_names
  for name in "${vhost_names[@]}"; do
    [[ "${name,,}" != "${primary_name,,}" ]] || continue
    if ! selectel_cert_json_covers_host "$certificate_json" "$name"; then
      if ((uncovered == 0)); then
        echo "Сертификат не покрывает следующие алиасы; они не будут добавлены в HTTPS-vhost:"
      fi
      echo -e "  ${YELLOW}${name}${WHITE}"
      uncovered=1
    fi
  done
}

selectel_cert_choose_certificate() {
  local source_vhost="$1"
  local temp_dir="$2"
  local list_file="${temp_dir}/certificates.json"
  local encoded
  local certificate_json
  local status
  local knox_cert_id
  local certificate_name
  local domains
  local expire_at
  local label
  local choice
  local primary_name
  local -a required_names=()
  local -a labels=()
  local -a certificates=()

  primary_name="$(selectel_cert_primary_vhost_name "$source_vhost")"
  [[ -n "$primary_name" ]] || {
    echo -e "В ${YELLOW}${source_vhost}${WHITE} не найден ServerName." >&2
    return 1
  }
  required_names=("$primary_name")

  selectel_cert_list_to_file "$list_file" || return 1
  if ! jq -e '.items | type == "array"' "$list_file" >/dev/null 2>&1; then
    echo "Selectel вернул некорректный список сертификатов." >&2
    return 1
  fi

  while IFS= read -r encoded; do
    [[ -n "$encoded" ]] || continue
    certificate_json="$(printf '%s' "$encoded" | base64 -d 2>/dev/null)" || continue
    status="$(jq -r '(.status // "") | ascii_upcase' <<< "$certificate_json")"
    case "$status" in
      ACTIVE|RENEWING|ISSUED)
        ;;
      *)
        continue
        ;;
    esac
    knox_cert_id="$(jq -r '.knox_cert_id // empty' <<< "$certificate_json")"
    [[ -n "$knox_cert_id" ]] || continue
    selectel_cert_json_covers_names "$certificate_json" required_names || continue

    certificate_name="$(jq -r '.name // "Без имени"' <<< "$certificate_json" | tr '\n\r\t' '   ')"
    domains="$(jq -r '[.domains[]?] | join(", ")' <<< "$certificate_json" | tr '\n\r\t' '   ')"
    expire_at="$(jq -r '.expire_at // "срок не указан"' <<< "$certificate_json" | tr '\n\r\t' '   ')"
    label="${certificate_name} | ${domains} | до ${expire_at}"
    labels+=("$label")
    certificates+=("$certificate_json")
    ((${#labels[@]} < 247)) || break
  done < <(jq -r '.items[] | @base64' "$list_file")

  if ((${#labels[@]} == 0)); then
    echo "В проекте Selectel нет готового сертификата для основного имени этого vhost." >&2
    return 1
  fi

  labels+=("Выйти")
  echo "Выберите сертификат Selectel:"
  vertical_menu "current" 2 12 72 "${labels[@]}"
  choice=$?
  if ((choice == 255 || choice >= ${#certificates[@]})); then
    return 130
  fi

  SELECTEL_CERT_SELECTED_JSON="${certificates[$choice]}"
}

selectel_cert_extract_certificate_blocks() {
  local input_file="$1"
  local output_file="$2"
  local normalized_file="${output_file}.normalized"

  : > "$normalized_file"
  if grep -q -- '-----BEGIN CERTIFICATE-----' "$input_file"; then
    if jq -e . "$input_file" >/dev/null 2>&1; then
      jq -r '.. | strings | select(contains("-----BEGIN CERTIFICATE-----"))' "$input_file" > "$normalized_file"
    else
      cp "$input_file" "$normalized_file"
    fi
  fi

  awk '
    /-----BEGIN CERTIFICATE-----/ {inside=1}
    inside {print}
    /-----END CERTIFICATE-----/ {inside=0; print ""}
  ' "$normalized_file" > "$output_file"
  rm -f "$normalized_file"
  grep -q -- '-----BEGIN CERTIFICATE-----' "$output_file"
}

selectel_cert_extract_private_key() {
  local input_file="$1"
  local output_file="$2"
  local normalized_file="${output_file}.normalized"

  : > "$normalized_file"
  if grep -q -- 'PRIVATE KEY-----' "$input_file"; then
    if jq -e . "$input_file" >/dev/null 2>&1; then
      jq -r '.. | strings | select(contains("PRIVATE KEY-----"))' "$input_file" > "$normalized_file"
    else
      cp "$input_file" "$normalized_file"
    fi
  fi

  awk '
    /-----BEGIN ([A-Z]+ )?PRIVATE KEY-----/ {inside=1}
    inside {print}
    /-----END ([A-Z]+ )?PRIVATE KEY-----/ {exit}
  ' "$normalized_file" > "$output_file"
  rm -f "$normalized_file"
  grep -q -- 'PRIVATE KEY-----' "$output_file"
}

selectel_cert_first_certificate() {
  local input_file="$1"
  local output_file="$2"

  awk '
    /-----BEGIN CERTIFICATE-----/ {inside=1}
    inside {print}
    /-----END CERTIFICATE-----/ {exit}
  ' "$input_file" > "$output_file"
  grep -q -- '-----BEGIN CERTIFICATE-----' "$output_file"
}

selectel_cert_without_leaf() {
  local leaf_file="$1"
  local certificates_file="$2"
  local output_file="$3"
  local temp_dir="$4"
  local split_dir="${temp_dir}/chain-parts"
  local part
  local leaf_fingerprint
  local part_fingerprint

  mkdir -p "$split_dir" || return 1
  awk -v directory="$split_dir" '
    /-----BEGIN CERTIFICATE-----/ {
      number++
      file=sprintf("%s/%03d.pem", directory, number)
      inside=1
    }
    inside {print > file}
    /-----END CERTIFICATE-----/ {
      close(file)
      inside=0
    }
  ' "$certificates_file"

  leaf_fingerprint="$(openssl x509 -in "$leaf_file" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [[ -n "$leaf_fingerprint" ]] || return 1
  : > "$output_file"
  for part in "$split_dir"/*.pem; do
    [[ -f "$part" ]] || continue
    part_fingerprint="$(openssl x509 -in "$part" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    [[ -n "$part_fingerprint" ]] || return 1
    if [[ "$part_fingerprint" != "$leaf_fingerprint" ]]; then
      cat "$part" >> "$output_file"
      echo >> "$output_file"
    fi
  done
}

selectel_cert_public_key_fingerprint() {
  local type="$1"
  local file="$2"

  case "$type" in
    certificate)
      openssl x509 -in "$file" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
      ;;
    private_key)
      openssl pkey -in "$file" -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
      ;;
  esac
}

selectel_cert_validate_download() {
  local certificate_file="$1"
  local chain_file="$2"
  local private_key_file="$3"
  local source_vhost="$4"
  local certificate_json="$5"
  local certificate_fingerprint
  local key_fingerprint
  local host
  local -a vhost_names=()

  openssl x509 -in "$certificate_file" -noout >/dev/null 2>&1 || {
    echo "Selectel вернул некорректный сертификат." >&2
    return 1
  }
  openssl pkey -in "$private_key_file" -noout >/dev/null 2>&1 || {
    echo "Selectel вернул некорректный приватный ключ." >&2
    return 1
  }
  openssl x509 -in "$certificate_file" -checkend 86400 -noout >/dev/null 2>&1 || {
    echo "Срок действия сертификата истек или закончится менее чем через сутки." >&2
    return 1
  }

  certificate_fingerprint="$(selectel_cert_public_key_fingerprint certificate "$certificate_file")"
  key_fingerprint="$(selectel_cert_public_key_fingerprint private_key "$private_key_file")"
  if [[ -z "$certificate_fingerprint" || "$certificate_fingerprint" != "$key_fingerprint" ]]; then
    echo "Приватный ключ не соответствует сертификату." >&2
    return 1
  fi

  if [[ -s "$chain_file" ]]; then
    openssl crl2pkcs7 -nocrl -certfile "$chain_file" 2>/dev/null |
      openssl pkcs7 -print_certs -noout >/dev/null 2>&1 || {
        echo "Selectel вернул некорректную цепочку сертификатов." >&2
        return 1
      }
  fi

  selectel_cert_collect_vhost_names "$source_vhost" vhost_names
  for host in "${vhost_names[@]}"; do
    [[ "$host" != \*.* ]] || continue
    selectel_cert_json_covers_host "$certificate_json" "$host" || continue
    if ! openssl x509 -in "$certificate_file" -checkhost "$host" -noout >/dev/null 2>&1; then
      echo -e "Сертификат не подходит для имени ${YELLOW}${host}${WHITE}." >&2
      return 1
    fi
  done
}

selectel_cert_download() {
  local certificate_json="$1"
  local source_vhost="$2"
  local temp_dir="$3"
  local knox_cert_id
  local certificate_response="${temp_dir}/certificate.response"
  local chain_response="${temp_dir}/chain.response"
  local key_response="${temp_dir}/private-key.response"
  local certificate_blocks="${temp_dir}/certificate-blocks.pem"
  local chain_blocks="${temp_dir}/chain-blocks.pem"
  local certificate_file="${temp_dir}/cert.pem"
  local chain_file="${temp_dir}/chain.pem"
  local private_key_file="${temp_dir}/privkey.pem"
  local fullchain_file="${temp_dir}/fullchain.pem"

  knox_cert_id="$(jq -r '.knox_cert_id // empty' <<< "$certificate_json")"
  [[ "$knox_cert_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Selectel вернул некорректный идентификатор сертификата." >&2
    return 1
  }

  selectel_cert_api_to_file GET "$SELECTEL_CERT_API_BASE" "/cert/${knox_cert_id}" "$certificate_response" || return 1
  selectel_cert_api_to_file GET "$SELECTEL_CERT_API_BASE" "/cert/${knox_cert_id}/ca_chain" "$chain_response" || return 1
  selectel_cert_api_to_file GET "$SELECTEL_CERT_API_BASE" "/cert/${knox_cert_id}/private_key" "$key_response" || return 1

  selectel_cert_extract_certificate_blocks "$certificate_response" "$certificate_blocks" || true
  selectel_cert_extract_certificate_blocks "$chain_response" "$chain_blocks" || true

  if ! selectel_cert_first_certificate "$certificate_blocks" "$certificate_file"; then
    selectel_cert_first_certificate "$chain_blocks" "$certificate_file" || {
      echo "В ответе Selectel не найден основной сертификат." >&2
      return 1
    }
  fi
  selectel_cert_without_leaf "$certificate_file" "$chain_blocks" "$chain_file" "$temp_dir" || return 1
  selectel_cert_extract_private_key "$key_response" "$private_key_file" || {
    echo "В ответе Selectel не найден приватный ключ." >&2
    return 1
  }

  cat "$certificate_file" > "$fullchain_file"
  echo >> "$fullchain_file"
  if [[ -s "$chain_file" ]]; then
    cat "$chain_file" >> "$fullchain_file"
  fi

  selectel_cert_validate_download "$certificate_file" "$chain_file" "$private_key_file" "$source_vhost" "$certificate_json"
}

selectel_cert_find_other_https_vhost() {
  local source_vhost="$1"
  local own_vhost="$2"
  local config_file
  local known_vhost
  local name
  local existing_name
  local -a names=()
  local -a existing_names=()

  for known_vhost in \
    "${source_vhost%.conf}-ssl.conf" \
    "${source_vhost%.conf}-le-ssl.conf"; do
    if [[ -f "$known_vhost" && "$known_vhost" != "$own_vhost" ]]; then
      printf '%s' "$known_vhost"
      return 0
    fi
  done

  selectel_cert_collect_vhost_names "$source_vhost" names
  for config_file in /etc/httpd/conf.d/*.conf; do
    [[ -f "$config_file" ]] || continue
    [[ "$config_file" != "$source_vhost" ]] || continue
    [[ "$config_file" != "$own_vhost" ]] || continue
    grep -Eqi '<VirtualHost[[:space:]][^>]*:443([[:space:]]|>)' "$config_file" || continue
    mapfile -t existing_names < <(awk '
      BEGIN {IGNORECASE=1; inside=0}
      /<VirtualHost[[:space:]][^>]*:443([[:space:]]|>)/ {inside=1}
      inside && ($1=="ServerName" || $1=="ServerAlias") {
        for (i=2; i<=NF; i++) {
          if ($i ~ /^#/) break
          sub(/[.]$/, "", $i)
          print $i
        }
      }
      /<\/VirtualHost>/ {inside=0}
    ' "$config_file")
    for name in "${names[@]}"; do
      for existing_name in "${existing_names[@]}"; do
        if selectel_cert_vhost_names_overlap "$name" "$existing_name"; then
          printf '%s' "$config_file"
          return 0
        fi
      done
    done
  done

  return 1
}

selectel_cert_render_vhost() {
  local source_vhost="$1"
  local output_file="$2"
  local fullchain_file="$3"
  local private_key_file="$4"
  local certificate_json="$5"
  local line
  local trimmed
  local indentation
  local directive
  local alias
  local comment=""
  local -a fields=()
  local -a covered_aliases=()

  if ! grep -Eqi '<VirtualHost[[:space:]][^>]*:80([[:space:]]|>)' "$source_vhost"; then
    echo -e "В ${YELLOW}${source_vhost}${WHITE} не найден VirtualHost для порта 80." >&2
    return 1
  fi
  if grep -Eqi '^[[:space:]]*SSLCertificate(File|KeyFile|ChainFile)[[:space:]]' "$source_vhost"; then
    echo -e "В ${YELLOW}${source_vhost}${WHITE} уже есть SSL-настройки; файл оставлен без изменений." >&2
    return 1
  fi

  {
    echo '# Managed by RISH Selectel certificate integration.'
    while IFS= read -r line || [[ -n "$line" ]]; do
      trimmed="${line#"${line%%[![:space:]]*}"}"
      directive="${trimmed%%[[:space:]]*}"
      if [[ "${directive,,}" != "serveralias" ]]; then
        printf '%s\n' "$line"
        continue
      fi

      indentation="${line%%[![:space:]]*}"
      read -r -a fields <<< "${trimmed#"$directive"}"
      covered_aliases=()
      comment=""
      for alias in "${fields[@]}"; do
        if [[ "$alias" == \#* ]]; then
          comment="$alias"
          break
        fi
        if selectel_cert_json_covers_host "$certificate_json" "$alias"; then
          covered_aliases+=("$alias")
        fi
      done
      if ((${#covered_aliases[@]} > 0)); then
        printf '%sServerAlias' "$indentation"
        printf ' %s' "${covered_aliases[@]}"
        [[ -z "$comment" ]] || printf ' %s' "$comment"
        printf '\n'
      fi
    done < "$source_vhost"
  } > "$output_file" || return 1

  sed -E -i 's#(<VirtualHost[[:space:]]+)([^>]*):80>#\1\2:443>#g' "$output_file"
  sed -i "/<\/VirtualHost>/i ServerSignature Off\nSSLCertificateFile ${fullchain_file}\nSSLCertificateKeyFile ${private_key_file}" "$output_file"
}

selectel_cert_write_metadata() {
  local certificate_json="$1"
  local zone="$2"
  local storage_dir="$3"
  local output_file="$4"
  local certificate_id
  local knox_cert_id
  local certificate_version
  local certificate_name
  local certificate_domains
  local certificate_expire_at

  certificate_id="$(jq -r '.id // empty' <<< "$certificate_json")"
  knox_cert_id="$(jq -r '.knox_cert_id // empty' <<< "$certificate_json")"
  certificate_version="$(jq -r '.version // 0' <<< "$certificate_json")"
  certificate_name="$(jq -r '.name // empty' <<< "$certificate_json")"
  certificate_domains="$(jq -c '.domains // []' <<< "$certificate_json")"
  certificate_expire_at="$(jq -r '.expire_at // empty' <<< "$certificate_json")"

  {
    echo '# RISH Selectel certificate metadata. No credentials are stored here.'
    echo "SELECTEL_CERT_ZONE=$(shell_quote "$zone")"
    echo "SELECTEL_DNS_CONFIG=$(shell_quote "$SELECTEL_CERT_DNS_CONFIG")"
    echo "SELECTEL_CERT_ID=$(shell_quote "$certificate_id")"
    echo "SELECTEL_KNOX_CERT_ID=$(shell_quote "$knox_cert_id")"
    echo "SELECTEL_CERT_VERSION=$(shell_quote "$certificate_version")"
    echo "SELECTEL_CERT_NAME=$(shell_quote "$certificate_name")"
    echo "SELECTEL_CERT_DOMAINS_JSON=$(shell_quote "$certificate_domains")"
    echo "SELECTEL_CERT_EXPIRES_AT=$(shell_quote "$certificate_expire_at")"
    echo "SELECTEL_CERT_DIRECTORY=$(shell_quote "$storage_dir")"
    echo "SELECTEL_CERT_FULLCHAIN=$(shell_quote "${storage_dir}/fullchain.pem")"
    echo "SELECTEL_CERT_PRIVATE_KEY=$(shell_quote "${storage_dir}/privkey.pem")"
  } > "$output_file"
}

selectel_cert_count_other_references() {
  local fullchain_file="$1"
  local excluded_vhost="$2"
  local config_file
  local count=0

  for config_file in /etc/httpd/conf.d/*-selectel-ssl.conf; do
    [[ -f "$config_file" ]] || continue
    [[ "$config_file" != "$excluded_vhost" ]] || continue
    selectel_cert_is_owned_vhost "$config_file" || continue
    if grep -Fq -- "SSLCertificateFile ${fullchain_file}" "$config_file"; then
      ((count++))
    fi
  done
  printf '%s' "$count"
}

selectel_cert_restore_file() {
  local backup_file="$1"
  local destination="$2"
  local mode="$3"

  if [[ -f "$backup_file" ]]; then
    install -m "$mode" -o root -g root "$backup_file" "$destination"
  else
    rm -f -- "$destination"
  fi
}

selectel_cert_backup_file() {
  local source_file="$1"
  local backup_file="$2"

  [[ -f "$source_file" ]] || return 0
  cp -p "$source_file" "$backup_file"
}

selectel_cert_install_selected() {
  local site_name="$1"
  local source_vhost="/etc/httpd/conf.d/${site_name}.conf"
  local own_vhost
  local other_vhost
  local temp_dir
  local zone
  local storage_dir
  local metadata_file
  local existing_certificate_id=""
  local selected_certificate_id
  local other_references=0
  local fullchain_file
  local private_key_file
  local rc=0

  selectel_cert_require_commands curl jq openssl apachectl systemctl install sha256sum base64 || return 1
  own_vhost="$(selectel_cert_vhost_file "$site_name")"
  [[ -f "$source_vhost" ]] || return 1

  if [[ -e "$own_vhost" ]] && ! selectel_cert_is_owned_vhost "$own_vhost"; then
    echo -e "Файл ${YELLOW}${own_vhost}${WHITE} создан не RISH и оставлен без изменений." >&2
    return 1
  fi
  if other_vhost="$(selectel_cert_find_other_https_vhost "$source_vhost" "$own_vhost")"; then
    echo -e "Для сайта уже настроен HTTPS в ${YELLOW}${other_vhost}${WHITE}." >&2
    echo "Существующая SSL-конфигурация оставлена без изменений." >&2
    return 1
  fi

  selectel_cert_prepare_provider "$site_name" || return 1
  zone="$SELECTEL_CERT_ZONE"
  storage_dir="$(selectel_cert_storage_dir "$zone")"
  metadata_file="$(selectel_cert_metadata_file "$zone")"
  fullchain_file="${storage_dir}/fullchain.pem"
  private_key_file="${storage_dir}/privkey.pem"

  if [[ -d "$storage_dir" && ! -f "$metadata_file" ]]; then
    echo -e "Каталог ${YELLOW}${storage_dir}${WHITE} не имеет служебной записи RISH и оставлен без изменений." >&2
    return 1
  fi
  if [[ -f "$metadata_file" ]]; then
    if ! selectel_cert_is_owned_metadata "$metadata_file"; then
      echo -e "Файл ${YELLOW}${metadata_file}${WHITE} создан не RISH и оставлен без изменений." >&2
      return 1
    fi
    existing_certificate_id="$(
      unset SELECTEL_CERT_ID
      source "$metadata_file" >/dev/null 2>&1 || exit 1
      printf '%s' "${SELECTEL_CERT_ID:-}"
    )" || {
      echo -e "Не удалось прочитать ${YELLOW}${metadata_file}${WHITE}." >&2
      return 1
    }
    if [[ -z "$existing_certificate_id" ]]; then
      echo -e "В ${YELLOW}${metadata_file}${WHITE} отсутствует идентификатор сертификата. Установка остановлена." >&2
      return 1
    fi
  fi

  temp_dir="$(mktemp -d)" || return 1
  chmod 700 "$temp_dir" 2>/dev/null || true
  selectel_cert_choose_certificate "$source_vhost" "$temp_dir"
  rc=$?
  if ((rc != 0)); then
    rm -rf -- "$temp_dir"
    return "$rc"
  fi

  selected_certificate_id="$(jq -r '.id // empty' <<< "$SELECTEL_CERT_SELECTED_JSON")"
  if [[ -n "$existing_certificate_id" && "$existing_certificate_id" != "$selected_certificate_id" ]]; then
    other_references="$(selectel_cert_count_other_references "$fullchain_file" "$own_vhost")"
    if ((other_references > 0)); then
      echo "Этот локальный комплект используется другими vhost и не может быть заменен другим сертификатом." >&2
      rm -rf -- "$temp_dir"
      return 1
    fi
  fi

  selectel_cert_print_uncovered_aliases "$SELECTEL_CERT_SELECTED_JSON" "$source_vhost"
  echo -e "Скачиваем сертификат для ${GREEN}${site_name}${WHITE} из Selectel."
  selectel_cert_download "$SELECTEL_CERT_SELECTED_JSON" "$source_vhost" "$temp_dir" || {
    rm -rf -- "$temp_dir"
    return 1
  }
  selectel_cert_render_vhost "$source_vhost" "${temp_dir}/vhost.conf" "$fullchain_file" "$private_key_file" "$SELECTEL_CERT_SELECTED_JSON" || {
    rm -rf -- "$temp_dir"
    return 1
  }
  selectel_cert_write_metadata "$SELECTEL_CERT_SELECTED_JSON" "$zone" "$storage_dir" "${temp_dir}/metadata.conf" || {
    rm -rf -- "$temp_dir"
    return 1
  }

  mkdir -p "$storage_dir" "$RISH_SELECTEL_CERT_CONFIG_DIR" || {
    rm -rf -- "$temp_dir"
    return 1
  }
  chmod 700 "$RISH_SELECTEL_CERT_STORAGE_DIR" "$storage_dir" "$RISH_SELECTEL_CERT_CONFIG_DIR" 2>/dev/null || true

  mkdir -p "${temp_dir}/backup" || {
    rm -rf -- "$temp_dir"
    return 1
  }
  selectel_cert_backup_file "${storage_dir}/cert.pem" "${temp_dir}/backup/cert.pem" &&
    selectel_cert_backup_file "${storage_dir}/chain.pem" "${temp_dir}/backup/chain.pem" &&
    selectel_cert_backup_file "$fullchain_file" "${temp_dir}/backup/fullchain.pem" &&
    selectel_cert_backup_file "$private_key_file" "${temp_dir}/backup/privkey.pem" &&
    selectel_cert_backup_file "$metadata_file" "${temp_dir}/backup/metadata.conf" &&
    selectel_cert_backup_file "$own_vhost" "${temp_dir}/backup/vhost.conf" || {
      rm -rf -- "$temp_dir"
      echo "Не удалось создать резервную копию текущих файлов. Установка остановлена." >&2
      return 1
    }

  install -m 644 -o root -g root "${temp_dir}/cert.pem" "${storage_dir}/cert.pem" &&
    install -m 644 -o root -g root "${temp_dir}/chain.pem" "${storage_dir}/chain.pem" &&
    install -m 644 -o root -g root "${temp_dir}/fullchain.pem" "$fullchain_file" &&
    install -m 600 -o root -g root "${temp_dir}/privkey.pem" "$private_key_file" &&
    install -m 600 -o root -g root "${temp_dir}/metadata.conf" "$metadata_file" &&
    install -m 644 -o root -g root "${temp_dir}/vhost.conf" "$own_vhost" || rc=1

  if ((rc == 0)) && command -v restorecon >/dev/null 2>&1; then
    restorecon -R "$storage_dir" "$own_vhost" >/dev/null 2>&1 || true
  fi
  if ((rc == 0)) && ! apachectl configtest; then
    echo "Apache не принял новую SSL-конфигурацию. Восстанавливаем прежнее состояние." >&2
    rc=1
  fi
  if ((rc == 0)) && ! systemctl reload httpd; then
    echo "Не удалось перезагрузить Apache. Восстанавливаем прежнее состояние." >&2
    rc=1
  fi

  if ((rc != 0)); then
    selectel_cert_restore_file "${temp_dir}/backup/cert.pem" "${storage_dir}/cert.pem" 644
    selectel_cert_restore_file "${temp_dir}/backup/chain.pem" "${storage_dir}/chain.pem" 644
    selectel_cert_restore_file "${temp_dir}/backup/fullchain.pem" "$fullchain_file" 644
    selectel_cert_restore_file "${temp_dir}/backup/privkey.pem" "$private_key_file" 600
    selectel_cert_restore_file "${temp_dir}/backup/metadata.conf" "$metadata_file" 600
    selectel_cert_restore_file "${temp_dir}/backup/vhost.conf" "$own_vhost" 644
    apachectl configtest >/dev/null 2>&1 && systemctl reload httpd >/dev/null 2>&1 || true
    rmdir "$storage_dir" 2>/dev/null || true
    rm -rf -- "$temp_dir"
    return 1
  fi

  rm -rf -- "$temp_dir"
  echo -e "Сертификат Selectel установлен для сайта ${GREEN}${site_name}${WHITE}."
  echo -e "SSL-конфигурация: ${YELLOW}${own_vhost}${WHITE}"
  echo -e "Сертификат: ${YELLOW}${fullchain_file}${WHITE}"
  echo -e "Приватный ключ: ${YELLOW}${private_key_file}${WHITE}"
}

selectel_cert_apache_directive_value() {
  local vhost_file="$1"
  local directive="$2"

  awk -v directive="$directive" 'tolower($1) == tolower(directive) {print $2; exit}' "$vhost_file"
}

selectel_cert_remove_local() {
  local site_name="$1"
  local own_vhost
  local zone
  local fullchain_file
  local private_key_file
  local storage_dir
  local metadata_file
  local temp_dir
  local other_references
  local choice

  selectel_cert_require_commands apachectl systemctl install || return 1
  own_vhost="$(selectel_cert_vhost_file "$site_name")"
  if ! selectel_cert_is_owned_vhost "$own_vhost"; then
    echo "Для этого сайта не найден сертификат Selectel, установленный RISH." >&2
    return 1
  fi

  fullchain_file="$(selectel_cert_apache_directive_value "$own_vhost" SSLCertificateFile)"
  private_key_file="$(selectel_cert_apache_directive_value "$own_vhost" SSLCertificateKeyFile)"
  if [[ "$fullchain_file" != "${RISH_SELECTEL_CERT_STORAGE_DIR}/"*/fullchain.pem ]]; then
    echo "Путь сертификата в SSL-конфигурации не принадлежит каталогу RISH. Удаление остановлено." >&2
    return 1
  fi
  storage_dir="${fullchain_file%/fullchain.pem}"
  zone="${storage_dir#"${RISH_SELECTEL_CERT_STORAGE_DIR}/"}"
  if ! validate_domain "$zone" || [[ "$zone" == .* || "$zone" == *. || "$zone" == *..* ]]; then
    echo "В SSL-конфигурации указан некорректный домен. Удаление остановлено." >&2
    return 1
  fi
  metadata_file="$(selectel_cert_metadata_file "$zone")"
  if [[ "$fullchain_file" != "${storage_dir}/fullchain.pem" || "$private_key_file" != "${storage_dir}/privkey.pem" ]]; then
    echo "Служебные пути SSL-конфигурации не соответствуют путям RISH. Удаление остановлено." >&2
    return 1
  fi

  echo -e "Удалить установленный RISH сертификат Selectel с сайта ${YELLOW}${site_name}${WHITE}?"
  echo "Сертификат в Selectel удален не будет. Сайт останется доступен по HTTP."
  vertical_menu "current" 2 0 38 "Удалить с сайта" "Отмена"
  choice=$?
  [[ "$choice" == "0" ]] || return 0

  temp_dir="$(mktemp -d)" || return 1
  chmod 700 "$temp_dir" 2>/dev/null || true
  cp -p "$own_vhost" "${temp_dir}/vhost.conf" || {
    rm -rf -- "$temp_dir"
    return 1
  }
  rm -f -- "$own_vhost" || {
    rm -rf -- "$temp_dir"
    return 1
  }

  if ! apachectl configtest || ! systemctl reload httpd; then
    install -m 644 -o root -g root "${temp_dir}/vhost.conf" "$own_vhost"
    apachectl configtest >/dev/null 2>&1 && systemctl reload httpd >/dev/null 2>&1 || true
    rm -rf -- "$temp_dir"
    echo "Не удалось применить удаление SSL-конфигурации; прежний vhost восстановлен." >&2
    return 1
  fi

  other_references="$(selectel_cert_count_other_references "$fullchain_file" "$own_vhost")"
  if ((other_references == 0)); then
    rm -f -- \
      "${storage_dir}/cert.pem" \
      "${storage_dir}/chain.pem" \
      "${storage_dir}/fullchain.pem" \
      "${storage_dir}/privkey.pem" \
      "$metadata_file"
    rmdir "$storage_dir" 2>/dev/null || true
  fi

  rm -rf -- "$temp_dir"
  echo -e "Локальный сертификат Selectel удален с сайта ${GREEN}${site_name}${WHITE}."
  if ((other_references > 0)); then
    echo "Файлы сертификата сохранены: их используют другие vhost."
  fi
}

selectel_cert_menu() {
  local site_name="$1"
  local source_vhost="/etc/httpd/conf.d/${site_name}.conf"
  local own_vhost
  local choice
  local -a labels=()
  local -a actions=()

  validate_domain "$site_name" || selectel_cert_fail "Некорректное имя сайта: ${site_name}." || return 1
  [[ -f "$source_vhost" ]] || selectel_cert_fail "Не найден vhost ${source_vhost}." || return 1
  own_vhost="$(selectel_cert_vhost_file "$site_name")"

  clear
  echo -e "Сертификат Selectel для сайта ${GREEN}${site_name}${WHITE}"
  echo
  if selectel_cert_is_owned_vhost "$own_vhost"; then
    echo -e "Установленная SSL-конфигурация: ${YELLOW}${own_vhost}${WHITE}"
    labels+=("Переустановить сертификат Selectel" "Удалить установленный RISH сертификат Selectel")
    actions+=(install remove)
  else
    labels+=("Скачать и установить сертификат Selectel")
    actions+=(install)
  fi
  labels+=("Выйти")
  actions+=(exit)

  echo
  vertical_menu "current" 2 0 54 "${labels[@]}"
  choice=$?
  if ((choice == 255 || choice >= ${#actions[@]})); then
    return 0
  fi

  case "${actions[$choice]}" in
    install)
      selectel_cert_install_selected "$site_name"
      ;;
    remove)
      selectel_cert_remove_local "$site_name"
      ;;
    exit)
      return 0
      ;;
  esac
}

main() {
  local command="${1:-menu}"

  case "$command" in
    menu)
      selectel_cert_menu "${2:-}"
      ;;
    *)
      echo "Неизвестная команда: ${command}." >&2
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
