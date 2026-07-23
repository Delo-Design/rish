#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034

umask 077

SELECTEL_SYNC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RISH_HOME="${RISH_HOME:-/root/rish}"
SELECTEL_CERTIFICATE_SCRIPT="${RISH_HOME}/scripts/certificates/selectel.sh"
SELECTEL_SYNC_SERVICE="rish-selectel-certificates-sync.service"
SELECTEL_SYNC_TIMER="rish-selectel-certificates-sync.timer"
SELECTEL_SYNC_SYSTEMD_DIR="/etc/systemd/system"
declare -a SELECTEL_SYNC_CHANGED_ZONES=()
declare -a SELECTEL_SYNC_CHANGED_STORAGE_DIRS=()
declare -a SELECTEL_SYNC_CHANGED_METADATA_FILES=()
declare -a SELECTEL_SYNC_CHANGED_BACKUP_DIRS=()
declare -a SELECTEL_SYNC_PENDING_ZONES=()
declare -a SELECTEL_SYNC_PENDING_STORAGE_DIRS=()
declare -a SELECTEL_SYNC_PENDING_METADATA_FILES=()
declare -a SELECTEL_SYNC_PENDING_ITEM_DIRS=()
SELECTEL_SYNC_RUN_DIR=""
SELECTEL_SYNC_ROLLBACK_ARMED=0
SELECTEL_SYNC_KEEP_RUN_DIR=0

if [[ ! -f "$SELECTEL_CERTIFICATE_SCRIPT" ]]; then
  SELECTEL_CERTIFICATE_SCRIPT="${SELECTEL_SYNC_SCRIPT_DIR}/selectel.sh"
fi
if [[ ! -f "$SELECTEL_CERTIFICATE_SCRIPT" ]]; then
  echo "Не найден скрипт управления сертификатами Selectel." >&2
  exit 1
fi

source "$SELECTEL_CERTIFICATE_SCRIPT"

selectel_sync_log() {
  printf '[RISH Selectel] %s\n' "$*"
}

selectel_sync_template_dir() {
  local template_dir="${RISH_HOME}/templates/systemd"

  if [[ ! -d "$template_dir" ]]; then
    template_dir="${SELECTEL_SYNC_SCRIPT_DIR}/../../templates/systemd"
  fi
  printf '%s' "$template_dir"
}

selectel_sync_enable() {
  local template_dir

  selectel_cert_require_commands install systemctl || return 1
  template_dir="$(selectel_sync_template_dir)"
  if [[ ! -f "${template_dir}/${SELECTEL_SYNC_SERVICE}" ||
    ! -f "${template_dir}/${SELECTEL_SYNC_TIMER}" ]]; then
    echo "Не найдены шаблоны systemd для синхронизации сертификатов Selectel." >&2
    return 1
  fi

  install -m 644 -o root -g root \
    "${template_dir}/${SELECTEL_SYNC_SERVICE}" \
    "${SELECTEL_SYNC_SYSTEMD_DIR}/${SELECTEL_SYNC_SERVICE}" || return 1
  install -m 644 -o root -g root \
    "${template_dir}/${SELECTEL_SYNC_TIMER}" \
    "${SELECTEL_SYNC_SYSTEMD_DIR}/${SELECTEL_SYNC_TIMER}" || return 1
  systemctl daemon-reload || return 1
  systemctl enable --now "$SELECTEL_SYNC_TIMER" || return 1

  echo "Автоматическая синхронизация сертификатов Selectel включена."
  systemctl list-timers "$SELECTEL_SYNC_TIMER" --no-pager
}

selectel_sync_disable() {
  selectel_cert_require_commands systemctl || return 1

  systemctl disable --now "$SELECTEL_SYNC_TIMER" || return 1
  echo "Автоматическая синхронизация сертификатов Selectel выключена."
}

selectel_sync_collect_vhosts() {
  local fullchain_file="$1"
  local result_var="$2"
  local -n result_ref="$result_var"
  local vhost_file

  result_ref=()
  for vhost_file in /etc/httpd/conf.d/*-selectel-ssl.conf; do
    [[ -f "$vhost_file" ]] || continue
    selectel_cert_is_owned_vhost "$vhost_file" || continue
    if awk -v fullchain_file="$fullchain_file" '
      tolower($1)=="sslcertificatefile" && $2==fullchain_file {found=1}
      END {exit !found}
    ' "$vhost_file"; then
      result_ref+=("$vhost_file")
    fi
  done
}

selectel_sync_validate_vhost_metadata_links() {
  local vhost_file
  local fullchain_file
  local storage_dir
  local zone
  local metadata_file
  local metadata_fullchain
  local status=0

  for vhost_file in /etc/httpd/conf.d/*-selectel-ssl.conf; do
    [[ -f "$vhost_file" ]] || continue
    selectel_cert_is_owned_vhost "$vhost_file" || continue

    fullchain_file="$(selectel_cert_apache_directive_value "$vhost_file" SSLCertificateFile)"
    if [[ "$fullchain_file" != "${RISH_SELECTEL_CERT_STORAGE_DIR}/"*/fullchain.pem ]]; then
      selectel_sync_log "${vhost_file}: некорректный путь сертификата Selectel."
      status=1
      continue
    fi

    storage_dir="${fullchain_file%/fullchain.pem}"
    zone="${storage_dir#"${RISH_SELECTEL_CERT_STORAGE_DIR}/"}"
    if ! validate_domain "$zone" ||
      [[ "$storage_dir" != "$(selectel_cert_storage_dir "$zone")" ]]; then
      selectel_sync_log "${vhost_file}: не удалось определить DNS-зону сертификата Selectel."
      status=1
      continue
    fi

    metadata_file="$(selectel_cert_metadata_file "$zone")"
    if ! selectel_cert_is_owned_metadata "$metadata_file"; then
      selectel_sync_log "${vhost_file}: не найдены metadata RISH Selectel ${metadata_file}."
      status=1
      continue
    fi

    metadata_fullchain="$(
      unset SELECTEL_CERT_ZONE SELECTEL_CERT_FULLCHAIN
      source "$metadata_file" >/dev/null 2>&1 || exit 1
      [[ "${SELECTEL_CERT_ZONE:-}" == "$zone" ]] || exit 1
      printf '%s' "${SELECTEL_CERT_FULLCHAIN:-}"
    )" || {
      selectel_sync_log "${vhost_file}: не удалось проверить metadata ${metadata_file}."
      status=1
      continue
    }
    if [[ "$metadata_fullchain" != "$fullchain_file" ]]; then
      selectel_sync_log "${vhost_file}: metadata ${metadata_file} ссылаются на другой сертификат."
      status=1
    fi
  done

  return "$status"
}

selectel_sync_installed_bundle_needs_update() {
  local storage_dir="$1"
  local fullchain_file="$2"
  local private_key_file="$3"
  local current_version="$4"
  local current_knox_cert_id="$5"
  local remote_version="$6"
  local remote_knox_cert_id="$7"
  local certificate_fingerprint
  local fullchain_fingerprint
  local key_fingerprint

  [[ "$current_version" == "$remote_version" ]] || return 0
  [[ "$current_knox_cert_id" == "$remote_knox_cert_id" ]] || return 0
  [[ -s "${storage_dir}/cert.pem" &&
    -s "${storage_dir}/chain.pem" &&
    -s "$fullchain_file" &&
    -s "$private_key_file" ]] || return 0
  openssl x509 -in "${storage_dir}/cert.pem" -checkend 604800 -noout >/dev/null 2>&1 || return 0
  openssl crl2pkcs7 -nocrl -certfile "$fullchain_file" 2>/dev/null |
    openssl pkcs7 -print_certs -noout >/dev/null 2>&1 || return 0
  openssl crl2pkcs7 -nocrl -certfile "${storage_dir}/chain.pem" 2>/dev/null |
    openssl pkcs7 -print_certs -noout >/dev/null 2>&1 || return 0

  certificate_fingerprint="$(selectel_cert_public_key_fingerprint certificate "${storage_dir}/cert.pem")"
  fullchain_fingerprint="$(selectel_cert_public_key_fingerprint certificate "$fullchain_file")"
  key_fingerprint="$(selectel_cert_public_key_fingerprint private_key "$private_key_file")"
  [[ -n "$certificate_fingerprint" &&
    "$certificate_fingerprint" == "$fullchain_fingerprint" &&
    "$certificate_fingerprint" == "$key_fingerprint" ]] || return 0

  return 1
}

selectel_sync_restore_bundle() {
  local backup_dir="$1"
  local storage_dir="$2"
  local metadata_file="$3"
  local status=0

  selectel_cert_restore_file "${backup_dir}/cert.pem" "${storage_dir}/cert.pem" 644 || status=1
  selectel_cert_restore_file "${backup_dir}/chain.pem" "${storage_dir}/chain.pem" 644 || status=1
  selectel_cert_restore_file "${backup_dir}/fullchain.pem" "${storage_dir}/fullchain.pem" 644 || status=1
  selectel_cert_restore_file "${backup_dir}/privkey.pem" "${storage_dir}/privkey.pem" 600 || status=1
  selectel_cert_restore_file "${backup_dir}/metadata.conf" "$metadata_file" 600 || status=1
  return "$status"
}

selectel_sync_prepare_bundle() {
  local metadata_file="$1"
  local run_dir="$2"
  local result_index="$3"
  local zone
  local dns_config
  local certificate_id
  local current_version
  local current_knox_cert_id
  local storage_dir
  local fullchain_file
  local private_key_file
  local list_file
  local certificate_json
  local status
  local remote_version
  local remote_knox_cert_id
  local item_dir
  local vhost_file
  local -a vhost_files=()
  local -a vhost_names=()

  if ! selectel_cert_is_owned_metadata "$metadata_file"; then
    selectel_sync_log "Пропуск ${metadata_file}: metadata не принадлежит RISH."
    return 1
  fi

  unset \
    SELECTEL_CERT_ZONE \
    SELECTEL_DNS_CONFIG \
    SELECTEL_CERT_ID \
    SELECTEL_KNOX_CERT_ID \
    SELECTEL_CERT_VERSION \
    SELECTEL_CERT_DIRECTORY \
    SELECTEL_CERT_FULLCHAIN \
    SELECTEL_CERT_PRIVATE_KEY
  source "$metadata_file" >/dev/null 2>&1 || {
    selectel_sync_log "Не удалось прочитать ${metadata_file}."
    return 1
  }

  zone="${SELECTEL_CERT_ZONE:-}"
  dns_config="${SELECTEL_DNS_CONFIG:-}"
  certificate_id="${SELECTEL_CERT_ID:-}"
  current_version="${SELECTEL_CERT_VERSION:-0}"
  current_knox_cert_id="${SELECTEL_KNOX_CERT_ID:-}"
  storage_dir="${SELECTEL_CERT_DIRECTORY:-}"
  fullchain_file="${SELECTEL_CERT_FULLCHAIN:-}"
  private_key_file="${SELECTEL_CERT_PRIVATE_KEY:-}"

  if ! validate_domain "$zone" ||
    [[ "$metadata_file" != "$(selectel_cert_metadata_file "$zone")" ]] ||
    [[ "$storage_dir" != "$(selectel_cert_storage_dir "$zone")" ]] ||
    [[ "$fullchain_file" != "${storage_dir}/fullchain.pem" ]] ||
    [[ "$private_key_file" != "${storage_dir}/privkey.pem" ]] ||
    [[ -z "$certificate_id" || -z "$dns_config" ]]; then
    selectel_sync_log "Некорректные metadata сертификата ${metadata_file}; комплект оставлен без изменений."
    return 1
  fi

  selectel_sync_collect_vhosts "$fullchain_file" vhost_files
  if ((${#vhost_files[@]} == 0)); then
    selectel_sync_log "Для ${zone} не найден активный RISH Selectel vhost; синхронизация пропущена."
    return 0
  fi
  if [[ ! -f "$dns_config" ]]; then
    selectel_sync_log "Для ${zone} не найдены сохранённые credentials Selectel: ${dns_config}."
    return 1
  fi

  unset \
    DNS_PROVIDER \
    SELECTEL_USERNAME \
    SELECTEL_PASSWORD \
    SELECTEL_ACCOUNT_ID \
    SELECTEL_PROJECT_NAME \
    SELECTEL_TOKEN \
    SELECTEL_TOKEN_EXPIRES_EPOCH
  source "$dns_config" >/dev/null 2>&1 || {
    selectel_sync_log "Не удалось прочитать credentials Selectel для ${zone}."
    return 1
  }
  if [[ "${DNS_PROVIDER:-}" != "selectel" ||
    -z "${SELECTEL_USERNAME:-}" ||
    -z "${SELECTEL_PASSWORD:-}" ||
    -z "${SELECTEL_ACCOUNT_ID:-}" ||
    -z "${SELECTEL_PROJECT_NAME:-}" ]]; then
    selectel_sync_log "Credentials Selectel для ${zone} заполнены не полностью."
    return 1
  fi

  SELECTEL_CERT_ZONE="$zone"
  SELECTEL_CERT_DNS_CONFIG="$dns_config"
  DNS_DOMAIN="$zone"
  load_provider selectel
  provider_auth || {
    selectel_sync_log "Не удалось авторизоваться в Selectel для ${zone}."
    return 1
  }

  item_dir="${run_dir}/item-${result_index}"
  mkdir -p "$item_dir" || return 1
  list_file="${item_dir}/certificates.json"
  selectel_cert_list_to_file "$list_file" || {
    selectel_sync_log "Не удалось получить список сертификатов Selectel для ${zone}."
    return 1
  }
  certificate_json="$(
    jq -c --arg certificate_id "$certificate_id" \
      '.items[]? | select(((.id // "") | tostring) == $certificate_id)' \
      "$list_file" | head -n 1
  )"
  if [[ -z "$certificate_json" ]]; then
    selectel_sync_log "Сертификат ${certificate_id} для ${zone} больше не найден в Selectel."
    return 1
  fi

  status="$(jq -r '(.status // "") | ascii_upcase' <<< "$certificate_json")"
  case "$status" in
    ACTIVE|RENEWING|ISSUED)
      ;;
    *)
      selectel_sync_log "Сертификат ${certificate_id} для ${zone} имеет статус ${status:-UNKNOWN}; обновление пропущено."
      return 1
      ;;
  esac
  remote_version="$(jq -r '(.version // 0) | tostring' <<< "$certificate_json")"
  remote_knox_cert_id="$(jq -r '.knox_cert_id // empty' <<< "$certificate_json")"
  if [[ -z "$remote_knox_cert_id" ]]; then
    selectel_sync_log "У сертификата ${certificate_id} для ${zone} отсутствует Knox ID."
    return 1
  fi

  for vhost_file in "${vhost_files[@]}"; do
    selectel_cert_collect_vhost_names "$vhost_file" vhost_names
    if ! selectel_cert_json_covers_names "$certificate_json" vhost_names; then
      selectel_sync_log "Сертификат ${certificate_id} больше не покрывает все имена ${vhost_file}."
      return 1
    fi
  done

  if ! selectel_sync_installed_bundle_needs_update \
    "$storage_dir" \
    "$fullchain_file" \
    "$private_key_file" \
    "$current_version" \
    "$current_knox_cert_id" \
    "$remote_version" \
    "$remote_knox_cert_id"; then
    selectel_sync_log "Сертификат для ${zone} актуален."
    return 0
  fi

  selectel_sync_log "Получена новая версия сертификата для ${zone}; проверяем комплект."
  selectel_cert_download "$certificate_json" "${vhost_files[0]}" "$item_dir" || {
    selectel_sync_log "Не удалось скачать или проверить сертификат для ${zone}."
    return 1
  }
  for vhost_file in "${vhost_files[@]:1}"; do
    selectel_cert_validate_download \
      "${item_dir}/cert.pem" \
      "${item_dir}/chain.pem" \
      "${item_dir}/privkey.pem" \
      "$vhost_file" \
      "$certificate_json" || {
      selectel_sync_log "Новый сертификат для ${zone} не подходит к ${vhost_file}."
      return 1
    }
  done
  selectel_cert_write_metadata "$certificate_json" "$zone" "$storage_dir" "${item_dir}/metadata.conf" || return 1

  SELECTEL_SYNC_PENDING_ZONES+=("$zone")
  SELECTEL_SYNC_PENDING_STORAGE_DIRS+=("$storage_dir")
  SELECTEL_SYNC_PENDING_METADATA_FILES+=("$metadata_file")
  SELECTEL_SYNC_PENDING_ITEM_DIRS+=("$item_dir")
}

selectel_sync_install_prepared_bundles() {
  local index
  local zone
  local storage_dir
  local metadata_file
  local item_dir
  local backup_dir

  for ((index = 0; index < ${#SELECTEL_SYNC_PENDING_ZONES[@]}; index++)); do
    zone="${SELECTEL_SYNC_PENDING_ZONES[$index]}"
    storage_dir="${SELECTEL_SYNC_PENDING_STORAGE_DIRS[$index]}"
    metadata_file="${SELECTEL_SYNC_PENDING_METADATA_FILES[$index]}"
    item_dir="${SELECTEL_SYNC_PENDING_ITEM_DIRS[$index]}"
    backup_dir="${SELECTEL_SYNC_RUN_DIR}/backup-${index}"

    mkdir -p "$backup_dir" || return 1
    selectel_cert_backup_file "${storage_dir}/cert.pem" "${backup_dir}/cert.pem" &&
      selectel_cert_backup_file "${storage_dir}/chain.pem" "${backup_dir}/chain.pem" &&
      selectel_cert_backup_file "${storage_dir}/fullchain.pem" "${backup_dir}/fullchain.pem" &&
      selectel_cert_backup_file "${storage_dir}/privkey.pem" "${backup_dir}/privkey.pem" &&
      selectel_cert_backup_file "$metadata_file" "${backup_dir}/metadata.conf" || {
        selectel_sync_log "Не удалось создать резервную копию сертификата для ${zone}."
        return 1
      }

    SELECTEL_SYNC_CHANGED_ZONES+=("$zone")
    SELECTEL_SYNC_CHANGED_STORAGE_DIRS+=("$storage_dir")
    SELECTEL_SYNC_CHANGED_METADATA_FILES+=("$metadata_file")
    SELECTEL_SYNC_CHANGED_BACKUP_DIRS+=("$backup_dir")
    SELECTEL_SYNC_ROLLBACK_ARMED=1

    mkdir -p "$storage_dir" || {
      selectel_sync_log "Не удалось создать каталог сертификата для ${zone}."
      return 1
    }
    chmod 700 "$RISH_SELECTEL_CERT_STORAGE_DIR" "$storage_dir" 2>/dev/null || true
    install -m 644 -o root -g root "${item_dir}/cert.pem" "${storage_dir}/cert.pem" &&
      install -m 644 -o root -g root "${item_dir}/chain.pem" "${storage_dir}/chain.pem" &&
      install -m 644 -o root -g root "${item_dir}/fullchain.pem" "${storage_dir}/fullchain.pem" &&
      install -m 600 -o root -g root "${item_dir}/privkey.pem" "${storage_dir}/privkey.pem" &&
      install -m 600 -o root -g root "${item_dir}/metadata.conf" "$metadata_file" || {
        selectel_sync_log "Не удалось установить новую версию сертификата для ${zone}."
        return 1
      }

    if command -v restorecon >/dev/null 2>&1; then
      restorecon -R "$storage_dir" >/dev/null 2>&1 || true
    fi
  done
}

selectel_sync_rollback_all() {
  local index
  local status=0

  for ((index = ${#SELECTEL_SYNC_CHANGED_ZONES[@]} - 1; index >= 0; index--)); do
    selectel_sync_restore_bundle \
      "${SELECTEL_SYNC_CHANGED_BACKUP_DIRS[$index]}" \
      "${SELECTEL_SYNC_CHANGED_STORAGE_DIRS[$index]}" \
      "${SELECTEL_SYNC_CHANGED_METADATA_FILES[$index]}" || status=1
  done
  if ((status == 0)); then
    SELECTEL_SYNC_ROLLBACK_ARMED=0
  fi
  return "$status"
}

selectel_sync_abort() {
  trap - INT TERM HUP
  selectel_sync_log "Синхронизация прервана системным сигналом."

  if [[ "$SELECTEL_SYNC_ROLLBACK_ARMED" -eq 1 ]]; then
    selectel_sync_log "Восстанавливаем прежние версии сертификатов."
    if selectel_sync_rollback_all; then
      apachectl configtest >/dev/null 2>&1 && systemctl reload httpd >/dev/null 2>&1 || true
    else
      SELECTEL_SYNC_KEEP_RUN_DIR=1
      selectel_sync_log "Откат выполнен не полностью; Apache не перезагружен."
    fi
  fi
  if [[ -n "$SELECTEL_SYNC_RUN_DIR" ]]; then
    if [[ "$SELECTEL_SYNC_KEEP_RUN_DIR" -eq 1 ]]; then
      selectel_sync_log "Резервные копии сохранены в ${SELECTEL_SYNC_RUN_DIR}."
    else
      rm -rf -- "$SELECTEL_SYNC_RUN_DIR"
    fi
  fi
  exit 1
}

selectel_sync_run() {
  local run_dir
  local metadata_file
  local status=0
  local result_index=0
  local lock_fd
  local -a metadata_files=()

  selectel_cert_require_commands \
    apachectl \
    base64 \
    curl \
    flock \
    install \
    jq \
    openssl \
    sha256sum \
    systemctl || return 1

  exec {lock_fd}> "$RISH_SELECTEL_CERT_LOCK_FILE" || {
    selectel_sync_log "Не удалось открыть lock-файл ${RISH_SELECTEL_CERT_LOCK_FILE}."
    return 1
  }
  if ! flock -n "$lock_fd"; then
    selectel_sync_log "Другая операция с сертификатами Selectel уже выполняется; запуск пропущен."
    return 0
  fi

  run_dir="$(mktemp -d)" || {
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  }
  SELECTEL_SYNC_RUN_DIR="$run_dir"
  trap selectel_sync_abort INT TERM HUP
  chmod 700 "$run_dir" 2>/dev/null || true
  SELECTEL_SYNC_CHANGED_ZONES=()
  SELECTEL_SYNC_CHANGED_STORAGE_DIRS=()
  SELECTEL_SYNC_CHANGED_METADATA_FILES=()
  SELECTEL_SYNC_CHANGED_BACKUP_DIRS=()
  SELECTEL_SYNC_PENDING_ZONES=()
  SELECTEL_SYNC_PENDING_STORAGE_DIRS=()
  SELECTEL_SYNC_PENDING_METADATA_FILES=()
  SELECTEL_SYNC_PENDING_ITEM_DIRS=()
  SELECTEL_SYNC_ROLLBACK_ARMED=0
  SELECTEL_SYNC_KEEP_RUN_DIR=0

  shopt -s nullglob
  metadata_files=("${RISH_SELECTEL_CERT_CONFIG_DIR}"/*.conf)
  shopt -u nullglob
  selectel_sync_validate_vhost_metadata_links || status=1
  if ((${#metadata_files[@]} == 0)); then
    if ((status == 0)); then
      selectel_sync_log "Локальные сертификаты Selectel не найдены."
    else
      selectel_sync_log "Для установленных Selectel-vhost отсутствуют корректные metadata."
    fi
    trap - INT TERM HUP
    rm -rf -- "$run_dir"
    SELECTEL_SYNC_RUN_DIR=""
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return "$status"
  fi

  for metadata_file in "${metadata_files[@]}"; do
    ((result_index++))
    selectel_sync_prepare_bundle "$metadata_file" "$run_dir" "$result_index" || status=1
  done

  if ((${#SELECTEL_SYNC_PENDING_ZONES[@]} > 0)); then
    if ! selectel_sync_install_prepared_bundles; then
      selectel_sync_log "Не удалось установить подготовленные сертификаты; восстанавливаем прежние версии."
      if ! selectel_sync_rollback_all; then
        SELECTEL_SYNC_KEEP_RUN_DIR=1
        selectel_sync_log "Откат выполнен не полностью; резервные копии будут сохранены."
      fi
      status=1
    elif ! apachectl configtest; then
      selectel_sync_log "Apache не принял обновлённые сертификаты; восстанавливаем прежние версии."
      if ! selectel_sync_rollback_all; then
        SELECTEL_SYNC_KEEP_RUN_DIR=1
        selectel_sync_log "Откат выполнен не полностью; резервные копии будут сохранены."
      fi
      status=1
    elif ! systemctl reload httpd; then
      selectel_sync_log "Не удалось перезагрузить Apache; восстанавливаем прежние версии сертификатов."
      if selectel_sync_rollback_all; then
        apachectl configtest >/dev/null 2>&1 && systemctl reload httpd >/dev/null 2>&1 || true
      else
        SELECTEL_SYNC_KEEP_RUN_DIR=1
        selectel_sync_log "Откат выполнен не полностью; Apache повторно не перезагружен."
      fi
      status=1
    else
      selectel_sync_log "Apache перечитал обновлённые сертификаты: ${SELECTEL_SYNC_CHANGED_ZONES[*]}."
      SELECTEL_SYNC_ROLLBACK_ARMED=0
    fi
  fi

  trap - INT TERM HUP
  if [[ "$SELECTEL_SYNC_KEEP_RUN_DIR" -eq 1 ]]; then
    selectel_sync_log "Резервные копии сохранены в ${run_dir}."
  else
    rm -rf -- "$run_dir"
  fi
  SELECTEL_SYNC_RUN_DIR=""
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  return "$status"
}

main() {
  local command="${1:-run}"

  case "$command" in
    run)
      selectel_sync_run
      ;;
    enable)
      selectel_sync_enable
      ;;
    disable)
      selectel_sync_disable
      ;;
    status)
      systemctl is-enabled "$SELECTEL_SYNC_TIMER"
      systemctl is-active "$SELECTEL_SYNC_TIMER"
      systemctl list-timers "$SELECTEL_SYNC_TIMER" --no-pager
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
