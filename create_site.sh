#!/usr/bin/env bash
source /root/rish/windows.sh
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'

function check_site() {
  site_name="$1" # Имя сайта
  local directory_path="$2"
  local full_path="$directory_path/$site_name"
  local choice
  local regex="^([a-zA-Z0-9]+([-\.][a-zA-Z0-9]+)*(\.[a-zA-Z]{2,})?|xn--[a-zA-Z0-9\-]+([-\.][a-zA-Z0-9\-]+)*(\.xn--[a-zA-Z0-9\-]+|[a-zA-Z]{2,})?|^[a-zA-Z0-9]+)$"
  local punycode_domain
  # Есть ли кириллица в имени сайта?
  if echo "$site_name" | awk 'BEGIN{found=0} /[А-Яа-яЁё]/ {found=1} END{exit !found}'; then
    echo -e "Имя сайта ${GREEN}${site_name}${WHITE} содержит кириллические символы."
    punycode_domain=$(idn2 --quiet  "$site_name" 2>/dev/null )
    if [ -d "$directory_path/$punycode_domain" ]; then
          echo -e "Переименование ${RED}${site_name}${WHITE} --> ${RED}${punycode_domain}${WHITE} невозможно."
          echo -e "Каталог с именем ${GREEN}${punycode_domain}${WHITE} уже существует."
          echo -e ""
    else
          # Переименовываем каталог
          mv "$full_path" "$directory_path/$punycode_domain"
          echo -e "Каталог переименован. ${GREEN}${site_name}${WHITE} --> ${GREEN}${punycode_domain}${WHITE}."
          site_name=$punycode_domain
          full_path="$directory_path/$site_name"
    fi
  fi

  # Проверяем, существует ли папка и корректно ли ее имя
  if [[ -d "$full_path" && "$site_name" =~ $regex ]]; then
    # Проверяем, а не создан ли уже такой сайт?
    if [[ ! -f "/etc/httpd/conf.d/$site_name.conf" ]]; then
      # Проверяем нет ли верхнего регистра в названии папки
      if [[ "$site_name" =~ [[:upper:]] ]]; then
          # Приводим имя к нижнему регистру
          lower_name="${site_name,,}"
          echo ${lower_name}
          # Проверяем, не существует ли уже каталог с именем в нижнем регистре
          if [ -d "$directory_path/$lower_name" ]; then
              echo -e "Переименование ${GREEN}${site_name}${WHITE} --> ${GREEN}${lower_name}${WHITE} невозможно."
              echo -e "Каталог с именем ${GREEN}${lower_name}${WHITE} уже существует."
              echo -e ""
              site_name=""
          else
              # Переименовываем каталог
              mv "$full_path" "$directory_path/$lower_name"
              echo -e "Каталог переименован. ${GREEN}${site_name}${WHITE} --> ${GREEN}${lower_name}${WHITE}."
              site_name=$lower_name
          fi
      fi
      if [[ -n "$site_name" ]]; then
        # Проверяем, а не punycode ли?
        if [[ "$site_name" =~ (xn\-\-) ]]
        then
          echo -e -n "Имя домена ${GREEN}$site_name${WHITE} "
          echo -e -n " (${GREEN}"$(idn2 -d "$site_name")"${WHITE}) корректное"
          echo
          echo -e -n "Будет создан сайт (vhost) с именем ${GREEN}$site_name${WHITE} "
          echo -e -n " (${GREEN}"$(idn2 -d "$site_name")"${WHITE})"
          echo
        else
          echo -e "Имя домена ${GREEN}$site_name${WHITE} корректное."
          echo -e "Будет создан сайт (vhost) с именем ${GREEN}$site_name${WHITE}."
        fi
        vertical_menu "current" 2 0 5 "Да" "Нет" "Задать свое имя сайта"
        choice=$?
        echo -e ${CURSORUP}${ERASEUNTILLENDOFLINE}
        case "$choice" in
        0)
          return 0 # Выход из функции, если все в порядке
          ;;
        1)
          return 1
          ;;
        255)
          return 2
          ;;
        *)
          site_name=""
          ;;
        esac
      fi
    else
        echo -e "Конфигурационный файл для сайта ${RED}$site_name${WHITE} уже существует."
    fi
    site_name=""
  else
    # Если имя некорректное - пускай сам вводит что ему нужно
    site_name=""
  fi
  echo -e  "${WHITE}Введите свое имя сайта (Enter для выхода):${GREEN}"
  read -e -p "" site_name
  site_name="${site_name,,}"
  while true; do
    if [[ -z "$site_name" ]]; then
      echo -e "${WHITE}"
      return 1
    fi
    # Проверяем, а не кириллицу ли ввели?
    if echo "$site_name" | awk 'BEGIN{found=0} /[А-Яа-яЁё]/ {found=1} END{exit !found}'; then
      echo -e "${WHITE}Имя сайта ${GREEN}${site_name}${WHITE} содержит кириллические символы."
      echo -e "Будет преобразование в стандарт punycode."
      site_name=$(idn2 --quiet  "$site_name" 2>/dev/null )
    fi
    # Проверяем корректность начального имени сайта
    if [[ "$site_name" =~ $regex ]]; then
      echo -e -n "${WHITE}Имя сайта ${GREEN}$site_name${WHITE} введено корректно."
      # Проверяем, а не punycode ли?
      if [[ "$site_name" =~ (xn\-\-) ]]
      then
          echo -e -n " (${GREEN}"$(idn2 -d "$site_name")"${WHITE})"
          echo
      else
          echo
      fi

      if [[ -f "/etc/httpd/conf.d/$site_name.conf" ]]; then
        echo -e "Конфигурационный файл для сайта ${RED}$site_name${WHITE} уже существует."
        echo -e "Введите другое имя (Enter для выхода):${GREEN}"
        read -e -p "" site_name
        continue # Пропускаем текущую итерацию цикла
      fi
      break
    else
      echo -e "${WHITE}Имя сайта ${RED}$site_name${WHITE} некорректное. "
      echo -e "Введите корректное имя (Enter для выхода):${GREEN}"
      read -e -p "" site_name
    fi
  done

  echo
}
function create_site() {
  clear
  local path="$2"
  local php_mode
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
      vertical_menu "current" 2 0 5 "Нажмите Enter"
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
      if [ ! -d "/var/www/${username}/tmp" ]; then
        echo "Папка /var/www/${username}/tmp не существует, создаём..."
        mkdir -p "/var/www/${username}/tmp"
      fi
      {
        echo "[${username}]"
        echo "listen = /var/opt/remi/${selected_php}/run/php-fpm/${username}.sock"
        echo "user = ${username}"
        echo "group = ${username}"
        echo "listen.owner = ${username}"
        echo "listen.group = ${username}"
        echo ""
        echo "listen.allowed_clients = 127.0.0.1"
        echo "pm = ${php_mode}"
        echo "pm.max_children = 20"
        echo "pm.start_servers = 3"
        echo "pm.min_spare_servers = 3"
        echo "pm.max_spare_servers = 5"
        echo "pm.process_idle_timeout = 10s"
        echo ";slowlog = /var/www/${username}/slow.log"
        echo ";request_slowlog_timeout = 15s"
        echo "php_value[session.save_handler] = files"
        echo "php_value[session.save_path] = /var/www/${username}/session"
        echo "php_value[soap.wsdl_cache_dir] = /var/www/${username}/wsdlcache"
        echo "php_value[upload_tmp_dir] = /var/www/${username}/tmp"
      } >"/etc/opt/remi/${selected_php}/php-fpm.d/${username}.conf"

      if [[ -f "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" ]]; then
        mv "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf.old"
      fi

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
    echo "Сайт (vhost) не был создан"
  fi

  vertical_menu "current" 2 0 5 "Нажмите Enter"
}
# Если идет прямой вызов - выполняем функцию. Если идет подключение через source - то ничего не делаем
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    create_site "$1" "$2"
fi