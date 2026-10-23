#!/usr/bin/env bash
function apache_restart() {
  local GREEN='\033[0;32m'
  local RED='\033[0;31m'
  local WHITE='\033[0m'
  local YELLOW='\033[0;33m'
  local choice stop_rc active_rc script_dir
  local status_output status_key status_value active_state="" sub_state=""
  local status_label="статус недоступен" status_color="$YELLOW"
  local -a options
  if ! declare -F vertical_menu >/dev/null; then
    # shellcheck disable=SC1091
    source /root/rish/windows.sh || return 1
  fi
  while true; do
    active_state="" sub_state=""
    status_label="статус недоступен" status_color="$YELLOW"
    clear
    if status_output=$(systemctl show httpd --property=ActiveState --property=SubState 2>/dev/null); then
      while IFS='=' read -r status_key status_value; do
        case "$status_key" in
          ActiveState) active_state="$status_value" ;;
          SubState) sub_state="$status_value" ;;
        esac
      done <<<"$status_output"
      case "$active_state" in
        active) status_label="работает"; status_color="$GREEN" ;;
        inactive) status_label="остановлен" ;;
        failed) status_label="ошибка"; status_color="$RED" ;;
        activating) status_label="запускается" ;;
        deactivating) status_label="останавливается" ;;
        reloading) status_label="перечитывает конфигурацию" ;;
        "") ;;
        *) status_label="неизвестное состояние" ;;
      esac
    fi
    printf 'Apache (httpd): %b%s%b' "$status_color" "$status_label" "$WHITE"
    if [[ -n "$active_state" ]]; then
      printf ' — %s/%s' "$active_state" "${sub_state:-unknown}"
    fi
    printf '\n\n'
    options=("Быстрый перезапуск Apache (reload) "
      "Полный перезапуск Apache (restart)"
      "Статус Apache (status)"
      "Режим HTTPS"
      "Остановить Apache (stop)"
      "Выйти")
    vertical_menu "current" 2 0 30 "${options[@]}"
    choice=$?
    clear
    case "$choice" in
    0)
      if apachectl configtest; then
        # Перезагрузка Apache, если конфигурация верна
        if systemctl reload httpd; then
          echo -e "Сервер успешно ${GREEN}перезагружен${WHITE}"
        else
          echo -e "${RED}Ошибка${WHITE} при попытке перезагрузить сервер"
        fi
      else
        echo -e "${RED}Ошибка${WHITE} в конфигурации Apache, сервер не был перезагружен"
      fi
      ;;
    1)
      if apachectl configtest; then
        # Перезагрузка Apache, если конфигурация верна
        echo -e "Перезагрузка начата. Процесс может оказаться долгим - до минуты или более."
        if systemctl restart httpd; then
          echo -e "Сервер успешно ${GREEN}перезагружен${WHITE}"
        else
          echo -e "${RED}Ошибка${WHITE} при попытке перезагрузить сервер"
        fi
      else
        echo -e "${RED}Ошибка${WHITE} в конфигурации Apache, сервер не был перезагружен"
      fi
      ;;
    2)
      systemctl --no-pager status httpd
      ;;
    3)
      script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
      # shellcheck disable=SC1091
      if source "${script_dir}/https_compatibility.sh"; then
        rish_https_menu
      else
        echo -e "Не удалось загрузить ${RED}режим HTTPS${WHITE}"
      fi
      ;;
    4)
      echo "Остановка Apache сделает сайты сервера недоступными."
      if vertical_menu "current" 2 0 30 default=1 "Остановить Apache" "Отмена"; then
        systemctl stop httpd
        stop_rc=$?
        systemctl is-active --quiet httpd
        active_rc=$?
        if [[ "$stop_rc" == 0 && "$active_rc" == 3 ]]; then
          echo -e "Сервер Apache ${GREEN}остановлен${WHITE}"
        elif [[ "$active_rc" == 0 ]]; then
          echo -e "${RED}Ошибка${WHITE}: сервер Apache продолжает работать"
        else
          echo -e "${RED}Ошибка${WHITE}: не удалось подтвердить успешную остановку Apache"
        fi
      else
        echo "Остановка Apache отменена."
      fi
      ;;
    *)
      echo "Никаких действий не было произведено."
      ;;
    esac
    vertical_menu "current" 2 0 5 "Нажмите Enter"
    [[ "$choice" == 2 ]] || break
  done
}
# Если идет прямой вызов - выполняем функцию. Если идет подключение через source - то ничего не делаем
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  apache_restart
fi
