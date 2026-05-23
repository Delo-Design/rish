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

get_installed_php_version_labels() {
  local php_version
  local fpm_binary
  local version_label

  while IFS= read -r php_version; do
    fpm_binary="/opt/remi/${php_version}/root/usr/sbin/php-fpm"
    [[ -x "$fpm_binary" ]] || continue

    version_label="$("$fpm_binary" -v 2>/dev/null | sed -n '1s/^PHP \([0-9][^ ]*\).*/php \1/p')"
    if [[ -n "$version_label" ]]; then
      echo "$version_label"
    else
      echo "$php_version"
    fi
  done < <(get_installed_php_versions)
}
