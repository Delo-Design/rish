#!/usr/bin/env bash

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
  if ! rpm -q $@ >/dev/null 2>&1; then
    echo -e "Ставим ${GREEN}$@${WHITE}"
    if yum -y install $@; then
      echo -e "${GREEN}$@${WHITE} установлен"
    else
      echo -e "Установить ${RED}$@${WHITE} не удалось, очищаем кэш и пытаемся снова"
      # Очистка кэша yum и повторная попытка установки
      yum clean all
      yum makecache
      if yum -y install $@; then
        echo -e "${GREEN}$@${WHITE} установлен после очистки кэша"
      else
        echo -e "Установить ${RED}$@${WHITE} не удалось даже после очистки кэша"
        exit 1
      fi
    fi
    echo
  else
    echo -e "${GREEN}$@${WHITE} уже установлен"
  fi
}

STEP="Установка dnf-utils"
if ! check_step "$STEP"; then
  Install dnf-utils
  mark_step_completed "$STEP"
fi

STEP="Добавление папки tmp всем пользователям"
if ! check_step "$STEP"; then
  for dir in /var/www/*; do
    # Проверяем, что это директория
    if [ -d "$dir" ]; then
      # Создаем папку tmp в каждой найденной директории
      mkdir -p "$dir/tmp"
      echo "Папка tmp создана в $dir"
    fi
  done
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
                  # Если параметра нет, добавляем его в конец файла
                  echo "php_value[upload_tmp_dir] = /var/www/$username/tmp" >> "$conf_file"
                  echo "Добавлен параметр php_value[upload_tmp_dir] в $conf_file"
              else
                  echo "Параметр php_value[upload_tmp_dir] уже существует в $conf_file"
              fi
          done
      fi
  done
  mark_step_completed "$STEP"
fi
