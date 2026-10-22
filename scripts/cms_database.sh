#!/usr/bin/env bash

# Each adapter supplies detect, inspect and update; the database menu is CMS-neutral.
CMS_DATABASE_ADAPTERS=(joomla)
CMS_DATABASE_PATHS=()
CMS_DATABASE_TYPES=()
CMS_DATABASE_PHP_BINS=()
CMS_DATABASE_NAMES=()
CMS_DATABASE_USERS=()
CMS_DATABASE_HOSTS=()
CMS_DATABASE_HASHES=()
CMS_DATABASE_SITE_NAMES=()
CMS_DATABASE_MANUAL_PATHS=()
CMS_DATABASE_MANUAL_NAMES=()
CMS_DATABASE_MANUAL_REASONS=()
CMS_DATABASE_MANUAL_HOSTS=()
CMS_DATABASE_MANUAL_DATABASES=()
CMS_DATABASE_NO_DATABASE_PATHS=()
CMS_DATABASE_NO_DATABASE_NAMES=()
CMS_DATABASE_NO_DATABASE_DATABASES=()
CMS_DATABASE_AFFECTED_DATABASES=()
CMS_DATABASE_WARNINGS=0

source "${RISH_HOME}/php_helpers.sh"

cms_database_joomla_detect() {
  [[ -f "$1/configuration.php" && -f "$1/administrator/manifests/files/joomla.xml" ]]
}

cms_database_joomla_label() {
  printf '%s' 'Настроить Joomla configuration.php'
}

cms_database_joomla_name() {
  printf '%s' 'Joomla'
}

cms_database_joomla_inspect() {
  local config="$1/configuration.php" php_bin="$2" line key value literal checksum
  local property_re="^[[:blank:]]*(public|var)[[:blank:]]+[$](db|user|host)[[:blank:]]*=[[:blank:]]*('([^'\\\\]|\\\\.)*'|\"([^\"\\\\]|\\\\.)*\")[[:blank:]]*;.*$"
  local -A values=()

  [[ -f "$config" && ! -L "$config" && -r "$config" ]] || return 1
  checksum="$(sha256sum < "$config")" || return 1
  "$php_bin" -n -l < "$config" >/dev/null 2>&1 || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ $property_re ]] || continue
    key="${BASH_REMATCH[2]}"
    literal="${BASH_REMATCH[3]}"
    [[ -z "${values[$key]+present}" ]] || return 1
    value="${literal:1:${#literal}-2}"
    if [[ "${literal:0:1}" == "'" ]]; then
      value="${value//\\\'/\'}"
      value="${value//\\\\/\\}"
    else
      [[ "$value" != *\\* && "$value" != *'$'* ]] || return 1
    fi
    [[ -n "$value" && "$value" != *[[:cntrl:]]* ]] || return 1
    values["$key"]="$value"
  done < "$config"
  [[ -n "${values[db]:-}" && -n "${values[user]:-}" && -n "${values[host]:-}" ]] || return 1
  [[ "$(sha256sum < "$config")" == "$checksum" ]] || return 1
  printf '%s\t%s\t%s\t%s\n' "${values[db]}" "${values[user]}" "${values[host]}" "${checksum%% *}"
}

cms_database_joomla_update() (
  local site_path="$1" php_bin="$2" fingerprint="$3" config="$1/configuration.php"
  local password literal line ending matches=0 config_fd temporary="" backup_temporary=""
  local password_re="^([[:blank:]]*(public|var)[[:blank:]]+[$]password[[:blank:]]*=[[:blank:]]*)('([^'\\\\]|\\\\.)*'|\"([^\"\\\\]|\\\\.)*\")([[:blank:]]*;.*)$"

  trap 'rm -f -- "$temporary" "$backup_temporary"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if IFS= read -r -d '' password || [[ -z "$password" || "$password" == *[[:cntrl:]]* ]]; then
    echo 'Новый пароль пуст или содержит недопустимые символы.' >&2
    return 1
  fi
  [[ -f "$config" && ! -L "$config" ]] || return 1
  exec {config_fd}< "$config" || return 1
  if ! flock -n "$config_fd"; then
    echo 'Конфигурация занята другим процессом.' >&2
    return 1
  fi
  if [[ ! "$fingerprint" =~ ^[a-f0-9]{64}$ || "$(sha256sum < "$config")" != "$fingerprint  -" ]]; then
    echo 'Конфигурация изменилась после выбора сайта; запись отменена.' >&2
    return 1
  fi
  temporary="$(mktemp --suffix=.php -- "$site_path/.rish-configuration.XXXXXX")" || return 1
  backup_temporary="$(mktemp --suffix=.php -- "$site_path/.rish-configuration.XXXXXX")" || return 1
  if ! chown --reference="$config" -- "$temporary" "$backup_temporary" ||
    ! chmod 600 -- "$temporary" "$backup_temporary"; then
    echo 'Не удалось сохранить владельца и права временных файлов.' >&2
    return 1
  fi

  literal="${password//\\/\\\\}"
  literal="'${literal//\'/\\\'}'"
  # Copy all other bytes, including CRLF and a missing final newline, unchanged.
  while :; do
    ending=$'\n'
    IFS= read -r line || ending=""
    [[ -n "$line$ending" ]] || break
    if [[ "$line" =~ $password_re ]]; then
      matches=$((matches + 1))
      line="${BASH_REMATCH[1]}${literal}${BASH_REMATCH[6]}"
    fi
    if ! printf '%s%s' "$line" "$ending"; then
      echo 'Не удалось записать временную конфигурацию.' >&2
      return 1
    fi
    [[ -n "$ending" ]] || break
  done < "$config" > "$temporary"
  if ((matches != 1)); then
    echo 'В configuration.php нужна ровно одна строка с объявлением $password.' >&2
    return 1
  fi
  if ! "$php_bin" -n -l < "$temporary" >/dev/null 2>&1; then
    echo 'После замены пароля обнаружена ошибка синтаксиса PHP; запись отменена.' >&2
    return 1
  fi
  if ! cp -- "$config" "$backup_temporary" || ! chmod --reference="$config" -- "$temporary"; then
    echo 'Не удалось подготовить резервную копию или сохранить права конфигурации.' >&2
    return 1
  fi
  if [[ -e /sys/fs/selinux/enforce ]] &&
    ! chcon --reference="$config" -- "$temporary" "$backup_temporary"; then
    echo 'Не удалось сохранить контекст SELinux; запись отменена.' >&2
    return 1
  fi
  if [[ "$(sha256sum < "$config")" != "$fingerprint  -" ]]; then
    echo 'Конфигурация была изменена другим процессом; запись отменена.' >&2
    return 1
  fi
  if ! mv -fT -- "$backup_temporary" "$config.bak.php"; then
    echo 'Не удалось сохранить резервную копию; конфигурация не изменена.' >&2
    return 1
  fi
  backup_temporary=""
  if [[ "$(sha256sum < "$config")" != "$fingerprint  -" ]] || ! mv -fT -- "$temporary" "$config"; then
    echo 'Не удалось заменить конфигурацию. Резервная копия уже обновлена; configuration.php не изменён этой операцией.' >&2
    return 1
  fi
  temporary=""
)

cms_database_has_affected_database() {
  local wanted_database="$1" db_name

  for db_name in "${CMS_DATABASE_AFFECTED_DATABASES[@]}"; do
    [[ "$db_name" == "$wanted_database" ]] && return 0
  done
  return 1
}

cms_database_mapped_database() {
  local wanted_path="$1" mapping_path db_name matched_path="" matched_database="" ambiguous=0
  local mapping_file="${SITE_DATABASES_FILE:-${RISH_HOME}/site_databases}"

  [[ -e "$mapping_file" || -L "$mapping_file" ]] || return 1
  [[ -f "$mapping_file" && -r "$mapping_file" ]] || return 2
  while IFS=';' read -r mapping_path db_name || [[ -n "$mapping_path$db_name" ]]; do
    [[ -n "$mapping_path" && "$mapping_path" != \#* && -n "$db_name" ]] || continue
    mapping_path="$(realpath -e -- "${mapping_path%/}" 2>/dev/null)" || continue
    if [[ "$wanted_path" == "$mapping_path" || "$wanted_path" == "$mapping_path/"* ]]; then
      if ((${#mapping_path} > ${#matched_path})); then
        matched_path="$mapping_path"
        matched_database="$db_name"
        ambiguous=0
      elif [[ "$mapping_path" == "$matched_path" && "$db_name" != "$matched_database" ]]; then
        ambiguous=1
      fi
    fi
  done < "$mapping_file" || return 2
  ((ambiguous == 0)) || return 2
  [[ -n "$matched_path" ]] || return 1
  printf '%s' "$matched_database"
}

cms_database_add_manual_site() {
  CMS_DATABASE_MANUAL_PATHS+=("$1")
  CMS_DATABASE_MANUAL_NAMES+=("$2")
  CMS_DATABASE_MANUAL_REASONS+=("$3")
  CMS_DATABASE_MANUAL_HOSTS+=("${4:-}")
  CMS_DATABASE_MANUAL_DATABASES+=("${5:-}")
  CMS_DATABASE_WARNINGS=$((CMS_DATABASE_WARNINGS + 1))
}

cms_database_print_site() {
  local site_name="$1" site_path="$2" site_name_color='\033[1;36m'

  if [[ -n "$site_name" ]]; then
    printf '  %b%s%b\n' "$site_name_color" "$site_name" "${WHITE:-}"
    printf '    Путь: %b%s%b\n' "${GREEN:-}" "$site_path" "${WHITE:-}"
  else
    printf '  %b%s%b\n' "${GREEN:-}" "$site_path" "${WHITE:-}"
  fi
}

cms_database_print_manual_sites() {
  local i

  printf '%b%s%b:\n' "${YELLOW:-}" 'Проверить и настроить вручную' "${WHITE:-}"
  for i in "${!CMS_DATABASE_MANUAL_PATHS[@]}"; do
    cms_database_print_site "${CMS_DATABASE_MANUAL_NAMES[$i]}" "${CMS_DATABASE_MANUAL_PATHS[$i]}"
    if [[ -n "${CMS_DATABASE_MANUAL_DATABASES[$i]:-}" ]]; then
      printf '    Имя базы RISH: %b%s%b\n' "${GREEN:-}" "${CMS_DATABASE_MANUAL_DATABASES[$i]}" "${WHITE:-}"
    fi
    if [[ -n "${CMS_DATABASE_MANUAL_HOSTS[$i]:-}" ]]; then
      printf '    Хост БД: %b%s%b\n' "${GREEN:-}" "${CMS_DATABASE_MANUAL_HOSTS[$i]}" "${WHITE:-}"
    fi
    printf '    Причина: %s\n' "${CMS_DATABASE_MANUAL_REASONS[$i]}"
  done
}

cms_database_print_sites_without_database() {
  local i

  printf 'Сайты без локальной базы RISH:\n'
  for i in "${!CMS_DATABASE_NO_DATABASE_PATHS[@]}"; do
    cms_database_print_site "${CMS_DATABASE_NO_DATABASE_NAMES[$i]}" "${CMS_DATABASE_NO_DATABASE_PATHS[$i]}"
    printf '    База %b%s%b %bотсутствует%b.\n' "${GREEN:-}" "${CMS_DATABASE_NO_DATABASE_DATABASES[$i]}" \
      "${WHITE:-}" "${GREEN:-}" "${WHITE:-}"
  done
  echo 'Проверены имена баз по правилам RISH; подключения к другим или внешним базам не определялись.'
}

cms_database_find_sites() {
  local wanted_user="$1" affected_databases="${2:-}"
  local conf_file site_path site_name php_bin adapter metadata db_name db_user db_host fingerprint
  local candidate detected mapped_database mapping_status site_database site_relative database_found
  local local_database_list="" local_database_status=0
  local -A seen=()
  local -A seen_databases=()

  CMS_DATABASE_PATHS=()
  CMS_DATABASE_TYPES=()
  CMS_DATABASE_PHP_BINS=()
  CMS_DATABASE_NAMES=()
  CMS_DATABASE_USERS=()
  CMS_DATABASE_HOSTS=()
  CMS_DATABASE_HASHES=()
  CMS_DATABASE_SITE_NAMES=()
  CMS_DATABASE_MANUAL_PATHS=()
  CMS_DATABASE_MANUAL_NAMES=()
  CMS_DATABASE_MANUAL_REASONS=()
  CMS_DATABASE_MANUAL_HOSTS=()
  CMS_DATABASE_MANUAL_DATABASES=()
  CMS_DATABASE_NO_DATABASE_PATHS=()
  CMS_DATABASE_NO_DATABASE_NAMES=()
  CMS_DATABASE_NO_DATABASE_DATABASES=()
  CMS_DATABASE_AFFECTED_DATABASES=()
  CMS_DATABASE_WARNINGS=0

  while IFS= read -r db_name; do
    [[ -n "$db_name" && -z "${seen_databases[$db_name]:-}" ]] || continue
    CMS_DATABASE_AFFECTED_DATABASES+=("$db_name")
    seen_databases["$db_name"]=1
  done <<< "$affected_databases"

  for conf_file in /etc/httpd/conf.d/*.conf; do
    [[ -f "$conf_file" ]] || continue
    site_path="$(awk '$1 == "DocumentRoot" { gsub(/^"|"$/, "", $2); print $2; exit }' "$conf_file")"
    [[ -n "$site_path" ]] || continue
    site_path="$(realpath -e -- "$site_path" 2>/dev/null)" || continue
    [[ "$site_path" =~ ^/var/www/[^/]+/www/ && -d "$site_path" ]] || continue
    [[ -z "${seen[$site_path]:-}" ]] || continue
    seen["$site_path"]=1
    site_name="$(awk '$1 == "ServerName" { print $2; exit }' "$conf_file")"
    candidate=0
    [[ "$site_path/" == "/var/www/$wanted_user/www/"* ]] && candidate=1
    mapping_status=0
    mapped_database="$(cms_database_mapped_database "$site_path")" || mapping_status=$?
    if ((mapping_status == 0)) && cms_database_has_affected_database "$mapped_database"; then
      candidate=1
    fi
    detected=0

    for adapter in "${CMS_DATABASE_ADAPTERS[@]}"; do
      "cms_database_${adapter}_detect" "$site_path" || continue
      detected=1
      php_bin="$(get_site_php_bin "$site_name" 2>/dev/null)" || php_bin=""
      if [[ -z "$php_bin" ]]; then
        if ((candidate)); then
          cms_database_add_manual_site "$site_path" "$site_name" \
            'Не найден PHP для проверки конфигурации; подключение к БД не проверено.'
        fi
        break
      fi
      if ! metadata="$("cms_database_${adapter}_inspect" "$site_path" "$php_bin" 2>/dev/null)"; then
        if ((candidate)); then
          cms_database_add_manual_site "$site_path" "$site_name" \
            'Не удалось прочитать конфигурацию; подключение к БД не проверено.'
        fi
        break
      fi
      IFS=$'\t' read -r db_name db_user db_host fingerprint <<< "$metadata"
      if [[ -z "$db_name" || -z "$db_user" || -z "$db_host" || -z "$fingerprint" ]]; then
        if ((candidate)); then
          cms_database_add_manual_site "$site_path" "$site_name" \
            'Не удалось прочитать параметры конфигурации; подключение к БД не проверено.'
        fi
        break
      fi
      [[ "$db_user" == "$wanted_user" ]] || continue
      if [[ "$db_host" != "localhost" ]]; then
        cms_database_add_manual_site "$site_path" "$site_name" \
          'Использование учётной записи localhost для этого хоста БД не подтверждено.' "$db_host"
        break
      fi
      CMS_DATABASE_PATHS+=("$site_path")
      CMS_DATABASE_TYPES+=("$adapter")
      CMS_DATABASE_PHP_BINS+=("$php_bin")
      CMS_DATABASE_NAMES+=("$db_name")
      CMS_DATABASE_USERS+=("$db_user")
      CMS_DATABASE_HOSTS+=("$db_host")
      CMS_DATABASE_HASHES+=("$fingerprint")
      CMS_DATABASE_SITE_NAMES+=("$site_name")
      break
    done
    if ((detected == 0 && candidate)); then
      if ((mapping_status > 1)); then
        cms_database_add_manual_site "$site_path" "$site_name" \
          'Не удалось однозначно определить имя базы сайта по site_databases; наличие базы не проверено.'
        continue
      fi
      if ((mapping_status == 0)); then
        site_database="$mapped_database"
      else
        site_relative="${site_path#/var/www/}"
        site_relative="${site_relative#*/www/}"
        site_database="${site_relative%%/*}"
      fi
      # A failed query must never turn into an empty list of existing databases.
      if ((local_database_status == 0)); then
        if local_database_list="$(mariadb --batch --raw --skip-column-names \
          -e 'SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA;' 2>/dev/null)"; then
          local_database_status=1
        else
          local_database_status=2
        fi
      fi
      if ((local_database_status == 2)); then
        cms_database_add_manual_site "$site_path" "$site_name" \
          'Не удалось проверить наличие локальной базы в MariaDB.' '' "$site_database"
        continue
      fi
      database_found=0
      while IFS= read -r db_name; do
        if [[ "$db_name" == "$site_database" ]]; then
          database_found=1
          break
        fi
      done <<< "$local_database_list"
      if ((database_found)); then
        cms_database_add_manual_site "$site_path" "$site_name" \
          'CMS не поддерживается; используемая учётная запись MariaDB не проверена.' '' "$site_database"
      else
        CMS_DATABASE_NO_DATABASE_PATHS+=("$site_path")
        CMS_DATABASE_NO_DATABASE_NAMES+=("$site_name")
        CMS_DATABASE_NO_DATABASE_DATABASES+=("$site_database")
      fi
    fi
  done
  return 0
}

cms_database_show_sites() {
  local i adapter

  printf '\n'
  echo "Автонастройка проверяет поддерживаемые CMS в DocumentRoot сайтов Apache."
  printf 'Поддерживаемые CMS:'
  for adapter in "${CMS_DATABASE_ADAPTERS[@]}"; do
    printf ' %b%s%b' "${GREEN:-}" "$("cms_database_${adapter}_name")" "${WHITE:-}"
  done
  printf '\n\n'
  if ((${#CMS_DATABASE_PATHS[@]} == 0)); then
    echo "Подходящие конфигурации сайтов не найдены."
  else
    echo "Сайты для автоматической настройки:"
    for i in "${!CMS_DATABASE_PATHS[@]}"; do
      cms_database_print_site "${CMS_DATABASE_SITE_NAMES[$i]}" "${CMS_DATABASE_PATHS[$i]}"
      printf '    База: %b%s%b\n' "${GREEN:-}" "${CMS_DATABASE_NAMES[$i]}" "${WHITE:-}"
    done
  fi
  if ((${#CMS_DATABASE_MANUAL_PATHS[@]} > 0)); then
    printf '\n'
    cms_database_print_manual_sites
  fi
  if ((${#CMS_DATABASE_NO_DATABASE_PATHS[@]} > 0)); then
    printf '\n'
    cms_database_print_sites_without_database
  fi
  printf '\n'
  echo 'Для неподдерживаемых CMS автоматическая смена пароля в конфигурации недоступна.'
  echo 'Вложенные сайты без отдельного vhost и внешние приложения с этой учётной записью MariaDB нужно настроить вручную.'
}

cms_database_offer_updates() {
  local password="$1" adapter i choice label update_error db_name count_color
  local updated=0 skipped=0 failed=0
  local -a indices=()
  local -a updated_indices=() not_updated_indices=() not_updated_reasons=() not_updated_statuses=() missing_databases=()
  local -A successful_databases=()

  for adapter in "${CMS_DATABASE_ADAPTERS[@]}"; do
    indices=()
    for i in "${!CMS_DATABASE_TYPES[@]}"; do
      [[ "${CMS_DATABASE_TYPES[$i]}" == "$adapter" ]] && indices+=("$i")
    done
    ((${#indices[@]} > 0)) || continue
    label="$("cms_database_${adapter}_label")"
    printf '\nНастройка конфигураций %b%s%b:\n' "${GREEN:-}" "$("cms_database_${adapter}_name")" "${WHITE:-}"
    for i in "${indices[@]}"; do
      cms_database_print_site "${CMS_DATABASE_SITE_NAMES[$i]}" "${CMS_DATABASE_PATHS[$i]}"
    done
    printf '\n'
    vertical_menu "current" 2 0 5 "$label" "Пропустить"
    choice=$?
    for i in "${indices[@]}"; do
      if ((choice != 0)); then
        not_updated_indices+=("$i")
        not_updated_reasons+=('Настройка пропущена пользователем; в конфигурации остался старый пароль.')
        not_updated_statuses+=('Пропущено')
        skipped=$((skipped + 1))
      elif update_error="$(printf '%s' "$password" | "cms_database_${adapter}_update" \
        "${CMS_DATABASE_PATHS[$i]}" "${CMS_DATABASE_PHP_BINS[$i]}" "${CMS_DATABASE_HASHES[$i]}" \
        "${CMS_DATABASE_USERS[$i]}" "${CMS_DATABASE_NAMES[$i]}" "${CMS_DATABASE_HOSTS[$i]}" 2>&1)"; then
        updated_indices+=("$i")
        successful_databases["${CMS_DATABASE_NAMES[$i]}"]=1
        updated=$((updated + 1))
      else
        not_updated_indices+=("$i")
        not_updated_reasons+=("${update_error:-Не удалось записать конфигурацию.}")
        not_updated_statuses+=('Ошибка')
        failed=$((failed + 1))
      fi
    done
  done

  printf '\nОбновлённые сайты:\n'
  if ((${#updated_indices[@]} == 0)); then
    echo '  Нет.'
  else
    for i in "${updated_indices[@]}"; do
      cms_database_print_site "${CMS_DATABASE_SITE_NAMES[$i]}" "${CMS_DATABASE_PATHS[$i]}"
    done
  fi

  printf '\nПропуски и ошибки автонастройки:\n'
  if ((${#not_updated_indices[@]} == 0)); then
    echo '  Нет.'
  else
    for i in "${!not_updated_indices[@]}"; do
      cms_database_print_site "${CMS_DATABASE_SITE_NAMES[${not_updated_indices[$i]}]}" \
        "${CMS_DATABASE_PATHS[${not_updated_indices[$i]}]}"
      if [[ "${not_updated_statuses[$i]}" == 'Ошибка' ]]; then
        printf '    Статус: %b%s%b\n' "${RED:-}" "${not_updated_statuses[$i]}" "${WHITE:-}"
      else
        printf '    Статус: %b%s%b\n' "${YELLOW:-}" "${not_updated_statuses[$i]}" "${WHITE:-}"
      fi
      printf '    Причина: %s\n' "${not_updated_reasons[$i]}"
    done
  fi

  if ((${#CMS_DATABASE_MANUAL_PATHS[@]} > 0)); then
    printf '\n'
    cms_database_print_manual_sites
  fi
  if ((${#CMS_DATABASE_NO_DATABASE_PATHS[@]} > 0)); then
    printf '\n'
    cms_database_print_sites_without_database
  fi

  printf '\nИтог настройки сайтов:\n'
  printf '  Обновлено: %b%s%b\n' "${GREEN:-}" "$updated" "${WHITE:-}"
  count_color="${GREEN:-}"
  ((skipped > 0)) && count_color="${YELLOW:-}"
  printf '  Пропущено: %b%s%b\n' "$count_color" "$skipped" "${WHITE:-}"
  if ((failed > 0)); then
    printf '  Ошибок: %b%s%b\n' "${RED:-}" "$failed" "${WHITE:-}"
  else
    printf '  Ошибок: %b%s%b\n' "${GREEN:-}" "$failed" "${WHITE:-}"
  fi
  count_color="${GREEN:-}"
  ((${#CMS_DATABASE_MANUAL_PATHS[@]} > 0)) && count_color="${YELLOW:-}"
  printf '  Проверить вручную: %b%s%b\n' "$count_color" "${#CMS_DATABASE_MANUAL_PATHS[@]}" "${WHITE:-}"
  if ((${#CMS_DATABASE_NO_DATABASE_PATHS[@]} > 0)); then
    printf '  Без локальной базы RISH: %b%s%b\n' "${GREEN:-}" "${#CMS_DATABASE_NO_DATABASE_PATHS[@]}" "${WHITE:-}"
  fi

  for db_name in "${CMS_DATABASE_AFFECTED_DATABASES[@]}"; do
    [[ -n "${successful_databases[$db_name]:-}" ]] || missing_databases+=("$db_name")
  done
  printf '\nБазы без успешно обновлённой конфигурации:\n'
  if ((${#missing_databases[@]} == 0)); then
    echo '  Нет.'
  else
    for db_name in "${missing_databases[@]}"; do
      printf '  %b%s%b\n' "${GREEN:-}" "$db_name" "${WHITE:-}"
    done
  fi

  if ((skipped + failed + ${#CMS_DATABASE_MANUAL_PATHS[@]} + ${#missing_databases[@]} > 0)); then
    printf '\n%b%s%b.\n' "${YELLOW:-}" 'Требуется ручная проверка' "${WHITE:-}"
    if ((skipped + failed > 0)); then
      echo 'В конфигурациях сайтов с пропуском или ошибкой измените пароль подключения к базе данных самостоятельно.'
    fi
    if ((${#CMS_DATABASE_MANUAL_PATHS[@]} + ${#missing_databases[@]} > 0)); then
      echo 'Для перечисленных сайтов и баз проверьте используемую учётную запись MariaDB.'
      echo 'Если сайт использует эту учётную запись MariaDB, обновите пароль в его коде или конфигурации самостоятельно.'
    fi
    echo 'Сайты со старым паролем могут потерять доступ к базе.'
    return 1
  fi
  return 0
}
