#!/usr/bin/env bash
#set -euo pipefail
#IFS=$'\n\t'

# little helpers for terminal print control and key input
ESC=$( printf "\033")
cursor_blink_on()     { printf "%s" "${ESC}[?25h"; }
cursor_blink_off()    { printf "%s" "${ESC}[?25l"; }

# Метаданные последнего отрисованного меню (обновляются в vertical_menu)
VERTICAL_MENU_LAST_WIDTH=0
VERTICAL_MENU_LAST_OUTER_WIDTH=0
VERTICAL_MENU_LAST_HEIGHT=0
VERTICAL_MENU_LAST_X=0
VERTICAL_MENU_LAST_Y=0
VERTICAL_MENU_LAST_RIGHT_X=0

vertical_menu_next_x() {
  local gap="${1:-1}"
  echo $((VERTICAL_MENU_LAST_RIGHT_X + gap + 1))
}

cursor_to() {
  local row="$1"
  local col="${2:-1}"
  printf "%s" "${ESC}[${row};${col}H"
}

print_option()        { printf "%s " "$1"; }
print_selected_on()   { printf "%s" "${ESC}[7m"; }
print_selected_off()  { printf "%s" "${ESC}[27m"; }

clear_input_buffer() {
  # Удаляем мусор из stdin
  local dummy
  while IFS= read -rsn1 -t 0.01 dummy 2>/dev/null; do :; done
}

drain_input_tail() {
  # Слить хвост неизвестной escape-последовательности, чтобы он не "протек" в UI.
  local dummy
  while IFS= read -rsn1 -t 0.001 dummy 2>/dev/null; do :; done
}

get_cursor_row() {
    local row col
    IFS=';' read -sdR -p $'\E[6n' row col
    row=${row#*[}
    [[ "$row" =~ ^[0-9]+$ ]] && echo "$row" || echo 1
}

get_cursor_column() {
    local row col
    IFS=';' read -sdR -p $'\E[6n' row col
    [[ "$col" =~ ^[0-9]+$ ]] && echo "$col" || echo 1
}
repl() { printf '%.0s'"$1" $(seq 1 "$2"); }
key_input() {
    local key=""
    local c1=""
    local c2=""
    local esc=$'\e'

    IFS= read -rsn1 key 2>/dev/null || true

    if [[ "$key" == "$esc" ]]; then
        # Одиночный ESC: продолжения нет.
        if ! IFS= read -rsn1 -t 0.008 c1 2>/dev/null; then
            echo "esc"
            return
        fi

        # Поддерживаем только стрелки вверх/вниз.
        if [[ "$c1" == "[" || "$c1" == "O" ]]; then
            if IFS= read -rsn1 -t 0.008 c2 2>/dev/null; then
                case "$c2" in
                    A) echo "up"; return ;;
                    B) echo "down"; return ;;
                esac
            fi
        fi

        # Неизвестный ESC-ввод: сливаем хвост, чтобы избежать артефактов.
        drain_input_tail
        echo "other:${esc}${c1}${c2}"
        return
    fi

    if [[ -z "$key" ]]; then
        echo "enter"
    else
        echo "other:$key"
    fi
}



function refresh_window {
# формат вызова
# refresh_window y x height width shift "@"

	local MaxWindowWidth
	local left_x
	local top_y
	local ReturnKey=""
	local temp
	local -a ms
	local -a menu_items
	local height
	local i=0
	local shift_y
	ms=( "$@" )
	left_x=${ms[1]}
	top_y=${ms[0]}
	MaxWindowWidth=${ms[3]}
	menu_items=( "${ms[@]:5}" )
	height=${ms[2]}
	shift_y=${ms[4]}

	cursor_to $(($top_y )) $(($left_x))
	printf "┌"
	repl "─" $(( $MaxWindowWidth + 3 ))
	printf "┐"

	for ((i=0;i<${height};i++))
	do
		cursor_to $(($top_y + ${i}  + 1)) $(($left_x))
		print_option "│  ${menu_items[${i}+${shift_y}]}"
		repl " " $(( ${MaxWindowWidth}-${#menu_items[${i}+${shift_y}]} ))
		printf "│"
	done

	cursor_to $(($top_y + ${i} +1 )) $(($left_x))
	printf "└"
	repl "─" $(( $MaxWindowWidth + 3 ))
	printf "┘"
}

function vertical_menu {
  # формат вызова
  # vertical_menu y x height width "@"
  # если x = center - то центрирование по горизонтали
  # если y = 	center - то центрирование по вертикали
  # 		 =	current - выводим меню в текущей строке
  # 		 =	current_noclear - выводим меню в текущей строке без очистки после выбора,
  #                курсор ставится под меню
  # если height = 0 - не устанавливать высоты (она будет посчитана автоматически)
  #			  = число - установить высоту окна равную числу. Пункты меню будут скролироваться
  #	width = число. Если строка будет больше этого числа - то ширина будет расширена до него
  # если среди пунктов меню встречается слово default со знаком =, то это значит установка пункта меню по умолчанию
  # этот пункт меню будет выбранным при выводе меню
  # vertical_menu y x height width  "default=2" "First Item" "Second Item" "Third Item"
  local MaxWindowWidth
  local left_x
  local top_y
  local ReturnKey=""
  local -a ms
  local -a menu_items
  local size
  local lines
  local columns
  local current_y
  local is_current_mode=0
  local skip_lines=0
  local required_bottom
  local scroll_lines=0
  local max_visible_height
  local stty_state=""
  local height
  local shift_y=0
  local el
  local arg
  size=$(stty size)
  lines=${size% *}
  columns=${size#* }

  # Обработка и удаление аргумента default, если он присутствует
  local default_selected_index=0
  local new_menu_items=()
  for arg in "$@"; do
    if [[ $arg == default=* ]]; then
      default_selected_index=${arg#default=}
    else
      new_menu_items+=("$arg")
    fi
  done

  ms=("${new_menu_items[@]:0:4}")
  menu_items=("${new_menu_items[@]:4}")
  left_x=${ms[1]}
  top_y=${ms[0]}
  MaxWindowWidth=${ms[3]}
  clear_input_buffer
  current_y=$(get_cursor_row)

  if ((${ms[2]} == 0)); then
    height=${#menu_items[@]}
  else
    # если требуемая высота больше чем количество пунктов меню, уменьшаем ее
    if ((${ms[2]} > ${#menu_items[@]})); then
      height=${#menu_items[@]}
    else
      height=${ms[2]}
    fi
  fi

  max_visible_height=$((lines - 2))
  if ((max_visible_height < 1)); then
    max_visible_height=1
  fi
  if ((height > max_visible_height)); then
    height=$max_visible_height
  fi

  #find the width of the window
  for el in "${menu_items[@]}"; do
    if ((${MaxWindowWidth} < ${#el})); then
      MaxWindowWidth=${#el}
    fi
  done
  ((MaxWindowWidth = ${MaxWindowWidth} + 2))

  if [[ ${ms[1]} == "center" ]]; then
    ((left_x = (${columns} - ${MaxWindowWidth} - 6) / 2))
  fi
  if [[ ${ms[0]} == "center" ]]; then
    ((top_y = (${lines} - ${height} - 2) / 2))
  fi

  if [[ ${ms[0]} == "current" || ${ms[0]} == "current_noclear" ]]; then
    is_current_mode=1
    top_y=${current_y}
  fi

  # Для любого режима обеспечиваем место под меню за счет скролла терминала.
  required_bottom=$((top_y + height + 1))
  if ((required_bottom > lines)); then
    scroll_lines=$((required_bottom - lines))
    if ((scroll_lines > 0)); then
      echo -en ${ESC}"[${scroll_lines}S"
      top_y=$((top_y - scroll_lines))
      if ((is_current_mode == 1)); then
        current_y=$top_y
        skip_lines=$((skip_lines + scroll_lines))
      fi
    fi
  fi

  stty_state="$(stty -g 2>/dev/null || true)"
  if [[ -n "$stty_state" ]]; then
    stty -echo
  fi
  # Ensure terminal state is restored on Ctrl+C while waiting for keys.
  trap 'cursor_blink_on; if [[ -n "$stty_state" ]]; then stty "$stty_state"; fi; printf "\n"; exit 130' INT
  cursor_blink_off
  refresh_window ${top_y} ${left_x} ${height} ${MaxWindowWidth} ${shift_y} "${menu_items[@]}"

  # Сохраняем геометрию окна для последующего позиционирования
  VERTICAL_MENU_LAST_WIDTH=${MaxWindowWidth}
  VERTICAL_MENU_LAST_OUTER_WIDTH=$((MaxWindowWidth + 5))
  VERTICAL_MENU_LAST_HEIGHT=$((height + 2))
  VERTICAL_MENU_LAST_X=${left_x}
  VERTICAL_MENU_LAST_Y=${top_y}
  VERTICAL_MENU_LAST_RIGHT_X=$((left_x + VERTICAL_MENU_LAST_OUTER_WIDTH - 1))

  local selected=${default_selected_index}
  local previous_selected=${default_selected_index}
  while true; do
    # print options by overwriting the last lines

    cursor_to $(($top_y + $previous_selected + 1)) $(($left_x))
    print_option "│  ${menu_items[$previous_selected + ${shift_y}]}"
    repl " " $(($MaxWindowWidth - ${#menu_items[$previous_selected + ${shift_y}]}))
    printf "│"

    cursor_to $(($top_y + $selected + 1)) $(($left_x))
    printf "│ "
    print_selected_on
    printf " ${menu_items[${selected} + ${shift_y}]}"
    repl " " $(($MaxWindowWidth - ${#menu_items[$selected + ${shift_y}]}))
    print_selected_off
    printf " │"

    # user key control
    ReturnKey=$(key_input)
    case ${ReturnKey} in
    enter) break ;;
    esc)
      selected=255
      break
      ;;
    up)
      previous_selected=${selected}
      ((selected--))
      if [[ ${selected} -lt 0 ]]; then
        if ((${shift_y} > 0)); then
          ((shift_y--))
          refresh_window ${top_y} ${left_x} ${height} ${MaxWindowWidth} ${shift_y} "${menu_items[@]}"
          cursor_blink_off
        fi
        selected=0
      fi
      ;;
    down)
      previous_selected=${selected}
      ((selected++))
      if [[ ${selected} -ge ${height} ]]; then
        if (((${shift_y} + ${selected}) < ${#menu_items[@]})); then
          ((shift_y++))
          refresh_window ${top_y} ${left_x} ${height} ${MaxWindowWidth} ${shift_y} "${menu_items[@]}"
          cursor_blink_off
        fi
        selected=${previous_selected}
      fi
      ;;
    esac
  done

  if ((is_current_mode == 1)); then
    printf "\n"
  fi
  cursor_blink_on
  if [[ -n "$stty_state" ]]; then
    stty "$stty_state"
  fi
  trap - INT
  if ((is_current_mode == 1)); then
    if [[ ${ms[0]} == "current" ]]; then
      cursor_to ${current_y} 1
    # очистить выведенное меню
      echo -en ${ESC}"[0J"
    else
      cursor_to $((${top_y} + ${height} + 2)) 1
    fi
  else
    cursor_to ${current_y} 1
  fi
  if ((selected != 255)); then
    ((selected += ${shift_y}))
  fi
  return ${selected}
}
