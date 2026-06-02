#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
WHITE='\033[0m'
MYSQLPASS="2"

source /root/rish/windows.sh

directory="$1"
site_name="$2"
site_path="${directory}/${site_name}"

clear
if [[ ! -d "$site_path" ]]; then
  echo "Это не является папкой сайта. Удаление прервано."
  exit
fi

echo -e "Вы действительно хотите удалить сайт ${LRED}${site_name}${WHITE}?"
vertical_menu "current" 2 0 5 "Нет" "Да"
choice=$?
if [[ "$choice" == "255" || "$choice" == "0" ]]; then
  exit
fi

echo "Проверяем наличие сертификата у сайта"
if command -v certbot >/dev/null 2>&1; then
  if certbot certificates --cert-name "$site_name" | grep "$site_name" &>/dev/null; then
    echo "У сайта есть SSL сертификат"
    echo "Производим отзыв сертификата"
    certbot revoke --cert-path "/etc/letsencrypt/live/${site_name}/cert.pem"
  else
    echo "У сайта нет SSL сертификата"
  fi
fi

rm /etc/httpd/conf.d/"${site_name}"* &>/dev/null
if [[ $? -eq 0 ]]; then
  echo -e "Файлы виртуальных хостов ${GREEN}/etc/httpd/conf.d/${site_name}${WHITE} удалены."
else
  echo -e "Файлы виртуального хоста ${RED}удалить не удалось${WHITE}."
fi

if apachectl configtest; then
  systemctl reload httpd
  echo "Сервер перезагружен."
else
  echo -e "Сервер не был перезагружен. ${RED}Ошибка${WHITE} в конфигурации апача."
  echo -e "Удаление сайта ${RED}прервано${WHITE}"
  exit
fi

rm -R "$site_path"
if [[ $? -eq 0 ]]; then
  echo -e "Папка сайта ${GREEN}${site_name}${WHITE} удалена"
else
  echo -e "В процессе удаления папки сайта ${RED}${site_name}${WHITE} возникли проблемы"
fi

user_name="${directory#/var/www/}"
user_name="${user_name%/www*}"
rm /var/www/"${user_name}"/logs/"${site_name}"* &>/dev/null
if [[ $? -eq 0 ]]; then
  echo -e "Логи сайта ${GREEN}удалены${WHITE}."
else
  echo -e "Логи сайта ${RED}удалены не были${WHITE}."
fi

if [[ -n "$(mariadb -uroot -p${MYSQLPASS} -qfsBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${site_name}'" 2>&1)" ]]; then
  echo "У сайта есть база данных"
  if mariadb-admin -f -u root -p${MYSQLPASS} drop "$site_name"; then
    echo -e "База данных ${GREEN}${site_name}${WHITE} удалена"
  else
    echo -e "При удалении базы данных ${RED}${site_name}${WHITE} произошли ${RED}ошибки${WHITE}"
  fi
fi

rm /etc/pki/tls/private/"${site_name}"* &>/dev/null
if [[ $? -eq 0 ]]; then
  echo "Удалены локальные ssl сертификаты сайта"
fi

rm /etc/pki/tls/certs/"${site_name}"* &>/dev/null
if [[ $? -eq 0 ]]; then
  echo "Удалены локальные ssl сертификаты сайта"
fi

source /root/rish/create_hotlist.sh
create_hotlist

echo "Убедитесь что для сайта не установлены задания cron (удалить можно командой crontab -e):"
crontab -l
echo "Нажмите Enter"
vertical_menu "current" 2 0 5 "Да"
