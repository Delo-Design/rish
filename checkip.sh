#!/bin/bash
CheckIP() {
  clear
  GREEN='\033[0;32m'
  LGREEN='\033[1;32m'
  RED='\033[0;31m'
  WHITE='\033[0m'
  myip="("$(ip route get 1 | grep -Eo 'src [0-9\.]{1,20}' | awk '{print $NF;exit}')")"
  echo "Адрес этого сервера: "$myip
  directory="/var/www/*/www/"
  for file in $directory/*; do
    if [ -d "$file" ]; then
      r="${file##*/}"
      if ping -c 1 $r &>/dev/null; then
        ip=$(ping -c 1 $r | grep PING | awk '{ print $3 }')
        if [[ "$myip" == "$ip" ]]; then
          echo -e -n "${GREEN}$ip${WHITE}"
        else
          echo -e -n "$ip"
        fi
        echo -e -n " ${LGREEN}$r${WHITE}"
        echo
      else
        echo -e "${RED}$r${WHITE}"
      fi
    fi
  done
}