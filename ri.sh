#!/usr/bin/env bash
#set -euo pipefail
#IFS=$'\n\t'

#Вспомогательное внутри сценария
SCRIPTVERSION='0.1.1'
GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
VIOLET='\033[0;35m'
WHITE='\033[0m'
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'
ServerArch=$( arch )


SUPPORTED_OS='Fedora|Rocky|AlmaLinux|CentOS|Red Hat Enterprise Linux Server'
size=$(stty size)
lines=${size% *}
columns=${size#* }
upperX=1
upperY=1
downY=$((${lines}/2))
rim=$(( ${downY} - 2 ))
whereCursorIs="down"

# save the home dir
declare _script_name=${BASH_SOURCE[0]}
declare _script_dir=${_script_name%/*}

if [[ "$_script_name" == "$_script_dir" ]]
then
	# _script name has no path
	_script_dir="."
fi

# convert to absolute path
_script_dir=$(cd ${_script_dir}; pwd -P)

export RISH_HOME=${_script_dir}

cd ${RISH_HOME}
source windows.sh
source clonesite.sh

# если настройка скрипта уже была произведена, но сессия не была перезапущена - подгрузим пароль базы данных
if [[ -z "${MYSQLPASS}" ]]
then
	if grep -q "MYSQLPASS" ~/.bashrc
	then
		MYSQLPASS=`cat ~/.bashrc | grep MYSQLPASS | awk -F= '{ print $2}'`
	fi
fi

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
		# ограничить скрол нижней частью экрана
		cursor_to ${downY} 1
		whereCursorIs="down"
	fi
}

RemoveRim () {
	echo -e ${ESC}"[;r"
	cursor_to $(( ${rim} +1 )) 1
	echo -en ${ESC}"[0J"
}

clear
# рисуем разделительную линию
cursor_to $(( ${rim} +1 )) 1
repl "─" $(( ${columns} ))
cursor_to $(( ${rim} +2 )) 1
Up
if (type lsb_release > /dev/null 2>&1); then
	CURRENT_OS=$(lsb_release -d -s)
	echo -e "Ваша версия Linux: ${RED}$CURRENT_OS${WHITE}"
elif [[ -f /etc/system-release ]]; then
	CURRENT_OS=$(head -1 /etc/system-release)
	echo -e "Ваша версия Linux: ${GREEN}$CURRENT_OS${WHITE}"
	echo
elif [[ -f /etc/issue ]]; then
	CURRENT_OS=$(head -2 /etc/issue)
	echo -e "Ваша версия Linux: ${RED}$CURRENT_OS${WHITE}"
else
	echo -e "${RED}Невозможно определить вашу версию Linux${WHITE}"
	exit 1
fi
if ! echo ${CURRENT_OS} | egrep -q "$SUPPORTED_OS"
then
   echo -e "Ваш дистрибутив Linux ${RED}не поддерживается${WHITE}"
   exit 1
fi
if echo ${CURRENT_OS} | grep -Eq "Fedora"
then
  FedoraVersion=$( cat /etc/fedora-release | sed 's@^[^0-9]*\([0-9]\+\).*@\1@' )
fi

Infon() {
    printf "${GREEN}$@${WHITE}"
}

Info()
{
    Infon "$@\n"
}

Error()
{
    printf "\033[1;31m$@\033[0m\n"
}

Warningn() {
    printf "\033[1;35m$@\033[0m"
}

Warning()
{
    Warningn "$@\n"
}

OpenFirewall() {
    if command -v firewall-cmd >/dev/null 2>&1  && systemctl status firewalld  >/dev/null
    then
        if firewall-cmd --list-all  | grep http > /dev/null && firewall-cmd --list-all  | grep https > /dev/null
        then
            Info "${GREEN}Firewall${WHITE} уже открыт"
        else
            echo -e "Открываем ${GREEN}firewall${WHITE}"
            Down
            ZoneName=$(firewall-cmd --get-default-zone)
            firewall-cmd --zone=${ZoneName} --permanent --add-service=http
            firewall-cmd --zone=${ZoneName} --permanent --add-service=https
            firewall-cmd --reload
            Up
        fi
    else
        echo -e "${GREEN}Firewall${WHITE} не установлен"
    fi
}

Install() {
if ! rpm -q $@ >/dev/null 2>&1
then
	Up
	echo -e "Ставим ${GREEN}${@}${WHITE}"
	Down
	if yum -y install $@
	then
		(( upperY -- ))
		Up
		echo -e "${GREEN}$@${WHITE} установлен "
	else
		(( upperY -- ))
		Up
		echo -e "Установить ${RED}$@${WHITE} не удалось"
		RemoveRim
		exit 1
	fi
	echo
else
	Up
  	echo -e "${GREEN}$@${WHITE} уже установлен"
fi
Down
}

# shellcheck disable=SC2120
CreateUser() {
local NAME
# try to create user
 	if (( $# == 0 ))
	then
		while true; do
			echo -e -n "${WHITE}Введите имя пользователя (для выхода наберите EXIT):${GREEN}"
			read -e -p " " -i  "siteuser" NAME
			if [[ -z "${NAME}" ]]
			then
				continue
			fi
			if id -u ${NAME} >/dev/null 2>&1
			then
				echo -e "${WHITE}Такой пользователь уже есть ${LRED}${NAME}${WHITE}"
			else
				break
			fi
		done
		echo -e ${WHITE}
		echo "При создании новых сайтов Joomla требуется указать учетную запись для администратора."
		echo "Вы можете указать имя этой учетной записи, чтобы в дальнейшем не тратить время на ее изменение."
		echo -e "Если вы не укажете имя сейчас - оно будет создано автоматически. "
		echo -e "Изменить его можно будет в файле ${GREEN}/home/${NAME}/.pass.txt${WHITE}"
		echo
		read -e -p "Введите имя учетной записи для создания сайтов по умолчанию (можно не заполнять - нажмите Enter)" DEFAULTSITEACCOUNT
	else
		NAME=$1
	fi


	if  [[ ${NAME} == "EXIT" ]] || [[ ${NAME} == "exit" ]]
	then
		echo -e ${WHITE}
		return 0
	else
		echo -e "${WHITE}Создаем пользователя ${GREEN}${NAME}${WHITE}"
	fi

	if id -u ${NAME} >/dev/null 2>&1
	then
		echo -e "${WHITE}Такой пользователь уже есть ${LRED}${NAME}${WHITE}"
		return 1
	fi
	useradd -s /sbin/nologin ${NAME}
	pass=$( tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs )
	echo ${NAME}:${pass} | chpasswd
	pass2=$( tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs )
	echo "Database: ${pass2}" > /home/${NAME}/.pass.txt
	echo -e "Пароль пользователя ${NAME}: ${GREEN}"${pass}${WHITE}
	echo "${NAME}: ${pass}" >> /home/${NAME}/.pass.txt
	echo -e "Пароль для баз данных ${NAME}: ${GREEN}"${pass2}${WHITE}
  pass3=$( tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs )
  if [[ -z ${DEFAULTSITEACCOUNT} ]]
  then
    DEFAULTSITEACCOUNT="info@${NAME}.com"
  fi
  echo "defaultsiteaccount ${DEFAULTSITEACCOUNT} ${pass3}" >> /home/${NAME}/.pass.txt

	chmod go-rwx /home/${NAME}/.pass.txt
	chown ${NAME}:${NAME} /home/${NAME}/.pass.txt

	echo -e "Пароли записаны в файл ${GREEN}/home/${NAME}/.pass.txt${WHITE}"
	if [[ $(getent group sftp) ]]; then
		echo ""
	else
	 	groupadd sftp
	fi
	usermod -a -G sftp ${NAME}
	# редактируем /etc/ssh/sshd_config.
	## override default of no subsystems
	##Subsystem<---->sftp<-->/usr/libexec/openssh/sftp-server
	#Subsystem sftp internal-sftp -u 022
	#Match Group sftp
	#ChrootDirectory /var/www/%u
	#ForceCommand internal-sftp -u 022
	sed -i '/Match Group sftp/d' /etc/ssh/sshd_config
	sed -i '/ChrootDirectory \/var\/www\/%u/d' /etc/ssh/sshd_config
	sed -i '/ForceCommand internal-sftp -u 022/d' /etc/ssh/sshd_config
	r="Subsystem sftp internal-sftp -u 022\n"
	r=${r}"Match Group sftp\n"
	r=${r}"ChrootDirectory /var/www/%u\n"
	r=${r}"ForceCommand internal-sftp -u 022"
	sed -i "s&^Subsystem.*&${r}&" /etc/ssh/sshd_config
	systemctl restart sshd
	usermod -aG ${NAME} apache
	mkdir /var/www/${NAME}
	mkdir /var/www/${NAME}/logs
	mkdir /var/www/${NAME}/www
	chown ${NAME}:${NAME} /var/www/${NAME}/www
	chown ${NAME}:${NAME} /var/www/${NAME}/logs

	# устанавливаем владельцем siteuser
	# создаем папку /home/siteuser/.ssh
	mkdir /home/${NAME}/.ssh
	chown ${NAME}:${NAME} /home/${NAME}/.ssh

	# прописываем в файл /home/siteuser/.ssh/authorized_keys ключ доступа для юзера
	echo "" > /home/${NAME}/.ssh/authorized_keys
	chown ${NAME}:${NAME} /home/${NAME}/.ssh/authorized_keys

	#копируем файл /etc/php-fpm.d/www.conf -> siteuser.conf

	echo
	echo -e "Выберите режим работы PHP для этого пользователя:"
	vertical_menu "current" 2 0 5 "ondemand - оптимально расходует память" "dynamic - более оперативно реагирует на запросы"
	cr=$?
	if (( ${cr}==0 ))
	then
		r="ondemand"
	else
		r="dynamic"
	fi
	echo -e ${CURSORUP}"Выбран режим PHP "${GREEN}${r}${WHITE}${ERASEUNTILLENDOFLINE}

	{
	  echo "[${NAME}]"
	  echo "listen = /var/run/php-fpm/${NAME}.sock"
	  echo "user = ${NAME}"
	  echo "group = ${NAME}"
	  echo "listen.owner = ${NAME}"
	  echo "listen.group = ${NAME}"
	  echo
	  echo "listen.allowed_clients = 127.0.0.1"
	  echo "pm = ${r}"
    echo "pm.max_children = 50"
    echo "pm.start_servers = 3"
    echo "pm.min_spare_servers = 3"
    echo "pm.max_spare_servers = 5"
    echo "slowlog = /var/log/php-fpm/www-slow.log"
    echo "php_value[session.save_handler] = files"
    echo "php_value[session.save_path] = /var/www/${NAME}/session"
    echo "php_value[soap.wsdl_cache_dir] = /var/www/${NAME}/wsdlcache"
	} > /etc/php-fpm.d/${NAME}.conf


	#cp /etc/php-fpm.d/www.conf  /etc/php-fpm.d/${NAME}.conf
	#меняем имя пула.
	#[www]->[siteuser]
	#sed -i "s/^\[www\]/\[${NAME}\]/" /etc/php-fpm.d/${NAME}.conf
	# удаляем старое
	#sed -i '/^user = apache/d' /etc/php-fpm.d/${NAME}.conf
	#sed -i '/^group = apache/d' /etc/php-fpm.d/${NAME}.conf

	# меняем user = apache -> user = siteuser
	# group = apache -> group = siteuser

	#listen.owner = siteuser
	#listen.group = siteuser
	#sed -i "s/^listen.owner = apache/listen.owner = ${NAME}/" /etc/php-fpm.d/${NAME}.conf
	#sed -i "s/^listen.group = apache/listen.group = ${NAME}/" /etc/php-fpm.d/${NAME}.conf
	#r="listen = \/var\/run\/php-fpm\/${NAME}.sock\n"
	#r=${r}"user = ${NAME}\n"
	#r=${r}"group = ${NAME}"
	#sed -i "s/^listen = \/var\/run\/php-fpm\/default.sock/${r}/" /etc/php-fpm.d/${NAME}.conf

	# если надо - меняем режим работы php на ondemand
	# в этом же файле в конце меняем
	# php_value[session.save_path]    = /var/lib/php/session/siteuser
	# php_value[soap.wsdl_cache_dir]  = /var/lib/php/wsdlcache/siteuser
	#sed -i "s/^php_value\[session.save_path\].*$/php_value\[session.save_path\] = \/var\/www\/${NAME}\/session/" /etc/php-fpm.d/${NAME}.conf
	#sed -i "s/^php_value\[soap.wsdl_cache_dir\].*$/php_value\[soap.wsdl_cache_dir\] = \/var\/lib\/${NAME}\/wsdlcache/" /etc/php-fpm.d/${NAME}.conf

	#sed -i "s/^pm = .*/pm = ${r}/" /etc/php-fpm.d/${NAME}.conf

	# и создаем папки и устанавливаем их владельцем siteuser
	mkdir /var/www/${NAME}/session
	mkdir /var/www/${NAME}/wsdlcache
	chown ${NAME}:${NAME} /var/www/${NAME}/session
	chown ${NAME}:${NAME} /var/www/${NAME}/wsdlcache

	# Архивируем конфигурацию апача по умолчанию
	if [[ -e /etc/httpd/conf.d/php.conf ]]
	then
		mv /etc/httpd/conf.d/php.conf /etc/httpd/conf.d/php.conf.bak
	fi

	if ! php-fpm -t
	then
		echo "Ошибка в настройках. PHP-FPM не был перезагружен"
	else
		systemctl restart php-fpm
		echo -n "PHP-FPM был перезагружен, "
	fi

	if ! [[ -d ~/.config ]]
	then
		mkdir ~/.config
	fi
	if ! [[ -d ~/.config/mc ]]
	then
		mkdir ~/.config/mc
	fi
	if ! grep -q "${NAME}" ~/.config/mc/hotlist
	then
		echo 'ENTRY "/var/www/'${NAME}'/www" URL "/var/www/'${NAME}'/www"' >> ~/.config/mc/hotlist
	fi
	if mysql  -e "CREATE USER ${NAME}@localhost IDENTIFIED BY '${pass2}';"
	then
		echo -e "пользователь ${GREEN}${NAME}${WHITE} успешно создан"
	else
		echo -e "во время создания пользователя ${RED}${NAME}${WHITE} MySQL произошла ошибка"
	fi
}

DeleteDatabase() {
	   echo -e "Вы хотите удалить базу данных ${LRED}${1}${WHITE}?"
		if vertical_menu "current" 2 0 5 "Нет" "Да"
		then
		  echo "База данных не была удалена"
		  return 1
	     elif (( $? == 255 ))
	     then
		  echo "База данных не была удалена"
		  return 1
		fi
		echo -e ${CURSORUP}${ERASEUNTILLENDOFLINE}
		if mysqladmin -f  drop ${1}
		then
		   echo -e "База данных ${GREEN}${1}${WHITE} удалена"
		else
		   echo -e "При удалении базы данных ${RED}${1}${WHITE} произошли ${RED}ошибки${WHITE}"
		fi
}
DeleteUser() {
	# если папка не пуста, то отказываться удалять пользователя
	if [[ -n $( ls -A /var/www/${1}/www ) ]]
	then
		echo "У пользователя есть неудаленные сайты. Вначале удалите их."
		echo -e -n ${RED}
		cd /var/www/${1}/www
		# выводим директории
		ls -d */ | cut -f1 -d'/'
		# и файлы
		echo -e -n ${LRED}
		ls -Sp | grep -v '/'
		echo -e ${WHITE}
		return 1
	fi
	# проверим на предмет неудаленных баз данных
	SiteuserMysqlPass=`cat /home/${1}/.pass.txt | grep Database | awk '{ print $2}'`
	bases=( `mysql -u${1} -p${SiteuserMysqlPass}  --batch -e "SHOW DATABASES" | tail -n +3` )
	if (( ${#bases[@]} > 0 ))
	then
		echo "У пользователя есть неудаленные базы данных:"
		echo -e ${RED}
		for i in "${bases[@]}"; do
		  echo ${i}
		done
		echo -e ${WHITE}
		echo "Вначале удалите их"
		return 1
	fi

	rm -rf /var/www/${1}

	rm -f /etc/php-fpm.d/${1}*
	gpasswd -d apache ${1}
	if ! php-fpm -t
	then
		echo "Ошибка в настройках. PHP-FPM не был перезагружен"
	else
		systemctl restart php-fpm
		echo "PHP-FPM был перезагружен"
	fi
	userdel --remove ${1}
	sed -i '/'${1}'/d' ~/.config/mc/hotlist
	mysql  -e "DROP USER IF EXISTS ${1}@localhost;"
}


Info "System memory:"
free -m
echo ""

Info "Disk space:"
df -h -P -l -x tmpfs -x devtmpfs
echo ""


if ! grep -q "MYSQLPASS" ~/.bashrc
then
	echo -n "Проверяем обновления сервера... "
	if yum check-update > /dev/null
	then
	  	echo "Сервер не требует обновления"
	else
		Down
		echo ""
		echo 'Обновляем сервер? '
		echo 'Настоятельно рекомендуем обновить при первом запуске.'
    vertical_menu "current" 2 0 5 "Да" "Нет" "Выйти"
    ret=$?
    if (( ret > 1 ))
    then
      exit 1
    fi
		if (( ret == 0 ))
		then
			((upperY--))
			Up
			echo
			echo -e "Идет обновление сервера..."${ERASEUNTILLENDOFLINE}
			Down
			yum update -y
		fi
		Up
	fi
fi


if ! grep -q "MYSQLPASS" ~/.bashrc
then
# we think that it is the first run of the script

	if localectl status | grep -q UTF-8
	then
	 	echo
	 	echo -e "Кодировка консоли уже установлена правильно - ${GREEN}UTF-8${WHITE}."
	else
		localectl set-locale LANG=en_US.UTF-8
		echo
		Warning "\nБыла установлена кодировка UTF-8 для консоли. Надо перезагрузить сервер. "
		tet=$(pwd)
		echo -e "После перезагрузки запустите скрипт заново командой ${GREEN}${tet}/ri.sh${WHITE}"
		Down
		echo "Перезагрузить сервер?"
		if vertical_menu "current" 2 0 5 "Да" "Нет"
		then
			echo "Перезагрузка сервера начата..."
			reboot
		else
			RemoveRim
			echo -e "Перезагрузите сервер самостоятельно командой ${GREEN}reboot${WHITE}"
			exit 0
		fi
	fi

	if command -v sestatus >/dev/null 2>&1
	then
		 if [[ -f /etc/selinux/config ]]
		 then
			  if [[ `cat /etc/selinux/config | grep "SELINUX=enforcing"` ]]
			  then
					sed -i "s/SELINUX=enforcing/SELINUX=disabled/" /etc/selinux/config
					echo
					Error "Включен selinux."
					echo "Мы установили значение в конфигурационном файле для отключения selinux"
					echo "Вам остается только выполнить перезагрузку сервера."

					tet=$(pwd)
					Down
					echo -e "После перезагрузки запустите скрипт заново командой ${GREEN}${tet}/ri.sh${WHITE}"
					echo "Перезагрузить сервер?"
					if vertical_menu "current" 2 0 5 "Да" "Нет"
					then
						echo "Перезагрузка сервера начата..."
						reboot
					else
						RemoveRim
						echo -e "Перезагрузите сервер самостоятельно командой ${GREEN}reboot${WHITE}"
						echo -e "После перезагрузки запустите скрипт заново командой ${GREEN}${tet}/ri.sh${WHITE}"
						exit 0
					fi
			  fi
		 else
			  echo "Конфигурационный файл selinux /etc/selinux/config не доступен,"
			  echo "Хотя система selinux на компьютере присутствует"
			  RemoveRim
			  exit 0
		 fi
	fi

	Down
	echo -e "Начать ${GREEN}установку${WHITE} сервера?"
	LocalServer=false
	vertical_menu "current" 2 0 5 "Установка боевого (production) сервера" "Установка локального сервера" "Выйти"
	ret=$?
  if (( ret > 1 ))
  then
    RemoveRim
		echo -e "${RED}Установка сервера прервана${WHITE}"
    exit
  fi
  if (( ret == 1 ))
  then
    LocalServer=true
		echo -e "Установка ${VIOLET}локального${WHITE} сервера"
	else
	  echo -e "Установка ${RED}боевого${WHITE} сервера"
  fi

	Install mc
	Install cronie
	Install logrotate
	if ! echo ${CURRENT_OS} | egrep -q "Fedora"
	then
	  Install epel-release
	fi
  Install wget
  Install tar

	cd /etc/yum.repos.d
#	ver="codeit.el"`rpm -q --qf "%{VERSION}" $(rpm -q --whatprovides redhat-release)`".repo"
#	if [[ -f ${ver} ]]
#	then
#	  rm -f $ver
#	fi
#	wget https://repo.codeit.guru/${ver}
	Install "httpd mod_ssl"

	Down
	systemctl enable httpd
	echo
	systemctl start httpd
	echo
	Up

	OpenFirewall
	if ! ${LocalServer}
	then
	  Down
	  echo -e "Закрываем порт доступа ${GREEN}cockpit${WHITE}?"
	  echo "Если не знаете что это такое - закрывайте"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      firewall-cmd --zone="${ZoneName}" --remove-service=ssh --permanent
      firewall-cmd --reload
    fi
    Up
  fi

	echo -e "Отключаем heartbeat module и перезапускаем ${GREEN}apache${WHITE}"
	sed -i "s/LoadModule lbmethod_heartbeat_module/#LoadModule lbmethod_heartbeat_module/" /etc/httpd/conf.modules.d/00-proxy.conf
	sed -i "s/##/#/" /etc/httpd/conf.modules.d/00-proxy.conf

	rm -f /usr/share/httpd/noindex/index.html
	cp ${RISH_HOME}/index.html /usr/share/httpd/noindex/index.html

	Down
	apachectl restart
	Up
	if [[ ${ServerArch} == "aarch64" ]]
	then
	  echo -e "Ставим стандартный php из репозиториев системы"
	  Down
	  dnf install -y php-fpm php-opcache php-cli php-gd php-mbstring php-mysqlnd php-xml php-soap php-xmlrpc php-zip php-intl php-json
	  echo -e "Ставим ${GREEN}imagick${WHITE}?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      Install "php-pecl-imagick"
      #yum install php-pecl-imagick
    fi
	  Up
  else
    echo -e "Ставим репозиторий ${GREEN}Remi Collet${WHITE} для установки ${GREEN}PHP${WHITE}"

    cd /etc/yum.repos.d
    Down
    if echo ${CURRENT_OS} | egrep -q "Fedora"
    then
      FedoraVersion=$( cat /etc/fedora-release | sed 's@^[^0-9]*\([0-9]\+\).*@\1@' )
      dnf install -y https://rpms.remirepo.net/fedora/remi-release-${FedoraVersion}.rpm
    else
      dnf install -y https://rpms.remirepo.net/enterprise/remi-release-8.rpm
    fi
    mapfile -t options < <( dnf module list -y php | grep -Eo 'remi-[0-9].[0-9]')
    echo -e "Выберите ${GREEN}версию PHP${WHITE} для установки"
    vertical_menu "current" 2 0 5 "${options[@]}"
    ret=$?
    if (( ${ret} == 255 ))
    then
      exit
    fi
    reply=${options[${ret}]}
    Up
    Warning "Выбран php версии ${reply}"

    Down
    dnf config-manager --set-enabled remi
    dnf module -y reset php
    dnf module enable -y php:"${reply}"

    dnf install -y php-fpm php-opcache php-cli php-gd php-mbstring php-mysqlnd php-xml php-soap php-xmlrpc php-zip php-intl php-json
    echo -e "Ставим ${GREEN}imagick${WHITE}?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      Install "php-pecl-imagick"
      #yum install php-pecl-imagick
    fi
    (( upperY-- ))
    Up
	fi
	php -v
	Down

	cd /etc/httpd/conf.d/

	echo "# Tell the PHP interpreter to handle files with a .php extension." > php.conf
	echo "# Proxy declaration" >> php.conf
	echo "<Proxy \"unix:/var/run/php-fpm/default.sock|fcgi://php-fpm\">" >> php.conf
	echo "# we must declare a parameter in here (doesn't matter which) or it'll not register the proxy ahead of time" >> php.conf
	echo "   ProxySet disablereuse=on connectiontimeout=3 timeout=60" >> php.conf
	echo "</Proxy>" >> php.conf
	echo "# Redirect to the proxy" >> php.conf
	echo "<FilesMatch \.php$>" >> php.conf
	echo "    SetHandler proxy:fcgi://php-fpm" >> php.conf
	echo "</FilesMatch>" >> php.conf
	echo "#" >> php.conf
	echo "# Allow php to handle Multiviews" >> php.conf
	echo "#" >> php.conf
	echo "AddType text/html .php" >> php.conf
	echo "#" >> php.conf
	echo "# Add index.php to the list of files that will be served as directory" >> php.conf
	echo "# indexes." >> php.conf
	echo "#" >> php.conf
	echo "DirectoryIndex index.php" >> php.conf
	echo "#" >> php.conf
	echo "#<LocationMatch "/status">" >> php.conf
	echo "#  SetHandler proxy:fcgi://php-fpm" >> php.conf
	echo "#</LocationMatch>" >> php.conf
	echo "#ProxyErrorOverride on" >> php.conf

	cd /etc/php-fpm.d/

#	r="; listen = 127.0.0.1:9000\n"
#	r=${r}"listen.allowed_clients = 127.0.0.1\n"
#	r=${r}"listen.owner = apache\n"
#	r=${r}"listen.group = apache\n"
#	r=${r}"listen.mode = 0660\n"
#	r=${r}"user = apache\n"
#	r=${r}"group = apache\n"
	r="listen = \/var\/run\/php-fpm\/default.sock\n"
	sed -i "s/^listen = .*/${r}/" /etc/php-fpm.d/www.conf

	sed -i "s/^pm = .*/pm = ondemand/" /etc/php-fpm.d/www.conf
	sed -i "s/^pm.start_servers = .*/pm.start_servers = 3/" /etc/php-fpm.d/www.conf
	sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = 3/" /etc/php-fpm.d/www.conf
	sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = 5/" /etc/php-fpm.d/www.conf
	sed -i "s/^php_admin_value\[error_log\]/; php_admin_value\[error_log\]/" /etc/php-fpm.d/www.conf
	sed -i "s/^php_admin_flag\[log_errors\]/; php_admin_flag\[log_errors\]/" /etc/php-fpm.d/www.conf


	sed -i "s/^#compress/compress/" /etc/logrotate.conf

	if ! grep -q "daily" /etc/logrotate.d/httpd
	then
		sed -i "s/missingok/missingok\n    daily/" /etc/logrotate.d/httpd
	fi

	if ! grep -q "/var/www/*/logs/*log" /etc/logrotate.d/httpd
	then
	  echo "/var/www/*/logs/*log {" >> /etc/logrotate.d/httpd
	  echo " missingok" >> /etc/logrotate.d/httpd
	  echo " daily" >> /etc/logrotate.d/httpd
	  echo " maxsize 50M" >> /etc/logrotate.d/httpd
	  echo " notifempty" >> /etc/logrotate.d/httpd
	  echo " sharedscripts" >> /etc/logrotate.d/httpd
	  echo " delaycompress" >> /etc/logrotate.d/httpd
	  echo " postrotate" >> /etc/logrotate.d/httpd
	  echo "  /bin/systemctl reload httpd.service > /dev/null 2>/dev/null || true" >> /etc/logrotate.d/httpd
	  echo " endscript" >> /etc/logrotate.d/httpd
	  echo "}" >> /etc/logrotate.d/httpd
	fi


	if [[ -d /var/lib/php/session ]]
	then
		echo "Папка /var/lib/php/session уже существует"
	else
		mkdir /var/lib/php/session
		chmod u+rwx,g+rwx,o-rwx /var/lib/php/session
		chgrp apache /var/lib/php/session
	fi

	if [[ -d /var/lib/php/wsdlcache ]]
	then
	   echo "Папка /var/lib/php/wsdlcache уже существует"
	else
		mkdir /var/lib/php/wsdlcache
		chmod u+rwx,g+rwx,o-rwx /var/lib/php/wsdlcache
		chgrp apache /var/lib/php/wsdlcache
	fi

	if php-fpm -t
	then
		Up
		echo -e "Конфигурационный файл ${GREEN}/etc/php-fpm.d/www.conf корректен${WHITE}"
		Down
	else
		Up
		echo -e "Ошибка в конфигурационном файле ${RED}/etc/php-fpm.d/www.conf${WHITE} . Требуется ручное вмешательство."
		echo "Скрипт остановлен."
		Down
		RemoveRim
		exit
	fi

	sed -i "s/memory_limit = .*/memory_limit = 256M/" /etc/php.ini
	sed -i "s/upload_max_filesize = .*/upload_max_filesize = 32M/" /etc/php.ini
	sed -i "s/post_max_size = .*/post_max_size = 32M/" /etc/php.ini
	sed -i "s/max_execution_time = .*/max_execution_time = 60/" /etc/php.ini
	sed -i "s/;max_input_vars = .*/max_input_vars = 20000/" /etc/php.ini
	sed -i "s/output_buffering .*/output_buffering = Off/" /etc/php.ini

	Up
	echo -e "Установлены лимиты для ${GREEN}PHP${WHITE}:"
	echo -e "memory_limit = ${GREEN}256M${WHITE}"
	echo -e "upload_max_filesize = ${GREEN}32M${WHITE}"
	echo -e "post_max_size = ${GREEN}32M${WHITE}"
	echo -e "max_execution_time = ${GREEN}60${WHITE}"
	echo -e "max_input_vars = ${GREEN}20000${WHITE}"
	Down

	systemctl enable php-fpm
	echo
	systemctl start php-fpm
	echo

	Install "htop"

	Up
	echo -e "Устанавливаем ${GREEN}время${WHITE}:"
	Down
  echo -e "Ставим ${GREEN}Московское время${WHITE}?"
  if vertical_menu "current" 2 0 5 "Да" "Нет"
  then
    mv /etc/localtime /etc/localtime.bak
    ln -s /usr/share/zoneinfo/Europe/Moscow /etc/localtime
  fi
	Up
	date
	Down

	Install unzip

	cd /var/www/html

	Up
	echo -e "Создаем хост для ответа сервера на обращения к ${GREEN}несуществующим сайтам${WHITE} 000-default"
	Down
	if [[ ! -d 000-default ]]
	then
		mkdir 000-default
	else
		echo -e  "каталог ${GREEN}000-default${WHITE} уже создан"
	fi

	cd /etc/httpd/conf.d
	echo "<VirtualHost *:80>" > 000-default.conf
	echo "ServerAdmin webmaster@localhost" >> 000-default.conf
	echo "ServerName 000-default" >> 000-default.conf
	echo "ServerAlias www.000-default" >> 000-default.conf
	echo "DocumentRoot /var/www/html/000-default" >> 000-default.conf
	echo "<Directory /var/www/html/000-default>" >> 000-default.conf
	echo "Options -Indexes +FollowSymLinks" >> 000-default.conf
	echo "AllowOverride All" >> 000-default.conf
	echo "Order allow,deny" >> 000-default.conf
	echo "allow from all" >> 000-default.conf
	echo "</Directory>" >> 000-default.conf
	echo "ServerSignature Off" >> 000-default.conf
	echo "ErrorLog /var/log/httpd/000-default-error-log" >> 000-default.conf
	echo "LogLevel warn" >> 000-default.conf
	echo "CustomLog /var/log/httpd/000-default-access-log combined" >> 000-default.conf
	echo "</VirtualHost>" >> 000-default.conf


	echo "<VirtualHost *:443>" > 000-default-ssl.conf
	echo "ServerAdmin webmaster@localhost" >> 000-default-ssl.conf
	echo "ServerName 000-default" >> 000-default-ssl.conf
	echo "ServerAlias www.000-default" >> 000-default-ssl.conf
	echo "DocumentRoot /var/www/html/000-default" >> 000-default-ssl.conf
	echo "<Directory /var/www/html/000-default>" >> 000-default-ssl.conf
	echo "Options -Indexes +FollowSymLinks" >> 000-default-ssl.conf
	echo "AllowOverride All" >> 000-default-ssl.conf
	echo "Order allow,deny" >> 000-default-ssl.conf
	echo "allow from all" >> 000-default-ssl.conf
	echo "deny from all" >> 000-default-ssl.conf
	echo "</Directory>" >> 000-default-ssl.conf
	echo "ServerSignature Off" >> 000-default-ssl.conf
	echo "ErrorLog /var/log/httpd/000-default-error-log" >> 000-default-ssl.conf
	echo "LogLevel warn" >> 000-default-ssl.conf
	echo "CustomLog /var/log/httpd/000-default-access-log combined" >> 000-default-ssl.conf
	echo "SSLCertificateFile /etc/pki/tls/certs/localhost.crt" >> 000-default-ssl.conf
	echo "SSLCertificateKeyFile /etc/pki/tls/private/localhost.key" >> 000-default-ssl.conf
	echo "</VirtualHost>" >> 000-default-ssl.conf


	cd /var/www/html/000-default
	echo "<?php phpinfo(); " > index.php

	apachectl restart

	r=$( wget -qO- ident.me )
	ipaddress=$( ip route get 1 | grep -Eo 'src [0-9\.]{1,20}' |  awk '{print $NF;exit}' )
	echo -e "Попробуйте ${GREEN}открыть этот адрес${WHITE} в своем браузере:"
	echo -e "${GREEN}http://"${ipaddress}${WHITE}
	echo

	echo "Информация о php отображается нормально?"
	if vertical_menu "current" 2 0 5 "Да" "Нет"
	then
	   rm  -f index.php
	else
		RemoveRim
	  echo "Установка завершена с ошибкой"
	  exit 1
	fi

	if  ${LocalServer}
	then
	  echo -e ${CURSORUP}"Ставим ${GREEN}Xdebug${WHITE}?${ERASEUNTILLENDOFLINE}"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      Install "php-xdebug"
      if [[ -e "/etc/php.d/15-xdebug.ini" ]]
      then
        {
          echo "xdebug.idekey = \"PHPSTORM\""
          echo "xdebug.mode = debug"
          echo "xdebug.client_port = 9003"
          echo "xdebug.discover_client_host=1"
        } >> /etc/php.d/15-xdebug.ini
      else
        echo -e "Файл ${RED}/etc/php.d/15-xdebug.ini${WHITE} не существует!"
        echo -e "Возможны ошибки при установке xdebug."
        echo -e "Продолжить установку?"
        if vertical_menu "current" 2 0 5 "Да" "Нет"
        then
          echo "Продолжаем..."
        else
          RemoveRim
          echo "Установка завершена с ошибкой"
          exit 1
        fi
      fi
    fi
    Install "telnet"
    Up
  fi

	pass=$( tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs )
	MYSQLPASS=${pass}

	cd ~

	if ! grep -q "EDITOR" ~/.bashrc
	then
		echo "export EDITOR=mcedit" >> ~/.bashrc
	fi

	cd /etc/yum.repos.d/

	if echo ${CURRENT_OS} | egrep -q "Fedora"
	then
    if [[ ${ServerArch} == "x86_64" ]]
    then
        ServerArch="amd64"
    fi
    {
    echo "# MariaDB 10.6 CentOS repository list - created 2021-09-30 08:32 UTC"
    echo "# http://downloads.mariadb.org/mariadb/repositories/"
    echo "[mariadb]"
    echo "name = MariaDB"
    echo "baseurl = http://mirror.mephi.ru/mariadb/yum/10.6/fedora${FedoraVersion}-${ServerArch}"
    echo "gpgkey=http://mirror.mephi.ru/mariadb/yum/RPM-GPG-KEY-MariaDB"
    echo "gpgcheck=1"
    } > MariaDB.repo
  else
    {
    echo "# MariaDB 10.6 CentOS repository list - created 2021-09-30 08:32 UTC"
    echo "# http://downloads.mariadb.org/mariadb/repositories/"
    echo "[mariadb]"
    echo "name = MariaDB"
    echo "baseurl = http://yum.mariadb.org/10.6/centos8-amd64"
    echo "module_hotfixes=1"
    echo "gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB"
    echo "gpgcheck=1"
    } > MariaDB.repo
  fi
	Install "MariaDB-server MariaDB-client"
	systemctl start mariadb
	systemctl enable mariadb

	Up
	echo -e "Генерируем ${GREEN}самоподписанный сертификат${WHITE} SSL на 10 лет"
	Down
	openssl req -new -days 3650 -x509  \
	-subj "/C=RU/ST=Moscow/L=Springfield/O=Dis/CN=www.example.com" \
	-nodes -out /etc/pki/tls/certs/localhost.crt \
	-keyout /etc/pki/tls/private/localhost.key

	if ! grep -q "MYSQLPASS" ~/.bashrc
	then
		Up

		echo -e "Производим настройку безопасности ${GREEN}mysql_secure_installation${WHITE}"
		Down
		sed -i '/character-set-server=utf8/d' /etc/my.cnf.d/server.cnf
		sed -i "s/^\[mysqld\]/\[mysqld\]\ncharacter-set-server=utf8/" /etc/my.cnf.d/server.cnf

mariadb-secure-installation <<EOF

n
n
y
y
y
y

EOF
	# mysql -uroot  -e "ALTER USER root@localhost IDENTIFIED VIA mysql_native_password USING PASSWORD(\"${pass}\");"

	fi

	echo -e "Ставим ${GREEN}certbot${WHITE}?"
	if vertical_menu "current" 2 0 5 "Да" "Нет"
	then
		Install "certbot python3-certbot-apache"
		echo "-----------------------------"
		echo -e "${GREEN}Настроим certbot. Введите свой email для обратной связи."
		echo -e "На этот емейл будут приходить сообщения о проблемах с сертификатами."
		echo -e "Обязательно укажите корректный email."
		echo -e "В конце сертификат для 000-default получать не нужно - просто нажмите 'c'${WHITE}"
		echo "-----------------------------"
		certbot --apache
	fi

	Up
	echo "Если есть почтовая служба - отключаем и останавливаем"
	Down
	if systemctl status postfix
	then
		systemctl stop postfix
		systemctl disable postfix
		systemctl status postfix
		Up
		echo -e "${GREEN}Почтовая служба остановлена.${WHITE}"
		Down
	fi

	Up
	echo
	echo "Делаем сервис апача автоматически перезапускаемым, в случае какого либо падения."
	echo "Сервер будет пытаться перезапустить апач каждые 3 минуты в случае падения."
	Down
	if [[ ! -d /etc/systemd/system/httpd.service.d ]]
	then
		mkdir /etc/systemd/system/httpd.service.d
	fi
	cat > /etc/systemd/system/httpd.service.d/local.conf << EOF
[Service]
Restart=always
RestartSec=180
EOF
	Up
	echo -e "Перезапускаем сервер ${GREEN}apache${WHITE} после настройки"
	Down
	systemctl daemon-reload
	systemctl restart httpd

	Up
	echo
	echo "Делаем сервис базы данных автоматически запускаемым, в случае какого либо падения."
	echo "Сервер будет пытаться перезапустить базу каждые 3 минуты в случае падения."
	Down
	if [[ ! -d /etc/systemd/system/mariadb.service.d ]]
	then
		mkdir /etc/systemd/system/mariadb.service.d
	fi
	cat > /etc/systemd/system/mariadb.service.d/local.conf << EOF
[Service]
Restart=always
RestartSec=180
EOF
	sed -i "s/^#bind-address.*$/bind-address=127.0.0.1/" /etc/my.cnf.d/server.cnf

	Up
	echo -e "Перезапускаем службу ${GREEN}баз данных${WHITE} после настройки"
	Down
	systemctl daemon-reload
	systemctl restart mariadb
	Up
	echo -e "Установка и настройка ${GREEN}MariaDB завершена.${WHITE}"
	Down

	if ! [[ -d ~/.config ]]
	then
		mkdir ~/.config
	fi
	if ! [[ -d ~/.config/mc ]]
	then
		mkdir ~/.config/mc
	fi

	cat > ~/.config/mc/hotlist << EOF
ENTRY "/etc" URL "/etc"
ENTRY "/var/www" URL "/var/www"
ENTRY "/etc/php-fpm.d" URL "/etc/php-fpm.d"
ENTRY "/etc/httpd/conf.d" URL "/etc/httpd/conf.d"
EOF

	cd ${RISH_HOME}
	if [[ -e mc.menu ]]
	then
		rm /etc/mc/mc.menu
    if  ${LocalServer}
    then
      cat mc.menu.local >> mc.menu
    fi
		cp mc.menu /etc/mc/mc.menu
	fi
	cd ..

  if systemctl status httpd.service -l --no-pager -n 3 | grep "Could not"
  then
    echo "Устанавливаем имя сервера как localhost"
    sed -i "s|#ServerName .*$|ServerName localhost|" /etc/httpd/conf/httpd.conf
    systemctl restart httpd.service
  fi

	Up
	echo
	echo -e "Для ${GREEN}root${WHITE} доступа к ${GREEN}mysql${WHITE} используются только скрипты."
	#Warning ${pass}
	echo -e "Учетная запись ${GREEN}root${WHITE} не доступна через интернет"

	RemoveRim
	echo ""
	echo ""
	echo -e "Теперь ${GREEN}создаем${WHITE} пользователя для работы с сайтом. "
	echo "Имя пользователя набирается латинскими буквами без спецсимволов, тире и точек."

	if ! grep -q "MYSQLPASS" ~/.bashrc
	then
		# устанавливаем признак выполненной настройки сервера
		echo "export MYSQLPASS="${SCRIPTVERSION} >> ~/.bashrc
		export MYSQLPASS=${SCRIPTVERSION}
	fi

	CreateUser

  echo
  echo -e "Советуем запретить авторизацию по паролю при доступе по ${GREEN}SSH${WHITE}."
  echo -e "Вы всегда сможете авторизоваться по паролю непосредственно на сервере."
  echo -e "Авторизация по паролю будет доступна, например, через KVM."
  echo -e "Запретить авторизацию по ${RED}паролю${WHITE} для SSH?"
  if vertical_menu "current" 2 0 5 "Да" "Нет"
  then
    echo -e "${CURSORUP}"
    sed -i "s|#PasswordAuthentication .*$|PasswordAuthentication no|" /etc/ssh/sshd_config
    systemctl restart sshd.service
    echo -e "Авторизация по паролю ${GREEN}запрещена${WHITE}."
  else
    echo -e "${CURSORUP}"
    echo -e "Авторизация по паролю ${RED}разрешена${WHITE}."
  fi
	echo -e "Конфигурирование сервера ${GREEN}завершено${WHITE}"
	Warning "Советуем сейчас отключиться и подключиться к серверу заново, во избежание неверной работы скриптов."

else
	options=( "Создать пользователя" \
	"Удалить пользователя" \
	"Удалить базу данных пользователя" \
	"Обновить mc.menu" \
	"Клонирование сайта" \
	"Выйти")
	Down
	echo
	echo -e "Версия ${GREEN}apache${WHITE}"
	httpd -v
	echo
	echo -e "Версия ${GREEN}PHP${WHITE}"
	php -v

	while true
	do

		vertical_menu "center" "center" 0 30 "${options[@]}"
		choice=$?

		case "$choice" in
			0)
				clear
				CreateUser
				;;
			1)
				clear
				usrs=( $( cat /etc/passwd | grep home | awk -F: '{ print $1}'   ))
				if (( ${#usrs[@]} > 0 ))
				then
					echo "Выберите пользователя для удаления из системы"
					vertical_menu "current" 2 0 30 "${usrs[@]}"
					choice=$?
					echo -e ${CURSORUP}
					if (( choice < 255 ))
					then
						echo -e "Удаляем пользователя ${GREEN}"${usrs[${choice}]}${WHITE}
						DeleteUser ${usrs[${choice}]}
					fi
				else
					echo "В системе нет ни одного пользователя"
				fi
				;;
			2)
				clear
				# проверим на предмет неудаленных баз данных
				usrs=( $( cat /etc/passwd | grep home | awk -F: '{ print $1}'   ))
				if (( ${#usrs[@]} > 0 ))
				then
					echo "Выберите пользователя для удаления его базы данных"
					vertical_menu "current" 2 0 30 "${usrs[@]}"
					choice=$?
					if (( choice < 255 ))
					then
						echo -e ${CURSORUP}"Выбран пользователь ${GREEN}${usrs[${choice}]}${WHITE}${ERASEUNTILLENDOFLINE}"
						SiteuserMysqlPass=`cat /home/${usrs[${choice}]}/.pass.txt | grep Database | awk '{ print $2}'`
						bases=( `mysql -u${usrs[${choice}]} -p${SiteuserMysqlPass}  --batch -e "SHOW DATABASES" | tail -n +2 | sed '/information_schema/d'` )
						if (( ${#bases[@]} > 0 ))
						then
							echo -e "Выберите базу данных пользователя ${RED}"${usrs[${choice}]}"${WHITE} для удаления"
							vertical_menu "current" 2 0 30 "${bases[@]}"
							choice=$?
							if (( ${choice} < 255 ))
							then
								DeleteDatabase ${bases[${choice}]}
							fi
						else
							echo "У пользователя нет баз данных"
						fi
					fi
				else
					echo "В системе нет пользователей"
				fi
				;;
			3)
				cd ${RISH_HOME}
				cd ..
				rm rish.tar.gz > /dev/null
				wget https://hika.su/rish.tar.gz
				tar -xf rish.tar.gz rish/mc.menu
				rm rish.tar.gz
				cd ${RISH_HOME}
				if [[ -e mc.menu ]]
				then
					rm /etc/mc/mc.menu
					cp mc.menu /etc/mc/mc.menu
				fi
				;;
		  4)
		    CloneSite
		    ;;
			*)
				RemoveRim
				clear
				break
				;;
		esac
	done
fi

