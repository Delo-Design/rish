#!/usr/bin/env bash

RISH_HOME="/root/rish"

GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'

source "${RISH_HOME}/windows.sh"

SITE_ENTRY="${1:-}"
SITE_PARENT="${2:-}"
PMA_LANGUAGE="all-languages"
PMA_LATEST_VERSION_INFO_URL="https://www.phpmyadmin.net/home_page/version.php"
PMA_DOWNLOAD_BASE_URL="https://files.phpmyadmin.net/phpMyAdmin"
DEBUG="${DEBUG:-0}"

silent()
{
  if [[ "$DEBUG" -eq 1 ]]; then
    "$@"
  else
    "$@" &>/dev/null
  fi
}

pause_exit()
{
  local code="${1:-0}"
  vertical_menu "current" 2 0 5 "Нажмите Enter"
  exit "$code"
}

fail()
{
  echo -e "${RED}$1${WHITE}"
  echo
  pause_exit 1
}

real_path()
{
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    readlink -f "$1"
  fi
}

dir_is_empty()
{
  local target="$1"
  local first_entry

  first_entry="$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)"
  [[ -z "$first_entry" ]]
}

dir_is_pma()
{
  local target="$1"
  local version

  [[ -f "${target}/README" && -f "${target}/config.sample.inc.php" ]] || return 1

  version="$(sed -n 's/^Version \(.*\)$/\1/p' "${target}/README")"
  [[ -n "$version" ]]
}

clear_dir_contents()
{
  local target="$1"

  find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

archive_version()
{
  local archive_name
  archive_name="$(basename "$1")"
  archive_name="${archive_name#phpMyAdmin-}"
  archive_name="${archive_name%-${PMA_LANGUAGE}.tar.gz}"
  echo "$archive_name"
}

latest_local_archive()
{
  local archives=()
  local archive

  for archive in "${RISH_HOME}"/phpMyAdmin-*-"${PMA_LANGUAGE}".tar.gz; do
    [[ -f "$archive" ]] && archives+=("$archive")
  done

  if [[ "${#archives[@]}" -eq 0 ]]; then
    return 1
  fi

  printf '%s\n' "${archives[@]}" | sort -V | tail -n 1
}

download_text()
{
  local url="$1"
  local output="$2"

  wget --timeout=15 --tries=1 --connect-timeout=10 -q -O "$output" "$url"
}

download_archive()
{
  local version="$1"
  local output="$2"
  local url="${PMA_DOWNLOAD_BASE_URL}/${version}/phpMyAdmin-${version}-${PMA_LANGUAGE}.tar.gz"

  wget --timeout=30 --tries=1 --connect-timeout=10 -O "$output" "$url"
}

extract_archive()
{
  local archive="$1"
  local destination="$2"
  local top_dir

  top_dir="$(tar -tzf "$archive" | sed -n '1p' | cut -d '/' -f 1)"
  [[ -n "$top_dir" ]] || return 1

  silent tar xzf "$archive" -C "$destination"
  [[ -d "${destination}/${top_dir}" ]] || return 1

  echo "${destination}/${top_dir}"
}

configure_pma()
{
  local target_path="$1"
  local owner="$2"
  local blowfish_secret="$3"

  rm -rf "${target_path}/setup"
  mkdir -p "${target_path}/tmp" || return 1

  if [[ ! -f "${target_path}/config.inc.php" ]]; then
    cp "${target_path}/config.sample.inc.php" "${target_path}/config.inc.php" || return 1
  fi

  sed -i "s|\$cfg\['blowfish_secret'\].*;|\$cfg['blowfish_secret'] = '${blowfish_secret}';|" \
    "${target_path}/config.inc.php" || return 1

  chown -R "${owner}:${owner}" "$target_path" || return 1
}

install_to_subdir()
{
  local archive="$1"
  local target_path="$2"
  local parent_path="$3"
  local dirname="$4"
  local tmp_dir="$5"
  local extracted_path
  local backup_time

  echo -n "Проверяем архив... "
  if silent tar -tzf "$archive"; then
    echo "Done"
  else
    echo "Ошибка"
    return 1
  fi

  echo -n "Распаковываем... "
  extracted_path="$(extract_archive "$archive" "$tmp_dir")" || {
    echo "Ошибка"
    return 1
  }
  echo "Done"

  if [[ -d "$target_path" ]] && dir_is_pma "$target_path"; then
    echo "Создаем архив текущей установки... "
    backup_time="$(date +%Y-%m-%d-%H-%M-%S)"
    if silent tar -zcf "${parent_path}/${backup_time}.tar.gz" -C "$parent_path" "$dirname"; then
      echo -e "Создан файл ${YELLOW}${backup_time}.tar.gz${WHITE}"
      echo -e "Старая версия архивирована в папку: ${YELLOW}${parent_path}${WHITE}"
      echo "Если phpMyAdmin работает корректно, этот архив можно удалить."
    else
      echo "Not created"
      return 1
    fi

    rm -rf "$target_path" || return 1
  fi

  echo -n "Устанавливаем... "
  if [[ -d "$target_path" ]]; then
    cp -a "${extracted_path}/." "$target_path/" || {
      echo "Can't install!"
      return 1
    }
  else
    mv "$extracted_path" "$target_path" || {
      echo "Can't install!"
      return 1
    }
  fi

  if [[ -d "$target_path" ]]; then
    echo "Done"
  else
    echo "Can't install!"
    return 1
  fi
}

install_to_root()
{
  local archive="$1"
  local target_path="$2"
  local parent_path="$3"
  local dirname="$4"
  local tmp_dir="$5"
  local extracted_path
  local backup_time

  echo -n "Проверяем архив... "
  if silent tar -tzf "$archive"; then
    echo "Done"
  else
    echo "Ошибка"
    return 1
  fi

  echo -n "Распаковываем... "
  extracted_path="$(extract_archive "$archive" "$tmp_dir")" || {
    echo "Ошибка"
    return 1
  }
  echo "Done"

  if dir_is_pma "$target_path"; then
    echo "Старая версия phpMyAdmin найдена в корне сайта."
    echo "После создания архива содержимое папки будет очищено и заменено новой версией."
    echo "Создаем архив текущей установки... "
    backup_time="$(date +%Y-%m-%d-%H-%M-%S)"
    if silent tar -zcf "${parent_path}/${dirname}-pma-root-${backup_time}.tar.gz" -C "$parent_path" "$dirname"; then
      echo -e "Создан файл ${YELLOW}${dirname}-pma-root-${backup_time}.tar.gz${WHITE}"
      echo -e "Старая версия архивирована в папку: ${YELLOW}${parent_path}${WHITE}"
      echo "Если phpMyAdmin работает корректно, этот архив можно удалить."
    else
      echo "Not created"
      return 1
    fi

    clear_dir_contents "$target_path" || return 1
  fi

  echo -n "Устанавливаем в корень сайта... "
  if cp -a "${extracted_path}/." "$target_path/"; then
    echo "Done"
  else
    echo "Can't install!"
    return 1
  fi
}

clear

if [[ -z "$SITE_ENTRY" || -z "$SITE_PARENT" ]]; then
  fail "Не переданы параметры Midnight Commander. Запустите установку из меню MC на папке сайта."
fi

if [[ "$SITE_ENTRY" == "." || "$SITE_ENTRY" == ".." ]]; then
  fail "Курсор MC должен стоять на папке сайта, а не на '${SITE_ENTRY}'. Перейдите в /var/www/<siteuser>/... и выберите папку сайта."
fi

SITE_PARENT_PATH="$(real_path "$SITE_PARENT")" || fail "Не удалось определить родительский путь сайта."
SITE_PATH="$(real_path "${SITE_PARENT_PATH}/${SITE_ENTRY}")" || fail "Не удалось определить путь сайта."

if [[ ! -d "$SITE_PATH" ]]; then
  fail "Выбранный элемент не является папкой сайта: ${SITE_PARENT}/${SITE_ENTRY}"
fi

case "$SITE_PATH" in
  /var/www/*) ;;
  *) fail "Папка сайта должна находиться внутри /var/www: ${SITE_PATH}" ;;
esac

if [[ "$SITE_PARENT_PATH" == "/var/www" ]]; then
  fail "Выбрана папка пользователя, а не папка сайта. Перейдите внутрь /var/www/<siteuser>/... и выберите каталог сайта."
fi

SITE_OWNER="${SITE_PARENT_PATH#/var/www/}"
SITE_OWNER="${SITE_OWNER%%/www*}"
SITE_OWNER="${SITE_OWNER%%/*}"

if [[ -z "$SITE_OWNER" || "$SITE_OWNER" == "$SITE_PARENT_PATH" ]]; then
  fail "Не удалось определить пользователя сайта по пути: ${SITE_PARENT_PATH}"
fi

echo -e "${WHITE}В какую папку на сайте ставить phpMyAdmin?${WHITE}"
echo "Рекомендуется создать отдельный домен/сайт для phpMyAdmin."
echo "Если ставите в папку, используйте нестандартное имя: не pma и не phpmyadmin."
echo "Пустое имя установит phpMyAdmin прямо в корень выбранного сайта (мы не рекомендуем так делать - лучше ставить в папку)."
echo "Для отмены введите: q"
read -e -p $'\001\033[0m\002> \001\033[0;32m\002' -i "pppma" PMA_NAME
echo -e "${WHITE}"

case "${PMA_NAME,,}" in
  q|й|quit|exit)
    echo "Установка прервана"
    pause_exit 1
    ;;
esac

if [[ -z "$PMA_NAME" ]]; then
  PMA_PATH="$SITE_PATH"
  PMA_PARENT_PATH="$SITE_PATH"
  PMA_DIRNAME=""
  PMA_ROOT_INSTALL=1
else
  PMA_PATH="${SITE_PATH}/${PMA_NAME}"
  PMA_PARENT_PATH="$SITE_PATH"
  PMA_DIRNAME="$PMA_NAME"
  PMA_ROOT_INSTALL=0
fi

if [[ "$PMA_NAME" == "." || "$PMA_NAME" == ".." || "$PMA_NAME" == */* ]]; then
  fail "Имя папки phpMyAdmin должно быть пустым или простым именем без '/'."
fi

if [[ "$PMA_ROOT_INSTALL" -eq 1 ]]; then
  if ! dir_is_empty "$PMA_PATH" && ! dir_is_pma "$PMA_PATH"; then
    echo -e "${YELLOW}Корень сайта не пуст:${WHITE} ${PMA_PATH}"
    echo "Папка не похожа на установленный phpMyAdmin."
    echo "Установка в корень может перезаписать файлы сайта."
    echo "Если выбрать \"Очистить папку и продолжить\", все содержимое этой папки будет удалено."
    vertical_menu "current" 2 0 30 "Очистить папку и продолжить" "Продолжить без очистки" "Прервать установку"
    choice=$?

    case "$choice" in
      0)
        clear_dir_contents "$PMA_PATH" || fail "Не удалось очистить папку сайта."
        echo "Папка очищена."
        ;;
      1)
        echo "Продолжаем без очистки папки."
        ;;
      *)
        echo "Установка прервана"
        pause_exit 1
        ;;
    esac
    echo
  fi
elif [[ -d "$PMA_PATH" ]] && ! dir_is_empty "$PMA_PATH" && ! dir_is_pma "$PMA_PATH"; then
  echo -e "${YELLOW}Папка не пуста:${WHITE} ${PMA_PATH}"
  echo "Папка не похожа на установленный phpMyAdmin."
  echo "Установка в эту папку может перезаписать файлы."
  vertical_menu "current" 2 0 30 "Удалить папку и продолжить" "Продолжить без удаления" "Прервать установку"
  choice=$?

  case "$choice" in
    0)
      rm -rf "$PMA_PATH" || fail "Не удалось удалить папку ${PMA_PATH}."
      echo "Папка удалена."
      ;;
    1)
      echo "Продолжаем без удаления папки."
      ;;
    *)
      echo "Установка прервана"
      pause_exit 1
      ;;
  esac
  echo
fi

case "${PMA_NAME,,}" in
  pma|phpmyadmin)
    echo -e "${YELLOW}Внимание:${WHITE} имя '${PMA_NAME}' легко угадать. Лучше выбрать нестандартное имя папки."
    echo
    ;;
esac

PMA_CURRENT_VERSION=""
if [[ -f "${PMA_PATH}/README" ]]; then
  PMA_CURRENT_VERSION="$(sed -n 's/^Version \(.*\)$/\1/p' "${PMA_PATH}/README")"
fi

echo -n "Установленная версия: "
if [[ -n "$PMA_CURRENT_VERSION" ]]; then
  echo "$PMA_CURRENT_VERSION"
elif [[ -d "$PMA_PATH" && "$PMA_ROOT_INSTALL" -eq 0 ]]; then
  echo "unknown version"
else
  echo "not installed"
fi

TMP_ROOT="$(mktemp -d /tmp/rish-pma.XXXXXX)" || fail "Не удалось создать временную папку."
trap 'rm -rf "$TMP_ROOT"' EXIT

PMA_VERSION=""
PMA_ARCHIVE=""
PMA_ONLINE_ARCHIVE="${TMP_ROOT}/phpMyAdmin-online.tar.gz"
ONLINE_VERSION_FILE="${TMP_ROOT}/version.txt"

echo -n "Проверяем последнюю online-версию... "
if download_text "$PMA_LATEST_VERSION_INFO_URL" "$ONLINE_VERSION_FILE"; then
  PMA_VERSION="$(sed -n '1p' "$ONLINE_VERSION_FILE")"
  if [[ "$PMA_VERSION" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    echo -e "${GREEN}${PMA_VERSION}${WHITE}"
  else
    PMA_VERSION=""
    echo -e "${YELLOW}ответ не распознан${WHITE}"
  fi
else
  echo -e "${YELLOW}недоступно${WHITE}"
fi

if [[ -n "$PMA_VERSION" ]]; then
  echo -n "Загружаем phpMyAdmin ${PMA_VERSION}... "
  if silent download_archive "$PMA_VERSION" "$PMA_ONLINE_ARCHIVE" && [[ -f "$PMA_ONLINE_ARCHIVE" ]]; then
    PMA_ARCHIVE="$PMA_ONLINE_ARCHIVE"
    echo "Done"
  else
    echo -e "${YELLOW}не удалось${WHITE}"
  fi
fi

if [[ -z "$PMA_ARCHIVE" ]]; then
  PMA_ARCHIVE="$(latest_local_archive)" || fail "Online-загрузка недоступна, локальный архив phpMyAdmin в ${RISH_HOME} не найден."
  PMA_VERSION="$(archive_version "$PMA_ARCHIVE")"
  echo -e "Используем локальный архив: ${YELLOW}$(basename "$PMA_ARCHIVE")${WHITE}"
fi

echo -e "Версия, доступная к установке: ${GREEN}${PMA_VERSION}${WHITE}"

if dir_is_pma "$PMA_PATH"; then
  if [[ "$PMA_ROOT_INSTALL" -eq 1 ]]; then
    echo "В корне сайта найдена установленная версия phpMyAdmin."
  else
    echo "В выбранной папке найдена установленная версия phpMyAdmin."
  fi
  echo "Старая версия будет архивирована перед установкой новой."
fi

echo -e "Ставим phpMyAdmin по адресу ${GREEN}${SITE_ENTRY}${PMA_NAME:+/${PMA_NAME}}${WHITE}?"

if [[ "$PMA_ROOT_INSTALL" -eq 1 ]] && ! dir_is_empty "$PMA_PATH" && ! dir_is_pma "$PMA_PATH"; then
  echo -e "${YELLOW}Внимание:${WHITE} установка в корень сайта может перезаписать одноименные файлы."
fi

if ! vertical_menu "current" 2 0 5 "Да" "Нет"; then
  echo "Установка прервана"
  pause_exit 1
fi

BLOWFISH_SECRET="$(tr -dc 'A-Za-z0-9' < /dev/urandom | dd bs=1 count=32 2>/dev/null)"
EXTRACT_DIR="${TMP_ROOT}/extract"
mkdir -p "$EXTRACT_DIR" || fail "Не удалось создать временную папку распаковки."

if [[ "$PMA_ROOT_INSTALL" -eq 1 ]]; then
  install_to_root "$PMA_ARCHIVE" "$PMA_PATH" "$SITE_PARENT_PATH" "$SITE_ENTRY" "$EXTRACT_DIR" || fail "Установка phpMyAdmin в корень сайта не выполнена."
else
  install_to_subdir "$PMA_ARCHIVE" "$PMA_PATH" "$PMA_PARENT_PATH" "$PMA_DIRNAME" "$EXTRACT_DIR" || fail "Установка phpMyAdmin не выполнена."
fi

echo -n "Настраиваем... "
if configure_pma "$PMA_PATH" "$SITE_OWNER" "$BLOWFISH_SECRET"; then
  echo "Done"
else
  echo "Ошибка"
  fail "Не удалось настроить phpMyAdmin."
fi

echo "Установка завершена"
pause_exit 0
