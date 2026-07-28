#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
WHITE='\033[0m'

RISH_HOME="${RISH_HOME:-/root/rish}"
RISH_COMPOSER_RUNTIME_DIR="${RISH_HOME}/composer"
RISH_COMPOSER_MARKER="${RISH_COMPOSER_RUNTIME_DIR}/.enabled"
RISH_COMPOSER_BIN="/usr/local/bin/composer"

source "${RISH_HOME}/windows.sh"
source "${RISH_HOME}/php_helpers.sh"
source "${RISH_HOME}/scripts/site_helpers.sh"

if [[ -f "${RISH_HOME}/rish_config.sh" ]]; then
  # shellcheck disable=SC1091
  source "${RISH_HOME}/rish_config.sh"
fi
LocalServer="${LocalServer:-false}"

wait_for_enter() {
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}

composer_is_local_server() {
  [[ "$LocalServer" == "true" ]]
}

composer_management_is_enabled() {
  [[ -x "$RISH_COMPOSER_MARKER" ]]
}

composer_binary_exists() {
  [[ -e "$RISH_COMPOSER_BIN" || -L "$RISH_COMPOSER_BIN" ]]
}

composer_binary_is_trusted() {
  local owner
  local mode

  [[ -f "$RISH_COMPOSER_BIN" && ! -L "$RISH_COMPOSER_BIN" && -x "$RISH_COMPOSER_BIN" ]] || return 1

  owner="$(stat -c '%u' "$RISH_COMPOSER_BIN" 2>/dev/null)" || return 1
  mode="$(stat -c '%a' "$RISH_COMPOSER_BIN" 2>/dev/null)" || return 1
  [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3}$ ]] || return 1

  (( (8#$mode & 18) == 0 && (8#$mode & 5) == 5 ))
}

get_php_version_id_for_bin() {
  local php_bin="$1"
  local php_version_id

  [[ -x "$php_bin" ]] || return 1
  php_version_id="$("$php_bin" -r 'echo PHP_VERSION_ID;' 2>/dev/null)" || return 1
  [[ "$php_version_id" =~ ^[0-9]+$ ]] || return 1

  printf '%s\n' "$php_version_id"
}

composer_php_bin_is_supported() {
  local php_version_id

  php_version_id="$(get_php_version_id_for_bin "$1")" || return 1
  ((php_version_id >= 70205))
}

get_preferred_composer_php_bin() {
  local php_version
  local php_bin
  local seen=" "
  local -a candidates=()

  while IFS= read -r php_version; do
    [[ -n "$php_version" ]] || continue
    candidates+=(
      "/bin/${php_version}"
      "/usr/bin/${php_version}"
      "/opt/remi/${php_version}/root/usr/bin/php"
    )
  done < <(get_installed_php_versions)

  if command -v php > /dev/null 2>&1; then
    candidates+=("$(command -v php)")
  fi

  for php_bin in "${candidates[@]}"; do
    [[ -x "$php_bin" ]] || continue
    [[ "$seen" != *" ${php_bin} "* ]] || continue
    seen+="${php_bin} "

    if composer_php_bin_is_supported "$php_bin"; then
      printf '%s\n' "$php_bin"
      return 0
    fi
  done

  return 1
}

get_composer_version_for_file() {
  local php_bin="$1"
  local composer_file="$2"
  local version_output
  local version_line

  version_output="$("$php_bin" "$composer_file" --version --no-ansi 2>&1)" || return 1
  version_line="$(
    printf '%s\n' "$version_output" |
      grep -m 1 -E '^Composer version [0-9]+(\.[0-9]+)+([[:space:]]|$)'
  )" || return 1
  printf '%s\n' "$version_line"
}

get_composer_version() {
  get_composer_version_for_file "$1" "$RISH_COMPOSER_BIN"
}

composer_version_is_supported() {
  [[ "$1" =~ ^Composer[[:space:]]version[[:space:]]2\. ]]
}

print_composer_status() {
  local php_bin
  local composer_version

  if composer_management_is_enabled; then
    echo -e "Управление ${GREEN}Composer${WHITE}: ${GREEN}включено${WHITE}"
  else
    echo -e "Управление ${GREEN}Composer${WHITE}: ${YELLOW}выключено${WHITE}"
  fi

  if ! composer_binary_exists; then
    echo -e "Composer: ${YELLOW}не установлен${WHITE}"
    return 0
  fi
  if ! composer_binary_is_trusted; then
    echo -e "Composer: ${RED}небезопасные владелец, права или тип файла${WHITE}"
    echo -e "Путь: ${YELLOW}${RISH_COMPOSER_BIN}${WHITE}"
    return 1
  fi
  if ! php_bin="$(get_preferred_composer_php_bin)"; then
    echo -e "Composer установлен, но не найден совместимый ${RED}PHP CLI${WHITE}."
    return 1
  fi
  if ! composer_version="$(get_composer_version "$php_bin")"; then
    echo -e "Composer установлен, но проверка завершилась с ${RED}ошибкой${WHITE}."
    return 1
  fi
  if ! composer_version_is_supported "$composer_version"; then
    echo -e "Composer установлен, но версия ${RED}не поддерживается${WHITE}: ${composer_version}"
    echo "Для работы RISH требуется Composer 2."
    return 1
  fi

  echo -e "Composer: ${GREEN}${composer_version}${WHITE}"
  echo -e "Путь: ${YELLOW}${RISH_COMPOSER_BIN}${WHITE}"
}

cleanup_composer_install_files() {
  local temp_dir="$1"
  local target_temp="$2"

  if [[ -n "$target_temp" ]]; then
    rm -f -- "$target_temp"
  fi
  if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
    rm -f -- "${temp_dir}/composer-setup.php" "${temp_dir}/composer"
    rmdir -- "$temp_dir" 2>/dev/null || true
  fi
}

install_composer() {
  local php_bin
  local temp_dir=""
  local installer
  local downloaded_composer
  local expected_checksum
  local actual_checksum
  local target_temp=""
  local installed_version

  if composer_binary_exists && ! composer_binary_is_trusted; then
    echo -e "Файл ${YELLOW}${RISH_COMPOSER_BIN}${WHITE} уже существует, но не прошел проверку безопасности."
    echo "RISH не будет автоматически заменять этот файл."
    return 1
  fi
  if ! php_bin="$(get_preferred_composer_php_bin)"; then
    echo -e "Не найден PHP CLI версии ${RED}7.2.5 или новее${WHITE}."
    return 1
  fi
  if ! command -v curl > /dev/null 2>&1 || ! command -v sha384sum > /dev/null 2>&1; then
    echo -e "Для установки Composer требуются ${RED}curl${WHITE} и ${RED}sha384sum${WHITE}."
    return 1
  fi
  if ! temp_dir="$(mktemp -d /tmp/rish-composer.XXXXXX)"; then
    echo -e "Не удалось создать временный каталог для ${RED}Composer${WHITE}."
    return 1
  fi

  installer="${temp_dir}/composer-setup.php"
  downloaded_composer="${temp_dir}/composer"

  echo "Получаем контрольную сумму установщика Composer..."
  if ! expected_checksum="$(curl -fsSL --connect-timeout 15 --max-time 60 https://composer.github.io/installer.sig)"; then
    echo -e "Не удалось получить контрольную сумму установщика ${RED}Composer${WHITE}."
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  fi
  expected_checksum="$(printf '%s' "$expected_checksum" | tr -d '[:space:]')"
  if [[ ! "$expected_checksum" =~ ^[a-fA-F0-9]{96}$ ]]; then
    echo -e "Получена ${RED}некорректная${WHITE} контрольная сумма установщика Composer."
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  fi

  echo "Скачиваем установщик Composer..."
  if ! curl -fsSL --connect-timeout 15 --max-time 120 https://getcomposer.org/installer -o "$installer"; then
    echo -e "Не удалось скачать установщик ${RED}Composer${WHITE}."
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  fi

  actual_checksum="$(sha384sum "$installer")" || {
    echo -e "Не удалось вычислить контрольную сумму установщика ${RED}Composer${WHITE}."
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  }
  actual_checksum="${actual_checksum%% *}"
  if [[ "${actual_checksum,,}" != "${expected_checksum,,}" ]]; then
    echo -e "Контрольная сумма установщика ${RED}Composer не совпадает${WHITE}."
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  fi

  echo -e "Устанавливаем ${GREEN}Composer${WHITE} через ${GREEN}${php_bin}${WHITE}..."
  if ! "$php_bin" "$installer" --2 --install-dir="$temp_dir" --filename=composer; then
    echo -e "Установщик ${RED}Composer${WHITE} завершился с ошибкой."
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  fi
  if ! installed_version="$(get_composer_version_for_file "$php_bin" "$downloaded_composer")"; then
    echo -e "Загруженный Composer не прошел ${RED}проверку запуска${WHITE}."
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  fi
  if ! composer_version_is_supported "$installed_version"; then
    echo -e "Установщик загрузил ${RED}неподдерживаемую версию${WHITE}: ${installed_version}"
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  fi

  if ! target_temp="$(mktemp /usr/local/bin/.composer.rish.XXXXXX)"; then
    echo -e "Не удалось подготовить файл в ${RED}/usr/local/bin${WHITE}."
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  fi
  if ! install -m 755 -o root -g root "$downloaded_composer" "$target_temp" ||
    ! mv -f -- "$target_temp" "$RISH_COMPOSER_BIN"; then
    echo -e "Не удалось установить Composer в ${RED}${RISH_COMPOSER_BIN}${WHITE}."
    cleanup_composer_install_files "$temp_dir" "$target_temp"
    return 1
  fi
  target_temp=""
  cleanup_composer_install_files "$temp_dir" "$target_temp"

  echo -e "Composer ${GREEN}установлен${WHITE}: ${installed_version%%$'\n'*}"
}

ensure_composer_is_ready() {
  local php_bin
  local composer_version

  if composer_binary_exists; then
    if ! composer_binary_is_trusted; then
      echo -e "Файл ${RED}${RISH_COMPOSER_BIN}${WHITE} не прошел проверку безопасности."
      return 1
    fi
    if php_bin="$(get_preferred_composer_php_bin)" &&
      composer_version="$(get_composer_version "$php_bin")" &&
      composer_version_is_supported "$composer_version"; then
      return 0
    fi
    echo -e "Установленный Composer не запускается или имеет неподдерживаемую версию."
    echo -e "Выполняется ${YELLOW}переустановка Composer 2${WHITE}."
  fi

  install_composer
}

enable_composer_management() {
  if ! ensure_composer_is_ready; then
    return 1
  fi
  if ! install -d -m 700 -o root -g root "$RISH_COMPOSER_RUNTIME_DIR" ||
    ! install -m 700 -o root -g root /dev/null "$RISH_COMPOSER_MARKER"; then
    echo -e "Не удалось создать признак управления ${RED}Composer${WHITE}."
    return 1
  fi

  echo -e "Управление ${GREEN}Composer включено${WHITE}."
  echo "Пункт Composer появится в меню MC для каталогов сайтов."
}

disable_composer_management() {
  if ! rm -f -- "$RISH_COMPOSER_MARKER"; then
    echo -e "Не удалось отключить управление ${RED}Composer${WHITE}."
    return 1
  fi

  echo -e "Управление ${GREEN}Composer выключено${WHITE}."
  echo "Сам Composer и файлы проектов не удалены."
}

check_composer() {
  local php_bin
  local composer_version

  if ! composer_binary_is_trusted; then
    echo -e "Composer в ${RED}${RISH_COMPOSER_BIN}${WHITE} не найден или не прошел проверку безопасности."
    return 1
  fi
  if ! php_bin="$(get_preferred_composer_php_bin)"; then
    echo -e "Не найден совместимый ${RED}PHP CLI${WHITE}."
    return 1
  fi
  if ! composer_version="$(get_composer_version "$php_bin")"; then
    echo -e "Composer не запускается через ${RED}${php_bin}${WHITE}."
    return 1
  fi
  if ! composer_version_is_supported "$composer_version"; then
    echo -e "Установлена ${RED}неподдерживаемая версия${WHITE}: ${composer_version}"
    echo "Для работы RISH требуется Composer 2."
    return 1
  fi

  echo -e "Проверка ${GREEN}Composer${WHITE} выполнена."
  echo -e "PHP CLI: ${GREEN}${php_bin}${WHITE}"
  echo -e "Версия: ${GREEN}${composer_version}${WHITE}"
}

remove_composer() {
  echo -e "Будет удален только ${YELLOW}${RISH_COMPOSER_BIN}${WHITE} и признак включения."
  echo "Файлы composer.json, composer.lock и vendor в проектах останутся."
  echo "Продолжить?"
  vertical_menu "current" 2 0 5 "Нет" "Да"
  if (( $? != 1 )); then
    echo "Удаление Composer отменено."
    return 0
  fi

  if ! rm -f -- "$RISH_COMPOSER_MARKER" "$RISH_COMPOSER_BIN"; then
    echo -e "Не удалось удалить ${RED}Composer${WHITE}."
    return 1
  fi

  echo -e "Composer ${GREEN}удален${WHITE}. Файлы проектов не изменялись."
}

server_menu() {
  local choice
  local action
  local -a menu_items
  local -a menu_actions

  while true; do
    clear
    echo "Управление Composer"
    echo
    print_composer_status
    echo

    menu_items=()
    menu_actions=()
    if composer_management_is_enabled; then
      menu_items+=("Проверить Composer" "Установить последнюю версию Composer 2" "Выключить управление Composer")
      menu_actions+=("check" "install" "disable")
    else
      menu_items+=("Включить управление Composer")
      menu_actions+=("enable")
      if composer_binary_exists; then
        menu_items+=("Установить последнюю версию Composer 2")
        menu_actions+=("install")
      fi
    fi
    if composer_binary_exists; then
      menu_items+=("Удалить Composer")
      menu_actions+=("remove")
    fi
    menu_items+=("Выйти")
    menu_actions+=("exit")

    vertical_menu "current" 2 0 38 "${menu_items[@]}"
    choice=$?
    if (( choice == 255 )); then
      return 0
    fi
    action="${menu_actions[${choice}]}"

    echo
    case "$action" in
      check)
        check_composer
        ;;
      install)
        install_composer
        ;;
      enable)
        enable_composer_management
        ;;
      disable)
        disable_composer_management
        ;;
      remove)
        remove_composer
        ;;
      *)
        return 0
        ;;
    esac
    echo
    wait_for_enter
  done
}

run_composer_for_site() {
  local site_user="$1"
  local site_home="$2"
  local php_bin="$3"
  local project_path="$4"
  local php_command_name
  local php_runtime_dir
  local -a clean_environment
  shift 4

  php_command_name="${php_bin##*/}"
  if [[ "$php_command_name" =~ ^php[0-9]{2}$ ]] &&
    [[ -x "/opt/remi/${php_command_name}/root/usr/bin/php" ]]; then
    php_runtime_dir="/opt/remi/${php_command_name}/root/usr/bin"
  else
    php_runtime_dir="${php_bin%/*}"
  fi

  clean_environment=(
    "HOME=${site_home}"
    "USER=${site_user}"
    "LOGNAME=${site_user}"
    "PATH=${php_runtime_dir}:/usr/local/bin:/usr/bin:/bin"
    "LANG=${LANG:-C.UTF-8}"
  )
  if [[ -n "${TERM:-}" ]]; then
    clean_environment+=("TERM=${TERM}")
  fi

  (
    cd "$project_path" || exit 1
    runuser -u "$site_user" -- \
      env -i "${clean_environment[@]}" \
      "$php_bin" "$RISH_COMPOSER_BIN" "$@"
  )
}

confirm_composer_project_action() {
  local site_user="$1"
  local site_home="$2"
  local php_bin="$3"
  local project_path="$4"
  local action_description="$5"
  shift 5

  echo "$action_description"
  echo "Composer plugins и scripts проекта могут выполнить код от имени владельца сайта."
  echo "Продолжить?"
  vertical_menu "current" 2 0 5 "Нет" "Да"
  if (( $? != 1 )); then
    echo "Действие Composer отменено."
    return 0
  fi

  run_composer_for_site "$site_user" "$site_home" "$php_bin" "$project_path" "$@"
}

site_menu() {
  local directory="${1%/}"
  local site_name="$2"
  local selected_site_path="${directory}/${site_name}"
  local canonical_directory
  local site_root_path
  local document_root
  local project_path
  local php_bin
  local site_user
  local site_home
  local composer_version
  local choice
  local action
  local -a menu_items
  local -a menu_actions

  clear

  if ! composer_management_is_enabled; then
    echo -e "Управление ${YELLOW}Composer${WHITE} выключено."
    echo "Включите его через пункт «Управление сервером»."
    wait_for_enter
    return 1
  fi
  if [[ ! "$directory" =~ ^/var/www/[^/]+/www$ ]] ||
    ! validate_site_name "$site_name" ||
    [[ ! -d "$selected_site_path" ]]; then
    echo -e "Установите курсор на ${RED}папку сайта${WHITE} в /var/www/<user>/www."
    wait_for_enter
    return 1
  fi
  if ! canonical_directory="$(realpath -e -- "$directory" 2>/dev/null)" ||
    ! site_root_path="$(realpath -e -- "$selected_site_path" 2>/dev/null)"; then
    echo -e "Не удалось определить фактический путь сайта ${RED}${site_name}${WHITE}."
    wait_for_enter
    return 1
  fi
  if [[ ! "$canonical_directory" =~ ^/var/www/[^/]+/www$ ]] ||
    [[ "$site_root_path" != "$canonical_directory/"* ]]; then
    echo -e "Фактический путь сайта ${RED}выходит за пределы${WHITE} каталога пользователя."
    echo -e "Каталог пользователя: ${GREEN}${canonical_directory}${WHITE}"
    echo -e "Путь сайта: ${GREEN}${site_root_path}${WHITE}"
    wait_for_enter
    return 1
  fi
  if ! document_root="$(rish_get_site_document_root "$site_name")"; then
    echo -e "Не удалось определить DocumentRoot сайта ${RED}${site_name}${WHITE}."
    wait_for_enter
    return 1
  fi
  if [[ "$document_root" != "$site_root_path" && "$document_root" != "$site_root_path/"* ]]; then
    echo -e "DocumentRoot сайта ${RED}не относится${WHITE} к выбранной папке."
    echo -e "Выбрано: ${GREEN}${site_root_path}${WHITE}"
    echo -e "DocumentRoot: ${GREEN}${document_root}${WHITE}"
    wait_for_enter
    return 1
  fi
  if ! php_bin="$(get_site_php_bin "$site_name")"; then
    echo -e "Не удалось определить PHP сайта ${RED}${site_name}${WHITE}."
    wait_for_enter
    return 1
  fi
  if ! composer_php_bin_is_supported "$php_bin"; then
    echo -e "Composer для сайта ${RED}${site_name}${WHITE} недоступен."
    echo -e "PHP сайта: ${YELLOW}${php_bin}${WHITE}"
    echo "Для актуальной версии Composer 2 требуется PHP 7.2.5 или новее."
    echo "Сначала смените версию PHP сайта."
    wait_for_enter
    return 1
  fi
  if ! site_user="$(rish_get_site_user "$site_root_path")"; then
    echo -e "Не удалось определить владельца сайта ${RED}${site_name}${WHITE}."
    wait_for_enter
    return 1
  fi
  site_home="$(getent passwd "$site_user" | awk -F: '{ print $6; exit }')"
  if [[ -z "$site_home" || ! -d "$site_home" ]]; then
    echo -e "Не удалось определить домашний каталог пользователя ${RED}${site_user}${WHITE}."
    wait_for_enter
    return 1
  fi
  if ! composer_binary_is_trusted; then
    echo -e "Composer в ${RED}${RISH_COMPOSER_BIN}${WHITE} отсутствует или не прошел проверку безопасности."
    echo "Переустановите его через пункт «Управление сервером»."
    wait_for_enter
    return 1
  fi

  if [[ -f "${site_root_path}/composer.json" ]]; then
    project_path="$site_root_path"
  elif [[ -f "${document_root}/composer.json" ]]; then
    project_path="$document_root"
  else
    echo -e "В папке сайта не найден ${YELLOW}composer.json${WHITE}."
    if [[ "$document_root" == "$site_root_path" ]]; then
      echo -e "Проверено: ${YELLOW}${site_root_path}${WHITE}."
    else
      echo -e "Проверены: ${YELLOW}${site_root_path}${WHITE} и ${YELLOW}${document_root}${WHITE}."
    fi
    wait_for_enter
    return 1
  fi
  if ! project_path="$(realpath -e -- "$project_path" 2>/dev/null)" ||
    [[ "$project_path" != "$site_root_path" && "$project_path" != "$site_root_path/"* ]]; then
    echo -e "Папка проекта ${RED}выходит за пределы${WHITE} выбранного сайта."
    wait_for_enter
    return 1
  fi
  if ! composer_version="$(get_composer_version "$php_bin")"; then
    echo -e "Composer не запускается через PHP сайта ${RED}${php_bin}${WHITE}."
    wait_for_enter
    return 1
  fi
  if ! composer_version_is_supported "$composer_version"; then
    echo -e "Установлена ${RED}неподдерживаемая версия${WHITE}: ${composer_version}"
    echo "Переустановите Composer 2 через пункт «Управление сервером»."
    wait_for_enter
    return 1
  fi

  while true; do
    clear
    echo -e "Composer для сайта: ${GREEN}${site_name}${WHITE}"
    echo
    echo -e "Папка проекта: ${GREEN}${project_path}${WHITE}"
    echo -e "Владелец: ${GREEN}${site_user}${WHITE}"
    echo -e "PHP сайта: ${GREEN}${php_bin}${WHITE}"
    echo -e "Composer: ${GREEN}${composer_version}${WHITE}"
    if composer_is_local_server; then
      echo -e "Режим сервера: ${YELLOW}локальная разработка${WHITE}"
    else
      echo -e "Режим сервера: ${GREEN}production${WHITE}"
    fi
    if [[ ! -f "${project_path}/composer.lock" ]]; then
      echo
      echo -e "Файл ${YELLOW}composer.lock${WHITE} не найден."
      if composer_is_local_server; then
        echo "При установке Composer подберет версии зависимостей и создаст composer.lock."
      else
        echo "Установка зависимостей на production отключена для проекта без lock-файла."
      fi
    fi
    echo

    menu_items=("Информация и диагностика" "Проверить composer.json и composer.lock")
    menu_actions=("diagnose" "validate")
    if composer_is_local_server; then
      if [[ -f "${project_path}/composer.lock" ]]; then
        menu_items+=("Установить зависимости из composer.lock, включая dev")
      else
        menu_items+=("Установить зависимости и создать composer.lock")
      fi
      menu_actions+=("install")
      menu_items+=("Обновить зависимости и composer.lock")
      menu_actions+=("update")
    elif [[ -f "${project_path}/composer.lock" ]]; then
      menu_items+=("Установить production-зависимости из composer.lock")
      menu_actions+=("install")
    fi
    menu_items+=("Пересобрать autoload" "Проверить устаревшие прямые зависимости" "Выйти")
    menu_actions+=("dump-autoload" "outdated" "exit")

    vertical_menu "current" 2 0 54 "${menu_items[@]}"
    choice=$?
    if (( choice == 255 )); then
      return 0
    fi
    action="${menu_actions[${choice}]}"

    echo
    case "$action" in
      diagnose)
        run_composer_for_site "$site_user" "$site_home" "$php_bin" "$project_path" \
          --no-interaction --no-plugins --no-scripts --version --no-ansi
        echo
        run_composer_for_site "$site_user" "$site_home" "$php_bin" "$project_path" \
          --no-interaction --no-plugins --no-scripts diagnose
        ;;
      validate)
        run_composer_for_site "$site_user" "$site_home" "$php_bin" "$project_path" \
          --no-interaction --no-plugins --no-scripts validate
        ;;
      install)
        if composer_is_local_server; then
          if [[ -f "${project_path}/composer.lock" ]]; then
            confirm_composer_project_action \
              "$site_user" "$site_home" "$php_bin" "$project_path" \
              "Будут установлены зависимости из composer.lock, включая dev-зависимости." \
              install --prefer-dist
          else
            confirm_composer_project_action \
              "$site_user" "$site_home" "$php_bin" "$project_path" \
              "Composer подберет версии зависимостей и создаст composer.lock." \
              install --prefer-dist
          fi
        else
          confirm_composer_project_action \
            "$site_user" "$site_home" "$php_bin" "$project_path" \
            "Будут установлены production-зависимости из composer.lock." \
            --no-interaction install --no-dev --prefer-dist --optimize-autoloader
        fi
        ;;
      update)
        if ! composer_is_local_server; then
          echo -e "Обновление зависимостей на production ${RED}запрещено${WHITE}."
        else
          confirm_composer_project_action \
            "$site_user" "$site_home" "$php_bin" "$project_path" \
            "Будут обновлены зависимости проекта и изменен composer.lock." \
            update --prefer-dist
        fi
        ;;
      dump-autoload)
        if composer_is_local_server; then
          confirm_composer_project_action \
            "$site_user" "$site_home" "$php_bin" "$project_path" \
            "Будет пересобран autoload проекта, включая dev-зависимости." \
            dump-autoload
        else
          confirm_composer_project_action \
            "$site_user" "$site_home" "$php_bin" "$project_path" \
            "Будет пересобран production-autoload проекта." \
            --no-interaction dump-autoload --no-dev --optimize
        fi
        ;;
      outdated)
        run_composer_for_site "$site_user" "$site_home" "$php_bin" "$project_path" \
          --no-interaction --no-plugins --no-scripts outdated --direct
        ;;
      *)
        return 0
        ;;
    esac
    echo
    wait_for_enter
  done
}

case "${1:-}" in
  status)
    print_composer_status
    ;;
  server-menu)
    server_menu
    ;;
  site-menu)
    shift
    site_menu "$@"
    ;;
  *)
    echo "Использование: $0 {status|server-menu|site-menu <directory> <site>}" >&2
    exit 1
    ;;
esac
