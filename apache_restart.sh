#!/usr/bin/env bash
source /root/rish/windows.sh
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
clear
function apache_restart() {
  options=("Быстрый перезапуск Apache (reload) "
    "Полный перезапуск Apache (restart)"
    "Статус Apache (status)"
    "Выйти")
  vertical_menu "center" "center" 0 30 "${options[@]}"
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
  *)
    echo "Никаких действий не было произведено."
    ;;
  esac
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}
