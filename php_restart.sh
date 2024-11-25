#!/usr/bin/env bash
source /root/rish/windows.sh
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
php_restart() {
  clear
  # Получаем список установленных версий PHP с помощью rpm и записываем в массив
  local versions
  mapfile -t versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
  local version
  local menu_items=()
  local choice
  local length

  # Добавление пункта для перезапуска всех версий в начало списка
  menu_items=("Перезапустить все установленные php-fpm")

  # Добавляем префикс и суффикс к каждой версии для создания пунктов меню
  for version in "${versions[@]}"; do
    menu_items+=("Перезапустить $version-php-fpm")
  done

  # Добавляем проверку статуса
  for version in "${versions[@]}"; do
    menu_items+=("Проверить статус $version-php-fpm")
  done

  # Вывод всех пунктов меню для проверки
  vertical_menu "center" "center" 0 10 "${menu_items[@]}"
  choice=$?
  if ((choice == 255)); then
    return
  fi
  clear
  if ((choice == 0)); then
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
    return
  fi
  length=${#versions[@]}
  if ((choice < length + 1)); then
    # Пункты меню для перезапуска
    version=${versions[${choice} - 1]}
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
    version=${versions[${choice} - $length - 1]}
    systemctl status "${version}-php-fpm"

  fi
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}

# Если идет прямой вызов - выполняем функцию. Если идет подключение через source - то ничего не делаем
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    php_restart
fi