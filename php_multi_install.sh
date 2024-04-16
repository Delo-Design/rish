#!/usr/bin/env bash

function php_multi_install() {
  local options
  while true; do
    mapfile -t available_versions < <(dnf repository-packages remi-safe list | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
    mapfile -t installed_versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
    options=()
    for available in "${available_versions[@]}"; do
      local skip=
      for installed in "${installed_versions[@]}"; do
        if [[ $available == $installed ]]; then
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
    echo -e "Выберите нужную версию ${GREEN}PHP${WHITE} из доступных."
    echo
    local current_y=$(get_cursor_row)
    local size=$(stty size)
    local lines=${size% *}
    ((skip_lines=0))
    ((need_to_skeep=${#installed_versions[@]}))
    if (((current_y + need_to_skeep + 1) > lines)); then
      ((skip_lines=${current_y} + need_to_skeep - ${lines} + 2))
      echo -en ${ESC}"[${skip_lines}S"
      ((current_y = ${current_y} - ${skip_lines}))
    fi
    if (( ${#installed_versions[@]} > 0 )); then
      cursor_to $(($current_y+2)) 23
      echo -en "───────────>"
      cursor_to $(($current_y)) 35
      echo -en "Установлено:"
      refresh_window ${current_y}+1 35 ${#installed_versions[@]} 10 0 "${installed_versions[@]}"
    fi


    # Добавляем опцию для завершения процесса
    options+=("Завершить выбор")
    cursor_to $(($current_y)) 0
    echo "Доступно:"
    vertical_menu "current" 1 0 10 "${options[@]}"
    local ret=$?
    if (( ret == 255 )) || (( ret == ${#options[@]}-1 )); then
      cursor_to $(($current_y)) 0
      echo -en ${ESC}"[0J"
      return 0
    fi
    local selected_version=${options[${ret}]}

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

    echo -e "Ставим ${GREEN}imagick${WHITE}?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      Install "${selected_version}-php-pecl-imagick"
      #yum install php-pecl-imagick
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

    systemctl enable ${selected_version}-php-fpm
    echo
    systemctl start ${selected_version}-php-fpm
    echo

  done
}


