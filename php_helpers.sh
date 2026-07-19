#!/usr/bin/env bash

PHP_FPM_SYSTEMD_CONF_NAME="local.conf"
declare -A PHP_FPM_SYSTEMD_ROLLBACK_PREPARED=()
declare -A PHP_FPM_SYSTEMD_ROLLBACK_EXISTED=()
declare -A PHP_FPM_SYSTEMD_ROLLBACK_FILES=()
declare -A PHP_FPM_SYSTEMD_ROLLBACK_MODES=()
declare -A PHP_FPM_SYSTEMD_ROLLBACK_OWNERS=()
declare -A PHP_FPM_SYSTEMD_ROLLBACK_GROUPS=()

get_installed_php_versions() {
  local fpm_binary

  shopt -s nullglob
  for fpm_binary in /opt/remi/php[0-9][0-9]/root/usr/sbin/php-fpm; do
    [[ -x "$fpm_binary" ]] || continue
    echo "$fpm_binary" | grep -oE 'php[0-9]{2}' | head -n 1
  done | sort -r | uniq
  shopt -u nullglob
}

get_systemd_version() {
  systemctl --version 2>/dev/null | awk 'NR == 1 && $1 == "systemd" { print $2; exit }'
}

php_fpm_systemd_supports_extended_hardening() {
  local systemd_version

  systemd_version="$(get_systemd_version)"
  [[ "$systemd_version" =~ ^[0-9]+$ ]] || return 1
  (( systemd_version >= 245 ))
}

render_php_fpm_systemd_conf() {
  cat <<EOF
[Service]
Restart=on-failure
RestartSec=180
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
EOF

  if php_fpm_systemd_supports_extended_hardening; then
    echo "RestrictSUIDSGID=yes"
  fi

  cat <<EOF
ProtectKernelTunables=yes
ProtectKernelModules=yes
EOF

  if php_fpm_systemd_supports_extended_hardening; then
    echo "ProtectKernelLogs=yes"
  fi

  cat <<EOF
ProtectControlGroups=yes
LockPersonality=yes
RestrictRealtime=yes
EOF
}

render_legacy_php_fpm_systemd_conf() {
  cat <<EOF
[Service]
Restart=on-failure
RestartSec=180
EOF
}

php_fpm_systemd_conf_path() {
  local php_version="$1"

  [[ "$php_version" =~ ^php[0-9]{2}$ ]] || return 1
  echo "/etc/systemd/system/${php_version}-php-fpm.service.d/${PHP_FPM_SYSTEMD_CONF_NAME}"
}

php_fpm_systemd_conf_is_known() {
  local conf_file="$1"

  [[ -f "$conf_file" ]] || return 1
  render_php_fpm_systemd_conf | cmp -s - "$conf_file" && return 0
  render_legacy_php_fpm_systemd_conf | cmp -s - "$conf_file"
}

backup_custom_php_fpm_systemd_conf() {
  local conf_file="$1"
  local backup_file

  backup_file="$(mktemp "${conf_file}.rish-backup.XXXXXX")" || return 1
  if ! install -m 600 -o root -g root "$conf_file" "$backup_file"; then
    rm -f "$backup_file"
    return 1
  fi

  echo "$backup_file"
}

prepare_php_fpm_systemd_rollback() {
  local php_version="$1"
  local conf_file
  local rollback_file=""
  local original_mode
  local original_owner
  local original_group

  [[ "${PHP_FPM_SYSTEMD_ROLLBACK_PREPARED[$php_version]:-0}" -eq 0 ]] || return 0
  conf_file="$(php_fpm_systemd_conf_path "$php_version")" || return 1

  if [[ -e "$conf_file" || -L "$conf_file" ]]; then
    [[ -f "$conf_file" ]] || return 1
    original_mode="$(stat -c '%a' "$conf_file")" || return 1
    original_owner="$(stat -c '%u' "$conf_file")" || return 1
    original_group="$(stat -c '%g' "$conf_file")" || return 1
    rollback_file="$(mktemp "${conf_file}.rish-rollback.XXXXXX")" || return 1
    if ! install -m 600 -o root -g root "$conf_file" "$rollback_file"; then
      rm -f "$rollback_file"
      return 1
    fi
    PHP_FPM_SYSTEMD_ROLLBACK_MODES["$php_version"]="$original_mode"
    PHP_FPM_SYSTEMD_ROLLBACK_OWNERS["$php_version"]="$original_owner"
    PHP_FPM_SYSTEMD_ROLLBACK_GROUPS["$php_version"]="$original_group"
    PHP_FPM_SYSTEMD_ROLLBACK_EXISTED["$php_version"]=1
    PHP_FPM_SYSTEMD_ROLLBACK_FILES["$php_version"]="$rollback_file"
  else
    PHP_FPM_SYSTEMD_ROLLBACK_EXISTED["$php_version"]=0
    PHP_FPM_SYSTEMD_ROLLBACK_FILES["$php_version"]=""
  fi

  PHP_FPM_SYSTEMD_ROLLBACK_PREPARED["$php_version"]=1
}

php_fpm_systemd_rollback_is_prepared() {
  local php_version="$1"

  [[ "${PHP_FPM_SYSTEMD_ROLLBACK_PREPARED[$php_version]:-0}" -eq 1 ]]
}

commit_php_fpm_systemd_conf() {
  local php_version="$1"
  local rollback_file="${PHP_FPM_SYSTEMD_ROLLBACK_FILES[$php_version]:-}"

  if [[ -n "$rollback_file" ]] && ! rm -f "$rollback_file"; then
    return 1
  fi
  unset 'PHP_FPM_SYSTEMD_ROLLBACK_PREPARED[$php_version]'
  unset 'PHP_FPM_SYSTEMD_ROLLBACK_EXISTED[$php_version]'
  unset 'PHP_FPM_SYSTEMD_ROLLBACK_FILES[$php_version]'
  unset 'PHP_FPM_SYSTEMD_ROLLBACK_MODES[$php_version]'
  unset 'PHP_FPM_SYSTEMD_ROLLBACK_OWNERS[$php_version]'
  unset 'PHP_FPM_SYSTEMD_ROLLBACK_GROUPS[$php_version]'
}

rollback_php_fpm_systemd_conf() {
  local php_version="$1"
  local conf_file
  local conf_dir
  local rollback_file
  local restore_file
  local restore_mode
  local restore_owner
  local restore_group
  local status=0

  php_fpm_systemd_rollback_is_prepared "$php_version" || return 0
  conf_file="$(php_fpm_systemd_conf_path "$php_version")" || return 1
  conf_dir="${conf_file%/*}"
  rollback_file="${PHP_FPM_SYSTEMD_ROLLBACK_FILES[$php_version]:-}"

  if [[ "${PHP_FPM_SYSTEMD_ROLLBACK_EXISTED[$php_version]:-0}" -eq 1 ]]; then
    restore_mode="${PHP_FPM_SYSTEMD_ROLLBACK_MODES[$php_version]}"
    restore_owner="${PHP_FPM_SYSTEMD_ROLLBACK_OWNERS[$php_version]}"
    restore_group="${PHP_FPM_SYSTEMD_ROLLBACK_GROUPS[$php_version]}"
    restore_file="$(mktemp "${conf_dir}/.${PHP_FPM_SYSTEMD_CONF_NAME}.rish-restore.XXXXXX")" || return 1
    if ! install -m "$restore_mode" -o "$restore_owner" -g "$restore_group" "$rollback_file" "$restore_file" || ! mv -f "$restore_file" "$conf_file"; then
      rm -f "$restore_file"
      status=1
    fi
  elif ! rm -f "$conf_file"; then
    status=1
  fi

  if [[ "$status" -eq 0 ]]; then
    commit_php_fpm_systemd_conf "$php_version" || status=1
  fi
  return "$status"
}

write_php_fpm_systemd_conf() {
  local php_version="$1"
  local conf_file
  local conf_dir
  local tmp_file
  local backup_file=""

  conf_file="$(php_fpm_systemd_conf_path "$php_version")" || return 1
  conf_dir="${conf_file%/*}"

  install -d -m 755 -o root -g root "$conf_dir" || return 1

  if [[ -e "$conf_file" || -L "$conf_file" ]]; then
    [[ -f "$conf_file" ]] || return 1
    if ! php_fpm_systemd_conf_is_known "$conf_file"; then
      backup_file="$(backup_custom_php_fpm_systemd_conf "$conf_file")" || return 1
    fi
  fi

  prepare_php_fpm_systemd_rollback "$php_version" || return 1

  tmp_file="$(mktemp "${conf_dir}/.${PHP_FPM_SYSTEMD_CONF_NAME}.rish-tmp.XXXXXX")" || {
    rollback_php_fpm_systemd_conf "$php_version"
    return 1
  }

  if ! render_php_fpm_systemd_conf > "$tmp_file"; then
    rm -f "$tmp_file"
    rollback_php_fpm_systemd_conf "$php_version"
    return 1
  fi

  if ! chown root:root "$tmp_file" || ! chmod 644 "$tmp_file" || ! mv -f "$tmp_file" "$conf_file"; then
    rm -f "$tmp_file"
    rollback_php_fpm_systemd_conf "$php_version"
    return 1
  fi

  if [[ -n "$backup_file" ]]; then
    printf '%b\n' "В ${YELLOW:-}${conf_file}${WHITE:-} обнаружены нестандартные настройки."
    printf '%b\n' "Резервная копия: ${YELLOW:-}${backup_file}${WHITE:-}"
    echo "После обновления проверьте резервную копию и вручную верните необходимые параметры."
  fi
}

php_fpm_systemd_conf_matches() {
  local php_version="$1"
  local conf_file

  conf_file="$(php_fpm_systemd_conf_path "$php_version")" || return 1
  [[ -f "$conf_file" ]] || return 1
  render_php_fpm_systemd_conf | cmp -s - "$conf_file"
}

php_fpm_systemd_security_settings() {
  render_php_fpm_systemd_conf | awk -F= '
    $1 != "Restart" && $1 != "RestartSec" && NF == 2 {
      print $1 "=" $2
    }
  '
}

php_fpm_systemd_security_is_effective() {
  local php_version="$1"
  local unit
  local setting
  local expected
  local actual

  [[ "$php_version" =~ ^php[0-9]{2}$ ]] || return 1
  unit="${php_version}-php-fpm"

  while IFS='=' read -r setting expected; do
    [[ -n "$setting" ]] || continue
    actual="$(systemctl show "$unit" --property="$setting" --value 2>/dev/null)" || return 1
    [[ "$actual" == "$expected" ]] || return 1
  done < <(php_fpm_systemd_security_settings)
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
