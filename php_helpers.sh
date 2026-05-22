#!/usr/bin/env bash

get_installed_php_versions() {
  local fpm_binary

  shopt -s nullglob
  for fpm_binary in /opt/remi/php[0-9][0-9]/root/usr/sbin/php-fpm; do
    [[ -x "$fpm_binary" ]] || continue
    echo "$fpm_binary" | grep -oE 'php[0-9]{2}' | head -n 1
  done | sort -r | uniq
  shopt -u nullglob
}

