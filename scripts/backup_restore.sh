#!/usr/bin/env bash

# Общий источник данных для потокового восстановления удалённых бэкапов.
# При source определяются только функции; настройку и очистку выполняет вызывающий код.

rish_restore_error() {
  if [[ -t 2 && "${TERM:-}" != dumb ]]; then
    printf '\r\033[K' >&2
  fi
  printf 'Потоковое восстановление: %s\n' "$*" >&2
}

rish_restore_valid_component() {
  [[ -n "$1" && "$1" != . && "$1" != .. && "$1" != */* &&
     "$1" != *$'\n'* && "$1" != *$'\r'* && "$1" != *';'* ]]
}

rish_restore_list_parts() {
  local remote_path="$1" output_file="$2"

  if ! rclone lsf --files-only --max-depth 1 --format sp --separator ';' \
    --contimeout 30s --timeout 2m --retries 3 --low-level-retries 3 \
    "$remote_path/" > "$output_file"; then
    rish_restore_error "не удалось получить список частей в ${remote_path}."
    return 1
  fi
}

# Возвращает 2, если частей с таким префиксом нет, и 1 для неполного набора.
rish_restore_build_manifest() {
  local listing_file="$1" archive_name="$2" output_file="$3" require_completion="$4"
  local line size filename suffix expected_name normal_name
  local part_prefix="${archive_name}-part-"
  local end_count=0 suffix_width=2 suffix_number=0
  local -a filenames=() sorted_filenames=() selected_filenames=()
  local -A sizes=() completed_parts=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *';'* ]] || continue
    size="${line%%;*}"
    filename="${line#*;}"
    [[ "$filename" == "$part_prefix"* ]] || continue
    suffix="${filename#"$part_prefix"}"
    if [[ ! "$size" =~ ^[0-9]{1,18}$ || ! "$suffix" =~ ^[0-9]+(\.end)?$ ||
          -n "${sizes[$filename]+x}" ]]; then
      rish_restore_error "некорректная или повторяющаяся часть ${filename}."
      return 1
    fi
    if ((10#$size == 0)); then
      rish_restore_error "часть ${filename} пуста."
      return 1
    fi
    sizes["$filename"]="$((10#$size))"
    filenames+=("$filename")
    if [[ "$filename" == *.end ]]; then
      normal_name="${filename%.end}"
      completed_parts["$normal_name"]=1
      end_count=$((end_count + 1))
    fi
  done < "$listing_file"

  ((${#filenames[@]} > 0)) || return 2
  if ((end_count > 1 || end_count < require_completion)); then
    rish_restore_error "для ${archive_name} не найдена единственная завершающая часть .end."
    return 1
  fi

  mapfile -t sorted_filenames < <(printf '%s\n' "${filenames[@]}" | LC_ALL=C sort -V)
  normal_name="${sorted_filenames[0]:-}"
  if [[ "${normal_name%.end}" == "${part_prefix}001" ]]; then
    suffix_width=3
    suffix_number=1
  fi
  for filename in "${sorted_filenames[@]}"; do
    if [[ "$filename" != *.end && -n "${completed_parts[$filename]+x}" ]]; then
      if [[ "${sizes[$filename]}" != "${sizes["${filename}.end"]}" ]]; then
        rish_restore_error "размеры дублирующей завершающей части ${filename} различаются."
        return 1
      fi
      continue
    fi
    printf -v expected_name '%s%0*d' "$part_prefix" "$suffix_width" "$suffix_number"
    if [[ "${filename%.end}" != "$expected_name" ]]; then
      rish_restore_error "нарушена последовательность частей ${archive_name}: ожидается ${expected_name}."
      return 1
    fi
    selected_filenames+=("$filename")
    suffix_number=$((suffix_number + 1))
  done

  if ((end_count == 1)) && [[ "${selected_filenames[${#selected_filenames[@]} - 1]}" != *.end ]]; then
    rish_restore_error "после завершающей части ${archive_name} найдены дополнительные части."
    return 1
  fi
  : > "$output_file" || return 1
  for filename in "${selected_filenames[@]}"; do
    printf '%s;%s\n' "${sizes[$filename]}" "$filename" >> "$output_file" || return 1
  done
}

rish_restore_prepare_snapshot() {
  local remote_name="$1" user_name="$2" date_dir="$3" site_name="$4" ts_part="$5"
  local archive_kind="$6" encrypted="$7" has_sql="$8" workdir="$9"
  local component age_suffix="" archive_name sql_name listing_file status

  RISH_RESTORE_TAR_MANIFEST=""
  RISH_RESTORE_SQL_MANIFEST=""
  RISH_RESTORE_REMOTE_PATH=""
  RISH_RESTORE_LOGICAL_NAME=""

  for component in "$remote_name" "$user_name" "$date_dir" "$site_name" "$ts_part"; do
    if ! rish_restore_valid_component "$component"; then
      rish_restore_error "некорректный путь или имя выбранной копии."
      return 1
    fi
  done
  if [[ "$remote_name" == *:* || -z "${server:-}" || "$server" == /* ||
        "/$server/" == */../* || "/$server/" == */./* ||
        "$server" == *$'\n'* || "$server" == *$'\r'* ||
        ! -d "$workdir" || ( "$archive_kind" != full && "$archive_kind" != sql ) ||
        ( "$encrypted" != 0 && "$encrypted" != 1 ) ||
        ( "$has_sql" != 0 && "$has_sql" != 1 ) ]]; then
    rish_restore_error "некорректные параметры выбранной копии."
    return 1
  fi
  [[ "$encrypted" == 1 ]] && age_suffix=".age"
  RISH_RESTORE_REMOTE_PATH="${remote_name}:${server}/${user_name}/${date_dir}"
  listing_file="${workdir%/}/remote-parts.list"
  rish_restore_list_parts "$RISH_RESTORE_REMOTE_PATH" "$listing_file" || return 1

  sql_name="${site_name}_${ts_part}.sql.gz${age_suffix}"
  if [[ "$archive_kind" == sql ]]; then
    RISH_RESTORE_SQL_MANIFEST="${workdir%/}/sql.parts"
    if ! rish_restore_build_manifest "$listing_file" "$sql_name" "$RISH_RESTORE_SQL_MANIFEST" 1; then
      rish_restore_error "не удалось подготовить полный набор частей ${sql_name}."
      return 1
    fi
    RISH_RESTORE_LOGICAL_NAME="$sql_name"
    return 0
  fi

  archive_name="${site_name}_${ts_part}.tar.gz${age_suffix}"
  RISH_RESTORE_TAR_MANIFEST="${workdir%/}/tar.parts"
  status=0
  rish_restore_build_manifest "$listing_file" "$archive_name" "$RISH_RESTORE_TAR_MANIFEST" 1 || status=$?
  if ((status == 2)); then
    archive_name="${site_name}.tar.gz${age_suffix}"
    status=0
    rish_restore_build_manifest "$listing_file" "$archive_name" "$RISH_RESTORE_TAR_MANIFEST" 1 || status=$?
  fi
  if ((status != 0)); then
    rish_restore_error "не удалось подготовить полный набор частей ${archive_name}."
    return 1
  fi
  # Публичное имя используется вызывающим меню для сообщения о проверке.
  # shellcheck disable=SC2034
  RISH_RESTORE_LOGICAL_NAME="$archive_name"

  if [[ "$has_sql" == 1 ]]; then
    RISH_RESTORE_SQL_MANIFEST="${workdir%/}/sql.parts"
    # Для копии сайта .end завершает TAR после полностью загруженного SQL.
    if ! rish_restore_build_manifest "$listing_file" "$sql_name" "$RISH_RESTORE_SQL_MANIFEST" 0; then
      rish_restore_error "не удалось подготовить соседний архив базы ${sql_name}."
      return 1
    fi
  fi
}

rish_restore_read_parts() (
  local manifest="$1" remote_path="$2" workdir="$3"
  local reserve_bytes="${RISH_RESTORE_RESERVE_BYTES:-67108864}"
  local line expected_size filename actual_size available checksum expected_checksum
  local part_dir="" part_file hash_pending="" transfer_pid="" status=0 verify_hashes=0
  local part_number=0 part_count=0 progress_log="" progress_title terminal_size progress_columns processing_status=0
  local hash_file="${manifest}.sha256"
  local -A expected_hashes=()
  local -a progress_opts=()

  umask 077
  if [[ ! -s "$manifest" || ! -d "$workdir" || ! "$reserve_bytes" =~ ^[0-9]{1,18}$ ]]; then
    rish_restore_error "недоступен список частей или временный каталог."
    return 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    rish_restore_error "команда sha256sum недоступна."
    return 1
  fi
  reserve_bytes="$((10#$reserve_bytes))"
  if [[ -f "$hash_file" ]]; then
    verify_hashes=1
    while IFS= read -r line; do
      expected_checksum="${line%%;*}"
      filename="${line#*;}"
      if [[ ! "$expected_checksum" =~ ^[0-9a-f]{64}$ || "$line" != *';'* ]]; then
        rish_restore_error "некорректный список контрольных сумм."
        return 1
      fi
      expected_hashes["$filename"]="$expected_checksum"
    done < "$hash_file"
  fi

  cleanup_rish_restore_reader() {
    if [[ -n "$transfer_pid" ]]; then
      kill "$transfer_pid" 2>/dev/null || true
      wait "$transfer_pid" 2>/dev/null || true
    fi
    if ((processing_status)); then
      printf '\r\033[K' >&2 || true
    fi
    if [[ -n "$progress_log" && -s "$progress_log" ]]; then
      printf '\n' >&2 || true
      cat -- "$progress_log" >&2 || true
    fi
    [[ -z "$part_dir" ]] || rm -rf -- "$part_dir"
    [[ -z "$hash_pending" ]] || rm -f -- "$hash_pending"
  }
  trap cleanup_rish_restore_reader EXIT
  trap 'exit 130' INT
  trap 'exit 129' HUP
  trap 'exit 143' TERM
  trap 'exit 141' PIPE
  part_dir="$(mktemp -d -- "${workdir%/}/.rish-restore-part.XXXXXXXX")" || return 1
  part_file="${part_dir}/part"
  if [[ -t 2 && "${TERM:-}" != dumb ]]; then
    progress_log="${part_dir}/rclone.log"
    progress_opts=(--progress --stats-one-line --stats=1s --log-file "$progress_log")
  fi
  if ((verify_hashes == 0)); then
    hash_pending="$(mktemp -- "${hash_file}.pending.XXXXXXXX")" || return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    part_count=$((part_count + 1))
  done < "$manifest"

  while IFS= read -r line || [[ -n "$line" ]]; do
    expected_size="${line%%;*}"
    filename="${line#*;}"
    if [[ "$line" != *';'* || ! "$expected_size" =~ ^[0-9]{1,18}$ ]] ||
      ! rish_restore_valid_component "$filename"; then
      rish_restore_error "некорректная запись в списке частей."
      return 1
    fi
    expected_size="$((10#$expected_size))"
    if ! available="$(LC_ALL=C df -B1 --output=avail -- "$workdir")"; then
      rish_restore_error "не удалось проверить свободное место в ${workdir}."
      return 1
    fi
    available="${available##*$'\n'}"
    available="${available//[[:space:]]/}"
    if [[ ! "$available" =~ ^[0-9]{1,18}$ ]] || ((available < expected_size + reserve_bytes)); then
      rish_restore_error "недостаточно места для части ${filename}: нужно $(((expected_size + reserve_bytes + 1048575) / 1048576)) МиБ с резервом."
      return 1
    fi
    part_number=$((part_number + 1))
    if [[ -n "$progress_log" ]]; then
      processing_status=0
      : > "$progress_log" || return 1
      terminal_size="$(stty size <&2 2>/dev/null)" || terminal_size=""
      progress_columns="${terminal_size##* }"
      if [[ ! "$progress_columns" =~ ^[0-9]+$ ]] || ((progress_columns <= 1)); then
        progress_columns=80
        terminal_size=""
      fi
      printf -v progress_title 'Часть %s из %s: %q (%s МиБ)' \
        "$part_number" "$part_count" "$filename" "$(((expected_size + 1048575) / 1048576))"
      # Оставляем последнюю колонку свободной, чтобы шапка не переносилась.
      printf '\r\033[K%s\n' "${progress_title:0:progress_columns-1}" >&2
    else
      printf 'Загрузка части %s из %s: %s (%s МиБ)...\n' \
        "$part_number" "$part_count" "$filename" "$(((expected_size + 1048575) / 1048576))" >&2
    fi
    rclone copyto --ignore-times --inplace \
      "${progress_opts[@]}" \
      --contimeout 30s --timeout 2m --retries 3 --low-level-retries 3 \
      "${remote_path}/${filename}" "$part_file" </dev/null >&2 &
    transfer_pid=$!
    status=0
    wait "$transfer_pid" || status=$?
    transfer_pid=""
    if [[ -n "$progress_log" ]]; then
      if ((status == 0)) && [[ -n "$terminal_size" && "$terminal_size" == "$(stty size <&2 2>/dev/null)" ]]; then
        # rclone оставляет курсор под строкой статистики. Освобождаем обе строки
        # до распаковки, чтобы затем не затереть сообщения gzip или tar.
        printf '\033[2A\r\033[K\033[1B\r\033[K\033[1A\r' >&2
      fi
      # Логи не участвуют в перерисовке: предупреждения и ошибки остаются видимыми.
      if [[ -s "$progress_log" ]]; then
        cat -- "$progress_log" >&2 || return 1
        : > "$progress_log" || return 1
      fi
    fi
    if ((status != 0)); then
      rish_restore_error "не удалось скачать часть ${filename}."
      return 1
    fi
    if [[ -n "$progress_log" ]]; then
      printf -v progress_title 'Часть %s из %s: обработка…' "$part_number" "$part_count"
      printf '\r\033[K%s\r' "${progress_title:0:progress_columns-1}" >&2
      processing_status=1
    fi
    actual_size="$(wc -c < "$part_file")" || return 1
    actual_size="${actual_size//[[:space:]]/}"
    if [[ "$actual_size" != "$expected_size" ]]; then
      rish_restore_error "размер части ${filename} изменился после проверки списка."
      return 1
    fi
    checksum="$(sha256sum -- "$part_file")" || return 1
    checksum="${checksum%% *}"
    if ((verify_hashes)); then
      if [[ "$checksum" != "${expected_hashes[$filename]:-}" ]]; then
        rish_restore_error "часть ${filename} изменилась после предварительной проверки."
        return 1
      fi
    else
      printf '%s;%s\n' "$checksum" "$filename" >> "$hash_pending" || return 1
    fi
    cat -- "$part_file" || return 1
    rm -f -- "$part_file" || return 1
  done < "$manifest"

  if ((verify_hashes == 0)); then
    mv -f -- "$hash_pending" "$hash_file" || return 1
    hash_pending=""
  fi
)
