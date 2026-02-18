#!/bin/bash
  clear
  GREEN='\033[0;32m'
  LGREEN='\033[1;32m'
  LWHITE='\033[1;37m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  WHITE='\033[0m'

function check_certificate() {
    local DOMAIN=$1
    local PORT=443 # Установка стандартного порта 443
    local CERT_INFO
    CERT_INFO=$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:${PORT}" 2>/dev/null | openssl x509 -noout -text 2>/dev/null)

    if [ -n "$CERT_INFO" ]; then
        local COMMON_NAMES
        COMMON_NAMES=$(echo "$CERT_INFO" | grep -o "DNS:[^ ,]*" | sed 's/DNS://g')
        local DOMAIN_FOUND=false

        for CN in $COMMON_NAMES; do
            if [ "$CN" = "$DOMAIN" ]; then
                DOMAIN_FOUND=true
                break
            fi
        done

        if $DOMAIN_FOUND; then
            echo -e -n "${GREEN}https://${WHITE}"
        else
            echo -e -n "${RED}https://${WHITE}"
        fi
    else
        echo -n " http://"
    fi
}
function check_certificate_expiration() {
    local DOMAIN=$1
    local PORT=443
    local CERT
    CERT=$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:${PORT}" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null)

    if [ -n "$CERT" ]; then
        local END_DATE
        END_DATE=$(echo "$CERT" | cut -d'=' -f2)
        local FORMATTED_END_DATE
        FORMATTED_END_DATE=$(date -d "${END_DATE}" +"%d %B %Y")
        local END_DATE_TS
        END_DATE_TS=$(date -d "${END_DATE}" +%s)
        local CURRENT_DATE_TS
        CURRENT_DATE_TS=$(date +%s)

        local DAYS_LEFT=$(((END_DATE_TS - CURRENT_DATE_TS) / 86400))
        printf "SSL %4s дней" "${DAYS_LEFT}"
    else
        printf "%13s" "-"
    fi
}
unicode_printf() {
  local field_width="$1"
  local unicode_string="$2"
  local string_length
  local formatted_string
  # Вычисляем количество символов в строке
  string_length=$(echo -n "$unicode_string" | awk '{print length}')
  # Вычисляем количество пробелов для заполнения
  local padding=$((field_width - string_length))
  # Если строка короче заданной ширины поля, добавляем пробелы
  for ((i=1; i<=padding; i++)); do
    formatted_string+=" "
  done
  # Добавляем пробелы справа от строки
  unicode_string+="$formatted_string"
  # Выводим отформатированную строку
  echo -n "$unicode_string"
}

get_php_version() {
    local DOMAIN=$1
    local CONF_FILE="/etc/httpd/conf.d/${DOMAIN}.conf"

    if [ -f "$CONF_FILE" ]; then
        local PHP_VERSION
        PHP_VERSION=$(grep -oP 'SetHandler\s+"proxy:unix:/var/opt/remi/php\K[0-9]+' "$CONF_FILE")
        if [ -n "$PHP_VERSION" ]; then
            echo "php ${PHP_VERSION}"
        else
            echo "-"
        fi
    else
        echo "-"
    fi
}

CheckIP() {
  clear
  echo "Что значат цвета IP:"
  echo -e "${RED}Красный цвет${WHITE} – сайт недоступен (проблемы с доменом)"
  echo -e "${GREEN}Зеленый цвет${WHITE} – все ок, сайт доступен по IP адресу этого сервера"
  echo -e "Белый цвет – сайт доступен по другому IP адресу"
  echo

  local myip="("$(ip route get 1 | grep -Eo 'src [0-9\.]{1,20}' | awk '{print $NF;exit}')")"
  echo -e "Адрес этого сервера: ${GREEN}${myip}${WHITE}"

  echo "───────────────────────────────────────────"
  for file in /var/www/*; do
    if [ -d "$file" ]; then
      local SiteUser="${file##*/}"
      if [[ ${SiteUser} == "cgi-bin" ]]; then
        continue
      fi
      if [[ ${SiteUser} == "html" ]]; then
        continue
      fi
      echo -e "${YELLOW}${SiteUser}${WHITE}:"
      for PathToSiteName in ${file}/www/*; do
        if [ -d "$PathToSiteName" ]; then
          local SiteName="${PathToSiteName##*/}"
          local CONF_FILE="/etc/httpd/conf.d/${SiteName}.conf"

          if [ -f "$CONF_FILE" ]; then
            if curl -I http://"$SiteName" &>/dev/null; then
              local ip
              ip=$(ping -c 1 $SiteName | grep PING | awk '{ print $3 }')
              if [[ "$myip" == "$ip" ]]; then
                printf "   ${GREEN}%-19s${WHITE}" "$ip"
              else
                printf "   %-19s" "$ip"
              fi
              check_certificate "$SiteName"
              if [[ "$SiteName" =~ (xn\-\-) ]]
              then
                unicode_domain=$(idn2 -d "$SiteName")
              else
                unicode_domain=$SiteName
              fi
              echo -e -n " ${LGREEN}"
              unicode_printf 32 "$unicode_domain"
              echo -e -n " ${WHITE}│ "
              check_certificate_expiration "$SiteName"
            else
              printf "   %-27s" " "
              if [[ "$SiteName" =~ (xn\-\-) ]]
              then
                unicode_domain=$(idn2 -d "$SiteName")
              else
                unicode_domain=$SiteName
              fi
              echo -e -n " ${RED}"
              unicode_printf 32 "$unicode_domain"
              echo -e -n " ${WHITE}"
              printf "              "
            fi
            if [ -f "${PathToSiteName}"/administrator/manifests/files/joomla.xml ]; then
              JoomlaVersion=$(cat "${PathToSiteName}"/administrator/manifests/files/joomla.xml | grep "<version>.*</version>" | sed -rn 's/.*>([0-9.]+)<.*/\1/p')
              printf " │ Joomla %8s" "${JoomlaVersion}"
            else
              printf " │ %15s" "-"
            fi
            PHP_VERSION=$(get_php_version "$SiteName")
            printf " │ %s" "${PHP_VERSION}"
            FOLDER_SIZE_MB=$(du -sm "${PathToSiteName}" | awk '{print $1}' | sed ':a;s/\([^0-9.][0-9]\+\|^[0-9]\+\)\([0-9]\{3\}\)/\1\ \2/g;ta')
            printf " │ ${LWHITE}%9s ${WHITE}Mb" "${FOLDER_SIZE_MB} "
            echo
          else
            printf "   %-19s" " "
            input_variable="папка ${RED}${SiteName}${WHITE} не сайт"

            # Убираем управляющие символы для подсчета длины строки
            plain_text=$(echo -e "$input_variable" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')

            # Вычисляем длину строки без учета управляющих символов
            plain_length=${#plain_text}

            # Выравниваем левую часть до той же позиции, где у обычных строк начинается колонка SSL.
            left_width=41
            if (( plain_length < left_width )); then
              padding_length=$((left_width - plain_length))
              padding=$(printf "%${padding_length}s" "")
            else
              padding=""
            fi

            echo -e -n "${input_variable}${padding}"
            printf " │ %13s │ %15s │ %6s │" "-" "-" "-"
            FOLDER_SIZE_MB=$(du -sm "${PathToSiteName}" | awk '{print $1}' | sed ':a;s/\([^0-9.][0-9]\+\|^[0-9]\+\)\([0-9]\{3\}\)/\1\ \2/g;ta')
            printf " ${LWHITE}%9s ${WHITE}Mb" "${FOLDER_SIZE_MB} "
            echo
          fi
        fi
      done
    fi
  done
  echo "───────────────────────────────────────────"
  # Функция красивого форматирования чисел через пробел
  format_number() {
    LC_NUMERIC=en_US.UTF-8 printf "%'d" "$1" | sed 's/,/ /g'
  }

  # --- 1. Данные диска ---
  read TOTAL USED AVAIL <<< $(df --output=size,used,avail -m /var/www | tail -1)

  # --- 2. Размер сайтов ---
  SITES_MB=$(du -sm /var/www | awk '{print $1}')

  # --- 3. Процент свободного места ---
  PERCENT_FREE=$(( AVAIL * 100 / TOTAL ))

  # --- 4. Цвет ---
  if   (( PERCENT_FREE >= 30 )); then
    COLOR_FREE="$GREEN"
  elif (( PERCENT_FREE >= 15 )); then
    COLOR_FREE="$YELLOW"
  else
    COLOR_FREE="$RED"
  fi

  # --- 5. Красивый вывод с пробелами между тысячами ---
  printf "Общий объём диска:    ${LWHITE}%10s${WHITE} MB\n" "$(format_number "$TOTAL")"
  printf "Размер всех сайтов:   ${LWHITE}%10s${WHITE} MB\n" "$(format_number "$SITES_MB")"
  printf "Свободно на диске:    ${COLOR_FREE}%10s${WHITE} MB (%2d%%)\n" \
    "$(format_number "$AVAIL")" "$PERCENT_FREE"
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}
