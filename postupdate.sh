#!/usr/bin/env bash

source /root/rish/windows.sh
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
version_gt() {
  test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}
#Вспомогательное внутри сценария
LOG_FILE="/root/rish/logfile_rish_install.log"
# Путь к конфигурационному файлу
config_file="/root/rish/rish_config.sh"
# Проверка на существование файла лога
if [ ! -f "$LOG_FILE" ]; then
  echo "Отсутствует лог файл установки RISH. Установка была выполнена неверно."
  echo "Обновление невозможно."
  exit 1
fi
# Функция для проверки, был ли шаг выполнен
check_step() {
  local step=$1
  grep -Fxq "$step" "$LOG_FILE"
}
# Функция для записи выполненного шага
mark_step_completed() {
  local step=$1
  echo "$step" >>"$LOG_FILE"
}
source $config_file
# Функция для сравнения версий (%%s нужен для макроподстановки mc.menu)

Install() {
  if ! rpm -q "$@" >/dev/null 2>&1; then
    echo -e "Ставим ${GREEN}${*}${WHITE}"
    if yum -y install "$@"; then
      echo -e "${GREEN}${*}${WHITE} установлен"
    else
      echo -e "Установить ${RED}${*}${WHITE} не удалось, очищаем кэш и пытаемся снова"
      yum clean all
      yum makecache
      if yum -y install "$@"; then
        echo -e "${GREEN}${*}${WHITE} установлен после очистки кэша"
      else
        echo -e "Установить ${RED}${*}${WHITE} не удалось даже после очистки кэша"
        exit 1
      fi
    fi
    echo
  else
    echo -e "${GREEN}${*}${WHITE} уже установлен"
  fi
}

STEP="Установка dnf-utils"
if ! check_step "$STEP"; then
  Install dnf-utils
  mark_step_completed "$STEP"
fi

STEP="Установка jq и rclone"
if ! check_step "$STEP"; then
  Install jq
  Install rclone
  mark_step_completed "$STEP"
fi

STEP="Настройка hard_delete для Yandex remote"
if ! check_step "$STEP"; then
  echo -e "Проверяем параметр hard_delete для Yandex-подключений ${GREEN}rclone${WHITE}..."
  rclone_config_dump="$(rclone config dump 2>/dev/null || true)"
  yandex_total=0
  yandex_updated=0
  yandex_skipped=0
  yandex_failed=0

  if [ -z "$rclone_config_dump" ]; then
    yandex_failed=1
    echo -e "${YELLOW}Не удалось прочитать конфигурацию rclone (config dump).${WHITE}"
  else
    mapfile -t yandex_remotes < <(
      printf '%s' "$rclone_config_dump" \
        | jq -r 'to_entries[] | select((.value.type // "") == "yandex") | .key'
    )

    if [ "${#yandex_remotes[@]}" -eq 0 ]; then
      echo -e "${YELLOW}Yandex-подключения rclone не найдены, настройка hard_delete не требуется.${WHITE}"
    else
      for remote_name in "${yandex_remotes[@]}"; do
        yandex_total=$((yandex_total + 1))
        hard_delete_value="$(
          printf '%s' "$rclone_config_dump" \
            | jq -r --arg remote "$remote_name" '.[$remote].hard_delete // ""'
        )"
        hard_delete_value="$(printf '%s' "$hard_delete_value" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

        case "$hard_delete_value" in
          true|1|yes|on)
            yandex_skipped=$((yandex_skipped + 1))
            echo -e "${GREEN}${remote_name}${WHITE}: hard_delete уже включен"
            continue
            ;;
        esac

        if rclone config update "$remote_name" hard_delete true --non-interactive >/dev/null 2>&1; then
          yandex_updated=$((yandex_updated + 1))
          echo -e "Для ${GREEN}${remote_name}${WHITE}: включили параметр ${GREEN}hard_delete=true${WHITE}"
        else
          yandex_failed=$((yandex_failed + 1))
          echo -e "Для ${YELLOW}${remote_name}${WHITE}: не удалось применить hard_delete=true"
        fi
      done
    fi

    if [ "$yandex_total" -gt 0 ]; then
      echo -e "Yandex remote: всего ${GREEN}${yandex_total}${WHITE}, уже включено ${GREEN}${yandex_skipped}${WHITE}, обновлено ${GREEN}${yandex_updated}${WHITE}, ошибок ${YELLOW}${yandex_failed}${WHITE}"
    fi
  fi

  if [ "$yandex_failed" -eq 0 ]; then
    mark_step_completed "$STEP"
  else
    echo -e "${YELLOW}Шаг не помечен выполненным, повторим на следующем запуске postupdate.${WHITE}"
  fi
fi

STEP="Обновление hotlist"
if ! check_step "$STEP"; then
  source /root/rish/create_hotlist.sh
  create_hotlist
  mark_step_completed "$STEP"
fi

STEP="Инициализация шаблона заглушки Apache"
if ! check_step "$STEP"; then
  if [[ ! -f /root/rish/templates/apache-noindex.html ]]; then
    install -m 644 /root/rish/templates/default-apache-noindex.html /root/rish/templates/apache-noindex.html || exit 1
  fi
  mark_step_completed "$STEP"
fi

declare -A missing_tmp_param # ассоциативный массив: php_version_dir => username

shopt -s nullglob   # если *.conf не найден — массив пустой, цикл не выполнится
for php_version_dir in /etc/opt/remi/*; do
    [ -d "$php_version_dir" ] || continue

    php_fpm_dir="$php_version_dir/php-fpm.d"
    [[ -d "$php_fpm_dir" ]] || continue

    for conf_file in "$php_version_dir/php-fpm.d"/*.conf; do
        [[ $(basename "$conf_file") == "www.conf" ]] && continue
        username=$(basename "$conf_file" .conf)
        if ! grep -q "php_value\[upload_tmp_dir\]" "$conf_file"; then
            missing_tmp_param["$conf_file"]="/var/www/$username/tmp"
            echo -e "${YELLOW}${username} ($(basename $php_version_dir))${WHITE}: отсутствует параметр php_value[upload_tmp_dir] "
        fi
    done
done
shopt -u nullglob

if [ ${#missing_tmp_param[@]} -gt 0 ]; then
  echo
  echo -e "Обнаружены пользователи без параметра ${YELLOW}php_value[upload_tmp_dir]. ${GREEN}Исправить?${WHITE}"
  if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      for dir in /var/www/*; do
        # Проверяем, что это директория и она не является cgi-bin или html
        if [ -d "$dir" ] && [[ $(basename "$dir") != "cgi-bin" && $(basename "$dir") != "html" ]]; then
            # Проверяем, существует ли папка tmp
            if [ ! -d "$dir/tmp" ]; then
                # Если папки нет, создаем её и выводим сообщение
                mkdir "$dir/tmp"
                echo -e ${GREEN}$(basename "$dir")${WHITE}": папка tmp создана в $dir"
                chown $(basename "$dir"):$(basename "$dir") "$dir/tmp"
            fi
        fi
      done
      echo
      # Проходим по каждой версии PHP в /etc/opt/remi/
      for php_version_dir in /etc/opt/remi/*; do
          # Проверяем, что это директория
          if [ -d "$php_version_dir" ]; then
              # Ищем все конфиги php-fpm.d/ для каждого пользователя, кроме www.conf
              for conf_file in "$php_version_dir/php-fpm.d"/*.conf; do
                  # Пропускаем файл www.conf
                  if [[ $(basename "$conf_file") == "www.conf" ]]; then
                      continue
                  fi

                  # Извлекаем имя пользователя из имени файла
                  username=$(basename "$conf_file" .conf)

                  # Проверяем, существует ли параметр php_value[upload_tmp_dir]
                  if ! grep -q "php_value\[upload_tmp_dir\]" "$conf_file"; then
                      # Проверка последнего символа с помощью od
                      last_char=$(tail -c 1 "$conf_file" | od -An -t u1)
                      # ASCII код для перевода строки (\n) — это 10
                      if [ "$last_char" -ne 10 ]; then
                          echo "Добавляем перевод строки в конец '$conf_file'"
                          echo "" >> "$conf_file"
                      fi
                      # Если параметра нет, добавляем его в конец файла.
                      echo "php_value[upload_tmp_dir] = /var/www/$username/tmp" >> "$conf_file"
                      echo -e "${GREEN}${username} ($(basename $php_version_dir))${WHITE}: Добавлен параметр php_value[upload_tmp_dir] в $conf_file"
                  else
                      echo -e "${username} ($(basename $php_version_dir)): Параметр php_value[upload_tmp_dir] уже существует в $conf_file"
                  fi
              done
          fi
      done
      echo
      mapfile -t versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)

      # Перезапуск всех версий
      for version in "${versions[@]}"; do
        if /opt/remi/${version}/root/usr/sbin/php-fpm -t; then
          if systemctl restart "${version}-php-fpm"; then
            echo -e "Версия ${GREEN}${version}${WHITE} корректно перезапущена."
            echo
          else
            echo
            echo -e "Ошибка при перезапуске ${RED}${version}-php-fpm${WHITE}. Проверьте журналы для диагностики."
            echo
          fi

        else
          echo
          echo -e "Версия ${RED}${version}${WHITE} имеет проблемы в конфигурационных файлах."
          echo -e "Сервис ${RED}не был перезапущен${WHITE} и продолжает работать."
          echo
          systemctl status "${version}-php-fpm"
        fi
      done
  else
        echo -e "${YELLOW}Добавление параметра отменено пользователем.${WHITE}"
        echo
  fi
fi

# Удаление файла autoindex для httpd
# файл autoindex может появиться при обновлении httpd
if [ -f /etc/httpd/conf.d/autoindex.conf ]; then
    echo "Файл /etc/httpd/conf.d/autoindex.conf найден. Удаляем его."
    echo "Рекомендуем перезапустить сервер Apache после завершения обновления RISH."
    rm -f /etc/httpd/conf.d/autoindex.conf
fi

ERROR_FOUND=0
ERRORS=()

check_dir() {
  local dir="$1"
  local expected_perm="$2"
  local expected_owner="$3"

  local actual_perm=$(stat -c "%a" "$dir")
  local actual_owner=$(stat -c "%U:%G" "$dir")

  if [[ "$actual_perm" != "$expected_perm" || "$actual_owner" != "$expected_owner" ]]; then
    if [[ "$dir" == "/var/www" ]]; then
      ERRORS+=("${YELLOW}$dir${WHITE} имеет права ${YELLOW}$actual_owner $actual_perm${WHITE} ")
    else
      dir_name=$(basename "$dir")
      ERRORS+=("${YELLOW}$dir_name${WHITE} имеет права ${YELLOW}$actual_owner $actual_perm${WHITE} ")
    fi
    ERROR_FOUND=1
    return 1
  fi
  return 0
}

# Проверяем основную папку /var/www
check_dir "/var/www" "751" "root:root"

# Проверяем все подпапки первого уровня (кроме исключенных)
for subdir in /var/www/*/; do
  if [[ -d "$subdir" ]]; then
    dir_name=$(basename "$subdir")

    # Пропускаем исключенные папки
    case "$dir_name" in
    "cgi-bin"|"html")
      continue
      ;;
    *)
    # Проверяем подпапку: ожидаем root:<имя_папки> 750
      check_dir "$subdir" "750" "root:$dir_name"
      ;;
    esac
  fi
done

# Если найдены ошибки - выводим сообщение
if [[ $ERROR_FOUND -eq 1 ]]; then
  echo "Рекомендация: Усиление изоляции сайтов по пользователям"
  echo ""
  echo "Сейчас каталоги пользователей изолированы недостаточно."
  echo ""

  for error in "${ERRORS[@]}"; do
    echo -e "$error"
  done
  echo
  echo "Мы усилим изоляцию сайтов на уровне UNIX-пользователей."
  echo
  echo -e "${YELLOW}Что будет сделано?${WHITE}"
  echo "------------------"
  echo "  Будут исправлены права и владельцы корневых папок пользователей. "
  echo "  Это не затронет никакие файлы в сайтах и не скажется на их работе."
  echo
  echo -e "  ${YELLOW}На что повлияет?${WHITE}"
  echo "----------------"
  echo "  Если сайты одного пользователя читали данные из папок сайта другого пользователя, это будет заблокировано."
  echo "  Такие сайты должны находиться в папке одного пользователя или обмениваться данными через API."
  echo
  echo -e "Вы согласны на ${YELLOW}исправление прав папок?${WHITE}"

  if vertical_menu "current" 2 0 5 "Да" "Нет"
  then
    echo
    cur_owner=$(stat -c "%U:%G" /var/www)
    cur_perm=$(stat -c "%a" /var/www)

    if [[ "$cur_owner" != "root:root" ]]; then
      echo -e "Меняем владельца папки ${YELLOW}/var/www${WHITE} на ${YELLOW}root:root${WHITE} "
      chown root:root /var/www
    fi

    if [[ "$cur_perm" != "751" ]]; then
      echo -e "Меняем права папки ${YELLOW}/var/www${WHITE} на ${YELLOW}751${WHITE} "
      chmod 751 /var/www
    fi

    want_perm="750"

    for subdir in /var/www/*/; do
      dir_name=$(basename "$subdir")

      # Пропускаем системные каталоги
      case "$dir_name" in
      cgi-bin|html)
        continue
        ;;
      esac

      want_owner="root:${dir_name}"
      cur_owner=$(stat -c "%U:%G" "$subdir")
      cur_perm=$(stat -c "%a" "$subdir")

      if [[ "$cur_owner" != "$want_owner" ]]; then
        echo -e "Меняем владельца ${YELLOW}${want_owner}${WHITE} для ${YELLOW}$subdir${WHITE}"
        if ! chown "$want_owner" "$subdir" 2>/dev/null; then
          echo -e "Не удалось установить группу ${YELLOW}'${dir_name}'${WHITE} (возможно, группы нет). Пропускаю chown."
        fi
      fi

      if [[ "$cur_perm" != "$want_perm" ]]; then
        echo -e "Меняем права на ${YELLOW}${want_perm}${WHITE} для ${YELLOW}$subdir${WHITE}"
        chmod "$want_perm" "$subdir"
      fi
    done

    echo -e "Готово. Права и владельцы ${GREEN}приведены в порядок${WHITE}."
  else
    echo -e "Права папок ${YELLOW}не были исправлены${WHITE}."
    echo -e "При следующем обновлении ${YELLOW}RISH${WHITE} вам будет повторно предложено исправить права папок."
  fi

fi

# Предупреждение о переходе на новую систему бэкапов
cron_jobs="$(crontab -l 2>/dev/null || true)"
if printf '%s\n' "$cron_jobs" | grep -Eq '^[[:space:]]*[^#].*/root/rish/backup\.sh([[:space:]]|$)'; then
  echo
  echo -e "${YELLOW}Вы еще не перешли на новую систему бэкапов.${WHITE}"
  echo
  echo "В cron по-прежнему вызов старой системы бэкапов backup.sh."
  echo "Старая система основана на утилите ydcmd, которая уже "
  echo "не поддерживается автором и в любой момент может перестать работать."
  echo
  echo "Переключитесь на новую систему бэкапов - в cron замените  backup.sh на backup2.sh."
  echo
fi

# Установка версии скрипта в меню
v=$(tr -d '\r' < /root/rish/version | awk '{$1=$1;print}')
sed -i "s/{VER}/$v/g" /etc/mc/mc.menu

# Пост-апдейт проверка: в default-зоне закрыть сервис ispmanager, если он включён.

if firewall-cmd --get-services | grep -qw ispmanager; then
  ZoneName="$(firewall-cmd --get-default-zone 2>/dev/null)"

  # 1) Permanent
  if firewall-cmd --permanent --zone="$ZoneName" --query-service=ispmanager >/dev/null 2>&1; then
    echo -e "Закрываю сервис ${GREEN}ispmanager${WHITE} (permanent) в зоне ${ZoneName}"
    firewall-cmd --permanent --zone="$ZoneName" --remove-service=ispmanager
    firewall-cmd --reload >/dev/null 2>&1
  fi

  if firewall-cmd --zone="$ZoneName" --query-service=ispmanager >/dev/null 2>&1; then
    echo -e "Закрываю сервис ${GREEN}ispmanager${WHITE} (runtime) в зоне ${ZoneName}"
    firewall-cmd --zone="$ZoneName" --remove-service=ispmanager >/dev/null 2>&1
  fi
fi
