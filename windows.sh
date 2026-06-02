#!/usr/bin/env bash
#set -euo pipefail
#IFS=$'\n\t'

# little helpers for terminal print control and key input
ESC=$( printf "\033")
cursor_blink_on()     { printf "%s" "${ESC}[?25h"; }
cursor_blink_off()    { printf "%s" "${ESC}[?25l"; }
mouse_tracking_on()   { printf "%s" "${ESC}[?1000h${ESC}[?1006h"; }
mouse_tracking_off()  { printf "%s" "${ESC}[?1006l${ESC}[?1000l"; }

VERTICAL_MENU_LAST_WHEEL_MS=0

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

vertical_menu_cleanup() {
  mouse_tracking_off
  cursor_blink_on
  if [[ -n "$stty_state" ]]; then
    stty "$stty_state"
  fi
}

vertical_menu_restore_traps() {
  if [[ -n "$previous_int_trap" ]]; then eval "$previous_int_trap"; else trap - INT; fi
  if [[ -n "$previous_term_trap" ]]; then eval "$previous_term_trap"; else trap - TERM; fi
  if [[ -n "$previous_hup_trap" ]]; then eval "$previous_hup_trap"; else trap - HUP; fi
}

vertical_menu_install_traps() {
  trap 'vertical_menu_handle_signal INT' INT
  trap 'vertical_menu_handle_signal TERM' TERM
  trap 'vertical_menu_handle_signal HUP' HUP
}

vertical_menu_handle_signal() {
  local signal="$1"
  vertical_menu_cleanup
  vertical_menu_restore_traps
  kill -s "$signal" "$$"

  # If the previous handler returned or ignored the signal, resume the menu.
  vertical_menu_install_traps
  if [[ -n "$stty_state" ]]; then
    stty -echo
  fi
  mouse_tracking_on
  cursor_blink_off
}

get_time_ms() {
  local now

  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    now="${EPOCHREALTIME/./}"
    printf "%s\n" "${now:0:${#now}-3}"
    return
  fi

  now=$(date +%s%3N)
  [[ "$now" =~ ^[0-9]+$ ]] && printf "%s\n" "$now" || printf "0\n"
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
repl() {
    local char="$1"
    local count="$2"
    local out

    ((count > 0)) || return
    printf -v out "%*s" "$count" ""
    printf "%s" "${out// /$char}"
}
key_input() {
    local result_var="$1"
    local key=""
    local c1=""
    local c2=""
    local c=""
    local esc=$'\e'
    local mouse_sequence=""
    local mouse_button
    local mouse_x
    local mouse_y
    local mouse_action
    local mouse_wheel_ms

    IFS= read -rsn1 key 2>/dev/null || true

    if [[ "$key" == "$esc" ]]; then
        # Одиночный ESC: продолжения нет.
        if ! IFS= read -rsn1 -t 0.008 c1 2>/dev/null; then
            printf -v "$result_var" "%s" "esc"
            return
        fi

        # Поддерживаем стрелки вверх/вниз и SGR-события мыши.
        if [[ "$c1" == "[" || "$c1" == "O" ]]; then
            if IFS= read -rsn1 -t 0.008 c2 2>/dev/null; then
                case "$c2" in
                    A) printf -v "$result_var" "%s" "up"; return ;;
                    B) printf -v "$result_var" "%s" "down"; return ;;
                    "<")
                        while IFS= read -rsn1 -t 0.008 c 2>/dev/null; do
                            if [[ "$c" == "M" || "$c" == "m" ]]; then
                                mouse_action="$c"
                                break
                            fi
                            mouse_sequence+="$c"
                            ((${#mouse_sequence} < 32)) || break
                        done
                        IFS=';' read -r mouse_button mouse_x mouse_y <<< "$mouse_sequence"
                        if [[ "$mouse_button" =~ ^[0-9]+$ && "$mouse_x" =~ ^[0-9]+$ && "$mouse_y" =~ ^[0-9]+$ ]]; then
                            if ((mouse_button & 64)); then
                                mouse_wheel_ms=$(get_time_ms)
                                if ((mouse_wheel_ms > 0 &&
                                     mouse_wheel_ms - VERTICAL_MENU_LAST_WHEEL_MS < 30)); then
                                    printf -v "$result_var" "%s" "other:mouse_wheel_ignored"
                                    return
                                fi
                                VERTICAL_MENU_LAST_WHEEL_MS=$mouse_wheel_ms
                                case $((mouse_button & 3)) in
                                    0) printf -v "$result_var" "%s" "up"; return ;;
                                    1) printf -v "$result_var" "%s" "down"; return ;;
                                esac
                            fi
                            if [[ "$mouse_action" == "m" ]] && (( (mouse_button & 3) == 0 )); then
                                printf -v "$result_var" "%s" "mouse_click:${mouse_x}:${mouse_y}"
                                return
                            fi
                            printf -v "$result_var" "%s" "other:mouse_ignored"
                            return
                        fi
                        ;;
                esac
            fi
        fi

        # Неизвестный ESC-ввод: сливаем хвост, чтобы избежать артефактов.
        drain_input_tail
        printf -v "$result_var" "%s" "other:${esc}${c1}${c2}"
        return
    fi

    if [[ -z "$key" ]]; then
        printf -v "$result_var" "%s" "enter"
    else
        printf -v "$result_var" "%s" "other:$key"
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
		repl " " $(( ${MaxWindowWidth}-${#menu_items[${i}+${shift_y}]} - 1 ))
		print_vertical_menu_right_border "$i" "$height" "$shift_y" "${#menu_items[@]}"
	done

	cursor_to $(($top_y + ${i} +1 )) $(($left_x))
	printf "└"
	repl "─" $(( $MaxWindowWidth + 3 ))
	printf "┘"
}

print_vertical_menu_right_border() {
  local row="$1"
  local height="$2"
  local shift_y="$3"
  local item_count="$4"

  if ((row == 0 && shift_y > 0)); then
    printf "↑│"
  elif ((row == height - 1 && shift_y + height < item_count)); then
    printf "↓│"
  else
    printf " │"
  fi
}

print_vertical_menu_selected_row() {
  local top_y="$1"
  local left_x="$2"
  local selected="$3"
  local height="$4"
  local MaxWindowWidth="$5"
  local shift_y="$6"
  local menu_item="$7"
  local item_count="$8"

  cursor_to $(($top_y + $selected + 1)) $(($left_x))
  printf "│ "
  print_selected_on
  printf " ${menu_item}"
  repl " " $(($MaxWindowWidth - ${#menu_item}))
  print_selected_off
  print_vertical_menu_right_border "$selected" "$height" "$shift_y" "$item_count"
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
  local previous_int_trap
  local previous_term_trap
  local previous_hup_trap
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
  if ((${#menu_items[@]} == 0)); then
    return 255
  fi
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
  # Ensure terminal state is restored if the menu is interrupted while waiting for keys.
  previous_int_trap="$(trap -p INT)"
  previous_term_trap="$(trap -p TERM)"
  previous_hup_trap="$(trap -p HUP)"
  vertical_menu_install_traps
  mouse_tracking_on
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
    repl " " $(($MaxWindowWidth - ${#menu_items[$previous_selected + ${shift_y}]} - 1))
    print_vertical_menu_right_border "$previous_selected" "$height" "$shift_y" "${#menu_items[@]}"

    print_vertical_menu_selected_row "$top_y" "$left_x" "$selected" "$height" "$MaxWindowWidth" "$shift_y" "${menu_items[$selected + $shift_y]}" "${#menu_items[@]}"

    # user key control
    key_input ReturnKey
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
    mouse_click:*)
      local mouse_x
      local mouse_y
      IFS=':' read -r _ mouse_x mouse_y <<< "$ReturnKey"
      if ((mouse_x >= left_x && mouse_x <= left_x + MaxWindowWidth + 4 &&
           mouse_y >= top_y + 1 && mouse_y <= top_y + height)); then
        cursor_to $(($top_y + $selected + 1)) $(($left_x))
        print_option "│  ${menu_items[$selected + ${shift_y}]}"
        repl " " $(($MaxWindowWidth - ${#menu_items[$selected + ${shift_y}]} - 1))
        print_vertical_menu_right_border "$selected" "$height" "$shift_y" "${#menu_items[@]}"
        selected=$((mouse_y - top_y - 1))
        print_vertical_menu_selected_row "$top_y" "$left_x" "$selected" "$height" "$MaxWindowWidth" "$shift_y" "${menu_items[$selected + $shift_y]}" "${#menu_items[@]}"
        sleep 0.08
        break
      fi
      ;;
    esac
  done

  if ((is_current_mode == 1)); then
    printf "\n"
  fi
  vertical_menu_cleanup
  vertical_menu_restore_traps
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
