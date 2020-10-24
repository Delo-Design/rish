#!/bin/bash

CloneSite() {

#суффикс для доменов на локальном сервере
declare suffix="test"

server=adonis
clear

if [[ ! -e ~/.ssh/config ]]
then
  echo "Файла config не существует"
  return
fi

declare localserver=false


if [[ -z "$MYSQLPASS" ]]
then
  echo -e "Переменная ${RED}\$MYSQLPASS${WHITE} не установлена."
  return
fi

serverip=$( ip route get 1 | awk '{print $NF;exit}' )
if [[ "$serverip" =~ ^192\.168\..* ]]
then
 echo "****************************************************************"
 echo "Включен режим работы на локальном сервере "
 echo -e "При клонировании домен первого уровня будет заменен на ${GREEN}.${suffix}${WHITE}"
 echo "Суффикс можно поменять в настройках скрипта"
 echo "****************************************************************"
 localserver=true
else
 echo "*****************************************************"
 echo -e "Адрес вашего сервера: ${GREEN}${serverip}${WHITE}"
 echo "Клонирование будет осуществляться в нормальном режиме"
 echo "*****************************************************"
 localserver=false
fi

mapfile -t array < <(< ~/.ssh/config grep "Host " |  awk '{print $2}')

vertical_menu "current" 2 0 30 "${array[@]}"
choice=$?
if (( choice == 255 ))
then
  return
fi


echo -e "Список сайтов удаленного сервера ${GREEN}$server${WHITE}:"
printf "\n"
return
directory="/var/www/html"

left_x=10
top_y=7
options=( $( ssh $server ls -l $directory | grep 'drwx'| awk '{print $9}'   ))

vertical_menu "${options[@]}"
choice=$?
clear
if (( $choice == 255 ))
then
    exit
fi

sitename=${options[$choice]}

if [[ "${sitename##*.}" == "${sitename##*/}" ]]
then
   echo "Неверный выбор. Сайт должен быть как минимум доменом второго уровня."
   echo -e "Был выбран ${RED}$sitename${WHITE}"
else
   if $localserver
   then
      localsitename=${sitename%${sitename##*.}}$suffix
   else
      localsitename=$sitename
   fi
fi

echo -e "Перенос сайта ${GREEN}$sitename${WHITE} с сервера ${GREEN}${server}${WHITE} "
echo -e "В сайт ${GREEN}$localsitename${WHITE} на сервер ${GREEN}$serverip${WHITE}"

if [ -z "$sitename" ]
then
  exit
fi

ssh $server "test -e /var/www/html/"$sitename

if [ $? -ne 0 ]
then
  echo "такого сайта "$sitename" нет на удаленном сервере!"
  exit
fi
echo "-----------------"

rr=$( ssh $server grep DocumentRoot /etc/httpd/conf.d/$sitename.conf  | sed 's|.*/||' )

if [[ "$sitename" == "$rr" ]]
then
  rr=""
  echo "DocumentRoot равен папке сайта"
else
  rr="/"$rr
  echo "DocumentRoot будет установлен: "$rr
fi

ext=${sitename##*.}
name=`basename "$sitename" ".$ext"`

ee='mysql  -uroot -p${MYSQLPASS} -qfsBe'
ee=$ee' "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='"'"$sitename"'\" "
ee=$ee'2>&1'
ee=$( ssh $server $ee )
if [ ! -z $ee ]
then
  echo -e "идет создание архива базы данных ${GREEN}${sitename}${WHITE}"
  ssh $server 'mysqldump -u root -p${MYSQLPASS}' $sitename > $sitename.sql
  echo -e "Архив базы данных ${GREEN}${sitename}${WHITE} скачан"
  mysql -u root -p$MYSQLPASS -e "create database if not exists \`"$localsitename"\` CHARACTER SET utf8 COLLATE utf8_general_ci;"
  mysql -u root -p$MYSQLPASS $localsitename < $sitename".sql"
  rm $sitename".sql"
  echo -e "База данных ${GREEN}$localsitename${WHITE} перенесена"
else
  echo "базы данных у сайта нет"
fi


namearch=$name."tar.gz"

echo "-----------------"
temp="cd /var/www/html/$sitename; tar czf ../$namearch ."
echo -e "Идет создание архива сайта ${GREEN}$sitename${WHITE}"
ssh $server "$temp"
cd /var/www/html
rm -rf $localsitename
echo "Идет скачивание архива сайта"
scp $server:/var/www/html/$namearch /var/www/html
ssh $server rm /var/www/html/$namearch
mkdir -p $localsitename
tar xzf $namearch -C /var/www/html/$localsitename
rm $namearch

chown -R apache:apache $localsitename
echo -e "Архив сайта развернут в каталоге ${GREEN}$localsitename${WHITE}"

cd /etc/httpd/conf.d
rm -f ${localsitename}*

tt=$localsitename".conf"
echo "<VirtualHost *:80>" > $tt
echo " ServerAdmin webmaster@localhost" >> $tt
echo " ServerName "$localsitename >> $tt
echo " ServerAlias www."$localsitename >> $tt
echo " DocumentRoot /var/www/html/"$localsitename$rr >> $tt
echo " <Directory /var/www/html/${localsitename}${rr}>" >> $tt
echo "   Options -Indexes +FollowSymLinks" >> $tt
echo "   AllowOverride All" >> $tt
echo "   Order allow,deny" >> $tt
echo "   Allow from all" >> $tt
echo " </Directory>" >>  $tt
echo " ErrorLog /var/log/httpd/"$localsitename"-error-log" >> $tt
echo " LogLevel warn" >> $tt
echo " CustomLog /var/log/httpd/"$localsitename"-access-log combined" >> $tt
echo " ServerSignature Off" >> $tt

ttssl=$localsitename"-ssl.conf"
if $localserver
then
#SSLCertificateFile /etc/pki/tls/certs/localhost.crt
#SSLCertificateKeyFile /etc/pki/tls/private/localhost.key
   echo
   echo -e "Нужно ли установить самоподписанный ${GREEN}SSL${WHITE} сертификат на сайт?"
   if ask "" Y
   then
    echo "<IfModule mod_ssl.c>" > $ttssl
    echo "<VirtualHost *:443>" >> $ttssl
    echo " ServerAdmin webmaster@localhost" >> $ttssl
    echo " ServerName "$localsitename >> $ttssl
    echo " ServerAlias www."$localsitename >> $ttssl
    echo " DocumentRoot /var/www/html/"$localsitename$rr >> $ttssl
    echo " <Directory /var/www/html/${localsitename}${rr}>" >> $ttssl
    echo "   Options -Indexes +FollowSymLinks" >> $ttssl
    echo "   AllowOverride All" >> $ttssl
    echo "   Order allow,deny" >> $ttssl
    echo "   Allow from all" >> $ttssl
    echo " </Directory>" >>  $ttssl
    echo " ErrorLog /var/log/httpd/"$localsitename"-error-log" >> $ttssl
    echo " LogLevel warn" >> $ttssl
    echo " CustomLog /var/log/httpd/"$localsitename"-access-log combined" >> $ttssl
    echo " ServerSignature Off" >> $ttssl
    echo " SSLCertificateFile /etc/pki/tls/certs/localhost.crt" >> $ttssl
    echo " SSLCertificateKeyFile /etc/pki/tls/private/localhost.key" >> $ttssl
    echo "</VirtualHost>" >> $ttssl
    echo "</IfModule>" >> $ttssl
    echo "Сертификат установлен"
    echo
    echo "Надо ли устанавливать редирект http->https ?"
    if ask "" Y
    then
      echo "RewriteEngine on" >> $tt
      echo "RewriteCond %{SERVER_NAME} =${localsitename} [OR]" >> $tt
      echo "RewriteCond %{SERVER_NAME} =www.${localsitename}" >> $tt
      echo "RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]" >> $tt
      echo "Редирект был установлен"
    else
      echo "Редирект не был установлен"
    fi
   else
    echo
    echo "Сертификат не был установлен"
   fi
fi

echo "</VirtualHost>" >> $tt


if [ -f "/var/www/html/${localsitename}/configuration.php" ]
then
    echo
    echo -e "Сайт распознан как созданный на основе ${GREEN}Joomla${WHITE}"
    sed -i "s/\$password.*$/\$password = '${MYSQLPASS}';/" /var/www/html/${localsitename}/configuration.php
    echo "Новый пароль внесен в configuration.php"
    sed -i "s/\$db .*$/\$db = '${localsitename}';/" /var/www/html/${localsitename}/configuration.php
    echo "имя базы данных установлено в configuration.php"
    sed -i "s/\$log_path .*$/\$log_path = '\/var\/www\/html\/${localsitename}\/administrator\/logs' ;/" /var/www/html/%f/configuration.php
    echo "Путь к папке logs скорректирован"
    sed -i "s/\$tmp_path .*$/\$tmp_path = '\/var\/www\/html\/${localsitename}\/tmp' ;/" /var/www/html/${localsitename}/configuration.php
    echo "Путь к папке tmp скорректирован"
    echo
fi

echo "Перезагрузка сервера"
if apachectl configtest
then
        apachectl restart
        echo "Сервер перезагружен"
else
        echo "Сервер не был перезагружен"
fi

}