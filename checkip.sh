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
    CERT=$(echo | openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:${PORT}" 2>/dev/null | openssl x509 -noout -enddate)

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
        printf "SSL %4s дней," "${DAYS_LEFT}"
    else
        echo -e -n " -"
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

CheckIP() {
  clear
  echo "Что значат цвета IP:"
  echo -e "${RED}Красный цвет${WHITE} – сайт недоступен (проблемы с доменом)"
  echo -e "${GREEN}Зеленый цвет${WHITE} – все ок, сайт доступен по IP адресу этого сервера"
  echo -e "Белый цвет – сайт доступен по другому IP адресу"
  echo

  myip="("$(ip route get 1 | grep -Eo 'src [0-9\.]{1,20}' | awk '{print $NF;exit}')")"
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
            echo -e -n " ${WHITE}"
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
            printf " Joomla %8s" "${JoomlaVersion}"
          else
            printf "        %8s" "-"
          fi
          FOLDER_SIZE_MB=$(du -sm "${PathToSiteName}" | awk '{print $1}' | sed ':a;s/\([^0-9.][0-9]\+\|^[0-9]\+\)\([0-9]\{3\}\)/\1\ \2/g;ta')
          printf " ${LWHITE}%9s ${WHITE}Mb" "${FOLDER_SIZE_MB} "
          echo
        fi
      done
    fi
  done
  echo "───────────────────────────────────────────"
  local FREE_SPACE
  FREE_SPACE=$(df -Pm / | awk 'NR==2 {print $4}' | sed ':a;s/\([^0-9.][0-9]\+\|^[0-9]\+\)\([0-9]\{3\}\)/\1\ \2/g;ta')
  local ALL_SITES_SIZE_MB
  ALL_SITES_SIZE_MB=$(du -sm "/var/www" | awk '{print $1}' | sed ':a;s/\([^0-9.][0-9]\+\|^[0-9]\+\)\([0-9]\{3\}\)/\1\ \2/g;ta')
  echo -e "На сервере свободно: ${GREEN}${FREE_SPACE}${WHITE} Mb. Сайты занимают ${GREEN}${ALL_SITES_SIZE_MB}${WHITE} Mb."
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}