#!/usr/bin/env bash

source /root/rish/windows.sh
source /root/rish/scripts/site_helpers.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'

function archive() {
  local path="$1"
  local folder="$2"
  local fullpath="$path/$folder"
  source /root/rish/rish_config.sh

  echo
  if [[ "$folder" == ".." || "$folder" == "." ]]; then
    echo -e "Вы выбрали ${YELLOW}$folder${WHITE}"
    echo -e "Нельзя архивировать ${RED}текущую${WHITE} или ${RED}родительскую${WHITE} директорию напрямую (. и ..)."
    return 1
  fi

  if [[ -f "$fullpath" ]]; then
    local filename
    filename=$(basename "$fullpath")
    local options=("archive_file::Создать архив файла ${filename}" "exit::Выйти")

    local menu_items=()
    for item in "${options[@]}"; do
      menu_items+=("${item#*::}")
    done

    vertical_menu "current" 1 0 60 "${menu_items[@]}"
    local choice=$?
    if [[ $choice -eq 255 || "${options[$choice]%%::*}" == "exit" ]]; then
      echo -e "Операция ${YELLOW}отменена${WHITE} пользователем."
      return
    fi

    local action="${options[$choice]%%::*}"
    [[ "$action" == "archive_file" ]] && archive_file "$fullpath"
    return
  fi

  # --- Размер папки до архивации ---
  if [[ -d "$fullpath" ]]; then
    # du считает логический размер (apparent-size), разыменовывая симлинки
    local size_bytes
    size_bytes=$(du --apparent-size --dereference -sm -- "$fullpath" | cut -f1)

    echo -e "Размер папки ${GREEN}$folder${WHITE}: ${YELLOW}${size_bytes} MB${WHITE}"
    echo
  fi

  local is_site=0
  if compgen -G "/etc/httpd/conf.d/${folder}*.conf" > /dev/null; then
    is_site=1
  fi

  local has_db=0
  if [[ -n "$(mariadb -qfsBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${folder}'" 2>/dev/null)" ]]; then
    has_db=1
  fi

  if [[ $is_site -eq 1 ]]; then
    echo -e "Папка является сайтом ${GREEN}${folder}${WHITE}"
  else
    echo -e "Папка не является ${YELLOW}сайтом${WHITE}."
  fi

  if [[ $has_db -eq 1 ]]; then
    echo -e "У сайта есть база данных с именем ${GREEN}${folder}${WHITE}."
  fi

  local options=()
  [[ $is_site -eq 1 && $has_db -eq 1 ]] && options+=("archive_site_and_db::Создать архив сайта ${folder} и базы данных ${folder}")
  options+=("archive_site::Создать архив папки ${folder}")
  [[ $has_db -eq 1 ]] && options+=("archive_db::Создать архив базы данных ${folder}")
  [[ $is_site -eq 1 && $has_db -eq 1 ]] && options+=("archive_site_with_exclude::Создать архив сайта ${folder} с исключениями и базы данных ${folder}")
  options+=("archive_folder_with_exclude::Создать архив папки ${folder} с исключениями")
  options+=("exit::Выйти")

  echo
  local menu_items=()
  for item in "${options[@]}"; do
    menu_items+=("${item#*::}")
  done

  vertical_menu "current" 1 0 60 "${menu_items[@]}"
  local choice=$?
  if [[ $choice -eq 255 || "${options[$choice]%%::*}" == "exit" ]]; then
    echo -e "Операция ${YELLOW}отменена${WHITE} пользователем."
    return 1
  fi

  local action="${options[$choice]%%::*}"
  local dt
  dt=$(date "+%Y-%m-%d_%H-%M")
  local base_name="${folder}_${dt}"
  local exclude_input
  local excl

  case "$action" in
    archive_site_and_db)
      archive_site "$fullpath" "$base_name"
      archive_db "$folder" "$base_name"
      ;;
    archive_site)
      archive_site "$fullpath" "$base_name"
      ;;
    archive_db)
      archive_db "$folder" "$base_name"
      ;;
    archive_site_with_exclude)
      local default_exclude="${ARCHIVE_EXCLUDE:-}"
      echo -e "Типовые примеры исключений:"
      echo -e "Для Joomla: ${YELLOW}administrator/cache,administrator/logs,cache,tmp${WHITE}"
      echo -e "Для Joomla Yootheme: ${YELLOW}administrator/cache,administrator/logs,cache,tmp,templates/yootheme/cache${WHITE}"
      echo -e "Для Joomla Akeeba: ${YELLOW}administrator/cache,administrator/logs,cache,tmp,administrator/components/com_akeeba/backup${WHITE}"
      echo
      echo -e "Введите папки для исключения (через запятую):${YELLOW}"
      read -r  -e -i "$default_exclude" exclude_input
      echo -e "${WHITE}"

      # Сохраняем в rish_config.sh
      if grep -q "^ARCHIVE_EXCLUDE=" /root/rish/rish_config.sh; then
        sed -i "s|^ARCHIVE_EXCLUDE=.*|ARCHIVE_EXCLUDE=\"${exclude_input}\"|" /root/rish/rish_config.sh
      else
        echo "ARCHIVE_EXCLUDE=\"${exclude_input}\"" >> /root/rish/rish_config.sh
      fi

      local IFS=',' exclude_arr=()
      read -ra exclude_arr <<< "$exclude_input"
      local exclude_args=()
      for excl in "${exclude_arr[@]}"; do
        excl=$(echo "$excl" | xargs)
        [[ -n "$excl" ]] && exclude_args+=("--exclude=$folder/${excl}/*")
      done
      archive_site "$fullpath" "$base_name" "${exclude_args[@]}"
      archive_db "$folder" "$base_name"
      ;;

    archive_folder_with_exclude)
      local default_exclude="${ARCHIVE_EXCLUDE:-}"
      echo -e "Типовые примеры исключений:"
      echo -e "Для Joomla: ${YELLOW}administrator/cache,administrator/logs,cache,tmp${WHITE}"
      echo -e "Для Joomla Yootheme: ${YELLOW}administrator/cache,administrator/logs,cache,tmp,templates/yootheme/cache${WHITE}"
      echo -e "Для Joomla Akeeba: ${YELLOW}administrator/cache,administrator/logs,cache,tmp,administrator/components/com_akeeba/backup${WHITE}"
      echo
      echo -e "Введите папки для исключения (через запятую):${YELLOW}"
      read -r -e -i "$default_exclude" exclude_input
      echo -e "${WHITE}"

      # Сохраняем в rish_config.sh
      if grep -q "^ARCHIVE_EXCLUDE=" /root/rish/rish_config.sh; then
        sed -i "s|^ARCHIVE_EXCLUDE=.*|ARCHIVE_EXCLUDE=\"${exclude_input}\"|" /root/rish/rish_config.sh
      else
        echo "ARCHIVE_EXCLUDE=\"${exclude_input}\"" >> /root/rish/rish_config.sh
      fi

      local IFS=',' exclude_arr=()
      read -ra exclude_arr <<< "$exclude_input"
      local exclude_args=()
      for excl in "${exclude_arr[@]}"; do
        excl=$(echo "$excl" | xargs)
        [[ -n "$excl" ]] && exclude_args+=("--exclude=$folder/${excl}/*")
      done
      archive_site "$fullpath" "$base_name" "${exclude_args[@]}"
      ;;
  esac

}

function archive_site() {
  local folder_path="$1"
  local archive_name="$2"
  shift 2
  local arg
  local extra_args=("$@")
  local parent_path="$(dirname "$folder_path")"
  local folder="$(basename "$folder_path")"
  local archive_path="${parent_path}/${archive_name}.tar.gz"

  # Формируем исключения для du
  local du_exclude=()
  for arg in "${extra_args[@]}"; do
    if [[ "$arg" =~ --exclude=.+ ]]; then
      du_exclude+=("--exclude=${arg#--exclude=}")
    fi
  done

  # Вычисление размера папки в мегабайтах с учетом исключений
  local folder_size_mb
  folder_size_mb=$(du --apparent-size --dereference -sm "${du_exclude[@]}" "$folder_path" | cut -f1)

  # Параметры для checkpoint
  local checkpoint=50000  # Проверять каждые 10 000 блоков
  local recordsize=1024   # Размер блока в байтах (для расчета в МБ)

  echo -e "Создаем архив ${GREEN}${folder}${WHITE}..."
  echo -e "Размер папки: ${YELLOW}${folder_size_mb} MB${WHITE}"
  echo

  if [[ ${#extra_args[@]} -gt 0 ]]; then
    echo -e "За исключением папок:"
    for arg in "${extra_args[@]}"; do
      if [[ "$arg" =~ --exclude=.+ ]]; then
        local clean_path="${arg#--exclude=}" # удалить --exclude=
        clean_path="${clean_path%/*}" # убрать /* в конце
        clean_path="${clean_path#*/}" # убрать $folder/ в начале
        echo -e " ${YELLOW}${clean_path}${WHITE}"
      fi
    done
    echo
  fi

  local tar_rc
  local tar_err_file
  local tar_reason=""

  tar_err_file="$(mktemp)" || {
    echo -e "${RED}Не удалось${WHITE} подготовить временный файл для анализа ошибок tar."
    return 2
  }

  # Команда tar с прогрессом, используя двойные кавычки
  tar -czhf "$archive_path" -C "$parent_path" "${extra_args[@]}" \
    --record-size=$recordsize --checkpoint=$checkpoint \
    --checkpoint-action=exec="echo -e \"${CURSORUP}Обработано: \$((TAR_CHECKPOINT / 1000)) MB${ERASEUNTILLENDOFLINE}\r\" >&2" \
    "$folder" \
    2> >(tee "$tar_err_file" >&2)
  tar_rc=$?
  echo -e "${CURSORUP}${ERASEUNTILLENDOFLINE}"

  if [[ -s "$tar_err_file" ]]; then
    tar_reason="$(grep '^tar:' "$tar_err_file" | sed 's/\r$//' | awk 'NR==1{out=$0;next}{out=out "; " $0} END{print out}')"
    if [[ -z "$tar_reason" ]]; then
      tar_reason="$(grep -v 'Обработано:' "$tar_err_file" | sed '/^[[:space:]]*$/d' | tail -n 1)"
    fi
  fi
  rm -f "$tar_err_file"

  case "$tar_rc" in
    0)
      echo -e "Архив ${GREEN}${archive_name}${WHITE} успешно создан."
      # Вывод размера конечного архива
      local archive_size_mb=$(du -sm "$archive_path" | cut -f1)
      echo -e "Размер архива: ${YELLOW}${archive_size_mb} MB${WHITE}"
      ;;
    1)
      echo -e "\n${YELLOW}Предупреждение${WHITE} при создании архива ${YELLOW}${archive_name}${WHITE} (код tar: 1)."
      if [[ -n "$tar_reason" ]]; then
        echo -e "Причина: ${YELLOW}${tar_reason}${WHITE}"
      fi
      ;;
    2)
      echo -e "\n${RED}Ошибка${WHITE} при создании архива ${RED}${archive_name}${WHITE} (код tar: 2)."
      if [[ -n "$tar_reason" ]]; then
        echo -e "Причина: ${RED}${tar_reason}${WHITE}"
      fi
      ;;
    *)
      echo -e "\n${RED}Ошибка${WHITE} при создании архива ${RED}${archive_name}${WHITE} (код tar: ${tar_rc})."
      if [[ -n "$tar_reason" ]]; then
        echo -e "Причина: ${RED}${tar_reason}${WHITE}"
      fi
      ;;
  esac

  return "$tar_rc"
}

function archive_db() {
  local dbname="$1"
  local base="$2"

  echo -e "Создаем архив базы данных ${GREEN}${dbname}${WHITE}..."

  if mariadb-dump \
      --extended-insert \
      --single-transaction \
      --quick \
      --routines \
      --events \
      --triggers \
      --quote-names \
      --order-by-primary \
      --hex-blob \
      "$dbname" \
    | sed '1{/999999.*sandbox/d}' \
    | sed '/NOTE_VERBOSITY/d' \
    | gzip > "${base}.sql.gz"; then

    echo -e "${CURSORUP}${ERASEUNTILLENDOFLINE}Архив базы данных ${GREEN}${base}.sql.gz${WHITE} создан."
  else
    echo -e "${RED}Ошибка${WHITE} при создании дампа базы ${RED}${dbname}${WHITE}"
  fi
}

function archive_file() {
  local filepath="$1"
  local filename="$(basename "$filepath")"
  local dt=$(date "+%Y-%m-%d_%H-%M")

  # Отделим имя и расширение
  local name="${filename%.*}"
  local ext="${filename##*.}"

  local archive_name="${name}_${dt}.${ext}.gz"

  echo -e "Создаем архив файла ${GREEN}${filename}${WHITE}..."
  gzip -c "$filepath" > "$archive_name" && \
  echo -e "Архив файла ${GREEN}${archive_name}${WHITE} создан."
}

function clean_directory_contents() {
  local target_dir="$1"
  local cleanup_dir="$target_dir"

  if [[ -L "$target_dir" ]]; then
    cleanup_dir="$(realpath "$target_dir")" || return 1
  fi

  [[ -d "$cleanup_dir" ]] || return 1
  find "$cleanup_dir" -mindepth 1 -delete
}

function inspect_tar_archive_layout() {
  local archive_path="$1"
  local entry top item seen
  local tar_list_file
  local -a root_dirs=()
  local -a root_files=()
  local -a root_items=()
  local -a sql_candidates=()

  ARCHIVE_SINGLE_ROOT_DIR=""
  ARCHIVE_SQL_ENTRY=""
  ARCHIVE_LAYOUT="mixed"

  tar_list_file="$(mktemp)" || {
    echo -e "${RED}Не удалось${WHITE} подготовить временный файл для проверки архива."
    return 1
  }

  if ! tar -tzf "$archive_path" > "$tar_list_file"; then
    echo -e "${RED}Ошибка${WHITE}: архив ${YELLOW}$(basename "$archive_path")${WHITE} поврежден или имеет неверный формат."
    rm -f "$tar_list_file"
    return 1
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue

    if [[ "$entry" == */* ]]; then
      top="${entry%%/*}"
      seen=0
      for item in "${root_dirs[@]}"; do
        if [[ "$item" == "$top" ]]; then
          seen=1
          break
        fi
      done
      [[ "$seen" -eq 0 ]] && root_dirs+=("$top")
    else
      root_files+=("$entry")
    fi
  done < "$tar_list_file"

  rm -f "$tar_list_file"

  root_items=("${root_dirs[@]}")
  for item in "${root_files[@]}"; do
    seen=0
    for top in "${root_items[@]}"; do
      if [[ "$top" == "$item" ]]; then
        seen=1
        break
      fi
    done
    [[ "$seen" -eq 0 ]] && root_items+=("$item")
  done

  if [[ "${#root_dirs[@]}" -eq 1 ]]; then
    ARCHIVE_SINGLE_ROOT_DIR="${root_dirs[0]}"
  fi

  local non_sql_root_files=0
  for item in "${root_files[@]}"; do
    if [[ "$item" == *.sql || "$item" == *.sql.gz ]]; then
      sql_candidates+=("$item")
    else
      non_sql_root_files=1
    fi
  done

  if [[ "${#sql_candidates[@]}" -gt 0 ]]; then
    if [[ -n "$ARCHIVE_SINGLE_ROOT_DIR" ]]; then
      local preferred_sql_gz="${ARCHIVE_SINGLE_ROOT_DIR}.sql.gz"
      local preferred_sql="${ARCHIVE_SINGLE_ROOT_DIR}.sql"
      for item in "${sql_candidates[@]}"; do
        if [[ "$item" == "$preferred_sql_gz" ]]; then
          ARCHIVE_SQL_ENTRY="$item"
          break
        fi
      done
      if [[ -z "$ARCHIVE_SQL_ENTRY" ]]; then
        for item in "${sql_candidates[@]}"; do
          if [[ "$item" == "$preferred_sql" ]]; then
            ARCHIVE_SQL_ENTRY="$item"
            break
          fi
        done
      fi
    fi
    [[ -z "$ARCHIVE_SQL_ENTRY" ]] && ARCHIVE_SQL_ENTRY="${sql_candidates[0]}"
  fi

  if [[ "${#root_dirs[@]}" -eq 1 && "${#root_files[@]}" -eq 0 ]]; then
    ARCHIVE_LAYOUT="single_dir"
  elif [[ "${#root_dirs[@]}" -eq 1 && "${#sql_candidates[@]}" -ge 1 && "$non_sql_root_files" -eq 0 ]]; then
    ARCHIVE_LAYOUT="site_plus_sql"
  fi
}


function restore_folder() {
  local archive_path="$1"
  local site_guess="$2"
  local mode="${3:-manual}"

  local folder_name="$site_guess"

  if [[ "$mode" != "auto" ]]; then
    echo -ne "${WHITE}Введите имя папки для восстановления: ${YELLOW}"
    read -e -i "$site_guess" folder_name
    echo -ne "${WHITE}"
  fi

  # Проверка существования папки
  if [[ -d "$folder_name" ]]; then
    if [[ -n "$(ls -A "$folder_name")" ]]; then
      echo -e "Папка ${YELLOW}${folder_name}${WHITE} уже существует и не пуста. Что делать?"
      vertical_menu "current" 2 0 60 "Очистить и извлечь" "Извлечь поверх существующих файлов" "Прервать извлечение"
      local choice=$?

      if [[ "$choice" -eq 255 || "$choice" -eq 2 ]]; then
        echo -e "Извлечение ${YELLOW}отменено${WHITE} пользователем."
        return 1
      elif [[ "$choice" -eq 0 ]]; then
        echo -e -n "${CURSORUP}${ERASEUNTILLENDOFLINE}"
        echo -e "${WHITE}Очищаем папку ${folder_name}...${WHITE}"
        clean_directory_contents "${folder_name:?}"
      else
        echo -e -n "${CURSORUP}${ERASEUNTILLENDOFLINE}"
        echo -e "${WHITE}Извлечение будет выполнено без очистки папки.${WHITE}"
      fi
    fi
  else
    mkdir -p "$folder_name"
  fi

  echo -e "Проверяем архив ${GREEN}$(basename "$archive_path")${WHITE} и подготавливаем распаковку в папку ${GREEN}${folder_name}${WHITE}..."

  if ! inspect_tar_archive_layout "$archive_path"; then
    echo -e "Восстановление ${YELLOW}прервано${WHITE}: не удалось прочитать архив."
    return 1
  fi

  echo -e "Начинаем распаковку архива в папку ${GREEN}${folder_name}${WHITE}..."

  local checkpoint=50000
  local recordsize=1024
  local tar_rc
  local extract_args=()

  if [[ "$ARCHIVE_LAYOUT" == "site_plus_sql" && -n "$ARCHIVE_SINGLE_ROOT_DIR" ]]; then
    extract_args=(--strip-components=1 -C "$folder_name" "$ARCHIVE_SINGLE_ROOT_DIR")
  elif [[ "$ARCHIVE_LAYOUT" == "single_dir" ]]; then
    extract_args=(--strip-components=1 -C "$folder_name")
  else
    extract_args=(-C "$folder_name")
  fi

  tar -xzf "$archive_path" \
    --record-size=$recordsize --checkpoint=$checkpoint \
    --checkpoint-action=exec="echo -e \"${CURSORUP}Обработано: \$((TAR_CHECKPOINT / 1000)) MB${ERASEUNTILLENDOFLINE}\r\" >&2" \
    "${extract_args[@]}"
  tar_rc=$?
  echo -e "${CURSORUP}${ERASEUNTILLENDOFLINE}"

  if [[ "$tar_rc" -ne 0 ]]; then
    echo -e "Произошла ${RED}ошибка${WHITE} при извлечении архива ${RED}$(basename "$archive_path")${WHITE}."
    return 1
  fi

  local abs_path
  abs_path="$(realpath "$folder_name")"

  if [[ "$abs_path" =~ ^/var/www/([^/]+)/www(/|$) ]]; then
    local user_dir="${BASH_REMATCH[1]}"
    chown -R "${user_dir}:${user_dir}" "$folder_name"
    echo -e "Все папки и файлы в восстановленной папке получили владельцем ${YELLOW}${user_dir}${WHITE}."
  fi

  echo -e "Архив успешно восстановлен в папку ${GREEN}${folder_name}${WHITE}."
}

function restore_site() {
  local file="$1"
  local site_guess="$2"
  local site_path="$(dirname "$file")"
  local skip_create=0
  local f
  local conf_file=""
  if [[ "$file" != *.tar.gz ]]; then
    echo -e "Файл ${RED}$(basename "$file")${WHITE} не является архивом tar.gz."
    echo -e "Восстановление ${YELLOW}отменено${WHITE}."
    return 1
  fi

  for f in /etc/httpd/conf.d/*.conf; do
    grep -q -E "^\s*ServerName\s+${site_guess}\s*$" "$f" && conf_file="$f" && break
  done

  if [[ -f "$conf_file" ]]; then
    local current_path
    current_path=$(awk '$1 == "DocumentRoot" { print $2; exit }' "$conf_file")

    if [[ -z "$current_path" ]]; then
      echo -e "Не удалось определить DocumentRoot в конфиге: ${RED}${conf_file}${WHITE}"
      return 1
    fi

    local current_user=""
    [[ "$current_path" =~ ^/var/www/([^/]+)/www/ ]] && current_user="${BASH_REMATCH[1]}"

    local archive_user=""
    [[ "$file" =~ ^/var/www/([^/]+)/www/ ]] && archive_user="${BASH_REMATCH[1]}"

    echo -e "Сайт ${YELLOW}${site_guess}${WHITE} уже существует и расположен в папке пользователя ${YELLOW}${archive_user}${WHITE}"

    local options=()
    if [[ "$current_user" == "$archive_user" ]]; then
      options+=("same_path::Восстановить в текущую папку ${site_guess}(${archive_user})")
    else
      echo
      echo -e "Если вы хотите восстановить из архива действующий сайт - переместите архив в папку пользователя ${GREEN}$current_user${WHITE}."
      echo -e "Для этого прервите восстановление и самостоятельно переместите архив с помощью midnight commander (это программа в которой вы работаете)."
      echo -e "Или просто выберите другое имя для сайта."
    fi
    options+=("rename::Задать другое имя для сайта")
    options+=("exit::Отменить восстановление")

    local menu_items=()
    for item in "${options[@]}"; do
      menu_items+=("${item#*::}")
    done

    vertical_menu "current" 2 0 60 "${menu_items[@]}"
    local choice=$?
    if [[ "$choice" -eq 255 ]]; then
      echo -e "Восстановление ${YELLOW}отменено${WHITE} пользователем."
      return
    fi

    local action="${options[$choice]%%::*}"
    case "$action" in
      same_path)
        echo -e "Сайт будет восстановлен в текущую папку."
        skip_create=1
        ;;
      rename)
        ;;
      exit)
        echo -e "Восстановление ${YELLOW}отменено${WHITE} пользователем."
        return 1
        ;;
    esac
  fi

  site_name=$site_guess
  local ret
  if [[ "$skip_create" -eq 0 ]]; then
    source /root/rish/create_site.sh
    create_site "$site_guess" "$site_path"
    ret=$?
    if (( ret == 1 )); then
      echo -e "Сайт ${YELLOW}$site_name${WHITE} не был создан. Восстановление прервано."
      return 1
    fi
  fi

  if ! restore_folder "$file" "$site_name" "auto"; then
    return 1
  fi

  local base="${file%.tar.gz}"
  local sql_file=""
  local temp_sql_dir=""
  [[ -f "${base}.sql.gz" ]] && sql_file="${base}.sql.gz"
  [[ -f "${base}.sql" ]] && sql_file="${base}.sql"

  if [[ -z "$sql_file" ]]; then
    inspect_tar_archive_layout "$file"
    if [[ -n "$ARCHIVE_SQL_ENTRY" ]]; then
      temp_sql_dir="$(mktemp -d "${site_path}/.restore_sql.XXXXXX")"
      if [[ -z "$temp_sql_dir" ]]; then
        echo -e "Не удалось подготовить временную папку для извлечения SQL."
      elif tar -xzf "$file" -C "$temp_sql_dir" "$ARCHIVE_SQL_ENTRY"; then
        sql_file="${temp_sql_dir}/${ARCHIVE_SQL_ENTRY}"
        echo -e "Найден SQL-файл внутри архива: ${GREEN}${ARCHIVE_SQL_ENTRY}${WHITE}"
      else
        echo -e "Не удалось извлечь SQL-файл ${RED}${ARCHIVE_SQL_ENTRY}${WHITE} из архива."
        rm -rf "$temp_sql_dir"
        temp_sql_dir=""
      fi
    fi
  fi

  if [[ -n "$sql_file" ]]; then
    echo -e "Найден файл базы данных: ${GREEN}$(basename "$sql_file")${WHITE}. Восстанавливаем..."
    if ! restore_db_auto "$sql_file" "$site_name"; then
      [[ -n "$temp_sql_dir" ]] && rm -rf "$temp_sql_dir"
      echo -e "Восстановление базы данных прервано."
      return 1
    fi
  fi

  [[ -n "$temp_sql_dir" ]] && rm -rf "$temp_sql_dir"

  fix_site_configuration "$site_path" "$site_name"
}

function restore_db_auto() {
  local file="$1"
  local dbname="$2"
  restore_db_core "$file" "$dbname" 0
  return $?
}

function restore_db_custom() {
  local file="$1"
  local dbname="$2"
  restore_db_core "$file" "$dbname" 1
  return $?
}

function restore_db_core() {
  local file="$1"
  local db_default="$2"
  local allow_edit="$3"
  local custom_db="$db_default"

  # Проверка на размещение в /var/www/<user>/www
  local user_dir=""
  local filepath="$(realpath "$file")"
  if [[ "$filepath" =~ ^/var/www/([^/]+)/www/ ]]; then
    user_dir="${BASH_REMATCH[1]}"
  else
    echo -e "Файл должен находиться в каталоге вида ${YELLOW}/var/www/<пользователь>/www${WHITE}..."
    echo -e "Переместите архив в соответствующую ${YELLOW}папку пользователя${WHITE}."
    return
  fi

  if [[ "$allow_edit" -eq 1 ]]; then
    echo -e "${WHITE}Введите имя базы данных (Пустая строка для выхода): ${YELLOW}"
    read -e -i "$db_default" custom_db
    echo -e "${WHITE}"
  fi

  if [[ -z "$custom_db" ]]; then
    echo -e "Имя базы данных не указано. ${YELLOW}Восстановление прервано.${WHITE}"
    return 1
  fi

  echo -e "Восстанавливаем базу данных ${GREEN}${custom_db}${WHITE} для пользователя ${YELLOW}${user_dir}${WHITE}..."

  # Проверка существования базы
  local check=$(mariadb -N -e "SHOW DATABASES LIKE '${custom_db}'" 2>/dev/null)

  if [[ "$check" != "$custom_db" ]]; then
    echo -e "База данных ${YELLOW}${custom_db}${WHITE} не существует. Создать?"
    if ! vertical_menu "current" 2 0 5 "Да" "Нет"; then
      echo -e "База ${YELLOW}${custom_db}${WHITE} не была создана. Импорт прерван."
      return 1
    fi

    if mariadb -e "CREATE DATABASE \`${custom_db}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
      echo -e "База данных ${GREEN}${custom_db}${WHITE} создана."
      mariadb -e "GRANT ALL PRIVILEGES ON \`${custom_db}\`.* TO '${user_dir}'@'localhost';"
      mariadb -e "FLUSH PRIVILEGES;"
      echo -e "Права на базу выданы пользователю ${GREEN}${user_dir}${WHITE}"
    else
      echo -e "Произошла ${RED}ошибка${WHITE} при создании базы ${RED}$custom_db${WHITE}."
      return 1
    fi
  else
    echo -e "База данных ${GREEN}${custom_db}${WHITE} уже существует."
  fi

  local SANDBOX_OPTION=""
  local -a mariadb_import_cmd=(mariadb)
  if mariadb --help | grep -q -- "--sandbox"; then
    SANDBOX_OPTION="--sandbox"
  fi
  [[ -n "$SANDBOX_OPTION" ]] && mariadb_import_cmd+=("$SANDBOX_OPTION")
  mariadb_import_cmd+=("$custom_db")

  echo -e "Импортируем базу из файла ${GREEN}$(basename "$file")${WHITE}..."

  if [[ "$file" == *.gz ]]; then
    if ! gzip -t "$file"; then
      echo -e "Файл ${RED}$(basename "$file")${WHITE} поврежден или не является корректным gzip-архивом."
      return 1
    fi

    if ! (set -o pipefail; gunzip -c "$file" | "${mariadb_import_cmd[@]}"); then
      echo -e "Произошла ${RED}ошибка${WHITE} при импорте базы ${RED}$custom_db${WHITE}."
      return 1
    fi
  else
    if ! "${mariadb_import_cmd[@]}" < "$file"; then
      echo -e "Произошла ${RED}ошибка${WHITE} при импорте базы ${RED}$custom_db${WHITE}."
      return 1
    fi
  fi

  echo -e "База данных ${GREEN}${custom_db}${WHITE} успешно импортирована."
}


function restore_zip_folder() {
  local file="$1"
  local folder_guess="$2"
  local filename="$(basename "$file")"

  echo -e "Введите имя папки для извлечения: ${YELLOW}"
  read -e -i "$folder_guess" folder
  echo -ne "${WHITE}"

  # Проверка существования папки
  if [[ -d "$folder" && -n "$(ls -A "$folder")" ]]; then
    echo -e "Папка ${YELLOW}${folder}${WHITE} уже существует и не пуста. Что делать?"
    vertical_menu "current" 2 0 60 "Очистить и извлечь" "Извлечь поверх существующих файлов" "Прервать извлечение"
    local choice=$?
    if [[ "$choice" -eq 255 || "$choice" -eq 2 ]]; then
      echo -e "Извлечение ${YELLOW}отменено${WHITE} пользователем."
      return
    elif [[ "$choice" -eq 0 ]]; then
      echo -e -n "${CURSORUP}${ERASEUNTILLENDOFLINE}"
      echo -e "${WHITE}Очищаем папку ${folder}...${WHITE}"
      clean_directory_contents "${folder:?}"
    else
      echo -e -n "${CURSORUP}${ERASEUNTILLENDOFLINE}"
      echo -e "${WHITE}Извлечение будет выполнено без очистки папки.${WHITE}"
    fi
  else
    mkdir -p "$folder"
  fi

  echo -e "Извлекаем архив ${GREEN}${filename}${WHITE} в папку ${GREEN}${folder}${WHITE}..."
  unzip -o -q "$file" -d "$folder"

  # Назначаем владельца, если путь соответствует /var/www/<user>/www
  local abs_path
  abs_path="$(realpath "$folder")"
  if [[ "$abs_path" =~ ^/var/www/([^/]+)/www(/|$) ]]; then
    local user_dir="${BASH_REMATCH[1]}"
    chown -R "${user_dir}:${user_dir}" "$folder"
    echo -e "Владелец восстановленных файлов: ${YELLOW}${user_dir}${WHITE}."
  fi

  echo -e "Архив успешно извлечён в папку ${GREEN}${folder}${WHITE}."
}


function extract() {
  local file="$1"
  local filename="$(basename "$file")"
  local ext="${filename##*.}"
  local base="${filename%.*}"

  # Уточняем расширение
  if [[ "$filename" == *.sql.gz ]]; then
    ext="sql.gz"
    base="${filename%.sql.gz}"
  elif [[ "$filename" == *.tar.gz ]]; then
    ext="tar.gz"
    base="${filename%.tar.gz}"
  elif [[ "$filename" == *.gz ]]; then
    ext="gz"
    base="${filename%.gz}"
  elif [[ "$filename" == *.zip ]]; then
    ext="zip"
    base="${filename%.zip}"
  fi


  # Определяем предполагаемое имя базы
  local db_guess
  if [[ "$base" == *"_"* ]]; then
    db_guess="${base%%_*}"
  else
    db_guess="$base"
  fi

  # Список действий
  local options=()
  if [[ "$ext" == "tar.gz" ]]; then
    options+=("restore_folder::Восстановить папку из архива $db_guess")
    options+=("restore_site::Восстановить сайт из архива $db_guess")
  elif [[ "$ext" == "sql.gz" || "$ext" == "sql" ]]; then
    local tar_archive="${file%.sql*}.tar.gz"
    if [[ -f "$tar_archive" ]]; then
      options+=("restore_site_from_sql::Восстановить сайт + базу из архива ${db_guess}")
    fi
    options+=("restore_db_auto::Восстановить базу данных ${db_guess}")
    options+=("restore_db_custom::Восстановить базу данных (указать своё имя)")
    [[ "$ext" == "sql" ]] && options+=("archive_file::Создать архив файла $filename")
    [[ "$ext" == "sql.gz" ]] && options+=("unpack_sql::Извлечь SQL-файл из архива $filename")
  elif [[ "$ext" == "gz" ]]; then
    options+=("unpack_gz::Распаковать файл ${filename}")
  elif [[ "$ext" == "zip" ]]; then
    options+=("restore_zip_folder::Извлечь содержимое архива ${filename}")
  fi
  options+=("exit::Выйти")

  # Отображаемые строки
  local menu_items=()
  for item in "${options[@]}"; do
    menu_items+=("${item#*::}")
  done

  vertical_menu "current" 1 0 40 "${menu_items[@]}"
  local choice=$?

  if [[ $choice -eq 255 || "${options[$choice]%%::*}" == "exit" ]]; then
    echo -e "Операция ${YELLOW}отменена${WHITE} пользователем."
    return
  fi

  local action="${options[$choice]%%::*}"

  case "$action" in
    restore_folder) restore_folder "$file" "$db_guess" ;;
    restore_site) restore_site "$file" "$db_guess" ;;
    restore_db_auto) restore_db_auto "$file" "$db_guess" ;;
    restore_db_custom) restore_db_custom "$file" "$db_guess" ;;
    archive_file) archive_file "$file" ;;
    restore_zip_folder) restore_zip_folder "$file" "$db_guess" ;;
    unpack_sql)
      local sql_name="${file%.gz}"
      echo -e "Распаковываем SQL-файл ${GREEN}${filename}${WHITE} → ${GREEN}$(basename "$sql_name")${WHITE}..."
      if gunzip -c "$file" > "$sql_name"; then
        echo -e "Файл успешно извлечён: ${GREEN}$(basename "$sql_name")${WHITE}"
      else
        echo -e "Ошибка при распаковке SQL-файла${RED}${filename}${WHITE}"
      fi
      ;;
    unpack_gz)
      local out_file="${file%.gz}"
      echo -e "Распаковываем файл ${GREEN}${filename}${WHITE} → ${GREEN}$(basename "$out_file")${WHITE}..."
      if gunzip -c "$file" > "$out_file"; then
        echo -e "Файл успешно извлечён: ${GREEN}$(basename "$out_file")${WHITE}"
      else
        echo -e "Ошибка при распаковке файла${RED}${filename}${WHITE}"
      fi
      ;;
    restore_site_from_sql)
      local tar_archive="${file%.sql*}.tar.gz"
      restore_site "$tar_archive" "$db_guess"
      ;;
  esac
}

# Если скрипт вызван напрямую — запускаем функцию
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  fullpath="$2/$1"

  if [[ -f "$fullpath" ]]; then
    filename="$(basename "$fullpath")"
    case "$filename" in
      *.gz|*.sql|*.zip)
        extract "$fullpath"
        ;;
      *)
        archive "$2" "$1"
        ;;
    esac
  else
    archive "$2" "$1"
  fi

  vertical_menu "current" 2 0 5 "Нажмите Enter"
fi
