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

php_check_rish_configuration() {
  local php_version="$1"
  local php_ini="/etc/opt/remi/${php_version}/php.ini"
  local pool_dir="/etc/opt/remi/${php_version}/php-fpm.d"
  local www_template="${RISH_HOME}/templates/php-fpm-www.conf.template"
  local pool_file expected_pool ini_mismatch
  local failed=0

  if [[ ! -r "$php_ini" ]]; then
    echo -e "Не удалось прочитать конфигурацию ${RED}${php_ini}${WHITE}."
    return 1
  fi

  # Пользовательские пулы означают существующую настройку сервера: базовые лимиты не навязываем.
  for pool_file in "$pool_dir"/*.conf; do
    if [[ -f "$pool_file" && "${pool_file##*/}" != "www.conf" ]]; then
      return 0
    fi
  done

  if [[ ! -r "$www_template" ]]; then
    echo -e "Не найден или недоступен шаблон ${RED}${www_template}${WHITE}."
    return 1
  fi
  expected_pool="$(sed "s/{{PHP_VERSION}}/${php_version}/g" "$www_template")" || return 1
  if ! printf '%s\n' "$expected_pool" | cmp -s - "$pool_dir/www.conf"; then
    echo -e "Конфигурация ${YELLOW}${pool_dir}/www.conf${WHITE} отсутствует или отличается от RISH-шаблона."
    failed=1
  fi

  if ! ini_mismatch="$(awk '
    BEGIN {
      count = split("memory_limit upload_max_filesize post_max_size max_execution_time max_input_vars output_buffering", keys, " ")
      expected["memory_limit"] = "256m"
      expected["upload_max_filesize"] = "32m"
      expected["post_max_size"] = "32m"
      expected["max_execution_time"] = "60"
      expected["max_input_vars"] = "20000"
      expected["output_buffering"] = "off"
    }
    /^[[:space:]]*[;#]/ { next }
    /^[[:space:]]*\[/ {
      scoped = $0 ~ /^[[:space:]]*\[(PATH|HOST)[[:space:]]*=/
      next
    }
    scoped { next }
    index($0, "=") {
      key = substr($0, 1, index($0, "=") - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (!(key in expected)) next
      value = substr($0, index($0, "=") + 1)
      sub(/;.*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["\047]|["\047]$/, "", value)
      value = tolower(value)
      if (key == "output_buffering" && value == "0") value = "off"
      actual[key] = value
    }
    END {
      failed = 0
      for (i = 1; i <= count; i++) {
        key = keys[i]
        if (!(key in actual) || actual[key] != expected[key]) {
          printf "  %s = %s; ожидается %s\n", key, (key in actual ? actual[key] : "не задано"), expected[key]
          failed = 1
        }
      }
      exit failed
    }
  ' "$php_ini")"; then
    echo -e "Базовые настройки ${YELLOW}${php_ini}${WHITE} не завершены или отличаются от RISH:"
    [[ -z "$ini_mismatch" ]] || printf '%s\n' "$ini_mismatch"
    failed=1
  fi
  if ((failed)); then
    echo "Автоматическое завершение невозможно. Проверьте указанные конфиги и повторите установку."
  fi
  return "$failed"
}

php_get_installed_fpm_versions() {
  local installed_packages

  if ! installed_packages="$(rpm -qa --qf '%{NAME}\n')"; then
    echo "Не удалось получить список установленных пакетов PHP." >&2
    return 1
  fi

  printf '%s\n' "$installed_packages" | sed -nE '/^php[0-9]{2}-php-fpm$/s/-php-fpm$//p' | sort -ru
}

php_fpm_needs_setup() {
  local php_version="$1"

  ! systemctl is-active --quiet "${php_version}-php-fpm" ||
    ! systemctl is-enabled --quiet "${php_version}-php-fpm" ||
    ! php_fpm_systemd_security_is_effective "$php_version" ||
    ! php_check_rish_configuration "$php_version" >/dev/null 2>&1
}

php_installed_versions_need_setup() {
  local installed_versions php_version

  installed_versions="$(php_get_installed_fpm_versions)" || return 2
  while IFS= read -r php_version; do
    [[ -n "$php_version" ]] || continue
    php_fpm_needs_setup "$php_version" && return 0
  done <<< "$installed_versions"
  return 1
}

php_verify_installed_versions() {
  local installed_versions php_version

  installed_versions="$(php_get_installed_fpm_versions)" || return 1
  while IFS= read -r php_version; do
    [[ -n "$php_version" ]] || continue
    php_check_rish_configuration "$php_version" || return 1
    php_check_cli "$php_version" || return 1
    php_check_fpm_configuration "$php_version" || return 1
    if ! systemctl is-active --quiet "${php_version}-php-fpm"; then
      echo -e "Установлены пакеты ${YELLOW}${php_version}${WHITE}, но служба ${RED}${php_version}-php-fpm${WHITE} не работает."
      echo -e "Проверьте состояние: ${YELLOW}systemctl status ${php_version}-php-fpm --no-pager -l${WHITE}"
      return 1
    fi
    if ! systemctl is-enabled --quiet "${php_version}-php-fpm"; then
      echo -e "Автозапуск ${RED}${php_version}-php-fpm${WHITE} не включён."
      return 1
    fi
    if ! php_fpm_systemd_security_is_effective "$php_version"; then
      echo -e "Systemd не применил ожидаемые параметры защиты для ${RED}${php_version}-php-fpm${WHITE}."
      return 1
    fi
  done <<< "$installed_versions"
  return 0
}

php_install_optional_extension() {
  local package="$1"
  local choice

  # 0: установлено, 2: пользователь пропустил, 1: остановка установки.
  while true; do
    if Install --optional "$package"; then
      return 0
    fi

    echo -e "Не удалось установить необязательное расширение ${YELLOW}${package}${WHITE}."
    vertical_menu "current" 2 0 10 "default=2" \
      "Повторить попытку" "Продолжить без расширения" "Остановить установку"
    choice=$?
    case "$choice" in
      0) continue ;;
      1)
        echo -e "Продолжаем без ${YELLOW}${package}${WHITE}. Расширение можно установить позднее."
        return 2
        ;;
      *)
        echo "Установка PHP остановлена."
        return 1
        ;;
    esac
  done
}

php_rollback_fpm_setup() {
  local php_version="$1"
  local disable_autostart="$2"
  # 0: службу не трогать, 1: восстановить работающую, 2: остановить.
  local restore_service="$3"
  local failed=0

  if ((restore_service == 2)); then
    systemctl stop "${php_version}-php-fpm" || failed=1
  fi
  if ((disable_autostart)); then
    systemctl disable "${php_version}-php-fpm" || failed=1
  fi
  rollback_php_fpm_systemd_conf "$php_version" || failed=1
  systemctl daemon-reload || failed=1
  if ((restore_service == 1)); then
    systemctl restart "${php_version}-php-fpm" || failed=1
    systemctl is-active --quiet "${php_version}-php-fpm" || failed=1
  fi
  if ((failed)); then
    echo -e "Не удалось полностью восстановить прежнее состояние ${RED}${php_version}-php-fpm${WHITE}."
    echo -e "Проверьте состояние: ${YELLOW}systemctl status ${php_version}-php-fpm --no-pager -l${WHITE}"
  fi
  return "$failed"
}

php_finalize_fpm_setup() {
  local php_version="$1"
  local disable_autostart=0
  local service_action="start"
  local restore_service=2

  php_check_rish_configuration "$php_version" || return 1
  php_check_cli "$php_version" || return 1
  php_check_fpm_configuration "$php_version" || return 1
  if systemctl is-active --quiet "${php_version}-php-fpm"; then
    service_action="restart"
    restore_service=1
  fi

  if ! write_php_fpm_systemd_conf "$php_version"; then
    echo -e "Не удалось создать защищенную systemd-конфигурацию для ${RED}${php_version}-php-fpm${WHITE}."
    return 1
  fi
  if ! systemctl daemon-reload; then
    echo -e "Не удалось перечитать systemd-конфигурацию для ${RED}${php_version}-php-fpm${WHITE}."
    php_rollback_fpm_setup "$php_version" 0 0 || true
    return 1
  fi
  if ! php_fpm_systemd_security_is_effective "$php_version"; then
    echo -e "Systemd не применил ожидаемые параметры защиты для ${RED}${php_version}-php-fpm${WHITE}."
    php_rollback_fpm_setup "$php_version" 0 0 || true
    return 1
  fi

  if ! systemctl is-enabled --quiet "${php_version}-php-fpm"; then
    disable_autostart=1
  fi
  if ! systemctl enable "${php_version}-php-fpm" ||
    ! systemctl is-enabled --quiet "${php_version}-php-fpm"; then
    echo -e "Не удалось включить автозапуск ${RED}${php_version}-php-fpm${WHITE}."
    php_rollback_fpm_setup "$php_version" "$disable_autostart" 0 || true
    return 1
  fi
  if ! systemctl "$service_action" "${php_version}-php-fpm" ||
    ! systemctl is-active --quiet "${php_version}-php-fpm"; then
    echo -e "Не удалось запустить ${RED}${php_version}-php-fpm${WHITE}. Выполняется откат systemd-настроек."
    echo -e "Проверьте состояние: ${YELLOW}systemctl status ${php_version}-php-fpm --no-pager -l${WHITE}"
    php_rollback_fpm_setup "$php_version" "$disable_autostart" "$restore_service" || true
    return 1
  fi
  commit_php_fpm_systemd_conf "$php_version" || true
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
  local installed_fpm_versions
  local optional_status

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

    installed_fpm_versions="$(php_get_installed_fpm_versions)" || return 1
    while IFS= read -r phpver; do
      [[ -n "$phpver" ]] || continue
      if ! ver="$(rpm -q --qf '%{VERSION}\n' "${phpver}-php-fpm")"; then
        echo -e "Не удалось определить версию установленного ${RED}${phpver}${WHITE}."
        return 1
      fi
      item="$phpver ($ver)"
      installed_versions+=("$item")
      (( ${#item} > max_installed_width )) && max_installed_width=${#item}
    done <<< "$installed_fpm_versions"
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
    for item in "${installed_versions[@]}"; do
      phpver="${item%% *}"
      if php_fpm_needs_setup "$phpver"; then
        options+=("$phpver (завершить настройку)")
      fi
    done

    if [ ${#options[@]} -eq 0 ]; then
      echo "Пакеты всех доступных версий PHP уже установлены."
      php_verify_installed_versions
      return $?
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
    for item in "${options[@]}"; do
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
      php_verify_installed_versions
      return $?
    fi
    local selected_line=${options[${ret}]}
    local selected_version
    selected_version=$(echo "$selected_line" | grep -oP '^php[0-9]{2}')

    if [[ "$selected_line" == *" (завершить настройку)" ]]; then
      echo -e "Завершаем настройку ${GREEN}${selected_version}${WHITE} с существующими конфигурациями PHP и пулов."
      php_finalize_fpm_setup "$selected_version" || return 1
      echo -e "Настройка ${GREEN}${selected_version}${WHITE} завершена. PHP-FPM работает."
      continue
    fi

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
      php_install_optional_extension "${selected_version}-php-pecl-imagick"
      optional_status=$?
      if ((optional_status != 0 && optional_status != 2)); then
        return 1
      fi
    fi
    if ${LocalServer}; then
      echo -e ${CURSORUP}"Ставим ${GREEN}Xdebug${WHITE}?${ERASEUNTILLENDOFLINE}"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        php_install_optional_extension "${selected_version}-php-xdebug"
        optional_status=$?
        if ((optional_status != 0 && optional_status != 2)); then
          return 1
        fi
        if ((optional_status == 2)); then
          : # Не записываем настройки пропущенного расширения.
        elif [[ -e "/etc/opt/remi/${selected_version}/php.d/15-xdebug.ini" ]]; then
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

    php_finalize_fpm_setup "$selected_version" || return 1
    Up
    echo -e "${GREEN}${selected_version}${WHITE} успешно установлен. PHP-FPM работает."
    Down
    echo

  done
  source /root/rish/create_hotlist.sh
  create_hotlist

}
