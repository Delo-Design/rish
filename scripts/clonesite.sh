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
  echo "Теперь нужно выбрать локальное имя SSH host."
  read -r -e -p " " server_name
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
  local -a sites=()

  echo -e "Получаем список сайтов удаленного сервера ${GREEN}${host}${WHITE}."
  mapfile -t sites < <(
    ssh "$host" 'for site in /var/www/*/www/*; do
      [ -d "$site" ] || continue
      case "$(basename "$site")" in 000-default) continue ;; esac
      user="${site#/var/www/}"
      user="${user%%/*}"
      printf "%s (%s)\n" "$(basename "$site")" "$user"
    done' | sort
  )

  if (( ${#sites[@]} == 0 )); then
    echo -e "На сервере ${YELLOW}${host}${WHITE} сайты в /var/www/<user>/www не найдены."
    return 1
  fi

  vertical_menu "current" 2 20 40 "${sites[@]}"
  choice=$?
  if (( choice == 255 )); then
    return 1
  fi

  CLONE_REMOTE_SITE="${sites[$choice]%% *}"
  if ! validate_site_name "$CLONE_REMOTE_SITE"; then
    echo -e "Выбранная папка ${RED}${CLONE_REMOTE_SITE}${WHITE} не является корректным именем сайта."
    return 1
  fi
  CLONE_REMOTE_USER="${sites[$choice]#*(}"
  CLONE_REMOTE_USER="${CLONE_REMOTE_USER%)}"
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
  if [[ -n "$CLONE_REMOTE_SSL_FILES" ]]; then
    echo -e "На источнике найдены SSL-ссылки: ${YELLOW}${CLONE_REMOTE_SSL_FILES}${WHITE}"
    echo "Автоматический перенос SSL в первом этапе не выполняется."
  fi
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
  local site_name

  echo -e "${WHITE}Подтвердите имя сайта для клонирования:${GREEN}"
  read -r -e -i "$proposed" site_name
  echo -e "${WHITE}"

  if [[ -z "$site_name" ]]; then
    return 1
  fi
  site_name="${site_name,,}"
  if ! validate_site_name "$site_name"; then
    echo -e "Имя сайта ${RED}${site_name}${WHITE} некорректное."
    return 1
  fi

  CLONE_LOCAL_SITE="$site_name"
}

function is_directory_empty() {
  local directory="$1"

  [[ -d "$directory" ]] || return 0
  [[ -z "$(find "$directory" -mindepth 1 \( -type f -o -type l \) -print -quit 2>/dev/null)" ]]
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

  if ! is_directory_empty "$site_root"; then
    echo -e "Целевая папка сайта уже содержит файлы: ${RED}${site_root}${WHITE}"
    echo "Политика первого этапа: не перезаписывать существующие файлы сайта."
    return 1
  fi

  if [[ ! -d "$site_root" ]]; then
    echo -e "Создаем пустой site_root для существующего vhost: ${GREEN}${site_root}${WHITE}"
    if ! mkdir -p "$site_root"; then
      echo -e "Не удалось создать site_root: ${RED}${site_root}${WHITE}"
      return 1
    fi
  fi

  echo -e "Существующий vhost ${GREEN}${conf_file}${WHITE} указывает на ожидаемый DocumentRoot."
  echo "Используем существующий сайт и продолжаем перенос файлов."
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

function copy_site_files() {
  local host="$1"
  local remote_site_root="$2"
  local local_site_root="$3"
  local local_user="$4"
  local size_bytes
  local size_mb
  local remote_root_quoted

  echo
  echo -e "Переносим файлы сайта в site_root: ${GREEN}${local_site_root}${WHITE}"
  remote_root_quoted="$(remote_shell_quote "$remote_site_root")"

  size_bytes="$(ssh "$host" "du -sb ${remote_root_quoted} 2>/dev/null | awk '{print \$1}'")"
  if [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
    size_mb=$(( (size_bytes + 1024 * 1024 - 1) / (1024 * 1024) ))
    echo -e "Размер исходного сайта: ${YELLOW}${size_mb} MB${WHITE}"
  else
    echo -e "Размер исходного сайта ${YELLOW}определить не удалось${WHITE}."
  fi

  echo "Передача выполняется tar-потоком через SSH со сжатием."
  if command -v pv >/dev/null 2>&1 && [[ "$size_bytes" =~ ^[0-9]+$ ]]; then
    if ! (set -o pipefail; ssh -C "$host" "tar -C ${remote_root_quoted} -cf - ." | pv -s "$size_bytes" | tar -C "$local_site_root" -xf -); then
      echo -e "Ошибка при переносе файлов сайта tar-потоком."
      return 1
    fi
  else
    if ! command -v pv >/dev/null 2>&1; then
      echo -e "${YELLOW}pv не установлен${WHITE}, прогресс передачи не будет показан."
    fi
    echo "Перенос продолжается, дождитесь завершения."
    if ! (set -o pipefail; ssh -C "$host" "tar -C ${remote_root_quoted} -cf - ." | tar -C "$local_site_root" -xf -); then
      echo -e "Ошибка при переносе файлов сайта tar-потоком."
      return 1
    fi
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
  echo -e "Переносим базу данных ${GREEN}${remote_db}${WHITE} -> ${GREEN}${local_db}${WHITE}."
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

function clone_site_run() {
  local only_database="$1"
  local proposed_site
  local local_path
  local local_site_root
  local expected_document_root
  local existing_php
  local existing_php_full_version
  local target_php_label
  local target_php_full_version
  local restart_php_fpm=1
  local reload_apache=1
  local update_hotlist=1
  local use_existing_target=0

  if [[ -f "${RISH_HOME}/rish_config.sh" ]]; then
    # shellcheck disable=SC1091
    source "${RISH_HOME}/rish_config.sh"
  fi

  if [[ -n "$only_database" ]]; then
    echo "Клонируем только базу данных."
  fi

  select_clone_server || return 1
  check_clone_ssh_access "$CLONE_SOURCE_HOST" || return 1
  select_remote_site "$CLONE_SOURCE_HOST" || return 1
  inspect_remote_site "$CLONE_SOURCE_HOST" "$CLONE_REMOTE_SITE" "$CLONE_REMOTE_USER" || return 1
  select_local_user || return 1

  proposed_site="$(default_local_site_name "$CLONE_REMOTE_SITE")"
  confirm_local_site_name "$proposed_site" || return 1

  local_path="/var/www/${CLONE_LOCAL_USER}/www"
  local_site_root="${local_path}/${CLONE_LOCAL_SITE}"
  expected_document_root="$local_site_root"
  if [[ -n "$CLONE_REMOTE_DOCUMENT_ROOT_REL" ]]; then
    expected_document_root="${local_site_root}/${CLONE_REMOTE_DOCUMENT_ROOT_REL}"
  fi

  echo
  if [[ -n "$only_database" ]]; then
    clear
    print_clone_summary_pair "" "" "database"
    if [[ "$CLONE_REMOTE_HAS_DB" != "1" ]]; then
      echo -e "У сайта ${YELLOW}${CLONE_REMOTE_SITE}${WHITE} база данных не найдена."
      return 1
    fi
    clone_database "$CLONE_SOURCE_HOST" "$CLONE_REMOTE_SITE" "$CLONE_LOCAL_SITE" "$CLONE_LOCAL_USER"
    return $?
  fi

  if [[ -e "/etc/httpd/conf.d/${CLONE_LOCAL_SITE}.conf" ]]; then
    echo -e "Целевой vhost уже существует: ${YELLOW}/etc/httpd/conf.d/${CLONE_LOCAL_SITE}.conf${WHITE}"
    if can_use_existing_target_site "$CLONE_LOCAL_SITE" "$local_site_root" "$expected_document_root"; then
      use_existing_target=1
      existing_php="$(get_local_vhost_php_version "$CLONE_LOCAL_SITE")"
      existing_php_full_version="$(get_local_php_full_version "$existing_php")"
      if [[ -n "$existing_php" ]]; then
        echo -e "Существующий vhost использует PHP: ${GREEN}${existing_php}${WHITE}"
      else
        echo -e "Версию PHP в существующем vhost ${YELLOW}определить не удалось${WHITE}."
      fi
    else
      echo "Перенос остановлен."
      return 1
    fi
  elif [[ -d "$local_site_root" ]] && ! is_directory_empty "$local_site_root"; then
    echo -e "Целевая папка сайта уже содержит файлы: ${RED}${local_site_root}${WHITE}"
    echo "Политика первого этапа: не перезаписывать существующие файлы сайта."
    return 1
  fi

  if [[ "$use_existing_target" -eq 0 ]]; then
    select_clone_php_version "$CLONE_REMOTE_PHP_VERSION" || return 1
    select_clone_php_mode || return 1
    target_php_label="$CLONE_LOCAL_PHP"
    target_php_full_version="$(get_local_php_full_version "$CLONE_LOCAL_PHP")"
  else
    target_php_label="$existing_php"
    target_php_full_version="$existing_php_full_version"
  fi

  clear
  print_clone_summary_pair "$target_php_label" "$target_php_full_version"

  if [[ "$use_existing_target" -eq 0 ]]; then
    echo
    echo -e "Создаем целевой сайт через ${GREEN}create_site_core${WHITE}."
    if ! create_site_core "$CLONE_LOCAL_SITE" "$local_path" "$CLONE_LOCAL_PHP" "$CLONE_REMOTE_DOCUMENT_ROOT_REL" "$CLONE_PHP_MODE" "$restart_php_fpm" "$reload_apache" "$update_hotlist"; then
      echo -e "Создание целевого сайта ${RED}${CLONE_LOCAL_SITE}${WHITE} не удалось. Перенос файлов не выполнялся."
      return 1
    fi
  fi

  if ! copy_site_files "$CLONE_SOURCE_HOST" "$CLONE_REMOTE_SITE_ROOT" "$local_site_root" "$CLONE_LOCAL_USER"; then
    echo -e "Сайт ${YELLOW}${CLONE_LOCAL_SITE}${WHITE} уже был создан, но перенос файлов не завершился."
    echo -e "Проверьте ${YELLOW}${local_site_root}${WHITE} и vhost ${YELLOW}/etc/httpd/conf.d/${CLONE_LOCAL_SITE}.conf${WHITE}."
    return 1
  fi

  if [[ "$CLONE_REMOTE_HAS_DB" == "1" ]]; then
    if ! clone_database "$CLONE_SOURCE_HOST" "$CLONE_REMOTE_SITE" "$CLONE_LOCAL_SITE" "$CLONE_LOCAL_USER"; then
      echo -e "Сайт и файлы уже перенесены, но база данных не была импортирована."
      return 1
    fi
  else
    echo -e "База данных для ${YELLOW}${CLONE_REMOTE_SITE}${WHITE} на источнике не найдена."
  fi

  fix_site_configuration "$local_path" "$CLONE_LOCAL_SITE"

  if [[ "${LocalServer:-false}" == "true" ]]; then
    echo
    echo "Self-signed SSL для локального сайта в первом этапе не создается автоматически."
    echo "Его лучше вынести в отдельную функцию после стабилизации базового переноса."
  elif [[ -n "$CLONE_REMOTE_SSL_FILES" ]]; then
    echo
    echo "Server -> server: SSL сертификаты не переносились автоматически."
    echo -e "Проверьте сертификаты/ключи источника: ${YELLOW}${CLONE_REMOTE_SSL_FILES}${WHITE}"
  fi

  echo
  echo -e "Клонирование сайта ${GREEN}${CLONE_LOCAL_SITE}${WHITE} завершено."
}

function CloneSite() {
  local rc

  clear
  CLONE_TMP_DIR="$(mktemp -d /tmp/rish-clone.XXXXXX)" || {
    echo -e "Не удалось создать временную папку для клонирования."
    return 1
  }

  clone_site_run "$@"
  rc=$?
  cleanup_clone_tmp_dir
  CLONE_TMP_DIR=""
  return "$rc"
}

function clone_site_menu() {
  local choice

  clear
  echo "Выберите сценарий клонирования:"
  vertical_menu "current" 2 0 45 "Клонирование сайта" "Клонирование только базы данных сайта" "Выйти"
  choice=$?
  case "$choice" in
    0)
      CloneSite
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      ;;
    1)
      CloneSite "Mysql"
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      ;;
    *) return 0 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  clone_site_menu
fi
