#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'

MODE="check"
ASSUME_YES=0
SILENT=0
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
NOINDEX_TEMPLATE="${TEMPLATE_DIR}/apache-noindex.html"
WWW_TEMPLATE="${TEMPLATE_DIR}/php-fpm-www.conf.template"
DEFAULT_VHOST_TEMPLATE="${TEMPLATE_DIR}/000-default.conf"
DEFAULT_SSL_VHOST_TEMPLATE="${TEMPLATE_DIR}/000-default-ssl.conf"
PHP_FPM_RESTART_CONF="local.conf"

declare -a ISSUE_MESSAGES=()
declare -a ISSUE_FIXES=()
declare -a ISSUE_ARGS=()
declare -a ERRORS=()
declare -A REFERENCED_POOLS=()
declare -A REFERENCED_POOL_FILES=()

usage() {
  cat <<EOF
Использование:
  ${SCRIPT_NAME}          подробная проверка без исправлений
  ${SCRIPT_NAME} silent   тихая проверка
  ${SCRIPT_NAME} fix      интерактивное исправление
  ${SCRIPT_NAME} fix --yes
EOF
}

log() {
  [[ "$SILENT" -eq 1 ]] && return
  printf '%b\n' "$*"
}

highlight_path_file() {
  local path="$1"
  local dir="${path%/*}"
  local file="${path##*/}"

  if [[ "$dir" == "$path" ]]; then
    echo "${YELLOW}${file}${WHITE}"
  else
    echo "${dir}/${YELLOW}${file}${WHITE}"
  fi
}

highlight_path_list_files() {
  local list="$1"
  local item
  local out=""
  local -a items

  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    if [[ -n "$out" ]]; then
      out+=", "
    fi
    out+="$(highlight_path_file "$item")"
  done
  echo "$out"
}

add_issue() {
  ISSUE_MESSAGES+=("$1")
  ISSUE_FIXES+=("${2:-}")
  ISSUE_ARGS+=("${3:-}")
}

reset_state() {
  ISSUE_MESSAGES=()
  ISSUE_FIXES=()
  ISSUE_ARGS=()
  ERRORS=()
  REFERENCED_POOLS=()
  REFERENCED_POOL_FILES=()
}

check_prerequisites() {
  [[ -f "$NOINDEX_TEMPLATE" ]] || ERRORS+=("Не найден шаблон ${NOINDEX_TEMPLATE}")
  [[ -f "$WWW_TEMPLATE" ]] || ERRORS+=("Не найден шаблон ${WWW_TEMPLATE}")
  [[ -f "$DEFAULT_VHOST_TEMPLATE" ]] || ERRORS+=("Не найден шаблон ${DEFAULT_VHOST_TEMPLATE}")
  [[ -f "$DEFAULT_SSL_VHOST_TEMPLATE" ]] || ERRORS+=("Не найден шаблон ${DEFAULT_SSL_VHOST_TEMPLATE}")

  if [[ "$MODE" == "fix" && "$ASSUME_YES" -ne 1 && ! -f "${SCRIPT_DIR}/windows.sh" ]]; then
    ERRORS+=("Не найден ${SCRIPT_DIR}/windows.sh, интерактивное исправление невозможно")
  fi
}

render_www_template() {
  local php_version="$1"
  sed "s/{{PHP_VERSION}}/${php_version}/g" "$WWW_TEMPLATE"
}

www_conf_matches_template() {
  local php_version="$1"
  local conf_file="$2"

  [[ -f "$conf_file" ]] || return 1
  render_www_template "$php_version" | cmp -s - "$conf_file"
}

write_www_conf() {
  local php_version="$1"
  local conf_file="$2"
  local tmp_file="${conf_file}.rish-tmp.$$"

  render_www_template "$php_version" > "$tmp_file" || return 1

  if [[ -f "$conf_file" ]]; then
    mv -f "$conf_file" "${conf_file}.old" || return 1
    log "Сохранен предыдущий ${YELLOW}${conf_file}${WHITE} как ${YELLOW}${conf_file}.old${WHITE}"
  fi

  mv "$tmp_file" "$conf_file"
}

write_template_file() {
  local template_file="$1"
  local target_file="$2"
  local tmp_file="${target_file}.rish-tmp.$$"

  install -m 644 "$template_file" "$tmp_file" || return 1

  if [[ -f "$target_file" ]]; then
    mv -f "$target_file" "${target_file}.old" || return 1
    log "Сохранен предыдущий ${YELLOW}${target_file}${WHITE} как ${YELLOW}${target_file}.old${WHITE}"
  fi

  mv "$tmp_file" "$target_file"
}

write_php_fpm_restart_conf() {
  local php_version="$1"
  local conf_dir="/etc/systemd/system/${php_version}-php-fpm.service.d"
  local conf_file="${conf_dir}/${PHP_FPM_RESTART_CONF}"

  install -d -m 755 "$conf_dir" || return 1
  cat > "$conf_file" <<EOF
[Service]
Restart=on-failure
RestartSec=180
EOF
}

collect_referenced_pools() {
  local conf_file
  local socket_path
  local php_version
  local user_name

  shopt -s nullglob
  for conf_file in /etc/httpd/conf.d/*.conf; do
    [[ -f "$conf_file" ]] || continue
    [[ "$(basename "$conf_file")" =~ ^php[0-9][0-9]-php\.conf$ ]] && continue
    while IFS= read -r socket_path; do
      php_version="$(echo "$socket_path" | sed -n 's|.*/remi/\(php[0-9][0-9]\)/run/php-fpm/.*|\1|p')"
      user_name="$(basename "$socket_path" .sock)"
      [[ -n "$php_version" && -n "$user_name" ]] || continue
      REFERENCED_POOLS["${php_version}:${user_name}"]=1
      if [[ -z "${REFERENCED_POOL_FILES["${php_version}:${user_name}"]:-}" ]]; then
        REFERENCED_POOL_FILES["${php_version}:${user_name}"]="$conf_file"
      else
        REFERENCED_POOL_FILES["${php_version}:${user_name}"]+=", ${conf_file}"
      fi
    done < <(grep -hoE '/var/opt/remi/php[0-9][0-9]/run/php-fpm/[^"|[:space:]]+\.sock' "$conf_file" 2>/dev/null || true)
  done
  shopt -u nullglob
}

check_var_www() {
  local owner
  local perm
  local user_dir
  local user_name
  local expected_owner

  if [[ ! -d /var/www ]]; then
    add_issue "/var/www отсутствует" "fix_var_www_root" ""
    return
  fi

  owner="$(stat -c '%U:%G' /var/www 2>/dev/null)" || ERRORS+=("Не удалось прочитать владельца /var/www")
  perm="$(stat -c '%a' /var/www 2>/dev/null)" || ERRORS+=("Не удалось прочитать права /var/www")

  [[ "$owner" == "root:root" ]] || add_issue "/var/www имеет владельца ${owner}, требуется root:root" "fix_chown" "/var/www|root:root"
  [[ "$perm" == "751" ]] || add_issue "/var/www имеет права ${perm}, требуется 751" "fix_chmod" "/var/www|751"

  shopt -s nullglob
  for user_dir in /var/www/*; do
    [[ -d "$user_dir" ]] || continue
    user_name="$(basename "$user_dir")"
    case "$user_name" in
      html|cgi-bin)
        continue
        ;;
    esac

    if ! id "$user_name" >/dev/null 2>&1; then
      add_issue "Для ${user_dir} не найден системный пользователь ${user_name}" "" ""
    fi

    if ! getent group "$user_name" >/dev/null 2>&1; then
      add_issue "Для ${user_dir} не найдена группа ${user_name}" "" ""
    fi

    expected_owner="root:${user_name}"
    owner="$(stat -c '%U:%G' "$user_dir" 2>/dev/null)" || ERRORS+=("Не удалось прочитать владельца ${user_dir}")
    perm="$(stat -c '%a' "$user_dir" 2>/dev/null)" || ERRORS+=("Не удалось прочитать права ${user_dir}")

    [[ "$owner" == "$expected_owner" ]] || add_issue "${user_dir} имеет владельца ${owner}, требуется ${expected_owner}" "fix_chown" "${user_dir}|${expected_owner}"
    [[ "$perm" == "750" ]] || add_issue "${user_dir} имеет права ${perm}, требуется 750" "fix_chmod" "${user_dir}|750"

    check_user_tmp_dir "$user_name"
  done
  shopt -u nullglob
}

check_user_tmp_dir() {
  local user_name="$1"
  local tmp_dir="/var/www/${user_name}/tmp"
  local owner
  local perm

  if [[ ! -d "$tmp_dir" ]]; then
    add_issue "${tmp_dir} отсутствует" "fix_user_tmp" "$user_name"
    return
  fi

  owner="$(stat -c '%U:%G' "$tmp_dir" 2>/dev/null)" || ERRORS+=("Не удалось прочитать владельца ${tmp_dir}")
  perm="$(stat -c '%a' "$tmp_dir" 2>/dev/null)" || ERRORS+=("Не удалось прочитать права ${tmp_dir}")

  [[ "$owner" == "${user_name}:${user_name}" ]] || add_issue "${tmp_dir} имеет владельца ${owner}, требуется ${user_name}:${user_name}" "fix_chown" "${tmp_dir}|${user_name}:${user_name}"
  [[ "$perm" == "755" ]] || add_issue "${tmp_dir} имеет права ${perm}, требуется 755" "fix_chmod" "${tmp_dir}|755"
}

check_noindex() {
  local target="/usr/share/httpd/noindex/index.html"

  if [[ ! -f "$target" ]]; then
    add_issue "$(highlight_path_file "$target") отсутствует" "fix_noindex" ""
    return
  fi

  if ! cmp -s "$NOINDEX_TEMPLATE" "$target"; then
    add_issue "$(highlight_path_file "$target") отличается от шаблона RISH" "fix_noindex" ""
  fi
}

check_apache_conf_files() {
  local conf_file
  local default_vhost="/etc/httpd/conf.d/000-default.conf"
  local default_ssl_vhost="/etc/httpd/conf.d/000-default-ssl.conf"

  if [[ -f /etc/httpd/conf.d/autoindex.conf ]]; then
    add_issue "Найден лишний Apache-конфиг /etc/httpd/conf.d/autoindex.conf" "fix_remove_file" "/etc/httpd/conf.d/autoindex.conf"
  fi

  if [[ ! -f "$default_vhost" ]]; then
    add_issue "$(highlight_path_file "$default_vhost") отсутствует" "fix_template_file" "${DEFAULT_VHOST_TEMPLATE}|${default_vhost}"
  elif ! cmp -s "$DEFAULT_VHOST_TEMPLATE" "$default_vhost"; then
    add_issue "$(highlight_path_file "$default_vhost") отличается от шаблона RISH" "fix_template_file" "${DEFAULT_VHOST_TEMPLATE}|${default_vhost}"
  fi

  if [[ ! -f "$default_ssl_vhost" ]]; then
    add_issue "$(highlight_path_file "$default_ssl_vhost") отсутствует" "fix_template_file" "${DEFAULT_SSL_VHOST_TEMPLATE}|${default_ssl_vhost}"
  elif ! cmp -s "$DEFAULT_SSL_VHOST_TEMPLATE" "$default_ssl_vhost"; then
    add_issue "$(highlight_path_file "$default_ssl_vhost") отличается от шаблона RISH" "fix_template_file" "${DEFAULT_SSL_VHOST_TEMPLATE}|${default_ssl_vhost}"
  fi

  shopt -s nullglob
  for conf_file in /etc/httpd/conf.d/php[0-9][0-9]-php.conf; do
    if grep -qE 'SetHandler "proxy:unix:/var/opt/remi/php[0-9][0-9]/run/php-fpm/www\.sock\|fcgi://localhost"' "$conf_file"; then
      add_issue "Найден Remi Apache PHP-конфиг с глобальным www.sock: $(highlight_path_file "$conf_file")" "fix_disable_file" "$conf_file"
    else
      add_issue "Найден Remi Apache PHP-конфиг: $(highlight_path_file "$conf_file")" "fix_disable_file" "$conf_file"
    fi
  done
  shopt -u nullglob
}

check_apache_ssl_conf() {
  local ssl_conf="/etc/httpd/conf.d/ssl.conf"

  [[ -f "$ssl_conf" ]] || return

  if ! grep -qE '^[[:space:]]*Protocols[[:space:]]+h2[[:space:]]+http/1\.1[[:space:]]*$' "$ssl_conf"; then
    add_issue "${ssl_conf} не содержит активную строку Protocols h2 http/1.1" "fix_ssl_protocols" "$ssl_conf"
  fi
}

check_vhost_handlers() {
  local key
  local php_version
  local user_name
  local pool_file
  local source_files

  for key in "${!REFERENCED_POOLS[@]}"; do
    php_version="${key%%:*}"
    user_name="${key#*:}"
    pool_file="/etc/opt/remi/${php_version}/php-fpm.d/${user_name}.conf"
    source_files="${REFERENCED_POOL_FILES[$key]:-неизвестный Apache-конфиг}"
    if [[ ! -f "$pool_file" ]]; then
      add_issue "В настройках сайта $(highlight_path_list_files "$source_files") указан отсутствующий PHP-пул $(highlight_path_file "$pool_file")" "" ""
    fi
  done
}

count_user_pools() {
  local php_fpm_dir="$1"
  local pool_file
  local count=0

  shopt -s nullglob
  for pool_file in "${php_fpm_dir}"/*.conf; do
    [[ "$(basename "$pool_file")" == "www.conf" ]] && continue
    count=$((count + 1))
  done
  shopt -u nullglob

  echo "$count"
}

check_php_fpm() {
  local php_dir
  local php_version
  local php_fpm_dir
  local pool_file
  local pool_base
  local user_name
  local expected_listen
  local user_pool_count
  local www_conf
  local key

  shopt -s nullglob
  for php_dir in /etc/opt/remi/php[0-9][0-9]; do
    [[ -d "$php_dir" ]] || continue
    php_version="$(basename "$php_dir")"
    php_fpm_dir="${php_dir}/php-fpm.d"
    [[ -d "$php_fpm_dir" ]] || continue

    user_pool_count="$(count_user_pools "$php_fpm_dir")"
    www_conf="${php_fpm_dir}/www.conf"

    if [[ "$user_pool_count" -gt 0 ]]; then
      if [[ -f "$www_conf" ]]; then
        add_issue "$(highlight_path_file "$www_conf") активен при наличии пользовательских pools" "fix_disable_file" "$www_conf"
      fi
    else
      if [[ ! -f "$www_conf" ]]; then
        add_issue "Для ${php_version} нет пользовательских pools и отсутствует $(highlight_path_file "$www_conf")" "fix_www_template" "${php_version}|${www_conf}"
      elif ! www_conf_matches_template "$php_version" "$www_conf"; then
        add_issue "$(highlight_path_file "$www_conf") отличается от RISH-шаблона default pool" "fix_www_template" "${php_version}|${www_conf}"
      fi
    fi

    for pool_file in "${php_fpm_dir}"/*.conf; do
      pool_base="$(basename "$pool_file")"
      [[ "$pool_base" == "www.conf" ]] && continue
      user_name="${pool_base%.conf}"
      key="${php_version}:${user_name}"
      expected_listen="/var/opt/remi/${php_version}/run/php-fpm/${user_name}.sock"

      if ! id "$user_name" >/dev/null 2>&1; then
        add_issue "Pool $(highlight_path_file "$pool_file") ссылается на отсутствующего пользователя ${user_name}" "" ""
      fi

      if [[ ! -d "/var/www/${user_name}" ]]; then
        add_issue "Pool $(highlight_path_file "$pool_file") есть, но /var/www/${user_name} отсутствует" "" ""
      fi

      if ! grep -qE '^[[:space:]]*php_value\[upload_tmp_dir\][[:space:]]*=[[:space:]]*/var/www/'"${user_name}"'/tmp[[:space:]]*$' "$pool_file"; then
        add_issue "В $(highlight_path_file "$pool_file") отсутствует php_value[upload_tmp_dir] = /var/www/${user_name}/tmp" "fix_pool_upload_tmp" "${pool_file}|${user_name}"
      fi

      if ! grep -qE '^[[:space:]]*listen[[:space:]]*=[[:space:]]*'"${expected_listen}"'[[:space:]]*$' "$pool_file"; then
        add_issue "В $(highlight_path_file "$pool_file") listen не совпадает с ${expected_listen}" "" ""
      fi

      if [[ -z "${REFERENCED_POOLS[$key]:-}" ]]; then
        add_issue "Pool $(highlight_path_file "$pool_file") не используется ни одним Apache vhost" "fix_disable_file" "$pool_file"
      fi
    done
  done
  shopt -u nullglob
}

get_installed_php_versions() {
  local fpm_binary

  shopt -s nullglob
  for fpm_binary in /opt/remi/php[0-9][0-9]/root/usr/sbin/php-fpm; do
    [[ -x "$fpm_binary" ]] || continue
    echo "$fpm_binary" | grep -oE 'php[0-9]{2}' | head -n 1
  done | sort -r | uniq
  shopt -u nullglob
}

is_php_fpm_restart_conf_valid() {
  local conf_file="$1"

  grep -qE '^[[:space:]]*Restart[[:space:]]*=[[:space:]]*on-failure[[:space:]]*$' "$conf_file" || return 1
  grep -qE '^[[:space:]]*RestartSec[[:space:]]*=[[:space:]]*180[[:space:]]*$' "$conf_file" || return 1
}

check_php_fpm_restart_policy() {
  local installed_versions
  local php_version
  local conf_dir
  local conf_file
  local orphan_dir
  local found

  installed_versions="$(get_installed_php_versions)"

  while IFS= read -r php_version; do
    [[ -n "$php_version" ]] || continue
    conf_dir="/etc/systemd/system/${php_version}-php-fpm.service.d"
    conf_file="${conf_dir}/${PHP_FPM_RESTART_CONF}"

    if [[ ! -f "$conf_file" ]]; then
      add_issue "Для ${YELLOW}${php_version}-php-fpm${WHITE} отсутствует systemd-настройка автоперезапуска ${conf_file}" "fix_php_fpm_restart_conf" "$php_version"
    elif ! is_php_fpm_restart_conf_valid "$conf_file"; then
      add_issue "В ${conf_file} нет ожидаемых Restart=on-failure и RestartSec=180" "" ""
    fi
  done <<< "$installed_versions"

  shopt -s nullglob
  for orphan_dir in /etc/systemd/system/php[0-9][0-9]-php-fpm.service.d; do
    [[ -d "$orphan_dir" ]] || continue
    php_version="$(basename "$orphan_dir" | grep -oE '^php[0-9]{2}')"
    found=0
    if grep -qxF "$php_version" <<< "$installed_versions"; then
      found=1
    fi
    if [[ "$found" -eq 0 ]]; then
      add_issue "Найдена systemd-настройка для удаленного PHP-FPM: ${orphan_dir}" "fix_remove_php_fpm_restart_dir" "$orphan_dir"
    fi
  done
  shopt -u nullglob
}

get_hotlist_php_versions() {
  local hotlist_file="${HOME}/.config/mc/hotlist"

  [[ -f "$hotlist_file" ]] || return 0
  grep -oE '/etc/opt/remi/php[0-9]{2}/php-fpm\.d' "$hotlist_file" | grep -oE 'php[0-9]{2}' | sort -r | uniq
}

check_hotlist_php_versions() {
  local installed_versions
  local hotlist_versions
  local hotlist_file="${HOME}/.config/mc/hotlist"

  installed_versions="$(get_installed_php_versions)"
  hotlist_versions="$(get_hotlist_php_versions)"

  if [[ ! -f "$hotlist_file" ]]; then
    add_issue "Midnight Commander hotlist ${hotlist_file} отсутствует" "fix_hotlist" ""
    return
  fi

  if [[ "$installed_versions" != "$hotlist_versions" ]]; then
    add_issue "Список PHP в Midnight Commander hotlist не соответствует установленным PHP-FPM версиям" "fix_hotlist" ""
  fi
}

check_apache_configtest() {
  if command -v apachectl >/dev/null 2>&1; then
    if apachectl configtest >/dev/null 2>&1; then
      log "Проверка конфигурации Apache: ${GREEN}ok${WHITE}"
    else
      add_issue "Apache configtest завершился с ошибкой" "" ""
    fi
  fi
}

check_php_fpm_configtests() {
  local php_dir
  local php_version
  local fpm_binary

  shopt -s nullglob
  for php_dir in /etc/opt/remi/php[0-9][0-9]; do
    [[ -d "$php_dir" ]] || continue
    php_version="$(basename "$php_dir")"
    fpm_binary="/opt/remi/${php_version}/root/usr/sbin/php-fpm"
    [[ -x "$fpm_binary" ]] || continue
    if "$fpm_binary" -t >/dev/null 2>&1; then
      log "Проверка конфигурации ${php_version}-php-fpm: ${GREEN}ok${WHITE}"
    else
      add_issue "${php_version}-php-fpm configtest завершился с ошибкой" "" ""
    fi
  done
  shopt -u nullglob
}

collect_issues() {
  reset_state
  check_prerequisites
  [[ "${#ERRORS[@]}" -gt 0 ]] && return

  collect_referenced_pools
  check_var_www
  check_noindex
  check_apache_conf_files
  check_apache_ssl_conf
  check_vhost_handlers
  check_php_fpm
  check_php_fpm_restart_policy
  check_hotlist_php_versions
  if [[ "$SILENT" -ne 1 ]]; then
    log
    check_apache_configtest
    check_php_fpm_configtests
  fi
}

print_issues() {
  local item

  if [[ "${#ISSUE_MESSAGES[@]}" -eq 0 ]]; then
    return
  fi

  log
  log "${YELLOW}Найдены отклонения настроек RISH:${WHITE}"
  for item in "${ISSUE_MESSAGES[@]}"; do
    log "  - ${item}"
  done
  log
}

print_final_report() {
  local item

  log
  log "${CYAN}Итог проверки:${WHITE}"
  if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    log "${RED}Проверка настроек RISH завершилась с ошибкой.${WHITE}"
    for item in "${ERRORS[@]}"; do
      log "  - ${item}"
    done
    log
    return
  fi

  if [[ "${#ISSUE_MESSAGES[@]}" -eq 0 ]]; then
    log "${GREEN}Настройки RISH в порядке.${WHITE}"
    log
    return
  fi

  log "${YELLOW}Найдены отклонения настроек RISH:${WHITE}"
  for item in "${ISSUE_MESSAGES[@]}"; do
    log "  - ${item}"
  done
  log
}

confirm_fix() {
  local message="$1"
  local choice

  [[ "$ASSUME_YES" -eq 1 ]] && return 0

  source "${SCRIPT_DIR}/windows.sh"
  echo
  echo -e "${YELLOW}Исправить:${WHITE} ${message}?"
  vertical_menu "current" 2 0 13 "Да" "Нет" "Исправить все" "Выйти"
  choice=$?
  case "$choice" in
    0)
      return 0
      ;;
    1)
      return 1
      ;;
    2)
      ASSUME_YES=1
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

apply_issues() {
  local i
  local fix_action
  local fix_arg
  local message
  local path
  local value
  local changed=0
  local confirm_status

  for i in "${!ISSUE_MESSAGES[@]}"; do
    message="${ISSUE_MESSAGES[$i]}"
    fix_action="${ISSUE_FIXES[$i]}"
    fix_arg="${ISSUE_ARGS[$i]}"

    if [[ -z "$fix_action" ]]; then
      continue
    fi

    confirm_fix "$message"
    confirm_status=$?

    if [[ "$confirm_status" -eq 2 ]]; then
      log "${YELLOW}Исправление прервано пользователем.${WHITE}"
      return 1
    fi

    if [[ "$confirm_status" -eq 0 ]]; then
      if case "$fix_action" in
          fix_var_www_root)
            install -d -m 751 -o root -g root /var/www || return 1
            ;;
          fix_chown)
            path="${fix_arg%%|*}"
            value="${fix_arg#*|}"
            chown "$value" "$path" || return 1
            ;;
          fix_chmod)
            path="${fix_arg%%|*}"
            value="${fix_arg#*|}"
            chmod "$value" "$path" || return 1
            ;;
          fix_user_tmp)
            install -d -m 755 -o "$fix_arg" -g "$fix_arg" "/var/www/${fix_arg}/tmp" || return 1
            ;;
          fix_noindex)
            install -D -m 644 "$NOINDEX_TEMPLATE" /usr/share/httpd/noindex/index.html || return 1
            ;;
          fix_template_file)
            path="${fix_arg%%|*}"
            value="${fix_arg#*|}"
            write_template_file "$path" "$value" || return 1
            ;;
          fix_remove_file)
            rm -f "$fix_arg" || return 1
            ;;
          fix_ssl_protocols)
            sed -i '/^[[:space:]]*Protocols[[:space:]]/d' "$fix_arg" || return 1
            sed -i 's|^[[:space:]]*Listen[[:space:]]\+443[[:space:]]\+https.*$|Listen 443 https\nProtocols h2 http/1.1|' "$fix_arg" || return 1
            grep -qE '^[[:space:]]*Protocols[[:space:]]+h2[[:space:]]+http/1\.1[[:space:]]*$' "$fix_arg" || return 1
            ;;
          fix_disable_file)
            if [[ -f "$fix_arg" ]]; then
              mv -f "$fix_arg" "${fix_arg}.old" || return 1
              log "Отключен $(highlight_path_file "$fix_arg") -> $(highlight_path_file "${fix_arg}.old")"
            fi
            ;;
          fix_pool_upload_tmp)
            path="${fix_arg%%|*}"
            value="${fix_arg#*|}"
            if [[ -s "$path" ]] && [[ "$(tail -c 1 "$path" | od -An -t u1 | tr -d ' ')" != "10" ]]; then
              echo >> "$path" || return 1
            fi
            echo "php_value[upload_tmp_dir] = /var/www/${value}/tmp" >> "$path" || return 1
            ;;
          fix_www_template)
            path="${fix_arg%%|*}"
            value="${fix_arg#*|}"
            write_www_conf "$path" "$value" || return 1
            ;;
          fix_hotlist)
            source "${SCRIPT_DIR}/create_hotlist.sh" || return 1
            create_hotlist || return 1
            ;;
          fix_php_fpm_restart_conf)
            write_php_fpm_restart_conf "$fix_arg" || return 1
            systemctl daemon-reload || return 1
            ;;
          fix_remove_php_fpm_restart_dir)
            rm -rf "$fix_arg" || return 1
            systemctl daemon-reload || return 1
            ;;
          *)
            ERRORS+=("Неизвестное исправление: ${fix_action}")
            return 1
            ;;
        esac
      then
        log "${GREEN}Исправлено:${WHITE} ${message}"
        changed=1
      else
        ERRORS+=("Не удалось исправить: ${message}")
        return 1
      fi
    else
      log "${YELLOW}Пропущено:${WHITE} ${message}"
    fi
  done

  if [[ "$changed" -eq 0 ]]; then
    for i in "${!ISSUE_MESSAGES[@]}"; do
      message="${ISSUE_MESSAGES[$i]}"
      fix_action="${ISSUE_FIXES[$i]}"
      if [[ -z "$fix_action" ]]; then
        log "${YELLOW}Нет автоматического исправления:${WHITE} ${message}"
      fi
    done
  fi

  [[ "$changed" -eq 1 ]]
}

run_fix() {
  local round=0

  while (( round < 3 )); do
    collect_issues
    if [[ "${#ERRORS[@]}" -gt 0 ]]; then
      print_final_report
      return 2
    fi

    if [[ "${#ISSUE_MESSAGES[@]}" -eq 0 ]]; then
      print_final_report
      return 0
    fi

    print_issues
    if ! apply_issues; then
      collect_issues
      print_final_report
      [[ "${#ERRORS[@]}" -gt 0 ]] && return 2
      [[ "${#ISSUE_MESSAGES[@]}" -eq 0 ]] && return 0
      return 1
    fi
    round=$((round + 1))
  done

  collect_issues
  print_final_report
  [[ "${#ERRORS[@]}" -gt 0 ]] && return 2
  [[ "${#ISSUE_MESSAGES[@]}" -eq 0 ]] && return 0
  return 1
}

case "${1:-}" in
  "")
    MODE="check"
    ;;
  silent)
    MODE="check"
    SILENT=1
    shift
    ;;
  fix)
    MODE="fix"
    shift
    if [[ "${1:-}" == "--yes" ]]; then
      ASSUME_YES=1
      shift
    fi
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ "$#" -gt 0 ]]; then
  usage
  exit 2
fi

if [[ "$MODE" == "fix" ]]; then
  run_fix
  exit $?
fi

collect_issues
print_final_report

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  exit 2
fi

if [[ "${#ISSUE_MESSAGES[@]}" -gt 0 ]]; then
  exit 1
fi

exit 0
