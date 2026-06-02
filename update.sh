#!/usr/bin/env bash

RISH_HOME="/root/rish"
UPDATE_TMP_DIR="/tmp/rish-update.$$"
UPDATE_HELPER="${UPDATE_TMP_DIR}/update.sh"

if [[ "${RISH_UPDATE_HELPER:-0}" != "1" ]]; then
  mkdir -p "${UPDATE_TMP_DIR}" || exit 1
  chmod 700 "${UPDATE_TMP_DIR}" || exit 1
  cp "$0" "${UPDATE_HELPER}" || exit 1
  chmod 700 "${UPDATE_HELPER}" || exit 1

  RISH_UPDATE_HELPER=1 exec bash "${UPDATE_HELPER}" "$@"
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
RISH_SETTINGS_NEED_FIX=0

source "${RISH_HOME}/windows.sh"
source "${RISH_HOME}/php_helpers.sh"
cd /root || exit 1
clear
source "${RISH_HOME}/rish_config.sh"
LocalServer="${LocalServer:-false}"

PrintPackageUpdates() {
  local update_line
  local package_name
  local package_version
  local package_repo
  local version_main
  local version_suffix

  for update_line in "$@"; do
    read -r package_name package_version package_repo <<< "$update_line"
    version_main="$package_version"
    version_suffix=""
    if [[ "$package_version" == *.el* ]]; then
      version_main="${package_version%%.el*}"
      version_suffix="${package_version#"$version_main"}"
    fi
    printf '  %s %b%s%b%s %s\n' "$package_name" "$GREEN" "$version_main" "$WHITE" "$version_suffix" "$package_repo"
  done
}

CheckPackageUpdates() {
  local title="$1"
  shift
  local -a packages=("$@")
  local -a updates=()
  local check_output
  local check_output_file
  local status

  if [[ "${#packages[@]}" -eq 0 ]]; then
    echo -e "${YELLOW}Не найдены установленные пакеты для проверки: ${title}.${WHITE}"
    return 0
  fi

  echo
  echo -e "${GREEN}${title}${WHITE}"
  echo "Проверяем доступные обновления..."

  check_output_file="${UPDATE_TMP_DIR}/check-update.$$"
  dnf check-update "${packages[@]}" 2>&1 \
    | tee "$check_output_file" \
    | awk 'NF == 0 || ! /^[[:alnum:]_.:+-]+\.[[:alnum:]_]+[[:space:]]/ {print}'
  status=${PIPESTATUS[0]}
  check_output="$(cat "$check_output_file")"
  rm -f "$check_output_file"
  mapfile -t updates < <(printf '%s\n' "$check_output" | awk '/^[[:alnum:]_.:+-]+\.[[:alnum:]_]+[[:space:]]/ {print $1 " " $2 " " $3}')

  if [[ "$status" -eq 0 ]]; then
    echo "Обновлений нет."
    return 0
  fi

  if [[ "$status" -ne 100 ]]; then
    echo -e "${RED}Не удалось проверить обновления.${WHITE}"
    return 1
  fi

  if [[ "${#updates[@]}" -eq 0 ]]; then
    echo "Обновлений нет."
    return 0
  fi

  echo
  echo "Доступны обновления:"
  PrintPackageUpdates "${updates[@]}"
  echo
  echo "Установить найденные обновления?"
  vertical_menu "current" 2 0 5 "Да" "Нет"
  if [[ "$?" -ne 0 ]]; then
    echo "Обновление отменено."
    return 0
  fi

  echo
  echo "Устанавливаем обновления..."
  if dnf update -y "${packages[@]}"; then
    echo
    echo -e "${GREEN}Обновление завершено.${WHITE}"
    echo "Запускаем проверку и восстановление настроек RISH."
    bash "${RISH_HOME}/rish_check.sh" fix
  else
    echo -e "${RED}Обновление завершилось с ошибкой.${WHITE}"
    return 1
  fi
}

CheckPhpUpdates() {
  local -a packages
  local php_version

  while IFS= read -r php_version; do
    packages+=("${php_version}-*")
  done < <(get_installed_php_versions)
  CheckPackageUpdates "Проверка обновлений PHP" "${packages[@]}"
}

CheckApacheUpdates() {
  CheckPackageUpdates "Проверка обновлений Apache" "httpd*" "mod_ssl"
}

version_gt() {
  test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

Update() {
  # Извлекаем файл версии из архива
  if tar -xzf "rish2.tar.gz" --strip-components=1 "rish/version"
  then
    # Если файл версии не существует в папке rish, то устанавливаем версию 0.0.0
    if [ ! -f "/root/rish/version" ]; then
      echo "Ваша версия RISH не известна."
      folder_version="0.0.0"
    else
      folder_version=$(cat "/root/rish/version")
      echo -e "Ваша версия RISH ${GREEN}${folder_version}${WHITE}"
    fi
    archive_version=$(cat "/root/version")
    rm -f "/root/version" > /dev/null
    update_label="Установить RISH ${archive_version}"
    def="default=0"
    if version_gt "${archive_version}" "${folder_version}"; then
      echo -e "Доступна более новая версия RISH для обновления – ${GREEN}${archive_version}${WHITE}"
      echo "Рекомендуем обновиться до этой версии."
      echo
    else
      echo -e "Ваша версия RISH ${GREEN}актуальна${WHITE} - обновление не требуется."
      echo "Но если нужно - вы можете переустановить RISH."
      echo
      update_label="Переустановить RISH ${archive_version}"
      def="default=4"
    fi
    if [[ "$RISH_SETTINGS_NEED_FIX" -eq 1 ]]; then
      def="default=1"
    fi
    vertical_menu "current" 2 0 50 ${def} "${update_label}" "Проверка и восстановление настроек RISH" "Проверка обновлений PHP" "Проверка обновлений Apache" "Выйти"
    choice=$?
    case "$choice" in
      0)
        #обновляем версию RISH
        if tar -tzf rish2.tar.gz > /dev/null 2>&1
        then
          echo "${folder_version}" > /root/rish/version_previous
          echo "Распаковываем файлы RISH..."
          if tar --no-same-owner -xf rish2.tar.gz; then
            echo -e "Файлы RISH ${GREEN}обновлены${WHITE}."
          else
            echo -e "${RED}Не удалось${WHITE} распаковать архив RISH."
            vertical_menu "current" 2 0 5 "Нажмите Enter"
            exit 1
          fi
          cd /root/rish || exit 1
          rm /etc/mc/mc.menu
          cp templates/mc.menu /etc/mc/mc.menu
          if ${LocalServer}; then
            cat templates/mc.menu.local >> /etc/mc/mc.menu
          fi
          chmod u+x ri.sh
          chmod u+x update.sh
          chmod u+x clonesite.sh
          chmod u+x backup2.sh
          chmod u+x rish_check.sh
          echo
          bash postupdate.sh
        else
          echo "Скачанный архив поврежден"
          vertical_menu "current" 2 0 5 "Нажмите Enter"
          exit 1
        fi
        ;;
      1)
        bash "${RISH_HOME}/rish_check.sh" fix
        ;;
      2)
        CheckPhpUpdates
        ;;
      3)
        CheckApacheUpdates
        ;;
      *)
        echo "RISH не был обновлен"
        ;;
    esac
  else
    echo "Внутри архива отсутствует файл версии. Что-то пошло не так."
    echo "Обновление невозможно."
    echo
    vertical_menu "current" 2 0 5 "Нажмите Enter"
    exit 1
  fi
}

echo "Проверяем настройки RISH..."
bash "${RISH_HOME}/rish_check.sh" silent
rish_check_status=$?

case "$rish_check_status" in
  0)
    ;;
  1)
    RISH_SETTINGS_NEED_FIX=1
    echo
    echo -e "${YELLOW}Требуется проверка и восстановление настроек RISH${WHITE}"
    echo
    ;;
  2)
    echo
    echo -e "${RED}Проверка настроек RISH завершилась с ошибкой:${WHITE}"
    bash "${RISH_HOME}/rish_check.sh"
    echo
    ;;
esac

echo "Проверяем обновление..."
if [[ -f /root/rish2.tar.gz ]]; then
  echo
  echo -e "Найден архив ${YELLOW}rish2.tar.gz${WHITE} в папке /root"
  echo "Проверка в интернете не выполняется."
  echo "Если хотите обновиться через интернет – удалите файл вручную."
  echo
  Update
else
  echo "Скачиваем архив RISH с rish.su..."
  if curl -L --connect-timeout 15 --max-time 60 --fail --progress-bar -o rish2.tar.gz https://rish.su/rish2.tar.gz
  then
    echo "Архив RISH скачан."
    Update
  else
    echo "rish.su недоступен, пробуем скачать релиз с GitHub..."
    release_url="$(curl -fsSL --connect-timeout 15 --max-time 30 https://api.github.com/repos/Delo-Design/rish/releases/latest | awk -F \" -v RS="," '/browser_download_url/ {print $(NF-1)}' | head -n 1)"
    if [[ -n "$release_url" ]] && curl -L --connect-timeout 15 --max-time 60 --fail --progress-bar -o rish2.tar.gz "$release_url"
    then
      echo "Архив RISH скачан с GitHub."
      Update
    else
      echo "Не удалось скачать архив"
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      exit 1
    fi
  fi
fi
rm -f /root/rish2.tar.gz > /dev/null
rm -rf "${UPDATE_TMP_DIR}"
vertical_menu "current" 2 0 5 "Нажмите Enter"
