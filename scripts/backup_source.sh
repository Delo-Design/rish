#!/bin/bash

site_backup_group_gid() {
    local user="$1" uid="$2" site_gid="$3" allow_empty="${4:-0}"
    local entry gid members apache_groups
    entry="$(getent group "rish-backup-$uid")" || return 1
    IFS=: read -r _ _ gid members <<< "$entry"
    [[ "$gid" =~ ^[1-9][0-9]*$ && "$gid" != "$site_gid" ]] || return 1
    [[ "$members" == "$user" || ( "$allow_empty" == 1 && -z "$members" ) ]] || return 1

    apache_groups="$(id -G -- apache)" || return 1
    [[ " $apache_groups " != *" $gid "* ]] || return 1
    printf '%s\n' "$gid"
}

# Выполняется в подоболочке архиватора: tar читает открытый рабочий каталог.
backup_source_enter_user() {
    local base="$1" path="$2" resolved
    if [[ "$(/usr/bin/realpath -e -- "$base")" != "$base" ]] ||
       ! resolved="$(/usr/bin/realpath -e -- "$path")" ||
       [[ "$resolved" != "$base/"* || "$resolved" == "$base/backups" || "$resolved" == "$base/backups/"* ]] ||
       [[ "$path" == "$resolved/"* ]] ||
       ! backup_source_enter_resolved "$resolved"; then
        printf 'Не удалось открыть каталог %s в пределах %s. Проверьте ссылку на релиз.\n' "$path" "$base" >&2
        return 1
    fi
}

backup_source_enter_resolved() {
    local resolved="$1" opened
    cd -P -- "$resolved" &&
        opened="$(/usr/bin/readlink -- /proc/self/cwd)" &&
        [[ "$opened" == "$resolved" ]]
}

backup_source_tar_transform() {
    local name="$1"
    name=${name//\\/\\\\}
    name=${name//&/'\&'}
    name=${name//|/'\|'}
    # Преобразуем имена записей и жёстких ссылок, сохраняя текст симлинков.
    printf 'flags=rh;s|^\\./|%s/|;s|^\\.$|%s/|' "$name" "$name"
}
