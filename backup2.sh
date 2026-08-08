#!/bin/bash
clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
if [[ -f /root/rish/scripts/backup_crypto.sh ]]; then
    source /root/rish/scripts/backup_crypto.sh
else
    source "${SCRIPT_DIR}/scripts/backup_crypto.sh"
fi

require_cmd rclone

if [ -z "${backupall2:-}" ]; then
    backupall2="/root/rish/backup_list_all"
fi

if [[ "$1" == "auto" ]] && [ -n "${2:-}" ]; then
    backupall2="$2"
fi


DATE_DIR=$(/bin/date '+%Y.%m.%d')
DATE_TS=$(/bin/date '+%Y-%m-%d_%H-%M')

GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
YELLOW='\033[0;33m'
WHITE='\033[0m'

backupall() {
    local overall_status=0
    local archive_base age_suffix completion_part completion_prefix completion_remote_path
    local USER TARGET TYPE DB REMOTE ARCHIVE_FLAG EXCLUDE_LIST
    local ARCHIVE_NAME dir
    local -a EXCLUDE_OPTS EXCLUDE_DIRS

    mkdir -p "$DIR_BACKUP"
    rm -rf "$DIR_BACKUP"/*

    declare -A CLEANUP_TARGETS CLEANUP_REMOTES
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

    backup_object_error() {
        local message="$1"
        overall_status=1
        echo -e "${LRED}Ошибка:${WHITE} ${message}"
        if command -v logger >/dev/null 2>&1; then
            logger -t rish-backup -- "$message"
        fi
    }

    cleanup_current_archive() {
        rm -f -- "${archive_base}".*-part-*
    }

    prepare_completion_part() {
        local part_prefix="$1"
        local last_part
        local -a part_files=()

        shopt -s nullglob
        part_files=("${part_prefix}"*)
        shopt -u nullglob
        ((${#part_files[@]} > 0)) || return 1
        mapfile -t part_files < <(printf '%s\n' "${part_files[@]}" | LC_ALL=C sort)
        last_part="${part_files[$((${#part_files[@]} - 1))]}"
        completion_part="${last_part}.end"
        if ! mv -- "$last_part" "$completion_part"; then
            completion_part=""
            return 1
        fi
        completion_remote_path="${completion_part#"${DIR_BACKUP%/}/"}"
        [[ -n "$completion_remote_path" && "$completion_remote_path" != "$completion_part" ]]
    }

    create_database_parts() {
        local db_name="$1"
        local output_prefix="$2"

        if [[ "$BACKUP_ARCHIVE_MODE" == "crypto" ]]; then
            (set -o pipefail; mariadb-dump \
                --extended-insert \
                --single-transaction \
                --quick \
                --routines \
                --events \
                --triggers \
                --quote-names \
                --order-by-primary \
                --hex-blob \
                "$db_name" \
                | sed '1{/999999.*sandbox/d}' \
                | sed '/NOTE_VERBOSITY/d' \
                | gzip \
                | age "${BACKUP_AGE_ARGS[@]}" \
                | split -b "$splitarchive" --numeric-suffixes - "$output_prefix")
        else
            (set -o pipefail; mariadb-dump \
                --extended-insert \
                --single-transaction \
                --quick \
                --routines \
                --events \
                --triggers \
                --quote-names \
                --order-by-primary \
                --hex-blob \
                "$db_name" \
                | sed '1{/999999.*sandbox/d}' \
                | sed '/NOTE_VERBOSITY/d' \
                | gzip \
                | split -b "$splitarchive" --numeric-suffixes - "$output_prefix")
        fi
    }

    create_file_parts() {
        local output_prefix="$1"

        echo "Идет создание архива файлов..."
        echo "Обработано: 0MB"
        if [[ "$BACKUP_ARCHIVE_MODE" == "crypto" ]]; then
            (set -o pipefail; tar -czhf - "${EXCLUDE_OPTS[@]}" "$TARGET" \
                --record-size="$recordsize" --checkpoint="$checkpoint" \
                --checkpoint-action=exec='printf "\033[1A\rОбработано: %sMB\033[K\033[1B\r" "$((TAR_CHECKPOINT))" >&2' \
                | age "${BACKUP_AGE_ARGS[@]}" \
                | split -b "$splitarchive" --numeric-suffixes - "$output_prefix")
        else
            (set -o pipefail; tar -czhf - "${EXCLUDE_OPTS[@]}" "$TARGET" \
                --record-size="$recordsize" --checkpoint="$checkpoint" \
                --checkpoint-action=exec='printf "\033[1A\rОбработано: %sMB\033[K\033[1B\r" "$((TAR_CHECKPOINT))" >&2' \
                | split -b "$splitarchive" --numeric-suffixes - "$output_prefix")
        fi
        local status=$?
        printf '\033[1A\r\033[K\033[1A\r\033[K'
        return "$status"
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

        if ! backup_parse_archive_policy "$ARCHIVE_FLAG"; then
            backup_object_error "Архивация ${TARGET} пропущена: ${BACKUP_ARCHIVE_POLICY_ERROR}."
            continue
        fi
        if [[ "$BACKUP_ARCHIVE_MODE" == "disabled" ]]; then
            echo -e "Пропускаем ${YELLOW}${TARGET}${WHITE}: архивирование отключено."
            continue
        fi
        if [[ "$BACKUP_ARCHIVE_MODE" == "crypto" ]]; then
            if ! backup_validate_age_recipients; then
                backup_object_error "Зашифрованная архивация ${TARGET} пропущена: ${BACKUP_ARCHIVE_POLICY_ERROR}."
                continue
            fi
            age_suffix=".age"
        else
            age_suffix=""
        fi

        if [ -z "$TYPE" ]; then
            TYPE="$(object_type_for_target "$TARGET")"
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
            backup_object_error "Подключение '${REMOTE}' не найдено в rclone. Архивация ${TARGET} пропущена."
            continue
        fi

        if [ ! -d "/var/www/${USER}/www/${TARGET}" ]; then
            backup_object_error "Архивация ${TARGET} пропущена: каталог /var/www/${USER}/www/${TARGET} не найден."
            continue
        fi

        ARCHIVE_NAME="${TARGET}_${DATE_TS}"
        EXCLUDE_OPTS=()
        if [ -n "$EXCLUDE_LIST" ]; then
            IFS=',' read -r -a EXCLUDE_DIRS <<< "$EXCLUDE_LIST"
            for dir in "${EXCLUDE_DIRS[@]}"; do
                dir="${dir#"${dir%%[![:space:]]*}"}"
                dir="${dir%"${dir##*[![:space:]]}"}"
                dir="${dir#/}"
                dir="${dir%/}"
                if [ -n "$dir" ]; then
                    EXCLUDE_OPTS+=(--exclude="${TARGET}/${dir}/*")
                    EXCLUDE_OPTS+=(--exclude="${TARGET}/${dir}/.*")
                fi
            done
        fi

        mkdir -p "$DIR_BACKUP/$server/$USER/$DATE_DIR/"
        archive_base="$DIR_BACKUP/${server}/${USER}/${DATE_DIR}/${ARCHIVE_NAME}"
        cleanup_current_archive

        if [ "$TYPE" = "site" ]; then
            echo -e "Архивация сайта ${GREEN}${TARGET}${WHITE}."
        elif [ "$TYPE" = "db" ]; then
            echo -e "Архивация базы сайта ${GREEN}${TARGET}${WHITE}."
        else
            echo -e "Архивация папки ${GREEN}${TARGET}${WHITE}."
        fi
        if [[ "$BACKUP_ARCHIVE_MODE" == "crypto" ]]; then
            echo -e "Шифрование: ${GREEN}age${WHITE}, публичных ключей: ${YELLOW}${#BACKUP_AGE_RECIPIENTS[@]}${WHITE}."
        fi

        if ! cd "/var/www/${USER}/www"; then
            backup_object_error "Не удалось перейти в /var/www/${USER}/www. Архивация ${TARGET} пропущена."
            continue
        fi

        if [ "$TYPE" = "db" ]; then
            if [ -z "$DB" ]; then
                backup_object_error "Для ${TARGET} не указана база данных. Архивация пропущена."
                continue
            fi
            echo -e "Создаем дамп базы ${GREEN}${DB}${WHITE}..."
            if ! create_database_parts "$DB" "${archive_base}.sql.gz${age_suffix}-part-"; then
                cleanup_current_archive
                backup_object_error "Не удалось создать архив базы ${DB}. Архивация ${TARGET} пропущена."
                continue
            fi
            printf '\033[1A\r\033[K'
        else
            if [ -n "$DB" ] && db_exists "$DB"; then
                echo -e "Создаем дамп базы ${GREEN}${DB}${WHITE}..."
                if ! create_database_parts "$DB" "${archive_base}.sql.gz${age_suffix}-part-"; then
                    cleanup_current_archive
                    backup_object_error "Не удалось создать архив базы ${DB}. Архивация ${TARGET} пропущена."
                    continue
                fi
                printf '\033[1A\r\033[K'
            elif [ -n "$DB" ]; then
                echo -e "${YELLOW}База ${DB} не найдена: архивируем только файлы сайта.${WHITE}"
            fi

            if ! create_file_parts "${archive_base}.tar.gz${age_suffix}-part-"; then
                cleanup_current_archive
                backup_object_error "Не удалось создать архив файлов ${TARGET}. Архивация пропущена."
                continue
            fi
        fi

        if [ "$TYPE" = "db" ]; then
            completion_prefix="${archive_base}.sql.gz${age_suffix}-part-"
        else
            completion_prefix="${archive_base}.tar.gz${age_suffix}-part-"
        fi
        completion_part=""
        completion_remote_path=""
        if ! prepare_completion_part "$completion_prefix"; then
            cleanup_current_archive
            backup_object_error "Не удалось отметить последнюю часть архива ${TARGET}. Архивация пропущена."
            continue
        fi

        if rclone copy --progress --stats-one-line --stats=1s --exclude "*.end" "$DIR_BACKUP/" "${REMOTE}:"; then
            printf '\033[1A\r\033[K'
            if rclone copyto --progress --stats-one-line --stats=1s \
                "$completion_part" "${REMOTE}:${completion_remote_path}"; then
                printf '\033[1A\r\033[K'
                rm -rf "$DIR_BACKUP"/*
                CLEANUP_TARGETS["$REMOTE|$USER"]=1
                CLEANUP_REMOTES["$REMOTE"]=1
            else
                printf '\033[1A\r\033[K'
                rm -rf "$DIR_BACKUP"/*
                backup_object_error "Ошибка передачи последней части архива ${TARGET} в подключение '${REMOTE}'. Переданные части сохранены без признака завершения."
            fi
        else
            printf '\033[1A\r\033[K'
            rm -rf "$DIR_BACKUP"/*
            backup_object_error "Ошибка передачи архива ${TARGET} в подключение '${REMOTE}'. Временные файлы очищены."
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

    for REMOTE in "${!CLEANUP_REMOTES[@]}"; do
        if [ -z "$REMOTE" ]; then
            continue
        fi
        if rclone cleanup "${REMOTE}:" >/dev/null 2>&1; then
            echo -e "${GREEN}${REMOTE}${WHITE}: cleanup выполнен."
        else
            echo -e "${YELLOW}${REMOTE}${WHITE}: cleanup недоступен или завершился с ошибкой."
        fi
    done

    return "$overall_status"
}

createlist() {
	echo
	echo "Создаем список объектов для архивации."
	echo

	if [ -f "$backupall2" ]; then
		echo -e "${YELLOW}Внимание:${WHITE} файл списка уже существует: ${YELLOW}${backupall2}${WHITE}"
		echo "Перезапись удалит текущие настройки объектов (включая type/archive/exclude и шифрование)."
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
	echo "# format: user;name;type(site|folder|db);db;remote;archive(no|yes|crypto:<age_or_ssh_public_key>[,<age_or_ssh_public_key>]);exclude_list" >> "$backupall2"
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
        elif [ "$TYPE" = "db" ]; then
            kind_label="база сайта"
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

        if [ "$old_type" != "db" ]; then
            TYPE="$(object_type_for_target "$TARGET")"
        fi
        if [ "$old_type" != "$TYPE" ] && [ "$old_type" != "unknown" ]; then
            echo -e "Изменен тип: ${GREEN}${TARGET}${WHITE} (${USER}) ${YELLOW}${old_type}${WHITE} -> ${GREEN}${TYPE}${WHITE}"
        fi

        if [ "$TYPE" = "site" ] || [ "$TYPE" = "db" ]; then
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
        echo "# format: user;name;type(site|folder|db);db;remote;archive(no|yes|crypto:<age_or_ssh_public_key>[,<age_or_ssh_public_key>]);exclude_list"
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
    if [ ! -r "$backupall2" ]; then
        echo -e "Автоматическая архивация пропущена: файл списка не найден или недоступен: ${LRED}${backupall2}${WHITE}"
        exit 1
    fi
    if ! is_remote_configured; then
        echo -e "Автоматическая архивация пропущена: подключение ${LRED}'${rclone_remote}'${WHITE} не настроено."
        exit 1
    fi
	echo "Автоматическая архивация"
	backupall
	exit $?
fi

configcnf() {
   echo "Конфигурируем rclone (Yandex Disk)"
   echo
   bash /root/rish/ydisk_oauth_device_login.sh "$rclone_remote"
}

remote_info() {
    local selected_remote="$rclone_remote"
    local remote_features about_supported about_output

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

    about_supported=""
    if remote_features="$(rclone backend features "${selected_remote}:" 2>/dev/null)"; then
        about_supported="$(
            printf '%s' "$remote_features" \
                | jq -r '.Features.About | if . == null then empty else tostring end' 2>/dev/null
        )"
    fi

    case "$about_supported" in
        true)
            echo "Общая информация о хранилище:"
            if ! rclone about "${selected_remote}:"; then
                echo -e "${YELLOW}Не удалось получить общую информацию о хранилище.${WHITE}"
            fi
            ;;
        false)
            echo "Общая квота хранилища не предоставляется этим типом подключения."
            ;;
        *)
            if about_output="$(rclone about "${selected_remote}:" 2>/dev/null)"; then
                echo "Общая информация о хранилище:"
                printf '%s\n' "$about_output"
            else
                echo "Общая квота хранилища не предоставляется этим типом подключения."
            fi
            ;;
    esac
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
                [ -f "$HOME/.config/rclone/rclone.conf" ] || touch "$HOME/.config/rclone/rclone.conf"
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

backup_crypto_menu_height() {
    local terminal_size lines height

    if ! terminal_size="$(stty size 2>/dev/null)"; then
        printf '20'
        return
    fi
    lines="${terminal_size% *}"
    if [[ ! "$lines" =~ ^[0-9]+$ ]]; then
        printf '20'
        return
    fi
    height=$((lines - 9))
    ((height < 5)) && height=5
    printf '%s' "$height"
}

backup_list_set_archive_policy() {
    local line_no="$1"
    local new_policy="$2"
    local list_dir list_name tmp_file

    [[ "$line_no" =~ ^[0-9]+$ ]] || return 1
    [[ "$new_policy" != *';'* && "$new_policy" != *$'\n'* && "$new_policy" != *$'\r'* ]] || return 1
    [[ -f "$backupall2" && ! -L "$backupall2" ]] || return 1

    list_dir="$(dirname "$backupall2")"
    list_name="$(basename "$backupall2")"
    tmp_file="$(mktemp "${list_dir}/.${list_name}.rish-tmp.XXXXXX")" || return 1

    if ! awk -F';' -v OFS=';' -v wanted_line="$line_no" -v policy="$new_policy" '
        NR == wanted_line {
            if (NF < 6) {
                exit 2
            }
            $6=policy
            updated=1
        }
        { print }
        END {
            if (!updated) {
                exit 3
            }
        }
    ' "$backupall2" > "$tmp_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi

    if ! chmod 600 "$tmp_file" || ! chown --reference="$backupall2" "$tmp_file" || ! mv -f -- "$tmp_file" "$backupall2"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    return 0
}

backup_list_describe_archive_policy_scope_changes() {
    local scope="$1"
    local scope_user="$2"
    local new_policy="$3"

    [[ "$scope" == "user" || "$scope" == "server" ]] || return 1
    [[ -f "$backupall2" ]] || return 1

    awk -F';' -v scope="$scope" -v wanted_user="$scope_user" -v policy="$new_policy" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*#/ || NF < 6 { next }
        {
            current=tolower(trim($6))
            enabled=(current == "yes" || current == "y" || current == "true" ||
                     current == "on" || current == "archive" || current == "да" ||
                     current ~ /^crypto:/)
            in_scope=(scope == "server" || $1 == wanted_user)
            if (enabled && in_scope && $6 != policy) {
                changed++
                object_type=trim($3)
                if (object_type == "") {
                    object_type="object"
                }
                changed_objects[changed]=sprintf("%s (%s, %s)", trim($2), trim($1), object_type)
                if (current ~ /^crypto:/) {
                    replaced++
                }
            }
        }
        END {
            print changed + 0 ";" replaced + 0
            for (i=1; i <= changed; i++) {
                print changed_objects[i]
            }
        }
    ' "$backupall2"
}

backup_list_apply_archive_policy_scope() {
    local scope="$1"
    local scope_user="$2"
    local new_policy="$3"
    local list_dir list_name tmp_file

    [[ "$scope" == "user" || "$scope" == "server" ]] || return 1
    [[ "$new_policy" != *';'* && "$new_policy" != *$'\n'* && "$new_policy" != *$'\r'* ]] || return 1
    [[ -f "$backupall2" && ! -L "$backupall2" ]] || return 1

    list_dir="$(dirname "$backupall2")"
    list_name="$(basename "$backupall2")"
    tmp_file="$(mktemp "${list_dir}/.${list_name}.rish-tmp.XXXXXX")" || return 1

    if ! awk -F';' -v OFS=';' -v scope="$scope" -v wanted_user="$scope_user" -v policy="$new_policy" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*#/ || NF < 6 { print; next }
        {
            current=tolower(trim($6))
            enabled=(current == "yes" || current == "y" || current == "true" ||
                     current == "on" || current == "archive" || current == "да" ||
                     current ~ /^crypto:/)
            in_scope=(scope == "server" || $1 == wanted_user)
            if (enabled && in_scope && $6 != policy) {
                $6=policy
                changed++
            }
            print
        }
        END {
            if (!changed) {
                exit 3
            }
        }
    ' "$backupall2" > "$tmp_file"; then
        rm -f -- "$tmp_file"
        return 1
    fi

    if ! chmod 600 "$tmp_file" || ! chown --reference="$backupall2" "$tmp_file" || ! mv -f -- "$tmp_file" "$backupall2"; then
        rm -f -- "$tmp_file"
        return 1
    fi
    return 0
}

backup_crypto_wait() {
    vertical_menu "current" 2 0 5 "$@" "Нажмите Enter"
}

backup_crypto_apply_policy() {
    local line_no="$1"
    local new_policy="$2"

    if backup_list_set_archive_policy "$line_no" "$new_policy"; then
        return 0
    fi
    clear
    echo -e "Не удалось ${LRED}обновить настройку шифрования${WHITE}."
    echo -e "Проверьте файл ${YELLOW}${backupall2}${WHITE} и права на его каталог."
    backup_crypto_wait
    return 1
}

backup_crypto_apply_policy_scope() {
    local scope="$1"
    local user="$2"
    local new_policy="$3"
    local change_report counts changed_count replaced_count title warning changed_object
    local -a change_lines=() changed_objects=()

    change_report="$(backup_list_describe_archive_policy_scope_changes "$scope" "$user" "$new_policy")" || change_report=""
    mapfile -t change_lines <<< "$change_report"
    counts="${change_lines[0]:-}"
    if ((${#change_lines[@]} > 1)); then
        changed_objects=("${change_lines[@]:1}")
    fi
    IFS=';' read -r changed_count replaced_count <<< "$counts"
    if [[ ! "$changed_count" =~ ^[0-9]+$ || ! "$replaced_count" =~ ^[0-9]+$ ]]; then
        clear
        echo -e "Не удалось ${LRED}прочитать список объектов${WHITE}."
        echo -e "Проверьте файл ${YELLOW}${backupall2}${WHITE}."
        backup_crypto_wait
        return 1
    fi
    if ((changed_count == 0)); then
        clear
        echo "Все подходящие объекты уже используют эти публичные ключи."
        echo "Строки с archive=no оставлены без изменений."
        backup_crypto_wait
        return 0
    fi

    if ((replaced_count > 0)); then
        if [[ "$scope" == "user" ]]; then
            title="Замена публичных ключей у объектов пользователя ${GREEN}${user}${WHITE}"
            warning="Будут заменены существующие публичные ключи у объектов: ${YELLOW}${replaced_count}${WHITE}."
        else
            title="Замена публичных ключей у объектов ${GREEN}всего сервера${WHITE}"
            warning="Будут заменены существующие публичные ключи у объектов: ${YELLOW}${replaced_count}${WHITE}.\nКомпрометация любого соответствующего ${YELLOW}приватного ключа${WHITE} откроет доступ к новым бэкапам всех изменённых объектов."
        fi
        warning+="\nВсего будут изменены настройки объектов: ${YELLOW}${changed_count}${WHITE}."
        warning+="\nСтроки с archive=no останутся без изменений."
        warning+="\nСуществующие архивы не изменятся: для них могут потребоваться прежние приватные ключи."

        if ! backup_crypto_confirm "$title" "$warning" "Заменить ключи"; then
            return 0
        fi
    fi
    if backup_list_apply_archive_policy_scope "$scope" "$user" "$new_policy"; then
        clear
        echo "Публичные ключи назначены объектам:"
        echo
        for changed_object in "${changed_objects[@]}"; do
            printf '  %b%s%b\n' "$GREEN" "$changed_object" "$WHITE"
        done
        echo
        echo -e "Всего изменено: ${GREEN}${changed_count}${WHITE}."
        backup_crypto_wait nomouse
        return 0
    fi

    clear
    echo -e "Не удалось ${LRED}обновить настройки шифрования${WHITE}."
    echo -e "Проверьте файл ${YELLOW}${backupall2}${WHITE} и права на его каталог."
    backup_crypto_wait
    return 1
}

backup_crypto_show_info() {
    local user="$1"
    local target="$2"
    local type="$3"
    local policy="$4"
    local recipient
    local index=0

    clear
    echo -e "Объект: ${GREEN}${target}${WHITE}"
    echo -e "Пользователь: ${YELLOW}${user}${WHITE}"
    echo -e "Тип: ${YELLOW}${type}${WHITE}"
    echo

    if ! backup_parse_archive_policy "$policy"; then
        echo -e "Состояние: ${LRED}ошибка настройки${WHITE}"
        echo -e "Причина: ${YELLOW}${BACKUP_ARCHIVE_POLICY_ERROR}${WHITE}"
    elif [[ "$BACKUP_ARCHIVE_MODE" == "plain" ]]; then
        echo -e "Состояние: резервные копии создаются ${YELLOW}без шифрования${WHITE}."
    elif [[ "$BACKUP_ARCHIVE_MODE" == "disabled" ]]; then
        echo -e "Состояние: резервное копирование ${YELLOW}отключено${WHITE}."
    elif ! backup_validate_age_recipients; then
        echo -e "Состояние: ${LRED}ошибка настройки${WHITE}"
        echo -e "Причина: ${YELLOW}${BACKUP_ARCHIVE_POLICY_ERROR}${WHITE}"
    else
        echo -e "Состояние: шифрование ${GREEN}включено${WHITE}."
        echo -e "Публичных ключей: ${YELLOW}${#BACKUP_AGE_RECIPIENTS[@]}${WHITE}"
        echo
        for recipient in "${BACKUP_AGE_RECIPIENTS[@]}"; do
            index=$((index + 1))
            if ((index == 1)); then
                if [[ "$recipient" == ssh-* ]]; then
                    echo -e "Основной публичный SSH-ключ: ${GREEN}${recipient}${WHITE}"
                else
                    echo -e "Основной публичный ключ age: ${GREEN}${recipient}${WHITE}"
                fi
            else
                if [[ "$recipient" == ssh-* ]]; then
                    echo -e "Запасной публичный SSH-ключ: ${GREEN}${recipient}${WHITE}"
                else
                    echo -e "Запасной публичный ключ age: ${GREEN}${recipient}${WHITE}"
                fi
            fi
        done
    fi
    echo
    backup_crypto_wait nomouse
}

backup_crypto_confirm() {
    local title="$1"
    local warning="$2"
    local confirm_label="$3"
    local choice

    clear
    echo -e "$title"
    echo
    [[ -z "$warning" ]] || echo -e "$warning"
    echo
    vertical_menu "current" 2 0 48 "Отмена" "$confirm_label"
    choice=$?
    [[ "$choice" -eq 1 ]]
}

BACKUP_GENERATED_RECIPIENT=""

backup_crypto_generate_identity() {
    local user="$1"
    local target="$2"
    local temp_dir identity_file recipient_log recipient
    local challenge_file encrypted_challenge restored_challenge
    local verification_error verification_failure=""
    local export_choice export_file export_name safe_user timestamp verification_identity
    local line armor_complete=0 input_cancelled=0
    local original_umask

    BACKUP_GENERATED_RECIPIENT=""
    if ! backup_crypto_available || ! backup_crypto_keygen_available; then
        clear
        echo -e "Не найдены команды ${LRED}age${WHITE} и ${LRED}age-keygen${WHITE}."
        backup_crypto_wait
        return 1
    fi

    original_umask="$(umask)"
    temp_dir="$(mktemp -d)" || return 1
    if ! chmod 700 "$temp_dir"; then
        rm -rf -- "$temp_dir"
        return 1
    fi
    backup_crypto_cleanup_identity_temp() {
        trap - EXIT
        if [[ -n "${temp_dir:-}" && -d "$temp_dir" ]]; then
            rm -rf -- "$temp_dir"
        fi
        temp_dir=""
        if [[ -n "${original_umask:-}" ]]; then
            umask "$original_umask"
            original_umask=""
        fi
    }
    trap 'backup_crypto_cleanup_identity_temp' EXIT
    identity_file="${temp_dir}/identity.age"
    recipient_log="${temp_dir}/recipient.log"
    challenge_file="${temp_dir}/challenge"
    encrypted_challenge="${temp_dir}/challenge.age"
    restored_challenge="${temp_dir}/challenge.restored"
    verification_error="${temp_dir}/verification.error"

    clear
    echo -e "Создание ключа шифрования для ${GREEN}${target}${WHITE}."
    echo
    echo "Сейчас age попросит пароль для защиты приватного ключа."
    echo "Вводимый пароль не отображается на экране — это нормальное поведение age."
    echo "Если оставить поле пустым и нажать Enter, age создаст пароль и покажет его один раз."
    echo "Сохраните пароль отдельно от файла ключа."
    echo

    umask 077
    if ! (set -o pipefail; age-keygen 2> "$recipient_log" | age -p -a -o "$identity_file"); then
        backup_crypto_cleanup_identity_temp
        echo -e "Не удалось ${LRED}создать защищённый ключ${WHITE}."
        backup_crypto_wait
        return 1
    fi

    echo
    echo "Если age создала пароль автоматически, скопируйте и сохраните его сейчас."
    echo "RISH не хранит этот пароль и не сможет показать его повторно."
    backup_crypto_wait nomouse

    recipient="$(sed -n 's/^Public key: //p' "$recipient_log" | head -n 1)"
    if ! backup_parse_archive_policy "crypto:${recipient}" || ! backup_validate_age_recipients; then
        backup_crypto_cleanup_identity_temp
        echo -e "Не удалось ${LRED}определить созданный публичный ключ${WHITE}."
        backup_crypto_wait
        return 1
    fi

    clear
    echo -e "Защищённый приватный ключ для ${GREEN}${target}${WHITE} создан."
    echo -e "Публичный ключ шифрования: ${GREEN}${recipient}${WHITE}"
    safe_user="${user//[![:alnum:]._-]/_}"
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    export_name="${safe_user}-age-identity-${timestamp}.age"
    echo
    echo "Для восстановления зашифрованных бэкапов потребуется файл приватного ключа."
    echo "Без этого файла и пароля к нему расшифровать архивы невозможно."
    echo
    echo "RISH не может сохранить файл прямо на вашем компьютере."
    echo "Выберите, как получить защищённый паролем файл ключа."
    echo "После сохранения ключ будет проверен, и только затем шифрование будет включено."
    echo
    vertical_menu "current" 2 0 50 \
        "Сохранить на свой компьютер через буфер обмена" \
        "Сохранить в /root для последующего скачивания" \
        "Отмена — не включать шифрование"
    export_choice=$?

    case "$export_choice" in
        0)
            clear
            echo -e "Защищённый ключ для ${GREEN}${target}${WHITE}:"
            echo
            cat "$identity_file"
            echo
            echo "Скопируйте защищённый ключ в буфер обмена и сохраните его"
            echo -e "на своём компьютере в файл ${GREEN}${export_name}${WHITE}."
            echo
            echo "Скопируйте блок целиком, включая строки BEGIN и END."
            echo "Последнюю строку END обязательно копируйте вместе с переводом строки!"
            echo "После сохранения нажмите Enter — экран будет очищен."
            backup_crypto_wait nomouse
            clear
            verification_identity="${temp_dir}/copied-identity.age"
            echo "Для проверки вставьте сохранённый защищённый блок обратно."
            echo "Ввод завершится после строки END и перевода строки за ней."
            echo "Для отмены нажмите Enter на пустой строке."
            echo
            : > "$verification_identity"
            while IFS= read -r line; do
                if [[ -z "$line" ]]; then
                    input_cancelled=1
                    break
                fi
                printf '%s\n' "$line" >> "$verification_identity"
                if [[ "$line" == "-----END AGE ENCRYPTED FILE-----" ]]; then
                    armor_complete=1
                    break
                fi
            done
            if [[ "$input_cancelled" -eq 1 ]]; then
                backup_crypto_cleanup_identity_temp
                echo -e "Проверка ключа ${YELLOW}отменена${WHITE}. Шифрование не включено."
                backup_crypto_wait
                return 1
            fi
            if [[ "$armor_complete" -ne 1 ]] || ! grep -Fqx -- "-----BEGIN AGE ENCRYPTED FILE-----" "$verification_identity"; then
                backup_crypto_cleanup_identity_temp
                echo -e "Защищённый ключ введён ${LRED}не полностью${WHITE}. Настройка не изменена."
                backup_crypto_wait
                return 1
            fi
            ;;
        1)
            export_file="/root/${export_name}"
            if ! install -m 600 "$identity_file" "$export_file"; then
                backup_crypto_cleanup_identity_temp
                echo -e "Не удалось сохранить защищённый ключ в ${LRED}/root${WHITE}."
                backup_crypto_wait
                return 1
            fi
            echo
            echo -e "Ключ сохранён: ${GREEN}${export_file}${WHITE}"
            echo "Скопируйте его с сервера и затем удалите серверную копию."
            backup_crypto_wait
            verification_identity="$export_file"
            ;;
        *)
            backup_crypto_cleanup_identity_temp
            return 1
            ;;
    esac

    printf 'rish-age-key-check:%s:%s\n' "$target" "$RANDOM" > "$challenge_file"
    if ! age -r "$recipient" -o "$encrypted_challenge" "$challenge_file"; then
        backup_crypto_cleanup_identity_temp
        echo -e "Не удалось выполнить ${LRED}проверочное шифрование${WHITE}."
        backup_crypto_wait
        return 1
    fi

    clear
    echo "Проверяем защищённый ключ."
    echo "Повторно введите пароль, который указали при его создании."
    echo "Вводимый пароль не отображается на экране."
    echo
    verification_failure=""
    if ! age -d -i "$verification_identity" -o "$restored_challenge" "$encrypted_challenge" 2> "$verification_error"; then
        if grep -Fqi -- "incorrect passphrase" "$verification_error"; then
            verification_failure="incorrect_passphrase"
        else
            verification_failure="decrypt_failed"
        fi
    elif ! cmp -s "$challenge_file" "$restored_challenge"; then
        verification_failure="mismatch"
    fi
    if [[ -n "$verification_failure" ]]; then
        backup_crypto_cleanup_identity_temp
        if [[ "$verification_failure" == "incorrect_passphrase" ]]; then
            echo -e "Введён ${LRED}неверный пароль${WHITE} приватного ключа. Настройка не изменена."
        else
            echo -e "Проверка ключа ${LRED}не пройдена${WHITE}. Настройка не изменена."
        fi
        backup_crypto_wait
        return 1
    fi
    rm -f -- "$verification_error"

    backup_crypto_cleanup_identity_temp
    BACKUP_GENERATED_RECIPIENT="$recipient"
    echo -e "Ключ для ${GREEN}${target}${WHITE} успешно проверен."
    return 0
}

backup_crypto_read_recipient() {
    local result_var="$1"
    local recipient

    clear
    echo "Введите существующий публичный ключ age (age1...):"
    echo
    read -r -e recipient
    recipient="$(backup_crypto_trim "$recipient")"

    if ! backup_parse_archive_policy "crypto:${recipient}" || ! backup_validate_age_recipients; then
        echo
        echo -e "${LRED}Некорректный публичный ключ:${WHITE} ${BACKUP_ARCHIVE_POLICY_ERROR}"
        backup_crypto_wait
        return 1
    fi
    printf -v "$result_var" '%s' "$recipient"
}

backup_crypto_choose_ssh_recipient() {
    local result_var="$1"
    local authorized_keys_file="/root/.ssh/authorized_keys"
    local line key_type key_data comment recipient label choice menu_height
    local -a recipients=() labels=()
    local -A seen=()

    clear
    echo "Публичный SSH-ключ для шифрования бэкапов"
    echo -e "Источник: ${GREEN}${authorized_keys_file}${WHITE}"
    echo

    if [[ ! -f "$authorized_keys_file" ]]; then
        echo -e "Файл ${YELLOW}${authorized_keys_file}${WHITE} не найден."
        backup_crypto_wait
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(backup_crypto_trim "$line")"
        [[ "$line" =~ ^(ssh-ed25519|ssh-rsa)[[:space:]]+([A-Za-z0-9+/]+={0,2})([[:space:]]+(.*))?$ ]] || continue
        key_type="${BASH_REMATCH[1]}"
        key_data="${BASH_REMATCH[2]}"
        comment="${BASH_REMATCH[4]:-}"
        recipient="${key_type} ${key_data}"
        [[ -z "${seen[$recipient]+x}" ]] || continue
        if ! backup_parse_archive_policy "crypto:${recipient}" || ! backup_validate_age_recipients; then
            continue
        fi
        seen["$recipient"]=1
        recipients+=("$recipient")
        comment="$(printf '%s' "$comment" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')"
        if [[ -n "$comment" ]]; then
            printf -v label '%s · %s' "$(backup_crypto_short_recipient "$recipient")" "${comment:0:48}"
        else
            label="$(backup_crypto_short_recipient "$recipient")"
        fi
        labels+=("$label")
    done < "$authorized_keys_file"

    if ((${#recipients[@]} == 0)); then
        echo "Поддерживаемые ключи ssh-ed25519 и ssh-rsa не найдены."
        echo "Строки с параметрами перед ключом в этом меню не используются."
        backup_crypto_wait
        return 1
    fi

    echo "Выберите ключ. Приватная часть должна быть сохранена на вашем компьютере."
    labels+=("Отмена")
    menu_height="$(backup_crypto_menu_height)"
    vertical_menu "current" 2 "$menu_height" 62 "${labels[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#recipients[@]})); then
        return 1
    fi
    printf -v "$result_var" '%s' "${recipients[$choice]}"
}

backup_crypto_choose_recipient_index() {
    local result_var="$1"
    shift
    local -a recipients=("$@") labels=()
    local recipient choice index=0

    if ((${#recipients[@]} == 1)); then
        printf -v "$result_var" '0'
        return 0
    fi
    clear
    echo "Выберите ключ:"
    echo
    for recipient in "${recipients[@]}"; do
        if ((index == 0)); then
            labels+=("Основной: $(backup_crypto_short_recipient "$recipient")")
        else
            labels+=("Запасной: $(backup_crypto_short_recipient "$recipient")")
        fi
        index=$((index + 1))
    done
    labels+=("Отмена")
    vertical_menu "current" 2 0 42 "${labels[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#recipients[@]})); then
        return 1
    fi
    printf -v "$result_var" '%s' "$choice"
}

draw_backup_crypto_action_connector() {
    local from_x="$1"
    local to_x="$2"
    local row="$3"
    local length

    length=$((to_x - from_x))
    ((length > 1)) || return 0
    cursor_to "$row" "$from_x"
    printf '├'
    repl '─' "$((length - 1))"
}

BACKUP_COPIED_POLICY=""
BACKUP_COPIED_SOURCE=""

backup_crypto_choose_policy_from_site() {
    local current_user="$1"
    local current_target="$2"
    local user target type db remote policy exclude normalized_policy details key_label label
    local choice index key_count set_number next_set_number=1 menu_height
    local target_width=0 details_width=0
    local -a labels=() source_users=() source_targets=() source_types=()
    local -a source_policies=() source_key_labels=() source_set_numbers=()
    local -A set_number_by_policy=() valid_policy_by_value=()

    BACKUP_COPIED_POLICY=""
    BACKUP_COPIED_SOURCE=""

    while IFS=';' read -r user target type db remote policy exclude; do
        [[ -n "$user" && -n "$target" && "$user" != \#* ]] || continue
        type="$(backup_crypto_trim "$type")"
        [[ "${type,,}" == "site" ]] || continue
        [[ "$user" == "$current_user" && "$target" == "$current_target" ]] && continue
        backup_parse_archive_policy "$policy" || continue
        [[ "$BACKUP_ARCHIVE_MODE" == "crypto" ]] || continue

        normalized_policy="$(backup_crypto_policy_value "${BACKUP_AGE_RECIPIENTS[@]}")"
        if [[ -z "${valid_policy_by_value[$normalized_policy]+x}" ]]; then
            if backup_validate_age_recipients; then
                valid_policy_by_value["$normalized_policy"]=1
            else
                valid_policy_by_value["$normalized_policy"]=0
            fi
        fi
        [[ "${valid_policy_by_value[$normalized_policy]}" -eq 1 ]] || continue
        if [[ -z "${set_number_by_policy[$normalized_policy]+x}" ]]; then
            set_number_by_policy["$normalized_policy"]="$next_set_number"
            next_set_number=$((next_set_number + 1))
        fi
        set_number="${set_number_by_policy[$normalized_policy]}"
        key_count="${#BACKUP_AGE_RECIPIENTS[@]}"
        if ((key_count == 1)); then
            key_label="1 ключ "
        else
            key_label="${key_count} ключа"
        fi
        details="(${user}, ${type})"

        source_users+=("$user")
        source_targets+=("$target")
        source_types+=("$type")
        source_policies+=("$normalized_policy")
        source_key_labels+=("$key_label")
        source_set_numbers+=("$set_number")
        ((${#target} > target_width)) && target_width=${#target}
        ((${#details} > details_width)) && details_width=${#details}
        if ((${#source_targets[@]} >= 247)); then
            break
        fi
    done < "$backupall2"

    clear
    echo "Скопировать публичные ключи с другого сайта"
    echo
    if ((${#source_targets[@]} == 0)); then
        echo -e "В списке ${YELLOW}нет других сайтов${WHITE} с настроенным шифрованием."
        backup_crypto_wait
        return 1
    fi

    for index in "${!source_targets[@]}"; do
        details="(${source_users[$index]}, ${source_types[$index]})"
        printf -v label '%-*s  %-*s  %s · набор #%s' \
            "$target_width" "${source_targets[$index]}" \
            "$details_width" "$details" \
            "${source_key_labels[$index]}" "${source_set_numbers[$index]}"
        labels+=("$label")
    done
    labels+=("Отмена")

    echo "Выберите сайт-источник:"
    menu_height="$(backup_crypto_menu_height)"
    vertical_menu "current" 2 "$menu_height" 54 "${labels[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#source_targets[@]})); then
        return 1
    fi

    BACKUP_COPIED_POLICY="${source_policies[$choice]}"
    BACKUP_COPIED_SOURCE="${source_targets[$choice]} (${source_users[$choice]})"
    return 0
}

backup_crypto_object_actions() {
    local line_no="$1"
    local user="$2"
    local target="$3"
    local type="$4"
    local policy="$5"
    local selected_row="$6"
    local menu_right_x="$7"
    local action_x="$8"
    local mode choice action new_recipient selected_index other_index new_policy current_policy
    local -a recipients=() labels=() actions=()

    if backup_parse_archive_policy "$policy"; then
        mode="$BACKUP_ARCHIVE_MODE"
        if [[ "$mode" == "crypto" ]] && ! backup_validate_age_recipients; then
            mode="invalid"
        else
            recipients=("${BACKUP_AGE_RECIPIENTS[@]}")
        fi
    else
        mode="invalid"
    fi

    labels+=("Инфо")
    actions+=("info")
    case "$mode" in
        plain)
            labels+=("Создать ключ age и включить шифрование" "Добавить существующий публичный ключ age" "Включить шифрование с публичным SSH-ключом" "Скопировать публичные ключи с другого сайта")
            actions+=("create" "add" "add_ssh" "copy_from_site")
            ;;
        disabled)
            labels+=("Создать ключ age и включить шифрование" "Включить с существующим публичным ключом age" "Включить с публичным SSH-ключом" "Скопировать публичные ключи с другого сайта")
            actions+=("create" "add" "add_ssh" "copy_from_site")
            ;;
        crypto)
            if ((${#recipients[@]} < 2)); then
                labels+=("Создать запасной ключ age" "Добавить запасной публичный ключ age" "Добавить запасной публичный SSH-ключ")
                actions+=("create_spare" "add_spare" "add_spare_ssh")
            fi
            labels+=("Заменить один публичный ключ")
            actions+=("reissue")
            labels+=("Скопировать публичные ключи с другого сайта")
            actions+=("copy_from_site")
            labels+=("Назначить эти ключи всем объектам пользователя ${user}")
            actions+=("apply_user")
            labels+=("Назначить эти ключи всем объектам сервера")
            actions+=("apply_server")
            if ((${#recipients[@]} > 1)); then
                labels+=("Удалить один публичный ключ")
                actions+=("remove_one")
            fi
            labels+=("Удалить ключи и отключить шифрование")
            actions+=("disable_crypto")
            ;;
        *)
            labels+=("Создать ключ age и исправить настройку" "Исправить существующим публичным ключом age" "Исправить публичным SSH-ключом" "Скопировать публичные ключи с другого сайта")
            actions+=("create" "add" "add_ssh" "copy_from_site")
            ;;
    esac
    labels+=("Назад")
    actions+=("back")

    selected_row=$((selected_row - 1))
    ((selected_row < 1)) && selected_row=1
    draw_backup_crypto_action_connector "$menu_right_x" "$action_x" "$((selected_row + 1))"
    vertical_menu "$selected_row" "$action_x" 0 30 "${labels[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#actions[@]})); then
        return 0
    fi
    action="${actions[$choice]}"

    case "$action" in
        info)
            backup_crypto_show_info "$user" "$target" "$type" "$policy"
            ;;
        create)
            if [[ "$mode" == "disabled" ]] && ! backup_crypto_confirm \
                "Включение зашифрованных бэкапов для ${GREEN}${target}${WHITE}" \
                "Одновременно будут включены резервное копирование и шифрование." \
                "Продолжить"; then
                return 0
            fi
            if backup_crypto_generate_identity "$user" "$target"; then
                new_policy="$(backup_crypto_policy_value "$BACKUP_GENERATED_RECIPIENT")"
                if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                    echo -e "Шифрование для ${GREEN}${target}${WHITE} включено."
                    backup_crypto_wait
                fi
            fi
            ;;
        add)
            if [[ "$mode" == "disabled" ]] && ! backup_crypto_confirm \
                "Включение зашифрованных бэкапов для ${GREEN}${target}${WHITE}" \
                "Одновременно будут включены резервное копирование и шифрование." \
                "Продолжить"; then
                return 0
            fi
            if backup_crypto_read_recipient new_recipient; then
                new_policy="$(backup_crypto_policy_value "$new_recipient")"
                if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                    echo -e "Шифрование для ${GREEN}${target}${WHITE} включено."
                    backup_crypto_wait
                fi
            fi
            ;;
        add_ssh)
            if [[ "$mode" == "disabled" ]] && ! backup_crypto_confirm \
                "Включение зашифрованных бэкапов для ${GREEN}${target}${WHITE}" \
                "Одновременно будут включены резервное копирование и шифрование." \
                "Продолжить"; then
                return 0
            fi
            if backup_crypto_choose_ssh_recipient new_recipient; then
                new_policy="$(backup_crypto_policy_value "$new_recipient")"
                if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                    echo -e "Шифрование для ${GREEN}${target}${WHITE} включено с публичным SSH-ключом."
                    backup_crypto_wait
                fi
            fi
            ;;
        copy_from_site)
            if ! backup_crypto_choose_policy_from_site "$user" "$target"; then
                return 0
            fi
            new_policy="$BACKUP_COPIED_POLICY"
            if [[ "$mode" == "crypto" ]]; then
                current_policy="$(backup_crypto_policy_value "${recipients[@]}")"
                if [[ "$new_policy" == "$current_policy" ]]; then
                    clear
                    echo -e "Для ${GREEN}${target}${WHITE} уже назначен тот же набор публичных ключей."
                    backup_crypto_wait
                    return 0
                fi
                if ! backup_crypto_confirm \
                    "Замена публичных ключей для ${GREEN}${target}${WHITE}" \
                    "Будут назначены публичные ключи сайта ${GREEN}${BACKUP_COPIED_SOURCE}${WHITE}.\n${YELLOW}Прежние приватные ключи${WHITE} потребуются для ранее созданных архивов." \
                    "Заменить ключи"; then
                    return 0
                fi
            elif [[ "$mode" == "disabled" ]] && ! backup_crypto_confirm \
                "Включение зашифрованных бэкапов для ${GREEN}${target}${WHITE}" \
                "Будут назначены публичные ключи сайта ${GREEN}${BACKUP_COPIED_SOURCE}${WHITE}.\nОдновременно будут включены резервное копирование и шифрование." \
                "Продолжить"; then
                return 0
            fi
            if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                clear
                echo "Публичные ключи скопированы:"
                echo
                echo -e "${GREEN}${BACKUP_COPIED_SOURCE}${WHITE}  →  ${GREEN}${target}${WHITE}"
                backup_crypto_wait
            fi
            ;;
        create_spare)
            if backup_crypto_generate_identity "$user" "$target"; then
                if [[ "$BACKUP_GENERATED_RECIPIENT" == "${recipients[0]}" ]]; then
                    echo -e "Созданный публичный ключ ${LRED}совпадает с основным${WHITE}."
                    backup_crypto_wait
                    return 1
                fi
                new_policy="$(backup_crypto_policy_value "${recipients[0]}" "$BACKUP_GENERATED_RECIPIENT")"
                if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                    echo -e "Запасной ключ age для ${GREEN}${target}${WHITE} добавлен."
                    backup_crypto_wait
                fi
            fi
            ;;
        add_spare)
            if backup_crypto_read_recipient new_recipient; then
                if [[ "$new_recipient" == "${recipients[0]}" ]]; then
                    echo -e "Этот публичный ключ уже указан как ${LRED}основной${WHITE}."
                    backup_crypto_wait
                    return 1
                fi
                new_policy="$(backup_crypto_policy_value "${recipients[0]}" "$new_recipient")"
                if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                    echo -e "Запасной публичный ключ для ${GREEN}${target}${WHITE} добавлен."
                    backup_crypto_wait
                fi
            fi
            ;;
        add_spare_ssh)
            if backup_crypto_choose_ssh_recipient new_recipient; then
                if [[ "$new_recipient" == "${recipients[0]}" ]]; then
                    echo -e "Этот публичный SSH-ключ уже указан как ${LRED}основной${WHITE}."
                    backup_crypto_wait
                    return 1
                fi
                new_policy="$(backup_crypto_policy_value "${recipients[0]}" "$new_recipient")"
                if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                    echo -e "Запасной публичный SSH-ключ для ${GREEN}${target}${WHITE} добавлен."
                    backup_crypto_wait
                fi
            fi
            ;;
        reissue)
            if ! backup_crypto_choose_recipient_index selected_index "${recipients[@]}"; then
                return 0
            fi
            if [[ "${recipients[$selected_index]}" == ssh-* ]]; then
                if ! backup_crypto_choose_ssh_recipient new_recipient; then
                    return 0
                fi
                if [[ "$new_recipient" == "${recipients[$selected_index]}" ]]; then
                    clear
                    echo -e "Для ${GREEN}${target}${WHITE} уже назначен этот публичный SSH-ключ."
                    backup_crypto_wait
                    return 0
                fi
                if ((${#recipients[@]} > 1)); then
                    other_index=$((1 - selected_index))
                    if [[ "$new_recipient" == "${recipients[$other_index]}" ]]; then
                        clear
                        echo -e "Этот публичный SSH-ключ уже назначен объекту ${GREEN}${target}${WHITE}."
                        backup_crypto_wait
                        return 0
                    fi
                fi
                if ! backup_crypto_confirm \
                    "Замена публичного SSH-ключа для ${GREEN}${target}${WHITE}" \
                    "Будет назначен другой готовый SSH-ключ из ${GREEN}/root/.ssh/authorized_keys${WHITE}.\n${YELLOW}Прежний приватный ключ${WHITE} потребуется для ранее созданных архивов." \
                    "Заменить SSH-ключ"; then
                    return 0
                fi
                recipients[selected_index]="$new_recipient"
                new_policy="$(backup_crypto_policy_value "${recipients[@]}")"
                if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                    echo -e "Публичный SSH-ключ для ${GREEN}${target}${WHITE} заменён для будущих бэкапов."
                    backup_crypto_wait
                fi
                return 0
            fi
            if ! backup_crypto_confirm \
                "Замена публичного ключа age для ${GREEN}${target}${WHITE}" \
                "${YELLOW}Старый приватный ключ${WHITE} потребуется для ранее созданных архивов.\nНе удаляйте его, пока старые копии не выйдут из срока хранения." \
                "Создать новый ключ age"; then
                return 0
            fi
            if backup_crypto_generate_identity "$user" "$target"; then
                recipients[selected_index]="$BACKUP_GENERATED_RECIPIENT"
                new_policy="$(backup_crypto_policy_value "${recipients[@]}")"
                if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                    echo -e "Публичный ключ age для ${GREEN}${target}${WHITE} заменён для будущих бэкапов."
                    backup_crypto_wait
                fi
            fi
            ;;
        apply_user)
            new_policy="$(backup_crypto_policy_value "${recipients[@]}")"
            backup_crypto_apply_policy_scope "user" "$user" "$new_policy"
            ;;
        apply_server)
            new_policy="$(backup_crypto_policy_value "${recipients[@]}")"
            backup_crypto_apply_policy_scope "server" "$user" "$new_policy"
            ;;
        remove_one)
            if ! backup_crypto_choose_recipient_index selected_index "${recipients[@]}"; then
                return 0
            fi
            if ! backup_crypto_confirm \
                "Удаление публичного ключа для ${GREEN}${target}${WHITE}" \
                "Старые архивы не изменятся. Убедитесь, что оставшийся ключ сохранён и проверен." \
                "Удалить публичный ключ"; then
                return 0
            fi
            if ((selected_index == 0)); then
                new_policy="$(backup_crypto_policy_value "${recipients[1]}")"
            else
                new_policy="$(backup_crypto_policy_value "${recipients[0]}")"
            fi
            if backup_crypto_apply_policy "$line_no" "$new_policy"; then
                echo -e "Публичный ключ для ${GREEN}${target}${WHITE} удалён из настройки."
                backup_crypto_wait
            fi
            ;;
        disable_crypto)
            if backup_crypto_confirm \
                "Удаление ключей шифрования для ${GREEN}${target}${WHITE}" \
                "${YELLOW}Новые резервные копии${WHITE} будут сохраняться без шифрования.\nСуществующие зашифрованные архивы не изменятся." \
                "Удалить ключи"; then
                if backup_crypto_apply_policy "$line_no" "yes"; then
                    echo -e "Шифрование для ${YELLOW}${target}${WHITE} отключено."
                    backup_crypto_wait
                fi
            fi
            ;;
        back)
            return 0
            ;;
    esac
}

backup_crypto_management_menu() {
    local default_index=0
    local menu_height choice line_no user target type db remote policy exclude status label details
    local target_width details_width index normalized_policy
    local menu_y menu_right_x action_x selected_row
    local -a labels=() line_numbers=() users=() targets=() types=() policies=() statuses=()
    local -A policy_validity=()

    if ! backup_crypto_available; then
        clear
        echo -e "Команда ${YELLOW}age не установлена${WHITE}. Управление шифрованием недоступно."
        backup_crypto_wait
        return 1
    fi

    while true; do
        labels=()
        line_numbers=()
        users=()
        targets=()
        types=()
        policies=()
        statuses=()
        policy_validity=()
        target_width=0
        details_width=0
        line_no=0

        while IFS=';' read -r user target type db remote policy exclude; do
            line_no=$((line_no + 1))
            [[ -n "$user" && -n "$target" && "$user" != \#* ]] || continue
            if backup_parse_archive_policy "$policy"; then
                case "$BACKUP_ARCHIVE_MODE" in
                    plain) status="без шифрования" ;;
                    disabled) status="бэкап отключён" ;;
                    crypto)
                        normalized_policy="$(backup_crypto_policy_value "${BACKUP_AGE_RECIPIENTS[@]}")"
                        if [[ -z "${policy_validity[$normalized_policy]+x}" ]]; then
                            if backup_validate_age_recipients; then
                                policy_validity["$normalized_policy"]=1
                            else
                                policy_validity["$normalized_policy"]=0
                            fi
                        fi
                        if [[ "${policy_validity[$normalized_policy]}" -eq 1 ]]; then
                            status="шифрование · ${#BACKUP_AGE_RECIPIENTS[@]} ключ"
                            (( ${#BACKUP_AGE_RECIPIENTS[@]} == 2 )) && status+="а"
                        else
                            status="ошибка настройки"
                        fi
                        ;;
                esac
            else
                status="ошибка настройки"
            fi
            type="${type:-object}"
            details="(${user}, ${type})"
            line_numbers+=("$line_no")
            users+=("$user")
            targets+=("$target")
            types+=("$type")
            policies+=("$policy")
            statuses+=("$status")
            ((${#target} > target_width)) && target_width=${#target}
            ((${#details} > details_width)) && details_width=${#details}
            if ((${#targets[@]} >= 247)); then
                break
            fi
        done < "$backupall2"

        for index in "${!targets[@]}"; do
            details="(${users[$index]}, ${types[$index]})"
            printf -v label '%-*s  %-*s  %s' \
                "$target_width" "${targets[$index]}" \
                "$details_width" "$details" \
                "${statuses[$index]}"
            labels+=("$label")
        done

        clear
        echo "Управление шифрованием резервных копий"
        echo -e "Список: ${GREEN}${backupall2}${WHITE}"
        echo -e "Утилита шифрования age: ${GREEN}установлена${WHITE}"
        echo
        if ((${#labels[@]} == 0)); then
            echo -e "В списке ${YELLOW}нет объектов${WHITE} для резервного копирования."
            backup_crypto_wait
            return 0
        fi
        labels+=("Назад")
        menu_height="$(backup_crypto_menu_height)"
        vertical_menu "current_noclear" 2 "$menu_height" 48 "default=${default_index}" "${labels[@]}"
        choice=$?
        menu_y="$VERTICAL_MENU_LAST_Y"
        menu_right_x="$VERTICAL_MENU_LAST_RIGHT_X"
        action_x="$(vertical_menu_next_x 2)"
        selected_row=$((menu_y + VERTICAL_MENU_LAST_VISIBLE_SELECTED + 1))

        if ((choice == 255 || choice >= ${#line_numbers[@]})); then
            return 0
        fi
        default_index="$choice"
        backup_crypto_object_actions \
            "${line_numbers[$choice]}" \
            "${users[$choice]}" \
            "${targets[$choice]}" \
            "${types[$choice]}" \
            "${policies[$choice]}" \
            "$selected_row" \
            "$menu_right_x" \
            "$action_x"
    done
}

declare -A CACHE_READY
declare -A CACHE_SITES
declare -A CACHE_SITE_SNAPSHOTS
declare -A CACHE_SNAPSHOT_META

progress_line_stderr() {
    local row="$1"
    local col="$2"
    local text="$3"
    printf '%s' "${ESC}[${row};${col}H" >&2
    printf '%b' "$text" >&2
    printf '%s' "${ESC}[K" >&2
}

ensure_remote_index() {
    local remote_name="$1"
    local status_row="${2:-}"
    local status_col="${3:-1}"
    local rel_path user_name rest_path date_dir file_name archive_base site_name site_cache_key site_prefix
    local ts_part date_part time_part label pair_key archive_kind encrypted has_sql snapshot_key complete is_completion_part completion_is_first
    local processed_files=0 progress_step=50
    local -a sorted_sites labels_for_site
    local -A seen_users seen_user_dates seen_sites seen_site_labels snapshot_meta
    local -A snapshot_user snapshot_date snapshot_site snapshot_ts snapshot_encrypted snapshot_has_tar snapshot_has_sql snapshot_complete

    if [ "${CACHE_READY[$remote_name]:-0}" = "1" ]; then
        return 0
    fi

    if [ -n "$status_row" ]; then
        progress_line_stderr "$status_row" "$status_col" "Сканирование ${YELLOW}${remote_name}${WHITE}: получение списка файлов..."
    fi

    while IFS= read -r rel_path; do
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
        if [ -n "$status_row" ] && (( processed_files == 1 || processed_files % progress_step == 0 )); then
            progress_line_stderr "$status_row" "$status_col" "Сканирование ${YELLOW}${remote_name}${WHITE}: обработано файлов ${YELLOW}${processed_files}${WHITE}, пользователей ${YELLOW}${#seen_users[@]}${WHITE}, дат ${YELLOW}${#seen_user_dates[@]}${WHITE}, найдено сайтов ${YELLOW}${#seen_sites[@]}${WHITE}"
        fi

        archive_kind="full"
        encrypted=0
        is_completion_part=0
        completion_is_first=0
        case "$file_name" in
            *.sql.gz.age-part-*.end)
                [[ "$file_name" == *-part-00.end ]] && completion_is_first=1
                archive_base="${file_name%.end}"
                archive_base="${archive_base%.sql.gz.age-part-*}"
                archive_kind="sql"
                encrypted=1
                is_completion_part=1
                ;;
            *.tar.gz.age-part-*.end)
                [[ "$file_name" == *-part-00.end ]] && completion_is_first=1
                archive_base="${file_name%.end}"
                archive_base="${archive_base%.tar.gz.age-part-*}"
                encrypted=1
                is_completion_part=1
                ;;
            *.sql.gz-part-*.end)
                [[ "$file_name" == *-part-00.end ]] && completion_is_first=1
                archive_base="${file_name%.end}"
                archive_base="${archive_base%.sql.gz-part-*}"
                archive_kind="sql"
                is_completion_part=1
                ;;
            *.tar.gz-part-*.end)
                [[ "$file_name" == *-part-00.end ]] && completion_is_first=1
                archive_base="${file_name%.end}"
                archive_base="${archive_base%.tar.gz-part-*}"
                is_completion_part=1
                ;;
            *.sql.gz.age-part-00)
                archive_base="${file_name%.sql.gz.age-part-00}"
                archive_kind="sql"
                encrypted=1
                ;;
            *.tar.gz.age-part-00)
                archive_base="${file_name%.tar.gz.age-part-00}"
                encrypted=1
                ;;
            *.sql.gz-part-00)
                archive_base="${file_name%.sql.gz-part-00}"
                archive_kind="sql"
                ;;
            *.tar.gz-part-00)
                archive_base="${file_name%.tar.gz-part-00}"
                ;;
            *)
                continue
                ;;
        esac

        if [[ "$archive_base" =~ ^(.+)_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2})$ ]]; then
            site_name="${BASH_REMATCH[1]}"
            ts_part="${BASH_REMATCH[2]}"
        elif [[ -n "$archive_base" ]]; then
            site_name="$archive_base"
            date_part="$date_dir"
            if [[ "$date_part" =~ ^([0-9]{4})\.([0-9]{2})\.([0-9]{2})$ ]]; then
                date_part="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
            fi
            ts_part="${date_part}_00-00"
        else
            continue
        fi

        snapshot_key="${user_name}|${site_name}|${ts_part}|${encrypted}"
        if [[ "$is_completion_part" -eq 1 ]]; then
            snapshot_complete["$snapshot_key"]=1
            [[ "$completion_is_first" -eq 1 ]] || continue
        fi

        seen_sites["$user_name|$site_name"]=1
        snapshot_user["$snapshot_key"]="$user_name"
        snapshot_date["$snapshot_key"]="$date_dir"
        snapshot_site["$snapshot_key"]="$site_name"
        snapshot_ts["$snapshot_key"]="$ts_part"
        snapshot_encrypted["$snapshot_key"]="$encrypted"
        if [[ "$archive_kind" == "sql" ]]; then
            snapshot_has_sql["$snapshot_key"]=1
        else
            snapshot_has_tar["$snapshot_key"]=1
        fi
    done < <(
        rclone lsf -R --max-depth 3 --files-only \
            --include "*.tar.gz-part-00" \
            --include "*.sql.gz-part-00" \
            --include "*.tar.gz.age-part-00" \
            --include "*.sql.gz.age-part-00" \
            --include "*.tar.gz-part-*.end" \
            --include "*.sql.gz-part-*.end" \
            --include "*.tar.gz.age-part-*.end" \
            --include "*.sql.gz.age-part-*.end" \
            --fast-list "${remote_name}:${server}/" 2>/dev/null
    )
    if [ -n "$status_row" ]; then
        progress_line_stderr "$status_row" "$status_col" "Сканирование ${YELLOW}${remote_name}${WHITE} завершено: обработано файлов ${YELLOW}${processed_files}${WHITE}, пользователей ${YELLOW}${#seen_users[@]}${WHITE}, дат ${YELLOW}${#seen_user_dates[@]}${WHITE}, найдено сайтов ${YELLOW}${#seen_sites[@]}${WHITE}"
    fi

    for snapshot_key in "${!snapshot_site[@]}"; do
        site_name="${snapshot_site[$snapshot_key]}"
        ts_part="${snapshot_ts[$snapshot_key]}"
        encrypted="${snapshot_encrypted[$snapshot_key]}"
        has_sql="${snapshot_has_sql[$snapshot_key]:-0}"
        complete="${snapshot_complete[$snapshot_key]:-0}"
        date_part="${ts_part%%_*}"
        time_part="${ts_part##*_}"
        label="${date_part} ${time_part//-/:}"
        if [[ "${snapshot_has_tar[$snapshot_key]:-0}" == "1" ]]; then
            archive_kind="full"
        else
            archive_kind="sql"
            label="${label} [SQL]"
        fi
        if [[ "$encrypted" == "1" ]]; then
            label="${label} [шифр]"
        fi
        if [[ "$complete" == "1" ]]; then
            label="${label} [ok]"
        fi
        pair_key="${snapshot_user[$snapshot_key]}|${site_name}|${label}"
        if [ -z "${seen_site_labels[$pair_key]:-}" ]; then
            seen_site_labels["$pair_key"]=1
            snapshot_meta["$pair_key"]="${snapshot_user[$snapshot_key]};${snapshot_date[$snapshot_key]};${site_name};${ts_part};${archive_kind};${encrypted};${has_sql}"
        fi
    done

    CACHE_SITES["$remote_name"]=""
    if [ "${#seen_sites[@]}" -eq 0 ]; then
        CACHE_READY["$remote_name"]=1
        return 0
    fi

    mapfile -t sorted_sites < <(printf '%s\n' "${!seen_sites[@]}" | LC_ALL=C sort)
    CACHE_SITES["$remote_name"]="$(printf '%s\n' "${sorted_sites[@]}")"

    for site_cache_key in "${sorted_sites[@]}"; do
        user_name="${site_cache_key%%|*}"
        site_name="${site_cache_key#*|}"
        site_prefix="${user_name}|${site_name}|"
        mapfile -t labels_for_site < <(
            for pair_key in "${!seen_site_labels[@]}"; do
                if [[ "$pair_key" == "${site_prefix}"* ]]; then
                    printf '%s\n' "${pair_key#"${site_prefix}"}"
                fi
            done | sort -r
        )
        if [ "${#labels_for_site[@]}" -gt 0 ]; then
            CACHE_SITE_SNAPSHOTS["$remote_name|$user_name|$site_name"]="$(printf '%s\n' "${labels_for_site[@]}")"
            for label in "${labels_for_site[@]}"; do
                pair_key="${user_name}|${site_name}|${label}"
                CACHE_SNAPSHOT_META["$remote_name|$user_name|$site_name|$label"]="${snapshot_meta[$pair_key]}"
            done
        else
            CACHE_SITE_SNAPSHOTS["$remote_name|$user_name|$site_name"]=""
        fi
    done

    CACHE_READY["$remote_name"]=1
}

collect_sites_for_remote() {
    local remote_name="$1"
    local site_name user_name site_cache_key
    local sites_blob
    sites_blob="${CACHE_SITES[$remote_name]:-}"
    if [ -z "$sites_blob" ]; then
        return 0
    fi

    while IFS= read -r site_cache_key; do
        [ -z "$site_cache_key" ] && continue
        user_name="${site_cache_key%%|*}"
        site_name="${site_cache_key#*|}"
        printf '%s|%s\n' "$site_name" "$user_name"
    done <<< "$sites_blob"
}

collect_snapshots_for_site() {
    local remote_name="$1"
    local site_name="$2"
    local _user_name="$3"
    local key prefix label
    local -A seen_labels

    prefix="${remote_name}|${_user_name}|${site_name}|"
    for key in "${!CACHE_SNAPSHOT_META[@]}"; do
        if [[ "$key" == "${prefix}"* ]]; then
            label="${key#"${prefix}"}"
            [ -n "$label" ] && seen_labels["$label"]=1
        fi
    done

    if [ "${#seen_labels[@]}" -eq 0 ]; then
        return 0
    fi

    while IFS= read -r label; do
        [ -z "$label" ] && continue
        printf '%s|%s\n' "$label" "${CACHE_SNAPSHOT_META["$remote_name|$_user_name|$site_name|$label"]}"
    done < <(printf '%s\n' "${!seen_labels[@]}" | sort -r)
}

download_site_snapshot_archive() {
    local remote_name="$1"
    local user_name="$2"
    local date_dir="$3"
    local site_name="$4"
    local ts_part="$5"
    local status_row="$6"
    local archive_kind="${7:-full}"
    local encrypted="${8:-0}"
    local has_sql="${9:-0}"
    local tmp_dir target_dir archive_extension age_suffix archive_filename
    local legacy_filename="" sql_filename="" assembled_archive="" assembled_sql=""
    local target_archive="" target_sql="" staged_archive="" staged_sql=""
    local archive_combined=0
    local -a include_opts

    combine_downloaded_parts() {
        local source_prefix="$1"
        local output_file="$2"
        local part_file normal_part
        local end_count=0
        local -a all_part_files=() part_files=()
        local -A completed_parts=()

        shopt -s nullglob
        all_part_files=("${tmp_dir}/${source_prefix}-part-"*)
        shopt -u nullglob
        ((${#all_part_files[@]} > 0)) || return 1
        mapfile -t all_part_files < <(printf '%s\n' "${all_part_files[@]}" | LC_ALL=C sort)
        for part_file in "${all_part_files[@]}"; do
            if [[ "$part_file" == *.end ]]; then
                normal_part="${part_file%.end}"
                completed_parts["$normal_part"]=1
                end_count=$((end_count + 1))
            fi
        done
        ((end_count <= 1)) || return 1
        for part_file in "${all_part_files[@]}"; do
            if [[ "$part_file" != *.end && -n "${completed_parts[$part_file]+x}" ]]; then
                continue
            fi
            part_files+=("$part_file")
        done
        ((${#part_files[@]} > 0)) || return 1
        if ((end_count == 1)) && [[ "${part_files[$((${#part_files[@]} - 1))]}" != *.end ]]; then
            return 1
        fi
        rm -f -- "$output_file"
        if ! mv -- "${part_files[0]}" "$output_file"; then
            rm -f -- "$output_file"
            return 1
        fi
        for part_file in "${part_files[@]:1}"; do
            if ! cat -- "$part_file" >> "$output_file"; then
                rm -f -- "$output_file"
                return 1
            fi
            if ! rm -f -- "$part_file"; then
                rm -f -- "$output_file"
                return 1
            fi
        done
        [[ -s "$output_file" ]]
    }

    if [ "$archive_kind" = "sql" ]; then
        archive_extension=".sql.gz"
    else
        archive_extension=".tar.gz"
    fi
    if [[ "$encrypted" == "1" ]]; then
        age_suffix=".age"
    else
        age_suffix=""
    fi

    tmp_dir="$(mktemp -d)" || return 1
    target_dir="$(pwd)"
    archive_filename="${site_name}_${ts_part}${archive_extension}${age_suffix}"
    assembled_archive="${tmp_dir}/${archive_filename}"

    cursor_to "$status_row" 1
    printf '\033[K'
    echo -e "Загрузка архива в ${GREEN}${target_dir}/${archive_filename}${WHITE}"

    include_opts=(--include "${archive_filename}-part-*")
    if [ "$archive_kind" != "sql" ]; then
        legacy_filename="${site_name}.tar.gz${age_suffix}"
        include_opts+=(--include "${legacy_filename}-part-*")
        if [[ "$has_sql" == "1" ]]; then
            sql_filename="${site_name}_${ts_part}.sql.gz${age_suffix}"
            include_opts+=(--include "${sql_filename}-part-*")
        fi
    fi

    if ! rclone copy --progress --stats-one-line --stats=1s \
        "${remote_name}:${server}/${user_name}/${date_dir}/" "$tmp_dir/" \
        "${include_opts[@]}"; then
        printf '\033[1A\r\033[K'
        cursor_to "$status_row" 1
        printf '\033[K'
        echo -e "Не удалось ${LRED}скачать архив${WHITE} из удаленного хранилища."
        rm -rf "$tmp_dir"
        return 1
    fi
    printf '\033[1A\r\033[K'

    if combine_downloaded_parts "$archive_filename" "$assembled_archive"; then
        archive_combined=1
    else
        if [ "$archive_kind" != "sql" ]; then
            archive_filename="$legacy_filename"
            assembled_archive="${tmp_dir}/${archive_filename}"
            if combine_downloaded_parts "$archive_filename" "$assembled_archive"; then
                archive_combined=1
            fi
        fi
    fi
    if [[ "$archive_combined" -ne 1 || ! -s "$assembled_archive" ]]; then
        cursor_to "$status_row" 1
        printf '\033[K'
        echo -e "Не удалось ${LRED}найти или собрать части архива${WHITE} после скачивания."
        rm -rf "$tmp_dir"
        return 1
    fi

    if [[ "$archive_kind" != "sql" && "$has_sql" == "1" ]]; then
        assembled_sql="${tmp_dir}/${sql_filename}"
        if ! combine_downloaded_parts "$sql_filename" "$assembled_sql" || [[ ! -s "$assembled_sql" ]]; then
            cursor_to "$status_row" 1
            printf '\033[K'
            echo -e "Не удалось собрать ${LRED}соседний архив базы данных${WHITE}."
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    target_archive="${target_dir}/${archive_filename}"
    if [[ -d "$target_archive" ]]; then
        echo -e "Путь назначения ${LRED}${target_archive}${WHITE} занят каталогом."
        rm -rf "$tmp_dir"
        return 1
    fi
    if [[ -n "$assembled_sql" ]]; then
        target_sql="${target_dir}/${sql_filename}"
        if [[ -d "$target_sql" ]]; then
            echo -e "Путь назначения ${LRED}${target_sql}${WHITE} занят каталогом."
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    staged_archive="${target_dir}/.${archive_filename}.rish-download.$$"
    if ! mv -f -- "$assembled_archive" "$staged_archive"; then
        echo -e "Не удалось сохранить скачанный архив в ${LRED}${target_dir}${WHITE}."
        rm -rf "$tmp_dir"
        return 1
    fi
    if [[ -n "$assembled_sql" ]]; then
        staged_sql="${target_dir}/.${sql_filename}.rish-download.$$"
        if ! mv -f -- "$assembled_sql" "$staged_sql"; then
            rm -f -- "$staged_archive"
            rm -rf "$tmp_dir"
            echo -e "Не удалось сохранить соседний архив базы в ${LRED}${target_dir}${WHITE}."
            return 1
        fi
    fi

    if [[ -n "$staged_sql" ]] && ! mv -f -- "$staged_sql" "$target_sql"; then
        rm -f -- "$staged_archive" "$staged_sql"
        rm -rf "$tmp_dir"
        echo -e "Не удалось опубликовать архив базы ${LRED}${sql_filename}${WHITE}."
        return 1
    fi
    if ! mv -f -- "$staged_archive" "$target_archive"; then
        rm -f -- "$staged_archive"
        rm -rf "$tmp_dir"
        echo -e "Не удалось опубликовать архив ${LRED}${archive_filename}${WHITE}."
        return 1
    fi

    rm -rf "$tmp_dir"
    cursor_to "$status_row" 1
    printf '\033[K'
    echo -e "Архив ${GREEN}${archive_filename}${WHITE} загружен в ${GREEN}${target_dir}${WHITE}"
    if [[ -n "$sql_filename" && "$has_sql" == "1" ]]; then
        printf '\033[1A\r\033[K'
        echo -e "Архив ${GREEN}${archive_filename}${WHITE} и архив базы ${GREEN}${sql_filename}${WHITE}"
        echo -e "загружены в ${GREEN}${target_dir}${WHITE}"
    fi
    return 0
}

restore_backup_menu() {
    local menu_start_row status_header_row remote_choice remote_exit_index
    local selected_remote selected_site selected_snapshot site_owner
    local site_line site_index
    local site_name_from_line site_user_from_line
    local snapshot_line snapshot_label snapshot_meta_line
    local right_x right_y snapshot_x snapshot_y
    local snapshot_meta snapshot_user snapshot_date snapshot_site snapshot_ts snapshot_kind snapshot_encrypted snapshot_has_sql status_row
    local remote_menu_y remote_menu_h snapshot_menu_y snapshot_menu_h
    local site_menu_y site_menu_x site_menu_h site_menu_w site_menu_drawn
    local -a remotes remote_menu site_entries sites site_owners site_menu snapshot_entries snapshots snapshot_menu
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
        menu_start_row="$remote_menu_y"
        status_header_row=$((menu_start_row - 2))
        if [ "$status_header_row" -lt 1 ]; then
            status_header_row=1
        fi

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

            sites=()
            site_owners=()
            for site_line in "${site_entries[@]}"; do
                [ -z "$site_line" ] && continue
                site_name_from_line="${site_line%%|*}"
                site_user_from_line="${site_line#*|}"
                [ -z "$site_name_from_line" ] && continue
                sites+=("$site_name_from_line")
                site_owners+=("$site_user_from_line")
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
            for site_index in "${!sites[@]}"; do
                site_menu+=("${sites[$site_index]} (${site_owners[$site_index]})")
            done
            site_menu+=("Выход")

            vertical_menu "$right_y" "$right_x" 20 5 "default=0" "${site_menu[@]}"
            remote_choice=$?
            site_menu_y="$VERTICAL_MENU_LAST_Y"
            site_menu_x="$VERTICAL_MENU_LAST_X"
            site_menu_h="$VERTICAL_MENU_LAST_HEIGHT"
            site_menu_w="$VERTICAL_MENU_LAST_OUTER_WIDTH"
            right_y="$site_menu_y"
            remote_menu_y="$site_menu_y"
            menu_start_row="$remote_menu_y"
            status_header_row=$((menu_start_row - 2))
            if [ "$status_header_row" -lt 1 ]; then
                status_header_row=1
            fi
            site_menu_drawn=1
            if [ "$remote_choice" -eq 255 ] || [ "$remote_choice" -eq "${#sites[@]}" ]; then
                clear_last_vertical_menu
                site_menu_drawn=0
                break
            fi

            selected_site="${sites[$remote_choice]}"
            site_owner="${site_owners[$remote_choice]}"
            status_row=$((site_menu_y + site_menu_h + 1))
            if [ -z "$site_owner" ]; then
                cursor_to "$status_row" 1
                echo -e "${LRED}Не удалось определить пользователя для сайта ${selected_site}.${WHITE}"
                continue
            fi

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
            site_menu_y="$snapshot_menu_y"
            right_y="$snapshot_menu_y"
            remote_menu_y="$snapshot_menu_y"
            menu_start_row="$remote_menu_y"
            status_header_row=$((menu_start_row - 2))
            if [ "$status_header_row" -lt 1 ]; then
                status_header_row=1
            fi
            status_row=$((snapshot_menu_y + snapshot_menu_h + 1))
            clear_last_vertical_menu

            if [ "$remote_choice" -eq 255 ] || [ "$remote_choice" -eq "${#snapshots[@]}" ]; then
                continue
            fi

            selected_snapshot="${snapshots[$remote_choice]}"
            snapshot_meta="${snapshot_map[$selected_snapshot]}"
            IFS=';' read -r snapshot_user snapshot_date snapshot_site snapshot_ts snapshot_kind snapshot_encrypted snapshot_has_sql <<< "$snapshot_meta"
            if [ -z "$snapshot_user" ] || [ -z "$snapshot_date" ] || [ -z "$snapshot_site" ] || [ -z "$snapshot_ts" ]; then
                cursor_to "$status_row" 1
                echo -e "${LRED}Не удалось разобрать выбранную копию.${WHITE}"
                continue
            fi

            if [ "$site_menu_drawn" -eq 1 ]; then
                clear_menu_rect "$site_menu_y" "$site_menu_x" "$site_menu_h" "$site_menu_w"
                site_menu_drawn=0
            fi

            download_site_snapshot_archive "$selected_remote" "$snapshot_user" "$snapshot_date" "$snapshot_site" "$snapshot_ts" "$status_header_row" "$snapshot_kind" "$snapshot_encrypted" "$snapshot_has_sql"
        done

        cursor_to "$menu_start_row" 1
    done
}

if is_remote_configured
then
    echo
    echo -e "Конфигурационный файл настроен ${GREEN}корректно${WHITE}"
    echo -e "Подключение: ${GREEN}${rclone_remote}${WHITE}"
    echo -e "Папка бэкапов: ${GREEN}${server}${WHITE}"
else
    echo -e "Подключение по умолчанию не настроено (подключение ${LRED}'${rclone_remote}'${WHITE} не найдено в rclone)."
fi

if [ ! -f "$backupall2" ]
then
	echo
	echo -e "${LRED}Файл списка архивируемых объектов не найден:${WHITE} ${backupall2}"
	echo "┌───────────────────────────────────────────────────────────────────────────────────┐"
	echo "│ Первый запуск: перед началом работы выполните первичную настройку.                │"
	echo "│ 1) Создайте список сайтов и папок для резервного копирования:                     │"
	echo "│    \"Создать файл-список всех архивируемых объектов\"                               │"
	echo "│ 2) Настройте подключение (remote) к хранилищу бэкапов:                            │"
	echo "│    - для Яндекс.Диска: \"Создать/Обновить подключение яндекс-диска\"                │"
	echo "│    - для других хранилищ: \"Создать/Выбрать подключение по умолчанию\"              │"
	echo "└───────────────────────────────────────────────────────────────────────────────────┘"
	echo
else
	echo -e "Список объектов для архивации ${GREEN}найден${WHITE} (${backupall2})"
	if ! backup_crypto_available && awk -F';' 'tolower($6) ~ /^crypto:/{found=1} END{exit !found}' "$backupall2"; then
		echo -e "В списке есть зашифрованные бэкапы, но команда ${LRED}age не установлена${WHITE}."
	fi
fi
if crontab -l 2>/dev/null | grep -Eq '^[[:space:]]*[^#].*/root/rish/backup2\.sh[[:space:]]+auto([[:space:]]|$)'; then
    echo
    echo -e "Задание ${GREEN}/root/rish/backup2.sh auto${WHITE} найдено в CRON.${WHITE}"
    echo
else
    minute=$(shuf -i 0-59 -n 1)
    minute=$(printf "%02d" "$minute")
    hour=$(shuf -i 1-5 -n 1)
    echo
    echo "┌───────────────────────────────────────────────────────────────────────────────────┐"
    echo "│ Для автоматической ежедневной архивации вам нужно добавить скрипт в задания CRON. │"
    echo "│ Сделать это можно из меню MC (Управление CRON). Скопируйте команду:               │"
    echo "│ $minute $hour * * * /root/rish/backup2.sh auto >/dev/null 2>&1                             │"
    echo "└───────────────────────────────────────────────────────────────────────────────────┘"
    echo
fi
echo
while true
do
    local_has_list=0
    local_remote_ready=0
    menu_items=()
    menu_actions=()
    IFS=$' \t\n'

    if [ -f "$backupall2" ]; then
        local_has_list=1
    fi
    if is_remote_configured; then
        local_remote_ready=1
    fi

    if [ "$local_has_list" -eq 0 ]; then
        menu_items+=("Создать файл-список всех архивируемых объектов")
        menu_actions+=("create_list")
    else
        if [ "$local_remote_ready" -eq 1 ]; then
            menu_items+=("Архивация всех сайтов сервера" "Скачать копию из бекапа на сервер")
            menu_actions+=("backup_all" "restore")
        fi
        if backup_crypto_available; then
            menu_items+=("Управление шифрованием бэкапов")
            menu_actions+=("crypto")
        fi
        menu_items+=("Обновить файл-список всех архивируемых объектов" "Создать файл-список всех архивируемых объектов")
        menu_actions+=("update_list" "create_list")
    fi
    menu_items+=("Создать/Обновить подключение яндекс-диска" "Создать/Выбрать подключение по умолчанию")
    menu_actions+=("config_yandex" "select_remote")
    if [ "$local_remote_ready" -eq 1 ]; then
        menu_items+=("О подключении по умолчанию ${rclone_remote}")
        menu_actions+=("remote_info")
    fi
    menu_items+=("Выйти")
    menu_actions+=("exit")

    menu_default=$((${#menu_items[@]} - 1))
    vertical_menu "current" 2 0 5 "default=${menu_default}" "${menu_items[@]}"
    choice=$?
    if ((choice == 255 || choice >= ${#menu_actions[@]})); then
        break
    fi
    case "${menu_actions[$choice]}" in
        backup_all) backupall ;;
        restore) restore_backup_menu ;;
        crypto) backup_crypto_management_menu ;;
        update_list) updatelist ;;
        create_list) createlist ;;
        config_yandex) configcnf ;;
        select_remote) select_default_remote ;;
        remote_info) remote_info ;;
        exit) break ;;
    esac
done
