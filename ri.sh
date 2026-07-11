#!/usr/bin/env bash
#set -euo pipefail
#IFS=$'\n\t'

#Вспомогательное внутри сценария
LOG_FILE="/root/rish/logfile_rish_install.log"
# Путь к конфигурационному файлу
config_file="/root/rish/rish_config.sh"

# Проверка на существование файла лога, если он не существует - создать его
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi
# Функция для проверки, был ли шаг выполнен
check_step() {
    local step=$1
    grep -Fxq "$step" "$LOG_FILE"
}

# Функция для записи выполненного шага
mark_step_completed() {
    local step=$1
    echo "$step" >> "$LOG_FILE"
}

# Проверяем существование файла
if [ ! -f "$config_file" ]; then
    # Создаем файл, если он не существует
    touch "$config_file"
fi

# Функция для добавления переменной и комментария, если они отсутствуют в конфиге
add_var_if_not_exists() {
    local var_name="$1"
    local var_value="$2"
    if ! grep -P "^\s*${var_name}\s*=" "$config_file" > /dev/null 2>&1; then
        echo -e "$var_value" >> "$config_file"
    fi
}


SCRIPTVERSION='1.0.1'
GREEN='\033[0;32m'
RED='\033[0;31m'
LRED='\033[1;31m'
VIOLET='\033[0;35m'
WHITE='\033[0m'
YELLOW='\033[0;33m'
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'
ServerArch=$( arch )
OS_VERSION=$( hostnamectl | grep -Eo 'Operating.*' |  sed 's@^[^0-9]*\([0-9]\+\).*@\1@' )

SUPPORTED_OS='Fedora|Rocky|AlmaLinux|CentOS|Red Hat Enterprise Linux Server|Oracle|ClearOS|Scientific Linux|MSVSphere'
size=$(stty size)
lines=${size% *}
columns=${size#* }
upperX=1
upperY=1
downY=$((${lines}/2))
rim=$(( ${downY} - 2 ))
whereCursorIs="down"

# save the home dir
declare _script_name=${BASH_SOURCE[0]}
declare _script_dir=${_script_name%/*}

if [[ "$_script_name" == "$_script_dir" ]]
then
  # _script name has no path
  _script_dir="."
fi

# convert to an absolute path
_script_dir=$(cd ${_script_dir}; pwd -P)

export RISH_HOME=${_script_dir}

cd ${RISH_HOME} || exit

source windows.sh
source php_multi_install.sh
source php_helpers.sh
source scripts/mariadb_install.sh
source create_hotlist.sh
source scripts/create_swapfile.sh
source scripts/ssh_authentication.sh

if (( lines < 40 || columns < 140 )); then
  echo
  echo "Размер окна вашего терминала слишком маленький."
  echo -e "Советуем увеличить окно терминала до размера ${RED}140x40${WHITE} символов."
  echo "Иначе вывод на экран возможно будет некорректным."
  echo
  if vertical_menu "current" 2 0 5  "Остановить выполнение скрипта установки" "Хорошо понятно. Продолжаем"
  then
    echo -e "Продолжить выполнение можно выполнив команду ${GREEN}/root/rish/ri.sh${WHITE}"
    exit 1
  fi
fi

# Если настройка скрипта уже была произведена, но сессия не была перезапущена - подгрузим пароль базы данных
if [[ -z "${MYSQLPASS}" ]]
then
  if grep -q "MYSQLPASS" ~/.bashrc
  then
    MYSQLPASS=`cat ~/.bashrc | grep MYSQLPASS | awk -F= '{ print $2}'`
  fi
fi

Up() {
  if [[ ${whereCursorIs} == "down" ]]
  then
    downY=$( get_cursor_row )
    whereCursorIs="up"
    # ограничить скрол верхней части экрана
    echo -e ${ESC}"[1;${rim}r"
    cursor_to ${upperY} 1
  fi
}

Down() {
  if [[ ${whereCursorIs} == "up" ]]
  then
    upperY=$( get_cursor_row )
    echo -e ${ESC}"[$(( ${rim}+2));${lines}r"
    # Ограничить скрол нижней частью экрана
    cursor_to ${downY} 1
    whereCursorIs="down"
  fi
}

RemoveRim () {
  echo -e ${ESC}"[;r"
  cursor_to $(( ${rim} +1 )) 1
  echo -en ${ESC}"[0J"
}

clear
# Рисуем разделительную линию
cursor_to $(( ${rim} +1 )) 1
repl "─" $(( ${columns} ))
cursor_to $(( ${rim} +2 )) 1
Up

if command -v lsb_release >/dev/null 2>&1; then
  CURRENT_OS=$(lsb_release -d -s)
  echo -e "Ваша версия Linux: ${RED}${CURRENT_OS}${WHITE}"
elif [[ -f /etc/system-release ]]; then
  CURRENT_OS=$(head -1 /etc/system-release)
  echo -e "Ваша версия Linux: ${GREEN}${CURRENT_OS}${WHITE}"
elif [[ -f /etc/issue ]]; then
  CURRENT_OS=$(head -2 /etc/issue)
  echo -e "Ваша версия Linux: ${RED}${CURRENT_OS}${WHITE}"
else
  echo -e "${RED}Невозможно определить вашу версию Linux${WHITE}"
  exit 1
fi

if [[ -f /etc/redhat-release ]] || grep -q 'ID_LIKE=.*rhel' /etc/os-release 2>/dev/null; then
    echo "Система относится к семейству RHEL."
else
    echo "Система НЕ относится к семейству RHEL."
    exit 1
fi

if echo ${CURRENT_OS} | grep -Eq "Fedora"
then
  FedoraVersion=$( cat /etc/fedora-release | sed 's@^[^0-9]*\([0-9]\+\).*@\1@' )
fi


Install() {
    if ! rpm -q "$@" >/dev/null 2>&1; then
        Up
        echo -e "Ставим ${GREEN}${*}${WHITE}"
        Down
        if yum -y install "$@"; then
            (( upperY -- ))
            Up
            echo -e "${GREEN}${*}${WHITE} установлен"
        else
            Up
            echo -e "Установить ${RED}${*}${WHITE} не удалось, очищаем кэш и пытаемся снова"
            Down
            yum clean all
            yum makecache
            if yum -y install "$@"; then
                Up
                echo -e "${GREEN}${*}${WHITE} установлен после очистки кэша"
            else
                Up
                echo -e "Установить ${RED}${*}${WHITE} не удалось даже после очистки кэша"
                RemoveRim
                exit 1
            fi
        fi
        echo
    else
        Up
        echo -e "${GREEN}${*}${WHITE} уже установлен"
    fi
    Down
}

CheckRebootRequired() {
  local reboot_status

  echo -n "Проверяем необходимость перезагрузки сервера... "
  if ! command -v needs-restarting >/dev/null 2>&1; then
    echo -e "${YELLOW}needs-restarting не найден${WHITE}"
    return 0
  fi

  needs-restarting -r >/dev/null 2>&1
  reboot_status=$?

  case "$reboot_status" in
    0)
      echo -e "${GREEN}перезагрузка не требуется${WHITE}"
      return 0
      ;;
    1)
      echo -e "${YELLOW}требуется перезагрузка${WHITE}"
      tet=$(pwd)
      echo -e "После перезагрузки запустите скрипт заново командой ${GREEN}${tet}/ri.sh${WHITE}"
      echo -e "Или войдите на сервер и нажмите стрелку ${GREEN}↑${WHITE} два раза: команда ${GREEN}/root/rish/ri.sh${WHITE} уже будет в истории команд."
      Down
      echo "Перезагрузить сервер?"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        echo "Перезагрузка сервера начата..."
        echo "/root/rish/ri.sh" >> /root/.bash_history
        reboot
        exit 0
      else
        RemoveRim
        echo -e "Перезагрузите сервер самостоятельно командой ${GREEN}reboot${WHITE}"
        echo -e "После перезагрузки запустите скрипт заново командой ${GREEN}${tet}/ri.sh${WHITE}"
        exit 0
      fi
      ;;
    *)
      echo -e "${YELLOW}не удалось проверить${WHITE}"
      return 0
      ;;
  esac
}

configure_httpd_tmpfiles_override() {
  local vendor_conf="/usr/lib/tmpfiles.d/httpd.conf"
  local override_conf="/etc/tmpfiles.d/httpd.conf"
  local tmp_conf="${override_conf}.rish-tmp.$$"

  if [[ ! -f "$vendor_conf" ]] || ! awk '$1 == "d" && $2 == "/var/www" { found=1 } END { exit !found }' "$vendor_conf"; then
    rm -f "$override_conf"
    return 0
  fi

  install -d -m 755 /etc/tmpfiles.d || return 1
  awk '$1 == "d" && $2 == "/var/www" { $3="751"; $4="root"; $5="root" } { print }' "$vendor_conf" > "$tmp_conf" || return 1
  install -m 644 "$tmp_conf" "$override_conf" || return 1
  rm -f "$tmp_conf"
  systemd-tmpfiles --create "$override_conf"
}


OpenFirewall() {
  # Проверка наличия и состояния firewalld
  if ! command -v firewall-cmd >/dev/null 2>&1 || ! systemctl is-active --quiet firewalld; then
    echo -e "${GREEN}Firewall${WHITE} не установлен или не запущен"
    Install firewalld
    Down
    systemctl enable --now firewalld
    Up
  fi

  Down
  local ZoneName changed
  ZoneName="$(firewall-cmd --get-default-zone)"
  changed=0

  # 1) Если сервис ispmanager существует — выключаем его в этой зоне
  if firewall-cmd --get-services | grep -qw ispmanager; then
    # Удалить из permanent при наличии
    if firewall-cmd --permanent --zone="$ZoneName" --query-service=ispmanager >/dev/null 2>&1; then
      echo -e "Закрываю сервис ${GREEN}ispmanager${WHITE} (permanent) в зоне ${ZoneName}"
      firewall-cmd --permanent --zone="$ZoneName" --remove-service=ispmanager
      changed=1
    fi
    # Попробовать убрать из runtime (если там был)
    if ! firewall-cmd --zone="$ZoneName" --remove-service=ispmanager >/dev/null 2>&1; then
      echo -e "${YELLOW}Предупреждение:${WHITE} сервис ispmanager уже не был активен (runtime)"
    fi
  fi

  # 2) Гарантировать, что http/https открыты (permanent)
  if ! firewall-cmd --permanent --zone="$ZoneName" --query-service=http  >/dev/null 2>&1; then
    firewall-cmd --permanent --zone="$ZoneName" --add-service=http
    changed=1
  fi
  if ! firewall-cmd --permanent --zone="$ZoneName" --query-service=https >/dev/null 2>&1; then
    firewall-cmd --permanent --zone="$ZoneName" --add-service=https
    changed=1
  fi

  # 3) Применить изменения при необходимости
  if [ "$changed" -eq 1 ]; then
    echo -e "Применяю изменения ${GREEN}firewalld${WHITE}"
    firewall-cmd --reload
  fi

  Up

  # 4) Итоговый статус
  if firewall-cmd --zone="$ZoneName" --query-service=http >/dev/null 2>&1 \
    && firewall-cmd --zone="$ZoneName" --query-service=https >/dev/null 2>&1; then
    echo -e "${GREEN}Firewall${WHITE}: http/https открыты в зоне ${ZoneName}."
  else
    echo -e "${RED}Внимание:${WHITE} не удалось гарантировать открытие http/https в зоне ${ZoneName}."
  fi
  # Сообщение о состоянии ispmanager (для наглядности)
  if firewall-cmd --zone="$ZoneName" --query-service=ispmanager >/dev/null 2>&1; then
    echo -e "${YELLOW}Замечание:${WHITE} сервис ${YELLOW}ispmanager${WHITE} всё ещё активен в runtime/зоне ${ZoneName}."
  else
    echo -e "Сервис ${GREEN}ispmanager${WHITE} в зоне ${ZoneName} отключён."
  fi
}

# shellcheck disable=SC2120
check_user_dirs_exist() {
  local count=0
  local dir
  for dir in /var/www/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name=$(basename "$dir")
    case "$name" in
    cgi-bin|html)
      continue
      ;;
    *)
      ((count++))
      ;;
    esac
  done

  (( count > 0 ))
}

CreateUser() {
  local NAME
  local default_username="$1"  # Получаем первый параметр, переданный в функцию
  # try to create user

  while true; do
    echo -e "При создании пользователя используйте только латинские буквы."
    echo -e -n "${WHITE}Введите имя пользователя (пустая строка для выхода):${GREEN}"
    if [[ -z "$default_username" ]]; then
      read -r -e -p " " NAME  # Не задаем значение по умолчанию, если параметр пустой
    else
      read -r -e -p " " -i "$default_username" NAME  # Используем переданный параметр как значение по умолчанию
    fi

    if [[ -z "$NAME" || "$NAME" == "EXIT" || "$NAME" == "exit" ]]; then
      echo -e "${WHITE}"
      if ! check_user_dirs_exist; then
        echo -e "${RED}Нельзя выйти${WHITE}, пока не создан ни один пользователь."
        echo -e "Создайте хотя бы одного пользователя."
        continue
      fi
      echo -e "${WHITE}"
      return 0
    fi

    if [[ "$NAME" == "html" || "$NAME" == "HTML" ]]; then
      echo -e "${WHITE}Имя ${RED}html${WHITE} запрещено. Выберите другое."
      continue
    fi

    NAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
    echo -e "${WHITE}Будет создан пользователь с именем: ${VIOLET}${NAME}${WHITE}"
    if vertical_menu "current" 2 0 5 "Да" "Нет"
    then
      if id -u ${NAME} >/dev/null 2>&1
      then
        echo -e "${WHITE}Такой пользователь уже есть ${LRED}${NAME}${WHITE}"
      else
        break
      fi
    fi
  done

  if  [[ ${NAME} == "EXIT" ]] || [[ ${NAME} == "exit" ]]
  then
    echo -e ${WHITE}
    return 0
  else
    echo -e "${WHITE}Создаем пользователя ${GREEN}${NAME}${WHITE}"
  fi
  echo -e "${WHITE}"
  echo "При создании новых сайтов Joomla требуется указать учетную запись для администратора."
  echo "Вы можете указать имя этой учетной записи, чтобы в дальнейшем не тратить время на ее изменение."
  echo -e "Если вы не укажете имя сейчас - оно будет создано автоматически. "
  echo -e "Изменить его можно будет в файле ${GREEN}/home/${NAME}/.pass.txt${WHITE}"
  echo
  echo "Введите имя учетной записи для создания сайтов по умолчанию (Обычно это ваш E-mail)"
  read -e -p "(Можно не заполнять - нажмите Enter)" DEFAULTSITEACCOUNT

  if id -u ${NAME} >/dev/null 2>&1
  then
    echo -e "${WHITE}Такой пользователь уже есть ${LRED}${NAME}${WHITE}"
    return 1
  fi
  useradd -s /sbin/nologin ${NAME}
  pass=$( tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs )
  echo ${NAME}:${pass} | chpasswd
  pass2=$( tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs )
  echo "Database: ${pass2}" > /home/${NAME}/.pass.txt
  echo -e "Пароль пользователя ${NAME}: ${GREEN}"${pass}${WHITE}
  echo "${NAME}: ${pass}" >> /home/${NAME}/.pass.txt
  echo -e "Пароль для баз данных ${NAME}: ${GREEN}"${pass2}${WHITE}
  pass3=$( tr -dc A-Za-z0-9 < /dev/urandom | head -c 16 | xargs )
  if [[ -z ${DEFAULTSITEACCOUNT} ]]
  then
    DEFAULTSITEACCOUNT="info@${NAME}.com"
  fi
  echo -e "Учетная запись по умолчанию: ${GREEN}${DEFAULTSITEACCOUNT}${WHITE}"
  echo "defaultsiteaccount ${DEFAULTSITEACCOUNT} ${pass3}" >> /home/${NAME}/.pass.txt

  chmod 600 "/home/${NAME}/.pass.txt"
  chown "${NAME}:${NAME}" "/home/${NAME}/.pass.txt"

  echo -e "Пароли записаны в файл ${GREEN}/home/${NAME}/.pass.txt${WHITE}"
  usermod -a -G sftp "${NAME}"
  usermod -aG "${NAME}" apache

  install -d -m 750 -o root -g "${NAME}" "/var/www/${NAME}"
  install -d -m 755 -o "${NAME}" -g "${NAME}" "/var/www/${NAME}/www"
  install -d -m 755 -o "${NAME}" -g "${NAME}" "/var/www/${NAME}/logs"
  install -d -m 755 -o "${NAME}" -g "${NAME}" "/var/www/${NAME}/session"
  install -d -m 755 -o "${NAME}" -g "${NAME}" "/var/www/${NAME}/wsdlcache"
  install -d -m 755 -o "${NAME}" -g "${NAME}" "/var/www/${NAME}/slowlog"
  install -d -m 755 -o "${NAME}" -g "${NAME}" "/var/www/${NAME}/tmp"

  install -d -m 700 -o "${NAME}" -g "${NAME}" "/home/${NAME}/.ssh"

  # создаем файл /home/siteuser/.ssh/authorized_keys для ключей доступа для юзера
  : > "/home/${NAME}/.ssh/authorized_keys"
  chown "${NAME}":"${NAME}" "/home/${NAME}/.ssh/authorized_keys"
  chmod 600 "/home/${NAME}/.ssh/authorized_keys"

  # Удаляем конфигурацию php по умолчанию (это файлы типа php74-php.conf)
  find /etc/httpd/conf.d -type f -name 'php[0-9][0-9]-php.conf' -exec rm -f {} +

  create_hotlist

  if mariadb  -e "CREATE USER ${NAME}@localhost IDENTIFIED BY '${pass2}';"
  then
    echo -e "пользователь ${GREEN}${NAME}${WHITE} успешно создан"
  else
    echo -e "во время создания пользователя ${RED}${NAME}${WHITE} MySQL произошла ошибка"
  fi
}

DeleteUser() {
  # Если папка не пуста, то отказываться удалять пользователя
  if [[ -n $( ls -A /var/www/${1}/www ) ]]
  then
    echo "У пользователя есть неудаленные сайты. Вначале удалите их."
    echo -e -n "${RED}"
    cd /var/www/${1}/www
    # Выводим директории
    ls -d */ | cut -f1 -d'/'
    # и файлы
    echo -e -n "${LRED}"
    ls -Sp | grep -v '/'
    echo -e "${WHITE}"
    return 1
  fi
  # Проверим на предмет неудаленных баз данных
  SiteuserMysqlPass=`cat /home/${1}/.pass.txt | grep Database | awk '{ print $2}'`
  bases=( `mariadb -u${1} -p${SiteuserMysqlPass}  --batch -e "SHOW DATABASES" | tail -n +3` )
  if (( ${#bases[@]} > 0 ))
  then
    echo "У пользователя есть неудаленные базы данных:"
    echo -e "${LRED}"
    for i in "${bases[@]}"; do
      echo "${i}"
    done
    echo -e "${WHITE}"
    echo "Вначале удалите их"
    return 1
  fi
  echo -e "Удалить пользователя ${RED}${1}${WHITE}?"

  if vertical_menu "current" 2 0 5 "Нет" "Да"
  then
    echo -e "${CURSORUP}Пользователь ${GREEN}$1${WHITE} не удален."
    return 1
  fi
  rm -rf "/var/www/${1}"

  # Удаляем пользователя изо всех php пулов
  mapfile -t installed_versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
  for installed in "${installed_versions[@]}"; do
    rm -f /etc/opt/remi/${installed}/php-fpm.d/${1}*
    if [ -z "$(find /etc/opt/remi/${installed}/php-fpm.d -maxdepth 1 -type f -name '*.conf')" ]; then
    # Если файлов .conf нет, проверяем наличие файла www.conf.old для переименования
      if [ -f "/etc/opt/remi/${installed}/php-fpm.d/www.conf.old" ]; then
          # Переименовываем файл www.conf.old в www.conf
          mv "/etc/opt/remi/${installed}/php-fpm.d/www.conf.old" "/etc/opt/remi/${installed}/php-fpm.d/www.conf"
          echo -e "Файл ${GREEN}www.conf${WHITE} восстановлен по умолчанию, так как все пулы этой версии php удалены."
      else
          echo -e "Файла ${RED}www.conf.old${WHITE} в папке пула ${RED}/etc/opt/remi/${installed}/php-fpm.d/${WHITE} нет!."
          echo "Невозможно восстановить его автоматически."
          echo -e "Нужно восстановить этот файл вручную, иначе ${installed} перестанет работать."
      fi
    fi
    if ! /opt/remi/${installed}/root/usr/sbin/php-fpm -t
    then
      echo "Ошибка в настройках. ${installed}-fpm не был перезагружен"
    else
      systemctl restart "${installed}-php-fpm"
      echo "${installed}-fpm был перезагружен"
    fi
  done
  gpasswd -d apache ${1}
  userdel --remove ${1}
  create_hotlist
  mariadb  -e "DROP USER IF EXISTS ${1}@localhost;"
  echo -e "Пользователь ${RED}$1${WHITE} был удален."
}

echo -e "${GREEN}System memory:${WHITE}"
free -m
echo ""

echo -e "${GREEN}Disk space:${WHITE}"
df -h -P -l -x tmpfs -x devtmpfs
echo ""

if ! grep -q "MYSQLPASS" ~/.bashrc; then
  STEP="Установка dnf-utils"
  if ! check_step "$STEP"; then
    Install dnf-utils
    mark_step_completed "$STEP"
  fi

  STEP="Проверка обновлений сервера выполнена"
  if ! check_step "$STEP"; then
    echo -n "Проверяем обновления сервера... "
    dnf check-update >/dev/null
    check_update_status=$?
    if ((check_update_status == 0)); then
      echo "Сервер не требует обновления"
    elif ((check_update_status == 100)); then
      Down
      echo ""
      echo 'Обновляем сервер? '
      echo 'Настоятельно рекомендуем обновить при первом запуске.'
      vertical_menu "current" 2 0 5 "Да" "Нет" "Выйти"
      ret=$?
      if ((ret > 1)); then
        exit 1
      fi
      if ((ret == 0)); then
        ((upperY--))
        Up
        echo
        echo -e "Идет обновление сервера..."${ERASEUNTILLENDOFLINE}
        Down
        if ! dnf update -y; then
          RemoveRim
          echo -e "${RED}Обновить сервер не удалось.${WHITE}"
          echo "Повторите установку после исправления ошибки обновления."
          exit 1
        fi
      fi
      Up
    else
      RemoveRim
      echo -e "${RED}Не удалось проверить обновления сервера.${WHITE}"
      echo "Повторите установку после исправления ошибки проверки обновлений."
      exit 1
    fi
    CheckRebootRequired
    mark_step_completed "$STEP"
  fi
  STEP="Установка языковых пакетов"
  if ! check_step "$STEP"; then
    Install langpacks-en glibc-all-langpacks
    mark_step_completed "$STEP"
  fi
fi


if ! grep -q "MYSQLPASS" ~/.bashrc; then
  # we think that it is the first run of the script
  STEP="Установка кодировки консоли"
  if ! check_step "$STEP"; then
    if localectl status | grep -q UTF-8; then
      echo
      echo -e "Кодировка консоли уже установлена правильно - ${GREEN}UTF-8${WHITE}."
    else
      localectl set-locale LANG=en_US.UTF-8
      echo
      echo -e "${VIOLET}\nБыла установлена кодировка UTF-8 для консоли.${WHITE}${RED} Надо перезагрузить сервер.${WHITE} "
      tet=$(pwd)
      echo -e "После перезагрузки запустите скрипт заново командой ${GREEN}${tet}/ri.sh${WHITE}"
      echo -e "Или войдите на сервер и нажмите стрелку ${GREEN}↑${WHITE} два раза: команда ${GREEN}/root/rish/ri.sh${WHITE} уже будет в истории команд."
      Down
      echo "Перезагрузить сервер?"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        echo "Перезагрузка сервера начата..."
        echo "/root/rish/ri.sh" >> /root/.bash_history
        reboot
        exit 0
      else
        RemoveRim
        echo -e "Перезагрузите сервер самостоятельно командой ${GREEN}reboot${WHITE}"
        exit 0
      fi
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Проверка и отключение SELinux если понадобится"
  if ! check_step "$STEP"; then
    if command -v sestatus >/dev/null 2>&1; then
      SELINUX_STATE=$(getenforce)
      if [ "$SELINUX_STATE" == "Enforcing" ] || [ "$SELINUX_STATE" == "Permissive" ]; then
        echo "SELinux is enabled"
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        echo
        echo -e "Включен ${RED}selinux${WHITE}."
        echo "Мы установили значение в конфигурационном файле для отключения selinux"
        echo "Вам остается только выполнить перезагрузку сервера."
        tet=$(pwd)
        Down
        echo -e "После перезагрузки запустите скрипт заново командой ${GREEN}${tet}/ri.sh${WHITE}"
        echo -e "Или войдите на сервер и нажмите стрелку ${GREEN}↑${WHITE} два раза: команда ${GREEN}/root/rish/ri.sh${WHITE} уже будет в истории команд."
        echo "Перезагрузить сервер?"
        if vertical_menu "current" 2 0 5 "Да" "Нет"; then
          echo "Перезагрузка сервера начата..."
          echo "/root/rish/ri.sh" >> /root/.bash_history
          reboot
          exit 0
        else
          RemoveRim
          echo -e "Перезагрузите сервер самостоятельно командой ${GREEN}reboot${WHITE}"
          echo -e "После перезагрузки запустите скрипт заново командой ${GREEN}${tet}/ri.sh${WHITE}"
          exit 0
        fi
      fi
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Проверка и включение swap файла, если нужно"
  if ! check_step "$STEP"; then
    Down
    create_swapfile
    Up
    mark_step_completed "$STEP"
  fi

  STEP="Выбор типа установки сервера"
  Down
  if ! check_step "$STEP"; then
    echo -e "Выберите тип установки:"
    echo -e "${GREEN}Боевой (production) сервер${WHITE} — для размещения сайтов, доступных из интернета."
    echo -e "${YELLOW}Локальный сервер${WHITE} — для разработки и тестирования:"
    echo -e "  при клонировании сайтов домен будет заменяться на ${GREEN}.test${WHITE},"
    echo -e "  будет предложена установка ${GREEN}Xdebug${WHITE},"
    echo -e "  в меню MC появятся инструменты для локальной сети."
    echo
    LocalServer=false
    while true; do
      vertical_menu "current" 2 0 5 "Установка боевого (production) сервера" "Установка локального сервера" "Выйти"
      ret=$?
      if ((ret > 1)); then
        RemoveRim
        echo -e "${YELLOW}Установка сервера прервана${WHITE}"
        echo -e "Продолжить установку можно, запустив команду ${GREEN}/root/rish/ri.sh${WHITE}"
        exit
      fi
      if ((ret == 1)); then
        echo -e "Вы выбрали ${YELLOW}локальную${WHITE} установку."
        echo "Этот режим предназначен для разработки и тестирования, а не для публичного сервера."
        echo -e "При клонировании сайтов домены будут заменяться на ${GREEN}.test${WHITE}."
        echo
        echo "Продолжить с локальной установкой?"
        vertical_menu "current" 2 0 5 "Да, установить локальный сервер" "Нет, вернуться к выбору"
        if (($? == 0)); then
          LocalServer=true
          add_var_if_not_exists "LocalServer" "LocalServer=true"
          Up
          echo -e "Установка ${YELLOW}локального${WHITE} сервера"
          Down
          break
        fi
        echo
        continue
      fi
      Up
      echo -e "Установка ${GREEN}боевого${WHITE} сервера"
      add_var_if_not_exists "LocalServer" "LocalServer=false"
      Down
      break
    done

    mark_step_completed "$STEP"
  else
    source $config_file
  fi

  STEP="Установка mc, cronie, logrotate, idn2, epel-release, wget, tar"
  if ! check_step "$STEP"; then
    Install mc
    Install cronie
    Install idn2
    if ! echo ${CURRENT_OS} | grep -qE "Fedora"; then
      Install epel-release
    fi
    Install wget
    Install tar
    Install glibc-gconv-extra
    Install logrotate
    TIMER_STATUS=$(systemctl is-active logrotate.timer 2>/dev/null)
    TIMER_ENABLED=$(systemctl is-enabled logrotate.timer 2>/dev/null)

    # Проверка и активация logrotate.timer
    if [ "$TIMER_STATUS" != "active" ] || [ "$TIMER_ENABLED" != "enabled" ]; then
        Up
        echo "logrotate.timer не активен или не включен. Пытаемся включить и запустить..."
        Down
        # Включаем и запускаем таймер
        systemctl enable logrotate.timer && systemctl start logrotate.timer

        # Повторная проверка
        NEW_TIMER_STATUS=$(systemctl is-active logrotate.timer 2>/dev/null)
        NEW_TIMER_ENABLED=$(systemctl is-enabled logrotate.timer 2>/dev/null)
        Up
        if [ "$NEW_TIMER_STATUS" == "active" ] && [ "$NEW_TIMER_ENABLED" == "enabled" ]; then
            echo -e "${GREEN}logrotate.timer${WHITE} успешно включен и запущен."
        else
            echo -e "Не удалось включить или запустить ${RED}logrotate.timer${WHITE}. Проверьте настройки вручную."
        fi
        Down
    else
        Up
        echo "logrotate.timer активен и включен."
        Down
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Установка pv"
  if ! check_step "$STEP"; then
    Install pv
    mark_step_completed "$STEP"
  fi

  STEP="Установка httpd mod_ssl"
  if ! check_step "$STEP"; then
    Install httpd mod_ssl mod_http2
    Up
    httpd -v
    echo
    Down
    mark_step_completed "$STEP"
  fi

  Down
  STEP="Настройка файла ssl.conf для включения по умолчанию http/2"
  if ! check_step "$STEP"; then
    sed -i "/^Protocols .*$/d" /etc/httpd/conf.d/ssl.conf
    sed -i "s|Listen 443 https.*$|Listen 443 https\nProtocols h2 http/1.1|" /etc/httpd/conf.d/ssl.conf
    mark_step_completed "$STEP"
  fi
  STEP="Настройка автозапуска httpd при перезагрузке. Запуск httpd сейчас."
  if ! check_step "$STEP"; then
    systemctl enable httpd
    echo
    systemctl start httpd
    echo
    mark_step_completed "$STEP"
  fi

  STEP="Удаление файла autoindex для httpd"
  if ! check_step "$STEP"; then
    rm -f /etc/httpd/conf.d/autoindex.conf
    mark_step_completed "$STEP"
  fi

  Up

  STEP="Установка прав 751 для /var/www"
  if ! check_step "$STEP"; then
    chown root:root /var/www
    chmod 751 /var/www
    mark_step_completed "$STEP"
  fi

  STEP="Настройка tmpfiles для прав /var/www"
  if ! check_step "$STEP"; then
    configure_httpd_tmpfiles_override || {
      echo "Не удалось настроить постоянные права /var/www через tmpfiles."
      RemoveRim
      exit 1
    }
    mark_step_completed "$STEP"
  fi

  STEP="Открытие портов 80 и 443 для web"
  if ! check_step "$STEP"; then
    OpenFirewall
    mark_step_completed "$STEP"
  fi

  STEP="Закрытие портов cockpit"
  if ! check_step "$STEP"; then
    if ! ${LocalServer}; then
      # Проверяем наличие службы cockpit
      if firewall-cmd --get-services | grep -qw cockpit; then
        Down
        echo -e "Закрываем порт доступа ${GREEN}cockpit${WHITE}?"
        echo "Если не знаете что это такое — закрывайте"
        if vertical_menu "current" 2 0 5 "Да" "Нет"; then
          ZoneName="$(firewall-cmd --get-default-zone)"
          if firewall-cmd --get-zones | grep -qw "$ZoneName"; then
            firewall-cmd --zone="${ZoneName}" --remove-service=cockpit --permanent
            firewall-cmd --reload
          else
            echo -e "${YELLOW}Зона firewalld ${ZoneName} не найдена, cockpit не изменён${WHITE}"
          fi
        fi
        Up
      else
        echo -e "${YELLOW}Служба cockpit${WHITE} не найдена, шаг пропущен"
      fi
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Отключение heartbeat module apache"
  if ! check_step "$STEP"; then
    echo -e "Отключаем heartbeat module и перезапускаем ${GREEN}apache${WHITE}"
    sed -i "s/LoadModule lbmethod_heartbeat_module/#LoadModule lbmethod_heartbeat_module/" /etc/httpd/conf.modules.d/00-proxy.conf
    sed -i "s/##/#/" /etc/httpd/conf.modules.d/00-proxy.conf
    mark_step_completed "$STEP"
  fi
  STEP="Замена стандартной заглушки Alma на заглушку RISH"
  if ! check_step "$STEP"; then
    if [[ ! -f "${RISH_HOME}/templates/apache-noindex.html" ]]; then
      install -m 644 "${RISH_HOME}/templates/default-apache-noindex.html" "${RISH_HOME}/templates/apache-noindex.html" &>>"$LOG_FILE" || exit 1
    fi
    install -D -m 644 "${RISH_HOME}/templates/apache-noindex.html" /usr/share/httpd/noindex/index.html &>>"$LOG_FILE" || exit 1
    mark_step_completed "$STEP"
  fi
  STEP="Проверка на наличие ServerName и исправление если его нет."
  if ! check_step "$STEP"; then
    if systemctl status httpd.service -l --no-pager -n 3 | grep "Could not"; then
      echo "Устанавливаем имя сервера как localhost"
      sed -i "s|#ServerName .*$|ServerName localhost|" /etc/httpd/conf/httpd.conf
      systemctl restart httpd.service
    fi
    mark_step_completed "$STEP"
  fi
  STEP="Перезапуск httpd"
  if ! check_step "$STEP"; then
    Down
    apachectl restart
    Up
    mark_step_completed "$STEP"
  fi

  STEP="Установка htop"
  if ! check_step "$STEP"; then
    Install htop
    mark_step_completed "$STEP"
  fi

  STEP="Настройка репозиториев для установки php"
  if ! check_step "$STEP"; then
    echo -e "Ставим репозиторий ${GREEN}Remi Collet${WHITE} для установки ${GREEN}PHP${WHITE}"
    Down
    if echo ${CURRENT_OS} | grep -qE "Fedora"; then
      FedoraVersion=$(cat /etc/fedora-release | sed 's@^[^0-9]*\([0-9]\+\).*@\1@')
      dnf install -y https://rpms.remirepo.net/fedora/remi-release-${FedoraVersion}.rpm
      dnf config-manager --set-enabled remi
    else
      if ! dnf install -y https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION}.rpm
      then
        echo -e "${RED}Ошибка${WHITE} при попытке установить репозитарий ${GREEN}Remi Collet${WHITE} для установки ${GREEN}PHP${WHITE}"
        exit 1
      fi
    fi
    Up
    mark_step_completed "$STEP"
  fi

  STEP="Установка php"
  if ! check_step "$STEP"; then
    echo -e "Выбор и установка нужных версий ${GREEN}PHP${WHITE}"
    Down
    echo -e "Идет получение списка доступных версий ${GREEN}PHP${WHITE}. Ждите."
    php_multi_install
    Up
    mark_step_completed "$STEP"
    echo -e "Установка выбранных версий ${GREEN}PHP${WHITE} завершена."
  fi

  Down

  STEP="Настройка файлов logrotate для httpd."
  if ! check_step "$STEP"; then
    sed -i "s/^#compress/compress/" /etc/logrotate.conf

    if ! grep -q "daily" /etc/logrotate.d/httpd; then
      sed -i "s/missingok/missingok\n    daily/" /etc/logrotate.d/httpd
    fi

    if ! grep -q "/var/www/*/logs/*log" /etc/logrotate.d/httpd; then
      echo "/var/www/*/logs/*log {" >>/etc/logrotate.d/httpd
      echo " missingok" >>/etc/logrotate.d/httpd
      echo " daily" >>/etc/logrotate.d/httpd
      echo " maxsize 50M" >>/etc/logrotate.d/httpd
      echo " notifempty" >>/etc/logrotate.d/httpd
      echo " sharedscripts" >>/etc/logrotate.d/httpd
      echo " delaycompress" >>/etc/logrotate.d/httpd
      echo " postrotate" >>/etc/logrotate.d/httpd
      echo "  /bin/systemctl reload httpd.service > /dev/null 2>/dev/null || true" >>/etc/logrotate.d/httpd
      echo " endscript" >>/etc/logrotate.d/httpd
      echo "}" >>/etc/logrotate.d/httpd
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Установка часового пояса."
  if ! check_step "$STEP"; then
    Up
    echo -e "Устанавливаем ${GREEN}время${WHITE}:"
    Down
    current_timezone="$(readlink -f /etc/localtime 2>/dev/null)"
    current_timezone="${current_timezone#/usr/share/zoneinfo/}"
    if [[ -z "$current_timezone" || "$current_timezone" == "/etc/localtime" ]]; then
      current_timezone="$(timedatectl show -p Timezone --value 2>/dev/null)"
    fi
    [[ -n "$current_timezone" ]] || current_timezone="не удалось определить"

    echo -e "Выберите часовой пояс:"
    vertical_menu "current" 2 0 45 "Москва (Europe/Moscow)" "Астана, Казахстан (Asia/Almaty)" "Киев (Europe/Kyiv)" "Оставить текущий (${current_timezone})"
    case "$?" in
      0)
        ln -sfn /usr/share/zoneinfo/Europe/Moscow /etc/localtime
        ;;
      1)
        ln -sfn /usr/share/zoneinfo/Asia/Almaty /etc/localtime
        ;;
      2)
        ln -sfn /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
        ;;
    esac
    Up
    date
    Down
    mark_step_completed "$STEP"
  fi

  STEP="Установка unzip"
  if ! check_step "$STEP"; then
    Install unzip
    mark_step_completed "$STEP"
  fi

  STEP="Установка jq и rclone"
  if ! check_step "$STEP"; then
    Install jq
    Install rclone
    mark_step_completed "$STEP"
  fi

  STEP="Установка bind-utils"
  if ! check_step "$STEP"; then
    Install bind-utils
    mark_step_completed "$STEP"
  fi

  STEP="Установка openssl"
  if ! check_step "$STEP"; then
    Up
    echo -e "Устанавливаем ${GREEN}OpenSSL${WHITE}:"
    if ! rpm -q openssl >/dev/null 2>&1; then
      Down
      Install openssl
      Up
      mark_step_completed "$STEP"
    else
      echo -e "${GREEN}openssl${WHITE} уже установлен, пропускаем установку."
      mark_step_completed "$STEP"
    fi
  fi

  STEP="Создание самоподписанного сертификата SSL на 10 лет"
  if ! check_step "$STEP"; then
    Up
    echo -e "Генерируем ${GREEN}самоподписанный сертификат${WHITE} SSL на 10 лет"
    Down
    openssl req -new -days 3650 -x509 \
      -subj "/C=RU/ST=Moscow/L=Springfield/O=Dis/CN=www.example.com" \
      -nodes -out /etc/pki/tls/certs/localhost.crt \
      -keyout /etc/pki/tls/private/localhost.key
    mark_step_completed "$STEP"
  fi

  STEP="Создание хоста для ответа на обращения к несуществующим сайтам."
  if ! check_step "$STEP"; then
    cd /var/www/html

    Up
    echo -e "Создаем хост для ответа сервера на обращения к ${GREEN}несуществующим сайтам${WHITE} 000-default"
    Down
    if [[ ! -d 000-default ]]; then
      mkdir 000-default
    else
      echo -e "каталог ${GREEN}000-default${WHITE} уже создан"
    fi

    install -m 644 "${RISH_HOME}/templates/000-default.conf" /etc/httpd/conf.d/000-default.conf
    install -m 644 "${RISH_HOME}/templates/000-default-ssl.conf" /etc/httpd/conf.d/000-default-ssl.conf

    apachectl restart || {
      echo "Ошибка при перезапуске Apache. Скрипт остановлен."
      RemoveRim
      exit 1
    }

    mark_step_completed "$STEP"
  fi

  pass=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16 | xargs)
  MYSQLPASS=${pass}

  STEP="Установка mcedit как основного редактора"
  if ! check_step "$STEP"; then
    cd ~
    if ! grep -q "EDITOR" ~/.bashrc; then
      echo "export EDITOR=mcedit" >>~/.bashrc
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Настройка задержки клавиши Esc в Midnight Commander"
  if ! check_step "$STEP"; then
    if ! grep -q '^export KEYBOARD_KEY_TIMEOUT_US=' ~/.bashrc; then
      echo "export KEYBOARD_KEY_TIMEOUT_US=100000" >>~/.bashrc
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Установка репозиториев для MariaDB"
  if ! check_step "$STEP"; then
    Up
    echo
    echo -e "Установка и настройка репозиториев для ${GREEN}MariaDB${WHITE}."
    Down
    cd /etc/yum.repos.d/

    echo
    echo -e "${GREEN}MariaDB${WHITE} на данный момент имеет 5 релизов с долгосрочной поддержкой:"
    echo "10.6  со сроком поддержки до 6 июля 2026"
    echo "10.11 со сроком поддержки до 16 февраля 2028"
    echo -e "${GREEN}11.4${WHITE}  со сроком поддержки до 29 мая 2029"
    echo "11.8  со сроком поддержки до 4 июня 2028"
    echo "12.3  со сроком поддержки до мая 2029"
    echo
    echo "Какой релиз ставить?"
    while true; do
      Maria_Version_Custom=0
      vertical_menu "current" 2 0 10 default=2 "MariaDB 10.6" "MariaDB 10.11" "MariaDB 11.4" "MariaDB 11.8" "MariaDB 12.3" "Ввести другую версию вручную"
      choice=$?
      case "$choice" in
      0)
        Maria_Version="10.6"
        ;;
      1)
        Maria_Version="10.11"
        ;;
      2)
        Maria_Version="11.4"
        ;;
      3)
        Maria_Version="11.8"
        ;;
      4)
        Maria_Version="12.3"
        ;;
      5)
        Maria_Version_Custom=1
        echo -e -n "Введите версию MariaDB в формате ${GREEN}X.Y${WHITE} (пустая строка для возврата в меню): ${GREEN}"
        read -r -e Maria_Version
        echo -e -n "${WHITE}"
        if [[ -z "$Maria_Version" ]]; then
          continue
        fi
        if [[ ! "$Maria_Version" =~ ^[0-9]+\.[0-9]+$ ]]; then
          echo -e "${RED}Некорректная версия.${WHITE} Используйте формат X.Y, например 12.2."
          continue
        fi
        ;;
      *)
        continue
        ;;
      esac

      echo -e "Выбрана версия ${GREEN}${Maria_Version}${WHITE}"

      if ! bash /root/rish/scripts/mariadb_repo_setup.sh --mariadb-server-version="${Maria_Version}" --skip-maxscale
      then
        if ((Maria_Version_Custom)); then
          echo -e "${RED}Указанная версия MariaDB недоступна.${WHITE} Выберите другую версию."
          continue
        fi
        {
          echo "[mariadb]"
          echo "name = MariaDB"
          echo "# rpm.mariadb.org is a dynamic mirror if your preferred mirror goes offline. See https://mariadb.org/mirrorbits/ for details."
          echo "# baseurl = https://rpm.mariadb.org/${Maria_Version}/rhel/\$releasever/\$basearch"
          echo "baseurl = https://mirror.docker.ru/mariadb/yum/${Maria_Version}/rhel/\$releasever/\$basearch"
          echo "module_hotfixes = 1"
          echo "# gpgkey = https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB"
          echo "gpgkey = https://mirror.docker.ru/mariadb/yum/RPM-GPG-KEY-MariaDB"
          echo "gpgcheck = 1"
        } >mariadb.repo
      fi
      break
    done
    mark_step_completed "$STEP"
  fi

  STEP="Установка MariaDB"
  if ! check_step "$STEP"; then
    Up
    echo
    echo -e "Установка ${GREEN}MariaDB${WHITE} в качестве базы данных."
    Down
    mariadb_install
    mark_step_completed "$STEP"
  fi

  STEP="Установка certbot"
  if ! check_step "$STEP"; then
    Up
    echo
    Down
    echo -e "Установить ${GREEN}certbot${WHITE} для получения SSL-сертификатов?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      Install certbot python3-certbot-apache
      echo "───────────────────────────────────────"
      echo -e "Регистрация ${GREEN}аккаунта Let's Encrypt${WHITE}..."
      echo -e "Email не требуется, регистрация будет выполнена без него."
      echo "───────────────────────────────────────"
      certbot register \
        --agree-tos \
        --register-unsafely-without-email \
        --non-interactive
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Отключить почтовую службу"
  if ! check_step "$STEP"; then
    Up
    echo "Если есть почтовая служба - отключаем и останавливаем"
    Down
    if systemctl status postfix; then
      systemctl stop postfix
      systemctl disable postfix
      systemctl status postfix
      Up
      echo -e "${GREEN}Почтовая служба остановлена.${WHITE}"
      Down
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Делаем сервис apache автоматически перезапускаемым, в случае какого либо падения."
  if ! check_step "$STEP"; then
    Up
    echo
    echo "Делаем сервис apache автоматически перезапускаемым, в случае какого либо падения."
    echo "Сервер будет пытаться перезапустить apache каждые 3 минуты в случае падения."
    Down
    if [[ ! -d /etc/systemd/system/httpd.service.d ]]; then
      mkdir /etc/systemd/system/httpd.service.d
    fi
    cat >/etc/systemd/system/httpd.service.d/local.conf <<EOF
[Service]
Restart=always
RestartSec=180
EOF
    Up
    echo -e "Перезапускаем сервер ${GREEN}apache${WHITE} после настройки"
    Down
    systemctl daemon-reload
    systemctl restart httpd
    mark_step_completed "$STEP"
  fi

  STEP="Делаем сервис базы данных автоматически запускаемым, в случае какого либо падения"
  if ! check_step "$STEP"; then
    Up
    echo
    echo "Делаем сервис базы данных автоматически запускаемым, в случае какого либо падения."
    echo "Сервер будет пытаться перезапустить базу каждые 3 минуты в случае падения."
    Down
    if [[ ! -d /etc/systemd/system/mariadb.service.d ]]; then
      mkdir /etc/systemd/system/mariadb.service.d
    fi
    cat >/etc/systemd/system/mariadb.service.d/local.conf <<EOF
[Service]
Restart=always
RestartSec=180
EOF

    Up
    echo
    echo -e "Перезапускаем службу ${GREEN}баз данных${WHITE} после настройки"
    Down
    systemctl daemon-reload
    systemctl restart mariadb
    Up
    echo -e "Установка и настройка ${GREEN}MariaDB завершена.${WHITE}"
    Down
    mark_step_completed "$STEP"
  fi

  RemoveRim

  STEP="Создание меню для MC и папки для hotlist"
  if ! check_step "$STEP"; then
    mkdir -p ~/.config/mc
    cd ${RISH_HOME}
    if [[ -e "${RISH_HOME}/templates/mc.menu" ]]; then
      rm /etc/mc/mc.menu
      cp "${RISH_HOME}/templates/mc.menu" /etc/mc/mc.menu
      if ${LocalServer}; then
        cat "${RISH_HOME}/templates/mc.menu.local" >> /etc/mc/mc.menu
      fi
    fi
    v=$(tr -d '\r' < /root/rish/version | awk '{$1=$1;print}')
    sed -i "s/{VER}/$v/g" /etc/mc/mc.menu
    mark_step_completed "$STEP"
  fi

  STEP="Настройка ssh config для sftp пользователя на сайте"
  if ! check_step "$STEP"; then

    if [[ $(getent group sftp) ]]; then
      echo ""
    else
      groupadd sftp
    fi

    # редактируем /etc/ssh/sshd_config.
    ## override default of no subsystems
    ##Subsystem<---->sftp<-->/usr/libexec/openssh/sftp-server
    #Subsystem sftp internal-sftp -u 022
    #Match Group sftp
    #ChrootDirectory /var/www/%u
    #ForceCommand internal-sftp -u 022

    sed -i '/Match Group sftp/d' /etc/ssh/sshd_config
    sed -i '/ChrootDirectory \/var\/www\/%u/d' /etc/ssh/sshd_config
    sed -i '/ForceCommand internal-sftp -u 022/d' /etc/ssh/sshd_config
    r="Subsystem sftp internal-sftp -u 022\n"
    r=${r}"Match Group sftp\n"
    r=${r}"ChrootDirectory /var/www/%u\n"
    r=${r}"ForceCommand internal-sftp -u 022"
    sed -i "s&^Subsystem.*&${r}&" /etc/ssh/sshd_config
    systemctl restart sshd

  fi

  STEP="Создание первого пользователя"
  if ! check_step "$STEP"; then
    echo ""
    echo ""
    echo -e "Теперь ${GREEN}создаем${WHITE} пользователя для работы с сайтом. "
    echo "Имя пользователя набирается латинскими буквами без спецсимволов, тире и точек."

    CreateUser "siteuser"
    mark_step_completed "$STEP"
  fi

  STEP="Предлагаем создать ключ доступ к серверу и вывести его на экран для копирования."
  if ! check_step "$STEP"; then
    echo -e "${RED}Не забудьте${WHITE} добавить свой открытый (public) ключ для авторизации без пароля."
    echo -e ""
    echo -e "Скрипт может добавить ваш публичный ключ доступа на сервер самостоятельно, а приватный показать здесь,"
    echo -e "Чтобы вы смогли скопировать его на свой компьютер через буфер обмена."
    echo -e "Показать? "
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      clear
      ssh-keygen -t ed25519 -C "rish-key" -f "/root/.ssh/rish-key" -N '' >/dev/null 2>&1
      cat "/root/.ssh/rish-key"
      cat "/root/.ssh/rish-key.pub" >>/root/.ssh/authorized_keys 2>/dev/null
      echo
      echo
      echo -e "${VIOLET}Внимание!${WHITE}"
      echo -e "Копировать ключ надо целиком, включая пустую строку за ним!"
      echo -e "Последняя строка обязательно должна заканчиваться переводом строки!"
      echo -e "Иначе при подключении вы получите сообщение о неверном формате ключа."
      echo
      echo -e "После того как скопируете этот ключ, нажмите Enter, чтобы очистить экран"
      echo -e "Оба файла ключа после этого будут уничтожены, но вы сможете подключиться с сохраненным ключом."
      vertical_menu "current" 2 0 5 "Очистить экран"
      rm -f /root/.ssh/rish-key /root/.ssh/rish-key.pub
      clear
      echo -e "Советуем сейчас подключиться к серверу заново в ${VIOLET}соседнем окне.${WHITE}"
      echo -e "${VIOLET}Это окно оставьте открытым,${WHITE} чтобы решить проблемы с доступом, если у вас не получится подключиться."
    else
      echo -e "С помощью команды ${GREEN}mcedit /root/.ssh/authorized_keys${WHITE} откройте файл и добавьте туда свой открытый ключ."
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Настройка способов авторизации SSH через 00-rish.conf"
  if ! check_step "$STEP"; then
    echo
    echo -e "Советуем запретить авторизацию по паролю при доступе по ${GREEN}SSH${WHITE}."
    echo -e "Вы всегда сможете авторизоваться по паролю на сервере через VNC."
    echo -e "Запретить авторизацию по ${VIOLET}паролю${WHITE} для SSH?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      echo -e -n "${CURSORUP}"
      if configure_ssh_password_authentication no; then
        echo -e "Авторизация по паролю для SSH ${GREEN}запрещена${WHITE}.${ERASEUNTILLENDOFLINE}"
        mark_step_completed "$STEP"
      fi
    else
      echo -e -n "${CURSORUP}"
      if configure_ssh_password_authentication yes; then
        echo -e "Авторизация по паролю для SSH ${YELLOW}разрешена${WHITE}.${ERASEUNTILLENDOFLINE}"
        mark_step_completed "$STEP"
      fi
    fi
  fi

  STEP="Обновление hotlist"
  if ! check_step "$STEP"; then
    # Для совместимости с postupdate
    mark_step_completed "$STEP"
  fi

  STEP="Финальная проверка необходимости перезагрузки сервера"
  if ! check_step "$STEP"; then
    CheckRebootRequired
    mark_step_completed "$STEP"
  fi

  STEP="Устанавливаем признак выполненной настройки сервера"
  if ! check_step "$STEP"; then
    echo -e "Конфигурирование сервера ${GREEN}завершено${WHITE}."
    echo
    if ! grep -q "MYSQLPASS" ~/.bashrc; then
      # Устанавливаем признак выполненной настройки сервера
      echo "export MYSQLPASS="${SCRIPTVERSION} >>~/.bashrc
      export MYSQLPASS=${SCRIPTVERSION}
    fi
    vertical_menu "current" 2 0 5 "Нажмите Enter"
    mark_step_completed "$STEP"
  fi

else
  source "${RISH_HOME}/scripts/server_management.sh"
  ServerManagementMenu
fi
