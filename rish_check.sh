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
source "${SCRIPT_DIR}/windows.sh"
source "${SCRIPT_DIR}/php_helpers.sh"
source "${SCRIPT_DIR}/scripts/ssh_authentication.sh"
source "${SCRIPT_DIR}/scripts/cron_access.sh"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
NOINDEX_TEMPLATE="${TEMPLATE_DIR}/apache-noindex.html"
DEFAULT_NOINDEX_TEMPLATE="${TEMPLATE_DIR}/default-apache-noindex.html"
WWW_TEMPLATE="${TEMPLATE_DIR}/php-fpm-www.conf.template"
DEFAULT_VHOST_TEMPLATE="${TEMPLATE_DIR}/000-default.conf"
DEFAULT_SSL_VHOST_TEMPLATE="${TEMPLATE_DIR}/000-default-ssl.conf"
HTTPD_TMPFILES_VENDOR="/usr/lib/tmpfiles.d/httpd.conf"
HTTPD_TMPFILES_OVERRIDE="/etc/tmpfiles.d/httpd.conf"
RISH_SELECTEL_CERT_SYNC_SERVICE="rish-selectel-certificates-sync.service"
RISH_SELECTEL_CERT_SYNC_TIMER="rish-selectel-certificates-sync.timer"
CERTBOT_RENEW_SERVICE="certbot-renew.service"
CERTBOT_RENEW_TIMER="certbot-renew.timer"

declare -a ISSUE_MESSAGES=()
declare -a ISSUE_FIXES=()
declare -a ISSUE_ARGS=()
declare -a ERRORS=()
declare -A REFERENCED_POOLS=()
declare -A REFERENCED_POOL_FILES=()
declare -A PHP_FPM_RESTART_REQUIRED=()
APACHE_RESTART_REQUIRED=0
KERNEL_REBOOT_REQUIRED=0

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

mark_apache_restart_required() {
  local fix_action="$1"
  local fix_arg="$2"
  local target_file

  case "$fix_action" in
    fix_template_file)
      target_file="${fix_arg#*|}"
      [[ "$target_file" == /etc/httpd/conf.d/* ]] && APACHE_RESTART_REQUIRED=1
      ;;
    fix_remove_file|fix_disable_file|fix_ssl_protocols)
      [[ "$fix_arg" == /etc/httpd/conf.d/* ]] && APACHE_RESTART_REQUIRED=1
      ;;
  esac
}

mark_php_fpm_restart_required() {
  local fix_action="$1"
  local fix_arg="$2"
  local target_file
  local php_version

  case "$fix_action" in
    fix_pool_upload_tmp)
      target_file="${fix_arg%%|*}"
      ;;
    fix_www_template)
      php_version="${fix_arg%%|*}"
      ;;
    fix_disable_file)
      target_file="$fix_arg"
      ;;
    fix_php_fpm_systemd_conf)
      php_version="$fix_arg"
      ;;
  esac

  if [[ -z "${php_version:-}" && -n "${target_file:-}" ]]; then
    php_version="$(echo "$target_file" | sed -n 's|^/etc/opt/remi/\(php[0-9][0-9]\)/php-fpm\.d/.*|\1|p')"
  fi

  if [[ "${php_version:-}" =~ ^php[0-9][0-9]$ ]]; then
    PHP_FPM_RESTART_REQUIRED["$php_version"]=1
  fi
}

rollback_php_fpm_check_change() {
  local php_version="$1"
  local restart_service="$2"

  if ! rollback_php_fpm_systemd_conf "$php_version"; then
    log "  ${RED}${php_version}-php-fpm${WHITE}: не удалось восстановить предыдущий local.conf"
    return 1
  fi
  if ! systemctl daemon-reload; then
    log "  ${RED}${php_version}-php-fpm${WHITE}: local.conf восстановлен, но systemd не перечитал конфигурацию"
    return 1
  fi

  if [[ "$restart_service" -eq 1 ]]; then
    if ! systemctl restart "${php_version}-php-fpm"; then
      log "  ${RED}${php_version}-php-fpm${WHITE}: не удалось запустить сервис после отката"
      return 1
    fi
    log "  ${YELLOW}${php_version}-php-fpm${WHITE}: предыдущая конфигурация восстановлена, сервис снова запущен"
  else
    log "  ${YELLOW}${php_version}-php-fpm${WHITE}: предыдущая конфигурация восстановлена"
  fi
}

rollback_pending_php_fpm_systemd_changes() {
  local php_version
  local status=0

  for php_version in "${!PHP_FPM_SYSTEMD_ROLLBACK_PREPARED[@]}"; do
    rollback_php_fpm_check_change "$php_version" 0 || status=1
  done
  return "$status"
}

restart_required_php_fpm() {
  local php_version
  local fpm_binary
  local output
  local status=0

  [[ "${#PHP_FPM_RESTART_REQUIRED[@]}" -gt 0 ]] || return 0
  [[ "$SILENT" -eq 1 ]] && return 0

  log
  log "${YELLOW}Изменены настройки PHP-FPM. ${WHITE}Перезапускаем затронутые версии PHP-FPM:"

  while IFS= read -r php_version; do
    [[ -n "$php_version" ]] || continue
    fpm_binary="/opt/remi/${php_version}/root/usr/sbin/php-fpm"

    if [[ ! -x "$fpm_binary" ]]; then
      log "  ${RED}${php_version}-php-fpm${WHITE}: не найден ${fpm_binary}"
      if php_fpm_systemd_rollback_is_prepared "$php_version"; then
        rollback_php_fpm_check_change "$php_version" 0 || status=1
      fi
      status=1
      continue
    fi

    output="$("$fpm_binary" -t 2>&1)"
    if [[ "$?" -ne 0 ]]; then
      log "  ${RED}${php_version}-php-fpm${WHITE}: ошибка конфигурации, сервис не перезапущен"
      printf '%s\n' "$output"
      if php_fpm_systemd_rollback_is_prepared "$php_version"; then
        rollback_php_fpm_check_change "$php_version" 0 || status=1
      fi
      status=1
      continue
    fi

    if systemctl restart "${php_version}-php-fpm"; then
      if commit_php_fpm_systemd_conf "$php_version"; then
        log "  ${GREEN}${php_version}-php-fpm${WHITE} перезапущен"
      else
        log "  ${YELLOW}${php_version}-php-fpm${WHITE}: сервис перезапущен, но временный rollback-файл не удалён"
        status=1
      fi
    else
      log "  ${RED}${php_version}-php-fpm${WHITE}: ошибка перезапуска"
      if php_fpm_systemd_rollback_is_prepared "$php_version"; then
        log "  Выполняем откат systemd-конфигурации ${YELLOW}${php_version}-php-fpm${WHITE}."
        rollback_php_fpm_check_change "$php_version" 1 || status=1
      fi
      status=1
    fi
  done < <(printf '%s\n' "${!PHP_FPM_RESTART_REQUIRED[@]}" | sort -r)

  return "$status"
}

reload_required_apache() {
  local choice

  [[ "$APACHE_RESTART_REQUIRED" -eq 1 ]] || return 0
  [[ "$SILENT" -eq 1 ]] && return 0

  log
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    log "${YELLOW}Изменены настройки Apache.${WHITE} Применяем изменения без остановки сайтов..."
  else
    echo
    echo -e "${YELLOW}Изменены настройки Apache.${WHITE}"
    echo "Apache может перечитать настройки без остановки сайтов."
    echo "Сделать это сейчас?"
    vertical_menu "current" 2 0 13 "Да" "Нет"
    choice=$?
    if [[ "$choice" -ne 0 ]]; then
      log "${YELLOW}Настройки Apache изменены, но пока не применены.${WHITE}"
      log "Их можно применить позже через меню ${CYAN}MC${WHITE}:"
      log "  Перезaпуск и стaтус серверa apache"
      return 0
    fi
  fi

  if systemctl reload httpd; then
    log "${GREEN}Apache перечитал настройки.${WHITE}"
    return 0
  fi

  log "${RED}Не удалось применить настройки Apache.${WHITE}"
  log "Проверьте статус Apache через меню ${CYAN}MC${WHITE}:"
  log "  Перезaпуск и стaтус серверa apache"
  return 1
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
  if [[ ! -f "$NOINDEX_TEMPLATE" ]]; then
    if [[ ! -f "$DEFAULT_NOINDEX_TEMPLATE" ]]; then
      ERRORS+=("Не найден шаблон ${DEFAULT_NOINDEX_TEMPLATE}. Переустановите RISH.")
    elif ! install -m 644 "$DEFAULT_NOINDEX_TEMPLATE" "$NOINDEX_TEMPLATE"; then
      ERRORS+=("Не удалось создать шаблон ${NOINDEX_TEMPLATE}. Проверьте права доступа и свободное место на диске.")
    fi
  fi

  [[ -f "$WWW_TEMPLATE" ]] || ERRORS+=("Не найден шаблон ${WWW_TEMPLATE}")
  [[ -f "$DEFAULT_VHOST_TEMPLATE" ]] || ERRORS+=("Не найден шаблон ${DEFAULT_VHOST_TEMPLATE}")
  [[ -f "$DEFAULT_SSL_VHOST_TEMPLATE" ]] || ERRORS+=("Не найден шаблон ${DEFAULT_SSL_VHOST_TEMPLATE}")

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

httpd_vendor_manages_var_www() {
  [[ -f "$HTTPD_TMPFILES_VENDOR" ]] || return 1
  awk '$1 == "d" && $2 == "/var/www" { found=1 } END { exit !found }' "$HTTPD_TMPFILES_VENDOR"
}

render_httpd_tmpfiles_override() {
  awk '$1 == "d" && $2 == "/var/www" { $3="751"; $4="root"; $5="root" } { print }' "$HTTPD_TMPFILES_VENDOR"
}

httpd_tmpfiles_override_matches() {
  [[ -f "$HTTPD_TMPFILES_OVERRIDE" ]] || return 1
  render_httpd_tmpfiles_override | cmp -s - "$HTTPD_TMPFILES_OVERRIDE"
}

write_httpd_tmpfiles_override() {
  local tmp_file="${HTTPD_TMPFILES_OVERRIDE}.rish-tmp.$$"

  if ! httpd_vendor_manages_var_www; then
    rm -f "$HTTPD_TMPFILES_OVERRIDE"
    return 0
  fi

  install -d -m 755 /etc/tmpfiles.d || return 1
  render_httpd_tmpfiles_override > "$tmp_file" || return 1
  install -m 644 "$tmp_file" "$HTTPD_TMPFILES_OVERRIDE" || return 1
  rm -f "$tmp_file"
  systemd-tmpfiles --create "$HTTPD_TMPFILES_OVERRIDE"
}

collect_referenced_pools() {
  local conf_file
  local socket_path
  local socket_rest
  local php_version
  local user_name

  shopt -s nullglob
  for conf_file in /etc/httpd/conf.d/*.conf; do
    [[ -f "$conf_file" ]] || continue
    [[ "${conf_file##*/}" =~ ^php[0-9][0-9]-php\.conf$ ]] && continue
    while IFS= read -r socket_path; do
      socket_rest="${socket_path#*/remi/}"
      php_version="${socket_rest%%/*}"
      user_name="${socket_path##*/}"
      user_name="${user_name%.sock}"
      [[ "$php_version" =~ ^php[0-9][0-9]$ && -n "$user_name" ]] || continue
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

check_httpd_tmpfiles_override() {
  if httpd_vendor_manages_var_www; then
    if ! httpd_tmpfiles_override_matches; then
      add_issue "$(highlight_path_file "$HTTPD_TMPFILES_OVERRIDE") не сохраняет права 751 для /var/www при обработке tmpfiles" "fix_httpd_tmpfiles_override" ""
    fi
  elif [[ -f "$HTTPD_TMPFILES_OVERRIDE" ]]; then
    add_issue "$(highlight_path_file "$HTTPD_TMPFILES_OVERRIDE") больше не требуется: пакет httpd не управляет /var/www через tmpfiles" "fix_httpd_tmpfiles_override" ""
  fi
}

check_cron_allow() {
  if ! cron_allow_is_secure; then
    add_issue "$(highlight_path_file "$RISH_CRON_ALLOW_FILE") должен разрешать управление пользовательским CRON только пользователю ${YELLOW}root${WHITE} и иметь права ${YELLOW}root:root${WHITE} 644" "fix_cron_allow" ""
  fi
}

check_legacy_backup_cron() {
  local cron_jobs

  cron_jobs="$(crontab -l 2>/dev/null || true)"
  if printf '%s\n' "$cron_jobs" | grep -Eq '^[[:space:]]*[^#].*/root/rish/backup\.sh([[:space:]]|$)'; then
    add_issue "В CRON пользователя ${YELLOW}root${WHITE} используется устаревший $(highlight_path_file "/root/rish/backup.sh"). Замените его вручную на $(highlight_path_file "/root/rish/backup2.sh") auto" "" ""
  fi
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
    add_issue "Открыт служебный URL /icons/ на всех сайтах в файле /etc/httpd/conf.d/autoindex.conf" "fix_remove_file" "/etc/httpd/conf.d/autoindex.conf"
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

      if [[ -z "${REFERENCED_POOLS[$key]:-}" ]]; then
        add_issue "Pool $(highlight_path_file "$pool_file") не используется ни одним Apache vhost" "fix_disable_file" "$pool_file"
        continue
      fi

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
    done
  done
  shopt -u nullglob
}

check_php_fpm_systemd_policy() {
  local installed_versions
  local php_version
  local conf_file
  local orphan_dir
  local found

  installed_versions="$(get_installed_php_versions)"

  while IFS= read -r php_version; do
    [[ -n "$php_version" ]] || continue
    conf_file="$(php_fpm_systemd_conf_path "$php_version")" || continue

    if [[ ! -f "$conf_file" ]]; then
      add_issue "Для ${YELLOW}${php_version}-php-fpm${WHITE} отсутствует защищенная systemd-настройка $(highlight_path_file "$conf_file")" "fix_php_fpm_systemd_conf" "$php_version"
    elif ! php_fpm_systemd_conf_matches "$php_version"; then
      add_issue "$(highlight_path_file "$conf_file") не соответствует настройкам автоперезапуска и защиты PHP-FPM" "fix_php_fpm_systemd_conf" "$php_version"
    elif ! php_fpm_systemd_security_is_effective "$php_version"; then
      add_issue "Для ${YELLOW}${php_version}-php-fpm${WHITE} systemd-защита записана, но фактически не загружена" "fix_php_fpm_systemd_conf" "$php_version"
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

check_hotlist() {
  local expected_hotlist
  local hotlist_file="${HOME}/.config/mc/hotlist"

  if [[ ! -f "$hotlist_file" ]]; then
    add_issue "Midnight Commander hotlist ${hotlist_file} отсутствует" "fix_hotlist" ""
    return
  fi

  expected_hotlist="$(mktemp)" || {
    ERRORS+=("Не удалось создать временный файл для проверки Midnight Commander hotlist")
    return
  }

  source "${SCRIPT_DIR}/create_hotlist.sh" || {
    rm -f "$expected_hotlist"
    ERRORS+=("Не удалось загрузить генератор Midnight Commander hotlist")
    return
  }

  if ! create_hotlist "$expected_hotlist"; then
    rm -f "$expected_hotlist"
    ERRORS+=("Не удалось сформировать ожидаемый Midnight Commander hotlist")
    return
  fi

  if ! cmp -s "$expected_hotlist" "$hotlist_file"; then
    add_issue "Midnight Commander hotlist не соответствует текущим настройкам сервера" "fix_hotlist" ""
  fi

  rm -f "$expected_hotlist"
}

check_apache_configtest() {
  local output
  local status

  if command -v apachectl >/dev/null 2>&1; then
    output="$(apachectl configtest 2>&1)"
    status=$?
    if [[ "$status" -eq 0 ]]; then
      log "Проверка конфигурации Apache: ${GREEN}ok${WHITE}"
    else
      log "Проверка конфигурации Apache: ${RED}ошибка${WHITE}"
      log
      printf '%s\n' "$output"
      log
      return 1
    fi
  fi
}

check_php_fpm_configtests() {
  local php_dir
  local php_version
  local fpm_binary
  local output
  local status=0

  shopt -s nullglob
  for php_dir in /etc/opt/remi/php[0-9][0-9]; do
    [[ -d "$php_dir" ]] || continue
    php_version="$(basename "$php_dir")"
    fpm_binary="/opt/remi/${php_version}/root/usr/sbin/php-fpm"
    [[ -x "$fpm_binary" ]] || continue
    output="$("$fpm_binary" -t 2>&1)"
    if [[ "$?" -eq 0 ]]; then
      log "Проверка конфигурации ${php_version}-php-fpm: ${GREEN}ok${WHITE}"
    else
      log "Проверка конфигурации ${php_version}-php-fpm: ${RED}ошибка${WHITE}"
      log
      printf '%s\n' "$output"
      log
      status=1
    fi
  done
  shopt -u nullglob
  return "$status"
}

print_ssh_password_auth_warning() {
  local sshd_config
  local option
  local value
  local password_authentication="no"
  local kbd_interactive_authentication="no"

  [[ "$SILENT" -eq 1 ]] && return

  if ! sshd_config="$(sshd -T 2>/dev/null)"; then
    return
  fi

  while read -r option value _; do
    case "$option" in
      passwordauthentication)
        password_authentication="$value"
        ;;
      kbdinteractiveauthentication)
        kbd_interactive_authentication="$value"
        ;;
    esac
  done <<< "$sshd_config"

  if [[ "$password_authentication" == "yes" || "$kbd_interactive_authentication" == "yes" ]]; then
    log
    log "В SSH ${YELLOW}способы аутентификации${WHITE} с вводом пароля ${YELLOW}разрешены${WHITE}."
    log "Это повышает риск подбора учетных данных и несанкционированного доступа."
    log "Рекомендуется использовать SSH-ключи и отключить PasswordAuthentication и KbdInteractiveAuthentication."
  fi
}

selectel_certificate_sites() {
  local site_name
  local vhost_file
  declare -A seen_sites=()

  for vhost_file in /etc/httpd/conf.d/*-selectel-ssl.conf; do
    [[ -f "$vhost_file" ]] || continue
    if grep -Fqx '# Managed by RISH Selectel certificate integration.' "$vhost_file" &&
      grep -Eq '^[[:space:]]*SSLCertificateFile[[:space:]]+/etc/pki/tls/rish/selectel/' "$vhost_file" &&
      grep -Eq '^[[:space:]]*SSLCertificateKeyFile[[:space:]]+/etc/pki/tls/rish/selectel/' "$vhost_file"; then
      site_name="$(awk 'tolower($1)=="servername" && NF>1 {print $2; exit}' "$vhost_file")"
      [[ -n "$site_name" ]] || site_name="${vhost_file##*/}"
      site_name="${site_name%-selectel-ssl.conf}"
      if [[ -z "${seen_sites[${site_name,,}]:-}" ]]; then
        printf '%s\n' "$site_name"
        seen_sites["${site_name,,}"]=1
      fi
    fi
  done
}

format_certificate_sites() {
  local limit=5
  local index
  local result=""
  local -a sites=("$@")

  for ((index = 0; index < ${#sites[@]} && index < limit; index++)); do
    [[ -z "$result" ]] || result+=", "
    result+="${sites[$index]}"
  done
  if ((${#sites[@]} > limit)); then
    result+=", и ещё $((${#sites[@]} - limit))"
  fi
  printf '%s' "$result"
}

print_selectel_certificate_sync_warning() {
  local followup_message=""
  local sites_text
  local -a selectel_sites=()

  [[ "$SILENT" -eq 1 ]] && return
  mapfile -t selectel_sites < <(selectel_certificate_sites)
  ((${#selectel_sites[@]} > 0)) || return

  if command -v systemctl >/dev/null 2>&1 &&
    systemctl is-enabled --quiet "$RISH_SELECTEL_CERT_SYNC_TIMER" 2>/dev/null &&
    systemctl is-active --quiet "$RISH_SELECTEL_CERT_SYNC_TIMER" 2>/dev/null &&
    ! systemctl is-failed --quiet "$RISH_SELECTEL_CERT_SYNC_SERVICE" 2>/dev/null; then
    return
  fi

  log
  if command -v systemctl >/dev/null 2>&1 &&
    systemctl is-failed --quiet "$RISH_SELECTEL_CERT_SYNC_SERVICE" 2>/dev/null; then
    log "Последняя автоматическая синхронизация сертификатов Selectel ${YELLOW}завершилась ошибкой${WHITE}."
    followup_message="Подробности: journalctl -u ${RISH_SELECTEL_CERT_SYNC_SERVICE}"
  elif command -v systemctl >/dev/null 2>&1 &&
    systemctl is-enabled --quiet "$RISH_SELECTEL_CERT_SYNC_TIMER" 2>/dev/null; then
    log "Автоматическая синхронизация сертификатов Selectel ${YELLOW}включена, но timer не активен${WHITE}."
  else
    log "Для установленных сертификатов Selectel автоматическая синхронизация ${YELLOW}не включена${WHITE}."
    followup_message="Синхронизацию можно включить в основном меню сертификатов любого сайта."
  fi
  sites_text="$(format_certificate_sites "${selectel_sites[@]}")"
  log "SSL-конфигурации Selectel найдены для: ${YELLOW}${sites_text}${WHITE}."
  log "Новые версии сертификатов не будут загружаться автоматически."
  [[ -z "$followup_message" ]] || log "$followup_message"
}

certbot_certificate_sites() {
  local site_name
  local vhost_file
  local fullchain_file
  local private_key_file
  local lineage_dir
  declare -A seen_sites=()

  for vhost_file in /etc/httpd/conf.d/*.conf; do
    [[ -f "$vhost_file" ]] || continue
    fullchain_file="$(awk 'tolower($1)=="sslcertificatefile" && NF>1 {print $2; exit}' "$vhost_file")"
    private_key_file="$(awk 'tolower($1)=="sslcertificatekeyfile" && NF>1 {print $2; exit}' "$vhost_file")"
    [[ "$fullchain_file" == /etc/letsencrypt/live/*/fullchain.pem ]] || continue
    lineage_dir="${fullchain_file%/fullchain.pem}"
    [[ "$private_key_file" == "${lineage_dir}/privkey.pem" ]] || continue

    site_name="$(awk 'tolower($1)=="servername" && NF>1 {print $2; exit}' "$vhost_file")"
    [[ -n "$site_name" ]] || site_name="${vhost_file##*/}"
    site_name="${site_name%.conf}"
    if [[ -z "${seen_sites[${site_name,,}]:-}" ]]; then
      printf '%s\n' "$site_name"
      seen_sites["${site_name,,}"]=1
    fi
  done
}

print_certbot_certificate_renewal_warning() {
  local followup_message=""
  local sites_text
  local -a certbot_sites=()

  [[ "$SILENT" -eq 1 ]] && return
  mapfile -t certbot_sites < <(certbot_certificate_sites)
  ((${#certbot_sites[@]} > 0)) || return

  if command -v certbot >/dev/null 2>&1 &&
    command -v systemctl >/dev/null 2>&1 &&
    systemctl cat "$CERTBOT_RENEW_TIMER" >/dev/null 2>&1 &&
    systemctl is-enabled --quiet "$CERTBOT_RENEW_TIMER" 2>/dev/null &&
    systemctl is-active --quiet "$CERTBOT_RENEW_TIMER" 2>/dev/null &&
    ! systemctl is-failed --quiet "$CERTBOT_RENEW_SERVICE" 2>/dev/null; then
    return
  fi

  log
  if ! command -v certbot >/dev/null 2>&1; then
    log "Для установленных сертификатов Let’s Encrypt команда ${YELLOW}certbot не найдена${WHITE}."
  elif ! command -v systemctl >/dev/null 2>&1; then
    log "Не удалось проверить автоматическое обновление Certbot: команда ${YELLOW}systemctl не найдена${WHITE}."
  elif ! systemctl cat "$CERTBOT_RENEW_TIMER" >/dev/null 2>&1; then
    log "Для установленных сертификатов Let’s Encrypt timer ${YELLOW}${CERTBOT_RENEW_TIMER} не найден${WHITE}."
  elif systemctl is-failed --quiet "$CERTBOT_RENEW_SERVICE" 2>/dev/null; then
    log "Последнее автоматическое обновление сертификатов Certbot ${YELLOW}завершилось ошибкой${WHITE}."
    followup_message="Подробности: journalctl -u ${CERTBOT_RENEW_SERVICE}"
  elif systemctl is-enabled --quiet "$CERTBOT_RENEW_TIMER" 2>/dev/null; then
    log "Автоматическое обновление сертификатов Certbot ${YELLOW}включено, но timer не активен${WHITE}."
  else
    log "Для установленных сертификатов Certbot автоматическое обновление ${YELLOW}не включено${WHITE}."
    followup_message="Включить timer: systemctl enable --now ${CERTBOT_RENEW_TIMER}"
  fi
  sites_text="$(format_certificate_sites "${certbot_sites[@]}")"
  log "SSL-конфигурации Certbot найдены для: ${YELLOW}${sites_text}${WHITE}."
  log "Автоматическое обновление этих сертификатов требует внимания."
  [[ -z "$followup_message" ]] || log "$followup_message"
}

check_sftp_security() {
  local effective_settings
  local password_authentication
  local user
  local issue_found=0

  effective_settings="$(get_effective_ssh_authentication)" || effective_settings=""
  read -r password_authentication _ <<<"$effective_settings"
  if [[ "$password_authentication" != "yes" && "$password_authentication" != "no" ]]; then
    add_issue "Не удалось определить фактические настройки SSH/SFTP через sshd -T" "" ""
    return
  fi

  rish_ssh_config_matches "$password_authentication" || issue_found=1
  sftp_authorized_keys_are_secure || issue_found=1
  legacy_rish_sftp_match_is_at_end && issue_found=1

  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    if ! sftp_security_is_effective "$user"; then
      issue_found=1
      break
    fi
  done < <(get_sftp_users)

  if [[ "$issue_found" -eq 1 ]]; then
    add_issue "Ограничения SFTP или каталог $(highlight_path_file "${RISH_SFTP_AUTHORIZED_KEYS_DIR}") не соответствуют настройкам RISH" "fix_sftp_security" "$password_authentication"
  fi
}

print_kernel_default_fix_hint() {
  local latest_kernel_path="$1"

  log
  log "${YELLOW}Чтобы загрузиться с последним установленным ядром:${WHITE}"
  log "  ${YELLOW}grubby --set-default ${latest_kernel_path}${WHITE}"
  log "  ${YELLOW}reboot${WHITE}"
  log
  log "После перезагрузки проверьте версию ядра:"
  log "  ${YELLOW}uname -r${WHITE}"
}

print_kernel_saved_entry_fix_hint() {
  local latest_kernel_id="$1"

  log
  log "${YELLOW}Чтобы GRUB загрузил уже выбранное последнее ядро:${WHITE}"
  log "  ${YELLOW}grub2-set-default '${latest_kernel_id}'${WHITE}"
  log "  ${YELLOW}reboot${WHITE}"
  log
  log "После перезагрузки проверьте версию ядра:"
  log "  ${YELLOW}uname -r${WHITE}"
}

ensure_kernel_saved_entry() {
  local latest_kernel="$1"
  local latest_kernel_path="$2"
  local latest_kernel_id
  local saved_entry
  local grub_default
  local choice

  if ! command -v grub2-editenv >/dev/null 2>&1 || ! command -v grub2-set-default >/dev/null 2>&1; then
    log
    log "${GREEN}Последнее ядро уже выбрано для следующей загрузки.${WHITE}"
    log "Осталось перезагрузить сервер вручную:"
    log "  ${YELLOW}reboot${WHITE}"
    return 0
  fi

  grub_default="$(awk -F= '{key=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)} key == "GRUB_DEFAULT" {value=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); gsub(/^"|"$/, "", value); print value; exit}' /etc/default/grub 2>/dev/null)"
  if [[ "$grub_default" != "saved" ]]; then
    log
    log "${GREEN}Последнее ядро уже выбрано для следующей загрузки.${WHITE}"
    log "Осталось перезагрузить сервер вручную:"
    log "  ${YELLOW}reboot${WHITE}"
    return 0
  fi

  latest_kernel_id="$(grubby --info="$latest_kernel_path" 2>/dev/null | awk -F= '$1 == "id" {gsub(/^"|"$/, "", $2); print $2; exit}')"
  saved_entry="$(grub2-editenv list 2>/dev/null | awk -F= '$1 == "saved_entry" {print $2; exit}')"

  if [[ -z "$latest_kernel_id" || "$saved_entry" == "$latest_kernel_id" ]]; then
    log
    log "${GREEN}Последнее ядро уже выбрано для следующей загрузки.${WHITE}"
    log "Осталось перезагрузить сервер вручную:"
    log "  ${YELLOW}reboot${WHITE}"
    return 0
  fi

  if [[ "$MODE" != "fix" ]]; then
    log
    log "${YELLOW}Последнее ядро выбрано через grubby, но GRUB saved_entry указывает не на него.${WHITE}"
    print_kernel_saved_entry_fix_hint "$latest_kernel_id"
    return 0
  fi

  if [[ "$ASSUME_YES" -ne 1 ]]; then
    echo
    echo -e "Сохранить в GRUB загрузку последнего ядра ${YELLOW}${latest_kernel}${WHITE}?"
    echo "Будет выполнено:"
    echo -e "  ${YELLOW}grub2-set-default '${latest_kernel_id}'${WHITE}"
    echo
    echo "Перезагрузку нужно будет сделать вручную."
    vertical_menu "current" 2 0 13 "Да" "Нет"
    choice=$?
    if [[ "$choice" -ne 0 ]]; then
      log "${YELLOW}Сохранение GRUB saved_entry пропущено.${WHITE}"
      print_kernel_saved_entry_fix_hint "$latest_kernel_id"
      return 1
    fi
  fi

  if grub2-set-default "$latest_kernel_id"; then
    log "${GREEN}GRUB saved_entry обновлен на последнее ядро.${WHITE}"
    log "Теперь перезагрузите сервер вручную:"
    log "  reboot"
    return 0
  fi

  log "${RED}Не удалось обновить GRUB saved_entry.${WHITE}"
  print_kernel_saved_entry_fix_hint "$latest_kernel_id"
  return 1
}

fix_kernel_default() {
  local latest_kernel="$1"
  local latest_kernel_path="$2"
  local current_default_kernel
  local choice

  if [[ ! -f "$latest_kernel_path" ]]; then
    log
    log "Файл ядра не найден: ${YELLOW}${latest_kernel_path}${WHITE}"
    log "Проверьте установленные ядра:"
    log "  rpm -q kernel-core"
    log "  ls -1 /boot/vmlinuz-*"
    return 1
  fi

  if ! command -v grubby >/dev/null 2>&1; then
    log
    log "${YELLOW}grubby не найден${WHITE}, автоматическое исправление невозможно."
    print_kernel_default_fix_hint "$latest_kernel_path"
    return 1
  fi

  current_default_kernel="$(grubby --default-kernel 2>/dev/null)"
  if [[ "$current_default_kernel" == "$latest_kernel_path" ]]; then
    ensure_kernel_saved_entry "$latest_kernel" "$latest_kernel_path"
    return $?
  fi

  if [[ "$MODE" != "fix" ]]; then
    print_kernel_default_fix_hint "$latest_kernel_path"
    return 0
  fi

  if [[ "$ASSUME_YES" -ne 1 ]]; then
    echo
    echo -e "Сделать последнее установленное ядро ${YELLOW}${latest_kernel}${WHITE} загрузочным по умолчанию?"
    echo "Будет выполнено:"
    echo -e "  ${YELLOW}grubby --set-default ${latest_kernel_path}${WHITE}"
    echo
    echo "Перезагрузку нужно будет сделать вручную."
    vertical_menu "current" 2 0 13 "Да" "Нет"
    choice=$?
    if [[ "$choice" -ne 0 ]]; then
      log "${YELLOW}Выбор ядра пропущен.${WHITE}"
      print_kernel_default_fix_hint "$latest_kernel_path"
      return 1
    fi
  fi

  if grubby --set-default "$latest_kernel_path"; then
    ensure_kernel_saved_entry "$latest_kernel" "$latest_kernel_path"
    return $?
  fi

  log "${RED}Не удалось выбрать ядро для следующей загрузки.${WHITE}"
  print_kernel_default_fix_hint "$latest_kernel_path"
  return 1
}

check_reboot_required() {
  local reboot_status
  local current_kernel
  local latest_kernel
  local latest_kernel_path

  if command -v rpm >/dev/null 2>&1; then
    printf 'Проверка загруженного ядра: '
    current_kernel="$(uname -r 2>/dev/null)"
    latest_kernel="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -n 1)"
    latest_kernel_path="/boot/vmlinuz-${latest_kernel}"

    if [[ -n "$current_kernel" && -n "$latest_kernel" ]]; then
      if [[ "$current_kernel" == "$latest_kernel" ]]; then
        printf '%b\n' "${GREEN}ok${WHITE} (используется последнее установленное ${YELLOW}${current_kernel}${WHITE})"
      else
        printf '%b\n' "текущее ${YELLOW}${current_kernel}${WHITE}, последнее установленное ${YELLOW}${latest_kernel}${WHITE}"
        KERNEL_REBOOT_REQUIRED=1
        fix_kernel_default "$latest_kernel" "$latest_kernel_path"
      fi
    else
      printf '%b\n' "${YELLOW}не удалось определить${WHITE}"
    fi
  fi

  if [[ "$KERNEL_REBOOT_REQUIRED" -eq 1 ]]; then
    printf 'Проверка необходимости перезагрузки: '
    printf '%b\n' "${YELLOW}требуется перезагрузка для загрузки последнего ядра${WHITE}"
    return 0
  fi

  if command -v needs-restarting >/dev/null 2>&1; then
    printf 'Проверка необходимости перезагрузки: '
    needs-restarting -r >/dev/null 2>&1
    reboot_status=$?

    case "$reboot_status" in
      0)
        printf '%b\n' "${GREEN}ok${WHITE} (перезагрузка не требуется)"
        ;;
      1)
        printf '%b\n' "${YELLOW}требуется перезагрузка${WHITE}"
        ;;
      *)
        printf '%b\n' "${YELLOW}не удалось выполнить needs-restarting -r${WHITE}"
        ;;
    esac
  else
    printf '%b\n' "Проверка необходимости перезагрузки: ${YELLOW}needs-restarting не найден${WHITE}"
  fi
}

collect_issues() {
  reset_state
  check_prerequisites
  [[ "${#ERRORS[@]}" -gt 0 ]] && return

  collect_referenced_pools
  check_httpd_tmpfiles_override
  check_cron_allow
  check_legacy_backup_cron
  check_sftp_security
  check_var_www
  check_noindex
  check_apache_conf_files
  check_apache_ssl_conf
  check_vhost_handlers
  check_php_fpm
  check_php_fpm_systemd_policy
  check_hotlist
}

run_final_configtests() {
  local status=0

  [[ "$SILENT" -eq 1 ]] && return

  print_ssh_password_auth_warning
  print_selectel_certificate_sync_warning
  print_certbot_certificate_renewal_warning
  log
  check_apache_configtest || status=1
  check_php_fpm_configtests || status=1
  check_reboot_required
  return "$status"
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
  local disabled_file
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
          fix_httpd_tmpfiles_override)
            write_httpd_tmpfiles_override || return 1
            ;;
          fix_cron_allow)
            configure_cron_allow || return 1
            ;;
          fix_sftp_security)
            configure_ssh_password_authentication "$fix_arg" || return 1
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
              disabled_file="${fix_arg}.bak"
              if [[ "${fix_arg##*/}" == "www.conf" ]]; then
                disabled_file="${fix_arg}.old"
              fi
              mv -f "$fix_arg" "$disabled_file" || return 1
              log "Отключен $(highlight_path_file "$fix_arg") -> $(highlight_path_file "$disabled_file")"
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
          fix_php_fpm_systemd_conf)
            write_php_fpm_systemd_conf "$fix_arg" || return 1
            if ! systemctl daemon-reload; then
              rollback_php_fpm_systemd_conf "$fix_arg" || true
              systemctl daemon-reload || true
              return 1
            fi
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
        mark_apache_restart_required "$fix_action" "$fix_arg"
        mark_php_fpm_restart_required "$fix_action" "$fix_arg"
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
  status=$?
  if run_final_configtests; then
    restart_required_php_fpm || status=1
    reload_required_apache || status=1
  else
    rollback_pending_php_fpm_systemd_changes || status=1
    status=1
  fi
  exit $status
fi

collect_issues
print_final_report
configtest_status=0
run_final_configtests || configtest_status=1

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
  exit 2
fi

if [[ "${#ISSUE_MESSAGES[@]}" -gt 0 ]]; then
  exit 1
fi

if [[ "$configtest_status" -ne 0 ]]; then
  exit 1
fi

exit 0
