#!/usr/bin/env bash

php_check_cli() {
  local php_version="$1"
  local php_binary="/opt/remi/${php_version}/root/usr/bin/php"

  if ! "$php_binary" --version >/dev/null; then
    echo -e "Не удалось запустить ${RED}${php_version}${WHITE}."
    echo -e "Проверьте PHP CLI: ${YELLOW}${php_binary} --version${WHITE}"
    return 1
  fi
}

php_check_fpm_configuration() {
  local php_version="$1"
  local fpm_binary="/opt/remi/${php_version}/root/usr/sbin/php-fpm"

  if ! "$fpm_binary" -t >/dev/null; then
    echo -e "Проверка конфигурации ${RED}${php_version}-php-fpm${WHITE} завершилась ошибкой."
    echo -e "Повторить проверку: ${YELLOW}${fpm_binary} -t${WHITE}"
    return 1
  fi
}

php_verify_installed_versions() {
  local installed_packages package_name php_version

  if ! installed_packages="$(rpm -qa --qf '%{NAME}\n')"; then
    echo "Не удалось получить список установленных пакетов PHP."
    return 1
  fi

  while IFS= read -r package_name; do
    [[ "$package_name" =~ ^(php[0-9]{2})-php-fpm$ ]] || continue
    php_version="${BASH_REMATCH[1]}"
    php_check_cli "$php_version" || return 1
    php_check_fpm_configuration "$php_version" || return 1
    if ! systemctl is-active --quiet "${php_version}-php-fpm"; then
      echo -e "Установлены пакеты ${YELLOW}${php_version}${WHITE}, но служба ${RED}${php_version}-php-fpm${WHITE} не работает."
      echo -e "Проверьте состояние: ${YELLOW}systemctl status ${php_version}-php-fpm --no-pager -l${WHITE}"
      return 1
    fi
    if ! php_fpm_systemd_security_is_effective "$php_version"; then
      echo -e "Systemd не применил ожидаемые параметры защиты для ${RED}${php_version}-php-fpm${WHITE}."
      return 1
    fi
  done <<< "$installed_packages"
  return 0
}

function php_multi_install() {
  local options
  local available_versions
  declare -a versions_arr
  local max_verlen=0
  local pkg
  local ver
  local item
  local line
  local phpver
  local shortver
  local ver_str
  local installed_versions
  local www_template
  local www_conf
  local repository_packages

  while true; do
    available_versions=()
    versions_arr=()
    installed_versions=()
    #mapfile -t available_versions < <(dnf repository-packages remi-safe list | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)

    # 1. Получаем список версий и статус
    if ! repository_packages="$(dnf repository-packages remi-safe list)"; then
      echo "Не удалось получить список доступных версий PHP. Установка остановлена."
      exit 1
    fi
    while read pkg ver; do
        phpver=$(echo "$pkg" | grep -oE 'php[0-9]{2}')
        shortver=$(echo "$ver" | cut -d'-' -f1)
        if [[ "$shortver" == *~* ]]; then
          status="[${shortver#*~}]"
        else
          status="[stable]"
        fi
        ver_str="$phpver ($shortver)"
        versions_arr+=("$ver_str|$status")
        (( ${#ver_str} > max_verlen )) && max_verlen=${#ver_str}
    done < <(
      printf '%s\n' "$repository_packages" | awk '/^php[0-9]{2}-php-fpm\./ {print $1, $2}' | sort -ru
    )

    # 2. Собираем красивый массив для меню
    available_versions=()
    for item in "${versions_arr[@]}"; do
        ver_str="${item%%|*}"
        status="${item##*|}"
        printf -v line "%-${max_verlen}s %s" "$ver_str" "$status"
        available_versions+=("$line")
    done

    local available
    local max_installed_width=0

    while read item; do
      installed_versions+=("$item")
      (( ${#item} > max_installed_width )) && max_installed_width=${#item}
    done < <(
      rpm -qa | grep '^php[0-9][0-9]-php-fpm' | sort -r | while read pkg; do
        phpver=$(echo "$pkg" | grep -oE '^php[0-9]{2}')
        version=$(rpm -q --qf '%{VERSION}\n' "$pkg" | head -n1)
        echo "$phpver ($version)"
      done
    )
    max_installed_width=$((max_installed_width + 2))

    options=()
    for available in "${available_versions[@]}"; do
      phpver="${available%% *}"  # до первого пробела — всегда phpXX
      skip=
      for installed in "${installed_versions[@]}"; do
        installed_phpver="${installed%% *}" # тоже только phpXX
        if [[ "$phpver" == "$installed_phpver" ]]; then
          skip=1
          break
        fi
      done
      [[ ! $skip ]] && options+=("$available")
    done



    if [ ${#options[@]} -eq 0 ]; then
      echo "Пакеты всех доступных версий PHP уже установлены."
      return 0
    fi

    echo
    echo -e "Вы сможете доустановить невыбранные версии ${GREEN}PHP${WHITE} позднее, после установки RISH."
    echo -e "Установка ${GREEN}PHP${WHITE} происходит по очереди, одна версия за другой."
    echo -e "Выбирайте только реально необходимые, не ставьте все подряд."
    echo
    echo -e "Выберите нужную версию ${GREEN}PHP${WHITE} из доступных."
    local max_width=0
    local len
    local item
    for item in "${available_versions[@]}"; do
      len=${#item}
      (( len > max_width )) && max_width=$len
    done

    local left_block_width=$((max_width + 7))
    local right_block_x=$((left_block_width + 13))
    local arrow_x=$((left_block_width + 1))

    local current_y
    current_y=$(get_cursor_row)
    echo
    local size
    size=$(stty size)
    local lines=${size% *}
    ((skip_lines=0))
    ((need_to_skeep=${#installed_versions[@]}))
    if (((current_y + need_to_skeep + 1) > lines)); then
      ((skip_lines=${current_y} + need_to_skeep - ${lines} + 2))
      echo -en ${ESC}"[${skip_lines}S"
      ((current_y = ${current_y} - ${skip_lines}))
    fi
    if (( ${#installed_versions[@]} > 0 )); then
      cursor_to $(($current_y+2)) $arrow_x
      echo -en "───────────>"
      cursor_to $(($current_y)) $right_block_x
      echo -en "Установлено:"
      refresh_window ${current_y}+1 $right_block_x ${#installed_versions[@]} ${max_installed_width} 0 "${installed_versions[@]}"
    fi


    # Добавляем опцию для завершения процесса
    options+=("Завершить выбор")
    local default_index=$((${#options[@]} - 1))
    local option_index
    if (( ${#installed_versions[@]} == 0 )); then
      for option_index in "${!options[@]}"; do
        if [[ "${options[$option_index]}" == *" [stable]" ]]; then
          default_index=$option_index
          break
        fi
      done
    fi
    cursor_to $(($current_y)) 0
    echo "Доступно:"
    vertical_menu "current" 1 0 10 "default=$default_index" "${options[@]}"
    local ret=$?
    echo -en "${ESC}[1A${ESC}[K"
    if (( ret == 255 )) || (( ret == ${#options[@]}-1 )); then
      return 0
    fi
    local selected_line=${options[${ret}]}
    local selected_version
    selected_version=$(echo "$selected_line" | grep -oP '^php[0-9]{2}')

    echo "Установка выбранной версии PHP ($selected_version) и дополнительных расширений..."
    if ! sudo dnf install -y "$selected_version" \
    "${selected_version}-php-fpm" \
    "${selected_version}-php-opcache" \
    "${selected_version}-php-cli" \
    "${selected_version}-php-gd" \
    "${selected_version}-php-mbstring" \
    "${selected_version}-php-mysqlnd" \
    "${selected_version}-php-xml" \
    "${selected_version}-php-soap" \
    "${selected_version}-php-zip" \
    "${selected_version}-php-intl" \
    "${selected_version}-php-json" \
    "${selected_version}-php-gmp"; then
      echo -e "Не удалось установить пакеты ${RED}${selected_version}${WHITE}. Установка остановлена."
      exit 1
    fi
    php_check_cli "$selected_version" || exit 1

    PHPINI="/etc/opt/remi/${selected_version}/php.ini"
    if ! sed -i "s/memory_limit = .*/memory_limit = 256M/" "$PHPINI" ||
      ! sed -i "s/upload_max_filesize = .*/upload_max_filesize = 32M/" "$PHPINI" ||
      ! sed -i "s/post_max_size = .*/post_max_size = 32M/" "$PHPINI" ||
      ! sed -i "s/max_execution_time = .*/max_execution_time = 60/" "$PHPINI" ||
      ! sed -i "/^;\?max_input_vars[[:space:]]*=/c\max_input_vars = 20000" "$PHPINI" ||
      ! sed -i "s/output_buffering .*/output_buffering = Off/" "$PHPINI"; then
      echo -e "Не удалось настроить ${RED}${PHPINI}${WHITE}. Установка остановлена."
      exit 1
    fi

    echo -e "Установлены лимиты для ${GREEN}${selected_version}${WHITE}:"
    echo -e "memory_limit = ${GREEN}256M${WHITE}"
    echo -e "upload_max_filesize = ${GREEN}32M${WHITE}"
    echo -e "post_max_size = ${GREEN}32M${WHITE}"
    echo -e "max_execution_time = ${GREEN}60${WHITE}"
    echo -e "max_input_vars = ${GREEN}20000${WHITE}"

    www_template="${RISH_HOME}/templates/php-fpm-www.conf.template"
    www_conf="/etc/opt/remi/${selected_version}/php-fpm.d/www.conf"
    if [[ -f "$www_template" ]]; then
      if ! sed "s/{{PHP_VERSION}}/${selected_version}/g" "$www_template" > "$www_conf"; then
        echo -e "Не удалось записать конфигурацию ${RED}${www_conf}${WHITE}. Установка остановлена."
        exit 1
      fi
    else
      echo -e "Шаблон ${RED}${www_template}${WHITE} не найден."
      echo "Установка остановлена. Восстановите шаблон RISH и повторите установку."
      exit 1
    fi

    echo
    echo -e "Ставим ${GREEN}imagick${WHITE}?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      Install "${selected_version}-php-pecl-imagick" || exit 1
    fi
    if ${LocalServer}; then
      echo -e ${CURSORUP}"Ставим ${GREEN}Xdebug${WHITE}?${ERASEUNTILLENDOFLINE}"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        Install "${selected_version}-php-xdebug" || exit 1
        if [[ -e "/etc/opt/remi/${selected_version}/php.d/15-xdebug.ini" ]]; then
          if ! printf '%s\n' \
            'xdebug.idekey = "PHPSTORM"' \
            'xdebug.mode = debug' \
            'xdebug.client_port = 9003' \
            'xdebug.discover_client_host=1' >>"/etc/opt/remi/${selected_version}/php.d/15-xdebug.ini"; then
            echo -e "Не удалось настроить ${RED}/etc/opt/remi/${selected_version}/php.d/15-xdebug.ini${WHITE}. Установка остановлена."
            exit 1
          fi
        else
          echo -e "Файл ${RED}/etc/opt/remi/${selected_version}/php.d/15-xdebug.ini${WHITE} не существует!"
          echo -e "Возможны ошибки при установке xdebug."
          echo -e "Продолжить установку?"
          if vertical_menu "current" 2 0 5 "Да" "Нет"; then
            echo "Продолжаем..."
          else
            RemoveRim
            echo "Установка завершена с ошибкой"
            exit 1
          fi
        fi
      fi
    fi

    php_check_fpm_configuration "$selected_version" || exit 1
    if ! write_php_fpm_systemd_conf "$selected_version"; then
      echo -e "Не удалось создать защищенную systemd-конфигурацию для ${RED}${selected_version}-php-fpm${WHITE}."
      exit 1
    fi
    if ! systemctl daemon-reload; then
      echo -e "Не удалось перечитать systemd-конфигурацию для ${RED}${selected_version}-php-fpm${WHITE}."
      rollback_php_fpm_systemd_conf "$selected_version" || true
      systemctl daemon-reload || true
      exit 1
    fi
    if ! php_fpm_systemd_security_is_effective "$selected_version"; then
      echo -e "Systemd не применил ожидаемые параметры защиты для ${RED}${selected_version}-php-fpm${WHITE}."
      rollback_php_fpm_systemd_conf "$selected_version" || true
      systemctl daemon-reload || true
      exit 1
    fi

    if ! systemctl enable "${selected_version}-php-fpm"; then
      echo -e "Не удалось включить автозапуск ${RED}${selected_version}-php-fpm${WHITE}."
      rollback_php_fpm_systemd_conf "$selected_version" || true
      systemctl daemon-reload || true
      exit 1
    fi
    echo
    if ! systemctl start "${selected_version}-php-fpm"; then
      echo -e "Не удалось запустить ${RED}${selected_version}-php-fpm${WHITE}. Новая systemd-конфигурация будет отменена."
      systemctl disable "${selected_version}-php-fpm" || true
      rollback_php_fpm_systemd_conf "$selected_version" || true
      systemctl daemon-reload || true
      exit 1
    fi
    if ! systemctl is-active --quiet "${selected_version}-php-fpm"; then
      echo -e "Служба ${RED}${selected_version}-php-fpm${WHITE} не работает после запуска. Новая systemd-конфигурация будет отменена."
      echo -e "Проверьте состояние: ${YELLOW}systemctl status ${selected_version}-php-fpm --no-pager -l${WHITE}"
      systemctl disable "${selected_version}-php-fpm" || true
      rollback_php_fpm_systemd_conf "$selected_version" || true
      systemctl daemon-reload || true
      exit 1
    fi
    commit_php_fpm_systemd_conf "$selected_version" || true
    Up
    echo -e "${GREEN}${selected_version}${WHITE} успешно установлен. PHP-FPM работает."
    Down
    echo

  done
  source /root/rish/create_hotlist.sh
  create_hotlist

}
