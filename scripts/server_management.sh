#!/usr/bin/env bash

# This module is sourced by ri.sh and uses its functions and globals.
# shellcheck disable=SC2154
ServerManagementMenu() {
  source $config_file
  options=("Создать пользователя"
    "Удалить пользователя"
    "Установка новых версий PHP"
    "Запретить авторизацию по паролю по SSH"
    "Включить/отключить управление DNS"
    "Выйти")
  Down
  echo
  echo -e "Версия ${GREEN}apache${WHITE}"
  httpd -v
  echo
  sshd -T | grep passwordauthentication
  echo
  echo -e "Установленные версии ${GREEN}PHP${WHITE}:"
  mapfile -t installed_versions < <(get_installed_php_version_labels)
  for installed in "${installed_versions[@]}"; do
    echo "       "$installed
  done

  while true; do

    vertical_menu "center" "center" 0 30 "${options[@]}"
    choice=$?

    case "$choice" in
    0)
      clear
      CreateUser
      ;;
    1)
      clear
      usrs=($(cat /etc/passwd | grep home | awk -F: '{ print $1}' | sort))
      if ((${#usrs[@]} > 0)); then
        echo "Выберите пользователя для удаления из системы"
        vertical_menu "current" 2 0 30 "${usrs[@]}"
        choice=$?
        echo -e ${CURSORUP}
        if ((choice < 255)); then
          DeleteUser ${usrs[${choice}]}
        fi
      else
        echo "В системе нет ни одного пользователя"
      fi
      ;;
    2)
      echo -e "Выбор и установка нужных версий ${GREEN}PHP${WHITE}"
      clear
      # Рисуем разделительную линию
      cursor_to $((${rim} + 1)) 1
      repl "─" $((${columns}))
      cursor_to $((${rim} + 2)) 1
      Up
      echo -e "Идет получение списка доступных версий ${GREEN}PHP${WHITE}. Ждите."
      Down
      php_multi_install
      clear
      # Рисуем разделительную линию
      cursor_to $((${rim} + 1)) 1
      repl "─" $((${columns}))
      cursor_to $((${rim} + 2)) 1
      ;;
    3)
      echo -e "Запретить авторизацию по ${RED}паролю${WHITE} для SSH?"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        echo -e -n "${CURSORUP}"
        # Обработка основного файла конфигурации
        process_ssh_config_file /etc/ssh/sshd_config
        # Обработка файлов в /etc/ssh/sshd_config.d
        for file in /etc/ssh/sshd_config.d/*.conf; do
          if [ -f "$file" ]; then
            process_ssh_config_file "$file"
          fi
        done
        systemctl restart sshd.service
        echo -e "Авторизация по паролю ${GREEN}запрещена${WHITE} ${ERASEUNTILLENDOFLINE} в файлах конфигурации."
        sshd -T | grep passwordauthentication
      else
        echo -e "${CURSORUP}Файл /etc/ssh/sshd_config ${VIOLET}не изменен${WHITE}.${ERASEUNTILLENDOFLINE}"
        echo -e
      fi
      ;;
    4)
      if [[ -d /root/rish/dns ]]; then
        if [[ -d /root/rish/dns_bak ]]; then
          dns_domains=0
          dns_bak_domains=0
          for domain_dir in /root/rish/dns/domains/*; do
            [[ -d "$domain_dir" ]] && ((dns_domains++))
          done
          for domain_dir in /root/rish/dns_bak/domains/*; do
            [[ -d "$domain_dir" ]] && ((dns_bak_domains++))
          done

          clear
          echo -e "Одновременно найдены текущие и резервные настройки ${GREEN}DNS${WHITE}."
          echo
          echo -e "Текущие настройки: ${YELLOW}/root/rish/dns${WHITE}"
          echo -e "Папок доменов: ${GREEN}${dns_domains}${WHITE}"
          echo
          echo -e "Резервные настройки: ${YELLOW}/root/rish/dns_bak${WHITE}"
          echo -e "Папок доменов: ${GREEN}${dns_bak_domains}${WHITE}"
          echo
          echo "Для отключения управления DNS должна остаться одна папка dns_bak."
          echo "Выберите, какие настройки сохранить:"
          vertical_menu "current" 2 0 48 \
            "Сохранить текущие настройки (доменов: ${dns_domains})" \
            "Сохранить резервные настройки (доменов: ${dns_bak_domains})" \
            "Отмена"
          dns_choice=$?

          case "$dns_choice" in
          0)
            echo
            echo -e "Резервные настройки ${YELLOW}/root/rish/dns_bak${WHITE} будут удалены."
            echo -e "Текущие настройки будут сохранены как ${YELLOW}/root/rish/dns_bak${WHITE}."
            echo "Продолжить?"
            vertical_menu "current" 2 0 5 "Нет" "Да"
            if (($? == 1)); then
              if rm -rf -- /root/rish/dns_bak && mv -- /root/rish/dns /root/rish/dns_bak; then
                echo -e "Управление ${GREEN}DNS${WHITE} отключено."
                echo -e "Текущие настройки сохранены в ${YELLOW}/root/rish/dns_bak${WHITE}."
              else
                echo -e "Не удалось отключить управление ${RED}DNS${WHITE}." >&2
              fi
            else
              echo "Настройки DNS не изменены."
            fi
            ;;
          1)
            echo
            echo -e "Текущие настройки ${YELLOW}/root/rish/dns${WHITE} будут удалены."
            echo -e "Будут сохранены резервные настройки из ${YELLOW}/root/rish/dns_bak${WHITE}."
            echo "Продолжить?"
            vertical_menu "current" 2 0 5 "Нет" "Да"
            if (($? == 1)); then
              if rm -rf -- /root/rish/dns; then
                echo -e "Управление ${GREEN}DNS${WHITE} отключено."
                echo -e "Резервные настройки сохранены в ${YELLOW}/root/rish/dns_bak${WHITE}."
              else
                echo -e "Не удалось отключить управление ${RED}DNS${WHITE}." >&2
              fi
            else
              echo "Настройки DNS не изменены."
            fi
            ;;
          *)
            echo "Настройки DNS не изменены."
            ;;
          esac
        else
          dns_domains=0
          for domain_dir in /root/rish/dns/domains/*; do
            [[ -d "$domain_dir" ]] && ((dns_domains++))
          done

          clear
          echo -e "Управление ${GREEN}DNS${WHITE} включено."
          echo -e "Папок доменов: ${GREEN}${dns_domains}${WHITE}"
          echo
          echo -e "Отключить управление ${RED}DNS${WHITE}?"
          echo -e "Настройки будут сохранены в ${YELLOW}/root/rish/dns_bak${WHITE}."
          vertical_menu "current" 2 0 5 "Нет" "Да"
          if (($? == 1)); then
            if mv -- /root/rish/dns /root/rish/dns_bak; then
              echo -e "Управление ${GREEN}DNS${WHITE} отключено."
              echo -e "Настройки сохранены в ${YELLOW}/root/rish/dns_bak${WHITE}."
            else
              echo -e "Не удалось отключить управление ${RED}DNS${WHITE}." >&2
            fi
          else
            echo "Настройки DNS не изменены."
          fi
        fi
      elif [[ -d /root/rish/dns_bak ]]; then
        dns_bak_domains=0
        for domain_dir in /root/rish/dns_bak/domains/*; do
          [[ -d "$domain_dir" ]] && ((dns_bak_domains++))
        done

        clear
        echo -e "Управление ${GREEN}DNS${WHITE} отключено."
        echo -e "В резервной копии папок доменов: ${GREEN}${dns_bak_domains}${WHITE}"
        echo
        echo -e "Включить управление ${GREEN}DNS${WHITE} и восстановить настройки?"
        vertical_menu "current" 2 0 5 "Нет" "Да"
        if (($? == 1)); then
          if mv -- /root/rish/dns_bak /root/rish/dns; then
            echo -e "Управление ${GREEN}DNS${WHITE} включено."
            echo -e "Настройки восстановлены из ${YELLOW}/root/rish/dns_bak${WHITE}."
            echo -e "Пункт ${GREEN}DNS${WHITE} появится в меню MC для каталогов сайтов."
          else
            echo -e "Не удалось включить управление ${RED}DNS${WHITE}." >&2
          fi
        else
          echo "Настройки DNS не изменены."
        fi
      else
        clear
        echo -e "Управление ${GREEN}DNS${WHITE} отключено."
        echo
        echo -e "Включить управление ${GREEN}DNS${WHITE}?"
        vertical_menu "current" 2 0 5 "Нет" "Да"
        if (($? == 1)); then
          if mkdir -p /root/rish/dns; then
            echo -e "Управление ${GREEN}DNS${WHITE} включено."
            echo -e "Пункт ${GREEN}DNS${WHITE} появится в меню MC для каталогов сайтов."
          else
            echo -e "Не удалось включить управление ${RED}DNS${WHITE}." >&2
          fi
        else
          echo "Настройки DNS не изменены."
        fi
      fi
      vertical_menu "current" 2 0 5 "Нажмите Enter"
      ;;
    *)
      RemoveRim
      clear
      break
      ;;
    esac
  done
}
