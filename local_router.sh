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

# Функция для запроса логина и пароля у пользователя и вычисления MD5_HASH
request_credentials() {
    echo "Введите логин для роутера (или нажмите Enter для выхода):"
    read -e ROUTER_LOGIN
    # Проверяем, введен ли логин
    if [ -z "$ROUTER_LOGIN" ]; then
        echo "Логин не введен. Выход из скрипта."
        exit 1
    fi
    echo "Введите пароль для роутера:"
    read -e ROUTER_PASSWORD
    echo
    # Вычисление MD5_HASH
    MD5_HASH=$(echo -n "$ROUTER_LOGIN:$REALM:$ROUTER_PASSWORD" | openssl md5 | awk '{print $2}')
    # Сохраняем логин и MD5_HASH в конфигурационный файл
    echo "ROUTER_LOGIN=\"$ROUTER_LOGIN\"" >> "$CONFIG_FILE"
    echo "MD5_HASH=\"$MD5_HASH\"" >> "$CONFIG_FILE"
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
    # Определяем IP адрес роутера автоматически
    DEFAULT_ROUTER_IP=$(ip route | grep default | awk '{print $3}')
    # Если автоматическое определение не удалось, используем 192.168.1.1
    if [ -z "$DEFAULT_ROUTER_IP" ]; then
        DEFAULT_ROUTER_IP="192.168.1.1"
    fi
    # Предлагаем пользователю принять IP адрес или изменить его, используя read -e -i
    echo "Введите IP адрес роутера (нажмите Enter для значения по умолчанию):"
    read -e -i "$DEFAULT_ROUTER_IP" ROUTER_IP
    # Перед добавлением новой записи удаляем старые из конфигурационного файла
    sed -i '/^ROUTER_IP=/d' "$CONFIG_FILE"
    # Сохраняем ROUTER_IP в конфигурационный файл
    echo "ROUTER_IP=\"$ROUTER_IP\"" >> "$CONFIG_FILE"
fi
# Проверяем доступность существующего ROUTER_IP
if ! check_router_ip "$ROUTER_IP"; then
    echo -e "${RED}Роутер недоступен ${WHITE} по  адресу ${RED}$ROUTER_IP${WHITE}."
    echo "Попробуйте ввести другой IP адрес роутера."
    echo
    # Определяем IP адрес роутера автоматически
    DEFAULT_ROUTER_IP=$(ip route | grep default | awk '{print $3}')
    # Если автоматическое определение не удалось, используем 192.168.1.1
    if [ -z "$DEFAULT_ROUTER_IP" ]; then
        DEFAULT_ROUTER_IP="192.168.1.1"
    fi
    # Предлагаем пользователю ввести новый IP адрес
    echo "Введите новый IP адрес роутера (нажмите Enter для значения по умолчанию):"
    read -e -i "$DEFAULT_ROUTER_IP" ROUTER_IP
    # Перед добавлением новой записи удаляем старые из конфигурационного файла
    sed -i '/^ROUTER_IP=/d' "$CONFIG_FILE"
    # Сохраняем новый ROUTER_IP в конфигурационный файл
    echo "ROUTER_IP=\"$ROUTER_IP\"" >> "$CONFIG_FILE"
    # Проверяем доступность нового IP адреса
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

# Проверяем, существует ли директория WORK_DIR, если нет - создаем
if [ ! -d "$WORK_DIR" ]; then
    mkdir -p "$WORK_DIR"
fi


# Функция для аутентификации
authenticate() {
    # Отправка GET-запроса на /auth и сохранение заголовков
    curl -s -D "$HEADER_FILE" -o /dev/null -c "$COOKIE_JAR" "http://$ROUTER_IP/auth"

    # Проверяем код ответа
    HTTP_CODE=$(awk '/HTTP\/1\.[01] [0-9]{3}/ {print $2}' "$HEADER_FILE" | tail -1)

    if [ "$HTTP_CODE" -eq 200 ]; then
        return 0
    else

        # Извлечение заголовков
        TOKEN=$(awk -F': ' '/X-NDM-Challenge:/ {print $2}' "$HEADER_FILE" | tr -d '\r')
        REALM=$(awk -F': ' '/X-NDM-Realm:/ {print $2}' "$HEADER_FILE" | tr -d '\r')

        # Если REALM пустой, устанавливаем значение по умолчанию
        if [ -z "$REALM" ]; then
            REALM="Keenetic"
            echo "Realm не предоставлен, используем значение по умолчанию: $REALM"
        fi

        # Проверяем, задан ли ROUTER_LOGIN и MD5_HASH
        if [ -z "$ROUTER_LOGIN" ] || [ -z "$MD5_HASH" ]; then
            echo "Логин или MD5_HASH не найдены. Запрашиваю у пользователя..."
            request_credentials
        fi

        # Вычисление SHA256 хеша: sha256(token + md5_hash)
        PASSWORD_HASH=$(echo -n "$TOKEN$MD5_HASH" | openssl sha256 | awk '{print $2}')
        # Подготовка данных для авторизации
        AUTH_DATA=$(printf '{"login":"%s","password":"%s"}' "$ROUTER_LOGIN" "$PASSWORD_HASH")

        # Отправка POST-запроса на /auth
        response=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
            -X POST "http://$ROUTER_IP/auth" \
            -H "Content-Type: application/json" \
            -d "$AUTH_DATA")

        if [ "$response" -eq 200 ]; then
            return 0
        else
            echo "Ошибка авторизации. Код ответа: $response"
            echo "Пожалуйста, введите корректный логин и пароль."
            # Удаляем неверный MD5_HASH и ROUTER_LOGIN из конфигурационного файла
            sed -i '/^MD5_HASH=/d' "$CONFIG_FILE"
            sed -i '/^ROUTER_LOGIN=/d' "$CONFIG_FILE"
            # Запрашиваем данные заново
            request_credentials
            # Повторяем аутентификацию
            authenticate
        fi
    fi
}

add_domain() {
    local domain="$1"
    local ip_address="$2"

    # URL для добавления записи
    ADD_URL="http://$ROUTER_IP/rci/ip/host/"

    # Данные для добавления
    ADD_DATA=$(printf '{"domain":"%s","address":"%s"}' "$domain" "$ip_address")

    # Отправка POST-запроса для добавления домена
    RESPONSE_CODE=$(curl --connect-timeout 10 -m 10 -s -o "$RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" \
        -X POST "$ADD_URL" \
        -H "Content-Type: application/json" \
        -d "$ADD_DATA")

    # Проверка кода ответа
    if [ "$RESPONSE_CODE" -eq 401 ]; then
        echo "Сессия истекла, повторная авторизация..."
        authenticate
        # Повторяем запрос после успешной авторизации
        RESPONSE_CODE=$(curl --connect-timeout 10 -m 10 -s -o "$RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" \
            -X POST "$ADD_URL" \
            -H "Content-Type: application/json" \
            -d "$ADD_DATA")
    fi

    if [ "$RESPONSE_CODE" -eq 200 ]; then
        echo -e "Домен ${GREEN}$domain${WHITE} успешно добавлен с IP ${GREEN}$ip_address${WHITE}."
    else
        echo -e "Ошибка при добавлении домена. Код ответа: ${RED}$RESPONSE_CODE${WHITE}"
        cat "$RESPONSE_FILE"
    fi

    # Очистка временного файла
    rm -f "$RESPONSE_FILE"
}

# Функция для отправки команды на удаление записи с обработкой повторной авторизации
delete_domain() {
    # URL для удаления записи
    DELETE_URL="http://$ROUTER_IP/rci/ip/host/?domain=$selected_domain"

    # Отправка DELETE-запроса и получение HTTP-кода
    RESPONSE_CODE=$(curl -s -o "$DELETE_RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" \
        -X DELETE "$DELETE_URL")

    # Проверка кода ответа
    if [ "$RESPONSE_CODE" -eq 401 ]; then
        echo "Сессия истекла, повторная авторизация..."
        authenticate
        # Повторяем запрос после успешной авторизации
        RESPONSE_CODE=$(curl -s -o "$DELETE_RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" \
            -X DELETE "$DELETE_URL")
    fi

    if [ "$RESPONSE_CODE" -eq 200 ]; then
        echo -e "Запись ${GREEN}$selected_domain${WHITE} успешно удалена."
    else
        echo "Ошибка при удалении записи. Код ответа: ${RED}$RESPONSE_CODE${WHITE}"
        cat "$DELETE_RESPONSE_FILE"
    fi

    # Очистка временного файла
    rm -f "$DELETE_RESPONSE_FILE"
}

while true
do
  # Выполняем аутентификацию
  authenticate
  # Отправка команды роутеру и получение HTTP-кода
  RESPONSE_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" "http://$ROUTER_IP/rci/show/running-config")

  # Проверка кода ответа. Если 401, то повторная авторизация
  if [ "$RESPONSE_CODE" -eq 401 ]; then
      echo "Сессия истекла, повторная авторизация..."
      authenticate
      # Повторяем запрос после успешной авторизации
      RESPONSE_CODE=$(curl -s -o "$RESPONSE_FILE" -w "%{http_code}" -b "$COOKIE_JAR" "http://$ROUTER_IP/rci/show/running-config")
  fi

  # Чтение ответа из файла
  RESPONSE_CONTENT=$(<"$RESPONSE_FILE")

  # Очистка временного файла
  rm -f "$RESPONSE_FILE"

  # Шаг 3: Извлечение строк с 'ip host' и создание массива

  # Извлекаем поле 'message' из JSON-ответа
  messages=$(echo "$RESPONSE_CONTENT" | sed -n '/"message": \[/,/^\s*\]/p' | sed '1d;$d' | sed 's/^[ \t]*"//;s/",\?$//')

  # Используем mapfile для чтения строк в массив
  mapfile -t array < <(echo "$messages" | grep "^ip host" | tr -d '\r')
  # Вывод меню для выбора
  echo
  echo "Выберите нужную запись для удаления или добавьте новый домен."
  echo "Нажмите Esc для выхода"
  echo
  # Проверка на пустой массив
  if [ ${#array[@]} -eq 0 ]; then
    sorted_array=("Добавить домен")
  else
    # Определение максимальной длины доменного имени
    max_length=0
    unset domains_ips
    declare -A domains_ips
    for line in "${array[@]}"; do
        # Извлекаем домен и IP
        read -r _ _ domain ip <<< "$line"
        domains_ips["$domain"]="$ip"
        # Определяем длину доменного имени
        domain_length=${#domain}
        if (( domain_length > max_length )); then
            max_length=$domain_length
        fi
    done

    # Формирование массива для меню с учетом выравнивания
    formatted_array=()
    for domain in "${!domains_ips[@]}"; do
        ip=${domains_ips["$domain"]}
        formatted_line=$(printf "%-${max_length}s %s" "$domain" "$ip")
        formatted_array+=("$formatted_line")
    done

    # Сортировка массива
    sorted_array=()
    mapfile -t sorted_array < <(printf '%s\n' "${formatted_array[@]}" | sort)
    sorted_array=("Добавить домен" "${sorted_array[@]}")
  fi

  # Используем функцию vertical_menu из windows.sh
  vertical_menu "current" 2 30 30 "${sorted_array[@]}"
  choice=$?
  if (( choice > 254 )); then
      exit
  fi

  if (( choice == 0 )); then
    # Добавляем новый домен

    # Сканируем директорию /etc/httpd/conf.d для получения списка доступных доменов
    conf_dir="/etc/httpd/conf.d"
    domain_files=()

    # Проходим по всем файлам в директории
    for file in "$conf_dir"/*.conf; do
        filename=$(basename "$file")

        # Пропускаем файлы, которые нужно исключить
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
        # Извлекаем доменное имя из названия файла
        domain="${filename%.conf}"
        domain_files+=("$domain")
    done

    # Проверяем, есть ли доступные домены для добавления
    if [ ${#domain_files[@]} -eq 0 ]; then
        echo -e "${RED}Внимание!${WHITE}. Не найдено ни одного хоста для добавления."
        echo "Вам следует создать хотя бы один сайт, чтобы домен работал."
        echo
    fi

    # Сортируем список доменов
    sorted_domains=($(printf '%s\n' "${domain_files[@]}" | sort))
    # Добавляем опцию для ввода своего домена
    sorted_domains=("Ввести свой домен" "${sorted_domains[@]}")

    # Вывод меню для выбора домена для добавления
    echo "Выберите домен для добавления или введите свой."
    echo "Нажмите Esc для выхода."

    vertical_menu "current" 2 30 30 "${sorted_domains[@]}"
    choice=$?
    if (( choice > 254 )); then
        exit
    fi

    # Получаем выбранный домен
    selected_domain="${sorted_domains[$choice]}"

    # Если пользователь выбрал "Ввести свой домен", запрашиваем доменное имя
    if (( choice == 0 )); then
        echo "Введите доменное имя, которое хотите добавить (Enter чтобы выйти):"
        read -e selected_domain
        # Убираем лишние пробелы
        selected_domain=$(echo "$selected_domain" | xargs)
        # Проверяем, что домен не пустой
        if [ -z "$selected_domain" ]; then
            echo "Домен не введен. Выход из скрипта."
            vertical_menu "current" 2 0 5 "Нажмите Enter"
            exit 1
        fi
    fi

    # Получаем IP адрес сервера
    ip_address=$(hostname -I | awk '{print $1}')

    # Подтверждение добавления
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
    # Обработка выбора пользователя
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

  # Очистка
  rm -f "$COOKIE_JAR" "$HEADER_FILE"
  echo
done