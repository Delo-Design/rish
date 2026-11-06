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
    CERT_INFO=$(echo | timeout -k 1s 5s openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:${PORT}" 2>/dev/null | openssl x509 -noout -checkhost "${DOMAIN}" 2>/dev/null) || :

    if [ -n "$CERT_INFO" ]; then
        # Код возврата -checkhost может быть 0 и при несовпадении имени.
        if [ "$CERT_INFO" = "Hostname ${DOMAIN} does match certificate" ]; then
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
    CERT=$(echo | timeout -k 1s 5s openssl s_client -servername "${DOMAIN}" -connect "${DOMAIN}:${PORT}" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null)

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

checkip_php_code() {
    [[ -f "$1" && -r "$1" ]] || return 0
    # Удаляем комментарии, сохраняя строковые литералы; PHP не выполняется.
    awk '
      BEGIN { single_quote = sprintf("%c", 39) }
      {
        code = ""
        started_in_string = (quote != "")
        for (pos = 1; pos <= length($0); pos++) {
          char = substr($0, pos, 1)
          next_char = substr($0, pos + 1, 1)
          if (block_comment) {
            if (char == "*" && next_char == "/") {
              block_comment = 0
              pos++
            }
            continue
          }
          if (quote != "") {
            code = code char
            if (escaped) escaped = 0
            else if (char == "\\") escaped = 1
            else if (char == quote) quote = ""
            continue
          }
          if (char == "/" && next_char == "*") {
            block_comment = 1
            code = code " "
            pos++
            continue
          }
          if ((char == "/" && next_char == "/") || char == "#") break
          code = code char
          if (char == single_quote || char == "\"") quote = char
        }
        if (!started_in_string) {
          sub(/^[[:space:]]*<\?php[[:space:]]*/, "", code)
          print code
        }
      }
    ' "$1" 2>/dev/null
}

checkip_php_string() {
    local php_file=$1
    local prefix=$2
    local suffix=$3
    local literal
    literal=$(checkip_php_code "$php_file" |
      sed -nE \
        -e "s@^[[:space:]]*${prefix}[[:space:]]*'([^']*)'[[:space:]]*${suffix}[[:space:]]*;.*@found:\\1@p" \
        -e "s@^[[:space:]]*${prefix}[[:space:]]*\"([^\"]*)\"[[:space:]]*${suffix}[[:space:]]*;.*@found:\\1@p" |
      head -n 1)
    [[ "$literal" == found:* ]] || return 1
    printf '%s' "${literal#found:}"
}

checkip_document_root() {
    local vhost_file=$1
    local site_directory=$2
    local document_root canonical_site
    [[ -f "$vhost_file" && -r "$vhost_file" ]] || return 1
    document_root=$(awk '
      tolower($1) == "documentroot" {
        sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "")
        if ($0 ~ /^"/) {
          sub(/^"/, "")
          sub(/".*$/, "")
        } else {
          sub(/[[:space:]].*$/, "")
        }
        print
        exit
      }
    ' "$vhost_file") || return 1
    [[ "$document_root" == /* ]] || return 1
    canonical_site=$(cd -P -- "$site_directory" 2>/dev/null && pwd -P) || return 1
    document_root=$(cd -P -- "$document_root" 2>/dev/null && pwd -P) || return 1
    [[ -d "$document_root" ]] || return 1
    [[ "$document_root" == "$canonical_site" || "$document_root" == "$canonical_site/"* ]] || return 1
    printf '%s\n' "$document_root"
}

get_cms_info() {
    local site_root=$1
    local cms_name=""
    local cms_version=""
    if [[ -f "$site_root/administrator/manifests/files/joomla.xml" ]]; then
        cms_name="Joomla"
        cms_version=$(sed -nE 's@.*<version>[[:space:]]*([^<[:space:]]+)[[:space:]]*</version>.*@\1@p' \
          "$site_root/administrator/manifests/files/joomla.xml" 2>/dev/null | head -n 1)
    elif [[ -f "$site_root/wp-includes/version.php" ]]; then
        cms_name="WordPress"
        cms_version=$(checkip_php_string "$site_root/wp-includes/version.php" '\$wp_version[[:space:]]*=' '') || cms_version=""
    elif [[ -f "$site_root/bitrix/modules/main/classes/general/version.php" ]]; then
        cms_name="Bitrix"
        local bitrix_version_file="$site_root/bitrix/modules/main/classes/general/version.php"
        cms_version=$(checkip_php_string "$bitrix_version_file" "define[[:space:]]*\\([[:space:]]*['\"]SM_VERSION['\"][[:space:]]*," '\)') ||
          cms_version=$(checkip_php_string "$bitrix_version_file" 'const[[:space:]]+SM_VERSION[[:space:]]*=' '') || cms_version=""
    elif [[ -f "$site_root/core/docs/version.inc.php" || -f "$site_root/config.core.php" ]]; then
        cms_name="MODX"
        local core_path="$site_root/core/"
        local core_config="$site_root/config.core.php"
        local core_define="define[[:space:]]*\\([[:space:]]*['\"]MODX_CORE_PATH['\"][[:space:]]*,"
        local core_const='const[[:space:]]+MODX_CORE_PATH[[:space:]]*='
        if checkip_php_code "$core_config" | grep -Eq "^[[:space:]]*($core_define|$core_const)"; then
            core_path=""
            local core_style core_prefix core_suffix core_base relative_core
            for core_style in define const; do
                if [[ "$core_style" == define ]]; then
                    core_prefix=$core_define
                    core_suffix='\)'
                else
                    core_prefix=$core_const
                    core_suffix=''
                fi
                core_path=$(checkip_php_string "$core_config" "$core_prefix" "$core_suffix") || core_path=""
                [[ -n "$core_path" ]] && break
                # Поддерживаем также штатные пути относительно config.core.php.
                for core_base in 'dirname[[:space:]]*\([[:space:]]*__FILE__[[:space:]]*\)' '__DIR__'; do
                    relative_core=$(checkip_php_string "$core_config" "${core_prefix}[[:space:]]*${core_base}[[:space:]]*\\." "$core_suffix") || relative_core=""
                    if [[ "$relative_core" == /* ]]; then
                        core_path="$site_root$relative_core"
                        break
                    fi
                done
                [[ -n "$core_path" ]] && break
            done
        fi
        if [[ "$core_path" == /* && "$core_path" != *'$'* && "$core_path" != *'\'* ]]; then
            local modx_file="$core_path/docs/version.inc.php"
            local modx_major modx_minor modx_patch
            cms_version=$(checkip_php_string "$modx_file" "\\\$v\\[['\"]version['\"]\\][[:space:]]*=" '') || cms_version=""
            modx_major=$(checkip_php_string "$modx_file" "\\\$v\\[['\"]major_version['\"]\\][[:space:]]*=" '') || modx_major=""
            modx_minor=$(checkip_php_string "$modx_file" "\\\$v\\[['\"]minor_version['\"]\\][[:space:]]*=" '') || modx_minor=""
            if modx_patch=$(checkip_php_string "$modx_file" "\\\$v\\[['\"]patch_level['\"]\\][[:space:]]*=" '') &&
              [[ "$cms_version" =~ ^[0-9]+$ && "$modx_major" =~ ^[0-9]+$ && "$modx_minor" =~ ^[0-9]+$ && "$modx_patch" =~ ^[A-Za-z0-9._-]*$ ]]; then
                cms_version="$cms_version.$modx_major.$modx_minor"
                [[ -z "$modx_patch" ]] || cms_version+="-$modx_patch"
            else
                cms_version=""
            fi
        fi
    fi
    if [[ -z "$cms_name" ]]; then
        printf '%s' '-'
    elif [[ "$cms_version" =~ ^[0-9]+(\.[0-9]+)+([A-Za-z0-9.+_-]*)$ ]]; then
        printf '%s %s' "$cms_name" "$cms_version"
    else
        printf '%s ?' "$cms_name"
    fi
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

  local myip
  myip="($(ip route get 1 | grep -Eo 'src [0-9\.]{1,20}' | awk '{print $NF;exit}'))"
  echo -e "Адрес этого сервера: ${GREEN}${myip}${WHITE}"

  echo "───────────────────────────────────────────"
  local site_number=1
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
            local site_available=false
            local ip=""
            local protocol=""
            local certificate_expiration=""
            if timeout -k 1s 10s curl --connect-timeout 3 --max-time 8 -I "http://${SiteName}" &>/dev/null; then
              site_available=true
              ip=$(timeout -k 1s 5s ping -n -c 1 -W 2 "$SiteName" 2>/dev/null | grep PING | awk '{ print $3 }')
              protocol=$(check_certificate "$SiteName")
              certificate_expiration=$(check_certificate_expiration "$SiteName")
            fi
            printf " %3d │ " "$site_number"
            ((site_number++))
            if "$site_available"; then
              if [[ "$myip" == "$ip" ]]; then
                printf "${GREEN}%-19s${WHITE}" "$ip"
              else
                printf "%-19s" "$ip"
              fi
              printf "%s" "$protocol"
              if [[ "$SiteName" =~ (xn\-\-) ]]
              then
                unicode_domain=$(idn2 -d "$SiteName")
              else
                unicode_domain=$SiteName
              fi
              echo -e -n " ${LGREEN}"
              unicode_printf 32 "$unicode_domain"
              echo -e -n " ${WHITE}│ "
              printf "%s" "$certificate_expiration"
            else
              # Держим ту же сетку колонок, что и у "живой" строки: IP(19) + proto(8)
              printf "%-19s%-8s" " " " "
              if [[ "$SiteName" =~ (xn\-\-) ]]
              then
                unicode_domain=$(idn2 -d "$SiteName")
              else
                unicode_domain=$SiteName
              fi
              echo -e -n " ${RED}"
              unicode_printf 32 "$unicode_domain"
              echo -e -n " ${WHITE}│ "
              printf "%13s" "-"
            fi
            local cms_info="-"
            local cms_root
            if cms_root=$(checkip_document_root "$CONF_FILE" "$PathToSiteName"); then
              cms_info=$(get_cms_info "$cms_root")
            fi
            printf " │ %21s" "$cms_info"
            PHP_VERSION=$(get_php_version "$SiteName")
            printf " │ %6s" "${PHP_VERSION}"
            FOLDER_SIZE_MB=$(du -sm "${PathToSiteName}" | awk '{print $1}' | sed ':a;s/\([^0-9.][0-9]\+\|^[0-9]\+\)\([0-9]\{3\}\)/\1\ \2/g;ta')
            printf " │ ${LWHITE}%9s ${WHITE}Mb" "${FOLDER_SIZE_MB} "
            echo
          else
            printf "     │ %-19s" " "
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
            printf " │ %13s │ %21s │ %6s │" "-" "-" "-"
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
  read TOTAL USED AVAIL <<< "$(df --output=size,used,avail -m /var/www | tail -1)"

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
