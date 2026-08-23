#!/usr/bin/env bash

function ensure_swapfile_configuration() {
    local SWAP_FILE="$1"
    local SWAPPINESS_VALUE="${2:-10}"

    # Добавляем swap в /etc/fstab для автоматической активации при загрузке.
    if ! awk -v swap_file="$SWAP_FILE" \
        '$1 == swap_file && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; then
        if ! printf '%s\n' "$SWAP_FILE none swap sw 0 0" | tee -a /etc/fstab > /dev/null; then
            echo -e "${RED}Ошибка${WHITE}: не удалось добавить swap в /etc/fstab."
            return 1
        fi
        echo -e "Swap добавлен в ${GREEN}/etc/fstab${WHITE}."
    else
        echo -e "Swap уже присутствует в ${GREEN}/etc/fstab${WHITE}."
    fi
    if ! awk -v swap_file="$SWAP_FILE" \
        '$1 == swap_file && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; then
        echo -e "${RED}Ошибка${WHITE}: запись swap не найдена в /etc/fstab после сохранения."
        return 1
    fi

    echo -e "Настройка ${GREEN}vm.swappiness${WHITE} в ${GREEN}$SWAPPINESS_VALUE${WHITE}"
    if ! sysctl "vm.swappiness=$SWAPPINESS_VALUE"; then
        echo -e "${RED}Ошибка${WHITE}: не удалось применить vm.swappiness."
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*vm\.swappiness[[:space:]]*=' /etc/sysctl.conf; then
        if ! printf '%s\n' "vm.swappiness=$SWAPPINESS_VALUE" | tee -a /etc/sysctl.conf > /dev/null; then
            echo -e "${RED}Ошибка${WHITE}: не удалось записать vm.swappiness в /etc/sysctl.conf."
            return 1
        fi
        echo -e "${GREEN}vm.swappiness${WHITE} добавлен в ${GREEN}/etc/sysctl.conf${WHITE}"
    else
        if ! sed -i -E \
            "s/^[[:space:]]*vm\.swappiness[[:space:]]*=.*/vm.swappiness=$SWAPPINESS_VALUE/" \
            /etc/sysctl.conf; then
            echo -e "${RED}Ошибка${WHITE}: не удалось обновить vm.swappiness в /etc/sysctl.conf."
            return 1
        fi
        echo -e "${GREEN}vm.swappiness${WHITE} обновлен в ${GREEN}/etc/sysctl.conf${WHITE}"
    fi
    if ! grep -Fxq "vm.swappiness=$SWAPPINESS_VALUE" /etc/sysctl.conf; then
        echo -e "${RED}Ошибка${WHITE}: vm.swappiness не сохранён в /etc/sysctl.conf."
        return 1
    fi
}

function create_swapfile() {
    echo
    local ACTIVE_SWAP
    if ! ACTIVE_SWAP=$(swapon --show=NAME --noheadings --raw); then
        echo -e "${RED}Ошибка${WHITE}: не удалось получить список активных swap устройств."
        return 1
    fi

    if [ -n "$ACTIVE_SWAP" ]; then
        echo "Активные swap устройства:"
        swapon --show
        echo
    fi

    # Zram хранит данные в оперативной памяти и не заменяет резервный swap на диске.
    if echo "$ACTIVE_SWAP" | awk 'NF && $1 !~ "^/dev/zram[0-9]+$" { found=1 } END { exit !found }'; then
        local DISK_SWAP_SIZE
        DISK_SWAP_SIZE=$(swapon --show=NAME,SIZE --noheadings --raw --bytes | awk '$1 !~ "^/dev/zram[0-9]+$" { total += $2 } END { print total + 0 }')
        DISK_SWAP_SIZE=$(awk -v bytes="$DISK_SWAP_SIZE" 'BEGIN { printf "%.1fG", bytes / 1024 / 1024 / 1024 }')
        echo -e "${GREEN}Дисковый swap${WHITE} размером ${GREEN}$DISK_SWAP_SIZE${WHITE} уже активен. Подключение swap файла не требуется."
        if printf '%s\n' "$ACTIVE_SWAP" | awk '$1 == "/swapfile" { found=1 } END { exit !found }'; then
            ensure_swapfile_configuration "/swapfile" 10 || return 1
        fi
    else
        if [ -n "$ACTIVE_SWAP" ]; then
            echo -e "Обнаружен только ${YELLOW}zram swap${WHITE}."
            echo "Рекомендуется создать swap файл на диске как резерв при нехватке памяти."
        fi

        echo "Swap файл не найден."
        local TOTAL_MEM
        TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
        local SWAP_FILE="/swapfile"
        local SWAP_SIZE
        local RECOMMENDED_SWAP_GB

        if [ "$TOTAL_MEM" -lt 2048 ]; then
            RECOMMENDED_SWAP_GB=$(( (TOTAL_MEM * 2 + 1023) / 1024 ))
        elif [ "$TOTAL_MEM" -lt 4096 ]; then
            RECOMMENDED_SWAP_GB=$(( (TOTAL_MEM + 1023) / 1024 ))
        else
            RECOMMENDED_SWAP_GB=4
        fi

        local def="default=1"
        local menu_items=("Не создавать swap файл" "Создать рекомендуемый swap файл размером ${RECOMMENDED_SWAP_GB} GiB")
        local menu_sizes=("" "${RECOMMENDED_SWAP_GB}G")
        local size

        for size in 1 2 4; do
            if [ "$size" -ne "$RECOMMENDED_SWAP_GB" ]; then
                menu_items+=("Создать swap файл размером ${size} GiB")
                menu_sizes+=("${size}G")
            fi
        done

        echo -e "Размер памяти сервера: ${GREEN}${TOTAL_MEM}${WHITE} Mb"
        if [ "$TOTAL_MEM" -lt 1024 ]; then
          echo -e "Для вас ${YELLOW}обязательно${WHITE} требуется ${YELLOW}включение swap файла${WHITE}."
        fi
        echo "Рекомендуется включить swap файл как резерв при нехватке памяти."
        echo "Его размер можно изменить позже в зависимости от нагрузки."
        echo -e "Рекомендуемый размер swap файла: ${GREEN}${RECOMMENDED_SWAP_GB} GiB${WHITE}"
        vertical_menu "current" 2 0 5 "${def}" "${menu_items[@]}"
        choice=$?

        if [ "$choice" -eq 0 ]; then
          echo -e "Swap файл ${YELLOW}не был создан${WHITE}."
          return
        fi

        SWAP_SIZE="${menu_sizes[$choice]}"

        echo -e "Создание swap файла размером ${GREEN}$SWAP_SIZE${WHITE}"

        if [ -e "$SWAP_FILE" ]; then
            echo -e "${RED}Ошибка${WHITE}: файл $SWAP_FILE уже существует."
            echo "Удалите или подключите его вручную после проверки содержимого."
            return 1
        fi

        # Создаем файл для swap
        fallocate -l "$SWAP_SIZE" "$SWAP_FILE"

        # Проверка на успех создания файла
        if [ $? -ne 0 ]; then
            echo -e "${RED}Ошибка${WHITE}: не удалось создать swap файл."
            exit 1
        fi

        # Назначаем правильные права доступа
        chmod 600 "$SWAP_FILE"

        # Создаем swap пространство
        mkswap "$SWAP_FILE"

        # Активируем swap
        swapon "$SWAP_FILE"

        # Проверяем статус swap
        if sudo swapon --show | grep -q "$SWAP_FILE"; then
            echo -e "Swap файл успешно ${GREEN}активирован${WHITE}."
        else
            echo -e "${RED}Ошибка${WHITE}: не удалось активировать swap файл."
            exit 1
        fi
        ensure_swapfile_configuration "$SWAP_FILE" 10 || return 1

    fi
    echo
}
