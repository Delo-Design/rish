#!/usr/bin/env bash
#set -euo pipefail
#IFS=$'\n\t'

# little helpers for terminal print control and key input
ESC=$( printf "\033")
cursor_blink_on()  { printf "$ESC[?25h"; }
cursor_blink_off() { printf "$ESC[?25l"; }
cursor_to()        { printf "$ESC[$1;${2:-1}H"; }
print_option()     { printf "$1 "; }
print_selected_on()   { printf "$ESC[7m"; }
print_selected_off()   { printf "$ESC[27m"; }
get_cursor_row()   { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo ${ROW#*[}; }
get_cursor_column()   { IFS=';' read -sdR -p $'\E[6n' ROW COL;  echo ${COL}; }
repl() { printf '%.0s'"$1" $(seq 1 "$2"); }
key_input()        {
local key=""
local extra=""
local escKey=`echo -en "\033"`
local upKey=`echo -en "\033[A"`
local downKey=`echo -en "\033[B"`

read -s -n1 key 2> /dev/null >&2
while read -s -n1 -t .0001 extra 2> /dev/null >&2 ; do
	key="$key$extra"
done

if [[ $key = $upKey ]]; then
	echo "up"
elif [[ $key = $downKey ]]; then
	echo "down"
elif [[ $key = $escKey ]]; then
	echo "esc"
elif [[ $key = "" ]]; then
	echo "enter"
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
# если height = 0 - не устанавливать высоты (она будет посчитана автоматически)
#			  = число - установить высоту окна равную числу. Пункты меню будут скролироваться
#	width = число. Если строка будет больше этого числа - то ширина будет расширена до него
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


	ms=( "$@" )
	left_x=${ms[1]}
	top_y=${ms[0]}
	MaxWindowWidth=${ms[3]}
	menu_items=( "${ms[@]:4}" )
	current_y=$(get_cursor_row)

	if (( ${ms[2]}==0 ))
	then
		height=${#menu_items[@]}
	else
		# если требуемая высота больше чем количество пунктов меню, уменьшаем ее
		if (( ${ms[2]} > ${#menu_items[@]} ))
		then
			height=${#menu_items[@]}
		else
			height=${ms[2]}
		fi
	fi

	#find the width of the window
	for el in "${menu_items[@]}"
	do
		if (( ${MaxWindowWidth} < ${#el} ))
		then
			MaxWindowWidth=${#el}
		fi
    done
	(( MaxWindowWidth=${MaxWindowWidth}+2 ))

	if [[ ${ms[1]} == "center" ]]
	then
		(( left_x= (${columns}-${MaxWindowWidth}-6) /2))
	fi
	if [[ ${ms[0]} == "center" ]]
	then
		(( top_y= (${lines}-${height}-2) /2))
	fi

	if [[ ${ms[0]} == "current" ]]
	then
		# если меню не поместится - надо сдвинуть экран
		(( skip_lines=0 ))
		if (( (${current_y}+${height}) > ${lines} ))
		then
			(( skip_lines=${current_y}+${height}-${lines} ))
			echo -en ${ESC}"[${skip_lines}S"
		fi
		(( top_y=${current_y} - ${skip_lines} ))
		(( current_y=top_y ))
	fi
	refresh_window ${top_y} ${left_x} ${height} ${MaxWindowWidth} ${shift_y} "${menu_items[@]}"

    # ensure cursor and input echoing back on upon a ctrl+c during read -s
    trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
    cursor_blink_off

    local selected=0
    local previous_selected=0
    while true; do
        # print options by overwriting the last lines

		cursor_to $(($top_y + $previous_selected + 1)) $(($left_x))
		print_option "│  ${menu_items[$previous_selected+${shift_y}]}"
		repl " " $(( $MaxWindowWidth-${#menu_items[$previous_selected+${shift_y}]} ))
		printf "│"

		cursor_to $(($top_y + $selected + 1)) $(($left_x))
		printf "│ "
		print_selected_on
		printf " ${menu_items[${selected}+${shift_y}]}"
		repl " " $(($MaxWindowWidth-${#menu_items[$selected+${shift_y}]}))
		print_selected_off
		printf " │"


        # user key control
        ReturnKey=`key_input`
        case ${ReturnKey} in
            enter) break;;
            esc) selected=255; break;;
            up)    previous_selected=${selected};
            	   ((selected--));
                   if [[ ${selected} -lt 0 ]]
                   then
                   		if (( ${shift_y} > 0 ))
                   		then
                   			(( shift_y-- ))
                   			refresh_window ${top_y} ${left_x} ${height} ${MaxWindowWidth} ${shift_y} "${menu_items[@]}"
                   		fi
                   		selected=0
                   fi
                   ;;
            down)  previous_selected=${selected};
            	   ((selected++));
                   if [[ ${selected} -ge ${height} ]]
                   then
                   		if (( (${shift_y} + ${selected}) < ${#menu_items[@]} ))
                   		then
                   			(( shift_y++ ))
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
	if [[ ${ms[0]} == "current" ]]
	then
		# очистить выведенное меню
		echo -en ${ESC}"[0J"
	fi
	(( selected+=${shift_y} ))
    return ${selected}
}


function fn_bui_setup_get_env()
{
    # save the home dir
    local _script_name=${BASH_SOURCE[0]}
    local _script_dir=${_script_name%/*}

    if [[ "$_script_name" == "$_script_dir" ]]
    then
        # _script name has no path
        _script_dir="."
    fi

    # convert to absolute path
    _script_dir=$(cd $_script_dir; pwd -P)

    export BUI_HOME=$_script_dir
}

