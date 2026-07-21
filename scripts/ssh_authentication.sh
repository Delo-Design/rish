#!/usr/bin/env bash

# This module is sourced by ri.sh, postupdate.sh and rish_check.sh and uses their color globals.
# shellcheck disable=SC2154
RISH_SSH_CONFIG_DIR="/etc/ssh/sshd_config.d"
RISH_SSH_CONFIG_FILE="${RISH_SSH_CONFIG_DIR}/00-rish.conf"
RISH_SFTP_AUTHORIZED_KEYS_DIR="/etc/ssh/authorized_keys"

get_sftp_users() {
  local user

  while IFS=: read -r user _; do
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sftp; then
      echo "$user"
    fi
  done < <(getent passwd)
}

render_rish_ssh_config() {
  local password_authentication="$1"

  [[ "$password_authentication" == "yes" || "$password_authentication" == "no" ]] || return 1
  cat <<EOF
# Managed by RISH
PasswordAuthentication ${password_authentication}
KbdInteractiveAuthentication no

Match Group sftp
    AuthorizedKeysFile ${RISH_SFTP_AUTHORIZED_KEYS_DIR}/%u
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    DisableForwarding yes
    PermitTTY no
    PermitUserRC no
    ForceCommand internal-sftp -u 022
    ChrootDirectory /var/www/%u

Match all
EOF
}

rish_ssh_config_matches() {
  local password_authentication="$1"

  [[ -f "$RISH_SSH_CONFIG_FILE" ]] || return 1
  render_rish_ssh_config "$password_authentication" | cmp -s - "$RISH_SSH_CONFIG_FILE"
}

get_effective_ssh_authentication() {
  local sshd_config
  local option
  local value
  local password_authentication=""
  local kbd_interactive_authentication=""

  sshd_config="$(sshd -T 2>/dev/null)" || return 1

  while read -r option value _; do
    case "$option" in
      passwordauthentication)
        password_authentication="$value"
        ;;
      kbdinteractiveauthentication)
        kbd_interactive_authentication="$value"
        ;;
    esac
  done <<<"$sshd_config"

  [[ -n "$password_authentication" && -n "$kbd_interactive_authentication" ]] || return 1
  printf '%s %s\n' "$password_authentication" "$kbd_interactive_authentication"
}

print_effective_ssh_authentication() {
  local effective_settings
  local password_authentication
  local kbd_interactive_authentication

  effective_settings="$(get_effective_ssh_authentication)" || return 1
  read -r password_authentication kbd_interactive_authentication <<<"$effective_settings"
  echo "PasswordAuthentication ${password_authentication}"
  echo "KbdInteractiveAuthentication ${kbd_interactive_authentication}"
}

sftp_security_is_effective() {
  local user="$1"
  local sshd_config
  local option
  local value
  local rest
  local authorized_keys_file=""
  local password_authentication=""
  local kbd_interactive_authentication=""
  local disable_forwarding=""
  local permit_tty=""
  local permit_user_rc=""
  local force_command=""
  local chroot_directory=""

  sshd_config="$(sshd -T -C "user=${user},host=localhost,addr=127.0.0.1" 2>/dev/null)" || return 1

  while read -r option value rest; do
    case "$option" in
      authorizedkeysfile)
        authorized_keys_file="${value}${rest:+ ${rest}}"
        ;;
      passwordauthentication)
        password_authentication="$value"
        ;;
      kbdinteractiveauthentication)
        kbd_interactive_authentication="$value"
        ;;
      disableforwarding)
        disable_forwarding="$value"
        ;;
      permittty)
        permit_tty="$value"
        ;;
      permituserrc)
        permit_user_rc="$value"
        ;;
      forcecommand)
        force_command="${value}${rest:+ ${rest}}"
        ;;
      chrootdirectory)
        chroot_directory="$value"
        ;;
    esac
  done <<<"$sshd_config"

  [[ "$authorized_keys_file" == "${RISH_SFTP_AUTHORIZED_KEYS_DIR}/%u" ]] || return 1
  [[ "$password_authentication" == "no" ]] || return 1
  [[ "$kbd_interactive_authentication" == "no" ]] || return 1
  [[ "$disable_forwarding" == "yes" ]] || return 1
  [[ "$permit_tty" == "no" ]] || return 1
  [[ "$permit_user_rc" == "no" ]] || return 1
  [[ "$force_command" == "internal-sftp -u 022" ]] || return 1
  [[ "$chroot_directory" == "/var/www/%u" ]]
}

ensure_sftp_authorized_keys_file() {
  local user="$1"
  local source_file="/home/${user}/.ssh/authorized_keys"
  local target_file="${RISH_SFTP_AUTHORIZED_KEYS_DIR}/${user}"
  local temp_file

  id "$user" >/dev/null 2>&1 || return 1
  install -d -m 755 -o root -g root "$RISH_SFTP_AUTHORIZED_KEYS_DIR" || return 1

  if [[ -e "$target_file" || -L "$target_file" ]]; then
    [[ -f "$target_file" && ! -L "$target_file" ]] || return 1
  fi
  if [[ -e "$source_file" || -L "$source_file" ]]; then
    [[ -f "$source_file" && ! -L "$source_file" ]] || return 1
  fi

  if [[ -f "$source_file" ]]; then
    temp_file="$(mktemp "${RISH_SFTP_AUTHORIZED_KEYS_DIR}/.${user}.rish-tmp.XXXXXX")" || return 1
    if [[ -f "$target_file" ]]; then
      awk '!seen[$0]++' "$target_file" "$source_file" >"$temp_file" || {
        rm -f "$temp_file"
        return 1
      }
    else
      cp "$source_file" "$temp_file" || {
        rm -f "$temp_file"
        return 1
      }
    fi
    if ! chown root:root "$temp_file" || ! chmod 644 "$temp_file" || ! mv -f "$temp_file" "$target_file"; then
      rm -f "$temp_file"
      return 1
    fi
  elif [[ ! -f "$target_file" ]]; then
    install -m 644 -o root -g root /dev/null "$target_file" || return 1
  else
    chown root:root "$target_file" || return 1
    chmod 644 "$target_file" || return 1
  fi
}

prepare_sftp_authorized_keys() {
  local user

  install -d -m 755 -o root -g root "$RISH_SFTP_AUTHORIZED_KEYS_DIR" || return 1
  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    if ! ensure_sftp_authorized_keys_file "$user"; then
      echo -e "${RED}Не удалось подготовить ключи SFTP для пользователя ${user}.${WHITE}"
      return 1
    fi
  done < <(get_sftp_users)
}

sftp_authorized_keys_are_secure() {
  local user
  local target_file

  [[ -d "$RISH_SFTP_AUTHORIZED_KEYS_DIR" && ! -L "$RISH_SFTP_AUTHORIZED_KEYS_DIR" ]] || return 1
  [[ "$(stat -c '%U:%G %a' "$RISH_SFTP_AUTHORIZED_KEYS_DIR" 2>/dev/null)" == "root:root 755" ]] || return 1

  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    target_file="${RISH_SFTP_AUTHORIZED_KEYS_DIR}/${user}"
    [[ -f "$target_file" && ! -L "$target_file" ]] || return 1
    [[ "$(stat -c '%U:%G %a' "$target_file" 2>/dev/null)" == "root:root 644" ]] || return 1
  done < <(get_sftp_users)
}

print_sftp_authorized_key_summary() {
  local key_file="$1"
  local summary
  local line
  local fingerprint
  local details
  local key_type
  local comment
  local source_count
  local parsed_count

  source_count="$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$key_file")"
  summary="$(LC_ALL=C ssh-keygen -lf "$key_file" 2>/dev/null || true)"
  parsed_count="$(printf '%s\n' "$summary" | awk 'NF { count++ } END { print count + 0 }')"

  if [[ "$parsed_count" -eq 0 ]]; then
    echo "  - ключи отсутствуют"
  else
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      line="${line#* }"
      fingerprint="${line%% *}"
      details="${line#* }"
      key_type="${details##* (}"
      key_type="${key_type%)}"
      comment="${details% (${key_type})}"

      if [[ -z "$comment" || "$comment" == "no comment" ]]; then
        printf '  - %s — %b (%s)\n' "$fingerprint" "${YELLOW}комментарий отсутствует${WHITE}" "$key_type"
      else
        printf '  - %s — %b (%s)\n' "$fingerprint" "${YELLOW}${comment}${WHITE}" "$key_type"
      fi
    done <<<"$summary"
  fi

  if [[ "$parsed_count" -lt "$source_count" ]]; then
    echo -e "  - ${YELLOW}часть строк не распознана как публичные SSH-ключи; требуется ручная проверка${WHITE}"
  fi
}

remove_old_sftp_authorized_keys() {
  local user
  local source_file
  local source_summary

  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    source_file="/home/${user}/.ssh/authorized_keys"
    if [[ -f "$source_file" && ! -L "$source_file" ]]; then
      source_summary="$(LC_ALL=C ssh-keygen -lf "$source_file" 2>/dev/null || true)"
      if rm -f "$source_file"; then
        if [[ -n "$source_summary" ]]; then
          SFTP_KEYS_MIGRATED=1
          echo
          echo -e "Перенос ключей пользователя ${YELLOW}${user}${WHITE}:"
          echo -e "  Файл: ${YELLOW}${RISH_SFTP_AUTHORIZED_KEYS_DIR}/${user}${WHITE}"
          print_sftp_authorized_key_summary "${RISH_SFTP_AUTHORIZED_KEYS_DIR}/${user}"
        fi
      else
        echo -e "${YELLOW}Старый файл ${source_file} не удалён, но SSH больше его не использует.${WHITE}"
      fi
    fi
  done < <(get_sftp_users)
}

write_sshd_config_without_trailing_legacy_rish_match() {
  local sshd_config="$1"
  local output_file="$2"

  [[ -f "$sshd_config" ]] || return 1
  awk '
    { lines[NR] = $0 }
    END {
      legacy_start = 0
      for (i = 1; i <= NR - 2; i++) {
        if (lines[i] == "Match Group sftp" &&
            lines[i + 1] == "ChrootDirectory /var/www/%u" &&
            lines[i + 2] == "ForceCommand internal-sftp -u 022") {
          only_comments_follow = 1
          for (j = i + 3; j <= NR; j++) {
            if (lines[j] !~ /^[[:space:]]*(#.*)?$/) {
              only_comments_follow = 0
              break
            }
          }
          if (only_comments_follow) {
            legacy_start = i
          }
        }
      }

      if (legacy_start == 0) {
        exit 1
      }

      for (i = 1; i <= NR; i++) {
        if (i < legacy_start || i > legacy_start + 2) {
          print lines[i]
        }
      }
    }
  ' "$sshd_config" >"$output_file"
}

legacy_rish_sftp_match_is_at_end() {
  write_sshd_config_without_trailing_legacy_rish_match /etc/ssh/sshd_config /dev/null
}

rish_sftp_configuration_is_secure() {
  local effective_settings
  local password_authentication
  local kbd_interactive_authentication
  local user

  effective_settings="$(get_effective_ssh_authentication)" || return 1
  read -r password_authentication kbd_interactive_authentication <<<"$effective_settings"
  [[ "$password_authentication" == "yes" || "$password_authentication" == "no" ]] || return 1
  [[ "$kbd_interactive_authentication" == "no" ]] || return 1
  rish_ssh_config_matches "$password_authentication" || return 1
  sftp_authorized_keys_are_secure || return 1
  legacy_rish_sftp_match_is_at_end && return 1

  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    sftp_security_is_effective "$user" || return 1
  done < <(get_sftp_users)

  return 0
}

restore_rish_ssh_files() {
  local had_config="$1"
  local backup_file="$2"
  local changed_sshd_config="$3"
  local sshd_backup="$4"
  local sshd_config="/etc/ssh/sshd_config"

  if [[ "$had_config" -eq 1 ]]; then
    mv -f "$backup_file" "$RISH_SSH_CONFIG_FILE" || return 1
  else
    rm -f "$RISH_SSH_CONFIG_FILE" || return 1
  fi
  if [[ "$changed_sshd_config" -eq 1 ]]; then
    mv -f "$sshd_backup" "$sshd_config" || return 1
  fi
}

print_ssh_config_priority_error() {
  echo -e "${RED}Не удалось применить${WHITE} настройки авторизации SSH."
  echo -e "Файлы конфигурации SSH читаются из ${YELLOW}/etc/ssh${WHITE}, включая ${YELLOW}/etc/ssh/sshd_config${WHITE}"
  echo -e "и файлы ${YELLOW}/etc/ssh/sshd_config.d/*.conf${WHITE}. Для большинства параметров используется первое найденное значение."
  echo -e "Возможно, существует файл с именем, имеющим более высокий приоритет, чем ${YELLOW}00-rish.conf${WHITE},"
  echo -e "либо настройка задана в основном ${YELLOW}sshd_config${WHITE} до директивы ${YELLOW}Include${WHITE}."
  echo -e "Проверьте фактическую конфигурацию командой ${YELLOW}sshd -T${WHITE}."
}

configure_ssh_password_authentication() {
  local target_value="$1"
  local temp_file="${RISH_SSH_CONFIG_FILE}.tmp.$$"
  local backup_file="${RISH_SSH_CONFIG_FILE}.bak.$$"
  local sshd_config="/etc/ssh/sshd_config"
  local sshd_temp="${sshd_config}.rish-tmp.$$"
  local sshd_backup="${sshd_config}.rish-bak.$$"
  local had_config=0
  local changed_sshd_config=0
  local effective_settings
  local effective_password
  local effective_kbd_interactive
  local user

  # Read by postupdate.sh after this function returns.
  # shellcheck disable=SC2034
  SFTP_KEYS_MIGRATED=0
  [[ "$target_value" == "yes" || "$target_value" == "no" ]] || return 1
  mkdir -p "$RISH_SSH_CONFIG_DIR" || return 1
  prepare_sftp_authorized_keys || return 1

  if [[ -f "$RISH_SSH_CONFIG_FILE" ]]; then
    cp -p "$RISH_SSH_CONFIG_FILE" "$backup_file" || return 1
    had_config=1
  fi

  if ! render_rish_ssh_config "$target_value" >"$temp_file"; then
    rm -f "$temp_file" "$backup_file"
    return 1
  fi

  chmod 600 "$temp_file" || {
    rm -f "$temp_file" "$backup_file"
    return 1
  }
  if write_sshd_config_without_trailing_legacy_rish_match "$sshd_config" "$sshd_temp"; then
    if ! cp -p "$sshd_config" "$sshd_backup" || ! chown --reference="$sshd_config" "$sshd_temp" || ! chmod --reference="$sshd_config" "$sshd_temp"; then
      rm -f "$temp_file" "$backup_file" "$sshd_temp" "$sshd_backup"
      return 1
    fi
    changed_sshd_config=1
  else
    rm -f "$sshd_temp"
  fi

  if ! mv -f "$temp_file" "$RISH_SSH_CONFIG_FILE"; then
    rm -f "$temp_file" "$backup_file" "$sshd_temp" "$sshd_backup"
    return 1
  fi
  if [[ "$changed_sshd_config" -eq 1 ]] && ! mv -f "$sshd_temp" "$sshd_config"; then
    restore_rish_ssh_files "$had_config" "$backup_file" 0 "$sshd_backup" || true
    rm -f "$sshd_temp" "$sshd_backup"
    return 1
  fi

  if ! sshd -t; then
    restore_rish_ssh_files "$had_config" "$backup_file" "$changed_sshd_config" "$sshd_backup" || true
    echo -e "${RED}Ошибка конфигурации SSH.${WHITE} Предыдущие настройки восстановлены."
    return 1
  fi

  effective_settings="$(get_effective_ssh_authentication)" || effective_settings=""
  read -r effective_password effective_kbd_interactive <<<"$effective_settings"
  if [[ "$effective_password" != "$target_value" || "$effective_kbd_interactive" != "no" ]]; then
    restore_rish_ssh_files "$had_config" "$backup_file" "$changed_sshd_config" "$sshd_backup" || true
    print_ssh_config_priority_error
    echo "Предыдущие настройки восстановлены."
    return 1
  fi

  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    if ! sftp_security_is_effective "$user"; then
      restore_rish_ssh_files "$had_config" "$backup_file" "$changed_sshd_config" "$sshd_backup" || true
      print_ssh_config_priority_error
      echo -e "Ограничения SFTP для пользователя ${YELLOW}${user}${WHITE} не применились."
      echo "Предыдущие настройки восстановлены."
      return 1
    fi
  done < <(get_sftp_users)

  if ! systemctl reload sshd.service; then
    restore_rish_ssh_files "$had_config" "$backup_file" "$changed_sshd_config" "$sshd_backup" || true
    systemctl reload sshd.service >/dev/null 2>&1 || true
    echo -e "${RED}Не удалось перечитать конфигурацию SSH.${WHITE} Предыдущие настройки восстановлены."
    return 1
  fi

  rm -f "$backup_file" "$sshd_backup" "$sshd_temp"
  remove_old_sftp_authorized_keys
  return 0
}
