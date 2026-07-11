#!/usr/bin/env bash

# This module is sourced by ri.sh and postupdate.sh and uses their color globals.
# shellcheck disable=SC2154
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
  local config_dir="/etc/ssh/sshd_config.d"
  local config_file="${config_dir}/00-rish.conf"
  local temp_file="${config_file}.tmp.$$"
  local backup_file="${config_file}.bak.$$"
  local had_config=0
  local effective_settings
  local effective_password
  local effective_kbd_interactive

  [[ "$target_value" == "yes" || "$target_value" == "no" ]] || return 1
  mkdir -p "$config_dir" || return 1

  if [[ -f "$config_file" ]]; then
    cp -p "$config_file" "$backup_file" || return 1
    had_config=1
  fi

  if ! {
    printf '%s\n' '# Managed by RISH'
    printf 'PasswordAuthentication %s\n' "$target_value"
    printf '%s\n' 'KbdInteractiveAuthentication no'
  } >"$temp_file"; then
    rm -f "$temp_file" "$backup_file"
    return 1
  fi

  chmod 600 "$temp_file" || {
    rm -f "$temp_file" "$backup_file"
    return 1
  }
  mv -f "$temp_file" "$config_file" || {
    rm -f "$temp_file" "$backup_file"
    return 1
  }

  if ! sshd -t; then
    if [[ "$had_config" -eq 1 ]]; then
      mv -f "$backup_file" "$config_file"
    else
      rm -f "$config_file"
    fi
    echo -e "${RED}Ошибка конфигурации SSH.${WHITE} Предыдущие настройки восстановлены."
    return 1
  fi

  effective_settings="$(get_effective_ssh_authentication)" || effective_settings=""
  read -r effective_password effective_kbd_interactive <<<"$effective_settings"
  if [[ "$effective_password" != "$target_value" || "$effective_kbd_interactive" != "no" ]]; then
    if [[ "$had_config" -eq 1 ]]; then
      mv -f "$backup_file" "$config_file"
    else
      rm -f "$config_file"
    fi
    print_ssh_config_priority_error
    echo "Предыдущие настройки восстановлены."
    return 1
  fi

  if ! systemctl reload sshd.service; then
    if [[ "$had_config" -eq 1 ]]; then
      mv -f "$backup_file" "$config_file"
    else
      rm -f "$config_file"
    fi
    systemctl reload sshd.service >/dev/null 2>&1 || true
    echo -e "${RED}Не удалось перечитать конфигурацию SSH.${WHITE} Предыдущие настройки восстановлены."
    return 1
  fi

  rm -f "$backup_file"
  return 0
}
