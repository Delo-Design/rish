#!/bin/bash
clear

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Ошибка: команда '$cmd' не установлена" >&2
    exit 1
  fi
}

db_exists() {
    local db_name="$1"
    [ -n "$(mariadb -qfsBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${db_name}'" 2>/dev/null)" ]
}

is_site() {
    local site_name="$1"
    compgen -G "/etc/httpd/conf.d/${site_name}*.conf" > /dev/null
}

object_type_for_target() {
    local target_name="$1"
    if is_site "$target_name"; then
        echo "site"
    else
        echo "folder"
    fi
}

is_remote_configured() {
    rclone listremotes 2>/dev/null | grep -q "^${rclone_remote}:$"
}

archive_enabled() {
    local value="$1"
    local normalized

    normalized="${value#"${value%%[![:space:]]*}"}"
    normalized="${normalized%"${normalized##*[![:space:]]}"}"
    normalized="${normalized,,}"

    case "$normalized" in
        yes|y|true|on|archive|да)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Путь к конфигурационному файлу
config_file="/root/rish/rish_config.sh"

# Проверяем существование файла
if [ ! -f "$config_file" ]; then
    echo -e "${LRED}Не найден файл конфигурации:${WHITE} ${config_file}"
    echo
    IFS=$' \t\n'
    vertical_menu "current" 1 0 5 "default=0" "Создать файл конфигурации" "Выйти"
    choice=$?
    case "${choice}" in
      0)
        mkdir -p "$(dirname "$config_file")"
        touch "$config_file"
        echo
        echo -e "Файл конфигурации ${GREEN}создан${WHITE}. Продолжаем настройку."
      ;;
      *)
        exit 0
      ;;
    esac
fi

# Определяем переменные, их значения и комментарии
declare -A vars
vars=(
    ["backupall2"]="#\nbackupall2=/root/rish/backup_list_all"
    ["directory"]="#директория из которой создается бекап (где лежат сайты по каталогам - один каталог - один сайт)\ndirectory=/var/www/*/www"
    ["DIR_BACKUP"]="#временная папка для создания бекапа\nDIR_BACKUP=/root/backup"
    ["keeplast"]="#сколько последних архиваций хранить\nkeeplast=5"
    ["splitarchive"]="#разбивать архив на части по сколько мегабайт\nsplitarchive=500m"
    ["recordsize"]="#размер записей tar\nrecordsize=1m"
    ["checkpoint"]="#через сколько записей вызывать checkpoint\ncheckpoint=10"
    ["server"]="#Директория бекапа сервера в месте архивирования (куда складывать копии).\n#Если на одном диске будут бекапы разных серверов - надо изменить название для каждого\nserver=\"backup_server\""
    ["rclone_remote"]="#имя rclone remote по умолчанию\nrclone_remote=ydisk"
    ["rclone_auth_script"]="#скрипт авторизации rclone (Yandex Disk)\nrclone_auth_script=/root/rish/ydisk_oauth_device_login.sh"
)

# Функция для добавления переменной и комментария, если они отсутствуют
add_var_if_not_exists() {
    local var_name="$1"
    local var_value="$2"
    if ! grep -P "^\s*${var_name}\s*=" "$config_file" > /dev/null 2>&1; then
        echo -e "$var_value" >> "$config_file"
    fi
}

set_config_var() {
    local var_name="$1"
    local var_value="$2"
    local tmp_file

    tmp_file=$(mktemp) || return 1

    awk -v name="$var_name" -v value="$var_value" '
        BEGIN { updated=0 }
        $0 ~ "^[[:space:]]*"name"[[:space:]]*=" {
            print name"="value
            updated=1
            next
        }
        { print }
        END {
            if (!updated) {
                print name"="value
            }
        }
    ' "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
}

# Проверяем каждую переменную
for var in "${!vars[@]}"; do
    add_var_if_not_exists "$var" "${vars[$var]}"
done

source "$config_file"
source /root/rish/windows.sh

require_cmd rclone

if [ -z "${backupall2:-}" ]; then
    backupall2="/root/rish/backup_list_all"
fi


DATE_DIR=$(/bin/date '+%Y.%m.%d')
DATE_TS=$(/bin/date '+%Y-%m-%d_%H-%M')

GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
YELLOW='\033[0;33m'
WHITE='\033[0m'

backupall() {

    if ! [[ -d $DIR_BACKUP ]]; then
        mkdir "$DIR_BACKUP"
    fi

    declare -A CLEANUP_TARGETS
    mapfile -t VALID_REMOTES < <(rclone listremotes 2>/dev/null | sed 's/:$//')

    remote_exists() {
        local remote_name="$1"
        local r
        for r in "${VALID_REMOTES[@]}"; do
            if [ "$r" = "$remote_name" ]; then
                return 0
            fi
        done
        return 1
    }

    while IFS=';' read -r USER TARGET TYPE DB REMOTE ARCHIVE_FLAG EXCLUDE_LIST; do
        if [ -z "$USER" ] || [ -z "$TARGET" ]; then
            continue
        fi
        case "$USER" in
            \#*)
                continue
                ;;
        esac

        if [ -z "$TYPE" ]; then
            TYPE="$(object_type_for_target "$TARGET")"
        fi

        if ! archive_enabled "$ARCHIVE_FLAG"; then
            echo -e "Пропускаем ${YELLOW}${TARGET}${WHITE}: признак архивирования = '${ARCHIVE_FLAG}'"
            continue
        fi

        if [ -z "$REMOTE" ]; then
            REMOTE="$rclone_remote"
        fi
        REMOTE="${REMOTE%%[[:space:]]*}"
        if ! remote_exists "$REMOTE"; then
            echo -e "Подключение ${LRED}'${REMOTE}'${WHITE} не найдено, используем ${YELLOW}'${rclone_remote}'${WHITE}."
            REMOTE="$rclone_remote"
        fi
        if ! remote_exists "$REMOTE"; then
            echo -e "Подключение ${LRED}'${REMOTE}'${WHITE} не найдено в rclone. Пропускаем ${TARGET}."
            continue
        fi

        ARCHIVE_NAME="${TARGET}_${DATE_TS}"
        CLEANUP_TARGETS["$REMOTE|$USER"]=1

        EXCLUDE_OPTS=()
        if [ -n "$EXCLUDE_LIST" ]; then
            IFS=',' read -ra EXCLUDE_DIRS <<< "$EXCLUDE_LIST"
            for dir in "${EXCLUDE_DIRS[@]}"; do
                dir="${dir#"${dir%%[![:space:]]*}"}"
                dir="${dir%"${dir##*[![:space:]]}"}"
                dir="${dir#/}"
                dir="${dir%/}"
                if [ -n "$dir" ]; then
                    # Исключаем содержимое папки, но оставляем саму папку.
                    EXCLUDE_OPTS+=(--exclude="${TARGET}/${dir}/*")
                    EXCLUDE_OPTS+=(--exclude="${TARGET}/${dir}/.*")
                fi
            done
        fi

        mkdir -p "$DIR_BACKUP/$server/$USER/$DATE_DIR/"
        if [ "$TYPE" = "site" ]; then
            echo -e "Архивация сайта ${GREEN}${TARGET}${WHITE}."
        else
            echo -e "Архивация папки ${GREEN}${TARGET}${WHITE}."
        fi
        cd "/var/www/${USER}/www"
        if [ -z "$DB" ]; then
            echo "Идет создание архива файлов..."
            echo "Обработано: 0MB"
            tar -czhf - "${EXCLUDE_OPTS[@]}" $TARGET \
                --record-size=$recordsize --checkpoint=$checkpoint \
                --checkpoint-action=exec='printf "\033[1A\rОбработано: %sMB\033[K\033[1B\r" "$((TAR_CHECKPOINT))" >&2' \
                | split -b $splitarchive --numeric-suffix - \
                $DIR_BACKUP/"${server}/${USER}/${DATE_DIR}/${ARCHIVE_NAME}.tar.gz-part-"
            printf '\033[1A\r\033[K\033[1A\r\033[K'
        else
            echo -e "Создаем дамп базы ${GREEN}${DB}${WHITE}..."
            mariadb-dump "$DB" > $DB.sql
            sed -i '1{/999999.*sandbox/d}' $DB.sql
            echo "Идет создание архива файлов..."
            echo "Обработано: 0MB"
            tar -czhf - "${EXCLUDE_OPTS[@]}" $TARGET $DB.sql \
                --record-size=$recordsize --checkpoint=$checkpoint \
                --checkpoint-action=exec='printf "\033[1A\rОбработано: %sMB\033[K\033[1B\r" "$((TAR_CHECKPOINT))" >&2' \
                | split -b $splitarchive --numeric-suffix - \
                $DIR_BACKUP/"${server}/${USER}/${DATE_DIR}/${ARCHIVE_NAME}.tar.gz-part-"
            printf '\033[1A\r\033[K\033[1A\r\033[K\033[1A\r\033[K'
            rm ./$DB.sql
        fi
        if rclone copy --progress --stats-one-line --stats=1s "$DIR_BACKUP/" "${REMOTE}:"; then
            # Финальная строка rclone остается выше текущей позиции: очищаем строку выше.
            printf '\033[1A\r\033[K'
            rm -rf "$DIR_BACKUP"/*
        else
            printf '\033[1A\r\033[K'
            echo -e "${LRED}Ошибка передачи в подключение '${REMOTE}'. Временные файлы сохранены в ${DIR_BACKUP}.${WHITE}"
        fi
    done < "$backupall2"

    for key in "${!CLEANUP_TARGETS[@]}"; do
        REMOTE="${key%%|*}"
        USER="${key##*|}"
        if [ -z "$REMOTE" ] || [ -z "$USER" ]; then
            continue
        fi
        echo "Очистка старых архивов для $USER на ${REMOTE}:"
        mapfile -t REMOTE_DIRS < <(rclone lsf --dirs-only "${REMOTE}:${server}/${USER}/" 2>/dev/null | sed 's:/$::' | sort)
        if [ "${#REMOTE_DIRS[@]}" -le "$keeplast" ]; then
            continue
        fi
        REMOVE_COUNT=$((${#REMOTE_DIRS[@]} - keeplast))
        for ((i=0; i<REMOVE_COUNT; i++)); do
            OLD_DIR="${REMOTE_DIRS[$i]}"
            if [ -n "$OLD_DIR" ]; then
                rclone purge "${REMOTE}:${server}/${USER}/${OLD_DIR}"
            fi
        done
    done
}

createlist() {
	echo
	echo "Создаем список объектов для архивации."
	echo

	if [ -f "$backupall2" ]; then
		echo -e "${YELLOW}Внимание:${WHITE} файл списка уже существует: ${YELLOW}${backupall2}${WHITE}"
		echo "Перезапись удалит текущие настройки объектов (включая type/archive/exclude)."
		echo
		vertical_menu "current" 1 0 5 "default=1" "Стереть старый файл и создать заново" "Отмена"
		choice=$?
		case "${choice}" in
		  0)
		    ;;
		  255)
		    echo "Операция отменена (Esc)."
		    return 1
		  ;;
		  *)
		    echo "Операция отменена."
		    return 1
		  ;;
		esac
	fi

	echo -n "" > "$backupall2"
	echo "# format: user;name;type(site|folder);db;remote;archive(yes|no);exclude_list" >> "$backupall2"
    let ii=0
    maxlen=0
    shopt -s nullglob

	for file in $directory/*
	do
		if [ -d "$file" ]
		then
			r="${file##*/}"
			if [[ "$r" == "000-default" ]]; then
			   continue
			fi
			len=${#r}
			if (( len > maxlen ))
			then
				maxlen=$len
			fi
		fi
	done

	for file in $directory/*
	do
		if [ -d "$file" ]
		then
			r="${file##*/}"
			if [[ "$r" == "000-default" ]]
			then
			   continue
			fi

			TYPE="$(object_type_for_target "$r")"
			db=""
			if [ "$TYPE" = "site" ] && db_exists "$r"; then
				db="$r"
			fi

			let ii=$ii+1
			printf "%3s. " $ii
			if [ "$TYPE" = "site" ]; then
				if [ -n "$db" ]; then
					db_output="Сайт, база данных $db"
				else
					db_output="Сайт, база: ----"
				fi
			else
				db_output="Папка"
			fi
			printf "${GREEN}%-${maxlen}s${WHITE} %-35s\n" "$r" "$db_output"

			currentuser=$(basename $(dirname $(dirname "$file")))
			echo "${currentuser};${r};${TYPE};${db};${rclone_remote};yes;" >> "$backupall2"
		fi
	done
    shopt -u nullglob
	echo
}

updatelist() {
    local tmp_list
    local removed=0
    local added=0
    local kept=0
    local line_no=0

    echo
    echo "Обновляем список объектов для архивации."
    echo

    if [ ! -f "$backupall2" ]; then
        echo -e "${LRED}Файл списка не найден:${WHITE} ${backupall2}"
        echo "Сначала создайте файл-список."
        return 1
    fi

    tmp_list=$(mktemp)
    declare -A EXISTING_TARGETS
    shopt -s nullglob

    while IFS=';' read -r USER TARGET TYPE DB REMOTE ARCHIVE_FLAG EXCLUDE_LIST; do
        local kind_label
        line_no=$((line_no + 1))
        if [ -z "$USER" ] || [ -z "$TARGET" ]; then
            continue
        fi
        case "$USER" in
            \#*)
                continue
                ;;
        esac

        if [ -z "$TYPE" ]; then
            TYPE="$(object_type_for_target "$TARGET")"
        fi
        if [ "$TYPE" = "site" ]; then
            kind_label="сайт"
        else
            kind_label="папка"
        fi

        if [ ! -d "/var/www/${USER}/www/${TARGET}" ]; then
            echo -e "${YELLOW}Удаляем строку ${line_no}:${WHITE} ${kind_label} ${LRED}${TARGET}${WHITE} (${USER}) не найден."
            removed=$((removed + 1))
            continue
        fi

        old_type="$TYPE"
        if [ -z "$old_type" ]; then
            old_type="unknown"
        fi

        TYPE="$(object_type_for_target "$TARGET")"
        if [ "$old_type" != "$TYPE" ] && [ "$old_type" != "unknown" ]; then
            echo -e "Изменен тип: ${GREEN}${TARGET}${WHITE} (${USER}) ${YELLOW}${old_type}${WHITE} -> ${GREEN}${TYPE}${WHITE}"
        fi

        if [ "$TYPE" = "site" ]; then
            if [ -z "$DB" ]; then
                if db_exists "$TARGET"; then
                    DB="$TARGET"
                fi
            elif ! db_exists "$DB"; then
                DB=""
            fi
        else
            DB=""
        fi

        # Для существующих строк не меняем подключение, если оно уже задано.
        # Подставляем дефолт только для пустого поля.
        if [ -z "$REMOTE" ]; then
            REMOTE="$rclone_remote"
        fi
        if [ -z "$ARCHIVE_FLAG" ]; then
            ARCHIVE_FLAG="yes"
        fi

        echo "${USER};${TARGET};${TYPE};${DB};${REMOTE};${ARCHIVE_FLAG};${EXCLUDE_LIST}" >> "$tmp_list"
        EXISTING_TARGETS["${USER}|${TARGET}"]=1
        kept=$((kept + 1))
    done < "$backupall2"

    for file in $directory/*
    do
        if [ ! -d "$file" ]; then
            continue
        fi

        r="${file##*/}"
        if [[ "$r" == "000-default" ]]; then
            continue
        fi

        currentuser=$(basename $(dirname $(dirname "$file")))
        key="${currentuser}|${r}"
        if [ -n "${EXISTING_TARGETS[$key]}" ]; then
            continue
        fi

        TYPE="$(object_type_for_target "$r")"
        db=""
        if [ "$TYPE" = "site" ] && db_exists "$r"; then
            db="$r"
        fi

        echo "${currentuser};${r};${TYPE};${db};${rclone_remote};yes;" >> "$tmp_list"
        EXISTING_TARGETS["$key"]=1
        added=$((added + 1))
        if [ "$TYPE" = "site" ]; then
            echo -e "Добавлен сайт: ${GREEN}${r}${WHITE} (${currentuser})"
        else
            echo -e "Добавлена папка: ${GREEN}${r}${WHITE} (${currentuser})"
        fi
    done
    shopt -u nullglob

    {
        echo "# format: user;name;type(site|folder);db;remote;archive(yes|no);exclude_list"
        cat "$tmp_list"
    } > "$backupall2"
    rm -f "$tmp_list"

    echo
    echo "Обновление завершено."
    echo "Оставлено: $kept"
    echo "Удалено: $removed"
    echo "Добавлено: $added"
    echo
}

if [[ "$1" == "auto" ]]
then
    if ! is_remote_configured; then
        echo -e "Автоматическая архивация пропущена: подключение ${LRED}'${rclone_remote}'${WHITE} не настроено."
        exit 1
    fi
   	echo "Автоматическая архивация"
	backupall
   	exit 0
fi

configcnf() {
   echo "Конфигурируем rclone (Yandex Disk)"
   echo
   if [ ! -f "$rclone_auth_script" ]; then
       echo "Ошибка: не найден скрипт авторизации: $rclone_auth_script"
       exit 1
   fi
   bash "$rclone_auth_script" "$rclone_remote"
}

remote_info() {
    local selected_remote="$rclone_remote"

    echo
    echo -e "Информация о подключении"
    echo -e "Подключение по умолчанию: ${GREEN}${selected_remote}${WHITE}"
    echo -e "Папка бэкапов: ${GREEN}${server}${WHITE}"
    echo

    if ! rclone listremotes 2>/dev/null | grep -q "^${selected_remote}:$"; then
        echo -e "${LRED}Подключение '${selected_remote}' не найдено в rclone.${WHITE}"
        echo
        return 1
    fi

    echo "Общая информация о хранилище:"
    if ! rclone about "${selected_remote}:"; then
        echo -e "${YELLOW}Команда 'rclone about' недоступна для этого типа подключения.${WHITE}"
    fi
    echo
    echo "Размер папки бэкапов:"
    if ! rclone size "${selected_remote}:${server}"; then
        echo -e "${YELLOW}Не удалось получить размер папки ${server}.${WHITE}"
    fi
    echo
}

select_default_remote() {
    local choice selected_remote exit_index
    local -a remotes menu_items

    while true; do
        menu_items=("Создать/Удалить новое подключение rclone")
        mapfile -t remotes < <(rclone listremotes 2>/dev/null | sed 's/:$//')

        echo
        if is_remote_configured; then
            echo -e "Текущее подключение по умолчанию: ${GREEN}${rclone_remote}${WHITE}"
        else
            echo -e "Текущее подключение по умолчанию: ${LRED}${rclone_remote}${WHITE} (не найдено в rclone)"
        fi

        if [ "${#remotes[@]}" -gt 0 ]; then
            for selected_remote in "${remotes[@]}"; do
                menu_items+=("Выбрать ${selected_remote} подключением по умолчанию")
            done
        fi
        menu_items+=("Выйти")
        exit_index=$(( ${#menu_items[@]} - 1 ))

        vertical_menu "current" 1 0 5 "default=0" "${menu_items[@]}"
        choice=$?

        case "$choice" in
            255)
                return 0
                ;;
            0)
                echo "Запуск интерактивной конфигурации rclone..."
                rclone config
                ;;
            *)
                if [ "$choice" -eq "$exit_index" ]; then
                    return 0
                fi
                selected_remote="${remotes[$((choice - 1))]}"
                if [ -z "$selected_remote" ]; then
                    echo -e "${LRED}Некорректный выбор.${WHITE}"
                    continue
                fi
                if ! set_config_var "rclone_remote" "$selected_remote"; then
                    echo -e "${LRED}Не удалось обновить ${config_file}.${WHITE}"
                    continue
                fi
                rclone_remote="$selected_remote"
                ;;
        esac
    done
}

clear_last_vertical_menu() {
    local row
    local y="$VERTICAL_MENU_LAST_Y"
    local x="$VERTICAL_MENU_LAST_X"
    local h="$VERTICAL_MENU_LAST_HEIGHT"
    local w="$VERTICAL_MENU_LAST_OUTER_WIDTH"

    if [ -z "$y" ] || [ -z "$x" ] || [ -z "$h" ] || [ -z "$w" ]; then
        return 0
    fi

    for ((row=0; row<h; row++)); do
        cursor_to "$((y + row))" "$x"
        printf "%*s" "$w" ""
    done
}

clear_menu_rect() {
    local y="$1"
    local x="$2"
    local h="$3"
    local w="$4"
    local row

    if [ -z "$y" ] || [ -z "$x" ] || [ -z "$h" ] || [ -z "$w" ]; then
        return 0
    fi

    for ((row=0; row<h; row++)); do
        cursor_to "$((y + row))" "$x"
        printf "%*s" "$w" ""
    done
}

declare -A RESTORE_SITE_OWNER
declare -A CACHE_READY
declare -A CACHE_SITES
declare -A CACHE_SITE_OWNER
declare -A CACHE_SITE_SNAPSHOTS
declare -A CACHE_SNAPSHOT_META

progress_line_stderr() {
    local row="$1"
    local col="$2"
    local text="$3"
    printf '%s' "${ESC}[${row};${col}H" >&2
    printf '%s' "$text" >&2
    printf '%s' "${ESC}[K" >&2
}

ensure_remote_index() {
    local remote_name="$1"
    local status_row="${2:-}"
    local status_col="${3:-1}"
    local rel_path user_name rest_path date_dir file_name archive_base site_name
    local ts_part date_part time_part label pair_key
    local processed_files=0 total_files=0
    local -a file_entries sorted_sites labels_for_site
    local -A seen_users seen_user_dates seen_sites site_user seen_site_labels snapshot_meta

    if [ "${CACHE_READY[$remote_name]:-0}" = "1" ]; then
        return 0
    fi

    mapfile -t file_entries < <(
        rclone lsf -R --files-only --include "*.tar.gz-part-00" --fast-list "${remote_name}:${server}/" 2>/dev/null
    )
    total_files="${#file_entries[@]}"
    if [ -n "$status_row" ]; then
        progress_line_stderr "$status_row" "$status_col" "Сканирование ${remote_name}: файлов 0/${total_files}, пользователей 0, дат 0, найдено сайтов 0"
    fi

    for rel_path in "${file_entries[@]}"; do
        [ -z "$rel_path" ] && continue
        processed_files=$((processed_files + 1))

        user_name="${rel_path%%/*}"
        [ -z "$user_name" ] && continue
        rest_path="${rel_path#*/}"
        [ "$rest_path" = "$rel_path" ] && continue

        date_dir="${rest_path%%/*}"
        [ -z "$date_dir" ] && continue
        file_name="${rest_path#*/}"
        [ "$file_name" = "$rest_path" ] && continue
        [ -z "$file_name" ] && continue

        seen_users["$user_name"]=1
        seen_user_dates["$user_name|$date_dir"]=1
        if [ -n "$status_row" ] && (( processed_files == 1 || processed_files % 200 == 0 || processed_files == total_files )); then
            progress_line_stderr "$status_row" "$status_col" "Сканирование ${remote_name}: файлов ${processed_files}/${total_files}, пользователей ${#seen_users[@]}, дат ${#seen_user_dates[@]}, найдено сайтов ${#seen_sites[@]}"
        fi

        archive_base="${file_name%.tar.gz-part-00}"
        if [[ "$archive_base" =~ ^(.+)_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2})$ ]]; then
            site_name="${BASH_REMATCH[1]}"
            ts_part="${BASH_REMATCH[2]}"
            seen_sites["$site_name"]=1
            if [ -z "${site_user[$site_name]:-}" ]; then
                site_user["$site_name"]="$user_name"
            fi

            date_part="${ts_part%%_*}"
            time_part="${ts_part##*_}"
            label="${date_part} ${time_part//-/:}"
            pair_key="${site_name}|${label}"
            if [ -z "${seen_site_labels[$pair_key]:-}" ]; then
                seen_site_labels["$pair_key"]=1
                snapshot_meta["$pair_key"]="${user_name};${date_dir};${site_name};${ts_part}"
            fi
        elif [[ -n "$archive_base" ]]; then
            site_name="$archive_base"
            seen_sites["$site_name"]=1
            if [ -z "${site_user[$site_name]:-}" ]; then
                site_user["$site_name"]="$user_name"
            fi

            date_part="$date_dir"
            if [[ "$date_part" =~ ^([0-9]{4})\.([0-9]{2})\.([0-9]{2})$ ]]; then
                date_part="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
            fi
            ts_part="${date_part}_00-00"
            label="${date_part} 00:00"
            pair_key="${site_name}|${label}"
            if [ -z "${seen_site_labels[$pair_key]:-}" ]; then
                seen_site_labels["$pair_key"]=1
                snapshot_meta["$pair_key"]="${user_name};${date_dir};${site_name};${ts_part}"
            fi
        fi
    done
    if [ -n "$status_row" ]; then
        progress_line_stderr "$status_row" "$status_col" "Сканирование ${remote_name} завершено: файлов ${processed_files}/${total_files}, пользователей ${#seen_users[@]}, дат ${#seen_user_dates[@]}, найдено сайтов ${#seen_sites[@]}"
    fi

    CACHE_SITES["$remote_name"]=""
    if [ "${#seen_sites[@]}" -eq 0 ]; then
        CACHE_READY["$remote_name"]=1
        return 0
    fi

    mapfile -t sorted_sites < <(printf '%s\n' "${!seen_sites[@]}" | LC_ALL=C sort)
    CACHE_SITES["$remote_name"]="$(printf '%s\n' "${sorted_sites[@]}")"

    for site_name in "${sorted_sites[@]}"; do
        CACHE_SITE_OWNER["$remote_name|$site_name"]="${site_user[$site_name]}"
        mapfile -t labels_for_site < <(
            for pair_key in "${!seen_site_labels[@]}"; do
                if [[ "$pair_key" == "${site_name}|"* ]]; then
                    printf '%s\n' "${pair_key#*|}"
                fi
            done | sort -r
        )
        if [ "${#labels_for_site[@]}" -gt 0 ]; then
            CACHE_SITE_SNAPSHOTS["$remote_name|$site_name"]="$(printf '%s\n' "${labels_for_site[@]}")"
            for label in "${labels_for_site[@]}"; do
                pair_key="${site_name}|${label}"
                CACHE_SNAPSHOT_META["$remote_name|$site_name|$label"]="${snapshot_meta[$pair_key]}"
            done
        else
            CACHE_SITE_SNAPSHOTS["$remote_name|$site_name"]=""
        fi
    done

    CACHE_READY["$remote_name"]=1
}

collect_sites_for_remote() {
    local remote_name="$1"
    local site_name
    local sites_blob
    sites_blob="${CACHE_SITES[$remote_name]:-}"
    if [ -z "$sites_blob" ]; then
        return 0
    fi

    while IFS= read -r site_name; do
        [ -z "$site_name" ] && continue
        printf '%s|%s\n' "$site_name" "${CACHE_SITE_OWNER["$remote_name|$site_name"]}"
    done <<< "$sites_blob"
}

collect_snapshots_for_site() {
    local remote_name="$1"
    local site_name="$2"
    local _user_name="$3"
    local key prefix label
    local -A seen_labels

    prefix="${remote_name}|${site_name}|"
    for key in "${!CACHE_SNAPSHOT_META[@]}"; do
        if [[ "$key" == "${prefix}"* ]]; then
            label="${key#${prefix}}"
            [ -n "$label" ] && seen_labels["$label"]=1
        fi
    done

    if [ "${#seen_labels[@]}" -eq 0 ]; then
        return 0
    fi

    while IFS= read -r label; do
        [ -z "$label" ] && continue
        printf '%s|%s\n' "$label" "${CACHE_SNAPSHOT_META["$remote_name|$site_name|$label"]}"
    done < <(printf '%s\n' "${!seen_labels[@]}" | sort -r)
}

download_site_snapshot_archive() {
    local remote_name="$1"
    local user_name="$2"
    local date_dir="$3"
    local site_name="$4"
    local ts_part="$5"
    local status_row="$6"
    local tmp_dir archive_path target_dir target_archive
    local -a part_files

    tmp_dir="$(mktemp -d)" || return 1
    target_dir="$(pwd)"
    target_archive="${target_dir}/${site_name}_${ts_part}.tar.gz"
    archive_path="${tmp_dir}/${site_name}_${ts_part}.tar.gz"

    cursor_to "$status_row" 1
    printf '\033[K'
    echo -e "Загрузка архива в ${GREEN}${target_archive}${WHITE}"

    if ! rclone copy --progress --stats-one-line --stats=1s \
        "${remote_name}:${server}/${user_name}/${date_dir}/" "$tmp_dir/" \
        --include "${site_name}_${ts_part}.tar.gz-part-*" \
        --include "${site_name}.tar.gz-part-*"; then
        printf '\033[1A\r\033[K'
        cursor_to "$status_row" 1
        printf '\033[K'
        echo -e "${LRED}Не удалось скачать архив из удаленного хранилища.${WHITE}"
        rm -rf "$tmp_dir"
        return 1
    fi
    printf '\033[1A\r\033[K'

    mapfile -t part_files < <(ls -1 "${tmp_dir}/${site_name}_${ts_part}.tar.gz-part-"* 2>/dev/null | sort)
    if [ "${#part_files[@]}" -eq 0 ]; then
        mapfile -t part_files < <(ls -1 "${tmp_dir}/${site_name}.tar.gz-part-"* 2>/dev/null | sort)
    fi
    if [ "${#part_files[@]}" -eq 0 ]; then
        cursor_to "$status_row" 1
        printf '\033[K'
        echo -e "${LRED}Части архива не найдены после скачивания.${WHITE}"
        rm -rf "$tmp_dir"
        return 1
    fi

    cat "${part_files[@]}" > "$archive_path"
    mv -f "$archive_path" "$target_archive"

    rm -rf "$tmp_dir"
    cursor_to "$status_row" 1
    printf '\033[K'
    echo -e "Архив ${GREEN}${site_name}_${ts_part}.tar.gz${WHITE} загружен в ${GREEN}${target_dir}${WHITE}"
    return 0
}

restore_backup_menu() {
    local menu_start_row status_header_row remote_choice remote_exit_index
    local selected_remote selected_site selected_snapshot site_owner
    local site_line
    local site_name_from_line site_user_from_line
    local snapshot_line snapshot_label snapshot_meta_line
    local right_x right_y snapshot_x snapshot_y
    local snapshot_meta snapshot_user snapshot_date snapshot_site snapshot_ts status_row
    local remote_menu_y remote_menu_h snapshot_menu_y snapshot_menu_h
    local site_menu_y site_menu_x site_menu_h site_menu_w site_menu_drawn
    local -a remotes remote_menu site_entries sites site_menu snapshot_entries snapshots snapshot_menu
    local -A snapshot_map

    echo
    echo -e "Загрузка будет выполнена в текущую директорию: ${GREEN}$(pwd)${WHITE}"
    menu_start_row=$(get_cursor_row)
    status_header_row=$((menu_start_row - 2))
    if [ "$status_header_row" -lt 1 ]; then
        status_header_row=1
    fi

    while true; do
        mapfile -t remotes < <(rclone listremotes 2>/dev/null | sed 's/:$//' | sort)
        if [ "${#remotes[@]}" -eq 0 ]; then
            echo -e "${LRED}Нет доступных подключений rclone.${WHITE}"
            return 1
        fi

        remote_menu=()
        for selected_remote in "${remotes[@]}"; do
            remote_menu+=("$selected_remote")
        done
        remote_menu+=("Выход")
        remote_exit_index=$(( ${#remote_menu[@]} - 1 ))

        cursor_to "$menu_start_row" 1
        vertical_menu "$menu_start_row" 1 12 5 "default=0" "${remote_menu[@]}"
        remote_choice=$?
        remote_menu_y="$VERTICAL_MENU_LAST_Y"
        remote_menu_h="$VERTICAL_MENU_LAST_HEIGHT"

        if [ "$remote_choice" -eq 255 ] || [ "$remote_choice" -eq "$remote_exit_index" ]; then
            clear_last_vertical_menu
            cursor_to "$menu_start_row" 1
            return 0
        fi

        selected_remote="${remotes[$remote_choice]}"
        right_x="$(vertical_menu_next_x 2)"
        right_y="$VERTICAL_MENU_LAST_Y"
        site_menu_drawn=0

        while true; do
            status_row=$((remote_menu_y + remote_menu_h + 1))

            if [ "$site_menu_drawn" -eq 1 ]; then
                clear_menu_rect "$site_menu_y" "$site_menu_x" "$site_menu_h" "$site_menu_w"
                site_menu_drawn=0
            fi

            if [ "${CACHE_READY[$selected_remote]:-0}" != "1" ]; then
                cursor_to "$status_row" 1
                printf '\033[K'
                echo -e "${YELLOW}Подготовка списка сайтов для ${selected_remote}...${WHITE}"
                cursor_blink_off
                ensure_remote_index "$selected_remote" "$status_row" "1"
                cursor_blink_on
            fi
            cursor_to "$status_row" 1
            printf '\033[K'
            mapfile -t site_entries < <(collect_sites_for_remote "$selected_remote")

            RESTORE_SITE_OWNER=()
            sites=()
            for site_line in "${site_entries[@]}"; do
                [ -z "$site_line" ] && continue
                site_name_from_line="${site_line%%|*}"
                site_user_from_line="${site_line#*|}"
                [ -z "$site_name_from_line" ] && continue
                sites+=("$site_name_from_line")
                if [ -n "$site_user_from_line" ] && [ -z "${RESTORE_SITE_OWNER[$site_name_from_line]:-}" ]; then
                    RESTORE_SITE_OWNER["$site_name_from_line"]="$site_user_from_line"
                fi
            done

            cursor_to "$status_row" 1
            printf '\033[K'

            if [ "${#sites[@]}" -eq 0 ]; then
                cursor_to "$status_row" 1
                echo -e "${YELLOW}На ${selected_remote} нет архивов.${WHITE}"
                sleep 1
                cursor_to "$status_row" 1
                printf '\033[K'
                break
            fi

            site_menu=()
            for selected_site in "${sites[@]}"; do
                site_menu+=("$selected_site")
            done
            site_menu+=("Выход")

            vertical_menu "$right_y" "$right_x" 20 5 "default=0" "${site_menu[@]}"
            remote_choice=$?
            site_menu_y="$VERTICAL_MENU_LAST_Y"
            site_menu_x="$VERTICAL_MENU_LAST_X"
            site_menu_h="$VERTICAL_MENU_LAST_HEIGHT"
            site_menu_w="$VERTICAL_MENU_LAST_OUTER_WIDTH"
            site_menu_drawn=1
            if [ "$remote_choice" -eq 255 ] || [ "$remote_choice" -eq "${#sites[@]}" ]; then
                clear_last_vertical_menu
                site_menu_drawn=0
                break
            fi

            selected_site="${sites[$remote_choice]}"
            site_owner="${RESTORE_SITE_OWNER[$selected_site]}"
            status_row=$((site_menu_y + site_menu_h + 1))
            if [ -z "$site_owner" ]; then
                cursor_to "$status_row" 1
                echo -e "${LRED}Не удалось определить пользователя для сайта ${selected_site}.${WHITE}"
                continue
            fi

            cursor_to "$status_row" 1
            printf '\033[K'
            mapfile -t snapshot_entries < <(collect_snapshots_for_site "$selected_remote" "$selected_site" "$site_owner")
            snapshots=()
            snapshot_map=()
            for snapshot_line in "${snapshot_entries[@]}"; do
                [ -z "$snapshot_line" ] && continue
                snapshot_label="${snapshot_line%%|*}"
                snapshot_meta_line="${snapshot_line#*|}"
                [ -z "$snapshot_label" ] && continue
                snapshots+=("$snapshot_label")
                snapshot_map["$snapshot_label"]="$snapshot_meta_line"
            done

            if [ "${#snapshots[@]}" -eq 0 ]; then
                echo -e "${YELLOW}Для сайта ${selected_site} не найдено доступных дат.${WHITE}"
                continue
            fi

            snapshot_menu=()
            for selected_snapshot in "${snapshots[@]}"; do
                snapshot_menu+=("$selected_snapshot")
            done
            snapshot_menu+=("Назад")

            snapshot_x="$(vertical_menu_next_x 2)"
            snapshot_y="$VERTICAL_MENU_LAST_Y"
            vertical_menu "$snapshot_y" "$snapshot_x" 20 5 "default=0" "${snapshot_menu[@]}"
            remote_choice=$?
            snapshot_menu_y="$VERTICAL_MENU_LAST_Y"
            snapshot_menu_h="$VERTICAL_MENU_LAST_HEIGHT"
            status_row=$((snapshot_menu_y + snapshot_menu_h + 1))
            clear_last_vertical_menu

            if [ "$remote_choice" -eq 255 ] || [ "$remote_choice" -eq "${#snapshots[@]}" ]; then
                continue
            fi

            selected_snapshot="${snapshots[$remote_choice]}"
            snapshot_meta="${snapshot_map[$selected_snapshot]}"
            IFS=';' read -r snapshot_user snapshot_date snapshot_site snapshot_ts <<< "$snapshot_meta"
            if [ -z "$snapshot_user" ] || [ -z "$snapshot_date" ] || [ -z "$snapshot_site" ] || [ -z "$snapshot_ts" ]; then
                cursor_to "$status_row" 1
                echo -e "${LRED}Не удалось разобрать выбранную копию.${WHITE}"
                continue
            fi

            if [ "$site_menu_drawn" -eq 1 ]; then
                clear_menu_rect "$site_menu_y" "$site_menu_x" "$site_menu_h" "$site_menu_w"
                site_menu_drawn=0
            fi

            download_site_snapshot_archive "$selected_remote" "$snapshot_user" "$snapshot_date" "$snapshot_site" "$snapshot_ts" "$status_header_row"
        done

        cursor_to "$menu_start_row" 1
    done
}

echo "Скрипт автоматического архивирования объектов сервера"
echo


if is_remote_configured
then
    echo
    echo -e "Конфигурационный файл настроен ${GREEN}корректно${WHITE}"
    echo -e "Подключение: ${GREEN}${rclone_remote}${WHITE}"
    echo -e "Папка бэкапов: ${GREEN}${server}${WHITE}"
else
    echo -e "Подключение не настроено (подключение ${LRED}'${rclone_remote}'${WHITE} не найдено в rclone)."
fi

if [ ! -f $backupall2 ]
then
	echo
	echo -e "${LRED}Файл списка архивируемых объектов не найден:${WHITE} ${backupall2}"
	echo "Создайте его через пункт меню."
	echo
else
	echo -e "Список объектов для архивации ${GREEN}найден${WHITE} (${backupall2})"
fi
minute=$(shuf -i 0-59 -n 1)
minute=$(printf "%2d" $minute)
echo
echo "┌────────────────────────────────────────────────────────────────┐"
echo "│ Для вызова скрипта в режиме CRON нужно добавить параметр auto. │"
echo "│ Настроить архивацию можно по команде crontab -e                │"
echo "│ $minute 4 * * * /root/rish/backup2.sh auto >/dev/null 2>&1          │"
echo "└────────────────────────────────────────────────────────────────┘"
echo
echo
while true
do
    local_has_list=0
    local_remote_ready=0
    IFS=$' \t\n'

    if [ -f "$backupall2" ]; then
        local_has_list=1
    fi
    if is_remote_configured; then
        local_remote_ready=1
    fi

    if [ "$local_has_list" -eq 0 ]; then
        vertical_menu "current" 1 0 5 "default=0" "Создать файл-список всех архивируемых объектов" "Создать/Обновить подключение яндекс-диска" "Создать/Выбрать подключение по умолчанию" "Выйти"
    elif [ "$local_remote_ready" -eq 1 ]; then
        vertical_menu "current" 2 0 5 "default=7" "Архивация всех сайтов сервера" "Скачать копию из бекапа на сервер" "Обновить файл-список всех архивируемых объектов" "Создать файл-список всех архивируемых объектов" "Создать/Обновить подключение яндекс-диска" "Создать/Выбрать подключение по умолчанию" "О подключении по умолчанию ${rclone_remote}" "Выйти"
    else
        vertical_menu "current" 2 0 5 "default=4" "Обновить файл-список всех архивируемых объектов" "Создать файл-список всех архивируемых объектов" "Создать/Обновить подключение яндекс-диска" "Создать/Выбрать подключение по умолчанию" "Выйти"
    fi
    choice=$?
    case "${choice}" in
      0)
      if [ "$local_has_list" -eq 0 ]; then
        createlist
      elif [ "$local_remote_ready" -eq 1 ]; then
        backupall
      else
        updatelist
      fi
      ;;
      1)
      if [ "$local_has_list" -eq 0 ]; then
        configcnf
      elif [ "$local_remote_ready" -eq 1 ]; then
        restore_backup_menu
      else
        createlist
      fi
      ;;
      2)
      if [ "$local_has_list" -eq 0 ]; then
        select_default_remote
      elif [ "$local_remote_ready" -eq 1 ]; then
        updatelist
      else
        configcnf
        echo
        if is_remote_configured
        then
              echo
              echo -e "Конфигурационный файл настроен ${GREEN}корректно${WHITE}"
              echo -e "Подключение: ${GREEN}${rclone_remote}${WHITE}"
        else
              echo -e "Подключение не настроено (подключение ${LRED}'${rclone_remote}'${WHITE} не найдено в rclone)."
        fi
      fi
      ;;
      3)
      if [ "$local_has_list" -eq 0 ]; then
        break
      elif [ "$local_remote_ready" -eq 1 ]; then
        createlist
        echo
      else
        select_default_remote
      fi
      ;;
      4)
      if [ "$local_has_list" -eq 0 ]; then
        break
      elif [ "$local_remote_ready" -eq 1 ]; then
        configcnf
        echo
        if is_remote_configured
        then
              echo
              echo -e "Конфигурационный файл настроен ${GREEN}корректно${WHITE}"
              echo -e "Подключение: ${GREEN}${rclone_remote}${WHITE}"
        else
              echo -e "Подключение не настроено (подключение ${LRED}'${rclone_remote}'${WHITE} не найдено в rclone)."
        fi
      else
        break
      fi
      ;;
      5)
      if [ "$local_has_list" -eq 0 ]; then
        break
      elif [ "$local_remote_ready" -eq 1 ]; then
        select_default_remote
      else
        break
      fi
      ;;
      6)
      if [ "$local_has_list" -eq 0 ]; then
        break
      elif [ "$local_remote_ready" -eq 1 ]; then
        remote_info
      else
        break
      fi
      ;;
      *)
        break
      ;;
    esac
done
