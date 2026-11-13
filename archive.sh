#!/usr/bin/env bash

source /root/rish/windows.sh
source /root/rish/scripts/site_helpers.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /root/rish/scripts/backup_crypto.sh ]]; then
  source /root/rish/scripts/backup_crypto.sh
else
  source "${SCRIPT_DIR}/scripts/backup_crypto.sh"
fi
# shellcheck source=scripts/backup_source.sh
source "${SCRIPT_DIR}/scripts/backup_source.sh" || exit 1

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
  local row_user row_target _row_type _row_db _row_remote row_policy _row_exclude

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

  while IFS=';' read -r row_user row_target _row_type _row_db _row_remote row_policy _row_exclude; do
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
          ARCHIVE_EXCLUDE_ARGS+=("--exclude=./${normalized}/*")
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

archive_enter_directory() {
  local path="$1" lexical resolved
  lexical="$(realpath -ms -- "$path")" || return 1
  if [[ "$lexical" =~ ^(/var/www/[^/]+)/www/ ]]; then
    backup_source_enter_user "${BASH_REMATCH[1]}" "$lexical"
  elif ! resolved="$(realpath -e -- "$path")" || ! backup_source_enter_resolved "$resolved"; then
    printf 'Не удалось открыть каталог %s.\n' "$path" >&2
    return 1
  fi
}

function print_archive_exclude_preview() (
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
  disk_free="$(df -h -P "$parent_path" | awk 'NR==2 {print $4}')"
  archive_enter_directory "$folder_path" || return 1

  for arg in "$@"; do
    if [[ "$arg" =~ --exclude=.+ ]]; then
      du_exclude+=("--exclude=${arg#--exclude=}")
    fi
  done

  folder_size_mb=$(du --apparent-size -sm "${du_exclude[@]}" -- . | cut -f1)

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
)

function confirm_archive_with_exclude() {
  local folder_path="$1"
  local choice

  while true; do
    select_archive_exclude_dirs || return 1
    print_archive_exclude_preview "$folder_path" "${ARCHIVE_EXCLUDE_ARGS[@]}" || return 1

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
    local size_bytes
    size_bytes=$(archive_enter_directory "$fullpath" && du --apparent-size -sm -- . | cut -f1) || return 1

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
  if ((has_db == 1)); then
    base_options+=("archive_db::Создать архив базы данных ${folder}")
  fi
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
  if [[ -d "$fullpath" ]]; then
    options+=("download_remote::Скачать копию из бекапа на сервер")
    options+=("restore_remote::Восстановить бэкап из облака потоком")
  fi
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
  if [[ "$action" == "download_remote" ]]; then
    (cd -- "$path" && bash /root/rish/backup2.sh --download-backup)
    return $?
  fi
  if [[ "$action" == "restore_remote" ]]; then
    bash /root/rish/backup2.sh --restore-stream "$fullpath"
    return $?
  fi
  if [[ "$action" == *_crypto ]]; then
    ARCHIVE_USE_CRYPTO=1
    action="${action%_crypto}"
  fi

  local dt
  dt=$(date "+%Y-%m-%d_%H-%M")
  local base_name="${folder}_${dt}"
  ARCHIVE_EXCLUDE_ARGS=()

  case "$action" in
    archive_site_and_db|archive_site_with_exclude)
      if [[ "$action" == archive_site_with_exclude ]]; then
        confirm_archive_with_exclude "$fullpath" || return 1
      fi
      archive_site "$fullpath" "$base_name" "${ARCHIVE_EXCLUDE_ARGS[@]}" || return "$?"
      archive_db "$folder" "$base_name"
      ;;
    archive_site)
      archive_site "$fullpath" "$base_name"
      ;;
    archive_db)
      archive_db "$folder" "$base_name"
      ;;
    archive_folder_with_exclude)
      confirm_archive_with_exclude "$fullpath" || return 1
      archive_site "$fullpath" "$base_name" "${ARCHIVE_EXCLUDE_ARGS[@]}"
      ;;
  esac

}

function archive_site() (
  local folder_path="$1"
  local archive_name="$2"
  shift 2
  local arg
  local extra_args=("$@")
  local parent_path
  local folder transform
  local crypto_suffix=""
  local tar_command=(/usr/bin/env -u TAR_OPTIONS /usr/bin/tar)
  parent_path="$(realpath -e -- "$(dirname -- "$folder_path")")" || return 1
  folder="$(basename "$folder_path")"
  archive_enter_directory "$folder_path" || return 1
  if [[ "$parent_path" == "$PWD" || "$parent_path" == "$PWD/"* ]]; then
    printf 'Каталог для готового архива находится внутри архивируемой папки.\n' >&2
    return 1
  fi
  transform="$(backup_source_tar_transform "$folder")" || return 1
  [[ "$ARCHIVE_USE_CRYPTO" -eq 1 ]] && crypto_suffix=".age"
  local archive_path="${parent_path}/${archive_name}.tar.gz${crypto_suffix}"

  # Формируем исключения для du
  local du_exclude=()
  for arg in "${extra_args[@]}"; do
    if [[ "$arg" =~ --exclude=.+ ]]; then
      du_exclude+=("--exclude=${arg#--exclude=}")
    fi
  done

  # Вычисление размера папки в мегабайтах с учетом исключений
  local folder_size_mb
  folder_size_mb=$(du --apparent-size -sm "${du_exclude[@]}" -- . | cut -f1)

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
  local archive_tmp tar_err_file archive_mode
  local tar_reason=""
  local -a pipeline_status=()

  tar_err_file="$(mktemp)" || {
    echo -e "${RED}Не удалось${WHITE} подготовить временный файл для анализа ошибок tar."
    return 2
  }
  archive_tmp=""
  trap 'rm -f -- "$tar_err_file"; [[ -z "$archive_tmp" ]] || rm -f -- "$archive_tmp"' EXIT
  archive_tmp="$(mktemp -- "${archive_path}.rish-tmp.XXXXXXXX")" || return 2

  if [[ "$ARCHIVE_USE_CRYPTO" -eq 1 ]]; then
    "${tar_command[@]}" -czf - --transform="$transform" "${extra_args[@]}" \
      --record-size=$recordsize --checkpoint=$checkpoint \
      --checkpoint-action=exec="echo -e \"${CURSORUP}Обработано: \$((TAR_CHECKPOINT / 1000)) MB${ERASEUNTILLENDOFLINE}\r\" >&2" \
      -- . \
      2> >(tee "$tar_err_file" >&2) \
      | age "${ARCHIVE_CRYPTO_ARGS[@]}" > "$archive_tmp"
    pipeline_status=("${PIPESTATUS[@]}")
    tar_rc="${pipeline_status[0]}"
    age_rc="${pipeline_status[1]}"
    if [[ "$age_rc" -ne 0 ]]; then
      tar_reason="age завершился с ошибкой ${age_rc}"
      tar_rc=2
    fi
  else
    "${tar_command[@]}" -czf "$archive_tmp" --transform="$transform" "${extra_args[@]}" \
      --record-size=$recordsize --checkpoint=$checkpoint \
      --checkpoint-action=exec="echo -e \"${CURSORUP}Обработано: \$((TAR_CHECKPOINT / 1000)) MB${ERASEUNTILLENDOFLINE}\r\" >&2" \
      -- . \
      2> >(tee "$tar_err_file" >&2)
    tar_rc=$?
  fi
  if ((tar_rc < 2)); then
    printf -v archive_mode '%03o' "$((0666 & ~$(umask)))"
    if ! chmod "$archive_mode" -- "$archive_tmp" || ! mv -fT -- "$archive_tmp" "$archive_path"; then
      tar_reason="не удалось сохранить архив"
      tar_rc=2
    fi
  fi
  echo -e "${CURSORUP}${ERASEUNTILLENDOFLINE}"

  if [[ -z "$tar_reason" && -s "$tar_err_file" ]]; then
    tar_reason="$(grep '^tar:' "$tar_err_file" | sed 's/\r$//' | awk 'NR==1{out=$0;next}{out=out "; " $0} END{print out}')"
    if [[ -z "$tar_reason" ]]; then
      tar_reason="$(grep -v 'Обработано:' "$tar_err_file" | sed '/^[[:space:]]*$/d' | tail -n 1)"
    fi
  fi
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
      echo "Некоторые файлы изменились во время создания архива."
      echo -e "Копии этих файлов могут быть ${YELLOW}неточными${WHITE}, но архив сохранен."
      tar_rc=0
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
)

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

# Источник можно открывать повторно: файл либо последовательность удалённых
# частей. Контекст передаётся по имени associative array, без eval и FIFO.
restore_source_bytes() (
  local context="$1" role="$2" source_file identity manifest
  local -n source_ref="$context"
  set -o pipefail
  if [[ "$role" == tar ]]; then
    source_file="${source_ref['tar']}"
    identity="${source_ref['identity']:-}"
    manifest="${source_ref['tar_manifest']:-}"
  else
    source_file="${source_ref['sql']}"
    identity="${source_ref['sql_identity']:-}"
    manifest="${source_ref['sql_manifest']:-}"
  fi
  if [[ "${source_ref['kind']}" == remote ]]; then
    if [[ -n "$identity" ]]; then
      rish_restore_read_parts "$manifest" "${source_ref['remote']}" "${source_ref['workdir']}" | age -d -i "$identity"
    else
      rish_restore_read_parts "$manifest" "${source_ref['remote']}" "${source_ref['workdir']}"
    fi
  elif [[ -n "$identity" ]]; then
    age -d -i "$identity" "$source_file"
  else
    cat -- "$source_file"
  fi
)

restore_source_tar() (
  local context="$1" tar_mode="$2" tar_status
  shift 2
  set -o pipefail
  restore_source_bytes "$context" tar | gzip -dc | (
    LC_ALL=C.UTF-8 tar "$tar_mode" - --quoting-style=escape "$@"
    tar_status=$?
    # tar может завершиться до конца gzip. Дочитываем источник, чтобы
    # проверить CRC, age и все части, а читатель успел сохранить SHA-256.
    cat >/dev/null || exit 1
    exit "$tar_status"
  )
)

restore_source_sql() (
  local context="$1" member
  local -n source_ref="$context"
  set -o pipefail
  member="${source_ref['sql_member']:-}"
  if [[ -n "$member" ]]; then
    if [[ "$member" == *.gz ]]; then
      restore_source_tar "$context" -xOf -- "$member" | gzip -dc
    else
      restore_source_tar "$context" -xOf -- "$member"
    fi
  elif [[ "${source_ref['sql']%.age}" == *.gz ]]; then
    restore_source_bytes "$context" sql | gzip -dc
  else
    restore_source_bytes "$context" sql
  fi
)

restore_source_protect() {
  local context="$1" target="$2" item canonical target_real
  local -n source_ref="$context"
  target_real="$(realpath -m -- "$target")" || return 1
  local -a protected=("${source_ref['identity']:-}" "${source_ref['sql_identity']:-}" "${source_ref['workdir']:-}")
  if [[ "${source_ref['kind']}" == file ]]; then
    protected+=("${source_ref['tar']:-}" "${source_ref['sql']:-}")
  fi
  for item in "${protected[@]}"; do
    [[ -n "$item" ]] || continue
    canonical="$(realpath -m -- "$item")" || return 1
    if [[ "$canonical" == "$target_real" || "$canonical" == "$target_real/"* ]]; then
      echo -e "Источник восстановления ${YELLOW}${canonical}${WHITE} находится внутри папки назначения."
      echo "Переместите источник за пределы папки сайта."
      return 1
    fi
  done
}

function validate_database_archive() {
  local file="$1" decrypt_identity="${2:-}" context="${3:-validation_restore_source}"
  # Контекст передаётся помощникам по имени переменной.
  # shellcheck disable=SC2034
  local -A validation_restore_source=(['kind']=file ['sql']="$file" ['sql_identity']="$decrypt_identity")
  # Проверяем весь поток и не принимаем пустой SQL. Сам дамп не сохраняем.
  if ! (set -o pipefail; restore_source_sql "$context" | (
    local first_byte
    # Первый символ нужен только для проверки непустого потока.
    # shellcheck disable=SC2034
    IFS= read -r -N 1 first_byte || exit 1
    cat >/dev/null
  )); then
    echo -e "Не удалось проверить дамп ${YELLOW}$(basename "$file")${WHITE}: источник недоступен, пуст, повреждён или ключ не подходит."
    return 1
  fi
}

function inspect_tar_archive_layout() {
  local archive_path="$1" decrypt_identity="${2:-}" context="${3:-inspect_restore_source}"
  local tar_list_file entry
  # shellcheck disable=SC2034
  local -A inspect_restore_source=(['kind']=file ['tar']="$archive_path" ['identity']="$decrypt_identity")
  local -n inspect_source_ref="$context"
  tar_list_file="$(mktemp)" || return 1
  if ! restore_source_tar "$context" -tf > "$tar_list_file"; then
    echo -e "Архив ${YELLOW}$(basename "$archive_path")${WHITE} недоступен, повреждён или ключ не подходит."
    rm -f -- "$tar_list_file"
    return 1
  fi
  if [[ "${inspect_source_ref['kind']}" == remote ]]; then
    while IFS= read -r entry; do
      if [[ -z "$entry" || "$entry" == /* || "$entry" == -* || "$entry" == *\\* ||
            "/$entry/" == */../* || "/$entry/" == */./* ]]; then
        echo "Архив содержит неподдерживаемые пути. Восстановление прервано."
        rm -f -- "$tar_list_file"
        return 1
      fi
    done < "$tar_list_file"
  fi
  inspect_tar_archive_entries "$tar_list_file"
  local layout_status=$?
  rm -f -- "$tar_list_file"
  return "$layout_status"
}

function inspect_tar_archive_entries() {
  local tar_list_file="$1"
  local entry top item seen
  local -a root_dirs=() root_files=() root_items=() sql_candidates=()

  ARCHIVE_SINGLE_ROOT_DIR=""
  ARCHIVE_SQL_ENTRY=""
  ARCHIVE_LAYOUT="mixed"

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


restore_cron() (
  local archive_path="$1"
  local decrypt_identity="${2:-}"
  local filename logical_filename source_user cron_entry archive_entries archive_details
  local temp_dir new_cron current_cron latest_cron cron_error install_cron user_path candidate target_user
  local choice action_choice default_index current_exists cron_exists=0
  local -a users=() menu_items=()

  if [[ "$(id -u)" != "0" ]]; then
    echo -e "Восстановление CRON доступно только пользователю ${YELLOW}root${WHITE}."
    return 1
  fi
  if [[ ! -f "$archive_path" ]]; then
    echo -e "Файл архива ${RED}не найден${WHITE}."
    return 1
  fi

  filename="$(basename "$archive_path")"
  logical_filename="$filename"
  if [[ -n "$decrypt_identity" && "$filename" == *.age ]]; then
    logical_filename="${filename%.age}"
  fi
  if [[ ! "$logical_filename" =~ ^cron_(.+)_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}\.tar\.gz$ ]]; then
    echo -e "Ожидается архив ${YELLOW}cron_<user>_<YYYY-MM-DD_HH-MM>.tar.gz${WHITE} (или .tar.gz.age)."
    return 1
  fi
  source_user="${BASH_REMATCH[1]}"
  if [[ ! "$source_user" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*[$]?$ ]]; then
    echo -e "Имя пользователя в архиве ${RED}некорректно${WHITE}."
    return 1
  fi
  cron_entry="crontab_${source_user}.txt"

  umask 077
  temp_dir="$(mktemp -d)" || return 1
  trap 'rm -rf -- "$temp_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 129' HUP
  trap 'exit 143' TERM
  new_cron="${temp_dir}/new-crontab.txt"
  current_cron="${temp_dir}/current-crontab.txt"
  latest_cron="${temp_dir}/latest-crontab.txt"
  cron_error="${temp_dir}/crontab-error.txt"

  read_cron_archive() {
    local tar_mode="$1"
    shift
    if [[ -n "$decrypt_identity" ]]; then
      (set -o pipefail; age -d -i "$decrypt_identity" "$archive_path" 2>/dev/null \
        | LC_ALL=C tar "$tar_mode" - "$@")
    else
      LC_ALL=C tar "$tar_mode" "$archive_path" "$@"
    fi
  }

  read_current_cron() {
    local output_file="$1"
    local cron_status

    cron_exists=0
    if LC_ALL=C crontab -l -u "$target_user" > "$output_file" 2> "$cron_error"; then
      cron_exists=1
      return 0
    else
      cron_status=$?
    fi
    if [[ "$cron_status" -eq 1 && "$(cat "$cron_error")" == "no crontab for ${target_user}" && ! -s "$output_file" ]]; then
      return 0
    fi
    echo -e "Не удалось ${RED}прочитать текущий CRON${WHITE} пользователя ${YELLOW}${target_user}${WHITE}. Восстановление прервано."
    cat -- "$cron_error"
    return 1
  }

  if ! archive_entries="$(read_cron_archive -tzf)" ||
    ! archive_details="$(read_cron_archive -tvzf)"; then
    echo -e "Не удалось ${RED}прочитать архив CRON${WHITE}. Проверьте архив и ключ расшифрования."
    return 1
  fi
  # Только один обычный файл в корне: без каталогов, ссылок и дополнительных записей.
  if [[ "$archive_entries" != "$cron_entry" || "$archive_details" != -* || "$archive_details" == *$'\n'* ]]; then
    echo -e "Архив должен содержать единственный обычный файл ${YELLOW}${cron_entry}${WHITE}."
    return 1
  fi
  if ! read_cron_archive -xOzf -- "$cron_entry" > "$new_cron" || [[ ! -s "$new_cron" ]]; then
    echo -e "Не удалось извлечь ${RED}непустой файл CRON${WHITE} из архива."
    return 1
  fi

  # Как в меню CRON: root, пользователи /home и владельцы существующих crontab.
  # Исходного пользователя включаем и при нестандартном домашнем каталоге.
  for candidate in root "$source_user"; do
    if id -u "$candidate" >/dev/null 2>&1 && [[ " ${users[*]} " != *" ${candidate} "* ]]; then
      users+=("$candidate")
    fi
  done
  for user_path in /home/* /var/spool/cron/*; do
    [[ -d "$user_path" || -f "$user_path" ]] || continue
    candidate="${user_path##*/}"
    if [[ "$candidate" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*[$]?$ ]] &&
      id -u "$candidate" >/dev/null 2>&1 && [[ " ${users[*]} " != *" ${candidate} "* ]]; then
      users+=("$candidate")
    fi
  done
  default_index=${#users[@]}
  for candidate in "${users[@]}"; do
    if [[ "$candidate" == "$source_user" ]]; then
      default_index=${#menu_items[@]}
    fi
    menu_items+=("Восстановить CRON для ${candidate}")
  done
  menu_items+=("Отмена")

  echo -e "Архив CRON пользователя ${YELLOW}${source_user}${WHITE}: ${GREEN}${filename}${WHITE}"
  if ! id -u "$source_user" >/dev/null 2>&1; then
    echo -e "Пользователь ${YELLOW}${source_user}${WHITE} отсутствует. Выберите другого пользователя или отмените восстановление."
  fi
  vertical_menu "current" 2 12 50 "default=${default_index}" "${menu_items[@]}"
  choice=$?
  if ((choice == 255 || choice >= ${#users[@]})); then
    echo -e "Восстановление CRON ${YELLOW}отменено${WHITE}."
    return 0
  fi
  target_user="${users[$choice]}"
  read_current_cron "$current_cron" || return 1
  current_exists=$cron_exists

  echo
  echo -e "Задания из архива (пользователь ${YELLOW}${source_user}${WHITE}):"
  cat -- "$new_cron"
  echo
  printf '    │\n    ▼\n\n'
  echo -e "Текущие задания cron (пользователь ${YELLOW}${target_user}${WHITE}):"
  if [[ -s "$current_cron" ]]; then
    cat -- "$current_cron"
  elif ((current_exists == 1)); then
    echo "Crontab пуст."
  else
    echo "Crontab не создан."
  fi
  echo
  vertical_menu "current" 2 0 50 "default=2" \
    "Заменить текущие задания архивными" \
    "Добавить архивные в конец текущих" \
    "Отмена"
  action_choice=$?
  if ((action_choice != 0 && action_choice != 1)); then
    echo -e "Восстановление CRON ${YELLOW}отменено${WHITE}."
    return 0
  fi
  if ! id -u "$target_user" >/dev/null 2>&1; then
    echo -e "Пользователь ${RED}${target_user}${WHITE} больше не существует. Восстановление прервано."
    return 1
  fi

  read_current_cron "$latest_cron" || return 1
  if ((cron_exists != current_exists)) || ! cmp -s -- "$current_cron" "$latest_cron"; then
    echo -e "Текущий CRON пользователя ${YELLOW}${target_user}${WHITE} изменился после показа. Повторите восстановление для просмотра актуальных заданий."
    return 1
  fi

  install_cron="$new_cron"
  if ((action_choice == 1)) && [[ -s "$current_cron" ]]; then
    install_cron="${temp_dir}/merged-crontab.txt"
    if ! { cat -- "$current_cron" && printf '\n' && cat -- "$new_cron"; } > "$install_cron"; then
      echo -e "Не удалось ${RED}объединить задания CRON${WHITE}. Восстановление прервано."
      return 1
    fi
  fi

  if ! id -u "$target_user" >/dev/null 2>&1 || ! crontab -u "$target_user" "$install_cron"; then
    echo -e "Не удалось ${RED}восстановить CRON${WHITE} пользователя ${YELLOW}${target_user}${WHITE}."
    return 1
  fi
  if ((action_choice == 1)); then
    echo -e "Задания из архива добавлены в CRON пользователя ${GREEN}${target_user}${WHITE}."
  else
    echo -e "CRON пользователя ${GREEN}${target_user}${WHITE} заменён заданиями из архива."
  fi
)


restore_site_check_target() {
  local target="$1" parent user name canonical_parent
  [[ "$target" =~ ^/var/www/([a-z_][a-z0-9_-]*)/www/([^/]+)$ ]] || {
    echo -e "Укажите папку вида ${YELLOW}/var/www/<пользователь>/www/<имя-сайта>${WHITE}." >&2
    return 1
  }
  user="${BASH_REMATCH[1]}"
  name="${BASH_REMATCH[2]}"
  validate_site_name "$name" && id -u "$user" >/dev/null 2>&1 || {
    echo "Некорректное имя сайта или пользователь сервера не существует." >&2
    return 1
  }
  parent="${target%/*}"
  canonical_parent="$(realpath -e -- "$parent")" || return 1
  if [[ "$canonical_parent" != "$parent" || -L "$target" || ( -e "$target" && ! -d "$target" ) ]]; then
    echo "Для восстановления нужна обычная папка сайта без симлинков в пути назначения." >&2
    return 1
  fi
}

# Поля плана читаются другими функциями через nameref.
# shellcheck disable=SC2034
restore_folder_plan() {
  local plan_name="$1" target="$2" ask_create="${3:-0}" first_entry
  local -n plan_ref="$plan_name"
  plan_ref['target']="$target"
  plan_ref['action']=create
  plan_ref['inode']=""
  if [[ -d "$target" ]]; then
    plan_ref['inode']="$(stat -Lc '%d:%i' -- "$target")" || return 1
    first_entry="$(find -H "$target" -mindepth 1 -maxdepth 1 -printf x -quit)" || return 1
    plan_ref['action']=empty
    if [[ -n "$first_entry" ]]; then
      echo -e "Папка ${YELLOW}${target}${WHITE} не пуста (учитываются скрытые файлы)."
      vertical_menu current 2 0 60 default=2 \
        "Очистить папку и восстановить" "Восстановить поверх существующих файлов" "Отмена"
      case "$?" in
        0) plan_ref['action']=clean ;;
        1) plan_ref['action']=overlay ;;
        *) return 1 ;;
      esac
    else
      echo -e "Папка ${GREEN}${target}${WHITE} пуста."
    fi
  elif [[ -e "$target" || -L "$target" ]]; then
    echo "Путь назначения занят файлом или недоступной ссылкой."
    return 1
  elif [[ "$ask_create" -eq 1 ]]; then
    echo -e "Папка ${YELLOW}${target}${WHITE} отсутствует."
    vertical_menu current 2 0 60 default=1 "Создать папку при восстановлении" "Отмена"
    [[ "$?" -eq 0 ]] || return 1
  fi
}

restore_folder_check_plan() {
  local plan_name="$1" target first_entry
  local -n check_plan_ref="$plan_name"
  target="${check_plan_ref['target']}"
  if [[ -n "${check_plan_ref['inode']}" ]]; then
    [[ "$(stat -Lc '%d:%i' -- "$target")" == "${check_plan_ref['inode']}" ]] || {
      echo "Папка назначения изменилась. Повторите восстановление."
      return 1
    }
  elif [[ -e "$target" || -L "$target" ]]; then
    echo "Папка назначения появилась после проверки. Повторите восстановление."
    return 1
  fi
  if [[ "${check_plan_ref['action']}" == empty ]]; then
    first_entry="$(find -H "$target" -mindepth 1 -maxdepth 1 -printf x -quit)" || return 1
    [[ -z "$first_entry" ]] || { echo "Папка больше не пуста. Повторите восстановление."; return 1; }
  fi
}

function restore_folder() {
  local archive_path="$1" site_guess="$2" mode="${3:-manual}" decrypt_identity="${4:-}"
  local archive_prevalidated="${5:-0}" context="${6:-folder_restore_source}" plan_name="${7:-folder_restore_plan}"
  local folder_name="$site_guess" abs_path user_dir
  # shellcheck disable=SC2034
  local -A folder_restore_source=(['kind']=file ['tar']="$archive_path" ['identity']="$decrypt_identity")
  # shellcheck disable=SC2034
  local -A folder_restore_plan=()
  local -n folder_source_ref="$context" folder_plan_ref="$plan_name"
  local -a extract_args=()

  if [[ "$mode" != auto ]]; then
    echo -ne "${WHITE}Введите имя папки для восстановления: ${YELLOW}"
    IFS= read -r -e -i "$site_guess" folder_name || return 1
    echo -ne "${WHITE}"
    [[ -n "$folder_name" ]] || return 1
  fi
  if [[ "$archive_prevalidated" -ne 1 ]]; then
    inspect_tar_archive_layout "$archive_path" "$decrypt_identity" "$context" || return 1
  fi
  if [[ -z "${7:-}" ]]; then
    restore_folder_plan "$plan_name" "$folder_name" || return 1
  fi
  restore_folder_check_plan "$plan_name" || return 1
  if [[ "${folder_source_ref['kind']}" == remote ]]; then
    restore_site_check_target "$folder_name" || return 1
  fi
  if [[ "${folder_plan_ref['action']}" == clean ]]; then
    restore_source_protect "$context" "$folder_name" || return 1
    clean_directory_contents "$folder_name" || return 1
  fi
  # Права содержимого берутся из TAR. Для нового корня задаём 755 явно,
  # независимо от umask защищённого временного окружения age/remote.
  if [[ ! -d "$folder_name" ]]; then
    # Режим 755 нужен только конечному корню восстановления.
    # shellcheck disable=SC2174
    mkdir -p -m 755 -- "$folder_name" || return 1
  fi
  if [[ "${folder_source_ref['kind']}" == remote ]]; then
    # backup2 сохраняет единственную папку сайта; имя назначения может отличаться.
    extract_args=(--strip-components=1 -C "$folder_name" -- "${folder_source_ref['root']}")
  elif [[ "$ARCHIVE_LAYOUT" == site_plus_sql && -n "$ARCHIVE_SINGLE_ROOT_DIR" ]]; then
    extract_args=(--strip-components=1 -C "$folder_name" -- "$ARCHIVE_SINGLE_ROOT_DIR")
  elif [[ "$ARCHIVE_LAYOUT" == single_dir ]]; then
    extract_args=(--strip-components=1 -C "$folder_name")
  else
    extract_args=(-C "$folder_name")
  fi
  echo -e "Распаковываем архив в ${GREEN}${folder_name}${WHITE}..."
  if ! restore_source_tar "$context" -xf "${extract_args[@]}"; then
    echo "Ошибка распаковки. Папка может содержать частично восстановленные файлы."
    return 1
  fi
  abs_path="$(realpath -e -- "$folder_name")" || return 1
  if [[ "$abs_path" =~ ^/var/www/([^/]+)/www(/|$) ]]; then
    user_dir="${BASH_REMATCH[1]}"
    chown -R "${user_dir}:${user_dir}" -- "$folder_name" || return 1
    echo -e "Владелец восстановленных файлов: ${YELLOW}${user_dir}${WHITE}."
  fi
  echo -e "Архив восстановлен в ${GREEN}${folder_name}${WHITE}."
}

restore_site_find_config() {
  local name="$1" f
  RESTORE_SITE_CONF=""
  for f in /etc/httpd/conf.d/*.conf; do
    [[ -f "$f" ]] || continue
    if awk -v name="$name" '$1 == "ServerName" && $2 == name { found=1 } END { exit !found }' "$f"; then
      RESTORE_SITE_CONF="$f"
      return 0
    fi
  done
  return 1
}

restore_site_check_config() {
  local conf_file="$1" target="$2" document_root
  document_root="$(awk '$1 == "DocumentRoot" { print $2; exit }' "$conf_file")"
  [[ -n "$document_root" ]] || return 1
  document_root="$(realpath -ms -- "$document_root")" || return 1
  if [[ "$document_root" != "$target" && "$document_root" != "$target/"* ]]; then
    echo -e "DocumentRoot сайта указывает на другую папку: ${YELLOW}${document_root}${WHITE}."
    return 1
  fi
}

function restore_site() {
  local file="$1" site_guess="$2" site_path="${3:-}" decrypt_identity="${4:-}" encrypted_sql_file="${5:-}"
  local context="${6:-site_restore_source}" base target_path target_user target_hint document_root choice ret
  local skip_create=0 has_database=0 conf_file="" sql_label
  # shellcheck disable=SC2034
  local -A site_restore_source=(['kind']=file ['tar']="$file" ['identity']="$decrypt_identity")
  # shellcheck disable=SC2034
  local -A site_restore_plan=()
  local -n site_source_ref="$context"
  [[ -n "$site_path" ]] || site_path="$(dirname "$file")"

  if [[ "${site_source_ref['kind']}" == remote ]]; then
    target_hint="${site_source_ref['target_hint']:-}"
    if [[ -z "$target_hint" ]]; then
      if [[ "$PWD" =~ ^/var/www/[^/]+/www$ ]]; then
        target_hint="${PWD}/${site_guess}"
      elif [[ "$PWD" =~ ^(/var/www/[^/]+/www/[^/]+)(/|$) ]]; then
        target_hint="${BASH_REMATCH[1]}"
      else
        # Вне каталога сайтов сначала учитываем фактического владельца
        # существующего vhost: он мог отличаться от владельца в бэкапе.
        if restore_site_find_config "$site_guess"; then
          document_root="$(awk '$1 == "DocumentRoot" { print $2; exit }' "$RESTORE_SITE_CONF")"
          if [[ "$document_root" =~ ^(/var/www/[^/]+/www/[^/]+)(/|$) ]]; then
            target_path="${BASH_REMATCH[1]}"
            [[ "${target_path##*/}" != "$site_guess" ]] || target_hint="$target_path"
          fi
        fi
        [[ -n "$target_hint" ]] || target_hint="/var/www/${site_source_ref['user']}/www/${site_guess}"
      fi
    fi
    target_path="$(realpath -ms -- "$target_hint")" || return 1
    if ! restore_site_check_target "$target_path"; then
      echo "Откройте в Midnight Commander папку сайта или /var/www/<пользователь>/www и повторите восстановление."
      return 1
    fi
    site_path="${target_path%/*}"
    site_guess="${target_path##*/}"
    echo -e "Копия: ${GREEN}${file}${WHITE}."
  else
    if [[ "$file" != *.tar.gz && "$file" != *.tar.gz.age ]]; then
      echo "Для восстановления сайта требуется архив tar.gz или tar.gz.age."
      return 1
    fi
    site_path="$(realpath -e -- "$site_path")" || return 1
    base="${file%.tar.gz}"
    if [[ -n "$decrypt_identity" ]]; then
      if [[ -n "$encrypted_sql_file" && -f "$encrypted_sql_file" ]]; then
        site_source_ref['sql']="$encrypted_sql_file"
        site_source_ref['sql_identity']="$decrypt_identity"
      fi
    else
      [[ ! -f "${base}.sql.gz" ]] || site_source_ref['sql']="${base}.sql.gz"
      [[ ! -f "${base}.sql" ]] || site_source_ref['sql']="${base}.sql"
    fi
  fi
  if [[ "${site_source_ref['kind']}" == remote ]]; then
    # Формат backup2 известен: папка сайта в TAR, дамп БД — отдельным потоком.
    # Полное чтение до распаковки привело бы к повторному скачиванию всех частей.
    ARCHIVE_LAYOUT=single_dir
    ARCHIVE_SINGLE_ROOT_DIR="${site_source_ref['root']}"
    ARCHIVE_SQL_ENTRY=""
    site_source_ref['sql_member']=""
  else
    echo -e "Проверяем архив ${GREEN}$(basename "$file")${WHITE}..."
    inspect_tar_archive_layout "$file" "$decrypt_identity" "$context" || return 1
    if [[ -z "${site_source_ref['sql']:-}" && -n "$ARCHIVE_SQL_ENTRY" ]]; then
      site_source_ref['sql_member']="$ARCHIVE_SQL_ENTRY"
    fi
  fi
  sql_label="${site_source_ref['sql']:-${site_source_ref['sql_member']:-}}"
  if [[ -n "$sql_label" ]]; then
    if [[ "${site_source_ref['kind']}" != remote ]]; then
      validate_database_archive "$sql_label" "${site_source_ref['sql_identity']:-}" "$context" || return 1
    fi
    mariadb -N -e 'SELECT 1' >/dev/null || return 1
    has_database=1
  fi
  target_path="${site_path}/${site_guess}"
  restore_source_protect "$context" "$target_path" || return 1
  if restore_site_find_config "$site_guess"; then
    conf_file="$RESTORE_SITE_CONF"
    echo -e "Сайт ${YELLOW}${site_guess}${WHITE} уже существует."
    if restore_site_check_config "$conf_file" "$target_path"; then
      vertical_menu current 2 0 60 default=2 \
        "Восстановить в папку ${site_guess}" "Задать другое имя сайта" "Отмена"
      choice=$?
      case "$choice" in
        0) skip_create=1 ;;
        1) ;;
        *) return 1 ;;
      esac
    else
      vertical_menu current 2 0 60 default=1 "Задать другое имя сайта" "Отмена"
      [[ "$?" -eq 0 ]] || return 1
    fi
  fi

  site_name="$site_guess"
  # Один и тот же мастер создания сайта используется для обоих источников.
  # Создание vhost завершается до очистки или распаковки файлов.
  if [[ "$skip_create" -eq 0 ]]; then
    source /root/rish/create_site.sh || return 1
    create_site "$site_guess" "$site_path"
    ret=$?
    if [[ "$ret" -ne 0 && "$ret" -ne 2 ]]; then
      return 1
    fi
    # Старый мастер может вернуть 0 при Esc в выборе PHP: без vhost
    # восстановление всё равно не должно начинать запись файлов.
    restore_site_find_config "$site_name" || { echo "Сайт не был создан. Восстановление прервано."; return 1; }
    conf_file="$RESTORE_SITE_CONF"
  fi
  target_path="${site_path}/${site_name}"
  restore_site_check_config "$conf_file" "$target_path" || return 1
  if [[ "${site_source_ref['kind']}" == remote ]]; then
    restore_site_check_target "$target_path" || return 1
  fi
  restore_source_protect "$context" "$target_path" || return 1
  restore_folder_plan site_restore_plan "$target_path" || return 1
  if [[ "$site_path" =~ ^/var/www/([^/]+)/www$ ]]; then
    target_user="${BASH_REMATCH[1]}"
  else
    echo "Сайт должен находиться в /var/www/<пользователь>/www."
    return 1
  fi
  if ((has_database)) && ((${#site_name} > 64)); then
    echo "Имя сайта превышает допустимую длину имени базы (64)."
    return 1
  fi
  echo -e "Назначение: ${GREEN}${target_path}${WHITE}; владелец: ${YELLOW}${target_user}${WHITE}."
  if ((has_database)); then
    echo -e "База данных: ${YELLOW}${site_name}${WHITE}. Таблицы из дампа будут импортированы в эту базу."
  elif [[ "${site_source_ref['kind']}" == remote ]]; then
    echo "Отдельный дамп базы в выбранной копии не найден: будут восстановлены файлы."
  else
    echo "Дамп базы отсутствует: будут восстановлены только файлы."
  fi
  echo "При обрыве или ошибке после начала записи восстановление может остаться частичным."
  vertical_menu current 2 0 60 default=1 "Начать восстановление" "Отмена"
  [[ "$?" -eq 0 ]] || return 1
  restore_site_check_config "$conf_file" "$target_path" || return 1
  if ! restore_folder "$file" "$target_path" auto "$decrypt_identity" 1 "$context" site_restore_plan; then
    return 1
  fi
  if ((has_database)); then
    restore_db_core "$sql_label" "$site_name" 0 "${site_source_ref['sql_identity']:-}" 1 "$context" "$target_user" || return 1
  fi
  fix_site_configuration "$site_path" "$site_name" || return 1
  echo -e "Сайт ${GREEN}${site_name}${WHITE} восстановлен."
}

function restore_db_auto() {
  restore_db_core "$1" "$2" 0 "${3:-}" "${4:-0}"
}

function restore_db_custom() {
  restore_db_core "$1" "$2" 1 "${3:-}" "${4:-0}"
}

function restore_db_core() {
  local file="$1" db_default="$2" allow_edit="$3" decrypt_identity="${4:-}" archive_prevalidated="${5:-0}"
  local context="${6:-db_restore_source}" user_dir="${7:-}" custom_db="$2" filepath check
  # shellcheck disable=SC2034
  local -A db_restore_source=(['kind']=file ['sql']="$file" ['sql_identity']="$decrypt_identity")
  local -a import_cmd=(mariadb)
  if [[ -z "$user_dir" ]]; then
    filepath="$(realpath -e -- "$file")" || return 1
    if [[ "$filepath" =~ ^/var/www/([^/]+)/www/ ]]; then
      user_dir="${BASH_REMATCH[1]}"
    else
      echo "Архив базы должен находиться в /var/www/<пользователь>/www."
      return 1
    fi
  fi
  if [[ "$allow_edit" -eq 1 ]]; then
    echo "Введите имя базы данных (пустая строка — отмена):"
    IFS= read -r -e -i "$db_default" custom_db || return 1
  fi
  [[ -n "$custom_db" ]] || return 1
  if [[ "$custom_db" == *\`* || "$custom_db" == *\'* || "$custom_db" == *\\* ||
        "$user_dir" == *\'* || "$user_dir" == *\\* ]]; then
    echo "Недопустимые символы в имени базы или пользователя."
    return 1
  fi
  if [[ "$archive_prevalidated" -ne 1 ]]; then
    validate_database_archive "$file" "$decrypt_identity" "$context" || return 1
  fi
  check="$(mariadb -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${custom_db}'")" || return 1
  if [[ "$check" != "$custom_db" ]]; then
    echo -e "База ${YELLOW}${custom_db}${WHITE} отсутствует. Создать?"
    vertical_menu current 2 0 5 "Да" "Нет"
    [[ "$?" -eq 0 ]] || return 1
    mariadb -e "CREATE DATABASE \`${custom_db}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
  fi
  # База могла сохраниться от прежнего владельца сайта.
  mariadb -e "GRANT ALL PRIVILEGES ON \`${custom_db}\`.* TO '${user_dir}'@'localhost';" || return 1
  mariadb -e 'FLUSH PRIVILEGES;' || return 1
  if mariadb --help | grep -q -- '--sandbox'; then
    import_cmd+=(--sandbox)
  fi
  import_cmd+=("$custom_db")
  echo -e "Импортируем базу ${GREEN}${custom_db}${WHITE}..."
  if ! (set -o pipefail; restore_source_sql "$context" | (
    # Проверяем непустоту SQL на том же проходе, которым импортируем дамп.
    local first_byte
    IFS= read -r -N 1 first_byte || exit 1
    printf '%s' "$first_byte" || exit 1
    cat
  ) | "${import_cmd[@]}"); then
    echo "Ошибка чтения, расшифрования или импорта SQL. База может быть восстановлена частично."
    return 1
  fi
  echo -e "База ${GREEN}${custom_db}${WHITE} импортирована."
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
  local invalid_identity_format=0 typographic_dash=0
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
        if [[ "$typographic_dash" -eq 1 ]]; then
          backup_crypto_line_is_key_end "$line" age && break
          [[ -z "$line" ]] && break
          continue
        fi
        if backup_crypto_has_typographic_dash "$line"; then
          typographic_dash=1
          backup_crypto_line_is_key_end "$line" age && break
          continue
        fi
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
      if [[ "$typographic_dash" -eq 1 ]]; then
        backup_crypto_warn_typographic_dash
        return 2
      fi
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
        if [[ "$typographic_dash" -eq 1 ]]; then
          backup_crypto_line_is_key_end "$line" ssh && break
          [[ -z "$line" ]] && break
          continue
        fi
        if backup_crypto_has_typographic_dash "$line"; then
          typographic_dash=1
          backup_crypto_line_is_key_end "$line" ssh && break
          continue
        fi
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
      if [[ "$typographic_dash" -eq 1 ]]; then
        backup_crypto_warn_typographic_dash
        return 2
      fi
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
  local requested_action="${2:-}"
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
  if [[ "$requested_action" == "restore_cron" ]]; then
    choice=0
  else
    vertical_menu "current" 2 0 54 \
      "Открыть и восстановить содержимое" \
      "Расшифровать в обычный архив" \
      "Выйти"
    choice=$?
  fi
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

  if [[ "$identity_was_pasted" -eq 1 ]]; then
    clear
    echo -e "Зашифрованный архив: ${GREEN}${filename}${WHITE}"
    if [[ -n "$companion_encrypted" ]]; then
      echo -e "Найден соседний архив: ${GREEN}$(basename "$companion_encrypted")${WHITE}"
    fi
    echo
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

  echo

  if [[ "$choice" -eq 0 ]]; then
    echo -e "Открываем ${GREEN}${filename}${WHITE} без создания промежуточного расшифрованного архива..."
    if [[ "$requested_action" == "restore_cron" ]]; then
      restore_cron "$encrypted_file" "$identity_file"
    else
      extract "$encrypted_file" "$parent_dir" "$identity_file" "$companion_encrypted"
    fi
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
  if [[ "$filename" == cron_* ]]; then
    options+=("restore_cron::Восстановить CRON")
  fi
  if [[ "$ext" == "tar.gz" ]]; then
    options+=("restore_site::Восстановить сайт из архива $db_guess")
    options+=("restore_folder::Восстановить папку из архива $db_guess")
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
    restore_cron) restore_cron "$file" "$decrypt_identity" ;;
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

# Удалённый вход подготавливает только источник. Проверка, создание сайта,
# распаковка, владелец, импорт БД и настройка CMS выполняются в restore_site.
restore_remote_site() (
  local remote_name="$1" source_user="$2" date_dir="$3" source_site="$4" snapshot_ts="$5"
  local archive_kind="$6" encrypted="$7" has_sql="$8" target_hint="${9:-}"
  local work_root restore_workdir="" restore_keydir="" identity="" identity_type command_name
  local -A remote_restore_source=()
  umask 077
  trap '[[ -z "$restore_workdir" ]] || rm -rf -- "$restore_workdir"; [[ -z "$restore_keydir" ]] || rm -rf -- "$restore_keydir"' EXIT
  trap 'exit 130' INT
  trap 'exit 129' HUP
  trap 'exit 143' TERM
  [[ "$archive_kind" == full ]] || { echo "Выберите копию с файлами сайта, а не отдельный SQL."; return 1; }
  for command_name in rclone tar gzip sha256sum stat df realpath; do
    command -v "$command_name" >/dev/null 2>&1 || { echo "Не найдена команда: $command_name"; return 1; }
  done
  source "${SCRIPT_DIR}/scripts/backup_restore.sh" || return 1
  if [[ -f /root/rish/rish_config.sh ]]; then
    source /root/rish/rish_config.sh
  fi
  server="${server:-backup_server}"
  if [[ "${backup_min_free_mib:-}" =~ ^[0-9]{1,7}$ ]]; then
    RISH_RESTORE_RESERVE_BYTES=$((10#$backup_min_free_mib * 1048576))
  fi
  work_root="${DIR_BACKUP:-/tmp}"
  work_root="$(realpath -e -- "$work_root" 2>/dev/null)" || work_root=/tmp
  [[ -d "$work_root" ]] || work_root=/tmp
  restore_workdir="$(mktemp -d -- "${work_root}/.rish-restore.XXXXXXXXXX")" || return 1
  echo -e "Проверяем список частей ${GREEN}${source_site}_${snapshot_ts}${WHITE}..."
  rish_restore_prepare_snapshot "$remote_name" "$source_user" "$date_dir" "$source_site" \
    "$snapshot_ts" "$archive_kind" "$encrypted" "$has_sql" "$restore_workdir" || return 1
  if [[ "$encrypted" == 1 ]]; then
    backup_crypto_available || { echo "Для расшифрования требуется age."; return 1; }
    restore_keydir="$(mktemp -d /run/rish-age-key.XXXXXX)" || return 1
    select_age_identity "$restore_keydir" || return 1
    identity_type="$AGE_SELECTED_IDENTITY_TYPE"
    identity="${restore_keydir}/unlocked-private-key.txt"
    case "$identity_type" in
      age) unlock_age_identity "$AGE_SELECTED_IDENTITY" "$identity" || return 1 ;;
      ssh) prepare_ssh_identity "$AGE_SELECTED_IDENTITY" "$identity" || return 1 ;;
      *) return 1 ;;
    esac
  fi
  remote_restore_source=(['kind']=remote ['tar']="$RISH_RESTORE_LOGICAL_NAME" ['identity']="$identity"
    ['tar_manifest']="$RISH_RESTORE_TAR_MANIFEST" ['sql_manifest']="$RISH_RESTORE_SQL_MANIFEST"
    ['remote']="$RISH_RESTORE_REMOTE_PATH" ['workdir']="$restore_workdir" ['user']="$source_user" ['root']="$source_site"
    ['target_hint']="$target_hint")
  if [[ -n "$RISH_RESTORE_SQL_MANIFEST" ]]; then
    remote_restore_source['sql']="${source_site}_${snapshot_ts}.sql.gz"
    # shellcheck disable=SC2034
    remote_restore_source['sql_identity']="$identity"
  fi
  restore_site "$RISH_RESTORE_LOGICAL_NAME" "$source_site" "" "$identity" "" remote_restore_source
)

# Если скрипт вызван напрямую — запускаем функцию
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == "--no-dereference" ]]; then
    shift
    if [[ "$#" -ne 2 || -z "$1" || -z "$2" || "$1" == */* || "$1" == . || "$1" == .. ]]; then
      printf 'Использование: %s --no-dereference <имя-папки> <родительский-каталог>\n' "${0##*/}" >&2
      exit 1
    fi
  fi
  if [[ "${1:-}" == --restore-remote ]]; then
    shift
    if [[ "$#" -ne 9 ]]; then
      echo "Некорректные параметры потокового восстановления."
      exit 1
    fi
    restore_remote_site "$@"
    exit $?
  fi
  requested_action=""
  if [[ "${1:-}" == "--restore-cron" ]]; then
    requested_action="restore_cron"
    shift
  fi
  fullpath="$2/$1"

  if [[ "$requested_action" == "restore_cron" ]]; then
    if [[ ! -f "$fullpath" ]]; then
      echo -e "Файл архива ${RED}не найден${WHITE}."
      restore_status=1
    else
      if [[ "$fullpath" == *.age ]]; then
        decrypt_age_archive "$fullpath" "restore_cron"
      else
        restore_cron "$fullpath"
      fi
      restore_status=$?
    fi
    vertical_menu "current" 2 0 5 "Нажмите Enter"
    exit "$restore_status"
  elif [[ -f "$fullpath" ]]; then
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
