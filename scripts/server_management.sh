#!/usr/bin/env bash

# Standalone server management. Installation and updates use dns_management.sh directly.
# shellcheck disable=SC2154

# Initialized by rish_initialize_split_screen from server_common.sh.
declare -g rim columns lines

rish_server_management_print_services() {
  local installed
  local -a installed_versions

  Down
  echo
  echo -e "Версия ${GREEN}apache${WHITE}"
  httpd -v
  echo
  print_effective_ssh_authentication
  echo
  echo -e "Установленные версии ${GREEN}PHP${WHITE}:"
  mapfile -t installed_versions < <(get_installed_php_version_labels)
  for installed in "${installed_versions[@]}"; do
    echo "       "$installed
  done
  echo
  if [[ -f /root/rish/scripts/composer_manager.sh ]]; then
    bash /root/rish/scripts/composer_manager.sh status
  else
    echo -e "Управление ${RED}Composer${WHITE}: модуль не найден."
  fi
}

rish_server_management_refresh() {
  rish_initialize_split_screen || return 1
  rish_draw_split_screen
  rish_server_management_print_info
  rish_server_management_print_services
  return 0
}

rish_server_management_open_module() {
  local module_path="${RISH_HOME}/scripts/$1"

  RemoveRim
  clear
  if [[ -r "$module_path" ]]; then
    bash "$module_path"
  else
    printf 'Модуль не найден или недоступен: %s\n' "$module_path" >&2
    vertical_menu "current" 2 0 5 "Нажмите Enter"
  fi
  rish_server_management_refresh
}

ServerManagementMenu() {
  local choice=0
  local -a options=("Статус и перезапуск Apache"
    "Статус и перезапуск PHP-FPM"
    "Статус и перезапуск MariaDB"
    "Управление TLS"
    "Управление CRON"
    "Установка новых версий PHP"
    "Удалить версию PHP"
    "Включить/отключить Composer"
    "Включить/отключить авторизацию по паролю по SSH"
    "Включить/отключить управление DNS"
    "Добавить внешние DNS"
    "Выйти")

  while true; do

    vertical_menu "center" "center" 0 30 "default=$choice" "${options[@]}"
    choice=$?

    case "$choice" in
    0)
      rish_server_management_open_module apache_restart.sh || return 1
      ;;
    1)
      rish_server_management_open_module php_restart.sh || return 1
      ;;
    2)
      rish_server_management_open_module mariadb_restart.sh || return 1
      ;;
    3)
      rish_server_management_open_module https_compatibility.sh || return 1
      ;;
    4)
      rish_server_management_open_module cron_users.sh || return 1
      ;;
    5)
      echo -e "Выбор и установка нужных версий ${GREEN}PHP${WHITE}"
      clear
      # Рисуем разделительную линию
      cursor_to $((${rim} + 1)) 1
      repl "─" $((${columns}))
      cursor_to $((${rim} + 2)) 1
      Up
      echo -e "Идет получение списка доступных версий ${GREEN}PHP${WHITE}. Ждите."
      Down
      if ! php_multi_install; then
        Down
        echo -e "Выбор или установка ${RED}PHP${WHITE} прерваны. Проверьте сообщения выше."
        vertical_menu "current" 2 0 5 "Нажмите Enter"
      fi
      clear
      # Рисуем разделительную линию
      cursor_to $((${rim} + 1)) 1
      repl "─" $((${columns}))
      cursor_to $((${rim} + 2)) 1
      ;;
    6)
      rish_server_management_open_module php_remove.sh || return 1
      ;;
    7)
      if [[ -f /root/rish/scripts/composer_manager.sh ]]; then
        bash /root/rish/scripts/composer_manager.sh server-menu
      else
        echo -e "Модуль управления ${RED}Composer${WHITE} не найден."
        vertical_menu "current" 2 0 5 "Нажмите Enter"
      fi
      ;;
    8)
      effective_settings="$(get_effective_ssh_authentication)" || effective_settings=""
      read -r password_authentication kbd_interactive_authentication <<<"$effective_settings"

      if [[ -z "$password_authentication" || -z "$kbd_interactive_authentication" ]]; then
        echo -e "${RED}Не удалось определить${WHITE} текущие настройки авторизации SSH."
        echo
        continue
      fi

      if [[ "$password_authentication" == "yes" || "$kbd_interactive_authentication" == "yes" ]]; then
        target_value="no"
        question_text="Запретить способы авторизации с вводом пароля для SSH?"
        result_text="запрещена"
        result_color="$GREEN"
      else
        target_value="yes"
        question_text="Разрешить авторизацию по паролю для SSH?"
        result_text="разрешена"
        result_color="$YELLOW"
      fi

      echo -e "${question_text/пароля/${YELLOW}пароля${WHITE}}"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        echo -e -n "${CURSORUP}"
        if configure_ssh_password_authentication "$target_value"; then
          echo -e "Авторизация по паролю для SSH ${result_color}${result_text}${WHITE}.${ERASEUNTILLENDOFLINE}"
          print_effective_ssh_authentication
        fi
      else
        echo -e "${CURSORUP}Настройки авторизации SSH ${VIOLET}не изменены${WHITE}.${ERASEUNTILLENDOFLINE}"
        echo
      fi
      ;;
    9)
      if [[ -d "$RISH_DNS_RUNTIME_DIR" && -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
        dns_domains="$(rish_dns_domain_count "$RISH_DNS_RUNTIME_DIR")"
        dns_bak_domains="$(rish_dns_domain_count "$RISH_DNS_LEGACY_DISABLED_DIR")"

        clear
        echo -e "Одновременно найдены текущие и резервные настройки ${GREEN}DNS${WHITE}."
        echo
        echo -e "Текущие настройки: ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}"
        echo -e "Папок доменов: ${GREEN}${dns_domains}${WHITE}"
        echo
        echo -e "Резервные настройки: ${YELLOW}${RISH_DNS_LEGACY_DISABLED_DIR}${WHITE}"
        echo -e "Папок доменов: ${GREEN}${dns_bak_domains}${WHITE}"
        echo
        echo "Выберите, какие настройки сохранить в постоянном каталоге DNS:"
        vertical_menu "current" 2 0 48 \
          "Сохранить текущие настройки (доменов: ${dns_domains})" \
          "Сохранить резервные настройки (доменов: ${dns_bak_domains})" \
          "Отмена"
        dns_choice=$?

        case "$dns_choice" in
        0)
          echo
          echo -e "Резервные настройки ${YELLOW}${RISH_DNS_LEGACY_DISABLED_DIR}${WHITE} будут удалены."
          echo "Продолжить?"
          vertical_menu "current" 2 0 5 "Нет" "Да"
          if (($? == 1)); then
            if rm -rf -- "$RISH_DNS_LEGACY_DISABLED_DIR" &&
              rish_dns_management_disable; then
              rish_dns_management_mark_migration_completed
              echo -e "Текущие настройки сохранены в ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}."
            else
              echo -e "Не удалось привести настройки ${RED}DNS${WHITE} к единому состоянию." >&2
            fi
          else
            echo "Настройки DNS не изменены."
          fi
          ;;
        1)
          echo
          echo -e "Текущие настройки ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE} будут удалены."
          echo -e "Резервные настройки будут перенесены в ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}."
          echo "Продолжить?"
          vertical_menu "current" 2 0 5 "Нет" "Да"
          if (($? == 1)); then
            if rm -rf -- "$RISH_DNS_RUNTIME_DIR" &&
              mv -- "$RISH_DNS_LEGACY_DISABLED_DIR" "$RISH_DNS_RUNTIME_DIR" &&
              rish_dns_management_disable; then
              rish_dns_management_mark_migration_completed
              echo -e "Резервные настройки сохранены в ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}."
            else
              echo -e "Не удалось привести настройки ${RED}DNS${WHITE} к единому состоянию." >&2
            fi
          else
            echo "Настройки DNS не изменены."
          fi
          ;;
        *)
          echo "Настройки DNS не изменены."
          ;;
        esac
      elif [[ -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
        if mv -- "$RISH_DNS_LEGACY_DISABLED_DIR" "$RISH_DNS_RUNTIME_DIR"; then
          rish_dns_management_disable
          rish_dns_management_mark_migration_completed
        else
          echo -e "Не удалось восстановить настройки DNS в ${RED}${RISH_DNS_RUNTIME_DIR}${WHITE}." >&2
        fi
      fi

      if [[ -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
        vertical_menu "current" 2 0 5 "Нажмите Enter"
        continue
      fi

      dns_domains="$(rish_dns_domain_count "$RISH_DNS_RUNTIME_DIR")"
      clear
      if rish_dns_management_is_enabled; then
        echo -e "Управление ${GREEN}DNS${WHITE} включено."
        echo -e "Папок доменов: ${GREEN}${dns_domains}${WHITE}"
        echo
        echo -e "Отключить управление ${RED}DNS${WHITE}?"
        echo "Настройки и credentials останутся в постоянном каталоге."
        vertical_menu "current" 2 0 5 "Нет" "Да"
        if (($? == 1)); then
          if rish_dns_management_disable; then
            echo -e "Управление ${GREEN}DNS${WHITE} отключено."
            echo -e "Настройки сохранены в ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}."
          else
            echo -e "Не удалось отключить управление ${RED}DNS${WHITE}." >&2
          fi
        else
          echo "Настройки DNS не изменены."
        fi
      else
        echo -e "Управление ${GREEN}DNS${WHITE} отключено."
        if [[ -d "$RISH_DNS_RUNTIME_DIR" ]]; then
          echo -e "Сохранено папок доменов: ${GREEN}${dns_domains}${WHITE}"
        fi
        echo
        echo -e "Включить управление ${GREEN}DNS${WHITE}?"
        vertical_menu "current" 2 0 5 "Нет" "Да"
        if (($? == 1)); then
          if rish_dns_management_enable; then
            rish_dns_management_mark_migration_completed
            echo -e "Управление ${GREEN}DNS${WHITE} включено."
            echo -e "Пункт ${GREEN}DNS${WHITE} появится в меню MC для каталогов сайтов."
          else
            echo -e "Не удалось включить управление ${RED}DNS${WHITE}." >&2
          fi
        else
          echo "Настройки DNS не изменены."
        fi
      fi
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      ;;
    10)
      if [[ -f /root/rish/scripts/external_dns.sh ]]; then
        bash /root/rish/scripts/external_dns.sh menu
      else
        echo "Модуль настройки внешних DNS не найден."
        vertical_menu "current" 2 0 5 "Нажмите Enter"
      fi
      ;;
    *)
      RemoveRim
      clear
      break
      ;;
    esac
  done
}

rish_server_management_print_info() {
  local version=""
  local current_os cpu_model server_ip

  if [[ -s "${RISH_HOME}/version" ]]; then
    version=$(tr -d '\r' < "${RISH_HOME}/version" | awk '{$1=$1; print; exit}')
  fi
  if [[ -n "$version" ]]; then
    printf 'Версия RISH: %b%s%b\n' "$GREEN" "$version" "$WHITE"
  else
    printf 'Версия RISH: %bне определена%b\n' "$YELLOW" "$WHITE"
  fi
  server_ip=$(ip route get 1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }') || server_ip=""
  printf 'IP сервера: %b%s%b\n' "$YELLOW" "${server_ip:-не определён}" "$WHITE"

  if [[ -r /etc/system-release ]]; then
    current_os=$(head -1 /etc/system-release)
  elif [[ -r /etc/os-release ]]; then
    current_os=$(awk -F= '$1 == "PRETTY_NAME" { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' /etc/os-release)
  else
    current_os=$(uname -sr)
  fi
  printf 'Ваша версия Linux: %b%s%b\n' "$GREEN" "$current_os" "$WHITE"

  cpu_model=$(awk '/^model name[[:space:]]*:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' /proc/cpuinfo 2>/dev/null)
  printf 'Процессор: %b%s%b\n' "$GREEN" "${cpu_model:-не определена}" "$WHITE"
  printf 'Архитектура CPU: %b%s%b\n' "$GREEN" "$(uname -m)" "$WHITE"
  printf '%bSystem memory:%b\n' "$GREEN" "$WHITE"
  free -m
  echo
  printf '%bDisk space:%b\n' "$GREEN" "$WHITE"
  df -h -P -l -x tmpfs -x devtmpfs
  echo
}

rish_server_management_cleanup() {
  printf '%s' "${ESC}[r"
  mouse_tracking_off
  cursor_blink_on
}

rish_server_management_main() {
  local config_file dns_migration_status

  RISH_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || return 1
  export RISH_HOME
  cd "$RISH_HOME" || return 1

  GREEN='\033[0;32m'
  RED='\033[0;31m'
  VIOLET='\033[0;35m'
  WHITE='\033[0m'
  YELLOW='\033[0;33m'
  CURSORUP='\033[1A'
  ERASEUNTILLENDOFLINE='\033[K'

  config_file="${RISH_HOME}/rish_config.sh"
  if [[ ! -r "$config_file" ]]; then
    printf 'Не удалось прочитать конфигурацию RISH: %s\n' "$config_file" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source "$config_file" || return 1
  LocalServer="${LocalServer:-false}"

  source "${RISH_HOME}/windows.sh" || return 1
  source "${RISH_HOME}/scripts/server_common.sh" || return 1
  source "${RISH_HOME}/php_helpers.sh" || return 1
  source "${RISH_HOME}/php_multi_install.sh" || return 1
  source "${RISH_HOME}/scripts/ssh_authentication.sh" || return 1
  source "${RISH_HOME}/scripts/steps.sh" || return 1
  source "${RISH_HOME}/scripts/dns_management.sh" || return 1

  # Управление использует существующее состояние и не начинает новую установку.
  initialize_completed_steps || return 1
  if ! check_step "$RISH_DNS_MANAGEMENT_MIGRATION_STEP"; then
    rish_dns_management_migrate_legacy_state
    dns_migration_status=$?
    case "$dns_migration_status" in
      0)
        mark_step_completed "$RISH_DNS_MANAGEMENT_MIGRATION_STEP"
        ;;
      2)
        echo -e "${YELLOW}Одновременно найдены /root/rish/dns и /root/rish/dns_bak.${WHITE}"
        echo "Выберите сохраняемые настройки через меню управления сервером."
        ;;
      *)
        echo -e "${RED}Не удалось перенести состояние управления DNS.${WHITE}" >&2
        return 1
        ;;
    esac
  fi

  rish_initialize_split_screen || return 1
  if ((lines < 40 || columns < 140)); then
    echo
    echo "Размер окна вашего терминала слишком маленький."
    echo -e "Советуем увеличить окно терминала до размера ${YELLOW}140x40${WHITE} символов."
    echo "Иначе вывод на экран возможно будет некорректным."
    echo
    if vertical_menu "current" 2 0 5 "Выйти" "Хорошо понятно. Продолжаем"; then
      return 0
    fi
  fi

  trap rish_server_management_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  rish_server_management_refresh || return 1
  ServerManagementMenu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rish_server_management_main "$@"
fi
