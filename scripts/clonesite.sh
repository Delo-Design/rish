#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2029

RISH_HOME="${RISH_HOME:-/root/rish}"

source "${RISH_HOME}/windows.sh"
source "${RISH_HOME}/create_site.sh"
source "${RISH_HOME}/scripts/site_helpers.sh"

GREEN="${GREEN:-$'\033[0;32m'}"
RED="${RED:-$'\033[0;31m'}"
WHITE="${WHITE:-$'\033[0m'}"
YELLOW="${YELLOW:-$'\033[0;33m'}"
CURSORUP="${CURSORUP:-$'\033[1A'}"
ERASEUNTILLENDOFLINE="${ERASEUNTILLENDOFLINE:-$'\033[K'}"

CLONE_TMP_DIR=""
CLONE_USE_EXCLUDES=0
CLONE_EXCLUDE_DIRS=()

function cleanup_clone_tmp_dir() {
  if [[ -n "$CLONE_TMP_DIR" && -d "$CLONE_TMP_DIR" ]]; then
    rm -rf "$CLONE_TMP_DIR"
  fi
}

function add_clone_server() {
  clear
  local regex="^[a-zA-Z0-9]+([-\.][a-zA-Z0-9]+)*(\.[a-zA-Z]{2,})?$|^[a-zA-Z0-9]+$"
  local ip_address=""
  local server_name=""

  while true; do
    echo "Добавляем новый сервер в список доступных для клонирования."
    read -r -e -p "Введите IP-адрес или hostname сервера-источника (Enter для выхода): " ip_address
    if [[ -z "$ip_address" ]]; then
      echo -e -n "${WHITE}${CURSORUP}${ERASEUNTILLENDOFLINE}"
      return 1
    fi

    # shellcheck disable=SC2016
    if timeout 5 bash -c ':</dev/tcp/$1/22' _ "$ip_address" 2>/dev/null; then
      echo -e "SSH/TCP порт 22 на ${GREEN}${ip_address}${WHITE} доступен."
      break
    fi

    echo -e "SSH/TCP порт 22 на ${RED}${ip_address}${WHITE} недоступен. ICMP/ping не используется."
  done

  echo
  echo "Придумайте короткое имя для подключения к этому серверу."
  echo "Имя должно быть из латинских букв и цифр; можно использовать точку или дефис."
  read -r -e -p "Имя SSH-подключения: " server_name
  while true; do
    if [[ -z "$server_name" ]]; then
      echo -e -n "${WHITE}${CURSORUP}${ERASEUNTILLENDOFLINE}"
      return 1
    fi
    if [[ "$server_name" =~ $regex ]]; then
      if grep -q -E "^[[:space:]]*Host[[:space:]]+${server_name}([[:space:]]|$)" "$HOME/.ssh/config" 2>/dev/null; then
        echo -e "SSH host ${RED}${server_name}${WHITE} уже существует. Введите другое имя:"
        read -r -e -p " " server_name
        continue
      fi
      break
    fi
    echo -e "Имя ${RED}${server_name}${WHITE} некорректное. Введите другое имя:"
    read -r -e -p " " server_name
  done

  local comment
  comment="$(hostname)"
  echo -e -n "${WHITE}Укажите комментарий для ключа:${GREEN}"
  read -r -e -p " " -i "$comment" comment
  echo -e "${WHITE}"

  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/config"
  ssh-keygen -t ed25519 -C "$comment" -f "$HOME/.ssh/${server_name}-key" -N ''
  {
    echo
    echo "Host ${server_name}"
    echo "    Hostname ${ip_address}"
    echo "    User root"
    echo "    Compression yes"
    echo "    IdentityFile ~/.ssh/${server_name}-key"
  } >> "$HOME/.ssh/config"

  echo "Скопируйте команду на удаленный сервер после подключения:"
  echo -e "${GREEN}echo '$(cat "$HOME/.ssh/${server_name}-key.pub")' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys${WHITE}"
  echo "После этого можно продолжить клонирование."
}

function select_clone_server() {
  local count choice
  local -a servers=()

  mkdir -p "$HOME/.ssh"
  touch "$HOME/.ssh/config"

  while true; do
    mapfile -t servers < <(awk '$1 == "Host" && $2 != "*" { print $2 }' "$HOME/.ssh/config" | sort)
    count="${#servers[@]}"
    servers+=("Добавить сервер")
    servers+=("Выйти")

    echo "Выберите сервер-источник:"
    vertical_menu "current" 2 0 40 "${servers[@]}"
    choice=$?
    if (( choice == 255 )); then
      return 1
    fi
    if (( choice < count )); then
      CLONE_SOURCE_HOST="${servers[$choice]}"
      return 0
    fi
    if (( choice == count + 1 )); then
      return 1
    fi
    add_clone_server
  done
}

function check_clone_ssh_access() {
  local host="$1"

  echo -e "Проверяем SSH-доступ к ${GREEN}${host}${WHITE}."
  if ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$host" 'exit 0'; then
    return 0
  fi

  echo -e "Подключиться к серверу ${RED}${host}${WHITE} по SSH не удалось."
  echo "Проверка выполнялась прямым SSH/TCP-подключением, без ping."
  return 1
}

function remote_shell_quote() {
  printf '%q' "$1"
}

function format_document_root_label() {
  local document_root="$1"

  if [[ -z "$document_root" ]]; then
    printf 'site_root'
  else
    printf '/%s' "${document_root#/}"
  fi
}

function format_site_name_label() {
  local name="$1"
  local decoded_name

  if [[ "$name" =~ (^|\.)xn-- ]]; then
    decoded_name="$(idn2 -d "$name" 2>/dev/null)"
    if [[ -n "$decoded_name" && "$decoded_name" != "$name" ]]; then
      printf '%s (%s)' "$name" "$decoded_name"
      return 0
    fi
  fi

  printf '%s' "$name"
}

function format_php_label() {
  local php_label="$1"
  local php_full_version="$2"

  if [[ -n "$php_label" && -n "$php_full_version" ]]; then
    printf '%s / %s' "$php_label" "$php_full_version"
  elif [[ -n "$php_label" ]]; then
    printf '%s' "$php_label"
  elif [[ -n "$php_full_version" ]]; then
    printf '%s' "$php_full_version"
  else
    printf 'не определен'
  fi
}

function print_clone_box() {
  local -a box_lines=()

  build_clone_box_lines box_lines "$@"
  printf '%s\n' "${box_lines[@]}"
}

function build_clone_box_lines() {
  local result_var="$1"
  local title="$2"
  shift 2
  # shellcheck disable=SC2034
  local -n result_ref="$result_var"

  local -a lines=()
  local content_width=40
  local title_text=" ${title} "
  local title_len=${#title_text}
  local border_width
  local top_fill_len
  local line pad_len
  local top_fill
  local bottom_fill

  for line in "$@"; do
    if (( ${#line} > content_width )); then
      content_width=${#line}
    fi
  done
  if (( title_len > content_width + 2 )); then
    content_width=$((title_len - 2))
  fi

  border_width=$((content_width + 2))
  top_fill_len=$((border_width - title_len))

  printf -v top_fill '%*s' "$top_fill_len" ''
  printf -v bottom_fill '%*s' "$border_width" ''
  lines+=("┌${title_text}${top_fill// /─}┐")

  for line in "$@"; do
    pad_len=$((content_width - ${#line}))
    (( pad_len < 0 )) && pad_len=0
    printf -v line '│ %s%*s │' "$line" "$pad_len" ''
    lines+=("$line")
  done

  lines+=("└${bottom_fill// /─}┘")
  # shellcheck disable=SC2034
  result_ref=("${lines[@]}")
}

function color_clone_box_site_line() {
  local lines_var="$1"
  local site_name="$2"
  # shellcheck disable=SC2034
  local -n lines_ref="$lines_var"
  local i
  local line

  for i in "${!lines_ref[@]}"; do
    line="${lines_ref[$i]}"
    if [[ "$line" == *"Сайт: ${site_name} ("* ]]; then
      lines_ref[$i]="${line/Сайт: ${site_name} (/Сайт: ${GREEN}${site_name}${WHITE} (}"
    fi
  done
}

function print_clone_boxes_side_by_side() {
  local -n left_lines_ref="$1"
  local -n right_lines_ref="$2"
  local left_width=${#left_lines_ref[0]}
  local gap="  "
  local arrow="-------->"
  local arrow_space
  local terminal_columns="${COLUMNS:-0}"
  local needed_columns
  local i middle_index connector

  printf -v arrow_space '%*s' "${#arrow}" ''
  needed_columns=$((left_width + ${#gap} + ${#arrow} + ${#gap} + ${#right_lines_ref[0]}))
  if [[ "$terminal_columns" =~ ^[0-9]+$ ]] && (( terminal_columns > 0 && needed_columns > terminal_columns )); then
    printf '%b\n' "${left_lines_ref[@]}"
    echo
    printf '%b\n' "${right_lines_ref[@]}"
    return
  fi

  middle_index=$((${#left_lines_ref[@]} / 2))
  for i in "${!left_lines_ref[@]}"; do
    if (( i == middle_index )); then
      connector="${gap}${arrow}${gap}"
    else
      connector="${gap}${arrow_space}${gap}"
    fi
    printf '%b%s%b\n' "${left_lines_ref[$i]}" "$connector" "${right_lines_ref[$i]}"
  done
}

function print_source_summary_box() {
  local -a source_lines=()

  build_source_summary_box_lines source_lines
  color_clone_box_site_line source_lines "$CLONE_REMOTE_SITE"
  printf '%b\n' "${source_lines[@]}"
}

function build_source_summary_box_lines() {
  local result_var="$1"
  local db_label="нет"

  if [[ "$CLONE_REMOTE_HAS_DB" == "1" ]]; then
    db_label="$CLONE_REMOTE_SITE"
  fi

  build_clone_box_lines "$result_var" "Источник" \
    "Сайт: ${CLONE_REMOTE_SITE} (${CLONE_REMOTE_USER})" \
    "DocumentRoot: $(format_document_root_label "$CLONE_REMOTE_DOCUMENT_ROOT_REL")" \
    "PHP: $(format_php_label "$CLONE_REMOTE_PHP_VERSION" "$CLONE_REMOTE_PHP_FULL_VERSION")" \
    "База данных: ${db_label}"
}

function print_target_summary_box() {
  local php_label="$1"
  local php_full_version="$2"
  local -a target_lines=()

  build_target_summary_box_lines target_lines "$php_label" "$php_full_version"
  color_clone_box_site_line target_lines "$CLONE_LOCAL_SITE"
  printf '%b\n' "${target_lines[@]}"
}

function build_target_summary_box_lines() {
  local result_var="$1"
  local php_label="$2"
  local php_full_version="$3"

  build_clone_box_lines "$result_var" "Цель" \
    "Сайт: ${CLONE_LOCAL_SITE} (${CLONE_LOCAL_USER})" \
    "DocumentRoot: $(format_document_root_label "$CLONE_REMOTE_DOCUMENT_ROOT_REL")" \
    "PHP: $(format_php_label "$php_label" "$php_full_version")" \
    "База данных: ${CLONE_LOCAL_SITE}"
}

function print_target_database_summary_box() {
  local -a target_lines=()

  build_target_database_summary_box_lines target_lines
  color_clone_box_site_line target_lines "$CLONE_LOCAL_SITE"
  printf '%b\n' "${target_lines[@]}"
}

function build_target_database_summary_box_lines() {
  local result_var="$1"

  build_clone_box_lines "$result_var" "Цель" \
    "Сайт: ${CLONE_LOCAL_SITE} (${CLONE_LOCAL_USER})" \
    "DocumentRoot: -" \
    "PHP: -" \
    "База данных: ${CLONE_LOCAL_SITE}"
}

function print_clone_summary_pair() {
  local php_label="$1"
  local php_full_version="$2"
  local mode="${3:-site}"
  # shellcheck disable=SC2034
  local -a source_lines=()
  # shellcheck disable=SC2034
  local -a target_lines=()

  build_source_summary_box_lines source_lines
  if [[ "$mode" == "database" ]]; then
    build_target_database_summary_box_lines target_lines
  else
    build_target_summary_box_lines target_lines "$php_label" "$php_full_version"
  fi
  color_clone_box_site_line source_lines "$CLONE_REMOTE_SITE"
  color_clone_box_site_line target_lines "$CLONE_LOCAL_SITE"
  print_clone_boxes_side_by_side source_lines target_lines
}

function get_local_php_full_version() {
  local php_label="$1"
  local php_bin="/opt/remi/${php_label}/root/usr/bin/php"

  [[ -x "$php_bin" ]] || return 1
  "$php_bin" -r 'echo PHP_VERSION;' 2>/dev/null
}

function get_remote_php_full_version() {
  local host="$1"
  local php_label="$2"

  [[ -n "$php_label" ]] || return 1
  ssh "$host" "php_bin=/opt/remi/$(remote_shell_quote "$php_label")/root/usr/bin/php; [ -x \"\$php_bin\" ] && \"\$php_bin\" -r 'echo PHP_VERSION;'"
}

function select_remote_site() {
  local host="$1"
  local choice
  local max_site_name_length=0
  local site_entry
  local site_name
  local site_padding
  local site_user
  local -a menu_items=()
  local -a sites=()
  local -a site_names=()
  local -a site_users=()

  echo -e "Получаем список сайтов удаленного сервера ${GREEN}${host}${WHITE}."
  mapfile -t sites < <(
    ssh "$host" 'for site in /var/www/*/www/*; do
      [ -d "$site" ] || continue
      case "$(basename "$site")" in 000-default) continue ;; esac
      user="${site#/var/www/}"
      user="${user%%/*}"
      printf "%s\t%s\n" "$(basename "$site")" "$user"
    done' | sort
  )

  if (( ${#sites[@]} == 0 )); then
    echo -e "На сервере ${YELLOW}${host}${WHITE} сайты в /var/www/<user>/www не найдены."
    return 1
  fi

  for site_entry in "${sites[@]}"; do
    site_name="${site_entry%%$'\t'*}"
    site_user="${site_entry#*$'\t'}"
    site_names+=("$site_name")
    site_users+=("$site_user")
    if (( ${#site_name} > max_site_name_length )); then
      max_site_name_length=${#site_name}
    fi
  done

  for choice in "${!site_names[@]}"; do
    site_name="${site_names[$choice]}"
    site_user="${site_users[$choice]}"
    printf -v site_padding "%*s" "$((max_site_name_length - ${#site_name}))" ""
    menu_items+=("${site_name}${site_padding}  (${site_user})")
  done

  vertical_menu "current" 2 20 40 "${menu_items[@]}"
  choice=$?
  if (( choice == 255 )); then
    return 1
  fi

  CLONE_REMOTE_SITE="${site_names[$choice]}"
  if ! validate_site_name "$CLONE_REMOTE_SITE"; then
    echo -e "Выбранная папка ${RED}${CLONE_REMOTE_SITE}${WHITE} не является корректным именем сайта."
    return 1
  fi
  CLONE_REMOTE_USER="${site_users[$choice]}"
  CLONE_REMOTE_SITE_ROOT="/var/www/${CLONE_REMOTE_USER}/www/${CLONE_REMOTE_SITE}"
}

function inspect_remote_site() {
  local host="$1"
  local site="$2"
  local user="$3"
  local remote_script
  local key value
  local vhost_file=""
  local document_root=""
  local site_root="/var/www/${user}/www/${site}"
  local inspect_output

  remote_script="$(cat <<'RISH_REMOTE_CLONE_INSPECT'
site="$1"
user="$2"
site_root="/var/www/${user}/www/${site}"
vhost_file=""
for f in /etc/httpd/conf.d/"${site}".conf /etc/httpd/conf.d/"${site}"-ssl.conf /etc/httpd/conf.d/"${site}"-le-ssl.conf /etc/httpd/conf.d/*.conf; do
  [ -f "$f" ] || continue
  if awk -v site="$site" '$1 == "ServerName" && $2 == site { found=1 } END { exit !found }' "$f"; then
    vhost_file="$f"
    break
  fi
done
document_root=""
php_version=""
ssl_files=""
if [ -n "$vhost_file" ]; then
  document_root="$(awk '$1 == "DocumentRoot" { print $2; exit }' "$vhost_file")"
  php_version="$(grep -Eo "php[0-9]{2}" "$vhost_file" | head -n 1)"
  ssl_files="$(awk '$1 ~ /^SSLCertificate(File|KeyFile|ChainFile)$/ { print $2 }' "$vhost_file" | paste -sd "," -)"
fi
has_db=0
if mariadb -N -e "SHOW DATABASES LIKE '${site}'" 2>/dev/null | grep -Fxq "$site"; then
  has_db=1
fi
printf "site_root=%s\n" "$site_root"
printf "vhost_file=%s\n" "$vhost_file"
printf "document_root=%s\n" "$document_root"
printf "php_version=%s\n" "$php_version"
printf "has_db=%s\n" "$has_db"
printf "ssl_files=%s\n" "$ssl_files"
RISH_REMOTE_CLONE_INSPECT
)"

  CLONE_REMOTE_DOCUMENT_ROOT_REL=""
  CLONE_REMOTE_PHP_VERSION=""
  CLONE_REMOTE_PHP_FULL_VERSION=""
  CLONE_REMOTE_HAS_DB=0
  CLONE_REMOTE_SSL_FILES=""

  if ! inspect_output="$(ssh "$host" "bash -s -- $(remote_shell_quote "$site") $(remote_shell_quote "$user")" <<< "$remote_script")"; then
    echo -e "Не удалось получить параметры сайта ${RED}${site}${WHITE} с источника ${RED}${host}${WHITE}."
    return 1
  fi

  while IFS='=' read -r key value; do
    case "$key" in
      site_root) site_root="$value" ;;
      vhost_file) vhost_file="$value" ;;
      document_root) document_root="$value" ;;
      php_version) CLONE_REMOTE_PHP_VERSION="$value" ;;
      has_db) CLONE_REMOTE_HAS_DB="$value" ;;
      ssl_files) CLONE_REMOTE_SSL_FILES="$value" ;;
    esac
  done <<< "$inspect_output"

  if [[ -z "$vhost_file" ]]; then
    echo -e "Vhost для ${YELLOW}${site}${WHITE} на источнике не найден. DocumentRoot будет считаться папкой сайта."
    CLONE_REMOTE_DOCUMENT_ROOT_REL=""
  elif [[ -z "$document_root" ]]; then
    echo -e "В vhost ${YELLOW}${vhost_file}${WHITE} не найден DocumentRoot. Перенос прерван."
    return 1
  elif [[ "$document_root" == "$site_root" ]]; then
    CLONE_REMOTE_DOCUMENT_ROOT_REL=""
  elif [[ "$document_root" == "$site_root/"* ]]; then
    CLONE_REMOTE_DOCUMENT_ROOT_REL="${document_root#"$site_root"/}"
  else
    echo -e "DocumentRoot источника указывает вне site_root:"
    echo -e "  site_root: ${YELLOW}${site_root}${WHITE}"
    echo -e "  DocumentRoot: ${RED}${document_root}${WHITE}"
    echo "Перенос в первом этапе поддерживает только DocumentRoot внутри site_root."
    return 1
  fi

  if ! CLONE_REMOTE_DOCUMENT_ROOT_REL="$(normalize_relative_document_root "$CLONE_REMOTE_DOCUMENT_ROOT_REL")"; then
    return 1
  fi

  if [[ -n "$CLONE_REMOTE_PHP_VERSION" ]]; then
    CLONE_REMOTE_PHP_FULL_VERSION="$(get_remote_php_full_version "$host" "$CLONE_REMOTE_PHP_VERSION")"
  fi

  echo
  print_source_summary_box
}

function default_local_site_name() {
  local remote_site="$1"

  if [[ "${LocalServer:-false}" == "true" ]]; then
    if [[ "$remote_site" == *.* ]]; then
      printf '%s.test' "${remote_site%.*}"
    else
      printf '%s.test' "$remote_site"
    fi
  else
    printf '%s' "$remote_site"
  fi
}

function select_local_user() {
  local choice
  local -a users=()

  echo
  echo "Выберите пользователя на текущем сервере, куда надо копировать сайт."
  mapfile -t users < <(find /var/www -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -Ev '^(cgi-bin|html)$' | sort)
  if (( ${#users[@]} == 0 )); then
    echo -e "Локальные пользователи в ${RED}/var/www${WHITE} не найдены."
    return 1
  fi

  vertical_menu "current" 2 20 40 "${users[@]}"
  choice=$?
  if (( choice == 255 )); then
    return 1
  fi
  CLONE_LOCAL_USER="${users[$choice]}"
}

function confirm_local_site_name() {
  local proposed="$1"
  local site_name="$proposed"

  while true; do
    echo -e "${WHITE}Подтвердите имя сайта для клонирования:${GREEN}"
    read -r -e -i "$site_name" site_name
    echo -e "${WHITE}"

    if [[ -z "$site_name" ]]; then
      return 1
    fi
    site_name="${site_name,,}"

    if echo "$site_name" | grep -qP '[А-Яа-яЁё]'; then
      local punycode_input

      punycode_input="$(idn2 --quiet "$site_name" 2>/dev/null)"
      if [[ -n "$punycode_input" && "$punycode_input" != "$site_name" ]]; then
        echo -e "${GREEN}${site_name}${WHITE}  --->  ${GREEN}${punycode_input}${WHITE}"
        site_name="$punycode_input"
      fi
    fi

    if validate_site_name "$site_name"; then
      break
    fi

    echo -e "Имя сайта ${RED}${site_name}${WHITE} некорректное."
    echo -e "Введите корректное имя сайта или очистите строку и нажмите ${YELLOW}Enter${WHITE} для выхода."
  done

  CLONE_LOCAL_SITE="$site_name"
}

function is_directory_empty() {
  local directory="$1"

  [[ -d "$directory" ]] || return 0
  [[ -z "$(find "$directory" -mindepth 1 -print -quit 2>/dev/null)" ]]
}

function handle_non_empty_target_site_root() {
  local site_root="$1"
  local target_action

  echo -e "Целевая папка сайта уже содержит файлы: ${RED}${site_root}${WHITE}"
  vertical_menu "current" 2 0 44 \
    "Очистить папку и продолжить клонирование" \
    "Не очищать папку и перезаписать содержимое" \
    "Выйти"
  target_action=$?

  case "$target_action" in
    0)
      if ! find "$site_root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; then
        echo -e "Не удалось очистить папку ${RED}${site_root}${WHITE}."
        return 1
      fi
      CLONE_TARGET_CLEARED=1
      ;;
    1)
      ;;
    *)
      echo "Перенос остановлен."
      return 1
      ;;
  esac
}

function get_local_vhost_document_root() {
  local site_name="$1"
  local conf_file="/etc/httpd/conf.d/${site_name}.conf"

  [[ -f "$conf_file" ]] || return 1
  awk '$1 == "DocumentRoot" { print $2; exit }' "$conf_file"
}

function get_local_vhost_php_version() {
  local site_name="$1"
  local conf_file="/etc/httpd/conf.d/${site_name}.conf"

  [[ -f "$conf_file" ]] || return 1
  grep -Eo 'php[0-9]{2}' "$conf_file" | head -n 1
}

function check_existing_vhost_php_available() {
  local site_name="$1"
  local php_label
  local php_fpm_bin

  php_label="$(get_local_vhost_php_version "$site_name")"
  if [[ -z "$php_label" ]]; then
    echo -e "Версию PHP в существующем vhost ${YELLOW}${site_name}.conf${WHITE} определить не удалось."
    return 1
  fi

  php_fpm_bin="/opt/remi/${php_label}/root/usr/sbin/php-fpm"
  if [[ ! -x "$php_fpm_bin" ]]; then
    echo -e "Существующий сайт ${GREEN}$(format_site_name_label "$site_name")${WHITE} использует ${YELLOW}${php_label}${WHITE}, но PHP-FPM ${RED}${php_label}${WHITE} не установлен."
    echo -e "Установите ${YELLOW}${php_label}${WHITE} или измените версию PHP сайта перед клонированием."
    return 1
  fi
}

function offer_local_self_signed_ssl() {
  local site_name="$1"

  echo
  # shellcheck disable=SC1091
  if ! source "${RISH_HOME}/scripts/certs.sh"; then
    echo -e "Не удалось подключить скрипт: ${RED}${RISH_HOME}/scripts/certs.sh${WHITE}"
    return 1
  fi

  if self_signed_cert_exists_for_site "$site_name"; then
    if ! create_self_signed_cert_for_site "$site_name"; then
      echo -e "Клонирование сайта завершено, но самоподписанный SSL-сертификат ${RED}не создан${WHITE}."
      return 1
    fi
    return 0
  fi

  echo -e "Создать самоподписанный ${GREEN}SSL${WHITE} сертификат для локального сайта ${GREEN}$(format_site_name_label "$site_name")${WHITE}?"
  if ! vertical_menu "current" 2 0 5 "Да" "Нет"; then
    echo "Self-signed SSL не создан."
    return 0
  fi

  if ! create_self_signed_cert_for_site "$site_name"; then
    echo -e "Клонирование сайта завершено, но самоподписанный SSL-сертификат ${RED}не создан${WHITE}."
    return 1
  fi
}

function can_use_existing_target_site() {
  local site_name="$1"
  local site_root="$2"
  local expected_document_root="$3"
  local conf_file="/etc/httpd/conf.d/${site_name}.conf"
  local document_root

  if [[ ! -f "$conf_file" ]]; then
    return 1
  fi

  document_root="$(get_local_vhost_document_root "$site_name")"
  if [[ -z "$document_root" ]]; then
    echo -e "В существующем vhost не найден DocumentRoot: ${RED}${conf_file}${WHITE}"
    return 1
  fi

  if [[ "$document_root" != "$expected_document_root" ]]; then
    echo -e "DocumentRoot существующего vhost не совпадает с ожидаемым:"
    echo -e "  ожидается: ${YELLOW}${expected_document_root}${WHITE}"
    echo -e "  DocumentRoot: ${RED}${document_root}${WHITE}"
    return 1
  fi

  check_existing_vhost_php_available "$site_name" || return 1

  if ! is_directory_empty "$site_root"; then
    handle_non_empty_target_site_root "$site_root" || return 1
  fi

  if [[ ! -d "$site_root" ]]; then
    echo -e "Создаем пустой site_root для существующего vhost: ${GREEN}${site_root}${WHITE}"
    if ! mkdir -p "$site_root"; then
      echo -e "Не удалось создать site_root: ${RED}${site_root}${WHITE}"
      return 1
    fi
  fi

}

function select_clone_php_version() {
  local preferred="$1"
  local choice selected_php
  local -a installed_versions=()

  mapfile -t installed_versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
  if (( ${#installed_versions[@]} == 0 )); then
    echo -e "Установленные версии PHP не найдены."
    return 1
  fi

  if [[ -n "$preferred" ]]; then
    local i
    for i in "${!installed_versions[@]}"; do
      if [[ "${installed_versions[$i]}" == "$preferred" ]]; then
        echo -e "Используем PHP как на источнике: ${GREEN}${preferred}${WHITE}"
        CLONE_LOCAL_PHP="$preferred"
        return 0
      fi
    done
    echo -e "PHP ${YELLOW}${preferred}${WHITE} найден на источнике, но не установлен на текущем сервере."
  fi

  echo
  echo -e "Выберите версию ${GREEN}PHP${WHITE} для целевого сайта."
  vertical_menu "current" 1 0 10 "${installed_versions[@]}"
  choice=$?
  if (( choice == 255 )); then
    return 1
  fi
  selected_php="${installed_versions[$choice]}"
  echo -e "${CURSORUP}${ERASEUNTILLENDOFLINE}Выбрана версия ${GREEN}${selected_php}${WHITE} для целевого сайта."
  CLONE_LOCAL_PHP="$selected_php"
}

function select_clone_php_mode() {
  local pool_file="/etc/opt/remi/${CLONE_LOCAL_PHP}/php-fpm.d/${CLONE_LOCAL_USER}.conf"
  local choice

  CLONE_PHP_MODE="ondemand"
  if [[ -f "$pool_file" ]]; then
    return 0
  fi

  echo
  echo -e "Выберите режим работы PHP для пользователя ${GREEN}${CLONE_LOCAL_USER}${WHITE}:"
  vertical_menu "current" 2 0 5 "ondemand - оптимально расходует память" "dynamic - более оперативно реагирует на запросы"
  choice=$?
  if (( choice == 1 )); then
    CLONE_PHP_MODE="dynamic"
  fi
}

function normalize_clone_exclude_dir() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  while [[ "$value" == ./* ]]; do
    value="${value#./}"
  done
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done

  if [[ -z "$value" ]]; then
    return 1
  fi
  if [[ "$value" == /* || "$value" == "." || "$value" == ".." || "$value" == *"/../"* || "$value" == ../* || "$value" == */.. ]]; then
    echo -e "Путь исключения ${RED}${value}${WHITE} некорректный. Укажите папку относительно site_root." >&2
    return 2
  fi
  if [[ ! "$value" =~ ^[A-Za-z0-9._@+/-]+$ ]]; then
    echo -e "Путь исключения ${RED}${value}${WHITE} содержит недопустимые символы." >&2
    echo -e "Разрешены только буквы, цифры, ${YELLOW}.${WHITE}, ${YELLOW}_${WHITE}, ${YELLOW}-${WHITE}, ${YELLOW}+${WHITE}, ${YELLOW}@${WHITE} и ${YELLOW}/${WHITE}." >&2
    return 2
  fi

  printf '%s' "$value"
}

function save_clone_archive_exclude() {
  local exclude_input="$1"
  local config_file="${RISH_HOME}/rish_config.sh"
  local exclude_line

  printf -v exclude_line 'ARCHIVE_EXCLUDE=%q' "$exclude_input"

  if [[ -f "$config_file" ]] && grep -q "^ARCHIVE_EXCLUDE=" "$config_file"; then
    sed -i "s|^ARCHIVE_EXCLUDE=.*|${exclude_line}|" "$config_file"
  else
    echo "$exclude_line" >> "$config_file"
  fi
}

function select_clone_exclude_dirs() {
  local default_exclude="${ARCHIVE_EXCLUDE:-}"
  local exclude_input
  local excl
  local normalized
  local -a exclude_arr=()
  local normalized_input
  local invalid_exclude

  while true; do
    echo -e "Типовые примеры исключений:"
    echo -e "Для Joomla: ${YELLOW}administrator/cache,administrator/logs,cache,tmp${WHITE}"
    echo -e "Для Joomla Yootheme: ${YELLOW}administrator/cache,administrator/logs,cache,tmp,templates/yootheme/cache${WHITE}"
    echo -e "Для Joomla Akeeba: ${YELLOW}administrator/cache,administrator/logs,cache,tmp,administrator/components/com_akeeba/backup${WHITE}"
    echo
    echo -e "Введите папки, содержимое которых надо исключить из клонирования (через запятую):${YELLOW}"
    read -r -e -i "$default_exclude" exclude_input
    echo -e "${WHITE}"

    CLONE_EXCLUDE_DIRS=()
    invalid_exclude=0
    local IFS=','
    read -ra exclude_arr <<< "$exclude_input"
    for excl in "${exclude_arr[@]}"; do
      normalized="$(normalize_clone_exclude_dir "$excl")"
      case "$?" in
        0) CLONE_EXCLUDE_DIRS+=("$normalized") ;;
        1) ;;
        *)
          CLONE_EXCLUDE_DIRS=()
          invalid_exclude=1
          break
          ;;
      esac
    done

    if [[ "$invalid_exclude" == "1" ]]; then
      echo
      continue
    fi

    if (( ${#CLONE_EXCLUDE_DIRS[@]} > 0 )); then
      local IFS=','
      normalized_input="${CLONE_EXCLUDE_DIRS[*]}"
      save_clone_archive_exclude "$normalized_input"
      return 0
    fi

    CLONE_USE_EXCLUDES=0
    echo -e "Список исключений ${YELLOW}пустой${WHITE}. Клонирование продолжится без исключения папок."
    return 0
  done
}

function append_remote_args_from_array() {
  local result_var="$1"
  shift
  local -n result_ref="$result_var"
  local arg
  local quoted

  for arg in "$@"; do
    quoted="$(remote_shell_quote "$arg")"
    result_ref+=" ${quoted}"
  done
}

function copy_site_files() {
  local host="$1"
  local remote_site_root="$2"
  local local_site_root="$3"
  local local_user="$4"
  local size_bytes
  local size_mb
  local remote_root_quoted
  local local_site_name
  local remote_du_exclude_args=""
  local remote_tar_exclude_args=""
  local -a du_exclude_args=()
  local -a tar_exclude_args=()
  local -a transfer_status=()
  local remote_tar_status
  local excl

  echo
  local_site_name="$(basename -- "$local_site_root")"
  echo -e "Переносим файлы сайта в site_root: ${GREEN}${local_site_name}${WHITE}"
  remote_root_quoted="$(remote_shell_quote "$remote_site_root")"

  if [[ "${CLONE_USE_EXCLUDES:-0}" == "1" && ${#CLONE_EXCLUDE_DIRS[@]} -gt 0 ]]; then
    echo -e "Содержимое этих папок не переносится:"
    for excl in "${CLONE_EXCLUDE_DIRS[@]}"; do
      echo -e " ${YELLOW}${excl}${WHITE}"
      du_exclude_args+=("--exclude=${remote_site_root}/${excl}/*")
      du_exclude_args+=("--exclude=${remote_site_root}/${excl}/.*")
      tar_exclude_args+=("--exclude=./${excl}/*")
      tar_exclude_args+=("--exclude=./${excl}/.*")
    done
    echo
    append_remote_args_from_array remote_du_exclude_args "${du_exclude_args[@]}"
    append_remote_args_from_array remote_tar_exclude_args "${tar_exclude_args[@]}"
  fi

  size_bytes="$(ssh "$host" "du -sb${remote_du_exclude_args} ${remote_root_quoted} 2>/dev/null | awk '{print \$1}'")"
  if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
    size_mb=$(( (size_bytes + 1024 * 1024 - 1) / (1024 * 1024) ))
    echo -e "Размер исходного сайта: ${YELLOW}${size_mb} MB${WHITE}"
  else
    echo -e "Размер исходного сайта ${YELLOW}определить не удалось${WHITE}."
  fi

  if command -v pv >/dev/null 2>&1 && [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
    if ssh -C "$host" "tar -C ${remote_root_quoted}${remote_tar_exclude_args} -cf - ." | pv -s "$size_bytes" | tar -C "$local_site_root" -xf -; then
      transfer_status=("${PIPESTATUS[@]}")
    else
      transfer_status=("${PIPESTATUS[@]}")
    fi
    remote_tar_status="${transfer_status[0]}"
    if (( (remote_tar_status != 0 && remote_tar_status != 1) || transfer_status[1] != 0 || transfer_status[2] != 0 )); then
      echo -e "Ошибка при переносе файлов сайта tar-потоком."
      return 1
    fi
  else
    if ! command -v pv >/dev/null 2>&1; then
      echo -e "${YELLOW}pv не установлен${WHITE}, прогресс передачи не будет показан."
    fi
    echo "Перенос продолжается, дождитесь завершения."
    if ssh -C "$host" "tar -C ${remote_root_quoted}${remote_tar_exclude_args} -cf - ." | tar -C "$local_site_root" -xf -; then
      transfer_status=("${PIPESTATUS[@]}")
    else
      transfer_status=("${PIPESTATUS[@]}")
    fi
    remote_tar_status="${transfer_status[0]}"
    if (( (remote_tar_status != 0 && remote_tar_status != 1) || transfer_status[1] != 0 )); then
      echo -e "Ошибка при переносе файлов сайта tar-потоком."
      return 1
    fi
  fi

  if (( remote_tar_status == 1 )); then
    echo "Некоторые файлы изменились на исходном сервере во время переноса."
    echo -e "Копии этих файлов могут быть ${YELLOW}неточными${WHITE}, но перенос будет продолжен."
  fi

  if ! chown -R "${local_user}:${local_user}" "$local_site_root"; then
    echo -e "Не удалось назначить владельца ${RED}${local_user}:${local_user}${WHITE} для ${RED}${local_site_root}${WHITE}."
    return 1
  fi
  echo -e "Файлы сайта перенесены в ${GREEN}${local_site_root}${WHITE}."
}

function clone_database() {
  local host="$1"
  local remote_db="$2"
  local local_db="$3"
  local local_user="$4"
  local dump_file="${CLONE_TMP_DIR}/${remote_db}.sql.gz"
  local remote_dump_command

  echo
  echo -e "Переносим базу данных ${GREEN}${remote_db}${WHITE} (${YELLOW}${host}${WHITE}) -> ${GREEN}${local_db}${WHITE}."
  remote_dump_command="mariadb-dump --extended-insert --single-transaction --quick --routines --events --triggers --quote-names --order-by-primary --hex-blob $(remote_shell_quote "$remote_db") | sed '1{/999999.*sandbox/d}' | sed '/NOTE_VERBOSITY/d' | gzip -c"
  if ! ssh "$host" "bash -o pipefail -c $(remote_shell_quote "$remote_dump_command")" > "$dump_file"; then
    echo -e "Не удалось получить дамп базы ${RED}${remote_db}${WHITE} с источника."
    return 1
  fi

  if ! create_database_for_user "$local_db" "$local_user"; then
    return 1
  fi
  import_database_file "$dump_file" "$local_db"
}

function clone_site_validate_flag() {
  local name="$1"
  local value="$2"

  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo -e "Параметр ${RED}${name}${WHITE} некорректный: ${value}"
    return 1
  fi
}

function clone_site_validate_core_params() {
  CLONE_REMOTE_DOCUMENT_ROOT_REL="$(normalize_relative_document_root "${CLONE_REMOTE_DOCUMENT_ROOT_REL:-}")" || return 1

  clone_site_validate_flag "CLONE_COPY_FILES" "${CLONE_COPY_FILES:-1}" || return 1
  clone_site_validate_flag "CLONE_COPY_DB" "${CLONE_COPY_DB:-1}" || return 1
  clone_site_validate_flag "CLONE_REQUIRE_DB" "${CLONE_REQUIRE_DB:-0}" || return 1
  clone_site_validate_flag "CLONE_CREATE_SITE" "${CLONE_CREATE_SITE:-1}" || return 1
  clone_site_validate_flag "CLONE_REUSE_EXISTING_TARGET" "${CLONE_REUSE_EXISTING_TARGET:-1}" || return 1
  clone_site_validate_flag "CLONE_RESTART_PHP_FPM" "${CLONE_RESTART_PHP_FPM:-1}" || return 1
  clone_site_validate_flag "CLONE_UPDATE_HOTLIST" "${CLONE_UPDATE_HOTLIST:-1}" || return 1

  if [[ "${CLONE_COPY_FILES:-1}" == "0" && "${CLONE_COPY_DB:-1}" == "0" ]]; then
    echo -e "Нечего клонировать: ${RED}CLONE_COPY_FILES=0${WHITE} и ${RED}CLONE_COPY_DB=0${WHITE}."
    return 1
  fi

  if [[ "${CLONE_COPY_DB:-1}" == "1" ]]; then
    if [[ -z "${CLONE_REMOTE_HAS_DB+x}" || -z "$CLONE_REMOTE_HAS_DB" ]]; then
      echo -e "Не задан ${RED}CLONE_REMOTE_HAS_DB${WHITE} для переноса базы данных."
      return 1
    fi
    clone_site_validate_flag "CLONE_REMOTE_HAS_DB" "$CLONE_REMOTE_HAS_DB" || return 1
  fi

  if [[ "${CLONE_RELOAD_APACHE:-1}" != "0" && "${CLONE_RELOAD_APACHE:-1}" != "1" ]]; then
    echo -e "Параметр ${RED}CLONE_RELOAD_APACHE${WHITE} некорректный для core: ${CLONE_RELOAD_APACHE:-1}"
    return 1
  fi

  if [[ -z "${CLONE_SOURCE_HOST:-}" ]]; then
    echo -e "Не задан ${RED}CLONE_SOURCE_HOST${WHITE}."
    return 1
  fi

  if ! validate_site_name "${CLONE_REMOTE_SITE:-}"; then
    echo -e "Имя исходного сайта ${RED}некорректное${WHITE}: ${CLONE_REMOTE_SITE:-}"
    return 1
  fi

  if [[ -z "${CLONE_REMOTE_USER:-}" ]]; then
    echo -e "Не задан ${RED}CLONE_REMOTE_USER${WHITE}."
    return 1
  fi

  if [[ "${CLONE_COPY_FILES:-1}" == "1" ]]; then
    if [[ -z "${CLONE_REMOTE_SITE_ROOT:-}" ]]; then
      echo -e "Не задан ${RED}CLONE_REMOTE_SITE_ROOT${WHITE}."
      return 1
    fi
    if [[ "$CLONE_REMOTE_SITE_ROOT" != "/var/www/${CLONE_REMOTE_USER}/www/${CLONE_REMOTE_SITE}" ]]; then
      echo -e "Исходный site_root ${RED}некорректный${WHITE}: ${CLONE_REMOTE_SITE_ROOT}"
      echo -e "Ожидается: ${YELLOW}/var/www/${CLONE_REMOTE_USER}/www/${CLONE_REMOTE_SITE}${WHITE}"
      return 1
    fi
  fi

  if [[ -z "${CLONE_LOCAL_USER:-}" ]]; then
    echo -e "Не задан ${RED}CLONE_LOCAL_USER${WHITE}."
    return 1
  fi

  if ! validate_site_name "${CLONE_LOCAL_SITE:-}"; then
    echo -e "Имя целевого сайта ${RED}некорректное${WHITE}: ${CLONE_LOCAL_SITE:-}"
    return 1
  fi

  if [[ ! -d "/var/www/${CLONE_LOCAL_USER}" ]]; then
    echo -e "Локальный пользователь ${RED}${CLONE_LOCAL_USER}${WHITE} не найден в /var/www."
    return 1
  fi

  if [[ "${CLONE_PHP_MODE:-ondemand}" != "ondemand" && "${CLONE_PHP_MODE:-ondemand}" != "dynamic" ]]; then
    echo -e "Режим PHP-FPM ${RED}некорректный${WHITE}: ${CLONE_PHP_MODE:-ondemand}"
    return 1
  fi
}

function clone_site_check_remote_source() {
  local remote_root_quoted

  check_clone_ssh_access "$CLONE_SOURCE_HOST" || return 1

  if [[ "${CLONE_COPY_FILES:-1}" == "1" ]]; then
    remote_root_quoted="$(remote_shell_quote "$CLONE_REMOTE_SITE_ROOT")"
    if ! ssh "$CLONE_SOURCE_HOST" "[ -d ${remote_root_quoted} ]"; then
      echo -e "Исходный site_root не найден на сервере ${RED}${CLONE_SOURCE_HOST}${WHITE}: ${RED}${CLONE_REMOTE_SITE_ROOT}${WHITE}"
      return 1
    fi
  fi
}

function clone_site_prepare_target() {
  CLONE_LOCAL_PATH="/var/www/${CLONE_LOCAL_USER}/www"
  CLONE_LOCAL_SITE_ROOT="${CLONE_LOCAL_PATH}/${CLONE_LOCAL_SITE}"
  CLONE_EXPECTED_DOCUMENT_ROOT="$CLONE_LOCAL_SITE_ROOT"
  CLONE_USE_EXISTING_TARGET=0
  CLONE_TARGET_PHP_LABEL=""
  CLONE_TARGET_PHP_FULL_VERSION=""

  if [[ -n "$CLONE_REMOTE_DOCUMENT_ROOT_REL" ]]; then
    CLONE_EXPECTED_DOCUMENT_ROOT="${CLONE_LOCAL_SITE_ROOT}/${CLONE_REMOTE_DOCUMENT_ROOT_REL}"
  fi

  if [[ "${CLONE_COPY_FILES:-1}" != "1" ]]; then
    CLONE_TARGET_PREPARED=1
    return 0
  fi

  if [[ -e "/etc/httpd/conf.d/${CLONE_LOCAL_SITE}.conf" ]]; then
    echo -e "Целевой vhost уже существует: ${YELLOW}${CLONE_LOCAL_SITE}.conf${WHITE}"
    if [[ "${CLONE_REUSE_EXISTING_TARGET:-1}" != "1" ]]; then
      echo "Политика core запрещает использовать существующий vhost."
      return 1
    fi
    if can_use_existing_target_site "$CLONE_LOCAL_SITE" "$CLONE_LOCAL_SITE_ROOT" "$CLONE_EXPECTED_DOCUMENT_ROOT"; then
      CLONE_USE_EXISTING_TARGET=1
      CLONE_TARGET_PHP_LABEL="$(get_local_vhost_php_version "$CLONE_LOCAL_SITE")"
      CLONE_TARGET_PHP_FULL_VERSION="$(get_local_php_full_version "$CLONE_TARGET_PHP_LABEL")"
    else
      return 1
    fi
  elif [[ -d "$CLONE_LOCAL_SITE_ROOT" ]] && ! is_directory_empty "$CLONE_LOCAL_SITE_ROOT"; then
    handle_non_empty_target_site_root "$CLONE_LOCAL_SITE_ROOT" || return 1
  elif [[ "${CLONE_CREATE_SITE:-1}" != "1" ]]; then
    echo -e "Целевой vhost ${RED}/etc/httpd/conf.d/${CLONE_LOCAL_SITE}.conf${WHITE} не найден."
    echo "Политика core запрещает создавать новый сайт."
    return 1
  fi

  CLONE_TARGET_PREPARED=1
}

function clone_site_create_or_reuse_target() {
  if [[ "${CLONE_COPY_FILES:-1}" != "1" ]]; then
    return 0
  fi

  CLONE_TARGET_CREATED=0

  if [[ "$CLONE_USE_EXISTING_TARGET" -eq 1 ]]; then
    return 0
  fi

  if [[ ! "${CLONE_LOCAL_PHP:-}" =~ ^php[0-9]{2}$ ]]; then
    echo -e "Версия PHP для целевого сайта ${RED}некорректная${WHITE}: ${CLONE_LOCAL_PHP:-}"
    return 1
  fi

  echo
  echo -e "Создаем сайт ${GREEN}$(format_site_name_label "$CLONE_LOCAL_SITE")${WHITE}."
  if ! create_site_core "$CLONE_LOCAL_SITE" "$CLONE_LOCAL_PATH" "$CLONE_LOCAL_PHP" "$CLONE_REMOTE_DOCUMENT_ROOT_REL" "$CLONE_PHP_MODE" "$CLONE_RESTART_PHP_FPM" "$CLONE_RELOAD_APACHE" "$CLONE_UPDATE_HOTLIST"; then
    echo -e "Создание целевого сайта ${RED}${CLONE_LOCAL_SITE}${WHITE} не удалось. Перенос файлов не выполнялся."
    return 1
  fi
  CLONE_TARGET_CREATED=1
}

function clone_site_core() {
  local rc=0
  local created_tmp_dir=0
  local target_prepared

  : "${CLONE_COPY_FILES:=1}"
  : "${CLONE_COPY_DB:=1}"
  : "${CLONE_REQUIRE_DB:=0}"
  : "${CLONE_CREATE_SITE:=1}"
  : "${CLONE_REUSE_EXISTING_TARGET:=1}"
  : "${CLONE_PHP_MODE:=ondemand}"
  : "${CLONE_RESTART_PHP_FPM:=1}"
  : "${CLONE_RELOAD_APACHE:=1}"
  : "${CLONE_UPDATE_HOTLIST:=1}"
  : "${CLONE_TARGET_PREPARED:=0}"
  if [[ "$CLONE_TARGET_PREPARED" != "1" ]]; then
    CLONE_TARGET_CREATED=0
    CLONE_TARGET_CLEARED=0
  fi

  target_prepared="$CLONE_TARGET_PREPARED"
  CLONE_TARGET_PREPARED=0
  clone_site_validate_flag "CLONE_TARGET_PREPARED" "$target_prepared" || return 1

  clone_site_validate_core_params || return 1
  clone_site_check_remote_source || return 1

  if [[ "$target_prepared" != "1" ]]; then
    clone_site_prepare_target || return 1
  fi

  if [[ "$CLONE_COPY_DB" == "1" && -z "$CLONE_TMP_DIR" ]]; then
    CLONE_TMP_DIR="$(mktemp -d /tmp/rish-clone.XXXXXX)" || {
      echo -e "Не удалось создать временную папку для клонирования."
      CLONE_TARGET_PREPARED=0
      return 1
    }
    created_tmp_dir=1
  fi

  if ! clone_site_create_or_reuse_target; then
    rc=1
  fi

  if [[ "$rc" -eq 0 && "$CLONE_COPY_FILES" == "1" ]]; then
    if ! copy_site_files "$CLONE_SOURCE_HOST" "$CLONE_REMOTE_SITE_ROOT" "$CLONE_LOCAL_SITE_ROOT" "$CLONE_LOCAL_USER"; then
      echo -e "Сайт ${YELLOW}${CLONE_LOCAL_SITE}${WHITE} уже был создан, но перенос файлов не завершился."
      echo -e "Проверьте ${YELLOW}${CLONE_LOCAL_SITE_ROOT}${WHITE} и vhost ${YELLOW}/etc/httpd/conf.d/${CLONE_LOCAL_SITE}.conf${WHITE}."
      rc=1
    fi
  fi

  if [[ "$rc" -eq 0 && "$CLONE_COPY_DB" == "1" ]]; then
    if [[ "$CLONE_REMOTE_HAS_DB" == "1" ]]; then
      if ! clone_database "$CLONE_SOURCE_HOST" "$CLONE_REMOTE_SITE" "$CLONE_LOCAL_SITE" "$CLONE_LOCAL_USER"; then
        if [[ "$CLONE_COPY_FILES" == "1" ]]; then
          echo -e "Сайт и файлы уже перенесены, но база данных не была импортирована."
        fi
        rc=1
      fi
    elif [[ "$CLONE_REQUIRE_DB" == "1" ]]; then
      echo -e "У сайта ${YELLOW}${CLONE_REMOTE_SITE}${WHITE} база данных не найдена."
      rc=1
    else
      echo -e "База данных для ${YELLOW}${CLONE_REMOTE_SITE}${WHITE} на источнике не найдена."
    fi
  fi

  if [[ "$rc" -eq 0 && "$CLONE_COPY_FILES" == "1" ]]; then
    fix_site_configuration "$CLONE_LOCAL_PATH" "$CLONE_LOCAL_SITE"

    if [[ "${LocalServer:-false}" == "true" ]]; then
      offer_local_self_signed_ssl "$CLONE_LOCAL_SITE" || rc=1
    elif [[ -n "$CLONE_REMOTE_SSL_FILES" ]]; then
      echo
      echo "SSL сертификаты с источника не переносились автоматически."
    fi
  fi

  if [[ "$created_tmp_dir" -eq 1 ]]; then
    cleanup_clone_tmp_dir
    CLONE_TMP_DIR=""
  fi
  CLONE_TARGET_PREPARED=0

  if [[ "$rc" -eq 0 ]]; then
    echo
    if [[ "$CLONE_COPY_FILES" == "1" ]]; then
      if [[ "$CLONE_TARGET_CREATED" == "1" ]]; then
        echo -e "Создан сайт ${GREEN}$(format_site_name_label "$CLONE_LOCAL_SITE")${WHITE} (vhost: ${YELLOW}${CLONE_LOCAL_SITE}.conf${WHITE})."
      elif [[ "$CLONE_USE_EXISTING_TARGET" -eq 1 ]]; then
        echo -e "Использован существующий сайт ${GREEN}$(format_site_name_label "$CLONE_LOCAL_SITE")${WHITE} (vhost: ${YELLOW}${CLONE_LOCAL_SITE}.conf${WHITE})."
      fi
      if [[ "$CLONE_TARGET_CLEARED" == "1" ]]; then
        echo -e "Папка сайта ${GREEN}$(format_site_name_label "$CLONE_LOCAL_SITE")${WHITE} была ${YELLOW}очищена${WHITE} перед переносом файлов."
      fi
      echo -e "Клонирование сайта ${GREEN}$(format_site_name_label "$CLONE_LOCAL_SITE")${WHITE} завершено."
    else
      echo -e "Клонирование базы данных ${GREEN}${CLONE_LOCAL_SITE}${WHITE} завершено."
    fi
  fi

  return "$rc"
}

function clone_site_interactive() {
  local mode="$1"
  local proposed_site
  local target_php_label
  local target_php_full_version

  if [[ -f "${RISH_HOME}/rish_config.sh" ]]; then
    # shellcheck disable=SC1091
    source "${RISH_HOME}/rish_config.sh"
  fi

  if [[ "$mode" == "Mysql" ]]; then
    echo "Клонируем только базу данных."
  fi

  select_clone_server || return 1
  check_clone_ssh_access "$CLONE_SOURCE_HOST" || return 1
  select_remote_site "$CLONE_SOURCE_HOST" || return 1
  inspect_remote_site "$CLONE_SOURCE_HOST" "$CLONE_REMOTE_SITE" "$CLONE_REMOTE_USER" || return 1
  select_local_user || return 1

  proposed_site="$(default_local_site_name "$CLONE_REMOTE_SITE")"
  confirm_local_site_name "$proposed_site" || return 1

  CLONE_COPY_FILES=1
  CLONE_COPY_DB=1
  CLONE_REQUIRE_DB=0
  CLONE_CREATE_SITE=1
  CLONE_REUSE_EXISTING_TARGET=1
  CLONE_RESTART_PHP_FPM=1
  CLONE_RELOAD_APACHE=1
  CLONE_UPDATE_HOTLIST=1
  CLONE_TARGET_PREPARED=0
  CLONE_TARGET_CREATED=0
  CLONE_TARGET_CLEARED=0
  CLONE_USE_EXCLUDES=0
  CLONE_EXCLUDE_DIRS=()

  echo
  if [[ "$mode" == "Mysql" ]]; then
    CLONE_COPY_FILES=0
    CLONE_COPY_DB=1
    CLONE_REQUIRE_DB=1
    CLONE_CREATE_SITE=0
    clone_site_prepare_target || return 1
    clear
    print_clone_summary_pair "" "" "database"
    clone_site_core
    return $?
  fi

  if [[ "$mode" == "Exclude" ]]; then
    CLONE_USE_EXCLUDES=1
    select_clone_exclude_dirs || return 1
  fi

  clone_site_prepare_target || return 1

  if [[ "$CLONE_USE_EXISTING_TARGET" -eq 0 ]]; then
    select_clone_php_version "$CLONE_REMOTE_PHP_VERSION" || return 1
    select_clone_php_mode || return 1
    target_php_label="$CLONE_LOCAL_PHP"
    target_php_full_version="$(get_local_php_full_version "$CLONE_LOCAL_PHP")"
  else
    target_php_label="$CLONE_TARGET_PHP_LABEL"
    target_php_full_version="$CLONE_TARGET_PHP_FULL_VERSION"
  fi

  clear
  print_clone_summary_pair "$target_php_label" "$target_php_full_version"

  clone_site_core
}

function CloneSite() {
  local rc

  clear
  CLONE_TMP_DIR="$(mktemp -d /tmp/rish-clone.XXXXXX)" || {
    echo -e "Не удалось создать временную папку для клонирования."
    return 1
  }

  clone_site_interactive "$@"
  rc=$?
  cleanup_clone_tmp_dir
  CLONE_TMP_DIR=""
  return "$rc"
}

function clone_site_menu() {
  local choice

  clear
  echo "Выберите сценарий клонирования:"
  vertical_menu "current" 2 0 45 "Клонирование сайта" "Клонирование сайта с исключением выбранных папок" "Клонирование только базы данных сайта" "Выйти"
  choice=$?
  case "$choice" in
    0)
      CloneSite
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      ;;
    1)
      CloneSite "Exclude"
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      ;;
    2)
      CloneSite "Mysql"
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      ;;
    *) return 0 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  clone_site_menu
fi
