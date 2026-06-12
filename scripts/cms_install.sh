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
site_phpmyadmin_path=""
site_phpmyadmin_version=""

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

  if [[ "$path" =~ ^/var/www/([^/]+)/www(/.*)?$ ]]; then
    user="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  if id -u "$user" > /dev/null 2>&1 && [[ -f "/home/${user}/.pass.txt" ]]; then
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
    echo -e "${RED}Не удалось получить список версий Joomla.${WHITE}"
    wait_for_enter
    exit 1
  fi
  mapfile -t downloads < <(
    printf '%s\n' "$releases_json" |
      grep 'browser_download.*Stable-Full.*tar.gz' |
      grep -Eo 'https?://[^ ]+Stable-Full_Package.tar.gz'
  )
  if (( ${#downloads[@]} == 0 )); then
    echo -e "${RED}Не найдены доступные для скачивания версии Joomla.${WHITE}"
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
    echo -e "${RED}Не удалось определить версию выбранного архива Joomla.${WHITE}"
    wait_for_enter
    exit 1
  fi
  joomla_minor_version=${joomla_full_version%.*}
  archive_name="${joomlas[${choice}]}"

  if [[ -z "$php_bin" ]]; then
    echo -e "${RED}Установка Joomla невозможна: не определен PHP сайта.${WHITE}"
    wait_for_enter
    exit 1
  fi

  if ! user=$(get_site_user "$directory"); then
    echo -e "${RED}Неверно выбран каталог для сайта.${WHITE}"
    wait_for_enter
    exit 1
  fi

  db_password=$( awk '/^Database:/ { print $2 }' "/home/${user}/.pass.txt" )
  admin_email=$( awk '/^defaultsiteaccount / { print $2 }' "/home/${user}/.pass.txt" )
  admin_password=$( awk '/^defaultsiteaccount / { print $3 }' "/home/${user}/.pass.txt" )
  if [[ -z "$db_password" || -z "$admin_email" || -z "$admin_password" ]]; then
    echo -e "Не удалось прочитать учетные данные из ${RED}/home/${user}/.pass.txt${WHITE}."
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
    echo -e "${RED}Не удалось создать временный файл для архива Joomla.${WHITE}"
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
    echo -e "${RED}Найдены временные папки предыдущей установки.${WHITE}"
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
    echo -e "${RED}Не удалось распаковать архив Joomla.${WHITE}"
    wait_for_enter
    exit 1
  fi
  rm -f -- "$archive_path"

  if [[ ! -f "${staging_path}/htaccess.txt" ]] ||
    ! mv "${staging_path}/htaccess.txt" "${staging_path}/.htaccess" ||
    ! chown -R "${user}:${user}" "$staging_path"; then
    rm -rf -- "$staging_path"
    echo -e "${RED}Не удалось подготовить файлы Joomla.${WHITE}"
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
    echo -e "${RED}Не удалось заменить файлы сайта.${WHITE}"
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
    echo -e "${RED}Установка Joomla завершилась с ошибкой.${WHITE}"
    wait_for_enter
    exit 1
  }

  echo
  echo -e "${GREEN}Установка Joomla завершена.${WHITE}"
  echo
  echo "Установить русскую локализацию?"
  vertical_menu "current" 2 0 5 "Да" "Нет"
  cr=$?
  if (( cr == 0 )); then
    if ! localisation_json=$(curl -fsSL https://api.github.com/repos/JPathRu/localisation/releases); then
      echo -e "${RED}Не удалось получить список пакетов русской локализации.${WHITE}"
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
          echo -e "${RED}Не удалось установить русскую локализацию.${WHITE}"
          echo "Основная установка Joomla завершена успешно."
          wait_for_enter
          return
        }
      echo -e "${GREEN}Русская локализация установлена.${WHITE}"
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
    echo -e "${RED}Неверно выбран каталог для сайта.${WHITE}"
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

  echo -e "${GREEN}Обновление Joomla завершено.${WHITE}"
  wait_for_enter
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
  local site_url="http://${site_name}"
  local user
  local cr
  local db_password
  local db_exists
  local admin_email
  local admin_password

  if ! releases_json=$(curl -fsSL https://api.github.com/repos/opencart/opencart/releases); then
    echo -e "${RED}Не удалось получить список версий OpenCart.${WHITE}"
    wait_for_enter
    exit 1
  fi
  mapfile -t downloads < <(
    printf '%s\n' "$releases_json" |
      grep browser_download_url |
      grep -Eo 'https?://[^ "]+/opencart-[34](\.[0-9]+)+\.zip'
  )
  if (( ${#downloads[@]} == 0 )); then
    echo -e "${RED}Не найдены доступные для скачивания версии OpenCart.${WHITE}"
    wait_for_enter
    exit 1
  fi
  echo "Выберите версию OpenCart для скачивания:"
  mapfile -t opencarts < <(
    printf '%s\n' "${downloads[@]}" |
      awk -F"/" '{print $NF}'
  )
  vertical_menu "current" 2 0 30 "${opencarts[@]}"
  choice=$?
  if (( choice == 255 )); then
    echo "Выход. Каталог не тронут. Никаких действий произведено не было."
    wait_for_enter
    exit
  fi
  archive_name="${opencarts[${choice}]}"
  opencart_version=$( echo "$archive_name" | sed -n 's/^opencart-\([0-9.]\+\)\.zip$/\1/p' )
  if [[ -z "$opencart_version" ]]; then
    echo -e "${RED}Не удалось определить версию выбранного архива OpenCart.${WHITE}"
    wait_for_enter
    exit 1
  fi

  if [[ -f "/etc/httpd/conf.d/${site_name}-ssl.conf" ||
    -f "/etc/httpd/conf.d/${site_name}-le-ssl.conf" ]]; then
    site_url="https://${site_name}"
  fi

  if ! user=$(get_site_user "$directory"); then
    echo -e "${RED}Неверно выбран каталог для сайта.${WHITE}"
    wait_for_enter
    exit 1
  fi

  db_password=$( awk '/^Database:/ { print $2 }' "/home/${user}/.pass.txt" )
  admin_email=$( awk '/^defaultsiteaccount / { print $2 }' "/home/${user}/.pass.txt" )
  admin_password=$( awk '/^defaultsiteaccount / { print $3 }' "/home/${user}/.pass.txt" )
  if [[ -z "$db_password" || -z "$admin_email" || -z "$admin_password" ]]; then
    echo -e "Не удалось прочитать учетные данные из ${RED}/home/${user}/.pass.txt${WHITE}."
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
    echo -e "${RED}Не удалось создать временный файл для архива OpenCart.${WHITE}"
    wait_for_enter
    exit 1
  fi
  if ! wget -q --show-progress --progress=bar:force:noscroll \
    -O "$archive_path" "${downloads[${choice}]}"; then
    rm -f -- "$archive_path"
    echo -e "Не удалось скачать OpenCart ${RED}${opencart_version}${WHITE}."
    wait_for_enter
    exit 1
  fi

  if compgen -G "${site_path}.rish-install.*" > /dev/null ||
    compgen -G "${site_path}.rish-package.*" > /dev/null; then
    rm -f -- "$archive_path"
    echo -e "${RED}Найдены временные папки предыдущей установки.${WHITE}"
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
    echo -e "${RED}Не удалось распаковать архив OpenCart.${WHITE}"
    wait_for_enter
    exit 1
  fi
  rm -f -- "$archive_path"

  upload_path="${package_path}/upload"
  if [[ ! -d "$upload_path" ]]; then
    upload_path=$(find "$package_path" -mindepth 1 -maxdepth 3 -type d -name upload -print -quit)
  fi
  if [[ -z "$upload_path" || ! -f "${upload_path}/install/cli_install.php" ]] ||
    ! cp -a "${upload_path}/." "$staging_path" ||
    ! cp "${staging_path}/config-dist.php" "${staging_path}/config.php" ||
    ! cp "${staging_path}/admin/config-dist.php" "${staging_path}/admin/config.php" ||
    ! chown -R "${user}:${user}" "$staging_path"; then
    rm -rf -- "$package_path" "$staging_path"
    echo -e "${RED}Не удалось подготовить файлы OpenCart.${WHITE}"
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
    echo -e "${RED}Не удалось заменить файлы сайта.${WHITE}"
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
    echo -e "${RED}Установка OpenCart завершилась с ошибкой.${WHITE}"
    wait_for_enter
    exit 1
  fi
  if ! rm -rf -- "${site_path}/install"; then
    echo -e "${RED}OpenCart установлен, но не удалось удалить папку install.${WHITE}"
    wait_for_enter
    exit 1
  fi

  echo
  echo -e "${GREEN}Установка OpenCart завершена.${WHITE}"
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
      echo -e "${RED}Не удалось создать временный файл для WP-CLI.${WHITE}"
      wait_for_enter
      exit 1
    fi
    if ! curl -fsSL \
      https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
      -o "$wp_cli_tmp"; then
      rm -f -- "$wp_cli_tmp"
      echo -e "${RED}Не удалось скачать WP-CLI.${WHITE}"
      wait_for_enter
      exit 1
    fi
    if ! "$php_bin" "$wp_cli_tmp" --info > /dev/null; then
      rm -f -- "$wp_cli_tmp"
      echo -e "${RED}Скачанный WP-CLI не прошел проверку.${WHITE}"
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
    echo -e "${GREEN}WP-CLI установлен.${WHITE}"
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
    echo -e "${RED}Неверно выбран каталог для сайта.${WHITE}"
    wait_for_enter
    exit 1
  fi

  db_password=$( awk '/^Database:/ { print $2 }' "/home/${user}/.pass.txt" )
  admin_email=$( awk '/^defaultsiteaccount / { print $2 }' "/home/${user}/.pass.txt" )
  admin_password=$( awk '/^defaultsiteaccount / { print $3 }' "/home/${user}/.pass.txt" )
  if [[ -z "$db_password" || -z "$admin_email" || -z "$admin_password" ]]; then
    echo -e "Не удалось прочитать учетные данные из ${RED}/home/${user}/.pass.txt${WHITE}."
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
    echo -e "${RED}Найдены временные папки предыдущей установки.${WHITE}"
    echo "Удалите их вручную после проверки содержимого:"
    echo "${site_path}.rish-install.*"
    wait_for_enter
    exit 1
  fi
  if ! wordpress_download_path=$(mktemp -d "${site_path}.rish-install.XXXXXX") ||
    ! chmod 755 "$wordpress_download_path" ||
    ! chown "${user}:${user}" "$wordpress_download_path"; then
    rm -rf -- "$wordpress_download_path"
    echo -e "${RED}Не удалось подготовить временную папку для WordPress.${WHITE}"
    wait_for_enter
    exit 1
  fi

  echo "Скачиваем WordPress..."
  if ! runuser -u "$user" -- "$php_bin" "$wp_cli" core download \
    --path="$wordpress_download_path"; then
    rm -rf -- "$wordpress_download_path"
    echo -e "${RED}Не удалось скачать WordPress.${WHITE}"
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
    echo -e "${RED}Не удалось заменить файлы сайта.${WHITE}"
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
    echo -e "${RED}Не удалось создать wp-config.php.${WHITE}"
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
    echo -e "${RED}Установка WordPress завершилась с ошибкой.${WHITE}"
    wait_for_enter
    exit 1
  fi
  if ! runuser -u "$user" -- "$php_bin" "$wp_cli" language core install ru_RU \
    --path="$site_path" \
    --activate; then
    echo -e "${RED}Не удалось включить русский язык WordPress.${WHITE}"
    echo "Основная установка WordPress завершена успешно."
    wait_for_enter
    return
  fi

  echo
  echo -e "${GREEN}Установка WordPress завершена.${WHITE}"
  echo -e "Будет использована учетная запись ${GREEN}${admin_email}${WHITE}"
  wait_for_enter
}

install_phpmyadmin() {
  bash /root/rish/scripts/phpmyadmin_install.sh "$folder" "$directory"
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
  -f "${site_path}/administrator/manifests/files/joomla.xml" &&
  -f "${site_path}/cli/joomla.php" ]]; then
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
if [[ -f "${site_path}/configuration.php" &&
  -f "${site_path}/administrator/manifests/files/joomla.xml" &&
  -f "${site_path}/cli/joomla.php" ]]; then
  menu_items+=("Обновление Joomla")
  menu_actions+=("update_joomla")
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
