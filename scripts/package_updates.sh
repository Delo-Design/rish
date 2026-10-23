#!/usr/bin/env bash

RISH_HOME="${RISH_HOME:-/root/rish}"

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'

source "${RISH_HOME}/windows.sh"
source "${RISH_HOME}/php_helpers.sh"

PACKAGE_UPDATES_INSTALLED=0
PACKAGE_UPDATES=()

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

CheckApacheConfig() {
  local configtest_output
  local configtest_status

  configtest_output="$(apachectl configtest 2>&1)"
  configtest_status=$?
  printf '%s\n' "$configtest_output"

  if grep -q 'AH01882' <<< "$configtest_output"; then
    echo -e "${RED}mod_ssl${WHITE} собран для другой версии OpenSSL."
    return 1
  fi

  if ((configtest_status != 0)); then
    echo -e "Конфигурация Apache содержит ${RED}ошибки${WHITE}."
    return 1
  fi
}

ReportServicesNeedingRestart() {
  local services_output
  local status

  if ! command -v needs-restarting >/dev/null 2>&1; then
    echo
    echo -e "${YELLOW}Не удалось проверить другие службы:${WHITE} needs-restarting не найден."
    return 0
  fi

  services_output="$(needs-restarting -s 2>&1)"
  status=$?

  if ((status != 0)); then
    echo
    echo -e "${YELLOW}Не удалось определить службы, которым требуется перезапуск.${WHITE}"
    if [[ -n "$services_output" ]]; then
      printf '%s\n' "$services_output"
    fi
    return 0
  fi

  if [[ -z "$services_output" ]]; then
    echo
    echo "Других служб, требующих перезапуска, не обнаружено."
    return 0
  fi

  echo
  echo -e "${YELLOW}Обнаружены службы, которым требуется перезапуск:${WHITE}"
  while IFS= read -r service_name; do
    [[ -n "$service_name" ]] && printf '  %s\n' "$service_name"
  done <<< "$services_output"
  echo "Перезапустите их в подходящее время. Для системных служб безопаснее выполнить плановую перезагрузку сервера."
}

FindPackageUpdates() {
  local title="$1"
  shift
  local -a packages=("$@")
  local check_output
  local check_output_file
  local status

  PACKAGE_UPDATES=()

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
  mapfile -t PACKAGE_UPDATES < <(printf '%s\n' "$check_output" | awk '/^[[:alnum:]_.:+-]+\.[[:alnum:]_]+[[:space:]]/ {print $1 " " $2 " " $3}')

  if [[ "$status" -eq 0 ]]; then
    PACKAGE_UPDATES=()
    echo "Обновлений нет."
    return 0
  fi

  if [[ "$status" -ne 100 ]]; then
    echo -e "${RED}Не удалось проверить обновления.${WHITE}"
    return 1
  fi

  if [[ "${#PACKAGE_UPDATES[@]}" -eq 0 ]]; then
    echo "Обновлений нет."
    return 0
  fi

  echo
  echo "Доступны обновления:"
  PrintPackageUpdates "${PACKAGE_UPDATES[@]}"
}

CheckPackageUpdates() {
  local title="$1"
  shift
  local -a packages=("$@")

  PACKAGE_UPDATES_INSTALLED=0
  FindPackageUpdates "$title" "${packages[@]}" || return 1
  [[ "${#PACKAGE_UPDATES[@]}" -gt 0 ]] || return 0

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
    PACKAGE_UPDATES_INSTALLED=1
    echo
    echo -e "Обновление ${GREEN}завершено${WHITE}."
    echo "Запускаем проверку и восстановление настроек RISH."
    if ! bash "${RISH_HOME}/rish_check.sh" fix; then
      echo -e "Проверка и восстановление настроек RISH завершились с ${YELLOW}ошибкой${WHITE}."
    fi
    return 0
  else
    echo -e "Обновление завершилось с ${RED}ошибкой${WHITE}."
    return 1
  fi
}

PromptApacheRestart() {
  echo
  echo -e "Обновления ${GREEN}Apache${WHITE} установлены."
  echo "Для применения обновлений нужен полный перезапуск Apache."
  echo "Это не быстрый reload: активные соединения могут быть прерваны."
  echo "Перезапустить Apache сейчас?"
  vertical_menu "current" 2 0 5 "Да" "Нет"
  if [[ "$?" -ne 0 ]]; then
    echo -e "Apache не перезапущен. ${YELLOW}Рекомендуется${WHITE} сделать это позже."
    return 0
  fi

  echo
  echo -e "Проверяем конфигурацию Apache: ${GREEN}apachectl configtest${WHITE}"
  if ! CheckApacheConfig; then
    echo "Перезапуск Apache отменен."
    return 1
  fi

  echo "Полный перезапуск может оказаться долгим - до минуты или более."
  echo -e "Перезапускаем Apache: ${GREEN}systemctl restart httpd${WHITE}"
  if systemctl restart httpd; then
    echo -e "Apache ${GREEN}перезапущен${WHITE}."
  else
    echo -e "Не удалось перезапустить ${RED}Apache${WHITE}."
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
  local restart_status=0

  CheckPackageUpdates "Проверка обновлений Apache" \
    "httpd*" "mod_ssl" "mod_http2" "openssl" "openssl-libs" || return 1
  if [[ "$PACKAGE_UPDATES_INSTALLED" -eq 1 ]]; then
    if ! PromptApacheRestart; then
      restart_status=1
    fi
    ReportServicesNeedingRestart
    return "$restart_status"
  fi
}

ReadMariaDbVersion() {
  local result
  local version
  local sql_check

  if ! result="$(mariadb --protocol=socket -uroot --connect-timeout=5 -NBe 'SELECT VERSION(); SELECT 1;')"; then
    echo "Не удалось выполнить проверочный SQL-запрос к MariaDB." >&2
    return 1
  fi
  version="${result%%$'\n'*}"
  sql_check="${result#*$'\n'}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ || "$sql_check" != "1" ]]; then
    echo "MariaDB вернула неожиданный результат проверочного SQL-запроса." >&2
    return 1
  fi
  printf '%s\n' "$version"
}

StartMariaDbAfterUpdate() {
  local expected_branch="$1"
  local version

  echo "Запускаем MariaDB..."
  if ! systemctl start mariadb || ! systemctl is-active --quiet mariadb; then
    echo -e "Не удалось запустить ${RED}MariaDB${WHITE}."
    echo "Проверьте состояние: systemctl status mariadb --no-pager -l"
    return 1
  fi
  if ! version="$(ReadMariaDbVersion)"; then
    echo -e "Служба MariaDB активна, но SQL-проверка завершилась с ${RED}ошибкой${WHITE}."
    return 1
  fi
  if [[ "$version" != "$expected_branch".* ]]; then
    echo "Работающий сервер ${version} не соответствует ожидаемой ветке ${expected_branch}."
    return 1
  fi
  echo -e "MariaDB ${GREEN}${version}${WHITE} работает; SQL-проверка пройдена."
}

StartApacheAfterMariaDbUpdate() {
  echo "Проверяем конфигурацию Apache перед запуском..."
  CheckApacheConfig || return 1
  echo "Запускаем Apache..."
  if ! systemctl start httpd || ! systemctl is-active --quiet httpd; then
    echo -e "Не удалось запустить ${RED}Apache${WHITE}."
    echo "Проверьте состояние: systemctl status httpd --no-pager -l"
    return 1
  fi
  echo -e "Apache ${GREEN}запущен${WHITE}."
}

CheckMariaDbPackageBranch() {
  local expected_branch="$1"
  local package_name="$2"
  local package_version="${3#*:}"
  local candidate_branch

  [[ "$package_name" == MariaDB-* ]] || return 0
  if [[ ! "$package_version" =~ ^([0-9]+\.[0-9]+)\.[0-9]+ ]]; then
    echo "Не удалось определить ветку кандидата ${package_name}: ${package_version}."
    return 1
  fi
  candidate_branch="${BASH_REMATCH[1]}"
  if [[ "$candidate_branch" != "$expected_branch" ]]; then
    echo -e "Обновление ${RED}отменено${WHITE}: кандидат ${package_name} ${YELLOW}${package_version}${WHITE} относится к ветке ${YELLOW}${candidate_branch}${WHITE}."
    echo -e "Текущая ветка MariaDB: ${GREEN}${expected_branch}${WHITE}."
    return 1
  fi
}

CheckMariaDbUpdates() (
  local installed_output
  local installed_version=""
  local installed_branch
  local running_version
  local target_version=""
  local package_name
  local package_version
  local package_repo
  local package_arch
  local expected_package
  local update_line
  local download_dir=""
  local downloaded_output
  local config_path
  local apache_config_output
  local config_line
  local restart_required=0
  local apache_restart_required=0
  local status
  local -a packages=()
  local -a update_packages=()
  local -a config_paths=()
  local -a package_files=()
  local -A prepared_packages=()

  # После начала остановки возвращаем службу в работу и при ошибке или прерывании.
  # Ловушки изолированы от режимов обновления PHP и Apache.
  RestoreMariaDbOnExit() {
    status=$?
    if ((restart_required || apache_restart_required)); then
      echo "Пытаемся восстановить работу служб после незавершённого обновления."
      if StartMariaDbAfterUpdate "$installed_branch"; then
        if ((apache_restart_required)); then
          if ! StartApacheAfterMariaDbUpdate && ((status == 0)); then status=1; fi
        fi
      else
        if ((apache_restart_required)); then
          echo "Apache оставлен остановленным: работоспособность MariaDB не подтверждена."
        fi
        ((status != 0)) || status=1
      fi
    fi
    [[ -z "$download_dir" ]] || rm -rf -- "$download_dir"
    exit "$status"
  }
  trap RestoreMariaDbOnExit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  if ! installed_output="$(rpm -qa --qf '%{NAME}.%{ARCH} %{VERSION}\n')"; then
    echo "Не удалось получить список установленных пакетов MariaDB."
    return 1
  fi
  while read -r package_name package_version; do
    case "$package_name" in
      MariaDB-*|galera.*|galera-[0-9]*.*)
        packages+=("$package_name")
        if [[ "$package_name" == MariaDB-server.* ]]; then
          installed_version="$package_version"
        fi
        ;;
    esac
  done <<< "$installed_output"

  if [[ -z "$installed_version" ]]; then
    echo "Установленный пакет MariaDB-server не найден."
    return 1
  fi
  if [[ ! "$installed_version" =~ ^([0-9]+\.[0-9]+)\.[0-9]+ ]]; then
    echo "Не удалось определить ветку установленной MariaDB: ${installed_version}."
    return 1
  fi
  installed_branch="${BASH_REMATCH[1]}"
  echo -e "Установлена MariaDB ${GREEN}${installed_version}${WHITE}, ветка ${GREEN}${installed_branch}${WHITE}."

  FindPackageUpdates "Проверка обновлений MariaDB" "${packages[@]}" || return 1
  [[ "${#PACKAGE_UPDATES[@]}" -gt 0 ]] || return 0

  for update_line in "${PACKAGE_UPDATES[@]}"; do
    read -r package_name package_version package_repo <<< "$update_line"
    case "$package_name" in
      MariaDB-*|galera.*|galera-[0-9]*.*)
        CheckMariaDbPackageBranch "$installed_branch" "$package_name" "$package_version" || return 1
        ;;
      *)
        echo "Обнаружен неожиданный пакет ${package_name}; обновление отменено."
        return 1
        ;;
    esac
    if [[ "$package_name" == MariaDB-server.* ]]; then
      target_version="${package_version#*:}"
      target_version="${target_version%-*}"
    fi
    package_arch="${package_name##*.}"
    [[ "$package_version" == *:* ]] || package_version="0:${package_version}"
    # Устанавливаем именно проверенные версии, даже если метаданные обновятся.
    update_packages+=("${package_name%.*}-${package_version}.${package_arch}")
  done

  if ! systemctl is-active --quiet mariadb || ! running_version="$(ReadMariaDbVersion)"; then
    echo "Перед обновлением MariaDB должна работать и быть доступна через локальный SQL-клиент."
    return 1
  fi
  if [[ ! "$running_version" =~ ^([0-9]+\.[0-9]+)\. || "${BASH_REMATCH[1]}" != "$installed_branch" ]]; then
    echo "Ветка работающего сервера ${running_version} отличается от ветки пакетов ${installed_branch}; обновление отменено."
    return 1
  fi

  echo
  if [[ -n "$target_version" ]]; then
    echo -e "Обновление MariaDB: ${GREEN}${installed_version}${WHITE} → ${GREEN}${target_version}${WHITE}"
  else
    echo -e "MariaDB-server: ${GREEN}${installed_version}${WHITE} (версия не изменится)"
    echo "Обновляются сопутствующие пакеты."
  fi
  echo -e "Ветка: ${GREEN}${installed_branch}${WHITE}"
  echo
  echo "Резервная копия баз"
  echo "  Перед обновлением нужна свежая копия всех баз данных."
  echo
  echo "Копии конфигурации"
  echo -e "  ${YELLOW}/etc/my.cnf.bak${WHITE}"
  echo -e "  ${YELLOW}/etc/my.cnf.d/*.cnf.bak${WHITE}"
  echo -e "  Существующие .bak будут ${YELLOW}перезаписаны${WHITE}."
  echo
  echo "На время обновления"
  echo "  MariaDB и работающий Apache будут остановлены."
  echo -e "  Сайты будут временно ${YELLOW}недоступны${WHITE}."
  echo
  echo "Установить обновления?"
  if ! vertical_menu "current" 2 0 5 default=1 "Да" "Нет"; then
    echo "Обновление отменено."
    return 0
  fi

  shopt -s nullglob
  for config_path in /etc/my.cnf /etc/my.cnf.d/*.cnf; do
    if [[ -f "$config_path" ]]; then
      config_paths+=("$config_path")
    elif [[ -e "$config_path" || -L "$config_path" ]]; then
      echo -e "Не удалось прочитать конфигурационный файл ${YELLOW}${config_path}${WHITE}; обновление отменено."
      return 1
    fi
  done
  if [[ "${#config_paths[@]}" -eq 0 ]]; then
    echo "Конфигурационные файлы MariaDB не найдены; обновление отменено."
    return 1
  fi
  for config_path in "${config_paths[@]}"; do
    if ! cp -aL --remove-destination --no-target-directory -- "$config_path" "${config_path}.bak"; then
      echo -e "Не удалось сохранить ${YELLOW}${config_path}.bak${WHITE}; обновление отменено."
      return 1
    fi
    echo -e "Конфигурация сохранена: ${GREEN}${config_path}.bak${WHITE}."
  done

  download_dir="$(mktemp -d /tmp/rish-mariadb-packages.XXXXXX)" || return 1
  echo "Загружаем пакеты перед остановкой MariaDB..."
  if ! dnf update --downloadonly --destdir="$download_dir" -y --best --setopt=obsoletes=False --setopt=strict=True "${update_packages[@]}"; then
    echo "Не удалось подготовить пакеты; MariaDB продолжает работать."
    return 1
  fi
  package_files=("$download_dir/"*.rpm)
  if [[ "${#package_files[@]}" -eq 0 ]]; then
    echo "Не найдены подготовленные RPM-пакеты; обновление отменено."
    return 1
  fi
  if ! downloaded_output="$(rpm -qp --qf '%{NAME} %{EPOCHNUM}:%{VERSION}-%{RELEASE} %{ARCH}\n' "${package_files[@]}")"; then
    echo "Не удалось проверить подготовленные RPM-пакеты; обновление отменено."
    return 1
  fi
  while read -r package_name package_version package_arch; do
    CheckMariaDbPackageBranch "$installed_branch" "$package_name" "$package_version" || return 1
    prepared_packages["${package_name}-${package_version}.${package_arch}"]=1
  done <<< "$downloaded_output"
  # Успех DNF не гарантирует, что отсутствующие точные версии не были пропущены.
  for expected_package in "${update_packages[@]}"; do
    if [[ -z "${prepared_packages[$expected_package]:-}" ]]; then
      echo -e "Не подготовлен выбранный пакет: ${YELLOW}${expected_package}${WHITE}."
      echo "Обновление отменено; MariaDB продолжает работать."
      return 1
    fi
  done

  if systemctl is-active --quiet httpd; then
    echo
    echo "Проверка Apache"
    if apache_config_output="$(CheckApacheConfig)"; then
      while IFS= read -r config_line; do
        [[ -z "$config_line" || "$config_line" == "Syntax OK" ]] || printf '  %s\n' "$config_line"
      done <<< "$apache_config_output"
      echo -e "  Конфигурация: ${GREEN}OK${WHITE}"
    else
      echo -e "  Конфигурация: ${RED}ошибка${WHITE}"
      printf '%s\n' "$apache_config_output"
      return 1
    fi
    echo
    echo "Остановка служб"
    apache_restart_required=1
    printf '  Apache:  '
    if ! systemctl stop httpd || systemctl is-active --quiet httpd; then
      echo -e "${RED}ошибка остановки${WHITE}"
      echo "Не удалось подтвердить остановку Apache; обновление MariaDB отменено."
      return 1
    fi
    echo -e "${YELLOW}остановлен${WHITE}"
  else
    echo
    echo "Остановка служб"
    echo "  Apache:  не запущен"
  fi
  restart_required=1
  printf '  MariaDB: '
  if ! systemctl stop mariadb || systemctl is-active --quiet mariadb; then
    echo -e "${RED}ошибка остановки${WHITE}"
    echo "Не удалось подтвердить остановку MariaDB; установка пакетов отменена."
    return 1
  fi
  echo -e "${YELLOW}остановлена${WHITE}"
  echo
  echo "Установка обновлений MariaDB"
  echo
  # Репозитории отключены: в транзакцию входят только проверенные RPM и установленные зависимости.
  if ! dnf --disablerepo='*' upgrade -y --best --setopt=obsoletes=False --setopt=strict=True --setopt=localpkg_gpgcheck=True "${package_files[@]}"; then
    echo -e "Обновление пакетов завершилось с ${RED}ошибкой${WHITE}."
    return 1
  fi
  StartMariaDbAfterUpdate "$installed_branch" || return 1
  restart_required=0
  if ((apache_restart_required)); then
    StartApacheAfterMariaDbUpdate || return 1
    apache_restart_required=0
  fi
  echo -e "Обновление MariaDB ${GREEN}завершено${WHITE}."
)

case "${1:-}" in
  php)
    CheckPhpUpdates
    ;;
  apache)
    CheckApacheUpdates
    ;;
  mariadb)
    CheckMariaDbUpdates
    ;;
  *)
    echo "Использование: $0 php|apache|mariadb"
    exit 1
    ;;
esac
