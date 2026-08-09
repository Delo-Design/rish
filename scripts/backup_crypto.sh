#!/usr/bin/env bash

# Общие функции шифрования архивов RISH.
# Файл предназначен для source из backup2.sh и archive.sh.

BACKUP_ARCHIVE_MODE=""
BACKUP_ARCHIVE_POLICY_ERROR=""
BACKUP_AGE_RECIPIENTS=()
BACKUP_AGE_ARGS=()

backup_crypto_trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

backup_crypto_has_typographic_dash() {
  case "$1" in
    *'‐'*|*'‑'*|*'‒'*|*'–'*|*'—'*|*'−'*|*'－'*) return 0 ;;
    *) return 1 ;;
  esac
}

backup_crypto_line_is_key_end() {
  local line="$1"
  local key_type="$2"

  case "$key_type" in
    age)
      [[ "$line" == *"END AGE ENCRYPTED FILE"* ]]
      return
      ;;
    ssh)
      case "$line" in
        *"END OPENSSH PRIVATE KEY"*|*"END RSA PRIVATE KEY"*|*"END PRIVATE KEY"*|*"END ENCRYPTED PRIVATE KEY"*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

backup_crypto_warn_typographic_dash() {
  echo -e "В текстовом блоке найдено ${YELLOW}типографское тире${WHITE} вместо обычного дефиса ${YELLOW}-${WHITE}."
  echo "Мессенджер или редактор изменил строки BEGIN/END."
  echo "Скопируйте ключ заново как обычный текст либо передайте его как файл без форматирования."
}

backup_crypto_available() {
  command -v age >/dev/null 2>&1
}

backup_crypto_keygen_available() {
  command -v age-keygen >/dev/null 2>&1
}

backup_parse_archive_policy() {
  local value
  local normalized
  local recipients_value
  local recipient
  local -a recipients=()
  local -A seen=()

  value="$(backup_crypto_trim "$1")"
  normalized="${value,,}"
  BACKUP_ARCHIVE_MODE="invalid"
  BACKUP_ARCHIVE_POLICY_ERROR=""
  BACKUP_AGE_RECIPIENTS=()
  BACKUP_AGE_ARGS=()

  case "$normalized" in
    yes|y|true|on|archive|да)
      BACKUP_ARCHIVE_MODE="plain"
      return 0
      ;;
    no|n|false|off|нет)
      BACKUP_ARCHIVE_MODE="disabled"
      return 0
      ;;
  esac

  if [[ "$normalized" != crypto:* ]]; then
    if [[ -z "$value" ]]; then
      BACKUP_ARCHIVE_POLICY_ERROR="режим архивации не указан"
    elif [[ "$normalized" == "crypto" ]]; then
      BACKUP_ARCHIVE_POLICY_ERROR="после crypto: не указаны публичные ключи"
    else
      BACKUP_ARCHIVE_POLICY_ERROR="неизвестный режим архивации '${value}'"
    fi
    return 1
  fi

  recipients_value="${value#*:}"
  if [[ -z "$(backup_crypto_trim "$recipients_value")" ]]; then
    BACKUP_ARCHIVE_POLICY_ERROR="после crypto: не указаны публичные ключи"
    return 1
  fi

  local IFS=','
  read -r -a recipients <<< "$recipients_value"
  if ((${#recipients[@]} > 2)); then
    BACKUP_ARCHIVE_POLICY_ERROR="поддерживается не больше двух публичных ключей"
    return 1
  fi

  for recipient in "${recipients[@]}"; do
    recipient="$(backup_crypto_trim "$recipient")"
    if [[ -z "$recipient" ]]; then
      BACKUP_ARCHIVE_POLICY_ERROR="в списке публичных ключей найдено пустое значение"
      return 1
    fi
    if [[ "$recipient" =~ ^(ssh-ed25519|ssh-rsa)[[:space:]]+([A-Za-z0-9+/]+={0,2})$ ]]; then
      recipient="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    elif [[ ! "$recipient" =~ ^age1[023456789acdefghjklmnpqrstuvwxyz]+$ ]]; then
      BACKUP_ARCHIVE_POLICY_ERROR="указанное значение не является поддерживаемым публичным ключом age или SSH"
      return 1
    fi
    if [[ -n "${seen[$recipient]+x}" ]]; then
      BACKUP_ARCHIVE_POLICY_ERROR="один и тот же публичный ключ указан дважды"
      return 1
    fi
    seen["$recipient"]=1
    BACKUP_AGE_RECIPIENTS+=("$recipient")
    BACKUP_AGE_ARGS+=(-r "$recipient")
  done

  BACKUP_ARCHIVE_MODE="crypto"
  return 0
}

backup_validate_age_recipients() {
  if [[ "$BACKUP_ARCHIVE_MODE" != "crypto" || ${#BACKUP_AGE_ARGS[@]} -eq 0 ]]; then
    BACKUP_ARCHIVE_POLICY_ERROR="не подготовлен список публичных ключей age"
    return 1
  fi
  if ! backup_crypto_available; then
    BACKUP_ARCHIVE_POLICY_ERROR="команда age не установлена"
    return 1
  fi

  if ! age "${BACKUP_AGE_ARGS[@]}" </dev/null >/dev/null 2>&1; then
    BACKUP_ARCHIVE_POLICY_ERROR="age отклонил один или несколько публичных ключей"
    return 1
  fi
  return 0
}

backup_crypto_policy_value() {
  local recipient
  local value="crypto:"
  local separator=""

  for recipient in "$@"; do
    value+="${separator}${recipient}"
    separator=","
  done
  printf '%s' "$value"
}

backup_crypto_short_recipient() {
  local recipient="$1"
  local key_type key_data

  if [[ "$recipient" =~ ^(ssh-ed25519|ssh-rsa)[[:space:]]+(.+)$ ]]; then
    key_type="${BASH_REMATCH[1]}"
    key_data="${BASH_REMATCH[2]}"
    if ((${#key_data} <= 20)); then
      printf '%s %s' "$key_type" "$key_data"
    else
      printf '%s %s…%s' "$key_type" "${key_data:0:10}" "${key_data: -8}"
    fi
    return
  fi

  if ((${#recipient} <= 24)); then
    printf '%s' "$recipient"
  else
    printf '%s…%s' "${recipient:0:14}" "${recipient: -8}"
  fi
}
