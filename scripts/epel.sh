#!/usr/bin/env bash
# shellcheck disable=SC2016

_rish_epel_repository_max_minor() {
    local os_major="$1"
    shift

    local package_releases
    local package_release
    local repository_id
    local max_minor=-1
    local -a repository_options=()

    if (($# == 0)); then
        echo "Не переданы репозитории EPEL для проверки." >&2
        return 1
    fi

    for repository_id in "$@"; do
        repository_options+=("--enablerepo=${repository_id}")
    done

    if ! package_releases="$(
        dnf -q --refresh \
            --disablerepo='*' \
            "${repository_options[@]}" \
            repoquery --available --qf '%{release}' 2>&1
    )"; then
        echo "$package_releases" >&2
        return 1
    fi

    while IFS= read -r package_release; do
        if [[ "$package_release" =~ \.el${os_major}_([0-9]+) ]] &&
            ((10#${BASH_REMATCH[1]} > max_minor)); then
            max_minor=$((10#${BASH_REMATCH[1]}))
        fi
    done <<<"$package_releases"

    if ((max_minor < 0)); then
        echo "Не удалось определить минорную версию пакетов в репозитории EPEL." >&2
        return 1
    fi

    printf '%s\n' "$max_minor"
}

_rish_epel_repository_section_content() {
    awk '
        FNR == 1 {
            in_epel_repository = 0
        }

        /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
            repository_id = $0
            sub(/^[[:space:]]*\[/, "", repository_id)
            sub(/\][[:space:]]*$/, "", repository_id)
            in_epel_repository = repository_id == "epel" || repository_id ~ /^epel-/
        }

        in_epel_repository && $0 !~ /^[[:space:]]*#/ {
            print
        }
    ' "$@"
}

_rish_epel_prepare_repository_file() {
    local source_file="$1"
    local prepared_file="$2"

    awk '
        function replace_literal(text, search, replacement, position) {
            while ((position = index(text, search)) > 0) {
                text = substr(text, 1, position - 1) replacement \
                    substr(text, position + length(search))
            }
            return text
        }

        function replace_epel_paths(text, found, replacement) {
            while (match(text, /\/epel\/(testing\/)?([0-9]+s|[0-9]+(\.[0-9]+)?)\/Everything\//)) {
                found = substr(text, RSTART, RLENGTH)
                if (found ~ /^\/epel\/testing\//) {
                    replacement = "/epel/testing/${releasever_major}.${releasever_minor}/Everything/"
                } else {
                    replacement = "/epel/${releasever_major}.${releasever_minor}/Everything/"
                }
                text = substr(text, 1, RSTART - 1) replacement \
                    substr(text, RSTART + RLENGTH)
            }
            return text
        }

        function replace_epel_metalinks(text, found) {
            while (match(text, /repo=epel(-testing)?(-debug|-source)?-([0-9]+s|[0-9]+(\.[0-9]+)?)/)) {
                found = substr(text, RSTART, RLENGTH)
                sub(/([0-9]+s|[0-9]+(\.[0-9]+)?)$/, \
                    "${releasever_major}.${releasever_minor}", found)
                text = substr(text, 1, RSTART - 1) found \
                    substr(text, RSTART + RLENGTH)
            }
            return text
        }

        function replace_legacy_epel_metalinks(text) {
            text = replace_literal(text, "repo=epel${releasever_minor:+-z}-$releasever", "repo=epel-${releasever_major}.${releasever_minor}")
            text = replace_literal(text, "repo=epel${releasever_minor:+-z}-debug-$releasever", "repo=epel-debug-${releasever_major}.${releasever_minor}")
            text = replace_literal(text, "repo=epel${releasever_minor:+-z}-source-$releasever", "repo=epel-source-${releasever_major}.${releasever_minor}")
            text = replace_literal(text, "repo=epel${releasever_minor:+-z}-testing-$releasever", "repo=epel-testing-${releasever_major}.${releasever_minor}")
            text = replace_literal(text, "repo=epel${releasever_minor:+-z}-testing-debug-$releasever", "repo=epel-testing-debug-${releasever_major}.${releasever_minor}")
            text = replace_literal(text, "repo=epel${releasever_minor:+-z}-testing-source-$releasever", "repo=epel-testing-source-${releasever_major}.${releasever_minor}")
            return text
        }

        {
            line = $0
            if (line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
                repository_id = line
                sub(/^[[:space:]]*\[/, "", repository_id)
                sub(/\][[:space:]]*$/, "", repository_id)
                in_epel_repository = repository_id == "epel" || repository_id ~ /^epel-/
            }

            if (in_epel_repository) {
                line = replace_literal(line, "$releasever${stream:+s}", "${releasever_major}.${releasever_minor}")
                line = replace_literal(line, "$releasever${releasever_minor:+z}", "${releasever_major}.${releasever_minor}")
                line = replace_epel_paths(line)
                line = replace_legacy_epel_metalinks(line)
                line = replace_epel_metalinks(line)
            }

            print line
        }
    ' "$source_file" >"$prepared_file"
}

_rish_epel_restore_repository_files() {
    local -n repository_files_ref="$1"
    local -n backup_files_ref="$2"
    local index
    local restore_status=0

    for ((index = 0; index < ${#repository_files_ref[@]}; index++)); do
        if ! cp -a -- "${backup_files_ref[$index]}" "${repository_files_ref[$index]}"; then
            restore_status=1
        fi
    done

    dnf -q --disablerepo='*' --enablerepo=epel clean metadata >/dev/null 2>&1 || true
    return "$restore_status"
}

rish_ensure_epel_minor_compatibility() {
    local os_release_data
    local os_id
    local os_id_like
    local os_name
    local os_pretty_name
    local os_variant_id
    local os_version_id
    local os_major
    local os_minor
    local os_minor_text
    local expected_version
    local current_branch="не закреплена за минорной версией ОС"
    local epel_repository_config
    local epel_main_section_found=0
    local epel_main_enabled=0
    local epel_stream_branch_detected=0
    local enabled_repositories_output
    local repository_id
    local repository_file
    local prepared_file
    local backup_file
    local backup_dir=""
    local backup_timestamp
    local package_max_minor
    local validation_status
    local index
    local applied_count=0
    local -a os_release_fields=()
    local -a enabled_epel_repository_ids=()
    local -a epel_repository_files=()
    local -a changed_repository_files=()
    local -a prepared_repository_files=()
    local -a backup_repository_files=()

    if [[ ! -r /etc/os-release ]]; then
        echo "Не удалось проверить EPEL: файл /etc/os-release недоступен." >&2
        return 1
    fi

    os_release_data="$(
        # shellcheck source=/dev/null
        source /etc/os-release
        printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
            "${ID:-}" \
            "${ID_LIKE:-}" \
            "${NAME:-}" \
            "${PRETTY_NAME:-}" \
            "${VARIANT_ID:-}" \
            "${VERSION_ID:-}"
    )"
    mapfile -t os_release_fields <<<"$os_release_data"
    os_id="${os_release_fields[0]:-}"
    os_id_like="${os_release_fields[1]:-}"
    os_name="${os_release_fields[2]:-}"
    os_pretty_name="${os_release_fields[3]:-}"
    os_variant_id="${os_release_fields[4]:-}"
    os_version_id="${os_release_fields[5]:-}"

    if [[ "$os_id" == "fedora" ]]; then
        return 0
    fi
    if [[ " $os_id_like " != *" rhel "* && "$os_id" != "rhel" ]]; then
        return 0
    fi
    if [[ "$os_variant_id" == "stream" || "$os_pretty_name" == *"Stream"* ||
        "$os_pretty_name" == *"Kitten"* ]]; then
        return 0
    fi
    if [[ ! "$os_version_id" =~ ^([0-9]+)(\.([0-9]+))? ]]; then
        echo "Не удалось определить версию EL из VERSION_ID=${os_version_id:-не задан}." >&2
        return 1
    fi

    os_major=$((10#${BASH_REMATCH[1]}))
    os_minor_text="${BASH_REMATCH[3]:-}"
    if ((os_major != 10)); then
        return 0
    fi
    if [[ -z "$os_minor_text" ]]; then
        echo "Не удалось определить минорную версию EL из VERSION_ID=${os_version_id}." >&2
        return 1
    fi
    os_minor=$((10#$os_minor_text))
    expected_version="${os_major}.${os_minor}"

    if ! enabled_repositories_output="$(dnf -q repolist --enabled 2>&1)"; then
        echo "$enabled_repositories_output" >&2
        echo "Не удалось получить список включённых репозиториев DNF." >&2
        return 1
    fi

    while IFS= read -r repository_id; do
        [[ "$repository_id" =~ ^epel($|-) ]] || continue
        enabled_epel_repository_ids+=("$repository_id")
        if [[ "$repository_id" == "epel" ]]; then
            epel_main_enabled=1
        fi
    done < <(awk '{print $1}' <<<"$enabled_repositories_output")

    if ((epel_main_enabled == 0)); then
        echo "Репозиторий EPEL не найден или не включён." >&2
        return 1
    fi

    while IFS= read -r -d '' repository_file; do
        if [[ ! -f "$repository_file" && ! -L "$repository_file" ]]; then
            continue
        fi
        if ! grep -qE '^[[:space:]]*\[epel(-[^]]+)?\][[:space:]]*$' "$repository_file"; then
            continue
        fi
        if [[ -L "$repository_file" || ! -f "$repository_file" ]]; then
            echo "Небезопасный тип файла репозитория EPEL: $repository_file" >&2
            return 1
        fi
        epel_repository_files+=("$repository_file")
        if grep -qE '^[[:space:]]*\[epel\][[:space:]]*$' "$repository_file"; then
            epel_main_section_found=1
        fi
    done < <(find /etc/yum.repos.d -maxdepth 1 -name '*.repo' -print0)

    if ((${#epel_repository_files[@]} == 0)) || ((epel_main_section_found == 0)); then
        echo "Не найден файл с секцией [epel] в /etc/yum.repos.d." >&2
        return 1
    fi

    if ! epel_repository_config="$(_rish_epel_repository_section_content "${epel_repository_files[@]}")"; then
        echo "Не удалось прочитать секции EPEL в /etc/yum.repos.d." >&2
        return 1
    fi

    if grep -qF '$releasever${stream:+s}' <<<"$epel_repository_config" &&
        [[ -s /etc/dnf/vars/stream ]]; then
        current_branch="${os_major}s"
        epel_stream_branch_detected=1
    elif grep -qE "/epel/(testing/)?${os_major}s/" <<<"$epel_repository_config" ||
        grep -qE "repo=epel(-testing)?(-debug|-source)?-${os_major}s([&[:space:]]|$)" <<<"$epel_repository_config"; then
        current_branch="${os_major}s"
        epel_stream_branch_detected=1
    elif grep -qE "/epel/(testing/)?${expected_version//./\.}/" <<<"$epel_repository_config"; then
        current_branch="$expected_version"
    fi

    package_max_minor="$(_rish_epel_repository_max_minor "$os_major" "${enabled_epel_repository_ids[@]}")"
    validation_status=$?
    if ((validation_status != 0)) || [[ ! "$package_max_minor" =~ ^[0-9]+$ ]]; then
        echo "Не удалось определить фактическую ветку подключённого репозитория EPEL." >&2
        echo "Конфигурация EPEL оставлена без изменений." >&2
        return 1
    fi

    if ((package_max_minor <= os_minor && epel_stream_branch_detected == 0)); then
        echo -e "EPEL не содержит пакетов новее установленной ОС: максимум ${GREEN}EL ${os_major}.${package_max_minor}${WHITE}, установлена ${GREEN}EL ${expected_version}${WHITE}."
        return 0
    fi

    for repository_file in "${epel_repository_files[@]}"; do
        if ! prepared_file="$(mktemp /tmp/rish-epel-repository.XXXXXX)"; then
            echo "Не удалось создать временный файл для проверки EPEL." >&2
            rm -f -- "${prepared_repository_files[@]}"
            return 1
        fi
        prepared_repository_files+=("$prepared_file")

        if ! _rish_epel_prepare_repository_file "$repository_file" "$prepared_file"; then
            echo "Не удалось подготовить конфигурацию EPEL: $repository_file" >&2
            rm -f -- "${prepared_repository_files[@]}"
            return 1
        fi

        if cmp -s -- "$repository_file" "$prepared_file"; then
            rm -f -- "$prepared_file"
            unset 'prepared_repository_files[-1]'
        else
            changed_repository_files+=("$repository_file")
        fi
    done

    if ((${#changed_repository_files[@]} == 0)); then
        echo -e "EPEL содержит пакеты для ${RED}EL ${os_major}.${package_max_minor}${WHITE}, а установлена ${YELLOW}EL ${expected_version}${WHITE}."
        echo "Автоматическое переключение невозможно: в секциях EPEL не найден поддерживаемый формат адреса репозитория." >&2
        echo "Конфигурация EPEL оставлена без изменений." >&2
        return 1
    fi

    if ((${#changed_repository_files[@]} > 0)); then
        backup_timestamp="$(date +%Y%m%d-%H%M%S)"
        backup_dir="${RISH_HOME}/backups/repositories/epel-${backup_timestamp}-$$"
        if ! install -d -m 700 "$backup_dir"; then
            echo "Не удалось создать каталог резервной копии EPEL: $backup_dir" >&2
            rm -f -- "${prepared_repository_files[@]}"
            return 1
        fi

        for repository_file in "${changed_repository_files[@]}"; do
            backup_file="${backup_dir}/$(basename "$repository_file")"
            if ! cp -a -- "$repository_file" "$backup_file"; then
                echo "Не удалось сохранить резервную копию: $repository_file" >&2
                rm -f -- "${prepared_repository_files[@]}"
                return 1
            fi
            backup_repository_files+=("$backup_file")
        done

        if ((package_max_minor > os_minor)); then
            echo "Обнаружена ветка EPEL, содержащая пакеты новее установленной операционной системы."
        else
            echo "Обнаружена опережающая ветка EPEL ${os_major}s на стабильной операционной системе."
            echo "Сейчас её пакеты ещё совместимы, но после перехода EPEL к следующей минорной версии они могут стать несовместимыми с установленной ОС."
        fi
        echo -e "Операционная система: ${GREEN}${os_pretty_name:-${os_name} ${os_version_id}}${WHITE}"
        echo -e "Текущая ветка EPEL: ${YELLOW}${current_branch}${WHITE}"
        echo -e "В EPEL обнаружены пакеты вплоть до: ${RED}EL ${os_major}.${package_max_minor}${WHITE}"
        echo -e "Требуемая ветка EPEL: ${GREEN}${expected_version}${WHITE}"
        echo

        for ((index = 0; index < ${#changed_repository_files[@]}; index++)); do
            if ! cp -- "${prepared_repository_files[$index]}" "${changed_repository_files[$index]}"; then
                echo -e "Не удалось изменить конфигурацию ${RED}${changed_repository_files[$index]}${WHITE}."
                break
            fi
            ((applied_count += 1))
        done
        rm -f -- "${prepared_repository_files[@]}"

        if ((applied_count != ${#changed_repository_files[@]})); then
            if _rish_epel_restore_repository_files changed_repository_files backup_repository_files; then
                echo "Исходная конфигурация EPEL восстановлена."
            else
                echo -e "Не удалось полностью восстановить ${RED}исходную конфигурацию EPEL${WHITE}." >&2
            fi
            return 1
        fi
    fi

    package_max_minor="$(_rish_epel_repository_max_minor "$os_major" "${enabled_epel_repository_ids[@]}")"
    validation_status=$?
    if ((validation_status != 0)) || [[ ! "$package_max_minor" =~ ^[0-9]+$ ]] ||
        ((package_max_minor > os_minor)); then
        if ((${#changed_repository_files[@]} > 0)); then
            echo "Новая конфигурация EPEL не прошла проверку ветки репозитория."
            if _rish_epel_restore_repository_files changed_repository_files backup_repository_files; then
                echo "Исходная конфигурация восстановлена."
            else
                echo -e "Не удалось полностью восстановить ${RED}исходную конфигурацию EPEL${WHITE}." >&2
            fi
        fi
        if [[ "$package_max_minor" =~ ^[0-9]+$ ]] && ((package_max_minor > os_minor)); then
            echo -e "EPEL содержит пакеты для ${RED}EL ${os_major}.${package_max_minor}${WHITE}, а установлена ${YELLOW}EL ${expected_version}${WHITE}."
        fi
        echo "Установка RISH остановлена без установки несовместимых пакетов."
        return 1
    fi

    echo -e "Репозиторий EPEL автоматически переключён на ветку ${GREEN}${expected_version}${WHITE}."
    echo -e "После переключения EPEL проверен: максимальная версия пакетов — ${GREEN}EL ${os_major}.${package_max_minor}${WHITE}."
    echo -e "Резервная копия прежней конфигурации: ${YELLOW}${backup_dir}${WHITE}"

    return 0
}
