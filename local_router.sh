#!/bin/bash
clear
# Путь к конфигурационному файлу
CONFIG_FILE="/root/rish/rish_config.sh"

# Подключение файла windows.sh
source /root/rish/windows.sh

# Проверяем, существует ли конфигурационный файл
if [ ! -f "$CONFIG_FILE" ]; then
    touch "$CONFIG_FILE"
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
# Подключаем конфигурационный файл
source "$CONFIG_FILE"

# Функция для запроса логина и пароля у пользователя
request_credentials() {
    echo "Введите логин для роутера (или нажмите Enter для выхода):"
    read -r -e ROUTER_LOGIN
    if [ -z "$ROUTER_LOGIN" ]; then
        echo "Логин не введен. Выход из скрипта."
        exit 1
    fi
    echo "Введите пароль для роутера:"
    read -r -e ROUTER_PASSWORD
    echo
}

# Функция для проверки доступности IP-адреса роутера
check_router_ip() {
    if ping -c 1 -W 5 "$1" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Проверяем, задан ли ROUTER_IP в конфигурационном файле
if [ -z "$ROUTER_IP" ]; then
    DEFAULT_ROUTER_IP=$(ip route | grep default | awk '{print $3}')
    if [ -z "$DEFAULT_ROUTER_IP" ]; then
        echo "Не удалось определить адрес роутера. Используем адрес 192.168.1.1"
        DEFAULT_ROUTER_IP="192.168.1.1"
    fi
    echo "Введите IP адрес роутера (нажмите Enter для значения по умолчанию):"
    read -r -e -i "$DEFAULT_ROUTER_IP" ROUTER_IP
    sed -i '/^ROUTER_IP=/d' "$CONFIG_FILE"
    echo "ROUTER_IP=\"$ROUTER_IP\"" >> "$CONFIG_FILE"
fi

# Проверяем доступность существующего ROUTER_IP
if ! check_router_ip "$ROUTER_IP"; then
    echo -e "${RED}Роутер недоступен ${WHITE} по  адресу ${RED}$ROUTER_IP${WHITE}."
    echo "Попробуйте ввести другой IP адрес роутера."
    echo
    DEFAULT_ROUTER_IP=$(ip route | grep default | awk '{print $3}')
    if [ -z "$DEFAULT_ROUTER_IP" ]; then
        DEFAULT_ROUTER_IP="192.168.1.1"
    fi
    echo "Введите новый IP адрес роутера (нажмите Enter для значения по умолчанию):"
    read -r -e -i "$DEFAULT_ROUTER_IP" ROUTER_IP
    sed -i '/^ROUTER_IP=/d' "$CONFIG_FILE"
    echo "ROUTER_IP=\"$ROUTER_IP\"" >> "$CONFIG_FILE"
    if ! check_router_ip "$ROUTER_IP"; then
        echo
        echo -e "${RED}Роутер недоступен ${WHITE} по  адресу ${RED}$ROUTER_IP${WHITE}. Проверьте подключение и повторите попытку."
        echo
        vertical_menu "current" 2 0 5 "Нажмите Enter"
        exit 1
    fi
fi

echo "IP адрес роутера: $ROUTER_IP"

# Директория для хранения временных файлов
WORK_DIR="/root/rish"
COOKIE_JAR="$WORK_DIR/cookies.txt"
HEADER_FILE="$WORK_DIR/headers.txt"
RESPONSE_FILE="$WORK_DIR/response.txt"
DELETE_RESPONSE_FILE="$WORK_DIR/delete_response.txt"

# Функция для аутентификации
authenticate() {
    # Получаем актуальный challenge и realm
    curl -s -D "$HEADER_FILE" -o /dev/null -c "$COOKIE_JAR" "http://$ROUTER_IP/auth"
    TOKEN=$(awk -F': ' '/X-NDM-Challenge:/ {print $2}' "$HEADER_FILE" | tr -d '\r')
    REALM=$(awk -F': ' '/X-NDM-Realm:/ {print $2}' "$HEADER_FILE" | tr -d '\r')
    [ -z "$REALM" ] && REALM="Keenetic"

    # Обновляем переменные из конфига (очищаем текущие значения)
    unset ROUTER_LOGIN MD5_HASH REALM_SAVED
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    # Проверяем, что ВСЕ поля есть и md5 соответствует актуальному realm
    if [ -z "$ROUTER_LOGIN" ] || [ -z "$MD5_HASH" ] || [ -z "$REALM_SAVED" ] || [ "$REALM_SAVED" != "$REALM" ]; then
        echo "Введите логин для роутера (или нажмите Enter для выхода):"
        read -r -e ROUTER_LOGIN
        [ -z "$ROUTER_LOGIN" ] && exit 1
        echo "Введите пароль для роутера:"
        read -r -e ROUTER_PASSWORD
        echo
        MD5_HASH=$(echo -n "$ROUTER_LOGIN:$REALM:$ROUTER_PASSWORD" | openssl md5 | awk '{print $2}')
        # Обновляем только при полной информации
        sed -i '/^MD5_HASH=/d' "$CONFIG_FILE"
        sed -i '/^ROUTER_LOGIN=/d' "$CONFIG_FILE"
        sed -i '/^REALM_SAVED=/d' "$CONFIG_FILE"
        echo "ROUTER_LOGIN=\"$ROUTER_LOGIN\"" >> "$CONFIG_FILE"
        echo "MD5_HASH=\"$MD5_HASH\"" >> "$CONFIG_FILE"
        echo "REALM_SAVED=\"$REALM\"" >> "$CONFIG_FILE"
      curl -s -D "$HEADER_FILE" -o /dev/null -c "$COOKIE_JAR" "http://$ROUTER_IP/auth"
      TOKEN=$(awk -F': ' '/X-NDM-Challenge:/ {print $2}' "$HEADER_FILE" | tr -d '\r')
      REALM=$(awk -F': ' '/X-NDM-Realm:/ {print $2}' "$HEADER_FILE" | tr -d '\r')
      [ -z "$REALM" ] && REALM="Keenetic"

    fi

    PASSWORD_HASH=$(echo -n "$TOKEN$MD5_HASH" | openssl sha256 | awk '{print $2}')
    AUTH_DATA=$(printf '{"login":"%s","password":"%s"}' "$ROUTER_LOGIN" "$PASSWORD_HASH")
    response=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        -X POST "http://$ROUTER_IP/auth" \
        -H "Content-Type: application/json" \
        -d "$AUTH_DATA")

    if [ "$response" -eq 200 ]; then
        return 0
    else
        echo "Ошибка авторизации. Код ответа: $response"
        echo "Пожалуйста, введите корректный логин и пароль."
        sed -i '/^MD5_HASH=/d' "$CONFIG_FILE"
        sed -i '/^ROUTER_LOGIN=/d' "$CONFIG_FILE"
        sed -i '/^REALM_SAVED=/d' "$CONFIG_FILE"
        authenticate
    fi
}

# --- Save Keenetic configuration (NDMS3) ---
save_config() {
  local url="http://$ROUTER_IP/rci/system/configuration/save"
  local code

  code=$(curl --connect-timeout 10 -m 10 -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_JAR" -X POST "$url" \
    -H "Content-Type: application/json" -d "{}")

  if [ "$code" -eq 401 ]; then
    echo "Сессия истекла, повторная авторизация перед сохранением..."
    authenticate
    code=$(curl --connect-timeout 10 -m 10 -s -o /dev/null -w "%{http_code}" \
      -b "$COOKIE_JAR" -X POST "$url" \
      -H "Content-Type: application/json" -d "{}")
  fi

  if [ "$code" -eq 200 ]; then
    echo -e "Конфигурация успешно ${GREEN}сохранена${WHITE}."
  else
    echo -e "Конфигурацию ${RED}не удалось${WHITE} сохранить (${YELLOW}код${WHITE} $code)."
  fi
}



add_domain() {
    local domain="$1"
    local ip_address="$2"
    ADD_URL="http://$ROUTER_IP/rci/ip/host/"
    ADD_DATA=$(printf '{"domain":"%s","address":"%s"}' "$domain" "$ip_address")
    RESPONSE_CODE=$(curl --connect-timeout 10 -m 10 -s -o "$RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" \
        -X POST "$ADD_URL" \
        -H "Content-Type: application/json" \
        -d "$ADD_DATA")

    if [ "$RESPONSE_CODE" -eq 401 ]; then
        echo "Сессия истекла, повторная авторизация..."
        authenticate
        RESPONSE_CODE=$(curl --connect-timeout 10 -m 10 -s -o "$RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" \
            -X POST "$ADD_URL" \
            -H "Content-Type: application/json" \
            -d "$ADD_DATA")
    fi

    if [ "$RESPONSE_CODE" -eq 200 ]; then
        echo -e "Домен ${GREEN}$domain${WHITE} успешно добавлен с IP ${GREEN}$ip_address${WHITE}."
        save_config
    else
        echo -e "Ошибка при добавлении домена. Код ответа: ${RED}$RESPONSE_CODE${WHITE}"
        cat "$RESPONSE_FILE"
    fi
    rm -f "$RESPONSE_FILE"
}

delete_domain() {
    DELETE_URL="http://$ROUTER_IP/rci/ip/host/?domain=$selected_domain"
    RESPONSE_CODE=$(curl -s -o "$DELETE_RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" \
        -X DELETE "$DELETE_URL")

    if [ "$RESPONSE_CODE" -eq 401 ]; then
        echo "Сессия истекла, повторная авторизация..."
        authenticate
        RESPONSE_CODE=$(curl -s -o "$DELETE_RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" \
            -X DELETE "$DELETE_URL")
    fi

    if [ "$RESPONSE_CODE" -eq 200 ]; then
        echo -e "Запись ${GREEN}$selected_domain${WHITE} успешно удалена."
        save_config
    else
        echo "Ошибка при удалении записи. Код ответа: ${RED}$RESPONSE_CODE${WHITE}"
        cat "$DELETE_RESPONSE_FILE"
    fi
    rm -f "$DELETE_RESPONSE_FILE"
}

while true
do
  authenticate
  RESPONSE_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" "http://$ROUTER_IP/rci/show/running-config")

  if [ "$RESPONSE_CODE" -eq 401 ]; then
      echo "Сессия истекла, повторная авторизация..."
      authenticate
      RESPONSE_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" "http://$ROUTER_IP/rci/show/running-config")
  fi

  RESPONSE_CONTENT=$(<"$RESPONSE_FILE")
  rm -f "$RESPONSE_FILE"

  messages=$(echo "$RESPONSE_CONTENT" | sed -n '/"message": \[/,/^\s*\]/p' | sed '1d;$d' | sed 's/^[ \t]*"//;s/",\?$//')
  mapfile -t array < <(echo "$messages" | grep "^ip host" | tr -d '\r')
  echo
  echo "Выберите нужную запись для удаления или добавьте новый домен."
  echo "Нажмите Esc для выхода"
  echo

  if [ ${#array[@]} -eq 0 ]; then
    sorted_array=("Добавить домен")
  else
    max_length=0
    unset domains_ips
    declare -A domains_ips
    for line in "${array[@]}"; do
        read -r _ _ domain ip <<< "$line"
        domains_ips["$domain"]="$ip"
        domain_length=${#domain}
        if (( domain_length > max_length )); then
            max_length=$domain_length
        fi
    done

    formatted_array=()
    for domain in "${!domains_ips[@]}"; do
        ip=${domains_ips["$domain"]}
        formatted_line=$(printf "%-${max_length}s %s" "$domain" "$ip")
        formatted_array+=("$formatted_line")
    done

    sorted_array=()
    mapfile -t sorted_array < <(printf '%s\n' "${formatted_array[@]}" | sort)
    sorted_array=("Добавить домен" "${sorted_array[@]}")
  fi

  vertical_menu "current" 2 30 30 "${sorted_array[@]}"
  choice=$?
  if (( choice > 254 )); then
      exit
  fi

  if (( choice == 0 )); then
    conf_dir="/etc/httpd/conf.d"
    domain_files=()
    for file in "$conf_dir"/*.conf; do
        filename=$(basename "$file")
        if [[ "$filename" == "userdir.conf" || "$filename" == "welcome.conf" || "$filename" == "ssl.conf" || \
              "$filename" == "README" || "$filename" == "000-default.conf" || "$filename" == "000-default-ssl.conf" ]]; then
            continue
        fi
        if [[ "$filename" == php*php.conf ]]; then
            continue
        fi
        if [[ "$filename" == *-ssl.conf ]]; then
            continue
        fi
        if [[ "$filename" == autoindex.conf ]]; then
            continue
        fi
        domain="${filename%.conf}"
        domain_files+=("$domain")
    done

    if [ ${#domain_files[@]} -eq 0 ]; then
        echo -e "${RED}Внимание!${WHITE}. Не найдено ни одного хоста для добавления."
        echo "Вам следует создать хотя бы один сайт, чтобы домен работал."
        echo
    fi

    sorted_domains=($(printf '%s\n' "${domain_files[@]}" | sort))
    sorted_domains=("Ввести свой домен" "${sorted_domains[@]}")

    echo "Выберите домен для добавления или введите свой."
    echo "Нажмите Esc для выхода."

    vertical_menu "current" 2 30 30 "${sorted_domains[@]}"
    choice=$?
    if (( choice > 254 )); then
        exit
    fi

    selected_domain="${sorted_domains[$choice]}"
    if (( choice == 0 )); then
        echo "Введите доменное имя, которое хотите добавить (Enter чтобы выйти):"
        read -e selected_domain
        selected_domain=$(echo "$selected_domain" | xargs)
        if [ -z "$selected_domain" ]; then
            echo "Домен не введен. Выход из скрипта."
            vertical_menu "current" 2 0 5 "Нажмите Enter"
            exit 1
        fi
    fi

    ip_address=$(hostname -I | awk '{print $1}')

    echo
    echo -e "Домен: ${GREEN}${selected_domain}${WHITE} будет добавлен с IP ${GREEN}$ip_address${WHITE}"
    echo
    vertical_menu "current" 2 0 5 "Добавить ${selected_domain}" "Добавить ${selected_domain} и www.${selected_domain}" "Ничего не добавлять"
    choice=$?
    case "$choice" in
    0)
      add_domain "$selected_domain" "$ip_address"
      ;;
    1)
      add_domain "$selected_domain" "$ip_address"
      add_domain "www.$selected_domain" "$ip_address"
      ;;
    *)
      ;;
    esac
  else
    selected_entry=${sorted_array[$choice]}
    selected_domain=$(echo "$selected_entry" | awk '{print $1}')

    echo
    echo -e "Домен: ${GREEN}${selected_domain}${WHITE} будет ${RED}удален${WHITE}"
    echo
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      delete_domain
    fi
  fi

  rm -f "$COOKIE_JAR" "$HEADER_FILE"
  echo
done
