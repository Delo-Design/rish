#!/usr/bin/env bash

_rish_yum_install_with_retry() {
    if yum -y install "$@"; then
        return 0
    fi

    echo "Установка ${*} не удалась, очищаем кэш и повторяем попытку."
    yum clean all
    yum makecache
    yum -y install "$@"
}

_rish_download_with_retry() {
    local url="$1"
    local output="$2"
    local attempt

    for attempt in 1 2; do
        if curl --fail --location --silent --show-error \
            --connect-timeout 15 --max-time 300 \
            --output "$output" "$url"; then
            return 0
        fi
        if [[ "$attempt" -eq 1 ]]; then
            echo "Скачать $url не удалось, повторяем попытку."
        fi
    done

    return 1
}

_rish_install_official_rclone_rpm() (
    local rclone_arch="$1"
    local rclone_tmp_dir=""
    local rclone_gnupg_home=""
    local rclone_version_text=""
    local rclone_version=""
    local rclone_release_url=""
    local rclone_rpm_name=""
    local rclone_rpm_path=""
    local rclone_sums_path=""
    local rclone_sums_clear_path=""
    local rclone_keys_path=""
    local rclone_signature_status=""
    local rclone_expected_hash=""
    local rclone_actual_hash=""
    local rclone_signing_fingerprint="FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA"
    local rclone_new_signing_fingerprint="E3B358DC858FB307F48170B9CB0DBEBC5F32C81D"

    if ! command -v curl >/dev/null 2>&1; then
        _rish_yum_install_with_retry curl || return 1
    fi
    if ! command -v gpg >/dev/null 2>&1; then
        _rish_yum_install_with_retry gnupg2 || return 1
    fi
    if ! command -v sha256sum >/dev/null 2>&1; then
        _rish_yum_install_with_retry coreutils || return 1
    fi

    rclone_tmp_dir=$(mktemp -d /tmp/rish-rclone.XXXXXX) || return 1
    trap 'rm -rf "$rclone_tmp_dir"' EXIT
    rclone_gnupg_home="$rclone_tmp_dir/gnupg"
    mkdir -m 700 "$rclone_gnupg_home" || return 1

    if ! _rish_download_with_retry \
        "https://downloads.rclone.org/version.txt" \
        "$rclone_tmp_dir/version.txt"; then
        echo "Не удалось определить актуальную версию rclone."
        return 1
    fi
    rclone_version_text=$(tr -d '\r\n' < "$rclone_tmp_dir/version.txt")
    if [[ ! "$rclone_version_text" =~ ^rclone\ v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Получена некорректная версия rclone: $rclone_version_text"
        return 1
    fi

    rclone_version="${rclone_version_text#rclone v}"
    rclone_release_url="https://downloads.rclone.org/v${rclone_version}"
    rclone_rpm_name="rclone-v${rclone_version}-linux-${rclone_arch}.rpm"
    rclone_rpm_path="$rclone_tmp_dir/$rclone_rpm_name"
    rclone_sums_path="$rclone_tmp_dir/SHA256SUMS"
    rclone_sums_clear_path="$rclone_tmp_dir/SHA256SUMS.clear"
    rclone_keys_path="$rclone_tmp_dir/KEYS"

    if ! _rish_download_with_retry "$rclone_release_url/$rclone_rpm_name" "$rclone_rpm_path" ||
        ! _rish_download_with_retry "$rclone_release_url/SHA256SUMS" "$rclone_sums_path" ||
        ! _rish_download_with_retry "https://rclone.org/KEYS" "$rclone_keys_path"; then
        echo "Не удалось скачать официальный RPM rclone или данные для его проверки."
        return 1
    fi

    if ! gpg --batch --homedir "$rclone_gnupg_home" \
        --import "$rclone_keys_path" >/dev/null 2>&1; then
        echo "Не удалось импортировать ключ подписи rclone."
        return 1
    fi
    if ! rclone_signature_status=$(gpg --batch --homedir "$rclone_gnupg_home" \
        --status-fd 1 --verify "$rclone_sums_path" 2>/dev/null); then
        echo "Подпись SHA256SUMS rclone недействительна."
        return 1
    fi
    if ! printf '%s\n' "$rclone_signature_status" | grep -Eq \
        "^\[GNUPG:\] VALIDSIG (${rclone_signing_fingerprint}|${rclone_new_signing_fingerprint})( |$)"; then
        echo "SHA256SUMS подписан неизвестным ключом."
        return 1
    fi
    if ! gpg --batch --homedir "$rclone_gnupg_home" \
        --decrypt "$rclone_sums_path" > "$rclone_sums_clear_path" 2>/dev/null; then
        echo "Не удалось извлечь подписанные контрольные суммы rclone."
        return 1
    fi

    rclone_expected_hash=$(awk -v rpm_name="$rclone_rpm_name" \
        '$2 == rpm_name { print $1; exit }' "$rclone_sums_clear_path")
    if [[ ! "$rclone_expected_hash" =~ ^[[:xdigit:]]{64}$ ]]; then
        echo "Контрольная сумма $rclone_rpm_name не найдена."
        return 1
    fi
    if ! rclone_actual_hash=$(sha256sum "$rclone_rpm_path"); then
        echo "Не удалось вычислить контрольную сумму $rclone_rpm_name."
        return 1
    fi
    rclone_actual_hash="${rclone_actual_hash%% *}"
    if [[ "$rclone_actual_hash" != "$rclone_expected_hash" ]]; then
        echo "Контрольная сумма $rclone_rpm_name не совпадает."
        return 1
    fi

    echo "Подпись и контрольная сумма $rclone_rpm_name проверены."
    _rish_yum_install_with_retry "$rclone_rpm_path"
)

install_rclone() {
    local os_version_id=""
    local os_major=""
    local rclone_arch=""

    if command -v rclone >/dev/null 2>&1; then
        rclone version >/dev/null 2>&1
        return $?
    fi

    if [[ -r /etc/os-release ]]; then
        os_version_id="$(
            # shellcheck source=/dev/null
            source /etc/os-release
            printf '%s' "${VERSION_ID:-}"
        )"
        os_major="${os_version_id%%.*}"
    fi

    if [[ "$os_major" != "8" ]]; then
        _rish_yum_install_with_retry rclone || return 1
    else
        case "$(uname -m)" in
            x86_64)
                rclone_arch="amd64"
                ;;
            i386|i486|i586|i686)
                rclone_arch="386"
                ;;
            aarch64)
                rclone_arch="arm64"
                ;;
            armv7l)
                rclone_arch="arm-v7"
                ;;
            armv6l)
                rclone_arch="arm-v6"
                ;;
            mips)
                rclone_arch="mips"
                ;;
            mipsel)
                rclone_arch="mipsle"
                ;;
            *)
                echo "Архитектура $(uname -m) не поддерживается официальным RPM rclone."
                return 1
                ;;
        esac

        echo "Пакет rclone недоступен в системном репозитории EL8."
        echo "Скачиваем и проверяем официальный RPM rclone."
        _rish_install_official_rclone_rpm "$rclone_arch" || return 1
    fi

    command -v rclone >/dev/null 2>&1 && rclone version >/dev/null 2>&1
}
