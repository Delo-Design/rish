#!/usr/bin/env bash
# shellcheck disable=SC1091
source /root/rish/windows.sh
# shellcheck disable=SC1091
source /root/rish/change_php_version.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'

function validate_site_name() {
  local name="$1"

  echo "$name" | grep -Eq '^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$' || return 1

  if [[ "$name" =~ (^|\.)xn-- ]]; then
    idn2 -d "$name" >/dev/null 2>&1 || return 1
  fi

  return 0
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

function check_site() {
  local folder_name="$1"
  local directory_path="$2"
  local choice=""

  # Обнуляем имя, если . или ..
  [[ "$folder_name" == "." || "$folder_name" == ".." ]] && folder_name=""

  # Проверка заглавных букв — до входа в цикл
  if [[ -d "$directory_path/$folder_name" ]]; then
    if [[ "$folder_name" =~ [[:upper:]] ]]; then
      local lower_name="${folder_name,,}"
      if [[ "$lower_name" != "$folder_name" && ! -e "$directory_path/$lower_name" ]]; then
        mv "$directory_path/$folder_name" "$directory_path/$lower_name"
        echo -e "${GREEN}${folder_name}${WHITE}  --->  ${GREEN}${lower_name}${WHITE}"
        folder_name="$lower_name"
      elif [[ "$lower_name" != "$folder_name" ]]; then
        echo -e "${YELLOW}Невозможно${WHITE} переименовать папку: ${GREEN}${folder_name}${WHITE}  --->  ${GREEN}${lower_name}${WHITE}"
        echo -e "${GREEN}${lower_name}${WHITE} уже существует.${WHITE}"
        echo -e "Переименуйте папку самостоятельно или выберите другое имя – будет создана новая папка."
        folder_name="$lower_name"
      fi
    fi
  fi

  while true; do
    echo
    echo -e "${WHITE}Введите имя сайта (пустая строка для выхода):${GREEN}"
    read -r -e -i "$folder_name" site_name
    echo -en "${WHITE}"
    site_name="${site_name,,}"

    if [[ -z "$site_name" ]]; then
      echo -e -n "${CURSORUP}${ERASEUNTILLENDOFLINE}"
      return 1
    fi

    # Преобразование кириллицы
    if echo "$site_name" | grep -qP '[А-Яа-яЁё]'; then
      local punycode_input
      punycode_input=$(idn2 --quiet "$site_name" 2>/dev/null)
      if [[ -n "$punycode_input" && "$punycode_input" != "$site_name" ]]; then
        echo -e "${GREEN}${site_name}${WHITE}  --->  ${GREEN}${punycode_input}${WHITE}"
        site_name="$punycode_input"
      fi
    fi

    # Проверка имени — минимум два уровня, ASCII, punycode тоже ок
    if ! validate_site_name "$site_name"; then
      echo -e "${RED}Имя сайта некорректное.${WHITE}"
      folder_name="$site_name"
      continue
    fi

    # Переименование папки в punycode
    if [[ -d "$directory_path/$folder_name" ]]; then
      if echo "$folder_name" | grep -qP '[А-Яа-яЁё]'; then
        local punycode_name
        punycode_name=$(idn2 --quiet "$folder_name" 2>/dev/null)
        if [[ "$punycode_name" != "$folder_name" && ! -e "$directory_path/$punycode_name" ]]; then
          mv "$directory_path/$folder_name" "$directory_path/$punycode_name"
          echo -e "Папка была переименована: ${GREEN}${folder_name}${WHITE}  --->  ${GREEN}${punycode_name}${WHITE}"
          folder_name="$punycode_name"
        elif [[ "$punycode_name" != "$folder_name" ]]; then
          echo -e "${YELLOW}Невозможно${WHITE} переименовать папку: ${GREEN}${folder_name}${WHITE}  --->  ${GREEN}${punycode_name}${WHITE}"
          echo -e "Папка ${GREEN}${punycode_name}${WHITE} уже существует."
          folder_name="$punycode_name"
          continue
        fi
      fi
    fi

    # Проверка: сайт уже существует?
    if [[ -f "/etc/httpd/conf.d/$site_name.conf" ]]; then
      echo -e "Сайт ${RED}$site_name${WHITE} уже существует."
      local can_use_existing=0
      local conf_file="/etc/httpd/conf.d/$site_name.conf"
      local current_path=""
      local expected_path="${directory_path%/}/${site_name}"
      current_path=$(awk '$1 == "DocumentRoot" { print $2; exit }' "$conf_file")

      if [[ -z "$current_path" ]]; then
        echo -e "Не удалось определить DocumentRoot в конфиге: ${RED}${conf_file}${WHITE}"
      elif [[ "$current_path" == "$expected_path" || "$current_path" == "$expected_path/"* ]]; then
        can_use_existing=1
      else
        echo -e "DocumentRoot существующего сайта указывает на: ${YELLOW}${current_path}${WHITE}"
        echo -e "Ожидается путь внутри: ${YELLOW}${expected_path}${WHITE}"
      fi

      if [[ "$can_use_existing" -eq 1 ]]; then
        vertical_menu "current" 2 0 50 "Использовать $site_name" "Ввести другое имя" "Отменить создание"
      else
        vertical_menu "current" 2 0 50 "Ввести другое имя" "Отменить создание"
      fi
      choice=$?
      echo -e "${CURSORUP}${ERASEUNTILLENDOFLINE}"
      if [[ "$can_use_existing" -eq 1 ]]; then
        case "$choice" in
          0) return 2 ;;
          1) folder_name="$site_name"; continue ;;
          2 | 255) return 1 ;;
        esac
      else
        case "$choice" in
          0) folder_name="$site_name"; continue ;;
          1 | 255) return 1 ;;
        esac
      fi
    fi

    # Подтверждение создания
    echo -e "Имя сайта: ${GREEN}$(format_site_name_label "$site_name")${WHITE}"

    vertical_menu "current" 2 0 50 "Да" "Выйти" "Ввести другое имя"
    choice=$?
    case "$choice" in
      0) return 0 ;;
      1 | 255) return 1 ;;
      2) folder_name="$site_name"; continue ;;
    esac
  done
}

function rollback_create_site_core() {
  local conf_file="$1"
  local pool_file="$2"

  if [[ -n "$conf_file" && -f "$conf_file" ]]; then
    rm -f "$conf_file"
    echo -e "Удален созданный vhost: ${YELLOW}${conf_file}${WHITE}"
  fi

  if [[ -n "$pool_file" && -f "$pool_file" ]]; then
    rm -f "$pool_file"
    echo -e "Удален созданный PHP-FPM pool: ${YELLOW}${pool_file}${WHITE}"
  fi
}

function create_site_core() {
  local site_name="$1"
  local path="$2"
  local selected_php="$3"
  local DocumentRoot="$4"
  local php_mode="${5:-ondemand}"
  local restart_php_fpm="${6:-1}"
  local reload_apache="${7:-1}"
  local update_hotlist="${8:-1}"
  local conf_file
  local created_pool_file=""
  local document_root_path
  local php_fpm_bin
  local pool_file
  local site_dir
  local username

  if [[ -z "$site_name" || -z "$path" || -z "$selected_php" ]]; then
    echo -e "Не хватает ${RED}параметров${WHITE} для создания сайта."
    return 1
  fi

  site_name="${site_name,,}"

  if ! validate_site_name "$site_name"; then
    echo -e "Имя сайта ${RED}некорректное${WHITE}: ${site_name}"
    return 1
  fi

  if [[ ! "$selected_php" =~ ^php[0-9]{2}$ ]]; then
    echo -e "Версия PHP ${RED}некорректная${WHITE}: ${selected_php}"
    return 1
  fi

  if [[ "$php_mode" != "ondemand" && "$php_mode" != "dynamic" ]]; then
    echo -e "Режим PHP-FPM ${RED}некорректный${WHITE}: ${php_mode}"
    return 1
  fi

  if [[ "$restart_php_fpm" != "0" && "$restart_php_fpm" != "1" ]]; then
    echo -e "Параметр restart_php_fpm ${RED}некорректный${WHITE}: ${restart_php_fpm}"
    return 1
  fi

  if [[ "$reload_apache" != "0" && "$reload_apache" != "1" && "$reload_apache" != "ask" ]]; then
    echo -e "Параметр reload_apache ${RED}некорректный${WHITE}: ${reload_apache}"
    return 1
  fi

  if [[ "$update_hotlist" != "0" && "$update_hotlist" != "1" ]]; then
    echo -e "Параметр update_hotlist ${RED}некорректный${WHITE}: ${update_hotlist}"
    return 1
  fi

  if [[ "$path" =~ ^/var/www/([^/]+)/www/?$ ]]; then
    username="${BASH_REMATCH[1]}"
  else
    echo -e "Не удалось определить пользователя из пути ${RED}${path}${WHITE}."
    echo -e "Ожидается путь вида ${YELLOW}/var/www/<user>/www${WHITE}."
    return 1
  fi

  conf_file="/etc/httpd/conf.d/${site_name}.conf"
  if [[ -e "$conf_file" ]]; then
    echo -e "Конфиг сайта уже существует: ${RED}${conf_file}${WHITE}"
    return 1
  fi

  php_fpm_bin="/opt/remi/${selected_php}/root/usr/sbin/php-fpm"
  if [[ ! -x "$php_fpm_bin" ]]; then
    echo -e "PHP-FPM для ${GREEN}${selected_php}${WHITE} не найден: ${RED}${php_fpm_bin}${WHITE}"
    return 1
  fi

  DocumentRoot="${DocumentRoot#/}"
  if [[ -n "$DocumentRoot" ]]; then
    if [[ "$DocumentRoot" == "." || "$DocumentRoot" == ".." || "$DocumentRoot" == *"/../"* || "$DocumentRoot" == "../"* || "$DocumentRoot" == *"/.." ]]; then
      echo -e "DocumentRoot ${RED}некорректный${WHITE}: ${DocumentRoot}"
      return 1
    fi
    DocumentRoot="/${DocumentRoot}"
  fi

  site_dir="${path}/${site_name}"
  document_root_path="${site_dir}${DocumentRoot}"

  if [[ -d "$document_root_path" ]]; then
    echo -e "Используем существующую папку сайта: ${GREEN}${site_name}${WHITE}"
  else
    echo -e "Создаем папку сайта: ${GREEN}${site_name}${WHITE}"
  fi
  if [[ -n "$DocumentRoot" ]]; then
    echo -e "DocumentRoot: ${GREEN}${DocumentRoot#/}${WHITE}"
  fi
  if ! mkdir -p "$document_root_path"; then
    echo -e "Не удалось создать папку сайта: ${RED}${document_root_path}${WHITE}"
    return 1
  fi

  echo -e "Назначаем владельца: ${GREEN}${username}:${username}${WHITE}"
  if ! chown -R "${username}:${username}" "$site_dir"; then
    echo -e "Не удалось назначить владельца для папки: ${RED}${site_dir}${WHITE}"
    return 1
  fi

  echo -e "Настраиваем права на папки сайта: ${GREEN}755${WHITE}"
  if ! find "$site_dir" -type d -print0 | xargs -0 chmod 755; then
    echo -e "Не удалось настроить права на папки сайта: ${RED}${site_dir}${WHITE}"
    return 1
  fi

  if find "$site_dir" -type f -print -quit | grep -q .; then
    echo -e "Настраиваем права на файлы сайта: ${GREEN}644${WHITE}"
    if ! find "$site_dir" -type f -print0 | xargs -0 chmod 644; then
      echo -e "Не удалось настроить права на файлы сайта: ${RED}${site_dir}${WHITE}"
      return 1
    fi
  fi

  echo -e "Создаем vhost: ${GREEN}${conf_file}${WHITE}"
  echo
  if ! {
    echo "<VirtualHost *:80>"
    echo "ServerAdmin webmaster@localhost"
    echo "ServerName ${site_name}"
    echo "ServerAlias www.${site_name}"
    echo "DocumentRoot /var/www/${username}/www/${site_name}${DocumentRoot}"
    echo ""
    echo "<FilesMatch \.php$>"
    echo "    SetHandler \"proxy:unix:/var/opt/remi/${selected_php}/run/php-fpm/${username}.sock|fcgi://localhost\""
    echo "</FilesMatch>"
    echo ""
    echo "DirectoryIndex index.php index.html"
    echo ""
    echo "<Directory /var/www/${username}/www/${site_name}${DocumentRoot}>"
    echo "    Options -Indexes +FollowSymLinks"
    echo "    AllowOverride All"
    echo "    Require all granted"
    echo "</Directory>"
    echo ""
    echo "ServerSignature Off"
    echo "ErrorLog /var/www/${username}/logs/${site_name}-error-log"
    echo "LogLevel warn"
    echo "CustomLog /var/www/${username}/logs/${site_name}-access-log combined"
    echo "</VirtualHost>"
  } >"$conf_file"; then
    echo -e "Не удалось записать vhost: ${RED}${conf_file}${WHITE}"
    rollback_create_site_core "$conf_file" ""
    return 1
  fi

  pool_file="/etc/opt/remi/${selected_php}/php-fpm.d/${username}.conf"
  if [[ ! -f "$pool_file" ]]; then
    echo -e "Создаем PHP-FPM pool для пользователя ${GREEN}${username}${WHITE} в режиме ${GREEN}${php_mode}${WHITE}"
    if ! create_php_fpm_pool "$selected_php" "$username" "$php_mode"; then
      echo -e "Не удалось создать PHP-FPM pool для пользователя: ${RED}${username}${WHITE}"
      rollback_create_site_core "$conf_file" "$pool_file"
      return 1
    fi
    created_pool_file="$pool_file"
  fi

  if [[ "$update_hotlist" -eq 1 ]]; then
    echo -e "Обновляем hotlist для Midnight Commander."
    # shellcheck disable=SC1091
    if ! source /root/rish/create_hotlist.sh; then
      echo -e "Не удалось подключить скрипт: ${RED}/root/rish/create_hotlist.sh${WHITE}"
      rollback_create_site_core "$conf_file" "$created_pool_file"
      return 1
    fi
    if ! create_hotlist; then
      echo -e "Не удалось обновить ${RED}hotlist${WHITE}."
      rollback_create_site_core "$conf_file" "$created_pool_file"
      return 1
    fi
  fi

  if [[ -n "$created_pool_file" && "$restart_php_fpm" -eq 1 ]]; then
    echo -e "Проверяем конфигурацию PHP-FPM: ${GREEN}${selected_php}${WHITE}"
    if ! "$php_fpm_bin" -t; then
      echo -e "Конфигурация PHP-FPM для ${RED}${selected_php}${WHITE} содержит ошибки."
      rollback_create_site_core "$conf_file" "$created_pool_file"
      return 1
    fi
  elif [[ -n "$created_pool_file" ]]; then
    echo -e "PHP-FPM ${YELLOW}${selected_php}-php-fpm${WHITE} не был перезапущен."
  fi

  if [[ "$reload_apache" == "ask" ]]; then
    echo -e -n "${WHITE}Перезапускаем apache для активации сайта ${GREEN}${site_name}${WHITE}? "
    # Проверяем, а не punycode ли?
    if [[ "$site_name" =~ (xn\-\-) ]]
    then
        echo -e -n " ($(idn2 -d "$site_name"))"
        echo
    else
        echo
    fi
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      reload_apache=1
    else
      reload_apache=0
    fi
  fi

  if [[ "$reload_apache" -eq 1 ]]; then
    echo -e "Проверяем конфигурацию Apache: ${GREEN}apachectl configtest${WHITE}"
    if ! apachectl configtest; then
      echo -e "Конфигурация Apache содержит ${RED}ошибки${WHITE}."
      rollback_create_site_core "$conf_file" "$created_pool_file"
      return 1
    fi
  elif [[ "$reload_apache" -eq 0 ]]; then
    echo -e "Apache ${YELLOW}не был перезагружен${WHITE}."
  else
    echo -e "Параметр reload_apache ${RED}некорректный${WHITE}: ${reload_apache}"
    return 1
  fi

  if [[ -n "$created_pool_file" && "$restart_php_fpm" -eq 1 ]]; then
    echo -e "Перезапускаем PHP-FPM: ${GREEN}${selected_php}-php-fpm${WHITE}"
    if ! systemctl restart "${selected_php}-php-fpm"; then
      echo -e "Не удалось перезапустить сервис: ${RED}${selected_php}-php-fpm${WHITE}"
      rollback_create_site_core "$conf_file" "$created_pool_file"
      return 1
    fi
  fi

  if [[ "$reload_apache" -eq 1 ]]; then
    echo -e "Перезагружаем Apache: ${GREEN}httpd${WHITE}"
    if ! systemctl reload httpd; then
      echo -e "Не удалось перезагрузить сервис: ${RED}httpd${WHITE}"
      return 1
    fi
  fi

  echo -e "Сайт ${GREEN}$(format_site_name_label "$site_name")${WHITE} создан."
  return 0
}

function create_site() {
  echo
  local path="$2"
  local php_mode
  local ret
  local username
  local decoded_name
  username=$(echo "$path" | cut -d'/' -f4)
  echo -e "Создание сайта (vhost) для пользователя ${GREEN}${username}${WHITE}"
  check_site "$1" "$2"
  ret=$?
  if ((ret == 0)); then
    echo -e -n "Создаем сайт (vhost) ${GREEN}${site_name}"
    if [[ "$site_name" =~ (xn\-\-) ]]; then
      decoded_name="$(idn2 -d "$site_name" 2>/dev/null)"
      if [[ -n "$decoded_name" && "$decoded_name" != "$site_name" ]]; then
        echo -e -n " (${decoded_name})"
      fi
    fi
    echo -e "${WHITE}"
    mapfile -t installed_versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
    echo
    echo -e "Выберите нужную версию ${GREEN}PHP${WHITE} из доступных."
    echo
    vertical_menu "current" 1 0 10 "${installed_versions[@]}"
    ret=$?
    if ((ret == 255)); then
      echo -e "Сайт (vhost) ${YELLOW}${site_name} ${RED}не был создан${WHITE}"
      return
    fi
    local selected_php=${installed_versions[${ret}]}
    echo -e "${CURSORUP}Выбрана версия ${GREEN}${selected_php}${WHITE}"
    echo -e -n "Введите имя  папки для DocumentRoot (${GREEN}Enter${WHITE}, если все стандартно):${GREEN}"
    read -r -e -p " " DocumentRoot
    echo -e "${WHITE}"

    if [[ ! -f "/etc/opt/remi/${selected_php}/php-fpm.d/${username}.conf" ]]; then
      # Если пул для этой версии PHP еще не был создан, то создаем
      echo
      echo -e "Выберите режим работы PHP для пользователя ${GREEN}${username}${WHITE}:"
      vertical_menu "current" 2 0 5 "ondemand - оптимально расходует память" "dynamic - более оперативно реагирует на запросы"
      ret=$?
      if ((ret == 0)); then
        php_mode="ondemand"
      else
        php_mode="dynamic"
      fi
    fi
    local restart_php_fpm=1
    if [[ ! -f "/etc/opt/remi/${selected_php}/php-fpm.d/${username}.conf" ]]; then
      echo -e "Перезапускаем ${GREEN}${selected_php}-php-fpm${WHITE} для активации версии ${GREEN}${selected_php}${WHITE}?"
      if ! vertical_menu "current" 2 0 5 "Да" "Нет"; then
        restart_php_fpm=0
      fi
    fi

    create_site_core "$site_name" "$path" "$selected_php" "$DocumentRoot" "$php_mode" "$restart_php_fpm" "ask" 1

  elif ((ret == 2)); then
    echo -e "Используется существующий сайт ${GREEN}${site_name}${WHITE}."
    return 2
  else
    echo -e "Создание сайта (vhost) для имени ${YELLOW}$site_name${WHITE} пропущено."
    return $ret
  fi

}
# Если идет прямой вызов - выполняем функцию. Если идет подключение через source - то ничего не делаем
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    create_site "$1" "$2"
    vertical_menu "current" 2 0 5 "Нажмите Enter"
fi
