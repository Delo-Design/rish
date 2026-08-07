#!/usr/bin/env bash

source /root/rish/windows.sh
source /root/rish/scripts/site_helpers.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /root/rish/scripts/backup_crypto.sh ]]; then
  source /root/rish/scripts/backup_crypto.sh
else
  source "${SCRIPT_DIR}/scripts/backup_crypto.sh"
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'

ARCHIVE_USE_CRYPTO=0
ARCHIVE_CRYPTO_RECIPIENTS=()
ARCHIVE_CRYPTO_ARGS=()

prepare_archive_crypto_for_path() {
  local selected_path="$1"
  local list_file="${backupall2:-}"
  local resolved_path user target
  local row_user row_target row_type row_db row_remote row_policy row_exclude

  ARCHIVE_USE_CRYPTO=0
  ARCHIVE_CRYPTO_RECIPIENTS=()
  ARCHIVE_CRYPTO_ARGS=()

  if [[ -z "$list_file" && -f /root/rish/rish_config.sh ]]; then
    source /root/rish/rish_config.sh
    list_file="${backupall2:-}"
  fi
  list_file="${list_file:-/root/rish/backup_list_all}"
  [[ -f "$list_file" ]] || return 0

  # Нормализуем путь, но не разрешаем симлинки: имя объекта в backup_list_all
  # определяется по пути /var/www/<user>/www/<target>, а не по его назначению.
  resolved_path="$(realpath -ms -- "$selected_path" 2>/dev/null)" || return 0
  if [[ ! "$resolved_path" =~ ^/var/www/([^/]+)/www/([^/]+)(/|$) ]]; then
    return 0
  fi
  user="${BASH_REMATCH[1]}"
  target="${BASH_REMATCH[2]}"

  while IFS=';' read -r row_user row_target row_type row_db row_remote row_policy row_exclude; do
    [[ "$row_user" == "$user" && "$row_target" == "$target" ]] || continue
    if ! backup_parse_archive_policy "$row_policy"; then
      echo -e "Настройка архивирования ${RED}${target}${WHITE} некорректна: ${BACKUP_ARCHIVE_POLICY_ERROR}." >&2
      return 1
    fi
    if [[ "$BACKUP_ARCHIVE_MODE" != "crypto" ]]; then
      return 0
    fi
    if ! backup_validate_age_recipients; then
      echo -e "Зашифрованная архивация ${RED}${target}${WHITE} недоступна: ${BACKUP_ARCHIVE_POLICY_ERROR}." >&2
      return 1
    fi
    ARCHIVE_USE_CRYPTO=1
    ARCHIVE_CRYPTO_RECIPIENTS=("${BACKUP_AGE_RECIPIENTS[@]}")
    ARCHIVE_CRYPTO_ARGS=("${BACKUP_AGE_ARGS[@]}")
    return 0
  done < "$list_file"

  return 0
}

function normalize_archive_exclude_dir() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  while [[ "$value" == ./* ]]; do
    value="${value#./}"
  done
  while [[ "$value" == */ ]]; do
    value="${value%/}"
  done

  if [[ -z "$value" ]]; then
    return 1
  fi
  if [[ "$value" == /* || "$value" == "." || "$value" == ".." || "$value" == *"/../"* || "$value" == ../* || "$value" == */.. ]]; then
    echo -e "Путь исключения ${RED}${value}${WHITE} некорректный. Укажите папку относительно архивируемой папки." >&2
    return 2
  fi
  if [[ ! "$value" =~ ^[A-Za-z0-9._@+/-]+$ ]]; then
    echo -e "Путь исключения ${RED}${value}${WHITE} содержит недопустимые символы." >&2
    echo -e "Разрешены только буквы, цифры, ${YELLOW}.${WHITE}, ${YELLOW}_${WHITE}, ${YELLOW}-${WHITE}, ${YELLOW}+${WHITE}, ${YELLOW}@${WHITE} и ${YELLOW}/${WHITE}." >&2
    return 2
  fi

  printf '%s' "$value"
}

function save_archive_exclude() {
  local exclude_input="$1"
  local config_file="/root/rish/rish_config.sh"
  local exclude_line

  printf -v exclude_line 'ARCHIVE_EXCLUDE=%q' "$exclude_input"

  if [[ -f "$config_file" ]] && grep -q "^ARCHIVE_EXCLUDE=" "$config_file"; then
    sed -i "s|^ARCHIVE_EXCLUDE=.*|${exclude_line}|" "$config_file"
  else
    echo "$exclude_line" >> "$config_file"
  fi
}

function select_archive_exclude_dirs() {
  local folder="$1"
  local default_exclude="${ARCHIVE_EXCLUDE:-}"
  local exclude_input
  local excl
  local normalized
  local normalized_input
  local invalid_exclude
  local exclude_arr=()
  local normalized_exclude_arr=()

  while true; do
    echo -e "Типовые примеры исключений:"
    echo -e "Для Joomla: ${YELLOW}administrator/cache,administrator/logs,cache,tmp${WHITE}"
    echo -e "Для Joomla Yootheme: ${YELLOW}administrator/cache,administrator/logs,cache,tmp,templates/yootheme/cache${WHITE}"
    echo -e "Для Joomla Akeeba: ${YELLOW}administrator/cache,administrator/logs,cache,tmp,administrator/components/com_akeeba/backup${WHITE}"
    echo
    echo -e "Введите папки для исключения (через запятую):${YELLOW}"
    read -r -e -i "$default_exclude" exclude_input
    echo -e "${WHITE}"

    local IFS=','
    read -ra exclude_arr <<< "$exclude_input"
    ARCHIVE_EXCLUDE_ARGS=()
    normalized_exclude_arr=()
    invalid_exclude=0
    for excl in "${exclude_arr[@]}"; do
      normalized="$(normalize_archive_exclude_dir "$excl")"
      case "$?" in
        0)
          normalized_exclude_arr+=("$normalized")
          ARCHIVE_EXCLUDE_ARGS+=("--exclude=$folder/${normalized}/*")
          ;;
        1) ;;
        *)
          invalid_exclude=1
          break
          ;;
      esac
    done
    if [[ "$invalid_exclude" == "1" ]]; then
      echo
      continue
    fi

    normalized_input="${normalized_exclude_arr[*]}"
    ARCHIVE_EXCLUDE="$normalized_input"
    save_archive_exclude "$normalized_input"
    return 0
  done
}

function print_archive_exclude_preview() {
  local folder_path="$1"
  shift
  local folder
  local parent_path
  local arg
  local clean_path
  local folder_size_mb
  local disk_free
  local du_exclude=()

  folder="$(basename "$folder_path")"
  parent_path="$(dirname "$folder_path")"

  for arg in "$@"; do
    if [[ "$arg" =~ --exclude=.+ ]]; then
      du_exclude+=("--exclude=${arg#--exclude=}")
    fi
  done

  folder_size_mb=$(du --apparent-size --dereference -sm "${du_exclude[@]}" "$folder_path" | cut -f1)
  disk_free="$(df -h -P "$parent_path" | awk 'NR==2 {print $4}')"

  if [[ "$#" -gt 0 ]]; then
    echo -e "За исключением папок:"
    for arg in "$@"; do
      if [[ "$arg" =~ --exclude=.+ ]]; then
        clean_path="${arg#--exclude=}"
        clean_path="${clean_path%/*}"
        clean_path="${clean_path#*/}"
        echo -e " ${YELLOW}${clean_path}${WHITE}"
      fi
    done
    echo
  fi

  echo -e "Предполагаемый размер папки ${GREEN}${folder}${WHITE}: ${YELLOW}${folder_size_mb} MB${WHITE}"
  if [[ -n "$disk_free" ]]; then
    echo -e "Свободное место на диске: ${YELLOW}${disk_free}${WHITE}"
  else
    echo -e "Свободное место на диске: ${YELLOW}определить не удалось${WHITE}"
  fi
  echo
}

function confirm_archive_with_exclude() {
  local folder_path="$1"
  local folder="$2"
  local choice

  while true; do
    select_archive_exclude_dirs "$folder" || return 1
    print_archive_exclude_preview "$folder_path" "${ARCHIVE_EXCLUDE_ARGS[@]}"

    vertical_menu "current" 1 0 30 "Начать архивацию" "Изменить исключаемые папки" "Выйти"
    choice=$?
    case "$choice" in
      0) return 0 ;;
      1)
        echo
        continue
        ;;
      *)
        echo -e "Операция ${YELLOW}отменена${WHITE} пользователем."
        return 1
        ;;
    esac
  done
}

function archive() {
  local path="$1"
  local folder="$2"
  local fullpath="$path/$folder"
  local crypto_available=0
  source /root/rish/rish_config.sh

  if ! prepare_archive_crypto_for_path "$fullpath"; then
    echo -e "Пункты ${YELLOW}(шифр)${WHITE} недоступны. Обычный архив можно создать без шифрования."
  fi
  crypto_available="$ARCHIVE_USE_CRYPTO"
  ARCHIVE_USE_CRYPTO=0

  echo
  if [[ "$crypto_available" -eq 1 ]]; then
    echo -e "Шифрование доступно: утилита ${GREEN}age${WHITE}, публичных ключей: ${YELLOW}${#ARCHIVE_CRYPTO_RECIPIENTS[@]}${WHITE}."
    echo
  fi
  if [[ "$folder" == ".." || "$folder" == "." ]]; then
    echo -e "Вы выбрали ${YELLOW}$folder${WHITE}"
    echo -e "Нельзя архивировать ${RED}текущую${WHITE} или ${RED}родительскую${WHITE} директорию напрямую (. и ..)."
    return 1
  fi

  if [[ -f "$fullpath" ]]; then
    local filename
    filename=$(basename "$fullpath")
    local options=()
    local menu_items=()
    local choice
    local action
    local menu_default=0

    if [[ "$crypto_available" -eq 1 ]]; then
      options+=("archive_file_crypto::Создать архив файла ${filename} (шифр)")
      menu_default=1
    fi
    options+=("archive_file::Создать архив файла ${filename}" "exit::Выйти")

    for item in "${options[@]}"; do
      menu_items+=("${item#*::}")
    done

    vertical_menu "current" 1 0 60 "default=${menu_default}" "${menu_items[@]}"
    choice=$?
    if [[ $choice -eq 255 || "${options[$choice]%%::*}" == "exit" ]]; then
      echo -e "Операция ${YELLOW}отменена${WHITE} пользователем."
      return
    fi

    action="${options[$choice]%%::*}"
    if [[ "$action" == "archive_file_crypto" ]]; then
      ARCHIVE_USE_CRYPTO=1
      action="archive_file"
    fi
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

  echo
  local base_options=()
  local options=()
  local menu_items=()
  local choice
  local action
  local item
  local item_action
  local item_label
  local menu_default=0

  [[ $is_site -eq 1 && $has_db -eq 1 ]] && base_options+=("archive_site_and_db::Создать архив сайта ${folder} и базы данных ${folder}")
  base_options+=("archive_site::Создать архив папки ${folder}")
  [[ $has_db -eq 1 ]] && base_options+=("archive_db::Создать архив базы данных ${folder}")
  [[ $is_site -eq 1 && $has_db -eq 1 ]] && base_options+=("archive_site_with_exclude::Создать архив сайта ${folder} с исключениями и базы данных ${folder}")
  base_options+=("archive_folder_with_exclude::Создать архив папки ${folder} с исключениями")

  for item in "${base_options[@]}"; do
    item_action="${item%%::*}"
    item_label="${item#*::}"
    if [[ "$crypto_available" -eq 1 ]]; then
      options+=("${item_action}_crypto::${item_label} (шифр)")
    fi
    options+=("$item")
  done
  options+=("exit::Выйти")

  [[ "$crypto_available" -eq 1 ]] && menu_default=1
  for item in "${options[@]}"; do
    menu_items+=("${item#*::}")
  done

  vertical_menu "current" 1 0 60 "default=${menu_default}" "${menu_items[@]}"
  choice=$?
  if [[ $choice -eq 255 || "${options[$choice]%%::*}" == "exit" ]]; then
    echo -e "Операция ${YELLOW}отменена${WHITE} пользователем."
    return 1
  fi

  action="${options[$choice]%%::*}"
  if [[ "$action" == *_crypto ]]; then
    ARCHIVE_USE_CRYPTO=1
    action="${action%_crypto}"
  fi

  local dt
  dt=$(date "+%Y-%m-%d_%H-%M")
  local base_name="${folder}_${dt}"
  ARCHIVE_EXCLUDE_ARGS=()

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
      confirm_archive_with_exclude "$fullpath" "$folder" || return 1
      archive_site "$fullpath" "$base_name" "${ARCHIVE_EXCLUDE_ARGS[@]}"
      archive_db "$folder" "$base_name"
      ;;

    archive_folder_with_exclude)
      confirm_archive_with_exclude "$fullpath" "$folder" || return 1
      archive_site "$fullpath" "$base_name" "${ARCHIVE_EXCLUDE_ARGS[@]}"
      ;;
  esac

}

function archive_site() {
  local folder_path="$1"
  local archive_name="$2"
  shift 2
  local arg
  local extra_args=("$@")
  local parent_path
  local folder
  local crypto_suffix=""
  parent_path="$(dirname "$folder_path")"
  folder="$(basename "$folder_path")"
  [[ "$ARCHIVE_USE_CRYPTO" -eq 1 ]] && crypto_suffix=".age"
  local archive_path="${parent_path}/${archive_name}.tar.gz${crypto_suffix}"
  local archive_tmp="${archive_path}.rish-tmp.$$"

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
  local age_rc=0
  local tar_err_file
  local tar_reason=""
  local -a pipeline_status=()

  tar_err_file="$(mktemp)" || {
    echo -e "${RED}Не удалось${WHITE} подготовить временный файл для анализа ошибок tar."
    return 2
  }

  if [[ "$ARCHIVE_USE_CRYPTO" -eq 1 ]]; then
    tar -czhf - -C "$parent_path" "${extra_args[@]}" \
      --record-size=$recordsize --checkpoint=$checkpoint \
      --checkpoint-action=exec="echo -e \"${CURSORUP}Обработано: \$((TAR_CHECKPOINT / 1000)) MB${ERASEUNTILLENDOFLINE}\r\" >&2" \
      "$folder" \
      2> >(tee "$tar_err_file" >&2) \
      | age "${ARCHIVE_CRYPTO_ARGS[@]}" > "$archive_tmp"
    pipeline_status=("${PIPESTATUS[@]}")
    tar_rc="${pipeline_status[0]}"
    age_rc="${pipeline_status[1]}"
    if [[ "$age_rc" -ne 0 || "$tar_rc" -ge 2 ]]; then
      rm -f -- "$archive_tmp"
      if [[ "$age_rc" -ne 0 ]]; then
        tar_reason="age завершился с ошибкой ${age_rc}"
        tar_rc=2
      fi
    elif ! mv -f -- "$archive_tmp" "$archive_path"; then
      rm -f -- "$archive_tmp"
      tar_reason="не удалось сохранить зашифрованный архив"
      tar_rc=2
    fi
  else
    tar -czhf "$archive_path" -C "$parent_path" "${extra_args[@]}" \
      --record-size=$recordsize --checkpoint=$checkpoint \
      --checkpoint-action=exec="echo -e \"${CURSORUP}Обработано: \$((TAR_CHECKPOINT / 1000)) MB${ERASEUNTILLENDOFLINE}\r\" >&2" \
      "$folder" \
      2> >(tee "$tar_err_file" >&2)
    tar_rc=$?
  fi
  echo -e "${CURSORUP}${ERASEUNTILLENDOFLINE}"

  if [[ -z "$tar_reason" && -s "$tar_err_file" ]]; then
    tar_reason="$(grep '^tar:' "$tar_err_file" | sed 's/\r$//' | awk 'NR==1{out=$0;next}{out=out "; " $0} END{print out}')"
    if [[ -z "$tar_reason" ]]; then
      tar_reason="$(grep -v 'Обработано:' "$tar_err_file" | sed '/^[[:space:]]*$/d' | tail -n 1)"
    fi
  fi
  rm -f "$tar_err_file"

  case "$tar_rc" in
    0)
      echo -e "Архив ${GREEN}$(basename "$archive_path")${WHITE} успешно создан."
      # Вывод размера конечного архива
      local archive_size_mb
      archive_size_mb=$(du -sm "$archive_path" | cut -f1)
      echo -e "Размер архива: ${YELLOW}${archive_size_mb} MB${WHITE}"
      ;;
    1)
      echo -e "\n${YELLOW}Предупреждение${WHITE} при создании архива ${YELLOW}${archive_name}${WHITE} (код tar: 1)."
      if [[ -n "$tar_reason" ]]; then
        echo -e "Причина: ${YELLOW}${tar_reason}${WHITE}"
      fi
      ;;
    2)
      if [[ "$ARCHIVE_USE_CRYPTO" -ne 1 ]]; then
        rm -f -- "$archive_path"
      fi
      echo -e "\n${RED}Ошибка${WHITE} при создании архива ${RED}${archive_name}${WHITE} (код tar: 2)."
      if [[ -n "$tar_reason" ]]; then
        echo -e "Причина: ${RED}${tar_reason}${WHITE}"
      fi
      ;;
    *)
      if [[ "$ARCHIVE_USE_CRYPTO" -ne 1 ]]; then
        rm -f -- "$archive_path"
      fi
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
  local crypto_suffix=""
  local output_file temp_file

  [[ "$ARCHIVE_USE_CRYPTO" -eq 1 ]] && crypto_suffix=".age"
  output_file="${base}.sql.gz${crypto_suffix}"
  temp_file="${output_file}.rish-tmp.$$"

  echo -e "Создаем архив базы данных ${GREEN}${dbname}${WHITE}..."

  if [[ "$ARCHIVE_USE_CRYPTO" -eq 1 ]]; then
    if (set -o pipefail; mariadb-dump \
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
      | gzip \
      | age "${ARCHIVE_CRYPTO_ARGS[@]}" > "$temp_file") && \
      mv -f -- "$temp_file" "$output_file"; then
      echo -e "${CURSORUP}${ERASEUNTILLENDOFLINE}Архив базы данных ${GREEN}${output_file}${WHITE} создан."
    else
      rm -f -- "$temp_file"
      echo -e "${RED}Ошибка${WHITE} при создании зашифрованного дампа базы ${RED}${dbname}${WHITE}"
      return 1
    fi
  else
    if (set -o pipefail; mariadb-dump \
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
      | gzip > "$temp_file") && \
      mv -f -- "$temp_file" "$output_file"; then
      echo -e "${CURSORUP}${ERASEUNTILLENDOFLINE}Архив базы данных ${GREEN}${output_file}${WHITE} создан."
    else
      rm -f -- "$temp_file"
      echo -e "${RED}Ошибка${WHITE} при создании дампа базы ${RED}${dbname}${WHITE}"
      return 1
    fi
  fi
}

function archive_file() {
  local filepath="$1"
  local filename
  local dt
  local crypto_suffix=""
  local output_file temp_file

  filename="$(basename "$filepath")"
  dt=$(date "+%Y-%m-%d_%H-%M")

  # Отделим имя и расширение
  local name="${filename%.*}"
  local ext="${filename##*.}"

  [[ "$ARCHIVE_USE_CRYPTO" -eq 1 ]] && crypto_suffix=".age"
  local archive_name="${name}_${dt}.${ext}.gz${crypto_suffix}"
  output_file="$archive_name"
  temp_file="${output_file}.rish-tmp.$$"

  echo -e "Создаем архив файла ${GREEN}${filename}${WHITE}..."
  if [[ "$ARCHIVE_USE_CRYPTO" -eq 1 ]]; then
    if (set -o pipefail; gzip -c "$filepath" | age "${ARCHIVE_CRYPTO_ARGS[@]}" > "$temp_file") && \
      mv -f -- "$temp_file" "$output_file"; then
      echo -e "Архив файла ${GREEN}${archive_name}${WHITE} создан."
    else
      rm -f -- "$temp_file"
      echo -e "${RED}Ошибка${WHITE} при создании зашифрованного архива ${RED}${filename}${WHITE}."
      return 1
    fi
  elif gzip -c "$filepath" > "$temp_file" && mv -f -- "$temp_file" "$output_file"; then
    echo -e "Архив файла ${GREEN}${archive_name}${WHITE} создан."
  else
    rm -f -- "$temp_file"
    echo -e "${RED}Ошибка${WHITE} при создании архива ${RED}${filename}${WHITE}."
    return 1
  fi
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

report_age_archive_open_error() {
  local archive_path="$1"

  echo -e "Не удалось открыть архив ${GREEN}$(basename "$archive_path")${WHITE} этим приватным ключом."
  echo -e "Ключ ${RED}не подходит${WHITE} к архиву либо архив повреждён."
}

function validate_database_archive() {
  local file="$1"
  local decrypt_identity="${2:-}"

  if [[ -n "$decrypt_identity" ]]; then
    if ! (set -o pipefail; age -d -i "$decrypt_identity" "$file" 2>/dev/null | gzip -t); then
      report_age_archive_open_error "$file"
      return 1
    fi
  elif [[ "$file" == *.gz ]] && ! gzip -t "$file"; then
    echo -e "Файл ${RED}$(basename "$file")${WHITE} поврежден или не является корректным gzip-архивом."
    return 1
  elif [[ ! -s "$file" ]]; then
    echo -e "Файл ${RED}$(basename "$file")${WHITE} пуст или недоступен."
    return 1
  fi
  return 0
}

function inspect_tar_archive_layout() {
  local archive_path="$1"
  local decrypt_identity="${2:-}"
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

  if [[ -n "$decrypt_identity" ]]; then
    if ! (set -o pipefail; age -d -i "$decrypt_identity" "$archive_path" 2>/dev/null | tar -tzf - > "$tar_list_file"); then
      report_age_archive_open_error "$archive_path"
      rm -f "$tar_list_file"
      return 1
    fi
  elif ! tar -tzf "$archive_path" > "$tar_list_file"; then
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
  local decrypt_identity="${4:-}"
  local archive_prevalidated="${5:-0}"

  local folder_name="$site_guess"

  if [[ "$mode" != "auto" ]]; then
    echo -ne "${WHITE}Введите имя папки для восстановления: ${YELLOW}"
    read -e -i "$site_guess" folder_name
    echo -ne "${WHITE}"
  fi

  if [[ "$archive_prevalidated" -ne 1 ]]; then
    echo -e "Проверяем архив ${GREEN}$(basename "$archive_path")${WHITE} и подготавливаем распаковку в папку ${GREEN}${folder_name}${WHITE}..."
    if ! inspect_tar_archive_layout "$archive_path" "$decrypt_identity"; then
      echo -e "Восстановление ${YELLOW}прервано${WHITE}: не удалось прочитать архив."
      return 1
    fi
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

  if [[ -n "$decrypt_identity" ]]; then
    (set -o pipefail; age -d -i "$decrypt_identity" "$archive_path" 2>/dev/null \
      | tar -xzf - \
        --record-size=$recordsize --checkpoint=$checkpoint \
        --checkpoint-action=exec="echo -e \"${CURSORUP}Обработано: \$((TAR_CHECKPOINT / 1000)) MB${ERASEUNTILLENDOFLINE}\r\" >&2" \
        "${extract_args[@]}")
    tar_rc=$?
  else
    tar -xzf "$archive_path" \
      --record-size=$recordsize --checkpoint=$checkpoint \
      --checkpoint-action=exec="echo -e \"${CURSORUP}Обработано: \$((TAR_CHECKPOINT / 1000)) MB${ERASEUNTILLENDOFLINE}\r\" >&2" \
      "${extract_args[@]}"
    tar_rc=$?
  fi
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
  local site_path="${3:-}"
  local decrypt_identity="${4:-}"
  local encrypted_sql_file="${5:-}"
  local skip_create=0
  local f
  local conf_file=""
  local embedded_sql_entry=""
  local base=""
  local sql_file=""
  local sql_identity=""
  local sql_prevalidated=0
  local temp_sql_dir=""
  [[ -n "$site_path" ]] || site_path="$(dirname "$file")"
  if [[ -n "$decrypt_identity" && "$file" != *.tar.gz.age ]]; then
    echo -e "Файл ${RED}$(basename "$file")${WHITE} не является зашифрованным архивом tar.gz.age."
    echo -e "Восстановление ${YELLOW}отменено${WHITE}."
    return 1
  elif [[ -z "$decrypt_identity" && "$file" != *.tar.gz ]]; then
    echo -e "Файл ${RED}$(basename "$file")${WHITE} не является архивом tar.gz."
    echo -e "Восстановление ${YELLOW}отменено${WHITE}."
    return 1
  fi

  if [[ -n "$decrypt_identity" ]]; then
    echo -e "Проверяем архив ${GREEN}$(basename "$file")${WHITE} и соответствие ключа..."
  else
    echo -e "Проверяем архив ${GREEN}$(basename "$file")${WHITE}..."
  fi
  if ! inspect_tar_archive_layout "$file" "$decrypt_identity"; then
    echo -e "Восстановление ${YELLOW}прервано${WHITE}: архив не прошёл проверку."
    return 1
  fi
  embedded_sql_entry="$ARCHIVE_SQL_ENTRY"

  base="${file%.tar.gz}"
  if [[ -n "$decrypt_identity" ]]; then
    if [[ -n "$encrypted_sql_file" && -f "$encrypted_sql_file" ]]; then
      sql_file="$encrypted_sql_file"
      sql_identity="$decrypt_identity"
    fi
  else
    [[ -f "${base}.sql.gz" ]] && sql_file="${base}.sql.gz"
    [[ -f "${base}.sql" ]] && sql_file="${base}.sql"
  fi
  if [[ -n "$sql_file" ]]; then
    echo -e "Проверяем архив базы данных ${GREEN}$(basename "$sql_file")${WHITE}..."
    if ! validate_database_archive "$sql_file" "$sql_identity"; then
      echo -e "Восстановление ${YELLOW}прервано${WHITE}: архив базы данных не прошёл проверку."
      return 1
    fi
    sql_prevalidated=1
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
    [[ "$site_path" =~ ^/var/www/([^/]+)/www(/|$) ]] && archive_user="${BASH_REMATCH[1]}"

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

  if ! restore_folder "$file" "$site_name" "auto" "$decrypt_identity" 1; then
    return 1
  fi

  if [[ -z "$sql_file" ]]; then
    if [[ -n "$embedded_sql_entry" ]]; then
      temp_sql_dir="$(mktemp -d "${site_path}/.restore_sql.XXXXXX")"
      if [[ -z "$temp_sql_dir" ]]; then
        echo -e "Не удалось подготовить временную папку для извлечения SQL."
      elif [[ -n "$decrypt_identity" ]] && \
        (set -o pipefail; age -d -i "$decrypt_identity" "$file" 2>/dev/null | tar -xzf - -C "$temp_sql_dir" "$embedded_sql_entry"); then
        sql_file="${temp_sql_dir}/${embedded_sql_entry}"
        echo -e "Найден SQL-файл внутри архива: ${GREEN}${embedded_sql_entry}${WHITE}"
      elif [[ -z "$decrypt_identity" ]] && tar -xzf "$file" -C "$temp_sql_dir" "$embedded_sql_entry"; then
        sql_file="${temp_sql_dir}/${embedded_sql_entry}"
        echo -e "Найден SQL-файл внутри архива: ${GREEN}${embedded_sql_entry}${WHITE}"
      else
        echo -e "Не удалось извлечь SQL-файл ${RED}${embedded_sql_entry}${WHITE} из архива."
        rm -rf "$temp_sql_dir"
        temp_sql_dir=""
      fi
    fi
  fi

  if [[ -n "$sql_file" ]]; then
    echo -e "Найден файл базы данных: ${GREEN}$(basename "$sql_file")${WHITE}. Восстанавливаем..."
    if ! restore_db_auto "$sql_file" "$site_name" "$sql_identity" "$sql_prevalidated"; then
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
  local decrypt_identity="${3:-}"
  local archive_prevalidated="${4:-0}"
  restore_db_core "$file" "$dbname" 0 "$decrypt_identity" "$archive_prevalidated"
  return $?
}

function restore_db_custom() {
  local file="$1"
  local dbname="$2"
  local decrypt_identity="${3:-}"
  local archive_prevalidated="${4:-0}"
  restore_db_core "$file" "$dbname" 1 "$decrypt_identity" "$archive_prevalidated"
  return $?
}

function restore_db_core() {
  local file="$1"
  local db_default="$2"
  local allow_edit="$3"
  local decrypt_identity="${4:-}"
  local archive_prevalidated="${5:-0}"
  local custom_db="$db_default"

  # Проверка на размещение в /var/www/<user>/www
  local user_dir=""
  local filepath
  filepath="$(realpath "$file")"
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

  if [[ "$archive_prevalidated" -ne 1 ]]; then
    if ! validate_database_archive "$file" "$decrypt_identity"; then
      return 1
    fi
  fi

  echo -e "Восстанавливаем базу данных ${GREEN}${custom_db}${WHITE} для пользователя ${YELLOW}${user_dir}${WHITE}..."

  # Проверка существования базы
  local check
  check=$(mariadb -N -e "SHOW DATABASES LIKE '${custom_db}'" 2>/dev/null)

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

  if [[ -n "$decrypt_identity" ]]; then
    if ! (set -o pipefail; age -d -i "$decrypt_identity" "$file" 2>/dev/null | gunzip -c | "${mariadb_import_cmd[@]}"); then
      echo -e "Произошла ${RED}ошибка${WHITE} при расшифровании или импорте базы ${RED}$custom_db${WHITE}."
      return 1
    fi
  elif [[ "$file" == *.gz ]]; then
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
  local filename
  filename="$(basename "$file")"

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

AGE_SELECTED_IDENTITY=""
AGE_SELECTED_IDENTITY_TYPE=""
AGE_DECRYPT_ERROR=""

ssh_identity_file_valid() {
  local identity_path="$1"
  local summary

  command -v ssh-keygen >/dev/null 2>&1 || return 1
  summary="$(LC_ALL=C ssh-keygen -lf "$identity_path" 2>/dev/null)" || return 1
  [[ "$summary" == *" (ED25519)" || "$summary" == *" (RSA)" ]]
}

age_identity_file_type() {
  local identity_path="$1"
  local first_line

  [[ -f "$identity_path" && ! -L "$identity_path" ]] || return 1
  IFS= read -r first_line < "$identity_path" || return 1
  case "$first_line" in
    "-----BEGIN AGE ENCRYPTED FILE-----")
      printf 'age'
      ;;
    "-----BEGIN OPENSSH PRIVATE KEY-----"|"-----BEGIN RSA PRIVATE KEY-----"|"-----BEGIN PRIVATE KEY-----"|"-----BEGIN ENCRYPTED PRIVATE KEY-----")
      ssh_identity_file_valid "$identity_path" || return 1
      printf 'ssh'
      ;;
    *)
      return 1
      ;;
  esac
}

select_age_identity() {
  local temp_dir="$1"
  local choice identity_choice identity_path identity_type line armor_file armor_complete=0 input_cancelled=0 expected_end=""
  local invalid_identity_format=0
  local -a identity_files=() identity_types=() identity_labels=()

  AGE_SELECTED_IDENTITY=""
  AGE_SELECTED_IDENTITY_TYPE=""
  echo
  echo "Выберите приватный ключ для расшифрования:"
  vertical_menu "current" 2 0 48 \
    "Выбрать файл приватного ключа из /root" \
    "Вставить защищённый ключ age из буфера обмена" \
    "Вставить приватный SSH-ключ из буфера обмена" \
    "Отмена"
  choice=$?

  case "$choice" in
    0)
      shopt -s nullglob
      for identity_path in /root/*; do
        identity_type="$(age_identity_file_type "$identity_path")" || continue
        if [[ "$identity_type" == "age" && "$(basename "$identity_path")" != *.age ]]; then
          continue
        fi
        identity_files+=("$identity_path")
        identity_types+=("$identity_type")
        if [[ "$identity_type" == "ssh" ]]; then
          identity_labels+=("[SSH] $(basename "$identity_path")")
        else
          identity_labels+=("[age] $(basename "$identity_path")")
        fi
      done
      shopt -u nullglob

      if ((${#identity_files[@]} == 0)); then
        echo
        echo -e "В каталоге ${YELLOW}/root${WHITE} не найдены поддерживаемые файлы приватных ключей."
        echo "Скопируйте ключ в /root или используйте вставку из буфера обмена."
        vertical_menu "current" 2 0 5 "Нажмите Enter"
        return 2
      fi

      identity_labels+=("Отмена")
      echo
      echo "Выберите файл приватного ключа:"
      vertical_menu "current" 2 12 48 "${identity_labels[@]}"
      identity_choice=$?
      if ((identity_choice == 255 || identity_choice >= ${#identity_files[@]})); then
        return 1
      fi
      AGE_SELECTED_IDENTITY="${identity_files[$identity_choice]}"
      AGE_SELECTED_IDENTITY_TYPE="${identity_types[$identity_choice]}"
      ;;
    1)
      armor_file="${temp_dir}/pasted-identity.age"
      echo "Вставьте защищённый текстовый блок приватного ключа, начиная со строки BEGIN."
      echo "Вставляемый блок не скрывается и будет виден на экране."
      echo "Ввод завершится после строки END и перевода строки за ней."
      echo "Для отмены нажмите Enter на пустой строке."
      echo
      : > "$armor_file"
      while IFS= read -r line; do
        if [[ -z "$line" ]]; then
          [[ ! -s "$armor_file" ]] && input_cancelled=1
          break
        fi
        if [[ ! -s "$armor_file" && "$line" != "-----BEGIN AGE ENCRYPTED FILE-----" ]]; then
          invalid_identity_format=1
          break
        fi
        printf '%s\n' "$line" >> "$armor_file"
        if [[ "$line" == "-----END AGE ENCRYPTED FILE-----" ]]; then
          armor_complete=1
          break
        fi
      done
      if [[ "$input_cancelled" -eq 1 ]]; then
        return 1
      fi
      if [[ "$invalid_identity_format" -eq 1 ]]; then
        echo -e "Вставленный текст ${RED}не является${WHITE} защищённым приватным ключом age."
        return 2
      fi
      if [[ "$armor_complete" -ne 1 ]] || ! grep -Fqx -- "-----BEGIN AGE ENCRYPTED FILE-----" "$armor_file"; then
        echo -e "Защищённый текстовый блок приватного ключа введён ${RED}не полностью${WHITE}."
        return 2
      fi
      AGE_SELECTED_IDENTITY="$armor_file"
      AGE_SELECTED_IDENTITY_TYPE="age"
      ;;
    2)
      armor_file="${temp_dir}/pasted-ssh-identity"
      echo "Вставьте приватный SSH-ключ целиком, начиная со строки BEGIN."
      echo "Вставляемый блок не скрывается и будет виден на экране."
      echo "Ввод завершится после строки END и перевода строки за ней."
      echo "Для отмены нажмите Enter на пустой строке."
      echo
      : > "$armor_file"
      while IFS= read -r line; do
        if [[ -z "$line" ]]; then
          [[ ! -s "$armor_file" ]] && input_cancelled=1
          break
        fi
        if [[ -z "$expected_end" ]]; then
          case "$line" in
            "-----BEGIN OPENSSH PRIVATE KEY-----") expected_end="-----END OPENSSH PRIVATE KEY-----" ;;
            "-----BEGIN RSA PRIVATE KEY-----") expected_end="-----END RSA PRIVATE KEY-----" ;;
            "-----BEGIN PRIVATE KEY-----") expected_end="-----END PRIVATE KEY-----" ;;
            "-----BEGIN ENCRYPTED PRIVATE KEY-----") expected_end="-----END ENCRYPTED PRIVATE KEY-----" ;;
            *) invalid_identity_format=1; break ;;
          esac
        fi
        printf '%s\n' "$line" >> "$armor_file"
        if [[ "$line" == "$expected_end" ]]; then
          armor_complete=1
          break
        fi
      done
      if [[ "$input_cancelled" -eq 1 ]]; then
        return 1
      fi
      if [[ "$invalid_identity_format" -eq 1 ]]; then
        echo -e "Вставленный текст ${RED}не является${WHITE} приватным SSH-ключом."
        return 2
      fi
      if [[ "$armor_complete" -ne 1 ]]; then
        echo -e "Приватный SSH-ключ вставлен ${RED}не полностью${WHITE}."
        return 2
      fi
      if [[ "$(age_identity_file_type "$armor_file")" != "ssh" ]]; then
        echo -e "Вставленный блок ${RED}не является поддерживаемым приватным SSH-ключом${WHITE}."
        return 2
      fi
      AGE_SELECTED_IDENTITY="$armor_file"
      AGE_SELECTED_IDENTITY_TYPE="ssh"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

unlock_age_identity() {
  local protected_identity_file="$1"
  local unlocked_identity_file="$2"
  local error_file="${unlocked_identity_file}.age-error"

  AGE_DECRYPT_ERROR=""
  rm -f -- "$unlocked_identity_file" "$error_file"
  if ! age -d -o "$unlocked_identity_file" "$protected_identity_file" 2> "$error_file"; then
    if grep -Fqi -- "incorrect passphrase" "$error_file"; then
      AGE_DECRYPT_ERROR="incorrect_passphrase"
    else
      AGE_DECRYPT_ERROR="identity_unlock_failed"
    fi
    rm -f -- "$unlocked_identity_file" "$error_file"
    return 1
  fi
  rm -f -- "$error_file"
  if ! chmod 600 "$unlocked_identity_file"; then
    rm -f -- "$unlocked_identity_file"
    AGE_DECRYPT_ERROR="identity_unlock_failed"
    return 1
  fi
  return 0
}

prepare_ssh_identity() {
  local source_identity_file="$1"
  local prepared_identity_file="$2"
  local error_file="${prepared_identity_file}.ssh-error"

  AGE_DECRYPT_ERROR=""
  rm -f -- "$prepared_identity_file" "$error_file"
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    AGE_DECRYPT_ERROR="ssh_keygen_missing"
    return 1
  fi
  if ! ssh_identity_file_valid "$source_identity_file"; then
    AGE_DECRYPT_ERROR="ssh_identity_invalid"
    return 1
  fi
  if ! install -m 600 "$source_identity_file" "$prepared_identity_file"; then
    AGE_DECRYPT_ERROR="ssh_identity_prepare_failed"
    return 1
  fi

  if LC_ALL=C ssh-keygen -y -P '' -f "$prepared_identity_file" >/dev/null 2> "$error_file"; then
    rm -f -- "$error_file"
    return 0
  fi

  echo
  echo "Приватный SSH-ключ защищён паролем."
  echo "Введите его пароль. Вводимые символы не отображаются на экране."
  if ! LC_ALL=C ssh-keygen -p -q -N '' -f "$prepared_identity_file" >/dev/null 2> "$error_file"; then
    rm -f -- "$prepared_identity_file" "$error_file"
    AGE_DECRYPT_ERROR="ssh_identity_unlock_failed"
    return 1
  fi
  if ! LC_ALL=C ssh-keygen -y -P '' -f "$prepared_identity_file" >/dev/null 2> "$error_file"; then
    rm -f -- "$prepared_identity_file" "$error_file"
    AGE_DECRYPT_ERROR="ssh_identity_prepare_failed"
    return 1
  fi
  rm -f -- "$error_file"
  if ! chmod 600 "$prepared_identity_file"; then
    rm -f -- "$prepared_identity_file"
    AGE_DECRYPT_ERROR="ssh_identity_prepare_failed"
    return 1
  fi
  return 0
}

decrypt_age_file() {
  local encrypted_file="$1"
  local identity_file="$2"
  local output_file="$3"
  local partial_file="${output_file}.partial"
  local error_file="${output_file}.age-error"

  AGE_DECRYPT_ERROR=""
  rm -f -- "$partial_file" "$error_file"
  if ! age -d -i "$identity_file" -o "$partial_file" "$encrypted_file" 2> "$error_file"; then
    if grep -Fqi -- "incorrect passphrase" "$error_file"; then
      AGE_DECRYPT_ERROR="incorrect_passphrase"
    else
      AGE_DECRYPT_ERROR="decrypt_failed"
    fi
    rm -f -- "$partial_file" "$error_file"
    return 1
  fi
  rm -f -- "$error_file"
  mv -f -- "$partial_file" "$output_file"
}

decrypt_age_archive() (
  local encrypted_file="$1"
  local filename parent_dir plain_filename temp_dir plain_file
  local key_temp_dir=""
  local companion_encrypted="" companion_filename="" companion_plain=""
  local choice identity_file protected_identity_file unlocked_identity_file selected_identity_type identity_select_status
  local identity_was_pasted=0

  if ! backup_crypto_available; then
    echo -e "Команда ${RED}age не установлена${WHITE}. Расшифрование недоступно."
    return 1
  fi
  filename="$(basename "$encrypted_file")"
  parent_dir="$(dirname "$encrypted_file")"
  plain_filename="${filename%.age}"
  case "$plain_filename" in
    *.tar.gz|*.sql.gz|*.gz) ;;
    *)
      echo -e "Файл ${RED}${filename}${WHITE} имеет неподдерживаемое имя зашифрованного архива."
      return 1
      ;;
  esac

  if [[ "$filename" == *.tar.gz.age ]]; then
    companion_encrypted="${encrypted_file%.tar.gz.age}.sql.gz.age"
  elif [[ "$filename" == *.sql.gz.age ]]; then
    companion_encrypted="${encrypted_file%.sql.gz.age}.tar.gz.age"
  fi
  if [[ -n "$companion_encrypted" && ! -f "$companion_encrypted" ]]; then
    companion_encrypted=""
  fi

  temp_dir="$(mktemp -d "${parent_dir}/.rish-decrypt.XXXXXX" 2>/dev/null)" || temp_dir="$(mktemp -d)" || return 1
  chmod 700 "$temp_dir"
  umask 077
  trap 'rm -rf -- "$temp_dir"; [[ -z "$key_temp_dir" ]] || rm -rf -- "$key_temp_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 129' HUP
  trap 'exit 143' TERM
  plain_file="${temp_dir}/${plain_filename}"

  clear
  echo -e "Зашифрованный архив: ${GREEN}${filename}${WHITE}"
  if [[ -n "$companion_encrypted" ]]; then
    echo -e "Найден соседний архив: ${GREEN}$(basename "$companion_encrypted")${WHITE}"
  fi
  echo
  vertical_menu "current" 2 0 54 \
    "Открыть и восстановить содержимое" \
    "Расшифровать в обычный архив" \
    "Выйти"
  choice=$?
  if [[ "$choice" -eq 255 || "$choice" -eq 2 ]]; then
    return 0
  fi

  key_temp_dir="$(mktemp -d /run/rish-age-key.XXXXXX 2>/dev/null)" || {
    echo -e "Не удалось подготовить защищённый временный каталог в ${RED}/run${WHITE}."
    return 1
  }
  if ! chmod 700 "$key_temp_dir"; then
    echo -e "Не удалось установить права на временный каталог в ${RED}/run${WHITE}."
    return 1
  fi

  select_age_identity "$key_temp_dir"
  identity_select_status=$?
  if [[ "$identity_select_status" -ne 0 ]]; then
    if [[ "$identity_select_status" -eq 1 ]]; then
      echo -e "Расшифрование ${YELLOW}отменено${WHITE}."
    else
      echo -e "Расшифрование ${YELLOW}не выполнено${WHITE}."
    fi
    return 1
  fi
  protected_identity_file="$AGE_SELECTED_IDENTITY"
  selected_identity_type="$AGE_SELECTED_IDENTITY_TYPE"
  unlocked_identity_file="${key_temp_dir}/unlocked-private-key.txt"
  if [[ "$protected_identity_file" == "${key_temp_dir}/pasted-"* ]]; then
    identity_was_pasted=1
  fi

  if [[ "$selected_identity_type" == "age" ]]; then
    echo
    echo "Введите пароль приватного ключа."
    echo "Вводимые символы не отображаются на экране."
    if ! unlock_age_identity "$protected_identity_file" "$unlocked_identity_file"; then
      if [[ "$AGE_DECRYPT_ERROR" == "incorrect_passphrase" ]]; then
        echo -e "Введён ${RED}неверный пароль${WHITE} приватного ключа."
      else
        echo -e "Не удалось ${RED}открыть приватный ключ${WHITE}. Проверьте файл ключа и его целостность."
      fi
      return 1
    fi
  elif [[ "$selected_identity_type" == "ssh" ]]; then
    if ! prepare_ssh_identity "$protected_identity_file" "$unlocked_identity_file"; then
      if [[ "$AGE_DECRYPT_ERROR" == "ssh_keygen_missing" ]]; then
        echo -e "Команда ${RED}ssh-keygen не установлена${WHITE}. Подготовка SSH-ключа недоступна."
      elif [[ "$AGE_DECRYPT_ERROR" == "ssh_identity_invalid" ]]; then
        echo -e "Выбранный файл ${RED}не является поддерживаемым приватным SSH-ключом${WHITE}."
      else
        echo -e "Не удалось ${RED}подготовить приватный SSH-ключ${WHITE}. Проверьте ключ и его пароль."
      fi
      return 1
    fi
  else
    echo -e "Не удалось ${RED}определить тип приватного ключа${WHITE}."
    return 1
  fi
  identity_file="$unlocked_identity_file"

  if [[ "$identity_was_pasted" -eq 1 ]]; then
    clear
    echo -e "Зашифрованный архив: ${GREEN}${filename}${WHITE}"
    if [[ -n "$companion_encrypted" ]]; then
      echo -e "Найден соседний архив: ${GREEN}$(basename "$companion_encrypted")${WHITE}"
    fi
    echo
  else
    echo
  fi

  if [[ "$choice" -eq 0 ]]; then
    echo -e "Открываем ${GREEN}${filename}${WHITE} без создания промежуточного расшифрованного архива..."
    extract "$encrypted_file" "$parent_dir" "$identity_file" "$companion_encrypted"
    return $?
  fi

  echo -e "Расшифровываем ${GREEN}${filename}${WHITE}..."
  if ! decrypt_age_file "$encrypted_file" "$identity_file" "$plain_file"; then
    if [[ "$AGE_DECRYPT_ERROR" == "incorrect_passphrase" ]]; then
      echo -e "Введён ${RED}неверный пароль${WHITE} приватного ключа."
    else
      report_age_archive_open_error "$encrypted_file"
    fi
    return 1
  fi

  if [[ -n "$companion_encrypted" ]]; then
    companion_filename="$(basename "${companion_encrypted%.age}")"
    companion_plain="${temp_dir}/${companion_filename}"
    echo -e "Расшифровываем ${GREEN}$(basename "$companion_encrypted")${WHITE}..."
    if ! decrypt_age_file "$companion_encrypted" "$identity_file" "$companion_plain"; then
      echo -e "Не удалось ${RED}расшифровать соседний архив${WHITE}. Открытые временные данные удалены."
      return 1
    fi
  fi

  if [[ -e "${parent_dir}/${plain_filename}" ]]; then
    echo -e "Файл ${YELLOW}${parent_dir}/${plain_filename}${WHITE} уже существует."
    vertical_menu "current" 2 0 42 "Отмена" "Перезаписать"
    [[ "$?" -eq 1 ]] || return 1
  fi
  if ! mv -f -- "$plain_file" "${parent_dir}/${plain_filename}"; then
    echo -e "Не удалось сохранить открытый архив: ${RED}${parent_dir}/${plain_filename}${WHITE}"
    return 1
  fi
  if ! chmod 600 "${parent_dir}/${plain_filename}"; then
    echo -e "Открытый архив создан, но не удалось установить права 600: ${RED}${parent_dir}/${plain_filename}${WHITE}"
    return 1
  fi
  echo -e "Создан открытый архив: ${GREEN}${parent_dir}/${plain_filename}${WHITE}"
  if [[ -n "$companion_plain" ]]; then
    if [[ -e "${parent_dir}/${companion_filename}" ]]; then
      echo -e "Соседний файл ${YELLOW}${parent_dir}/${companion_filename}${WHITE} уже существует и оставлен без изменений."
    else
      if ! mv -- "$companion_plain" "${parent_dir}/${companion_filename}"; then
        echo -e "Основной архив сохранён, но не удалось сохранить соседний архив: ${RED}${parent_dir}/${companion_filename}${WHITE}"
        return 1
      fi
      if ! chmod 600 "${parent_dir}/${companion_filename}"; then
        echo -e "Соседний архив создан, но не удалось установить права 600: ${RED}${parent_dir}/${companion_filename}${WHITE}"
        return 1
      fi
      echo -e "Создан соседний открытый архив: ${GREEN}${parent_dir}/${companion_filename}${WHITE}"
    fi
  fi
  echo
  echo -e "Не оставляйте ${YELLOW}расшифрованные архивы${WHITE} на сервере дольше необходимого."
)


function extract() {
  local file="$1"
  local restore_site_path="${2:-}"
  local decrypt_identity="${3:-}"
  local encrypted_companion="${4:-}"
  local archive_crypto_available=0
  local filename logical_filename tar_archive=""
  filename="$(basename "$file")"
  logical_filename="$filename"
  if [[ -n "$decrypt_identity" && "$logical_filename" == *.age ]]; then
    logical_filename="${logical_filename%.age}"
  fi
  local ext="${logical_filename##*.}"
  local base="${logical_filename%.*}"

  # Уточняем расширение
  if [[ "$logical_filename" == *.sql.gz ]]; then
    ext="sql.gz"
    base="${logical_filename%.sql.gz}"
  elif [[ "$logical_filename" == *.tar.gz ]]; then
    ext="tar.gz"
    base="${logical_filename%.tar.gz}"
  elif [[ "$logical_filename" == *.gz ]]; then
    ext="gz"
    base="${logical_filename%.gz}"
  elif [[ "$logical_filename" == *.zip ]]; then
    ext="zip"
    base="${logical_filename%.zip}"
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
    if [[ -n "$decrypt_identity" ]]; then
      if [[ "$encrypted_companion" == *.tar.gz.age && -f "$encrypted_companion" ]]; then
        tar_archive="$encrypted_companion"
      fi
    else
      tar_archive="${file%.sql*}.tar.gz"
    fi
    if [[ -n "$tar_archive" && -f "$tar_archive" ]]; then
      options+=("restore_site_from_sql::Восстановить сайт + базу из архива ${db_guess}")
    fi
    options+=("restore_db_auto::Восстановить базу данных ${db_guess}")
    options+=("restore_db_custom::Восстановить базу данных (указать своё имя)")
    if [[ "$ext" == "sql" ]]; then
      if prepare_archive_crypto_for_path "$file"; then
        archive_crypto_available="$ARCHIVE_USE_CRYPTO"
      else
        echo -e "Пункт ${YELLOW}(шифр)${WHITE} недоступен. Обычный архив можно создать без шифрования."
      fi
      ARCHIVE_USE_CRYPTO=0
      if [[ "$archive_crypto_available" -eq 1 ]]; then
        options+=("archive_file_crypto::Создать архив файла $filename (шифр)")
      fi
      options+=("archive_file::Создать архив файла $filename")
    fi
    [[ "$ext" == "sql.gz" ]] && options+=("unpack_sql::Извлечь SQL-файл из архива $logical_filename")
  elif [[ "$ext" == "gz" ]]; then
    options+=("unpack_gz::Распаковать файл ${logical_filename}")
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
    restore_folder) restore_folder "$file" "$db_guess" "manual" "$decrypt_identity" ;;
    restore_site) restore_site "$file" "$db_guess" "$restore_site_path" "$decrypt_identity" "$encrypted_companion" ;;
    restore_db_auto) restore_db_auto "$file" "$db_guess" "$decrypt_identity" ;;
    restore_db_custom) restore_db_custom "$file" "$db_guess" "$decrypt_identity" ;;
    archive_file_crypto)
      ARCHIVE_USE_CRYPTO=1
      archive_file "$file"
      ;;
    archive_file)
      ARCHIVE_USE_CRYPTO=0
      archive_file "$file"
      ;;
    restore_zip_folder) restore_zip_folder "$file" "$db_guess" ;;
    unpack_sql)
      local sql_name sql_temp
      sql_name="$(dirname "$file")/${logical_filename%.gz}"
      sql_temp="${sql_name}.rish-tmp.$$"
      echo -e "Распаковываем SQL-файл ${GREEN}${filename}${WHITE} → ${GREEN}$(basename "$sql_name")${WHITE}..."
      if [[ -n "$decrypt_identity" ]] && \
        (set -o pipefail; age -d -i "$decrypt_identity" "$file" 2>/dev/null | gunzip -c > "$sql_temp") && \
        mv -f -- "$sql_temp" "$sql_name"; then
        echo -e "Файл успешно извлечён: ${GREEN}$(basename "$sql_name")${WHITE}"
      elif [[ -z "$decrypt_identity" ]] && gunzip -c "$file" > "$sql_temp" && mv -f -- "$sql_temp" "$sql_name"; then
        echo -e "Файл успешно извлечён: ${GREEN}$(basename "$sql_name")${WHITE}"
      else
        rm -f -- "$sql_temp"
        echo -e "Ошибка при распаковке SQL-файла${RED}${filename}${WHITE}"
      fi
      ;;
    unpack_gz)
      local out_file out_temp
      out_file="$(dirname "$file")/${logical_filename%.gz}"
      out_temp="${out_file}.rish-tmp.$$"
      echo -e "Распаковываем файл ${GREEN}${filename}${WHITE} → ${GREEN}$(basename "$out_file")${WHITE}..."
      if [[ -n "$decrypt_identity" ]] && \
        (set -o pipefail; age -d -i "$decrypt_identity" "$file" 2>/dev/null | gunzip -c > "$out_temp") && \
        mv -f -- "$out_temp" "$out_file"; then
        echo -e "Файл успешно извлечён: ${GREEN}$(basename "$out_file")${WHITE}"
      elif [[ -z "$decrypt_identity" ]] && gunzip -c "$file" > "$out_temp" && mv -f -- "$out_temp" "$out_file"; then
        echo -e "Файл успешно извлечён: ${GREEN}$(basename "$out_file")${WHITE}"
      else
        rm -f -- "$out_temp"
        echo -e "Ошибка при распаковке файла${RED}${filename}${WHITE}"
      fi
      ;;
    restore_site_from_sql)
      restore_site "$tar_archive" "$db_guess" "$restore_site_path" "$decrypt_identity" "$file"
      ;;
  esac
}

# Если скрипт вызван напрямую — запускаем функцию
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  fullpath="$2/$1"

  if [[ -f "$fullpath" ]]; then
    filename="$(basename "$fullpath")"
    case "$filename" in
      *.age)
        decrypt_age_archive "$fullpath"
        ;;
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
