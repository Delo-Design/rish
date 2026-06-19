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
source /root/rish/rish_config.sh
LocalServer="${LocalServer:-false}"
# Функция для сравнения версий (%%s нужен для макроподстановки mc.menu)

UpdateMcMenu() {
  local menu_template="/root/rish/templates/mc.menu"
  local local_menu_template="/root/rish/templates/mc.menu.local"
  local menu_target="/etc/mc/mc.menu"
  local v

  if [[ ! -f "$menu_template" ]]; then
    echo -e "${YELLOW}Шаблон меню ${menu_template} не найден, пропускаю обновление MC menu.${WHITE}"
    return 0
  fi

  cp "$menu_template" "$menu_target" || return 1

  if [[ "$LocalServer" == "true" ]]; then
    if [[ -f "$local_menu_template" ]]; then
      cat "$local_menu_template" >> "$menu_target" || return 1
    else
      echo -e "${YELLOW}Локальный шаблон меню ${local_menu_template} не найден.${WHITE}"
    fi
  fi

  v=$(tr -d '\r' < /root/rish/version | awk '{$1=$1;print}')
  sed -i "s/{VER}/$v/g" "$menu_target" || return 1
  echo -e "Меню Midnight Commander ${GREEN}обновлено${WHITE}."
}

# Удаление устаревших копий шаблонов из корня RISH
if [[ -f /root/rish/templates/mc.menu ]]; then
  rm -f /root/rish/mc.menu
fi
if [[ -f /root/rish/templates/mc.menu.local ]]; then
  rm -f /root/rish/mc.menu.local
fi
if [[ -f /root/rish/phpmyadmin_install.sh ]]; then
  if [[ -f /root/rish/scripts/phpmyadmin_install.sh ]]; then
    rm -f /root/rish/phpmyadmin_install.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/phpmyadmin_install.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/create_swapfile.sh ]]; then
  if [[ -f /root/rish/scripts/create_swapfile.sh ]]; then
    rm -f /root/rish/create_swapfile.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/create_swapfile.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/checkip.sh ]]; then
  if [[ -f /root/rish/scripts/checkip.sh ]]; then
    rm -f /root/rish/checkip.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/checkip.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/php_restart.sh ]]; then
  if [[ -f /root/rish/scripts/php_restart.sh ]]; then
    rm -f /root/rish/php_restart.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/php_restart.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/mariadb_install.sh ]]; then
  if [[ -f /root/rish/scripts/mariadb_install.sh ]]; then
    rm -f /root/rish/mariadb_install.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/mariadb_install.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/mariadb_repo_setup.sh ]]; then
  if [[ -f /root/rish/scripts/mariadb_repo_setup.sh ]]; then
    rm -f /root/rish/mariadb_repo_setup.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/mariadb_repo_setup.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/apache_restart.sh ]]; then
  if [[ -f /root/rish/scripts/apache_restart.sh ]]; then
    rm -f /root/rish/apache_restart.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/apache_restart.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/cron_users.sh ]]; then
  if [[ -f /root/rish/scripts/cron_users.sh ]]; then
    rm -f /root/rish/cron_users.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/cron_users.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/mariadb_restart.sh ]]; then
  if [[ -f /root/rish/scripts/mariadb_restart.sh ]]; then
    rm -f /root/rish/mariadb_restart.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/mariadb_restart.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/local_router.sh ]]; then
  if [[ -f /root/rish/scripts/local_router.sh ]]; then
    rm -f /root/rish/local_router.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/local_router.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
if [[ -f /root/rish/clonesite.sh ]]; then
  if [[ -f /root/rish/scripts/clonesite.sh ]]; then
    rm -f /root/rish/clonesite.sh
  else
    echo -e "${RED}Ошибка:${WHITE} установка RISH неполная."
    echo "Новый файл /root/rish/scripts/clonesite.sh не найден."
    echo "Повторите установку RISH через обновление."
    exit 1
  fi
fi
for archive in /root/rish/phpMyAdmin-*-all-languages.tar.gz; do
  if [[ -f "$archive" && -f "/root/rish/templates/$(basename "$archive")" ]]; then
    rm -f "$archive"
  fi
done

# Обновление меню Midnight Commander
if ! UpdateMcMenu; then
  echo -e "${RED}Ошибка:${WHITE} не удалось обновить меню Midnight Commander."
  exit 1
fi

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

configure_httpd_tmpfiles_override() {
  local vendor_conf="/usr/lib/tmpfiles.d/httpd.conf"
  local override_conf="/etc/tmpfiles.d/httpd.conf"
  local tmp_conf="${override_conf}.rish-tmp.$$"

  if [[ ! -f "$vendor_conf" ]] || ! awk '$1 == "d" && $2 == "/var/www" { found=1 } END { exit !found }' "$vendor_conf"; then
    if [[ -f "$override_conf" ]]; then
      echo "Удаляем больше не требуемую настройку tmpfiles для /var/www."
      rm -f "$override_conf" || return 1
    fi
    return 0
  fi

  install -d -m 755 /etc/tmpfiles.d || return 1
  awk '$1 == "d" && $2 == "/var/www" { $3="751"; $4="root"; $5="root" } { print }' "$vendor_conf" > "$tmp_conf" || return 1
  if [[ -f "$override_conf" ]] && cmp -s "$tmp_conf" "$override_conf"; then
    rm -f "$tmp_conf"
    return 0
  fi

  echo "Настраиваем постоянные права /var/www через tmpfiles."
  install -m 644 "$tmp_conf" "$override_conf" || return 1
  rm -f "$tmp_conf"
  systemd-tmpfiles --create "$override_conf"
}

STEP="Установка dnf-utils"
if ! check_step "$STEP"; then
  Install dnf-utils
  mark_step_completed "$STEP"
fi

STEP="Установка pv"
if ! check_step "$STEP"; then
  Install pv
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

source /root/rish/create_hotlist.sh
create_hotlist

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
            echo -e "${YELLOW}${username} ($(basename "$php_version_dir"))${WHITE}: отсутствует параметр php_value[upload_tmp_dir] "
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
        dir_name=$(basename "$dir")
        if [ -d "$dir" ] && [[ "$dir_name" != "cgi-bin" && "$dir_name" != "html" ]]; then
            # Проверяем, существует ли папка tmp
            if [ ! -d "$dir/tmp" ]; then
                # Если папки нет, создаем её и выводим сообщение
                mkdir "$dir/tmp"
                echo -e "${GREEN}${dir_name}${WHITE}: папка tmp создана в $dir"
                chown "${dir_name}:${dir_name}" "$dir/tmp"
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
                      echo -e "${GREEN}${username} ($(basename "$php_version_dir"))${WHITE}: Добавлен параметр php_value[upload_tmp_dir] в $conf_file"
                  else
                      echo -e "${username} ($(basename "$php_version_dir")): Параметр php_value[upload_tmp_dir] уже существует в $conf_file"
                  fi
              done
          fi
      done
      echo
      mapfile -t versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)

      # Перезапуск всех версий
      for version in "${versions[@]}"; do
        if /opt/remi/"${version}"/root/usr/sbin/php-fpm -t; then
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

configure_httpd_tmpfiles_override || {
  echo -e "${RED}Не удалось${WHITE} настроить постоянные права /var/www через tmpfiles."
  exit 1
}

ERROR_FOUND=0
ERRORS=()

check_dir() {
  local dir="$1"
  local expected_perm="$2"
  local expected_owner="$3"

  local actual_perm
  local actual_owner
  actual_perm=$(stat -c "%a" "$dir")
  actual_owner=$(stat -c "%U:%G" "$dir")

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
