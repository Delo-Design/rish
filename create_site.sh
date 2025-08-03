#!/usr/bin/env bash
source /root/rish/windows.sh
source /root/rish/change_php_version.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'

function check_site() {
  local folder_name="$1"
  local directory_path="$2"
  local full_path=""
  local choice=""

  # Обнуляем имя, если . или ..
  [[ "$folder_name" == "." || "$folder_name" == ".." ]] && folder_name=""

  # Проверка заглавных букв — до входа в цикл
  if [[ -d "$directory_path/$folder_name" ]]; then
    if [[ "$folder_name" =~ [[:upper:]] ]]; then
      local lower_name="${folder_name,,}"
      if [[ "$lower_name" != "$folder_name" && ! -e "$directory_path/$lower_name" ]]; then
        mv "$directory_path/$folder_name" "$directory_path/$lower_name"
        echo -e "${GREEN}${folder_name}${WHITE}  --->  ${GREEN}${lower_name}${WHITE}"
        folder_name="$lower_name"
      elif [[ "$lower_name" != "$folder_name" ]]; then
        echo -e "${YELLOW}Невозможно${WHITE} переименовать папку: ${GREEN}${folder_name}${WHITE}  --->  ${GREEN}${lower_name}${WHITE}"
        echo -e "${GREEN}${lower_name}${WHITE} уже существует.${WHITE}"
        echo -e "Переименуйте папку самостоятельно или выберите другое имя – будет создана новая папка."
        folder_name="$lower_name"
      fi
    fi
  fi

  while true; do
    echo
    echo -e "${WHITE}Введите имя сайта (пустая строка для выхода):${GREEN}"
    read -e -i "$folder_name" site_name
    echo -en "${WHITE}"
    site_name="${site_name,,}"

    if [[ -z "$site_name" ]]; then
      echo -e -n "${CURSORUP}${ERASEUNTILLENDOFLINE}"
      return 1
    fi

    # Преобразование кириллицы
    if echo "$site_name" | grep -qP '[А-Яа-яЁё]'; then
      local punycode_input
      punycode_input=$(idn2 --quiet "$site_name" 2>/dev/null)
      if [[ -n "$punycode_input" && "$punycode_input" != "$site_name" ]]; then
        echo -e "${GREEN}${site_name}${WHITE}  --->  ${GREEN}${punycode_input}${WHITE}"
        site_name="$punycode_input"
      fi
    fi

    full_path="$directory_path/$site_name"

    # Проверка имени — минимум два уровня, ASCII, punycode тоже ок
    if ! echo "$site_name" | grep -Eq '^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'; then
      echo -e "${RED}Имя сайта некорректное.${WHITE}"
      folder_name="$site_name"
      continue
    fi

    # Переименование папки в punycode
    if [[ -d "$directory_path/$folder_name" ]]; then
      if echo "$folder_name" | grep -qP '[А-Яа-яЁё]'; then
        local punycode_name
        punycode_name=$(idn2 --quiet "$folder_name" 2>/dev/null)
        if [[ "$punycode_name" != "$folder_name" && ! -e "$directory_path/$punycode_name" ]]; then
          mv "$directory_path/$folder_name" "$directory_path/$punycode_name"
          echo -e "Папка была переименована: ${GREEN}${folder_name}${WHITE}  --->  ${GREEN}${punycode_name}${WHITE}"
          folder_name="$punycode_name"
        elif [[ "$punycode_name" != "$folder_name" ]]; then
          echo -e "${YELLOW}Невозможно${WHITE} переименовать папку: ${GREEN}${folder_name}${WHITE}  --->  ${GREEN}${punycode_name}${WHITE}"
          echo -e "Папка ${GREEN}${punycode_name}${WHITE} уже существует."
          folder_name="$punycode_name"
          continue
        fi
      fi
    fi

    # Проверка: сайт уже существует?
    if [[ -f "/etc/httpd/conf.d/$site_name.conf" ]]; then
      echo -e "Сайт ${RED}$site_name${WHITE} уже существует."
      vertical_menu "current" 2 0 50 "Использовать $site_name" "Ввести другое имя" "Отменить создание"
      choice=$?
      echo -e ${CURSORUP}${ERASEUNTILLENDOFLINE}
      case "$choice" in
        0) return 2 ;;
        1) folder_name="$site_name"; continue ;;
        2 | 255) return 1 ;;
      esac
    fi

    # Подтверждение создания
    if [[ "$site_name" =~ ^xn-- ]]; then
      echo -e "Имя сайта: ${GREEN}${site_name}${WHITE} (${GREEN}$(idn2 -d "$site_name")${WHITE})"
    else
      echo -e "Имя сайта: ${GREEN}${site_name}${WHITE}"
    fi

    vertical_menu "current" 2 0 50 "Да" "Выйти" "Ввести другое имя"
    choice=$?
    case "$choice" in
      0) return 0 ;;
      1 | 255) return 1 ;;
      2) folder_name="$site_name"; continue ;;
    esac
  done
}

function create_site() {
  echo
  local path="$2"
  local php_mode
  local username
  username=$(echo "$path" | cut -d'/' -f4)
  echo -e "Создание сайта (vhost) для пользователя ${GREEN}${username}${WHITE}"
  if check_site "$1" "$2"; then
    echo -e -n "Создаем сайт (vhost) ${GREEN}${site_name}"
    if [[ "$site_name" =~ (xn\-\-) ]]
    then
     echo -e -n " ("$(idn2 -d "$site_name")")"
    fi
    echo -e ${WHITE}
    mapfile -t installed_versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
    echo
    echo -e "Выберите нужную версию ${GREEN}PHP${WHITE} из доступных."
    echo
    vertical_menu "current" 1 0 10 "${installed_versions[@]}"
    local ret=$?
    if ((ret == 255)); then
      echo -e "Сайт (vhost) ${site_name} ${RED}не был создан${WHITE}"
      return
    fi
    local selected_php=${installed_versions[${ret}]}
    echo -e "${CURSORUP}Выбрана версия ${GREEN}${selected_php}${WHITE}"
    echo -e -n "Введите имя  папки для DocumentRoot (${GREEN}Enter${WHITE}, если все стандартно):${GREEN}"
    read -e -p " " DocumentRoot
    echo
    echo -e "${WHITE}Владельцем всех папок и файлов в папке ${GREEN}${path}/${site_name}/${DocumentRoot}${WHITE}"
    if [[ -z "$DocumentRoot" ]]; then
      mkdir -p "$path/$site_name"
    else
      DocumentRoot="/"${DocumentRoot}
      mkdir -p "$path/$site_name/$DocumentRoot"
    fi

    chown -R ${username}:${username} "$path/$site_name"
    find "$path/$site_name" -type d -print0 | xargs -0 chmod 755

    if ! find "$path/$site_name" -type f -exec false {} +; then
        find "$path/$site_name" -type f -print0 | xargs -0 chmod 644
    fi

    echo -e "Установлен пользователь ${GREEN}${username}${WHITE}"
    echo

    {
      echo "<VirtualHost *:80>"
      echo "ServerAdmin webmaster@localhost"
      echo "ServerName ${site_name}"
      echo "ServerAlias www.${site_name}"
      echo "DocumentRoot /var/www/${username}/www/${site_name}${DocumentRoot}"
      echo ""
      echo "<FilesMatch \.php$>"
      echo "    SetHandler \"proxy:unix:/var/opt/remi/${selected_php}/run/php-fpm/${username}.sock|fcgi://localhost\""
      echo "</FilesMatch>"
      echo ""
      echo "DirectoryIndex index.php index.html"
      echo ""
      echo "<Directory /var/www/${username}/www/${site_name}${DocumentRoot}>"
      echo "    Options -Indexes +FollowSymLinks"
      echo "    AllowOverride All"
      echo "    Require all granted"
      echo "</Directory>"
      echo ""
      echo "ServerSignature Off"
      echo "ErrorLog /var/www/${username}/logs/${site_name}-error-log"
      echo "LogLevel warn"
      echo "CustomLog /var/www/${username}/logs/${site_name}-access-log combined"
      echo "</VirtualHost>"
    } >"/etc/httpd/conf.d/${site_name}.conf"

    if [[ ! -f "/etc/opt/remi/${selected_php}/php-fpm.d/${username}.conf" ]]; then
      # Если пул для этой версии PHP еще не был создан, то создаем
      echo
      echo -e "Выберите режим работы PHP для пользователя ${GREEN}${username}${WHITE}:"
      vertical_menu "current" 2 0 5 "ondemand - оптимально расходует память" "dynamic - более оперативно реагирует на запросы"
      ret=$?
      if ((ret == 0)); then
        php_mode="ondemand"
      else
        php_mode="dynamic"
      fi

      create_php_fpm_pool "$selected_php" "$username" "$php_mode"

      echo -e "Перезапускаем ${GREEN}${selected_php}-php-fpm${WHITE} для активации версии ${GREEN}${selected_php}${WHITE}?"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        if /opt/remi/${selected_php}/root/usr/sbin/php-fpm -t; then
          if systemctl restart "${selected_php}-php-fpm"; then
            echo -e "Версия ${GREEN}${selected_php}${WHITE} корректно перезапущена."
            echo
          else
            echo
            echo -e "Ошибка при перезапуске ${RED}${selected_php}-php-fpm${WHITE}. Проверьте журналы для диагностики."
            echo
          fi
        else
          echo
          echo -e "Версия ${RED}${selected_php}${WHITE} имеет проблемы в конфигурационных файлах."
          echo -e "Сервис ${RED}не был перезапущен${WHITE} и продолжает работать."
          echo
          systemctl status "${selected_php}-php-fpm"
        fi
      else
        echo -e "${RED}${selected_php}-php-fpm${WHITE} перезапущен не был. Не забудьте потом перезапустить его самостоятельно."
      fi
    fi
    echo -e -n "Перезапускаем apache для активации сайта ${GREEN}${site_name}${WHITE}? "
    # Проверяем, а не punycode ли?
    if [[ "$site_name" =~ (xn\-\-) ]]
    then
        echo -e -n " (${GREEN}"$(idn2 -d "$site_name")"${WHITE})"
        echo
    else
        echo
    fi
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      if apachectl configtest; then
        systemctl reload httpd
        echo "Сервер apache перезагружен"
      else
        echo "Сервер не был перезагружен"
      fi
    else
      echo "Сервер apache перезапущен не был. Не забудьте потом перезапустить его самостоятельно."
    fi

  else
    ret=$?
    echo -e "Сайт (vhost) ${YELLOW}$site_name${WHITE} не был создан"
    return $ret
  fi

}
# Если идет прямой вызов - выполняем функцию. Если идет подключение через source - то ничего не делаем
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    create_site "$1" "$2"
    vertical_menu "current" 2 0 5 "Нажмите Enter"
fi