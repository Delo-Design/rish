#!/bin/bash
LGREEN='\033[1;32m'
AddServer() {
  clear
  local regex="^[a-zA-Z0-9]+([-\.][a-zA-Z0-9]+)*(\.[a-zA-Z]{2,})?$|^[a-zA-Z0-9]+$"
  server_name=
  while true; do
    # Запрос IP-адреса у пользователя
    read -p "Введите IP-адрес нового сервера или нажмите Enter для выхода: " ip_address

    # Проверка на пустой ввод - выход из скрипта
    if [[ -z "$ip_address" ]]; then
      echo -e -n ${WHITE}${CURSORUP}${ERASEUNTILLENDOFLINE}
      return
    fi

    # Проверка IP-адреса на доступность с помощью пинга
    if ping -c 1 -W 2 "$ip_address" &>/dev/null; then
      echo -e "IP-адрес ${GREEN}$ip_address${WHITE} доступен."
      break
    else
      echo -e "IP-адрес ${RED}$ip_address${WHITE} недоступен. Попробуйте ввести другой адрес."
    fi
  done
  echo "Теперь нужно выбрать имя сервера."
  echo "Имя сервера имеет смысл только для вас и содержит латинские символы и цифры."
  echo "Имя можно выбрать по своему усмотрению."
  echo
  echo -e -n "${WHITE}Введите имя сервера (Enter для выхода):${GREEN}"
  read -e -p " " server_name
  while true; do
    if [[ -z "$server_name" ]]; then
      echo -e -n ${WHITE}${CURSORUP}${ERASEUNTILLENDOFLINE}
      return 1
    fi
    # Проверяем корректность начального имени сайта
    if [[ "$server_name" =~ $regex ]]; then
      echo -e "${WHITE}Имя сервера ${GREEN}$server_name${WHITE} введено корректно."
      if grep -q "$server_name" /root/.ssh/config; then
        echo -e "Этот сервер уже существует в списке, выберите другой."
        echo -e -n "Введите корректное имя сервера:${GREEN}"
        read -e -p " " server_name
        continue # Пропускаем текущую итерацию цикла
      fi
      break
    else
      echo -e "${WHITE}Имя сервера ${RED}$server_name${WHITE} некорректное. "
      echo -e -n "Введите корректное имя (Enter для выхода):${GREEN}"
      read -e -p " " server_name
    fi
  done
  comment=${server_name}
  echo -e -n "${WHITE}Укажите комментарий для ключа:${GREEN}"
  read -e -p " " -i "$comment" comment
  echo -e ${WHITE}
  ssh-keygen -t ed25519 -C "$comment" -f ~/.ssh/${server_name}-key -N ''
  {
    echo
    echo "Host ${server_name}"
    echo "  Hostname ${ip_address}"
    echo "  User root"
    echo "  Compression yes"
    echo "  IdentityFile ~/.ssh/${server_name}-key"
  } >>~/.ssh/config
  echo "Пожалуйста, скопируйте следующую команду и вставьте её в терминал удалённого сервера после подключения:"
  echo -e "${LGREEN}echo '$(cat ~/.ssh/${server_name}-key.pub)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys${WHITE}"
  echo "После этого можете продолжить работу."
  echo

  # Сортируем файл config по алфавиту
  # Путь к файлу конфигурации SSH
  config_file="$HOME/.ssh/config"
  temp_file="$HOME/.ssh/temp_config"
  sorted_file="$HOME/.ssh/config.sorted"

  # Создаем резервную копию файла конфигурации
  cp "$config_file" "${config_file}.bak"

  # Создаем временный файл, преобразуем все многострочные записи в однострочные
  awk 'BEGIN {
    first = 1;  # Флаг для отслеживания первой записи
}
{
    if ($1 == "Host") {
        if (!first) {
            printf "\n\n";  # Добавляем два перевода строки только если это не первая запись
        }
        first = 0;  # Сбрасываем флаг первой записи после первой обработки
        printf "%s", $0;  # Печатаем заголовок Host без начального перевода строки
    } else {
        # Удаляем начальные пробелы и табуляции, заменяем внутренние пробелы на один пробел
        gsub(/^[ \t]+|[ \t]+$/, "", $0);
        gsub(/[ \t]+/, " ", $0);
        printf "@%s", $0;  # Добавляем разделитель @
    }
} END {print "";}' "$config_file" >"$temp_file"

  # Удаление всех двойных переводов строк (пустых строк), которые могли появиться
  sed '/^$/d' "$temp_file" >"$sorted_file"

  # Сортировка строк
  sort "$sorted_file" -o "$sorted_file"

  # Преобразование обратно в многострочный формат
  awk 'BEGIN {FS="@"} {
    for (i = 1; i <= NF; i++) {
        if (i == 1) {
            print $i;  # Печать заголовка Host
        } else if (length($i) > 0) {
            print "    " $i;  # Добавление отступа и печать строки
        }
    }
    print "";  # Добавляем пустую строку после каждого блока для разделения
}' "$sorted_file" >"$config_file"

  # Очистка временных файлов
  rm -f "$temp_file" "$sorted_file"

}
CloneSite() {

  # Суффикс для доменов на локальном сервере
  declare suffix="test"
  local count
  local onlydatabase=$1

  clear
  if [[ $onlydatabase ]]; then
    echo "Клонируем только базу данных."
  fi

  source /root/rish/rish_config.sh

  if [[ -z "$MYSQLPASS" ]]; then
    echo -e "Переменная ${RED}\$MYSQLPASS${WHITE} не установлена."
    return
  fi

  serverip=$(ip route get 1 | grep -Eo 'src [0-9\.]{1,16}' | awk '{print $NF;exit}')
  if ${LocalServer}; then
    echo "──────────────────────────────────────────────────────────────────"
    echo -e "При клонировании домен первого уровня будет заменен на ${GREEN}.${suffix}${WHITE}"
    echo "Суффикс можно поменять в настройках скрипта"
    echo "──────────────────────────────────────────────────────────────────"
  else
    echo "────────────────────────────────────────────────────────"
    echo -e "Адрес вашего сервера: ${GREEN}${serverip}${WHITE}"
    echo "Клонирование будет осуществляться в нормальном режиме"
    echo "────────────────────────────────────────────────────────"
  fi

  if [[ ! -e ~/.ssh/config ]]; then
    touch ~/.ssh/config
  fi

  while true; do
    mapfile -t servers < <(<~/.ssh/config grep "Host " | awk '{print $2}' | sort)
    count=${#servers[@]}
    servers+=("Добавить сервер")
    echo "Выберите сервер для подключения:"
    vertical_menu "current" 2 0 30 "${servers[@]}"
    choice=$?
    if ((choice == 255)); then
      echo -e ${CURSORUP}"Отказ от клонирования."${ERASEUNTILLENDOFLINE}
      return
    fi
    if ((choice < count)); then
      break
    fi
    AddServer
  done

  local choosenserver=${servers[${choice}]}

  ssh -q -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${choosenserver} 'exit 0'
  if (($? == 255)); then
    echo -e "Подключиться к серверу ${LRED}${choosenserver}${WHITE} невозможно."
    return
  fi

  echo -e "Список сайтов удаленного сервера ${GREEN}${choosenserver}${WHITE}:"
  printf "\n"

  #local sites=( $( ssh $choosenserver ls -l $directory | grep 'drwx'| awk '{print $9}'   ) )
  mapfile -t sites < <(ssh $choosenserver 'ls -l /var/www/*/www/ 2>/dev/null' | grep drwx | grep -v 000-default | awk '{print  $9" ("$3")"}' | sort)

  vertical_menu "current" 2 10 30 "${sites[@]}"
  choice=$?
  if ((choice == 255)); then
    return
  fi

  sitename=${sites[$choice]}
  local remoteuser
  remoteuser=$(echo "${sitename}" | cut -d "(" -f2 | cut -d ")" -f1)

  local remotesitename
  remotesitename="${sitename%% *}"

  if [[ "${remotesitename##*.}" == "${remotesitename##*/}" ]]; then
    echo "Неверный выбор. Сайт должен быть как минимум доменом второго уровня."
    echo -e "Был выбран ${RED}${remotesitename}${WHITE}"
    return
  else
    if $LocalServer; then
      localsitename=${remotesitename%${remotesitename##*.}}$suffix
    else
      localsitename=$remotesitename
    fi
  fi

  echo -e "Перенос сайта ${GREEN}${remotesitename}${WHITE} пользователя ${GREEN}${remoteuser}${WHITE} с сервера ${GREEN}${choosenserver}${WHITE} "

  if [ -z "$sitename" ]; then
    return
  fi

  local siteusers
  echo
  echo "Выберите пользователя на текущем сервере, куда надо копировать сайт"
  mapfile -t siteusers < <(ls -l /var/www 2>/dev/null | grep drwx | grep -v cgi-bin | grep -v html | awk '{print  $9}' | sort)

  vertical_menu "current" 2 10 30 "${siteusers[@]}"
  choice=$?
  if ((choice == 255)); then
    return
  fi
  local localuser=${siteusers[$choice]}

  echo -e -n "${WHITE}Подтвердите имя сайта для клонирования:${GREEN}"
  read -e -p " " -i "$localsitename" site_name
  localsitename=$site_name

  echo -e ${CURSORUP}${CURSORUP}${CURSORUP}${ERASEUNTILLENDOFLINE}${WHITE}"В сайт ${GREEN}$localsitename${WHITE} пользователя ${GREEN}${localuser}${WHITE} на сервер ${GREEN}$serverip${WHITE}${ERASEUNTILLENDOFLINE}"
  echo -e " "${ERASEUNTILLENDOFLINE}
  echo -e " "${ERASEUNTILLENDOFLINE}
  local pathtosite

  pathtosite="/var/www/${remoteuser}/www/${remotesitename}"

  ssh ${choosenserver} "test -e "${pathtosite}

  if [ $? -ne 0 ]; then
    echo "такого сайта ${remotesitename} нет на удаленном сервере!"
    return
  fi

  rr=$(ssh $choosenserver 'grep DocumentRoot /etc/httpd/conf.d/'${remotesitename}'.conf' | sed 's|.*/||')

  if [[ "${remotesitename}" == "${rr}" ]]; then
    documentroot=""
    echo -e "DocumentRoot равен папке сайта"${ERASEUNTILLENDOFLINE}
  else
    documentroot="/"$rr
    echo -e "DocumentRoot будет установлен: "${documentroot}${ERASEUNTILLENDOFLINE}
  fi

  ext=${remotesitename##*.}

  ee='mysql  -uroot -p${MYSQLPASS} -qfsBe'
  ee=$ee' "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='"'${remotesitename}'\" "
  ee=$ee'2>&1'
  ee=$(ssh $choosenserver $ee)
  if [ -n "$ee" ]; then
    echo -e "идет создание архива базы данных ${GREEN}${remotesitename}${WHITE}"
    ssh $choosenserver 'mysqldump -u root -p$'{MYSQLPASS} $remotesitename >$remotesitename.sql
    echo -e "Архив базы данных ${GREEN}${remotesitename}${WHITE} скачан"
    if mysql -u root -p${MYSQLPASS} -e "CREATE DATABASE IF NOT EXISTS \`${localsitename}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
      echo -e "База mysql с именем ${GREEN}${localsitename}${WHITE} создана"
      mysql -uroot -p${MYSQLPASS} -e "GRANT ALL PRIVILEGES ON \`${localsitename}\`.* TO '${localuser}'@'localhost';"
      mysql -uroot -p${MYSQLPASS} -e "FLUSH PRIVILEGES;"
      echo -e "Права на базу выданы пользователю ${GREEN}${localuser}${WHITE}"
    else
      echo -e ${RED}"Произошла ошибка"${WHITE}
    fi
    mysql -u root -p$MYSQLPASS $localsitename <$remotesitename".sql"
    rm $remotesitename".sql"
    echo -e "База данных ${GREEN}$localsitename${WHITE} перенесена"
  else
    echo "базы данных у сайта нет"
  fi

  if [[ $onlydatabase ]]; then
    return
  fi

  namearch=$remotesitename."tar.gz"

  echo
  temp1="cd ${pathtosite}; rm -f ../$namearch"
  temp2="cd ${pathtosite}; tar czf ../$namearch ."
  echo -e "Идет создание архива сайта ${GREEN}$remotesitename${WHITE} пользователя ${GREEN}${remoteuser}${WHITE}"
  ssh $choosenserver "$temp1"
  ssh $choosenserver "$temp2"

  local pathtolocalsite="/var/www/${localuser}/www/${localsitename}"
  local pathtolocaluser="/var/www/${localuser}/www"
  cd ${pathtolocaluser} || return
  rm -rf $namearch

  echo "Идет скачивание архива сайта"
  scp $choosenserver:${pathtosite}/../$namearch ${pathtolocaluser}
  ssh $choosenserver rm ${pathtosite}/../$namearch

  if [[ -d "${pathtolocalsite}" ]]; then
    rm -rf "${pathtolocalsite}"
    echo -e "Старое содержимое локального сайта ${GREEN}${localsitename}${WHITE} удалено "
    mkdir -p "$localsitename"
    echo -e "Создан новый сайт ${GREEN}${localsitename}${WHITE} пользователя ${GREEN}${localuser}${WHITE} "
  else
    echo -e "Создан новый сайт ${GREEN}${localsitename}${WHITE} пользователя ${GREEN}${localuser}${WHITE} "
    mkdir -p "$localsitename"
  fi
  echo -e "Началось разархивирование сайта на локальном компьютере ${GREEN}${localsitename}${WHITE}."
  tar xzf $namearch -C ${pathtolocaluser}/$localsitename
  rm $namearch

  chown -R ${localuser}:${localuser} $localsitename
  echo -e "Архив сайта развернут в каталоге ${GREEN}${localuser}/${localsitename}${WHITE}"

  mapfile -t installed_versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
  echo
  echo -e "Выберите нужную версию ${GREEN}PHP${WHITE} из доступных."
  echo
  vertical_menu "current" 1 0 10 "${installed_versions[@]}"
  local ret=$?
  local selected_php
  if ((ret == 255)); then
    selected_php=${installed_versions[0]}
  else
    selected_php=${installed_versions[${ret}]}
  fi

  echo -e "${CURSORUP}Выбрана версия ${GREEN}${selected_php}${WHITE}"

  if [[ ! -f "/etc/opt/remi/${selected_php}/php-fpm.d/${localuser}.conf" ]]; then
    # Если пул для этой версии PHP еще не был создан, то создаем
    echo
    echo -e "Выберите режим работы PHP для пользователя ${GREEN}${localuser}${WHITE}:"
    vertical_menu "current" 2 0 5 "ondemand - оптимально расходует память" "dynamic - более оперативно реагирует на запросы"
    ret=$?
    local php_mode
    if ((ret == 0)); then
      php_mode="ondemand"
    else
      php_mode="dynamic"
    fi
    {
      echo "[${localuser}]"
      echo "listen = /var/opt/remi/${selected_php}/run/php-fpm/${localuser}.sock"
      echo "user = ${localuser}"
      echo "group = ${localuser}"
      echo "listen.owner = ${localuser}"
      echo "listen.group = ${localuser}"
      echo ""
      echo "listen.allowed_clients = 127.0.0.1"
      echo "pm = ${php_mode}"
      echo "pm.max_children = 20"
      echo "pm.start_servers = 3"
      echo "pm.min_spare_servers = 3"
      echo "pm.max_spare_servers = 5"
      echo "pm.process_idle_timeout = 10s"
      echo ";slowlog = /var/www/${localuser}/slow.log"
      echo ";request_slowlog_timeout = 15s"
      echo "php_value[session.save_handler] = files"
      echo "php_value[session.save_path] = /var/www/${localuser}/session"
      echo "php_value[soap.wsdl_cache_dir] = /var/www/${localuser}/wsdlcache"
    } >"/etc/opt/remi/${selected_php}/php-fpm.d/${localuser}.conf"

    if [[ -f "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" ]]; then
      mv "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf" "/etc/opt/remi/${selected_php}/php-fpm.d/www.conf.old"
    fi

    echo -e "Перезапускаем ${GREEN}${selected_php}-php-fpm${WHITE} для активации версии ${GREEN}${selected_php}${WHITE}?"

    if /opt/remi/${selected_php}/root/usr/sbin/php-fpm -t; then
      if systemctl restart "${selected_php}-php-fpm"; then
        echo -e "Версия ${GREEN}${selected_php}${WHITE} корректно перезапущена."
        echo
      else
        echo
        echo -e "Ошибка при перезапуске ${RED}${selected_php}-php-fpm${WHITE}. Проверьте журналы для диагностики."
        echo
      fi
    else
      echo
      echo -e "Версия ${RED}${selected_php}${WHITE} имеет проблемы в конфигурационных файлах."
      echo -e "Сервис ${RED}не был перезапущен${WHITE} и продолжает работать."
      echo
      systemctl status "${selected_php}-php-fpm"
    fi

  fi

  cd /etc/httpd/conf.d
  rm -f ${localsitename}*

  {
    echo "<VirtualHost *:80>"
    echo "ServerAdmin webmaster@localhost"
    echo "ServerName ${localsitename}"
    echo "ServerAlias www.${localsitename}"
    echo "DocumentRoot /var/www/${localuser}/www/${localsitename}${documentroot}"
    echo ""
    echo "<FilesMatch \.php$>"
    echo "    SetHandler \"proxy:unix:/var/opt/remi/${selected_php}/run/php-fpm/${localuser}.sock|fcgi://localhost\""
    echo "</FilesMatch>"
    echo ""
    echo "DirectoryIndex index.php index.html"
    echo ""
    echo "<Directory /var/www/${localuser}/www/${localsitename}${documentroot}>"
    echo "    Options -Indexes +FollowSymLinks"
    echo "    AllowOverride All"
    echo "    Require all granted"
    echo "</Directory>"
    echo ""
    echo "ServerSignature Off"
    echo "ErrorLog /var/www/${localuser}/logs/${localsitename}-error-log"
    echo "LogLevel warn"
    echo "CustomLog /var/www/${localuser}/logs/${localsitename}-access-log combined"
    echo "</VirtualHost>"

  } >>$localsitename".conf"

  ttssl=$localsitename"-ssl.conf"
  if $LocalServer; then
    #SSLCertificateFile /etc/pki/tls/certs/localhost.crt
    #SSLCertificateKeyFile /etc/pki/tls/private/localhost.key
    echo
    echo -e "Нужно ли установить самоподписанный ${GREEN}SSL${WHITE} сертификат на сайт?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      {
        echo "[req]"
        echo "distinguished_name = req_distinguished_name"
        echo "x509_extensions = v3_req"
        echo "prompt = no"
        echo "[req_distinguished_name]"
        echo "CN = ${localsitename}"
        echo "[v3_req]"
        echo "keyUsage = critical, digitalSignature, keyAgreement"
        echo "extendedKeyUsage = serverAuth"
        echo "subjectAltName = @alt_names"
        echo "[alt_names]"
        echo "DNS.1 = www.${localsitename}"
        echo "DNS.2 = ${localsitename}"
      } >rish_temp_file_for_creating_selfsigned_cert.txt
      openssl req -x509 -nodes \
        -newkey rsa:2048 \
        -keyout /etc/pki/tls/private/${localsitename}.key \
        -out /etc/pki/tls/certs/${localsitename}.crt \
        -sha256 \
        -days 3650 \
        -subj "/CN=${localsitename}" \
        -config rish_temp_file_for_creating_selfsigned_cert.txt
      rm -f rish_temp_file_for_creating_selfsigned_cert.txt

      cp $localsitename".conf" $ttssl
      sed -i 's/<VirtualHost \*:\s*80>/<VirtualHost *:443>/g' "$ttssl"
      sed -i "/<\/VirtualHost>/i ServerSignature Off\nSSLCertificateFile /etc/pki/tls/certs/${localsitename}.crt\nSSLCertificateKeyFile /etc/pki/tls/private/${localsitename}.key" "$ttssl"

      echo "Сертификат установлен"
      echo
    else
      echo
      echo "Сертификат не был установлен"
    fi
  fi

  if [ -f "${pathtolocalsite}/configuration.php" ]; then
    echo
    DATABASEPASS=$(cat /home/${localuser}/.pass.txt | grep Database | awk '{ print $2}')
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
  if apachectl configtest; then
    systemctl reload httpd
    echo "Сервер перезагружен"
  else
    echo "Сервер не был перезагружен"
  fi
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}
