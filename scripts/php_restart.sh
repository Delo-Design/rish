#!/usr/bin/env bash
source /root/rish/windows.sh
source /root/rish/php_helpers.sh
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'

php_fpm_status_dot() {
  local active_state="$1"

  case "$active_state" in
    active)
      echo -en "${GREEN}●${WHITE}"
      ;;
    failed)
      echo -en "${RED}●${WHITE}"
      ;;
    *)
      echo -en "${YELLOW}●${WHITE}"
      ;;
  esac
}

show_all_php_fpm_statuses() {
  local -n status_versions="$1"
  local version
  local active_state
  local sub_state
  local enabled_state
  local main_pid
  local restart_policy
  local restarts

  for version in "${status_versions[@]}"; do
    active_state="$(systemctl is-active "${version}-php-fpm" 2>/dev/null || true)"
    enabled_state="$(systemctl is-enabled "${version}-php-fpm" 2>/dev/null || true)"
    sub_state="$(systemctl show "${version}-php-fpm" -p SubState --value 2>/dev/null)"
    main_pid="$(systemctl show "${version}-php-fpm" -p MainPID --value 2>/dev/null)"
    restart_policy="$(systemctl show "${version}-php-fpm" -p Restart --value 2>/dev/null)"
    restarts="$(systemctl show "${version}-php-fpm" -p NRestarts --value 2>/dev/null)"

    [[ -z "$sub_state" ]] && sub_state="unknown"
    [[ -z "$main_pid" ]] && main_pid="0"
    [[ -z "$restart_policy" ]] && restart_policy="no"
    [[ -z "$restarts" ]] && restarts="0"

    php_fpm_status_dot "$active_state"
    printf ' %-14s %-8s (%-8s) %-8s pid=%-7s restart=%-10s restarts=%s\n' \
      "${version}-php-fpm" "$active_state" "$sub_state" "$enabled_state" "$main_pid" "$restart_policy" "$restarts"
  done
}

php_restart() {
  local versions
  local version
  local menu_items=()
  local choice
  local length

  while true; do
    clear
    mapfile -t versions < <(get_installed_php_versions)

    menu_items=("Статус всех php-fpm" "Перезапустить все установленные php-fpm")

    # Добавляем префикс и суффикс к каждой версии для создания пунктов меню
    for version in "${versions[@]}"; do
      menu_items+=("Перезапустить $version-php-fpm")
    done

    # Добавляем проверку статуса
    for version in "${versions[@]}"; do
      menu_items+=("Проверить статус $version-php-fpm")
    done

    menu_items+=("Выйти")

    # Вывод всех пунктов меню для проверки
    vertical_menu "center" "center" 0 10 "${menu_items[@]}"
    choice=$?
    if ((choice == 255)); then
      return
    fi
    clear
    if ((choice == 0)); then
      show_all_php_fpm_statuses versions
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      continue
    fi
    if ((choice == 1)); then
      # Перезапуск всех версий
      for version in "${versions[@]}"; do
        if /opt/remi/${version}/root/usr/sbin/php-fpm -t; then
          if systemctl restart "${version}-php-fpm"; then
            echo -e "Версия ${GREEN}${version}${WHITE} корректно перезапущена."
            echo
          else
            echo
            echo -e "Ошибка при перезапуске ${RED}${version}-php-fpm${WHITE}. Проверьте журналы для диагностики."
            echo
          fi

        else
          echo
          echo -e "Версия ${RED}${version}${WHITE} имеет проблемы в конфигурационных файлах."
          echo -e "Сервис ${RED}не был перезапущен${WHITE} и продолжает работать."
          echo
          systemctl status "${version}-php-fpm"
        fi
      done
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      continue
    fi
    length=${#versions[@]}
    if ((choice == length * 2 + 2)); then
      return
    fi
    if ((choice < length + 2)); then
      # Пункты меню для перезапуска
      version=${versions[${choice} - 2]}
      if /opt/remi/${version}/root/usr/sbin/php-fpm -t; then
        if systemctl restart "${version}-php-fpm"; then
          echo -e "Версия ${GREEN}${version}${WHITE} корректно перезапущена."
          echo
        else
          echo
          echo -e "Ошибка при перезапуске ${RED}${version}-php-fpm${WHITE}. Проверьте журналы для диагностики."
          echo
        fi

      else
        echo
        echo -e "Версия ${RED}${version}${WHITE} имеет проблемы в конфигурационных файлах."
        echo -e "Сервис ${RED}не был перезапущен${WHITE} и продолжает работать."
        echo
        systemctl status "${version}-php-fpm"
      fi
    else
      version=${versions[${choice} - $length - 2]}
      systemctl status "${version}-php-fpm"

    fi
    vertical_menu "current" 2 0 5 "Нажмите Enter"
  done
}

# Если идет прямой вызов - выполняем функцию. Если идет подключение через source - то ничего не делаем
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    php_restart
fi
