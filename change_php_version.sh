#!/usr/bin/env bash
source /root/rish/windows.sh
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'

function create_php_fpm_pool() {
  local selected_php="$1"
  local username="$2"
  local php_mode="$3"

  local fpm_conf="/etc/opt/remi/${selected_php}/php-fpm.d/${username}.conf"

  if [[ ! -f "$fpm_conf" ]]; then
    echo -e "Создаем пул PHP-FPM для ${GREEN}${username} ${WHITE}(${YELLOW}${selected_php}${WHITE}, ${YELLOW}${php_mode}${WHITE})..."

    if [ ! -d "/var/www/${username}/tmp" ]; then
      echo -e "Папка ${YELLOW}/var/www/${username}/tmp${WHITE} не существует, создаём..."
      mkdir -p "/var/www/${username}/tmp"
    fi

    {
      echo "[${username}]"
      echo "listen = /var/opt/remi/${selected_php}/run/php-fpm/${username}.sock"
      echo "user = ${username}"
      echo "group = ${username}"
      echo "listen.owner = ${username}"
      echo "listen.group = ${username}"
      echo "listen.allowed_clients = 127.0.0.1"
      echo "pm = ${php_mode}"
      echo "pm.max_children = 20"
      echo "pm.start_servers = 3"
      echo "pm.min_spare_servers = 3"
      echo "pm.max_spare_servers = 5"
      echo "pm.process_idle_timeout = 10s"
      echo ";slowlog = /var/www/${username}/slow.log"
      echo ";request_slowlog_timeout = 15s"
      echo ";php_admin_value[error_log] = /var/www/${username}/logs/php-error-log"
      echo ";php_admin_flag[log_errors] = on"
      echo "php_value[session.save_handler] = files"
      echo "php_value[session.save_path] = /var/www/${username}/session"
      echo "php_value[soap.wsdl_cache_dir] = /var/www/${username}/wsdlcache"
      echo "php_value[upload_tmp_dir] = /var/www/${username}/tmp"
    } > "$fpm_conf"

    if [[ -f "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" ]]; then
      mv "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" \
         "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf.old"
    fi

    echo "Пул PHP-FPM создан."
  fi
}

function highlight_path_basename() {
  local path="$1"
  local dir="${path%/*}"
  local file="${path##*/}"

  if [[ "$dir" == "$path" ]]; then
    echo -e "${YELLOW}${file}${WHITE}"
  else
    echo -e "${dir}/${YELLOW}${file}${WHITE}"
  fi
}

function update_site_php_conf() {
  local conf_file="$1"
  local selected_php="$2"
  local backup_file="${conf_file}.bak"

  [[ -f "$conf_file" ]] || return 0

  cp "$conf_file" "$backup_file" || return 1

  sed -i -r "s|/var/opt/remi/php[0-9][0-9]/run/php-fpm/|/var/opt/remi/${selected_php}/run/php-fpm/|g" "$conf_file" || return 1

  if cmp -s "$conf_file" "$backup_file"; then
    echo -e " Замен в файле ${RED}${conf_file}${WHITE} не произведено."
    rm "$backup_file" || return 1
  else
    echo -e "Версия PHP в файле ${conf_file} изменена на ${GREEN}${selected_php}${WHITE}."
    echo -e "Сохранен предыдущий конфиг: $(highlight_path_basename "$backup_file")"
  fi
}

function get_site_php_version() {
  local site_name="$1"
  local conf_file
  local php_version

  for conf_file in \
    "/etc/httpd/conf.d/${site_name}.conf" \
    "/etc/httpd/conf.d/${site_name}-ssl.conf" \
    "/etc/httpd/conf.d/${site_name}-le-ssl.conf"; do
    [[ -f "$conf_file" ]] || continue

    php_version=$(grep -oE '/var/opt/remi/php[0-9]{2}/run/php-fpm/' "$conf_file" \
      | grep -oE 'php[0-9]{2}' \
      | head -n 1)
    if [[ -n "$php_version" ]]; then
      echo "$php_version"
      return 0
    fi
  done

  return 1
}

function change_php_version() {
  echo
  local path="$2"
  local site_name="$1" # Имя сайта
  local username
  local php_version
  if [[ -f "/etc/httpd/conf.d/$site_name.conf" ]]; then

    php_version=$(get_site_php_version "$site_name")
    if [[ -z "$php_version" ]]; then
      echo -e "Сайт ${GREEN}${site_name}${WHITE} не использует ${GREEN}PHP-FPM${WHITE}."
      echo "Смена версии PHP для этого сайта недоступна."
      echo "Никаких изменений не произведено."
      return
    fi

    echo -e "Сайт ${GREEN}${site_name}${WHITE} использует ${GREEN}${php_version}${WHITE}"
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
      ret=$?
      echo -e ${CURSORUP}${ERASEUNTILLENDOFLINE}
      local php_mode
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
    update_site_php_conf "/etc/httpd/conf.d/${site_name}.conf" "$selected_php" || return 1
    update_site_php_conf "/etc/httpd/conf.d/${site_name}-ssl.conf" "$selected_php" || return 1
    update_site_php_conf "/etc/httpd/conf.d/${site_name}-le-ssl.conf" "$selected_php" || return 1
    if [[ -f "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" ]]; then
      mv "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf.old"
    fi
    echo
    echo -e -n "Перезапускаем apache для активации сайта ${LRED}${site_name}${WHITE}?"
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
    echo -e "Сайт(vhost) ${RED}${site_name}${WHITE} не существует."
    echo -e "Вначале создайте сайт (vhost)."
    echo -e "Никаких изменений не произведено."
  fi
}

# Если идет прямой вызов - выполняем функцию. Если идет подключение через source - то ничего не делаем
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    change_php_version "$1" "$2"
    vertical_menu "current" 2 0 5 "Нажмите Enter"
 fi
