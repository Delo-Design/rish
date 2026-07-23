#!/usr/bin/env bash
# shellcheck disable=SC2155

source /root/rish/windows.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'

function collect_vhost_aliases() {
  local vhost="$1"
  local result_var="$2"
  local -n aliases_ref="$result_var"

  mapfile -t aliases_ref < <(awk '
    BEGIN{IGNORECASE=1}
    $1=="ServerAlias"{
      for(i=2;i<=NF;i++){
        if ($i ~ /^#/) break;
        print $i;
      }
    }' "$vhost")
}

function self_signed_cert_exists_for_site() {
  local site_name="$1"
  local key_file="/etc/pki/tls/private/${site_name}.key"
  local cert_file="/etc/pki/tls/certs/${site_name}.crt"
  local ssl_conf="/etc/httpd/conf.d/${site_name}-ssl.conf"

  [[ -f "$key_file" || -f "$cert_file" || -f "$ssl_conf" ]]
}

function selectel_certificate_sites() {
  local site_name
  local vhost_file
  declare -A seen_sites=()

  for vhost_file in /etc/httpd/conf.d/*-selectel-ssl.conf; do
    [[ -f "$vhost_file" ]] || continue
    if grep -Fqx '# Managed by RISH Selectel certificate integration.' "$vhost_file" &&
      grep -Eq '^[[:space:]]*SSLCertificateFile[[:space:]]+/etc/pki/tls/rish/selectel/' "$vhost_file" &&
      grep -Eq '^[[:space:]]*SSLCertificateKeyFile[[:space:]]+/etc/pki/tls/rish/selectel/' "$vhost_file"; then
      site_name="$(awk 'tolower($1)=="servername" && NF>1 {print $2; exit}' "$vhost_file")"
      [[ -n "$site_name" ]] || site_name="${vhost_file##*/}"
      site_name="${site_name%-selectel-ssl.conf}"
      if [[ -z "${seen_sites[${site_name,,}]:-}" ]]; then
        printf '%s\n' "$site_name"
        seen_sites["${site_name,,}"]=1
      fi
    fi
  done
}

function format_certificate_sites() {
  local limit=5
  local index
  local result=""
  local -a sites=("$@")

  for ((index = 0; index < ${#sites[@]} && index < limit; index++)); do
    [[ -z "$result" ]] || result+=", "
    result+="${sites[$index]}"
  done
  if ((${#sites[@]} > limit)); then
    result+=", и ещё $((${#sites[@]} - limit))"
  fi
  printf '%s' "$result"
}

function selectel_certificate_is_configured_for_site() {
  local site_name="$1"
  local vhost_file="/etc/httpd/conf.d/${site_name}-selectel-ssl.conf"
  local storage_prefix="/etc/pki/tls/rish/selectel/"

  [[ -f "$vhost_file" ]] || return 1
  grep -Fqx '# Managed by RISH Selectel certificate integration.' "$vhost_file" || return 1
  awk -v storage_prefix="$storage_prefix" '
    tolower($1)=="sslcertificatefile" && index($2, storage_prefix)==1 {certificate=1}
    tolower($1)=="sslcertificatekeyfile" && index($2, storage_prefix)==1 {private_key=1}
    END {exit !(certificate && private_key)}
  ' "$vhost_file"
}

function self_signed_certificate_is_configured_for_site() {
  local site_name="$1"
  local vhost_file="/etc/httpd/conf.d/${site_name}-ssl.conf"
  local certificate_file="/etc/pki/tls/certs/${site_name}.crt"
  local private_key_file="/etc/pki/tls/private/${site_name}.key"

  [[ -f "$vhost_file" ]] || return 1
  awk -v certificate_file="$certificate_file" -v private_key_file="$private_key_file" '
    tolower($1)=="sslcertificatefile" && $2==certificate_file {certificate=1}
    tolower($1)=="sslcertificatekeyfile" && $2==private_key_file {private_key=1}
    END {exit !(certificate && private_key)}
  ' "$vhost_file"
}

function apache_vhost_directive_value() {
  local vhost_file="$1"
  local directive="$2"

  awk -v directive="$directive" '
    tolower($1)==tolower(directive) {print $2; exit}
  ' "$vhost_file"
}

function certbot_certificate_is_configured_for_site() {
  local site_name="$1"
  local vhost_file="/etc/httpd/conf.d/${site_name}-le-ssl.conf"
  local fullchain_file
  local private_key_file
  local lineage_dir
  local lineage_name

  [[ -f "$vhost_file" ]] || return 1
  fullchain_file="$(apache_vhost_directive_value "$vhost_file" SSLCertificateFile)"
  private_key_file="$(apache_vhost_directive_value "$vhost_file" SSLCertificateKeyFile)"
  [[ "$fullchain_file" == /etc/letsencrypt/live/*/fullchain.pem ]] || return 1

  lineage_dir="${fullchain_file%/fullchain.pem}"
  lineage_name="${lineage_dir#/etc/letsencrypt/live/}"
  [[ -n "$lineage_name" && "$lineage_name" != */* ]] || return 1
  [[ "$private_key_file" == "${lineage_dir}/privkey.pem" ]]
}

function certbot_certificate_sites() {
  local site_name
  local vhost_file
  local fullchain_file
  local private_key_file
  local lineage_dir
  declare -A seen_sites=()

  for vhost_file in /etc/httpd/conf.d/*.conf; do
    [[ -f "$vhost_file" ]] || continue
    fullchain_file="$(apache_vhost_directive_value "$vhost_file" SSLCertificateFile)"
    private_key_file="$(apache_vhost_directive_value "$vhost_file" SSLCertificateKeyFile)"
    [[ "$fullchain_file" == /etc/letsencrypt/live/*/fullchain.pem ]] || continue
    lineage_dir="${fullchain_file%/fullchain.pem}"
    [[ "$private_key_file" == "${lineage_dir}/privkey.pem" ]] || continue

    site_name="$(apache_vhost_directive_value "$vhost_file" ServerName)"
    [[ -n "$site_name" ]] || site_name="${vhost_file##*/}"
    site_name="${site_name%.conf}"
    if [[ -z "${seen_sites[${site_name,,}]:-}" ]]; then
      printf '%s\n' "$site_name"
      seen_sites["${site_name,,}"]=1
    fi
  done
}

function print_configured_certificate_type() {
  local site_name="$1"
  local certificate_types_text
  local -a certificate_types=()

  if selectel_certificate_is_configured_for_site "$site_name"; then
    certificate_types+=("Selectel")
  fi
  if self_signed_certificate_is_configured_for_site "$site_name"; then
    certificate_types+=("самоподписанный")
  fi
  if certbot_certificate_is_configured_for_site "$site_name"; then
    certificate_types+=("Let’s Encrypt")
  fi

  if ((${#certificate_types[@]} == 0)); then
    echo -e "Сертификат: ${YELLOW}не настроен${WHITE}"
  elif ((${#certificate_types[@]} == 1)); then
    certificate_types_text="${certificate_types[0]}"
    echo -e "Используется сертификат: ${YELLOW}${certificate_types_text}${WHITE}"
  else
    printf -v certificate_types_text '%s, ' "${certificate_types[@]}"
    certificate_types_text="${certificate_types_text%, }"
    echo -e "Настроены SSL-конфигурации: ${YELLOW}${certificate_types_text}${WHITE}"
  fi
  echo
}

function selectel_certificate_script_path() {
  local selectel_certificate_script="/root/rish/scripts/certificates/selectel.sh"

  if [[ ! -f "$selectel_certificate_script" ]]; then
    selectel_certificate_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/certificates/selectel.sh"
  fi
  [[ -f "$selectel_certificate_script" ]] || return 1
  printf '%s' "$selectel_certificate_script"
}

function run_selectel_certificate_command() {
  local selectel_certificate_script

  if ! selectel_certificate_script="$(selectel_certificate_script_path)"; then
    echo "Не найден скрипт управления сертификатами Selectel." >&2
    return 1
  fi
  bash "$selectel_certificate_script" "$@"
}

function selectel_certificate_sync_is_ready() {
  local sync_timer="rish-selectel-certificates-sync.timer"

  command -v systemctl >/dev/null 2>&1 &&
    systemctl is-enabled --quiet "$sync_timer" 2>/dev/null &&
    systemctl is-active --quiet "$sync_timer" 2>/dev/null
}

function find_other_vhost_certificate_reference() {
  local certificate_file="$1"
  local private_key_file="$2"
  local excluded_vhost="$3"
  local vhost_file

  for vhost_file in /etc/httpd/conf.d/*.conf; do
    [[ -f "$vhost_file" && "$vhost_file" != "$excluded_vhost" ]] || continue
    if awk -v certificate_file="$certificate_file" -v private_key_file="$private_key_file" '
      tolower($1)=="sslcertificatefile" && $2==certificate_file {found=1}
      tolower($1)=="sslcertificatekeyfile" && $2==private_key_file {found=1}
      END {exit !found}
    ' "$vhost_file"; then
      printf '%s' "$vhost_file"
      return 0
    fi
  done

  return 1
}

function remove_selectel_certificate_for_site() {
  local site_name="$1"

  run_selectel_certificate_command remove-local "$site_name"
}

function remove_self_signed_certificate_for_site() {
  local site_name="$1"
  local vhost_file="/etc/httpd/conf.d/${site_name}-ssl.conf"
  local certificate_file="/etc/pki/tls/certs/${site_name}.crt"
  local private_key_file="/etc/pki/tls/private/${site_name}.key"
  local other_vhost=""
  local temp_dir
  local choice

  if ! self_signed_certificate_is_configured_for_site "$site_name"; then
    echo "Для этого сайта не найдена самоподписанная SSL-конфигурация RISH." >&2
    return 1
  fi
  if ! command -v apachectl >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
    echo "Не найдены команды для проверки и перезагрузки Apache." >&2
    return 1
  fi

  echo -e "Удалить самоподписанный сертификат с сайта ${YELLOW}${site_name}${WHITE}?"
  echo "Сайт останется доступен по HTTP."
  vertical_menu "current" 2 0 38 "Удалить с сайта" "Отмена"
  choice=$?
  [[ "$choice" == "0" ]] || return 0

  other_vhost="$(find_other_vhost_certificate_reference \
    "$certificate_file" "$private_key_file" "$vhost_file")" || other_vhost=""
  temp_dir="$(mktemp -d)" || return 1
  chmod 700 "$temp_dir" 2>/dev/null || true
  cp -p "$vhost_file" "${temp_dir}/vhost.conf" || {
    rm -rf -- "$temp_dir"
    return 1
  }
  rm -f -- "$vhost_file" || {
    rm -rf -- "$temp_dir"
    return 1
  }

  if ! apachectl configtest || ! systemctl reload httpd; then
    if cp -p "${temp_dir}/vhost.conf" "$vhost_file" &&
      apachectl configtest >/dev/null 2>&1 &&
      systemctl reload httpd >/dev/null 2>&1; then
      echo "Не удалось применить удаление SSL-конфигурации; прежний vhost восстановлен." >&2
      rm -rf -- "$temp_dir"
    else
      echo "Не удалось применить удаление SSL-конфигурации и полностью восстановить прежний vhost." >&2
      echo -e "Резервная копия сохранена: ${YELLOW}${temp_dir}/vhost.conf${WHITE}" >&2
    fi
    return 1
  fi

  if [[ -n "$other_vhost" ]]; then
    echo -e "Файлы сертификата сохранены: их использует ${YELLOW}${other_vhost}${WHITE}."
  elif ! rm -f -- "$certificate_file" "$private_key_file"; then
    rm -rf -- "$temp_dir"
    echo "SSL-конфигурация удалена, но удалить файлы самоподписанного сертификата полностью не удалось." >&2
    return 1
  fi

  rm -rf -- "$temp_dir"
  echo -e "Самоподписанный сертификат удален с сайта ${GREEN}${site_name}${WHITE}."
}

function revoke_certbot_certificate_for_site() {
  local site_name="$1"
  local vhost_file="/etc/httpd/conf.d/${site_name}-le-ssl.conf"
  local fullchain_file
  local private_key_file
  local lineage_dir
  local certificate_file
  local other_vhost=""
  local temp_dir
  local choice
  local required_command

  if ! certbot_certificate_is_configured_for_site "$site_name"; then
    echo "Для этого сайта не найдена SSL-конфигурация Let’s Encrypt." >&2
    return 1
  fi
  for required_command in certbot apachectl systemctl; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
      echo -e "Не найдена необходимая команда ${YELLOW}${required_command}${WHITE}." >&2
      return 1
    fi
  done

  fullchain_file="$(apache_vhost_directive_value "$vhost_file" SSLCertificateFile)"
  private_key_file="$(apache_vhost_directive_value "$vhost_file" SSLCertificateKeyFile)"
  lineage_dir="${fullchain_file%/fullchain.pem}"
  certificate_file="${lineage_dir}/cert.pem"
  if [[ ! -f "$certificate_file" ]]; then
    echo -e "Не найден сертификат Certbot: ${YELLOW}${certificate_file}${WHITE}." >&2
    return 1
  fi
  if other_vhost="$(find_other_vhost_certificate_reference \
    "$fullchain_file" "$private_key_file" "$vhost_file")"; then
    echo -e "Сертификат Certbot также использует ${YELLOW}${other_vhost}${WHITE}." >&2
    echo "Автоматический отзыв остановлен, чтобы не нарушить работу другого vhost." >&2
    return 1
  fi

  echo -e "Отозвать и удалить сертификат Let’s Encrypt для сайта ${YELLOW}${site_name}${WHITE}?"
  echo "Сайт останется доступен по HTTP."
  vertical_menu "current" 2 0 42 "Отозвать и удалить" "Отмена"
  choice=$?
  [[ "$choice" == "0" ]] || return 0

  temp_dir="$(mktemp -d)" || return 1
  chmod 700 "$temp_dir" 2>/dev/null || true
  cp -p "$vhost_file" "${temp_dir}/vhost.conf" || {
    rm -rf -- "$temp_dir"
    return 1
  }
  rm -f -- "$vhost_file" || {
    rm -rf -- "$temp_dir"
    return 1
  }

  if ! apachectl configtest || ! systemctl reload httpd; then
    if cp -p "${temp_dir}/vhost.conf" "$vhost_file" &&
      apachectl configtest >/dev/null 2>&1 &&
      systemctl reload httpd >/dev/null 2>&1; then
      echo "Не удалось применить удаление SSL-конфигурации; прежний vhost восстановлен." >&2
      rm -rf -- "$temp_dir"
    else
      echo "Не удалось применить удаление SSL-конфигурации и полностью восстановить прежний vhost." >&2
      echo -e "Резервная копия сохранена: ${YELLOW}${temp_dir}/vhost.conf${WHITE}" >&2
    fi
    return 1
  fi

  if ! certbot revoke \
    --cert-path "$certificate_file" \
    --delete-after-revoke \
    --non-interactive; then
    echo "Не удалось полностью отозвать и удалить сертификат Certbot." >&2
    echo "SSL-конфигурация сайта удалена; сайт оставлен на HTTP, поскольку состояние отзыва неизвестно." >&2
    if [[ -f "$certificate_file" ]]; then
      echo -e "Lineage Certbot сохранен в ${YELLOW}${lineage_dir}${WHITE} для повторной попытки." >&2
    else
      echo "Файлы lineage уже удалены. Проверьте журнал Certbot, чтобы уточнить результат отзыва." >&2
    fi
    rm -rf -- "$temp_dir"
    return 1
  fi

  rm -rf -- "$temp_dir"
  echo -e "Сертификат Let’s Encrypt отозван и удален для сайта ${GREEN}${site_name}${WHITE}."
}

function remove_configured_certificate_for_site() {
  local site_name="$1"
  local action
  local choice
  local -a actions=()
  local -a labels=()

  if selectel_certificate_is_configured_for_site "$site_name"; then
    actions+=("selectel")
    labels+=("Удалить локальный сертификат Selectel")
  fi
  if self_signed_certificate_is_configured_for_site "$site_name"; then
    actions+=("self-signed")
    labels+=("Удалить самоподписанный сертификат")
  fi
  if certbot_certificate_is_configured_for_site "$site_name"; then
    actions+=("certbot")
    labels+=("Отозвать и удалить сертификат Let’s Encrypt")
  fi

  if ((${#actions[@]} == 0)); then
    echo -e "Для сайта ${YELLOW}${site_name}${WHITE} не найдена поддерживаемая SSL-конфигурация."
    return 0
  fi

  if ((${#actions[@]} == 1)); then
    action="${actions[0]}"
  else
    echo -e "Для сайта ${YELLOW}${site_name}${WHITE} найдено несколько SSL-конфигураций."
    vertical_menu "current" 2 0 52 "${labels[@]}" "Отмена"
    choice=$?
    if ((choice == 255 || choice >= ${#actions[@]})); then
      return 0
    fi
    action="${actions[$choice]}"
  fi

  case "$action" in
    selectel)
      remove_selectel_certificate_for_site "$site_name"
      ;;
    self-signed)
      remove_self_signed_certificate_for_site "$site_name"
      ;;
    certbot)
      revoke_certbot_certificate_for_site "$site_name"
      ;;
  esac
}

function print_selectel_certificate_sync_warning() {
  local sync_service="rish-selectel-certificates-sync.service"
  local sync_timer="rish-selectel-certificates-sync.timer"
  local followup_message=""
  local sites_text
  local -a selectel_sites=()

  mapfile -t selectel_sites < <(selectel_certificate_sites)
  ((${#selectel_sites[@]} > 0)) || return 0

  if command -v systemctl >/dev/null 2>&1 &&
    systemctl is-enabled --quiet "$sync_timer" 2>/dev/null &&
    systemctl is-active --quiet "$sync_timer" 2>/dev/null &&
    ! systemctl is-failed --quiet "$sync_service" 2>/dev/null; then
    return
  fi

  if command -v systemctl >/dev/null 2>&1 &&
    systemctl is-failed --quiet "$sync_service" 2>/dev/null; then
    echo -e "Последняя автоматическая синхронизация сертификатов Selectel ${YELLOW}завершилась ошибкой${WHITE}."
    followup_message="Подробности: journalctl -u ${sync_service}"
  elif command -v systemctl >/dev/null 2>&1 &&
    systemctl is-enabled --quiet "$sync_timer" 2>/dev/null; then
    echo -e "Автоматическая синхронизация сертификатов Selectel ${YELLOW}включена, но timer не активен${WHITE}."
  else
    echo -e "Автоматическая синхронизация сертификатов Selectel ${YELLOW}не включена${WHITE}."
    followup_message="Включить её можно в основном меню сертификатов."
  fi
  sites_text="$(format_certificate_sites "${selectel_sites[@]}")"
  echo -e "SSL-конфигурации Selectel найдены для: ${YELLOW}${sites_text}${WHITE}."
  [[ -z "$followup_message" ]] || echo "$followup_message"
  echo
}

function print_certbot_certificate_renewal_warning() {
  local renew_service="certbot-renew.service"
  local renew_timer="certbot-renew.timer"
  local followup_message=""
  local sites_text
  local -a certbot_sites=()

  mapfile -t certbot_sites < <(certbot_certificate_sites)
  ((${#certbot_sites[@]} > 0)) || return 0

  if command -v certbot >/dev/null 2>&1 &&
    command -v systemctl >/dev/null 2>&1 &&
    systemctl cat "$renew_timer" >/dev/null 2>&1 &&
    systemctl is-enabled --quiet "$renew_timer" 2>/dev/null &&
    systemctl is-active --quiet "$renew_timer" 2>/dev/null &&
    ! systemctl is-failed --quiet "$renew_service" 2>/dev/null; then
    return
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    echo -e "Для установленных сертификатов Let’s Encrypt команда ${YELLOW}certbot не найдена${WHITE}."
  elif ! command -v systemctl >/dev/null 2>&1; then
    echo -e "Не удалось проверить автоматическое обновление Certbot: команда ${YELLOW}systemctl не найдена${WHITE}."
  elif ! systemctl cat "$renew_timer" >/dev/null 2>&1; then
    echo -e "Для установленных сертификатов Let’s Encrypt timer ${YELLOW}${renew_timer} не найден${WHITE}."
  elif systemctl is-failed --quiet "$renew_service" 2>/dev/null; then
    echo -e "Последнее автоматическое обновление сертификатов Certbot ${YELLOW}завершилось ошибкой${WHITE}."
    followup_message="Подробности: journalctl -u ${renew_service}"
  elif systemctl is-enabled --quiet "$renew_timer" 2>/dev/null; then
    echo -e "Автоматическое обновление сертификатов Certbot ${YELLOW}включено, но timer не активен${WHITE}."
  else
    echo -e "Для установленных сертификатов Certbot автоматическое обновление ${YELLOW}не включено${WHITE}."
    followup_message="Включить timer: systemctl enable --now ${renew_timer}"
  fi
  sites_text="$(format_certificate_sites "${certbot_sites[@]}")"
  echo -e "SSL-конфигурации Certbot найдены для: ${YELLOW}${sites_text}${WHITE}."
  echo "Автоматическое обновление этих сертификатов требует внимания."
  [[ -z "$followup_message" ]] || echo "$followup_message"
  echo
}

function create_self_signed_cert_for_site() {
  local site_name="$1"
  local vhost="/etc/httpd/conf.d/${site_name}.conf"
  local server_name
  local ttssl="${site_name}-ssl.conf"
  local tmpcfg="rish_temp_file_for_creating_selfsigned_cert.txt"
  local openssl_error_file="rish_temp_file_for_openssl_error.txt"
  local key_file="/etc/pki/tls/private/${site_name}.key"
  local cert_file="/etc/pki/tls/certs/${site_name}.crt"
  local ssl_conf="/etc/httpd/conf.d/${ttssl}"
  local choice
  local old_pwd
  local rc=0
  local i
  local d
  local a
  local -a aliases_flat=()
  local -a aliases=()
  local -a all_dns=()
  declare -A seen=()
  declare -A dns_seen=()

  if [[ ! -f "$vhost" ]]; then
    echo -e "${RED}${site_name}${WHITE} это не сайт (не vhost)"
    return 1
  fi

  if [[ -f "$key_file" || -f "$cert_file" || -f "$ssl_conf" ]]; then
    echo -e "Для сайта ${GREEN}${site_name}${WHITE} уже найден самоподписанный SSL:"
    [[ -f "$cert_file" ]] && echo -e "  сертификат: ${YELLOW}${cert_file}${WHITE}"
    [[ -f "$key_file" ]] && echo -e "  ключ: ${YELLOW}${key_file}${WHITE}"
    [[ -f "$ssl_conf" ]] && echo -e "  vhost: ${YELLOW}${ttssl}${WHITE}"
    vertical_menu "current" 2 0 38 \
      "Перевыпустить сертификат" \
      "Оставить существующий" \
      "Выйти"
    choice=$?
    case "$choice" in
      0)
        ;;
      1)
        echo "Существующий self-signed SSL оставлен без изменений."
        return 0
        ;;
      *)
        echo "Создание self-signed SSL отменено."
        return 0
        ;;
    esac
  fi

  server_name="$(awk 'BEGIN{IGNORECASE=1} $1=="ServerName"{print $2; exit}' "$vhost")"
  [[ -z "$server_name" ]] && server_name="$site_name"

  collect_vhost_aliases "$vhost" aliases_flat
  for a in "${aliases_flat[@]}"; do
    [[ -z "$a" ]] && continue
    [[ "$a" == "$server_name" ]] && continue
    [[ "$a" == \** ]] && continue
    if [[ -z "${seen[$a]}" ]]; then
      aliases+=("$a")
      seen["$a"]=1
    fi
  done

  all_dns+=("$server_name")
  dns_seen["$server_name"]=1
  for a in "${aliases[@]}"; do
    if [[ -z "${dns_seen[$a]}" ]]; then
      all_dns+=("$a")
      dns_seen["$a"]=1
    fi
  done

  old_pwd="$PWD"
  cd /etc/httpd/conf.d || return 1
  rm -f "${site_name}-ssl"* "$openssl_error_file" 2>/dev/null

  {
    echo "[req]"
    echo "distinguished_name = req_distinguished_name"
    echo "x509_extensions = v3_req"
    echo "prompt = no"
    echo "[req_distinguished_name]"
    echo "CN = ${server_name}"
    echo "[v3_req]"
    echo "keyUsage = critical, digitalSignature, keyAgreement"
    echo "extendedKeyUsage = serverAuth"
    echo "subjectAltName = @alt_names"
    echo "[alt_names]"
    i=1
    for d in "${all_dns[@]}"; do
      echo "DNS.$i = $d"
      ((i++))
    done
  } >"$tmpcfg"

  echo -e "Создаем самоподписанный SSL сертификат для сайта ${GREEN}${site_name}${WHITE}."
  if ! openssl req -x509 -nodes \
    -newkey rsa:2048 \
    -keyout "$key_file" \
    -out "$cert_file" \
    -sha256 \
    -days 3650 \
    -subj "/CN=${server_name}" \
    -config "$tmpcfg" \
    2>"$openssl_error_file"; then
    rm -f "$tmpcfg"
    echo -e "Не удалось создать самоподписанный SSL-сертификат для ${RED}${site_name}${WHITE}."
    if [[ -s "$openssl_error_file" ]]; then
      echo -e "${YELLOW}openssl:${WHITE}"
      sed 's/^/  /' "$openssl_error_file"
    fi
    rm -f "$openssl_error_file"
    cd "$old_pwd" || true
    return 1
  fi

  rm -f "$tmpcfg" "$openssl_error_file"

  if ! cp "${site_name}.conf" "$ttssl"; then
    cd "$old_pwd" || true
    return 1
  fi
  sed -E -i 's#(<VirtualHost[[:space:]]+)([^>]*):80>#\1\2:443>#g' "$ttssl"
  sed -i "/<\/VirtualHost>/i ServerSignature Off\nSSLCertificateFile /etc/pki/tls/certs/${site_name}.crt\nSSLCertificateKeyFile /etc/pki/tls/private/${site_name}.key" "$ttssl"

  if apachectl configtest; then
    systemctl reload httpd
    echo "Сервер перезагружен."
  else
    echo -e "Сервер не был перезагружен. ${RED}Ошибка${WHITE} в конфигурации Apache."
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    echo -e "Самоподписанный SSL сертификат для сайта ${GREEN}${site_name}${WHITE} создан."
  fi

  cd "$old_pwd" || true
  return "$rc"
}

certs() {
  clear
  local site_name="$1"
  local vhost="/etc/httpd/conf.d/${site_name}.conf"

  echo -e "Сертификат для сайта ${GREEN}${site_name}${WHITE}"
  echo

  if [[ ! -f "$vhost" ]]; then
    echo -e "${RED}${site_name}${WHITE} это не сайт (не vhost)"
    return 1
  fi

  # ---- 1) ServerName ----
  local server_name
  local -a aliases_flat=()
  server_name=$(awk 'BEGIN{IGNORECASE=1} $1=="ServerName"{print $2; exit}' "$vhost")
  [[ -z "$server_name" ]] && server_name="$site_name"

  # ---- 2) ServerAlias: извлекаем по словам до комментария, учитываем несколько алиасов в строке ----
  collect_vhost_aliases "$vhost" aliases_flat

  # ---- 3) Нормализуем: без дублей, без wildcard, без самого server_name ----
  declare -A seen=()
  declare -a aliases=()
  for a in "${aliases_flat[@]}"; do
    [[ -z "$a" ]] && continue
    [[ "$a" == "$server_name" ]] && continue
    [[ "$a" == \** ]] && continue     # wildcard не берём для HTTP-01
    if [[ -z "${seen[$a]}" ]]; then
      aliases+=("$a")
      seen["$a"]=1
    fi
  done

  # ---- 4) Вывод списка с подсветкой ----
  echo "Основной домен:"
  echo -e "${GREEN}${server_name}${WHITE}"
  echo
  echo "Список алиасов:"
  if ((${#aliases[@]}==0)); then
    echo "—"
  else
    for alias in "${aliases[@]}"; do
      if [[ "$alias" == *".${server_name}" ]]; then
        # подсветка хвоста (поддомен базового домена)
        local prefix="${alias%.$server_name}"
        echo -e "${prefix}.${GREEN}${server_name}${WHITE}"
      else
        echo "$alias"
      fi
    done
  fi
  echo

  print_configured_certificate_type "$site_name"
  print_selectel_certificate_sync_warning
  print_certbot_certificate_renewal_warning

  # ---- 5) Меню ----
  local action
  local choice
  local has_configured_certificate=0
  local certbot_available=0
  local has_selectel_certificates=0
  local uses_selectel_certificate=0
  local -a certificate_menu_actions=()
  local -a certificate_menu_items=()
  local -a installed_selectel_sites=()

  mapfile -t installed_selectel_sites < <(selectel_certificate_sites)
  if command -v certbot >/dev/null 2>&1; then
    certbot_available=1
  fi
  if ((${#installed_selectel_sites[@]} > 0)); then
    has_selectel_certificates=1
  fi
  if selectel_certificate_is_configured_for_site "$site_name"; then
    has_configured_certificate=1
    uses_selectel_certificate=1
  fi
  if self_signed_certificate_is_configured_for_site "$site_name" ||
    certbot_certificate_is_configured_for_site "$site_name"; then
    has_configured_certificate=1
  fi
  if ((has_configured_certificate == 0)); then
    if ((certbot_available == 1)); then
      certificate_menu_items+=(
        "Certbot: получить для www.${site_name} и ${site_name}"
        "Certbot: получить только для ${site_name}"
        "Certbot: получить для всех алиасов и ${site_name}"
      )
      certificate_menu_actions+=(
        certbot-www
        certbot-site
        certbot-aliases
      )
    else
      echo -e "Certbot: ${YELLOW}не установлен${WHITE}; варианты Let’s Encrypt недоступны."
      echo
    fi
    certificate_menu_items+=("Создать самоподписанный для всех алиасов")
    certificate_menu_actions+=(self-signed)
    certificate_menu_items+=("Скачать и установить сертификат Selectel")
    certificate_menu_actions+=(selectel-install)
  elif ((uses_selectel_certificate == 1)); then
    certificate_menu_items+=("Переустановить сертификат Selectel")
    certificate_menu_actions+=(selectel-install)
  fi
  if ((has_selectel_certificates == 1)); then
    if selectel_certificate_sync_is_ready; then
      certificate_menu_items+=("Выключить автоматическую синхронизацию Selectel")
      certificate_menu_actions+=(selectel-sync-disable)
    else
      certificate_menu_items+=("Включить автоматическую синхронизацию Selectel")
      certificate_menu_actions+=(selectel-sync-enable)
    fi
  fi
  if ((has_configured_certificate == 1)); then
    certificate_menu_items+=("Удалить/отозвать сертификат для ${site_name}")
    certificate_menu_actions+=(remove)
  fi
  certificate_menu_items+=("Выйти")
  certificate_menu_actions+=(exit)

  vertical_menu "current" 2 0 6 "${certificate_menu_items[@]}"
  choice=$?
  if ((choice == 255 || choice >= ${#certificate_menu_actions[@]})); then
    return 0
  fi
  action="${certificate_menu_actions[$choice]}"

  case "$action" in
  certbot-www)
    certbot --apache -d "$site_name" -d "www.${site_name}"
    ;;
  certbot-site)
    certbot --apache -d "$site_name"
    ;;
  certbot-aliases)
    # все алиасы из конфига + базовый, без дублей
    declare -A used=()
    declare -a args=()
    used["$server_name"]=1
    args+=(-d "$server_name")
    for a in "${aliases[@]}"; do
      if [[ -z "${used[$a]}" ]]; then
        args+=(-d "$a")
        used["$a"]=1
      fi
    done
    certbot --apache "${args[@]}"
    ;;
  self-signed)
    create_self_signed_cert_for_site "$site_name"
    echo
    ;;
  selectel-install)
    run_selectel_certificate_command install "$site_name"
    ;;
  selectel-sync-enable)
    run_selectel_certificate_command sync-enable
    ;;
  selectel-sync-disable)
    run_selectel_certificate_command sync-disable
    ;;
  remove)
    remove_configured_certificate_for_site "$site_name"
    ;;
  exit)
    return 0
    ;;
  esac
}

# Если идёт прямой вызов — выполняем функцию.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  certs "$1"
  vertical_menu "current" 2 0 5 "Нажмите Enter"
fi
