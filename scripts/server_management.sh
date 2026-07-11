#!/usr/bin/env bash

# This module is sourced by ri.sh and uses its functions and globals.
# shellcheck disable=SC2154
ServerManagementMenu() {
  source $config_file
  options=("Создать пользователя"
    "Удалить пользователя"
    "Установка новых версий PHP"
    "Включить/отключить авторизацию по паролю по SSH"
    "Включить/отключить управление DNS"
    "Выйти")
  Down
  echo
  echo -e "Версия ${GREEN}apache${WHITE}"
  httpd -v
  echo
  print_effective_ssh_authentication
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
      mapfile -t usrs < <(
        awk -F: '$6 ~ /^\/home\// { print $1 }' /etc/passwd | sort
      )
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
      effective_settings="$(get_effective_ssh_authentication)" || effective_settings=""
      read -r password_authentication kbd_interactive_authentication <<<"$effective_settings"

      if [[ -z "$password_authentication" || -z "$kbd_interactive_authentication" ]]; then
        echo -e "${RED}Не удалось определить${WHITE} текущие настройки авторизации SSH."
        echo
        continue
      fi

      if [[ "$password_authentication" == "yes" || "$kbd_interactive_authentication" == "yes" ]]; then
        target_value="no"
        question_text="Запретить способы авторизации с вводом пароля для SSH?"
        result_text="запрещена"
        result_color="$GREEN"
      else
        target_value="yes"
        question_text="Разрешить авторизацию по паролю для SSH?"
        result_text="разрешена"
        result_color="$YELLOW"
      fi

      echo -e "${question_text/пароля/${YELLOW}пароля${WHITE}}"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        echo -e -n "${CURSORUP}"
        if configure_ssh_password_authentication "$target_value"; then
          echo -e "Авторизация по паролю для SSH ${result_color}${result_text}${WHITE}.${ERASEUNTILLENDOFLINE}"
          print_effective_ssh_authentication
        fi
      else
        echo -e "${CURSORUP}Настройки авторизации SSH ${VIOLET}не изменены${WHITE}.${ERASEUNTILLENDOFLINE}"
        echo
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
