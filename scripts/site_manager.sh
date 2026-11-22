#!/usr/bin/env bash

site_manager_is_site_name() {
  [[ "$1" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]
}

site_manager_message() {
  printf '%b\n' "$1"
  vertical_menu "current" 2 0 5 "Нажмите Enter"
}

site_manager_user_is_available() {
  local user="$1" user_id user_root destination canonical_destination

  [[ "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || return 1
  user_id="$(id -u "$user" 2>/dev/null)" || return 1
  [[ "$user_id" =~ ^[0-9]+$ ]] && ((user_id > 0)) || return 1
  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sftp || return 1
  user_root="/var/www/${user}"
  destination="${user_root}/www"
  [[ -d "$user_root" && ! -L "$user_root" && -d "$destination" && ! -L "$destination" ]] || return 1
  canonical_destination="$(realpath -e -- "$destination" 2>/dev/null)" || return 1
  [[ "$canonical_destination" == "$destination" ]]
}

site_manager_choose_user() {
  local user choice page_start=0 page_end previous_index next_index cancel_index
  local -a users=()
  local -a labels=()

  SM_SELECTED_USER=""
  SM_CREATE_DIRECTORY=""
  while IFS= read -r user; do
    if site_manager_user_is_available "$user"; then
      users+=("$user")
    fi
  done < <(get_sftp_users | LC_ALL=C sort -u)

  clear
  if ((${#users[@]} == 0)); then
    site_manager_message "Нет доступных пользователей для размещения сайта.\nСначала создайте пользователя через пункт «Пользователи сервера»."
    return 1
  fi
  while true; do
    clear
    echo "Выберите пользователя, у которого будет создан сайт:"
    # Индекс 255 зарезервирован vertical_menu для Esc.
    page_end=$((page_start + 250))
    ((page_end <= ${#users[@]})) || page_end=${#users[@]}
    labels=()
    for user in "${users[@]:page_start:page_end-page_start}"; do
      labels+=("Пользователь: ${user}")
    done
    previous_index=-1
    next_index=-1
    if ((page_start > 0)); then
      previous_index=${#labels[@]}
      labels+=("Предыдущая страница")
    fi
    if ((page_end < ${#users[@]})); then
      next_index=${#labels[@]}
      labels+=("Следующая страница")
    fi
    cancel_index=${#labels[@]}
    labels+=("Отмена")
    vertical_menu "current" 2 20 20 "${labels[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#labels[@]} || choice == cancel_index)); then
      return 1
    fi
    if ((choice == previous_index)); then
      page_start=$((page_start - 250))
      continue
    fi
    if ((choice == next_index)); then
      page_start=$page_end
      continue
    fi
    SM_SELECTED_USER="${users[$((page_start + choice))]}"
    SM_CREATE_DIRECTORY="/var/www/${SM_SELECTED_USER}/www"
    return 0
  done
}

site_manager_resolve_context() {
  local current_directory current_www user_root user_real selected_real logical_real site_relative site_real parent_real document_root document_real

  SM_OUTSIDE_CONTEXT=0
  SM_CREATE_NEEDS_USER=0
  SM_SELECTED_PATH=""
  SM_SITE_DIRECTORY=""
  SM_SITE_NAME=""
  SM_SITE_PATH=""
  SM_DOCUMENT_ROOT=""
  SM_CREATE_NAME=""
  SM_CREATE_AVAILABLE=0
  SM_DELETE_AVAILABLE=0
  SM_CLEAR_AVAILABLE=0
  SM_SITE_AVAILABLE=0
  SM_PERMISSIONS_AVAILABLE=0
  SM_VHOST_EXISTS=0
  SM_WARNING=""

  if ! current_directory="$(realpath -ms -- "$SM_DIRECTORY" 2>/dev/null)"; then
    SM_WARNING="Не удалось определить текущий каталог."
    return 1
  fi
  if [[ ! "$current_directory" =~ ^(/var/www/([^/]+)/www)(/|$) ]]; then
    SM_OUTSIDE_CONTEXT=1
    SM_CREATE_NEEDS_USER=1
    SM_CREATE_AVAILABLE=1
    return 0
  fi
  current_www="${BASH_REMATCH[1]}"
  user_root="/var/www/${BASH_REMATCH[2]}"
  if [[ "$SM_FILE_NAME" == */* ]]; then
    SM_WARNING="Не переданы корректные параметры Midnight Commander."
    return 1
  fi
  if [[ "$SM_FILE_NAME" == ".." && "${current_directory%/*}" == "$current_www" ]]; then
    SM_FILE_NAME="."
  fi
  if ! SM_SELECTED_PATH="$(realpath -ms -- "${SM_DIRECTORY}/${SM_FILE_NAME}" 2>/dev/null)"; then
    SM_WARNING="Не удалось определить выбранный каталог."
    return 1
  fi
  if [[ "$SM_SELECTED_PATH" != "$user_root" && "$SM_SELECTED_PATH" != "$user_root/"* ]]; then
    SM_WARNING="Выберите каталог внутри /var/www/<пользователь>."
    return 1
  fi

  if ! user_real="$(realpath -e -- "$user_root" 2>/dev/null)"; then
    SM_WARNING="Каталог пользователя не найден."
    return 1
  fi
  SM_SITE_DIRECTORY="$current_www"
  if [[ -d "$current_www" ]] &&
    parent_real="$(realpath -e -- "$current_www" 2>/dev/null)" &&
    [[ "$parent_real" == "$user_real/"* ]]; then
    SM_CREATE_AVAILABLE=1
  fi
  selected_real="$(realpath -e -- "${SM_DIRECTORY}/${SM_FILE_NAME}" 2>/dev/null)" || selected_real=""
  logical_real="$(realpath -e -- "$SM_SELECTED_PATH" 2>/dev/null)" || logical_real=""
  if [[ "$selected_real" != "$logical_real" ]]; then
    SM_WARNING="Путь через символическую ссылку неоднозначен. Откройте фактический каталог."
    return 0
  fi
  if [[ -n "$selected_real" && "$selected_real" != "$user_real" && "$selected_real" != "$user_real/"* ]]; then
    SM_WARNING="Выбранный каталог выходит за пределы каталога пользователя."
    return 0
  fi
  if [[ -d "$SM_SELECTED_PATH" && "$SM_SELECTED_PATH" == "$current_www/"* ]]; then
    SM_PERMISSIONS_AVAILABLE=1
  fi

  if [[ "$SM_SELECTED_PATH" =~ ^(/var/www/[^/]+/www)(/(.*))?$ ]]; then
    SM_SITE_DIRECTORY="${BASH_REMATCH[1]}"
    site_relative="${BASH_REMATCH[3]}"
    SM_SITE_NAME="${site_relative%%/*}"
  else
    return 0
  fi

  # Переход на .. или . в www не должен превращаться в изменение прав всех сайтов.
  if [[ "$SM_SELECTED_PATH" == "$SM_SITE_DIRECTORY" &&
    ("$SM_FILE_NAME" == "." || "$SM_FILE_NAME" == "..") ]]; then
    SM_PERMISSIONS_AVAILABLE=0
  fi
  [[ -n "$SM_SITE_NAME" ]] || return 0
  SM_SITE_PATH="${SM_SITE_DIRECTORY}/${SM_SITE_NAME}"

  if site_manager_is_site_name "$SM_SITE_NAME" && [[ -f "/etc/httpd/conf.d/${SM_SITE_NAME}.conf" ]]; then
    SM_VHOST_EXISTS=1
  fi
  if ((SM_VHOST_EXISTS == 0)) && [[ -d "$SM_SELECTED_PATH" && "$SM_SELECTED_PATH" == "$SM_SITE_PATH" &&
    "$SM_FILE_NAME" != "." && "$SM_FILE_NAME" != ".." ]]; then
    SM_CREATE_NAME="$SM_SITE_NAME"
  fi
  ((SM_VHOST_EXISTS == 1)) || return 0
  [[ -d "$SM_SITE_PATH" ]] || return 0
  site_real="$(realpath -e -- "$SM_SITE_PATH" 2>/dev/null)" || return 0
  if [[ "$site_real" != "$parent_real/"* || -z "$selected_real" ||
    ("$selected_real" != "$site_real" && "$selected_real" != "$site_real/"*) ]]; then
    SM_WARNING="Фактический путь выбранного каталога не относится к этому сайту."
    return 0
  fi

  document_root="$(rish_read_vhost_document_roots "$SM_SITE_NAME" --inherit "/etc/httpd/conf.d/${SM_SITE_NAME}.conf")" || document_root=""
  document_root="${document_root%%$'\n'*}"
  document_real="$(realpath -m -- "$document_root" 2>/dev/null)" || document_real=""
  if [[ "$document_root" != /* || -z "$document_real" ||
    ("$document_real" != "$site_real" && "$document_real" != "$site_real/"*) ]]; then
    SM_WARNING="DocumentRoot конфигурации сайта не относится к выбранной папке."
    return 0
  fi
  # Отсутствующий DocumentRoot не должен мешать удалению неисправного сайта.
  SM_DELETE_AVAILABLE=1
  SM_DOCUMENT_ROOT="$(realpath -ms -- "$document_root" 2>/dev/null)" || SM_DOCUMENT_ROOT=""
  if [[ ! -L "$SM_SITE_PATH" &&
    ("$SM_DOCUMENT_ROOT" == "$SM_SITE_PATH" || "$SM_DOCUMENT_ROOT" == "$SM_SITE_PATH/"*) ]]; then
    SM_CLEAR_AVAILABLE=1
  fi
  if [[ ! -d "$document_real" ]]; then
    SM_WARNING="Каталог DocumentRoot не найден или не является каталогом."
    return 0
  fi
  SM_SITE_AVAILABLE=1
  return 0
}

site_manager_render_document_root() {
  python3 - "$1" "$2" "$3" "${4:-}" "${5:-render}" <<'PY'
from fnmatch import fnmatchcase
import os
import re
import shlex
import sys

filename, site, new_root, site_path, mode = sys.argv[1:]
with open(filename, encoding="utf-8", errors="surrogateescape", newline="") as source:
    config = source.read()

vhost = re.compile(r"^[ \t]*<VirtualHost[ \t]+[^>]+>.*?^[ \t]*</VirtualHost[ \t]*>", re.I | re.M | re.S)
server_host = re.compile(r"^[ \t]*(ServerName|ServerAlias)[ \t]+([^\r\n]+)", re.I | re.M)
include = re.compile(r"^[ \t]*Include(?:Optional)?[ \t]+([^\r\n]+)", re.I | re.M)
path_token = r"""("[^"\r\n]*"|'[^'\r\n]*'|[^\s"']+)"""
document_root = re.compile(r"^([ \t]*DocumentRoot[ \t]+)" + path_token + r"(?=[ \t]*(?:#.*)?\r?$)", re.I | re.M)
directory = re.compile(r"^([ \t]*<Directory[ \t]+)" + path_token + r"(?=[ \t]*>[ \t]*(?:#.*)?\r?$)", re.I | re.M)
site_names = {site, f"www.{site}"}
site_real = os.path.realpath(site_path) if site_path else None
matched = False

def fail(message):
    sys.exit(f"{message} ({os.path.basename(filename)})")

def hostname(value):
    return value.rsplit("://", 1)[-1].split(":", 1)[0].rstrip(".").lower()

def directive_values(line):
    try:
        return shlex.split(line, comments=True)
    except ValueError:
        fail("Не удалось прочитать директиву VirtualHost")

def matches_site(block):
    names = set()
    aliases = set()
    for directive, line in server_host.findall(block):
        values = directive_values(line)
        if any("${" in value for value in values):
            fail("Не удалось проверить имя VirtualHost с переменной")
        hosts = {hostname(value) for value in values}
        if directive.lower() == "servername":
            names.update(hosts)
        else:
            aliases.update(hosts)
    if site_names & (names | aliases):
        return True
    if any(fnmatchcase(name, alias) for name in site_names for alias in aliases):
        fail(f"VirtualHost может обслуживать {site} через шаблон ServerAlias")
    return False

def literal_path(token):
    path = token[1:-1] if token[0] in ('"', "'") else token
    return path.rstrip("/") or "/"

def replace_path(match):
    token = match[2]
    if literal_path(token) == new_root:
        return match[0]
    quote = token[0] if token[0] in ('"', "'") else ""
    if not quote and re.search(r"[\s<>#]", new_root):
        quote = '"'
    return match[1] + quote + new_root + quote

def replace_vhost(match):
    global matched
    block = match[0]
    directives = re.sub(r"\\\r?\n", "", block)
    if not matches_site(directives):
        return block
    # Certbot inserts this include for TLS settings into its HTTPS vhost.
    for argument in include.findall(directives):
        if directive_values(argument) != ["/etc/letsencrypt/options-ssl-apache.conf"]:
            fail(f"VirtualHost сайта {site} содержит внешний файл конфигурации")
    declared = len(re.findall(r"^[ \t]*DocumentRoot\b", block, re.I | re.M))
    roots = list(document_root.finditer(block))
    if len(roots) != 1 or declared != 1:
        fail(f"Не удалось однозначно определить DocumentRoot для {site}")
    old_root = literal_path(roots[0][2])
    if not old_root.startswith("/") or "${" in old_root or "\\" in old_root:
        fail(f"Не удалось проверить путь DocumentRoot для {site}")
    old_real = os.path.realpath(old_root)
    if site_real and os.path.commonpath((site_real, old_real)) != site_real:
        fail(f"DocumentRoot для {site} находится за пределами папки сайта: {old_root}")
    matched = True
    if mode == "check":
        if old_real != os.path.realpath(new_root):
            fail(f"DocumentRoot для {site} указывает на {old_root}")
        return block

    def replace_directory(section):
        if literal_path(section[2]) == old_root:
            return replace_path(section)
        return section[0]

    return document_root.sub(replace_path, directory.sub(replace_directory, block))

result = vhost.sub(replace_vhost, config)
if not matched and os.path.basename(filename) == site + ".conf":
    fail(f"В конфигурации не найден DocumentRoot для {site}")
if mode == "render":
    sys.stdout.buffer.write(result.encode("utf-8", "surrogateescape"))
PY
}

site_manager_apply_document_root() {
  local status=0
  site_manager_commit_document_root "$@" || status=$?
  ((status == 2)) && return 2
  vertical_menu current 2 0 5 "Нажмите Enter"
  return "$status"
}

site_manager_commit_document_root() (
  local conf_dir="$1" site="$SM_SITE_NAME" site_path="$SM_SITE_PATH" old_root="$SM_DOCUMENT_ROOT" new_root="$2"
  local mode="${3:-select}" confirm work name file lock_fd reload_attempted=0 restoring=0
  local after_change="${4:-}" finish_change="${5:-}" after_change_started=0
  local target_real site_user site_uid path index directory_id displayed_root folder columns
  local config_root="$new_root" site_real
  local -a missing=() created=() created_ids=()
  local input_count=0 current_count=0
  local -a configs=() touched=()

  if ! site_manager_document_root_path_ok "$site_path" "$new_root" ||
    ! site_manager_check_document_root "$site_path" "$new_root"; then
    echo "Выберите допустимую папку внутри сайта." >&2
    return 1
  fi
  target_real="$(realpath -m -- "$new_root")" || return 1
  case "$mode" in
    create)
      if [[ -e "$new_root" || -L "$new_root" ]]; then
        echo "Это имя уже занято. Выберите папку из списка или введите другое имя." >&2
        return 1
      fi
      ;;
    select)
      if [[ ! -d "$new_root" ]]; then
        echo "Выбранная папка больше не существует." >&2
        return 1
      fi
      ;;
    *) return 1 ;;
  esac

  # При выборе активной папки сохраняем путь, записанный в vhost развёрнутого через симлинк сайта.
  if [[ "$old_root" != "$site_path" && "$old_root" != "$site_path/"* ]]; then
    site_real="$(realpath -e -- "$site_path")" || return 1
    if [[ "$(realpath -m -- "$old_root")" == "$site_real${new_root#"$site_path"}" ]]; then
      config_root="$old_root"
    fi
  fi
  if [[ "$mode" == create && "$config_root" == "$old_root" ]]; then
    restoring=1
  fi
  work="$(mktemp -d -- "$conf_dir/.rish-documentroot.XXXXXX")" || return 1
  site_manager_finish_document_root() {
    local status=$? item failed=0 index
    trap - EXIT INT TERM HUP
    if ((after_change_started)); then
      trap '' INT TERM HUP
      # Finish or isolate the site's files before the original vhosts can serve them.
      if [[ -n "$finish_change" ]] && ! "$finish_change" "$status"; then
        printf 'Прежний DocumentRoot не восстановлен. Копии конфигураций Apache сохранены в %s.\n' "$work" >&2
        return
      fi
      if ((status != 0)); then
        for item in "${touched[@]}"; do
          if [[ -L "$conf_dir/$item" ]] || ! cmp -s -- "$work/applied/$item" "$conf_dir/$item"; then
            printf 'Конфигурация %s изменилась во время установки. Копии сохранены в %s.\n' "$item" "$work" >&2
            return
          fi
        done
      fi
    fi
    if ((status != 0)); then
      for item in "${touched[@]}"; do
        cp -a -- "$work/original/$item" "$work/restore/$item" &&
          mv -fT -- "$work/restore/$item" "$conf_dir/$item" || failed=1
      done
      if ((reload_attempted && !failed)); then
        apachectl configtest && systemctl reload httpd || failed=1
      fi
      if ((!failed)); then
        for ((index=${#created[@]}-1; index>=0; index--)); do
          item="${created[index]}"
          if [[ -n "${created_ids[index]}" && ! -L "$item" ]] &&
            [[ "$(stat -Lc '%d:%i' -- "$item" 2>/dev/null)" == "${created_ids[index]}" ]] &&
            site_manager_check_document_root "$site_path" "$item"; then
            runuser -u "$site_user" -- rmdir -- "$item" ||
              printf 'Созданная папка сохранена: %s\n' "$item" >&2
          fi
        done
      fi
    fi
    if ((failed)); then
      printf 'Не удалось завершить откат. Проверьте конфигурации Apache и копии в %s.\n' "$work" >&2
    else
      if ((status != 0 && ${#touched[@]})); then
        echo "Изменение отменено. Прежние конфигурации Apache восстановлены." >&2
      fi
      rm -rf -- "$work"
    fi
  }
  trap site_manager_finish_document_root EXIT
  trap 'exit 1' INT TERM HUP

  mkdir -- "$work/original" "$work/new" "$work/applied" "$work/restore" || return 1
  if [[ -L "$conf_dir/$site.conf" || ! -f "$conf_dir/$site.conf" ]]; then
    printf 'Нужен обычный файл конфигурации: %s\n' "$conf_dir/$site.conf" >&2
    return 1
  fi
  for file in "$conf_dir"/*.conf; do
    name="${file##*/}"
    if [[ ! -f "$file" ]]; then
      printf 'Нужен обычный файл конфигурации: %s\n' "$file" >&2
      return 1
    fi
    ((input_count += 1))
    cp -aL -- "$file" "$work/original/$name" &&
      cp -a -- "$work/original/$name" "$work/new/$name" || return 1
    if ! site_manager_render_document_root "$work/original/$name" "$site" "$config_root" "$site_path" >"$work/new/$name"; then
      printf 'Не удалось подготовить %s.\n' "$file" >&2
      return 1
    fi
    if ! cmp -s -- "$work/original/$name" "$work/new/$name"; then
      if [[ -L "$file" ]]; then
        printf 'DocumentRoot нужно изменить в файле, на который ссылается %s.\n' "$file" >&2
        return 1
      fi
      configs+=("$name")
    fi
  done
  if ((${#configs[@]} == 0)) && [[ "$mode" == select ]]; then
    printf 'Сайт %b%s%b уже использует папку %b%s%b.\n' "$GREEN" "$site" "$WHITE" "$GREEN" "$new_root" "$WHITE"
    return 0
  fi
  if [[ "$new_root" == "$site_path" ]]; then
    folder="корень сайта"
  else
    folder="папку «${new_root#"$site_path/"}»"
  fi
  if ((restoring)); then
    printf 'Восстановить публичную папку сайта %b%s%b?\n\n' "$GREEN" "$site" "$WHITE"
    printf 'Будет создана пустая папка  %b%s%b\n' "$GREEN" "$new_root" "$WHITE"
    if ((${#configs[@]})); then
      echo "Этот путь также будет назначен остальным конфигурациям сайта."
    fi
    confirm="Восстановить папку"
  else
    if [[ "$mode" == create ]]; then
      printf 'Создать и назначить %s для сайта %b%s%b?\n\n' "$folder" "$GREEN" "$site" "$WHITE"
      confirm="Создать и назначить"
    else
      if [[ "$new_root" == "$site_path" ]]; then
        printf 'Использовать корень сайта %b%s%b как публичную папку?\n\n' "$GREEN" "$site" "$WHITE"
      else
        printf 'Использовать %s для сайта %b%s%b?\n\n' "$folder" "$GREEN" "$site" "$WHITE"
      fi
      confirm="Использовать $folder"
      read -r _ columns < <(stty size 2>/dev/null)
      [[ "$columns" =~ ^[1-9][0-9]*$ ]] || columns=80
      if ((${#confirm} > columns - 10)); then
        confirm="Использовать эту папку"
      fi
    fi
    if [[ "$config_root" == "$old_root" ]]; then
      echo "В конфигурациях сайта указаны разные пути."
      printf 'Общая публичная папка  %b%s%b\n\n' "$GREEN" "$new_root" "$WHITE"
    else
      site_manager_format_path "$old_root" displayed_root
      printf 'Сейчас       %b%s%b\n' "$GREEN" "$displayed_root" "$WHITE"
      printf 'После смены  %b%s%b\n\n' "$GREEN" "$new_root" "$WHITE"
    fi
    if [[ "$mode" == create ]]; then
      echo "Новая папка будет пустой."
    fi
    echo "Файлы останутся на своих местах."
  fi
  echo
  vertical_menu current 2 0 24 "Отмена" "$confirm"
  [[ $? == 1 ]] || return 2

  exec {lock_fd}<"$conf_dir" && flock -n "$lock_fd" || {
    echo "Уже выполняется смена DocumentRoot." >&2
    return 1
  }
  if ! site_manager_resolve_context || ((!SM_DELETE_AVAILABLE)) ||
    [[ "$SM_SITE_PATH" != "$site_path" || "$SM_DOCUMENT_ROOT" != "$old_root" ]] ||
    ! site_manager_check_document_root "$site_path" "$new_root" ||
    [[ "$(realpath -m -- "$new_root")" != "$target_real" ]]; then
    echo "Путь сайта или DocumentRoot изменился. Операция отменена." >&2
    return 1
  fi
  if [[ "$mode" == create ]]; then
    if [[ -e "$new_root" || -L "$new_root" ||
      ( "$restoring" == 0 && ! -d "${new_root%/*}" ) ]]; then
      echo "Папка изменилась во время выбора. Откройте список заново." >&2
      return 1
    fi
    site_user="${SM_SITE_DIRECTORY%/www}"
    site_user="${site_user##*/}"
    site_uid="$(id -u -- "$site_user")" && [[ "$site_uid" =~ ^[1-9][0-9]*$ ]] || {
      echo "Не удалось определить пользователя сайта." >&2
      return 1
    }
    path="$new_root"
    while [[ "$path" == "$site_path/"* && ! -e "$path" && ! -L "$path" ]]; do
      missing+=("$path")
      path="${path%/*}"
    done
    if [[ ! -d "$path" || ${#missing[@]} -eq 0 ]]; then
      echo "Не удалось найти родительский каталог для новой папки." >&2
      return 1
    fi
    for ((index=${#missing[@]}-1; index>=0; index--)); do
      path="${missing[index]}"
      site_manager_check_document_root "$site_path" "$path" &&
        runuser -u "$site_user" -- mkdir -m 755 -- "$path" || return 1
      directory_id="$(stat -Lc '%d:%i' -- "$path")" || return 1
      created+=("$path")
      created_ids+=("$directory_id")
    done
  fi
  if [[ ! -d "$new_root" || "$(realpath -e -- "$new_root")" != "$target_real" ]] ||
    ! site_manager_check_document_root "$site_path" "$new_root"; then
    echo "Выбранная папка изменилась. Операция отменена." >&2
    return 1
  fi
  for file in "$conf_dir"/*.conf; do
    name="${file##*/}"
    ((current_count += 1))
    if [[ ! -f "$file" ]] || ! cmp -s -- "$work/original/$name" "$file"; then
      printf 'Конфигурация изменилась во время выбора: %s\n' "$file" >&2
      return 1
    fi
  done
  if ((current_count != input_count)); then
    echo "Список конфигураций Apache изменился во время выбора." >&2
    return 1
  fi
  if ((${#configs[@]} == 0)); then
    printf 'Папка DocumentRoot создана: %b%s%b\n' "$GREEN" "$new_root" "$WHITE"
  else
    for name in "${configs[@]}"; do
      if [[ -L "$conf_dir/$name" ]]; then
        printf 'Конфигурация изменилась во время выбора: %s\n' "$conf_dir/$name" >&2
        return 1
      fi
      if [[ -n "$after_change" ]]; then
        cp -a -- "$work/new/$name" "$work/applied/$name" || return 1
      fi
      touched+=("$name")
      mv -fT -- "$work/new/$name" "$conf_dir/$name" || return 1
    done
    apachectl configtest || return 1
    reload_attempted=1
    systemctl reload httpd || return 1
    printf 'Сайт %b%s%b теперь использует папку %b%s%b.\n' "$GREEN" "$site" "$WHITE" "$GREEN" "$new_root" "$WHITE"
  fi
  if [[ -n "$after_change" ]]; then
    after_change_started=1
    "$after_change" "$site" "$new_root" || return 1
  fi
)

site_manager_check_document_root() {
  local site_real document_real
  [[ "$2" == "$1" || "$2" == "$1/"* ]] || return 1
  site_real="$(realpath -e -- "$1")" && document_real="$(realpath -m -- "$2")" || return 1
  [[ ( "$document_real" == "$site_real" || "$document_real" == "$site_real/"* ) &&
    ( -d "$2" || ( ! -e "$2" && ! -L "$2" ) ) ]]
}

site_manager_document_root_name_ok() {
  case "$1" in
    ''|.|..|*/*|*[[:cntrl:]]*|*\"*|*\'*|*\\*|*'${'*|*'*'*|*'?'*|*'['*|*']'*) return 1 ;;
  esac
  local LC_ALL=C
  ((${#1} <= 255))
}

site_manager_document_root_path_ok() {
  local site_path="$1" path="$2" remaining
  [[ "$path" != "$site_path" ]] || return 0
  [[ "$path" == "$site_path/"* ]] || return 1
  remaining="${path#"$site_path/"}"/
  while [[ -n "$remaining" ]]; do
    site_manager_document_root_name_ok "${remaining%%/*}" || return 1
    remaining="${remaining#*/}"
  done
}

site_manager_format_path() {
  if [[ "$1" == *[[:cntrl:]]* ]]; then
    printf -v "$2" '%q' "$1"
  else
    printf -v "$2" '%s' "$1"
  fi
}

site_manager_document_root_label() {
  local prefix="$1" name="$2" suffix="$3" width="$4" display available
  site_manager_format_path "$name" display
  available=$((width - ${#prefix} - ${#suffix}))
  ((available >= 4)) || available=4
  if ((${#display} > available)); then
    display="${display:0:available-1}…"
  fi
  printf -v "$5" '%s%s%s' "$prefix" "$display" "$suffix"
}

site_manager_change_document_root() {
  local site_path="$SM_SITE_PATH" selected="" active="$SM_DOCUMENT_ROOT" site_real active_real
  local name path label mark focus choice action mode status rows width menu_height default_index
  local page=0 page_size=245 first last index restore=0
  local -a folders=("$site_path") labels actions

  if [[ -d "$SM_SELECTED_PATH" ]] && site_manager_check_document_root "$site_path" "$SM_SELECTED_PATH"; then
    selected="$SM_SELECTED_PATH"
    [[ "$selected" == "$site_path" ]] || folders+=("$selected")
  fi
  # При развёртывании через симлинк vhost может содержать физический путь.
  if [[ "$active" != "$site_path" && "$active" != "$site_path/"* ]]; then
    site_real="$(realpath -e -- "$site_path")" || return 1
    active_real="$(realpath -m -- "$active")" || return 1
    case "$active_real" in
      "$site_real") active="$site_path" ;;
      "$site_real/"*) active="$site_path/${active_real#"$site_real/"}" ;;
    esac
  fi
  if [[ "$active" != "$site_path" && "$active" != "$selected" ]] &&
    site_manager_check_document_root "$site_path" "$active"; then
    folders+=("$active")
    [[ -d "$active" ]] || restore=1
  fi
  while IFS= read -r -d '' name; do
    path="$site_path/$name"
    [[ "$path" != "$selected" && "$path" != "$active" ]] || continue
    if [[ -L "$path" ]] && { [[ ! -d "$path" ]] || ! site_manager_check_document_root "$site_path" "$path"; }; then
      continue
    fi
    folders+=("$path")
  done < <(find -H "$site_path" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -printf '%f\0' | LC_ALL=C sort -z)

  focus="${selected:-$active}"
  while true; do
    clear
    printf 'Публичная папка сайта %b%s%b\n\n' "$GREEN" "$SM_SITE_NAME" "$WHITE"
    echo "Выберите папку, из которой сайт будет отдавать файлы."
    echo
    read -r rows width < <(stty size 2>/dev/null)
    [[ "$rows" =~ ^[1-9][0-9]*$ ]] || rows=24
    [[ "$width" =~ ^[1-9][0-9]*$ ]] || width=80
    menu_height=$((rows > 6 ? rows - 6 : 1))
    width=$((width - 10))
    labels=("Создать и назначить новую папку…")
    actions=(create)
    default_index=1
    [[ "$focus" != create ]] || default_index=0
    # Оставляем место для служебных пунктов: индекс 255 означает Esc.
    first=$((page * page_size))
    last=$((first + page_size))
    for ((index = first; index < last && index < ${#folders[@]}; index++)); do
      path="${folders[index]}"
      mark=""
      if [[ "$path" == "$active" && "$restore" == 0 ]]; then
        mark=" — используется сейчас"
      fi
      if [[ "$path" == "$site_path" ]]; then
        site_manager_document_root_label "Корень сайта " "$SM_SITE_NAME" "$mark" "$width" label
      elif [[ "$path" == "$active" && "$restore" == 1 ]]; then
        site_manager_document_root_label "Восстановить " "${path#"$site_path/"}" " — каталог отсутствует" "$width" label
      else
        site_manager_document_root_label "" "${path#"$site_path/"}" "$mark" "$width" label
        case "$label" in
          # vertical_menu разбирает эти аргументы как параметры даже среди пунктов.
          default=*|nomouse) label=" $label" ;;
          # Одноимённый каталог должен отличаться от команды меню.
          Отмена|"Предыдущая страница"|"Следующая страница"|"${labels[0]}"|"Корень сайта $SM_SITE_NAME") label+="/" ;;
        esac
      fi
      [[ "$path" != "$focus" ]] || default_index=${#labels[@]}
      labels+=("$label")
      actions+=("$path")
    done
    if ((page > 0)); then
      labels+=("Предыдущая страница")
      actions+=(previous)
    fi
    if ((last < ${#folders[@]})); then
      labels+=("Следующая страница")
      actions+=(next)
    fi
    labels+=("Отмена")
    actions+=(cancel)
    vertical_menu current 2 "$menu_height" 32 "default=$default_index" "${labels[@]}"
    choice=$?
    action="${actions[choice]:-cancel}"
    focus="$action"
    mode=select
    case "$action" in
      create)
        printf 'Новая папка будет создана в %b%s%b.\n' "$GREEN" "$site_path" "$WHITE"
        echo "Введите имя папки, например public. Enter без имени вернёт к списку."
        while true; do
          IFS= read -r -e -p "Имя папки: " name || return 0
          [[ -n "$name" ]] || continue 2
          path="$site_path/$name"
          if ! site_manager_document_root_name_ok "$name"; then
            echo "Это имя нельзя использовать для папки DocumentRoot. Попробуйте другое."
          elif [[ -e "$path" || -L "$path" ]]; then
            echo "Такое имя уже занято. Введите другое имя или нажмите Enter для возврата."
          else
            break
          fi
        done
        mode=create
        ;;
      previous) page=$((page - 1)); continue ;;
      next) page=$((page + 1)); continue ;;
      cancel) return 0 ;;
      *)
        path="$action"
        if [[ "$path" == "$active" && "$restore" == 1 ]]; then
          mode=create
        fi
        ;;
    esac
    status=0
    site_manager_apply_document_root /etc/httpd/conf.d "$path" "$mode" || status=$?
    ((status == 2)) || return "$status"
  done
}

site_manager_clear_site() {
  local site_path="$SM_SITE_PATH" document_root="$SM_DOCUMENT_ROOT" site_user choice

  clear
  printf 'Очистить папку сайта %b%s%b?\n' "$GREEN" "$SM_SITE_NAME" "$WHITE"
  printf 'Папка: %b%s%b\n' "$GREEN" "$site_path" "$WHITE"
  printf 'Все файлы и подпапки %bбудут удалены%b, включая скрытые.\n' "$YELLOW" "$WHITE"
  printf 'Будет создан пустой DocumentRoot: %b%s%b\n' "$GREEN" "$document_root" "$WHITE"
  vertical_menu "current" 2 0 30 "Отмена" "Очистить папку"
  choice=$?
  ((choice == 1)) || return 0

  if ! site_manager_resolve_context || ((SM_CLEAR_AVAILABLE == 0)) ||
    [[ "$SM_SITE_PATH" != "$site_path" || "$SM_DOCUMENT_ROOT" != "$document_root" ]]; then
    site_manager_message "Путь сайта или DocumentRoot изменился. Очистка отменена."
    return 1
  fi
  site_user="${SM_SITE_DIRECTORY%/www}"
  site_user="${site_user##*/}"
  if ! cd -- "$SM_SITE_DIRECTORY"; then
    site_manager_message "Не удалось перейти в родительскую папку сайта. Очистка отменена."
    return 1
  fi
  SM_DIRECTORY="$SM_SITE_DIRECTORY"
  SM_FILE_NAME="$SM_SITE_NAME"
  if find "$site_path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + &&
    install -d -m 755 -o "$site_user" -g "$site_user" -- "$document_root" &&
    chown -R "$site_user:$site_user" -- "$site_path"; then
    site_manager_message "Папка сайта очищена. Пустой DocumentRoot создан."
  else
    site_manager_message "Не удалось полностью очистить папку сайта или создать DocumentRoot."
    return 1
  fi
}

site_manager_is_cms_action() {
  case "$1" in
    install_joomla|install_wordpress|install_opencart|install_phpmyadmin|audit_joomla_extensions|update_joomla|manage_joomla_users|run_manual_joomla_cli_command|fix_joomla_site_configuration) return 0 ;;
    *) return 1 ;;
  esac
}

site_manager_load_cms_context() {
  local index token
  local -a descriptor=()

  SM_CMS_DOCUMENT_ROOT=""
  SM_CMS_PHP_BIN=""
  SM_CMS_NAME=""
  SM_CMS_PMA_VERSION=""
  SM_CMS_PMA_PATH=""
  SM_CMS_WARNING=""
  SM_CMS_MENU_ITEMS=()
  SM_CMS_MENU_ACTIONS=()
  ((SM_SITE_AVAILABLE)) || return 0
  mapfile -d '' -t descriptor < <(
    bash "${RISH_HOME}/scripts/cms_install.sh" --describe "$SM_SITE_DIRECTORY" "$SM_SITE_NAME" 2>/dev/null
  )
  if ((${#descriptor[@]} < 6 || (${#descriptor[@]} - 6) % 2 != 0)) ||
    [[ "${descriptor[0]}" != rish-cms-v1 ]]; then
    SM_CMS_WARNING="Не удалось получить сведения CMS/phpMyAdmin."
    return 1
  fi
  for ((index = 6; index < ${#descriptor[@]}; index += 2)); do
    token="${descriptor[$index]}"
    if ! site_manager_is_cms_action "$token"; then
      SM_CMS_WARNING="Не удалось получить список действий CMS/phpMyAdmin."
      return 1
    fi
  done
  SM_CMS_DOCUMENT_ROOT="${descriptor[1]}"
  SM_CMS_PHP_BIN="${descriptor[2]}"
  SM_CMS_NAME="${descriptor[3]}"
  SM_CMS_PMA_VERSION="${descriptor[4]}"
  SM_CMS_PMA_PATH="${descriptor[5]}"
  for ((index = 6; index < ${#descriptor[@]}; index += 2)); do
    SM_CMS_MENU_ACTIONS+=("cms:${descriptor[$index]}")
    SM_CMS_MENU_ITEMS+=("${descriptor[$((index + 1))]}")
  done
}

site_manager_print_site_info() {
  local LC_ALL=en_US.UTF-8
  local site_label="Папка сайта:" public_label="Публичная папка (DocumentRoot):"
  local site_path public_path
  site_manager_format_path "$SM_SITE_PATH" site_path
  site_manager_format_path "${SM_DOCUMENT_ROOT:-${SM_CMS_DOCUMENT_ROOT:-не определена}}" public_path
  printf '%s%*s %b%s%b\n' "$site_label" "$((${#public_label} - ${#site_label}))" '' "$GREEN" "$site_path" "$WHITE"
  printf '%s %b%s%b\n' "$public_label" "$GREEN" "$public_path" "$WHITE"
  if [[ -n "$SM_CMS_PHP_BIN" ]]; then
    printf 'PHP сайта: %b%s%b\n' "$GREEN" "$SM_CMS_PHP_BIN" "$WHITE"
  fi
  if [[ -n "$SM_CMS_NAME" ]]; then
    printf 'CMS сайта: %b%s%b\n' "$GREEN" "$SM_CMS_NAME" "$WHITE"
  fi
  if [[ -n "$SM_CMS_PMA_VERSION" ]]; then
    printf 'phpMyAdmin: %b%s%b (установлен в %s)\n' "$GREEN" "$SM_CMS_PMA_VERSION" "$WHITE" "$SM_CMS_PMA_PATH"
  fi
  if [[ -n "$SM_CMS_WARNING" ]]; then
    printf '%s\n' "$SM_CMS_WARNING"
  fi
}

site_manager_build_menu() {
  local create_label="Создать сайт"

  SM_MENU_ITEMS=()
  SM_MENU_ACTIONS=()
  if ((SM_OUTSIDE_CONTEXT)); then
    SM_MENU_ITEMS=("Создать сайт" "Выйти")
    SM_MENU_ACTIONS=(create back)
    return 0
  fi
  if ((SM_PERMISSIONS_AVAILABLE)); then
    SM_MENU_ITEMS+=("Настроить права доступа каталога")
    SM_MENU_ACTIONS+=(permissions)
  fi
  if ((SM_CREATE_AVAILABLE)); then
    [[ -z "$SM_CREATE_NAME" ]] || create_label+=" ${SM_CREATE_NAME}"
    SM_MENU_ITEMS+=("$create_label")
    SM_MENU_ACTIONS+=(create)
  fi
  if ((SM_SITE_AVAILABLE)); then
    SM_MENU_ITEMS+=("Сменить версию PHP")
    SM_MENU_ACTIONS+=(php)
  fi
  if ((SM_DELETE_AVAILABLE)); then
    SM_MENU_ITEMS+=("Публичная папка сайта (DocumentRoot)")
    SM_MENU_ACTIONS+=(document_root)
  fi
  if ((SM_SITE_AVAILABLE)); then
    SM_MENU_ITEMS+=("${SM_CMS_MENU_ITEMS[@]}" "SSL-сертификаты")
    SM_MENU_ACTIONS+=("${SM_CMS_MENU_ACTIONS[@]}" ssl)
  fi
  if ((SM_DELETE_AVAILABLE)) && [[ -x "${RISH_HOME}/dns/.enabled" ]]; then
    SM_MENU_ITEMS+=("DNS")
    SM_MENU_ACTIONS+=(dns)
  fi
  if ((SM_SITE_AVAILABLE)) && [[ -x "${RISH_HOME}/composer/.enabled" ]]; then
    SM_MENU_ITEMS+=("Composer")
    SM_MENU_ACTIONS+=(composer)
  fi
  if ((SM_DELETE_AVAILABLE)); then
    SM_MENU_ITEMS+=("Удалить сайт ${SM_SITE_NAME}")
    SM_MENU_ACTIONS+=(delete)
  fi
  if ((SM_CLEAR_AVAILABLE)); then
    SM_MENU_ITEMS+=("Очистить папку сайта ${SM_SITE_NAME}")
    SM_MENU_ACTIONS+=(clear)
  fi
  SM_MENU_ITEMS+=("Назад")
  SM_MENU_ACTIONS+=(back)
}

site_manager_main() {
  local choice action default_action=permissions default_index index php_version php_branch server_ip

  RISH_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || return 1
  export RISH_HOME
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  WHITE='\033[0m'
  source "${RISH_HOME}/windows.sh" || return 1
  source "${RISH_HOME}/php_helpers.sh" || return 1
  source "${RISH_HOME}/scripts/site_helpers.sh" || return 1
  source "${RISH_HOME}/scripts/ssh_authentication.sh" || return 1

  SM_FILE_NAME="${1:-.}"
  SM_DIRECTORY="${2:-$PWD}"
  SM_DIRECTORY="${SM_DIRECTORY%/}"
  SM_DIRECTORY="${SM_DIRECTORY:-/}"

  while true; do
    clear
    if ! site_manager_resolve_context; then
      site_manager_message "$SM_WARNING"
      return 1
    fi
    site_manager_load_cms_context || :
    if ((SM_SITE_AVAILABLE || SM_DELETE_AVAILABLE)); then
      printf 'Управление сайтом %b%s%b\n' "$GREEN" "$SM_SITE_NAME" "$WHITE"
      if php_version="$(get_site_php_version "$SM_SITE_NAME")"; then
        php_branch="${php_version#php}"
        printf 'Текущая версия PHP: %b%s.%s%b\n' "$GREEN" "${php_branch:0:1}" "${php_branch:1}" "$WHITE"
      else
        echo "Текущая версия PHP: не определена"
      fi
      server_ip=$(ip route get 1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }') || server_ip=""
      printf 'IP сервера: %b%s%b\n' "$YELLOW" "${server_ip:-не определён}" "$WHITE"
      site_manager_print_site_info
    else
      echo "Управление сайтом"
    fi
    echo
    if ((SM_OUTSIDE_CONTEXT)); then
      echo "Сайт не выбран. Здесь можно создать новый сайт."
      echo
      echo "Для управления существующим сайтом:"
      echo "1. Выйдите из этого меню."
      echo "2. В MC откройте /var/www/<пользователь>/www"
      echo "   и установите курсор на папку нужного сайта."
      echo "3. Нажмите F2 и выберите «Управление сайтом»."
      echo
      echo "Для быстрого перехода к сайтам и другим папкам"
      printf '%s\n' 'нажмите в MC Ctrl+\ — откроется список закладок каталогов.'
      echo
    fi
    if [[ -n "$SM_WARNING" ]]; then
      printf '%s\n\n' "$SM_WARNING"
    fi
    site_manager_build_menu
    default_index=0
    for index in "${!SM_MENU_ACTIONS[@]}"; do
      if [[ "${SM_MENU_ACTIONS[$index]}" == "$default_action" ]]; then
        default_index=$index
        break
      fi
    done
    vertical_menu "current" 2 0 32 "default=$default_index" "${SM_MENU_ITEMS[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#SM_MENU_ACTIONS[@]})); then
      return 0
    fi
    action="${SM_MENU_ACTIONS[$choice]}"
    [[ "$action" != back ]] || return 0
    default_action="$action"

    # Пока открыто меню, сайт или признаки включённых модулей могли измениться.
    if ! site_manager_resolve_context; then
      site_manager_message "$SM_WARNING"
      return 1
    fi
    case "$action" in
      create)
        ((SM_CREATE_AVAILABLE)) || continue
        if ((SM_CREATE_NEEDS_USER)); then
          if site_manager_choose_user; then
            if site_manager_user_is_available "$SM_SELECTED_USER"; then
              bash "${RISH_HOME}/create_site.sh" "" "$SM_CREATE_DIRECTORY"
            else
              site_manager_message "Пользователь или каталог назначения изменился. Выберите пользователя заново."
            fi
          fi
        else
          bash "${RISH_HOME}/create_site.sh" "$SM_CREATE_NAME" "$SM_SITE_DIRECTORY"
        fi
        ;;
      permissions)
        ((SM_PERMISSIONS_AVAILABLE)) || continue
        bash "${RISH_HOME}/scripts/fix_permissions.sh" "$SM_DIRECTORY" "$SM_FILE_NAME"
        ;;
      dns)
        ((SM_DELETE_AVAILABLE)) || continue
        [[ -x "${RISH_HOME}/dns/.enabled" ]] || continue
        bash "${RISH_HOME}/scripts/dns/dns.sh" menu-from-mc "$SM_SITE_DIRECTORY" "$SM_SITE_NAME"
        ;;
      delete)
        ((SM_DELETE_AVAILABLE)) || continue
        bash "${RISH_HOME}/scripts/delete_site.sh" "$SM_SITE_DIRECTORY" "$SM_SITE_NAME"
        ;;
      clear)
        ((SM_CLEAR_AVAILABLE)) || continue
        site_manager_clear_site
        ;;
      document_root)
        ((SM_DELETE_AVAILABLE)) || continue
        site_manager_change_document_root
        ;;
      cms:*)
        ((SM_SITE_AVAILABLE)) || continue
        site_manager_load_cms_context || continue
        for index in "${!SM_CMS_MENU_ACTIONS[@]}"; do
          if [[ "${SM_CMS_MENU_ACTIONS[$index]}" == "$action" ]]; then
            bash "${RISH_HOME}/scripts/cms_install.sh" --action "${action#cms:}" "$SM_SITE_DIRECTORY" "$SM_SITE_NAME"
            break
          fi
        done
        ;;
      php|ssl|composer)
        ((SM_SITE_AVAILABLE)) || continue
        case "$action" in
          php) bash "${RISH_HOME}/change_php_version.sh" "$SM_SITE_NAME" "$SM_SITE_DIRECTORY" ;;
          ssl) bash "${RISH_HOME}/scripts/certs.sh" "$SM_SITE_NAME" ;;
          composer)
            [[ -x "${RISH_HOME}/composer/.enabled" ]] || continue
            bash "${RISH_HOME}/scripts/composer_manager.sh" site-menu "$SM_SITE_DIRECTORY" "$SM_SITE_NAME"
            ;;
        esac
        ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  site_manager_main "$@"
fi
