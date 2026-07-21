#!/usr/bin/env bash

# This module is sourced by scripts/user_management.sh.
# shellcheck disable=SC2154
DeleteUser() {
  local user="$1"
  local user_root
  local sites_dir
  local home_dir
  local sftp_authorized_keys_file
  local credentials_file
  local user_sql
  local database_output
  local global_privilege_output
  local process_output
  local cron_output=""
  local cron_exists=0
  local cron_status
  local blockers=0
  local deletion_errors=0
  local choice
  local version
  local pool_dir
  local pool_file
  local pool_candidate
  local pool_backup
  local www_conf
  local www_backup
  local www_temp
  local www_existed
  local default_pool_written
  local remaining_pool_count
  local php_error
  local php_test_output
  local pool_removed
  local rollback_version
  local rollback_pool_file
  local rollback_www_conf
  local rollback_failed
  local apache_group_membership_removed=0
  local group_entry
  local group_members
  local backup_dir=""
  local php_template="${RISH_HOME}/templates/php-fpm-www.conf.template"
  local -a server_users=()
  local -a site_entries=()
  local -a databases=()
  local -a vhost_candidates=()
  local -a vhost_files=()
  local -a pool_candidates=()
  local -a affected_versions=()
  local -a affected_pool_files=()
  local -a processed_versions=()
  local -A version_default_pool_written=()
  local -A version_www_existed=()

  if [[ -z "$user" || ! "$user" =~ ^[a-z0-9_][a-z0-9_-]*$ ]]; then
    echo -e "Некорректное имя пользователя: ${RED}${user:-пустое значение}${WHITE}."
    return 1
  fi
  if ! id "$user" > /dev/null 2>&1; then
    echo -e "Пользователь ${RED}${user}${WHITE} не существует."
    return 1
  fi
  if ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sftp; then
    echo -e "Пользователь ${RED}${user}${WHITE} не входит в группу ${YELLOW}sftp${WHITE}."
    echo "Удаление через RISH запрещено."
    return 1
  fi

  mapfile -t server_users < <(get_sftp_users)
  if ((${#server_users[@]} <= 1)); then
    echo -e "Пользователь ${YELLOW}${user}${WHITE} — последний пользователь сервера."
    echo "Удаление невозможно: на сервере должен оставаться хотя бы один пользователь."
    echo "Сначала создайте другого пользователя."
    return 1
  fi

  home_dir="$(getent passwd "$user" | awk -F: '{ print $6 }')"
  if [[ "$home_dir" != "/home/${user}" ]]; then
    echo -e "Домашний каталог пользователя ${RED}${user}${WHITE} не соответствует структуре RISH: ${YELLOW}${home_dir:-не определен}${WHITE}."
    return 1
  fi

  user_root="/var/www/${user}"
  sites_dir="${user_root}/www"
  sftp_authorized_keys_file="${RISH_SFTP_AUTHORIZED_KEYS_DIR}/${user}"
  credentials_file="$(rish_credentials_file "$user")" || return 1
  if [[ ! -d "$user_root" || -L "$user_root" || ! -d "$sites_dir" || -L "$sites_dir" ]]; then
    echo -e "Каталоги пользователя ${RED}${user}${WHITE} не соответствуют структуре RISH."
    echo -e "Ожидается обычный каталог ${YELLOW}${sites_dir}${WHITE}."
    return 1
  fi
  if [[ -e "$credentials_file" || -L "$credentials_file" ]]; then
    if [[ ! -f "$credentials_file" || -L "$credentials_file" ]]; then
      echo -e "Файл учетных данных имеет неожиданный тип: ${RED}${credentials_file}${WHITE}."
      return 1
    fi
  fi

  mapfile -t site_entries < <(find "$sites_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  if ((${#site_entries[@]} > 0)); then
    echo -e "У пользователя ${YELLOW}${user}${WHITE} остались сайты или файлы:"
    for pool_candidate in "${site_entries[@]}"; do
      echo -e "  - ${YELLOW}${pool_candidate}${WHITE}"
    done
    blockers=1
  fi

  user_sql="${user//\\/\\\\}"
  user_sql="${user_sql//\'/\\\'}"
  if ! database_output="$(
    mariadb -N -B -e "
      SELECT DISTINCT granted_objects.DATABASE_NAME
      FROM (
        SELECT TABLE_SCHEMA AS DATABASE_NAME
        FROM INFORMATION_SCHEMA.SCHEMA_PRIVILEGES
        WHERE GRANTEE = CONCAT(CHAR(39), '${user_sql}', CHAR(39), '@', CHAR(39), 'localhost', CHAR(39))
        UNION ALL
        SELECT TABLE_SCHEMA AS DATABASE_NAME
        FROM INFORMATION_SCHEMA.TABLE_PRIVILEGES
        WHERE GRANTEE = CONCAT(CHAR(39), '${user_sql}', CHAR(39), '@', CHAR(39), 'localhost', CHAR(39))
        UNION ALL
        SELECT TABLE_SCHEMA AS DATABASE_NAME
        FROM INFORMATION_SCHEMA.COLUMN_PRIVILEGES
        WHERE GRANTEE = CONCAT(CHAR(39), '${user_sql}', CHAR(39), '@', CHAR(39), 'localhost', CHAR(39))
        UNION ALL
        SELECT Db AS DATABASE_NAME
        FROM mysql.procs_priv
        WHERE User = '${user_sql}' AND Host = 'localhost'
      ) AS granted_objects
      INNER JOIN INFORMATION_SCHEMA.SCHEMATA AS existing_schemas
        ON existing_schemas.SCHEMA_NAME = granted_objects.DATABASE_NAME
      ORDER BY granted_objects.DATABASE_NAME;
    " 2>&1
  )"; then
    echo
    echo -e "Не удалось проверить базы данных пользователя ${RED}${user}${WHITE}."
    [[ -n "$database_output" ]] && echo "$database_output"
    blockers=1
  elif [[ -n "$database_output" ]]; then
    mapfile -t databases <<< "$database_output"
    echo
    echo -e "У пользователя ${YELLOW}${user}${WHITE} остались базы данных:"
    for pool_candidate in "${databases[@]}"; do
      echo -e "  - ${YELLOW}${pool_candidate}${WHITE}"
    done
    blockers=1
  fi

  if ! global_privilege_output="$(
    mariadb -N -B -e "
      SELECT PRIVILEGE_TYPE
      FROM INFORMATION_SCHEMA.USER_PRIVILEGES
      WHERE GRANTEE = CONCAT(CHAR(39), '${user_sql}', CHAR(39), '@', CHAR(39), 'localhost', CHAR(39))
        AND PRIVILEGE_TYPE <> 'USAGE'
      ORDER BY PRIVILEGE_TYPE;
    " 2>&1
  )"; then
    echo
    echo -e "Не удалось проверить глобальные права MariaDB пользователя ${RED}${user}${WHITE}."
    [[ -n "$global_privilege_output" ]] && echo "$global_privilege_output"
    blockers=1
  elif [[ -n "$global_privilege_output" ]]; then
    echo
    echo -e "У пользователя ${YELLOW}${user}${WHITE} остались глобальные права MariaDB:"
    while IFS= read -r pool_candidate; do
      echo -e "  - ${YELLOW}${pool_candidate}${WHITE}"
    done <<< "$global_privilege_output"
    blockers=1
  fi

  shopt -s nullglob
  vhost_candidates=(/etc/httpd/conf.d/*.conf)
  shopt -u nullglob
  if ((${#vhost_candidates[@]} > 0)); then
    mapfile -t vhost_files < <(grep -lF -- "${user_root}/" "${vhost_candidates[@]}" 2>/dev/null | sort)
  fi
  if ((${#vhost_files[@]} > 0)); then
    echo
    echo -e "В конфигурации Apache остались ссылки на пользователя ${YELLOW}${user}${WHITE}:"
    for pool_candidate in "${vhost_files[@]}"; do
      echo -e "  - ${YELLOW}${pool_candidate}${WHITE}"
    done
    blockers=1
  fi

  process_output="$(ps -u "$user" -o pid=,comm=,args= 2>/dev/null | awk '$2 != "php-fpm"')"
  if [[ -n "$process_output" ]]; then
    echo
    echo -e "У пользователя ${YELLOW}${user}${WHITE} выполняются процессы, не относящиеся к PHP-FPM:"
    while IFS= read -r pool_candidate; do
      echo -e "  - ${YELLOW}${pool_candidate}${WHITE}"
    done <<< "$process_output"
    blockers=1
  fi

  cron_output="$(LC_ALL=C crontab -l -u "$user" 2>&1)"
  cron_status=$?
  if ((cron_status == 0)); then
    cron_exists=1
  elif grep -Fqi "no crontab for" <<< "$cron_output"; then
    cron_output=""
  else
    echo
    echo -e "Не удалось проверить CRON пользователя ${RED}${user}${WHITE}."
    [[ -n "$cron_output" ]] && echo "$cron_output"
    blockers=1
  fi

  shopt -s nullglob
  pool_candidates=(/etc/opt/remi/php[0-9][0-9]/php-fpm.d/"${user}.conf")
  shopt -u nullglob
  for pool_file in "${pool_candidates[@]}"; do
    version="${pool_file#/etc/opt/remi/}"
    version="${version%%/*}"
    if [[ -f "$pool_file" && ! -L "$pool_file" ]]; then
      if [[ ! -x "/opt/remi/${version}/root/usr/sbin/php-fpm" ]]; then
        echo
        echo -e "Для PHP-пула ${RED}${pool_file}${WHITE} отсутствует исполняемый файл ${RED}/opt/remi/${version}/root/usr/sbin/php-fpm${WHITE}."
        blockers=1
      else
        affected_versions+=("$version")
        affected_pool_files+=("$pool_file")
      fi
    elif [[ -e "$pool_file" || -L "$pool_file" ]]; then
      echo
      echo -e "PHP-пул имеет неожиданный тип: ${RED}${pool_file}${WHITE}."
      blockers=1
    fi
  done

  if ((blockers != 0)); then
    echo
    echo -e "Удаление пользователя ${RED}${user}${WHITE} остановлено."
    echo
    echo "Как подготовить пользователя к удалению:"
    echo
    echo -e "  1. В Midnight Commander нажмите ${YELLOW}F2${WHITE}, чтобы открыть меню RISH."
    echo -e "     Выберите ${YELLOW}Создать/Удалить сайт${WHITE} → ${YELLOW}Удалить сайт${WHITE}"
    echo "     и последовательно удалите каждый сайт пользователя."
    echo
    echo -e "  2. В меню RISH выберите ${YELLOW}Базы данных${WHITE}"
    echo "     и удалите оставшиеся базы данных пользователя."
    echo
    echo -e "  3. Удалите оставшиеся файлы в Midnight Commander клавишей ${YELLOW}F8${WHITE}."
    echo
    echo "После этого снова запустите удаление пользователя."
    return 1
  fi

  echo
  echo -e "Пользователь: ${YELLOW}${user}${WHITE}"
  echo "Будут удалены:"
  echo -e "  - учетная запись Linux и каталог ${YELLOW}${home_dir}${WHITE}"
  echo -e "  - каталог данных ${YELLOW}${user_root}${WHITE}"
  echo -e "  - учетная запись MariaDB ${YELLOW}'${user}'@'localhost'${WHITE}"
  if [[ -e "$sftp_authorized_keys_file" || -L "$sftp_authorized_keys_file" ]]; then
    echo -e "  - ключи SFTP ${YELLOW}${sftp_authorized_keys_file}${WHITE}"
  fi
  if [[ -f "$credentials_file" && ! -L "$credentials_file" ]]; then
    echo -e "  - учетные данные ${YELLOW}${credentials_file}${WHITE}"
  fi
  for pool_file in "${affected_pool_files[@]}"; do
    echo -e "  - PHP-пул ${YELLOW}${pool_file}${WHITE}"
  done
  if ((cron_exists == 1)); then
    if [[ -n "$cron_output" ]]; then
      echo -e "  - пользовательский ${YELLOW}CRON${WHITE}:"
      while IFS= read -r pool_candidate; do
        echo "      ${pool_candidate}"
      done <<< "$cron_output"
    else
      echo -e "  - пустой файл пользовательского ${YELLOW}CRON${WHITE}"
    fi
  fi

  echo
  echo -e "Удалить пользователя ${RED}${user}${WHITE} и перечисленные данные?"
  vertical_menu "current" 2 0 5 "Нет" "Да"
  choice=$?
  if ((choice != 1)); then
    echo -e "${CURSORUP}Пользователь ${GREEN}${user}${WHITE} не удален."
    return 1
  fi

  if ((${#affected_versions[@]} > 0)); then
    backup_dir="$(mktemp -d "/tmp/rish-delete-${user}.XXXXXX")" || {
      echo "Не удалось подготовить резервные копии PHP-пулов."
      return 1
    }
    for version in "${affected_versions[@]}"; do
      pool_file="/etc/opt/remi/${version}/php-fpm.d/${user}.conf"
      pool_backup="${backup_dir}/${version}-${user}.conf"
      if ! cp -a -- "$pool_file" "$pool_backup"; then
        echo -e "Не удалось сохранить PHP-пул ${RED}${pool_file}${WHITE}."
        rm -rf -- "$backup_dir"
        return 1
      fi
    done
  fi

  if ((cron_exists == 1)); then
    if ! crontab -r -u "$user"; then
      echo -e "Не удалось удалить CRON пользователя ${RED}${user}${WHITE}."
      [[ -n "$backup_dir" ]] && rm -rf -- "$backup_dir"
      echo "Удаление пользователя остановлено."
      return 1
    fi
    echo -e "CRON пользователя ${GREEN}${user}${WHITE} удален."
  fi

  for version in "${affected_versions[@]}"; do
    pool_dir="/etc/opt/remi/${version}/php-fpm.d"
    pool_file="${pool_dir}/${user}.conf"
    pool_backup="${backup_dir}/${version}-${user}.conf"
    www_conf="${pool_dir}/www.conf"
    www_backup="${backup_dir}/${version}-www.conf"
    www_existed=0
    default_pool_written=0
    php_error=""
    php_test_output=""
    pool_removed=0

    if ! rm -f -- "$pool_file"; then
      php_error="Не удалось удалить PHP-пул ${pool_file}."
    else
      pool_removed=1
    fi

    if ((pool_removed == 1)); then
      remaining_pool_count=0
      shopt -s nullglob
      for pool_candidate in "${pool_dir}"/*.conf; do
        [[ "${pool_candidate##*/}" == "www.conf" ]] && continue
        remaining_pool_count=$((remaining_pool_count + 1))
      done
      shopt -u nullglob

      if ((remaining_pool_count == 0)); then
        if [[ ! -f "$php_template" ]]; then
          php_error="Не найден шаблон default pool ${php_template}."
        else
          if [[ -e "$www_conf" || -L "$www_conf" ]]; then
            if [[ ! -f "$www_conf" || -L "$www_conf" ]] || ! cp -a -- "$www_conf" "$www_backup"; then
              php_error="Не удалось сохранить существующий ${www_conf}."
            else
              www_existed=1
            fi
          fi
          if [[ -z "$php_error" ]]; then
            www_temp="$(mktemp "${pool_dir}/.www.conf.rish-tmp.XXXXXX")" || php_error="Не удалось подготовить ${www_conf}."
          fi
          if [[ -z "$php_error" ]]; then
            if ! sed "s/{{PHP_VERSION}}/${version}/g" "$php_template" > "$www_temp" ||
              ! chown root:root "$www_temp" ||
              ! chmod 644 "$www_temp" ||
              ! mv -f -- "$www_temp" "$www_conf"; then
              rm -f -- "$www_temp"
              php_error="Не удалось установить default pool ${www_conf}."
            else
              default_pool_written=1
            fi
          fi
        fi
      fi

      processed_versions+=("$version")
      version_default_pool_written["$version"]="$default_pool_written"
      version_www_existed["$version"]="$www_existed"
    fi

    if [[ -z "$php_error" ]]; then
      if ! php_test_output="$(/opt/remi/${version}/root/usr/sbin/php-fpm -t 2>&1)"; then
        php_error="Конфигурация ${version}-php-fpm не прошла проверку."
      elif ! systemctl restart "${version}-php-fpm"; then
        php_error="Не удалось перезапустить ${version}-php-fpm."
      fi
    fi

    if [[ -n "$php_error" ]]; then
      echo -e "${RED}${php_error}${WHITE}"
      [[ -n "$php_test_output" ]] && echo "$php_test_output"
      rollback_failed=0
      for rollback_version in "${processed_versions[@]}"; do
        rollback_pool_file="/etc/opt/remi/${rollback_version}/php-fpm.d/${user}.conf"
        rollback_www_conf="/etc/opt/remi/${rollback_version}/php-fpm.d/www.conf"

        if [[ "${version_default_pool_written[$rollback_version]}" -eq 1 ]]; then
          if [[ "${version_www_existed[$rollback_version]}" -eq 1 ]]; then
            if ! cp -a -- "${backup_dir}/${rollback_version}-www.conf" "$rollback_www_conf"; then
              echo -e "Не удалось восстановить ${RED}${rollback_www_conf}${WHITE}."
              rollback_failed=1
            fi
          elif ! rm -f -- "$rollback_www_conf"; then
            echo -e "Не удалось удалить временный default pool ${RED}${rollback_www_conf}${WHITE}."
            rollback_failed=1
          fi
        fi
        if ! cp -a -- "${backup_dir}/${rollback_version}-${user}.conf" "$rollback_pool_file"; then
          echo -e "Не удалось восстановить PHP-пул ${RED}${rollback_pool_file}${WHITE}."
          rollback_failed=1
          continue
        fi
        if ! /opt/remi/${rollback_version}/root/usr/sbin/php-fpm -t > /dev/null 2>&1 ||
          ! systemctl restart "${rollback_version}-php-fpm"; then
          echo -e "PHP-пул восстановлен, но сервис ${RED}${rollback_version}-php-fpm${WHITE} не удалось перезапустить."
          rollback_failed=1
        else
          echo -e "PHP-пул ${YELLOW}${rollback_pool_file}${WHITE} восстановлен."
        fi
      done
      rm -rf -- "$backup_dir"
      if ((rollback_failed != 0)); then
        echo -e "Откат PHP завершился с ${RED}ошибками${WHITE}."
      fi
      if ((cron_exists == 1)) && ! printf '%s\n' "$cron_output" | crontab -u "$user" -; then
        echo -e "Не удалось восстановить CRON пользователя ${RED}${user}${WHITE}."
      fi
      echo "Удаление пользователя остановлено."
      return 1
    fi

    echo -e "PHP-пул ${YELLOW}${pool_file}${WHITE} удален; ${GREEN}${version}-php-fpm перезапущен${WHITE}."
  done

  if id -nG apache 2>/dev/null | tr ' ' '\n' | grep -Fxq "$user"; then
    if gpasswd -d apache "$user" > /dev/null 2>&1; then
      apache_group_membership_removed=1
    else
      echo -e "Не удалось удалить пользователя ${RED}apache${WHITE} из группы ${RED}${user}${WHITE}."
      echo "Удаление учетной записи Linux будет продолжено, результат удаления группы будет проверен отдельно."
    fi
  fi

  if ! userdel --remove "$user"; then
    if id "$user" > /dev/null 2>&1; then
      echo -e "Не удалось удалить учетную запись Linux ${RED}${user}${WHITE}."
      rollback_failed=0
      for rollback_version in "${processed_versions[@]}"; do
        rollback_pool_file="/etc/opt/remi/${rollback_version}/php-fpm.d/${user}.conf"
        rollback_www_conf="/etc/opt/remi/${rollback_version}/php-fpm.d/www.conf"

        if [[ "${version_default_pool_written[$rollback_version]}" -eq 1 ]]; then
          if [[ "${version_www_existed[$rollback_version]}" -eq 1 ]]; then
            if ! cp -a -- "${backup_dir}/${rollback_version}-www.conf" "$rollback_www_conf"; then
              echo -e "Не удалось восстановить ${RED}${rollback_www_conf}${WHITE}."
              rollback_failed=1
            fi
          elif ! rm -f -- "$rollback_www_conf"; then
            echo -e "Не удалось удалить временный default pool ${RED}${rollback_www_conf}${WHITE}."
            rollback_failed=1
          fi
        fi
        if ! cp -a -- "${backup_dir}/${rollback_version}-${user}.conf" "$rollback_pool_file"; then
          echo -e "Не удалось восстановить PHP-пул ${RED}${rollback_pool_file}${WHITE}."
          rollback_failed=1
          continue
        fi
        if ! /opt/remi/${rollback_version}/root/usr/sbin/php-fpm -t > /dev/null 2>&1 ||
          ! systemctl restart "${rollback_version}-php-fpm"; then
          echo -e "PHP-пул восстановлен, но сервис ${RED}${rollback_version}-php-fpm${WHITE} не удалось перезапустить."
          rollback_failed=1
        else
          echo -e "PHP-пул ${YELLOW}${rollback_pool_file}${WHITE} восстановлен."
        fi
      done
      if ((apache_group_membership_removed == 1)) && ! usermod -aG "$user" apache; then
        echo -e "Не удалось вернуть пользователя ${RED}apache${WHITE} в группу ${RED}${user}${WHITE}."
        rollback_failed=1
      fi
      [[ -n "$backup_dir" ]] && rm -rf -- "$backup_dir"
      if ((rollback_failed != 0)); then
        echo -e "Откат завершился с ${RED}ошибками${WHITE}."
      fi
      if ((cron_exists == 1)); then
        if printf '%s\n' "$cron_output" | crontab -u "$user" -; then
          echo -e "CRON пользователя ${YELLOW}${user}${WHITE} восстановлен."
        else
          echo -e "Не удалось восстановить CRON пользователя ${RED}${user}${WHITE}."
        fi
      fi
      return 1
    fi

    echo -e "Учетная запись Linux ${GREEN}${user}${WHITE} удалена, но userdel не смог удалить все связанные с ней файлы."
    echo "Продолжаем очистку остальных данных."
    deletion_errors=1
  fi
  [[ -n "$backup_dir" ]] && rm -rf -- "$backup_dir"

  if group_entry="$(getent group "$user")"; then
    group_members="${group_entry##*:}"
    if tr ',' '\n' <<< "$group_members" | grep -Fxq apache; then
      if ! gpasswd -d apache "$user" > /dev/null 2>&1; then
        echo -e "Не удалось удалить пользователя ${RED}apache${WHITE} из оставшейся группы ${RED}${user}${WHITE}."
        deletion_errors=1
      fi
    fi

    if group_entry="$(getent group "$user")"; then
      group_members="${group_entry##*:}"
      if [[ -z "$group_members" ]]; then
        if groupdel "$user"; then
          echo -e "Персональная группа ${GREEN}${user}${WHITE} удалена."
        else
          echo -e "Не удалось удалить персональную группу ${RED}${user}${WHITE}."
          deletion_errors=1
        fi
      else
        echo -e "Персональная группа ${RED}${user}${WHITE} не удалена: в ней остались другие участники."
        echo -e "Участники: ${YELLOW}${group_members//,/, }${WHITE}"
        deletion_errors=1
      fi
    fi
  fi

  if ! rm -rf -- "$user_root"; then
    echo -e "Не удалось удалить каталог ${RED}${user_root}${WHITE}."
    deletion_errors=1
  fi
  if ! rm -f -- "$sftp_authorized_keys_file"; then
    echo -e "Не удалось удалить файл ключей SFTP ${RED}${sftp_authorized_keys_file}${WHITE}."
    deletion_errors=1
  fi
  if mariadb -e "DROP USER IF EXISTS '${user_sql}'@'localhost';"; then
    if ! remove_user_credentials "$user"; then
      echo -e "Не удалось удалить файл учетных данных ${RED}${credentials_file}${WHITE}."
      deletion_errors=1
    fi
  else
    echo -e "Не удалось удалить учетную запись MariaDB ${RED}'${user}'@'localhost'${WHITE}."
    echo -e "Файл учетных данных ${YELLOW}${credentials_file}${WHITE} сохранен для ручного восстановления."
    deletion_errors=1
  fi
  if ! create_hotlist; then
    echo -e "Не удалось обновить ${RED}hotlist Midnight Commander${WHITE}."
    deletion_errors=1
  fi

  if ((deletion_errors != 0)); then
    echo
    echo -e "Учетная запись Linux ${GREEN}${user}${WHITE} удалена, но часть сопутствующих данных удалить не удалось."
    return 1
  fi

  echo
  echo -e "Пользователь ${GREEN}${user}${WHITE} и связанные с ним данные удалены."
}
