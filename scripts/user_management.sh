#!/usr/bin/env bash

RISH_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
export RISH_HOME

# These color globals are used by the sourced user-management modules.
# shellcheck disable=SC2034
GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
VIOLET='\033[0;35m'
WHITE='\033[0m'
# Used by scripts/delete_user.sh loaded below.
# shellcheck disable=SC2034
YELLOW='\033[0;33m'
CURSORUP='\033[1A'

source "${RISH_HOME}/windows.sh"
source "${RISH_HOME}/create_hotlist.sh"
source "${RISH_HOME}/scripts/ssh_authentication.sh"
source "${RISH_HOME}/scripts/create_user.sh"
source "${RISH_HOME}/scripts/delete_user.sh"

# shellcheck disable=SC2154
get_context_rish_user() {
  local current_directory="$1"
  local selected_name="$2"
  local path
  local user
  local -a paths=()

  if [[ -n "$selected_name" && "$selected_name" != ".." && -d "${current_directory%/}/${selected_name}" ]]; then
    paths+=("${current_directory%/}/${selected_name}")
  fi
  paths+=("$current_directory")

  for path in "${paths[@]}"; do
    case "$path" in
    /var/www/*)
      user="${path#/var/www/}"
      user="${user%%/*}"
      if [[ -n "$user" ]] && get_sftp_users | grep -Fxq "$user"; then
        printf '%s\n' "$user"
        return 0
      fi
      ;;
    esac
  done

  return 1
}

select_user_for_deletion() {
  local choice
  local -a users=()

  clear
  mapfile -t users < <(get_sftp_users | sort)
  if ((${#users[@]} == 0)); then
    echo "В системе нет пользователей сервера."
    vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
    return 0
  fi

  echo "Выберите пользователя сервера для удаления"
  vertical_menu "current" 2 0 30 "${users[@]}"
  choice=$?
  echo -e "${CURSORUP}"
  if ((choice < 255)); then
    DeleteUser "${users[${choice}]}"
    vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
  fi
}

UserManagementMenu() {
  local current_directory="$1"
  local selected_name="$2"
  local context_user
  local choice
  local server_user
  local -a options=()
  local -a server_users=()

  while true; do
    context_user="$(get_context_rish_user "$current_directory" "$selected_name" 2>/dev/null || true)"
    mapfile -t server_users < <(get_sftp_users | sort)
    options=()
    if [[ -n "$context_user" ]]; then
      options+=("Удалить пользователя ${context_user}")
    fi
    options+=("Создать пользователя" "Удалить пользователя")

    clear
    echo "Пользователи сервера:"
    echo
    for server_user in "${server_users[@]}"; do
      if [[ "$server_user" == "$context_user" ]]; then
        echo -e "  - ${YELLOW}${server_user}${WHITE}"
      else
        echo "  - ${server_user}"
      fi
    done
    echo
    vertical_menu "current" 2 0 30 "${options[@]}"
    choice=$?

    if [[ -n "$context_user" ]]; then
      case "$choice" in
      0)
        clear
        DeleteUser "$context_user"
        vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
        ;;
      1)
        clear
        CreateUser ""
        vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
        ;;
      2)
        select_user_for_deletion
        ;;
      *)
        clear
        break
        ;;
      esac
    else
      case "$choice" in
      0)
        clear
        CreateUser ""
        vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
        ;;
      1)
        select_user_for_deletion
        ;;
      *)
        clear
        break
        ;;
      esac
    fi
  done
}

UserManagementMenu "${1:-}" "${2:-}"
