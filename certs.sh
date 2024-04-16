#!/usr/bin/env bash
source /root/rish/windows.sh
GREEN='\033[0;32m'
RED='\033[0;31m'
WHITE='\033[0m'
certs() {
  clear
  site_name=$1
  echo -e "Сертификат для сайта ${GREEN}${site_name}${WHITE}"
  echo
  if [[ -f "/etc/httpd/conf.d/$site_name.conf" ]]; then
    mapfile -t aliases < <(grep "ServerAlias" "/etc/httpd/conf.d/$site_name.conf" | sed 's/^[ \t]*ServerAlias[ \t]*//')
    echo "Список алиасов:"
    for alias in "${aliases[@]}"; do
      echo -e "${alias%"${site_name}"}"${GREEN}${site_name}${WHITE}
    done
    echo
    vertical_menu "current" 2 0 5 "Получить для www.${site_name} и ${site_name}" \
      "Получить только для ${site_name}" \
      "Получить для всех алиасов и ${site_name}" \
      "Получить самоподписанный для www.${site_name} и ${site_name}" \
      "Отозвать сертификат для ${site_name}"

    choice=$?
    case "$choice" in
    0)
      certbot --apache -d ${site_name} -d www.${site_name}
      ;;
    1)
      certbot --apache -d ${site_name}
      ;;
    2)
      domain_args="-d $site_name"
      for alias in "${aliases[@]}"; do
        domain_args="$domain_args -d $alias"
      done
      certbot --apache $domain_args
      ;;
    3)
      cd /etc/httpd/conf.d

      rm -f ${site_name}-ssl*
      ttssl="${site_name}-ssl.conf"
      localsitename="${site_name}"
      {
        echo "[req]"
        echo "distinguished_name = req_distinguished_name"
        echo "x509_extensions = v3_req"
        echo "prompt = no"
        echo "[req_distinguished_name]"
        echo "CN = ${localsitename}"
        echo "[v3_req]"
        echo "keyUsage = critical, digitalSignature, keyAgreement"
        echo "extendedKeyUsage = serverAuth"
        echo "subjectAltName = @alt_names"
        echo "[alt_names]"
        echo "DNS.1 = www.${localsitename}"
        echo "DNS.2 = ${localsitename}"
      } >rish_temp_file_for_creating_selfsigned_cert.txt
      openssl req -x509 -nodes \
        -newkey rsa:2048 \
        -keyout /etc/pki/tls/private/${localsitename}.key \
        -out /etc/pki/tls/certs/${localsitename}.crt \
        -sha256 \
        -days 3650 \
        -subj "/CN=${localsitename}" \
        -config rish_temp_file_for_creating_selfsigned_cert.txt
      rm -f rish_temp_file_for_creating_selfsigned_cert.txt
      cp ${site_name}.conf $ttssl
      sed -i 's/<VirtualHost \*:\s*80>/<VirtualHost *:443>/g' "$ttssl"
      sed -i "/<\/VirtualHost>/i ServerSignature Off\nSSLCertificateFile /etc/pki/tls/certs/${site_name}.crt\nSSLCertificateKeyFile /etc/pki/tls/private/${site_name}.key" "$ttssl"
      if apachectl configtest; then
        systemctl reload httpd
        echo "Сервер перезагружен."
      else
        echo -e "Сервер не был перезагружен. ${RED}Ошибка${WHITE} в конфигурации апача."
      fi
      echo "Сертификат установлен"
      echo
      ;;
    4)
      echo -e "Отзыв сертификата ${GREEN}${site_name}${WHITE}"
      # Путь к сертификату
      cert_path="/etc/letsencrypt/live/${site_name}/cert.pem"
      # Проверка существования сертификата
      if [ ! -f "$cert_path" ]; then
        echo "Сертификат не найден: $cert_path"
        return
      fi
      # Отзыв сертификата
      if ! certbot revoke --cert-path "$cert_path"; then
        echo "Не удалось отозвать сертификат"
        return
      fi
      # Путь к файлу конфигурации SSL для Apache
      ssl_conf="/etc/httpd/conf.d/${site_name}-le-ssl.conf"
      # Удаление файла конфигурации SSL, если он существует
      if [ -f "$ssl_conf" ]; then
        rm "$ssl_conf" &>/dev/null
        echo "Файл SSL конфигурации удален: $ssl_conf"
      else
        echo "Файл SSL конфигурации не найден: $ssl_conf"
      fi
      # Проверка конфигурации Apache
      if apachectl configtest; then
        # Перезагрузка Apache, если конфигурация верна
        if systemctl reload httpd; then
          echo "Сервер успешно перезагружен"
        else
          echo "Ошибка при попытке перезагрузить сервер"
        fi
      else
        echo "Ошибка в конфигурации Apache, сервер не был перезагружен"
      fi
      ;;
    *) ;;
    esac
  else
    echo -e "${RED}$site_name${WHITE} это не сайт (не vhost)"
  fi
}
