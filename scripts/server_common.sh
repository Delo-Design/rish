#!/usr/bin/env bash

# Shared split-screen UI and package installation helpers. Sourcing does not open the UI.
# shellcheck disable=SC2154

rish_initialize_split_screen() {
  local size

  if ! size="$(stty size)"; then
    echo "Не удалось определить размер терминала." >&2
    return 1
  fi
  lines=${size% *}
  columns=${size#* }
  if [[ ! "$lines" =~ ^[0-9]+$ || ! "$columns" =~ ^[0-9]+$ ]] ||
    ((lines < 6 || columns < 1)); then
    echo "Не удалось определить размер терминала." >&2
    return 1
  fi
  upperY=1
  downY=$((lines / 2))
  rim=$((downY - 2))
  whereCursorIs="down"
}

Up() {
  if [[ ${whereCursorIs} == "down" ]]
  then
    downY=$( get_cursor_row )
    whereCursorIs="up"
    # ограничить скрол верхней части экрана
    echo -e ${ESC}"[1;${rim}r"
    cursor_to ${upperY} 1
  fi
}

Down() {
  if [[ ${whereCursorIs} == "up" ]]
  then
    upperY=$( get_cursor_row )
    echo -e ${ESC}"[$(( ${rim}+2));${lines}r"
    # Ограничить скрол нижней частью экрана
    cursor_to ${downY} 1
    whereCursorIs="down"
  fi
}

RemoveRim() {
  echo -e ${ESC}"[;r"
  cursor_to $(( ${rim} +1 )) 1
  echo -en ${ESC}"[0J"
}

rish_draw_split_screen() {
  clear
  cursor_to $((rim + 1)) 1
  repl "─" "$columns"
  cursor_to $((rim + 2)) 1
  Up
}

Install() {
    local ensure_latest=0
    local optional=0

    while [[ "${1:-}" == "--ensure-latest" || "${1:-}" == "--optional" ]]; do
        case "$1" in
            --ensure-latest) ensure_latest=1 ;;
            --optional) optional=1 ;;
        esac
        shift
    done

    if ((ensure_latest == 1)) || ! rpm -q "$@" >/dev/null 2>&1; then
        Up
        if ((ensure_latest == 1)); then
            echo -e "Устанавливаем или обновляем ${GREEN}${*}${WHITE}"
        else
            echo -e "Ставим ${GREEN}${*}${WHITE}"
        fi
        Down
        if yum -y install "$@"; then
            (( upperY -- ))
            Up
            echo -e "${GREEN}${*}${WHITE} установлен"
        else
            Up
            echo -e "Установить ${RED}${*}${WHITE} не удалось, очищаем кэш и пытаемся снова"
            Down
            yum clean all
            yum makecache
            if yum -y install "$@"; then
                Up
                echo -e "${GREEN}${*}${WHITE} установлен после очистки кэша"
            else
                Up
                echo -e "Установить ${RED}${*}${WHITE} не удалось даже после очистки кэша"
                if ((optional)); then
                    Down
                    return 1
                fi
                RemoveRim
                exit 1
            fi
        fi
        echo
    else
        Up
        echo -e "${GREEN}${*}${WHITE} уже установлен"
    fi
    Down
}
