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

source "${RISH_HOME}/windows.sh"
cd /root || exit 1
if [[ -t 0 && -t 1 ]]; then
  clear -x
fi

version_gt() {
  test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

PrintVersionLine() {
  local label="$1" version="$2" missing_label="$3"
  local hint="${4:-}" hint_color="${5:-}"
  local color="$GREEN"

  if [[ -z "$version" ]]; then
    version="$missing_label"
    color="$YELLOW"
  fi
  printf '  %-8s  %b%s%b' "$label" "$color" "$version" "$WHITE"
  if [[ -n "$hint" ]]; then
    printf ' · %b%s%b' "$hint_color" "$hint" "$WHITE"
  fi
  printf '\n'
}

PrintInstalledVersions() {
  local packages package version
  local php_version_list="" apache_version="" mariadb_version=""
  local -a php_versions=()

  if ! packages=$(rpm -qa --qf '%{NAME} %{VERSION}\n' 2>/dev/null); then
    printf '  %bНе удалось прочитать%b установленные версии пакетов.\n' "$YELLOW" "$WHITE"
    return
  fi

  while read -r package version; do
    case "$package" in
      php[0-9][0-9]-php-fpm|php-fpm) php_versions+=("$version") ;;
      httpd) apache_version="$version" ;;
      MariaDB-server|mariadb-server) mariadb_version="$version" ;;
    esac
  done <<< "$packages"

  if ((${#php_versions[@]} > 0)); then
    php_version_list=$(printf '%s\n' "${php_versions[@]}" | sort -Vu)
    php_version_list=${php_version_list//$'\n'/, }
  fi

  PrintVersionLine 'PHP-FPM' "$php_version_list" 'не установлен'
  PrintVersionLine 'Apache' "$apache_version" 'не установлен'
  PrintVersionLine 'MariaDB' "$mariadb_version" 'не установлена'
}

PrintSettingsWarning() {
  case "$1" in
    0) ;;
    1)
      printf '  Требуется %bпроверка и восстановление%b настроек RISH.\n' "$YELLOW" "$WHITE"
      ;;
    *)
      printf '  Проверка настроек RISH завершилась с %bошибкой%b.\n' "$RED" "$WHITE"
      ;;
  esac
}

Update() {
  local archive_source="${1:-}"
  local archive_version folder_version installed_version update_label def choice action_status
  local version_hint="" version_hint_color="$YELLOW"
  local settings_status="$rish_check_status" preserve_check_output=0

  if archive_version=$(tar -xOzf rish2.tar.gz rish/version) && [[ -n "$archive_version" ]]; then
    installed_version=$(cat "${RISH_HOME}/version" 2>/dev/null)
    folder_version="${installed_version:-0.0.0}"
    update_label="Установить RISH ${archive_version}"
    def="default=5"
    if version_gt "${archive_version}" "${folder_version}"; then
      def="default=0"
      version_hint="доступна ${archive_version}"
    elif [[ "$archive_version" == "$folder_version" ]]; then
      update_label="Переустановить RISH ${archive_version}"
      version_hint="актуальна"
      version_hint_color="$GREEN"
    else
      version_hint="в архиве ${archive_version}"
    fi

    if [[ "$archive_source" == local ]]; then
      version_hint=""
    fi
    if [[ "$settings_status" -eq 1 ]]; then
      def="default=1"
    elif [[ "$settings_status" -ne 0 ]]; then
      preserve_check_output=1
    fi

    while true; do
      # Без терминала меню может принять конец ввода за Enter.
      [[ -t 0 && -t 1 ]] || exit 1
      if [[ "$preserve_check_output" -eq 0 ]]; then
        clear -x
      fi
      preserve_check_output=0

      PrintVersionLine 'RISH' "$installed_version" 'неизвестна' "$version_hint" "$version_hint_color"
      PrintVersionLine 'Kernel' "$(uname -r 2>/dev/null)" 'не удалось определить'
      PrintInstalledVersions
      if [[ "$archive_source" == local ]]; then
        printf '\n  Для обновления RISH использует архив %b/root/rish2.tar.gz%b.\n' "$YELLOW" "$WHITE"
        printf '  При выходе архив удалится. Для онлайн-проверки откройте меню снова.\n'
      fi
      PrintSettingsWarning "$settings_status"
      echo

      vertical_menu "current" 2 0 50 "${def}" "${update_label}" "Проверка и восстановление настроек RISH" "Проверка обновлений PHP" "Проверка обновлений Apache" "Проверка обновлений MariaDB" "Выйти"
      choice=$?
      [[ -t 0 && -t 1 ]] || exit 1

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
            chmod u+x ri.sh
            chmod u+x update.sh
            chmod u+x backup2.sh
            chmod u+x rish_check.sh
            echo
            if ! bash postupdate.sh; then
              echo
              echo -e "${RED}Обновление RISH завершилось с ошибкой.${WHITE}"
              echo "Исправьте указанную выше причину и повторите обновление."
              exit 1
            fi
          else
            echo "Скачанный архив поврежден"
            vertical_menu "current" 2 0 5 "Нажмите Enter"
            exit 1
          fi
          break
          ;;
        1)
          bash "${RISH_HOME}/rish_check.sh" fix
          ;;
        2)
          bash "${RISH_HOME}/scripts/package_updates.sh" php
          ;;
        3)
          bash "${RISH_HOME}/scripts/package_updates.sh" apache
          ;;
        4)
          bash "${RISH_HOME}/scripts/package_updates.sh" mariadb
          ;;
        *)
          echo "RISH не был обновлен"
          break
          ;;
      esac
      action_status=$?
      case "$action_status" in
        129|130|143)
          exit "$action_status"
          ;;
      esac
      if [[ "$choice" -eq 1 ]]; then
        settings_status="$action_status"
      fi
      def="default=$choice"
      echo
      [[ -t 0 && -t 1 ]] || exit 1
      vertical_menu "current" 2 0 5 nomouse "Вернуться к сводке"
    done
  else
    echo "Не удалось прочитать версию RISH из архива."
    echo "Обновление невозможно."
    echo
    vertical_menu "current" 2 0 5 "Нажмите Enter"
    exit 1
  fi
}

echo "Проверяем настройки RISH..."
bash "${RISH_HOME}/rish_check.sh" silent
rish_check_status=$?

if [[ "$rish_check_status" -ne 0 ]]; then
  echo
  PrintSettingsWarning "$rish_check_status"
  if [[ "$rish_check_status" -eq 2 ]]; then
    bash "${RISH_HOME}/rish_check.sh"
  fi
  echo
fi

echo "Проверяем обновление..."
if [[ -f /root/rish2.tar.gz ]]; then
  echo
  echo -e "Найден архив ${YELLOW}rish2.tar.gz${WHITE} в папке /root"
  echo
  Update local
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
vertical_menu "current" 2 0 5 nomouse "Нажмите Enter"
