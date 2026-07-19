#!/usr/bin/env bash

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

  while true; do
    available_versions=()
    versions_arr=()
    installed_versions=()
    #mapfile -t available_versions < <(dnf repository-packages remi-safe list | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)

    # 1. Получаем список версий и статус
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
      dnf repository-packages remi-safe list | awk '/^php[0-9]{2}-php-fpm\./ {print $1, $2}' | sort -ru
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
      echo "Все доступные версии PHP уже установлены."
      return
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
    cursor_to $(($current_y)) 0
    echo "Доступно:"
    vertical_menu "current" 1 0 10 "${options[@]}"
    local ret=$?
    echo -en "${ESC}[1A${ESC}[K"
    if (( ret == 255 )) || (( ret == ${#options[@]}-1 )); then
      return 0
    fi
    local selected_line=${options[${ret}]}
    local selected_version
    selected_version=$(echo "$selected_line" | grep -oP '^php[0-9]{2}')

    echo "Установка выбранной версии PHP ($selected_version) и дополнительных расширений..."
    sudo dnf install -y "$selected_version" \
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
    "${selected_version}-php-gmp"

    Up
    echo -e "${GREEN}${selected_version}${WHITE} успешно установлен."
    Down
    PHPINI="/etc/opt/remi/${selected_version}/php.ini"
    sed -i "s/memory_limit = .*/memory_limit = 256M/" $PHPINI
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = 32M/" $PHPINI
    sed -i "s/post_max_size = .*/post_max_size = 32M/" $PHPINI
    sed -i "s/max_execution_time = .*/max_execution_time = 60/" $PHPINI
    sed -i "/^;\?max_input_vars[[:space:]]*=/c\max_input_vars = 20000" $PHPINI
    sed -i "s/output_buffering .*/output_buffering = Off/" $PHPINI

    echo -e "Установлены лимиты для ${GREEN}${selected_version}${WHITE}:"
    echo -e "memory_limit = ${GREEN}256M${WHITE}"
    echo -e "upload_max_filesize = ${GREEN}32M${WHITE}"
    echo -e "post_max_size = ${GREEN}32M${WHITE}"
    echo -e "max_execution_time = ${GREEN}60${WHITE}"
    echo -e "max_input_vars = ${GREEN}20000${WHITE}"

    www_template="${RISH_HOME}/templates/php-fpm-www.conf.template"
    www_conf="/etc/opt/remi/${selected_version}/php-fpm.d/www.conf"
    if [[ -f "$www_template" ]]; then
      sed "s/{{PHP_VERSION}}/${selected_version}/g" "$www_template" > "$www_conf"
    else
      echo -e "Шаблон ${RED}${www_template}${WHITE} не найден."
      echo -e "Оставляем стандартный ${YELLOW}${www_conf}${WHITE} от Remi."
    fi

    echo
    echo -e "Ставим ${GREEN}imagick${WHITE}?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      Install "${selected_version}-php-pecl-imagick"
    fi
    if ${LocalServer}; then
      echo -e ${CURSORUP}"Ставим ${GREEN}Xdebug${WHITE}?${ERASEUNTILLENDOFLINE}"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        Install "${selected_version}-php-xdebug"
        if [[ -e "/etc/opt/remi/${selected_version}/php.d/15-xdebug.ini" ]]; then
          {
            echo "xdebug.idekey = \"PHPSTORM\""
            echo "xdebug.mode = debug"
            echo "xdebug.client_port = 9003"
            echo "xdebug.discover_client_host=1"
          } >>"/etc/opt/remi/${selected_version}/php.d/15-xdebug.ini"
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
    commit_php_fpm_systemd_conf "$selected_version" || true
    echo

  done
  source /root/rish/create_hotlist.sh
  create_hotlist

}
