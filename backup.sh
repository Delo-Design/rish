#!/bin/bash
clear
MYSQLPASS="2"
if [[ -x "/usr/bin/ydcmd" ]]; then
    ydcmd_path="/usr/bin/ydcmd"
elif [[ -x "/usr/local/bin/ydcmd" ]]; then
    ydcmd_path="/usr/local/bin/ydcmd"
else
    cp /root/rish/ydcmd.py /usr/local/bin/ydcmd || { echo "Ошибка: ydcmd.py не найден"; exit 1; }
    chmod +x /usr/local/bin/ydcmd
    ydcmd_path="/usr/local/bin/ydcmd"
fi

# Путь к конфигурационному файлу
config_file="/root/rish/rish_config.sh"

# Проверяем существование файла
if [ ! -f "$config_file" ]; then
    # Создаем файл, если он не существует
    touch "$config_file"
fi

# Определяем переменные, их значения и комментарии
declare -A vars
vars=(
    ["cnf"]="#конфигурационный файл для ydcmd\ncnf=/root/.ydcmd.cfg"
    ["backupall"]="#\nbackupall=/root/backup_list_all"
    ["directory"]="#директория из которой создается бекап (где лежат сайты по каталогам - один каталог - один сайт)\ndirectory=/var/www/*/www"
    ["DIR_BACKUP"]="#временная папка для создания бекапа\nDIR_BACKUP=/root/backup"
    ["keeplast"]="#сколько последних архиваций хранить\nkeeplast=5"
    ["splitarchive"]="#разбивать архив на части по сколько мегабайт\nsplitarchive=500m"
    ["recordsize"]="#размер записей tar\nrecordsize=1m"
    ["checkpoint"]="#через сколько записей вызывать checkpoint\ncheckpoint=10"
    ["server"]="#Директория бекапа сервера в месте архивирования (куда складывать копии).\n#Если на одном диске будут бекапы разных серверов - надо изменить название для каждого\nserver=\"backup_server\""
)

# Функция для добавления переменной и комментария, если они отсутствуют
add_var_if_not_exists() {
    local var_name="$1"
    local var_value="$2"
    if ! grep -P "^\s*${var_name}\s*=" "$config_file" > /dev/null 2>&1; then
        echo -e "$var_value" >> "$config_file"
    fi
}

# Проверяем каждую переменную
for var in "${!vars[@]}"; do
    add_var_if_not_exists "$var" "${vars[$var]}"
done

source "$config_file"
source /root/rish/windows.sh



DATE=$(/bin/date '+%Y.%m.%d')

GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
WHITE='\033[0m'

createlist() {
	echo
	echo "Создаем список сайтов для архивации."
	echo
	echo -n "" > $backupall
  let ii=0

  maxlen=0

	# Первый проход для определения максимальной длины имени сайта
	for file in $directory/*
	do
		if [ -d "$file" ]
		then
			r="${file##*/}"
			# Определяем длину имени сайта
			len=${#r}
			if (( len > maxlen ))
			then
				maxlen=$len
			fi
		fi
	done

	for file in $directory/*
	do
		if [ -d "$file" ]
		then
			r="${file##*/}"
			db="${r}"
			if [[ "$db" == "000-default" ]]
			then
			   continue
			fi
			let ii=$ii+1
			printf "%3s. " $ii

			if [ -n "`mariadb -uroot -p${MYSQLPASS} -qfsBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$db'" 2>&1`" ];
			then
				db_output="База данных $db"
			else
				db=""
				db_output="----"
			fi
			printf "${GREEN}%-${maxlen}s${WHITE} %-30s\n" "$r" "$db_output"
			currentuser=$(basename $(dirname $(dirname "$file")))
			MYSQLPASS=$(cat /home/${currentuser}/.pass.txt | grep Database | awk '{ print $2}')
			echo "${currentuser};$r;$db;${currentuser};$MYSQLPASS" >> $backupall
		fi
	done
	echo
}

backupall() {

	if ! [[ -d $DIR_BACKUP ]]; then
		mkdir $DIR_BACKUP
	fi

	#/usr/bin/ydcmd --config=$cnf --quiet mkdir disk:/backup"$server"
	#/usr/bin/ydcmd --config=$cnf --quiet mkdir disk:/backup"$server"/"$DATE"

	while read line;do
    IFS=";"
		set -- $line
    USER=$1
		SITE=$2
		DB=$3
		DB_USER=$4
		DB_PASSWD=$5

		mkdir -p $DIR_BACKUP/$server/$USER/$DATE/
		echo -e -n "Архивация ${GREEN}"$SITE"${WHITE}. "
		cd "/var/www/${USER}/www"
		if [ -z "$DB" ]
		then
		   echo -n " Базы нет. "
		   echo -e "Идет создание архива сайта"
		   echo
		   tar -czf -  $SITE --record-size=$recordsize --checkpoint=$checkpoint --checkpoint-action=exec='echo -e "\033[1A"$TAR_CHECKPOINT"mB">&2' | split -b $splitarchive --numeric-suffix - $DIR_BACKUP/"${server}/${USER}/${DATE}/${SITE}.tar.gz-part-"
		else
		   mariadb-dump -u$DB_USER -p$DB_PASSWD $DB > $DB.sql
		   sed -i '1{/999999.*sandbox/d}' $DB.sql
		   echo -e -n " База ${GREEN}$DB${WHITE} создана. "
		   echo -e "Идет создание архива сайта"
		   echo
		   tar -czf - $SITE $DB.sql --record-size=$recordsize --checkpoint=$checkpoint --checkpoint-action=exec='echo -e "\033[1A"$TAR_CHECKPOINT"mB">&2' | split -b $splitarchive --numeric-suffix - $DIR_BACKUP/"${server}/${USER}/${DATE}/${SITE}.tar.gz-part-"
		   rm ./$DB.sql
		fi
		echo -e "\033[1AАрхив сайта создан. Передаем на место хранения."
		$ydcmd_path --config=$cnf put --progress  $DIR_BACKUP/ disk:/
		#sshpass -p 'hzGZadbd1Geg' scp  -r $DIR_BACKUP/* ih1515719@193.124.176.46:/
		rm -rf $DIR_BACKUP/*
	done < $backupall
  for userdir in /var/www/*; do
    # Извлекаем имя пользователя из пути
    user=$(basename "$userdir")
    # Проверяем, является ли элемент директорией
    if [ -d "$userdir" ] && [ "$user" != "cgi-bin" ] && [ "$user" != "html" ]; then
        # Выполнение очистки для директории пользователя
        $ydcmd_path --keep=$keeplast --type=dir clean disk:/"$server/$user"
    fi
  done
}

if [[ "$1" == "auto" ]]
then
   	echo "Автоматическая архивация"
	backupall
   	exit 0
fi

basename() {
    # Usage: basename "path"
    : "${1%/}"
    printf '%s\n' "${_##*/}"
}
configcnf() {
   echo "Конфигурируем ydcmd"
   echo
   echo -e "${GREEN}Скопируйте указанную строку в браузер${WHITE}, выдайте разрешения и полученный код введите по запросу."
   echo
   $ydcmd_path token
   echo
   echo -e -n "${GREEN}Введите код: ${WHITE}"
   read TOKEN
   tt=$( $ydcmd_path token $TOKEN | awk '{print $4}' )
   cd ~
   echo "[ydcmd]" > $cnf
   echo "token = ${tt}" >> $cnf
   echo "verbose = yes" >> $cnf
}

echo "Скрипт автоматического архивирования сайтов сервера"
echo


if [ ! -f $cnf ]
then
	configcnf
fi

if $ydcmd_path --config=$cnf info
then
    echo
    echo -e "Конфигурационный файл настроен ${GREEN}корректно${WHITE}"
else
    echo -e "${LRED}Конфигурирование не удалось${WHITE}"
fi

if [ ! -f $backupall ]
then
	createlist
	echo
	echo -e "Список сайтов для архивации ${GREEN}создан${WHITE} (${backupall})"
  echo
  echo "Для запуска процесса архивации запустите скрипт повторно"
	echo
  echo "Предварительная настройка завершена"
  vertical_menu "current" 2 0 5 "Нажмите Enter"
	exit 0
else
	echo -e "Список сайтов для архивации ${GREEN}найден${WHITE} (${backupall})"
fi
minute=$(shuf -i 0-59 -n 1)
minute=$(printf "%2d" $minute)
echo
echo "┌────────────────────────────────────────────────────────────────┐"
echo "│ Для вызова скрипта в режиме CRON нужно добавить параметр auto. │"
echo "│ Настроить архивацию можно по команде crontab -e                │"
echo "│ $minute 4 * * * /root/rish/backup.sh auto >/dev/null 2>&1           │"
echo "└────────────────────────────────────────────────────────────────┘"
echo
echo
while true
do
	  IFS=$' \t\n'
    echo "Выберите действие:"
    vertical_menu "current" 2 0 5 "default=3" "Архивация всех сайтов сервера" "Обновить файл-список всех архивируемых сайтов"  "Обновить привязку аккаунта яндекс-диска" "Выйти"
    choice=$?
    case "${choice}" in
      0)
      backupall
      ;;
      1)
      createlist
      ;;
      2)
      if [ -f $cnf ]
      then
        rm $cnf
      fi
      configcnf
      echo
      if $ydcmd_path --config=$cnf info
      then
            echo
            echo -e "Конфигурационный файл настроен ${GREEN}корректно${WHITE}"
      else
            echo -e "${LRED}Конфигурирование не удалось${WHITE}"
      fi
      ;;
      *)
        break
      ;;
    esac
done

