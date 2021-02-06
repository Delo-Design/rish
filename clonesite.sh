#!/bin/bash

CloneSite() {

#суффикс для доменов на локальном сервере
declare suffix="test"

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

mapfile -t servers < <(< ~/.ssh/config grep "Host " |  awk '{print $2}' | sort )

vertical_menu "current" 2 0 30 "${servers[@]}"
choice=$?
if (( choice == 255 ))
then
  return
fi


echo -e "Список сайтов удаленного сервера ${GREEN}${servers[${choice}]}${WHITE}:"
printf "\n"

local choosenserver=${servers[${choice}]}

#local sites=( $( ssh $choosenserver ls -l $directory | grep 'drwx'| awk '{print $9}'   ) )
mapfile -t sites < <(ssh $choosenserver 'ls -l /var/www/html/ /var/www/*/www/ 2>/dev/null' | grep drwx | grep -v 000-default | awk '{print  $9" ("$3")"}' | sort)

vertical_menu "current" 2 10 30 "${sites[@]}"
choice=$?

if (( choice == 255 ))
then
    return
fi

sitename=${sites[$choice]}
local remoteuser
remoteuser=$( echo "${sitename}" | cut -d "(" -f2 | cut -d ")" -f1 )
if [[ "root" == "${remoteuser}" ]]
then
    remoteuser="apache"
fi

local remotesitename
remotesitename="${sitename%% *}"

if [[ "${remotesitename##*.}" == "${remotesitename##*/}" ]]
then
   echo "Неверный выбор. Сайт должен быть как минимум доменом второго уровня."
   echo -e "Был выбран ${RED}${remotesitename}${WHITE}"
   return
else
   if $localserver
   then
      localsitename=${remotesitename%${remotesitename##*.}}$suffix
   else
      localsitename=$remotesitename
   fi
fi


echo -e "Перенос сайта ${GREEN}${remotesitename}${WHITE} пользователя ${GREEN}${remoteuser}${WHITE} с сервера ${GREEN}${choosenserver}${WHITE} "

if [ -z "$sitename" ]
then
  return
fi

local siteusers
echo
echo "Выберите пользователя на текущем сервере, куда надо копировать сайт"
mapfile -t siteusers < <(ls -l /var/www 2>/dev/null | grep drwx | grep -v cgi-bin |  grep -v html | awk '{print  $9}' | sort)

vertical_menu "current" 2 10 30 "${siteusers[@]}"
choice=$?
if (( choice == 255 ))
then
    return
fi
local localuser=${siteusers[$choice]}

echo -e ${CURSORUP}"В сайт ${GREEN}$localsitename${WHITE} пользователя ${GREEN}${localuser}${WHITE} на сервер ${GREEN}$serverip${WHITE}${ERASEUNTILLENDOFLINE}"

local pathtosite
if [[ ${remoteuser} == "apache" ]]
then
  pathtosite="/var/www/html/"${remotesitename}
else
  pathtosite="/var/www/${remoteuser}/www/${remotesitename}"
fi

ssh ${choosenserver} "test -e "${pathtosite}

if [ $? -ne 0 ]
then
  echo "такого сайта ${remotesitename} нет на удаленном сервере!"
  return
fi
echo "-----------------"

rr=$( ssh $choosenserver 'grep DocumentRoot /etc/httpd/conf.d/'${remotesitename}'.conf'  | sed 's|.*/||' )

if [[ "${remotesitename}" == "${rr}" ]]
then
  documentroot=""
  echo "DocumentRoot равен папке сайта"
else
  documentroot="/"$rr
  echo "DocumentRoot будет установлен: "${documentroot}
fi


ext=${remotesitename##*.}

ee='mysql  -uroot -p${MYSQLPASS} -qfsBe'
ee=$ee' "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='"'"${remotesitename}"'\" "
ee=$ee'2>&1'
ee=$( ssh $choosenserver $ee )
if [ -n "$ee" ]
then
  echo -e "идет создание архива базы данных ${GREEN}${remotesitename}${WHITE}"
  ssh $choosenserver 'mysqldump -u root -p$'{MYSQLPASS} $remotesitename > $remotesitename.sql
  echo -e "Архив базы данных ${GREEN}${remotesitename}${WHITE} скачан"
  if mysql -u root -p${MYSQLPASS} -e "CREATE DATABASE IF NOT EXISTS \`${localsitename}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  then
    echo -e "База mysql с именем ${GREEN}${localsitename}${WHITE} создана"
    mysql -uroot -p${MYSQLPASS} -e "GRANT ALL PRIVILEGES ON \`${localsitename}\`.* TO '${localuser}'@'localhost';"
    mysql -uroot -p${MYSQLPASS} -e "FLUSH PRIVILEGES;"
    echo -e "Права на базу выданы пользователю ${GREEN}${localuser}${WHITE}"
  else
     echo -e ${RED}"Произошла ошибка"${WHITE}
  fi
  mysql -u root -p$MYSQLPASS $localsitename < $remotesitename".sql"
  rm $remotesitename".sql"
  echo -e "База данных ${GREEN}$localsitename${WHITE} перенесена"
else
  echo "базы данных у сайта нет"
fi

namearch=$remotesitename."tar.gz"

echo "-----------------"
temp1="cd ${pathtosite}; rm -f ../$namearch"
temp2="cd ${pathtosite}; tar czf ../$namearch ."
echo -e "Идет создание архива сайта ${GREEN}$remotesitename${WHITE} пользователя ${GREEN}${remoteuser}${WHITE}"
ssh $choosenserver "$temp1"
ssh $choosenserver "$temp2"

local  pathtolocalsite="/var/www/${localuser}/www/${localsitename}"
local pathtolocaluser="/var/www/${localuser}/www"
cd ${pathtolocaluser} || return
rm -rf $namearch

echo "Идет скачивание архива сайта"
scp $choosenserver:${pathtosite}/../$namearch ${pathtolocaluser}
ssh $choosenserver rm ${pathtosite}/../$namearch

if [[ -d "${pathtolocalsite}" ]]
then
  rm -rf  "${pathtolocalsite}"
  echo -e "Старое содержимое локального сайта ${GREEN}${localsitename}${WHITE} удалено "
  mkdir -p "$localsitename"
  echo -e "Создан новый сайт ${GREEN}${localsitename}${WHITE} пользователя ${GREEN}${localuser}${WHITE} "
else
  echo -e "Создан новый сайт ${GREEN}${localsitename}${WHITE} пользователя ${GREEN}${localuser}${WHITE} "
  mkdir -p "$localsitename"
fi
tar xzf $namearch -C ${pathtolocaluser}/$localsitename
rm $namearch

chown -R ${localuser}:${localuser} $localsitename
echo -e "Архив сайта развернут в каталоге ${GREEN}${localuser}/${localsitename}${WHITE}"

cd /etc/httpd/conf.d
rm -f ${localsitename}*

{
echo "<VirtualHost *:80>"
echo "ServerAdmin webmaster@localhost"
echo "ServerName "$localsitename
echo "ServerAlias www."$localsitename
echo "DocumentRoot /var/www/${localuser}/www/"${localsitename}${documentroot}
echo '<Proxy "unix:/var/run/php-fpm/'${localuser}'.sock|fcgi://php-fpm">'
echo 'ProxySet disablereuse=on connectiontimeout=3 timeout=60'
echo '</Proxy>'
echo '<FilesMatch \.php$>'
echo 'SetHandler proxy:fcgi://php-fpm'
echo '</FilesMatch>'
echo 'DirectoryIndex index.php index.html'
echo "<Directory /var/www/${localuser}/www/${localsitename}${documentroot}>"
echo "  Options -Indexes +FollowSymLinks"
echo "  AllowOverride All"
echo "  Order allow,deny"
echo "  Allow from all"
echo "</Directory>"
echo "ErrorLog /var/www/${localuser}/logs/${localsitename}-error-log"
echo "LogLevel warn"
echo "CustomLog /var/www/${localuser}/logs/${localsitename}-access-log combined"
echo "ServerSignature Off"
} >> $localsitename".conf"

ttssl=$localsitename"-ssl.conf"
if $localserver
then
#SSLCertificateFile /etc/pki/tls/certs/localhost.crt
#SSLCertificateKeyFile /etc/pki/tls/private/localhost.key
   echo
   echo -e "Нужно ли установить самоподписанный ${GREEN}SSL${WHITE} сертификат на сайт?"
   if vertical_menu "current" 2 0 5 "Да" "Нет"
   then
      openssl req -x509 -out $localsitename.crt -keyout $localsitename.key \
        -newkey rsa:2048 -nodes -sha256 -days 3650 -out /etc/pki/tls/certs/${localsitename}.crt -keyout /etc/pki/tls/private/${localsitename}.key \
       -subj "/CN=${localsitename}" -extensions EXT -config <( \
       printf "[dn]\nCN=${localsitename}\n[req]\ndistinguished_name = dn\n[EXT]\nsubjectAltName=DNS:${localsitename}, DNS:www.${localsitename}\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth")
     {
      echo "<IfModule mod_ssl.c>"
      echo "<VirtualHost *:443>"
      echo "ServerAdmin webmaster@localhost"
      echo "ServerName "$localsitename
      echo "ServerAlias www."$localsitename
      echo "DocumentRoot /var/www/${localuser}/www/"${localsitename}${documentroot}
      echo '<Proxy "unix:/var/run/php-fpm/'${localuser}'.sock|fcgi://php-fpm">'
      echo 'ProxySet disablereuse=on connectiontimeout=3 timeout=60'
      echo '</Proxy>'
      echo '<FilesMatch \.php$>'
      echo 'SetHandler proxy:fcgi://php-fpm'
      echo '</FilesMatch>'
      echo 'DirectoryIndex index.php index.html'
      echo "<Directory /var/www/${localuser}/www/${localsitename}${documentroot}>"
      echo "  Options -Indexes +FollowSymLinks"
      echo "  AllowOverride All"
      echo "  Order allow,deny"
      echo "  Allow from all"
      echo "</Directory>"
      echo "ErrorLog /var/www/${localuser}/logs/${localsitename}-error-log"
      echo "LogLevel warn"
      echo "CustomLog /var/www/${localuser}/logs/${localsitename}-access-log combined"
      echo "ServerSignature Off"
      echo "SSLCertificateFile /etc/pki/tls/certs/${localsitename}.crt"
      echo "SSLCertificateKeyFile /etc/pki/tls/private/${localsitename}.key"
      echo "</VirtualHost>"
      echo "</IfModule>"
     } >> $ttssl

    echo "Сертификат установлен"
    echo
    echo "Надо ли устанавливать редирект http->https ?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      echo "RewriteEngine on" >> $localsitename".conf"
      echo "RewriteCond %{SERVER_NAME} =${localsitename} [OR]" >> $localsitename".conf"
      echo "RewriteCond %{SERVER_NAME} =www.${localsitename}" >> $localsitename".conf"
      echo "RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]" >> $localsitename".conf"
      echo "Редирект был установлен"
    else
      echo "Редирект не был установлен"
    fi
   else
    echo
    echo "Сертификат не был установлен"
   fi
fi

echo "</VirtualHost>" >> $localsitename".conf"

if [ -f "${pathtolocalsite}/configuration.php" ]
then
    echo
    DATABASEPASS=$( cat /home/${localuser}/.pass.txt | grep Database | awk '{ print $2}' )
    echo -e "Сайт распознан как созданный на основе ${GREEN}Joomla${WHITE}"
    sed -i "s/\$password.*$/\$password = '${DATABASEPASS}';/" "${pathtolocalsite}/configuration.php"
    echo "Новый пароль внесен в configuration.php"
    sed -i "s/\$db .*$/\$db = '${localsitename}';/" "${pathtolocalsite}/configuration.php"
    echo -e "имя базы данных ${GREEN}${localsitename}${WHITE} установлено в configuration.php"
		sed -i "s/\$user.*$/\$user =  '${localuser}';/" "${pathtolocalsite}/configuration.php"
		echo -e "Имя пользователя базы данных установлено ${GREEN}${localuser}${WHITE}"
    sed -i "s|\$log_path .*$|\$log_path = '${pathtolocalsite}/administrator/logs';|" "${pathtolocalsite}/configuration.php"
    echo "Путь к папке logs скорректирован"
    sed -i "s|\$tmp_path .*$|\$tmp_path = '${pathtolocalsite}/tmp';|" "${pathtolocalsite}/configuration.php"
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