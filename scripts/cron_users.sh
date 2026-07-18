#!/usr/bin/env bash

source /root/rish/windows.sh
source /root/rish/scripts/cron_access.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
ROOT_COLOR='\033[1;36m'

function cron_users() {
  while true; do
    clear
    echo -e "${WHITE}CRON для пользователей (/home/*) и root:${WHITE}"
    if cron_allow_is_secure; then
      echo -e "Управление crontab разрешено только пользователю ${ROOT_COLOR}root${WHITE}."
    else
      echo -e "${RED}Внимание:${WHITE} /etc/cron.allow не соответствует безопасной конфигурации RISH."
    fi
    echo

    local users=("root")
    local home_users=()
    local user
    local size
    local columns
    local pad_total
    local cron_content
    local cron_filtered
    local read_errors=0

    if [ -d /home ]; then
      for d in /home/*; do
        [ -d "$d" ] || continue
        home_users+=("$(basename "$d")")
      done
      if [ "${#home_users[@]}" -gt 0 ]; then
        mapfile -t home_users < <(printf '%s\n' "${home_users[@]}" | sort)
      fi
      users+=("${home_users[@]}")
    fi

    local any_jobs=0
    for user in "${users[@]}"; do
      if [ -n "$user" ] && (id "$user" >/dev/null 2>&1); then
        if cron_content="$(LC_ALL=C crontab -l -u "$user" 2>&1)"; then
          :
        elif [[ "$cron_content" == "no crontab for ${user}" ]]; then
          cron_content=""
        else
          read_errors=1
          echo -e "Не удалось прочитать CRON пользователя ${YELLOW}${user}${WHITE}:"
          printf '  %s\n\n' "$cron_content"
          continue
        fi
        cron_filtered="$(printf '%s\n' "$cron_content" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d')"
        if [[ -n "$cron_filtered" ]]; then
          any_jobs=1
          size=$(stty size 2>/dev/null)
          columns=${size#* }
          if [ -z "$columns" ] || [ "$columns" -lt 20 ]; then
            columns=80
          fi
          local line_width=$((columns - 1))
          if [ "$line_width" -lt 20 ]; then
            line_width=80
          fi

          local header_len=$(( ${#user} + 3 ))
          pad_total=$((line_width - header_len))
          if [ "$pad_total" -lt 0 ]; then
            pad_total=0
          fi
          local name_color="${YELLOW}"
          if [[ "$user" == "root" ]]; then
            name_color="${ROOT_COLOR}"
          fi
          printf "─ %b%s%b %s\n" \
            "${name_color}" "${user}" "${WHITE}" \
            "$(printf '─%.0s' $(seq 1 $pad_total))"

          printf '%s\n' "$cron_content"

          printf "%s\n\n" "$(printf '─%.0s' $(seq 1 $line_width))"
        fi
      fi
    done

    if [ "$any_jobs" -eq 0 ]; then
      if [[ "$read_errors" -eq 0 ]]; then
        echo -e "Не создано ни одного ${YELLOW}cron-задания${WHITE} у root и пользователей из /home."
        echo
      fi
    fi

    if [[ "$read_errors" -eq 1 ]]; then
      echo -e "${YELLOW}Список CRON может быть неполным из-за ошибок чтения.${WHITE}"
      echo
    fi

    echo -e "${WHITE}Выберите действие:${WHITE}"
    local menu_items=("Выход" "Вывести все cron-задания всех пользователей")
    for user in "${users[@]}"; do
      if [ -n "$user" ] && (id "$user" >/dev/null 2>&1); then
        menu_items+=("Создать/отредактировать CRON для ${user}")
      fi
    done
    vertical_menu "current" 2 0 5 "${menu_items[@]}"
    local choice=$?
    if ((choice == 255)) || ((choice == 0)); then
      break
    fi
    if ((choice == 1)); then
      continue
    fi

    local idx=$((choice - 2))
    local target_user="${users[$idx]}"
    if [ -n "$target_user" ]; then
      clear
      echo -e "${WHITE}Сейчас откроется редактор crontab для пользователя ${YELLOW}${target_user}${WHITE}."
      echo
      echo "Каждая задача — это отдельная строка."
      echo "Важно: каждая строка должна заканчиваться Enter,"
      echo "и последняя строка тоже должна оканчиваться переводом строки."
      echo
      echo "Схема полей (пример из crontab):"
      echo ""
      echo "# ┌──────── минуты (0 - 59)"
      echo "# │ ┌────── часы (0 - 23)"
      echo "# │ │ ┌──── день месяца (1 - 31)"
      echo "# │ │ │ ┌── месяц (1 - 12) или jan,feb,mar,apr ..."
      echo "# │ │ │ │ ┌ день недели (0 - 6) (Sunday=0 или 7) или sun,mon,tue,wed,thu,fri,sat"
      echo "# │ │ │ │ │"
      echo "# * * * * * команда для исполнения"
      echo
      echo "Звездочка (*) означает «каждое значение» этого поля"
      echo "(например, в минутах — каждую минуту, в часах — каждый час)."
      echo
      echo "Пример (вызывает скрипт php в 3:05 ночи каждый день):"
      echo "5 3 * * * /bin/php82 /var/www/siteuser/www/rish.su/cli/joomla.php radicalsitemap:scan --live-site=https://rish.su/"
      echo
      echo "Если вы не справитесь самостоятельно, то вот понятный генератор cron в интернете:"
      echo "https://crontab-generator.org/"
      echo
      vertical_menu "current" 2 0 5 "Открыть редактор crontab для ${target_user}" "Выйти"
      local edit_choice=$?
      if ((edit_choice == 0)); then
        clear
        crontab -e -u "$target_user"
      fi
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cron_users
fi
