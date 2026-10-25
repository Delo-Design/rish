#!/usr/bin/env bash

site_manager_is_site_name() {
  [[ "$1" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]
}

site_manager_message() {
  printf '%b\n' "$1"
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}

site_manager_user_is_available() {
  local user="$1" user_id user_root destination canonical_destination

  [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || return 1
  user_id="$(id -u "$user" 2>/dev/null)" || return 1
  [[ "$user_id" =~ ^[0-9]+$ ]] && ((user_id > 0)) || return 1
  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sftp || return 1
  user_root="/var/www/${user}"
  destination="${user_root}/www"
  [[ -d "$user_root" && ! -L "$user_root" && -d "$destination" && ! -L "$destination" ]] || return 1
  canonical_destination="$(realpath -e -- "$destination" 2>/dev/null)" || return 1
  [[ "$canonical_destination" == "$destination" ]]
}

site_manager_choose_user() {
  local user choice page_start=0 page_end previous_index next_index cancel_index
  local -a users=()
  local -a labels=()

  SM_SELECTED_USER=""
  SM_CREATE_DIRECTORY=""
  while IFS= read -r user; do
    if site_manager_user_is_available "$user"; then
      users+=("$user")
    fi
  done < <(get_sftp_users | LC_ALL=C sort -u)

  clear
  if ((${#users[@]} == 0)); then
    site_manager_message "Нет доступных пользователей для размещения сайта.\nСначала создайте пользователя через пункт «Пользователи сервера»."
    return 1
  fi
  while true; do
    clear
    echo "Выберите пользователя, у которого будет создан сайт:"
    # Индекс 255 зарезервирован vertical_menu для Esc.
    page_end=$((page_start + 250))
    ((page_end <= ${#users[@]})) || page_end=${#users[@]}
    labels=()
    for user in "${users[@]:page_start:page_end-page_start}"; do
      labels+=("Пользователь: ${user}")
    done
    previous_index=-1
    next_index=-1
    if ((page_start > 0)); then
      previous_index=${#labels[@]}
      labels+=("Предыдущая страница")
    fi
    if ((page_end < ${#users[@]})); then
      next_index=${#labels[@]}
      labels+=("Следующая страница")
    fi
    cancel_index=${#labels[@]}
    labels+=("Отмена")
    vertical_menu "current" 2 20 20 "${labels[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#labels[@]} || choice == cancel_index)); then
      return 1
    fi
    if ((choice == previous_index)); then
      page_start=$((page_start - 250))
      continue
    fi
    if ((choice == next_index)); then
      page_start=$page_end
      continue
    fi
    SM_SELECTED_USER="${users[$((page_start + choice))]}"
    SM_CREATE_DIRECTORY="/var/www/${SM_SELECTED_USER}/www"
    return 0
  done
}

site_manager_resolve_context() {
  local current_directory current_www user_root user_real selected_real logical_real site_relative site_real parent_real document_root document_real

  SM_OUTSIDE_CONTEXT=0
  SM_CREATE_NEEDS_USER=0
  SM_SELECTED_PATH=""
  SM_SITE_DIRECTORY=""
  SM_SITE_NAME=""
  SM_SITE_PATH=""
  SM_DOCUMENT_ROOT=""
  SM_CREATE_NAME=""
  SM_CREATE_AVAILABLE=0
  SM_DELETE_AVAILABLE=0
  SM_CLEAR_AVAILABLE=0
  SM_SITE_AVAILABLE=0
  SM_PERMISSIONS_AVAILABLE=0
  SM_VHOST_EXISTS=0
  SM_WARNING=""

  if ! current_directory="$(realpath -ms -- "$SM_DIRECTORY" 2>/dev/null)"; then
    SM_WARNING="Не удалось определить текущий каталог."
    return 1
  fi
  if [[ ! "$current_directory" =~ ^(/var/www/([^/]+)/www)(/|$) ]]; then
    SM_OUTSIDE_CONTEXT=1
    SM_CREATE_NEEDS_USER=1
    SM_CREATE_AVAILABLE=1
    return 0
  fi
  current_www="${BASH_REMATCH[1]}"
  user_root="/var/www/${BASH_REMATCH[2]}"
  if [[ "$SM_FILE_NAME" == */* ]]; then
    SM_WARNING="Не переданы корректные параметры Midnight Commander."
    return 1
  fi
  if ! SM_SELECTED_PATH="$(realpath -ms -- "${SM_DIRECTORY}/${SM_FILE_NAME}" 2>/dev/null)"; then
    SM_WARNING="Не удалось определить выбранный каталог."
    return 1
  fi
  if [[ "$SM_SELECTED_PATH" != "$user_root" && "$SM_SELECTED_PATH" != "$user_root/"* ]]; then
    SM_WARNING="Выберите каталог внутри /var/www/<пользователь>."
    return 1
  fi

  if ! user_real="$(realpath -e -- "$user_root" 2>/dev/null)"; then
    SM_WARNING="Каталог пользователя не найден."
    return 1
  fi
  SM_SITE_DIRECTORY="$current_www"
  if [[ -d "$current_www" ]] &&
    parent_real="$(realpath -e -- "$current_www" 2>/dev/null)" &&
    [[ "$parent_real" == "$user_real/"* ]]; then
    SM_CREATE_AVAILABLE=1
  fi
  selected_real="$(realpath -e -- "${SM_DIRECTORY}/${SM_FILE_NAME}" 2>/dev/null)" || selected_real=""
  logical_real="$(realpath -e -- "$SM_SELECTED_PATH" 2>/dev/null)" || logical_real=""
  if [[ "$selected_real" != "$logical_real" ]]; then
    SM_WARNING="Путь через символическую ссылку неоднозначен. Откройте фактический каталог."
    return 0
  fi
  if [[ -n "$selected_real" && "$selected_real" != "$user_real" && "$selected_real" != "$user_real/"* ]]; then
    SM_WARNING="Выбранный каталог выходит за пределы каталога пользователя."
    return 0
  fi
  if [[ -d "$SM_SELECTED_PATH" && "$SM_SELECTED_PATH" == "$current_www/"* ]]; then
    SM_PERMISSIONS_AVAILABLE=1
  fi

  if [[ "$SM_SELECTED_PATH" =~ ^(/var/www/[^/]+/www)(/(.*))?$ ]]; then
    SM_SITE_DIRECTORY="${BASH_REMATCH[1]}"
    site_relative="${BASH_REMATCH[3]}"
    SM_SITE_NAME="${site_relative%%/*}"
  else
    return 0
  fi

  # Переход на .. или . в www не должен превращаться в изменение прав всех сайтов.
  if [[ "$SM_SELECTED_PATH" == "$SM_SITE_DIRECTORY" &&
    ("$SM_FILE_NAME" == "." || "$SM_FILE_NAME" == "..") ]]; then
    SM_PERMISSIONS_AVAILABLE=0
  fi
  [[ -n "$SM_SITE_NAME" ]] || return 0
  SM_SITE_PATH="${SM_SITE_DIRECTORY}/${SM_SITE_NAME}"

  if site_manager_is_site_name "$SM_SITE_NAME" && [[ -f "/etc/httpd/conf.d/${SM_SITE_NAME}.conf" ]]; then
    SM_VHOST_EXISTS=1
  fi
  if ((SM_VHOST_EXISTS == 0)) && [[ -d "$SM_SELECTED_PATH" && "$SM_SELECTED_PATH" == "$SM_SITE_PATH" &&
    "$SM_FILE_NAME" != "." && "$SM_FILE_NAME" != ".." ]]; then
    SM_CREATE_NAME="$SM_SITE_NAME"
  fi
  ((SM_VHOST_EXISTS == 1)) || return 0
  [[ -d "$SM_SITE_PATH" ]] || return 0
  site_real="$(realpath -e -- "$SM_SITE_PATH" 2>/dev/null)" || return 0
  if [[ "$site_real" != "$parent_real/"* || -z "$selected_real" ||
    ("$selected_real" != "$site_real" && "$selected_real" != "$site_real/"*) ]]; then
    SM_WARNING="Фактический путь выбранного каталога не относится к этому сайту."
    return 0
  fi

  document_root="$(awk '
    tolower($1) == "documentroot" {
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "")
      if ($0 ~ /^"/) {
        sub(/^"/, "")
        sub(/".*$/, "")
      } else {
        sub(/[[:space:]].*$/, "")
      }
      print
      exit
    }
  ' "/etc/httpd/conf.d/${SM_SITE_NAME}.conf")"
  document_real="$(realpath -m -- "$document_root" 2>/dev/null)" || document_real=""
  if [[ "$document_root" != /* || -z "$document_real" ||
    ("$document_real" != "$site_real" && "$document_real" != "$site_real/"*) ]]; then
    SM_WARNING="DocumentRoot конфигурации сайта не относится к выбранной папке."
    return 0
  fi
  # Отсутствующий DocumentRoot не должен мешать удалению неисправного сайта.
  SM_DELETE_AVAILABLE=1
  SM_DOCUMENT_ROOT="$(realpath -ms -- "$document_root" 2>/dev/null)" || SM_DOCUMENT_ROOT=""
  if [[ ! -L "$SM_SITE_PATH" &&
    ("$SM_DOCUMENT_ROOT" == "$SM_SITE_PATH" || "$SM_DOCUMENT_ROOT" == "$SM_SITE_PATH/"*) ]]; then
    SM_CLEAR_AVAILABLE=1
  fi
  if [[ ! -d "$document_real" ]]; then
    SM_WARNING="Каталог DocumentRoot не найден или не является каталогом. Доступно удаление сайта."
    return 0
  fi
  SM_SITE_AVAILABLE=1
  return 0
}

site_manager_clear_site() {
  local site_path="$SM_SITE_PATH" document_root="$SM_DOCUMENT_ROOT" site_user choice

  clear
  printf 'Очистить папку сайта %b%s%b?\n' "$GREEN" "$SM_SITE_NAME" "$WHITE"
  printf 'Папка: %b%s%b\n' "$GREEN" "$site_path" "$WHITE"
  echo "Все файлы и подпапки будут удалены, включая скрытые."
  printf 'Будет создан пустой DocumentRoot: %b%s%b\n' "$GREEN" "$document_root" "$WHITE"
  vertical_menu "current" 2 0 30 "Отмена" "Очистить папку"
  choice=$?
  ((choice == 1)) || return 0

  if ! site_manager_resolve_context || ((SM_CLEAR_AVAILABLE == 0)) ||
    [[ "$SM_SITE_PATH" != "$site_path" || "$SM_DOCUMENT_ROOT" != "$document_root" ]]; then
    site_manager_message "Путь сайта или DocumentRoot изменился. Очистка отменена."
    return 1
  fi
  site_user="${SM_SITE_DIRECTORY%/www}"
  site_user="${site_user##*/}"
  if ! cd -- "$SM_SITE_DIRECTORY"; then
    site_manager_message "Не удалось перейти в родительскую папку сайта. Очистка отменена."
    return 1
  fi
  SM_DIRECTORY="$SM_SITE_DIRECTORY"
  SM_FILE_NAME="$SM_SITE_NAME"
  if find "$site_path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + &&
    install -d -m 755 -o "$site_user" -g "$site_user" -- "$document_root" &&
    chown -R "$site_user:$site_user" -- "$site_path"; then
    site_manager_message "Папка сайта очищена. Пустой DocumentRoot создан."
  else
    site_manager_message "Не удалось полностью очистить папку сайта или создать DocumentRoot."
    return 1
  fi
}

site_manager_is_cms_action() {
  case "$1" in
    install_joomla|install_wordpress|install_opencart|install_phpmyadmin|audit_joomla_extensions|update_joomla|manage_joomla_users|run_manual_joomla_cli_command|fix_joomla_site_configuration) return 0 ;;
    *) return 1 ;;
  esac
}

site_manager_load_cms_context() {
  local index token
  local -a descriptor=()

  SM_CMS_DOCUMENT_ROOT=""
  SM_CMS_PHP_BIN=""
  SM_CMS_NAME=""
  SM_CMS_PMA_VERSION=""
  SM_CMS_PMA_PATH=""
  SM_CMS_WARNING=""
  SM_CMS_MENU_ITEMS=()
  SM_CMS_MENU_ACTIONS=()
  ((SM_SITE_AVAILABLE)) || return 0
  mapfile -d '' -t descriptor < <(
    bash "${RISH_HOME}/scripts/cms_install.sh" --describe "$SM_SITE_DIRECTORY" "$SM_SITE_NAME" 2>/dev/null
  )
  if ((${#descriptor[@]} < 6 || (${#descriptor[@]} - 6) % 2 != 0)) ||
    [[ "${descriptor[0]}" != rish-cms-v1 ]]; then
    SM_CMS_WARNING="Не удалось получить сведения CMS/phpMyAdmin."
    return 1
  fi
  for ((index = 6; index < ${#descriptor[@]}; index += 2)); do
    token="${descriptor[$index]}"
    if ! site_manager_is_cms_action "$token"; then
      SM_CMS_WARNING="Не удалось получить список действий CMS/phpMyAdmin."
      return 1
    fi
  done
  SM_CMS_DOCUMENT_ROOT="${descriptor[1]}"
  SM_CMS_PHP_BIN="${descriptor[2]}"
  SM_CMS_NAME="${descriptor[3]}"
  SM_CMS_PMA_VERSION="${descriptor[4]}"
  SM_CMS_PMA_PATH="${descriptor[5]}"
  for ((index = 6; index < ${#descriptor[@]}; index += 2)); do
    SM_CMS_MENU_ACTIONS+=("cms:${descriptor[$index]}")
    SM_CMS_MENU_ITEMS+=("${descriptor[$((index + 1))]}")
  done
}

site_manager_print_cms_info() {
  if [[ -n "$SM_CMS_DOCUMENT_ROOT" ]]; then
    printf 'DocumentRoot сайта: %b%s%b\n' "$GREEN" "$SM_CMS_DOCUMENT_ROOT" "$WHITE"
    printf 'PHP сайта: %b%s%b\n' "$GREEN" "$SM_CMS_PHP_BIN" "$WHITE"
  fi
  if [[ -n "$SM_CMS_NAME" ]]; then
    printf 'CMS сайта: %b%s%b\n' "$GREEN" "$SM_CMS_NAME" "$WHITE"
  fi
  if [[ -n "$SM_CMS_PMA_VERSION" ]]; then
    printf 'phpMyAdmin: %b%s%b (установлен в %s)\n' "$GREEN" "$SM_CMS_PMA_VERSION" "$WHITE" "$SM_CMS_PMA_PATH"
  fi
  if [[ -n "$SM_CMS_WARNING" ]]; then
    printf '%s\n' "$SM_CMS_WARNING"
  fi
}

site_manager_build_menu() {
  local create_label="Создать сайт"

  SM_MENU_ITEMS=()
  SM_MENU_ACTIONS=()
  if ((SM_OUTSIDE_CONTEXT)); then
    SM_MENU_ITEMS=("Создать сайт" "Выйти")
    SM_MENU_ACTIONS=(create back)
    return 0
  fi
  if ((SM_PERMISSIONS_AVAILABLE)); then
    SM_MENU_ITEMS+=("Настроить права доступа каталога")
    SM_MENU_ACTIONS+=(permissions)
  fi
  if ((SM_CREATE_AVAILABLE)); then
    [[ -z "$SM_CREATE_NAME" ]] || create_label+=" ${SM_CREATE_NAME}"
    SM_MENU_ITEMS+=("$create_label")
    SM_MENU_ACTIONS+=(create)
  fi
  if ((SM_SITE_AVAILABLE)); then
    SM_MENU_ITEMS+=("Сменить версию PHP")
    SM_MENU_ACTIONS+=(php)
  fi
  if ((SM_SITE_AVAILABLE)); then
    SM_MENU_ITEMS+=("${SM_CMS_MENU_ITEMS[@]}" "SSL-сертификаты")
    SM_MENU_ACTIONS+=("${SM_CMS_MENU_ACTIONS[@]}" ssl)
  fi
  if ((SM_DELETE_AVAILABLE)) && [[ -x "${RISH_HOME}/dns/.enabled" ]]; then
    SM_MENU_ITEMS+=("DNS")
    SM_MENU_ACTIONS+=(dns)
  fi
  if ((SM_SITE_AVAILABLE)) && [[ -x "${RISH_HOME}/composer/.enabled" ]]; then
    SM_MENU_ITEMS+=("Composer")
    SM_MENU_ACTIONS+=(composer)
  fi
  if ((SM_DELETE_AVAILABLE)); then
    SM_MENU_ITEMS+=("Удалить сайт ${SM_SITE_NAME}")
    SM_MENU_ACTIONS+=(delete)
  fi
  if ((SM_CLEAR_AVAILABLE)); then
    SM_MENU_ITEMS+=("Очистить папку сайта ${SM_SITE_NAME}")
    SM_MENU_ACTIONS+=(clear)
  fi
  SM_MENU_ITEMS+=("Назад")
  SM_MENU_ACTIONS+=(back)
}

site_manager_main() {
  local choice action default_action=permissions default_index index php_version php_branch server_ip

  RISH_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || return 1
  export RISH_HOME
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  WHITE='\033[0m'
  source "${RISH_HOME}/windows.sh" || return 1
  source "${RISH_HOME}/php_helpers.sh" || return 1
  source "${RISH_HOME}/scripts/ssh_authentication.sh" || return 1

  SM_FILE_NAME="${1:-.}"
  SM_DIRECTORY="${2:-$PWD}"
  SM_DIRECTORY="${SM_DIRECTORY%/}"
  SM_DIRECTORY="${SM_DIRECTORY:-/}"

  while true; do
    clear
    if ! site_manager_resolve_context; then
      site_manager_message "$SM_WARNING"
      return 1
    fi
    site_manager_load_cms_context || :
    if ((SM_SITE_AVAILABLE || SM_DELETE_AVAILABLE)); then
      printf 'Управление сайтом %b%s%b\n' "$GREEN" "$SM_SITE_NAME" "$WHITE"
      if php_version="$(get_site_php_version "$SM_SITE_NAME")"; then
        php_branch="${php_version#php}"
        printf 'Текущая версия PHP: %b%s.%s%b\n' "$GREEN" "${php_branch:0:1}" "${php_branch:1}" "$WHITE"
      else
        echo "Текущая версия PHP: не определена"
      fi
      server_ip=$(ip route get 1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }') || server_ip=""
      printf 'IP сервера: %b%s%b\n' "$YELLOW" "${server_ip:-не определён}" "$WHITE"
      site_manager_print_cms_info
    else
      echo "Управление сайтом"
    fi
    echo
    if ((SM_OUTSIDE_CONTEXT)); then
      echo "Сайт не выбран. Здесь можно создать новый сайт."
      echo
      echo "Для управления существующим сайтом:"
      echo "1. Выйдите из этого меню."
      echo "2. В MC откройте /var/www/<пользователь>/www"
      echo "   и установите курсор на папку нужного сайта."
      echo "3. Нажмите F2 и выберите «Управление сайтом»."
      echo
      echo "Для быстрого перехода к сайтам и другим папкам"
      printf '%s\n' 'нажмите в MC Ctrl+\ — откроется список закладок каталогов.'
      echo
    fi
    if [[ -n "$SM_WARNING" ]]; then
      printf '%s\n\n' "$SM_WARNING"
    fi
    site_manager_build_menu
    default_index=0
    for index in "${!SM_MENU_ACTIONS[@]}"; do
      if [[ "${SM_MENU_ACTIONS[$index]}" == "$default_action" ]]; then
        default_index=$index
        break
      fi
    done
    vertical_menu "current" 2 0 32 "default=$default_index" "${SM_MENU_ITEMS[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#SM_MENU_ACTIONS[@]})); then
      return 0
    fi
    action="${SM_MENU_ACTIONS[$choice]}"
    [[ "$action" != back ]] || return 0
    default_action="$action"

    # Пока открыто меню, сайт или признаки включённых модулей могли измениться.
    if ! site_manager_resolve_context; then
      site_manager_message "$SM_WARNING"
      return 1
    fi
    case "$action" in
      create)
        ((SM_CREATE_AVAILABLE)) || continue
        if ((SM_CREATE_NEEDS_USER)); then
          if site_manager_choose_user; then
            if site_manager_user_is_available "$SM_SELECTED_USER"; then
              bash "${RISH_HOME}/create_site.sh" "" "$SM_CREATE_DIRECTORY"
            else
              site_manager_message "Пользователь или каталог назначения изменился. Выберите пользователя заново."
            fi
          fi
        else
          bash "${RISH_HOME}/create_site.sh" "$SM_CREATE_NAME" "$SM_SITE_DIRECTORY"
        fi
        ;;
      permissions)
        ((SM_PERMISSIONS_AVAILABLE)) || continue
        bash "${RISH_HOME}/scripts/fix_permissions.sh" "$SM_DIRECTORY" "$SM_FILE_NAME"
        ;;
      dns)
        ((SM_DELETE_AVAILABLE)) || continue
        [[ -x "${RISH_HOME}/dns/.enabled" ]] || continue
        bash "${RISH_HOME}/scripts/dns/dns.sh" menu-from-mc "$SM_SITE_DIRECTORY" "$SM_SITE_NAME"
        ;;
      delete)
        ((SM_DELETE_AVAILABLE)) || continue
        bash "${RISH_HOME}/scripts/delete_site.sh" "$SM_SITE_DIRECTORY" "$SM_SITE_NAME"
        ;;
      clear)
        ((SM_CLEAR_AVAILABLE)) || continue
        site_manager_clear_site
        ;;
      cms:*)
        ((SM_SITE_AVAILABLE)) || continue
        site_manager_load_cms_context || continue
        for index in "${!SM_CMS_MENU_ACTIONS[@]}"; do
          if [[ "${SM_CMS_MENU_ACTIONS[$index]}" == "$action" ]]; then
            bash "${RISH_HOME}/scripts/cms_install.sh" --action "${action#cms:}" "$SM_SITE_DIRECTORY" "$SM_SITE_NAME"
            break
          fi
        done
        ;;
      php|ssl|composer)
        ((SM_SITE_AVAILABLE)) || continue
        case "$action" in
          php) bash "${RISH_HOME}/change_php_version.sh" "$SM_SITE_NAME" "$SM_SITE_DIRECTORY" ;;
          ssl) bash "${RISH_HOME}/scripts/certs.sh" "$SM_SITE_NAME" ;;
          composer)
            [[ -x "${RISH_HOME}/composer/.enabled" ]] || continue
            bash "${RISH_HOME}/scripts/composer_manager.sh" site-menu "$SM_SITE_DIRECTORY" "$SM_SITE_NAME"
            ;;
        esac
        ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  site_manager_main "$@"
fi
