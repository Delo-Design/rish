#!/usr/bin/env bash

PHP_REMOVE_GREEN=''
PHP_REMOVE_RED=''
PHP_REMOVE_YELLOW=''
PHP_REMOVE_RESET=''

# Safe to source. Standalone execution resets fixture paths and command overrides.
php_remove_path() {
  if [[ -n "${PHP_REMOVE_ROOT:-}" && "$1" != "${PHP_REMOVE_ROOT}"/* ]]; then
    printf '%s%s\n' "${PHP_REMOVE_ROOT}" "$1"
  else
    printf '%s\n' "$1"
  fi
}

php_remove_require_root() {
  if ((EUID != 0)); then
    printf 'Удаление PHP доступно только %broot%b.\n' "$PHP_REMOVE_GREEN" "$PHP_REMOVE_RESET" >&2
    return 1
  fi
}

php_remove_valid_version() {
  [[ "$1" =~ ^php[0-9]{2}$ ]]
}

php_remove_all_packages() {
  local output
  output="$("${PHP_REMOVE_RPM:-rpm}" -qa --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n')" || return 1
  [[ -n "$output" ]] || return 1
  LC_ALL=C sort <<<"$output"
}

php_remove_packages() {
  local version="$1" output package
  php_remove_valid_version "$version" || return 1
  output="$(php_remove_all_packages)" || return 1
  while IFS= read -r package; do
    [[ "$package" == "$version"-* ]] && printf '%s\n' "$package"
  done <<<"$output"
  return 0
}

php_remove_list_versions() {
  local output package version
  local -A found=()
  output="$(php_remove_all_packages)" || return 1
  while IFS= read -r package; do
    if [[ "$package" =~ ^(php[0-9]{2})- ]]; then
      version="${BASH_REMATCH[1]}"
      found["$version"]=1
    fi
  done <<<"$output"
  if ((${#found[@]})); then
    printf '%s\n' "${!found[@]}" | LC_ALL=C sort -r
  fi
}

php_remove_trim() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s\n' "$text"
}

php_remove_is_packaged_dropin() {
  local filename="$1" version="$2" owner line stage=0
  case "$filename" in
    "$(php_remove_path "/etc/systemd/system/httpd.service.d/$version-php-fpm.conf")"|\
    "$(php_remove_path "/etc/systemd/system/nginx.service.d/$version-php-fpm.conf")") ;;
    *) return 1 ;;
  esac
  [[ -f "$filename" && -r "$filename" && ! -L "$filename" ]] || return 1
  owner="$("${PHP_REMOVE_RPM:-rpm}" -qf --qf '%{NAME}\n' -- "$filename" 2>/dev/null)" || return 1
  [[ "$owner" =~ ^${version}($|-) && "$owner" != *$'\n'* ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(php_remove_trim "$line")"
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue
    if ((stage == 0)) && [[ "$line" == '[Unit]' ]]; then
      stage=1
    elif ((stage == 1)) && [[ "$line" =~ ^Wants[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      [[ "$(php_remove_trim "${BASH_REMATCH[1]}")" == "$version-php-fpm.service" ]] || return 1
      stage=2
    else
      return 1
    fi
  done <"$filename"
  ((stage == 2))
}

php_remove_pool_file() {
  local filename="$1" line value port pattern included
  local number=0
  local -a matches=()
  [[ -n "${PHP_REMOVE_POOL_VISITED[$filename]:-}" ]] && return 0
  PHP_REMOVE_POOL_VISITED["$filename"]=1
  if [[ ! -f "$filename" || ! -r "$filename" ]]; then
    PHP_REMOVE_BLOCKERS+=("Не удалось прочитать пул PHP: ${PHP_REMOVE_YELLOW}${filename}${PHP_REMOVE_RESET}")
    return
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((number+=1))
    line="$(php_remove_trim "$line")"
    [[ -z "$line" || "$line" == \;* || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^listen[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      value="${BASH_REMATCH[1]%%;*}"
      value="$(php_remove_trim "$value")"
      value="${value#\"}"; value="${value%\"}"
      if [[ "$value" == /* ]]; then
        PHP_REMOVE_SOCKETS+=("$value")
        included="$(readlink -m -- "$(php_remove_path "$value")" 2>/dev/null)" || {
          PHP_REMOVE_BLOCKERS+=("Не удалось проверить socket ${PHP_REMOVE_YELLOW}${filename}:${number}${PHP_REMOVE_RESET}")
          continue
        }
        PHP_REMOVE_REAL_SOCKETS+=("$included")
      else
        port="${value##*:}"
        if [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port > 0 && 10#$port <= 65535)); then
          PHP_REMOVE_TCP_PORTS+=("$((10#$port))")
        else
          PHP_REMOVE_BLOCKERS+=("Не удалось определить listen: ${PHP_REMOVE_YELLOW}${filename}:${number}${PHP_REMOVE_RESET}")
        fi
      fi
    elif [[ "$line" =~ ^include[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      pattern="$(php_remove_trim "${BASH_REMATCH[1]%%;*}")"
      if [[ "$pattern" != /* || "$pattern" == *'$'* ]]; then
        PHP_REMOVE_BLOCKERS+=("Нужна ручная проверка include: ${PHP_REMOVE_YELLOW}${filename}:${number}${PHP_REMOVE_RESET}")
        continue
      fi
      pattern="$(php_remove_path "$pattern")"
      matches=()
      mapfile -t matches < <(compgen -G "$pattern")
      if ((${#matches[@]} == 0)); then
        PHP_REMOVE_BLOCKERS+=("Не найден include PHP-FPM: ${PHP_REMOVE_YELLOW}${filename}:${number}${PHP_REMOVE_RESET}")
      else
        for included in "${matches[@]}"; do
          php_remove_pool_file "$included"
        done
      fi
    fi
  done <"$filename"
}

php_remove_apache_site() {
  local filename="$1" name suffix
  [[ "${filename%/*}" == "$(php_remove_path /etc/httpd/conf.d)" && "$filename" == *.conf ]] || return 1
  name="${filename##*/}"
  name="${name%.conf}"
  for suffix in -selectel-ssl -le-ssl -ssl; do
    if [[ "$name" == *"$suffix" ]]; then
      name="${name%"$suffix"}"
      [[ -f "$(php_remove_path "/etc/httpd/conf.d/$name.conf")" ]] || return 1
      break
    fi
  done
  [[ "$name" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || return 1
  printf '%s\n' "$name"
}

php_remove_check_file() {
  local filename="$1" mode="${2:-generic}" line original_line directive rest endpoint canonical socket port site='' cron_user=''
  local number=0 matched=0
  local token="(^|[^[:alnum:]_])${PHP_REMOVE_VERSION}([^[:alnum:]_]|$)"
  local unix_pattern="unix:([^|[:space:]\"']+)"
  local tcp_pattern='fcgi://[^/[:space:]"|]+:([0-9]+)'
  if [[ ! -f "$filename" || ! -r "$filename" ]]; then
    PHP_REMOVE_BLOCKERS+=("Не удалось прочитать ${PHP_REMOVE_YELLOW}${filename}${PHP_REMOVE_RESET}")
    return
  fi
  if [[ "$mode" == apache ]]; then
    site="$(php_remove_apache_site "$filename")" || site=''
  elif [[ "$mode" == cron && ( "${filename%/*}" == "$(php_remove_path /var/spool/cron)" ||
    "${filename%/*}" == "$(php_remove_path /var/spool/cron/crontabs)" ) ]]; then
    cron_user="${filename##*/}"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((number+=1))
    original_line="$line"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue
    matched=0
    if [[ "$mode" == apache ]]; then
      if [[ "$line" == *"/opt/remi/${PHP_REMOVE_VERSION}/"* || "$line" == *"/var/opt/remi/${PHP_REMOVE_VERSION}/"* ]]; then
        matched=1
      fi
      read -r directive rest <<<"$line"
      case "${directive,,}" in
        sethandler|addhandler|action|proxypass|proxypassmatch|loadmodule|define)
          [[ "$line" =~ $token ]] && matched=1
          if [[ "$line" =~ $unix_pattern ]]; then
            endpoint="${BASH_REMATCH[1]}"
            if [[ "$endpoint" != /* ]]; then
              PHP_REMOVE_BLOCKERS+=("Нужна ручная проверка относительного socket ${PHP_REMOVE_YELLOW}${filename}:${number}${PHP_REMOVE_RESET}")
            fi
            canonical="$(readlink -m -- "$(php_remove_path "$endpoint")" 2>/dev/null)" || PHP_REMOVE_BLOCKERS+=("Не удалось проверить socket ${PHP_REMOVE_YELLOW}${filename}:${number}${PHP_REMOVE_RESET}")
            for socket in "${PHP_REMOVE_REAL_SOCKETS[@]}"; do
              [[ "$canonical" == "$socket" ]] && matched=1
            done
          fi
          if [[ "$line" =~ $tcp_pattern ]]; then
            endpoint="${BASH_REMATCH[1]}"
            for port in "${PHP_REMOVE_TCP_PORTS[@]}"; do
              ((10#$endpoint == port)) && matched=1
            done
          fi
          ;;
      esac
      for socket in "${PHP_REMOVE_SOCKETS[@]}"; do
        [[ "$line" == *"$socket"* ]] && matched=1
      done
    else
      [[ "$line" =~ $token ]] && matched=1
    fi
    if ((matched)); then
      case "$mode" in
        apache)
          if [[ -n "$site" ]]; then
            PHP_REMOVE_SITES["$site"]=1
          else
            PHP_REMOVE_APACHE_CONFIGS+=("${filename}:${number}")
          fi
          ;;
        cron)
          PHP_REMOVE_CRON_TASKS+=("${filename}:${number}")
          PHP_REMOVE_CRON_USERS+=("$cron_user")
          PHP_REMOVE_CRON_LINES+=("$original_line")
          ;;
        *) PHP_REMOVE_BLOCKERS+=("${PHP_REMOVE_YELLOW}${filename}:${number}${PHP_REMOVE_RESET}: $line") ;;
      esac
    fi
  done <"$filename"
}

php_remove_audit() {
  local version="$1" temporary output filename directory home entry target owner canonical
  local line source number value state _inode socket port hexport pid exe cgroup _remainder endpoint cron_index
  local own_unit="$version-php-fpm.service" own_pattern=":/system[.]slice/${version}-php-fpm[.]service(/|$)"
  local include_pattern='^[[:space:]]*\((\*|[0-9]+)\)[[:space:]]+(/.*)$'
  local -a includes=() homes=() bin_dirs=() roots=() stat_fields=()
  local -A PHP_REMOVE_POOL_VISITED=() checked_bin_dirs=()
  local -A PHP_REMOVE_SITES=()
  local -a PHP_REMOVE_APACHE_CONFIGS=() PHP_REMOVE_CRON_TASKS=()
  local -a PHP_REMOVE_CRON_USERS=() PHP_REMOVE_CRON_LINES=()
  local -a PHP_REMOVE_BLOCKERS=() PHP_REMOVE_SOCKETS=() PHP_REMOVE_REAL_SOCKETS=() PHP_REMOVE_TCP_PORTS=()
  local PHP_REMOVE_VERSION="$version"
  php_remove_valid_version "$version" || return 1
  temporary="$(mktemp -d /tmp/rish-php-audit.XXXXXX)" || return 1

  directory="$(php_remove_path "/etc/opt/remi/$version")"
  if [[ -e "$directory/php-fpm.conf" || -L "$directory/php-fpm.conf" ]]; then
    php_remove_pool_file "$directory/php-fpm.conf"
  fi
  for filename in "$directory/php-fpm.d/"*.conf; do
    [[ -e "$filename" || -L "$filename" ]] || continue
    php_remove_pool_file "$filename"
  done

  if output="$("${PHP_REMOVE_HTTPD:-httpd}" -t -D DUMP_INCLUDES 2>&1)"; then
    while IFS= read -r line; do
      if [[ "$line" =~ $include_pattern ]]; then
        includes+=("$(php_remove_path "${BASH_REMATCH[2]}")")
      fi
    done <<<"$output"
    ((${#includes[@]})) || PHP_REMOVE_BLOCKERS+=("Apache не вернул список включённых конфигураций.")
    for filename in "${includes[@]}"; do
      php_remove_check_file "$filename" apache
    done
  else
    PHP_REMOVE_BLOCKERS+=("Не удалось проверить конфигурацию Apache: $output")
  fi
  if output="$("${PHP_REMOVE_GETENT:-getent}" passwd)"; then
    while IFS=: read -r entry owner pid port value home source; do
      [[ "$home" == /* ]] && homes+=("$home")
    done <<<"$output"
  else
    PHP_REMOVE_BLOCKERS+=("Не удалось получить список пользователей.")
  fi
  bin_dirs=(/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /root/bin /root/.local/bin)
  for home in "${homes[@]}"; do
    bin_dirs+=("${home%/}/bin" "${home%/}/.local/bin")
  done
  for source in "${bin_dirs[@]}"; do
    directory="$(readlink -m -- "$(php_remove_path "$source")" 2>/dev/null)" || {
      PHP_REMOVE_BLOCKERS+=("Не удалось проверить каталог CLI: ${PHP_REMOVE_YELLOW}${source}${PHP_REMOVE_RESET}")
      continue
    }
    [[ -d "$directory" ]] || continue
    [[ -n "${checked_bin_dirs[$directory]:-}" ]] && continue
    checked_bin_dirs["$directory"]=1
    if ! find -H "$directory" -mindepth 1 -maxdepth 1 -type l -print0 >"$temporary/files" 2>"$temporary/errors"; then
      PHP_REMOVE_BLOCKERS+=("Не удалось проверить CLI-ссылки в ${PHP_REMOVE_YELLOW}${directory}${PHP_REMOVE_RESET}")
      continue
    fi
    while IFS= read -r -d '' entry; do
      target="$(readlink -m -- "$entry" 2>/dev/null)" || {
        PHP_REMOVE_BLOCKERS+=("Не удалось проверить CLI-ссылку ${PHP_REMOVE_YELLOW}${entry}${PHP_REMOVE_RESET}")
        continue
      }
      if [[ "$target" == "$(php_remove_path "/opt/remi/$version")/"* ]]; then
        if [[ ( "$entry" == "$(php_remove_path /bin)/"* || "$entry" == "$(php_remove_path /usr/bin)/"* ) &&
          "${entry##*/}" =~ ^${version}($|-) ]]; then
          if owner="$("${PHP_REMOVE_RPM:-rpm}" -qf --qf '%{NAME}\n' -- "$entry" 2>/dev/null)" &&
            [[ "$owner" =~ ^${version}($|-) && "$owner" != *$'\n'* ]]; then
            continue
          fi
        fi
        PHP_REMOVE_BLOCKERS+=("CLI-ссылка ${PHP_REMOVE_YELLOW}${entry}${PHP_REMOVE_RESET} ведёт в ${PHP_REMOVE_YELLOW}${target}${PHP_REMOVE_RESET}")
      fi
    done <"$temporary/files"
  done

  for source in /etc/crontab /etc/anacrontab; do
    filename="$(php_remove_path "$source")"
    [[ -e "$filename" || -L "$filename" ]] && php_remove_check_file "$filename" cron
  done
  for source in /var/spool/cron /var/spool/cron/crontabs /etc/cron.d; do
    directory="$(php_remove_path "$source")"
    [[ -d "$directory" ]] || continue
    if ! find -H "$directory" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 >"$temporary/files" 2>"$temporary/errors"; then
      PHP_REMOVE_BLOCKERS+=("Не удалось проверить CRON в ${PHP_REMOVE_YELLOW}${directory}${PHP_REMOVE_RESET}")
      continue
    fi
    while IFS= read -r -d '' filename; do
      entry="${filename##*/}"
      case "$entry" in .*|\#*|*~|*.rpmnew|*.rpmorig|*.rpmsave) continue ;; esac
      php_remove_check_file "$filename" cron
    done <"$temporary/files"
  done
  for source in /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
    directory="$(php_remove_path "$source")"
    [[ -d "$directory" ]] || continue
    if ! find -H "$directory" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 >"$temporary/files" 2>"$temporary/errors"; then
      PHP_REMOVE_BLOCKERS+=("Не удалось проверить периодические задания ${PHP_REMOVE_YELLOW}${directory}${PHP_REMOVE_RESET}")
      continue
    fi
    while IFS= read -r -d '' filename; do
      entry="${filename##*/}"
      case "$entry" in .*|*~|*.cfsaved|*.rpmsave|*.rpmorig|*.rpmnew|*.swp|*,v|jobs.allow|jobs.deny) continue ;; esac
      [[ -x "$filename" ]] && php_remove_check_file "$filename" cron
    done <"$temporary/files"
  done

  roots=(/etc/systemd/system /run/systemd/system /usr/lib/systemd/system /etc/systemd/user /usr/lib/systemd/user)
  for home in "${homes[@]}"; do
    roots+=("$home/.config/systemd/user" "$home/.local/share/systemd/user")
  done
  directory="$(php_remove_path /run/user)"
  for entry in "$directory/"*; do
    [[ -d "$entry" && "${entry##*/}" =~ ^[0-9]+$ ]] || continue
    roots+=("/run/user/${entry##*/}/systemd/user")
  done
  for source in "${roots[@]}"; do
    directory="$(php_remove_path "$source")"
    [[ -d "$directory" ]] || continue
    if ! find -L "$directory" \( -type f -o -type l \) -print0 >"$temporary/files" 2>"$temporary/errors"; then
      PHP_REMOVE_BLOCKERS+=("Неполная проверка systemd: ${PHP_REMOVE_YELLOW}${directory}${PHP_REMOVE_RESET}")
      continue
    fi
    while IFS= read -r -d '' filename; do
      if [[ "$source" == */system && ( "${filename##*/}" == "$own_unit" || "$filename" == *"/$own_unit.d/"* ) ]]; then
        continue
      fi
      if php_remove_is_packaged_dropin "$filename" "$version"; then
        continue
      fi
      if [[ -L "$filename" ]]; then
        target="$(readlink -m -- "$filename" 2>/dev/null)" || {
          PHP_REMOVE_BLOCKERS+=("Не удалось проверить unit ${PHP_REMOVE_YELLOW}${filename}${PHP_REMOVE_RESET}")
          continue
        }
        [[ "$target" == /dev/null || "$target" == "$(php_remove_path /dev/null)" ]] && continue
      fi
      case "$filename" in
        *.service|*.socket|*.timer|*.path|*.target|*.conf|*.mount|*.automount|*.slice|*.scope)
          php_remove_check_file "$filename"
          ;;
      esac
    done <"$temporary/files"
  done

  filename="$(php_remove_path /proc/net/unix)"
  if [[ ! -r "$filename" ]]; then
    PHP_REMOVE_BLOCKERS+=("Не удалось проверить ${PHP_REMOVE_YELLOW}/proc/net/unix${PHP_REMOVE_RESET}.")
  else
    while read -r entry owner pid value port state _inode socket; do
      [[ "$state" == 03 && -n "$socket" ]] || continue
      canonical="$(readlink -m -- "$(php_remove_path "$socket")" 2>/dev/null)" || {
        PHP_REMOVE_BLOCKERS+=("Не удалось проверить активный Unix socket ${PHP_REMOVE_YELLOW}${socket}${PHP_REMOVE_RESET}")
        continue
      }
      for endpoint in "${PHP_REMOVE_REAL_SOCKETS[@]}"; do
        [[ "$canonical" == "$endpoint" ]] && PHP_REMOVE_BLOCKERS+=("Активное Unix-соединение PHP: ${PHP_REMOVE_YELLOW}${socket}${PHP_REMOVE_RESET}")
      done
      [[ "$socket" == *"/var/opt/remi/$version/"* ]] && PHP_REMOVE_BLOCKERS+=("Активное Unix-соединение PHP: ${PHP_REMOVE_YELLOW}${socket}${PHP_REMOVE_RESET}")
    done <"$filename"
  fi
  if ((${#PHP_REMOVE_TCP_PORTS[@]})); then
    filename="$(php_remove_path /proc/net/tcp)"
    [[ -r "$filename" ]] || PHP_REMOVE_BLOCKERS+=("Не удалось проверить ${PHP_REMOVE_YELLOW}/proc/net/tcp${PHP_REMOVE_RESET}.")
    for source in /proc/net/tcp /proc/net/tcp6; do
      filename="$(php_remove_path "$source")"
      [[ -e "$filename" ]] || continue
      [[ -r "$filename" ]] || { PHP_REMOVE_BLOCKERS+=("Не удалось прочитать ${PHP_REMOVE_YELLOW}${source}${PHP_REMOVE_RESET}"); continue; }
      while read -r entry value target state _remainder; do
        [[ "$state" == 01 ]] || continue
        hexport="${value##*:}"
        if [[ ! "$hexport" =~ ^[[:xdigit:]]+$ ]]; then
          PHP_REMOVE_BLOCKERS+=("Не удалось разобрать TCP-соединение ${PHP_REMOVE_YELLOW}${source}${PHP_REMOVE_RESET}")
          continue
        fi
        for port in "${PHP_REMOVE_TCP_PORTS[@]}"; do
          ((16#$hexport == port)) && PHP_REMOVE_BLOCKERS+=("Активное TCP-соединение к PHP-FPM: порт ${PHP_REMOVE_GREEN}${port}${PHP_REMOVE_RESET} (${PHP_REMOVE_YELLOW}${source}${PHP_REMOVE_RESET}).")
        done
      done <"$filename"
    done
  fi
  directory="$(php_remove_path /proc)"
  if ! find "$directory" -mindepth 1 -maxdepth 1 -type d -print0 >"$temporary/files" 2>"$temporary/errors"; then
    PHP_REMOVE_BLOCKERS+=("Не удалось проверить процессы.")
  else
    while IFS= read -r -d '' entry; do
      pid="${entry##*/}"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if ! exe="$(readlink -- "$entry/exe" 2>/dev/null)"; then
        [[ -d "$entry" ]] || continue
        if [[ -r "$entry/stat" ]]; then
          value="$(cat "$entry/stat")"
          value="${value##*) }"
          read -r -a stat_fields <<<"$value"
          if [[ "${stat_fields[0]:-}" == Z ]] ||
            { [[ "${stat_fields[6]:-}" =~ ^[0-9]+$ ]] && ((stat_fields[6] & 2097152)); }; then
            continue
          fi
        fi
        PHP_REMOVE_BLOCKERS+=("Не удалось проверить процесс PID ${PHP_REMOVE_GREEN}${pid}${PHP_REMOVE_RESET}.")
        continue
      fi
      exe="${exe% (deleted)}"
      [[ "$exe" == "$(php_remove_path "/opt/remi/$version")/"* ]] || continue
      if ! cgroup="$(cat "$entry/cgroup" 2>/dev/null)"; then
        [[ -d "$entry" ]] && PHP_REMOVE_BLOCKERS+=("Не удалось проверить cgroup PID ${PHP_REMOVE_GREEN}${pid}${PHP_REMOVE_RESET}.")
        continue
      fi
      if [[ "$exe" == "$(php_remove_path "/opt/remi/$version/root/usr/sbin/php-fpm")" && "$cgroup" =~ $own_pattern ]]; then
        continue
      fi
      PHP_REMOVE_BLOCKERS+=("Процесс PID ${PHP_REMOVE_GREEN}${pid}${PHP_REMOVE_RESET} использует ${PHP_REMOVE_YELLOW}${exe}${PHP_REMOVE_RESET}")
    done <"$temporary/files"
  fi
  rm -rf -- "$temporary"
  if ((${#PHP_REMOVE_SITES[@]} + ${#PHP_REMOVE_APACHE_CONFIGS[@]} + ${#PHP_REMOVE_CRON_TASKS[@]} + ${#PHP_REMOVE_BLOCKERS[@]})); then
    printf '\nУдалить %b%s%b нельзя.\n' "$PHP_REMOVE_GREEN" "$version" "$PHP_REMOVE_RESET"
    if ((${#PHP_REMOVE_SITES[@]})); then
      printf '\nЭта версия PHP используется сайтами:\n\n'
      while IFS= read -r source; do
        printf '  %b%s%b\n' "$PHP_REMOVE_GREEN" "$source" "$PHP_REMOVE_RESET"
      done < <(printf '%s\n' "${!PHP_REMOVE_SITES[@]}" | LC_ALL=C sort)
    fi
    if ((${#PHP_REMOVE_APACHE_CONFIGS[@]})); then
      printf '\nСсылки на эту версию в Apache-конфигах:\n\n'
      for source in "${PHP_REMOVE_APACHE_CONFIGS[@]}"; do
        printf '  %b%s%b\n' "$PHP_REMOVE_YELLOW" "$source" "$PHP_REMOVE_RESET"
      done
    fi
    if ((${#PHP_REMOVE_CRON_TASKS[@]})); then
      printf '\nЭта версия PHP используется заданиями CRON:\n\n'
      for cron_index in "${!PHP_REMOVE_CRON_TASKS[@]}"; do
        if [[ -n "${PHP_REMOVE_CRON_USERS[$cron_index]}" ]]; then
          printf '  CRON пользователя %b%s%b\n' "$PHP_REMOVE_GREEN" "${PHP_REMOVE_CRON_USERS[$cron_index]}" "$PHP_REMOVE_RESET"
        fi
        printf '  %b%s%b\n' "$PHP_REMOVE_YELLOW" "${PHP_REMOVE_CRON_TASKS[$cron_index]}" "$PHP_REMOVE_RESET"
        printf '  %s\n\n' "${PHP_REMOVE_CRON_LINES[$cron_index]}"
      done
    fi
    if ((${#PHP_REMOVE_BLOCKERS[@]})); then
      printf '\nПричины запрета удаления:\n\n'
      printf '  %s\n' "${PHP_REMOVE_BLOCKERS[@]}"
    fi
    printf '\n'
    if ((${#PHP_REMOVE_SITES[@]})); then
      echo "Переключите указанные сайты на другую версию PHP"
      printf 'через меню управления сайтом.\n\n'
    fi
    if ((${#PHP_REMOVE_CRON_TASKS[@]})); then
      printf 'Переключите указанные задания CRON на другую версию PHP.\n\n'
    fi
    printf 'Повторите удаление после устранения указанных причин.\n\n'
    return 1
  fi
  return 0
}

php_remove_service_state() {
  local output
  output="$("${PHP_REMOVE_SYSTEMCTL:-systemctl}" show "$1-php-fpm.service" --property=LoadState,ActiveState,SubState,UnitFileState)" || {
    [[ "$output" == *'LoadState=not-found'* ]] || return 1
  }
  [[ "$output" == *'ActiveState='* ]] || return 1
  printf '%s\n' "$output"
}

php_remove_state_value() {
  local state="$1" key="$2" line
  while IFS= read -r line; do
    [[ "$line" == "$key="* ]] && { printf '%s\n' "${line#*=}"; return 0; }
  done <<<"$state"
  return 1
}

php_remove_restore_service() {
  local version="$1" original="$2" current wanted actual active
  current="$(php_remove_service_state "$version")" || return 1
  wanted="$(php_remove_state_value "$original" UnitFileState)" || return 1
  actual="$(php_remove_state_value "$current" UnitFileState)" || return 1
  if [[ "$wanted" != "$actual" ]]; then
    case "$wanted" in
      enabled) "${PHP_REMOVE_SYSTEMCTL:-systemctl}" enable "$version-php-fpm.service" || return 1 ;;
      enabled-runtime) "${PHP_REMOVE_SYSTEMCTL:-systemctl}" enable --runtime "$version-php-fpm.service" || return 1 ;;
      disabled) "${PHP_REMOVE_SYSTEMCTL:-systemctl}" disable "$version-php-fpm.service" || return 1 ;;
      masked) "${PHP_REMOVE_SYSTEMCTL:-systemctl}" mask "$version-php-fpm.service" || return 1 ;;
      masked-runtime) "${PHP_REMOVE_SYSTEMCTL:-systemctl}" mask --runtime "$version-php-fpm.service" || return 1 ;;
      *) return 1 ;;
    esac
  fi
  active="$(php_remove_state_value "$original" ActiveState)" || return 1
  case "$active" in
    active|activating|reloading)
      "$(php_remove_path "/opt/remi/$version/root/usr/sbin/php-fpm")" -t || return 1
      "${PHP_REMOVE_SYSTEMCTL:-systemctl}" start "$version-php-fpm.service" || return 1
      "${PHP_REMOVE_SYSTEMCTL:-systemctl}" is-active --quiet "$version-php-fpm.service" || return 1
      ;;
  esac
}

php_remove_disable_apache_conf() {
  local filename="$1"
  [[ -e "$filename" || -L "$filename" ]] || return 0
  if [[ -e "${filename}.bak" || -L "${filename}.bak" ]] || ! mv -- "$filename" "${filename}.bak"; then
    printf 'Не удалось снова отключить Apache-конфиг %b%s%b. Проверьте его вручную.\n' "$PHP_REMOVE_YELLOW" "$filename" "$PHP_REMOVE_RESET" >&2
    return 1
  fi
}

php_remove_execute() (
  local version="$1" expected="$2" temporary current state active status=0 interrupted=0 lock_fd source info owner mode
  local apache_conf='' apache_restored=0
  local -a packages=()
  php_remove_require_root || return 1
  php_remove_valid_version "$version" && [[ -s "$expected" && -r "$expected" ]] || return 1
  temporary="$(mktemp -d /tmp/rish-php-execute.XXXXXX)" || return 1
  trap '
    if ((apache_restored)); then
      php_remove_disable_apache_conf "$apache_conf" || true
    fi
    rm -rf -- "$temporary"
  ' EXIT
  trap 'interrupted=1' INT TERM
  source="$(php_remove_path /run/lock/rish-php-remove.lock)"
  [[ ! -L "$source" ]] || { printf '%bНебезопасный%b файл блокировки.\n' "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" >&2; return 1; }
  exec {lock_fd}>"$source" || return 1
  info="$(stat -c '%u %a' -- "$source")" || return 1
  read -r owner mode <<<"$info"
  if [[ -f "$source" && "$owner" == 0 && "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode & 18) == 0 )); then
    :
  else
    printf '%bНебезопасный%b файл блокировки.\n' "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" >&2
    return 1
  fi
  flock -n "$lock_fd" || { printf 'Другое удаление PHP %bуже выполняется%b.\n' "$PHP_REMOVE_YELLOW" "$PHP_REMOVE_RESET" >&2; return 1; }
  php_remove_packages "$version" >"$temporary/packages" || return 1
  cmp -s "$expected" "$temporary/packages" || { printf 'Набор пакетов %bизменился%b. Повторите выбор.\n' "$PHP_REMOVE_YELLOW" "$PHP_REMOVE_RESET" >&2; return 1; }
  mapfile -t packages <"$temporary/packages"
  ((${#packages[@]})) || return 1
  php_remove_audit "$version" || return 1
  "${PHP_REMOVE_RPM:-rpm}" -e --test -- "${packages[@]}" || return 1
  php_remove_all_packages >"$temporary/all-before" || return 1
  state="$(php_remove_service_state "$version")" || return 1
  ((interrupted == 0)) || return 1
  php_remove_all_packages >"$temporary/all-after" || return 1
  cmp -s "$temporary/all-before" "$temporary/all-after" || {
    printf 'RPMDB %bизменилась%b. Удаление отменено.\n' "$PHP_REMOVE_YELLOW" "$PHP_REMOVE_RESET" >&2
    return 1
  }
  php_remove_audit "$version" || return 1
  ((interrupted == 0)) || return 1
  active="$(php_remove_state_value "$state" ActiveState)" || return 1
  case "$active" in
    active|activating|reloading|deactivating)
      "${PHP_REMOVE_SYSTEMCTL:-systemctl}" stop "$version-php-fpm.service" || status=1
      ;;
  esac
  ((interrupted)) && status=1
  if ((status == 0)); then
    current="$(php_remove_service_state "$version")" || status=1
    active="$(php_remove_state_value "$current" ActiveState)" || status=1
    case "$active" in active|activating|reloading|deactivating) status=1 ;; esac
  fi
  if ((status == 0 && interrupted == 0)); then
    apache_conf="$(php_remove_path "/etc/httpd/conf.d/$version-php.conf")"
    if [[ ! -e "$apache_conf" && ! -L "$apache_conf" && -f "${apache_conf}.bak" && ! -L "${apache_conf}.bak" ]]; then
      apache_restored=1
      if ! mv -- "${apache_conf}.bak" "$apache_conf"; then
        printf 'Не удалось вернуть Apache-конфиг %b%s%b перед удалением.\n' "$PHP_REMOVE_YELLOW" "$apache_conf" "$PHP_REMOVE_RESET" >&2
        status=1
      fi
    fi
  fi
  if ((status == 0 && interrupted == 0)); then
    "${PHP_REMOVE_RPM:-rpm}" -e -- "${packages[@]}" || status=1
    printf '\nСообщения «warning: … saved as …%b.rpmsave%b» означают, что RPM создал\n' "$PHP_REMOVE_YELLOW" "$PHP_REMOVE_RESET"
    echo "штатный бекап конфигурационного файла."
    printf 'Это нормальное поведение при удалении пакета.\n\n'
  fi
  if ((apache_restored)); then
    php_remove_disable_apache_conf "$apache_conf" || return 1
    apache_restored=0
  fi
  if ! php_remove_packages "$version" >"$temporary/remaining"; then
    printf 'Не удалось проверить %bRPMDB%b после удаления.\n' "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" >&2
    return 1
  fi
  if [[ -s "$temporary/remaining" ]]; then
    status=1
  fi
  if ((status || interrupted)) && cmp -s "$temporary/packages" "$temporary/remaining"; then
    trap '' INT TERM
    if php_remove_restore_service "$version" "$state"; then
      printf 'Удаление %bне выполнено%b. Пакеты целы, прежняя работа службы %bвосстановлена%b.\n' "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" "$PHP_REMOVE_GREEN" "$PHP_REMOVE_RESET" >&2
    else
      printf 'Удаление %bне выполнено%b. Пакеты целы; восстановить службу автоматически %bне удалось%b.\n' "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" >&2
    fi
    return 1
  fi
  if [[ -s "$temporary/remaining" ]]; then
    printf 'Пакеты удалены %bчастично%b. Автоматический откат не выполнялся.\n' "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" >&2
    while IFS= read -r source; do
      printf '  %b%s%b\n' "$PHP_REMOVE_GREEN" "$source" "$PHP_REMOVE_RESET" >&2
    done <"$temporary/remaining"
    return 1
  fi
  trap '' INT TERM
  source="$(php_remove_path "/etc/systemd/system/$version-php-fpm.service.d")"
  if [[ -L "$source" ]]; then
    rm -f -- "$source" || printf 'Не удалось удалить сохранённую настройку systemd: %b%s%b\n' "$PHP_REMOVE_YELLOW" "$source" "$PHP_REMOVE_RESET" >&2
  elif [[ -d "$source" ]]; then
    rm -rf -- "$source" || printf 'Не удалось удалить сохранённую настройку systemd: %b%s%b\n' "$PHP_REMOVE_YELLOW" "$source" "$PHP_REMOVE_RESET" >&2
  fi
  "${PHP_REMOVE_SYSTEMCTL:-systemctl}" daemon-reload || printf 'PHP удалён, но %bsystemd%b не перечитал конфигурацию.\n' "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" >&2
  if ((status || interrupted)); then
    printf 'Пакеты %b%s%b удалены, но операция завершилась с %bошибкой%b или была прервана.\n' "$PHP_REMOVE_GREEN" "$version" "$PHP_REMOVE_RESET" "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" >&2
    return 2
  fi
  printf 'Версия %b%s%b %bудалена%b.\n' "$PHP_REMOVE_GREEN" "$version" "$PHP_REMOVE_RESET" "$PHP_REMOVE_GREEN" "$PHP_REMOVE_RESET"
  return 0
)

php_remove_confirmation_screen() {
  local version="$1" package name index width=0
  local -a package_names=()
  shift
  for package in "$@"; do
    if [[ "$package" =~ ^(.+)-[0-9]+:.*$ ]]; then
      name="${BASH_REMATCH[1]}"
    else
      name="$package"
    fi
    package_names+=("$name")
    ((${#name} > width)) && width=${#name}
  done

  clear
  printf 'Удаление PHP: %b%s%b\n\n' "$PHP_REMOVE_GREEN" "$version" "$PHP_REMOVE_RESET"
  echo "Проверены сайты, CRON, systemd, CLI-ссылки и процессы."
  printf 'Явных зависимостей %bне найдено%b.\n\n' "$PHP_REMOVE_GREEN" "$PHP_REMOVE_RESET"
  printf 'Пакеты к удалению: %s\n\n' "${#package_names[@]}"
  for ((index=0; index<${#package_names[@]}; index+=2)); do
    if ((index + 1 < ${#package_names[@]})); then
      printf '  %-*s  %s\n' "$width" "${package_names[$index]}" "${package_names[$((index + 1))]}"
    else
      printf '  %s\n' "${package_names[$index]}"
    fi
  done
  printf '\n%bВнимание:%b\n' "$PHP_REMOVE_YELLOW" "$PHP_REMOVE_RESET"
  echo "  Нестандартные способы запуска PHP могут не обнаруживаться."
  echo "  Убедитесь, что версия не нужна вашим службам и скриптам."
  printf '\nУдалить %b%s%b?\n\n' "$PHP_REMOVE_GREEN" "$version" "$PHP_REMOVE_RESET"
}

php_remove_main() {
  local rish_home="${RISH_HOME:-/root/rish}" temporary selected choice output command result
  local -a versions=() packages=()
  PHP_REMOVE_ROOT=''
  PHP_REMOVE_RPM=/usr/bin/rpm
  PHP_REMOVE_HTTPD=/usr/sbin/httpd
  PHP_REMOVE_SYSTEMCTL=/usr/bin/systemctl
  PHP_REMOVE_GETENT=/usr/bin/getent
  PHP_REMOVE_GREEN=$'\033[0;32m'
  PHP_REMOVE_RED=$'\033[0;31m'
  PHP_REMOVE_YELLOW=$'\033[0;33m'
  PHP_REMOVE_RESET=$'\033[0m'
  php_remove_require_root || return 1
  source "$rish_home/windows.sh" || return 1
  for command in "$PHP_REMOVE_RPM" "$PHP_REMOVE_HTTPD" "$PHP_REMOVE_SYSTEMCTL" "$PHP_REMOVE_GETENT" find readlink flock stat cmp sort; do
    command -v "$command" >/dev/null 2>&1 || { printf 'Не найдена команда %b%s%b. Удаление PHP недоступно.\n' "$PHP_REMOVE_YELLOW" "$command" "$PHP_REMOVE_RESET" >&2; return 1; }
  done
  temporary="$(mktemp -d /tmp/rish-php-remove.XXXXXX)" || return 1
  while true; do
    if ! php_remove_list_versions >"$temporary/versions"; then
      printf 'Не удалось получить список пакетов %bPHP%b.\n' "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" >&2
      rm -rf -- "$temporary"
      return 1
    fi
    mapfile -t versions <"$temporary/versions"
    if ((${#versions[@]} == 0)); then
      echo "Версии PHP из Remi для удаления не найдены."
      break
    fi
    printf '\nУдаление версий %bPHP%b\n' "$PHP_REMOVE_GREEN" "$PHP_REMOVE_RESET"
    echo "Выберите версию для проверки возможности удаления."
    echo "Удаление выполняется только после отдельного подтверждения."
    vertical_menu "current" 2 0 38 "${versions[@]}" "Выйти"
    choice=$?
    ((choice == 255 || choice == ${#versions[@]})) && break
    selected="${versions[$choice]:-}"
    php_remove_valid_version "$selected" || break
    printf 'Проверяем использование %b%s%b и зависимости пакетов.\n' "$PHP_REMOVE_GREEN" "$selected" "$PHP_REMOVE_RESET"
    if ! php_remove_packages "$selected" >"$temporary/packages" || [[ ! -s "$temporary/packages" ]]; then
      printf 'Не удалось получить пакеты %b%s%b. Удаление %bне выполнялось%b.\n' "$PHP_REMOVE_GREEN" "$selected" "$PHP_REMOVE_RESET" "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET" >&2
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      continue
    fi
    if ! php_remove_audit "$selected"; then
      printf 'Удаление не выполнялось.\n\n'
      printf 'Выберите другую версию или выйдите.\n\n'
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      continue
    fi
    mapfile -t packages <"$temporary/packages"
    if ! "$PHP_REMOVE_RPM" -e --test -- "${packages[@]}"; then
      printf 'Проверка зависимостей %b%s%b %bне пройдена%b. Удаление не выполнялось.\n' "$PHP_REMOVE_GREEN" "$selected" "$PHP_REMOVE_RESET" "$PHP_REMOVE_RED" "$PHP_REMOVE_RESET"
      echo "Выберите другую версию или выйдите."
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      continue
    fi
    php_remove_confirmation_screen "$selected" "${packages[@]}"
    vertical_menu "current" 2 0 10 "default=0" "Нет" "Да"
    choice=$?
    if ((choice != 1)); then
      printf 'Удаление %b%s%b %bотменено%b.\n' "$PHP_REMOVE_GREEN" "$selected" "$PHP_REMOVE_RESET" "$PHP_REMOVE_YELLOW" "$PHP_REMOVE_RESET"
      continue
    fi
    result=0
    php_remove_execute "$selected" "$temporary/packages" || result=$?
    if ((result == 0 || result == 2)); then
      if ! source "$rish_home/create_hotlist.sh" || ! create_hotlist; then
        printf 'PHP удалён, но обновить %bhotlist Midnight Commander%b не удалось.\n' "$PHP_REMOVE_YELLOW" "$PHP_REMOVE_RESET" >&2
      fi
    fi
    vertical_menu "current" 2 0 5 "Нажмите Enter"
  done
  rm -rf -- "$temporary"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  php_remove_main "$@"
fi
