#!/usr/bin/env bash

function create_swapfile() {
    echo
    # Проверяем, есть ли активный swap
    if swapon --show | grep -q '^[^ ]'; then
        echo "Swap уже активен:"
        swapon --show
        echo "Подключение swap не требуется."
    else
        echo "Swap файл не найден."
        local TOTAL_MEM
        TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
        local SWAP_FILE="/swapfile"
        local SWAP_SIZE

        local def=""
        echo -e "Размер памяти сервера: ${GREEN}${TOTAL_MEM}${WHITE} Mb"
        if [ "$TOTAL_MEM" -lt 1024 ]; then
          echo "Для вас обязательно требуется включение swap файла. "
          def="default=1"
        elif [ "$TOTAL_MEM" -lt 4096 ]; then
          echo "При размере памяти менее 4Гб желательно включение swap файла. "
          echo "Однако это не обязательно – сервер будет работать и все зависит от нагрузки."
          echo "Swap файл можно будет включить позже, если понадобится."
          def="default=1"
        fi
        vertical_menu "current" 2 0 5 "Не создавать swap файл" "Создать swap  файл размером 1 Gb" "Создать swap  файл размером 2 Gb" ${def}
        choice=$?
        case "$choice" in
        0)
          echo "Swap файл не был создан."
          return
          ;;
        1)
          SWAP_SIZE="1G"
          ;;
        2)
          SWAP_SIZE="2G"
          ;;
        esac

        echo "Создание swap файла размером $SWAP_SIZE"

        # Создаем файл для swap
        fallocate -l $SWAP_SIZE $SWAP_FILE

        # Проверка на успех создания файла
        if [ $? -ne 0 ]; then
            echo "Ошибка: не удалось создать swap файл."
            exit 1
        fi

        # Назначаем правильные права доступа
        chmod 600 $SWAP_FILE

        # Создаем swap пространство
        mkswap $SWAP_FILE

        # Активируем swap
        swapon $SWAP_FILE

        # Проверяем статус swap
        if sudo swapon --show | grep -q "$SWAP_FILE"; then
            echo -e "Swap файл успешно ${GREEN}активирован${WHITE}."
        else
            echo -e "${RED}Ошибка${WHITE}: не удалось активировать swap файл."
            exit 1
        fi
        # Добавляем в /etc/fstab для автоматической активации при загрузке
        if ! grep -q "$SWAP_FILE" /etc/fstab; then
            echo "$SWAP_FILE none swap sw 0 0" | tee -a /etc/fstab > /dev/null
            echo -e "Swap добавлен в ${GREEN}/etc/fstab${WHITE}."
        else
            echo "Swap уже присутствует в /etc/fstab."
        fi
        
        # Устанавливаем значение vm.swappiness, если swap активен
        local SWAPPINESS_VALUE=10  # Здесь можно указать нужное значение
        echo "Настройка vm.swappiness в $SWAPPINESS_VALUE"

        # Устанавливаем значение на лету
        sysctl vm.swappiness=$SWAPPINESS_VALUE

        # Для постоянного изменения добавляем его в /etc/sysctl.conf, если его там нет
        if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
            echo "vm.swappiness=$SWAPPINESS_VALUE" | tee -a /etc/sysctl.conf
            echo "vm.swappiness добавлен в /etc/sysctl.conf"
        else
            # Если параметр уже существует, заменим его на новое значение
            sed -i "s/^vm.swappiness=.*/vm.swappiness=$SWAPPINESS_VALUE/" /etc/sysctl.conf
            echo "vm.swappiness обновлен в /etc/sysctl.conf"
        fi

    fi
    echo
}