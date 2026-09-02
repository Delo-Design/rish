#!/usr/bin/env bash

COMPLETED_STEPS_FILE="/root/rish/completed_steps"
LEGACY_COMPLETED_STEPS_FILE="/root/rish/logfile_rish_install.log"

declare -Ag RISH_STEP_TITLES=()
declare -Ag RISH_LEGACY_STEP_IDS=()
declare -Ag RISH_IGNORED_LEGACY_RECORDS=(
  ["Установка telnet"]=1
  ["Установка openssl"]=1
  ["Добавление папки tmp всем пользователям"]=1
  ["Отключение авторизации по паролю для SSH."]=1
)

# Номера шагов постоянны: их нельзя менять или повторно использовать.
# При изменении текста старое название нужно передать следующим аргументом как псевдоним.
rish_register_step() {
  local step_id="$1"
  local step_title="$2"
  local legacy_title

  RISH_STEP_TITLES["$step_id"]="$step_title"
  RISH_LEGACY_STEP_IDS["$step_title"]="$step_id"

  shift 2
  for legacy_title in "$@"; do
    RISH_LEGACY_STEP_IDS["$legacy_title"]="$step_id"
  done
}

rish_register_step 100 "Переход на отдельный признак управления DNS"
rish_register_step 200 "Установка dnf-utils"
rish_register_step 300 "Проверка обновлений сервера выполнена"
rish_register_step 400 "Установка языковых пакетов"
rish_register_step 500 "Установка кодировки консоли"
rish_register_step 600 "Проверка и отключение SELinux если понадобится"
rish_register_step 700 "Проверка и включение swap файла, если нужно"
rish_register_step 800 "Выбор типа установки сервера"
rish_register_step 900 "Установка mc, cronie, logrotate, idn2, epel-release, wget, tar"
rish_register_step 950 "Проверка ветки EPEL для минорной версии EL"
rish_register_step 1000 "Установка age для шифрования бэкапов"
rish_register_step 1100 "Установка pv"
rish_register_step 1200 "Ограничение пользовательского CRON через cron.allow"
rish_register_step 1300 "Установка httpd mod_ssl"
rish_register_step 1400 "Создание самоподписанного сертификата SSL на 10 лет"
rish_register_step 1500 "Настройка файла ssl.conf для включения по умолчанию http/2"
rish_register_step 1600 "Настройка автозапуска httpd при перезагрузке. Запуск httpd сейчас."
rish_register_step 1700 "Удаление файла autoindex для httpd"
rish_register_step 1800 "Установка прав 751 для /var/www"
rish_register_step 1900 "Настройка tmpfiles для прав /var/www"
rish_register_step 2000 "Открытие портов 80 и 443 для web"
rish_register_step 2100 "Закрытие портов cockpit"
rish_register_step 2200 "Отключение heartbeat module apache"
rish_register_step 2300 "Замена стандартной заглушки Alma на заглушку RISH"
rish_register_step 2400 "Инициализация шаблона заглушки Apache"
rish_register_step 2500 "Проверка на наличие ServerName и исправление если его нет."
rish_register_step 2600 "Перезапуск httpd"
rish_register_step 2700 "Установка htop"
rish_register_step 2800 "Настройка репозиториев для установки php"
rish_register_step 2900 "Установка php"
rish_register_step 3000 "Усиление изоляции PHP-FPM через systemd"
rish_register_step 3100 "Настройка файлов logrotate для httpd."
rish_register_step 3200 "Установка часового пояса." "Установка часового пояса для Москвы."
rish_register_step 3300 "Установка unzip"
rish_register_step 3400 "Установка jq и rclone"
rish_register_step 3500 "Настройка hard_delete для Yandex remote"
rish_register_step 3600 "Установка bind-utils"
rish_register_step 3700 "Создание хоста для ответа на обращения к несуществующим сайтам."
rish_register_step 3800 "Установка mcedit как основного редактора"
rish_register_step 3900 "Настройка задержки клавиши Esc в Midnight Commander"
rish_register_step 4000 "Установка репозиториев для MariaDB"
rish_register_step 4100 "Установка MariaDB"
rish_register_step 4200 "Установка certbot"
rish_register_step 4300 "Отключить почтовую службу"
rish_register_step 4400 "Делаем сервис apache автоматически перезапускаемым, в случае какого либо падения."
rish_register_step 4500 "Делаем сервис базы данных автоматически запускаемым, в случае какого либо падения"
rish_register_step 4600 "Создание меню для MC и папки для hotlist"
rish_register_step 4700 "Настройка ssh config для sftp пользователя на сайте"
rish_register_step 4800 "Усиление ограничений SFTP и перенос ключей"
rish_register_step 4900 "Создание первого пользователя"
rish_register_step 5000 "Перенос учетных данных пользователей в /root/rish/credentials"
rish_register_step 5100 "Предлагаем создать ключ доступ к серверу и вывести его на экран для копирования."
rish_register_step 5200 "Настройка способов авторизации SSH через 00-rish.conf"
rish_register_step 5300 "Обновление hotlist"
rish_register_step 5400 "Финальная проверка необходимости перезагрузки сервера"
rish_register_step 5500 "Устанавливаем признак выполненной настройки сервера"

unset -f rish_register_step

rish_step_is_registered() {
  local step_id="$1"
  [[ -n "${RISH_STEP_TITLES[$step_id]+registered}" ]]
}

check_step() {
  local step_id="$1"
  local grep_status

  if ! rish_step_is_registered "$step_id"; then
    echo "Неизвестный номер шага RISH: ${step_id}" >&2
    exit 1
  fi

  if [[ ! -f "$COMPLETED_STEPS_FILE" ]]; then
    echo "Файл выполненных шагов RISH не найден: ${COMPLETED_STEPS_FILE}" >&2
    exit 1
  fi

  grep -Eq "^${step_id}[[:space:]]" "$COMPLETED_STEPS_FILE"
  grep_status=$?

  case "$grep_status" in
    0)
      return 0
      ;;
    1)
      return 1
      ;;
    *)
      echo "Не удалось прочитать файл выполненных шагов RISH: ${COMPLETED_STEPS_FILE}" >&2
      exit 1
      ;;
  esac
}

mark_step_completed() {
  local step_id="$1"

  if check_step "$step_id"; then
    return 0
  fi

  if ! printf '%s %s\n' "$step_id" "${RISH_STEP_TITLES[$step_id]}" >>"$COMPLETED_STEPS_FILE"; then
    echo "Не удалось записать выполненный шаг RISH: ${step_id}" >&2
    exit 1
  fi
}

rish_migrate_completed_steps() {
  local temporary_file="${COMPLETED_STEPS_FILE}.tmp.$$"
  local legacy_step
  local step_id
  local -a unknown_records=()

  if ! install -m 600 /dev/null "$temporary_file"; then
    echo "Не удалось создать временный файл состояния RISH." >&2
    return 1
  fi

  while IFS= read -r legacy_step || [[ -n "$legacy_step" ]]; do
    [[ -n "$legacy_step" ]] || continue

    step_id="${RISH_LEGACY_STEP_IDS[$legacy_step]-}"
    if [[ -z "$step_id" ]]; then
      if [[ -n "${RISH_IGNORED_LEGACY_RECORDS[$legacy_step]+ignored}" ||
        "$legacy_step" == "MariaDB innodb_buffer_pool_size="* ]]; then
        continue
      fi
      unknown_records+=("$legacy_step")
      continue
    fi

    if ! grep -Eq "^${step_id}[[:space:]]" "$temporary_file"; then
      printf '%s %s\n' "$step_id" "${RISH_STEP_TITLES[$step_id]}" >>"$temporary_file" || {
        rm -f -- "$temporary_file"
        echo "Не удалось записать состояние шагов RISH." >&2
        return 1
      }
    fi
  done <"$LEGACY_COMPLETED_STEPS_FILE"

  if ! mv -f -- "$temporary_file" "$COMPLETED_STEPS_FILE"; then
    rm -f -- "$temporary_file"
    echo "Не удалось сохранить файл состояния шагов RISH." >&2
    return 1
  fi

  echo "Список выполненных шагов RISH обновлён."

  if ((${#unknown_records[@]} > 0)); then
    echo
    echo "Обнаружены старые записи, которые не используются текущей версией RISH:"
    printf '  %s\n' "${unknown_records[@]}"
    echo
    echo "Это не мешает обновлению RISH. Дополнительные действия не требуются."
  fi
}

initialize_completed_steps() {
  local allow_create="${1:-false}"

  if [[ -f "$COMPLETED_STEPS_FILE" ]]; then
    return 0
  fi

  if [[ -f "$LEGACY_COMPLETED_STEPS_FILE" ]]; then
    rish_migrate_completed_steps
    return
  fi

  if [[ "$allow_create" == "true" ]]; then
    install -m 600 /dev/null "$COMPLETED_STEPS_FILE"
    return
  fi

  echo "Отсутствует файл выполненных шагов RISH. Установка была выполнена неверно." >&2
  echo "Обновление невозможно." >&2
  return 1
}
