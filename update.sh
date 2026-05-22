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
cd /root || exit 1
clear
source "${RISH_HOME}/rish_config.sh"

CheckRishSettingsNotice() {
  local rish_check_status

  [[ -f "${RISH_HOME}/rish_check.sh" ]] || return 0

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
}

RunRishSettingsFix() {
  if [[ -f "${RISH_HOME}/rish_check.sh" ]]; then
    bash "${RISH_HOME}/rish_check.sh" fix
  else
    echo -e "${YELLOW}Скрипт ${RISH_HOME}/rish_check.sh не найден.${WHITE}"
  fi
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
      def="default=2"
    fi
    if [[ "$RISH_SETTINGS_NEED_FIX" -eq 1 ]]; then
      def="default=1"
    fi
    vertical_menu "current" 2 0 50 ${def} "${update_label}" "Проверка и восстановление настроек RISH" "Выйти"
    choice=$?
    case "$choice" in
      0)
        #обновляем версию RISH
        if tar -tzf rish2.tar.gz > /dev/null 2>&1
        then
          echo "${folder_version}" > /root/rish/version_previous
          tar --no-same-owner -xvf rish2.tar.gz
          cd /root/rish || exit 1
          rm /etc/mc/mc.menu
          cp mc.menu /etc/mc/mc.menu
          if ${LocalServer}; then
            cat mc.menu.local >> /etc/mc/mc.menu
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
        RunRishSettingsFix
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

CheckRishSettingsNotice
echo "Проверяем обновление..."
if [[ -f /root/rish2.tar.gz ]]; then
  echo
  echo -e "Найден архив ${YELLOW}rish2.tar.gz${WHITE} в папке /root"
  echo "Проверка в интернете не выполняется."
  echo "Если хотите обновиться через интернет – удалите файл вручную."
  echo
  Update
else
  if wget --timeout=15 --tries=1 https://rish.su/rish2.tar.gz > /dev/null 2>&1
  then
    Update
  else
    if wget https://api.github.com/repos/Delo-Design/rish/releases/latest -O - | awk -F \" -v RS="," '/browser_download_url/ {print $(NF-1)}' | xargs wget > /dev/null 2>&1
    then
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
