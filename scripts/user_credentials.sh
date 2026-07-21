#!/usr/bin/env bash

RISH_CREDENTIALS_DIR="${RISH_HOME:-/root/rish}/credentials"
RISH_CREDENTIALS_MIGRATION_ERROR=""

rish_credentials_file() {
  local user="$1"

  [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || return 1
  printf '%s/%s\n' "$RISH_CREDENTIALS_DIR" "$user"
}

ensure_rish_credentials_dir() {
  if [[ -e "$RISH_CREDENTIALS_DIR" || -L "$RISH_CREDENTIALS_DIR" ]]; then
    if [[ ! -d "$RISH_CREDENTIALS_DIR" || -L "$RISH_CREDENTIALS_DIR" ]]; then
      echo "Отказ: ${RISH_CREDENTIALS_DIR} не является обычным каталогом." >&2
      return 1
    fi
  elif ! install -d -m 700 -o root -g root "$RISH_CREDENTIALS_DIR"; then
    return 1
  fi

  chown root:root "$RISH_CREDENTIALS_DIR" && chmod 700 "$RISH_CREDENTIALS_DIR"
}

rish_credentials_file_is_secure() {
  local file="$1"

  [[ -d "$RISH_CREDENTIALS_DIR" && ! -L "$RISH_CREDENTIALS_DIR" ]] || return 1
  [[ -f "$file" && ! -L "$file" ]] || return 1
  [[ "$(stat -c '%U:%G %a' "$RISH_CREDENTIALS_DIR" 2>/dev/null)" == "root:root 700" ]] || return 1
  [[ "$(stat -c '%U:%G %a' "$file" 2>/dev/null)" == "root:root 600" ]]
}

rish_ini_value() {
  local file="$1"
  local wanted_section="$2"
  local wanted_key="$3"

  rish_credentials_file_is_secure "$file" || return 1

  awk -v wanted_section="$wanted_section" -v wanted_key="$wanted_key" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
      section = $0
      sub(/^[[:space:]]*\[/, "", section)
      sub(/\][[:space:]]*$/, "", section)
      section = trim(section)
      next
    }

    section == wanted_section && index($0, "=") > 0 {
      key = substr($0, 1, index($0, "=") - 1)
      key = trim(key)
      if (key == wanted_key) {
        value = substr($0, index($0, "=") + 1)
        print trim(value)
        found = 1
        exit
      }
    }

    END {
      if (!found) {
        exit 1
      }
    }
  ' "$file"
}

read_user_credential() {
  local user="$1"
  local section="$2"
  local key="$3"
  local credentials_file

  credentials_file="$(rish_credentials_file "$user")" || return 1
  rish_ini_value "$credentials_file" "$section" "$key"
}

validate_user_credentials() {
  local user="$1"
  local credentials_file
  local sftp_login
  local sftp_password
  local mariadb_login
  local mariadb_password
  local site_login
  local site_password

  credentials_file="$(rish_credentials_file "$user")" || return 1
  rish_credentials_file_is_secure "$credentials_file" || return 1

  sftp_login="$(rish_ini_value "$credentials_file" "SFTP" "Login")" || return 1
  sftp_password="$(rish_ini_value "$credentials_file" "SFTP" "Password")" || return 1
  mariadb_login="$(rish_ini_value "$credentials_file" "MariaDB" "Login")" || return 1
  mariadb_password="$(rish_ini_value "$credentials_file" "MariaDB" "Password")" || return 1
  site_login="$(rish_ini_value "$credentials_file" "Default site administrator" "Login")" || return 1
  site_password="$(rish_ini_value "$credentials_file" "Default site administrator" "Password")" || return 1

  [[ "$sftp_login" == "$user" && -n "$sftp_password" ]] || return 1
  [[ "$mariadb_login" == "$user" && -n "$mariadb_password" ]] || return 1
  [[ -n "$site_login" && -n "$site_password" ]]
}

user_credentials_match() {
  local user="$1"
  local sftp_password="$2"
  local mariadb_password="$3"
  local site_login="$4"
  local site_password="$5"

  validate_user_credentials "$user" || return 1
  [[ "$(read_user_credential "$user" "SFTP" "Password")" == "$sftp_password" ]] || return 1
  [[ "$(read_user_credential "$user" "MariaDB" "Password")" == "$mariadb_password" ]] || return 1
  [[ "$(read_user_credential "$user" "Default site administrator" "Login")" == "$site_login" ]] || return 1
  [[ "$(read_user_credential "$user" "Default site administrator" "Password")" == "$site_password" ]]
}

write_user_credentials() {
  local user="$1"
  local sftp_password="$2"
  local mariadb_password="$3"
  local site_login="$4"
  local site_password="$5"
  local credentials_file
  local temp_file

  credentials_file="$(rish_credentials_file "$user")" || return 1
  [[ "$sftp_password" != *$'\n'* && "$sftp_password" != *$'\r'* ]] || return 1
  [[ "$mariadb_password" != *$'\n'* && "$mariadb_password" != *$'\r'* ]] || return 1
  [[ "$site_login" != *$'\n'* && "$site_login" != *$'\r'* ]] || return 1
  [[ "$site_password" != *$'\n'* && "$site_password" != *$'\r'* ]] || return 1
  [[ -n "$sftp_password" && -n "$mariadb_password" && -n "$site_login" && -n "$site_password" ]] || return 1

  ensure_rish_credentials_dir || return 1
  if [[ -e "$credentials_file" || -L "$credentials_file" ]]; then
    echo "Отказ: файл учетных данных ${credentials_file} уже существует." >&2
    return 1
  fi

  temp_file="$(mktemp "${RISH_CREDENTIALS_DIR}/.${user}.rish-tmp.XXXXXX")" || return 1
  if ! {
    printf '# Учетные данные пользователя RISH.\n'
    printf '# Файл используется скриптами RISH при автоматической установке\n'
    printf '# и настройке сайтов и баз данных.\n'
    printf '#\n'
    printf '# По умолчанию авторизация SFTP по паролю запрещена настройками RISH.\n'
    printf '# Сохранённый пароль можно использовать, если администратор вручную\n'
    printf '# разрешит парольную авторизацию для пользователей SFTP.\n'
    printf '# Рекомендуемый способ подключения — SSH-ключ.\n'
    printf '# Публичные ключи пользователя хранятся в:\n'
    printf '# /etc/ssh/authorized_keys/%s\n' "$user"
    printf '#\n'
    printf '# Не переименовывайте секции и параметры.\n'
    printf '# Права файла должны оставаться root:root 600.\n'
    printf '\n[SFTP]\n'
    printf 'Login = %s\n' "$user"
    printf 'Password = %s\n' "$sftp_password"
    printf '\n[MariaDB]\n'
    printf 'Login = %s\n' "$user"
    printf 'Password = %s\n' "$mariadb_password"
    printf '\n[Default site administrator]\n'
    printf 'Login = %s\n' "$site_login"
    printf 'Password = %s\n' "$site_password"
  } >"$temp_file"; then
    rm -f -- "$temp_file"
    return 1
  fi

  if ! chown root:root "$temp_file" || ! chmod 600 "$temp_file" || ! mv -- "$temp_file" "$credentials_file"; then
    rm -f -- "$temp_file"
    return 1
  fi

  if ! validate_user_credentials "$user"; then
    rm -f -- "$credentials_file"
    return 1
  fi
}

remove_user_credentials() {
  local user="$1"
  local credentials_file

  credentials_file="$(rish_credentials_file "$user")" || return 1
  if [[ -e "$credentials_file" || -L "$credentials_file" ]]; then
    [[ -f "$credentials_file" && ! -L "$credentials_file" ]] || return 1
    rm -f -- "$credentials_file"
  fi
}

migrate_legacy_user_credentials() {
  local user="$1"
  local legacy_file="/home/${user}/.pass.txt"
  local credentials_file
  local sftp_password
  local mariadb_password
  local site_login
  local site_password

  RISH_CREDENTIALS_MIGRATION_ERROR=""
  credentials_file="$(rish_credentials_file "$user")" || {
    RISH_CREDENTIALS_MIGRATION_ERROR="недопустимое имя пользователя"
    return 1
  }
  if [[ ! -f "$legacy_file" || -L "$legacy_file" ]]; then
    RISH_CREDENTIALS_MIGRATION_ERROR="исходный файл имеет недопустимый тип"
    return 1
  fi

  sftp_password="$(awk -v user="$user" '$1 == user ":" { print $2; exit }' "$legacy_file")"
  mariadb_password="$(awk '$1 == "Database:" { print $2; exit }' "$legacy_file")"
  site_login="$(awk '$1 == "defaultsiteaccount" { print $2; exit }' "$legacy_file")"
  site_password="$(awk '$1 == "defaultsiteaccount" { print $3; exit }' "$legacy_file")"
  if [[ -z "$sftp_password" || -z "$mariadb_password" || -z "$site_login" || -z "$site_password" ]]; then
    RISH_CREDENTIALS_MIGRATION_ERROR="исходный файл поврежден или имеет неизвестный формат"
    return 1
  fi

  if [[ -e "$credentials_file" || -L "$credentials_file" ]]; then
    if [[ ! -f "$credentials_file" || -L "$credentials_file" ]]; then
      RISH_CREDENTIALS_MIGRATION_ERROR="целевой путь имеет недопустимый тип: ${credentials_file}"
      return 1
    fi
    if ! validate_user_credentials "$user"; then
      RISH_CREDENTIALS_MIGRATION_ERROR="целевой файл поврежден или имеет небезопасные права: ${credentials_file}"
      return 1
    fi
    if ! user_credentials_match "$user" "$sftp_password" "$mariadb_password" "$site_login" "$site_password"; then
      RISH_CREDENTIALS_MIGRATION_ERROR="данные целевого файла не совпадают с исходным: ${credentials_file}"
      return 1
    fi
  else
    if ! write_user_credentials "$user" "$sftp_password" "$mariadb_password" "$site_login" "$site_password"; then
      RISH_CREDENTIALS_MIGRATION_ERROR="не удалось создать целевой файл: ${credentials_file}"
      return 1
    fi
    if ! user_credentials_match "$user" "$sftp_password" "$mariadb_password" "$site_login" "$site_password"; then
      RISH_CREDENTIALS_MIGRATION_ERROR="созданный целевой файл поврежден: ${credentials_file}"
      return 1
    fi
  fi

  if ! rm -f -- "$legacy_file"; then
    RISH_CREDENTIALS_MIGRATION_ERROR="не удалось удалить исходный файл: ${legacy_file}"
    return 1
  fi
}

legacy_user_credentials_exist() {
  compgen -G '/home/*/.pass.txt' >/dev/null
}

migrate_all_legacy_user_credentials() {
  local legacy_file
  local user
  local credentials_file
  local failed=0
  local migrated=0
  local error_color
  local -a legacy_files=()

  ensure_rish_credentials_dir || return 1
  shopt -s nullglob
  legacy_files=(/home/*/.pass.txt)
  shopt -u nullglob

  if ((${#legacy_files[@]} == 0)); then
    echo "Файлы учетных данных .pass.txt не найдены."
    echo "Перенос не требуется."
    return 0
  fi

  for legacy_file in "${legacy_files[@]}"; do
    user="${legacy_file#/home/}"
    user="${user%%/*}"
    credentials_file="${RISH_CREDENTIALS_DIR}/${user}"
    if migrate_legacy_user_credentials "$user"; then
      printf '  %b%s%b -> %b%s%b %b(ok)%b\n' \
        "${YELLOW:-}" "$legacy_file" "${WHITE:-}" \
        "${YELLOW:-}" "$credentials_file" "${WHITE:-}" \
        "${GREEN:-}" "${WHITE:-}"
      migrated=$((migrated + 1))
    else
      printf '  %b%s%b -> %b%s%b\n' \
        "${YELLOW:-}" "$legacy_file" "${WHITE:-}" \
        "${YELLOW:-}" "$credentials_file" "${WHITE:-}"
      printf '  Результат: %bошибка%b' "${RED:-}" "${WHITE:-}"
      if [[ -n "$RISH_CREDENTIALS_MIGRATION_ERROR" ]]; then
        printf ' — %s' "$RISH_CREDENTIALS_MIGRATION_ERROR"
      fi
      echo
      echo "  Исходный файл сохранен."
      failed=$((failed + 1))
    fi
  done
  echo

  if ((failed == 0)); then
    error_color="${GREEN:-}"
  else
    error_color="${YELLOW:-}"
  fi
  printf 'Итог: перенесено — %b%d%b, ошибок — %b%d%b.\n' \
    "${GREEN:-}" "$migrated" "${WHITE:-}" \
    "$error_color" "$failed" "${WHITE:-}"

  ((failed == 0))
}
