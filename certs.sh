#!/usr/bin/env bash
# shellcheck disable=SC2155

source /root/rish/windows.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
YELLOW='\033[0;33m'

function collect_vhost_aliases() {
  local vhost="$1"
  local result_var="$2"
  local -n aliases_ref="$result_var"

  mapfile -t aliases_ref < <(awk '
    BEGIN{IGNORECASE=1}
    $1=="ServerAlias"{
      for(i=2;i<=NF;i++){
        if ($i ~ /^#/) break;
        print $i;
      }
    }' "$vhost")
}

function self_signed_cert_exists_for_site() {
  local site_name="$1"
  local key_file="/etc/pki/tls/private/${site_name}.key"
  local cert_file="/etc/pki/tls/certs/${site_name}.crt"
  local ssl_conf="/etc/httpd/conf.d/${site_name}-ssl.conf"

  [[ -f "$key_file" || -f "$cert_file" || -f "$ssl_conf" ]]
}

function create_self_signed_cert_for_site() {
  local site_name="$1"
  local vhost="/etc/httpd/conf.d/${site_name}.conf"
  local server_name
  local ttssl="${site_name}-ssl.conf"
  local tmpcfg="rish_temp_file_for_creating_selfsigned_cert.txt"
  local openssl_error_file="rish_temp_file_for_openssl_error.txt"
  local key_file="/etc/pki/tls/private/${site_name}.key"
  local cert_file="/etc/pki/tls/certs/${site_name}.crt"
  local ssl_conf="/etc/httpd/conf.d/${ttssl}"
  local choice
  local old_pwd
  local rc=0
  local i
  local d
  local a
  local -a aliases_flat=()
  local -a aliases=()
  local -a all_dns=()
  declare -A seen=()
  declare -A dns_seen=()

  if [[ ! -f "$vhost" ]]; then
    echo -e "${RED}${site_name}${WHITE} это не сайт (не vhost)"
    return 1
  fi

  if [[ -f "$key_file" || -f "$cert_file" || -f "$ssl_conf" ]]; then
    echo -e "Для сайта ${GREEN}${site_name}${WHITE} уже найден самоподписанный SSL:"
    [[ -f "$cert_file" ]] && echo -e "  сертификат: ${YELLOW}${cert_file}${WHITE}"
    [[ -f "$key_file" ]] && echo -e "  ключ: ${YELLOW}${key_file}${WHITE}"
    [[ -f "$ssl_conf" ]] && echo -e "  vhost: ${YELLOW}${ttssl}${WHITE}"
    vertical_menu "current" 2 0 38 \
      "Перевыпустить сертификат" \
      "Оставить существующий" \
      "Выйти"
    choice=$?
    case "$choice" in
      0)
        ;;
      1)
        echo "Существующий self-signed SSL оставлен без изменений."
        return 0
        ;;
      *)
        echo "Создание self-signed SSL отменено."
        return 0
        ;;
    esac
  fi

  server_name="$(awk 'BEGIN{IGNORECASE=1} $1=="ServerName"{print $2; exit}' "$vhost")"
  [[ -z "$server_name" ]] && server_name="$site_name"

  collect_vhost_aliases "$vhost" aliases_flat
  for a in "${aliases_flat[@]}"; do
    [[ -z "$a" ]] && continue
    [[ "$a" == "$server_name" ]] && continue
    [[ "$a" == \** ]] && continue
    if [[ -z "${seen[$a]}" ]]; then
      aliases+=("$a")
      seen["$a"]=1
    fi
  done

  all_dns+=("$server_name")
  dns_seen["$server_name"]=1
  for a in "${aliases[@]}"; do
    if [[ -z "${dns_seen[$a]}" ]]; then
      all_dns+=("$a")
      dns_seen["$a"]=1
    fi
  done

  old_pwd="$PWD"
  cd /etc/httpd/conf.d || return 1
  rm -f "${site_name}-ssl"* "$openssl_error_file" 2>/dev/null

  {
    echo "[req]"
    echo "distinguished_name = req_distinguished_name"
    echo "x509_extensions = v3_req"
    echo "prompt = no"
    echo "[req_distinguished_name]"
    echo "CN = ${server_name}"
    echo "[v3_req]"
    echo "keyUsage = critical, digitalSignature, keyAgreement"
    echo "extendedKeyUsage = serverAuth"
    echo "subjectAltName = @alt_names"
    echo "[alt_names]"
    i=1
    for d in "${all_dns[@]}"; do
      echo "DNS.$i = $d"
      ((i++))
    done
  } >"$tmpcfg"

  echo -e "Создаем самоподписанный SSL сертификат для сайта ${GREEN}${site_name}${WHITE}."
  if ! openssl req -x509 -nodes \
    -newkey rsa:2048 \
    -keyout "$key_file" \
    -out "$cert_file" \
    -sha256 \
    -days 3650 \
    -subj "/CN=${server_name}" \
    -config "$tmpcfg" \
    2>"$openssl_error_file"; then
    rm -f "$tmpcfg"
    echo -e "Не удалось создать самоподписанный SSL-сертификат для ${RED}${site_name}${WHITE}."
    if [[ -s "$openssl_error_file" ]]; then
      echo -e "${YELLOW}openssl:${WHITE}"
      sed 's/^/  /' "$openssl_error_file"
    fi
    rm -f "$openssl_error_file"
    cd "$old_pwd" || true
    return 1
  fi

  rm -f "$tmpcfg" "$openssl_error_file"

  if ! cp "${site_name}.conf" "$ttssl"; then
    cd "$old_pwd" || true
    return 1
  fi
  sed -E -i 's#(<VirtualHost[[:space:]]+)([^>]*):80>#\1\2:443>#g' "$ttssl"
  sed -i "/<\/VirtualHost>/i ServerSignature Off\nSSLCertificateFile /etc/pki/tls/certs/${site_name}.crt\nSSLCertificateKeyFile /etc/pki/tls/private/${site_name}.key" "$ttssl"

  if apachectl configtest; then
    systemctl reload httpd
    echo "Сервер перезагружен."
  else
    echo -e "Сервер не был перезагружен. ${RED}Ошибка${WHITE} в конфигурации Apache."
    rc=1
  fi

  if [[ "$rc" -eq 0 ]]; then
    echo -e "Самоподписанный SSL сертификат для сайта ${GREEN}${site_name}${WHITE} создан."
  fi

  cd "$old_pwd" || true
  return "$rc"
}

certs() {
  clear
  local site_name="$1"
  local vhost="/etc/httpd/conf.d/${site_name}.conf"

  echo -e "Сертификат для сайта ${GREEN}${site_name}${WHITE}"
  echo

  if [[ ! -f "$vhost" ]]; then
    echo -e "${RED}${site_name}${WHITE} это не сайт (не vhost)"
    return 1
  fi

  # ---- 1) ServerName ----
  local server_name
  local -a aliases_flat=()
  server_name=$(awk 'BEGIN{IGNORECASE=1} $1=="ServerName"{print $2; exit}' "$vhost")
  [[ -z "$server_name" ]] && server_name="$site_name"

  # ---- 2) ServerAlias: извлекаем по словам до комментария, учитываем несколько алиасов в строке ----
  collect_vhost_aliases "$vhost" aliases_flat

  # ---- 3) Нормализуем: без дублей, без wildcard, без самого server_name ----
  declare -A seen=()
  declare -a aliases=()
  for a in "${aliases_flat[@]}"; do
    [[ -z "$a" ]] && continue
    [[ "$a" == "$server_name" ]] && continue
    [[ "$a" == \** ]] && continue     # wildcard не берём для HTTP-01
    if [[ -z "${seen[$a]}" ]]; then
      aliases+=("$a")
      seen["$a"]=1
    fi
  done

  # ---- 4) Вывод списка с подсветкой ----
  echo "Основной домен:"
  echo -e "${GREEN}${server_name}${WHITE}"
  echo
  echo "Список алиасов:"
  if ((${#aliases[@]}==0)); then
    echo "—"
  else
    for alias in "${aliases[@]}"; do
      if [[ "$alias" == *".${server_name}" ]]; then
        # подсветка хвоста (поддомен базового домена)
        local prefix="${alias%.$server_name}"
        echo -e "${prefix}.${GREEN}${server_name}${WHITE}"
      else
        echo "$alias"
      fi
    done
  fi
  echo

  # ---- 5) Меню ----
  vertical_menu "current" 2 0 5 \
    "Получить для www.${site_name} и ${site_name}" \
    "Получить только для ${site_name}" \
    "Получить для всех алиасов и ${site_name}" \
    "Получить самоподписанный для всех алиасов" \
    "Отозвать сертификат для ${site_name}"

  local choice=$?
  case "$choice" in
  0)
    certbot --apache -d "$site_name" -d "www.${site_name}"
    ;;
  1)
    certbot --apache -d "$site_name"
    ;;
  2)
  # все алиасы из конфига + базовый, без дублей
    declare -A used=()
    declare -a args=()
    used["$server_name"]=1
    args+=(-d "$server_name")
    for a in "${aliases[@]}"; do
      if [[ -z "${used[$a]}" ]]; then
        args+=(-d "$a")
        used["$a"]=1
      fi
    done
    certbot --apache "${args[@]}"
    ;;
  3)
    create_self_signed_cert_for_site "$site_name"
    echo
    ;;
  4)
    echo -e "Отзыв сертификата ${GREEN}${site_name}${WHITE}"
    local cert_path="/etc/letsencrypt/live/${site_name}/cert.pem"
    if [[ ! -f "$cert_path" ]]; then
      echo "Сертификат не найден: $cert_path"
      return
    fi
    if ! certbot revoke --cert-path "$cert_path"; then
      echo "Не удалось отозвать сертификат"
      return
    fi

    local ssl_conf="/etc/httpd/conf.d/${site_name}-le-ssl.conf"
    if [[ -f "$ssl_conf" ]]; then
      rm -f "$ssl_conf"
      echo "Файл SSL конфигурации удален: $ssl_conf"
    else
      echo "Файл SSL конфигурации не найден: $ssl_conf"
    fi

    if apachectl configtest; then
      if systemctl reload httpd; then
        echo "Сервер успешно перезагружен"
      else
        echo "Ошибка при попытке перезагрузить сервер"
      fi
    else
      echo "Ошибка в конфигурации Apache, сервер не был перезагружен"
    fi
    ;;
  *)
    ;;
  esac
}

# Если идёт прямой вызов — выполняем функцию.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  certs "$1"
  vertical_menu "current" 2 0 5 "Нажмите Enter"
fi
