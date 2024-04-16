#!/usr/bin/env bash
source /root/rish/windows.sh
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
clear
function mariadb_restart() {
  options=("Перезапуск MariaDB"
    "Статус MariaDB"
    "Выйти")
  vertical_menu "center" "center" 0 30 "${options[@]}"
  choice=$?
  clear
  case "$choice" in
  0)
    echo "Перезапуск MariaDB..."
    systemctl restart mariadb
    sleep 2
    if systemctl is-active --quiet mariadb; then
      echo -e "MariaDB перезапущена ${GREEN}успешно${WHITE}."
    else
      echo -e "Перезапуск ${RED}неудачен${WHITE}... Проверьте статус MariaDB."
      systemctl status mariadb
    fi
    ;;
  1)
    systemctl --no-pager status mariadb
    ;;
  *)
    echo "Никаких действий не было произведено."
    ;;
  esac
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}
