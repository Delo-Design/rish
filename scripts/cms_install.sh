#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
WHITE='\033[0m'
LRED='\033[1;31m'

source /root/rish/windows.sh
source /root/rish/scripts/site_helpers.sh

directory="$1"
folder="$2"
site_root_path="${directory}/${folder}"
site_path=""
site_name="${folder}"
site_cms=""
joomla_version=""
site_is_joomla=0
site_has_joomla_cli=0
site_supports_joomla_user_cli=0
site_phpmyadmin_path=""
site_phpmyadmin_version=""
joomla_users_full_list_limit=200

wait_for_enter() {
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}

get_site_php_bin() {
  local conf_file
  local php_version

  for conf_file in \
    "/etc/httpd/conf.d/${site_name}.conf" \
    "/etc/httpd/conf.d/${site_name}-ssl.conf" \
    "/etc/httpd/conf.d/${site_name}-le-ssl.conf"; do
    [[ -f "$conf_file" ]] || continue

    php_version=$(grep -oE '/var/opt/remi/php[0-9]{2}/run/php-fpm/' "$conf_file" \
      | grep -oE 'php[0-9]{2}' \
      | head -n 1)
    if [[ -n "$php_version" && -x "/bin/${php_version}" ]]; then
      echo "/bin/${php_version}"
      return 0
    fi
  done

  return 1
}

get_site_user() {
  local path="$1"
  local user
  local credentials_file

  if [[ "$path" =~ ^/var/www/([^/]+)/www(/.*)?$ ]]; then
    user="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  credentials_file="$(rish_credentials_file "$user")" || return 1
  if id -u "$user" > /dev/null 2>&1 && [[ -f "$credentials_file" && ! -L "$credentials_file" ]]; then
    echo "$user"
    return 0
  fi

  return 1
}

select_compatible_language_package() {
  local joomla_full_version="$1"
  local package_pattern="$2"
  local url
  local package_version
  shift 2

  while IFS= read -r url; do
    package_version=$( echo "$url" | sed -n 's@.*/ru-RU_joomla_lang_full_\([0-9]\+\.[0-9]\+\.[0-9]\+\)v[0-9]\+\.zip$@\1@p' )
    [[ -n "$package_version" ]] || continue

    if [[ "$(printf '%s\n%s\n' "$package_version" "$joomla_full_version" | sort -V | head -n 1)" == "$package_version" ]]; then
      echo "$url"
      return 0
    fi
  done < <(
    printf '%s\n' "$@" |
      grep -E "$package_pattern" |
      sort -Vr
  )

  return 1
}

install_joomla() {
  local -a downloads
  local -a joomlas
  local choice
  local joomla_version
  local joomla_full_version
  local joomla_minor_version
  local user
  local cr
  local admin_email
  local admin_password
  local db_password
  local db_exists
  local archive_name
  local archive_path
  local staging_path
  local releases_json
  local language_package_url
  local localisation_json
  local -a language_packages

  if ! releases_json=$(curl -fsSL https://api.github.com/repos/joomla/joomla-cms/releases); then
    echo -e "Не удалось получить список версий ${RED}Joomla${WHITE}."
    wait_for_enter
    exit 1
  fi
  mapfile -t downloads < <(
    printf '%s\n' "$releases_json" |
      grep 'browser_download.*Stable-Full.*tar.gz' |
      grep -Eo 'https?://[^ ]+Stable-Full_Package.tar.gz'
  )
  if (( ${#downloads[@]} == 0 )); then
    echo -e "Не найдены доступные для скачивания версии ${RED}Joomla${WHITE}."
    wait_for_enter
    exit 1
  fi
  echo "Выберите версию Joomla для скачивания:"
  mapfile -t joomlas < <(
    printf '%s\n' "${downloads[@]}" |
      awk -F"/" '{print $NF}'
  )
  vertical_menu "current" 2 0 30 "${joomlas[@]}"
  choice=$?
  if (( choice == 255 )); then
    echo "Выход. Каталог не тронут. Никаких действий произведено не было."
    wait_for_enter
    exit
  fi
  joomla_version=$( echo "${joomlas[${choice}]}" | sed 's@^[^0-9]*\([0-9]\+\).*@\1@' )
  joomla_full_version=$( echo "${joomlas[${choice}]}" | sed -n 's@^[^0-9]*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*@\1@p' )
  if [[ -z "$joomla_full_version" ]]; then
    echo -e "Не удалось определить версию выбранного архива ${RED}Joomla${WHITE}."
    wait_for_enter
    exit 1
  fi
  joomla_minor_version=${joomla_full_version%.*}
  archive_name="${joomlas[${choice}]}"

  if [[ -z "$php_bin" ]]; then
    echo -e "Установка ${RED}Joomla${WHITE} невозможна: не определен PHP сайта."
    wait_for_enter
    exit 1
  fi

  if ! user=$(get_site_user "$directory"); then
    echo -e "Выбран ${RED}неверный${WHITE} каталог для сайта."
    wait_for_enter
    exit 1
  fi

  db_password="$(read_user_credential "$user" "MariaDB" "Password")"
  admin_email="$(read_user_credential "$user" "Default site administrator" "Login")"
  admin_password="$(read_user_credential "$user" "Default site administrator" "Password")"
  if [[ -z "$db_password" || -z "$admin_email" || -z "$admin_password" ]]; then
    echo -e "Не удалось прочитать учетные данные из ${RED}${RISH_CREDENTIALS_DIR}/${user}${WHITE}."
    wait_for_enter
    exit 1
  fi

  if ! cd "${directory}"; then
    echo -e "Не удалось перейти в каталог ${RED}${directory}${WHITE}."
    wait_for_enter
    exit 1
  fi
  echo -e "Установка Joomla version ${GREEN}${joomla_full_version}${WHITE}"
  if [ -n "$(ls -A "${site_path}")" ]; then
    echo -e "Удалить содержимое папки ${GREEN}${site_path}${WHITE}?"
    vertical_menu "current" 2 0 5 "Да" "Нет"
    cr=$?
    if (( cr != 0 )); then
      echo "Установка отменена. Каталог не был изменен."
      wait_for_enter
      exit
    fi
  fi

  if ! db_exists=$(mariadb -uroot -NBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${folder}'"); then
    echo -e "Не удалось проверить наличие базы данных ${RED}${folder}${WHITE}."
    wait_for_enter
    exit 1
  fi
  if [[ -z "$db_exists" ]]; then
    echo -e "Базы данных с именем ${GREEN}${folder}${WHITE} не существует. Создать?"
    vertical_menu "current" 2 0 5 "Да" "Нет"
    cr=$?
    if (( cr != 0 )); then
      echo "Установка отменена. База данных не была создана."
      wait_for_enter
      exit
    fi
  else
    echo -e "База данных с именем ${GREEN}${folder}${WHITE} уже существует. Хотите очистить ее?"
    vertical_menu "current" 2 0 5 "Да" "Нет"
    cr=$?
    if (( cr != 0 )); then
      echo "Установка отменена. База данных не была изменена."
      wait_for_enter
      exit
    fi
  fi

  echo -e "Скачиваем Joomla ${GREEN}${joomla_full_version}${WHITE}..."
  if ! archive_path=$(mktemp "/tmp/rish-${archive_name}.XXXXXX"); then
    echo -e "Не удалось создать временный файл для архива ${RED}Joomla${WHITE}."
    wait_for_enter
    exit 1
  fi
  if ! wget -q --show-progress --progress=bar:force:noscroll \
    -O "$archive_path" "${downloads[${choice}]}"; then
    rm -f -- "$archive_path"
    echo -e "Не удалось скачать Joomla ${RED}${joomla_full_version}${WHITE}."
    wait_for_enter
    exit 1
  fi

  if compgen -G "${site_path}.rish-install.*" > /dev/null; then
    rm -f -- "$archive_path"
    echo -e "Найдены ${RED}временные папки${WHITE} предыдущей установки."
    echo "Удалите их вручную после проверки содержимого:"
    echo "${site_path}.rish-install.*"
    wait_for_enter
    exit 1
  fi
  if ! staging_path=$(mktemp -d "${site_path}.rish-install.XXXXXX") ||
    ! chmod 755 "$staging_path" ||
    ! tar xzf "$archive_path" -C "$staging_path"; then
    rm -f -- "$archive_path"
    rm -rf -- "$staging_path"
    echo -e "Не удалось распаковать архив ${RED}Joomla${WHITE}."
    wait_for_enter
    exit 1
  fi
  rm -f -- "$archive_path"

  if [[ ! -f "${staging_path}/htaccess.txt" ]] ||
    ! mv "${staging_path}/htaccess.txt" "${staging_path}/.htaccess" ||
    ! chown -R "${user}:${user}" "$staging_path"; then
    rm -rf -- "$staging_path"
    echo -e "Не удалось подготовить файлы ${RED}Joomla${WHITE}."
    wait_for_enter
    exit 1
  fi

  if [[ -n "$db_exists" ]]; then
    if ! mariadb-admin -f -u root drop "${folder}"; then
      rm -rf -- "$staging_path"
      echo -e "При удалении базы данных ${RED}${folder}${WHITE} произошли ${RED}ошибки${WHITE}"
      wait_for_enter
      exit 1
    fi
    echo -e "База данных ${GREEN}${folder}${WHITE} удалена"
  fi
  if ! mariadb -u root -e "CREATE DATABASE \`${folder}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
    rm -rf -- "$staging_path"
    echo -e "Не удалось создать базу данных ${RED}${folder}${WHITE}."
    wait_for_enter
    exit 1
  fi
  echo -e "База mysql с именем ${GREEN}${folder}${WHITE} создана"
  if ! mariadb -uroot -e "GRANT ALL PRIVILEGES ON \`${folder}\`.* TO '${user}'@'localhost'; FLUSH PRIVILEGES;"; then
    rm -rf -- "$staging_path"
    echo -e "Не удалось выдать права на базу данных пользователю ${RED}${user}${WHITE}."
    wait_for_enter
    exit 1
  fi
  echo -e "Права на базу выданы пользователю ${GREEN}${user}${WHITE}"

  if ! rm -rf -- "$site_path" ||
    ! mv -- "$staging_path" "$site_path"; then
    rm -rf -- "$staging_path"
    echo -e "Не удалось заменить ${RED}файлы сайта${WHITE}."
    echo "База данных уже была пересоздана."
    wait_for_enter
    exit 1
  fi

  echo -e "Будет использована учетная запись ${GREEN}${admin_email}${WHITE}"
  (
    cd "${site_path}" || exit 1
    runuser -u "$user" -- "$php_bin" installation/joomla.php install \
      --no-interaction \
      --site-name="$site_name" \
      --admin-user="$admin_email" \
      --admin-username="$admin_email" \
      --admin-password="$admin_password" \
      --admin-email="$admin_email" \
      --db-type="mysqli" \
      --db-host="localhost" \
      --db-user="$user" \
      --db-pass="$db_password" \
      --db-name="$folder" \
      --db-encryption="0"
  ) || {
    echo -e "Установка Joomla завершилась с ${RED}ошибкой${WHITE}."
    wait_for_enter
    exit 1
  }

  echo
  echo -e "Установка Joomla ${GREEN}завершена${WHITE}."
  echo
  echo "Установить русскую локализацию?"
  vertical_menu "current" 2 0 5 "Да" "Нет"
  cr=$?
  if (( cr == 0 )); then
    if ! localisation_json=$(curl -fsSL https://api.github.com/repos/JPathRu/localisation/releases); then
      echo -e "Не удалось получить список пакетов ${RED}русской локализации${WHITE}."
      echo "Основная установка Joomla завершена успешно."
      wait_for_enter
      return
    fi
    mapfile -t language_packages < <(
      printf '%s\n' "$localisation_json" |
        grep browser_download_url |
        grep -Eo 'https?://[^ "]+/ru-RU_joomla_lang_full_[^ "]+\.zip'
    )
    language_package_url=$(select_compatible_language_package \
      "$joomla_full_version" \
      "ru-RU_joomla_lang_full_${joomla_full_version//./\\.}v[0-9]+\\.zip$" \
      "${language_packages[@]}")
    if [[ -z "$language_package_url" ]]; then
      language_package_url=$(select_compatible_language_package \
        "$joomla_full_version" \
        "ru-RU_joomla_lang_full_${joomla_minor_version//./\\.}\\.[0-9]+v[0-9]+\\.zip$" \
        "${language_packages[@]}")
    fi
    if [[ -z "$language_package_url" ]]; then
      language_package_url=$(select_compatible_language_package \
        "$joomla_full_version" \
        "ru-RU_joomla_lang_full_${joomla_version}\\.[0-9]+\\.[0-9]+v[0-9]+\\.zip$" \
        "${language_packages[@]}")
    fi
    if [[ -n "$language_package_url" ]]; then
      echo -e "Будет установлен пакет локализации: ${GREEN}${language_package_url##*/}${WHITE}"
      runuser -u "$user" -- "$php_bin" "${site_path}/cli/joomla.php" extension:install \
        --url="$language_package_url" || {
          echo -e "Не удалось установить ${RED}русскую локализацию${WHITE}."
          echo "Основная установка Joomla завершена успешно."
          wait_for_enter
          return
        }
      echo -e "Русская локализация ${GREEN}установлена${WHITE}."
    else
      echo -e "Не найден пакет русской локализации для Joomla ${RED}${joomla_version}${WHITE}."
    fi
  fi
  wait_for_enter
}

update_joomla() {
  local user
  local cr

  if ! user=$(get_site_user "$directory"); then
    echo -e "Выбран ${RED}неверный${WHITE} каталог для сайта."
    wait_for_enter
    exit 1
  fi

  echo -e "Перед обновлением рекомендуется создать резервную копию файлов сайта и базы данных."
  echo -e "Продолжить обновление Joomla для сайта ${YELLOW}${site_name}${WHITE}?"
  vertical_menu "current" 2 0 5 "Продолжить" "Отмена"
  cr=$?
  if (( cr != 0 )); then
    echo "Обновление Joomla отменено."
    wait_for_enter
    return
  fi

  echo "Проверяем наличие обновлений Joomla..."
  (
    cd "$site_path" &&
      timeout 30s runuser -u "$user" -- "$php_bin" cli/joomla.php core:check-updates
  )
  cr=$?
  if (( cr == 124 )); then
    echo -e "Проверка обновлений Joomla ${RED}не завершилась за 30 секунд${WHITE}."
    echo "Проверьте доступ к серверу обновлений."
    wait_for_enter
    return
  elif (( cr != 0 )); then
    echo -e "Не удалось ${RED}проверить наличие обновлений Joomla${WHITE}."
    wait_for_enter
    return
  fi

  echo "Обновляем Joomla..."
  if ! (
    cd "$site_path" &&
      runuser -u "$user" -- "$php_bin" cli/joomla.php core:update
  ); then
    echo -e "Обновление Joomla ${RED}завершилось с ошибкой${WHITE}."
    wait_for_enter
    return
  fi

  echo -e "Обновление Joomla ${GREEN}завершено${WHITE}."
  wait_for_enter
}

joomla_config_value() {
  local name="$1"
  local config_file="${site_path}/configuration.php"

  sed -nE "s/^[[:space:]]*(public[[:space:]]+)?\\\$${name}[[:space:]]*=[[:space:]]*'([^']*)'.*/\\2/p" "$config_file" | head -n 1
}

joomla_user_count() {
  local db_name
  local db_prefix

  db_name=$(joomla_config_value "db")
  db_prefix=$(joomla_config_value "dbprefix")

  if [[ -z "$db_name" || -z "$db_prefix" ]]; then
    return 1
  fi
  if ! [[ "$db_prefix" =~ ^[A-Za-z0-9_]+$ ]]; then
    return 1
  fi

  mariadb "$db_name" -NBe "SELECT COUNT(*) FROM \`${db_prefix}users\`;" 2>/dev/null
}

run_joomla_user_command() {
  local user="$1"
  shift

  (
    cd "$site_path" &&
      runuser -u "$user" -- "$php_bin" cli/joomla.php "$@"
  )
}

shell_quote_command() {
  local quoted=()
  local arg

  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    quoted+=("$arg")
  done
  printf '%s' "${quoted[*]}"
}

show_joomla_users() {
  local user="$1"
  local user_count="$2"
  local cr

  if [[ ! "$user_count" =~ ^[0-9]+$ || "$user_count" -gt "$joomla_users_full_list_limit" ]]; then
    if [[ "$user_count" =~ ^[0-9]+$ ]]; then
      echo -e "На сайте ${YELLOW}${user_count}${WHITE} пользователей."
    else
      echo -e "Количество пользователей ${YELLOW}не удалось определить${WHITE}."
    fi
    echo -e "Полный вывод может быть очень большим. Показать весь список?"
    vertical_menu "current" 2 0 5 "Нет" "Да"
    cr=$?
    if (( cr != 1 )); then
      echo "Вывод полного списка отменен."
      wait_for_enter
      return
    fi
  fi

  run_joomla_user_command "$user" user:list
  wait_for_enter
}

show_joomla_users_head() {
  local user="$1"
  local label="$2"
  local line_limit="$3"
  local cr

  (
    cd "$site_path" &&
      runuser -u "$user" -- "$php_bin" cli/joomla.php user:list | head -n "$line_limit"
  )
  cr=$?
  if (( cr != 0 )); then
    echo -e "Команда ${RED}user:list${WHITE} завершилась с ошибкой."
  else
    echo -e "Показано начало списка: ${GREEN}${label}${WHITE}."
  fi
  wait_for_enter
}

show_joomla_super_users() {
  local user="$1"
  local cr

  (
    set -o pipefail
    cd "$site_path" &&
      runuser -u "$user" -- "$php_bin" cli/joomla.php user:list |
        awk '
          function print_header() {
            if (header_printed) {
              return
            }
            for (i = 1; i <= header_count; i++) {
              print header[i]
            }
            header_printed = 1
          }

          /^[[:space:]]*[0-9]+[[:space:]]/ {
            in_data = 1
            if (tolower($0) ~ /super users/) {
              print_header()
              print
              found = 1
            }
            next
          }

          !in_data {
            header[++header_count] = $0
            next
          }

          found && $0 ~ /^[[:space:]-]+$/ {
            footer = $0
          }

          END {
            if (found && footer) {
              print footer
            }
            exit found ? 0 : 1
          }
        '
  )
  cr=$?
  if (( cr == 1 )); then
    echo -e "Пользователи группы ${YELLOW}Super Users${WHITE} не найдены в выводе user:list."
  elif (( cr != 0 )); then
    echo -e "Команда ${RED}user:list${WHITE} завершилась с ошибкой."
  fi
  wait_for_enter
}

filter_joomla_users() {
  local user="$1"
  local pattern
  local cr

  echo -e "Введите строку для фильтра user:list через ${GREEN}grep -i${WHITE} (пустая строка для выхода): ${GREEN}"
  read -r -e pattern
  echo -e -n "${WHITE}"
  if [[ -z "$pattern" ]]; then
    echo "Фильтр отменен."
    wait_for_enter
    return
  fi

  (
    set -o pipefail
    cd "$site_path" &&
      runuser -u "$user" -- "$php_bin" cli/joomla.php user:list | grep -i -- "$pattern"
  )
  cr=$?
  if (( cr == 1 )); then
    echo -e "Совпадений по строке ${YELLOW}${pattern}${WHITE} не найдено."
  elif (( cr != 0 )); then
    echo -e "Команда ${RED}user:list${WHITE} завершилась с ошибкой."
  fi
  wait_for_enter
}

manage_joomla_users() {
  local user
  local user_count
  local choice
  local -a menu_items
  local -a menu_actions

  if ! user=$(get_site_user "$directory"); then
    echo -e "Выбран ${RED}неверный${WHITE} каталог для сайта."
    wait_for_enter
    return
  fi

  while true; do
    clear
    echo -e "Управление пользователями Joomla для сайта: ${GREEN}${site_name}${WHITE}"
    echo -e "DocumentRoot сайта: ${GREEN}${site_path}${WHITE}"
    if user_count=$(joomla_user_count); then
      echo -e "Пользователей Joomla: ${GREEN}${user_count}${WHITE}"
      if [[ "$user_count" =~ ^[0-9]+$ && "$user_count" -gt "$joomla_users_full_list_limit" ]]; then
        echo -e "Полный список больше ${YELLOW}${joomla_users_full_list_limit}${WHITE}; перед выводом будет запрошено подтверждение."
      fi
    else
      user_count=""
      echo -e "Пользователей Joomla: ${YELLOW}не удалось определить${WHITE}"
    fi
    echo
    echo "Выберите действие:"

    menu_items=("Показать всех пользователей (user:list)")
    menu_actions=("show_users")
    if [[ "$user_count" =~ ^[0-9]+$ && "$user_count" -gt 500 ]]; then
      menu_items+=("Показать первые 200 пользователей" "Показать первые 1000 пользователей")
      menu_actions+=("show_head_200" "show_head_1000")
    fi
    menu_items+=(
      "Показать Super User пользователей (user:list)"
      "Показать отфильтрованный список пользователей"
      "Добавить пользователя (user:add)"
      "Сбросить пароль (user:reset-password)"
      "Удалить пользователя (user:delete)"
      "Добавить пользователя в группу (user:addtogroup)"
      "Удалить пользователя из группы (user:removefromgroup)"
      "Выйти"
    )
    menu_actions+=(
      "show_super_users"
      "filter_users"
      "user:add"
      "user:reset-password"
      "user:delete"
      "user:addtogroup"
      "user:removefromgroup"
      "back"
    )

    vertical_menu "current" 2 0 45 "${menu_items[@]}"
    choice=$?
    if (( choice == 255 )) || [[ "${menu_actions[${choice}]}" == "back" ]]; then
      return
    fi

    case "${menu_actions[${choice}]}" in
      show_users)
        show_joomla_users "$user" "$user_count"
        ;;
      show_head_200)
        show_joomla_users_head "$user" "первые 200 пользователей" 220
        ;;
      show_head_1000)
        show_joomla_users_head "$user" "первые 1000 пользователей" 1020
        ;;
      show_super_users)
        show_joomla_super_users "$user"
        ;;
      filter_users)
        filter_joomla_users "$user"
        ;;
      user:*)
        run_joomla_user_command "$user" "${menu_actions[${choice}]}"
        wait_for_enter
        ;;
    esac
  done
}

install_opencart() {
  local -a downloads
  local -a opencarts
  local choice
  local opencart_version
  local archive_name
  local archive_path
  local package_path
  local staging_path
  local upload_path
  local releases_json
  local livestore_tags_json
  local livestore_tag
  local livestore_version
  local livestore_url
  local site_url="http://${site_name}"
  local user
  local cr
  local db_password
  local db_exists
  local admin_email
  local admin_password

  if releases_json=$(curl -fsSL https://api.github.com/repos/opencart/opencart/releases); then
    mapfile -t downloads < <(
      printf '%s\n' "$releases_json" |
        grep browser_download_url |
        grep -Eo 'https?://[^ "]+/opencart-[34](\.[0-9]+)+\.zip'
    )
  else
    echo -e "Не удалось получить список версий ${YELLOW}OpenCart${WHITE}."
  fi
  mapfile -t opencarts < <(
    printf '%s\n' "${downloads[@]}" |
      awk -F"/" 'NF {print $NF}'
  )
  if livestore_tags_json=$(curl -fsSL https://api.github.com/repos/19th19th/LiveStore/tags); then
    while IFS=$'\t' read -r livestore_tag livestore_url; do
      livestore_version="${livestore_tag#v}"
      [[ "$livestore_version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || continue
      [[ -n "$livestore_url" ]] || continue

      downloads=("$livestore_url" "${downloads[@]}")
      opencarts=("livestore-${livestore_version}.zip" "${opencarts[@]}")
      break
    done < <(
      printf '%s\n' "$livestore_tags_json" |
        awk '
          /"name":/ {
            name = $0
            sub(/^.*"name": *"/, "", name)
            sub(/".*$/, "", name)
          }
          /"zipball_url":/ {
            url = $0
            sub(/^.*"zipball_url": *"/, "", url)
            sub(/".*$/, "", url)
            if (name != "" && url != "") {
              print name "\t" url
            }
          }
        '
    )
  else
    echo -e "Не удалось получить список версий ${YELLOW}LiveStore${WHITE}."
  fi
  if (( ${#downloads[@]} == 0 )); then
    echo -e "Не найдены доступные для скачивания версии ${RED}OpenCart${WHITE}."
    wait_for_enter
    exit 1
  fi
  echo "Выберите версию OpenCart для скачивания:"
  vertical_menu "current" 2 0 30 "${opencarts[@]}"
  choice=$?
  if (( choice == 255 )); then
    echo "Выход. Каталог не тронут. Никаких действий произведено не было."
    wait_for_enter
    exit
  fi
  archive_name="${opencarts[${choice}]}"
  opencart_version=$( echo "$archive_name" | sed -n 's/^\(opencart\|livestore\)-\([0-9.]\+\)\.zip$/\2/p' )
  if [[ -z "$opencart_version" ]]; then
    echo -e "Не удалось определить версию выбранного архива ${RED}OpenCart${WHITE}."
    wait_for_enter
    exit 1
  fi

  if [[ -f "/etc/httpd/conf.d/${site_name}-ssl.conf" ||
    -f "/etc/httpd/conf.d/${site_name}-le-ssl.conf" ]]; then
    site_url="https://${site_name}"
  fi

  if ! user=$(get_site_user "$directory"); then
    echo -e "Выбран ${RED}неверный${WHITE} каталог для сайта."
    wait_for_enter
    exit 1
  fi

  db_password="$(read_user_credential "$user" "MariaDB" "Password")"
  admin_email="$(read_user_credential "$user" "Default site administrator" "Login")"
  admin_password="$(read_user_credential "$user" "Default site administrator" "Password")"
  if [[ -z "$db_password" || -z "$admin_email" || -z "$admin_password" ]]; then
    echo -e "Не удалось прочитать учетные данные из ${RED}${RISH_CREDENTIALS_DIR}/${user}${WHITE}."
    wait_for_enter
    exit 1
  fi

  echo -e "Установка OpenCart version ${GREEN}${opencart_version}${WHITE}"
  if [ -n "$(ls -A "${site_path}")" ]; then
    echo -e "Удалить содержимое папки ${GREEN}${site_path}${WHITE}?"
    vertical_menu "current" 2 0 5 "Да" "Нет"
    cr=$?
    if (( cr != 0 )); then
      echo "Установка отменена. Каталог не был изменен."
      wait_for_enter
      exit
    fi
  fi

  if ! db_exists=$(mariadb -uroot -NBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${folder}'"); then
    echo -e "Не удалось проверить наличие базы данных ${RED}${folder}${WHITE}."
    wait_for_enter
    exit 1
  fi
  if [[ -z "$db_exists" ]]; then
    echo -e "Базы данных с именем ${GREEN}${folder}${WHITE} не существует. Создать?"
  else
    echo -e "База данных с именем ${GREEN}${folder}${WHITE} уже существует. Хотите очистить ее?"
  fi
  vertical_menu "current" 2 0 5 "Да" "Нет"
  cr=$?
  if (( cr != 0 )); then
    echo "Установка отменена. База данных не была изменена."
    wait_for_enter
    exit
  fi

  echo -e "Скачиваем OpenCart ${GREEN}${opencart_version}${WHITE}..."
  if ! archive_path=$(mktemp "/tmp/rish-${archive_name}.XXXXXX"); then
    echo -e "Не удалось создать временный файл для архива ${RED}OpenCart${WHITE}."
    wait_for_enter
    exit 1
  fi
  if ! wget -q --show-progress --progress=bar:force:noscroll \
    --timeout=20 \
    --tries=2 \
    --waitretry=2 \
    -O "$archive_path" "${downloads[${choice}]}"; then
    rm -f -- "$archive_path"
    echo -e "Не удалось скачать OpenCart ${RED}${opencart_version}${WHITE}."
    wait_for_enter
    exit 1
  fi

  if compgen -G "${site_path}.rish-install.*" > /dev/null ||
    compgen -G "${site_path}.rish-package.*" > /dev/null; then
    rm -f -- "$archive_path"
    echo -e "Найдены ${RED}временные папки${WHITE} предыдущей установки."
    echo "Удалите их вручную после проверки содержимого:"
    echo "${site_path}.rish-install.*"
    echo "${site_path}.rish-package.*"
    wait_for_enter
    exit 1
  fi
  if ! package_path=$(mktemp -d "${site_path}.rish-package.XXXXXX") ||
    ! staging_path=$(mktemp -d "${site_path}.rish-install.XXXXXX") ||
    ! chmod 755 "$package_path" "$staging_path" ||
    ! unzip -q "$archive_path" -d "$package_path"; then
    rm -f -- "$archive_path"
    rm -rf -- "$package_path" "$staging_path"
    echo -e "Не удалось распаковать архив ${RED}OpenCart${WHITE}."
    wait_for_enter
    exit 1
  fi
  rm -f -- "$archive_path"

  upload_path="${package_path}/upload"
  if [[ ! -d "$upload_path" ]]; then
    upload_path=$(find "$package_path" -mindepth 1 -maxdepth 3 -type d -name upload -print -quit)
  fi
  if [[ -z "$upload_path" || ! -f "${upload_path}/install/cli_install.php" ]] ||
    ! cp -a "${upload_path}/." "$staging_path"; then
    rm -rf -- "$package_path" "$staging_path"
    echo -e "Не удалось подготовить файлы ${RED}OpenCart${WHITE}."
    wait_for_enter
    exit 1
  fi
  if [[ -f "${staging_path}/config-dist.php" ]]; then
    if ! cp "${staging_path}/config-dist.php" "${staging_path}/config.php"; then
      rm -rf -- "$package_path" "$staging_path"
      echo -e "Не удалось подготовить ${RED}config.php${WHITE} для OpenCart."
      wait_for_enter
      exit 1
    fi
  elif [[ ! -f "${staging_path}/config.php" ]]; then
    rm -rf -- "$package_path" "$staging_path"
    echo -e "Не найден ${RED}config.php${WHITE} для OpenCart."
    wait_for_enter
    exit 1
  fi
  if [[ -f "${staging_path}/admin/config-dist.php" ]]; then
    if ! cp "${staging_path}/admin/config-dist.php" "${staging_path}/admin/config.php"; then
      rm -rf -- "$package_path" "$staging_path"
      echo -e "Не удалось подготовить ${RED}admin/config.php${WHITE} для OpenCart."
      wait_for_enter
      exit 1
    fi
  elif [[ ! -f "${staging_path}/admin/config.php" ]]; then
    rm -rf -- "$package_path" "$staging_path"
    echo -e "Не найден ${RED}admin/config.php${WHITE} для OpenCart."
    wait_for_enter
    exit 1
  fi
  if ! chown -R "${user}:${user}" "$staging_path"; then
    rm -rf -- "$package_path" "$staging_path"
    echo -e "Не удалось подготовить файлы ${RED}OpenCart${WHITE}."
    wait_for_enter
    exit 1
  fi
  rm -rf -- "$package_path"

  if [[ -n "$db_exists" ]]; then
    if ! mariadb-admin -f -u root drop "${folder}"; then
      rm -rf -- "$staging_path"
      echo -e "При удалении базы данных ${RED}${folder}${WHITE} произошли ${RED}ошибки${WHITE}"
      wait_for_enter
      exit 1
    fi
    echo -e "База данных ${GREEN}${folder}${WHITE} удалена"
  fi
  if ! mariadb -u root -e "CREATE DATABASE \`${folder}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
    rm -rf -- "$staging_path"
    echo -e "Не удалось создать базу данных ${RED}${folder}${WHITE}."
    wait_for_enter
    exit 1
  fi
  echo -e "База mysql с именем ${GREEN}${folder}${WHITE} создана"
  if ! mariadb -uroot -e "GRANT ALL PRIVILEGES ON \`${folder}\`.* TO '${user}'@'localhost'; FLUSH PRIVILEGES;"; then
    rm -rf -- "$staging_path"
    echo -e "Не удалось выдать права на базу данных пользователю ${RED}${user}${WHITE}."
    wait_for_enter
    exit 1
  fi
  echo -e "Права на базу выданы пользователю ${GREEN}${user}${WHITE}"

  if ! rm -rf -- "$site_path" ||
    ! mv -- "$staging_path" "$site_path"; then
    rm -rf -- "$staging_path"
    echo -e "Не удалось заменить ${RED}файлы сайта${WHITE}."
    echo "База данных уже была пересоздана."
    wait_for_enter
    exit 1
  fi

  echo -e "Будет использована учетная запись ${GREEN}${admin_email}${WHITE}"
  if ! (
    cd "${site_path}" &&
      runuser -u "$user" -- "$php_bin" install/cli_install.php install \
        --username admin \
        --email "$admin_email" \
        --password "$admin_password" \
        --http_server "$site_url/" \
        --db_hostname localhost \
        --db_username "$user" \
        --db_password "$db_password" \
        --db_database "$folder"
  ); then
    echo -e "Установка OpenCart завершилась с ${RED}ошибкой${WHITE}."
    wait_for_enter
    exit 1
  fi
  if ! rm -rf -- "${site_path}/install"; then
    echo -e "OpenCart установлен, но не удалось удалить папку ${RED}install${WHITE}."
    wait_for_enter
    exit 1
  fi

  echo
  echo -e "Установка OpenCart ${GREEN}завершена${WHITE}."
  wait_for_enter
}

install_wordpress() {
  local wp_cli="/usr/local/bin/wp"
  local wp_cli_tmp
  local wordpress_download_path
  local site_url="http://${site_name}"
  local user
  local cr
  local db_password
  local db_exists
  local admin_email
  local admin_password

  if [[ ! -f "$wp_cli" ]]; then
    echo "WP-CLI не найден. Скачиваем официальный установщик..."
    if ! wp_cli_tmp=$(mktemp /tmp/rish-wp-cli.XXXXXX); then
      echo -e "Не удалось создать временный файл для ${RED}WP-CLI${WHITE}."
      wait_for_enter
      exit 1
    fi
    if ! curl -fsSL \
      https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
      -o "$wp_cli_tmp"; then
      rm -f -- "$wp_cli_tmp"
      echo -e "Не удалось скачать ${RED}WP-CLI${WHITE}."
      wait_for_enter
      exit 1
    fi
    if ! "$php_bin" "$wp_cli_tmp" --info > /dev/null; then
      rm -f -- "$wp_cli_tmp"
      echo -e "Скачанный ${RED}WP-CLI${WHITE} не прошел проверку."
      wait_for_enter
      exit 1
    fi
    if ! install -m 755 "$wp_cli_tmp" "$wp_cli"; then
      rm -f -- "$wp_cli_tmp"
      echo -e "Не удалось установить WP-CLI в ${RED}${wp_cli}${WHITE}."
      wait_for_enter
      exit 1
    fi
    rm -f -- "$wp_cli_tmp"
    echo -e "WP-CLI ${GREEN}установлен${WHITE}."
  elif ! "$php_bin" "$wp_cli" --info > /dev/null; then
    echo -e "Установленный WP-CLI не работает с ${RED}${php_bin}${WHITE}."
    wait_for_enter
    exit 1
  fi

  if [[ -f "/etc/httpd/conf.d/${site_name}-ssl.conf" ||
    -f "/etc/httpd/conf.d/${site_name}-le-ssl.conf" ]]; then
    site_url="https://${site_name}"
  fi

  if ! user=$(get_site_user "$directory"); then
    echo -e "Выбран ${RED}неверный${WHITE} каталог для сайта."
    wait_for_enter
    exit 1
  fi

  db_password="$(read_user_credential "$user" "MariaDB" "Password")"
  admin_email="$(read_user_credential "$user" "Default site administrator" "Login")"
  admin_password="$(read_user_credential "$user" "Default site administrator" "Password")"
  if [[ -z "$db_password" || -z "$admin_email" || -z "$admin_password" ]]; then
    echo -e "Не удалось прочитать учетные данные из ${RED}${RISH_CREDENTIALS_DIR}/${user}${WHITE}."
    wait_for_enter
    exit 1
  fi

  if [ -n "$(ls -A "${site_path}")" ]; then
    echo -e "Удалить содержимое папки ${GREEN}${site_path}${WHITE}?"
    vertical_menu "current" 2 0 5 "Да" "Нет"
    cr=$?
    if (( cr != 0 )); then
      echo "Установка отменена. Каталог не был изменен."
      wait_for_enter
      exit
    fi
  fi

  if ! db_exists=$(mariadb -uroot -NBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${folder}'"); then
    echo -e "Не удалось проверить наличие базы данных ${RED}${folder}${WHITE}."
    wait_for_enter
    exit 1
  fi
  if [[ -z "$db_exists" ]]; then
    echo -e "Базы данных с именем ${GREEN}${folder}${WHITE} не существует. Создать?"
  else
    echo -e "База данных с именем ${GREEN}${folder}${WHITE} уже существует. Хотите очистить ее?"
  fi
  vertical_menu "current" 2 0 5 "Да" "Нет"
  cr=$?
  if (( cr != 0 )); then
    echo "Установка отменена. База данных не была изменена."
    wait_for_enter
    exit
  fi

  if compgen -G "${site_path}.rish-install.*" > /dev/null; then
    echo -e "Найдены ${RED}временные папки${WHITE} предыдущей установки."
    echo "Удалите их вручную после проверки содержимого:"
    echo "${site_path}.rish-install.*"
    wait_for_enter
    exit 1
  fi
  if ! wordpress_download_path=$(mktemp -d "${site_path}.rish-install.XXXXXX") ||
    ! chmod 755 "$wordpress_download_path" ||
    ! chown "${user}:${user}" "$wordpress_download_path"; then
    rm -rf -- "$wordpress_download_path"
    echo -e "Не удалось подготовить временную папку для ${RED}WordPress${WHITE}."
    wait_for_enter
    exit 1
  fi

  echo "Скачиваем WordPress..."
  if ! runuser -u "$user" -- "$php_bin" "$wp_cli" core download \
    --path="$wordpress_download_path"; then
    rm -rf -- "$wordpress_download_path"
    echo -e "Не удалось скачать ${RED}WordPress${WHITE}."
    wait_for_enter
    exit 1
  fi

  if [[ -n "$db_exists" ]]; then
    if ! mariadb-admin -f -u root drop "${folder}"; then
      rm -rf -- "$wordpress_download_path"
      echo -e "При удалении базы данных ${RED}${folder}${WHITE} произошли ${RED}ошибки${WHITE}"
      wait_for_enter
      exit 1
    fi
    echo -e "База данных ${GREEN}${folder}${WHITE} удалена"
  fi
  if ! mariadb -u root -e "CREATE DATABASE \`${folder}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
    rm -rf -- "$wordpress_download_path"
    echo -e "Не удалось создать базу данных ${RED}${folder}${WHITE}."
    wait_for_enter
    exit 1
  fi
  echo -e "База mysql с именем ${GREEN}${folder}${WHITE} создана"
  if ! mariadb -uroot -e "GRANT ALL PRIVILEGES ON \`${folder}\`.* TO '${user}'@'localhost'; FLUSH PRIVILEGES;"; then
    rm -rf -- "$wordpress_download_path"
    echo -e "Не удалось выдать права на базу данных пользователю ${RED}${user}${WHITE}."
    wait_for_enter
    exit 1
  fi
  echo -e "Права на базу выданы пользователю ${GREEN}${user}${WHITE}"

  if ! rm -rf -- "$site_path" ||
    ! mv -- "$wordpress_download_path" "$site_path"; then
    rm -rf -- "$wordpress_download_path"
    echo -e "Не удалось заменить ${RED}файлы сайта${WHITE}."
    echo "База данных уже была пересоздана."
    wait_for_enter
    exit 1
  fi

  if ! runuser -u "$user" -- "$php_bin" "$wp_cli" config create \
    --path="$site_path" \
    --dbname="$folder" \
    --dbuser="$user" \
    --dbpass="$db_password" \
    --dbhost=localhost; then
    echo -e "Не удалось создать ${RED}wp-config.php${WHITE}."
    wait_for_enter
    exit 1
  fi
  if ! runuser -u "$user" -- "$php_bin" "$wp_cli" core install \
    --path="$site_path" \
    --url="$site_url" \
    --title="$site_name" \
    --admin_user="$admin_email" \
    --admin_password="$admin_password" \
    --admin_email="$admin_email" \
    --skip-email; then
    echo -e "Установка WordPress завершилась с ${RED}ошибкой${WHITE}."
    wait_for_enter
    exit 1
  fi
  if ! runuser -u "$user" -- "$php_bin" "$wp_cli" language core install ru_RU \
    --path="$site_path" \
    --activate; then
    echo -e "Не удалось включить русский язык ${RED}WordPress${WHITE}."
    echo "Основная установка WordPress завершена успешно."
    wait_for_enter
    return
  fi

  echo
  echo -e "Установка WordPress ${GREEN}завершена${WHITE}."
  echo -e "Будет использована учетная запись ${GREEN}${admin_email}${WHITE}"
  wait_for_enter
}

install_phpmyadmin() {
  bash /root/rish/scripts/phpmyadmin_install.sh "$folder" "$directory"
}

audit_joomla_extensions() {
  local site_user=""

  if ! site_user=$(get_site_user "$directory"); then
    site_user=""
  fi

  bash /root/rish/scripts/joomla_extensions_audit.sh \
    "$site_path" "$site_name" "$joomla_version" "$php_bin" "$site_user"
}

run_manual_joomla_cli_command() {
  local user
  local command_line
  local full_command
  local -a command_args

  if ! user=$(get_site_user "$directory"); then
    echo -e "Выбран ${RED}неверный${WHITE} каталог для сайта."
    wait_for_enter
    return
  fi

  run_joomla_user_command "$user" list

  while true; do
    echo
    echo 'Введите CLI команду Joomla без "php cli/joomla.php".'
    echo -e "Например, для вывода списка пользователей введите: ${GREEN}user:list${WHITE}"
    echo "Аргументы с пробелами в кавычках не поддерживаются."
    echo
    echo -e "Пустая строка - выход. Команда: ${GREEN}"
    read -r -e command_line
    echo -e -n "${WHITE}"
    if [[ -z "$command_line" ]]; then
      return
    fi

    read -r -a command_args <<< "$command_line"
    full_command="cd $(shell_quote_command "$site_path") && $(shell_quote_command runuser -u "$user" -- "$php_bin" cli/joomla.php "${command_args[@]}")"
    echo
    run_joomla_user_command "$user" "${command_args[@]}"
    echo
    echo "Команда:"
    echo "$full_command"
  done
}

dir_is_phpmyadmin() {
  local target="$1"

  [[ -f "${target}/README" && -f "${target}/config.sample.inc.php" ]]
}

phpmyadmin_version() {
  local target="$1"
  local version

  version="$(sed -n 's/^Version \(.*\)$/\1/p' "${target}/README" | head -n 1)"
  if [[ -n "$version" ]]; then
    printf '%s' "$version"
  else
    printf 'unknown version'
  fi
}

detect_phpmyadmin_installations() {
  local candidate
  local relative_path
  local version

  while IFS= read -r candidate; do
    candidate="${candidate%/config.sample.inc.php}"
    dir_is_phpmyadmin "$candidate" || continue

    if [[ "$candidate" == "$site_path" ]]; then
      relative_path="корень сайта"
    else
      relative_path="${candidate#${site_path}/}"
    fi

    version="$(phpmyadmin_version "$candidate")"
    site_phpmyadmin_version="$version"
    site_phpmyadmin_path="$relative_path"
    return 0
  done < <(
    find "$site_path" \
      -maxdepth 4 \
      \( -path "${site_path}/cache" -o \
         -path "${site_path}/tmp" -o \
         -path "${site_path}/administrator/cache" -o \
         -path "${site_path}/vendor" -o \
         -path "${site_path}/node_modules" -o \
         -path "${site_path}/wp-content/uploads" \) -prune -o \
      -type f -name config.sample.inc.php -print 2>/dev/null
  )
  return 1
}

fix_joomla_site_configuration() {
  local config_parent="${site_path%/*}"
  local config_name="${site_path##*/}"

  if [[ ! -f "${site_path}/configuration.php" ]]; then
    echo
    echo -e "В выбранной папке нет файла ${GREEN}configuration.php${WHITE}."
    echo "Папка не выглядит как сайт Joomla."
    wait_for_enter
    return
  fi

  echo
  echo -e "Сайт распознан как созданный на основе ${GREEN}Joomla${WHITE}."
  echo -e "Вы хотите внести изменения в файл ${GREEN}configuration.php${WHITE}, чтобы сайт работал корректно?"
  if vertical_menu "current" 2 0 5 "Да" "Нет"; then
    fix_joomla_configuration "$config_parent" "$config_name" "$folder"
    echo
  else
    echo -e "Никаких изменений в файл ${GREEN}configuration.php${WHITE} не вносилось."
  fi
  wait_for_enter
}

clear

if [[ -z "$directory" || -z "$folder" || "$folder" == "." || "$folder" == ".." || ! -d "$site_root_path" ]]; then
  echo -e "Установите курсор на ${RED}папку сайта${WHITE}."
  wait_for_enter
  exit 1
fi

if ! echo "$site_name" | grep -Eq '^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'; then
  echo -e "Имя выбранной папки не похоже на домен: ${RED}${site_name}${WHITE}."
  echo "Установите курсор на папку сайта."
  wait_for_enter
  exit 1
fi

if [[ ! -f "/etc/httpd/conf.d/${site_name}.conf" ]]; then
  echo -e "Не найден Apache vhost для сайта ${RED}${site_name}${WHITE}."
  echo "Вначале создайте сайт (vhost)."
  wait_for_enter
  exit 1
fi

site_path=$(awk '$1 == "DocumentRoot" { print $2; exit }' "/etc/httpd/conf.d/${site_name}.conf")
if [[ -z "$site_path" || ! -d "$site_path" ]]; then
  echo -e "Не удалось определить DocumentRoot сайта ${RED}${site_name}${WHITE}."
  wait_for_enter
  exit 1
fi
if [[ "$site_path" != "$site_root_path" && "$site_path" != "$site_root_path/"* ]]; then
  echo -e "DocumentRoot сайта ${RED}не относится${WHITE} к выбранной папке."
  echo -e "Выбрано: ${GREEN}${site_root_path}${WHITE}"
  echo -e "DocumentRoot: ${GREEN}${site_path}${WHITE}"
  wait_for_enter
  exit 1
fi

php_bin=$(get_site_php_bin)
if [[ -f "${site_path}/configuration.php" &&
  -f "${site_path}/administrator/manifests/files/joomla.xml" ]]; then
  site_is_joomla=1
  joomla_version=$(
    sed -nE 's@.*<version>[[:space:]]*([0-9]+(\.[0-9]+)+)[[:space:]]*</version>.*@\1@p' \
      "${site_path}/administrator/manifests/files/joomla.xml" |
      head -n 1
  )
  if [[ -n "$joomla_version" ]]; then
    site_cms="Joomla ${joomla_version}"
  else
    site_cms="Joomla"
  fi
  if [[ -f "${site_path}/cli/joomla.php" ]]; then
    site_has_joomla_cli=1
  fi
  if [[ "$joomla_version" =~ ^[56]\. ]]; then
    site_supports_joomla_user_cli=1
  fi
fi
if [[ -n "$php_bin" ]]; then
  echo -e "Установка/управление CMS/phpMyAdmin для сайта: ${GREEN}${site_name}${WHITE}"
  echo
  echo -e "DocumentRoot сайта: ${GREEN}${site_path}${WHITE}"
  echo -e "PHP сайта: ${GREEN}${php_bin}${WHITE}"
  if [[ -n "$site_cms" ]]; then
    echo -e "CMS сайта: ${GREEN}${site_cms}${WHITE}"
  fi
  if detect_phpmyadmin_installations; then
    echo -e "phpMyAdmin: ${GREEN}${site_phpmyadmin_version}${WHITE} (установлен в ${site_phpmyadmin_path})"
  fi
else
  echo -e "Не удалось определить PHP сайта из конфигурации ${RED}Apache${WHITE}."
  echo "Проверьте vhost выбранного сайта и наличие /bin/phpXX."
  wait_for_enter
  exit 1
fi

echo
echo "Выберите действие:"
menu_items=()
menu_actions=()
if (( site_is_joomla == 1 )); then
  menu_items+=("Проверить расширения Joomla")
  menu_actions+=("audit_joomla_extensions")
  if (( site_has_joomla_cli == 1 )); then
    menu_items+=("Обновление Joomla")
    menu_actions+=("update_joomla")
    if (( site_supports_joomla_user_cli == 1 )); then
      menu_items+=("Управление пользователями Joomla")
      menu_actions+=("manage_joomla_users")
    fi
    menu_items+=("Выполнить CLI команду Joomla")
    menu_actions+=("run_manual_joomla_cli_command")
  fi
fi
if [[ -f "${site_path}/configuration.php" ]]; then
  menu_items+=("Настроить Joomla configuration.php")
  menu_actions+=("fix_joomla_site_configuration")
fi
menu_items+=("Установка Joomla" "Установка WordPress" "Установка OpenCart" "Установка/обновление phpMyAdmin" "Выйти")
menu_actions+=("install_joomla" "install_wordpress" "install_opencart" "install_phpmyadmin" "exit")

vertical_menu "current" 2 0 30 "${menu_items[@]}"
choice=$?
if (( choice == 255 )) || [[ "${menu_actions[${choice}]}" == "exit" ]]; then
  echo "Выход. Никаких действий произведено не было."
  wait_for_enter
else
  "${menu_actions[${choice}]}"
fi
