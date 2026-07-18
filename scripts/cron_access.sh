#!/usr/bin/env bash

RISH_CRON_ALLOW_FILE="/etc/cron.allow"
RISH_CRON_ALLOW_BACKUP="${RISH_CRON_ALLOW_FILE}.rish-backup"

cron_allow_is_secure() {
  [[ -f "$RISH_CRON_ALLOW_FILE" && ! -L "$RISH_CRON_ALLOW_FILE" ]] || return 1
  [[ "$(stat -c '%U:%G' "$RISH_CRON_ALLOW_FILE" 2>/dev/null)" == "root:root" ]] || return 1
  [[ "$(stat -c '%a' "$RISH_CRON_ALLOW_FILE" 2>/dev/null)" == "644" ]] || return 1
  cmp -s "$RISH_CRON_ALLOW_FILE" <(printf 'root\n')
}

configure_cron_allow() {
  local temp_file

  cron_allow_is_secure && return 0

  if [[ -L "$RISH_CRON_ALLOW_FILE" ]]; then
    echo "Отказ: ${RISH_CRON_ALLOW_FILE} является символической ссылкой."
    return 1
  fi
  if [[ -e "$RISH_CRON_ALLOW_FILE" && ! -f "$RISH_CRON_ALLOW_FILE" ]]; then
    echo "Отказ: ${RISH_CRON_ALLOW_FILE} не является обычным файлом."
    return 1
  fi
  if [[ -L "$RISH_CRON_ALLOW_BACKUP" ]]; then
    echo "Отказ: ${RISH_CRON_ALLOW_BACKUP} является символической ссылкой."
    return 1
  fi
  if [[ -e "$RISH_CRON_ALLOW_BACKUP" && ! -f "$RISH_CRON_ALLOW_BACKUP" ]]; then
    echo "Отказ: ${RISH_CRON_ALLOW_BACKUP} не является обычным файлом."
    return 1
  fi

  temp_file="$(mktemp "${RISH_CRON_ALLOW_FILE}.rish-tmp.XXXXXX")" || return 1
  if ! printf 'root\n' > "$temp_file" ||
     ! chown root:root "$temp_file" ||
     ! chmod 644 "$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi

  if [[ -f "$RISH_CRON_ALLOW_FILE" && ! -e "$RISH_CRON_ALLOW_BACKUP" ]]; then
    if ! install -o root -g root -m 600 "$RISH_CRON_ALLOW_FILE" "$RISH_CRON_ALLOW_BACKUP"; then
      rm -f "$temp_file"
      return 1
    fi
  fi

  if ! mv -f -- "$temp_file" "$RISH_CRON_ALLOW_FILE"; then
    rm -f "$temp_file"
    return 1
  fi

  cron_allow_is_secure
}
