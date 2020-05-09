#!/bin/bash

#Вспомогательное внутри сценария
GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
WHITE='\033[0m'
SUPPORTED_OS='CentOS|Red Hat Enterprise Linux Server'

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


Info "System memory:"
free -m
echo ""

Info "Disk space:"
df -h -P -l -x tmpfs -x devtmpfs
echo ""


echo ""
echo 'Обновляем сервер? '
echo 'Настоятельно рекомендуем обновить при первом запуске.'

if ask "" Y
then
yum update -y
fi

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
   echo "После перезагрузки запустите скрипт заново командой ./ri.sh"
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
r=$r"listen = \/var\/run\/php-fpm\/default.sock\n"
r=$r"listen.allowed_clients = 127.0.0.1\n"
r=$r"listen.owner = apache\n"
r=$r"listen.group = apache\n"
r=$r"listen.mode = 0660\n"
r=$r"user = apache\n"
r=$r"group = apache\n"
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
echo "http://"$r
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

if ! grep -q "EDITOR" .bashrc
then
    echo "export EDITOR=mcedit" >> .bashrc
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
Info "При заполнении данных - главное указать страну - остальное можно не заполнять"
openssl req -new -days 3650 -x509 -nodes -out /etc/pki/tls/certs/localhost.crt -keyout /etc/pki/tls/private/localhost.key

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
echo "Сервер будет пытаться перезапустить апач каждые 3 минуты."
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
echo "Сервер будет пытаться перезапустить базу каждые 3 минуты."
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



Info "Для базы данных mysql создан следующий пароль (запишите его):"
Warning $pass
Info "В дальнейшем доступ к паролю можно получить командой"
Warning "echo \$MYSQLPASS"

Info "Конфигурирование сервера завершено"

