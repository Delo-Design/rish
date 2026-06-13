#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'

source /root/rish/windows.sh

wait_for_enter() {
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}

fail() {
  echo -e "$1"
  wait_for_enter
  exit 1
}

run_step() {
  local label="$1"
  shift

  echo -e "${label}"
  if ! "$@"; then
    fail "Ошибка при выполнении шага: ${RED}${label}${WHITE}"
  fi
  echo -e "${GREEN}Готово${WHITE}"
}

directory="$1"
folder="$2"
directory="${directory%/}"
target_path="${directory}/${folder}"

if [[ -z "$directory" || -z "$folder" ]]; then
  fail "Не удалось определить выбранный каталог."
fi

if ! target_path="$(realpath -m -- "$target_path" 2>/dev/null)"; then
  fail "Не удалось определить полный путь выбранного каталога."
fi

if [[ ! -d "$target_path" ]]; then
  fail "Выбранный путь ${RED}${target_path}${WHITE} не является каталогом."
fi

user_name="${target_path#/var/www/}"
user_name="${user_name%%/*}"

if [[ "$target_path" != /var/www/* || -z "$user_name" || "$user_name" == "." || "$user_name" == ".." ]]; then
  fail "Настройка прав доступна только для каталогов внутри /var/www/<пользователь>."
fi

if [[ "$target_path" == "/var/www/${user_name}" ]]; then
  fail "Выберите папку сайта или вложенный каталог внутри ${GREEN}/var/www/${user_name}${WHITE}."
fi

target_name="$(basename -- "$target_path")"

echo -e "Настроить права и владельца для папки ${GREEN}${target_name}${WHITE} и всех вложенных в нее папок и файлов?"
echo -e "Путь: ${GREEN}${target_path}${WHITE}"
echo -e "Папки: ${GREEN}755${WHITE}, файлы: ${GREEN}644${WHITE}, владелец: ${GREEN}${user_name}:${user_name}${WHITE}"
echo -e "Special bits будут сняты с папок и файлов."
if vertical_menu "current" 2 0 5 "Да" "Нет"
then
  run_step "[1/5] Устанавливаем права 755 для папок..." \
    find "$target_path" -type d -exec chmod 755 {} +
  run_step "[2/5] Снимаем special bits с папок..." \
    find "$target_path" -type d -exec chmod u-s,g-s,-t {} +
  run_step "[3/5] Устанавливаем права 644 для файлов..." \
    find "$target_path" -type f -exec chmod 644 {} +
  run_step "[4/5] Снимаем special bits с файлов..." \
    find "$target_path" -type f -exec chmod u-s,g-s,-t {} +
  run_step "[5/5] Устанавливаем владельца ${user_name}:${user_name}..." \
    chown -R "${user_name}:${user_name}" "$target_path"

  echo -e "Права и владелец ${GREEN}приведены в порядок${WHITE}."
else
  echo "Никаких изменений не сделано."
fi

wait_for_enter
