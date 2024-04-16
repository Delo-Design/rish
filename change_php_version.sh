#!/usr/bin/env bash
source /root/rish/windows.sh
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'
function change_php_version() {
  clear
  local path="$2"
  site_name="$1" # Имя сайта
  if [[ -f "/etc/httpd/conf.d/$site_name.conf" ]]; then
    username=$(echo "$path" | cut -d'/' -f4)
    mapfile -t installed_versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
    echo
    echo -e "Выберите нужную версию ${GREEN}PHP${WHITE} из доступных."
    echo
    vertical_menu "current" 1 0 10 "${installed_versions[@]}"
    local ret=$?
    if ((ret == 255)); then
      echo -e "Никаких изменений в конфигурации ${RED}не производилось${WHITE}!"
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      return
    fi
    local selected_php=${installed_versions[${ret}]}
    if [[ ! -f "/etc/opt/remi/${selected_php}/php-fpm.d/${username}.conf" ]]; then
      # Если пул для этой версии PHP еще не был создан, то создаем
      echo
      echo -e "Выберите режим работы PHP для пользователя ${GREEN}${username}${WHITE}:"
      vertical_menu "current" 2 0 5 "ondemand - оптимально расходует память" "dynamic - более оперативно реагирует на запросы"
      echo -e ${CURSORUP}${ERASEUNTILLENDOFLINE}
      ret=$?
      if ((ret == 0)); then
        php_mode="ondemand"
      else
        php_mode="dynamic"
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
    cp "/etc/httpd/conf.d/${site_name}.conf" "/etc/httpd/conf.d/${site_name}.conf.old"
    # Меняем путь к сокету
    sed -i -r "s|/var/opt/remi/php[0-9][0-9]/run/php-fpm/|/var/opt/remi/${selected_php}/run/php-fpm/|g" "/etc/httpd/conf.d/${site_name}.conf"
    if cmp -s "/etc/httpd/conf.d/${site_name}.conf" "/etc/httpd/conf.d/${site_name}.conf.old"; then
      echo -e "Замен в файле ${RED}не произведено${WHITE}."
      rm "/etc/httpd/conf.d/${site_name}.conf.old"
    else
      echo -e "Версия PHP в файле /etc/httpd/conf.d/${site_name}.conf изменена на ${GREEN}${selected_php}${WHITE}."
      rm "/etc/httpd/conf.d/${site_name}.conf.old"
    fi
    if [[ -f "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" ]]; then
      mv "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf.old"
    fi
    echo -e "Перезапускаем apache для активации сайта ${LRED}${site_name}${WHITE}?"
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
    echo -e "Сайт(vhost) ${RED}${site_name}${WHITE} не существует."
    echo -e "Вначале создайте сайт (vhost)."
    echo -e "Никаких изменений не произведено."
  fi
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}
