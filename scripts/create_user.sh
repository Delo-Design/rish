#!/usr/bin/env bash

# This module is sourced by ri.sh and scripts/user_management.sh.
# shellcheck disable=SC2154
check_user_dirs_exist() {
  local count=0
  local dir
  local name

  for dir in /var/www/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    case "$name" in
    cgi-bin|html)
      continue
      ;;
    *)
      count=$((count + 1))
      ;;
    esac
  done

  ((count > 0))
}

rollback_failed_user_creation() {
  local user="$1"
  local home_existed="$2"
  local user_root_existed="$3"
  local authorized_keys_file_existed="$4"
  local private_group_existed="$5"
  local mariadb_user_created="$6"
  local credentials_created="$7"
  local authorized_keys_file="/etc/ssh/authorized_keys/${user}"
  local group_members
  local rollback_failed=0

  if [[ ! "$user" =~ ^[a-z0-9]+$ ]]; then
    echo -e "${RED}Откат остановлен:${WHITE} недопустимое имя пользователя."
    return 1
  fi

  echo "Отменяем создание пользователя ${user}."

  if ((credentials_created)); then
    if ! remove_user_credentials "$user"; then
      echo -e "Не удалось удалить файл учетных данных пользователя ${RED}${user}${WHITE}."
      rollback_failed=1
    fi
  fi

  if ((mariadb_user_created)); then
    if ! mariadb -e "DROP USER IF EXISTS '${user}'@'localhost';"; then
      echo -e "Не удалось удалить учётную запись MariaDB ${RED}'${user}'@'localhost'${WHITE}."
      rollback_failed=1
    fi
  fi

  if ((!authorized_keys_file_existed)); then
    if ! rm -f -- "$authorized_keys_file"; then
      echo -e "Не удалось удалить файл ключей ${RED}${authorized_keys_file}${WHITE}."
      rollback_failed=1
    fi
  fi

  if id "$user" >/dev/null 2>&1; then
    if id -nG apache 2>/dev/null | tr ' ' '\n' | grep -Fxq "$user"; then
      if ! gpasswd -d apache "$user" >/dev/null 2>&1; then
        echo -e "Не удалось удалить пользователя ${RED}apache${WHITE} из группы ${RED}${user}${WHITE}."
        rollback_failed=1
      fi
    fi

    if ((home_existed)); then
      userdel "$user" >/dev/null 2>&1 || true
    else
      userdel --remove "$user" >/dev/null 2>&1 || true
    fi
    if id "$user" >/dev/null 2>&1; then
      echo -e "Не удалось удалить учётную запись Linux ${RED}${user}${WHITE}."
      rollback_failed=1
    fi
  fi

  if ((!private_group_existed)) && getent group "$user" >/dev/null 2>&1; then
    group_members="$(getent group "$user" | awk -F: '{print $4}')"
    if [[ -z "$group_members" ]]; then
      if ! groupdel "$user" >/dev/null 2>&1; then
        echo -e "Не удалось удалить группу ${RED}${user}${WHITE}."
        rollback_failed=1
      fi
    else
      echo -e "Группа ${RED}${user}${WHITE} не удалена: в ней остались участники ${group_members}."
      rollback_failed=1
    fi
  fi

  if ((!user_root_existed)); then
    if ! rm -rf -- "/var/www/${user}"; then
      echo -e "Не удалось удалить каталог ${RED}/var/www/${user}${WHITE}."
      rollback_failed=1
    fi
  fi

  if ! create_hotlist; then
    echo -e "Не удалось обновить ${RED}hotlist${WHITE} после отката."
    rollback_failed=1
  fi

  if ((rollback_failed)); then
    echo -e "Откат создания пользователя ${RED}${user}${WHITE} выполнен не полностью. Проверьте перечисленные ошибки."
    return 1
  fi

  echo -e "Создание пользователя ${GREEN}${user}${WHITE} полностью отменено."
  return 0
}

fail_user_creation() {
  local stage="$1"
  shift

  echo -e "Не удалось выполнить этап создания пользователя: ${RED}${stage}${WHITE}."
  rollback_failed_user_creation "$@" || true
  return 1
}

is_valid_site_email() {
  local email="$1"
  local local_part
  local domain
  local label
  local top_level_domain
  local -a domain_labels=()

  ((${#email} <= 254)) || return 1
  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || return 1

  local_part="${email%%@*}"
  domain="${email#*@}"
  ((${#local_part} <= 64 && ${#domain} <= 253)) || return 1
  [[ "$local_part" != .* && "$local_part" != *. && "$local_part" != *..* ]] || return 1
  [[ "$domain" == *.* && "$domain" != .* && "$domain" != *. && "$domain" != *..* ]] || return 1

  IFS='.' read -r -a domain_labels <<<"$domain"
  for label in "${domain_labels[@]}"; do
    ((${#label} <= 63)) || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done

  top_level_domain="${domain_labels[${#domain_labels[@]} - 1]}"
  [[ "$top_level_domain" =~ ^([A-Za-z]{2,63}|[Xx][Nn]--[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)$ ]]
}

print_created_user_credentials() {
  local user="$1"
  local sftp_password="$2"
  local database_password="$3"
  local site_login="$4"
  local site_password="$5"
  local credentials_file="$6"
  local terminal_columns="${COLUMNS:-80}"
  local content_width=48
  local framed=1
  local i line label chunk offset label_length padding
  # Each row is a label/value pair. Add color only after measuring plain text.
  local -a rows=(
    "Сохраните доступы" ""
    "" ""
    "SFTP" ""
    "  Логин:         " "$user"
    "  Пароль:        " "$sftp_password"
    "" ""
    "MariaDB" ""
    "  Сервер:        " "localhost"
    "  Логин:         " "$user"
    "  Пароль:        " "$database_password"
    "" ""
    "Администратор новых сайтов" ""
    "  Логин (E-mail): " "$site_login"
    "  Пароль:         " "$site_password"
    "" ""
    "Файл доступов:" ""
    "  " "$credentials_file"
  )

  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    terminal_columns="$(tput cols 2>/dev/null)" || terminal_columns="${COLUMNS:-80}"
  fi
  [[ "$terminal_columns" =~ ^[1-9][0-9]{0,3}$ ]] || terminal_columns=80

  for ((i = 0; i < ${#rows[@]}; i += 2)); do
    line="${rows[i]}${rows[i + 1]}"
    if ((${#line} > content_width)); then
      content_width=${#line}
    fi
  done

  # Leave the last terminal column free to avoid automatic line wrapping.
  if ((terminal_columns < 8)); then
    framed=0
    content_width=$((terminal_columns - 1))
    ((content_width > 0)) || content_width=1
  elif ((content_width > terminal_columns - 5)); then
    content_width=$((terminal_columns - 5))
  fi

  if ((framed)); then
    printf '┌'
    repl '─' "$((content_width + 2))"
    printf '┐\n'
  fi

  for ((i = 0; i < ${#rows[@]}; i += 2)); do
    label="${rows[i]}"
    line="${label}${rows[i + 1]}"
    offset=0
    while true; do
      chunk="${line:offset:content_width}"
      label_length=$((${#label} - offset))
      ((label_length >= 0)) || label_length=0
      if ((label_length > ${#chunk})); then
        label_length=${#chunk}
      fi

      if ((framed)); then
        printf '│ '
      fi
      printf '%s' "${chunk:0:label_length}"
      if ((label_length < ${#chunk})); then
        printf '%b%s%b' "$GREEN" "${chunk:label_length}" "$WHITE"
      fi
      if ((framed)); then
        padding=$((content_width - ${#chunk}))
        printf '%*s │\n' "$padding" ''
      else
        printf '\n'
      fi

      offset=$((offset + content_width))
      ((offset < ${#line})) || break
    done
  done

  if ((framed)); then
    printf '└'
    repl '─' "$((content_width + 2))"
    printf '┘\n'
  fi
  printf '\nSFTP: по умолчанию вход по SSH-ключу.\n'
  printf 'Публичные ключи: %b%s%b\n' "$GREEN" "/etc/ssh/authorized_keys/${user}" "$WHITE"
  return 0
}

CreateUser() {
  local NAME
  local default_username="$1"  # Получаем первый параметр, переданный в функцию
  local credentials_file
  local home_existed=0
  local user_root_existed=0
  local authorized_keys_file_existed=0
  local private_group_existed=0
  local mariadb_user_created=0
  local credentials_created=0
  local -a rollback_args=()
  # try to create user

  printf '%bСоздание пользователя\n\n' "$WHITE"
  while true; do
    echo "Имя: латинские буквы и цифры, первый символ буква. Пример: okna40."
    echo -e -n "${WHITE}Имя пользователя (Enter для выхода):${GREEN}"
    if [[ -z "$default_username" ]]; then
      read -r -e -p " " NAME  # Не задаем значение по умолчанию, если параметр пустой
    else
      read -r -e -p " " -i "$default_username" NAME  # Используем переданный параметр как значение по умолчанию
    fi

    if [[ -z "$NAME" || "$NAME" == "EXIT" || "$NAME" == "exit" ]]; then
      echo -e "${WHITE}"
      if ! check_user_dirs_exist; then
        echo -e "${RED}Нельзя выйти${WHITE}, пока не создан ни один пользователь."
        echo -e "Создайте хотя бы одного пользователя."
        continue
      fi
      echo -e "${WHITE}"
      return 0
    fi

    NAME="${NAME,,}"
    if [[ ! "$NAME" =~ ^[a-z][a-z0-9]*$ ]]; then
      echo -e "${WHITE}Некорректное имя."
      continue
    fi

    if [[ "$NAME" == "html" ]]; then
      echo -e "${WHITE}Имя ${RED}html${WHITE} запрещено. Выберите другое."
      continue
    fi

    echo -e "${WHITE}Создать пользователя ${VIOLET}${NAME}${WHITE}?"
    if vertical_menu "current" 2 0 5 "Создать" "Изменить имя"
    then
      if id -u "${NAME}" >/dev/null 2>&1
      then
        echo -e "${WHITE}Такой пользователь уже есть ${LRED}${NAME}${WHITE}"
      else
        break
      fi
    fi
  done

  if  [[ ${NAME} == "EXIT" ]] || [[ ${NAME} == "exit" ]]
  then
    echo -e "${WHITE}"
    return 0
  else
    printf '\n%bАдминистратор новых сайтов\n' "$WHITE"
  fi
  while true; do
    printf '%b' "$GREEN"
    read -r -e -i "info@${NAME}.com" \
      -p $'\001\033[0m\002Логин (E-mail): \001\033[0;32m\002' DEFAULTSITEACCOUNT
    printf '%b' "$WHITE"
    if [[ -z "$DEFAULTSITEACCOUNT" ]] || is_valid_site_email "$DEFAULTSITEACCOUNT"; then
      break
    fi

    echo -e "${WHITE}Некорректный E-mail: ${RED}${DEFAULTSITEACCOUNT}${WHITE}"
    echo "Введите адрес в формате name@example.com или оставьте поле пустым."
  done

  if id -u "${NAME}" >/dev/null 2>&1
  then
    echo -e "${WHITE}Такой пользователь уже есть ${LRED}${NAME}${WHITE}"
    return 1
  fi

  [[ -e "/home/${NAME}" || -L "/home/${NAME}" ]] && home_existed=1
  [[ -e "/var/www/${NAME}" || -L "/var/www/${NAME}" ]] && user_root_existed=1
  [[ -e "/etc/ssh/authorized_keys/${NAME}" || -L "/etc/ssh/authorized_keys/${NAME}" ]] && authorized_keys_file_existed=1
  getent group "$NAME" >/dev/null 2>&1 && private_group_existed=1
  credentials_file="$(rish_credentials_file "$NAME")" || return 1
  if [[ -e "$credentials_file" || -L "$credentials_file" ]]; then
    echo -e "Файл учетных данных ${RED}${credentials_file}${WHITE} уже существует."
    return 1
  fi
  rollback_args=("$NAME" "$home_existed" "$user_root_existed" \
    "$authorized_keys_file_existed" "$private_group_existed" "$mariadb_user_created" "$credentials_created")

  printf '\nСоздаём пользователя %b%s%b...\n' "$GREEN" "$NAME" "$WHITE"
  if ! useradd -s /sbin/nologin "$NAME"; then
    fail_user_creation "создание учётной записи Linux" "${rollback_args[@]}"
    return 1
  fi

  pass=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs)
  if ((${#pass} != 16)); then
    fail_user_creation "генерация пароля SFTP-пользователя" "${rollback_args[@]}"
    return 1
  fi
  if ! printf '%s:%s\n' "$NAME" "$pass" | chpasswd; then
    fail_user_creation "установка пароля SFTP-пользователя" "${rollback_args[@]}"
    return 1
  fi

  pass2=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs)
  if ((${#pass2} != 16)); then
    fail_user_creation "генерация пароля MariaDB" "${rollback_args[@]}"
    return 1
  fi
  pass3=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs)
  if ((${#pass3} != 16)); then
    fail_user_creation "генерация пароля учётной записи сайта" "${rollback_args[@]}"
    return 1
  fi

  if [[ -z ${DEFAULTSITEACCOUNT} ]]
  then
    DEFAULTSITEACCOUNT="info@${NAME}.com"
  fi

  if ! write_user_credentials "$NAME" "$pass" "$pass2" "$DEFAULTSITEACCOUNT" "$pass3"; then
    fail_user_creation "запись файла ${credentials_file}" "${rollback_args[@]}"
    return 1
  fi
  credentials_created=1
  rollback_args=("$NAME" "$home_existed" "$user_root_existed" \
    "$authorized_keys_file_existed" "$private_group_existed" "$mariadb_user_created" "$credentials_created")

  if ! usermod -aG sftp "$NAME"; then
    fail_user_creation "добавление пользователя в группу sftp" "${rollback_args[@]}"
    return 1
  fi
  if ! usermod -aG "$NAME" apache; then
    fail_user_creation "добавление apache в группу ${NAME}" "${rollback_args[@]}"
    return 1
  fi

  if ! install -d -m 750 -o root -g "$NAME" "/var/www/${NAME}" ||
    ! install -d -m 755 -o "$NAME" -g "$NAME" "/var/www/${NAME}/www" ||
    ! install -d -m 755 -o "$NAME" -g "$NAME" "/var/www/${NAME}/logs" ||
    ! install -d -m 755 -o "$NAME" -g "$NAME" "/var/www/${NAME}/session" ||
    ! install -d -m 755 -o "$NAME" -g "$NAME" "/var/www/${NAME}/wsdlcache" ||
    ! install -d -m 755 -o "$NAME" -g "$NAME" "/var/www/${NAME}/tmp"; then
    fail_user_creation "создание каталогов пользователя" "${rollback_args[@]}"
    return 1
  fi

  if ! ensure_sftp_authorized_keys_file "${NAME}"; then
    fail_user_creation "создание защищённого файла ключей SFTP" "${rollback_args[@]}"
    return 1
  fi
  # Удаляем конфигурацию php по умолчанию (это файлы типа php74-php.conf)
  find /etc/httpd/conf.d -type f -name 'php[0-9][0-9]-php.conf' -exec rm -f {} +

  if ! create_hotlist; then
    fail_user_creation "обновление hotlist" "${rollback_args[@]}"
    return 1
  fi

  if mariadb  -e "CREATE USER '${NAME}'@'localhost' IDENTIFIED BY '${pass2}';"
  then
    mariadb_user_created=1
  else
    echo -e "во время создания пользователя ${RED}${NAME}${WHITE} MySQL произошла ошибка"
    fail_user_creation "создание учётной записи MariaDB" "${rollback_args[@]}"
    return 1
  fi

  printf '\nПользователь %b%s%b создан.\n\n' "$GREEN" "$NAME" "$WHITE"
  print_created_user_credentials "$NAME" "$pass" "$pass2" "$DEFAULTSITEACCOUNT" "$pass3" "$credentials_file"

  return 0
}
