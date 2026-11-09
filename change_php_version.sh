#!/usr/bin/env bash
source /root/rish/windows.sh
source /root/rish/php_helpers.sh
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
      echo ";slowlog = /var/www/${username}/logs/php-slow-log"
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

php_cron_matches_site_path() {
  local command_text="$1" site_root="$2" before after left right
  local left_boundary="[[:space:]\"'=;&|<>()]"
  local right_boundary="[[:space:]\"'/;&|<>()]"

  while [[ "$command_text" == *"$site_root"* ]]; do
    before="${command_text%%"$site_root"*}"
    after="${command_text#*"$site_root"}"
    left="${before: -1}"
    right="${after:0:1}"
    if [[ ( -z "$before" || "$left" =~ $left_boundary ) &&
          ( -z "$after" || "$right" =~ $right_boundary ) ]]; then
      return 0
    fi
    # Сохраняем левую границу для следующего совпадения пути.
    command_text="${site_root: -1}${after}"
  done
  return 1
}

php_cron_other_versions() {
  local command_text="$1" selected_php="$2" match token version versions=""
  local php_pattern="(^|[[:space:];|&()'\"=])((/(usr/)?bin/)?php[0-9]{2}|/opt/remi/php[0-9]{2}/root/usr/bin/php)([[:space:];|&()'\"<>]|$)"

  while [[ "$command_text" =~ $php_pattern ]]; do
    match="${BASH_REMATCH[0]}"
    token="${BASH_REMATCH[2]}"
    command_text="${command_text#*"$match"}"
    [[ "$token" =~ php[0-9]{2} ]] || continue
    version="${BASH_REMATCH[0]}"
    if [[ "$version" != "$selected_php" && " $versions " != *" $version "* ]]; then
      versions="${versions:+$versions }${version}"
    fi
  done
  printf '%s' "$versions"
}

check_site_php_cron() {
  local site_name="$1" site_parent="$2" username="$3" selected_php="$4"
  local site_root owner cron_content cron_status line line_number command_text versions
  local owner_has_matches cli_bin choice read_errors=0
  local job_pattern='^[[:space:]]*[^[:space:]]+([[:space:]]+[^[:space:]]+){4}[[:space:]]+(.+)$'
  local macro_pattern='^[[:space:]]*@[[:alpha:]]+[[:space:]]+(.+)$'
  local -a owners=("$username") affected_owners=() menu_items=()

  [[ "$selected_php" =~ ^php[0-9]{2}$ && -n "$username" ]] || return 1
  [[ "$username" == root ]] || owners+=(root)
  site_root="$(realpath -ms -- "${site_parent}/${site_name}")" || return 1
  echo
  echo -e "Проверяем CRON для ${GREEN}${site_root}${WHITE}. PHP в конфигурации сайта: ${YELLOW}${selected_php}${WHITE}."

  for owner in "${owners[@]}"; do
    cron_status=0
    cron_content="$(LC_ALL=C crontab -l -u "$owner" 2>&1)" || cron_status=$?
    if ((cron_status != 0)); then
      if [[ "$cron_status" -eq 1 && "$cron_content" == "no crontab for ${owner}" ]]; then
        continue
      fi
      read_errors=1
      echo -e "Не удалось прочитать CRON пользователя ${YELLOW}${owner}${WHITE}:"
      printf '  %s\n' "$cron_content"
      continue
    fi
    owner_has_matches=0
    line_number=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_number=$((line_number + 1))
      [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
      [[ "$line" =~ ^[[:space:]]*[[:alpha:]_][[:alnum:]_]*[[:space:]]*= ]] && continue
      if [[ "$line" =~ $macro_pattern ]]; then
        command_text="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ $job_pattern ]]; then
        command_text="${BASH_REMATCH[2]}"
      else
        continue
      fi
      [[ "$command_text" =~ ^[[:space:]]*# ]] && continue
      php_cron_matches_site_path "$command_text" "$site_root" || continue
      versions="$(php_cron_other_versions "$command_text" "$selected_php")"
      [[ -n "$versions" ]] || continue
      if ((owner_has_matches == 0)); then
        echo
        echo -e "Возможно требуют обновления задания CRON пользователя ${YELLOW}${owner}${WHITE}:"
        affected_owners+=("$owner")
        owner_has_matches=1
      fi
      printf '  Строка %s, PHP %s:\n    %s\n' "$line_number" "$versions" "$line"
    done <<< "$cron_content"
  done

  if ((${#affected_owners[@]} == 0)); then
    if ((read_errors == 0)); then
      echo "В crontab владельца сайта и root прямые вызовы PHP для этого пути с другой версией не найдены."
    fi
    return 0
  fi
  echo
  if cli_bin="$(get_site_php_bin "$site_name")"; then
    echo -e "Для выбранной версии PHP используйте: ${GREEN}${cli_bin}${WHITE}."
  else
    echo -e "CLI для ${YELLOW}${selected_php}${WHITE} не найден. Проверьте установку перед изменением заданий."
  fi
  echo "Проверьте найденные строки: команда может вызывать несколько сайтов или скрипт-обёртку."
  for owner in "${affected_owners[@]}"; do
    menu_items+=("Открыть CRON пользователя ${owner}")
  done
  menu_items+=("Продолжить")
  while true; do
    vertical_menu current 2 0 60 "default=${#affected_owners[@]}" "${menu_items[@]}"
    choice=$?
    ((choice < ${#affected_owners[@]})) || return 0
    owner="${affected_owners[$choice]}"
    if ! crontab -e -u "$owner"; then
      echo -e "Не удалось открыть CRON пользователя ${YELLOW}${owner}${WHITE}."
    fi
  done
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
    update_site_php_conf "/etc/httpd/conf.d/${site_name}-selectel-ssl.conf" "$selected_php" || return 1
    if [[ -f "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" ]]; then
      mv "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf.old"
    fi
    echo
    echo -e -n "Перезапускаем apache для активации сайта ${LRED}${site_name}${WHITE}?"
        # Проверяем, а не punycode ли?
    if [[ "$site_name" =~ (xn\-\-) ]]
    then
        echo -e -n " (${GREEN}$(idn2 -d "$site_name")${WHITE})"
        echo
    else
        echo
    fi
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      if apachectl configtest; then
        if systemctl reload httpd; then
          echo "Сервер apache перезагружен"
        else
          echo "Не удалось перезагрузить сервер apache. Проверьте журналы для диагностики."
        fi
      else
        echo "Сервер не был перезагружен"
      fi
    else
      echo "Сервер apache перезапущен не был. Не забудьте потом перезапустить его самостоятельно."
    fi
    if [[ "$selected_php" != "$php_version" ]]; then
      check_site_php_cron "$site_name" "$path" "$username" "$selected_php" || return 1
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
