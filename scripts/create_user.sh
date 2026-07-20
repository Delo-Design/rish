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
  local authorized_keys_file="/etc/ssh/authorized_keys/${user}"
  local group_members
  local rollback_failed=0

  if [[ ! "$user" =~ ^[a-z0-9]+$ ]]; then
    echo -e "${RED}Откат остановлен:${WHITE} недопустимое имя пользователя."
    return 1
  fi

  echo "Отменяем создание пользователя ${user}."

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

CreateUser() {
  local NAME
  local default_username="$1"  # Получаем первый параметр, переданный в функцию
  local pass_file
  local home_existed=0
  local user_root_existed=0
  local authorized_keys_file_existed=0
  local private_group_existed=0
  local mariadb_user_created=0
  local -a rollback_args=()
  # try to create user

  while true; do
    echo -e "Используйте латинские буквы и цифры; первый символ должен быть буквой."
    echo -e -n "${WHITE}Введите имя пользователя (пустая строка для выхода):${GREEN}"
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
      echo "Используйте латинские буквы и цифры; первый символ должен быть буквой."
      continue
    fi

    if [[ "$NAME" == "html" ]]; then
      echo -e "${WHITE}Имя ${RED}html${WHITE} запрещено. Выберите другое."
      continue
    fi

    echo -e "${WHITE}Будет создан пользователь с именем: ${VIOLET}${NAME}${WHITE}"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
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
    echo -e "${WHITE}Создаем пользователя ${GREEN}${NAME}${WHITE}"
  fi
  echo -e "${WHITE}"
  echo "При создании новых сайтов Joomla требуется указать учетную запись для администратора."
  echo "Вы можете указать имя этой учетной записи, чтобы в дальнейшем не тратить время на ее изменение."
  echo -e "Если вы не укажете имя сейчас - оно будет создано автоматически. "
  echo -e "Изменить его можно будет в файле ${GREEN}/home/${NAME}/.pass.txt${WHITE}"
  echo
  echo "Введите имя учетной записи для создания сайтов по умолчанию (Обычно это ваш E-mail)"
  read -r -e -p "(Можно не заполнять - нажмите Enter)" DEFAULTSITEACCOUNT

  if id -u "${NAME}" >/dev/null 2>&1
  then
    echo -e "${WHITE}Такой пользователь уже есть ${LRED}${NAME}${WHITE}"
    return 1
  fi

  [[ -e "/home/${NAME}" || -L "/home/${NAME}" ]] && home_existed=1
  [[ -e "/var/www/${NAME}" || -L "/var/www/${NAME}" ]] && user_root_existed=1
  [[ -e "/etc/ssh/authorized_keys/${NAME}" || -L "/etc/ssh/authorized_keys/${NAME}" ]] && authorized_keys_file_existed=1
  getent group "$NAME" >/dev/null 2>&1 && private_group_existed=1
  rollback_args=("$NAME" "$home_existed" "$user_root_existed" \
    "$authorized_keys_file_existed" "$private_group_existed" "$mariadb_user_created")

  if ! useradd -s /sbin/nologin "$NAME"; then
    fail_user_creation "создание учётной записи Linux" "${rollback_args[@]}"
    return 1
  fi

  pass=$(tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs)
  if ((${#pass} != 16)); then
    fail_user_creation "генерация пароля Linux" "${rollback_args[@]}"
    return 1
  fi
  if ! printf '%s:%s\n' "$NAME" "$pass" | chpasswd; then
    fail_user_creation "установка пароля Linux" "${rollback_args[@]}"
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

  pass_file="/home/${NAME}/.pass.txt"
  if ! {
    printf 'Database: %s\n' "$pass2"
    printf '%s: %s\n' "$NAME" "$pass"
    printf 'defaultsiteaccount %s %s\n' "$DEFAULTSITEACCOUNT" "$pass3"
  } >"$pass_file"; then
    fail_user_creation "запись файла ${pass_file}" "${rollback_args[@]}"
    return 1
  fi

  if ! chmod 600 "$pass_file" || ! chown "${NAME}:${NAME}" "$pass_file"; then
    fail_user_creation "настройка прав файла ${pass_file}" "${rollback_args[@]}"
    return 1
  fi

  echo -e "Пароль пользователя ${NAME}: ${GREEN}${pass}${WHITE}"
  echo -e "Пароль для баз данных ${NAME}: ${GREEN}${pass2}${WHITE}"
  echo -e "Учетная запись по умолчанию: ${GREEN}${DEFAULTSITEACCOUNT}${WHITE}"
  echo -e "Пароли записаны в файл ${GREEN}${pass_file}${WHITE}"

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
    ! install -d -m 755 -o "$NAME" -g "$NAME" "/var/www/${NAME}/slowlog" ||
    ! install -d -m 755 -o "$NAME" -g "$NAME" "/var/www/${NAME}/tmp"; then
    fail_user_creation "создание каталогов пользователя" "${rollback_args[@]}"
    return 1
  fi

  if ! ensure_sftp_authorized_keys_file "${NAME}"; then
    fail_user_creation "создание защищённого файла ключей SFTP" "${rollback_args[@]}"
    return 1
  fi
  echo -e "Публичные ключи SFTP для ${GREEN}${NAME}${WHITE} добавляются в ${GREEN}/etc/ssh/authorized_keys/${NAME}${WHITE}."

  # Удаляем конфигурацию php по умолчанию (это файлы типа php74-php.conf)
  find /etc/httpd/conf.d -type f -name 'php[0-9][0-9]-php.conf' -exec rm -f {} +

  if ! create_hotlist; then
    fail_user_creation "обновление hotlist" "${rollback_args[@]}"
    return 1
  fi

  if mariadb  -e "CREATE USER ${NAME}@localhost IDENTIFIED BY '${pass2}';"
  then
    mariadb_user_created=1
    echo -e "пользователь ${GREEN}${NAME}${WHITE} успешно создан"
  else
    echo -e "во время создания пользователя ${RED}${NAME}${WHITE} MySQL произошла ошибка"
    fail_user_creation "создание учётной записи MariaDB" "${rollback_args[@]}"
    return 1
  fi

  return 0
}
