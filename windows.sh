#!/usr/bin/env bash
#set -euo pipefail
#IFS=$'\n\t'

# little helpers for terminal print control and key input
ESC=$( printf "\033")
cursor_blink_on()     { printf "%s" "${ESC}[?25h"; }
cursor_blink_off()    { printf "%s" "${ESC}[?25l"; }

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
  while read -t 0.01 -n 1 dummy 2>/dev/null; do :; done
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
    local esc=$'\e'
    local up=$'\e[A'
    local down=$'\e[B'

    IFS= read -rsn1 key 2>/dev/null
    if [[ $key == $esc ]]; then
        # Ждем остаток escape-последовательности (до 2 символов)
        IFS= read -rsn2 -t 0.001 rest 2>/dev/null
        key+="$rest"
    fi

    case "$key" in
        $up) echo "up" ;;
        $down) echo "down" ;;
        $esc) echo "esc" ;;
        "") echo "enter" ;;
        *) echo "other:$key" ;;
    esac
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
  local skip_lines=0
  local height
  local shift_y=0
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

  if [[ ${ms[0]} == "current" ]]; then
    # если меню не поместится - надо сдвинуть экран
    ((skip_lines = 0))
    if (((${current_y} + ${height}+1) > ${lines})); then
      ((skip_lines = ${current_y} + ${height} - ${lines} + 2))
      echo -en ${ESC}"[${skip_lines}S"
    fi
    ((top_y = ${current_y} - ${skip_lines}))
    ((current_y = top_y))
  fi
  refresh_window ${top_y} ${left_x} ${height} ${MaxWindowWidth} ${shift_y} "${menu_items[@]}"

  # ensure cursor and input echoing back on upon a ctrl+c during read -s
  trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
  cursor_blink_off

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
        fi
        selected=${previous_selected}
      fi
      ;;
    esac
  done

  printf "\n"
  cursor_blink_on
  cursor_to ${current_y} 1
  if [[ ${ms[0]} == "current" ]]; then
    # очистить выведенное меню
    echo -en ${ESC}"[0J"
  fi
  ((selected += ${shift_y}))
  return ${selected}
}


