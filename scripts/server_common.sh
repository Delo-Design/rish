#!/usr/bin/env bash

# Shared server, package installation and split-screen UI helpers. Sourcing only defines functions.
# shellcheck disable=SC2154

rish_initialize_split_screen() {
  local size

  if ! size="$(stty size)"; then
    echo "Не удалось определить размер терминала." >&2
    return 1
  fi
  lines=${size% *}
  columns=${size#* }
  if [[ ! "$lines" =~ ^[0-9]+$ || ! "$columns" =~ ^[0-9]+$ ]] ||
    ((lines < 6 || columns < 1)); then
    echo "Не удалось определить размер терминала." >&2
    return 1
  fi
  upperY=1
  downY=$((lines / 2))
  rim=$((downY - 2))
  whereCursorIs="down"
}

Up() {
  if [[ ${whereCursorIs} == "down" ]]
  then
    downY=$( get_cursor_row )
    whereCursorIs="up"
    # ограничить скрол верхней части экрана
    echo -e ${ESC}"[1;${rim}r"
    cursor_to ${upperY} 1
  fi
}

Down() {
  if [[ ${whereCursorIs} == "up" ]]
  then
    upperY=$( get_cursor_row )
    echo -e ${ESC}"[$(( ${rim}+2));${lines}r"
    # Ограничить скрол нижней частью экрана
    cursor_to ${downY} 1
    whereCursorIs="down"
  fi
}

RemoveRim() {
  echo -e ${ESC}"[;r"
  cursor_to $(( ${rim} +1 )) 1
  echo -en ${ESC}"[0J"
}

rish_draw_split_screen() {
  clear
  cursor_to $((rim + 1)) 1
  repl "─" "$columns"
  cursor_to $((rim + 2)) 1
  Up
}

Install() {
    local ensure_latest=0
    local optional=0

    while [[ "${1:-}" == "--ensure-latest" || "${1:-}" == "--optional" ]]; do
        case "$1" in
            --ensure-latest) ensure_latest=1 ;;
            --optional) optional=1 ;;
        esac
        shift
    done

    if ((ensure_latest == 1)) || ! rpm -q "$@" >/dev/null 2>&1; then
        Up
        if ((ensure_latest == 1)); then
            echo -e "Устанавливаем или обновляем ${GREEN}${*}${WHITE}"
        else
            echo -e "Ставим ${GREEN}${*}${WHITE}"
        fi
        Down
        if yum -y install "$@"; then
            (( upperY -- ))
            Up
            echo -e "${GREEN}${*}${WHITE} установлен"
        else
            Up
            echo -e "Установить ${RED}${*}${WHITE} не удалось, очищаем кэш и пытаемся снова"
            Down
            yum clean all
            yum makecache
            if yum -y install "$@"; then
                Up
                echo -e "${GREEN}${*}${WHITE} установлен после очистки кэша"
            else
                Up
                echo -e "Установить ${RED}${*}${WHITE} не удалось даже после очистки кэша"
                if ((optional)); then
                    Down
                    return 1
                fi
                RemoveRim
                exit 1
            fi
        fi
        echo
    else
        Up
        echo -e "${GREEN}${*}${WHITE} уже установлен"
    fi
    Down
}

_rish_system_logrotate_debug() {
  local check_output

  if ! check_output="$(LC_ALL=C logrotate --debug /etc/logrotate.conf 2>&1)"; then
    printf 'Проверка конфигурации logrotate завершилась ошибкой:\n%s\n' "$check_output" >&2
    return 1
  fi
  printf '%s\n' "$check_output"
}

_rish_system_logrotate_missing_logs() {
  local check_output="$1"
  local log_path

  # Проверяем разобранные правила, а не наличие строки в файле или имени RPM.
  # considering log выводится и для отсутствующего пока журнала с missingok.
  for log_path in /var/log/secure /var/log/messages /var/log/cron /var/log/maillog /var/log/spooler; do
    if ! grep -Eq "^[[:space:]]*considering log ${log_path}$" <<<"$check_output"; then
      printf '%s\n' "$log_path"
    fi
  done
  return 0
}

rish_ensure_system_logrotate() {
  local os_major
  local check_output
  local missing_logs

  if ! os_major="$(awk -F= '$1 == "VERSION_ID" { gsub(/["\047]/, "", $2); split($2, version, "."); print version[1]; exit }' /etc/os-release)" ||
    [[ ! "$os_major" =~ ^(8|9|10)$ ]]; then
    echo "Не удалось определить поддерживаемую версию EL для ротации системных журналов." >&2
    return 1
  fi

  Install logrotate || return 1
  check_output="$(_rish_system_logrotate_debug)" || return 1

  # В EL8/10 правило входит в rsyslog. В EL9 оно может поставляться отдельно.
  # Полные пользовательские правила сохраняем; при частичных не добавляем
  # пакетное правило, которое могло бы создать повторяющиеся записи.
  if ! grep -Eq '^[[:space:]]*considering log /var/log/(secure|messages|cron|maillog|spooler)$' <<<"$check_output"; then
    Install rsyslog || return 1
    check_output="$(_rish_system_logrotate_debug)" || return 1
    if [[ "$os_major" == "9" ]] &&
      ! grep -Eq '^[[:space:]]*considering log /var/log/(secure|messages|cron|maillog|spooler)$' <<<"$check_output"; then
      Install rsyslog-logrotate || return 1
      check_output="$(_rish_system_logrotate_debug)" || return 1
    fi
  fi

  missing_logs="$(_rish_system_logrotate_missing_logs "$check_output")"
  if [[ -n "$missing_logs" ]]; then
    printf 'Не найдены действующие правила logrotate для журналов:\n%s\n' "$missing_logs" >&2
    echo "Проверьте штатные правила rsyslog и их подключение через /etc/logrotate.conf." >&2
    return 1
  fi

  if systemctl cat logrotate.timer >/dev/null 2>&1; then
    if ! systemctl enable --now logrotate.timer; then
      echo "Не удалось включить или запустить logrotate.timer." >&2
      return 1
    fi
    if ! systemctl is-enabled --quiet logrotate.timer || ! systemctl is-active --quiet logrotate.timer; then
      echo "logrotate.timer не перешёл в состояния enabled и active." >&2
      return 1
    fi
    echo "Ротация системных журналов проверена: используется logrotate.timer."
  elif [[ -x /etc/cron.daily/logrotate ]]; then
    Install cronie || return 1
    if ! systemctl enable --now crond.service; then
      echo "Не удалось включить или запустить crond.service." >&2
      return 1
    fi
    if ! systemctl is-enabled --quiet crond.service || ! systemctl is-active --quiet crond.service; then
      echo "crond.service не перешёл в состояния enabled и active." >&2
      return 1
    fi
    if ! command -v run-parts >/dev/null 2>&1 ||
      ! run-parts --test /etc/cron.daily 2>/dev/null | grep -Fxq /etc/cron.daily/logrotate; then
      echo "/etc/cron.daily/logrotate не включён в ежедневный запуск." >&2
      return 1
    fi
    echo "Ротация системных журналов проверена: используется /etc/cron.daily/logrotate через crond.service."
  else
    echo "Не найден механизм запуска logrotate: нет logrotate.timer и исполняемого /etc/cron.daily/logrotate." >&2
    return 1
  fi
  return 0
}
