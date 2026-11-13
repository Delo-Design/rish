#!/bin/bash

# Загружается обработчиком заявок RISH после проверки каталогов сайта.

cloud_root_file() {
    local path="$1" mode
    [[ -f "$path" && ! -L "$path" ]] || return 1
    path="$(realpath -e -- "$path")" || return 1
    local canonical="$path"
    while [[ "$path" != / ]]; do
        if [[ ! -O "$path" ]] || ! mode="$(stat -c %a -- "$path")" ||
           [[ ! "$mode" =~ ^[0-7]{1,4}$ ]]; then
            return 1
        fi
        if ((8#$mode & 022)) && { [[ ! -d "$path" ]] || ! ((8#$mode & 01000)); }; then
            return 1
        fi
        path="${path%/*}"
        path="${path:-/}"
    done
    printf '%s\n' "$canonical"
}

cloud_storage_path() {
    local backupall2="$RISH_DIR/backup_list_all" server=backup_server rclone_remote=ydisk
    local config="$RISH_DIR/rish_config.sh" row remote available

    if [[ -e "$config" || -L "$config" ]]; then
        config="$(cloud_root_file "$config")" || return 1
        # shellcheck disable=SC1090
        source "$config" >&2 || return 1
    fi
    backupall2="${backupall2:-$RISH_DIR/backup_list_all}"
    server="${server:-backup_server}"
    rclone_remote="${rclone_remote:-ydisk}"
    if ! backupall2="$(cloud_root_file "$backupall2")"; then
        printf '%s\n' 'Список объектов бэкапа должен быть доступен на запись только root.' >&2
        return 1
    fi

    # SITE_NAME and the other site settings are set by scripts/joomla_backup.sh.
    # shellcheck disable=SC2153
    if ! row="$(awk -F';' -v user="$SITE_USER" -v site="$SITE_NAME" -v db="$DATABASE" '
        ($1 "") == (user "") && ($2 "") == (site "") {
            count++
            if ((NF == 6 || NF == 7) && $3 == "site" && ($4 "") == (db "")) {
                found = 1
                remote = $5
            }
        }
        END {
            if (count != 1 || !found) exit 1
            print remote
        }
    ' "$backupall2")"; then
        printf '%s\n' 'Не найдена единственная запись сайта и базы в списке объектов бэкапа.' >&2
        return 1
    fi

    remote="${row%%[[:space:]]*}"
    remote="${remote:-$rclone_remote}"
    if ! available="$(timeout -k 2s 5s rclone listremotes </dev/null)"; then
        return 1
    fi
    if ! grep -Fxq -- "$remote:" <<< "$available"; then
        remote="$rclone_remote"
    fi
    if [[ -z "$remote" || "$remote" == *[:/]* || "$remote" == *[$'\n\r']* ||
          "$server" == /* || "$server" == *[$'\n\r']* ||
          "/$server/" == */../* || "/$server/" == */./* ]] ||
       ! grep -Fxq -- "$remote:" <<< "$available"; then
        printf '%s\n' 'Проверьте подключение и каталог хранилища бэкапов RISH.' >&2
        return 1
    fi
    printf '%s\n' "$remote:$server/$SITE_USER"
}

cloud_list_remote() {
    local seconds="$1" depth="$2" path="$3" output="$4" prefix="$5" result=0
    shift 5
    (ulimit -f 16384 && timeout -k 2s "${seconds}s" rclone lsf --max-depth "$depth" \
        --contimeout 4s --timeout 6s --retries 1 --low-level-retries 1 --files-only --format sp --separator ';' \
        --include "/$prefix${SITE_NAME}_*.tar.gz*-part-*" --include "/$prefix${SITE_NAME}_*.sql.gz*-part-*" \
        --include "/$prefix${SITE_NAME}.tar.gz*-part-*" --include "/$prefix${SITE_NAME}.sql.gz*-part-*" \
        --include "/$prefix${SITE_NAME}_*.tar.gz*.rish-origin.txt" --include "/$prefix${SITE_NAME}.tar.gz*.rish-origin.txt" \
        "$@" -- "$path/" </dev/null) > "$output" || result=$?
    # Пока для пользователя нет ни одной копии, самого каталога может ещё не быть.
    if ((result == 3)); then
        : > "$output"
    else
        return "$result"
    fi
}

cloud_manifests() {
    local listing="$1" scratch="$2" tar_name="$3" sql_name="$4"
    rish_restore_build_manifest "$listing" "$tar_name" "$scratch/tar.parts" 1 &&
        rish_restore_build_manifest "$listing" "$sql_name" "$scratch/sql.parts" 0
}

cloud_snapshot_id() {
    local path="$1" scratch="$2" timestamp="$3" digest
    digest="$(
        { printf '%s\n' "$path" "$SITE_NAME" "$DATABASE" "$timestamp" &&
          cat -- "$scratch/tar.parts" "$scratch/sql.parts"; } | sha256sum
    )" || return 1
    printf '%s\n' "${digest%% *}"
}

# 2 означает неподтверждённое происхождение; 1 — ошибку чтения хранилища.
cloud_verify_origin() {
    local seconds="$1" path="$2" scratch="$3" listing="$4" tar_name="$5" sql_name="$6"
    local sidecar="$tar_name.rish-origin.txt" size tar_count sql_count

    tar_count="$(wc -l < "$scratch/tar.parts")" || return 1
    sql_count="$(wc -l < "$scratch/sql.parts")" || return 1
    printf 'rish-site-root-only-v2\n%s;%s;%s\n%s;%s\n%s;%s\n' \
        "$SITE_USER" "$SITE_NAME" "$DATABASE" "$tar_name" "$sql_name" \
        "${tar_count//[[:space:]]/}" "${sql_count//[[:space:]]/}" > "$scratch/origin.expected" || return 1
    size="$(wc -c < "$scratch/origin.expected")" || return 1
    size="${size//[[:space:]]/}"
    if ! awk -F';' -v sidecar="$sidecar" -v size="$size" '
        ($2 "") == (sidecar "") { count++; actual = $1 }
        END { exit (count != 1 || (actual "") != (size "")) }
    ' "$listing"; then
        return 2
    fi
    if ! (ulimit -f 4 && timeout -k 2s "${seconds}s" rclone cat --max-depth 1 \
        --contimeout 4s --timeout 6s --retries 1 --low-level-retries 1 \
        -- "$path/$sidecar" </dev/null) > "$scratch/origin.actual"; then
        return 1
    fi
    if ! cmp -s -- "$scratch/origin.expected" "$scratch/origin.actual"; then
        return 2
    fi
}

cloud_snapshot_candidates() {
    local listing="$1" day="$2"
    local time_pattern='[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])_([01][0-9]|2[0-3])-[0-5][0-9](-[0-5][0-9]-[0-9]{9})?'
    local age_pattern='(\.age)?'
    local name remainder timestamp
    while IFS=';' read -r _ name; do
        if [[ "$name" == "$SITE_NAME"_* ]]; then
            remainder="${name#"$SITE_NAME"_}"
            if [[ "$remainder" =~ ^($time_pattern)\.tar\.gz$age_pattern-part-[0-9]+\.end$ ]]; then
                timestamp="${BASH_REMATCH[1]}"
                printf '%s;%s;%s;%s_%s.sql.gz%s\n' "$timestamp" "$day" "${name%-part-*}" \
                    "$SITE_NAME" "$timestamp" "${BASH_REMATCH[6]}"
            fi
        elif [[ "$name" == "$SITE_NAME".tar.gz* ]]; then
            remainder="${name#"$SITE_NAME"}"
            if [[ "$remainder" =~ ^\.tar\.gz$age_pattern-part-[0-9]+\.end$ ]]; then
                timestamp="${day//./-}_00-00"
                printf '%s;%s;%s;%s_%s.sql.gz%s\n' "$timestamp" "$day" "${name%-part-*}" \
                    "$SITE_NAME" "$timestamp" "${BASH_REMATCH[1]}"
            fi
        fi
    done < "$listing"
}

cloud_sort_candidates() {
    local scratch="$1" path origin_index
    mkdir -- "$scratch/days" || return 1
    origin_index="$scratch/origins"
    : > "$origin_index" || return 1
    awk -F'[;/]' -v out="$scratch/days" -v origins="$origin_index" '
        NF == 3 && $1 ~ /^[0-9]+$/ &&
        $2 ~ /^[0-9][0-9][0-9][0-9]\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])$/ {
            file = out "/" $2
            if (previous != file && previous != "") close(previous)
            print $1 ";" $3 >> file
            if ($3 ~ /\.rish-origin\.txt$/) print $2 ";" $3 >> origins
            previous = file
        }
    ' "$scratch/listing" || return 1
    for path in "$scratch/days/"*; do
        [[ -f "$path" ]] || continue
        cloud_snapshot_candidates "$path" "${path##*/}" || return 1
    done > "$scratch/day-candidates"

    # После первых десяти копий проверяем только кандидатов без файла происхождения.
    awk -F';' '
        FILENAME == ARGV[1] { origins[$1 SUBSEP $2]++; next }
        { print $0 ";" (origins[$2 SUBSEP ($3 ".rish-origin.txt")] != 1 ? "legacy" : "marked") }
    ' "$origin_index" "$scratch/day-candidates"
}

cloud_refresh() (
    set -o pipefail
    local base scratch output day timestamp tar_name sql_name encrypted snapshot size time date listing candidate
    local count=0 deadline budget origin legacy=false
    # shellcheck source=scripts/backup_restore.sh
    source "$RISH_DIR/scripts/backup_restore.sh" || return 1
    base="$(cloud_storage_path)" || return 1
    scratch="$(mktemp -d -- "$WORK_DIR/cloud-list.XXXXXXXX")" || return 1
    output=""
    trap 'rm -rf -- "$scratch"; [[ -z "$output" ]] || rm -f -- "$output"' EXIT
    trap 'exit 1' HUP INT TERM

    deadline=$((SECONDS + 65))
    cloud_list_remote 40 2 "$base" "$scratch/listing" '????.??.??/' -R || return 1
    cloud_sort_candidates "$scratch" | sort -ru -t ';' -k1,1 -k2,2 -k3,3 > "$scratch/candidates" ||
        return 1
    : > "$scratch/rows" || return 1
    while IFS=';' read -r timestamp day tar_name sql_name candidate; do
        if ((SECONDS >= deadline)); then
            printf '%s\n' 'Превышено время ожидания списка бэкапов RISH.' >&2
            return 1
        fi
        listing="$scratch/days/$day"
        if ((count >= 10)) && [[ "$legacy" == true ]]; then
            break
        fi
        if ((count >= 10)) && [[ "$candidate" != legacy ]]; then
            continue
        fi
        cloud_manifests "$listing" "$scratch" "$tar_name" "$sql_name" || continue
        if [[ "$candidate" == legacy ]]; then
            legacy=true
            ((count < 10)) || break
            continue
        fi
        budget=$((deadline - SECONDS))
        ((budget > 0)) || return 1
        ((budget <= 8)) || budget=8
        origin=0
        cloud_verify_origin "$budget" "$base/$day" "$scratch" "$listing" "$tar_name" "$sql_name" || origin=$?
        case "$origin" in
            0) ;;
            2) legacy=true; continue ;;
            *) return 1 ;;
        esac

        snapshot="$(cloud_snapshot_id "$base/$day" "$scratch" "$timestamp")" || return 1
        size="$(awk -F';' '{ size += $1 } END { printf "%.0f", size }' \
            "$scratch/tar.parts" "$scratch/sql.parts")" || return 1
        [[ "$size" =~ ^[1-9][0-9]{0,15}$ ]] || return 1
        encrypted=false
        [[ "$tar_name" != *.age ]] || encrypted=true
        date="${timestamp%_*}"
        time="${timestamp#*_}"
        time="${time//-/:}"
        [[ "${#time}" != 5 ]] || time="$time:00"
        printf '%s;%s %s;%s;%s;%s;%s;%s;%s\n' "$snapshot" "$date" "${time:0:8}" \
            "$size" "$encrypted" "$day" "$timestamp" "$tar_name" "$sql_name" \
            >> "$scratch/rows" || return 1
        count=$((count + 1))
    done < "$scratch/candidates"

    output="$(mktemp -- "$STATUS_DIR/.cloud-catalog.XXXXXXXX")" || return 1
    jq -Rn --argjson updated_at "$(date +%s)" --argjson legacy "$legacy" '
        {schema: 2, updated_at: $updated_at, legacy: $legacy, snapshots: [
            inputs | split(";") |
            {id: .[0], created_at: .[1], size: (.[2] | tonumber), encrypted: (.[3] == "true"),
             day: .[4], timestamp: .[5], tar: .[6], sql: .[7]}
        ]}
    ' < "$scratch/rows" > "$output" &&
        chgrp -- "$SITE_GID" "$output" && chmod 0640 -- "$output" &&
        mv -fT -- "$output" "$STATUS_DIR/cloud-catalog.json"
)

cloud_staged_blocks() {
    local blocks part_size
    blocks="$(free_export_blocks)" || return 1
    part_size="$(awk -F';' '$1 + 0 > max + 0 { max = $1 } END { print max }' "$1")" || return 1
    [[ "$part_size" =~ ^[1-9][0-9]{0,17}$ ]] || return 1
    # The reader holds one downloaded part on disk while the combined file grows.
    blocks=$((blocks - (part_size + 1023) / 1024))
    if ((blocks <= 0)); then
        printf '%s\n' 'Недостаточно места для временной части бэкапа.' >&2
        return 1
    fi
    printf '%s\n' "$blocks"
}

cloud_read_archive() (
    set -o pipefail
    local source="$1" scratch="$2" tar_name="$3" sql_name="$4" blocks
    # The reader inherits this limit in the current import only.
    # shellcheck disable=SC2030
    local RISH_RESTORE_RESERVE_BYTES="$DISK_RESERVE"
    local -a tar_cmd=(/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/tar)

    if [[ "$tar_name" == *.age ]]; then
        # Шифротекст остаётся в исходном формате age, ключ серверу не нужен.
        blocks="$(cloud_staged_blocks "$scratch/tar.parts")" || return 1
        rish_restore_read_parts "$scratch/tar.parts" "$source" "$scratch" |
            (ulimit -f "$blocks" && cat) > "$scratch/$tar_name" || return 1
        blocks="$(cloud_staged_blocks "$scratch/sql.parts")" || return 1
        rish_restore_read_parts "$scratch/sql.parts" "$source" "$scratch" |
            (ulimit -f "$blocks" && cat) > "$scratch/$sql_name" || return 1
        blocks="$(free_export_blocks)" || return 1
        (ulimit -f "$blocks" && "${tar_cmd[@]}" -czf "$scratch/archive" -C "$scratch" \
            -- "$tar_name" "$sql_name")
        return "$?"
    fi

    blocks="$(cloud_staged_blocks "$scratch/tar.parts")" || return 1
    if ! rish_restore_read_parts "$scratch/tar.parts" "$source" "$scratch" |
        (ulimit -f "$blocks" && gzip -dc) > "$scratch/site.tar"; then
        return 1
    fi
    # Проверяем имена без извлечения архива. Дамп добавляется отдельным файлом.
    if ! "${tar_cmd[@]}" --list --ignore-zeros --quoting-style=escape -f "$scratch/site.tar" |
        awk -v site="$SITE_NAME" '
            {
                name = $0
                sub(/^\.\//, "", name)
                if ((name != site && index(name, site "/") != 1) ||
                    name ~ /(^|\/)\.\.?(\/|$)/) bad = 1
                count++
            }
            END { exit (bad || count == 0) }
        '; then
        printf '%s\n' 'В архиве есть файлы за пределами ожидаемого каталога сайта или архив повреждён.' >&2
        return 1
    fi

    blocks="$(cloud_staged_blocks "$scratch/sql.parts")" || return 1
    rish_restore_read_parts "$scratch/sql.parts" "$source" "$scratch" |
        (ulimit -f "$blocks" && cat) > "$scratch/$SITE_NAME.sql.gz" || return 1
    gzip -t -- "$scratch/$SITE_NAME.sql.gz" || return 1
    local sql_size
    sql_size="$(stat -c %s -- "$scratch/$SITE_NAME.sql.gz")" || return 1
    blocks="$(free_export_blocks)" || return 1
    if ((sql_size + 1048576 > blocks * 1024)); then
        printf '%s\n' 'Недостаточно места для добавления базы в архив.' >&2
        return 1
    fi
    "${tar_cmd[@]}" -rf "$scratch/site.tar" -C "$scratch" -- "$SITE_NAME.sql.gz" || return 1
    rm -f -- "$scratch/$SITE_NAME.sql.gz" || return 1
    blocks="$(free_export_blocks)" || return 1
    (ulimit -f "$blocks" && gzip -c -- "$scratch/site.tar") > "$scratch/archive"
)

cloud_import() (
    set -o pipefail
    local id="$1" base scratch record day timestamp tar_name sql_name archive archive_id previous lock_fd
    local catalog="$STATUS_DIR/cloud-catalog.json"
    # shellcheck source=scripts/backup_restore.sh
    source "$RISH_DIR/scripts/backup_restore.sh" || return 1
    [[ "$id" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ -f "$catalog" && ! -L "$catalog" && "$(stat -c '%u:%g:%a' -- "$catalog")" == "0:$SITE_GID:640" ]] ||
        return 1
    if ! record="$(jq -er --arg id "$id" '
        select(.schema == 2) | [.snapshots[] | select(.id == $id)] | select(length == 1) |
        .[0] | [.day, .timestamp, .tar, .sql] | select(all(.[]; type == "string" and length > 0)) | join(";")
    ' "$catalog")"; then
        printf '%s\n' 'Копия отсутствует в последнем списке хранилища RISH.' >&2
        return 1
    fi
    IFS=';' read -r day timestamp tar_name sql_name <<< "$record"
    base="$(cloud_storage_path)" || return 1
    scratch="$(mktemp -d -- "$DOWNLOADS/.export.XXXXXXXX")" || return 1
    trap 'rm -rf -- "$scratch"' EXIT
    trap 'exit 1' HUP INT TERM
    [[ ! -L "$BACKUP_LOCK" && ( ! -e "$BACKUP_LOCK" || -f "$BACKUP_LOCK" ) ]] || return 1
    exec {lock_fd}>>"$BACKUP_LOCK" || return 1
    flock -w 300 -E 75 "$lock_fd" || return "$?"
    if ! cloud_list_remote 12 1 "$base/$day" "$scratch/parts" '' ||
       ! cloud_manifests "$scratch/parts" "$scratch" "$tar_name" "$sql_name" ||
       ! cloud_verify_origin 8 "$base/$day" "$scratch" "$scratch/parts" "$tar_name" "$sql_name" ||
       ! previous="$(cloud_snapshot_id "$base/$day" "$scratch" "$timestamp")" ||
       [[ "$previous" != "$id" ]]; then
        printf '%s\n' 'Копия в хранилище изменилась. Обновите список и выберите её заново.' >&2
        return 1
    fi

    if [[ -f "$WORK_DIR/cloud-import.$id" && ! -L "$WORK_DIR/cloud-import.$id" ]] &&
       IFS= read -r archive < "$WORK_DIR/cloud-import.$id" &&
       [[ "$archive" == "$SITE_NAME"_*.tar.gz ]]; then
        archive_id="${archive#"$SITE_NAME"_}"
        if valid_archive_id "${archive_id%.tar.gz}" &&
           [[ ! -L "$DOWNLOADS/$archive" && -f "$DOWNLOADS/$archive" && -s "$DOWNLOADS/$archive" &&
              "$(stat -c '%u:%g:%a' -- "$DOWNLOADS/$archive")" == "0:$SITE_GID:640" ]]; then
            printf '%s\n' "$archive"
            return 0
        fi
    fi
    archive_id="$(date +%Y-%m-%d_%H-%M-%S-%N)" && valid_archive_id "$archive_id" || return 1
    archive="${SITE_NAME}_$archive_id.tar.gz"
    cloud_read_archive "$base/$day" "$scratch" "$tar_name" "$sql_name" || return 1
    printf '%s\n' "$archive" > "$scratch/import" &&
        mv -fT -- "$scratch/import" "$WORK_DIR/cloud-import.$id" &&
        chgrp -- "$SITE_GID" "$scratch/archive" && chmod 0640 -- "$scratch/archive" &&
        mv -nT -- "$scratch/archive" "$DOWNLOADS/$archive" && [[ ! -e "$scratch/archive" ]] ||
        return 1
    printf '%s\n' "$archive"
)
