#!/bin/bash

umask 077
export LC_ALL=C

RISH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
SITE_ROOT=/var/www
SYSTEMD_DIR=/etc/systemd/system
BACKUP_LOCK=/run/lock/rish-backup.lock
DISK_RESERVE=536870912
REQUEST_COOLDOWN=60

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

site_paths() {
    SITE_USER="$1"
    SITE_NAME="$2"
    [[ "$SITE_USER" =~ ^[a-z_][a-z0-9_-]*$ &&
       "$SITE_NAME" =~ ^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] ||
        fail 'Некорректное имя пользователя или сайта.'
    if ! SITE_UID="$(id -u -- "$SITE_USER")" || [[ "$SITE_UID" == 0 ]]; then
        fail 'Нужен отдельный Unix-пользователь сайта.'
    fi
    SITE_GID="$(id -g -- "$SITE_USER")" || fail 'Не удалось определить группу сайта.'
    SITE_PARENT="$SITE_ROOT/$SITE_USER/www"
    USER_BACKUPS="$SITE_ROOT/$SITE_USER/backups"
    JOB_DIR="$USER_BACKUPS/$SITE_NAME"
    INBOX="$JOB_DIR/inbox"
    STATUS_DIR="$JOB_DIR/status"
    DOWNLOADS="$JOB_DIR/downloads"
    WORK_DIR="$JOB_DIR/.work"
}

trusted_directory() {
    [[ -d "$1" && "$(realpath -e -- "$1")" == "$1" &&
       "$(stat -c '%u:%g:%a' -- "$1")" == "0:$2:$3" ]]
}

prepare_directory() {
    local path="$1" gid="$2" mode="$3"
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        if ! mkdir -m 0700 -- "$path" || ! chgrp -- "$gid" "$path" || ! chmod -- "$mode" "$path"; then
            fail "Не удалось создать $path."
        fi
    fi
    trusted_directory "$path" "$gid" "$mode" || fail "Проверьте владельца и права каталога $path."
}

check_user_directory() {
    if ! trusted_directory "$SITE_ROOT" 0 751 ||
       ! trusted_directory "$SITE_ROOT/$SITE_USER" "$SITE_GID" 750; then
        fail 'Ожидаются штатные права RISH на /var/www и каталог пользователя.'
    fi
}

valid_database() {
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_\$.-]{0,63}$ ]]
}

open_site_source() {
    # shellcheck source=scripts/backup_source.sh
    source "$RISH_DIR/scripts/backup_source.sh" || return 1
    backup_source_enter_user "$SITE_ROOT/$SITE_USER" "$SITE_PARENT/$SITE_NAME"
}

stop_legacy_timer() {
    if [[ -e "$SYSTEMD_DIR/rish-joomla-backup@.timer" ]]; then
        systemctl disable --now "rish-joomla-backup@$1.timer"
    fi
}

publish_schedule() {
    local cron state=not_configured temporary checked_at
    if ! cron="$(crontab -l -u root 2>&1)"; then
        [[ "$cron" == 'no crontab for root' ]] || state=unknown
        cron=
    fi

    checked_at="$(date +%s)" || return 1
    temporary="$(mktemp -- "$STATUS_DIR/.schedule.XXXXXXXX")" || return 1
    if ! (
        set -o pipefail
        awk '
            function unquote(value) {
                if (value ~ /^"[^"]*"$/ || value ~ /^\047[^\047]*\047$/)
                    return substr(value, 2, length(value) - 2)
                return value
            }
            /^[[:space:]]*($|#)/ { next }
            /^[[:space:]]*CRON_TZ[[:space:]]*=/ {
                zone = $0
                sub(/^[^=]*=[[:space:]]*/, "", zone)
                sub(/[[:space:]]*$/, "", zone)
                zone = unquote(zone)
                if (zone !~ /^[[:alnum:]_.+\/-]+$/) zone = ""
                next
            }
            /^[[:space:]]*[[:alpha:]_][[:alnum:]_]*[[:space:]]*=/ { next }
            {
                if ($1 ~ /^@(reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)$/) {
                    expression = $1
                    field = 2
                } else if (NF >= 6) {
                    expression = $1 " " $2 " " $3 " " $4 " " $5
                    field = 6
                } else next
                if (unquote($field) ~ /^(\/(usr\/)?bin\/)?(ba)?sh$/) {
                    field++
                    if ($field == "--") field++
                }
                command = $field
                sub(/[<>].*$/, "", command)
                if (unquote(command) == "/root/rish/backup2.sh") print expression "\t" zone
            }
        ' <<< "$cron" | jq -Rn --arg state "$state" --argjson checked_at "$checked_at" '
            [inputs | split("\t") | {expression: .[0]} +
                (if .[1] == "" then {} else {timezone: .[1]} end)] as $jobs |
            {state: (if $jobs == [] then $state else "configured" end), jobs: $jobs, checked_at: $checked_at}
        ' > "$temporary"
    ) || ! chgrp -- "$SITE_GID" "$temporary" || ! chmod 0640 -- "$temporary" ||
       ! mv -fT -- "$temporary" "$STATUS_DIR/schedule.json"; then
        rm -f -- "$temporary"
        return 1
    fi
}

prepare_cloud_fetch_lock() {
    local path="$JOB_DIR/cloud-fetch.lock" temporary
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        temporary="$(mktemp -- "$WORK_DIR/cloud-fetch-lock.XXXXXXXX")" || return 1
        if ! chgrp -- "$SITE_GID" "$temporary" || ! chmod 0640 -- "$temporary" ||
           ! mv -nT -- "$temporary" "$path"; then
            rm -f -- "$temporary"
            return 1
        fi
        rm -f -- "$temporary"
    fi
    [[ -f "$path" && ! -L "$path" && "$(stat -c '%u:%g:%a' -- "$path")" == "0:$SITE_GID:640" ]]
}

rollback_activation() {
    local unit="$1" active="$2" enabled="$3" activation_started="$4" inbox_was_open="$5"
    local path_unit="rish-joomla-backup@$unit.path"

    if ((activation_started)); then
        if ((!active)); then
            systemctl stop "$path_unit" "rish-joomla-backup@$unit.service" || :
        fi
        if ((!enabled)); then
            systemctl disable "$path_unit" || :
        fi
        if ((active)) && ! systemctl is-active --quiet "$path_unit"; then
            if ! systemctl start "$path_unit" || ! systemctl is-active --quiet "$path_unit"; then
                printf '%s\n' 'Не удалось восстановить наблюдатель заявок. Приём заявок закрыт.' >&2
                return 1
            fi
        fi
    fi

    if ((inbox_was_open)) && ! chmod 0730 -- "$INBOX"; then
        printf '%s\n' 'Не удалось восстановить права каталога приёма заявок.' >&2
        return 1
    fi
}

enable_site() (
    local database="$3" unit template temporary active=0 enabled=0
    local activation_started=0 inbox_was_open=0
    site_paths "$1" "$2"
    valid_database "$database" || fail 'Некорректное имя базы данных.'
    check_user_directory
    (open_site_source) || fail 'Не удалось открыть каталог сайта в пределах каталога пользователя.'
    unit="$(systemd-escape --path -- "$JOB_DIR")" || fail 'Не удалось определить имя службы.'

    prepare_directory "$USER_BACKUPS" "$SITE_GID" 750
    prepare_directory "$JOB_DIR" "$SITE_GID" 750
    prepare_directory "$STATUS_DIR" "$SITE_GID" 750
    prepare_directory "$DOWNLOADS" "$SITE_GID" 750
    prepare_directory "$WORK_DIR" 0 700
    systemctl is-active --quiet "rish-joomla-backup@$unit.path" && active=1
    systemctl is-enabled --quiet "rish-joomla-backup@$unit.path" && enabled=1
    trap 'rollback_activation "$unit" "$active" "$enabled" "$activation_started" "$inbox_was_open"' EXIT
    trap 'exit 1' HUP INT TERM
    if trusted_directory "$INBOX" "$SITE_GID" 730; then
        inbox_was_open=1
        chmod 0710 -- "$INBOX" || fail 'Не удалось временно закрыть приём заявок.'
    fi
    prepare_directory "$INBOX" "$SITE_GID" 710
    temporary="$(mktemp -- "$WORK_DIR/database.XXXXXXXX")" || fail 'Не удалось создать настройку БД.'
    if ! printf '%s\n' "$database" > "$temporary" ||
       ! mv -fT -- "$temporary" "$JOB_DIR/database"; then
        rm -f -- "$temporary"
        fail 'Не удалось сохранить настройку БД.'
    fi
    publish_schedule || fail 'Не удалось опубликовать расписание бэкапов.'
    prepare_cloud_fetch_lock || fail 'Не удалось подготовить блокировку запросов скачивания.'
    temporary="$(mktemp -- "$WORK_DIR/cloud-enabled.XXXXXXXX")" || fail 'Не удалось подготовить доступ к хранилищу.'
    if ! chgrp -- "$SITE_GID" "$temporary" || ! chmod 0640 -- "$temporary" ||
       ! mv -fT -- "$temporary" "$JOB_DIR/cloud-enabled"; then
        rm -f -- "$temporary"
        fail 'Не удалось сохранить настройку доступа к хранилищу.'
    fi
    for template in path service; do
        install -o root -g root -m 0644 -- \
            "$RISH_DIR/templates/systemd/rish-joomla-backup@.$template" \
            "$SYSTEMD_DIR/rish-joomla-backup@.$template" || fail 'Не удалось установить шаблоны systemd.'
    done
    if ! stop_legacy_timer "$unit" || ! systemctl daemon-reload; then
        fail 'Не удалось загрузить шаблоны systemd.'
    fi
    activation_started=1
    if ! systemctl enable "rish-joomla-backup@$unit.path" ||
       ! systemctl restart "rish-joomla-backup@$unit.path" ||
       ! systemctl is-active --quiet "rish-joomla-backup@$unit.path" ||
       ! chmod 0730 -- "$INBOX"; then
        fail 'Не удалось включить бэкапы из админки сайта.'
    fi
    trap - EXIT HUP INT TERM
    printf 'Каталог заданий для настройки интеграции: %s\n' "$JOB_DIR"
)

disable_site() {
    local unit path_unit service_unit load_state
    site_paths "$1" "$2"
    check_user_directory
    if ! trusted_directory "$USER_BACKUPS" "$SITE_GID" 750 ||
       ! trusted_directory "$JOB_DIR" "$SITE_GID" 750; then
        fail 'Каталог заданий не найден или имеет некорректные права.'
    fi
    unit="$(systemd-escape --path -- "$JOB_DIR")" || fail 'Не удалось определить имя службы.'
    if trusted_directory "$INBOX" "$SITE_GID" 730; then
        chmod 0710 -- "$INBOX" || fail 'Не удалось закрыть приём заявок.'
    fi
    stop_legacy_timer "$unit" || fail 'Не удалось остановить прежний таймер бэкапов.'
    path_unit="rish-joomla-backup@$unit.path"
    service_unit="rish-joomla-backup@$unit.service"
    load_state="$(systemctl show -p LoadState --value "$path_unit")" || [[ "$load_state" == not-found ]] ||
        fail 'Не удалось проверить наблюдатель заявок.'
    if [[ "$load_state" != not-found ]]; then
        systemctl disable --now "$path_unit" || fail 'Не удалось остановить наблюдатель заявок.'
    fi
    load_state="$(systemctl show -p LoadState --value "$service_unit")" || [[ "$load_state" == not-found ]] ||
        fail 'Не удалось проверить службу бэкапов.'
    if [[ "$load_state" != not-found ]]; then
        systemctl stop "$service_unit" || fail 'Не удалось остановить службу бэкапов.'
    fi
    cancel_pending_requests || fail 'Не удалось очистить очередь бэкапов.'
}

write_status() {
    local action="$1" state="$2" message="$3" archive="${4:-}" snapshot_id="${5:-}" next_at="${6:-}"
    local now temporary size fields=""
    now="$(date +%s)" || return 1
    if [[ -n "$archive" ]]; then
        size="$(stat -c '%s' -- "$DOWNLOADS/$archive")" || return 1
        printf -v fields ',"archive":"%s","size":%s' "$archive" "$size"
    fi
    if [[ -n "$snapshot_id" ]]; then
        [[ "$snapshot_id" =~ ^[a-f0-9]{64}$ ]] || return 1
        printf -v fields '%s,"snapshot_id":"%s"' "$fields" "$snapshot_id"
    fi
    if [[ -n "$next_at" ]]; then
        [[ "$next_at" =~ ^[1-9][0-9]*$ ]] || return 1
        printf -v fields '%s,"next_at":%s' "$fields" "$next_at"
    fi
    temporary="$(mktemp -- "$STATUS_DIR/.$action.XXXXXXXX")" || return 1
    if ! printf '{"state":"%s","updated_at":%s,"message":"%s"%s}\n' \
            "$state" "$now" "$message" "$fields" > "$temporary" ||
       ! chgrp -- "$SITE_GID" "$temporary" || ! chmod 0640 -- "$temporary" ||
       ! mv -fT -- "$temporary" "$STATUS_DIR/$action.json"; then
        rm -f -- "$temporary"
        return 1
    fi
}

discard_claim() {
    local claim="$1" quarantine
    if [[ -d "$claim" && ! -L "$claim" ]]; then
        quarantine="$(mktemp -d -- "$WORK_DIR/rejected.XXXXXXXX")" || return 1
        mv -T -- "$claim" "$quarantine/request" || return 1
        printf 'Недопустимый каталог заявки перемещён в %s\n' "$quarantine" >&2
    else
        rm -f -- "$claim"
    fi
}

cancel_pending_requests() (
    shopt -s nullglob
    local directory claim action
    if [[ -e "$WORK_DIR" || -L "$WORK_DIR" ]]; then
        trusted_directory "$WORK_DIR" 0 700 || return 1
    fi
    if [[ -e "$INBOX" || -L "$INBOX" ]]; then
        trusted_directory "$INBOX" "$SITE_GID" 710 || return 1
    fi
    if [[ -e "$STATUS_DIR" || -L "$STATUS_DIR" ]]; then
        trusted_directory "$STATUS_DIR" "$SITE_GID" 750 || return 1
        for action in backup export cloud-list cloud-fetch delete; do
            if grep -Fq '"state":"running"' "$STATUS_DIR/$action.json" 2>/dev/null; then
                write_status "$action" failed 'Задание прервано при отключении бэкапов.' || return 1
            fi
        done
    fi
    for directory in "$INBOX" "$WORK_DIR"; do
        for claim in "$directory"/{backup.request,export.request,cloud-list.request,cloud-fetch.*.request,delete.*.request,backup.request.duplicate,export.request.duplicate}; do
            if [[ -e "$claim" || -L "$claim" ]]; then
                discard_claim "$claim" || return 1
            fi
        done
    done
)

valid_claim() {
    [[ ! -L "$1" && -f "$1" && ! -s "$1" && "$(stat -c %u -- "$1")" == "$SITE_UID" ]]
}

read_site_database() {
    [[ -f "$JOB_DIR/database" && ! -L "$JOB_DIR/database" &&
       "$(stat -c '%u:%g:%a' -- "$JOB_DIR/database")" == 0:0:600 ]] &&
        IFS= read -r DATABASE < "$JOB_DIR/database" && valid_database "$DATABASE"
}

valid_archive_id() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{9}$ ]]
}

free_export_blocks() {
    local available
    available="$(df -B1 --output=avail -- "$DOWNLOADS" | awk 'NR == 2 {print $1}')" || return 1
    if [[ ! "$available" =~ ^[0-9]+$ ]] || ((available <= DISK_RESERVE)); then
        printf 'Для экспорта нужно сохранить резерв 512 МиБ на диске.\n' >&2
        return 1
    fi
    printf '%s\n' "$(((available - DISK_RESERVE) / 1024))"
}

make_export() (
    set -o pipefail
    local temporary archive_id archive blocks lock_fd
    [[ ! -L "$BACKUP_LOCK" && ( ! -e "$BACKUP_LOCK" || -f "$BACKUP_LOCK" ) ]] || return 1
    exec {lock_fd}>>"$BACKUP_LOCK" || return 1
    flock -w 300 -E 75 "$lock_fd" || return "$?"
    (open_site_source) || return 1
    temporary="$(mktemp -d -- "$DOWNLOADS/.export.XXXXXXXX")" || return 1
    trap 'rm -rf -- "$temporary"' EXIT
    trap 'exit 1' HUP INT TERM
    archive_id="$(date +%Y-%m-%d_%H-%M-%S-%N)" && valid_archive_id "$archive_id" || return 1
    archive="${SITE_NAME}_$archive_id.tar.gz"

    blocks="$(free_export_blocks)" || return 1
    if ! (ulimit -f "$blocks" && mariadb-dump --single-transaction --quick --routines \
            --events --triggers --hex-blob "$DATABASE" | gzip -c) > "$temporary/$SITE_NAME.sql.gz"; then
        return 1
    fi
    blocks="$(free_export_blocks)" || return 1
    if ! (
        ulimit -f "$blocks" || exit 1
        if ! open_site_source; then
            printf 'Не удалось открыть проверенный каталог сайта %s.\n' "$SITE_NAME" >&2
            exit 1
        fi
        # Преобразуем имена файлов и жёстких ссылок, сохраняя цели симлинков.
        /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C /usr/bin/tar -cf - \
            --transform="flags=rh;s|^\\./|$SITE_NAME/|;s|^\\.$|$SITE_NAME/|" \
            . -C "$temporary" -- "$SITE_NAME.sql.gz" {worker_lock}>&- {lock_fd}>&- |
            /usr/bin/gzip -c
    ) > "$temporary/archive"; then
        return 1
    fi
    if ! chgrp -- "$SITE_GID" "$temporary/archive" || ! chmod 0640 -- "$temporary/archive" ||
       ! mv -nT -- "$temporary/archive" "$DOWNLOADS/$archive" || [[ -e "$temporary/archive" ]]; then
        return 1
    fi
    printf '%s\n' "$archive"
)

report_joomla_backup_progress() {
    write_status backup running "$1"
}

backup_to_storage() (
    local attempt result
    export STATUS_DIR SITE_GID
    export -f write_status report_joomla_backup_progress
    for ((attempt = 0; attempt < 20; attempt++)); do
        result=0
        /bin/bash "$RISH_DIR/backup2.sh" --joomla-site "$SITE_USER" "$SITE_NAME" "$DATABASE" \
            {worker_lock}>&- || result=$?
        [[ "$result" == 75 ]] || return "$result"
        sleep 15
    done
    return 75
)

process_request() {
    local action="$1" archive="" result=0 now last=0 next_at message DATABASE
    local marker="$INBOX/$1.request" claim="$WORK_DIR/$1.request" stamp="$WORK_DIR/$1.stamp"
    if [[ -e "$claim" || -L "$claim" ]]; then
        if grep -Fq '"state":"running"' "$STATUS_DIR/$action.json" 2>/dev/null; then
            write_status "$action" failed 'Задание прервано. Запустите его заново.' || return 1
        fi
        discard_claim "$claim" || return 1
    fi
    [[ -e "$marker" || -L "$marker" ]] || return 0
    mv -T -- "$marker" "$claim" || return 0
    if ! valid_claim "$claim"; then
        write_status "$action" failed 'Получен недопустимый файл запроса.' || return 1
        discard_claim "$claim"
        return "$?"
    fi
    if ! read_site_database; then
        write_status "$action" failed 'Нужна действующая настройка базы данных.' || return 1
        discard_claim "$claim"
        return "$?"
    fi

    now="$(date +%s)" || return 1
    if [[ -f "$stamp" ]]; then
        last="$(stat -c %Y -- "$stamp")" || return 1
    fi
    if ((now - last < REQUEST_COOLDOWN)); then
        next_at=$((last + REQUEST_COOLDOWN))
        write_status "$action" failed 'Повторите запрос после окончания паузы.' "" "" "$next_at" || return 1
        discard_claim "$claim"
        return "$?"
    fi
    write_status "$action" running 'Задание выполняется.' || return 1
    if [[ "$action" == backup ]]; then
        backup_to_storage || result=$?
    else
        archive="$(make_export)" || result=$?
    fi
    if [[ -e "$marker" || -L "$marker" ]]; then
        mv -T -- "$marker" "$claim.duplicate" && discard_claim "$claim.duplicate"
    fi
    now="$(date +%s)" || return 1
    next_at=$((now + REQUEST_COOLDOWN))
    touch -d "@$now" -- "$stamp" || return 1
    if [[ "$result" == 75 ]]; then
        write_status "$action" failed 'Система занята другим бэкапом. Повторите позже.' "" "" "$next_at" || return 1
    elif ((result != 0)); then
        message='Не удалось завершить копирование. Подробности в журнале RISH.'
        if [[ "$action" == backup ]]; then
            # Коды этапов возвращает backup2.sh в режиме --joomla-site.
            case "$result" in
                20) message='Не удалось подготовить дамп базы данных. Подробности в журнале RISH.' ;;
                21) message='Не удалось создать архив файлов сайта. Подробности в журнале RISH.' ;;
                22) message='Файлы сайта изменились во время архивации. Повторите бэкап.' ;;
                23) message='Не удалось выгрузить или подтвердить копию в хранилище. Подробности в журнале RISH.' ;;
                24) message='База данных сайта недоступна. Проверьте её настройки в RISH.' ;;
                130|143) message='Задание прервано. Запустите его заново.' ;;
            esac
        fi
        write_status "$action" failed "$message" "" "" "$next_at" || return 1
    elif [[ "$action" == backup ]]; then
        write_status "$action" ready 'Копия сайта и базы сохранена в хранилище.' "" "" "$next_at" || return 1
    else
        write_status "$action" ready 'Архив создан.' "$archive" "" "$next_at" || return 1
    fi
    discard_claim "$claim"
}

process_delete_claim() {
    local claim="$1" name archive_id archive
    name="${claim##*/}"
    archive_id="${name#delete.}"
    archive_id="${archive_id%.request}"
    if ! valid_archive_id "$archive_id" || ! valid_claim "$claim"; then
        write_status delete failed 'Получен недопустимый запрос на удаление.' || return 1
    else
        archive="$DOWNLOADS/${SITE_NAME}_$archive_id.tar.gz"
        write_status delete running 'Архив удаляется.' || return 1
        if [[ -L "$archive" || ( -e "$archive" && ( ! -f "$archive" || ! -O "$archive" ) ) ]] ||
           ! rm -f -- "$archive"; then
            printf 'Не удалось удалить архив %s.\n' "$archive" >&2
            write_status delete failed 'Не удалось удалить архив. Подробности в журнале RISH.' || return 1
        else
            write_status delete ready 'Архив удалён.' || return 1
        fi
    fi
    discard_claim "$claim"
}

process_delete_requests() (
    shopt -s nullglob
    local marker claim
    # Оставшаяся после сбоя заявка безопасно повторяется под блокировкой сайта.
    for claim in "$WORK_DIR"/delete.*.request; do
        process_delete_claim "$claim" || return 1
    done
    for marker in "$INBOX"/delete.*.request; do
        claim="$WORK_DIR/${marker##*/}"
        if mv -T -- "$marker" "$claim"; then
            process_delete_claim "$claim" || return 1
        fi
    done
)

process_cloud_claim() (
    local marker="$1" action="$2" snapshot_id="${3:-}" claim archive archive_id stamp now last=0 next_at message DATABASE
    local fetch_lock result=0
    claim="$WORK_DIR/${marker##*/}"
    stamp="$WORK_DIR/$action.stamp"

    if [[ "$action" == cloud-fetch ]]; then
        prepare_cloud_fetch_lock || return 1
        exec {fetch_lock}<"$JOB_DIR/cloud-fetch.lock" || return 1
        flock -w 3 -- "$fetch_lock" || return 1
    fi
    mv -T -- "$marker" "$claim" || return 0
    if ! valid_claim "$claim" ||
       [[ "$action" == cloud-fetch && ! "$snapshot_id" =~ ^[a-f0-9]{64}$ ]]; then
        discard_claim "$claim"
        return "$?"
    fi

    if [[ ! -f "$JOB_DIR/cloud-enabled" || -L "$JOB_DIR/cloud-enabled" || -s "$JOB_DIR/cloud-enabled" ||
          "$(stat -c '%u:%g:%a' -- "$JOB_DIR/cloud-enabled")" != "0:$SITE_GID:640" ]]; then
        discard_claim "$claim"
        return "$?"
    fi

    now="$(date +%s)" || return 1
    if [[ -f "$stamp" ]]; then
        last="$(stat -c %Y -- "$stamp")" || return 1
    fi
    if ((now - last < REQUEST_COOLDOWN)); then
        next_at=$((last + REQUEST_COOLDOWN))
        write_status "$action" failed 'Повторите запрос после окончания паузы.' "" "$snapshot_id" "$next_at" || return 1
        discard_claim "$claim"
        return "$?"
    fi

    next_at=$((now + REQUEST_COOLDOWN))
    message='Получаем список бэкапов из хранилища.'
    if [[ "$action" == cloud-fetch ]]; then
        message='Скачиваем бэкап на сервер.'
    fi
    touch -d "@$now" -- "$stamp" || return 1
    write_status "$action" running "$message" "" "$snapshot_id" "$next_at" || return 1
    if [[ "$action" == cloud-fetch ]]; then
        exec {fetch_lock}<&-
    fi
    if ! read_site_database; then
        write_status "$action" failed 'Нужна действующая настройка базы данных.' "" "$snapshot_id" "$next_at" || return 1
        discard_claim "$claim"
        return "$?"
    fi

    # shellcheck source=scripts/site_backup_cloud.sh
    if ! source "$RISH_DIR/scripts/site_backup_cloud.sh"; then
        write_status "$action" failed 'Не удалось загрузить обработчик хранилища RISH.' "" "$snapshot_id" "$next_at" || return 1
        discard_claim "$claim"
        return "$?"
    fi
    if [[ "$action" == cloud-list ]]; then
        if cloud_refresh; then
            write_status "$action" ready 'Список бэкапов обновлён.' "" "" "$next_at" || return 1
        else
            write_status "$action" failed 'Не удалось обновить список бэкапов. Подробности в журнале RISH.' "" "" "$next_at" || return 1
        fi
    else
        archive="$(cloud_import "$snapshot_id")" || result=$?
        if ((result == 0)) && [[ "$archive" == "$SITE_NAME"_*.tar.gz ]]; then
            archive_id="${archive#"$SITE_NAME"_}"
            if valid_archive_id "${archive_id%.tar.gz}"; then
                write_status "$action" ready 'Копия сохранена в локальных бэкапах.' "$archive" "$snapshot_id" "$next_at" || return 1
                discard_claim "$claim"
                return "$?"
            fi
        fi
        message='Не удалось скачать бэкап на сервер. Обновите список и проверьте журнал RISH.'
        if ((result == 75)); then
            message='Система занята другим бэкапом. Повторите позже.'
        fi
        write_status "$action" failed "$message" "" "$snapshot_id" "$next_at" || return 1
    fi
    discard_claim "$claim"
)

process_cloud_requests() (
    shopt -s nullglob
    local claim marker name id

    for claim in "$WORK_DIR"/cloud-list.request "$WORK_DIR"/cloud-fetch.*.request; do
        [[ -e "$claim" || -L "$claim" ]] || continue
        name="${claim##*/}"
        if [[ "$name" == cloud-list.request ]]; then
            if grep -Fq '"state":"running"' "$STATUS_DIR/cloud-list.json" 2>/dev/null; then
                write_status cloud-list failed 'Обновление списка было прервано. Повторите запрос.' || return 1
            fi
        else
            id="${name#cloud-fetch.}"
            id="${id%.request}"
            if [[ "$id" =~ ^[a-f0-9]{64}$ ]] &&
               grep -Eq '"state":"running".*"snapshot_id":"'"$id"'"' "$STATUS_DIR/cloud-fetch.json" 2>/dev/null; then
                write_status cloud-fetch failed 'Скачивание было прервано. Повторите запрос.' "" "$id" || return 1
            fi
        fi
        discard_claim "$claim" || return 1
    done

    marker="$INBOX/cloud-list.request"
    if [[ -e "$marker" || -L "$marker" ]]; then
        process_cloud_claim "$marker" cloud-list || return 1
    fi
    for marker in "$INBOX"/cloud-fetch.*.request; do
        name="${marker##*/}"
        id="${name#cloud-fetch.}"
        id="${id%.request}"
        process_cloud_claim "$marker" cloud-fetch "$id" || return 1
    done
)

run_site() {
    local path="$1" worker_lock status=0
    [[ "$path" == "$SITE_ROOT/"* ]] || fail 'Некорректный каталог заданий.'
    local relative="${path#"$SITE_ROOT/"}"
    site_paths "${relative%%/*}" "${relative##*/}"
    [[ "$path" == "$JOB_DIR" ]] || fail 'Некорректный каталог заданий.'
    check_user_directory
    if ! trusted_directory "$USER_BACKUPS" "$SITE_GID" 750 ||
       ! trusted_directory "$JOB_DIR" "$SITE_GID" 750 ||
       { ! trusted_directory "$INBOX" "$SITE_GID" 730 && ! trusted_directory "$INBOX" "$SITE_GID" 710; } ||
       ! trusted_directory "$STATUS_DIR" "$SITE_GID" 750 ||
       ! trusted_directory "$DOWNLOADS" "$SITE_GID" 750 ||
       ! trusted_directory "$WORK_DIR" 0 700; then
        fail 'Небезопасные права каталога заданий.'
    fi
    [[ "$(stat -c %d -- "$INBOX")" == "$(stat -c %d -- "$WORK_DIR")" ]] ||
        fail 'Каталоги приёма и обработки заявок должны находиться на одной файловой системе.'
    exec {worker_lock}>>"$WORK_DIR/worker.lock" || return 1
    flock -n -E 75 "$worker_lock" || return "$?"
    if ! publish_schedule; then
        printf '%s\n' 'Не удалось обновить расписание бэкапов.' >&2
        status=1
    fi
    find "$JOB_DIR" "$DOWNLOADS" -mindepth 1 -maxdepth 1 -type d -uid 0 -name '.export.????????' \
        -exec rm -rf -- {} + || status=1
    process_delete_requests || status=1
    process_request backup || status=1
    process_request export || status=1
    process_cloud_requests || status=1
    return "$status"
}

((EUID == 0)) || fail 'Команда предназначена для администратора сервера.'
case "${1:-}:$#" in
    enable:4) enable_site "$2" "$3" "$4" ;;
    disable:3) disable_site "$2" "$3" ;;
    run:2) run_site "$2" ;;
    *)
        printf 'Использование: %s enable <пользователь> <сайт> <база>\n' "${0##*/}" >&2
        printf '               %s disable <пользователь> <сайт>\n' "${0##*/}" >&2
        exit 2
        ;;
esac
