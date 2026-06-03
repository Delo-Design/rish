#!/usr/bin/env bash

RISH_HOME="${RISH_HOME:-/root/rish}"

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'

source "${RISH_HOME}/windows.sh"
source "${RISH_HOME}/php_helpers.sh"

PrintPackageUpdates() {
  local update_line
  local package_name
  local package_version
  local package_repo
  local version_main
  local version_suffix

  for update_line in "$@"; do
    read -r package_name package_version package_repo <<< "$update_line"
    version_main="$package_version"
    version_suffix=""
    if [[ "$package_version" == *.el* ]]; then
      version_main="${package_version%%.el*}"
      version_suffix="${package_version#"$version_main"}"
    fi
    printf '  %s %b%s%b%s %s\n' "$package_name" "$GREEN" "$version_main" "$WHITE" "$version_suffix" "$package_repo"
  done
}

CheckPackageUpdates() {
  local title="$1"
  shift
  local -a packages=("$@")
  local -a updates=()
  local check_output
  local check_output_file
  local status

  if [[ "${#packages[@]}" -eq 0 ]]; then
    echo -e "${YELLOW}Не найдены установленные пакеты для проверки: ${title}.${WHITE}"
    return 0
  fi

  echo
  echo -e "${GREEN}${title}${WHITE}"
  echo "Проверяем доступные обновления..."

  check_output_file="$(mktemp /tmp/rish-package-update.XXXXXX)" || return 1
  dnf check-update "${packages[@]}" 2>&1 \
    | tee "$check_output_file" \
    | awk 'NF == 0 || ! /^[[:alnum:]_.:+-]+\.[[:alnum:]_]+[[:space:]]/ {print}'
  status=${PIPESTATUS[0]}
  check_output="$(cat "$check_output_file")"
  rm -f "$check_output_file"
  mapfile -t updates < <(printf '%s\n' "$check_output" | awk '/^[[:alnum:]_.:+-]+\.[[:alnum:]_]+[[:space:]]/ {print $1 " " $2 " " $3}')

  if [[ "$status" -eq 0 ]]; then
    echo "Обновлений нет."
    return 0
  fi

  if [[ "$status" -ne 100 ]]; then
    echo -e "${RED}Не удалось проверить обновления.${WHITE}"
    return 1
  fi

  if [[ "${#updates[@]}" -eq 0 ]]; then
    echo "Обновлений нет."
    return 0
  fi

  echo
  echo "Доступны обновления:"
  PrintPackageUpdates "${updates[@]}"
  echo
  echo "Установить найденные обновления?"
  vertical_menu "current" 2 0 5 "Да" "Нет"
  if [[ "$?" -ne 0 ]]; then
    echo "Обновление отменено."
    return 0
  fi

  echo
  echo "Устанавливаем обновления..."
  if dnf update -y "${packages[@]}"; then
    echo
    echo -e "${GREEN}Обновление завершено.${WHITE}"
    echo "Запускаем проверку и восстановление настроек RISH."
    bash "${RISH_HOME}/rish_check.sh" fix
  else
    echo -e "${RED}Обновление завершилось с ошибкой.${WHITE}"
    return 1
  fi
}

CheckPhpUpdates() {
  local -a packages=()
  local php_version

  while IFS= read -r php_version; do
    packages+=("${php_version}-*")
  done < <(get_installed_php_versions)

  if rpm -qa | grep -qE '^php[0-9]{2}-php-pecl-imagick-im7'; then
    packages+=("ImageMagick7-*")
  fi
  if rpm -qa | grep -qE '^php[0-9]{2}-php-pecl-imagick-im6'; then
    packages+=("ImageMagick6-*")
  fi

  CheckPackageUpdates "Проверка обновлений PHP" "${packages[@]}"
}

CheckApacheUpdates() {
  CheckPackageUpdates "Проверка обновлений Apache" "httpd*" "mod_ssl"
}

case "${1:-}" in
  php)
    CheckPhpUpdates
    ;;
  apache)
    CheckApacheUpdates
    ;;
  *)
    echo "Использование: $0 php|apache"
    exit 1
    ;;
esac
