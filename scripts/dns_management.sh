#!/usr/bin/env bash

# Shared DNS management state for installation, updates and the server menu.
RISH_DNS_RUNTIME_DIR="/root/rish/dns"
RISH_DNS_LEGACY_DISABLED_DIR="/root/rish/dns_bak"
RISH_DNS_MANAGEMENT_MARKER="${RISH_DNS_RUNTIME_DIR}/.enabled"
RISH_DNS_MANAGEMENT_MIGRATION_STEP=100

rish_dns_management_is_enabled() {
  [[ -x "$RISH_DNS_MANAGEMENT_MARKER" ]]
}

rish_dns_management_enable() {
  mkdir -p "$RISH_DNS_RUNTIME_DIR" || return 1
  install -m 700 /dev/null "$RISH_DNS_MANAGEMENT_MARKER"
}

rish_dns_management_disable() {
  rm -f -- "$RISH_DNS_MANAGEMENT_MARKER"
}

rish_dns_management_migrate_legacy_state() {
  if [[ -d "$RISH_DNS_RUNTIME_DIR" && -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
    return 2
  fi
  if [[ -e "$RISH_DNS_MANAGEMENT_MARKER" ]]; then
    chmod 700 "$RISH_DNS_MANAGEMENT_MARKER"
    return
  fi
  if [[ -d "$RISH_DNS_LEGACY_DISABLED_DIR" ]]; then
    mv -- "$RISH_DNS_LEGACY_DISABLED_DIR" "$RISH_DNS_RUNTIME_DIR"
    return
  fi
  if [[ -d "$RISH_DNS_RUNTIME_DIR" ]]; then
    rish_dns_management_enable
  fi
}

rish_dns_management_mark_migration_completed() {
  if declare -F check_step >/dev/null 2>&1 &&
    declare -F mark_step_completed >/dev/null 2>&1 &&
    ! check_step "$RISH_DNS_MANAGEMENT_MIGRATION_STEP"; then
    mark_step_completed "$RISH_DNS_MANAGEMENT_MIGRATION_STEP"
  fi
}

rish_dns_domain_count() {
  local domain_dir
  local count=0

  for domain_dir in "$1"/domains/*; do
    [[ -d "$domain_dir" ]] && ((count++))
  done
  printf '%s' "$count"
}
