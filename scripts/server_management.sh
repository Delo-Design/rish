#!/usr/bin/env bash

# This module is sourced by ri.sh and uses its functions and globals.
# shellcheck disable=SC2154
RISH_DNS_RUNTIME_DIR="/root/rish/dns"
RISH_DNS_LEGACY_DISABLED_DIR="/root/rish/dns_bak"
RISH_DNS_MANAGEMENT_MARKER="${RISH_DNS_RUNTIME_DIR}/.enabled"
RISH_DNS_MANAGEMENT_MIGRATION_STEP=100

rish_dns_management_is_enabled() {
  [[ -x "$RISH_DNS_MANAGEMENT_MARKER" ]]
}

rish_dns_management_enable() {
  mkdir -p "$RISH_DNS_RUNTIME_DIR" || return 1
  install -m 700 /dev/null "$RISH_DNS_MANAGEMENT_MARKER"
}

rish_dns_management_disable() {
  rm -f -- "$RISH_DNS_MANAGEMENT_MARKER"
}

rish_dns_management_migrate_legacy_state() {
  if [[ -d "$RISH_DNS_RUNTIME_DIR" && -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
    return 2
  fi
  if [[ -e "$RISH_DNS_MANAGEMENT_MARKER" ]]; then
    chmod 700 "$RISH_DNS_MANAGEMENT_MARKER"
    return
  fi
  if [[ -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
    mv -- "$RISH_DNS_LEGACY_DISABLED_DIR" "$RISH_DNS_RUNTIME_DIR"
    return
  fi
  if [[ -d "$RISH_DNS_RUNTIME_DIR" ]]; then
    rish_dns_management_enable
  fi
}

rish_dns_management_mark_migration_completed() {
  if declare -F check_step >/dev/null 2>&1 &&
    declare -F mark_step_completed >/dev/null 2>&1 &&
    ! check_step "$RISH_DNS_MANAGEMENT_MIGRATION_STEP"; then
    mark_step_completed "$RISH_DNS_MANAGEMENT_MIGRATION_STEP"
  fi
}

rish_dns_domain_count() {
  local domain_dir
  local count=0

  for domain_dir in "$1"/domains/*; do
    [[ -d "$domain_dir" ]] && ((count++))
  done
  printf '%s' "$count"
}

ServerManagementMenu() {
  source $config_file
  options=("Установка новых версий PHP"
    "Включить/отключить Composer"
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
  echo
  if [[ -f /root/rish/scripts/composer_manager.sh ]]; then
    bash /root/rish/scripts/composer_manager.sh status
  else
    echo -e "Управление ${RED}Composer${WHITE}: модуль не найден."
  fi

  while true; do

    vertical_menu "center" "center" 0 30 "${options[@]}"
    choice=$?

    case "$choice" in
    0)
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
    1)
      if [[ -f /root/rish/scripts/composer_manager.sh ]]; then
        bash /root/rish/scripts/composer_manager.sh server-menu
      else
        echo -e "Модуль управления ${RED}Composer${WHITE} не найден."
        vertical_menu "current" 2 0 5 "Нажмите Enter"
      fi
      ;;
    2)
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
    3)
      if [[ -d "$RISH_DNS_RUNTIME_DIR" && -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
        dns_domains="$(rish_dns_domain_count "$RISH_DNS_RUNTIME_DIR")"
        dns_bak_domains="$(rish_dns_domain_count "$RISH_DNS_LEGACY_DISABLED_DIR")"

        clear
        echo -e "Одновременно найдены текущие и резервные настройки ${GREEN}DNS${WHITE}."
        echo
        echo -e "Текущие настройки: ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}"
        echo -e "Папок доменов: ${GREEN}${dns_domains}${WHITE}"
        echo
        echo -e "Резервные настройки: ${YELLOW}${RISH_DNS_LEGACY_DISABLED_DIR}${WHITE}"
        echo -e "Папок доменов: ${GREEN}${dns_bak_domains}${WHITE}"
        echo
        echo "Выберите, какие настройки сохранить в постоянном каталоге DNS:"
        vertical_menu "current" 2 0 48 \
          "Сохранить текущие настройки (доменов: ${dns_domains})" \
          "Сохранить резервные настройки (доменов: ${dns_bak_domains})" \
          "Отмена"
        dns_choice=$?

        case "$dns_choice" in
        0)
          echo
          echo -e "Резервные настройки ${YELLOW}${RISH_DNS_LEGACY_DISABLED_DIR}${WHITE} будут удалены."
          echo "Продолжить?"
          vertical_menu "current" 2 0 5 "Нет" "Да"
          if (($? == 1)); then
            if rm -rf -- "$RISH_DNS_LEGACY_DISABLED_DIR" &&
              rish_dns_management_disable; then
              rish_dns_management_mark_migration_completed
              echo -e "Текущие настройки сохранены в ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}."
            else
              echo -e "Не удалось привести настройки ${RED}DNS${WHITE} к единому состоянию." >&2
            fi
          else
            echo "Настройки DNS не изменены."
          fi
          ;;
        1)
          echo
          echo -e "Текущие настройки ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE} будут удалены."
          echo -e "Резервные настройки будут перенесены в ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}."
          echo "Продолжить?"
          vertical_menu "current" 2 0 5 "Нет" "Да"
          if (($? == 1)); then
            if rm -rf -- "$RISH_DNS_RUNTIME_DIR" &&
              mv -- "$RISH_DNS_LEGACY_DISABLED_DIR" "$RISH_DNS_RUNTIME_DIR" &&
              rish_dns_management_disable; then
              rish_dns_management_mark_migration_completed
              echo -e "Резервные настройки сохранены в ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}."
            else
              echo -e "Не удалось привести настройки ${RED}DNS${WHITE} к единому состоянию." >&2
            fi
          else
            echo "Настройки DNS не изменены."
          fi
          ;;
        *)
          echo "Настройки DNS не изменены."
          ;;
        esac
      elif [[ -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
        if mv -- "$RISH_DNS_LEGACY_DISABLED_DIR" "$RISH_DNS_RUNTIME_DIR"; then
          rish_dns_management_disable
          rish_dns_management_mark_migration_completed
        else
          echo -e "Не удалось восстановить настройки DNS в ${RED}${RISH_DNS_RUNTIME_DIR}${WHITE}." >&2
        fi
      fi

      if [[ -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
        vertical_menu "current" 2 0 5 "Нажмите Enter"
        continue
      fi

      dns_domains="$(rish_dns_domain_count "$RISH_DNS_RUNTIME_DIR")"
      clear
      if rish_dns_management_is_enabled; then
        echo -e "Управление ${GREEN}DNS${WHITE} включено."
        echo -e "Папок доменов: ${GREEN}${dns_domains}${WHITE}"
        echo
        echo -e "Отключить управление ${RED}DNS${WHITE}?"
        echo "Настройки и credentials останутся в постоянном каталоге."
        vertical_menu "current" 2 0 5 "Нет" "Да"
        if (($? == 1)); then
          if rish_dns_management_disable; then
            echo -e "Управление ${GREEN}DNS${WHITE} отключено."
            echo -e "Настройки сохранены в ${YELLOW}${RISH_DNS_RUNTIME_DIR}${WHITE}."
          else
            echo -e "Не удалось отключить управление ${RED}DNS${WHITE}." >&2
          fi
        else
          echo "Настройки DNS не изменены."
        fi
      else
        echo -e "Управление ${GREEN}DNS${WHITE} отключено."
        if [[ -d "$RISH_DNS_RUNTIME_DIR" ]]; then
          echo -e "Сохранено папок доменов: ${GREEN}${dns_domains}${WHITE}"
        fi
        echo
        echo -e "Включить управление ${GREEN}DNS${WHITE}?"
        vertical_menu "current" 2 0 5 "Нет" "Да"
        if (($? == 1)); then
          if rish_dns_management_enable; then
            rish_dns_management_mark_migration_completed
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
