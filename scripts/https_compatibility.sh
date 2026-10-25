#!/usr/bin/env bash

# Sourcing this module only defines functions. Direct execution opens the HTTPS menu.
rish_https_paths() {
  if [[ "${RISH_HTTPS_TEST_MODE:-0}" == 1 ]]; then
    RISH_HTTPS_CONFIG_DIR="${RISH_HTTPS_CONF_DIR:?test configuration directory required}"
    RISH_HTTPS_WEB_ROOT="${RISH_HTTPS_WWW_DIR:?test web root directory required}"
    RISH_HTTPS_LOCK="${RISH_HTTPS_LOCK_FILE:-${RISH_HTTPS_CONFIG_DIR}/.https.lock}"
  else
    RISH_HTTPS_CONFIG_DIR=/etc/httpd/conf.d
    RISH_HTTPS_WEB_ROOT=/var/www
    RISH_HTTPS_LOCK=/run/lock/rish-https-compatibility.lock
  fi
}

rish_https_file_safe() {
  local file="$1" prefix
  if [[ -L "$file" || ! -f "$file" || "$file" == *$'\t'* || "$file" == *$'\n'* || "$file" == *$'\r'* ]]; then
    echo "Нужен обычный файл конфигурации без символической ссылки: ${file}" >&2
    return 1
  fi
  if [[ "$(stat -c %h -- "$file")" != 1 ]]; then
    echo "Файл имеет жёсткие ссылки: ${file}" >&2
    return 1
  fi
  prefix=$(head -c 3 -- "$file" | od -An -tx1 | tr -d ' \n')
  if [[ "$prefix" == efbbbf ]] || ! (set -o pipefail; iconv -f UTF-8 -t UTF-8 "$file" | cat >/dev/null); then
    echo "Требуется UTF-8 без BOM: ${file}" >&2
    return 1
  fi
  # Both commands only read the configuration.
  # shellcheck disable=SC2094
  if ! tr -d '\000' <"$file" | cmp -s -- "$file" -; then
    echo "В конфигурации обнаружены нулевые байты: ${file}" >&2
    return 1
  fi
}

rish_https_parse() {
  local action="$1" file="$2" mode="$3" scope="$4" targets="$5" site_name="$6" terminated=0
  [[ "$(tail -c 1 -- "$file" | od -An -tx1 | tr -d ' \n')" != 0a ]] || terminated=1
  awk -v action="$action" -v mode="$mode" -v scope="$scope" -v targets="$targets" \
    -v site_name="$site_name" -v terminated="$terminated" '
    function trim(value) {
      sub(/^[ \t\r]+/, "", value)
      sub(/[ \t\r]+$/, "", value)
      return value
    }
    function fail(message) {
      print "Ошибка HTTPS: " message " (" FILENAME ":" NR ")" > "/dev/stderr"
      failed = 1
      exit 1
    }
    BEGIN {
      begin_marker = "# BEGIN RISH HTTPS compatibility"
      end_marker = "# END RISH HTTPS compatibility"
      policy = "SSLProtocol -all +TLSv1.2"
    }
    {
      lines[NR] = $0
      text = trim($0)
      if (text == begin_marker) {
        if (!inside || marker) fail("повреждён блок RISH")
        marker = NR
      } else if (text == end_marker) {
        if (!marker || NR != marker + 2 || trim(lines[marker + 1]) != policy)
          fail("повреждён блок RISH")
        for (i = marker; i <= NR; i++) managed[i] = 1
        host_managed = 1
        marker = 0
      }
      if (text == "" || text ~ /^#/) next
      clean = text
      sub(/[ \t]+#.*/, "", clean)
      lower = tolower(clean)
      if (lower ~ /^<virtualhost[ \t]+[^>]+>$/) {
        if (inside) fail("вложенный VirtualHost")
        inside = 1
        start = NR
        name = ""
        aliases = ""
        ssl = (lower ~ /:443([ \t]|>)/)
        custom = 0
        host_managed = 0
      } else if (lower == "</virtualhost>") {
        if (!inside || marker) fail("непарный VirtualHost или блок RISH")
        if (host_managed && !ssl) fail("блок RISH вне HTTPS VirtualHost")
        host_count++
        key = name == "" ? "@" FILENAME ":" start : name
        if (key == "all" || key ~ /[ \t\r\n]/) fail("неоднозначное имя сайта")
        eligible = ssl && name != "" && tolower(name) == tolower(site_name)
        if (eligible && action == "inventory") {
          names = key (aliases == "" ? "" : ", " aliases)
          state = host_managed ? "совместимость RISH" : (custom ? "свой SSLProtocol" : "штатные настройки")
          printf "%s\t%s\t%s\n", key, names, state
        }
        if (eligible && action == "render" && (scope == "all" || tolower(scope) == tolower(key))) {
          printf "%s\t%d\n", FILENAME, start >> targets
          for (i = start; i < NR; i++) if (managed[i]) skip[i] = 1
          if (mode == "compatibility") insert[NR] = 1
        }
        inside = 0
      } else if (lower ~ /^<\/?virtualhost([ \t>]|$)/) {
        fail("неподдерживаемая запись VirtualHost")
      } else if (inside) {
        count = split(clean, fields, /[ \t]+/)
        directive = tolower(fields[1])
        if (directive == "servername") {
          if (count != 2) fail("неподдерживаемая запись ServerName")
          value = fields[2]
          gsub(/^"|"$/, "", value)
          if (name != "" && name != value) fail("несколько ServerName в VirtualHost")
          name = value
        } else if (directive == "serveralias") {
          for (i = 2; i <= count; i++) aliases = aliases (aliases == "" ? "" : ", ") fields[i]
        } else if (directive == "sslengine" && tolower(fields[2]) == "on") {
          ssl = 1
        } else if (directive == "sslprotocol" && !marker) {
          custom = 1
        }
      }
    }
    END {
      if (failed) exit 1
      if (inside || marker) {
        print "Ошибка HTTPS: незакрытый VirtualHost или блок RISH (" FILENAME ")" > "/dev/stderr"
        exit 1
      }
      if (action != "render") exit
      for (i = 1; i <= NR; i++) {
        if (insert[i]) {
          cr = lines[i] ~ /\r$/ ? "\r" : ""
          printf "%s%s\n%s%s\n%s%s\n", begin_marker, cr, policy, cr, end_marker, cr
        }
        if (!skip[i]) {
          printf "%s", lines[i]
          if (i < NR || terminated) printf "\n"
        }
      }
    }
  ' "$file"
}

rish_https_config_tool() {
  local action="$1" directory="$2" mode="${3:-}" scope="${4:-}" workdir="${5:-}"
  local web_root="${6:-/var/www}" site_directory site_name suffix
  local file backup index=0 command_name
  local -A site_files=()
  for command_name in awk iconv stat; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "Не найдена команда: ${command_name}" >&2
      return 1
    }
  done
  [[ -d "$directory" ]] || { echo "Каталог конфигураций не найден: ${directory}" >&2; return 1; }
  if [[ "$action" == plan ]]; then
    : >"${workdir}/manifest" || return 1
    : >"${workdir}/targets" || return 1
  elif [[ "$action" != inventory ]]; then
    return 1
  fi
  # Use the same directory-backed site list for display and every change scope.
  for site_directory in "$web_root"/*/www/*; do
    [[ -d "$site_directory" ]] || continue
    site_name="${site_directory##*/}"
    [[ "$site_name" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || continue
    for suffix in .conf -ssl.conf -le-ssl.conf -selectel-ssl.conf; do
      site_files["${directory}/${site_name}${suffix}"]="$site_name"
    done
  done
  for file in "$directory"/*.conf; do
    [[ -e "$file" || -L "$file" ]] || continue
    site_name="${site_files[$file]:-}"
    [[ -n "$site_name" ]] || continue
    rish_https_file_safe "$file" || return 1
    if [[ "$action" == inventory ]]; then
      rish_https_parse inventory "$file" "" "" "" "$site_name" || return 1
      continue
    fi
    cp -a -- "$file" "${workdir}/original.${index}" || return 1
    rish_https_parse render "$file" "$mode" "$scope" "${workdir}/targets" "$site_name" \
      >"${workdir}/rendered.${index}" || return 1
    if cmp -s -- "${workdir}/original.${index}" "${workdir}/rendered.${index}"; then
      continue
    fi
    backup="${file}.bak"
    if [[ -e "$backup" || -L "$backup" ]]; then
      if [[ -L "$backup" || ! -f "$backup" || "$(stat -c %h -- "$backup")" != 1 ]]; then
        echo "Небезопасная резервная копия: ${backup}" >&2
        return 1
      fi
    fi
    printf '%s\t%s\n' "$index" "$file" >>"${workdir}/manifest" || return 1
    index=$((index + 1))
  done
  if [[ "$action" == plan && ! -s "${workdir}/targets" ]]; then
    echo "Подходящие HTTPS-сайты не найдены." >&2
    return 1
  fi
}

rish_https_inventory() {
  rish_https_paths
  rish_https_config_tool inventory "$RISH_HTTPS_CONFIG_DIR" "" "" "" "$RISH_HTTPS_WEB_ROOT"
}

rish_https_versions_supported() {
  local mode="${1:-compatibility}"
  local apache_version openssl_version major minor patch apache_supported=0
  local package_info package_version package_release
  # Service vhosts stay unchanged, including when all directory-backed sites are selected.
  [[ "$mode" != standard ]] || return 0
  apache_version=$(httpd -v) || return 1
  openssl_version=$(openssl version) || return 1
  if [[ "$apache_version" =~ Apache/([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
    if ((major > 2 || (major == 2 && (minor > 4 || (minor == 4 && patch >= 42))))); then
      apache_supported=1
    elif ((major == 2 && minor == 4 && patch == 37)) && command -v rpm >/dev/null 2>&1; then
      # EL8 backports per-vhost SSLProtocol in RHSA-2021:4257 (mod_ssl 2.4.37-41).
      if package_info=$(rpm -q --qf '%{VERSION} %{RELEASE}\n' mod_ssl 2>/dev/null); then
        read -r package_version package_release <<<"$package_info"
        if [[ "$package_version" == 2.4.37 && "$package_release" =~ [._+]el8([._+]|$) &&
              "$package_release" =~ ^([0-9]+)\. ]]; then
          if ((10#${BASH_REMATCH[1]} >= 41)); then
            apache_supported=1
          fi
        fi
      fi
    fi
  fi
  if ((apache_supported == 1)) && [[ "$openssl_version" =~ OpenSSL\ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}"
    if ((major > 1 || (major == 1 && (minor > 1 || (minor == 1 && patch >= 1))))); then
      return 0
    fi
  fi
  echo "Для режима совместимости нужны Apache 2.4.42+ или EL8 mod_ssl 2.4.37-41+ и OpenSSL 1.1.1+." >&2
  echo "Обновите штатные пакеты сервера." >&2
  return 1
}

rish_https_check_base_vhost() {
  local targets="$1" dump line base_file base_line file opening_line
  dump=$(httpd -t -D DUMP_VHOSTS 2>&1) || { printf '%s\n' "$dump" >&2; return 1; }
  while IFS= read -r line; do
    if [[ "$line" =~ default\ server.*\ \((.*):([0-9]+)\) ]]; then
      base_file="${BASH_REMATCH[1]}" base_line="${BASH_REMATCH[2]}"
      while IFS=$'\t' read -r file opening_line; do
        if [[ "$file" -ef "$base_file" && "$opening_line" == "$base_line" ]]; then
          echo "Этот сайт — базовый HTTPS-хост. Изменение может повлиять на другие HTTPS-блоки." >&2
          echo "Режим HTTPS не изменён." >&2
          return 1
        fi
      done <"$targets"
    fi
  done <<<"$dump"
}

rish_https_apply() (
  local mode="${1:-}" scope="${2:-}" command_name workdir lock_fd
  local index file backup current_index rollback_failed=0 changed=0
  local -a files=() previous_backups=() touched=()
  [[ "$mode" == compatibility || "$mode" == standard ]] && [[ -n "$scope" ]] || return 1
  if [[ "${RISH_HTTPS_TEST_MODE:-0}" != 1 && "$EUID" != 0 ]]; then
    echo "Изменять режим HTTPS может только root." >&2
    return 1
  fi
  for command_name in awk iconv stat flock apachectl systemctl httpd openssl; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "Не найдена команда: ${command_name}" >&2
      return 1
    }
  done
  rish_https_paths
  exec {lock_fd}>"$RISH_HTTPS_LOCK" || return 1
  if ! flock -n "$lock_fd"; then
    echo "Сейчас уже выполняется изменение режима HTTPS." >&2
    return 1
  fi
  if ! systemctl is-active --quiet httpd; then
    echo "Apache не запущен. Сначала запустите его; режим HTTPS не изменён." >&2
    return 1
  fi
  rish_https_versions_supported "$mode" || return 1
  apachectl configtest || return 1
  workdir=$(mktemp -d "${RISH_HTTPS_CONFIG_DIR}/.rish-https.XXXXXX") || return 1

  # Invoked by the EXIT trap, including interrupted transactions.
  # shellcheck disable=SC2329
  rish_https_cleanup() {
    local result=$? restore_index restore_file
    trap - EXIT INT TERM HUP
    if ((changed == 1)); then
      for restore_index in "${touched[@]}"; do
        restore_file="${files[$restore_index]}"
        if ! cp -a -- "${workdir}/snapshot.${restore_index}" "$restore_file"; then
          rollback_failed=1
        fi
        if [[ "${previous_backups[$restore_index]}" == 1 ]]; then
          cp -a -- "${workdir}/backup.${restore_index}" "${restore_file}.bak" || rollback_failed=1
        else
          rm -f -- "${restore_file}.bak" || rollback_failed=1
        fi
      done
      if ((rollback_failed == 0)); then
        if ! apachectl configtest; then
          rollback_failed=1
        elif systemctl is-active --quiet httpd; then
          systemctl reload httpd || rollback_failed=1
        else
          echo "Apache остаётся остановленным; автоматический запуск не выполняется." >&2
        fi
      fi
      if ((rollback_failed == 1)); then
        echo "Не удалось полностью восстановить конфигурацию Apache. Копии сохранены: ${workdir}" >&2
        return 1
      fi
      echo "Исходные конфигурации и резервные копии восстановлены." >&2
    fi
    rm -rf -- "$workdir"
    return "$result"
  }
  trap rish_https_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  rish_https_config_tool plan "$RISH_HTTPS_CONFIG_DIR" "$mode" "$scope" "$workdir" "$RISH_HTTPS_WEB_ROOT" || return 1
  if [[ ! -s "${workdir}/manifest" ]]; then
    echo "Выбранный режим уже применён. Конфигурации и .bak не изменены."
    return 0
  fi
  rish_https_check_base_vhost "${workdir}/targets" || return 1
  while IFS=$'\t' read -r index file; do
    backup="${file}.bak"
    if [[ -L "$file" || ! -f "$file" || -L "$backup" || ( -e "$backup" && ! -f "$backup" ) ]] ||
       ! cmp -s -- "$file" "${workdir}/original.${index}"; then
      echo "Конфигурация изменилась во время подготовки: ${file}" >&2
      return 1
    fi
    cp -a -- "$file" "${workdir}/snapshot.${index}" || return 1
    cp -a -- "$file" "${workdir}/candidate.${index}" || return 1
    cat "${workdir}/rendered.${index}" >"${workdir}/candidate.${index}" || return 1
    if [[ -e "$backup" ]]; then
      cp -a -- "$backup" "${workdir}/backup.${index}" || return 1
      previous_backups+=(1)
    else
      previous_backups+=(0)
    fi
    files+=("$file")
  done <"${workdir}/manifest"

  # Recheck the whole batch before changing the first file.
  for current_index in "${!files[@]}"; do
    file="${files[$current_index]}"
    if [[ -L "$file" || -L "${file}.bak" ]] || ! cmp -s -- "$file" "${workdir}/snapshot.${current_index}"; then
      echo "Конфигурация изменилась во время подготовки: ${file}" >&2
      return 1
    fi
  done
  for current_index in "${!files[@]}"; do
    file="${files[$current_index]}"
    if [[ -L "$file" || -L "${file}.bak" || ( -e "${file}.bak" && ! -f "${file}.bak" ) ]] ||
       [[ "$(stat -c %h -- "$file")" != 1 ]] ||
       ! cmp -s -- "$file" "${workdir}/snapshot.${current_index}"; then
      echo "Конфигурация изменилась перед записью: ${file}" >&2
      return 1
    fi
    if [[ -e "${file}.bak" && "$(stat -c %h -- "${file}.bak")" != 1 ]]; then
      echo "Небезопасная резервная копия: ${file}.bak" >&2
      return 1
    fi
    touched+=("$current_index")
    changed=1
    cp -a -- "${workdir}/snapshot.${current_index}" "${file}.bak" || return 1
    mv -f -- "${workdir}/candidate.${current_index}" "$file" || return 1
  done
  apachectl configtest || return 1
  if ! systemctl is-active --quiet httpd; then
    echo "Apache был остановлен во время изменения. Автоматический запуск не выполняется." >&2
    return 1
  fi
  systemctl reload httpd || return 1
  if ! systemctl is-active --quiet httpd; then
    echo "После reload Apache не работает." >&2
    return 1
  fi
  changed=0
  printf 'Режим HTTPS \033[0;32mприменён\033[0m.\n\n'
  printf 'Резервные копии:\n  \033[0;32m%s/*.conf.bak\033[0m\n' "$RISH_HTTPS_CONFIG_DIR"
)

rish_https_confirm() {
  local mode="$1" scope="$2" names="$3" result
  local rish_confirm_green='\033[0;32m'
  local rish_confirm_yellow='\033[0;33m'
  local rish_confirm_reset='\033[0m'
  rish_https_paths
  clear
  echo "Режим HTTPS"
  echo
  if [[ "$scope" == all ]]; then
    printf 'Сайты: %bвсе HTTPS-сайты RISH%b\n\n' "$rish_confirm_yellow" "$rish_confirm_reset"
  else
    printf 'Сайт: %b%s%b\n\n' "$rish_confirm_green" "$names" "$rish_confirm_reset"
  fi
  if [[ "$mode" == compatibility ]]; then
    printf 'Режим: %bсовместимость — только TLS 1.2%b\n\n' "$rish_confirm_green" "$rish_confirm_reset"
  else
    printf 'Режим: %bштатный TLS%b\n\n' "$rish_confirm_green" "$rish_confirm_reset"
  fi
  printf 'Резервные копии:\n  %b%s/*.conf.bak%b\n\n' "$rish_confirm_green" "$RISH_HTTPS_CONFIG_DIR" "$rish_confirm_reset"
  vertical_menu current 2 0 32 default=0 "Отмена" "Применить"
  [[ $? == 1 ]] || return 0
  rish_https_apply "$mode" "$scope"
  result=$?
  vertical_menu current 2 0 5 "Нажмите Enter"
  return "$result"
}

rish_https_menu() {
  local inventory key names state label padding size rows columns
  local choice mode scope selected=2 page_start=0 page_end site_index
  local name_width state_width name_limit height selected_row right_x action_x action_y
  local previous_index next_index back_index
  local -a site_keys site_names site_titles site_states labels

  while true; do
    clear
    echo "Режим HTTPS"
    echo
    inventory=$(rish_https_inventory) || return 1
    if [[ -z "$inventory" ]]; then
      echo "HTTPS-сайты не найдены."
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      return 0
    fi
    site_keys=() site_names=() site_titles=() site_states=()
    name_width=0 state_width=0
    while IFS=$'\t' read -r key names state; do
      label="$key"
      [[ "$key" != @* ]] || label="${key##*/}"
      case "$state" in
        "совместимость RISH") state="TLS 1.2" ;;
        "штатные настройки") state="Штатный" ;;
        "свой SSLProtocol") state="Свой SSLProtocol" ;;
      esac
      site_keys+=("$key")
      site_names+=("$names")
      site_titles+=("$label")
      site_states+=("$state")
      ((${#label} <= name_width)) || name_width=${#label}
      ((${#state} <= state_width)) || state_width=${#state}
    done <<<"$inventory"

    size=$(stty size 2>/dev/null) || size="24 80"
    read -r rows columns <<<"$size"
    [[ "$rows" =~ ^[0-9]+$ ]] && ((rows >= 10)) || rows=24
    [[ "$columns" =~ ^[0-9]+$ ]] && ((columns >= 20)) || columns=80
    # Reserve room for the side menu, both borders and their connector.
    name_limit=$((columns - state_width - 32))
    ((name_limit >= 8)) || name_limit=8
    ((name_width <= name_limit)) || name_width=$name_limit
    height=$((rows - 5))
    ((height <= 20)) || height=20

    ((page_start < ${#site_keys[@]})) || { page_start=0; selected=2; }
    # Keep every return code below 255, which vertical_menu reserves for Esc.
    page_end=$((page_start + 250))
    ((page_end <= ${#site_keys[@]})) || page_end=${#site_keys[@]}
    labels=("TLS 1.2 для всех сайтов" "Штатный режим для всех")
    for ((site_index=page_start; site_index<page_end; site_index++)); do
      label="${site_titles[$site_index]}"
      if ((${#label} > name_width)); then
        label="${label:0:$((name_width - 1))}…"
      fi
      printf -v padding '%*s' "$((name_width - ${#label}))" ""
      labels+=("${label}${padding}  ${site_states[$site_index]}")
    done
    previous_index=-1 next_index=-1
    if ((page_start > 0)); then
      previous_index=${#labels[@]}
      labels+=("Предыдущая страница")
    fi
    if ((page_end < ${#site_keys[@]})); then
      next_index=${#labels[@]}
      labels+=("Следующая страница")
    fi
    back_index=${#labels[@]}
    labels+=("Назад")
    vertical_menu current_noclear 2 "$height" 5 "default=$selected" "${labels[@]}"
    choice=$?
    if ((choice == 255 || choice == back_index)); then
      return 0
    fi
    if ((choice == previous_index)); then
      page_start=$((page_start - 250))
      selected=2
      continue
    fi
    if ((choice == next_index)); then
      page_start=$page_end
      selected=2
      continue
    fi
    selected=$choice
    case "$choice" in
      0) mode=compatibility; scope=all; names="" ;;
      1) mode=standard; scope=all; names="" ;;
      *)
        site_index=$((page_start + choice - 2))
        ((choice >= 2 && site_index < page_end)) || return 1
        scope="${site_keys[$site_index]}"
        names="${site_names[$site_index]}"
        selected_row=$((VERTICAL_MENU_LAST_Y + VERTICAL_MENU_LAST_VISIBLE_SELECTED + 1))
        right_x=$VERTICAL_MENU_LAST_RIGHT_X
        action_x=$(vertical_menu_next_x 2)
        action_y=$((selected_row - 1))
        if ((action_x + 19 <= columns)); then
          ((action_y <= rows - 4)) || action_y=$((rows - 4))
          cursor_to "$selected_row" "$right_x"
          printf '├'
          repl '─' "$((action_x - right_x - 1))"
        else
          # A very narrow terminal cannot fit two menus side by side.
          action_x=2
          action_y=$((VERTICAL_MENU_LAST_Y + VERTICAL_MENU_LAST_HEIGHT + 1))
        fi
        vertical_menu "$action_y" "$action_x" 0 5 "TLS 1.2" "Штатный режим" "Назад"
        choice=$?
        case "$choice" in
          0) mode=compatibility ;;
          1) mode=standard ;;
          *) continue ;;
        esac
        ;;
    esac
    rish_https_confirm "$mode" "$scope" "$names"
  done
}

rish_https_main() {
  local script_dir menu_status

  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
  # shellcheck source=../windows.sh
  source "${script_dir}/../windows.sh" || return 1
  rish_https_menu
  menu_status=$?
  if ((menu_status != 0)); then
    vertical_menu "current" 2 0 5 "Нажмите Enter"
  fi
  return "$menu_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rish_https_main "$@"
fi
