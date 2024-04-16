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
CURSORUP='\033[1A'
ERASEUNTILLENDOFLINE='\033[K'
ServerArch=$( arch )
OS_VERSION=$( hostnamectl | grep -Eo 'Operating.*' |  sed 's@^[^0-9]*\([0-9]\+\).*@\1@' )

SUPPORTED_OS='Fedora|Rocky|AlmaLinux|CentOS|Red Hat Enterprise Linux Server'
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

# convert to absolute path
_script_dir=$(cd ${_script_dir}; pwd -P)

export RISH_HOME=${_script_dir}

cd ${RISH_HOME} || exit

source windows.sh
source clonesite.sh
source checkip.sh
source php_multi_install.sh
source mariadb_install.sh
source create_hotlist.sh

if (( lines < 40 || columns < 140 )); then
  echo
  echo "Размер окна вашего терминала слишком маленький."
  echo -e "Советуем увеличить окно терминала до размера ${RED}140x40${WHITE} символов."
  echo "Иначе вывод на экран возможно будет некорректным."
  echo
  if vertical_menu "current" 2 0 5  "Остановить выполнение скрипта установки" "Хорошо понятно. Продолжаем"
  then
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
    # ограничить скрол нижней частью экрана
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
if (type lsb_release > /dev/null 2>&1); then
  CURRENT_OS=$(lsb_release -d -s)
  echo -e "Ваша версия Linux: ${RED}$CURRENT_OS${WHITE}"
elif [[ -f /etc/system-release ]]; then
  CURRENT_OS=$(head -1 /etc/system-release)
  echo -e "Ваша версия Linux: ${GREEN}$CURRENT_OS${WHITE}"
  echo
elif [[ -f /etc/issue ]]; then
  CURRENT_OS=$(head -2 /etc/issue)
  echo -e "Ваша версия Linux: ${RED}$CURRENT_OS${WHITE}"
else
  echo -e "${RED}Невозможно определить вашу версию Linux${WHITE}"
  exit 1
fi
if ! echo ${CURRENT_OS} | egrep -q "$SUPPORTED_OS"
then
   echo -e "Ваш дистрибутив Linux ${RED}не поддерживается${WHITE}"
   exit 1
fi
if echo ${CURRENT_OS} | grep -Eq "Fedora"
then
  FedoraVersion=$( cat /etc/fedora-release | sed 's@^[^0-9]*\([0-9]\+\).*@\1@' )
fi


Install() {
    if ! rpm -q $@ >/dev/null 2>&1; then
        Up
        echo -e "Ставим ${GREEN}$@${WHITE}"
        Down
        if yum -y install $@; then
            (( upperY -- ))
            Up
            echo -e "${GREEN}$@${WHITE} установлен"
        else
            Up
            echo -e "Установить ${RED}$@${WHITE} не удалось, очищаем кэш и пытаемся снова"
            # Очистка кэша yum и повторная попытка установки
            Down
            yum clean all
            yum makecache
            if yum -y install $@; then
                Up
                echo -e "${GREEN}$@${WHITE} установлен после очистки кэша"
            else
                Up
                echo -e "Установить ${RED}$@${WHITE} не удалось даже после очистки кэша"
                RemoveRim
                exit 1
            fi
        fi
        echo
    else
        Up
        echo -e "${GREEN}$@${WHITE} уже установлен"
    fi
    Down
}


OpenFirewall() {
    if command -v firewall-cmd >/dev/null 2>&1  && systemctl status firewalld  >/dev/null
    then
        if firewall-cmd --list-all  | grep http > /dev/null && firewall-cmd --list-all  | grep https > /dev/null
        then
            echo -e "${GREEN}Firewall${WHITE} уже открыт"
        else
            echo -e "Открываем ${GREEN}firewall${WHITE}"
            Down
            ZoneName=$(firewall-cmd --get-default-zone)
            firewall-cmd --zone=${ZoneName} --permanent --add-service=http
            firewall-cmd --zone=${ZoneName} --permanent --add-service=https
            firewall-cmd --reload
            Up
        fi
    else
        echo -e "${GREEN}Firewall${WHITE} не установлен"
        Install "firewalld"
        Down
        systemctl enable firewalld
        systemctl start firewalld
        ZoneName=$(firewall-cmd --get-default-zone)
        firewall-cmd --zone=${ZoneName} --permanent --add-service=http
        firewall-cmd --zone=${ZoneName} --permanent --add-service=https
        firewall-cmd --reload
        Up
    fi
}

# shellcheck disable=SC2120
CreateUser() {
  local NAME
  local default_username="$1"  # Получаем первый параметр, переданный в функцию
  # try to create user

  while true; do
    echo -e "При создании пользователя используйте только латинские буквы."
    echo -e -n "${WHITE}Введите имя пользователя (для выхода наберите EXIT):${GREEN}"
    if [[ -z "$default_username" ]]; then
      read -e -p " " NAME  # Не задаем значение по умолчанию, если параметр пустой
    else
      read -e -p " " -i "$default_username" NAME  # Используем переданный параметр как значение по умолчанию
    fi
    if [[ -z "${NAME}" ]]
    then
      continue
    fi
    if  [[ ${NAME} == "EXIT" ]] || [[ ${NAME} == "exit" ]]
    then
      break
    fi
    NAME=$( echo ${NAME} | tr -cd "[:alnum:]")
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
  echo -e ${WHITE}
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

  chmod go-rwx /home/${NAME}/.pass.txt
  chown ${NAME}:${NAME} /home/${NAME}/.pass.txt

  echo -e "Пароли записаны в файл ${GREEN}/home/${NAME}/.pass.txt${WHITE}"
  if [[ $(getent group sftp) ]]; then
    echo ""
  else
     groupadd sftp
  fi
  usermod -a -G sftp ${NAME}
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
  usermod -aG ${NAME} apache
  mkdir /var/www/${NAME}
  mkdir /var/www/${NAME}/logs
  mkdir /var/www/${NAME}/www
  chown ${NAME}:${NAME} /var/www/${NAME}/www
  chown ${NAME}:${NAME} /var/www/${NAME}/logs

  # устанавливаем владельцем siteuser
  # создаем папку /home/siteuser/.ssh
  mkdir /home/${NAME}/.ssh
  chown ${NAME}:${NAME} /home/${NAME}/.ssh

  # создаем файл /home/siteuser/.ssh/authorized_keys для ключей доступа для юзера
  echo "" > /home/${NAME}/.ssh/authorized_keys
  chown ${NAME}:${NAME} /home/${NAME}/.ssh/authorized_keys

  # Создаем папки и устанавливаем их владельцем siteuser
  mkdir /var/www/${NAME}/session
  mkdir /var/www/${NAME}/wsdlcache
  mkdir /var/www/${NAME}/slowlog

  chown ${NAME}:${NAME} /var/www/${NAME}/session
  chown ${NAME}:${NAME} /var/www/${NAME}/wsdlcache
  chown ${NAME}:${NAME} /var/www/${NAME}/slowlog

  # Удаляем конфигурацию php по умолчанию (это файлы типа php74-php.conf)
  find /etc/httpd/conf.d -type f -name 'php[0-9][0-9]-php.conf' -exec rm -f {} +

  create_hotlist

  if mysql  -e "CREATE USER ${NAME}@localhost IDENTIFIED BY '${pass2}';"
  then
    echo -e "пользователь ${GREEN}${NAME}${WHITE} успешно создан"
  else
    echo -e "во время создания пользователя ${RED}${NAME}${WHITE} MySQL произошла ошибка"
  fi
}

DeleteDatabase() {
     echo -e "Вы хотите удалить базу данных ${LRED}${1}${WHITE}?"
    if vertical_menu "current" 2 0 5 "Нет" "Да"
    then
      echo "База данных не была удалена"
      return 1
       elif (( $? == 255 ))
       then
      echo "База данных не была удалена"
      return 1
    fi
    echo -e ${CURSORUP}${ERASEUNTILLENDOFLINE}
    if mysqladmin -f  drop ${1}
    then
       echo -e "База данных ${GREEN}${1}${WHITE} удалена"
    else
       echo -e "При удалении базы данных ${RED}${1}${WHITE} произошли ${RED}ошибки${WHITE}"
    fi
}
DeleteUser() {
  # если папка не пуста, то отказываться удалять пользователя
  if [[ -n $( ls -A /var/www/${1}/www ) ]]
  then
    echo "У пользователя есть неудаленные сайты. Вначале удалите их."
    echo -e -n ${RED}
    cd /var/www/${1}/www
    # выводим директории
    ls -d */ | cut -f1 -d'/'
    # и файлы
    echo -e -n ${LRED}
    ls -Sp | grep -v '/'
    echo -e ${WHITE}
    return 1
  fi
  # проверим на предмет неудаленных баз данных
  SiteuserMysqlPass=`cat /home/${1}/.pass.txt | grep Database | awk '{ print $2}'`
  bases=( `mysql -u${1} -p${SiteuserMysqlPass}  --batch -e "SHOW DATABASES" | tail -n +3` )
  if (( ${#bases[@]} > 0 ))
  then
    echo "У пользователя есть неудаленные базы данных:"
    echo -e ${RED}
    for i in "${bases[@]}"; do
      echo ${i}
    done
    echo -e ${WHITE}
    echo "Вначале удалите их"
    return 1
  fi
  echo -e "Удалить пользователя ${RED}${1}${WHITE}?"

  if vertical_menu "current" 2 0 5 "Нет" "Да"
  then
    echo -e ${CURSORUP}"Пользователь ${GREEN}$1${WHITE} не удален."
    return 1
  fi
  rm -rf /var/www/${1}

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
  mysql  -e "DROP USER IF EXISTS ${1}@localhost;"
  echo -e "Пользователь ${RED}$1${WHITE} был удален."
}

echo -e "${GREEN}System memory:${WHITE}"
free -m
echo ""

echo -e "${GREEN}Disk space:${WHITE}"
df -h -P -l -x tmpfs -x devtmpfs
echo ""

if ! grep -q "MYSQLPASS" ~/.bashrc; then
  STEP="Проверка обновлений сервера выполнена"
  if ! check_step "$STEP"; then
    echo -n "Проверяем обновления сервера... "
    if dnf check-update >/dev/null; then
      echo "Сервер не требует обновления"
    else
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
        yum update -y
      fi
      Up
    fi
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
      Down
      echo "Перезагрузить сервер?"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        echo "Перезагрузка сервера начата..."
        reboot
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
        echo "Перезагрузить сервер?"
        if vertical_menu "current" 2 0 5 "Да" "Нет"; then
          echo "Перезагрузка сервера начата..."
          reboot
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

  STEP="Выбор типа установки сервера"
  Down
  if ! check_step "$STEP"; then
    echo -e "Начать ${GREEN}установку${WHITE} сервера?"
    LocalServer=false
    vertical_menu "current" 2 0 5 "Установка боевого (production) сервера" "Установка локального сервера" "Выйти"
    ret=$?
    if ((ret > 1)); then
      RemoveRim
      echo -e "${RED}Установка сервера прервана${WHITE}"
      exit
    fi
    if ((ret == 1)); then
      LocalServer=true
      add_var_if_not_exists "LocalServer" "LocalServer=true"
      Up
      echo -e "Установка ${VIOLET}локального${WHITE} сервера"
      Down
    else
      Up
      echo -e "Установка ${RED}боевого${WHITE} сервера"
      add_var_if_not_exists "LocalServer" "LocalServer=false"
      Down
    fi

    mark_step_completed "$STEP"
  else
    source $config_file
  fi

  STEP="Установка mc, cronie, logrotate, idn2, epel-release, wget, tar"
  if ! check_step "$STEP"; then
    Install mc
    Install cronie
    Install logrotate
    Install idn2
    if ! echo ${CURRENT_OS} | egrep -q "Fedora"; then
      Install epel-release
    fi
    Install wget
    Install tar
    mark_step_completed "$STEP"
  fi

  STEP="Установка telnet"
  if ! check_step "$STEP"; then
    if ${LocalServer}; then
      Install "telnet"
    fi
    mark_step_completed "$STEP"
  fi

  STEP="Установка httpd mod_ssl"
  if ! check_step "$STEP"; then
    Install "httpd mod_ssl"
    Up
    httpd -v
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

  STEP="Открытие портов 80 и 443 для web"
  if ! check_step "$STEP"; then
    OpenFirewall
    mark_step_completed "$STEP"
  fi

  STEP="Закрытие портов cockpit"
  if ! check_step "$STEP"; then
    if ! ${LocalServer}; then
      Down
      echo -e "Закрываем порт доступа ${GREEN}cockpit${WHITE}?"
      echo "Если не знаете что это такое - закрывайте"
      if vertical_menu "current" 2 0 5 "Да" "Нет"; then
        firewall-cmd --zone="${ZoneName}" --remove-service=cockpit --permanent
        firewall-cmd --reload
      fi
      Up
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
    rm -f /usr/share/httpd/noindex/index.html &>>$LOG_FILE
    cp ${RISH_HOME}/index.html /usr/share/httpd/noindex/index.html &>>$LOG_FILE
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
    Install "htop"
    mark_step_completed "$STEP"
  fi

  STEP="Настройка репозиториев для установки php"
  if ! check_step "$STEP"; then
    echo -e "Ставим репозиторий ${GREEN}Remi Collet${WHITE} для установки ${GREEN}PHP${WHITE}"
    Down
    if echo ${CURRENT_OS} | egrep -q "Fedora"; then
      FedoraVersion=$(cat /etc/fedora-release | sed 's@^[^0-9]*\([0-9]\+\).*@\1@')
      dnf install -y https://rpms.remirepo.net/fedora/remi-release-${FedoraVersion}.rpm
      dnf config-manager --set-enabled remi
    else
      dnf install -y https://rpms.remirepo.net/enterprise/remi-release-${OS_VERSION}.rpm
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

  STEP="Установка часового пояса для Москвы."
  if ! check_step "$STEP"; then
    Up
    echo -e "Устанавливаем ${GREEN}время${WHITE}:"
    Down
    echo -e "Ставим ${GREEN}Московское время${WHITE}?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      mv /etc/localtime /etc/localtime.bak
      ln -s /usr/share/zoneinfo/Europe/Moscow /etc/localtime
    fi
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

    cd /etc/httpd/conf.d
    {
      echo "<VirtualHost *:80>"
      echo "ServerAdmin webmaster@localhost"
      echo "ServerName 000-default"
      echo "ServerAlias www.000-default"
      echo "DocumentRoot /var/www/html/000-default"
      echo "<Directory /var/www/html/000-default>"
      echo "    Options -Indexes +FollowSymLinks"
      echo "    AllowOverride All"
      echo "    Order allow,deny"
      echo "    allow from all"
      echo "</Directory>"
      echo "ServerSignature Off"
      echo "ErrorLog /var/log/httpd/000-default-error-log"
      echo "LogLevel warn"
      echo "CustomLog /var/log/httpd/000-default-access-log combined"
      echo "</VirtualHost>"
    } >000-default.conf

    {
      echo "<VirtualHost *:443>"
      echo "ServerAdmin webmaster@localhost"
      echo "ServerName 000-default"
      echo "ServerAlias www.000-default"
      echo "DocumentRoot /var/www/html/000-default"
      echo "<Directory /var/www/html/000-default>"
      echo "    Options -Indexes +FollowSymLinks"
      echo "    AllowOverride All"
      echo "    Order allow,deny"
      echo "    allow from all"
      echo "    deny from all"
      echo "</Directory>"
      echo "ServerSignature Off"
      echo "ErrorLog /var/log/httpd/000-default-error-log"
      echo "LogLevel warn"
      echo "CustomLog /var/log/httpd/000-default-access-log combined"
      echo "SSLCertificateFile /etc/pki/tls/certs/localhost.crt"
      echo "SSLCertificateKeyFile /etc/pki/tls/private/localhost.key"
      echo "</VirtualHost>"
    } >000-default-ssl.conf

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

  STEP="Установка MariaDB"
  if ! check_step "$STEP"; then
    Up
    echo -e "Установка ${GREEN}MariaDB${WHITE} в качестве базы данных."
    Down
    mariadb_install
    mark_step_completed "$STEP"
  fi

  STEP="Установка certbot"
  if ! check_step "$STEP"; then
    echo -e "Ставим ${GREEN}certbot${WHITE} для получения SSL сертификатов?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      Install "certbot python3-certbot-apache"
      echo "───────────────────────────────────────"
      echo -e "${GREEN}Настроим certbot.${WHITE} Введите свой ${GREEN}Email${WHITE} для обратной связи."
      echo -e "На этот Email будут приходить сообщения о проблемах с сертификатами."
      echo -e "Обязательно укажите корректный email."
      echo -e "${GREEN}В конце сертификат для 000-default получать не нужно - просто нажмите 'c'${WHITE}"
      echo "───────────────────────────────────────"
      certbot --apache
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
    if [[ -e mc.menu ]]
    then
      rm /etc/mc/mc.menu
      if  ${LocalServer}
      then
        cat mc.menu.local >> mc.menu
      fi
      cp mc.menu /etc/mc/mc.menu
    fi
    mark_step_completed "$STEP"
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

  STEP="Отключение авторизации по паролю для SSH."
  if ! check_step "$STEP"; then
    echo
    echo -e "Советуем запретить авторизацию по паролю при доступе по ${GREEN}SSH${WHITE}."
    echo -e "Вы всегда сможете авторизоваться по паролю на сервере через VNC."
    echo -e "Запретить авторизацию по ${RED}паролю${WHITE} для SSH?"
    if vertical_menu "current" 2 0 5 "Да" "Нет"; then
      echo -e -n "${CURSORUP}"
      # Резервное копирование оригинального файла конфигурации
      cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
      # Удаление всех строк с PasswordAuthentication
      sed -i '/^#\?PasswordAuthentication/d' /etc/ssh/sshd_config
      # Добавление строки с отключением аутентификации по паролю перед первым блоком Match
      awk '/^Match/ && !done {print "PasswordAuthentication no"; done=1} 1' /etc/ssh/sshd_config >/etc/ssh/sshd_config.tmp && mv /etc/ssh/sshd_config.tmp /etc/ssh/sshd_config

      # Если строка PasswordAuthentication no не была добавлена, добавить её в конец файла
      if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
        echo "PasswordAuthentication no" >>/etc/ssh/sshd_config
      fi
      systemctl restart sshd.service
      echo -e "Авторизация по паролю ${GREEN}запрещена${WHITE}."
    else
      echo -e "${CURSORUP}Авторизация по паролю ${RED}разрешена${WHITE}."
      echo -e
    fi
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
      ssh-keygen -t ed25519 -C "rish-key" -f "/root/.ssh/rish-key" -N '' >/dev/null 2>&1
      cat "/root/.ssh/rish-key"
      cat "/root/.ssh/rish-key.pub" >>/root/.ssh/authorized_keys 2>/dev/null
      echo -e "После того как скопируете этот ключ, нажмите Enter, чтобы очистить экран"
      echo -e "Оба файла после этого будут уничтожены."
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
  options=("Создать пользователя" \
    "Удалить пользователя" \
    "Удалить базу данных пользователя" \
    "Клонирование сайта" \
    "Клонирование только базы данных сайта" \
    "Установка новых версий PHP" \
    "Выйти")
  Down
  echo
  echo -e "Версия ${GREEN}apache${WHITE}"
  httpd -v
  echo
  echo -e "Установленные версии ${GREEN}PHP${WHITE}:"
  mapfile -t installed_versions < <(rpm -qa | grep php | grep -oP 'php[0-9]{2}' | sort -r | uniq)
  for installed in "${installed_versions[@]}"; do
    echo "       "$installed
  done

  while true; do

    vertical_menu "center" "center" 0 30 "${options[@]}"
    choice=$?

    case "$choice" in
    0)
      clear
      CreateUser
      ;;
    1)
      clear
      usrs=($(cat /etc/passwd | grep home | awk -F: '{ print $1}' | sort))
      if ((${#usrs[@]} > 0)); then
        echo "Выберите пользователя для удаления из системы"
        vertical_menu "current" 2 0 30 "${usrs[@]}"
        choice=$?
        echo -e ${CURSORUP}
        if ((choice < 255)); then
          DeleteUser ${usrs[${choice}]}
        fi
      else
        echo "В системе нет ни одного пользователя"
      fi
      ;;
    2)
      clear
      # Проверим на предмет неудаленных баз данных
      usrs=($(cat /etc/passwd | grep home | awk -F: '{ print $1}' | sort) )
      if ((${#usrs[@]} > 0)); then
        echo "Выберите пользователя для удаления его базы данных"
        vertical_menu "current" 2 0 30 "${usrs[@]}"
        choice=$?
        if ((choice < 255)); then
          echo -e ${CURSORUP}"Выбран пользователь ${GREEN}${usrs[${choice}]}${WHITE}${ERASEUNTILLENDOFLINE}"
          SiteuserMysqlPass=$(cat /home/${usrs[${choice}]}/.pass.txt | grep Database | awk '{ print $2}')
          bases=($(mysql -u${usrs[${choice}]} -p${SiteuserMysqlPass} --batch -e "SHOW DATABASES" | tail -n +2 | sed '/information_schema/d'))
          if ((${#bases[@]} > 0)); then
            echo -e "Выберите базу данных пользователя ${RED}"${usrs[${choice}]}"${WHITE} для удаления"
            vertical_menu "current" 2 0 30 "${bases[@]}"
            choice=$?
            if ((${choice} < 255)); then
              DeleteDatabase ${bases[${choice}]}
            fi
          else
            echo "У пользователя нет баз данных"
          fi
        fi
      else
        echo "В системе нет пользователей"
      fi
      ;;
    3)
      CloneSite
      ;;
    4)
      CloneSite "Mysql"
      ;;
    5)
      echo -e "Выбор и установка нужных версий ${GREEN}PHP${WHITE}"
      clear
      # Рисуем разделительную линию
      cursor_to $(( ${rim} +1 )) 1
      repl "─" $(( ${columns} ))
      cursor_to $(( ${rim} +2 )) 1
      Up
      echo -e "Идет получение списка доступных версий ${GREEN}PHP${WHITE}. Ждите."
      Down
      php_multi_install
      clear
      # Рисуем разделительную линию
      cursor_to $(( ${rim} +1 )) 1
      repl "─" $(( ${columns} ))
      cursor_to $(( ${rim} +2 )) 1
      ;;
    *)
      RemoveRim
      clear
      break
      ;;
    esac
  done
fi

