#!/bin/bash

#Вспомогательное внутри сценария
GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
WHITE='\033[0m'
SUPPORTED_OS='CentOS|Red Hat Enterprise Linux Server'
size=$(stty size)
lines=${size% *}
columns=${size#* }

clear
if `type lsb_release > /dev/null 2>&1`; then
	CURRENT_OS=`lsb_release -d -s`
	echo -e "Ваша версия Linux: ${RED}$CURRENT_OS${WHITE}"
elif [ -f /etc/system-release ]; then
	CURRENT_OS=`head -1 /etc/system-release`
	echo -e "Ваша версия Linux: ${GREEN}$CURRENT_OS${WHITE}"
	echo
elif [ -f /etc/issue ]; then
	CURRENT_OS=`head -2 /etc/issue`
	echo -e "Ваша версия Linux: ${RED}$CURRENT_OS${WHITE}"
else
	echo -e "${RED}Невозможно определить вашу версию Linux${WHITE}"
	exit 1
fi
if ! echo $CURRENT_OS | egrep -q "$SUPPORTED_OS"
then
   echo -e "Ваш дистрибутив Linux ${RED}не поддерживается${WHITE}"
   exit 1
fi




#максимальная ширина окна
declare -i MaxWindowWidth=25
ReturnKey=""
declare -i left_x
declare -i top_y
declare -i MaxWindowHeight=7
declare -i ShiftWindow

GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
WHITE='\033[0m'


# little helpers for terminal print control and key input
ESC=$( printf "\033")
cursor_blink_on()  { printf "$ESC[?25h"; }
cursor_blink_off() { printf "$ESC[?25l"; }
cursor_to()        { printf "$ESC[$1;${2:-1}H"; }
print_option()     { printf "$1 "; }
print_selected_on()   { printf "$ESC[7m"; }
print_selected_off()   { printf "$ESC[27m"; }
get_cursor_row()   { IFS=';' read -sdR -p $'\E[6n' ROW COL; echo ${ROW#*[}; }
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
	local idx=0

	cursor_to $(($top_y )) $(($left_x))
	printf "┌"
	repl "─" $(( $MaxWindowWidth + 3 ))
	printf "┐"

    for opt
	do
		cursor_to $(($top_y + $idx + 1)) $(($left_x))
	 	print_option "│  $opt"
		let temp=$MaxWindowWidth-${#opt}
		repl " " $temp
		printf "│"
		((idx++))
    done

	cursor_to $(($top_y + $idx +1)) $(($left_x))
	printf "└"
	repl "─" $(( $MaxWindowWidth + 3 ))
	printf "┘"
}

function vertical_menu {

	menu_items=( "$@" )

    # initially print empty new lines (scroll down if at bottom of screen)
    for opt
	do
		if (( "${#opt}" > "${MaxWindowWidth}" ))
		then
			MaxWindowWidth=${#opt}
		fi
    done
	let MaxWindowWidth=$MaxWindowWidth+2

	refresh_window "$@"

    # ensure cursor and input echoing back on upon a ctrl+c during read -s
    trap "cursor_blink_on; stty echo; printf '\n'; exit" 2
    cursor_blink_off

    local selected=0
    local previous_selected=0
    while true; do
        # print options by overwriting the last lines
        local idx=0

		cursor_to $(($top_y + $previous_selected + 1)) $(($left_x))
		print_option "│  ${menu_items[$previous_selected]}"
		let temp=$MaxWindowWidth-${#menu_items[$previous_selected]}
		repl " " $temp
		printf "│"

		cursor_to $(($top_y + $selected + 1)) $(($left_x))
		printf "│ "
		print_selected_on
		printf " ${menu_items[$selected]}"
		let temp=$MaxWindowWidth-${#menu_items[$selected]}
		repl " " $temp
		print_selected_off
		printf " │"


        # user key control
        ReturnKey=`key_input`
        case ${ReturnKey} in
            enter) break;;
            esc) selected=255; break;;
            up)    previous_selected=$selected;
            	   ((selected--));
                   if [ $selected -lt 0 ]; then selected=$(($# - 1)); fi;;
            down)  previous_selected=$selected;
            	   ((selected++));
                   if [ $selected -ge $# ]; then selected=0; fi;;
        esac
    done

    # cursor position back to normal
    cursor_to $lastrow
    printf "\n"
    cursor_blink_on

    return $selected
}

Infon() {
    printf "\033[1;32m$@\033[0m"
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
            Info "Firewall уже открыт"
        else
            Info "Открываем firewall"
            firewall-cmd --zone=public --permanent --add-service=http
            firewall-cmd --zone=public --permanent --add-service=https
            firewall-cmd --reload

        fi

    else
        Info "Firewall не установлен"
    fi
}

ask() {
    # https://gist.github.com/davejamesmiller/1965569
    local prompt default reply

    if [ "${2:-}" = "Y" ]; then
        prompt="Y/n или Д/н"
        default=Y
    elif [ "${2:-}" = "N" ]; then
        prompt="y/N или д/Н"
        default=N
    else
        prompt="y/n"
        default=
    fi

    while true; do

        # Ask the question (not using "read -p" as it uses stderr not stdout)
        if [ -z "$1" ]
        then
          echo -n "[$prompt]"
        else
          echo -n "$1 [$prompt] "
        fi

        # Read the answer (use /dev/tty in case stdin is redirected from somewhere else)
        read reply </dev/tty

        # Default?
        if [ -z "$reply" ]; then
            reply=$default
        fi

        # Check if the reply is valid
        case "$reply" in
            Y*|y*|Д*|д*) return 0 ;;
            N*|n*|Н*|н*) return 1 ;;
        esac

    done
}


Install() {
if ! rpm -q $@ >/dev/null 2>&1
then
  Info "Ставим ${@}"
  if yum -y install $@
  then
   Info "$@ установлен"
  else
   Error "Установить $@ не удалось"
   exit 1
  fi
  echo
else
  Info "$@ уже установлен"
fi

}

CreateUser() {
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
	echo -e "Пароль для баз данных ${NAME}: ${GREEN}"${pass}${WHITE}
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
	cp /etc/php-fpm.d/www.conf  /etc/php-fpm.d/${NAME}.conf
	#меняем имя пула.
	#[www]->[siteuser]
	sed -i "s/^\[www\]/\[${NAME}\]/" /etc/php-fpm.d/${NAME}.conf
	# удаляем старое
	sed -i '/^user = apache/d' /etc/php-fpm.d/${NAME}.conf
	sed -i '/^group = apache/d' /etc/php-fpm.d/${NAME}.conf

	#меняем user = apache -> user = siteuser
	#group = apache -> group = siteuser

	#listen.owner = siteuser
	#listen.group = siteuser
	sed -i "s/^listen.owner = apache/listen.owner = ${NAME}/" /etc/php-fpm.d/${NAME}.conf
	sed -i "s/^listen.group = apache/listen.group = ${NAME}/" /etc/php-fpm.d/${NAME}.conf
	r="listen = \/var\/run\/php-fpm\/${NAME}.sock\n"
	r=${r}"user = ${NAME}\n"
	r=${r}"group = ${NAME}"
	sed -i "s/^listen = \/var\/run\/php-fpm\/default.sock/${r}/" /etc/php-fpm.d/${NAME}.conf

	#если надо - меняем режим работы php на ondemand
	#в этом же файле в конце меняем
	#php_value[session.save_path]    = /var/lib/php/session/siteuser
	#php_value[soap.wsdl_cache_dir]  = /var/lib/php/wsdlcache/siteuser
	sed -i "s/^php_value\[session.save_path\].*$/php_value\[session.save_path\] = \/var\/www\/${NAME}\/session/" /etc/php-fpm.d/${NAME}.conf
	sed -i "s/^php_value\[soap.wsdl_cache_dir\].*$/php_value\[soap.wsdl_cache_dir\] = \/var\/lib\/${NAME}\/wsdlcache/" /etc/php-fpm.d/${NAME}.conf

	#и создаем папки и устанавливаем их владельцем siteuser
	mkdir /var/www/${NAME}/session
	mkdir /var/www/${NAME}/wsdlcache
	chown ${NAME}:${NAME} /var/www/${NAME}/session
	chown ${NAME}:${NAME} /var/www/${NAME}/wsdlcache

	#Архивируем конфигурацию апача по умолчанию
	if [[ -e /etc/httpd/conf.d/php.conf ]]
	then
		mv /etc/httpd/conf.d/php.conf /etc/httpd/conf.d/php.conf.bak
	fi

	if ! php-fpm -t
	then
		echo "Ошибка в настройках. PHP-FPM не был перезагружен"
	else
		systemctl restart php-fpm
		echo "PHP-FPM был перезагружен"
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
	mysql -uroot -p${MYSQLPASS} -e "CREATE USER ${NAME}@localhost IDENTIFIED BY '${pass2}';"
}

DeleteDatabase() {
	   echo -e "Вы хотите удалить базу данных ${LRED}${1}${WHITE}?"
		if ! ask "" N
		then
		  echo "База данных не была удалена"
		  return 1
		fi
		if mysqladmin -f -u root -p${MYSQLPASS} drop ${1}
		then
		   echo -e "База данных ${GREEN}${1}${WHITE} удалена"
		else
		   echo -e "При удалении базы данных ${RED}${1}${WHITE} произошли ${RED}ошибки${WHITE}"
		fi
}
DeleteUser() {
	#если папка не пуста, то отказываться удалять пользователя
	if [[ ! -z `ls -A /var/www/${1}/www` ]]
	then
		echo "У пользователя есть неудаленные сайты. Вначале удалите их."
		echo -e -n ${RED}
		cd /var/www/${1}/www
		#выводим директории
		ls -d */ | cut -f1 -d'/'
		#и файлы
		echo -e -n ${LRED}
		find ./ -maxdepth 1 -type f -print0 | cut -f2 -d'/'
		echo -e ${WHITE}
		return 1
	fi
	#проверим на предмет неудаленных баз данных
	SiteuserMysqlPass=`cat /home/${1}/.pass.txt | grep Database | awk '{ print $2}'`
	bases=( `mysql -u$USER -p$tt  --batch -e "SHOW DATABASES" | tail -n +3` )
	if (( ${#bases[@]} > 0 ))
	then
		echo "У пользователя есть неудаленные базы данных:"
		for i in "${bases[@]}"; do
		  echo ${i}
		done
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
	mysql -uroot -p${MYSQLPASS} -e "DROP USER IF EXISTS ${1}@localhost;"
}


Info "System memory:"
free -m
echo ""

Info "Disk space:"
df -h -P -l -x tmpfs -x devtmpfs
echo ""

if ! grep -q "MYSQLPASS" ~/.bashrc
then
	if yum check-update > /dev/null
	then
	  echo "Сервер уже обновлен"
	else
	  echo ""
	  echo 'Обновляем сервер? '
	  echo 'Настоятельно рекомендуем обновить при первом запуске.'

	  if ask "" Y
	  then
	  yum update -y
	  fi
	fi
fi

if ! grep -q "MYSQLPASS" ~/.bashrc
then
# we think that it is the first run of the script
	clear
	if localectl status | grep -q UTF-8
	then
	 	echo
	 	Info "Кодировка консоли уже выбрана правильно."
	else
		localectl set-locale LANG=en_US.UTF-8
		echo
		Warning "\nБыла установлена кодировка UTF-8 для консоли. Надо перезагрузить сервер. \nВведите команду reboot.\n"
		echo "После перезагрузки запустите скрипт заново командой ./ri.sh"
		exit 0
	fi

	if command -v sestatus >/dev/null 2>&1
	then
	 if [ -f /etc/selinux/config ]
	  then
	  if [ `cat /etc/selinux/config | grep "SELINUX=enforcing"` ]
	  then

	   sed -i "s/SELINUX=enforcing/SELINUX=disabled/" /etc/selinux/config
	   echo
	   Error "Включен selinux."
	   echo "Мы установили значение в конфигурационном файле для отключения selinux"
	   echo "Вам остается только выполнить перезагрузку сервера."
	   echo "Убедитесь, что в следующих строках установлено значение SELINUX=disabled "
	   echo "Если, значение установлено верно, вам остается только выполнить команду reboot"
	   head /etc/selinux/config
	   echo
	   Warning "Введите команду reboot"
	   tet=$(pwd)
	   echo "После перезагрузки запустите скрипт заново командой ${tet}./ri.sh"
	   exit 0

	  fi
	 else
	  echo "Конфигурационный файл selinux /etc/selinux/config не доступен,"
	  echo "Хотя система selinux на компьютере присутствует"
	  exit 0
	 fi
	fi

	clear

	Install mc

	Install cronie

	Install logrotate

	Install epel-release

	cd /etc/yum.repos.d
	ver="codeit.el"`rpm -q --qf "%{VERSION}" $(rpm -q --whatprovides redhat-release)`".repo"
	if [ -f ${ver} ]
	then
	  rm -f $ver
	fi

	wget https://repo.codeit.guru/${ver}
	Install "httpd mod_ssl"

	systemctl enable httpd
	echo
	systemctl start httpd
	echo

	OpenFirewall

	Info "Перезапускаем apache"
	sed -i "s/LoadModule lbmethod_heartbeat_module/#LoadModule lbmethod_heartbeat_module/" /etc/httpd/conf.modules.d/00-proxy.conf
	sed -i "s/##/#/" /etc/httpd/conf.modules.d/00-proxy.conf

	rm -f /usr/share/httpd/noindex/index.html
	cat > /usr/share/httpd/noindex/index.html << EOF
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">

<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
	<head>
		<title>Test Page for the Apache HTTP Server on Fedora</title>
		<meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
		<style type="text/css">
			/*<![CDATA[*/
			body {
				background-color: #fff;
				color: #000;
				font-size: 0.9em;
				font-family: sans-serif,helvetica;
				margin: 0;
				padding: 0;
			}
			:link {
				color: #c00;
			}
			:visited {
				color: #c00;
			}
			a:hover {
				color: #f50;
			}
			h1 {
				text-align: center;
				margin: 0;
				padding: 0.6em 2em 0.4em;
				background-color: #3d5c0e;
				color: #fff;
				font-weight: normal;
				font-size: 1.75em;
				border-bottom: 2px solid #000;
			}
			h2 {
				font-size: 1.1em;
				font-weight: bold;
			}
			hr {
				display: none;
			}
			.content {
				padding: 1em 5em;
			}
			.content-columns {
				position: relative;
				padding-top: 1em;
			}
			.content-column-left {
				width: 47%;
				padding-right: 3%;
				float: left;
				padding-bottom: 2em;
			}
			.content-column-left hr {
				display: none;
			}
			.content-column-right {
				/* Values for IE/Win; will be overwritten for other browsers */
				width: 47%;
				padding-left: 3%;
				float: left;
				padding-bottom: 2em;
			}
			.content-columns>.content-column-left, .content-columns>.content-column-right {
				/* Non-IE/Win */
			}
			img {
				border: 2px solid #fff;
				padding: 2px;
				margin: 2px;
			}
			a:hover img {
				border: 2px solid #f50;
			}
			/*]]>*/
		</style>
	</head>

	<body>
		<h1>RISH Test Page</h1>

		<div class="content">
			<div class="content-middle">
				<p>This page is used to test the proper operation of the Apache HTTP server after it has been installed. If you can read this page, it means that the web server installed at this site is working properly, but has not yet been configured.</p>
			</div>
			<hr />

			<div class="content-columns">
				<div class="content-column-left">
					<h2>If you are a member of the general public:</h2>

					<p>The fact that you are seeing this page indicates that the website you just visited is either experiencing problems, or is undergoing routine maintenance.</p>

					<p>If you would like to let the administrators of this website know that you've seen this page instead of the page you expected, you should send them e-mail. In general, mail sent to the name "webmaster" and directed to the website's domain should reach the appropriate person.</p>

					<p>For example, if you experienced problems while visiting www.example.com, you should send e-mail to "webmaster@example.com".</p>

					<p>Fedora is a distribution of Linux, a popular computer operating system. It is commonly used by hosting companies because it is free, and includes free web server software. Many times, they do not set up their web server correctly, and it displays this "test page" instead of the expected website.</p>

					<p>Accordingly, please keep these facts in mind:</p>
					<ul>
					<li>Neither the Fedora Project or Red Hat has any affiliation with any website or content hosted from this server (unless otherwise explicitly stated).</li>
					<li>Neither the Fedora Project or Red Hat has "hacked" this webserver, this test page is an included component of Apache's httpd webserver software.</li>
					</ul>

					<p>For more information about RISH, please visit the <a href="https://github.com/Delo-Design/rish">RISH Project website</a>.</p>
					<hr />
				</div>

				<div class="content-column-right">
					<h2>If you are the website administrator:</h2>

					<p>You may now add content to the directory <code>/var/www/html/</code>. Note that until you do so, people visiting your website will see this page, and not your content. To prevent this page from ever being used, follow the instructions in the file <code>/etc/httpd/conf.d/welcome.conf</code>.</p>

					<div class="logos">
						<p>You are free to use the images below on Apache and Fedora powered HTTP servers. Thanks for using Apache and Fedora!</p>

						<p><a href="https://httpd.apache.org/"><img src="/icons/apache_pb2.gif" alt="[ Powered by Apache ]"/></a> <a href="https://getfedora.org/"><img src="/icons/poweredby.png" alt="[ Powered by Fedora ]" width="88" height="31" /></a></p>
					</div>
				</div>
			</div>
		</div>
	</body>
</html>
EOF
	apachectl restart
	echo
	Info "Ставим репозитарий Remi Collet для установки php"

	cd /etc/yum.repos.d
	remi="remi-release-7.rpm"
	if [ -f ${remi} ]
	then
	  rm -f $remi
	fi

	wget http://rpms.remirepo.net/enterprise/remi-release-7.rpm
	rpm -Uvh remi-release-7*.rpm
	Install yum-utils

	default=6
	while true; do
			# Ask the question (not using "read -p" as it uses stderr not stdout)
			Info "Какую версию php будем ставить?"
			echo "1) 5.4"
			echo "2) 5.6"
			echo "3) 7.0"
			echo "4) 7.1"
			echo "5) 7.2"
			Warning "6) 7.3 (выбран по умолчанию - достаточно нажать Enter)"

			# Read the answer (use /dev/tty in case stdin is redirected from somewhere else)
			read reply </dev/tty

			# Default?
			if [ -z "$reply" ]; then
				reply=$default
			fi

			# Check if the reply is valid
			case "$reply" in
				1*) reply=54 ; break ;;
				2*) reply=56 ; break ;;
				3*) reply=70 ; break ;;
				4*) reply=71 ; break ;;
				5*) reply=72 ; break ;;
				6*) reply=73 ; break ;;
			esac
	done

	clear
	Warning "Выбран php версии ${reply}"

	yum-config-manager --disable remi-php54 > /dev/null
	yum-config-manager --disable remi-php56 > /dev/null
	yum-config-manager --disable remi-php70 > /dev/null
	yum-config-manager --disable remi-php71 > /dev/null
	yum-config-manager --disable remi-php72 > /dev/null
	yum-config-manager --disable remi-php73 > /dev/null

	yum-config-manager --enable remi-php${reply} > /dev/null

	if (( $reply > 70 ))
	then
		Install "php-fpm php-opcache php-cli php-gd php-mbstring php-mysqlnd php-xml php-soap php-xmlrpc"
	else
		Install "php-fpm php-opcache php-cli php-gd php-mbstring php-mcrypt php-mysqlnd php-xml php-soap php-xmlrpc"
	fi

	Warning "Установлен php версии ${reply}"
	php -v

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

	r="; listen = 127.0.0.1:9000\n"
	r=${r}"listen = \/var\/run\/php-fpm\/default.sock\n"
	r=${r}"listen.allowed_clients = 127.0.0.1\n"
	r=${r}"listen.owner = apache\n"
	r=${r}"listen.group = apache\n"
	r=${r}"listen.mode = 0660\n"
	r=${r}"user = apache\n"
	r=${r}"group = apache\n"
	sed -i "s/^listen = 127.0.0.1:9000/${r}/" /etc/php-fpm.d/www.conf

	sed -i "s/^pm.start_servers = 5/pm.start_servers = 3/" /etc/php-fpm.d/www.conf
	sed -i "s/^pm.min_spare_servers = 5/pm.min_spare_servers = 3/" /etc/php-fpm.d/www.conf
	sed -i "s/^pm.max_spare_servers = 35/pm.max_spare_servers = 5/" /etc/php-fpm.d/www.conf
	sed -i "s/^php_admin_value\[error_log\]/; php_admin_value\[error_log\]/" /etc/php-fpm.d/www.conf
	sed -i "s/^php_admin_flag\[log_errors\]/; php_admin_flag\[log_errors\]/" /etc/php-fpm.d/www.conf

	sed -i "s/^#compress/compress/" /etc/logrotate.conf

	if ! grep -q "daily" /etc/logrotate.d/httpd
	then
		sed -i "s/missingok/missingok\n    daily/" /etc/logrotate.d/httpd
	fi



	if [ -d /var/lib/php/session ]
	then
		echo "Папка /var/lib/php/session уже существует"
	else
		mkdir /var/lib/php/session
		chmod u+rwx,g+rwx,o-rwx /var/lib/php/session
		chgrp apache /var/lib/php/session
	fi

	if [ -d /var/lib/php/wsdlcache ]
	then
	   echo "Папка /var/lib/php/wsdlcache уже существует"
	else
		mkdir /var/lib/php/wsdlcache
		chmod u+rwx,g+rwx,o-rwx /var/lib/php/wsdlcache
		chgrp apache /var/lib/php/wsdlcache
	fi

	if php-fpm -t
	then
		Info "Конфигурационный файл /etc/php-fpm.d/www.conf корректен"
	else
		Error "Ошибка в конфигурационном файле /etc/php-fpm.d/www.conf . Требуется ручное вмешательство."
	fi

	sed -i "s/memory_limit = 128M/memory_limit = 256M/" /etc/php.ini
	sed -i "s/upload_max_filesize = 2M/upload_max_filesize = 32M/" /etc/php.ini
	sed -i "s/post_max_size = 8M/post_max_size = 32M/" /etc/php.ini
	sed -i "s/max_execution_time = 30/max_execution_time = 60/" /etc/php.ini
	sed -i "s/;max_input_vars = 1000/max_input_vars = 10000/" /etc/php.ini

	Info "Установлены лимиты для php:"
	Info "memory_limit = 256M"
	Info "upload_max_filesize = 32M"
	Info "post_max_size = 32M"
	Info "max_execution_time = 60"
	Info "max_input_vars = 10000"

	systemctl enable php-fpm
	echo
	systemctl start php-fpm
	echo

	Install "htop"

	Info "Устанавливаем московское время:"
	mv /etc/localtime /etc/localtime.bak
	ln -s /usr/share/zoneinfo/Europe/Moscow /etc/localtime
	date

	Install unzip

	cd /var/www/html

	if [ ! -d 000-default ]
	then
		mkdir 000-default
	else
		Info "каталог 000-default уже создан"
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
	Info "Попробуйте открыть этот адрес в своем браузере:"
	echo "http://"${r}
	echo

	if ask "Информация о php отображается нормально?" Y
	then
	   rm  -f index.php
	else
	   echo "Установка завершена с ошибкой"
	   exit 1
	fi


	pass=$( tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs )

	cd ~

	if ! grep -q "EDITOR" ~/.bashrc
	then
		echo "export EDITOR=mcedit" >> ~/.bashrc
	fi


	cd /etc/yum.repos.d/

	echo "# MariaDB 10.3 CentOS repository list - created 2018-10-22 16:03 UTC" > MariaDB.repo
	echo "# http://downloads.mariadb.org/mariadb/repositories/" >> MariaDB.repo
	echo "[mariadb]" >> MariaDB.repo
	echo "name = MariaDB" >> MariaDB.repo
	echo "baseurl = http://yum.mariadb.org/10.3/centos7-amd64" >> MariaDB.repo
	echo "gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB" >> MariaDB.repo
	echo "gpgcheck=1" >> MariaDB.repo

	Install "MariaDB-server MariaDB-client"
	systemctl start mariadb
	systemctl enable mariadb

	Info "Генерируем самоподписанный сертификат SSL на 10 лет"
	openssl req -new -days 3650 -x509  \
	-subj "/C=RU/ST=Moscow/L=Springfield/O=Dis/CN=www.example.com" \
	-nodes -out /etc/pki/tls/certs/localhost.crt \
	-keyout /etc/pki/tls/private/localhost.key

	clear

	if [ -z "$MYSQLPASS" ]
	then
		Warning "Добавляем пароль базы данных в файл автозапуска"
		if grep -q "MYSQLPASS" ~/.bashrc
		then
			sed -i "s/export MYSQLPASS=.*$/export MYSQLPASS=${pass}/" ~/.bashrc
		else
			echo "export MYSQLPASS="${pass} >> ~/.bashrc
		fi
			Info "Для базы данных mysql создан следующий пароль (запишите его):"
			Warning $pass
mysql_secure_installation <<EOF

y
$pass
$pass
y
y
y
y
EOF

	fi


	Info "На локальных системах certbot не нужен."
	if ask "Ставим certbot?" Y
	then
		Install "certbot python2-certbot-apache"
		echo "-----------------------------"
		echo "Настроим certbot. Введите свой email для обратной связи."
		echo "На этот емейл будут приходить сообщения о проблемах с сертификатами."
		echo "Обязательно укажите корректный email."
			echo "В конце сертификат для 000-default получать не нужно - просто нажмите 'c'"
			echo "-----------------------------"
		certbot --apache
	fi

	echo "Если есть почтовая служба - отключаем и останавливаем"
	if systemctl status postfix
	then
		systemctl stop postfix
		systemctl disable postfix
		systemctl status postfix
		echo -e "${GREEN}Почтовая служба остановлена.${WHITE}"
	fi

	echo
	echo "Делаем сервис апача автоматически перезапускаемым, в случае какого либо падения."
	echo "Сервер будет пытаться перезапустить апач каждые 3 минуты в случае падения."
	if [ ! -d /etc/systemd/system/httpd.service.d ]
	then
		mkdir /etc/systemd/system/httpd.service.d
	fi
	cat > /etc/systemd/system/httpd.service.d/local.conf << EOF
[Service]
Restart=always
RestartSec=180
EOF
	echo -e "Перезапускаем апач после настройки"
	systemctl daemon-reload
	systemctl restart httpd


	echo
	echo "Делаем сервис базы данных автоматически запускаемым, в случае какого либо падения."
	echo "Сервер будет пытаться перезапустить базу каждые 3 минуты в случае падения."
	if [ ! -d /etc/systemd/system/mariadb.service.d ]
	then
		mkdir /etc/systemd/system/mariadb.service.d
	fi
	cat > /etc/systemd/system/mariadb.service.d/local.conf << EOF
[Service]
Restart=always
RestartSec=180
EOF
	sed -i "s/^#bind-address.*$/bind-address=127.0.0.1/" /etc/my.cnf.d/server.cnf

	echo -e "Перезапускаем службу баз данных после настройки"
	systemctl daemon-reload
	systemctl restart mariadb
	echo -e "${GREEN}Установка и настройка MariaDB завершена.${WHITE}"

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


	Info "Для базы данных mysql создан следующий пароль (запишите его):"
	Warning $pass
	Info "В дальнейшем доступ к паролю можно получить командой"
	Warning "echo \$MYSQLPASS"


	echo ""
	echo "Теперь создаем пользователя для работы с сайтом. "
	echo "Имя пользователя набирается латинскими буквами без спецсимволов, тире и точек."
	CreateUser

	Info "Конфигурирование сервера завершено"

else
	clear
	left_x=1
	top_y=7
	options=( "Создать пользователя" \
	"Удалить пользователя" \
	"Удалить базу данных пользователя"
	"Выйти")
	ml=MaxWindowWidth

	for elmnt in "${options[@]}"
	do
		if (( ${#elmnt} > ${ml} ))
		then
			(( $ml=${#elmnt} ))
		fi
	done

	(( ml=${ml} + 2 ))
	(( left_x=(${columns}-${ml})/2 ))
	(( top_y= (${lines}-${#options[@]})/2-1 ))

	while true
	do
		let MaxWindowWidth=25
		vertical_menu "${options[@]}"
		choice=$?
		clear
		case "$choice" in
			0)
				CreateUser
				;;
			1)
				usrs=( $( cat /etc/passwd | grep home | awk -F: '{ print $1}'   ))
				if (( ${#usrs[@]} > 0 ))
				then
					echo "Выберите пользователя для удаления из системы"
					vertical_menu "${usrs[@]}"
					choice=$?
					if (( choice < 255 ))
					then
						clear
						echo -e "Удаляем пользователя ${GREEN}"${usrs[${choice}]}${WHITE}
						DeleteUser ${usrs[${choice}]}
					fi
				else
					echo "В системе нет ни одного пользователя"
				fi
				;;
			2)
				#проверим на предмет неудаленных баз данных
				usrs=( $( cat /etc/passwd | grep home | awk -F: '{ print $1}'   ))
				if (( ${#usrs[@]} > 0 ))
				then
					echo "Выберите пользователя для удаления его базы данных"
					vertical_menu "${usrs[@]}"
					choice=$?
					if (( choice < 255 ))
					then
						clear
						SiteuserMysqlPass=`cat /home/${usrs[${choice}]}/.pass.txt | grep Database | awk '{ print $2}'`
						bases=( `mysql -u${usrs[${choice}]} -p$SiteuserMysqlPass  --batch -e "SHOW DATABASES" | tail -n +3` )
						if (( ${#bases[@]} > 0 ))
						then
							echo -e "Выберите базу данных пользователя ${RED}"${usrs[${choice}]}"${WHITE} для удаления"
							vertical_menu "${bases[@]}"
							choice=$?
							if (( ${choice} < 255 ))
							then
								DeleteDatabase ${bases[${choice}]}
							fi
						else
							echo "У пользователя нет баз данных"
						fi
					fi
				fi

				;;
			*)
				echo "Выход"
				break
				;;
		esac
	done

fi

