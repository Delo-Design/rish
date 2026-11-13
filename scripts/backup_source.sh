#!/bin/bash

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
