#!/usr/bin/env bash

# Standalone firewalld management. Sourcing this file only defines functions.
RISH_FIREWALL_HOME="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || return 1 2>/dev/null || exit 1
RISH_FW_ZONE=""
RISH_FW_LIST_ID=manual
RISH_FW_ATTACH_GATE=1
RISH_FW_LOCK_HELD=0
RISH_FW_GREEN=""
RISH_FW_YELLOW=""
RISH_FW_RED=""
RISH_FW_RESET=""
RISH_FW_SITE_NAME=""
RISH_FW_SITE_LOG=""
if [[ -t 1 ]]; then
  RISH_FW_GREEN=$'\033[0;32m'
  RISH_FW_YELLOW=$'\033[0;33m'
  RISH_FW_RED=$'\033[0;31m'
  RISH_FW_RESET=$'\033[0m'
fi

rish_fw_paths() {
  if [[ "${RISH_FIREWALL_TEST_MODE:-0}" == 1 ]]; then
    RISH_FW_STATE_DIR="${RISH_FIREWALL_STATE_DIR:?test state directory required}"
    RISH_FW_LIST_DIR="${RISH_FIREWALL_LIST_DIR:?test list directory required}"
    RISH_FW_LOCK_FILE="${RISH_FIREWALL_LOCK_FILE:-${RISH_FW_STATE_DIR}/lock}"
    RISH_FW_WHITELIST="${RISH_FIREWALL_WHITELIST_FILE:-${RISH_FW_LIST_DIR}/whitelist.txt}"
  else
    RISH_FW_STATE_DIR="/run/rish/firewall"
    RISH_FW_LIST_DIR="/etc/firewalld/blocklists"
    RISH_FW_LOCK_FILE="${RISH_FW_STATE_DIR}/lock"
    RISH_FW_WHITELIST="/etc/firewalld/rish-whitelist.txt"
  fi
  RISH_FW_LEDGER="${RISH_FW_STATE_DIR}/temporary.tsv"
  RISH_FW_SERVER_LOCK_FILE="${RISH_FW_STATE_DIR}/server-lock.tsv"
}

rish_fw_cmd() { command firewall-cmd "$@"; }
rish_fw_error() {
  local red="" reset=""
  if [[ -t 2 ]]; then red=$'\033[0;31m'; reset=$'\033[0m'; fi
  printf '%sОшибка:%s %s\n' "$red" "$reset" "$*" >&2
}

# These renderers are only for human-facing output, never saved/parsed values.
rish_fw_field() {
  printf '%s: %s%s%s\n' "$1" "${3:-$RISH_FW_GREEN}" "$2" "$RISH_FW_RESET"
}

rish_fw_ui_entries() {
  local entry
  if [[ -z "$1" ]]; then printf '  (список пуст)\n'; return 0; fi
  while IFS= read -r entry; do
    [[ -z "$entry" ]] || printf '  %s%s%s\n' "$RISH_FW_GREEN" "$entry" "$RISH_FW_RESET"
  done <<<"$1"
}

rish_fw_shared_notice() {
  printf 'Изменение затронет %sвсе зоны%s,\nиспользующие %s.\n' \
    "$RISH_FW_YELLOW" "$RISH_FW_RESET" "${1:-этот постоянный список}"
}

# Only uncaptured actions use this helper; queries and parsed responses stay raw.
rish_fw_quiet() {
  local output rc
  output=$(rish_fw_cmd "$@" 2>&1); rc=$?
  if [[ -n "$output" && ( "$output" != success || "$rc" != 0 ) ]]; then
    printf '%s\n' "$output" >&2
  fi
  return "$rc"
}

rish_fw_check_config() {
  rish_fw_quiet --check-config || return $?
  printf 'Конфигурация %sfirewalld%s %sв порядке%s.\n' \
    "$RISH_FW_GREEN" "$RISH_FW_RESET" "$RISH_FW_GREEN" "$RISH_FW_RESET"
}

rish_fw_zone_fields() {
  local line value
  RISH_FW_ZONE_INTERFACES=""; RISH_FW_ZONE_SOURCES=""; RISH_FW_ZONE_SERVICES=""; RISH_FW_ZONE_PORTS=""
  RISH_FW_ZONE_FIELDS=" "
  while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    value=${line#*:}; value=${value#"${value%%[![:space:]]*}"}
    case "$line" in
      interfaces:*) RISH_FW_ZONE_INTERFACES="$value"; RISH_FW_ZONE_FIELDS+="interfaces " ;;
      sources:*) RISH_FW_ZONE_SOURCES="$value"; RISH_FW_ZONE_FIELDS+="sources " ;;
      services:*) RISH_FW_ZONE_SERVICES="$value"; RISH_FW_ZONE_FIELDS+="services " ;;
      ports:*) RISH_FW_ZONE_PORTS="$value"; RISH_FW_ZONE_FIELDS+="ports " ;;
    esac
  done <<<"$1"
}

rish_fw_header() {
  local state state_rc color interfaces sources label
  state=$(rish_fw_cmd --state 2>&1); state_rc=$?
  color=$RISH_FW_YELLOW
  case "$state" in
    running) if [[ "$state_rc" == 0 ]]; then state="работает"; color=$RISH_FW_GREEN; fi ;;
    'not running') state="не работает"; color=$RISH_FW_RED ;;
  esac
  printf 'Управление %sfirewalld%s\n' "$RISH_FW_GREEN" "$RISH_FW_RESET"
  rish_fw_field "Состояние" "$state" "$color"
  color=$RISH_FW_GREEN; [[ -n "$RISH_FW_ZONE" ]] || color=$RISH_FW_YELLOW
  rish_fw_field "Зона" "${RISH_FW_ZONE:-не выбрана}" "$color"
  RISH_FW_HEADER_INFO=""; RISH_FW_HEADER_INFO_RC=1
  if [[ -n "$RISH_FW_ZONE" ]]; then
    RISH_FW_HEADER_INFO=$(rish_fw_cmd --zone="$RISH_FW_ZONE" --list-all 2>/dev/null); RISH_FW_HEADER_INFO_RC=$?
    if [[ "$RISH_FW_HEADER_INFO_RC" == 0 ]]; then
      rish_fw_zone_fields "$RISH_FW_HEADER_INFO"
      interfaces=$RISH_FW_ZONE_INTERFACES; sources=$RISH_FW_ZONE_SOURCES
    else interfaces=""; sources=""; fi
    if [[ -n "$interfaces" ]]; then
      label="Интерфейс"; [[ "$interfaces" != *' '* ]] || label="Интерфейсы"
      rish_fw_field "$label" "$interfaces"
    fi
    if [[ -n "$sources" ]]; then
      rish_fw_field "Адреса зоны" "$sources"
    fi
  fi
  rish_fw_server_lock_refresh
  rish_fw_server_lock_summary
}
rish_fw_now() {
  if [[ "${RISH_FIREWALL_TEST_MODE:-0}" == 1 && "${RISH_FIREWALL_NOW:-}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$RISH_FIREWALL_NOW"
  else
    date +%s
  fi
}

rish_fw_date() {
  python3 - "$1" <<'PY'
import datetime, sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1])).astimezone().strftime('%d.%m.%Y %H:%M:%S %Z'))
PY
}

rish_fw_duration_label() {
  local seconds="$1"
  if [[ "$seconds" == permanent ]]; then printf 'постоянно';
  elif ((seconds % 86400 == 0 && seconds >= 86400)); then printf '%s дн.' "$((seconds / 86400))";
  elif ((seconds % 3600 == 0 && seconds >= 3600)); then printf '%s ч.' "$((seconds / 3600))";
  elif ((seconds % 60 == 0 && seconds >= 60)); then printf '%s мин.' "$((seconds / 60))";
  else printf '%s сек.' "$seconds"; fi
}

rish_fw_confirm() {
  printf '\n%s\n' "$1"
  vertical_menu current 2 0 32 default=0 "Отмена" "Продолжить"
  [[ $? == 1 ]]
}

rish_fw_require() {
  local tool
  [[ $EUID == 0 || "${RISH_FIREWALL_TEST_MODE:-0}" == 1 ]] || { rish_fw_error "Запустите модуль от root."; return 1; }
  for tool in firewall-cmd python3 flock mktemp sort cmp diff stat; do
    command -v "$tool" >/dev/null 2>&1 || { rish_fw_error "Не найдена команда ${tool}."; return 1; }
  done
  rish_fw_paths || return 1
}

rish_fw_active() {
  rish_fw_cmd --state >/dev/null 2>&1 || {
    rish_fw_error "firewalld не работает. Модуль не запускает и не устанавливает службу автоматически."
    return 1
  }
  [[ "$RISH_FW_ZONE" =~ ^[A-Za-z0-9_.-]+$ ]] || { rish_fw_error "Зона не выбрана."; return 1; }
  rish_fw_cmd --get-zones | tr ' ' '\n' | grep -Fxq -- "$RISH_FW_ZONE" || {
    rish_fw_error "Зона ${RISH_FW_ZONE} не найдена."; return 1;
  }
}

rish_fw_set_name() {
  local id="${RISH_FW_LIST_ID:-manual}"
  [[ "$id" =~ ^[a-z][a-z0-9_-]{0,15}$ && ( "$1" == 4 || "$1" == 6 ) ]] || return 2
  printf 'rish_%s_ipv%s\n' "$id" "$1"
}

rish_fw_list_path() {
  local id="${RISH_FW_LIST_ID:-manual}"
  [[ "$id" =~ ^[a-z][a-z0-9_-]{0,15}$ && ( "$1" == 4 || "$1" == 6 ) ]] || return 2
  if [[ "$id" == manual ]]; then
    printf '%s/manual-ipv%s.txt\n' "$RISH_FW_LIST_DIR" "$1"
  else
    printf '%s/%s/ipv%s.txt\n' "$RISH_FW_LIST_DIR" "$id" "$1"
  fi
}

# Validate every line before producing output; comments and empty lines are allowed.
# Python's ipaddress module is available in Python 3.6 and needs no extra package.
rish_fw_normalize() {
  python3 - "$1" "$2" "${3:-collapse}" <<'PY'
import ipaddress, sys
src, dst, mode = sys.argv[1:]
networks = []
try:
    with open(src, encoding='utf-8-sig') as handle:
        for number, line in enumerate(handle, 1):
            value = line.split('#', 1)[0].strip()
            if not value:
                continue
            if len(value.split()) != 1:
                raise ValueError('строка %d: требуется один IP/CIDR' % number)
            if '%' in value:
                raise ValueError('строка %d: IPv6 zone ID не поддерживается' % number)
            try:
                net = ipaddress.ip_network(value, strict=False)
            except ValueError:
                raise ValueError('строка %d: неверный IP/CIDR' % number)
            loopback = ipaddress.ip_network('127.0.0.0/8' if net.version == 4 else '::1/128')
            if net.prefixlen == 0 or net.network_address.is_unspecified or net.overlaps(loopback):
                raise ValueError('строка %d: default route, неопределённый адрес или loopback запрещены' % number)
            networks.append(net)
    result = []
    for version in (4, 6):
        selected = set(n for n in networks if n.version == version)
        result.extend(ipaddress.collapse_addresses(selected) if mode == 'collapse' else sorted(selected))
    with open(dst, 'w', encoding='utf-8') as handle:
        for net in result:
            handle.write(str(net) + '\n')
except (ValueError, OSError, UnicodeError) as error:
    print('Ошибка списка: %s' % error, file=sys.stderr)
    sys.exit(1)
PY
}

rish_fw_network() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    if '%' in sys.argv[1]:
        raise ValueError()
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    loopback = ipaddress.ip_network('127.0.0.0/8' if net.version == 4 else '::1/128')
    if net.prefixlen == 0 or net.network_address.is_unspecified or net.overlaps(loopback):
        raise ValueError()
    print(net)
except ValueError:
    print('Неверный или запрещённый IP/CIDR.', file=sys.stderr)
    sys.exit(1)
PY
}

# Preserve the editable document separately from its validated network snapshot.
# SOURCE is a dynamically scoped, internal transaction snapshot, never user input.
rish_fw_whitelist_read() {
  local target="$1" source_file
  rish_fw_paths || return 1
  source_file="${RISH_FW_WHITELIST_SOURCE:-$RISH_FW_WHITELIST}"
  if [[ -z "${RISH_FW_WHITELIST_SOURCE:-}" ]]; then
    rish_fw_secure_path "$source_file" || return 1
  fi
  [[ ! -e "$source_file" && ! -L "$source_file" ]] || [[ -f "$source_file" && ! -L "$source_file" ]] || return 1
  python3 - "$source_file" "$target" <<'PY'
import ipaddress, os, sys
source, target = sys.argv[1:]
try:
    networks = set()
    if os.path.exists(source):
        with open(source, encoding='utf-8') as handle:
            document = handle.read(1048577)
        if len(document.encode('utf-8')) > 1048576:
            raise ValueError('размер списка превышает 1 МиБ')
        for number, line in enumerate(document.splitlines(), 1):
            value = line.split('#', 1)[0].strip()
            if not value:
                continue
            if '%' in value or len(value.split()) != 1:
                raise ValueError('строка %d: требуется один IP или CIDR' % number)
            try:
                net = ipaddress.ip_network(value, strict=False)
            except ValueError:
                raise ValueError('строка %d: неверный IP или CIDR' % number)
            if net.version == 6 and net.prefixlen < 96 and net.overlaps(ipaddress.ip_network('::ffff:0:0/96')):
                raise ValueError('строка %d: слишком широкая IPv4-mapped подсеть' % number)
            if net.version == 6 and net.network_address.ipv4_mapped:
                if net.prefixlen < 96:
                    raise ValueError('строка %d: слишком широкая IPv4-mapped подсеть' % number)
                net = ipaddress.ip_network((net.network_address.ipv4_mapped, net.prefixlen - 96), strict=False)
            loopback = ipaddress.ip_network('127.0.0.0/8' if net.version == 4 else '::1/128')
            if net.prefixlen == 0 or net.network_address.is_unspecified or net.overlaps(loopback) or net.is_multicast:
                raise ValueError('строка %d: default route, неопределённый адрес, loopback и multicast запрещены' % number)
            networks.add(net)
            if len(networks) > 4096:
                raise ValueError('допускается не более 4096 адресов и подсетей')
    result = []
    for family in (4, 6):
        result.extend(ipaddress.collapse_addresses(n for n in networks if n.version == family))
    with open(target, 'w', encoding='utf-8') as handle:
        for net in result:
            handle.write(str(net) + '\n')
except (OSError, UnicodeError, ValueError) as error:
    print('Ошибка белого списка: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
}

# Subtract ranges rather than accepting whitelist traffic ahead of port rules.
rish_fw_whitelist_filter() (
  local input="$1" output="$2" work
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_whitelist_read "$work/white" || return 1
  python3 - "$input" "$output" "$work/white" <<'PY'
import bisect, ipaddress, sys
source, target, whitelist = sys.argv[1:]
try:
    with open(whitelist, encoding='utf-8') as handle:
        white = [ipaddress.ip_network(line.strip()) for line in handle if line.strip()]
    # Existing inet6 sets/journals may contain mapped addresses. Keep their
    # native family and subtract the IPv6 equivalents of protected IPv4 ranges.
    white.extend(ipaddress.ip_network((ipaddress.IPv6Address((0xffff << 32) | int(n.network_address)), n.prefixlen + 96))
                 for n in list(white) if n.version == 4)
    ranges = {}
    for family in (4, 6):
        nets = list(ipaddress.collapse_addresses(n for n in white if n.version == family))
        ranges[family] = ([int(n.network_address) for n in nets], [int(n.broadcast_address) for n in nets])
    result, seen, additional = set(), set(), 0
    with open(source, encoding='utf-8') as handle:
        for line in handle:
            value = line.split('#', 1)[0].strip()
            if not value:
                continue
            net = ipaddress.ip_network(value, strict=False)
            if net in seen:
                continue
            seen.add(net)
            fragments = []
            starts, ends = ranges[net.version]
            first, last = int(net.network_address), int(net.broadcast_address)
            index = bisect.bisect_left(ends, first)
            address_type = ipaddress.IPv4Address if net.version == 4 else ipaddress.IPv6Address
            while index < len(starts) and starts[index] <= last:
                if first < starts[index]:
                    fragments.extend(ipaddress.summarize_address_range(address_type(first), address_type(starts[index] - 1)))
                    if additional + max(0, len(fragments) - 1) > 8192:
                        raise ValueError('исключение белого списка создаёт более 8192 дополнительных подсетей; уменьшите диапазон')
                first = max(first, ends[index] + 1)
                index += 1
                if first > last:
                    break
            if first <= last:
                fragments.extend(ipaddress.summarize_address_range(address_type(first), address_type(last)))
            # Bound only fragmentation, not the size of an existing blocklist.
            additional += max(0, len(fragments) - 1)
            if additional > 8192:
                raise ValueError('исключение белого списка создаёт более 8192 дополнительных подсетей; уменьшите диапазон')
            result.update(fragments)
    with open(target, 'w', encoding='utf-8') as handle:
        for net in sorted(result, key=lambda n: (n.version, int(n.network_address), n.prefixlen)):
            handle.write(str(net) + '\n')
except (OSError, UnicodeError, ValueError) as error:
    print('Не удалось исключить белый список: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
)

rish_fw_whitelist_guard_file() (
  local work
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_normalize "$1" "$work/before" preserve &&
    rish_fw_whitelist_filter "$work/before" "$work/after" || return 1
  cmp -s "$work/before" "$work/after" || {
    rish_fw_error "Список пересекается с белым списком. Сначала сохраните белый список через его редактор для сверки блокировок."
    return 1
  }
)

rish_fw_whitelist_template() {
  cat <<'TEXT'
# Белый список RISH
#
# Указанные адреса исключаются из анализа активных IP
# и из блокировок RISH, включая блокировку сервера.
# Доступ по портам определяется настройками firewalld.
#
# Добавляйте один IPv4, IPv6 или подсеть CIDR на строку.
# Подсеть исключает из анализа и блокировок все её адреса.
# После символа # можно написать пояснение.
# Пустые строки и комментарии игнорируются.
# Default route /0, неопределённые адреса, loopback,
# multicast и IPv6 zone ID (например %eth0) не допускаются.
#
# Примеры закомментированы. Добавьте свои адреса ниже:
# 203.0.113.10       # Мой внешний IP
# 198.51.100.0/24    # Доверенная подсеть
# 2001:db8::10       # Доверенный IPv6
#
# Изменяйте список через пункт «Редактирование белого списка».
# Сохраните файл и закройте редактор для применения.
# При ошибке в адресах изменения не применяются.
# Удаление из белого списка разрешает будущие блокировки;
# ранее снятые блокировки автоматически не возвращаются.

TEXT
}

# The editable file is committed last. Every native change keeps an undo log;
# the same flock covers saving, imports, temporary bans and server isolation.
rish_fw_whitelist_apply() (
  local candidate="$1" expected="${2:-}" work ids id family mode path info state failed=0 rollback_failed=0
  local temporary_changed=0 isolation_changed=0 item
  local RISH_FW_LIST_ID RISH_FW_ATTACH_GATE=0 RISH_FW_WHITELIST_SOURCE
  local -a whitelist_changes=()
  rish_fw_active && rish_fw_lock || return 1
  rish_fw_secure_path "$RISH_FW_WHITELIST" || return 1
  [[ ! -e "$RISH_FW_WHITELIST" || -f "$RISH_FW_WHITELIST" ]] || return 1
  umask 077
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  : >"$work/old-document" || return 1
  if [[ -e "$RISH_FW_WHITELIST" ]]; then cp -- "$RISH_FW_WHITELIST" "$work/old-document" || return 1; fi
  if [[ -n "$expected" ]] && ! cmp -s "$expected" "$work/old-document"; then
    rish_fw_error "Белый список изменился в другой сессии. Откройте редактор заново."
    return 1
  fi
  cp -- "$candidate" "$work/document" || return 1
  RISH_FW_WHITELIST_SOURCE="$work/old-document"
  if ! rish_fw_whitelist_read "$work/old-white" 2>"$work/old-error"; then
    # Repairing an invalid document is safe when isolation is off. With active
    # isolation its previous exceptions must remain recoverable for rollback.
    rish_fw_server_lock_refresh || return 1
    if [[ "$RISH_FW_SERVER_LOCK_STATE" != off ]]; then
      cat -- "$work/old-error" >&2
      rish_fw_error "Для исправления повреждённого белого списка сначала снимите блокировку сервера."
      return 1
    fi
    : >"$work/old-white" || return 1
  fi
  RISH_FW_WHITELIST_SOURCE="$work/document"
  rish_fw_whitelist_read "$work/new-white" || return 1
  rish_fw_temporary_snapshot "$work/old-ledger" || return 1
  ids=$(rish_fw_list_ids) || return 1
  # Read all lists before the first mutation, including disabled/shared lists.
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    RISH_FW_LIST_ID="$id"
    for family in 4 6; do
      item="$work/$id-$family"
      mkdir -- "$item" || return 1
      for mode in runtime permanent; do
        info=$(rish_fw_ipset_info "$family" "$mode"); state=$?
        [[ "$state" == 0 || "$state" == 1 ]] || return 1
        printf '%s\n' "$state" >"$item/state-$mode" || return 1
        : >"$item/raw-$mode" || return 1
        if [[ "$state" == 0 ]]; then rish_fw_entries_from_info "$family" "$info" >"$item/raw-$mode" || return 1; fi
        rish_fw_normalize "$item/raw-$mode" "$item/$mode" preserve || return 1
      done
      if ! cmp -s "$item/state-runtime" "$item/state-permanent" || ! cmp -s "$item/runtime" "$item/permanent"; then
        rish_fw_error "Список ${id}, IPv${family}: действующие и сохранённые данные различаются. Сначала требуется сверка."
        return 1
      fi
      rish_fw_whitelist_filter "$item/permanent" "$item/desired" || return 1
      path=$(rish_fw_list_path "$family") || return 1
      rish_fw_secure_path "$path" || return 1
      if [[ -e "$path" ]]; then
        [[ -f "$path" ]] && cp -- "$path" "$item/file" || return 1
        rish_fw_normalize "$path" "$item/file-normalized" preserve || return 1
        if [[ $(cat "$item/state-permanent") == 0 ]] && ! cmp -s "$item/file-normalized" "$item/permanent"; then
          rish_fw_error "Файл списка ${id}, IPv${family} отличается от firewalld. Сначала требуется сверка."
          return 1
        fi
        rish_fw_whitelist_filter "$item/file-normalized" "$item/new-file" || return 1
      fi
    done
  done <<<"$ids"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    RISH_FW_LIST_ID="$id"
    for family in 4 6; do
      item="$work/$id-$family"; path=$(rish_fw_list_path "$family") || { failed=1; break; }
      if ! cmp -s "$item/permanent" "$item/desired"; then
        whitelist_changes+=("$id/$family")
        rish_fw_permanent_apply "$family" "$item/desired" preserve "$item/undo" || { failed=1; break; }
      elif [[ -f "$item/file" ]] && ! cmp -s "$item/file-normalized" "$item/new-file"; then
        whitelist_changes+=("$id/$family")
        rish_fw_atomic_file "$item/new-file" "$path" || { failed=1; break; }
      fi
    done
    [[ "$failed" == 0 ]] || break
  done <<<"$ids"
  if [[ "$failed" == 0 ]]; then
    if rish_fw_temporary_whitelist_apply; then temporary_changed=1; else failed=1; fi
  fi
  if [[ "$failed" == 0 ]]; then
    if rish_fw_server_lock_whitelist_apply; then isolation_changed=1; else failed=1; fi
  fi
  if [[ "$failed" == 0 ]]; then
    rish_fw_atomic_file "$work/document" "$RISH_FW_WHITELIST" || failed=1
  fi
  if [[ "$failed" == 0 ]]; then
    rish_fw_ui_changed || true
    printf 'Белый список %sприменён и сохранён%s.\n' "$RISH_FW_GREEN" "$RISH_FW_RESET"
    rish_fw_field "Файл" "$RISH_FW_WHITELIST"
    return 0
  fi
  RISH_FW_WHITELIST_SOURCE="$work/old-white"
  if [[ "$isolation_changed" == 1 ]]; then rish_fw_server_lock_whitelist_apply || rollback_failed=1; fi
  if [[ "$temporary_changed" == 1 ]]; then rish_fw_temporary_restore "$work/old-ledger" || rollback_failed=1; fi
  local index
  for ((index=${#whitelist_changes[@]}-1; index>=0; index--)); do
    id="${whitelist_changes[index]%/*}"; family="${whitelist_changes[index]##*/}"
    RISH_FW_LIST_ID="$id"; item="$work/$id-$family"
    RISH_FW_OPERATION_SET=$(rish_fw_set_name "$family") || { rollback_failed=1; continue; }
    if [[ -f "$item/undo" ]]; then rish_fw_rollback_ops "$item/undo" || rollback_failed=1; fi
    path=$(rish_fw_list_path "$family") || { rollback_failed=1; continue; }
    if [[ -f "$item/file" ]]; then rish_fw_atomic_file "$item/file" "$path" || rollback_failed=1;
    else rm -f -- "$path" || rollback_failed=1; fi
    for mode in runtime permanent; do
      rish_fw_current_entries "$family" "$mode" >"$item/verify-raw" &&
        rish_fw_normalize "$item/verify-raw" "$item/verify" preserve &&
        cmp -s "$item/$mode" "$item/verify" || rollback_failed=1
    done
  done
  rish_fw_error "Белый список не сохранён; выполнен откат изменений блокировок."
  [[ "$rollback_failed" == 0 ]] || rish_fw_error "Полный откат не подтверждён. Проверьте списки блокировок и состояние блокировки сервера."
  return 1
)

rish_fw_whitelist_edit() (
  local work choice
  command -v mcedit >/dev/null 2>&1 || { rish_fw_error "Редактор mcedit не найден."; return 1; }
  rish_fw_paths && rish_fw_secure_path "$RISH_FW_WHITELIST" || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  : >"$work/original" || return 1
  if [[ -e "$RISH_FW_WHITELIST" ]]; then
    [[ -f "$RISH_FW_WHITELIST" ]] && cp -- "$RISH_FW_WHITELIST" "$work/original" || return 1
    cp -- "$work/original" "$work/edit.txt" || return 1
  else rish_fw_whitelist_template >"$work/edit.txt" || return 1; fi
  while true; do
    mcedit "$work/edit.txt" || return 1
    cmp -s "$work/original" "$work/edit.txt" && return 0
    if rish_fw_whitelist_apply "$work/edit.txt" "$work/original"; then return 0; fi
    choice=0
    vertical_menu current 2 0 32 default=0 "Отмена" "Вернуться в редактор" || choice=$?
    [[ "$choice" == 1 ]] || return 1
  done
)

rish_fw_whitelist_add_peer() (
  local peer work RISH_FW_WHITELIST_SOURCE
  peer=$(rish_fw_server_lock_peer) || return 1
  rish_fw_paths && rish_fw_secure_path "$RISH_FW_WHITELIST" || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  : >"$work/original" || return 1
  if [[ -e "$RISH_FW_WHITELIST" ]]; then
    [[ -f "$RISH_FW_WHITELIST" ]] && cp -- "$RISH_FW_WHITELIST" "$work/original" || return 1
    cp -- "$work/original" "$work/edit" || return 1
  else rish_fw_whitelist_template >"$work/edit" || return 1; fi
  printf '%s\n' "$peer" >"$work/peer" || return 1
  RISH_FW_WHITELIST_SOURCE="$work/original"
  rish_fw_whitelist_filter "$work/peer" "$work/remaining" || return 1
  if [[ ! -s "$work/remaining" ]]; then
    printf 'IP %s%s%s уже входит в белый список.\n' "$RISH_FW_GREEN" "$peer" "$RISH_FW_RESET"
    return 0
  fi
  printf '\n%s # Текущий SSH-IP\n' "$peer" >>"$work/edit" || return 1
  rish_fw_whitelist_apply "$work/edit" "$work/original" || return 1
  rish_fw_field "Добавленный IP" "$peer"
)

rish_fw_ip_lookup() {
  python3 - "$1" "$RISH_FW_GREEN" "$RISH_FW_YELLOW" "$RISH_FW_RESET" "${2:-}" "${3:-}" "${4:-10}" <<'PY'
import ipaddress, json, math, os, re, selectors, shutil, signal, subprocess, sys, time, unicodedata
from urllib.parse import quote

value, green, yellow, reset, result_path, summary_path, timeout_value = sys.argv[1:]
try:
    timeout = float(timeout_value)
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError()
    timeout = min(timeout, 10)
except ValueError:
    timeout = 10
deadline = time.monotonic() + timeout
summary = dict.fromkeys(('organization', 'name', 'country', 'asn', 'prefix'), '')
summary['status'] = 'unavailable'
address = ''

def interrupted(signum, frame):
    raise KeyboardInterrupt()

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)

def clean(value):
    if not isinstance(value, str):
        return ''
    return ' '.join(''.join(' ' if unicodedata.category(c).startswith('C') else c for c in value).split())[:240]

def field(label, value, available=True):
    print('%s: %s%s%s' % (label, green if available else yellow, value, reset))

def result(prefix=''):
    if result_path:
        with open(result_path, 'w', encoding='utf-8') as handle:
            handle.write('%s\n%s\n' % (address, prefix))

def save_summary():
    if summary_path:
        with open(summary_path, 'w', encoding='utf-8') as handle:
            json.dump(summary, handle, ensure_ascii=False)

save_summary()
result()
try:
    if '%' in value:
        raise ValueError()
    interface = ipaddress.ip_interface(value.strip())
    address = interface.ip
except ValueError:
    print('Неверный IP-адрес или CIDR.', file=sys.stderr)
    sys.exit(1)
result()
if '/' in value:
    field('Введённая сеть', str(interface.network))
field('Адрес поиска', str(address))
if (not address.is_global or address.is_multicast or address.is_reserved or
        getattr(address, 'is_site_local', False) or getattr(address, 'ipv4_mapped', None) is not None or
        getattr(address, 'sixtofour', None) is not None):
    summary['status'] = 'special'
    save_summary()
    field('Сведения', 'локальный или специальный адрес; внешний запрос не выполняется', False)
    sys.exit(0)
if shutil.which('curl') is None:
    print('Ошибка: Для сведений об IP требуется curl.', file=sys.stderr)
    sys.exit(1)

# Initial requests and optional RIPE organization resolution share one budget.
limit, received = 512 * 1024, 0
def fetch(urls):
    global received
    selector, requests = selectors.DefaultSelector(), {}
    for endpoint, url in urls.items():
        state = {'body': bytearray(), 'error': None, 'process': None}
        requests[endpoint] = state
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            state['error'] = 'истекло время ожидания'
            continue
        if received >= limit:
            state['error'] = 'ответ превышает допустимый размер'
            continue
        try:
            process = subprocess.Popen(
                ['curl', '--silent', '--fail', '--proto', '=https', '--proto-redir', '=https',
                 '--connect-timeout', str(min(2, remaining)), '--max-time', str(min(8, remaining)),
                 '--max-filesize', str(limit - received), url],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            state['process'] = process
            selector.register(process.stdout, selectors.EVENT_READ, endpoint)
        except OSError:
            state['error'] = 'не удалось выполнить запрос'
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            for key, _ in selector.select(remaining):
                state = requests[key.data]
                chunk = os.read(key.fd, min(65536, limit - received + 1))
                if chunk:
                    received += len(chunk)
                    if received > limit:
                        state['error'] = 'ответ превышает допустимый размер'
                        break
                    state['body'].extend(chunk)
                else:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    try:
                        result = state['process'].wait(timeout=max(0.001, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired:
                        state['error'] = 'истекло время ожидания'
                    else:
                        if result != 0:
                            state['error'] = ('истекло время ожидания' if result == 28 else
                                              'ответ превышает допустимый размер' if result == 63 else 'запрос не выполнен')
            if received > limit:
                break
    finally:
        for key in list(selector.get_map().values()):
            state = requests[key.data]
            state['error'] = state['error'] or ('ответ превышает допустимый размер' if received > limit else 'истекло время ожидания')
            selector.unregister(key.fileobj)
            key.fileobj.close()
        selector.close()
        for state in requests.values():
            process = state['process']
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
    return requests

requests = fetch({endpoint: 'https://stat.ripe.net/data/%s/data.json?resource=%s' %
                  (endpoint, quote(str(address), safe='')) for endpoint in ('whois', 'network-info')})

data = {}
for endpoint, state in requests.items():
    if state['error'] is None:
        try:
            response = json.loads(state['body'])
            if not isinstance(response, dict) or response.get('status') != 'ok' or not isinstance(response.get('data'), dict):
                raise ValueError()
            data[endpoint] = response['data']
        except (ValueError, UnicodeError):
            state['error'] = 'получен некорректный ответ'

# Only registry records supply organization and registration country. IRR
# descriptions/origins describe routing objects and are not used for these fields.
records = data.get('whois', {}).get('records', [])
registry, network_countries = {}, []
if isinstance(records, list):
    for record in records:
        if not isinstance(record, list):
            continue
        fields = {}
        for item in record:
            if isinstance(item, dict):
                key, content = clean(item.get('key')).casefold(), clean(item.get('value'))
                if key and content:
                    fields.setdefault(key, []).append(content)
                    registry.setdefault(key, []).append(content)
        if any(key in fields for key in ('inetnum', 'inet6num', 'netrange', 'netname')):
            network_countries.extend(fields.get('country', []))

def first(keys):
    return next((registry[key][0] for key in keys if registry.get(key)), '')

organization = first(('org-name', 'orgname', 'organization'))
organization_id = first(('org', 'organisation', 'orgid'))
rdap_name = False
if not organization and re.fullmatch(r'ORG-[A-Za-z0-9]+-RIPE', organization_id):
    requests.update(fetch({'rdap': 'https://rdap.db.ripe.net/entity/' + quote(organization_id, safe='')}))
    state = requests['rdap']
    if state['error'] is None:
        try:
            entity = json.loads(state['body'])
            if (not isinstance(entity, dict) or entity.get('objectClassName') != 'entity' or
                    entity.get('handle', '').casefold() != organization_id.casefold()):
                raise ValueError()
            card = entity.get('vcardArray')
            if not isinstance(card, list) or len(card) != 2 or card[0] != 'vcard' or not isinstance(card[1], list):
                raise ValueError()
            for item in card[1]:
                if isinstance(item, list) and len(item) >= 4 and item[0] == 'fn':
                    organization = clean(item[3])
                    if organization:
                        rdap_name = True
                        break
            if not organization:
                state['error'] = 'имя организации не получено'
        except (ValueError, UnicodeError, AttributeError):
            state['error'] = 'получен некорректный ответ'
name = first(('netname',))
ip_range = first(('inetnum', 'inet6num', 'netrange', 'cidr'))
country = next(iter(network_countries), '') or first(('country',))
route = data.get('network-info', {})
asns = []
if isinstance(route.get('asns'), list):
    for asn in route['asns']:
        text = str(asn)
        if re.fullmatch(r'[0-9]{1,10}', text) and 0 < int(text) <= 4294967295:
            label = 'AS' + str(int(text))
            if label not in asns:
                asns.append(label)
prefix = ''
try:
    announced = ipaddress.ip_network(route.get('prefix', ''), strict=False)
    if address.version == announced.version and address in announced:
        prefix = str(announced)
except (ValueError, TypeError):
    pass
if prefix and 0 < announced.prefixlen < address.max_prefixlen:
    result(prefix)
available = any((organization, organization_id, name, ip_range, country, asns, prefix))
summary.update(organization=clean(organization), name=clean(name), country=clean(country),
               asn=clean(', '.join(asns)), prefix=prefix,
               status=('partial' if any(state['error'] for state in requests.values()) else 'ok')
               if available else 'unavailable')
save_summary()
print()
for label, content in (('Организация', organization), ('Название сети', name),
                       ('Диапазон (WHOIS)', ip_range), ('Страна регистрации', country),
                       ('ASN', ', '.join(asns)), ('Анонсируемая сеть', prefix)):
    field(label, content or 'нет данных', bool(content))
if organization_id and not organization:
    field('Идентификатор организации', organization_id)
field('Источник', 'RIPEstat / RIPE Database' if rdap_name else 'RIPEstat (RIPE NCC)')
for endpoint, state in requests.items():
    if state['error']:
        label = {'whois': 'WHOIS', 'network-info': 'Данные маршрутизации', 'rdap': 'Имя организации (RIPE Database)'}[endpoint]
        field(label, state['error'], False)
sys.exit(0 if available else 1)
PY
}

rish_fw_ip_lookups() {
  python3 - "$1" "$2" "$3" "${BASH_SOURCE[0]}" "${RISH_FIREWALL_TEST_MODE:-0}" "${RISH_FIREWALL_LOOKUP_BUDGET:-15}" <<'PY'
import ipaddress, json, math, os, signal, subprocess, sys, tempfile, time, unicodedata

stats_path, output_path, cache_path, script_path, test_mode, budget_value = sys.argv[1:]
budget = 15
if test_mode == '1':
    try:
        candidate = float(budget_value)
        if math.isfinite(candidate) and candidate > 0:
            budget = min(candidate, budget)
    except ValueError:
        pass
deadline = time.monotonic() + budget
fields = ('organization', 'name', 'country', 'asn', 'prefix', 'status')
empty = dict.fromkeys(fields, '')
empty['status'] = 'unavailable'

def clean(value):
    if not isinstance(value, str):
        return ''
    return ' '.join(''.join(' ' if unicodedata.category(c).startswith('C') else c for c in value).split())[:240]

def valid_summary(value):
    if not isinstance(value, dict) or value.get('status') not in ('ok', 'partial', 'special'):
        return None
    return {key: clean(value.get(key)) for key in fields}

def read_json(path, fallback):
    try:
        with open(path, encoding='utf-8') as handle:
            return json.load(handle)
    except (OSError, ValueError, UnicodeError):
        return fallback

stats = read_json(stats_path, {})
rows = stats.get('rows', []) if isinstance(stats, dict) else []
addresses = []
for row in rows if isinstance(rows, list) else []:
    value = row.get('ip') if isinstance(row, dict) else None
    try:
        if not isinstance(value, str) or '%' in value:
            raise ValueError()
        ipaddress.ip_address(value)
    except ValueError:
        continue
    if value not in addresses:
        addresses.append(value)
cached = read_json(cache_path, {})
cache = {}
if isinstance(cached, dict):
    for key, value in cached.items():
        sanitized = valid_summary(value)
        if sanitized is not None:
            cache[key] = sanitized
output = {address: cache.get(address, dict(empty)) for address in addresses}
pending = [address for address in addresses if address not in cache or cache[address]['status'] == 'partial']
active = {}
script_path = os.path.abspath(script_path)
worker_script = 'source "$1" && rish_fw_ip_lookup "$2" "" "$3" "$4"'

def interrupted(signum, frame):
    raise KeyboardInterrupt()

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)

def collect(process, address, path):
    process.wait()
    value = valid_summary(read_json(path, {}))
    if value is not None:
        if value['status'] == 'partial' and cache.get(address, {}).get('status') == 'partial':
            value = {key: value[key] or cache[address][key] for key in fields}
        output[address] = value
        cache[address] = value

def stop_workers():
    # Each worker has its own group, including its Python parser and curl children.
    for process in active:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for process in active:
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

exit_status = 0
try:
    with tempfile.TemporaryDirectory(prefix='rish-ip-lookups-') as directory:
        try:
            while pending or active:
                for process, (address, path) in list(active.items()):
                    if process.poll() is not None:
                        collect(process, address, path)
                        del active[process]
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                while pending and len(active) < 4:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    address = pending.pop(0)
                    path = os.path.join(directory, str(len(addresses) - len(pending)) + '.json')
                    try:
                        process = subprocess.Popen(
                            ['/bin/bash', '-c', worker_script, 'rish-ip-lookup', script_path,
                             address, path, str(min(10, remaining))],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                        active[process] = (address, path)
                    except OSError:
                        continue
                if active:
                    time.sleep(min(0.03, max(0, deadline - time.monotonic())))
        finally:
            stop_workers()
except KeyboardInterrupt:
    exit_status = 130
try:
    with open(output_path, 'w', encoding='utf-8') as handle:
        json.dump(output, handle, ensure_ascii=False)
    if cache_path:
        with open(cache_path, 'w', encoding='utf-8') as handle:
            json.dump(cache, handle, ensure_ascii=False)
except OSError as error:
    print('Не удалось сохранить сведения об IP: %s' % error, file=sys.stderr)
    sys.exit(1)
sys.exit(exit_status)
PY
}

rish_fw_family() { [[ "$1" == *:* ]] && printf '6\n' || printf '4\n'; }

rish_fw_ssh_guard() {
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]] || {
    if [[ "${RISH_FIREWALL_TEST_MODE:-0}" == 1 ]]; then
      return 0
    fi
    rish_fw_error "Адрес текущего SSH-клиента неизвестен. Блокировка недоступна в этой сессии."
    return 1
  }
  python3 - "$1" "${SSH_CONNECTION:-${SSH_CLIENT:-}}" <<'PY'
import ipaddress, sys
try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    peer = ipaddress.ip_address(sys.argv[2].split()[0])
    if peer.version == 6 and peer.ipv4_mapped:
        peer = peer.ipv4_mapped
    if peer.version == 4 and net.version == 6:
        peer = ipaddress.IPv6Address((0xffff << 32) | int(peer))
    if peer.version == net.version and peer in net:
        raise ValueError()
except (ValueError, IndexError):
    print('Блокировка запрещена: CIDR включает текущий SSH-клиент либо SSH-контекст неверен.', file=sys.stderr)
    sys.exit(1)
PY
}

# Check a whole addition/attachment in one process, before the first mutation.
# Empty inputs need no SSH context, just like an empty per-entry guard loop.
rish_fw_ssh_guard_file() {
  python3 - "${SSH_CONNECTION:-${SSH_CLIENT:-}}" "${RISH_FIREWALL_TEST_MODE:-0}" "$@" <<'PY'
import ipaddress, sys
context, test_mode, *paths = sys.argv[1:]
peer = None
try:
    for path in paths:
        with open(path, encoding='utf-8') as handle:
            for line in handle:
                value = line.strip()
                if not value:
                    continue
                if not context:
                    if test_mode == '1':
                        continue
                    raise ValueError('Адрес текущего SSH-клиента неизвестен. Блокировка недоступна в этой сессии.')
                if peer is None:
                    peer = ipaddress.ip_address(context.split()[0])
                    if peer.version == 6 and peer.ipv4_mapped:
                        peer = peer.ipv4_mapped
                net = ipaddress.ip_network(value, strict=False)
                comparable = ipaddress.IPv6Address((0xffff << 32) | int(peer)) if peer.version == 4 and net.version == 6 else peer
                if comparable.version == net.version and comparable in net:
                    raise ValueError('CIDR включает текущий SSH-клиент')
except (OSError, UnicodeError, ValueError, IndexError) as error:
    print('Блокировка запрещена: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
}

rish_fw_temp_rule() {
  printf 'rule priority="-110" family="ipv%s" source address="%s" drop' "$(rish_fw_family "$1")" "$1"
}

rish_fw_set_rule() {
  printf 'rule priority="-100" family="ipv%s" source ipset="%s" drop' "$1" "$(rish_fw_set_name "$1")"
}

# Server isolation is runtime-only and never grants the peer additional ports.
# Keep its journal after expiry/reload until old firewalld timeout handles have
# been cancelled; reusing an identical rule with an orphan timer is unsafe.
rish_fw_server_lock_peer() {
  python3 - "${SSH_CONNECTION:-}" "${SSH_CLIENT:-}" <<'PY'
import ipaddress, sys
try:
    connection, client = sys.argv[1:]
    parts = (connection or client).split()
    if len(parts) != (4 if connection else 3):
        raise ValueError('нет достоверного SSH-контекста')
    peer = ipaddress.ip_address(parts[0])
    if '%' in parts[0] or peer.is_unspecified or peer.is_multicast:
        raise ValueError('недопустимый адрес SSH-клиента')
    ports = (parts[1], parts[3]) if connection else (parts[1], parts[2])
    if any(not value.isdigit() or not 1 <= int(value) <= 65535 for value in ports):
        raise ValueError('некорректные порты SSH-контекста')
    if connection:
        ipaddress.ip_address(parts[2])
    if peer.version == 6 and peer.ipv4_mapped:
        peer = peer.ipv4_mapped
    print(peer)
except (ValueError, IndexError) as error:
    print('Не удалось определить IP текущего SSH-подключения: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
}

rish_fw_server_lock_icmptypes() {
  printf '%s\n' neighbour-advertisement neighbour-solicitation router-advertisement redirect \
    mld-listener-done mld-listener-query mld-listener-report mld2-listener-report
}

rish_fw_server_lock_legacy_rules() {
  local peer="$1" family other kind
  family=$(rish_fw_family "$peer"); other=6; [[ "$family" != 6 ]] || other=4
  while IFS= read -r kind; do
    printf 'rule priority="-32001" family="ipv6" icmp-type name="%s" accept\n' "$kind"
  done < <(rish_fw_server_lock_icmptypes)
  # Match the standard dhcpv6-client service without trusting service overrides.
  # Replies to multicast DHCPv6 requests need not be conntrack ESTABLISHED.
  printf 'rule priority="-32001" family="ipv6" destination address="fe80::/64" port port="546" protocol="udp" accept\n'
  printf 'rule priority="-32000" family="ipv%s" source NOT address="%s" drop\n' "$family" "$peer"
  printf 'rule priority="-32000" family="ipv%s" drop\n' "$other"
}

# Compute only DROP exclusions: trusted addresses still use the zone's ports.
# A snapshot in the journal keeps cleanup independent of later whitelist edits.
rish_fw_server_lock_rules() (
  local peer="$1" work kind
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_whitelist_read "$work/whitelist" || return 1
  python3 - "$peer" "$work/whitelist" >"$work/drops" <<'PY'
import ipaddress, sys
try:
    peer = ipaddress.ip_address(sys.argv[1])
    protected = [ipaddress.ip_network(str(peer))]
    with open(sys.argv[2], encoding='utf-8') as handle:
        protected.extend(ipaddress.ip_network(line.strip()) for line in handle if line.strip())
    drops = []
    def add_gap(first, last, address_type):
        for net in ipaddress.summarize_address_range(address_type(first), address_type(last)):
            if len(drops) >= 2048:
                raise ValueError('белый список требует более 2048 правил ограничения; сократите число отдельных адресов')
            drops.append(net)
    for version in (4, 6):
        address_type = ipaddress.IPv4Address if version == 4 else ipaddress.IPv6Address
        first, last = 0, 2 ** (32 if version == 4 else 128) - 1
        # Collapsed networks are sorted and disjoint. Visit each gap once;
        # do not repeatedly rescan the growing complement for every address.
        for allowed in ipaddress.collapse_addresses(net for net in protected if net.version == version):
            start = int(allowed.network_address)
            if first < start:
                add_gap(first, start - 1, address_type)
            first = int(allowed.broadcast_address) + 1
        if first <= last:
            add_gap(first, last, address_type)
    for net in sorted(drops, key=lambda n: (n.version, int(n.network_address), n.prefixlen)):
        print('rule priority="-32000" family="ipv%d" source address="%s" drop' % (net.version, net))
except (OSError, UnicodeError, ValueError) as error:
    print('Не удалось подготовить исключения блокировки сервера: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
  [[ $? == 0 ]] || return 1
  while IFS= read -r kind; do
    printf 'rule priority="-32001" family="ipv6" icmp-type name="%s" accept\n' "$kind"
  done < <(rish_fw_server_lock_icmptypes)
  printf 'rule priority="-32001" family="ipv6" destination address="fe80::/64" port port="546" protocol="udp" accept\n'
  cat -- "$work/drops"
)

rish_fw_server_lock_owned_rules() {
  if [[ -n "${RISH_FW_SERVER_LOCK_RULES:-}" ]]; then
    printf '%s\n' "$RISH_FW_SERVER_LOCK_RULES"
  else
    rish_fw_server_lock_legacy_rules "$RISH_FW_SERVER_LOCK_IP"
  fi
}

rish_fw_server_lock_read() {
  local record
  RISH_FW_SERVER_LOCK_RULES=""
  rish_fw_paths || return 1
  [[ -e "$RISH_FW_SERVER_LOCK_FILE" || -L "$RISH_FW_SERVER_LOCK_FILE" ]] || return 0
  rish_fw_secure_path "$RISH_FW_SERVER_LOCK_FILE" && [[ -f "$RISH_FW_SERVER_LOCK_FILE" ]] || return 1
  record=$(python3 - "$RISH_FW_SERVER_LOCK_FILE" <<'PY'
import ipaddress, re, sys
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        rows = handle.read().splitlines()
    if not rows or len(rows) > 4106:
        raise ValueError('недопустимое число записей')
    zone, peer, expiry = rows[0].split('\t')
    address = ipaddress.ip_address(peer)
    if (not re.fullmatch(r'[A-Za-z0-9_.-]+', zone) or str(address) != peer or
            '%' in peer or address.is_unspecified or address.is_multicast or
            not re.fullmatch(r'0|[1-9][0-9]{0,11}', expiry)):
        raise ValueError('некорректные поля')
    rules = rows[1:]
    if rules:
        if len(rules) != len(set(rules)):
            raise ValueError('повторное правило')
        kinds = {'neighbour-advertisement', 'neighbour-solicitation', 'router-advertisement', 'redirect',
                 'mld-listener-done', 'mld-listener-query', 'mld-listener-report', 'mld2-listener-report'}
        support = {'rule priority="-32001" family="ipv6" icmp-type name="%s" accept' % kind for kind in kinds}
        support.add('rule priority="-32001" family="ipv6" destination address="fe80::/64" port port="546" protocol="udp" accept')
        legacy = {'rule priority="-32000" family="ipv%d" source NOT address="%s" drop' % (address.version, address),
                  'rule priority="-32000" family="ipv%d" drop' % (6 if address.version == 4 else 4)}
        for rule in rules:
            if rule in support or rule in legacy:
                continue
            match = re.fullmatch(r'rule priority="-32000" family="ipv([46])" source address="([^"\s]+)" drop', rule)
            if not match:
                raise ValueError('неизвестное правило снимка')
            net = ipaddress.ip_network(match[2], strict=True)
            if str(net.version) != match[1] or str(net) != match[2] or (net.version == address.version and address in net):
                raise ValueError('некорректное DROP-правило снимка')
        if not support <= set(rules):
            raise ValueError('неполный служебный снимок')
    print('\t'.join((zone, peer, expiry)))
    for rule in rules:
        print(rule)
except (OSError, UnicodeError, ValueError) as error:
    print('Не удалось прочитать журнал блокировки сервера: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
  ) || return 1
  IFS=$'\t' read -r RISH_FW_SERVER_LOCK_ZONE RISH_FW_SERVER_LOCK_IP RISH_FW_SERVER_LOCK_EXPIRY <<<"$record"
  if [[ "$record" == *$'\n'* ]]; then RISH_FW_SERVER_LOCK_RULES="${record#*$'\n'}"; fi
}

# Validate active bindings separately: a default zone is not necessarily the
# zone actually receiving traffic. An empty list can use the implicit default.
rish_fw_server_lock_zone_check() {
  local expected="$1" current active
  current=$(rish_fw_cmd --get-default-zone) && active=$(rish_fw_cmd --get-active-zones) || return 1
  [[ "$current" == "$expected" ]] || { rish_fw_error "Рабочая зона изменилась. Откройте раздел firewall заново."; return 1; }
  python3 - "$expected" "$active" <<'PY'
import re, sys
try:
    zone, text = sys.argv[1:]
    seen = set()
    current = None
    for line in text.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            match = re.fullmatch(r'([A-Za-z0-9_.-]+)( \(default\))?', line)
            if not match or match[1] in seen:
                raise ValueError('неизвестный формат активных зон')
            current = match[1]
            if match[2] and current != zone:
                raise ValueError('несогласованная пометка зоны по умолчанию')
            seen.add(current)
        elif current is None or not re.match(r'^\s+(interfaces|sources):', line):
            raise ValueError('неизвестный формат привязок зоны')
    others = seen - {zone}
    if others:
        raise ValueError('есть другие активные зоны: ' + ', '.join(sorted(others)))
except ValueError as error:
    print('Блокировка сервера недоступна: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
}

rish_fw_server_lock_refresh() {
  local diagnostics="${1:-quiet}" rules work output expected_count=0 expected_drops=0 foreign_rules=0
  RISH_FW_SERVER_LOCK_STATE=unknown
  RISH_FW_SERVER_LOCK_IP=""; RISH_FW_SERVER_LOCK_ZONE=""; RISH_FW_SERVER_LOCK_EXPIRY=""
  RISH_FW_SERVER_LOCK_PRESENT=0; RISH_FW_SERVER_LOCK_DROPS=0
  rish_fw_server_lock_read || return 1
  if [[ -z "$RISH_FW_SERVER_LOCK_IP" ]]; then
    [[ -n "$RISH_FW_ZONE" ]] || return 1
    rules=$(rish_fw_cmd --zone="$RISH_FW_ZONE" --list-rich-rules) || return 1
    # Reserved priorities without a valid journal have no proven owner.
    if grep -Eq 'priority="?-3200[01]"?([[:space:]]|$)' <<<"$rules"; then return 1; fi
    RISH_FW_SERVER_LOCK_STATE=off
    return 0
  fi
  rules=$(rish_fw_server_lock_owned_rules) || return 1
  work=$(mktemp -d) || return 1
  if ! printf '%s\n' "$rules" >"$work/expected" ||
      ! rish_fw_cmd --zone="$RISH_FW_SERVER_LOCK_ZONE" --list-rich-rules >"$work/actual"; then
    rm -rf -- "$work"; return 1
  fi
  output=$(python3 - "$work" <<'PY'
import os, shlex, sys
try:
    def read(name):
        with open(os.path.join(sys.argv[1], name), encoding='utf-8') as handle:
            return {tuple(sorted(shlex.split(line))) for line in handle if line.strip()}
    expected, actual = read('expected'), read('actual')
    if not expected or any(not row or 'rule' not in row for row in actual):
        raise ValueError('неверный снимок rich rules')
    present = expected & actual
    foreign = sum(any(token.startswith('priority=') and int(token.split('=', 1)[1]) <= -32000
                      for token in row) for row in actual - expected)
    print(len(expected), sum('drop' in row for row in expected), len(present),
          sum('drop' in row for row in present), foreign)
except (OSError, UnicodeError, ValueError) as error:
    print('Не удалось сверить правила блокировки сервера: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
  ) || { rm -rf -- "$work"; return 1; }
  read -r expected_count expected_drops RISH_FW_SERVER_LOCK_PRESENT RISH_FW_SERVER_LOCK_DROPS foreign_rules <<<"$output"
  if ((foreign_rules > 0)); then
    RISH_FW_SERVER_LOCK_STATE=partial
  elif ((RISH_FW_SERVER_LOCK_DROPS == 0)); then
    RISH_FW_SERVER_LOCK_STATE=off
  elif ((RISH_FW_SERVER_LOCK_PRESENT == expected_count && RISH_FW_SERVER_LOCK_DROPS == expected_drops)) &&
      [[ "$RISH_FW_SERVER_LOCK_EXPIRY" == 0 || "$RISH_FW_SERVER_LOCK_EXPIRY" -gt "$(rish_fw_now)" ]]; then
    # A newly added policy/direct rule can bypass otherwise intact zone rules.
    # Recheck coverage instead of treating our journal as proof of isolation.
    if output=$(local RISH_FW_ZONE="$RISH_FW_SERVER_LOCK_ZONE"; rish_fw_server_lock_preflight "$work" "$RISH_FW_SERVER_LOCK_IP" 2>&1); then
      RISH_FW_SERVER_LOCK_STATE=active
    else
      RISH_FW_SERVER_LOCK_STATE=partial
      if [[ "$diagnostics" == verbose && -n "$output" ]]; then printf '%s\n' "$output" >&2; fi
    fi
  else
    RISH_FW_SERVER_LOCK_STATE=partial
  fi
  rm -rf -- "$work"
}

rish_fw_server_lock_summary() {
  case "$RISH_FW_SERVER_LOCK_STATE" in
    off) return 0 ;;
    active)
      rish_fw_field "Блокировка сервера" "включена" "$RISH_FW_YELLOW"
      rish_fw_field "Разрешённый IP" "$RISH_FW_SERVER_LOCK_IP"
      printf 'Исключения белого списка также сохраняют доступ по разрешённым портам.\n'
      rish_fw_field "Зона ограничения" "$RISH_FW_SERVER_LOCK_ZONE"
      if [[ "$RISH_FW_SERVER_LOCK_EXPIRY" == 0 ]]; then
        rish_fw_field "Срок" "до ручного снятия / перезагрузки" "$RISH_FW_YELLOW"
      else
        rish_fw_field "Действует до" "$(rish_fw_date "$RISH_FW_SERVER_LOCK_EXPIRY")" "$RISH_FW_YELLOW"
      fi ;;
    partial)
      rish_fw_field "Блокировка сервера" "требует сверки" "$RISH_FW_YELLOW"
      rish_fw_field "Разрешённый IP режима" "$RISH_FW_SERVER_LOCK_IP"
      printf 'Правила режима применены не полностью или настройки изменились.\n' ;;
    unknown) rish_fw_field "Блокировка сервера" "не удалось проверить" "$RISH_FW_YELLOW" ;;
  esac
}

rish_fw_server_lock_preflight() {
  local work="$1" own_peer="${2:-}" output help kind
  rish_fw_active && rish_fw_server_lock_zone_check "$RISH_FW_ZONE" || return 1
  for kind in rules chains passthroughs; do
    output=$(rish_fw_cmd --direct "--get-all-${kind}") || { rish_fw_error "Не удалось проверить direct-правила."; return 1; }
    [[ -z "${output//[[:space:]]/}" ]] || { rish_fw_error "Есть direct-правила/цепочки. Блокировка сервера требует отдельной проверки."; return 1; }
  done
  rish_fw_cmd --list-all-zones >"${work}/zones" && rish_fw_cmd --get-icmptypes >"${work}/icmptypes" || return 1
  rish_fw_object_snapshot zones "${work}/zones" >/dev/null || return 1
  help=$(LC_ALL=C rish_fw_cmd --help) || return 1
  grep -Eq '^[[:space:]]*--list-all-zones([[:space:]]|$)' <<<"$help" || {
    rish_fw_error "Не удалось распознать возможности firewall-cmd. Блокировка отменена."; return 1;
  }
  : >"${work}/policies" || return 1
  if grep -Eq '^[[:space:]]*--list-all-policies([[:space:]]|$)' <<<"$help"; then
    rish_fw_cmd --list-all-policies >"${work}/policies" || return 1
    rish_fw_object_snapshot policies "${work}/policies" >/dev/null || return 1
  fi
  rish_fw_server_lock_icmptypes >"${work}/required-icmp" || return 1
  : >"${work}/own-rules" || return 1
  [[ -z "$own_peer" ]] || rish_fw_server_lock_owned_rules >"${work}/own-rules" || return 1
  python3 - "$RISH_FW_ZONE" "$work" <<'PY'
import os, re, shlex, sys
zone, work = sys.argv[1:]
def read(name):
    with open(os.path.join(work, name), encoding='utf-8') as handle:
        return handle.read()
def objects(text):
    result, item = {}, None
    for line in text.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            match = re.fullmatch(r'([A-Za-z0-9_.-]+)(?: \(([^()]*)\))?', line)
            if not match:
                raise ValueError('неизвестный заголовок зоны/политики')
            name = match[1]
            item = {'rules': [], 'attributes': set((match[2] or '').split(', ')) - {''}}
            result[name] = item
        elif item is None:
            raise ValueError('строка без зоны/политики')
        elif line.strip().startswith('rule '):
            item['rules'].append(shlex.split(line.strip()))
        elif line.strip() == 'rich rules:':
            continue
        elif ':' in line:
            key, value = line.strip().split(':', 1)
            if key in item:
                raise ValueError('повторное поле конфигурации')
            item[key] = value.strip()
        else:
            raise ValueError('неизвестное поле конфигурации')
    return result
try:
    required = set(read('required-icmp').split())
    own_rules = {tuple(sorted(shlex.split(line))) for line in read('own-rules').splitlines()}
    if not required <= set(read('icmptypes').split()):
        raise ValueError('firewalld не поддерживает необходимые служебные типы ICMPv6')
    zones = objects(read('zones'))
    if zone not in zones:
        raise ValueError('рабочая зона не найдена')
    for name, item in zones.items():
        if 'forward-ports' not in item or item['forward-ports']:
            raise ValueError('не подтверждено отсутствие перенаправления портов в зоне ' + name)
        for rule in item['rules']:
            if 'forward-port' in rule:
                raise ValueError('есть rich-перенаправление портов в зоне ' + name)
            priorities = [int(t.split('=', 1)[1]) for t in rule if t.startswith('priority=')]
            if name == zone and any(p <= -32000 for p in priorities) and tuple(sorted(rule)) not in own_rules:
                raise ValueError('есть конфликтующее приоритетное правило в зоне ' + name)
    # Policies precede zones. Permit only the strict service-ICMPv6 shape of
    # the standard host policy; its name alone is not a safety guarantee.
    for name, item in objects(read('policies')).items():
        disabled = 'disabled' in item['attributes']
        disable = item.get('disable', 'no')
        if (disable not in ('yes', 'no') or disabled != (disable == 'yes') or
                disabled and 'active' in item['attributes']):
            raise ValueError('не удалось подтвердить состояние политики ' + name)
        # Since firewalld 2.4, bundled gateway templates are listed even when
        # explicitly disabled. They cannot bypass this host's zone rules.
        if disabled:
            continue
        if item.get('forward-ports') or any('forward-port' in r for r in item['rules']):
            raise ValueError('есть перенаправление портов в политике ' + name)
        egress = item.get('egress-zones', '').split()
        if not egress or not item.get('ingress-zones'):
            raise ValueError('не удалось определить направление политики ' + name)
        if 'HOST' not in egress:
            continue
        allowed_fields = {'priority', 'target', 'ingress-zones', 'egress-zones',
                          'services', 'ports', 'protocols', 'masquerade',
                          'forward-ports', 'source-ports', 'icmp-blocks', 'rules',
                          'disable', 'attributes'}
        if (set(item) - allowed_fields or item.get('target') != 'CONTINUE' or
                int(item.get('priority', '0')) >= 0 or egress != ['HOST'] or
                item['ingress-zones'].split() != ['ANY'] or
                item.get('masquerade', 'no') != 'no' or
                any(item.get(k) for k in ('services', 'ports', 'protocols', 'source-ports', 'icmp-blocks'))):
            raise ValueError('политика может обходить ограничение: ' + name)
        for rule in item['rules']:
            if (len(rule) != 5 or rule[:3] != ['rule', 'family=ipv6', 'icmp-type'] or
                    not rule[3].startswith('name=') or rule[3][5:] not in required or rule[4] != 'accept'):
                raise ValueError('нестандартное правило политики ' + name)
except (OSError, UnicodeError, ValueError) as error:
    print('Блокировка сервера недоступна: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
}

# Remove DROP first so cleanup cannot break IPv6 neighbour discovery. Absent
# timed rules still need their old callbacks cancelled before journal removal.
rish_fw_server_lock_cleanup() {
  local rules rule rc kind cancel_absent="${1:-yes}" pending_timers=0
  [[ -n "$RISH_FW_SERVER_LOCK_IP" && -n "$RISH_FW_SERVER_LOCK_ZONE" ]] || return 1
  local RISH_FW_ZONE="$RISH_FW_SERVER_LOCK_ZONE"
  rules=$(rish_fw_server_lock_owned_rules) || return 1
  for kind in drop accept; do
    while IFS= read -r rule; do
      [[ "$rule" == *" $kind" ]] || continue
      rish_fw_cmd --zone="$RISH_FW_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
      case "$rc" in
        0) rish_fw_remove_rule_checked "$rule" || return 1 ;;
        1)
          if [[ "$RISH_FW_SERVER_LOCK_EXPIRY" != 0 ]]; then
            if [[ "$cancel_absent" == yes ]]; then
              rish_fw_clear_orphan_timer "$rule" "проверки состояния блокировки сервера" || return 1
            else
              pending_timers=1
            fi
          fi ;;
        *) return 1 ;;
      esac
      rish_fw_cmd --zone="$RISH_FW_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
      [[ "$rc" == 1 ]] || return 1
    done <<<"$rules"
  done
  # An intervening external reload may leave callbacks even during rollback.
  # Preserve ownership until the next explicit cleanup cancels those handles.
  [[ "$pending_timers" == 1 ]] || rm -f -- "$RISH_FW_SERVER_LOCK_FILE"
}

rish_fw_server_lock_enable() (
  local peer="$1" seconds="$2" actual work expiry rule result remaining rc rules failed=0
  [[ "$seconds" == 0 || "$seconds" == 900 || "$seconds" == 3600 || "$seconds" == 86400 ]] || return 1
  actual=$(rish_fw_server_lock_peer) || return 1
  [[ "$actual" == "$peer" ]] || { rish_fw_error "IP не совпадает с текущим SSH-клиентом."; return 1; }
  rish_fw_active && rish_fw_lock && rish_fw_server_lock_refresh || return 1
  [[ "$RISH_FW_SERVER_LOCK_STATE" == off ]] || { rish_fw_error "Сначала снимите или проверьте существующее ограничение сервера."; return 1; }
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rules=$(rish_fw_server_lock_rules "$peer") || return 1
  # Clean expired/reloaded rules and their old timers before another attempt.
  if [[ -n "$RISH_FW_SERVER_LOCK_IP" ]]; then rish_fw_server_lock_cleanup || return 1; fi
  rish_fw_server_lock_preflight "$work" || return 1
  expiry=0; [[ "$seconds" == 0 ]] || expiry=$(($(rish_fw_now) + seconds))
  printf '%s\t%s\t%s\n' "$RISH_FW_ZONE" "$peer" "$expiry" >"${work}/journal" || return 1
  printf '%s\n' "$rules" >>"${work}/journal" || return 1
  # Reserve ownership before any firewalld mutation, including interrupted adds.
  rish_fw_atomic_file "${work}/journal" "$RISH_FW_SERVER_LOCK_FILE" || return 1
  RISH_FW_SERVER_LOCK_ZONE="$RISH_FW_ZONE"; RISH_FW_SERVER_LOCK_IP="$peer"; RISH_FW_SERVER_LOCK_EXPIRY="$expiry"
  RISH_FW_SERVER_LOCK_RULES="$rules"
  trap 'rish_fw_server_lock_cleanup no || rish_fw_error "Очистка правил режима не завершена; журнал сохранён."; exit 130' INT TERM HUP
  while IFS= read -r rule; do
    remaining=0
    if [[ "$expiry" != 0 ]]; then
      remaining=$((expiry - $(rish_fw_now)))
      ((remaining > 0)) || { failed=1; break; }
      # IPv6 support must outlive DROP, even if several D-Bus calls take time.
      [[ "$rule" != *' accept' ]] || remaining=$((remaining + 30))
    fi
    result=$(rish_fw_cmd --zone="$RISH_FW_ZONE" --add-rich-rule="$rule" --timeout="${remaining}s" 2>&1); rc=$?
    if [[ "$rc" != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then
      [[ -z "$result" ]] || printf '%s\n' "$result" >&2
      failed=1; break
    fi
  done <<<"$rules"
  if [[ "$failed" == 0 ]]; then
    rish_fw_server_lock_refresh verbose || failed=1
    [[ "$RISH_FW_SERVER_LOCK_STATE" == active ]] || failed=1
  fi
  if [[ "$failed" == 1 ]]; then
    rish_fw_server_lock_cleanup no || rish_fw_error "Откат выполнен не полностью. Откройте проверку состояния блокировки сервера; журнал сохранён."
    rish_fw_error "Блокировка сервера не включена полностью."
    return 1
  fi
  trap - INT TERM HUP
  rish_fw_server_lock_summary
)

rish_fw_server_lock_disable() (
  rish_fw_lock && rish_fw_server_lock_refresh || {
    rish_fw_error "Не удалось достоверно прочитать состояние режима. Правила не изменены."; return 1;
  }
  [[ -n "$RISH_FW_SERVER_LOCK_IP" ]] || { rish_fw_error "Учтённая блокировка сервера не найдена."; return 1; }
  rish_fw_server_lock_cleanup || { rish_fw_error "Не все правила режима сняты; журнал сохранён для повторной попытки."; return 1; }
  printf 'Блокировка сервера %sснята%s.\n' "$RISH_FW_GREEN" "$RISH_FW_RESET"
  printf 'Обычные правила firewall сохранены.\n'
)

rish_fw_server_lock_add_timed() {
  local rule="$1" expiry="$2" remaining=0 output rc
  if [[ "$expiry" != 0 ]]; then
    remaining=$((expiry - $(rish_fw_now)))
    ((remaining > 0)) || { rish_fw_error "Срок ограничения сервера уже истёк."; return 1; }
    [[ "$rule" != *' accept' ]] || remaining=$((remaining + 30))
  fi
  output=$(rish_fw_cmd --zone="$RISH_FW_ZONE" --add-rich-rule="$rule" --timeout="${remaining}s" 2>&1); rc=$?
  if [[ "$rc" != 0 || "$output" == *ALREADY_ENABLED* || "$output" == *NOT_ENABLED* ]]; then
    [[ -z "$output" ]] || printf '%s\n' "$output" >&2
    return 1
  fi
}

# Called by the whitelist transaction under the same flock. Keep the absolute
# deadline and publish the union first so interrupted updates remain removable.
rish_fw_server_lock_whitelist_apply() (
  local work peer expiry old_rules new_rules union rule rc failed=0 rollback_failed=0
  local -a attempted_add=() attempted_remove=()
  rish_fw_lock && rish_fw_server_lock_refresh || return 1
  [[ "$RISH_FW_SERVER_LOCK_STATE" != off ]] || return 0
  [[ "$RISH_FW_SERVER_LOCK_STATE" == active ]] || {
    rish_fw_error "Сначала проверьте или снимите неполную блокировку сервера."; return 1;
  }
  local RISH_FW_ZONE="$RISH_FW_SERVER_LOCK_ZONE"
  peer="$RISH_FW_SERVER_LOCK_IP"; expiry="$RISH_FW_SERVER_LOCK_EXPIRY"
  old_rules=$(rish_fw_server_lock_owned_rules) || return 1
  new_rules=$(rish_fw_server_lock_rules "$peer") || return 1
  [[ "$old_rules" != "$new_rules" ]] || return 0
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  cp -- "$RISH_FW_SERVER_LOCK_FILE" "$work/original" || return 1
  rish_fw_server_lock_preflight "$work" "$peer" || return 1
  printf '%s\n' "$old_rules" | LC_ALL=C sort -u >"$work/old" || return 1
  printf '%s\n' "$new_rules" | LC_ALL=C sort -u >"$work/new" || return 1
  LC_ALL=C comm -13 "$work/old" "$work/new" >"$work/add" || return 1
  LC_ALL=C comm -23 "$work/old" "$work/new" >"$work/remove" || return 1
  union=$(cat -- "$work/old" "$work/new" | LC_ALL=C sort -u) || return 1
  printf '%s\t%s\t%s\n%s\n' "$RISH_FW_ZONE" "$peer" "$expiry" "$union" >"$work/union" || return 1
  printf '%s\t%s\t%s\n%s\n' "$RISH_FW_ZONE" "$peer" "$expiry" "$new_rules" >"$work/journal" || return 1
  rish_fw_atomic_file "$work/union" "$RISH_FW_SERVER_LOCK_FILE" || return 1
  RISH_FW_SERVER_LOCK_RULES="$union"
  # Add the new DROP coverage before removing old rules, avoiding an interval
  # in which unrelated addresses escape the server restriction.
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    attempted_add+=("$rule")
    if ! rish_fw_server_lock_add_timed "$rule" "$expiry"; then failed=1; break; fi
  done <"$work/add"
  if [[ "$failed" == 0 ]]; then
    while IFS= read -r rule; do
      [[ -n "$rule" ]] || continue
      attempted_remove+=("$rule")
      if ! rish_fw_remove_rule_checked "$rule"; then failed=1; break; fi
    done <"$work/remove"
  fi
  if [[ "$failed" == 0 ]]; then
    if ! rish_fw_atomic_file "$work/journal" "$RISH_FW_SERVER_LOCK_FILE" ||
        ! rish_fw_server_lock_refresh verbose || [[ "$RISH_FW_SERVER_LOCK_STATE" != active ]]; then
      failed=1
    fi
  fi
  [[ "$failed" != 0 ]] || return 0
  rish_fw_atomic_file "$work/union" "$RISH_FW_SERVER_LOCK_FILE" || rollback_failed=1
  RISH_FW_SERVER_LOCK_RULES="$union"
  if [[ "$expiry" != 0 && "$expiry" -le "$(rish_fw_now)" ]]; then
    rish_fw_server_lock_cleanup || rish_fw_error "Очистка истёкшего ограничения не завершена; журнал сохранён."
    rish_fw_error "Ограничение сервера истекло во время изменения белого списка."
    return 1
  fi
  for rule in "${attempted_add[@]}"; do
    rish_fw_cmd --zone="$RISH_FW_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) rish_fw_remove_rule_checked "$rule" || rollback_failed=1 ;;
      1) [[ "$expiry" == 0 ]] || rish_fw_clear_orphan_timer "$rule" "блокировки сервера" || rollback_failed=1 ;;
      *) rollback_failed=1 ;;
    esac
  done
  for rule in "${attempted_remove[@]}"; do
    rish_fw_cmd --zone="$RISH_FW_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) ;;
      1)
        if [[ "$expiry" != 0 ]] && ! rish_fw_clear_orphan_timer "$rule" "блокировки сервера"; then
          rollback_failed=1; continue
        fi
        rish_fw_server_lock_add_timed "$rule" "$expiry" || rollback_failed=1 ;;
      *) rollback_failed=1 ;;
    esac
  done
  # Verify both restored rules and absence of newly introduced rules before
  # restoring the original journal. Keep the union if recovery is uncertain.
  while IFS= read -r rule; do
    rish_fw_cmd --zone="$RISH_FW_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1 || rollback_failed=1
  done <"$work/old"
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    rish_fw_cmd --zone="$RISH_FW_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
    [[ "$rc" == 1 ]] || rollback_failed=1
  done <"$work/add"
  if [[ "$rollback_failed" == 0 ]]; then
    rish_fw_atomic_file "$work/original" "$RISH_FW_SERVER_LOCK_FILE" || rollback_failed=1
  fi
  if [[ "$rollback_failed" != 0 ]]; then
    rish_fw_error "Откат исключений блокировки сервера не подтверждён; журнал сохранён для очистки."
  fi
  rish_fw_error "Исключения блокировки сервера не изменены полностью. Белый список не применён."
  return 1
)

# A long explanation/confirmation flow can scroll an early error off screen.
# Collect both streams and show the complete operation result on a fresh screen.
rish_fw_server_lock_run() {
  local operation="$1" output rc
  shift
  case "$operation" in enable|disable) ;; *) return 2 ;; esac
  printf '\nВыполняется операция с блокировкой сервера…\n'
  output=$("rish_fw_server_lock_${operation}" "$@" 2>&1); rc=$?
  clear
  printf 'Результат операции с блокировкой сервера\n\n'
  if [[ "$rc" != 0 ]]; then
    if [[ "$operation" == enable ]]; then
      rish_fw_error "Включение блокировки сервера не завершено."
    else
      rish_fw_error "Снятие блокировки сервера не завершено."
    fi
    printf '\nПричина и результаты проверки:\n'
  fi
  [[ -z "$output" ]] || printf '%s\n' "$output"
  return "$rc"
}

rish_fw_server_lock_menu() {
  local expected="${1:-}" peer choice=0 seconds label
  rish_fw_server_lock_refresh || true
  printf '\n'
  if [[ -n "$expected" && "$expected" != "$RISH_FW_SERVER_LOCK_STATE" ]]; then
    printf 'Состояние блокировки сервера изменилось. Меню будет обновлено.\n'
    rish_fw_server_lock_summary
    return 0
  fi
  case "$RISH_FW_SERVER_LOCK_STATE" in
    active)
      rish_fw_server_lock_summary
      printf '\nБудут удалены только правила этого режима.\nОбычные правила firewall продолжат действовать.\n'
      rish_fw_confirm "Снять блокировку сервера?" || return 0
      rish_fw_server_lock_run disable ;;
    off)
      peer=$(rish_fw_server_lock_peer) || return 1
      printf 'Будут заблокированы новые входящие подключения всех,\nкроме текущего SSH-IP и адресов белого списка.\n'
      printf 'Остальные пользователи потеряют доступ к сайтам и другим службам сервера.\n'
      printf 'Установленные соединения, ответы на исходящие запросы\nи необходимый служебный трафик IPv6 сохраняются.\n'
      printf 'Для исключений доступны порты, разрешённые настройками firewalld.\n\n'
      rish_fw_field "Разрешённый IP текущего SSH" "$peer"
      rish_fw_field "Рабочая зона" "$RISH_FW_ZONE"
      printf '\nВыберите срок ограничения:\n'
      vertical_menu current 2 0 38 default=4 "15 минут" "1 час" "24 часа" "До ручного снятия" "Отмена" || choice=$?
      case "$choice" in
        0) seconds=900; label="15 минут" ;;
        1) seconds=3600; label="1 час" ;;
        2) seconds=86400; label="24 часа" ;;
        3) seconds=0; label="до ручного снятия" ;;
        *) return 0 ;;
      esac
      printf '\n'; rish_fw_field "Срок" "$label" "$RISH_FW_YELLOW"
      printf 'Перезагрузка сервера или reload firewalld также %sснимает ограничение%s.\n' "$RISH_FW_YELLOW" "$RISH_FW_RESET"
      printf 'Для досрочного снятия используйте пункт «Снять блокировку сервера».\n'
      rish_fw_confirm "Включить блокировку сервера с исключениями SSH-IP и белого списка?" || return 0
      rish_fw_server_lock_run enable "$peer" "$seconds" ;;
    *)
      rish_fw_server_lock_summary
      printf '\nПолная блокировка сервера не подтверждена.\n'
      if [[ -n "$RISH_FW_SERVER_LOCK_IP" && "$RISH_FW_SERVER_LOCK_STATE" == partial ]]; then
        printf 'Можно очистить собственные правила режима и затем включить его заново.\n'
        rish_fw_confirm "Очистить оставшиеся правила режима?" || return 0
        rish_fw_server_lock_run disable
      else
        printf 'Проверьте доступность firewalld и журнал режима:\n'
        rish_fw_field "Журнал" "$RISH_FW_SERVER_LOCK_FILE"
        return 1
      fi ;;
  esac
}

rish_fw_secure_path() {
  local path="$1" parent uid mode attributes
  [[ "$path" == /* ]] || return 1
  parent="$path"
  while [[ "$parent" != / ]]; do
    if [[ "${RISH_FIREWALL_TEST_MODE:-0}" == 1 && "$parent" == /tmp ]]; then
      parent=/
      continue
    fi
    [[ ! -L "$parent" ]] || { rish_fw_error "Символическая ссылка недопустима: ${parent}"; return 1; }
    if [[ -e "$parent" ]]; then
      attributes=$(stat -c '%u %a' -- "$parent") || return 1
      read -r uid mode <<<"$attributes" || return 1
      [[ "$uid" == 0 || "${RISH_FIREWALL_TEST_MODE:-0}" == 1 && "$uid" == "$EUID" ]] || { rish_fw_error "Владелец ${parent} должен быть root."; return 1; }
      [[ "$parent" == "$path" || -d "$parent" ]] || { rish_fw_error "Родительский путь не является каталогом: ${parent}"; return 1; }
      # /tmp is allowed only as a test-harness ancestor, never as a production state directory.
      if [[ "${RISH_FIREWALL_TEST_MODE:-0}" != 1 || "$parent" != /tmp && "$parent" != /private/tmp ]]; then
        (( (8#$mode & 18) == 0 )) || { rish_fw_error "Каталог/файл доступен группе или всем на запись: ${parent}"; return 1; }
      fi
    fi
    parent="${parent%/*}"
    [[ -n "$parent" ]] || parent=/
  done
}

rish_fw_lock() {
  if [[ "$RISH_FW_LOCK_HELD" == 1 ]]; then
    flock -n 9 || { rish_fw_error "Унаследованная блокировка недоступна."; return 1; }
    return 0
  fi
  rish_fw_paths || return 1
  rish_fw_secure_path "$RISH_FW_STATE_DIR" || return 1
  install -d -m 700 -- "$RISH_FW_STATE_DIR" || return 1
  rish_fw_secure_path "$RISH_FW_LOCK_FILE" || return 1
  [[ ! -e "$RISH_FW_LOCK_FILE" || -f "$RISH_FW_LOCK_FILE" ]] || return 1
  exec 9>"$RISH_FW_LOCK_FILE" || return 1
  chmod 600 -- "$RISH_FW_LOCK_FILE" || return 1
  flock -n 9 || { rish_fw_error "Другая операция RISH уже меняет firewall."; return 1; }
  RISH_FW_LOCK_HELD=1
}

rish_fw_atomic_file() {
  local source_file="$1" target="$2" directory temporary attributes
  directory="${target%/*}"
  rish_fw_secure_path "$target" || return 1
  # The whitelist lives directly in /etc/firewalld; preserve that system
  # directory's existing permissions while retaining private list directories.
  if [[ "$target" != "${RISH_FW_WHITELIST:-}" || ! -d "$directory" ]]; then
    install -d -m 700 -- "$directory" || return 1
  fi
  [[ ! -e "$target" || -f "$target" ]] || return 1
  local owner=0
  [[ "${RISH_FIREWALL_TEST_MODE:-0}" != 1 ]] || owner="$EUID"
  if [[ -f "$target" ]] && cmp -s -- "$source_file" "$target"; then
    attributes=$(stat -c '%u %a' -- "$target") || return 1
    [[ "$attributes" != "$owner 600" ]] || return 0
  fi
  temporary=$(mktemp "${directory}/.rish-firewall.XXXXXX") || return 1
  if cat -- "$source_file" >"$temporary" && chmod 600 -- "$temporary" && chown "$owner" -- "$temporary" && mv -f -- "$temporary" "$target"; then
    return 0
  fi
  rm -f -- "$temporary"
  return 1
}

rish_fw_read_ledger() {
  rish_fw_paths || return 1
  [[ -e "$RISH_FW_LEDGER" ]] || return 0
  rish_fw_secure_path "$RISH_FW_LEDGER" || return 1
  [[ -f "$RISH_FW_LEDGER" ]] || return 1
  python3 - "$RISH_FW_LEDGER" <<'PY'
import ipaddress, re, sys
try:
    rows = []
    with open(sys.argv[1], encoding='utf-8') as handle:
        for line in handle:
            row = line.rstrip('\n').split('\t')
            if len(row) != 4:
                raise ValueError()
            net, zone, expiry, rule = row
            n = ipaddress.ip_network(net, strict=True)
            expected = 'rule priority="-110" family="ipv%d" source address="%s" drop' % (n.version, n)
            if not re.match(r'^[A-Za-z0-9_.-]+$', zone) or not expiry.isdigit() or rule != expected:
                raise ValueError()
            rows.append(row)
    for row in rows:
        print('\t'.join(row))
except (ValueError, OSError, UnicodeError):
    print('Некорректный журнал временных правил; изменения остановлены.', file=sys.stderr)
    sys.exit(1)
PY
}

# 0: present, 1: confirmed absent, 2: could not read. Older clients may use a
# different missing-set code; only their successful name listing proves absence.
rish_fw_ipset_info() {
  local family="$1" mode="$2" set_name info state names name
  local -a flag=() listed=()
  [[ "$mode" == runtime || "$mode" == permanent ]] || return 2
  set_name=$(rish_fw_set_name "$family") || return 2
  [[ "$mode" != permanent ]] || flag=(--permanent)
  info=$(rish_fw_cmd "${flag[@]}" --info-ipset="$set_name" 2>&1); state=$?
  if [[ "$state" == 0 ]]; then printf '%s\n' "$info"; return 0; fi
  [[ "$state" != 135 ]] || return 1
  if names=$(rish_fw_cmd "${flag[@]}" --get-ipsets); then
    read -r -a listed <<<"$names"
    for name in "${listed[@]}"; do
      [[ "$name" != "$set_name" ]] || { printf '%s\n' "$info" >&2; return 2; }
    done
    return 1
  fi
  [[ -z "$info" ]] || printf '%s\n' "$info" >&2
  return 2
}

rish_fw_ipset_exists() { rish_fw_ipset_info "$1" "$2" >/dev/null; }

rish_fw_ipset_validate() {
  local family="$1" info="$2" expected set_name line type="" options="" option entries_seen=0
  local -a values=()
  set_name=$(rish_fw_set_name "$family") || return 1
  expected=inet
  [[ "$family" == 6 ]] && expected=inet6
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*type:[[:space:]]*(.*)$ ]]; then type="${BASH_REMATCH[1]}";
    elif [[ "$line" =~ ^[[:space:]]*options:[[:space:]]*(.*)$ ]]; then options="${BASH_REMATCH[1]}";
    elif [[ "$line" =~ ^[[:space:]]*entries: ]]; then entries_seen=$((entries_seen + 1)); fi
  done <<<"$info"
  [[ "$type" == hash:net && "$entries_seen" == 1 ]] || {
    rish_fw_error "Список адресов ${set_name}: нужен тип hash:net."; return 1;
  }
  if [[ "$options" == *family=* ]]; then
    [[ " $options " == *" family=$expected "* ]] || { rish_fw_error "Несовместимое семейство ${set_name}."; return 1; }
  elif [[ "$family" == 6 ]]; then
    rish_fw_error "У списка IPv6 не найден параметр family=inet6."; return 1
  fi
  read -r -a values <<<"$options"
  for option in "${values[@]}"; do
    if [[ "$option" == timeout=* && "$option" != timeout=0 ]]; then
      rish_fw_error "Списки с автоматическим сроком хранения адресов (timeout) не поддерживаются."
      return 1
    fi
  done
}

rish_fw_ipset_compatible() {
  local info
  info=$(rish_fw_ipset_info "$1" "$2") || return 1
  rish_fw_ipset_validate "$1" "$info"
}

rish_fw_entries_from_info() {
  local family="$1" info="$2" line
  local -a entries=()
  rish_fw_ipset_validate "$family" "$info" || return 1
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*entries:[[:space:]]*(.*)$ ]]; then
      read -r -a entries <<<"${BASH_REMATCH[1]}"
      ((${#entries[@]} == 0)) || printf '%s\n' "${entries[@]}"
      return 0
    fi
  done <<<"$info"
  return 1
}

rish_fw_current_entries() {
  local family="$1" mode="$2" state info
  info=$(rish_fw_ipset_info "$family" "$mode"); state=$?
  [[ "$state" != 2 ]] || return 1
  [[ "$state" == 0 ]] || return 0
  rish_fw_entries_from_info "$family" "$info"
}

rish_fw_entry_map() {
  python3 - "$1" <<'PY'
import ipaddress, sys
seen = set()
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        for line in handle:
            value = line.strip()
            if not value:
                continue
            canonical = str(ipaddress.ip_network(value, strict=False))
            if canonical in seen:
                raise ValueError('duplicate canonical entry')
            seen.add(canonical)
            print(canonical + '\t' + value)
except (OSError, ValueError):
    print('Не удалось сопоставить исходные адреса списка.', file=sys.stderr)
    sys.exit(1)
PY
}

# Include definitions behind zone/policy service names, including rich rules
# and recursive service includes. The same name can differ between configurations.
rish_fw_service_snapshot() {
  local source_file="$1" mode="$2" names name info includes index=0
  local -a flag=() pending=()
  local -A seen=()
  [[ "$mode" != permanent ]] || flag=(--permanent)
  names=$(python3 - "$source_file" <<'PY'
import re, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    text = handle.read()
names = set()
for line in text.splitlines():
    match = re.match(r'^\s*services:\s*(.*)$', line)
    if match:
        names.update(match.group(1).split())
names.update(re.findall(r'\bservice\s+name="([A-Za-z0-9_.-]+)"', text))
if any(not re.match(r'^[A-Za-z0-9_.-]+$', name) for name in names):
    sys.exit(1)
print(' '.join(sorted(names)))
PY
  ) || return 1
  read -r -a pending <<<"$names"
  while ((index < ${#pending[@]})); do
    name="${pending[$index]}"
    index=$((index + 1))
    [[ -z "${seen[$name]:-}" ]] || continue
    seen["$name"]=1
    info=$(rish_fw_cmd "${flag[@]}" --info-service="$name") || return 1
    printf '\nSERVICE %s\n%s\n' "$name" "$info"
    includes=$(sed -n 's/^[[:space:]]*includes:[[:space:]]*//p' <<<"$info")
    for name in $includes; do
      [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
      pending+=("$name")
    done
  done
}

# Normalize header metadata and unordered rich-rule enumeration, never values.
# Unknown headers must stop reload even when both configurations contain them.
rish_fw_object_snapshot() {
  python3 - "$1" "$2" <<'PY'
import re, sys
kind, path = sys.argv[1:]
allowed = {'zones': {'default', 'active'}, 'policies': {'active', 'disabled'}}
try:
    if kind not in allowed:
        raise ValueError('неизвестный тип объектов')
    with open(path, encoding='utf-8') as handle:
        lines = handle.readlines()
    result, seen = [], set()
    for line in lines:
        line = line.rstrip('\n')
        if line and not line[0].isspace():
            match = re.fullmatch(r'([A-Za-z0-9_.-]+)(?: \(([^()]*)\))?', line)
            if not match:
                raise ValueError('неизвестный формат заголовка')
            name, attributes = match.groups()
            if attributes is not None:
                attributes = attributes.split(', ')
                if len(set(attributes)) != len(attributes) or any(a not in allowed[kind] for a in attributes):
                    raise ValueError('неизвестные пометки заголовка')
            if name in seen:
                raise ValueError('повторный заголовок')
            seen.add(name)
            line = name
        result.append(line.rstrip())
    if kind == 'zones' and not seen:
        raise ValueError('список зон пуст')
    # firewalld may enumerate the same rich rules in different orders in runtime
    # and permanent. Evaluation uses rule priority, not this display order.
    normalized, pending, in_rules = [], [], False
    for line in result:
        if in_rules and line.strip().startswith('rule '):
            pending.append(line)
            continue
        if pending:
            normalized.extend(sorted(pending))
            pending = []
        normalized.append(line)
        in_rules = line.strip() == 'rich rules:'
    normalized.extend(sorted(pending))
    for line in normalized:
        print(line)
except (OSError, UnicodeError, ValueError) as exc:
    print('Не удалось прочитать снимок %s: %s.' % (kind, exc), file=sys.stderr)
    sys.exit(1)
PY
}

# Entry order and equivalent plain IP/CIDR spelling do not change set coverage.
# Compound native entries remain intact; option values and metadata stay exact.
rish_fw_ipset_snapshot() {
  python3 - "$1" <<'PY'
import ipaddress, re, sys
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        lines = handle.readlines()
    result, seen = [], set()
    for line in lines:
        line = line.rstrip('\n')
        match = re.match(r'^(\s*)(options|entries):\s*(.*)$', line)
        if match:
            indent, field, value = match.groups()
            if field in seen:
                raise ValueError('повторное поле набора')
            seen.add(field)
            values = value.split()
            if field == 'entries':
                canonical = []
                for entry in values:
                    try:
                        entry = str(ipaddress.ip_network(entry, strict=False))
                    except ValueError:
                        pass
                    canonical.append(entry)
                values = canonical
            line = indent + field + ':' + (' ' + ' '.join(sorted(values)) if values else '')
        result.append(line.rstrip())
    if seen != {'options', 'entries'}:
        raise ValueError('неполный снимок набора')
    for line in result:
        print(line)
except (OSError, UnicodeError, ValueError) as error:
    print('Не удалось прочитать снимок набора адресов: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
}

rish_fw_reload_preview() {
  local work runtime permanent name mode output now net zone expiry rule
  rish_fw_server_lock_refresh || { rish_fw_error "Не удалось проверить блокировку сервера. Применение сохранённых правил отменено."; return 1; }
  [[ "$RISH_FW_SERVER_LOCK_STATE" == off ]] || {
    rish_fw_error "Сначала снимите блокировку сервера или очистите правила режима через меню."; return 1;
  }
  work=$(mktemp -d) || return 1
  runtime="${work}/runtime"; permanent="${work}/permanent"
  now=$(rish_fw_now)
  output=$(rish_fw_read_ledger) || { rm -rf -- "$work"; return 1; }
  while IFS=$'\t' read -r net zone expiry rule; do
    [[ -n "$net" ]] || continue
    if ((expiry > now)); then
      rish_fw_error "Нельзя применить сохранённые правила: ещё не закончился учтённый срок временных блокировок. Дождитесь его окончания или снимите действующие блокировки через меню."
      rm -rf -- "$work"; return 1
    fi
  done <<<"$output"
  for mode in runtime permanent; do
    local -a flag=()
    [[ "$mode" == permanent ]] && flag=(--permanent)
    {
      rish_fw_cmd "${flag[@]}" --list-all-zones >"${work}/zones-${mode}" || exit 1
      rish_fw_object_snapshot zones "${work}/zones-${mode}" || exit 1
      printf '\nIPSETS\n'
      output=$(rish_fw_cmd "${flag[@]}" --get-ipsets) || exit 1
      for name in $(tr ' ' '\n' <<<"$output" | LC_ALL=C sort); do
        rish_fw_cmd "${flag[@]}" --info-ipset="$name" >"${work}/ipset-info" || exit 1
        rish_fw_ipset_snapshot "${work}/ipset-info" || exit 1
      done
      printf '\nDIRECT RULES\n'
      rish_fw_cmd "${flag[@]}" --direct --get-all-rules || exit 1
      rish_fw_cmd "${flag[@]}" --direct --get-all-chains || exit 1
      rish_fw_cmd "${flag[@]}" --direct --get-all-passthroughs || exit 1
    } | sed -e 's/[[:space:]]*$//' >"${work}/${mode}"
    if [[ "${PIPESTATUS[*]}" != '0 0' ]]; then
      rm -rf -- "$work"; rish_fw_error "Не удалось сравнить действующие и сохранённые настройки. Применение отменено."; return 1
    fi
  done
  local default_zone permanent_default_zone
  default_zone=$(rish_fw_cmd --get-default-zone) || { rm -rf -- "$work"; return 1; }
  if [[ ! "$default_zone" =~ ^[A-Za-z0-9_.-]+$ ]] ||
      ! command -v firewall-offline-cmd >/dev/null 2>&1 ||
      ! permanent_default_zone=$(LC_ALL=C command firewall-offline-cmd --get-default-zone) ||
      [[ ! "$permanent_default_zone" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    rm -rf -- "$work"; rish_fw_error "Не удалось проверить сохранённую зону по умолчанию. Применение отменено."; return 1
  fi
  if [[ "$default_zone" != "$permanent_default_zone" ]]; then
    rm -rf -- "$work"
    rish_fw_error "Зона по умолчанию различается: сейчас ${default_zone}, сохранена ${permanent_default_zone}. Применение отменено."
    return 1
  fi
  # NetworkManager commonly binds an interface only at runtime in the default
  # zone. Reload safely falls back to that same default zone. Do not exempt any
  # explicit binding to another zone, or an interface bound anywhere permanently.
  if ! python3 - "$runtime" "$permanent" "$default_zone" <<'PY'
import re, sys
runtime_path, permanent_path, default = sys.argv[1:]
with open(runtime_path, encoding='utf-8') as handle:
    runtime = handle.readlines()
with open(permanent_path, encoding='utf-8') as handle:
    permanent = handle.readlines()
def bindings(lines):
    zone = None
    result = {}
    for number, line in enumerate(lines):
        if line.strip() == 'IPSETS':
            break
        if line and not line[0].isspace():
            zone = line.strip()
        match = re.match(r'^(\s*)interfaces:\s*(.*?)\s*$', line)
        if match and zone is not None:
            result[zone] = (number, match.group(1), match.group(2).split())
    return result
r, p = bindings(runtime), bindings(permanent)
all_permanent = set(i for _, _, items in p.values() for i in items)
if default in r and default in p:
    number, indent, interfaces = r[default]
    expected = p[default][2]
    retained = [i for i in interfaces if i in expected or i in all_permanent]
    if retained != interfaces:
        runtime[number] = indent + 'interfaces:' + (' ' + ' '.join(retained) if retained else '') + '\n'
with open(runtime_path, 'w', encoding='utf-8') as handle:
    handle.writelines(runtime)
PY
  then
    rm -rf -- "$work"; return 1
  fi
  # Old EL8 clients have no policy option. Probe the CLI without connecting to
  # D-Bus; failed reads on clients that support policies must never permit reload.
  local runtime_policies permanent_policies help_output
  if ! help_output=$(LC_ALL=C rish_fw_cmd --help 2>&1) ||
      ! grep -Eq '^[[:space:]]*--state([[:space:]]|$)' <<<"$help_output" ||
      ! grep -Eq '^[[:space:]]*--list-all-zones([[:space:]]|$)' <<<"$help_output"; then
    rm -rf -- "$work"; rish_fw_error "Не удалось определить возможности firewall-cmd. Применение отменено."; return 1
  fi
  if grep -Eq '^[[:space:]]*--list-all-policies([[:space:]]|$)' <<<"$help_output"; then
    if ! runtime_policies=$(rish_fw_cmd --list-all-policies) ||
        ! permanent_policies=$(rish_fw_cmd --permanent --list-all-policies); then
      rm -rf -- "$work"; rish_fw_error "Не удалось прочитать политики firewalld. Применение отменено."; return 1
    fi
    printf '%s\n' "$runtime_policies" >"${work}/policies-runtime" || { rm -rf -- "$work"; return 1; }
    printf '%s\n' "$permanent_policies" >"${work}/policies-permanent" || { rm -rf -- "$work"; return 1; }
    for mode in runtime permanent; do
      printf '\nPOLICIES\n' >>"${work}/${mode}" || { rm -rf -- "$work"; return 1; }
      if ! rish_fw_object_snapshot policies "${work}/policies-${mode}" >>"${work}/${mode}"; then
        rm -rf -- "$work"; rish_fw_error "Не удалось сравнить действующие и сохранённые политики. Применение отменено."; return 1
      fi
    done
  fi
  for mode in runtime permanent; do
    if ! rish_fw_service_snapshot "${work}/${mode}" "$mode" >"${work}/services-${mode}"; then
      rm -rf -- "$work"; rish_fw_error "Не удалось сравнить действующие и сохранённые настройки служб. Применение отменено."; return 1
    fi
    cat "${work}/services-${mode}" >>"${work}/${mode}" || { rm -rf -- "$work"; return 1; }
  done
  if ! cmp -s -- "$runtime" "$permanent"; then
    printf '\nДействующие настройки %sотличаются%s от сохранённых.\n' "$RISH_FW_YELLOW" "$RISH_FW_RESET"
    printf 'Применение отменено, чтобы не потерять временные изменения.\nТехнические подробности (- сохранено, + действует):\n'
    diff -u -- "$permanent" "$runtime" || true
    rm -rf -- "$work"
    rish_fw_error "Сначала согласуйте различия действующих и сохранённых настроек."
    return 1
  fi
  rm -rf -- "$work"
  return 0
}

rish_fw_ensure_ipsets() {
  local family state runtime_state set_name expected permanent_info runtime_info failed=0
  local -a missing=() created=()
  for family in "$@"; do
    set_name=$(rish_fw_set_name "$family") || return 1
    permanent_info=$(rish_fw_ipset_info "$family" permanent); state=$?
    runtime_info=$(rish_fw_ipset_info "$family" runtime); runtime_state=$?
    [[ "$state" != 2 && "$runtime_state" != 2 ]] || return 1
    if [[ "$state" == 0 && "$runtime_state" == 0 ]]; then
      rish_fw_ipset_validate "$family" "$permanent_info" || return 1
      rish_fw_ipset_validate "$family" "$runtime_info" || return 1
    elif [[ "$state" != "$runtime_state" ]]; then
      rish_fw_error "Список адресов ${set_name} существует только в действующих или только в сохранённых настройках. Сначала требуется сверка."
      return 1
    else
      missing+=("$family")
    fi
  done
  ((${#missing[@]} > 0)) || return 0
  rish_fw_reload_preview || return 1
  printf '\nПодготовка постоянных блокировок\n\n'
  printf 'Нужно создать списки адресов и применить\nсохранённые правила %sfirewalld%s.\n' "$RISH_FW_GREEN" "$RISH_FW_RESET"
  rish_fw_confirm "Подготовить и продолжить?" || return 1
  # The confirmation can stay open while another administrator changes config.
  rish_fw_reload_preview || return 1
  for family in "${missing[@]}"; do
    set_name=$(rish_fw_set_name "$family")
    expected=inet
    [[ "$family" != 6 ]] || expected=inet6
    if rish_fw_quiet --permanent --new-ipset="$set_name" --type=hash:net --option="family=${expected}"; then
      created+=("$set_name")
    else
      failed=1; break
    fi
  done
  if [[ "$failed" == 0 ]]; then
    if ! rish_fw_quiet --reload; then failed=1; fi
  fi
  if [[ "$failed" != 0 ]]; then
    rish_fw_error "Подготовка списков адресов не завершена. Удаляю созданные сохранённые списки; проверьте состояние firewalld."
    for set_name in "${created[@]}"; do
      rish_fw_quiet --permanent --delete-ipset="$set_name" || rish_fw_error "Не удалось удалить подготовленный список ${set_name}."
    done
    return 1
  fi
  for family in "${missing[@]}"; do
    rish_fw_ipset_compatible "$family" permanent || return 1
    rish_fw_ipset_compatible "$family" runtime || return 1
  done
}

rish_fw_ensure_ipset() { rish_fw_ensure_ipsets "$1"; }

rish_fw_rollback_ops() {
  local file="$1" mode action value failed=0 i
  shift
  local -a operations=("$@")
  if [[ -n "$file" ]]; then
    mapfile -t operations <"$file" || {
      rish_fw_error "Не удалось прочитать журнал отката. Проверьте действующие и сохранённые правила вручную."
      return 1
    }
  fi
  for ((i=${#operations[@]}-1; i>=0; i--)); do
    IFS=$'\t' read -r mode action value <<<"${operations[$i]}"
    [[ -n "$mode" ]] || continue
    local -a flag=()
    [[ "$mode" == permanent ]] && flag=(--permanent)
    if [[ "$action" == add ]]; then
      rish_fw_cmd "${flag[@]}" --ipset="$RISH_FW_OPERATION_SET" --remove-entry="$value" >/dev/null || failed=1
    elif [[ "$action" == remove ]]; then
      rish_fw_cmd "${flag[@]}" --ipset="$RISH_FW_OPERATION_SET" --add-entry="$value" >/dev/null || failed=1
    elif [[ "$action" == rule ]]; then
      rish_fw_cmd "${flag[@]}" --zone="$RISH_FW_ZONE" --remove-rich-rule="$value" >/dev/null || failed=1
    fi
  done
  ((failed == 0)) || rish_fw_error "Откат выполнен не полностью. Проверьте действующие и сохранённые правила вручную."
  return "$failed"
}

# Repeated entry options use firewalld's per-entry operations, without replacing
# or flushing the runtime set. Successful chunks share the final verification;
# failed/warned chunks need immediate readback to journal partial success.
rish_fw_apply_entry_chunk() {
  local family="$1" mode="$2" action="$3" work="$7" result command_rc map_output canonical raw i
  local -n chunk_nets_ref="$4" chunk_arguments_ref="$5" journal_ref="$6"
  local -a flag=() options=()
  local -A present=()
  [[ "$mode" != permanent ]] || flag=(--permanent)
  for raw in "${chunk_arguments_ref[@]}"; do options+=("--${action}-entry=${raw}"); done
  result=$(rish_fw_cmd "${flag[@]}" --ipset="$RISH_FW_OPERATION_SET" "${options[@]}" 2>&1); command_rc=$?
  if [[ "$command_rc" == 0 && "$result" == success ]]; then
    for raw in "${chunk_arguments_ref[@]}"; do journal_ref+=("$mode"$'\t'"$action"$'\t'"$raw"); done
    return 0
  fi
  if rish_fw_current_entries "$family" "$mode" >"$work/chunk-raw" &&
      map_output=$(rish_fw_entry_map "$work/chunk-raw"); then
    while IFS=$'\t' read -r canonical raw; do [[ -z "$canonical" ]] || present["$canonical"]="$raw"; done <<<"$map_output"
    for ((i=0; i<${#chunk_nets_ref[@]}; i++)); do
      canonical="${chunk_nets_ref[$i]}"; raw="${chunk_arguments_ref[$i]}"
      if [[ "$action" == add && -n "${present[$canonical]:-}" || "$action" == remove && -z "${present[$canonical]:-}" ]]; then
        journal_ref+=("$mode"$'\t'"$action"$'\t'"$raw")
      fi
    done
  else
    # All planned additions were absent, and all planned removals were present.
    # If readback failed, restoring every planned entry is the safe inverse.
    for raw in "${chunk_arguments_ref[@]}"; do journal_ref+=("$mode"$'\t'"$action"$'\t'"$raw"); done
  fi
  [[ -z "$result" ]] || printf '%s\n' "$result" >&2
  return 1
}

# Desired file must contain only the selected address family. All mutations are
# addressed to the RISH ipset; the export file is committed only after verification.
rish_fw_permanent_apply() (
  local family="$1" desired_source="$2" normalize_mode="${3:-collapse}" undo_file="${4:-}" work current_runtime current_permanent desired additions removals gate net mode action failed=0 rollback_failed=0 query_rc result
  local -a applied_ops=() chunk_nets=() chunk_arguments=()
  [[ "$normalize_mode" == collapse || "$normalize_mode" == preserve ]] || return 2
  rish_fw_active && rish_fw_lock || return 1
  umask 077
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  desired="${work}/desired"; current_runtime="${work}/runtime"; current_permanent="${work}/permanent"
  rish_fw_normalize "$desired_source" "$work/unfiltered" "$normalize_mode" &&
    rish_fw_whitelist_filter "$work/unfiltered" "$desired" || return 1
  case "$family" in
    4) if grep -q ':' "$desired"; then rish_fw_error "Список содержит IPv6."; return 1; fi ;;
    6) if grep -qv ':' "$desired"; then rish_fw_error "Список содержит IPv4."; return 1; fi ;;
    *) return 2 ;;
  esac
  rish_fw_current_entries "$family" runtime >"${work}/raw-runtime" || return 1
  rish_fw_current_entries "$family" permanent >"${work}/raw-permanent" || return 1
  rish_fw_normalize "${work}/raw-runtime" "$current_runtime" preserve || return 1
  rish_fw_normalize "${work}/raw-permanent" "$current_permanent" preserve || return 1
  local -A runtime_entry_map=() permanent_entry_map=()
  local canonical raw map_output argument
  map_output=$(rish_fw_entry_map "${work}/raw-runtime") || return 1
  while IFS=$'\t' read -r canonical raw; do [[ -z "$canonical" ]] || runtime_entry_map["$canonical"]="$raw"; done <<<"$map_output"
  map_output=$(rish_fw_entry_map "${work}/raw-permanent") || return 1
  while IFS=$'\t' read -r canonical raw; do [[ -z "$canonical" ]] || permanent_entry_map["$canonical"]="$raw"; done <<<"$map_output"
  cmp -s -- "$current_runtime" "$current_permanent" || {
    rish_fw_error "Действующий и сохранённый списки адресов различаются. Изменения остановлены."; return 1;
  }
  if [[ ! -s "$desired" && ! -s "$current_permanent" ]]; then
    # Commit an explicit empty replacement even when no native set is needed.
    rish_fw_atomic_file "$desired" "$(rish_fw_list_path "$family")"
    return $?
  fi
  additions="${work}/add"; removals="${work}/remove"
  LC_ALL=C sort "$desired" >"${work}/desired-sort" || return 1
  LC_ALL=C sort "$current_permanent" >"${work}/current-sort" || return 1
  LC_ALL=C comm -13 "${work}/current-sort" "${work}/desired-sort" >"$additions" || return 1
  LC_ALL=C comm -23 "${work}/current-sort" "${work}/desired-sort" >"$removals" || return 1
  rish_fw_ssh_guard_file "$additions" || return 1
  rish_fw_ensure_ipset "$family" || return 1
  RISH_FW_OPERATION_SET=$(rish_fw_set_name "$family") || return 1
  gate=$(rish_fw_set_rule "$family")
  for mode in permanent runtime; do
    [[ "${RISH_FW_ATTACH_GATE:-1}" == 1 ]] || break
    local -a flag=()
    [[ "$mode" == permanent ]] && flag=(--permanent)
    rish_fw_cmd "${flag[@]}" --zone="$RISH_FW_ZONE" --query-rich-rule="$gate" >/dev/null 2>&1
    query_rc=$?
    if [[ "$query_rc" != 0 && "$query_rc" != 1 ]]; then failed=1; break; fi
    if [[ "$query_rc" == 1 ]]; then
      # Attaching a shared pre-populated set to a new zone must not lock out
      # the SSH peer through an entry that was already present before this edit.
      rish_fw_ssh_guard_file "$current_permanent" "$desired" &&
        rish_fw_whitelist_guard_file "$current_permanent" || failed=1
      [[ "$failed" == 0 ]] || break
      result=$(rish_fw_cmd "${flag[@]}" --zone="$RISH_FW_ZONE" --add-rich-rule="$gate" 2>&1)
      if [[ $? != 0 ]]; then printf '%s\n' "$result" >&2; failed=1; break; fi
      if [[ "$result" != *ALREADY_ENABLED* ]]; then applied_ops+=("$mode"$'\trule\t'"$gate"); fi
    fi
  done
  # Remove covered old subnets before adding their collapsed parent: hash:net
  # accepts overlaps, but firewalld rejects adding entries already covered by one.
  for action in remove add; do
    [[ "$failed" == 0 ]] || break
    local input_file="$removals"
    [[ "$action" == add ]] && input_file="$additions"
    for mode in permanent runtime; do
      chunk_nets=(); chunk_arguments=()
      while IFS= read -r net; do
        argument="$net"
        if [[ "$action" == remove ]]; then
          if [[ "$mode" == permanent ]]; then argument="${permanent_entry_map[$net]}"; else argument="${runtime_entry_map[$net]}"; fi
        fi
        chunk_nets+=("$net"); chunk_arguments+=("$argument")
        if ((${#chunk_nets[@]} == 100)); then
          rish_fw_apply_entry_chunk "$family" "$mode" "$action" chunk_nets chunk_arguments applied_ops "$work" || { failed=1; break; }
          chunk_nets=(); chunk_arguments=()
        fi
      done <"$input_file"
      if [[ "$failed" == 0 && ${#chunk_nets[@]} -gt 0 ]]; then
        rish_fw_apply_entry_chunk "$family" "$mode" "$action" chunk_nets chunk_arguments applied_ops "$work" || failed=1
      fi
      [[ "$failed" == 0 ]] || break
    done
  done
  if [[ "$failed" == 0 ]]; then
    for mode in permanent runtime; do
      rish_fw_current_entries "$family" "$mode" >"${work}/verify-raw" && rish_fw_normalize "${work}/verify-raw" "${work}/verify" "$normalize_mode" && cmp -s "$desired" "${work}/verify" || failed=1
    done
  fi
  if [[ "$failed" == 0 ]]; then
    # A successful first family can still need undoing if the second fails.
    # Keep applied operations in memory so a full disk cannot lose the local
    # rollback. Publish for the outer transaction before committing the list.
    if [[ -n "$undo_file" ]]; then
      if ((${#applied_ops[@]} > 0)); then
        printf '%s\n' "${applied_ops[@]}" >"$undo_file" || failed=1
      else
        : >"$undo_file" || failed=1
      fi
    fi
  fi
  if [[ "$failed" == 0 ]]; then
    rish_fw_atomic_file "$desired" "$(rish_fw_list_path "$family")" || failed=1
  fi
  if [[ "$failed" != 0 ]]; then
    rish_fw_error "Операция не завершена. Восстанавливаю прежний список адресов."
    rish_fw_rollback_ops "" "${applied_ops[@]}" || rollback_failed=1
    for mode in runtime permanent; do
      rish_fw_current_entries "$family" "$mode" >"${work}/rollback-raw" &&
        rish_fw_normalize "${work}/rollback-raw" "${work}/rollback-verify" preserve &&
        cmp -s "${work}/${mode}" "${work}/rollback-verify" || rollback_failed=1
    done
    ((rollback_failed == 0)) || rish_fw_error "Восстановление прежнего списка адресов не подтверждено. Проверьте действующие и сохранённые адреса."
    [[ -z "$undo_file" ]] || rm -f -- "$undo_file"
    return 1
  fi
  printf 'Список %s%s%s, IPv%s: изменения %sприменены и сохранены%s.\n' \
    "$RISH_FW_GREEN" "${RISH_FW_LIST_ID:-manual}" "$RISH_FW_RESET" "$family" "$RISH_FW_GREEN" "$RISH_FW_RESET"
)

rish_fw_temporary_coverage() (
  local net="$1" family work ids id rt perm
  local RISH_FW_LIST_ID
  family=$(rish_fw_family "$net")
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  : >"$work/entries"
  rish_fw_zone_snapshot "$work/zones" || return 1
  ids=$(rish_fw_list_ids) || return 1
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    RISH_FW_LIST_ID="$id"
    rish_fw_snapshot_gate "$work/zones" "$id" runtime "$RISH_FW_ZONE" "$family"; rt=$?
    rish_fw_snapshot_gate "$work/zones" "$id" permanent "$RISH_FW_ZONE" "$family"; perm=$?
    [[ "$rt" != 2 && "$perm" != 2 ]] || return 1
    if [[ "$rt" == 0 || "$perm" == 0 ]]; then
      rish_fw_current_entries "$family" permanent >>"$work/entries" || return 1
      rish_fw_current_entries "$family" runtime >>"$work/entries" || return 1
    fi
  done <<<"$ids"
  python3 - "$net" "$work/entries" <<'PY'
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1])
with open(sys.argv[2], encoding='utf-8') as handle:
    entries = [ipaddress.ip_network(line.strip(), strict=False) for line in handle if line.strip()]
entries = list(ipaddress.collapse_addresses(entries))
if any(net.overlaps(other) and net.prefixlen >= other.prefixlen for other in entries):
    print('Адрес уже входит в постоянный список RISH. Временное правило не создано.', file=sys.stderr)
    sys.exit(1)
if any(net.overlaps(other) for other in entries):
    print('CIDR частично пересекается с постоянными блокировками. Выберите непересекающийся CIDR.', file=sys.stderr)
    sys.exit(1)
PY
)

rish_fw_ledger_replace() {
  local records="$1" net="$2" expiry="$3" old_net old_zone old_expiry old_rule
  while IFS=$'\t' read -r old_net old_zone old_expiry old_rule; do
    [[ -n "$old_net" ]] || continue
    [[ "$old_net" != "$net" || "$old_zone" != "$RISH_FW_ZONE" ]] || continue
    printf '%s\t%s\t%s\t%s\n' "$old_net" "$old_zone" "$old_expiry" "$old_rule"
  done <<<"$records"
  printf '%s\t%s\t%s\t%s\n' "$net" "$RISH_FW_ZONE" "$expiry" "$(rish_fw_temp_rule "$net")"
}

rish_fw_remove_rule_checked() {
  local rule="$1" result
  result=$(rish_fw_cmd --zone="$RISH_FW_ZONE" --remove-rich-rule="$rule" 2>&1)
  if [[ $? != 0 || "$result" == *NOT_ENABLED* || "$result" == *ALREADY_ENABLED* ]]; then
    printf '%s\n' "$result" >&2
    return 1
  fi
}

# A reload can remove the rule without cancelling its old GLib callback.
# timeout=0 preserves that callback's handle; exact removal then cancels it.
# Never overwrite the handle with a fresh positive timeout before this succeeds.
rish_fw_clear_orphan_timer() {
  local rule="$1" menu_label="${2:-временных блокировок}" result query_rc
  result=$(rish_fw_cmd --zone="$RISH_FW_ZONE" --add-rich-rule="$rule" --timeout=0 2>&1)
  if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then
    printf '%s\n' "$result" >&2
    # A daemon failure can arrive after the technical untimed DROP was added.
    # ALREADY_ENABLED does not prove this invocation created the live rule.
    if [[ "$result" != *ALREADY_ENABLED* ]]; then
      rish_fw_cmd --zone="$RISH_FW_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1
      query_rc=$?
      if [[ "$query_rc" == 0 ]]; then
        rish_fw_remove_rule_checked "$rule" || rish_fw_remove_rule_checked "$rule" >/dev/null 2>&1 ||
          rish_fw_error "Техническое правило без срока осталось в зоне ${RISH_FW_ZONE}. Очистите его через меню ${menu_label}."
      elif [[ "$query_rc" != 1 ]]; then
        rish_fw_error "Не удалось проверить техническое правило в зоне ${RISH_FW_ZONE}."
      fi
    fi
    rish_fw_error "Не удалось подготовить очистку прежнего таймера; новый срок не установлен."
    return 1
  fi
  rish_fw_remove_rule_checked "$rule" && return 0
  # A failed daemon operation can leave the technical rule without a timeout.
  # Retry cleanup, but do not install a fresh timed rule in this failed attempt.
  rish_fw_remove_rule_checked "$rule" >/dev/null 2>&1 || true
  rish_fw_cmd --zone="$RISH_FW_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1
  query_rc=$?
  if [[ "$query_rc" == 0 ]]; then
    rish_fw_error "В зоне ${RISH_FW_ZONE} осталась блокировка с неизвестным сроком. Снимите её через меню ${menu_label}."
  else
    rish_fw_error "Очистка прежнего срока блокировки не подтверждена. Новый срок не задан; запись сохранена для повторной попытки."
  fi
  return 1
}

# Keep inactive ledger rows as timer ownership, separately from proven live bans.
# A reload may remove a timed rule before its GLib timer has been cancelled.
rish_fw_temporary_snapshot() (
  local target="$1" net zone expiry rule rc now
  rish_fw_read_ledger >"$target" || return 1
  : >"${target}.active" || return 1
  now=$(rish_fw_now)
  while IFS=$'\t' read -r net zone expiry rule; do
    [[ -n "$net" ]] || continue
    rish_fw_cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0)
        ((expiry > now)) || {
          rish_fw_error "Временное правило ${net} в зоне ${zone} действует с неподтверждённым сроком. Сначала снимите его через меню."
          return 1
        }
        printf '%s\t%s\t%s\t%s\n' "$net" "$zone" "$expiry" "$rule" >>"${target}.active" || return 1 ;;
      1) ;;
      *) rish_fw_error "Не удалось проверить временную блокировку ${net} в зоне ${zone}."; return 1 ;;
    esac
  done <"$target"
)

# Both files form one snapshot: the ledger and its .active companion. Native
# timeouts always use the remaining absolute deadline, including during rollback.
rish_fw_temporary_reconcile() (
  local desired="$1" work net zone expiry rule rc result remaining failed=0 rollback_failed=0 row
  local RISH_FW_ZONE="$RISH_FW_ZONE"
  local -a removed=() attempted=()
  rish_fw_active && rish_fw_lock || return 1
  [[ -f "$desired" && -f "${desired}.active" ]] || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_temporary_snapshot "$work/before" || return 1
  python3 - "$work/before" "$desired" "$work" <<'PY'
import ipaddress, os, re, sys
before, desired, work = sys.argv[1:]
def read(path):
    rows = {}
    with open(path, encoding='utf-8') as handle:
        for line in handle:
            if not line.strip():
                continue
            fields = line.rstrip('\n').split('\t')
            if len(fields) != 4:
                raise ValueError('неверная запись временного правила')
            net, zone, expiry, rule = fields
            network = ipaddress.ip_network(net, strict=True)
            expected = 'rule priority="-110" family="ipv%d" source address="%s" drop' % (network.version, network)
            if (not re.fullmatch(r'[A-Za-z0-9_.-]+', zone) or not expiry.isdigit() or rule != expected):
                raise ValueError('неверные поля временного правила')
            key = (zone, net)
            if key in rows and rows[key] != fields:
                raise ValueError('неоднозначный срок временного правила')
            rows[key] = fields
            if len(rows) > 8192:
                raise ValueError('больше 8192 временных правил')
    return rows
def write(name, rows):
    with open(os.path.join(work, name), 'w', encoding='utf-8') as handle:
        for row in rows:
            handle.write('\t'.join(row) + '\n')
try:
    old, old_active, new, new_active = (read(path) for path in (before, before + '.active', desired, desired + '.active'))
    for ledger, active in ((old, old_active), (new, new_active)):
        if any(ledger.get(key) != row or int(row[2]) <= 0 for key, row in active.items()):
            raise ValueError('активный снимок не соответствует журналу')
    write('remove', (row for key, row in old_active.items() if new_active.get(key) != row))
    write('add', (row for key, row in new_active.items() if old_active.get(key) != row))
    # Cancel an absent rule's old callback before dropping ownership or before
    # reusing its exact identity for a fresh positive timeout.
    write('cleanup', (row for key, row in old.items() if key not in old_active and
                     (key not in new or key in new_active)))
    write('desired', new.values())
    write('desired.active', new_active.values())
except (ValueError, OSError, UnicodeError) as error:
    print('Не удалось подготовить временные правила: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
  [[ $? == 0 ]] || return 1
  # A rule absent from our ledger must never be adopted or removed as ours.
  while IFS=$'\t' read -r net zone expiry rule; do
    [[ -n "$net" ]] || continue
    rish_fw_cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
    [[ "$rc" == 0 || "$rc" == 1 ]] || return 1
    if [[ "$rc" == 0 ]] && ! grep -Fqx -- "$net"$'\t'"$zone"$'\t'"$expiry"$'\t'"$rule" "$work/remove"; then
      # An extension has the same rule with a different expiry in remove.
      if ! awk -F '\t' -v z="$zone" -v r="$rule" '$2==z && $4==r { found=1 } END { exit !found }' "$work/remove"; then
        rish_fw_error "Временное правило ${net} уже существует без подходящей записи RISH."
        return 1
      fi
    fi
  done <"$work/add"
  while IFS=$'\t' read -r net zone expiry rule; do
    [[ -n "$net" ]] || continue
    RISH_FW_ZONE="$zone"
    rish_fw_clear_orphan_timer "$rule" || return 1
  done <"$work/cleanup"
  while IFS=$'\t' read -r net zone expiry rule; do
    [[ -n "$net" ]] || continue
    RISH_FW_ZONE="$zone"
    removed+=("$net"$'\t'"$zone"$'\t'"$expiry"$'\t'"$rule")
    if ! rish_fw_remove_rule_checked "$rule"; then failed=1; break; fi
  done <"$work/remove"
  if [[ "$failed" == 0 ]]; then
    while IFS=$'\t' read -r net zone expiry rule; do
      [[ -n "$net" ]] || continue
      remaining=$((expiry - $(rish_fw_now)))
      ((remaining > 0)) || continue
      attempted+=("$net"$'\t'"$zone"$'\t'"$expiry"$'\t'"$rule")
      result=$(rish_fw_cmd --zone="$zone" --add-rich-rule="$rule" --timeout="${remaining}s" 2>&1)
      if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then
        printf '%s\n' "$result" >&2; failed=1; break
      fi
    done <"$work/add"
  fi
  if [[ "$failed" == 0 ]]; then
    while IFS=$'\t' read -r net zone expiry rule; do
      [[ -n "$net" ]] || continue
      rish_fw_cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
      if [[ "$rc" != 0 && ( "$rc" != 1 || "$expiry" -gt "$(rish_fw_now)" ) ]]; then failed=1; break; fi
    done <"$work/desired.active"
  fi
  if [[ "$failed" == 0 ]]; then
    while IFS=$'\t' read -r net zone expiry rule; do
      [[ -n "$net" ]] || continue
      # The same identity may have just been re-added with an extended expiry.
      if awk -F '\t' -v z="$zone" -v r="$rule" '$2==z && $4==r { found=1 } END { exit !found }' "$work/desired.active"; then continue; fi
      rish_fw_cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
      [[ "$rc" == 1 ]] || { failed=1; break; }
    done <"$work/remove"
  fi
  if [[ "$failed" == 0 ]]; then
    rish_fw_atomic_file "$work/desired" "$RISH_FW_LEDGER" || failed=1
  fi
  [[ "$failed" != 0 ]] || return 0
  rish_fw_error "Временные правила не применены. Восстанавливаю прежние сроки."
  for row in "${attempted[@]}"; do
    IFS=$'\t' read -r net zone expiry rule <<<"$row"
    RISH_FW_ZONE="$zone"
    rish_fw_cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) rish_fw_remove_rule_checked "$rule" || rollback_failed=1 ;;
      1) rish_fw_clear_orphan_timer "$rule" || rollback_failed=1 ;;
      *) rollback_failed=1 ;;
    esac
  done
  for row in "${removed[@]}"; do
    IFS=$'\t' read -r net zone expiry rule <<<"$row"
    remaining=$((expiry - $(rish_fw_now)))
    ((remaining > 0)) || continue
    RISH_FW_ZONE="$zone"
    rish_fw_cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; rc=$?
    case "$rc" in
      0) continue ;;
      1) rish_fw_clear_orphan_timer "$rule" || { rollback_failed=1; continue; } ;;
      *) rollback_failed=1; continue ;;
    esac
    # Queries and orphan cleanup may consume the remaining lifetime.
    remaining=$((expiry - $(rish_fw_now)))
    ((remaining > 0)) || continue
    result=$(rish_fw_cmd --zone="$zone" --add-rich-rule="$rule" --timeout="${remaining}s" 2>&1)
    if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then
      printf '%s\n' "$result" >&2; rollback_failed=1
    fi
    rish_fw_cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 || rollback_failed=1
  done
  ((rollback_failed == 0)) || rish_fw_error "Откат временных блокировок не подтверждён. Проверьте правила firewalld и журнал RISH."
  return 1
)

rish_fw_temporary_restore() {
  rish_fw_temporary_reconcile "$1"
}

rish_fw_temporary_whitelist_apply() (
  local work net zone expiry rule fragment
  rish_fw_active && rish_fw_lock || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_temporary_snapshot "$work/before" || return 1
  cp -- "$work/before" "$work/desired" || return 1
  : >"$work/desired.active" || return 1
  : >"$work/replacements" || return 1
  while IFS=$'\t' read -r net zone expiry rule; do
    [[ -n "$net" ]] || continue
    printf '%s\n' "$net" >"$work/input" || return 1
    rish_fw_whitelist_filter "$work/input" "$work/filtered" || return 1
    # Mark all original live identities for replacement, including full removal.
    printf '%s\t%s\n' "$zone" "$net" >>"$work/replacements" || return 1
    while IFS= read -r fragment; do
      [[ -n "$fragment" ]] || continue
      printf '%s\t%s\t%s\t%s\n' "$fragment" "$zone" "$expiry" "$(rish_fw_temp_rule "$fragment")" >>"$work/desired.active" || return 1
    done <"$work/filtered"
  done <"$work/before.active"
  python3 - "$work/before" "$work/replacements" "$work/desired.active" "$work/desired" <<'PY'
import sys
before, replacements, active, desired = sys.argv[1:]
try:
    with open(replacements, encoding='utf-8') as handle:
        replaced = {tuple(line.rstrip('\n').split('\t')) for line in handle}
    rows = {}
    with open(before, encoding='utf-8') as handle:
        for line in handle:
            row = line.rstrip('\n').split('\t')
            if (row[1], row[0]) not in replaced:
                rows[(row[1], row[0])] = row
    live = {}
    with open(active, encoding='utf-8') as handle:
        for line in handle:
            row = line.rstrip('\n').split('\t')
            key = row[1], row[0]
            if key not in live or int(row[2]) > int(live[key][2]):
                live[key] = row
    rows.update(live)
    if len(rows) > 8192:
        raise ValueError('после исключения белого списка больше 8192 временных правил')
    for path, records in ((desired, rows), (active, live)):
        with open(path, 'w', encoding='utf-8') as handle:
            for row in records.values():
                handle.write('\t'.join(row) + '\n')
except (ValueError, OSError, UnicodeError) as error:
    print('Не удалось исключить белый список из временных правил: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
  [[ $? == 0 ]] || return 1
  rish_fw_temporary_reconcile "$work/desired"
)

rish_fw_temporary_whitelist_guard() (
  local work
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  printf '%s\n' "$1" >"$work/input" || return 1
  rish_fw_whitelist_filter "$work/input" "$work/output" || return 1
  cmp -s "$work/input" "$work/output" || {
    rish_fw_error "Блокировка пересекается с белым списком. Выберите один из оставшихся незашищённых диапазонов."
    return 1
  }
)

rish_fw_temporary_add() (
  local net seconds="$2" work fragment zone expiry rule rc deadline old_net old_zone old_expiry old_rule key
  local -A existing_expiry=() chosen=()
  net=$(rish_fw_network "$1") || return 1
  [[ "$seconds" =~ ^[0-9]+$ ]] && ((seconds >= 1 && seconds <= 31536000)) || { rish_fw_error "Срок: от 1 секунды до 365 дней."; return 1; }
  rish_fw_active && rish_fw_lock || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  printf '%s\n' "$net" >"$work/input" || return 1
  rish_fw_whitelist_filter "$work/input" "$work/filtered" || return 1
  [[ -s "$work/filtered" ]] || { printf 'Адрес входит в белый список; блокировка не создана.\n'; return 0; }
  rish_fw_ssh_guard_file "$work/filtered" || return 1
  while IFS= read -r fragment; do
    rish_fw_temporary_coverage "$fragment" || return 1
  done <"$work/filtered"
  rish_fw_temporary_snapshot "$work/before" || return 1
  while IFS=$'\t' read -r old_net old_zone old_expiry old_rule; do
    [[ -n "$old_net" ]] || continue
    key="$old_zone"$'\t'"$old_net"
    existing_expiry["$key"]="$old_expiry"
  done <"$work/before.active"
  deadline=$(($(rish_fw_now) + seconds))
  : >"$work/chosen" || return 1
  while IFS= read -r fragment; do
    key="$RISH_FW_ZONE"$'\t'"$fragment"
    chosen["$key"]=1
    expiry="${existing_expiry[$key]:-$deadline}"
    rule=$(rish_fw_temp_rule "$fragment")
    printf '%s\t%s\t%s\t%s\n' "$fragment" "$RISH_FW_ZONE" "$expiry" "$rule" >>"$work/chosen" || return 1
  done <"$work/filtered"
  : >"$work/desired"; : >"$work/desired.active"
  for zone in before before.active; do
    while IFS=$'\t' read -r old_net old_zone old_expiry old_rule; do
      [[ -n "$old_net" ]] || continue
      key="$old_zone"$'\t'"$old_net"
      [[ -z "${chosen[$key]:-}" ]] || continue
      if [[ "$zone" == before ]]; then
        printf '%s\t%s\t%s\t%s\n' "$old_net" "$old_zone" "$old_expiry" "$old_rule" >>"$work/desired" || return 1
      else
        printf '%s\t%s\t%s\t%s\n' "$old_net" "$old_zone" "$old_expiry" "$old_rule" >>"$work/desired.active" || return 1
      fi
    done <"$work/$zone"
  done
  cat "$work/chosen" >>"$work/desired" || return 1
  cat "$work/chosen" >>"$work/desired.active" || return 1
  rish_fw_temporary_reconcile "$work/desired" || return 1
  printf 'Временная блокировка %s%s%s применена с учётом белого списка.\n' "$RISH_FW_GREEN" "$net" "$RISH_FW_RESET"
  printf 'Уже действующие точные правила сохраняют прежний срок.\n'
  rish_fw_field "Срок новых правил" "$(rish_fw_duration_label "$seconds")" "$RISH_FW_YELLOW"
  printf 'Применение сохранённых правил или перезагрузка сервера %sснимает временную блокировку%s.\n' "$RISH_FW_YELLOW" "$RISH_FW_RESET"
)

rish_fw_temporary_extend() (
  local net seconds="$2" records old_net old_zone old_expiry old_rule rule="" expiry now remaining work result
  net=$(rish_fw_network "$1") || return 1
  rish_fw_temporary_whitelist_guard "$net" || return 1
  [[ "$seconds" =~ ^[0-9]+$ ]] && ((seconds >= 1 && seconds <= 31536000)) || return 1
  rish_fw_active && rish_fw_ssh_guard "$net" && rish_fw_lock && rish_fw_temporary_coverage "$net" || return 1
  records=$(rish_fw_read_ledger) || return 1
  now=$(rish_fw_now)
  while IFS=$'\t' read -r old_net old_zone old_expiry old_rule; do
    if [[ "$old_net" == "$net" && "$old_zone" == "$RISH_FW_ZONE" ]]; then
      rule="$old_rule"; expiry="$old_expiry"; break
    fi
  done <<<"$records"
  [[ -n "$rule" ]] && ((expiry > now)) && rish_fw_cmd --zone="$RISH_FW_ZONE" --query-rich-rule="$rule" >/dev/null 2>&1 || {
    rish_fw_error "Действующее учтённое временное правило не найдено. Продление недоступно."; return 1;
  }
  if ((now + seconds <= expiry)); then
    rish_fw_error "Выбранный срок не продлевает текущую блокировку. Укажите более позднее окончание."; return 1
  fi
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  if ! rish_fw_remove_rule_checked "$rule"; then
    rish_fw_error "Снятие прежней блокировки и отмена её срока не подтверждены. Срок не продлён."
    return 1
  fi
  result=$(rish_fw_cmd --zone="$RISH_FW_ZONE" --add-rich-rule="$rule" --timeout="${seconds}s" 2>&1)
  if [[ $? != 0 || "$result" == *ALREADY_ENABLED* ]]; then
    printf '%s\n' "$result" >&2
    remaining=$((expiry - $(rish_fw_now)))
    if ((remaining > 0)); then
      rish_fw_quiet --zone="$RISH_FW_ZONE" --add-rich-rule="$rule" --timeout="${remaining}s" || rish_fw_error "Прежняя временная блокировка не восстановлена."
    fi
    rish_fw_error "Продление не выполнено."; return 1
  fi
  now=$(rish_fw_now)
  while IFS=$'\t' read -r old_net old_zone old_expiry old_rule; do
    [[ -n "$old_net" ]] || continue
    if [[ "$old_net" == "$net" && "$old_zone" == "$RISH_FW_ZONE" ]]; then old_expiry=$((now + seconds)); fi
    printf '%s\t%s\t%s\t%s\n' "$old_net" "$old_zone" "$old_expiry" "$old_rule" >>"$work"
  done <<<"$records"
  if ! rish_fw_atomic_file "$work" "$RISH_FW_LEDGER"; then
    if ! rish_fw_remove_rule_checked "$rule"; then
      rish_fw_error "Новое правило не снято после ошибки записи; прежний срок не восстановлен."
      return 1
    fi
    remaining=$((expiry - $(rish_fw_now)))
    if ((remaining > 0)); then rish_fw_quiet --zone="$RISH_FW_ZONE" --add-rich-rule="$rule" --timeout="${remaining}s" || rish_fw_error "Прежняя блокировка не восстановлена."; fi
    rish_fw_error "Учёт срока не сохранён; продление отменено."; return 1
  fi
  printf 'Блокировка %s%s%s %sпродлена%s до %s%s%s.\n' \
    "$RISH_FW_GREEN" "$net" "$RISH_FW_RESET" "$RISH_FW_GREEN" "$RISH_FW_RESET" "$RISH_FW_YELLOW" "$(rish_fw_date "$((now + seconds))")" "$RISH_FW_RESET"
)

rish_fw_temporary_remove() (
  local net records old_net old_zone expiry rule work found=0 query_rc result
  net=$(rish_fw_network "$1") || return 1
  rish_fw_active && rish_fw_lock || return 1
  records=$(rish_fw_read_ledger) || return 1
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  while IFS=$'\t' read -r old_net old_zone expiry rule; do
    [[ -n "$old_net" ]] || continue
    if [[ "$old_net" == "$net" && "$old_zone" == "$RISH_FW_ZONE" ]]; then
      found=1
      rish_fw_cmd --zone="$old_zone" --query-rich-rule="$rule" >/dev/null 2>&1
      query_rc=$?
      if [[ "$query_rc" != 0 && "$query_rc" != 1 ]]; then rish_fw_error "Не удалось сверить временное правило."; return 1; fi
      if [[ "$query_rc" == 0 ]]; then
        result=$(rish_fw_cmd --zone="$old_zone" --remove-rich-rule="$rule" 2>&1)
        if [[ $? != 0 || "$result" == *NOT_ENABLED* ]]; then printf '%s\n' "$result" >&2; return 1; fi
      else
        # A wall-clock deadline cannot prove that the old callback has run.
        # Retain ownership until an exact live removal confirms cancellation.
        printf '%s\t%s\t%s\t%s\n' "$old_net" "$old_zone" "$expiry" "$rule" >>"$work"
        continue
      fi
    else
      printf '%s\t%s\t%s\t%s\n' "$old_net" "$old_zone" "$expiry" "$rule" >>"$work"
    fi
  done <<<"$records"
  [[ "$found" == 1 ]] || { rish_fw_error "Точное временное правило RISH для ${net} не найдено."; return 1; }
  rish_fw_atomic_file "$work" "$RISH_FW_LEDGER" || {
    rish_fw_error "Правило снято, но журнал не обновлён. Статус будет сверяться с firewalld."; return 1;
  }
  printf 'Временная блокировка %s%s%s %sснята или уже не действует%s.\n' \
    "$RISH_FW_GREEN" "$net" "$RISH_FW_RESET" "$RISH_FW_GREEN" "$RISH_FW_RESET"
)

rish_fw_ssh_port() {
  local server_port extra
  read -r _ _ _ server_port extra <<<"${SSH_CONNECTION:-}"
  [[ "$server_port" =~ ^[0-9]+$ && -z "$extra" ]] && ((server_port >= 1 && server_port <= 65535)) || {
    rish_fw_error "Реальный порт текущего SSH-соединения неизвестен. Закрытие портов/служб запрещено."; return 1;
  }
  printf '%s\n' "$server_port"
}

rish_fw_port_guard() {
  local spec="$1" ssh_port start end protocol
  [[ "$spec" =~ ^([0-9]+)(-([0-9]+))?/(tcp|udp|sctp|dccp)$ ]] || { rish_fw_error "Формат порта: 443/tcp или 8000-8010/tcp."; return 1; }
  start=$((10#${BASH_REMATCH[1]})); end="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"; end=$((10#$end)); protocol="${BASH_REMATCH[4]}"
  ((start >= 1 && end <= 65535 && end >= start)) || return 1
  ssh_port=$(rish_fw_ssh_port) || return 1
  if [[ "$protocol" == tcp ]] && ((ssh_port >= start && ssh_port <= end)); then
    rish_fw_error "Нельзя закрыть порт текущего SSH-соединения ${ssh_port}/tcp."; return 1
  fi
}

rish_fw_service_guard() {
  local service="$1" info item includes broad mode
  [[ "$service" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  rish_fw_ssh_port >/dev/null || return 1
  for mode in runtime permanent; do
    local -a flag=()
    [[ "$mode" != permanent ]] || flag=(--permanent)
    info=$(rish_fw_cmd "${flag[@]}" --info-service="$service") || return 1
    while IFS= read -r item; do
      [[ -n "$item" ]] || continue
      rish_fw_port_guard "$item" || return 1
    done < <(sed -n 's/^[[:space:]]*ports:[[:space:]]*//p' <<<"$info" | tr ' ' '\n')
    includes=$(sed -n 's/^[[:space:]]*includes:[[:space:]]*//p' <<<"$info")
    broad=$(sed -n -e 's/^[[:space:]]*protocols:[[:space:]]*//p' -e 's/^[[:space:]]*source-ports:[[:space:]]*//p' <<<"$info" | tr -d '[:space:]')
    if [[ -n "$includes" || -n "$broad" ]]; then
      rish_fw_error "Служба содержит includes, protocols или source-ports. Её удаление недоступно без отдельной проверки SSH-доступа."; return 1
    fi
  done
  [[ "$service" != ssh ]] || { rish_fw_error "Удаление службы ssh запрещено."; return 1; }
}

# Work with effective coverage: native add/remove coalesce and split ranges.
rish_fw_port_intervals() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import re, sys

def intervals(text):
    result = {}
    for token in text.split():
        match = re.match(r'^([0-9]{1,5})(?:-([0-9]{1,5}))?/(tcp|udp|sctp|dccp)$', token)
        if not match:
            raise ValueError('неверная запись порта')
        start, end = int(match.group(1)), int(match.group(2) or match.group(1))
        if not 1 <= start <= end <= 65535:
            raise ValueError('порт вне допустимого диапазона')
        result.setdefault(match.group(3), []).append((start, end))
    for protocol, ranges in result.items():
        merged = []
        for start, end in sorted(ranges):
            if merged and start <= merged[-1][1] + 1:
                merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
            else:
                merged.append((start, end))
        result[protocol] = merged
    return result

def subtract(left, right):
    result = []
    for start, end in left:
        cursor = start
        for other_start, other_end in right:
            if other_end < cursor:
                continue
            if other_start > end:
                break
            if other_start > cursor:
                result.append((cursor, other_start - 1))
            cursor = max(cursor, other_end + 1)
            if cursor > end:
                break
        if cursor <= end:
            result.append((cursor, end))
    return result

def spec(protocol, start, end):
    port = str(start) if start == end else '%d-%d' % (start, end)
    return port + '/' + protocol

try:
    mode, before_text, current_text = sys.argv[1:]
    before = intervals(before_text)
    if mode == 'normalize':
        for protocol in sorted(before):
            for start, end in before[protocol]:
                print(spec(protocol, start, end))
    elif mode == 'diff':
        current = intervals(current_text)
        protocols = sorted(set(before) | set(current))
        # Restore missing old ports before withdrawing any excess permissions.
        for action, left, right in (('add', before, current), ('remove', current, before)):
            for protocol in protocols:
                for start, end in subtract(left.get(protocol, []), right.get(protocol, [])):
                    print(action + '\t' + spec(protocol, start, end))
    else:
        raise ValueError('неверная операция со списком портов')
except ValueError as error:
    print('Не удалось обработать список портов firewalld: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
}

rish_fw_restore_ports() {
  local snapshot="$1" expected current operations action port result actual
  expected=$(rish_fw_port_intervals normalize "$snapshot") || return 1
  current=$(rish_fw_cmd --permanent --zone="$RISH_FW_ZONE" --list-ports) || return 1
  operations=$(rish_fw_port_intervals diff "$snapshot" "$current") || return 1
  while IFS=$'\t' read -r action port; do
    [[ -n "$action" ]] || continue
    result=$(rish_fw_cmd --permanent --zone="$RISH_FW_ZONE" "--${action}-port=${port}" 2>&1)
    if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then
      printf '%s\n' "$result" >&2
      return 1
    fi
  done <<<"$operations"
  current=$(rish_fw_cmd --permanent --zone="$RISH_FW_ZONE" --list-ports) || return 1
  actual=$(rish_fw_port_intervals normalize "$current") || return 1
  [[ "$actual" == "$expected" ]]
}

rish_fw_endpoint_change() (
  local kind="$1" value="$2" action="$3" mode present runtime_present permanent_present inverse result ports_snapshot ports_expected runtime_snapshot runtime_expected runtime_after
  [[ "$kind" == port || "$kind" == service ]] && [[ "$action" == add || "$action" == remove ]] || return 2
  rish_fw_active || return 1
  if [[ "$kind" == port ]]; then
    [[ "$value" =~ ^([0-9]+)(-([0-9]+))?/(tcp|udp|sctp|dccp)$ ]] || return 1
    local start=$((10#${BASH_REMATCH[1]})) end="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
    end=$((10#$end)); ((start >= 1 && end >= start && end <= 65535)) || return 1
    [[ "$action" != remove ]] || rish_fw_port_guard "$value" || return 1
  else
    [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    rish_fw_cmd --get-services | tr ' ' '\n' | grep -Fxq -- "$value" || return 1
    [[ "$action" != remove ]] || rish_fw_service_guard "$value" || return 1
  fi
  rish_fw_lock || return 1
  for mode in permanent runtime; do
    local -a flag=()
    [[ "$mode" == permanent ]] && flag=(--permanent)
    rish_fw_cmd "${flag[@]}" --zone="$RISH_FW_ZONE" "--query-${kind}=${value}" >/dev/null 2>&1
    present=$?
    [[ "$present" == 0 || "$present" == 1 ]] || return 1
    if [[ "$mode" == permanent ]]; then permanent_present=$present; else runtime_present=$present; fi
  done
  [[ "$permanent_present" == "$runtime_present" ]] || {
    rish_fw_error "Действующие и сохранённые разрешения порта/службы различаются. Сначала требуется сверка."; return 1;
  }
  [[ "$action" != add || "$runtime_present" != 0 ]] || { printf '%sУже открыто%s; настройка сохранена.\n' "$RISH_FW_GREEN" "$RISH_FW_RESET"; return 0; }
  [[ "$action" != remove || "$runtime_present" != 1 ]] || { printf '%sУже закрыто%s; настройка сохранена.\n' "$RISH_FW_GREEN" "$RISH_FW_RESET"; return 0; }
  if [[ "$kind" == port ]]; then
    ports_snapshot=$(rish_fw_cmd --permanent --zone="$RISH_FW_ZONE" --list-ports) || return 1
    ports_expected=$(rish_fw_port_intervals normalize "$ports_snapshot") || return 1
    runtime_snapshot=$(rish_fw_cmd --zone="$RISH_FW_ZONE" --list-ports) || return 1
    runtime_expected=$(rish_fw_port_intervals normalize "$runtime_snapshot") || return 1
    if [[ "$runtime_expected" != "$ports_expected" ]]; then
      rish_fw_error "Действующие и сохранённые разрешения портов различаются. Сначала требуется сверка."
      return 1
    fi
  fi
  inverse=remove; [[ "$action" == remove ]] && inverse=add
  result=$(rish_fw_cmd --permanent --zone="$RISH_FW_ZONE" "--${action}-${kind}=${value}" 2>&1)
  if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then printf '%s\n' "$result" >&2; return 1; fi
  result=$(rish_fw_cmd --zone="$RISH_FW_ZONE" "--${action}-${kind}=${value}" 2>&1)
  if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then
    printf '%s\n' "$result" >&2
    if [[ "$kind" == port ]]; then
      if rish_fw_restore_ports "$ports_snapshot"; then
        printf 'Прежние сохранённые разрешения портов %sвосстановлены%s и проверены.\n' "$RISH_FW_GREEN" "$RISH_FW_RESET"
      else
        rish_fw_error "Прежние сохранённые разрешения портов восстановлены не полностью. Проверьте зону ${RISH_FW_ZONE}."
      fi
      if ! runtime_after=$(rish_fw_cmd --zone="$RISH_FW_ZONE" --list-ports) ||
          ! runtime_after=$(rish_fw_port_intervals normalize "$runtime_after") ||
          [[ "$runtime_after" != "$runtime_expected" ]]; then
        rish_fw_error "Не удалось подтвердить прежнее состояние действующих разрешений портов. Проверьте зону ${RISH_FW_ZONE}."
      fi
    else
      rish_fw_quiet --permanent --zone="$RISH_FW_ZONE" "--${inverse}-${kind}=${value}" || rish_fw_error "Сохранённые настройки не восстановлены."
    fi
    rish_fw_error "Операция не завершена."; return 1
  fi
  local action_label="открыт доступ к" kind_label="порту/диапазону"
  [[ "$action" != remove ]] || action_label="закрыт доступ к"
  [[ "$kind" != service ]] || kind_label="службе"
  printf 'В зоне %s%s%s %s%s%s %s %s%s%s. Настройка сохранена.\n' \
    "$RISH_FW_GREEN" "$RISH_FW_ZONE" "$RISH_FW_RESET" "$RISH_FW_GREEN" "$action_label" "$RISH_FW_RESET" "$kind_label" "$RISH_FW_GREEN" "$value" "$RISH_FW_RESET"
)

rish_fw_port_change() { rish_fw_endpoint_change port "$1" "$2"; }
rish_fw_service_change() { rish_fw_endpoint_change service "$1" "$2"; }

rish_fw_status() {
  rish_fw_header
  printf '\nАктивные зоны, интерфейсы и привязанные адреса:\n'
  rish_fw_cmd --get-active-zones || return 1
  [[ -n "$RISH_FW_ZONE" ]] || return 0
  printf '\nАктивные правила:\n'
  if [[ "$RISH_FW_HEADER_INFO_RC" == 0 ]]; then printf '%s\n' "$RISH_FW_HEADER_INFO";
  else rish_fw_cmd --zone="$RISH_FW_ZONE" --list-all || return 1; fi
  printf '\nПостоянные правила:\n'
  rish_fw_cmd --permanent --zone="$RISH_FW_ZONE" --list-all
}

rish_fw_show_blocks() (
  local work
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  rish_fw_collect_blocks "$work" || return 1
  rish_fw_table_page "$work" all "" all 0 145 || return 1
  printf '%s\n' "$RISH_FW_TABLE_HEADER" "${RISH_FW_TABLE_LABELS[@]}"
  printf 'Записей: %s; страниц: %s.\n' "$RISH_FW_TABLE_TOTAL" "$RISH_FW_TABLE_PAGES"
)

rish_fw_duration() {
  local choice=0 value
  vertical_menu current 2 0 38 default=5 "15 минут" "1 час" "24 часа" "Другой срок" "Постоянно" "Отмена" || choice=$?
  case "$choice" in
    0) RISH_FW_DURATION=900 ;;
    1) RISH_FW_DURATION=3600 ;;
    2) RISH_FW_DURATION=86400 ;;
    3)
      read -r -p "Срок (30m — 30 мин., 2h — 2 ч., 3d — 3 дн.; максимум 365 дн.): " value
      [[ "$value" =~ ^([0-9]{1,8})([smhd])?$ ]] || return 1
      RISH_FW_DURATION=$((10#${BASH_REMATCH[1]}))
      case "${BASH_REMATCH[2]:-s}" in m) RISH_FW_DURATION=$((RISH_FW_DURATION * 60));; h) RISH_FW_DURATION=$((RISH_FW_DURATION * 3600));; d) RISH_FW_DURATION=$((RISH_FW_DURATION * 86400));; esac
      ((RISH_FW_DURATION > 0 && RISH_FW_DURATION <= 31536000)) || return 1
      ;;
    4) RISH_FW_DURATION=permanent ;;
    *) return 1 ;;
  esac
}

rish_fw_promote() (
  local net family work
  net=$(rish_fw_network "$1") || return 1
  rish_fw_active && rish_fw_lock || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  family=$(rish_fw_family "$net")
  rish_fw_current_entries "$family" permanent >"${work}/desired" || return 1
  printf '%s\n' "$net" >>"${work}/desired"
  if rish_fw_permanent_apply "$family" "${work}/desired"; then
    if rish_fw_read_ledger | awk -F '\t' -v n="$net" -v z="$RISH_FW_ZONE" '$1==n && $2==z { found=1 } END { exit !found }'; then
      rish_fw_temporary_remove "$net" || return 1
    fi
  else
    rish_fw_error "Постоянная блокировка не применена."
    return 1
  fi
)

# Named-list storage and independent firewalld sets. No automatic migrations.
rish_fw_list_id_valid() { [[ "$1" =~ ^[a-z][a-z0-9_-]{0,15}$ ]]; }

rish_fw_list_meta_json() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, re, sys, unicodedata
ident, name, description = sys.argv[1:]
if any(c in '\u2028\u2029' for c in name + description):
    sys.exit(1)
name, description = name.strip(), description.strip()
if not re.fullmatch(r'[a-z][a-z0-9_-]{0,15}', ident) or not name or len(name) > 80 or len(description) > 500:
    sys.exit(1)
if any(unicodedata.category(c).startswith('C') for c in name + description):
    sys.exit(1)
print(json.dumps({'version': 1, 'id': ident, 'name': name, 'description': description}, ensure_ascii=False))
PY
}

rish_fw_list_meta() {
  local id="$1" directory file
  rish_fw_list_id_valid "$id" && rish_fw_paths || return 1
  directory="$RISH_FW_LIST_DIR/$id"; file="$directory/metadata.json"
  rish_fw_secure_path "$directory" || return 1
  if [[ "$id" == manual && ! -e "$file" && ! -L "$file" ]]; then
    printf 'manual\tРучные блокировки\tАдреса, добавленные вручную.\n'
    return 0
  fi
  [[ -d "$directory" && ! -L "$directory" && -f "$file" && ! -L "$file" ]] || return 1
  [[ $(stat -c %a -- "$directory") == 700 && $(stat -c %a -- "$file") == 600 ]] || return 1
  rish_fw_secure_path "$file" || return 1
  python3 - "$id" "$file" <<'PY'
import json, sys, unicodedata
try:
    with open(sys.argv[2], encoding='utf-8') as handle:
        item = json.load(handle)
    if not isinstance(item, dict) or type(item.get('version')) is not int or item['version'] != 1 or item.get('id') != sys.argv[1]:
        raise ValueError()
    name, description = item.get('name'), item.get('description')
    if not isinstance(name, str) or not name.strip() or not isinstance(description, str) or len(name) > 80 or len(description) > 500:
        raise ValueError()
    if any(unicodedata.category(c).startswith('C') or c in '\u2028\u2029' for c in name + description):
        raise ValueError()
    print('\t'.join((sys.argv[1], name, description)))
except (ValueError, OSError, UnicodeError):
    sys.exit(1)
PY
}

rish_fw_list_metadata() {
  local directory id
  rish_fw_paths && rish_fw_secure_path "$RISH_FW_LIST_DIR" || return 1
  rish_fw_list_meta manual || return 1
  [[ -d "$RISH_FW_LIST_DIR" ]] || return 0
  for directory in "$RISH_FW_LIST_DIR"/*; do
    id="${directory##*/}"
    rish_fw_list_id_valid "$id" || continue
    [[ "$id" != manual ]] || continue
    [[ ! -L "$directory" ]] || { rish_fw_error "Недопустимая ссылка в реестре списков: ${directory}"; return 1; }
    [[ -d "$directory" ]] || continue
    rish_fw_list_meta "$id" || { rish_fw_error "Повреждены сведения о списке ${id}. Изменения остановлены."; return 1; }
  done
  return 0
}

rish_fw_list_ids() {
  local metadata id rest
  metadata=$(rish_fw_list_metadata) || return 1
  while IFS=$'\t' read -r id rest; do printf '%s\n' "$id"; done <<<"$metadata"
}

rish_fw_list_create() (
  local id="$1" name="$2" description="${3:-}" directory work family mode names set_name failed=0
  local RISH_FW_LIST_ID="$id"
  rish_fw_list_id_valid "$id" && [[ "$id" != manual ]] || return 1
  rish_fw_lock || return 1
  directory="$RISH_FW_LIST_DIR/$id"
  rish_fw_secure_path "$directory" && [[ ! -e "$directory" && ! -L "$directory" ]] || return 1
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  rish_fw_list_meta_json "$id" "$name" "$description" >"$work" || { rish_fw_error "Недопустимое название или описание списка."; return 1; }
  for mode in runtime permanent; do
    local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
    names=$(rish_fw_cmd "${flag[@]}" --get-ipsets) || return 1
    for family in 4 6; do
      set_name=$(rish_fw_set_name "$family") || return 1
      if tr ' ' '\n' <<<"$names" | grep -Fxq -- "$set_name"; then
        rish_fw_error "Имя ${set_name} уже используется firewalld. Существующий набор не изменён."
        return 1
      fi
    done
  done
  umask 077
  install -d -m 700 -- "$RISH_FW_LIST_DIR" || return 1
  mkdir -m 700 -- "$directory" || return 1
  : >"$directory/ipv4.txt" && : >"$directory/ipv6.txt" &&
    rish_fw_atomic_file "$work" "$directory/metadata.json" || failed=1
  if [[ "$failed" != 0 ]]; then
    rm -f -- "$directory/ipv4.txt" "$directory/ipv6.txt" "$directory/metadata.json"
    rmdir -- "$directory" 2>/dev/null || true
    return 1
  fi
)

rish_fw_list_rename() (
  local id="$1" name="$2" description="${3:-}" directory work
  rish_fw_list_meta "$id" >/dev/null && rish_fw_lock || return 1
  rish_fw_list_meta "$id" >/dev/null || return 1
  directory="$RISH_FW_LIST_DIR/$id"
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  rish_fw_list_meta_json "$id" "$name" "$description" >"$work" || { rish_fw_error "Недопустимое название или описание списка."; return 1; }
  rish_fw_secure_path "$directory" && install -d -m 700 -- "$directory" || return 1
  rish_fw_atomic_file "$work" "$directory/metadata.json"
)

# One operation-local snapshot replaces per-list/per-family/per-zone queries.
# Optional raw files let deletion reuse the zones already read for references.
rish_fw_zone_snapshot() (
  local output="$1" runtime="${2:-}" permanent="${3:-}" work
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  if [[ -z "$runtime" && -z "$permanent" ]]; then
    runtime="$work/runtime"; permanent="$work/permanent"
    rish_fw_cmd --list-all-zones >"$runtime" &&
      rish_fw_cmd --permanent --list-all-zones >"$permanent" || return 1
  fi
  [[ -f "$runtime" && -r "$runtime" && -f "$permanent" && -r "$permanent" ]] || return 1
  python3 - "$runtime" "$permanent" >"$output" <<'PYZONE'
import re, shlex, sys
try:
    for mode, path in zip(('runtime', 'permanent'), sys.argv[1:]):
        zones, zone = {}, None
        with open(path, encoding='utf-8') as handle:
            for line in handle:
                line = line.rstrip('\n')
                if not line.strip():
                    continue
                if not line[0].isspace():
                    match = re.fullmatch(r'([A-Za-z0-9_.-]+)(?: \(([^)]+)\))?', line)
                    if not match or match[2] and any(marker.strip() not in ('default', 'active') for marker in match[2].split(',')):
                        raise ValueError('неизвестный формат списка зон')
                    zone = match[1]
                    if zone in zones:
                        raise ValueError('повторная зона')
                    zones[zone] = set()
                elif zone is None:
                    raise ValueError('правило без зоны')
                elif line.strip().startswith('rule '):
                    tokens = shlex.split(line.strip())
                    names = [token[6:] for token in tokens if token.startswith('ipset=')]
                    if len(names) != 1:
                        continue
                    match = re.fullmatch(r'rish_([a-z][a-z0-9_-]{0,15})_ipv([46])', names[0])
                    if not match:
                        continue
                    family = match[2]
                    expected = ['rule', 'priority=-100', 'family=ipv' + family, 'source', 'ipset=' + names[0], 'drop']
                    if sorted(tokens) == sorted(expected):
                        zones[zone].add((family, names[0]))
        if not zones:
            raise ValueError('список зон пуст')
        for zone, gates in sorted(zones.items()):
            print('\t'.join((mode, zone, '-', '-')))
            for family, name in sorted(gates):
                print('\t'.join((mode, zone, family, name)))
except (OSError, UnicodeError, ValueError) as error:
    print('Не удалось прочитать зоны firewalld: %s.' % error, file=sys.stderr)
    sys.exit(1)
PYZONE
)

rish_fw_snapshot_zones() {
  local snapshot="$1" id="$2" mode="$3" wanted="${4:-all}" row_mode zone family set_name
  local -A seen=()
  [[ -r "$snapshot" && ( "$mode" == runtime || "$mode" == permanent ) && ( "$wanted" == all || "$wanted" == 4 || "$wanted" == 6 ) ]] || return 1
  while IFS=$'\t' read -r row_mode zone family set_name; do
    [[ "$row_mode" == "$mode" && "$family" != - && ( "$wanted" == all || "$family" == "$wanted" ) && "$set_name" == "rish_${id}_ipv${family}" ]] || continue
    if [[ -z "${seen[$zone]:-}" ]]; then printf '%s\n' "$zone"; seen[$zone]=1; fi
  done <"$snapshot"
}

# Return codes match --query-rich-rule: 0 present, 1 absent, 2 invalid zone/read.
rish_fw_snapshot_gate() {
  local snapshot="$1" id="$2" mode="$3" wanted_zone="$4" wanted_family="$5" row_mode zone family set_name found_zone=0
  [[ -r "$snapshot" ]] || return 2
  while IFS=$'\t' read -r row_mode zone family set_name; do
    [[ "$row_mode" == "$mode" && "$zone" == "$wanted_zone" ]] || continue
    found_zone=1
    [[ "$family" != "$wanted_family" || "$set_name" != "rish_${id}_ipv${wanted_family}" ]] || return 0
  done <"$snapshot"
  [[ "$found_zone" == 1 ]] || return 2
  return 1
}

rish_fw_list_zones() (
  local id="$1" mode="$2" wanted="${3:-all}" work
  rish_fw_list_meta "$id" >/dev/null || return 1
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  rish_fw_zone_snapshot "$work" && rish_fw_snapshot_zones "$work" "$id" "$mode" "$wanted"
)

rish_fw_list_gate_rollback() {
  local file="$1" mode action rule result failed=0 inverse i
  shift
  local -a operations=("$@")
  if [[ -n "$file" ]]; then
    mapfile -t operations <"$file" || { rish_fw_error "Не удалось прочитать журнал отката правил списка."; return 1; }
  fi
  for ((i=${#operations[@]}-1; i>=0; i--)); do
    IFS=$'\t' read -r mode action rule <<<"${operations[$i]}"
    [[ -n "$mode" ]] || continue
    local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
    inverse=remove; [[ "$action" != remove ]] || inverse=add
    result=$(rish_fw_cmd "${flag[@]}" --zone="$RISH_FW_ZONE" "--${inverse}-rich-rule=$rule" 2>&1)
    if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then
      printf '%s\n' "$result" >&2; failed=1
    fi
  done
  return "$failed"
}

rish_fw_list_toggle() (
  local id="$1" zone="$2" action="$3" family mode info state rule query_rc result work failed=0 expected runtime_state permanent_state path rollback_failed=0
  local RISH_FW_LIST_ID="$id" RISH_FW_ZONE="$zone"
  local -a needed=() missing=() applied_ops=()
  local -A states=()
  [[ "$action" == add || "$action" == remove ]] || return 1
  rish_fw_list_meta "$id" >/dev/null && rish_fw_active && rish_fw_lock || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  : >"$work/before" || return 1
  if [[ "$action" == add ]]; then
    for family in 4 6; do
      for mode in runtime permanent; do
        info=$(rish_fw_ipset_info "$family" "$mode"); state=$?
        [[ "$state" == 0 || "$state" == 1 ]] || return 1
        states["${family}-${mode}"]="$state"
        : >"$work/$mode.raw" || return 1
        if [[ "$state" == 0 ]]; then
          rish_fw_entries_from_info "$family" "$info" >"$work/$mode.raw" || return 1
        fi
        rish_fw_normalize "$work/$mode.raw" "$work/$mode" preserve || return 1
      done
      runtime_state=${states["${family}-runtime"]}; permanent_state=${states["${family}-permanent"]}
      [[ "$runtime_state" == "$permanent_state" ]] || { rish_fw_error "Список существует только в действующих или сохранённых настройках. Включение отменено."; return 1; }
      cmp -s "$work/runtime" "$work/permanent" || { rish_fw_error "Действующий и сохранённый списки различаются. Включение отменено."; return 1; }
      cp -- "$work/runtime" "$work/guard$family" || return 1
      path=$(rish_fw_list_path "$family") || return 1
      rish_fw_secure_path "$path" || return 1
      if [[ "$runtime_state" == 0 || -s "$path" ]]; then
        needed+=("$family")
        [[ "$runtime_state" != 1 ]] || missing+=("$family")
      fi
    done
    if ((${#needed[@]} == 0)); then
      [[ "$id" != manual ]] || return 0
      rish_fw_error "Список пуст. Добавьте адреса или импортируйте файл."
      return 1
    fi
    # Existing sets were read and validated above. Only new sets need preparation.
    if ((${#missing[@]} > 0)); then
      rish_fw_ensure_ipsets "${missing[@]}" || return 1
      for family in "${missing[@]}"; do
        for mode in runtime permanent; do
          rish_fw_current_entries "$family" "$mode" >"$work/$mode.raw" &&
            rish_fw_normalize "$work/$mode.raw" "$work/$mode" preserve || return 1
        done
        cmp -s "$work/runtime" "$work/permanent" || { rish_fw_error "Действующий и сохранённый списки различаются. Включение отменено."; return 1; }
        cp -- "$work/runtime" "$work/guard$family" || return 1
      done
    fi
  fi
  rish_fw_zone_snapshot "$work/zones-before" || return 1
  for family in 4 6; do
    if [[ "$action" == add && " ${needed[*]} " != *" $family "* ]]; then continue; fi
    rule=$(rish_fw_set_rule "$family") || return 1
    for mode in permanent runtime; do
      rish_fw_snapshot_gate "$work/zones-before" "$id" "$mode" "$zone" "$family"; query_rc=$?
      [[ "$query_rc" == 0 || "$query_rc" == 1 ]] || return 1
      printf '%s\t%s\t%s\n' "$mode" "$query_rc" "$rule" >>"$work/before" || return 1
    done
  done
  if [[ "$action" == add ]]; then
    for family in "${needed[@]}"; do
      rule=$(rish_fw_set_rule "$family") || return 1
      if grep -Fq -- $'\t1\t'"$rule" "$work/before"; then
        rish_fw_ssh_guard_file "$work/guard$family" && rish_fw_whitelist_guard_file "$work/guard$family" || return 1
      fi
    done
  fi
  while IFS=$'\t' read -r mode query_rc rule; do
    [[ "$action:$query_rc" != add:0 && "$action:$query_rc" != remove:1 ]] || continue
    local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
    result=$(rish_fw_cmd "${flag[@]}" --zone="$zone" "--${action}-rich-rule=$rule" 2>&1)
    if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then
      printf '%s\n' "$result" >&2; failed=1; break
    fi
    applied_ops+=("$mode"$'\t'"$action"$'\t'"$rule")
  done <"$work/before"
  ((${#applied_ops[@]} > 0 || failed != 0)) || return 0
  if [[ "$failed" == 0 ]]; then
    rish_fw_zone_snapshot "$work/zones-after" || failed=1
    expected=0; [[ "$action" != remove ]] || expected=1
    while IFS=$'\t' read -r mode query_rc rule; do
      family=6; [[ "$rule" != *'family="ipv4"'* ]] || family=4
      rish_fw_snapshot_gate "$work/zones-after" "$id" "$mode" "$zone" "$family"
      [[ $? == "$expected" ]] || failed=1
    done <"$work/before"
  fi
  if [[ "$failed" != 0 ]]; then
    rish_fw_list_gate_rollback "" "${applied_ops[@]}" || rollback_failed=1
    rish_fw_zone_snapshot "$work/zones-rollback" || rollback_failed=1
    while IFS=$'\t' read -r mode expected rule; do
      family=6; [[ "$rule" != *'family="ipv4"'* ]] || family=4
      rish_fw_snapshot_gate "$work/zones-rollback" "$id" "$mode" "$zone" "$family"
      [[ $? == "$expected" ]] || rollback_failed=1
    done <"$work/before"
    ((rollback_failed == 0)) || rish_fw_error "Откат правил списка выполнен не полностью. Проверьте зону ${zone}."
    return 1
  fi
)

rish_fw_list_restore_files() {
  local work="$1" family path failed=0
  for family in 4 6; do
    path=$(rish_fw_list_path "$family") || return 1
    if [[ -f "$work/file$family" ]]; then
      rish_fw_atomic_file "$work/file$family" "$path" && cmp -s "$work/file$family" "$path" || failed=1
    else
      rish_fw_secure_path "$path" && [[ ! -e "$path" || -f "$path" && ! -L "$path" ]] && rm -f -- "$path" || failed=1
    fi
  done
  return "$failed"
}

rish_fw_list_restore_added_gates() (
  local file="$1" zone mode family expected rule state result failed=0 work changed=0
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_zone_snapshot "$work/zones" || return 1
  while IFS=$'\t' read -r zone mode family expected rule; do
    rish_fw_snapshot_gate "$work/zones" "$RISH_FW_LIST_ID" "$mode" "$zone" "$family"; state=$?
    [[ "$state" == 0 || "$state" == 1 ]] || { failed=1; continue; }
    if [[ "$expected" == 1 && "$state" == 0 ]]; then
      local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
      result=$(rish_fw_cmd "${flag[@]}" --zone="$zone" --remove-rich-rule="$rule" 2>&1)
      if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then printf '%s\n' "$result" >&2; failed=1; fi
      changed=1
    fi
  done <"$file"
  if [[ "$changed" == 1 ]]; then rish_fw_zone_snapshot "$work/zones" || return 1; fi
  while IFS=$'\t' read -r zone mode family expected rule; do
    rish_fw_snapshot_gate "$work/zones" "$RISH_FW_LIST_ID" "$mode" "$zone" "$family"; state=$?
    [[ "$state" == "$expected" ]] || failed=1
  done <"$file"
  return "$failed"
)

rish_fw_list_apply_internal() (
  local id="$1" source_file="$2" operation="$3" zone="${4:-${RISH_FW_ZONE:-}}" normalize_mode="${5:-collapse}" family mode work path enabled_zone state info rule query_rc expected failed=0 rollback_failed=0 gates_changed=0
  local RISH_FW_LIST_ID="$id" RISH_FW_ATTACH_GATE=0 RISH_FW_ZONE="$zone"
  local -a missing=()
  local -A states=()
  [[ "$operation" == add || "$operation" == replace ]] && [[ "$normalize_mode" == preserve || "$normalize_mode" == collapse ]] || return 1
  rish_fw_list_meta "$id" >/dev/null && [[ -f "$source_file" && -r "$source_file" ]] || return 1
  [[ -n "$RISH_FW_ZONE" ]] || RISH_FW_ZONE=$(rish_fw_cmd --get-default-zone) || return 1
  rish_fw_active && rish_fw_lock || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_normalize "$source_file" "$work/unfiltered" "$normalize_mode" &&
    rish_fw_whitelist_filter "$work/unfiltered" "$work/input" || return 1
  rish_fw_zone_snapshot "$work/zones-before" || return 1
  : >"$work/gates-before"; : >"$work/enabled-zones"
  for family in 4 6; do
    for mode in runtime permanent; do
      info=$(rish_fw_ipset_info "$family" "$mode"); state=$?
      [[ "$state" == 0 || "$state" == 1 ]] || return 1
      states["${family}-${mode}"]="$state"
      : >"$work/$mode$family.raw" || return 1
      if [[ "$state" == 0 ]]; then
        rish_fw_entries_from_info "$family" "$info" >"$work/$mode$family.raw" || return 1
      fi
      rish_fw_normalize "$work/$mode$family.raw" "$work/$mode$family" preserve || return 1
      rish_fw_snapshot_zones "$work/zones-before" "$id" "$mode" "$family" >"$work/zones-$family-$mode" || return 1
    done
    [[ "${states["${family}-runtime"]}" == "${states["${family}-permanent"]}" ]] || { rish_fw_error "IPv${family}: список существует только в действующих или сохранённых настройках."; return 1; }
    cmp -s "$work/runtime$family" "$work/permanent$family" || { rish_fw_error "IPv${family}: действующий и сохранённый списки различаются."; return 1; }
    cmp -s "$work/zones-$family-runtime" "$work/zones-$family-permanent" || { rish_fw_error "IPv${family}: подключения списка к зонам различаются. Изменения остановлены."; return 1; }
    cat "$work/zones-$family-runtime" >>"$work/enabled-zones" || return 1
    path=$(rish_fw_list_path "$family") || return 1
    rish_fw_secure_path "$path" || return 1
    if [[ -e "$path" ]]; then [[ -f "$path" && ! -L "$path" ]] && cp -- "$path" "$work/file$family" || return 1; fi
    if [[ "$family" == 4 ]]; then grep -v ':' "$work/input" >"$work/all$family" || true; else grep ':' "$work/input" >"$work/all$family" || true; fi
    [[ "$operation" != add ]] || cat "$work/permanent$family" >>"$work/all$family"
    rish_fw_normalize "$work/all$family" "$work/unfiltered$family" "$normalize_mode" &&
      rish_fw_whitelist_filter "$work/unfiltered$family" "$work/new$family" || return 1
    LC_ALL=C sort "$work/permanent$family" >"$work/old-sort" || return 1
    LC_ALL=C sort "$work/new$family" >"$work/new-sort" || return 1
    LC_ALL=C comm -13 "$work/old-sort" "$work/new-sort" >"$work/add$family" || return 1
    if [[ "${states["${family}-runtime"]}" == 1 && -s "$work/new$family" ]]; then missing+=("$family"); fi
  done
  rish_fw_ssh_guard_file "$work/add4" "$work/add6" || return 1
  LC_ALL=C sort -u "$work/enabled-zones" >"$work/enabled-sorted" || return 1
  # A legacy split between nonempty IPv4/IPv6 coverage must not silently widen it.
  for family in 4 6; do
    [[ -s "$work/permanent$family" ]] || continue
    while IFS= read -r enabled_zone; do
      grep -Fxq -- "$enabled_zone" "$work/zones-$family-runtime" || { rish_fw_error "IPv4 и IPv6 списка подключены к разным зонам. Сначала требуется сверка."; return 1; }
    done <"$work/enabled-sorted"
  done
  while IFS= read -r enabled_zone; do
    for mode in permanent runtime; do
      for family in 4 6; do
        rule=$(rish_fw_set_rule "$family") || return 1
        query_rc=1
        grep -Fxq -- "$enabled_zone" "$work/zones-$family-$mode" && query_rc=0
        printf '%s\t%s\t%s\t%s\t%s\n' "$enabled_zone" "$mode" "$family" "$query_rc" "$rule" >>"$work/gates-before" || return 1
      done
    done
  done <"$work/enabled-sorted"
  # Prepare missing families before the first address/file change. Existing
  # families were validated above and permanent_apply reads them again itself.
  if ((${#missing[@]} > 0)); then
    rish_fw_ensure_ipsets "${missing[@]}" || return 1
    rish_fw_zone_snapshot "$work/zones-prepared" && cmp -s "$work/zones-before" "$work/zones-prepared" || { rish_fw_error "Подключения списков изменились во время подготовки. Повторите операцию."; return 1; }
  fi
  for family in 4 6; do
    if ((${#missing[@]} == 0)) && cmp -s "$work/new$family" "$work/permanent$family"; then
      # Initial entries are already validated and equal in both configurations.
      # A preparation/reload confirmation above always keeps the fresh-read path.
      path=$(rish_fw_list_path "$family") || { failed=1; break; }
      if ! { : >"$work/undo$family" && rish_fw_atomic_file "$work/new$family" "$path"; }; then failed=1; break; fi
      if [[ -s "$work/new$family" ]]; then
        printf 'Список %s%s%s, IPv%s: изменения %sприменены и сохранены%s.\n' \
          "$RISH_FW_GREEN" "$id" "$RISH_FW_RESET" "$family" "$RISH_FW_GREEN" "$RISH_FW_RESET"
      fi
    elif ! rish_fw_permanent_apply "$family" "$work/new$family" "$normalize_mode" "$work/undo$family"; then failed=1; break; fi
  done
  if [[ "$failed" == 0 ]]; then
    # Existing gates do not need a second full list_toggle. Only a newly
    # populated family may need its gate added in already enabled zones.
    while IFS=$'\t' read -r enabled_zone mode family query_rc rule; do
      [[ "$query_rc" == 1 && -s "$work/new$family" ]] || continue
      local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
      info=$(rish_fw_cmd "${flag[@]}" --zone="$enabled_zone" --add-rich-rule="$rule" 2>&1)
      if [[ $? != 0 || "$info" == *ALREADY_ENABLED* || "$info" == *NOT_ENABLED* ]]; then printf '%s\n' "$info" >&2; failed=1; break; fi
      gates_changed=1
    done <"$work/gates-before"
    if [[ "$failed" == 0 && "$gates_changed" == 1 ]]; then
      rish_fw_zone_snapshot "$work/zones-after" || failed=1
      while IFS=$'\t' read -r enabled_zone mode family expected rule; do
        [[ -s "$work/new$family" ]] || continue
        rish_fw_snapshot_gate "$work/zones-after" "$id" "$mode" "$enabled_zone" "$family" || failed=1
      done <"$work/gates-before"
    fi
  fi
  if [[ "$failed" != 0 ]]; then
    rish_fw_list_restore_added_gates "$work/gates-before" || rollback_failed=1
    for family in 6 4; do
      if [[ -f "$work/undo$family" ]]; then
        RISH_FW_OPERATION_SET=$(rish_fw_set_name "$family")
        rish_fw_rollback_ops "$work/undo$family" || rollback_failed=1
      fi
    done
    rish_fw_list_restore_files "$work" || rollback_failed=1
    for family in 4 6; do
      for mode in runtime permanent; do
        rish_fw_current_entries "$family" "$mode" >"$work/verify.raw" &&
          rish_fw_normalize "$work/verify.raw" "$work/verify" preserve &&
          cmp -s "$work/$mode$family" "$work/verify" || rollback_failed=1
      done
    done
    ((rollback_failed == 0)) || rish_fw_error "Откат списка выполнен не полностью. Проверьте действующие адреса, сохранённые адреса и файлы списка."
    return 1
  fi
)

rish_fw_list_apply_file() { rish_fw_list_apply_internal "$1" "$2" "$3" "${4:-${RISH_FW_ZONE:-}}" collapse; }

rish_fw_list_remove_entry() (
  local id="$1" net family work found=0
  local RISH_FW_LIST_ID="$id"
  rish_fw_list_meta "$id" >/dev/null && rish_fw_lock || return 1
  net=$(rish_fw_network "$2") || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  : >"$work/desired"
  for family in 4 6; do
    rish_fw_current_entries "$family" permanent >"$work/raw" && rish_fw_normalize "$work/raw" "$work/current" preserve || return 1
    if grep -Fxq -- "$net" "$work/current"; then found=1; fi
    grep -Fxv -- "$net" "$work/current" >>"$work/desired" || true
  done
  [[ "$found" == 1 ]] || { rish_fw_error "Точный адрес или подсеть не найдены в выбранном списке."; return 1; }
  rish_fw_list_apply_internal "$id" "$work/desired" replace "${RISH_FW_ZONE:-}" preserve
)

# Native deletion does not reject foreign references. Inspect all supported
# configurations before removing anything; only our exact zone gates are exempt.
rish_fw_list_delete_references() {
  local work="$1" mode help name4 name6
  name4=$(rish_fw_set_name 4); name6=$(rish_fw_set_name 6)
  help=$(LC_ALL=C rish_fw_cmd --help) || return 1
  for mode in runtime permanent; do
    local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
    rish_fw_cmd "${flag[@]}" --list-all-zones >"$work/refs-$mode-zones" || return 1
    : >"$work/refs-$mode-other"
    if grep -Eq '^[[:space:]]*--list-all-policies([[:space:]]|$)' <<<"$help"; then
      rish_fw_cmd "${flag[@]}" --list-all-policies >>"$work/refs-$mode-other" || return 1
    fi
    rish_fw_cmd "${flag[@]}" --direct --get-all-rules >>"$work/refs-$mode-other" || return 1
    rish_fw_cmd "${flag[@]}" --direct --get-all-passthroughs >>"$work/refs-$mode-other" || return 1
  done
  python3 - "$work" "$name4" "$name6" <<'PY'
import os, re, shlex, sys
directory, name4, name6 = sys.argv[1:]
names = (name4, name6)
pattern = re.compile(r'(?<![A-Za-z0-9_-])(?:' + '|'.join(re.escape(n) for n in names) + r')(?![A-Za-z0-9_-])')
owned = [sorted(shlex.split('rule priority="-100" family="ipv%d" source ipset="%s" drop' % (family, name))) for family, name in ((4, name4), (6, name6))]
try:
    for mode in ('runtime', 'permanent'):
        for kind in ('zones', 'other'):
            with open(os.path.join(directory, 'refs-' + mode + '-' + kind), encoding='utf-8') as handle:
                for line in handle:
                    if not pattern.search(line):
                        continue
                    if kind == 'zones' and sorted(shlex.split(line.strip())) in owned:
                        continue
                    raise ValueError('список используется другим правилом: ' + line.strip())
except (ValueError, OSError, UnicodeError) as error:
    print('Удаление отменено: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
}

rish_fw_list_delete_verify() (
  local work="$1" family mode expected state zone rule info failed=0
  while IFS=$'\t' read -r family mode expected; do
    info=$(rish_fw_ipset_info "$family" "$mode"); state=$?
    [[ "$state" == "$expected" ]] || { failed=1; continue; }
    if [[ "$state" == 0 ]]; then
      rish_fw_entries_from_info "$family" "$info" >"$work/verify.raw" &&
        rish_fw_normalize "$work/verify.raw" "$work/verify" preserve &&
        cmp -s "$work/before-$family-$mode" "$work/verify" || failed=1
    fi
  done <"$work/exists"
  rish_fw_zone_snapshot "$work/zones-verify" || return 1
  while IFS=$'\t' read -r zone mode family expected rule; do
    rish_fw_snapshot_gate "$work/zones-verify" "$RISH_FW_LIST_ID" "$mode" "$zone" "$family"; state=$?
    [[ "$state" == "$expected" ]] || failed=1
  done <"$work/gates"
  return "$failed"
)

rish_fw_list_delete_restore() {
  local work="$1" need_reload="$2" family set_name state zone mode expected rule result failed=0
  for family in 4 6; do
    [[ -f "$work/set$family.xml" ]] || continue
    rish_fw_ipset_exists "$family" permanent; state=$?
    if [[ "$state" == 1 ]]; then
      set_name=$(rish_fw_set_name "$family")
      rish_fw_quiet --permanent --new-ipset-from-file="$work/set$family.xml" --name="$set_name" || failed=1
    elif [[ "$state" != 0 ]]; then failed=1; fi
    rish_fw_ipset_exists "$family" runtime; state=$?
    [[ "$state" != 1 ]] || need_reload=1
  done
  # Saved gates must exist before recovery reload can recreate runtime sets.
  for mode in permanent runtime; do
    if [[ "$mode" == runtime && "$need_reload" == 1 ]]; then
      if [[ "$failed" == 0 ]]; then
        rish_fw_quiet --check-config && rish_fw_quiet --reload || failed=1
      fi
    fi
    while IFS=$'\t' read -r zone original_mode family expected rule; do
      [[ "$original_mode" == "$mode" && "$expected" == 0 ]] || continue
      local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
      rish_fw_cmd "${flag[@]}" --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; state=$?
      if [[ "$state" == 1 ]]; then
        result=$(rish_fw_cmd "${flag[@]}" --zone="$zone" --add-rich-rule="$rule" 2>&1)
        if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then printf '%s\n' "$result" >&2; failed=1; fi
      elif [[ "$state" != 0 ]]; then failed=1; fi
    done <"$work/gates"
  done
  rish_fw_quiet --check-config || failed=1
  rish_fw_list_delete_verify "$work" || failed=1
  return "$failed"
}

rish_fw_list_delete() (
  local id="$1" work directory family mode state set_name xml_path zone row_family rule query_rc result path archive info failed=0 reload_attempted=0 had_sets=0
  local RISH_FW_LIST_ID="$id"
  [[ "$id" != manual ]] || { rish_fw_error "Ручной список нельзя удалить. Можно удалить его адреса."; return 1; }
  rish_fw_list_meta "$id" >/dev/null && rish_fw_active && rish_fw_lock || return 1
  rish_fw_list_meta "$id" >/dev/null || return 1
  directory="$RISH_FW_LIST_DIR/$id"
  # Refuse unexpected/symlinked registry contents instead of deleting recursively.
  for path in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    [[ -e "$path" || -L "$path" ]] || continue
    case "${path##*/}" in metadata.json|ipv4.txt|ipv6.txt) ;; *) rish_fw_error "В каталоге списка есть посторонние файлы. Удаление отменено."; return 1;; esac
    [[ -f "$path" && ! -L "$path" ]] && rish_fw_secure_path "$path" || return 1
  done
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  : >"$work/exists"; : >"$work/gates"; : >"$work/ops"
  rish_fw_list_delete_references "$work" || return 1
  rish_fw_zone_snapshot "$work/zones-before" "$work/refs-runtime-zones" "$work/refs-permanent-zones" || return 1
  rish_fw_quiet --check-config || return 1
  rish_fw_reload_preview || return 1
  for family in 4 6; do
    for mode in runtime permanent; do
      info=$(rish_fw_ipset_info "$family" "$mode"); state=$?
      [[ "$state" == 0 || "$state" == 1 ]] || return 1
      printf '%s\t%s\t%s\n' "$family" "$mode" "$state" >>"$work/exists"
      if [[ "$state" == 0 ]]; then
        had_sets=1
        rish_fw_entries_from_info "$family" "$info" >"$work/before.raw" &&
          rish_fw_normalize "$work/before.raw" "$work/before-$family-$mode" preserve || return 1
        if [[ "$mode" == permanent ]]; then
          set_name=$(rish_fw_set_name "$family")
          xml_path=$(rish_fw_cmd --permanent --path-ipset="$set_name") || return 1
          [[ -f "$xml_path" && ! -L "$xml_path" ]] && rish_fw_secure_path "$xml_path" && cp -- "$xml_path" "$work/set$family.xml" || return 1
        fi
      fi
    done
  done
  while IFS=$'\t' read -r mode zone row_family set_name; do
    [[ "$row_family" == - ]] || continue
    for family in 4 6; do
      rule=$(rish_fw_set_rule "$family") || return 1
      rish_fw_snapshot_gate "$work/zones-before" "$id" "$mode" "$zone" "$family"; query_rc=$?
      [[ "$query_rc" == 0 || "$query_rc" == 1 ]] || return 1
      printf '%s\t%s\t%s\t%s\t%s\n' "$zone" "$mode" "$family" "$query_rc" "$rule" >>"$work/gates" || return 1
    done
  done <"$work/zones-before"
  # Recheck immediately before writes; other administrators do not share our lock.
  rish_fw_list_delete_references "$work" && rish_fw_reload_preview || return 1
  rish_fw_zone_snapshot "$work/zones-rechecked" "$work/refs-runtime-zones" "$work/refs-permanent-zones" &&
    cmp -s "$work/zones-before" "$work/zones-rechecked" || { rish_fw_error "Подключения списков изменились. Повторите удаление."; return 1; }
  while IFS=$'\t' read -r zone mode family query_rc rule; do
    [[ "$query_rc" == 0 ]] || continue
    local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
    result=$(rish_fw_cmd "${flag[@]}" --zone="$zone" --remove-rich-rule="$rule" 2>&1)
    if [[ $? != 0 || "$result" == *ALREADY_ENABLED* || "$result" == *NOT_ENABLED* ]]; then printf '%s\n' "$result" >&2; failed=1; break; fi
    printf '%s\t%s\t%s\n' "$zone" "$mode" "$rule" >>"$work/ops"
  done <"$work/gates"
  if [[ "$failed" == 0 ]]; then
    for family in 4 6; do
      [[ -f "$work/set$family.xml" ]] || continue
      set_name=$(rish_fw_set_name "$family")
      rish_fw_quiet --permanent --delete-ipset="$set_name" || { failed=1; break; }
    done
  fi
  if [[ "$failed" == 0 && "$had_sets" == 1 ]]; then
    reload_attempted=1
    rish_fw_quiet --check-config && rish_fw_quiet --reload || failed=1
  fi
  if [[ "$failed" == 0 ]]; then
    for family in 4 6; do
      for mode in runtime permanent; do
        rish_fw_ipset_exists "$family" "$mode"; [[ $? == 1 ]] || failed=1
      done
    done
  fi
  if [[ "$failed" == 0 ]]; then
    archive=$(mktemp -d "$RISH_FW_LIST_DIR/.rish-delete-${id}.XXXXXX") || failed=1
    if [[ "$failed" == 0 ]] && ! mv -- "$directory" "$archive/registry"; then failed=1; fi
  fi
  if [[ "$failed" != 0 ]]; then
    rish_fw_list_delete_restore "$work" "$reload_attempted" || rish_fw_error "Откат удаления выполнен не полностью. Проверьте списки и правила firewalld вручную."
    [[ -z "$archive" ]] || rmdir -- "$archive" 2>/dev/null || true
    return 1
  fi
  # The active registry disappears atomically, only after native deletion verified.
  rm -f -- "$archive/registry/metadata.json" "$archive/registry/ipv4.txt" "$archive/registry/ipv6.txt" &&
    rmdir -- "$archive/registry" "$archive" || rish_fw_error "Список удалён, но резервный каталог ${archive} не удалось очистить."
  return 0
)


# Collect UI records separately from their labels: kind, list ID, title, CIDR,
# zones, expiry, state, writable. Optional coverage keeps active and saved ranges
# separate in the selected zone; combined zones cannot establish persistence.
# Queries fail closed; no per-address native calls.
rish_fw_collect_blocks() (
  local target="$1" summary="${2:-}" coverage="${3:-}" work id rest family mode names set_name now
  local RISH_FW_LIST_ID
  local -a ids=() set_names=()
  local -A known_sets=()
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_list_metadata >"$work/metadata" || return 1
  while IFS=$'\t' read -r id rest; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
  done <"$work/metadata"
  for mode in runtime permanent; do
    local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
    rish_fw_cmd "${flag[@]}" --list-all-zones >"$work/zones-$mode" || return 1
    names=$(rish_fw_cmd "${flag[@]}" --get-ipsets) || return 1
    known_sets=()
    while read -r -a set_names; do
      for set_name in "${set_names[@]}"; do known_sets["$set_name"]=1; done
    done <<<"$names"
    for id in "${ids[@]}"; do
      RISH_FW_LIST_ID="$id"
      for family in 4 6; do
        set_name=$(rish_fw_set_name "$family") || return 1
        if [[ -n "${known_sets[$set_name]:-}" ]]; then
          rish_fw_cmd "${flag[@]}" --info-ipset="$set_name" >"$work/info-$id-$family-$mode" || return 1
        fi
      done
    done
  done
  rish_fw_read_ledger >"$work/ledger" || return 1
  now=$(rish_fw_now)
  python3 - "$work" "$now" "$summary" "$coverage" "$RISH_FW_ZONE" >"$target" <<'PY'
import ipaddress, json, os, re, sys
directory, now, summary, coverage, selected_zone = sys.argv[1:]
now = int(now)
def read(name):
    with open(os.path.join(directory,name),encoding='utf-8') as handle:
        return handle.read()
def zones(mode):
    result, zone = {}, None
    for line in read('zones-'+mode).splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            match = re.fullmatch(r'([A-Za-z0-9_.-]+)(?: \(([^)]+)\))?',line)
            if not match or match[2] and any(marker.strip() not in ('default','active') for marker in match[2].split(',')):
                raise ValueError('неизвестный формат списка зон')
            zone = match[1]
            result[zone] = set()
        elif zone is None:
            raise ValueError('правило без зоны')
        elif line.strip().startswith('rule '):
            result[zone].add(line.strip())
    if not result:
        raise ValueError('список зон пуст')
    return result
def entries(ident,family,mode):
    name = 'info-%s-%s-%s' % (ident,family,mode)
    if not os.path.exists(os.path.join(directory,name)):
        return set()
    fields = {}
    for line in read(name).splitlines()[1:]:
        if ':' in line:
            key,value = line.strip().split(':',1)
            fields[key] = value.strip()
    options = dict(token.split('=',1) for token in fields.get('options','').split() if '=' in token)
    expected = 'inet' if family == 4 else 'inet6'
    if fields.get('type') != 'hash:net' or options.get('family','inet') != expected or options.get('timeout','0') != '0' or 'entries' not in fields:
        raise ValueError('несовместимый набор %s IPv%s' % (ident,family))
    result = set()
    loopback = ipaddress.ip_network('127.0.0.0/8' if family == 4 else '::1/128')
    for value in fields['entries'].split():
        net = ipaddress.ip_network(value,strict=False)
        if net.version != family or net.prefixlen == 0 or net.network_address.is_unspecified or net.overlaps(loopback) or '%' in value:
            raise ValueError('недопустимый адрес в наборе')
        result.add(str(net))
    return result
def sort_key(value):
    net = ipaddress.ip_network(value)
    return (net.version,int(net.network_address),net.prefixlen)
try:
    configurations = {mode: zones(mode) for mode in ('runtime','permanent')}
    if coverage and selected_zone not in configurations['runtime']:
        raise ValueError('выбранная зона отсутствует')
    coverage_networks = {'runtime': set(), 'permanent': set(), 'temporary': set()}
    records, summaries = [], []
    for metadata in read('metadata').split('\n'):
        if not metadata:
            continue
        ident,title,description = metadata.split('\t')
        all_runtime_zones, all_permanent_zones, drift = set(), set(), False
        for family in (4,6):
            runtime,permanent = (entries(ident,family,mode) for mode in ('runtime','permanent'))
            gate = 'rule priority="-100" family="ipv%s" source ipset="rish_%s_ipv%s" drop' % (family,ident,family)
            zr,zp = ({zone for zone,rules in configurations[mode].items() if gate in rules} for mode in ('runtime','permanent'))
            if coverage and selected_zone in zr:
                coverage_networks['runtime'].update(runtime)
            if coverage and selected_zone in zp:
                coverage_networks['permanent'].update(permanent)
            all_runtime_zones.update(zr)
            all_permanent_zones.update(zp)
            present = [os.path.exists(os.path.join(directory,'info-%s-%s-%s' % (ident,family,mode))) for mode in ('runtime','permanent')]
            same_entries, same_zones = runtime == permanent, zr == zp
            zone_text = ','.join(sorted(zr | zp)) or '-'
            writable = 'yes' if same_entries else 'no'
            drift = drift or not same_entries or not same_zones or present[0] != present[1]
            for net in sorted(runtime | permanent,key=sort_key):
                if net not in runtime:
                    state = 'permanent'
                elif net not in permanent:
                    state = 'runtime'
                elif not same_zones:
                    state = 'zones'
                elif not zr:
                    state = 'off'
                else:
                    state = 'saved'
                records.append(('P',ident,title,net,zone_text,'-',state,writable))
        summaries.append((ident,title,','.join(sorted(all_runtime_zones | all_permanent_zones)) or '-', 'Требует сверки' if drift else 'Включён' if all_runtime_zones else 'Отключён'))
    for line in read('ledger').splitlines():
        net,zone,expiry,rule = line.split('\t')
        if zone not in configurations['runtime']:
            raise ValueError('зона временного правила отсутствует')
        present = rule in configurations['runtime'][zone]
        state = 'expired' if not present else 'temporary' if int(expiry) > now else 'uncertain'
        records.append(('T','temporary','Временные',net,zone,expiry,state,'yes' if present else 'no'))
        if coverage and present and zone == selected_zone:
            coverage_networks['temporary'].add(net)
    if summary:
        with open(summary,'w',encoding='utf-8') as handle:
            for row in summaries:
                handle.write('\t'.join(row)+'\n')
    if coverage:
        # Merge once per snapshot; rendering up to 200 IPs then uses binary search.
        ranges = {'zone': selected_zone}
        for kind, networks in coverage_networks.items():
            parsed = [ipaddress.ip_network(net) for net in networks]
            ranges[kind] = {str(family): [[int(net.network_address), int(net.broadcast_address)]
                for net in ipaddress.collapse_addresses(net for net in parsed if net.version == family)]
                for family in (4, 6)}
        with open(coverage, 'w', encoding='utf-8') as handle:
            json.dump(ranges, handle)
    for record in records:
        print('\t'.join(record))
except (ValueError,OSError,UnicodeError) as error:
    print('Не удалось прочитать таблицу блокировок: %s.' % error,file=sys.stderr)
    sys.exit(1)
PY
)


# At most 200 rows plus navigation: vertical_menu returns an 8-bit index.
rish_fw_table_page() {
  local source_file="$1" scope="$2" search="$3" filter="$4" page="$5" columns="$6" page_size="${7:-200}" cache="${8:-}" result line label row
  RISH_FW_TABLE_LABELS=(); RISH_FW_TABLE_ROWS=()
  result=$(python3 - "$source_file" "$scope" "$search" "$filter" "$page" "$columns" "$page_size" "$cache" <<'PY'
import datetime, ipaddress, json, os, sys
path, scope, search, kind, page, columns, page_size, cache = sys.argv[1:]
page, columns = int(page), max(30, int(columns))
page_size = min(200,max(1,int(page_size)))
states = {'saved':'Заблокирован', 'runtime':'Только действующая', 'permanent':'Только сохранённая', 'zones':'Различаются зоны', 'off':'Отключена', 'temporary':'Действует', 'expired':'Не действует', 'uncertain':'Срок не подтверждён'}
query = None
try:
    query = ipaddress.ip_network(search, strict=False) if search else None
except ValueError:
    pass
rows, metadata = [], None
if cache:
    source_stat = os.stat(path)
    key = [path, scope, search, kind, page_size, source_stat.st_mtime_ns, source_stat.st_size]
    try:
        with open(cache+'.json', encoding='utf-8') as handle:
            metadata = json.load(handle)
        if metadata['key'] != key or not os.path.isfile(cache+'.tsv'):
            metadata = None
    except (OSError, ValueError, KeyError, TypeError):
        metadata = None
def selected():
    folded = search.casefold()
    with open(path, encoding='utf-8') as handle:
        for line in handle:
            values = line.rstrip('\n').split('\t')
            if len(values) != 8:
                raise ValueError('Некорректная строка таблицы')
            typ, ident, title, net, zones, expiry, state, writable = values
            if scope.startswith('temporary:') and (typ != 'T' or zones != scope.split(':',1)[1]):
                continue
            if scope == 'temporary' and typ != 'T' or scope not in ('all', 'temporary') and not scope.startswith('temporary:') and ident != scope:
                continue
            if kind in ('P', 'T') and typ != kind:
                continue
            if search:
                match = folded in ' '.join(values[:5]).casefold()
                if query and not match:
                    network = ipaddress.ip_network(net)
                    match = network.version == query.version and network.overlaps(query)
                if not match:
                    continue
            yield values
if metadata is None:
    total, address_width, offsets = 0, len('Адрес / подсеть'), []
    if cache:
        try:
            os.unlink(cache+'.json')
        except FileNotFoundError:
            pass
        with open(cache+'.tsv', 'wb') as handle:
            for values in selected():
                if total % page_size == 0:
                    offsets.append(handle.tell())
                handle.write(('\t'.join(values)+'\n').encode('utf-8'))
                address_width = max(address_width, len(values[3]))
                total += 1
        metadata = {'key': key, 'total': total, 'address_width': address_width, 'offsets': offsets or [0]}
        with open(cache+'.json', 'w', encoding='utf-8') as handle:
            json.dump(metadata, handle)
    else:
        rows = list(selected())
        total = len(rows)
        address_width = max(address_width, max((len(row[3]) for row in rows), default=0))
else:
    total, address_width = metadata['total'], metadata['address_width']
pages = max(1, (total + page_size-1) // page_size)
page = min(max(0, page), pages - 1)
if cache:
    rows = []
    with open(cache+'.tsv', 'rb') as handle:
        handle.seek(metadata['offsets'][page])
        for number in range(page_size):
            line = handle.readline()
            if not line:
                break
            rows.append(line.decode('utf-8').rstrip('\n').split('\t'))
else:
    rows = rows[page*page_size:(page+1)*page_size]
print('%s\t%s\t%s' % (total, page, pages))
def clip(text, width):
    return text if len(text) <= width else text[:max(0, width-1)] + '…'
def label(values, header=False):
    typ, ident, title, net, zones, expiry, state, writable = values
    state_code = state
    typ = 'Тип' if header else 'Постоянная' if typ == 'P' else 'Временная'
    state = 'Состояние' if header else states[state]
    until = '—'
    if header:
        until = 'Срок'
    elif expiry != '-':
        until = datetime.datetime.fromtimestamp(int(expiry)).strftime('%d.%m %H:%M') if expiry != '0' else 'неизвестен'
    if columns >= 145:
        return '%-*s │ %-18s │ %-10s │ %-14s │ %-11s │ %s' % (address_width, net, clip(title,18), typ, clip(zones,14), until, state)
    if scope == 'all' and columns >= 120:
        return '%-*s │ %-18s │ %-10s │ %s' % (address_width, net, clip(title,18), typ, state)
    if columns >= 120:
        return '%-*s │ %-10s │ %-12s │ %-11s │ %s' % (address_width, net, typ, clip(zones,12), until, state)
    if columns < 55:
        return clip(net, max(12, columns-8))
    if not header:
        state = {'saved':'Заблокирован', 'runtime':'Не сохранена', 'permanent':'Не применена', 'zones':'Разные зоны', 'off':'Отключена', 'temporary':'Действует', 'expired':'Не действует', 'uncertain':'Срок неясен'}[state_code]
    width = min(address_width, max(12, columns - 30))
    state_width = max(6, columns-width-24)
    return ('%-'+str(width)+'s │ %-10s │ %s') % (clip(net,width), typ, clip(state,state_width))
headers = ['P','Список','Список','Адрес / подсеть','Зоны','-','saved','no']
print(label(headers, True))
for values in rows:
    print(label(values) + '\t' + '\t'.join(values))
PY
  ) || return 1
  local first=1 second=0
  while IFS= read -r line; do
    if [[ "$first" == 1 ]]; then
      IFS=$'\t' read -r RISH_FW_TABLE_TOTAL RISH_FW_TABLE_PAGE RISH_FW_TABLE_PAGES <<<"$line"
      first=0; second=1
    elif [[ "$second" == 1 ]]; then RISH_FW_TABLE_HEADER="$line"; second=0
    else
      label=${line%%$'\t'*}; row=${line#*$'\t'}
      RISH_FW_TABLE_LABELS+=("$label"); RISH_FW_TABLE_ROWS+=("$row")
    fi
  done <<<"$result"
}

rish_fw_context_menu() {
  local columns x y width=0 item
  columns=$(tput cols 2>/dev/null) || columns=80
  for item in "$@"; do ((${#item} <= width)) || width=${#item}; done
  x=$(( ${VERTICAL_MENU_LAST_RIGHT_X:-0} + 3 ))
  y=$(( ${VERTICAL_MENU_LAST_Y:-0} + ${VERTICAL_MENU_LAST_VISIBLE_SELECTED:-0} ))
  if ((x + width + 8 <= columns)); then
    if declare -F cursor_to >/dev/null && declare -F repl >/dev/null; then
      cursor_to "$((y + 1))" "$VERTICAL_MENU_LAST_RIGHT_X"; printf '├'; repl '─' 2
    fi
    vertical_menu "$y" "$x" 0 "$width" "$@"
  else
    clear
    vertical_menu current 2 0 "$width" "$@"
  fi
}

rish_fw_pause() { vertical_menu current 2 0 25 "Нажмите Enter"; }

rish_fw_ui_changed() {
  [[ -z "${RISH_FW_UI_CHANGED_FILE:-}" ]] || : >"$RISH_FW_UI_CHANGED_FILE"
}

rish_fw_row_info() {
  local kind id name net zones expiry state writable
  IFS=$'\t' read -r kind id name net zones expiry state writable <<<"$1"
  printf '\n'
  rish_fw_field "Адрес / подсеть" "$net"
  rish_fw_field "Список" "$name"
  rish_fw_field "Зоны" "$zones"
  if [[ "$kind" == T ]]; then
    if [[ "$expiry" == 0 ]]; then rish_fw_field "Срок" "не подтверждён" "$RISH_FW_YELLOW";
    else rish_fw_field "Записанный срок" "$(rish_fw_date "$expiry")" "$RISH_FW_YELLOW"; fi
  fi
  case "$state" in
    saved) state="Заблокирован";; runtime) state="Есть только в действующих настройках";;
    permanent) state="Есть только в сохранённых настройках";; zones) state="Зоны применения различаются";;
    off) state="Список отключён";; temporary) state="Действует";; expired) state="Не действует";;
    uncertain) state="Действует; срок не подтверждён";;
  esac
  rish_fw_field "Состояние" "$state" "$RISH_FW_YELLOW"
  [[ "$writable" != no ]] || printf 'Изменение этой записи недоступно; проверьте состояние списка.\n'
}

# Revalidate the stable raw identity under the same lock as the backend action.
rish_fw_row_action() (
  local original="$1" action="$2" kind id name net zones expiry state writable work found line newkind newid newname newnet newzones rest
  IFS=$'\t' read -r kind id name net zones expiry state writable <<<"$original"
  rish_fw_lock || return 1
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  rish_fw_collect_blocks "$work" || return 1
  found=""
  while IFS= read -r line; do
    IFS=$'\t' read -r newkind newid newname newnet newzones rest <<<"$line"
    if [[ "$newkind" == "$kind" && "$newid" == "$id" && "$newnet" == "$net" && ( "$kind" == P || "$newzones" == "$zones" ) ]]; then found="$line"; break; fi
  done <"$work"
  [[ -n "$found" ]] || { rish_fw_error "Запись уже изменилась. Обновите таблицу."; return 1; }
  IFS=$'\t' read -r kind id name net zones expiry state writable <<<"$found"
  [[ "$writable" == yes ]] || { rish_fw_error "Изменение записи недоступно. Обновите таблицу."; return 1; }
  if [[ "$kind" == P ]]; then
    [[ "$action" == remove ]] || return 2
    rish_fw_confirm "Удалить ${RISH_FW_GREEN}${net}${RISH_FW_RESET} из списка ${RISH_FW_GREEN}${name}${RISH_FW_RESET}?" || return 0
    rish_fw_ui_changed || return 1
    rish_fw_list_remove_entry "$id" "$net"
  else
    local RISH_FW_ZONE="$zones"
    case "$action" in
      remove)
        rish_fw_confirm "Снять блокировку ${RISH_FW_GREEN}${net}${RISH_FW_RESET} в зоне ${RISH_FW_GREEN}${zones}${RISH_FW_RESET}?" || return 0
        rish_fw_ui_changed || return 1
        rish_fw_temporary_remove "$net" ;;
      extend)
        [[ "$state" == temporary && "$expiry" -gt "$(rish_fw_now)" ]] || return 1
        rish_fw_duration || return 0
        [[ "$RISH_FW_DURATION" != permanent ]] || { rish_fw_error "Выберите временный срок."; return 1; }
        rish_fw_confirm "Продлить блокировку от текущего момента?" || return 0
        rish_fw_ui_changed || return 1
        rish_fw_temporary_extend "$net" "$RISH_FW_DURATION" ;;
      promote)
        rish_fw_choose_list || return 0
        rish_fw_confirm "Сделать блокировку ${RISH_FW_GREEN}${net}${RISH_FW_RESET} постоянной в зоне ${RISH_FW_GREEN}${zones}${RISH_FW_RESET}, список ${RISH_FW_GREEN}${RISH_FW_SELECTED_NAME}${RISH_FW_RESET}?" || return 0
        rish_fw_ui_changed || return 1
        rish_fw_add_to_selected "$net" ensure || return 1
        rish_fw_temporary_remove "$net" ;;
    esac
  fi
)

rish_fw_new_list_fields() {
  local name
  read -r -p "Название нового списка: " name || return 1
  # Validate names before using them in terminal labels or confirmation text.
  python3 - "$name" <<'PY'
import sys, unicodedata
name = sys.argv[1]
if not name.strip() or len(name) > 80 or any(unicodedata.category(c).startswith('C') or c in '\u2028\u2029' for c in name):
    print('Название: 1–80 символов; управляющие символы и разделители строк недопустимы.', file=sys.stderr)
    sys.exit(1)
PY
  [[ $? == 0 ]] || return 1
  RISH_FW_SELECTED_ID="l$(date +%s)${RANDOM:0:4}"
  RISH_FW_SELECTED_NAME="$name"
  RISH_FW_SELECTED_DESCRIPTION=""
  RISH_FW_SELECTED_NEW=1
}

rish_fw_choose_list() {
  local metadata id name description choice count i columns width label height
  local -a all_ids=() all_names=() labels=()
  metadata=$(rish_fw_list_metadata) || return 1
  while IFS=$'\t' read -r id name description; do
    [[ -n "$id" ]] || continue
    all_ids+=("$id"); all_names+=("$name")
  done <<<"$metadata"
  columns=$(tput cols 2>/dev/null) || columns=80
  width=$((columns-10)); ((width >= 20)) || width=20
  height=$(tput lines 2>/dev/null) || height=24
  height=$((height-8)); ((height > 4)) || height=5
  count=${#all_ids[@]}
  ((count + 2 <= 255)) || { rish_fw_error "Слишком много списков для меню."; return 1; }
  for ((i=0; i<count; i++)); do
    label=${all_names[$i]}
    ((${#label} <= width)) || label="${label:0:$((width-1))}…"
    labels+=(" $label")
  done
  choice=0
  printf '\nВыберите постоянный список:\n'
  vertical_menu current 2 "$height" 32 default=0 "${labels[@]}" "Создать новый список…" "Отмена" || choice=$?
  if ((choice < count)); then
    RISH_FW_SELECTED_ID=${all_ids[$choice]}
    RISH_FW_SELECTED_NAME=${all_names[$choice]}
    RISH_FW_SELECTED_DESCRIPTION=""; RISH_FW_SELECTED_NEW=0
    return 0
  fi
  case "$((choice-count))" in
    0) rish_fw_new_list_fields; return $? ;;
    *) return 1 ;;
  esac
}

rish_fw_prepare_selected() {
  [[ "${RISH_FW_SELECTED_NEW:-0}" == 1 ]] || return 0
  rish_fw_list_create "$RISH_FW_SELECTED_ID" "$RISH_FW_SELECTED_NAME" "$RISH_FW_SELECTED_DESCRIPTION" || return 1
  RISH_FW_SELECTED_NEW=0
}

rish_fw_add_to_selected() (
  local net="$1" work zones selected_zone="$RISH_FW_ZONE" attach="${2:-keep}"
  rish_fw_lock || return 1
  rish_fw_prepare_selected || return 1
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  printf '%s\n' "$net" >"$work"
  # Existing enabled lists retain all zone bindings. A disabled/new list is
  # explicitly enabled in the zone shown in the user's confirmation.
  zones=$(rish_fw_list_zones "$RISH_FW_SELECTED_ID" runtime) || return 1
  rish_fw_list_apply_file "$RISH_FW_SELECTED_ID" "$work" add "$selected_zone" || return 1
  if [[ -z "$zones" || "$attach" == ensure ]]; then
    if ! rish_fw_list_toggle "$RISH_FW_SELECTED_ID" "$selected_zone" add; then
      rish_fw_error "Адрес сохранён в списке, но его включение в зоне ${selected_zone} не завершено. Проверьте зоны применения."
      return 1
    fi
  fi
  if [[ "$attach" == ensure ]]; then
    local RISH_FW_LIST_ID="$RISH_FW_SELECTED_ID" gate family mode
    family=$(rish_fw_family "$net"); gate=$(rish_fw_set_rule "$family")
    for mode in runtime permanent; do
      local -a flag=(); [[ "$mode" != permanent ]] || flag=(--permanent)
      rish_fw_cmd "${flag[@]}" --zone="$selected_zone" --query-rich-rule="$gate" >/dev/null 2>&1 || {
        rish_fw_error "Постоянная блокировка в исходной зоне не подтверждена; временная сохранена."; return 1;
      }
    done
  fi
)

rish_fw_block_menu() (
  local input="${1:-}" net zones work
  if (($# == 0)); then
    read -r -p "IP-адрес или подсеть для блокировки: " input || return 1
  fi
  net=$(rish_fw_network "$input") || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  printf '%s\n' "$net" >"$work/input" || return 1
  rish_fw_whitelist_filter "$work/input" "$work/filtered" || return 1
  if [[ ! -s "$work/filtered" ]]; then
    printf 'Адрес %s%s%s входит в белый список. Блокировка не применяется.\n' "$RISH_FW_GREEN" "$net" "$RISH_FW_RESET"
    return 1
  fi
  rish_fw_ssh_guard_file "$work/filtered" || return 1
  rish_fw_duration || return 2
  if [[ "$RISH_FW_DURATION" == permanent ]]; then
    rish_fw_choose_list || return 2
    zones=""
    [[ "$RISH_FW_SELECTED_NEW" == 1 ]] || zones=$(rish_fw_list_zones "$RISH_FW_SELECTED_ID" runtime) || return 1
    [[ -n "$zones" ]] || zones="$RISH_FW_ZONE"
    zones=$(tr '\n' ' ' <<<"$zones")
  else zones="$RISH_FW_ZONE"; fi
  printf '\n'
  rish_fw_field "Адрес / подсеть" "$net"
  printf 'Адреса белого списка исключаются из блокировки.\n'
  rish_fw_field "Зоны применения" "$zones"
  rish_fw_field "Срок" "$(rish_fw_duration_label "$RISH_FW_DURATION")" "$RISH_FW_YELLOW"
  [[ "$RISH_FW_DURATION" != permanent ]] || rish_fw_field "Список" "$RISH_FW_SELECTED_NAME"
  rish_fw_confirm "Применить блокировку?" || return 2
  rish_fw_ui_changed || return 1
  if [[ "$RISH_FW_DURATION" != permanent ]]; then rish_fw_temporary_add "$net" "$RISH_FW_DURATION" || return 1;
  else rish_fw_add_to_selected "$net" || return 1; fi
)

rish_fw_choose_import_file() {
  local directory=/root candidate label choice=0 height columns width
  local -a files=() labels=()
  RISH_FW_IMPORT_FILE=""
  if [[ "${RISH_FIREWALL_TEST_MODE:-0}" == 1 ]]; then
    directory="${RISH_FIREWALL_IMPORT_DIR:-/root}"
  fi
  printf '\nИмпорт адресов из файла\n'
  rish_fw_field "Файлы для импорта" "${directory}/ipset*" "$RISH_FW_YELLOW"
  [[ -d "$directory" && -r "$directory" && -x "$directory" ]] || {
    rish_fw_error "Не удалось прочитать каталог ${directory}."; return 1;
  }
  for candidate in "$directory"/ipset*; do
    [[ -f "$candidate" && -r "$candidate" && ! -L "$candidate" ]] || continue
    files+=("$candidate")
  done
  if ((${#files[@]} == 0)); then
    printf 'Файлы %s/ipset* не найдены.\nПоместите файл, например %s/ipset-scanners.txt, и откройте импорт снова.\n' "$directory" "$directory"
    return 1
  fi
  ((${#files[@]} < 255)) || { rish_fw_error "Слишком много файлов для меню импорта."; return 1; }
  columns=$(tput cols 2>/dev/null) || columns=80
  width=$((columns-10)); ((width >= 20)) || width=20
  for candidate in "${files[@]}"; do
    label=${candidate##*/}
    ((${#label} <= width)) || label="${label:0:$((width-1))}…"
    labels+=(" $label")
  done
  height=$(tput lines 2>/dev/null) || height=24
  height=$((height-8)); ((height > 3)) || height=3
  printf '\nВыберите файл со списком адресов:\n'
  vertical_menu current 2 "$height" 52 "${labels[@]}" "Отмена" || choice=$?
  ((choice < ${#files[@]})) || return 1
  candidate=${files[$choice]}
  [[ -f "$candidate" && -r "$candidate" && ! -L "$candidate" ]] || {
    rish_fw_error "Выбранный файл недоступен."; return 1;
  }
  RISH_FW_IMPORT_FILE="$candidate"
}

rish_fw_import_menu() (
  local selected="${1:-}" source_file work mode=0
  rish_fw_choose_import_file || return 0
  source_file="$RISH_FW_IMPORT_FILE"
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  rish_fw_normalize "$source_file" "$work" || return 1
  if [[ -n "$selected" ]]; then
    local meta
    meta=$(rish_fw_list_meta "$selected") || return 1
    IFS=$'\t' read -r RISH_FW_SELECTED_ID RISH_FW_SELECTED_NAME RISH_FW_SELECTED_DESCRIPTION <<<"$meta"
    RISH_FW_SELECTED_NEW=0
  else rish_fw_choose_list || return 0; fi
  vertical_menu current 2 0 32 default=2 "Добавить из файла" "Заменить содержимое" "Отмена" || mode=$?
  [[ "$mode" == 0 || "$mode" == 1 ]] || return 0
  rish_fw_field "Список" "$RISH_FW_SELECTED_NAME"
  rish_fw_field "Файл импорта" "$source_file" "$RISH_FW_YELLOW"
  if [[ "$mode" == 0 ]]; then mode=add; else mode=replace; fi
  rish_fw_lock || return 1
  rish_fw_list_preview "$RISH_FW_SELECTED_ID" "$work" "$mode" || return 1
  if [[ "$RISH_FW_SELECTED_NEW" == 1 ]]; then
    rish_fw_field "Зона применения нового списка" "$RISH_FW_ZONE"
  else printf 'Зоны и включение существующего списка сохраняются.\n'; fi
  rish_fw_confirm "Применить показанные изменения списка?" || return 0
  local new_list_created="$RISH_FW_SELECTED_NEW"
  rish_fw_ui_changed || return 1
  rish_fw_prepare_selected || return 1
  rish_fw_list_apply_file "$RISH_FW_SELECTED_ID" "$work" "$mode" "$RISH_FW_ZONE" || return 1
  if [[ "$new_list_created" == 1 ]]; then
    rish_fw_list_toggle "$RISH_FW_SELECTED_ID" "$RISH_FW_ZONE" add || {
      rish_fw_error "Список импортирован, но его включение не завершено. Проверьте зоны применения."; return 1;
    }
  fi
)

rish_fw_list_preview() (
  local RISH_FW_LIST_ID="$1" file="$2" operation="$3" work family
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_normalize "$file" "$work/unfiltered" &&
    rish_fw_whitelist_filter "$work/unfiltered" "$work/input" || return 1
  for family in 4 6; do
    rish_fw_current_entries "$family" permanent >"$work/raw" &&
      rish_fw_normalize "$work/raw" "$work/old" preserve || return 1
    if [[ "$family" == 4 ]]; then grep -v ':' "$work/input" >"$work/all" || true;
    else grep ':' "$work/input" >"$work/all" || true; fi
    [[ "$operation" != add ]] || cat "$work/old" >>"$work/all"
    rish_fw_normalize "$work/all" "$work/unfiltered" &&
      rish_fw_whitelist_filter "$work/unfiltered" "$work/new" || return 1
    printf '\nIPv%s: изменения (- удалить, + добавить):\n' "$family"
    diff -u --label 'Сейчас' --label 'После применения' -- "$work/old" "$work/new" || true
  done
)

rish_fw_update_files_menu() (
  local id="$1" work family path
  local RISH_FW_LIST_ID="$id"
  rish_fw_list_meta "$id" >/dev/null && rish_fw_lock || return 1
  work=$(mktemp) || return 1
  trap 'rm -f -- "$work"' EXIT
  for family in 4 6; do
    path=$(rish_fw_list_path "$family") || return 1
    rish_fw_secure_path "$path" || return 1
    if [[ -e "$path" ]]; then
      [[ -f "$path" && ! -L "$path" ]] && cat -- "$path" >>"$work" || return 1
      printf '\n' >>"$work"
    fi
  done
  rish_fw_list_preview "$id" "$work" replace || return 1
  rish_fw_confirm "Применить состав списка из его сохранённых файлов?" || return 0
  rish_fw_ui_changed || return 1
  rish_fw_list_apply_file "$id" "$work" replace
)

rish_fw_list_zone_menu() (
  local id="$1" zone="$RISH_FW_ZONE" current saved family rule active_families="" saved_families="" action=add
  local RISH_FW_LIST_ID="$id"
  [[ "$zone" =~ ^[A-Za-z0-9_.-]+$ ]] || { rish_fw_error "Зона не выбрана."; return 1; }
  current=$(rish_fw_cmd --zone="$zone" --list-rich-rules) || return 1
  saved=$(rish_fw_cmd --permanent --zone="$zone" --list-rich-rules) || return 1
  for family in 4 6; do
    rule=$(rish_fw_set_rule "$family") || return 1
    if grep -Fxq -- "$rule" <<<"$current"; then active_families+="$family"; fi
    if grep -Fxq -- "$rule" <<<"$saved"; then saved_families+="$family"; fi
  done
  [[ "$active_families" == "$saved_families" ]] || {
    rish_fw_error "Состояние списка в зоне ${zone} различается в действующих и постоянных правилах. Сначала требуется сверка."; return 1;
  }
  [[ -z "$active_families" ]] || action=remove
  if [[ "$action" == add ]]; then
    rish_fw_confirm "Включить список в зоне ${RISH_FW_GREEN}${zone}${RISH_FW_RESET}?" || return 0
  else rish_fw_confirm "Отключить список в зоне ${RISH_FW_GREEN}${zone}${RISH_FW_RESET}, сохранив его адреса?" || return 0; fi
  rish_fw_ui_changed || return 1
  rish_fw_list_toggle "$id" "$zone" "$action"
)

rish_fw_list_info() (
  local id="$1" summary="${2:-}" meta name _description mode zones family label cached_id _cached_name cached_zones cached_status found=0
  local RISH_FW_LIST_ID="$id"
  meta=$(rish_fw_list_meta "$id") || return 1
  IFS=$'\t' read -r id name _description <<<"$meta"
  printf '\n'
  rish_fw_field "Список" "$name"
  rish_fw_field "ID" "$id"
  if [[ -n "$summary" ]]; then
    [[ -f "$summary" && -r "$summary" ]] || { rish_fw_error "Сведения списка устарели. Откройте список снова."; return 1; }
    while IFS=$'\t' read -r cached_id _cached_name cached_zones cached_status; do
      [[ "$cached_id" == "$id" ]] || continue
      found=1
      break
    done <"$summary"
    [[ "$found" == 1 && -n "$cached_zones" && -n "$cached_status" ]] || { rish_fw_error "Сведения списка устарели. Откройте список снова."; return 1; }
    [[ "$cached_zones" != - ]] || cached_zones=нет
    rish_fw_field "Зоны применения" "$cached_zones"
    rish_fw_field "Состояние" "$cached_status"
  else
    for mode in runtime permanent; do
      zones=$(rish_fw_list_zones "$id" "$mode") || return 1
      zones=$(tr '\n' ' ' <<<"$zones")
      label="Зоны активных правил"; [[ "$mode" != permanent ]] || label="Зоны постоянных правил"
      rish_fw_field "$label" "${zones:-нет}"
    done
  fi
  for family in 4 6; do rish_fw_field "Файл IPv${family}" "$(rish_fw_list_path "$family")"; done
)

rish_fw_list_menu() {
  local id="$1" name="$2" records="${3:-}" summary="${4:-}" choice=0 newname description meta entry_id _entry_name zones _state zone_label="Включить / отключить в зоне ${RISH_FW_ZONE}"
  if [[ -r "$summary" ]]; then
    while IFS=$'\t' read -r entry_id _entry_name zones _state; do
      [[ "$entry_id" == "$id" ]] || continue
      zone_label="Включить в зоне ${RISH_FW_ZONE}"
      [[ ",$zones," != *",$RISH_FW_ZONE,"* ]] || zone_label="Отключить в зоне ${RISH_FW_ZONE}"
      break
    done <"$summary"
  fi
  rish_fw_context_menu "Адреса" "Добавить адрес / подсеть" "Импорт из файла" "$zone_label" "Переименовать" "Удалить список" "Сведения" "Назад" || choice=$?
  ((choice < 7)) || return 0
  clear
  if [[ "$choice" != 0 && "$choice" != 6 ]]; then
    rish_fw_field "Список" "$name"
    rish_fw_field "Зона" "$RISH_FW_ZONE"
    printf '\n'
  fi
  case "$choice" in
    0) rish_fw_blocks_table "$id" "$name" "$records" ;;
    1)
      local input net
      read -r -p "IP-адрес или подсеть: " input || return 1
      net=$(rish_fw_network "$input") || return 1
      RISH_FW_SELECTED_ID="$id"; RISH_FW_SELECTED_NAME="$name"; RISH_FW_SELECTED_NEW=0
      rish_fw_confirm "Добавить ${RISH_FW_GREEN}${net}${RISH_FW_RESET} и применить блокировку?" || return 0
      rish_fw_ui_changed || return 1
      rish_fw_add_to_selected "$net"; rish_fw_pause ;;
    2) rish_fw_import_menu "$id"; rish_fw_pause ;;
    3)
      if [[ "$zone_label" == "Включить в зоне ${RISH_FW_ZONE}" && -r "$records" ]] &&
          ! grep -q -- "^P"$'\t'"${id}"$'\t' "$records"; then
        printf 'Список пуст. Добавьте адреса или импортируйте файл.\n'
      else rish_fw_list_zone_menu "$id"; fi
      rish_fw_pause ;;
    4)
      meta=$(rish_fw_list_meta "$id") || return 1
      IFS=$'\t' read -r entry_id _entry_name description <<<"$meta"
      read -r -p "Новое название: " newname || return 1
      rish_fw_ui_changed || return 1
      rish_fw_list_rename "$id" "$newname" "$description"; rish_fw_pause ;;
    5)
      [[ "$id" != manual ]] || { rish_fw_error "Ручной список можно очистить или отключить; удалить его нельзя."; rish_fw_pause; return 1; }
      rish_fw_confirm "Удалить список ${RISH_FW_GREEN}${name}${RISH_FW_RESET} и его правила во всех зонах?" || return 0
      rish_fw_ui_changed || return 1
      rish_fw_list_delete "$id"; rish_fw_pause ;;
    6) rish_fw_list_info "$id" "$summary"; rish_fw_pause ;;
  esac
}

rish_fw_lists_table() {
  local records="$1" names_file="$2" columns="$3" result line first=1 second=0
  RISH_FW_LIST_LABELS=(); RISH_FW_LIST_ROWS=()
  result=$(python3 - "$records" "$names_file" "$columns" <<'PY'
import collections, sys
records, names, columns = sys.argv[1:]
columns = int(columns)
groups = collections.OrderedDict()
with open(names, encoding='utf-8') as handle:
    for line in handle:
        ident, title, zones, status = line.rstrip('\n').split('\t')
        groups[ident] = [ident, title, 'Постоянный', 0, zones, status]
with open(records, encoding='utf-8') as handle:
    for line in handle:
        typ, ident, title, net, zones, expiry, state, writable = line.rstrip('\n').split('\t')
        if typ == 'T':
            ident = 'temporary:' + zones
            groups.setdefault(ident, [ident, 'Временные — '+zones, 'Временный', 0, zones, 'По сроку'])
        elif state not in ('saved', 'off'):
            groups[ident][5] = 'Требует сверки'
        groups[ident][3] += 1
rows = list(groups.values())
print(len(rows))
def clip(text,width):
    return text if len(text)<=width else text[:width-1]+'…'
def format_row(title,typ,count,zones,state):
    if columns >= 105:
        return '%-30s │ %-10s │ %7s │ %-18s │ %s' % (clip(title,30),typ,count,clip(zones,18),state)
    if columns < 55:
        width = max(12,columns-19)
        return ('%-'+str(width)+'s │ %7s') % (clip(title,width),count)
    width = min(24,max(12,columns-44))
    return ('%-'+str(width)+'s │ %-10s │ %7s │ %s') % (clip(title,width),typ,count,clip(state,max(6,columns-width-41)))
print(format_row('Список','Тип','Адресов','Зоны','Состояние'))
for ident,title,typ,count,zones,state in rows:
    label = format_row(title,typ,count,zones,state)
    print(label+'\t'+ident+'\t'+title)
PY
  ) || return 1
  while IFS= read -r line; do
    if [[ "$first" == 1 ]]; then
      RISH_FW_LIST_TOTAL="$line"; first=0; second=1
    elif [[ "$second" == 1 ]]; then RISH_FW_LIST_HEADER="$line"; second=0
    else RISH_FW_LIST_LABELS+=("${line%%$'\t'*}"); RISH_FW_LIST_ROWS+=("${line#*$'\t'}"); fi
  done <<<"$result"
}

rish_fw_lists_menu() (
  local work id name choice count columns height selected="" default=0 i refresh=1 table_columns=""
  local RISH_FW_UI_CHANGED_FILE
  local -a menu_labels=()
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  RISH_FW_UI_CHANGED_FILE="${work}/changed"
  while true; do
    if [[ "$refresh" == 1 ]]; then
      rish_fw_collect_blocks "${work}/blocks" "${work}/names" || return 1
      refresh=0
      table_columns=""
      rm -f -- "$RISH_FW_UI_CHANGED_FILE"
    fi
    columns=$(tput cols 2>/dev/null) || columns=80
    height=$(tput lines 2>/dev/null) || height=24
    height=$((height - 8)); ((height > 3)) || height=3
    if [[ "$table_columns" != "$columns" ]]; then
      rish_fw_lists_table "${work}/blocks" "${work}/names" "$columns" || return 1
      table_columns="$columns"
    fi
    count=${#RISH_FW_LIST_ROWS[@]}; default=0; menu_labels=()
    ((count + 3 <= 255)) || { rish_fw_error "Слишком много списков для меню."; return 1; }
    for ((i=0; i<count; i++)); do
      menu_labels+=("├─ ${RISH_FW_LIST_LABELS[$i]}")
      [[ "${RISH_FW_LIST_ROWS[$i]%%$'\t'*}" != "$selected" ]] || default="$i"
    done
    clear
    rish_fw_field "Списки блокировок" "$RISH_FW_LIST_TOTAL"
    printf 'Enter или щелчок — действия\n\n'
    printf '       %s\n' "$RISH_FW_LIST_HEADER"
    choice=0
    vertical_menu current_noclear 2 "$height" 32 "default=$default" "${menu_labels[@]}" "Создать список" "Все блокировки" "Назад" || choice=$?
    if ((choice < count)); then
      IFS=$'\t' read -r id name <<<"${RISH_FW_LIST_ROWS[$choice]}"; selected="$id"
      if [[ "$id" == temporary:* ]]; then rish_fw_blocks_table "$id" "$name" "${work}/blocks";
      else rish_fw_list_menu "$id" "$name" "${work}/blocks" "${work}/names"; fi
      [[ ! -f "$RISH_FW_UI_CHANGED_FILE" ]] || refresh=1
    else
      case "$((choice-count))" in
        0)
          if rish_fw_new_list_fields && rish_fw_confirm "Создать список ${RISH_FW_GREEN}${RISH_FW_SELECTED_NAME}${RISH_FW_RESET}?"; then
            rish_fw_prepare_selected; selected="$RISH_FW_SELECTED_ID"; refresh=1; rish_fw_pause
          fi ;;
        1)
          rish_fw_blocks_table all "Все блокировки" "${work}/blocks"
          [[ ! -f "$RISH_FW_UI_CHANGED_FILE" ]] || refresh=1 ;;
        *) return 0 ;;
      esac
    fi
  done
)

rish_fw_row_menu() {
  local row="$1" kind id name net zones expiry state writable choice=0
  local -a labels=("Сведения" "Проверить IP") actions=(info lookup)
  IFS=$'\t' read -r kind id name net zones expiry state writable <<<"$row"
  if [[ "$writable" == yes ]]; then
    if [[ "$kind" == P ]]; then labels+=("Удалить из списка"); else labels+=("Снять блокировку"); fi
    actions+=(remove)
    if [[ "$kind" == T ]]; then
      if [[ "$state" == temporary ]]; then labels+=("Продлить"); actions+=(extend); fi
      labels+=("Сделать постоянной"); actions+=(promote)
    fi
  fi
  labels+=("Назад"); actions+=(back)
  rish_fw_context_menu "${labels[@]}" || choice=$?
  ((choice < ${#actions[@]})) || return 0
  [[ "${actions[$choice]}" != back ]] || return 0
  clear
  case "${actions[$choice]}" in
    info) rish_fw_row_info "$row"; rish_fw_pause ;;
    lookup) rish_fw_ip_lookup_actions "$net" ;;
    back) return 0 ;;
    *) rish_fw_row_action "$row" "${actions[$choice]}"; rish_fw_pause ;;
  esac
}

rish_fw_blocks_table() (
  local scope="${1:-all}" title="${2:-Все блокировки}" snapshot="${3:-}" work work_dir search="" filter=all page=0 choice count columns height selected="" default=0 i key kind id name net zones rest refresh=1
  local parent_changed_file="${RISH_FW_UI_CHANGED_FILE:-}" RISH_FW_UI_CHANGED_FILE
  local render_page=-1 render_columns="" render_height="" render_search="" render_filter=""
  local -a labels=() actions=()
  work_dir=$(mktemp -d) || return 1
  work="${work_dir}/blocks"
  RISH_FW_UI_CHANGED_FILE="${work_dir}/changed"
  trap 'rm -rf -- "$work_dir"' EXIT
  if [[ -n "$snapshot" ]]; then
    cp -- "$snapshot" "$work" || return 1
    refresh=0
  fi
  while true; do
    if [[ "$refresh" == 1 ]]; then
      rish_fw_collect_blocks "$work" || { rish_fw_error "Не удалось прочитать блокировки."; return 1; }
      refresh=0
      render_page=-1
      rm -f -- "${work_dir}/page.json"
    fi
    columns=$(tput cols 2>/dev/null) || columns=80
    height=$(tput lines 2>/dev/null) || height=24
    height=$((height - 10)); ((height > 3)) || height=3
    if [[ "$render_page" != "$page" || "$render_columns" != "$columns" || "$render_height" != "$height" ||
          "$render_search" != "$search" || "$render_filter" != "$filter" ]]; then
      rish_fw_table_page "$work" "$scope" "$search" "$filter" "$page" "$columns" "$((height>5 ? height-5 : 1))" "${work_dir}/page" || return 1
      render_page=$RISH_FW_TABLE_PAGE; render_columns="$columns"; render_height="$height"
      render_search="$search"; render_filter="$filter"
    fi
    page=$RISH_FW_TABLE_PAGE; count=${#RISH_FW_TABLE_ROWS[@]}; default=0
    for ((i=0; i<count; i++)); do
      IFS=$'\t' read -r kind id name net zones rest <<<"${RISH_FW_TABLE_ROWS[$i]}"
      key="${kind}/${id}/${net}"; [[ "$kind" != T ]] || key+="/${zones}"
      [[ "$key" != "$selected" ]] || default="$i"
    done
    clear
    rish_fw_field "Блокировки" "$title"
    printf 'Записей: %s%s%s' "$RISH_FW_GREEN" "$RISH_FW_TABLE_TOTAL" "$RISH_FW_RESET"
    if ((RISH_FW_TABLE_PAGES > 1)); then
      printf ' · страница %s%s/%s%s' "$RISH_FW_GREEN" "$((page+1))" "$RISH_FW_TABLE_PAGES" "$RISH_FW_RESET"
    fi
    printf '\n'
    [[ -z "$search" ]] || rish_fw_field "Поиск" "$search" "$RISH_FW_YELLOW"
    printf 'Enter или щелчок — действия над записью.\n\n    %s\n' "$RISH_FW_TABLE_HEADER"
    labels=("${RISH_FW_TABLE_LABELS[@]}" "Поиск"); actions=(search)
    if [[ "$scope" == all ]]; then labels+=("Фильтр"); actions+=(filter); fi
    if ((page > 0)); then labels+=("Предыдущая страница"); actions+=(prev); fi
    if ((page+1 < RISH_FW_TABLE_PAGES)); then labels+=("Следующая страница"); actions+=(next); fi
    labels+=("Назад"); actions+=(back)
    choice=0
    vertical_menu current_noclear 2 "$height" 30 "default=$default" "${labels[@]}" || choice=$?
    if ((choice < count)); then
      IFS=$'\t' read -r kind id name net zones rest <<<"${RISH_FW_TABLE_ROWS[$choice]}"
      selected="${kind}/${id}/${net}"; [[ "$kind" != T ]] || selected+="/${zones}"
      rish_fw_row_menu "${RISH_FW_TABLE_ROWS[$choice]}"
      if [[ -f "$RISH_FW_UI_CHANGED_FILE" ]]; then
        refresh=1
        [[ -z "$parent_changed_file" ]] || : >"$parent_changed_file" || return 1
        rm -f -- "$RISH_FW_UI_CHANGED_FILE"
      fi
    else
      case "${actions[$((choice-count))]:-back}" in
        search) read -r -p "Поиск по IP, подсети или названию (пусто — все): " search; page=0; selected="" ;;
        filter)
          choice=0; vertical_menu current 2 0 25 "Все" "Постоянные" "Временные" "Отмена" || choice=$?
          case "$choice" in 0) filter=all;; 1) filter=P;; 2) filter=T;; esac
          page=0; selected="" ;;
        prev) page=$((page-1)); selected="" ;;
        next) page=$((page+1)); selected="" ;;
        *) return 0 ;;
      esac
    fi
  done
)


rish_fw_ip_lookup_actions() (
  local metadata address="" prefix="" choice=0 result=0
  local -a labels=("Назад") targets=("")
  metadata=$(mktemp) || return 1
  trap 'rm -f -- "$metadata"' EXIT
  rish_fw_ip_lookup "$1" "$metadata"
  {
    IFS= read -r address
    IFS= read -r prefix
  } <"$metadata"
  if [[ -n "$address" ]]; then
    labels+=("Заблокировать $address"); targets+=("$address")
  fi
  if [[ -n "$prefix" ]]; then
    labels+=("Заблокировать $prefix"); targets+=("$prefix")
  fi
  printf '\n'
  vertical_menu current 2 0 38 default=0 "${labels[@]}" || choice=$?
  ((choice > 0 && choice < ${#targets[@]})) || return 0
  rish_fw_block_menu "${targets[$choice]}" || result=$?
  [[ "$result" != 2 ]] || return 0
  rish_fw_pause
  return "$result"
)

rish_fw_ip_lookup_menu() {
  local address
  read -r -p "IP-адрес или подсеть (Enter — назад): " address || return 0
  [[ -n "${address//[[:space:]]/}" ]] || return 0
  printf '\n'
  rish_fw_ip_lookup_actions "$address"
}

rish_fw_ports_menu() {
  local choice=0 value kind action mode label values info_rc action_label kind_label result
  printf '\n'
  rish_fw_field "Зона" "$RISH_FW_ZONE"
  for mode in runtime permanent; do
    local -a flag=()
    label="активные"; [[ "$mode" != permanent ]] || { flag=(--permanent); label="постоянные"; }
    values=$(rish_fw_cmd "${flag[@]}" --zone="$RISH_FW_ZONE" --list-all); info_rc=$?
    rish_fw_zone_fields "$values"
    if [[ "$info_rc" == 0 && "$RISH_FW_ZONE_FIELDS" == *' services '* ]]; then
      rish_fw_field "Службы — ${label}" "${RISH_FW_ZONE_SERVICES:-нет}"
    else
      rish_fw_field "Службы — ${label}" "не удалось прочитать" "$RISH_FW_YELLOW"
    fi
    if [[ "$info_rc" == 0 && "$RISH_FW_ZONE_FIELDS" == *' ports '* ]]; then
      rish_fw_field "Порты — ${label}" "${RISH_FW_ZONE_PORTS:-нет}"
    else
      rish_fw_field "Порты — ${label}" "не удалось прочитать" "$RISH_FW_YELLOW"
    fi
  done
  vertical_menu current 2 0 38 default=4 "Открыть порт/диапазон" "Закрыть порт/диапазон" "Открыть службу" "Закрыть службу" "Назад" || choice=$?
  case "$choice" in 0) kind=port; action=add;; 1) kind=port; action=remove;; 2) kind=service; action=add;; 3) kind=service; action=remove;; *) return 0;; esac
  if [[ "$kind" == port ]]; then read -r -p "Порт/диапазон и протокол, например 443/tcp: " value; else read -r -p "Имя службы firewalld: " value; fi
  action_label="открыть доступ"; [[ "$action" != remove ]] || action_label="закрыть доступ"
  kind_label="Порт/диапазон"; [[ "$kind" != service ]] || kind_label="Служба"
  printf '\n'
  rish_fw_field "Зона" "$RISH_FW_ZONE"
  rish_fw_field "$kind_label" "$value"
  rish_fw_field "Действие" "$action_label" "$RISH_FW_YELLOW"
  printf 'Изменение применится сразу и сохранится после перезагрузки.\n'
  rish_fw_confirm "Применить изменение?" || return 0
  rish_fw_endpoint_change "$kind" "$value" "$action"
  result=$?
  rish_fw_pause
  return "$result"
}

# MC context is optional. Do not source site helpers: reading logs needs no credentials.
rish_fw_site_context() {
  local result
  RISH_FW_SITE_NAME=""; RISH_FW_SITE_LOG=""
  result=$(python3 - "$1" "$2" "${RISH_FIREWALL_TEST_MODE:-0}" "${RISH_FIREWALL_WWW_ROOT:-}" "${RISH_FIREWALL_VHOST_DIR:-}" <<'PY'
import os, re, sys
directory, site, testing, test_root, test_vhosts = sys.argv[1:]
root = os.path.realpath(test_root if testing == '1' and test_root else '/var/www')
vhosts = os.path.realpath(test_vhosts if testing == '1' and test_vhosts else '/etc/httpd/conf.d')
try:
    if len(site) > 253 or not re.fullmatch(r'([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?', site):
        raise ValueError()
    directory = os.path.abspath(directory)
    relative = os.path.relpath(os.path.realpath(directory), root).split(os.sep)
    if len(relative) != 2 or relative[1] != 'www' or not re.fullmatch(r'[A-Za-z0-9_-]+', relative[0]):
        raise ValueError()
    user = relative[0]
    parent = os.path.join(root, user, 'www')
    selected = os.path.join(parent, site)
    if not os.path.isdir(selected) or os.path.realpath(selected) != selected:
        raise ValueError()
    conf = os.path.join(vhosts, site + '.conf')
    if not os.path.isfile(conf) or os.path.islink(conf):
        raise ValueError()
    with open(conf, encoding='utf-8') as handle:
        content = handle.read()
    documents = re.findall(r'^\s*DocumentRoot\s+(?:"([^"]+)"|(\S+))\s*$', content, re.MULTILINE | re.IGNORECASE)
    if not documents:
        raise ValueError()
    for quoted, plain in documents:
        document = os.path.realpath(quoted or plain)
        if not os.path.isdir(document) or not (document == selected or document.startswith(selected + os.sep)):
            raise ValueError()
    log = os.path.join(root, user, 'logs', site + '-access-log')
    if os.path.realpath(log) != log:
        raise ValueError()
    print(site)
    print(log)
except (OSError, ValueError, UnicodeError):
    sys.exit(1)
PY
  ) || return 1
  { IFS= read -r RISH_FW_SITE_NAME; IFS= read -r RISH_FW_SITE_LOG; } <<<"$result"
}

# Read a fixed tail snapshot, not the whole log. Bound bytes as well as line count.
rish_fw_access_stats() (
  local work
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_whitelist_read "$work/whitelist" || return 1
  python3 - "$@" "$work/whitelist" <<'PY'
import bisect, collections, datetime, ipaddress, json, os, re, stat, sys, unicodedata
path, site, lines, top, output, whitelist_path = sys.argv[1:]
with open(whitelist_path, encoding='utf-8') as handle:
    whitelist = [str(ipaddress.ip_network(line.strip())) for line in handle if line.strip()]
protected = {}
for family in (4, 6):
    networks = ipaddress.collapse_addresses(ipaddress.ip_network(value) for value in whitelist
                                          if ipaddress.ip_network(value).version == family)
    pairs = [(int(net.network_address), int(net.broadcast_address)) for net in networks]
    protected[family] = ([pair[0] for pair in pairs], [pair[1] for pair in pairs])
def excluded_address(value):
    ip = ipaddress.ip_address(value)
    starts, ends = protected[ip.version]
    index = bisect.bisect_right(starts, int(ip)) - 1
    return index >= 0 and int(ip) <= ends[index]
def clean(value, limit=512):
    return ' '.join(''.join(' ' if unicodedata.category(c).startswith('C') else c for c in value).split())[:limit]
quoted = rb'"((?:[^"\\]|\\.)*)"'
pattern = re.compile(rb'^(\S+)\s+\S+\s+\S+\s+\[([^\]]+)\]\s+' + quoted + rb'\s+([1-5][0-9]{2})\s+(?:[0-9]+|-)\s+' + quoted + rb'\s+' + quoted + rb'\s*$')
months = {name: number for number, name in enumerate(('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'), 1)}
def timestamp(value):
    match = re.fullmatch(r'(\d{2})/([A-Za-z]{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2}) ([+-])(\d{2})(\d{2})', value)
    if not match:
        raise ValueError()
    day, month, year, hour, minute, second, sign, offset_hour, offset_minute = match.groups()
    if int(offset_hour) > 23 or int(offset_minute) > 59:
        raise ValueError()
    offset = datetime.timedelta(hours=int(offset_hour), minutes=int(offset_minute))
    zone = datetime.timezone(offset if sign == '+' else -offset)
    return datetime.datetime(int(year), months[month], int(day), int(hour), int(minute), int(second), tzinfo=zone)
def text(value):
    def replace(match):
        if match.group(1):
            return bytes([int(match.group(1), 16)])
        char = match.group(2)
        return {b'n': b'\n', b'r': b'\r', b't': b'\t', b'b': b'\b', b'v': b'\v'}.get(char, char)
    return re.sub(rb'\\(?:x([0-9a-fA-F]{2})|(.))', replace, value).decode('utf-8', 'replace')
def parse(line):
    if len(line) > 65536:
        return None
    match = pattern.fullmatch(line)
    if not match:
        return None
    raw_ip, date, request, status, referer, agent = match.groups()
    try:
        raw_ip = raw_ip.decode('ascii')
        if '%' in raw_ip:
            return None
        address = ipaddress.ip_address(raw_ip)
        if address.version == 6 and address.ipv4_mapped:
            address = address.ipv4_mapped
        address = str(address)
        label = date.decode('ascii')
        moment = timestamp(label)
    except (ValueError, KeyError, UnicodeError):
        return None
    return address, label, moment, int(status), request, agent
try:
    lines, top = int(lines), int(top)
    if not 1 <= lines <= 200000 or not 1 <= top <= 200:
        raise ValueError('число строк должно быть 1–200000, число IP — 1–200')
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0))
    with os.fdopen(fd, 'rb') as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('требуется обычный файл access-log')
        position, size = info.st_size, info.st_size
        chunks, newline_count, received = [], 0, 0
        byte_limit = 32 * 1024 * 1024
        while position > 0 and newline_count < lines + 2 and received < byte_limit:
            length = min(65536, position, byte_limit - received)
            position -= length
            handle.seek(position)
            chunk = handle.read(length)
            if len(chunk) != length:
                raise ValueError('лог изменился во время чтения; повторите анализ')
            chunks.append(chunk)
            newline_count += chunk.count(b'\n')
            received += length
        if os.fstat(handle.fileno()).st_size < size:
            raise ValueError('лог уменьшился во время чтения; повторите анализ')
    data = b''.join(reversed(chunks))
    del chunks
    selected = data.split(b'\n')
    del data
    if position > 0:
        selected = selected[1:]  # The first fragment can start in the middle of a line.
    selected = selected[:-1][-lines:]  # Ignore the final, possibly incomplete request.
    counts, errors4, errors5 = collections.Counter(), collections.Counter(), collections.Counter()
    parsed, excluded, invalid = 0, 0, 0
    start, end, start_label, end_label = None, None, '', ''
    for line in selected:
        record = parse(line)
        if record is None:
            invalid += 1
            continue
        address, label, moment, status, request, agent = record
        if excluded_address(address):
            excluded += 1
            continue
        parsed += 1
        counts[address] += 1
        errors4[address] += int(400 <= status < 500)
        errors5[address] += int(500 <= status < 600)
        if start is None or moment < start:
            start, start_label = moment, label
        if end is None or moment > end:
            end, end_label = moment, label
    addresses = sorted(counts, key=lambda ip: (-counts[ip], ipaddress.ip_address(ip).version, int(ipaddress.ip_address(ip))))[:top]
    urls = {ip: collections.Counter() for ip in addresses}
    agents = {ip: collections.Counter() for ip in addresses}
    for line in selected:
        record = parse(line)
        if record is None or record[0] not in urls:
            continue
        address, label, moment, status, request, agent = record
        parts = text(request).split(' ', 2)
        target = parts[1] if len(parts) >= 2 else text(request)
        urls[address][clean(target)] += 1
        agents[address][clean(text(agent))] += 1
    rows = [{'ip': ip, 'requests': counts[ip], 'share': round(100.0 * counts[ip] / parsed, 2),
             'errors4': errors4[ip], 'errors5': errors5[ip],
             'urls': urls[ip].most_common(5), 'agents': agents[ip].most_common(5)} for ip in addresses]
    result = {'site': site, 'log': path, 'requested_lines': lines, 'top': top,
              'lines': len(selected), 'parsed': parsed, 'skipped': invalid, 'excluded': excluded,
              'whitelist': whitelist,
              'unique': len(counts), 'period_start': start_label, 'period_end': end_label,
              'byte_limited': position > 0 and received >= byte_limit and newline_count < lines + 2, 'rows': rows}
    with open(output, 'w', encoding='utf-8') as handle:
        json.dump(result, handle, ensure_ascii=False)
except (OSError, ValueError, UnicodeError) as error:
    print('Не удалось прочитать access-log: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
)

rish_fw_access_export() (
  local work
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  rish_fw_whitelist_read "$work/whitelist" || return 1
  python3 - "$1" "$2" "${3:-/root}" "${RISH_FIREWALL_TEST_MODE:-0}" "$work/whitelist" <<'PY'
import datetime, ipaddress, json, os, re, stat, sys, tempfile, unicodedata
source, ownership, directory, testing, whitelist_path = sys.argv[1:]
def clean(value):
    if not isinstance(value, str):
        return ''
    return ' '.join(''.join(' ' if unicodedata.category(c).startswith('C') else c for c in value).split())[:240]
path = None
try:
    if testing != '1' and directory != '/root':
        raise ValueError('экспорт разрешён только в /root')
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
        raise ValueError('каталог экспорта должен принадлежать текущему пользователю и быть защищён от записи другими')
    with open(source, encoding='utf-8') as handle:
        stats = json.load(handle)
    with open(ownership, encoding='utf-8') as handle:
        owners = json.load(handle)
    with open(whitelist_path, encoding='utf-8') as handle:
        whitelist = [str(ipaddress.ip_network(line.strip())) for line in handle if line.strip()]
    if stats.get('whitelist', []) != whitelist:
        raise ValueError('белый список изменился; обновите анализ перед экспортом')
    site = stats['site']
    if len(site) > 253 or not re.fullmatch(r'([a-z0-9-]+\.)+[a-z0-9-]+', site):
        raise ValueError('неверное имя сайта')
    content = ['# Самые активные IP %s' % site, '# Лог: %s' % clean(stats['log']),
               '# Период: %s — %s' % (clean(stats['period_start']), clean(stats['period_end'])),
               '# Прочитано строк: %s; учтено: %s; не распознано: %s; исключено белым списком: %s' %
               (stats['lines'], stats['parsed'], stats['skipped'], stats.get('excluded', 0)),
               '# Перед импортом удалите ненужные адреса или закомментируйте их знаком #.',
               '# Блокировка при импорте применяется в зонах выбранного списка.', '']
    count = 0
    for row in stats['rows']:
        ip = ipaddress.ip_address(row['ip'])
        item = owners.get(str(ip), {})
        comment = 'запросов=%d; доля=%.2f%%; 4xx=%d; 5xx=%d; %s; %s; %s' % (
            row['requests'], row['share'], row['errors4'], row['errors5'],
            clean(item.get('organization') or item.get('name')) or 'нет данных о сети',
            clean(item.get('asn')) or 'ASN неизвестен', clean(item.get('country')) or 'страна неизвестна')
        forbidden = ip.is_unspecified or ip in ipaddress.ip_network('127.0.0.0/8' if ip.version == 4 else '::1/128')
        content.append(('# ' if forbidden else '') + str(ip) + ' # ' + comment + ('; запрещён текущим импортом' if forbidden else ''))
        count += int(not forbidden)
    if count == 0:
        raise ValueError('нет адресов, подходящих для импорта')
    # mkstemp never overwrites an existing report and creates the file with mode 0600.
    # A full domain can be 253 bytes; keep the filename below filesystem limits.
    prefix = 'ipset-%s-%s-' % (site[:120], datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    fd, path = tempfile.mkstemp(prefix=prefix, suffix='.txt', dir=directory)
    with os.fdopen(fd, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write('\n'.join(content) + '\n')
    print(path)
except (OSError, ValueError, TypeError, KeyError) as error:
    if path:
        os.unlink(path)
    print('Не удалось экспортировать IP: %s.' % error, file=sys.stderr)
    sys.exit(1)
PY
)


rish_fw_access_table() {
  local result line stage=0
  RISH_FW_ACCESS_LABELS=(); RISH_FW_ACCESS_IPS=()
  result=$(python3 - "$1" "$2" "$3" "$RISH_FW_GREEN" "$RISH_FW_YELLOW" "$RISH_FW_RESET" "${4:-}" "$RISH_FW_ZONE" <<'PY'
import bisect, datetime, ipaddress, json, sys
source, ownership, columns, green, yellow, reset, coverage, zone = sys.argv[1:]
with open(source, encoding='utf-8') as handle:
    stats = json.load(handle)
with open(ownership, encoding='utf-8') as handle:
    owners = json.load(handle)
try:
    with open(coverage, encoding='utf-8') as handle:
        bans = json.load(handle)
    if bans['zone'] != zone:
        raise ValueError('снимок другой зоны')
    ranges = {}
    for kind in ('runtime', 'permanent', 'temporary'):
        for family in ('4', '6'):
            starts, ends = [], []
            for pair in bans[kind][family]:
                if (len(pair) != 2 or any(type(value) is not int for value in pair) or
                        not 0 <= pair[0] <= pair[1] < 2 ** (32 if family == '4' else 128) or
                        ends and pair[0] <= ends[-1]):
                    raise ValueError('неверный диапазон блокировки')
                starts.append(pair[0]); ends.append(pair[1])
            ranges[(kind, family)] = (starts, ends)
except (OSError, ValueError, KeyError, TypeError, UnicodeError):
    ranges = None
def ban_status(address):
    if ranges is None:
        return '?'
    ip = ipaddress.ip_address(address)
    def covered(kind):
        starts, ends = ranges[(kind, str(ip.version))]
        index = bisect.bisect_right(starts, int(ip)) - 1
        return index >= 0 and int(ip) <= ends[index]
    if covered('runtime'):
        return 'пост.' if covered('permanent') else 'не сохр.'
    if covered('temporary'):
        return 'врем.'
    return '—'
columns = max(30, int(columns) - 9)
def clip(value, width):
    return value if len(value) <= width else value[:max(0, width - 1)] + '…'
ip_width = min(max([len('IP')] + [len(row['ip']) for row in stats['rows']]), max(15, columns // 3))
count_width = max([len('Запросов')] + [len(str(row['requests'])) for row in stats['rows']])
errors = columns >= 79
def render(ip, ban, requests, share, error, owner):
    left = '%-*s │ %*s │ %6s' % (ip_width, clip(ip, ip_width), count_width, requests, share)
    left = '%-8s │ ' % ban + left
    if errors:
        left += ' │ %9s' % error
    width = max(1, columns - len(left) - 3)
    return clip(left + ' │ ' + clip(owner, width), columns)
def value(number):
    return green + str(number) + reset
def period():
    if not stats['period_start'] or not stats['period_end']:
        return 'нет запросов'
    months = {name: number for number, name in enumerate(('Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'), 1)}
    def moment(stamp):
        day, month, rest = stamp.split('/', 2)
        return datetime.datetime.strptime('%s/%s/%s' % (day, months[month], rest), '%d/%m/%Y:%H:%M:%S %z')
    first, last = moment(stats['period_start']), moment(stats['period_end'])
    last = last.astimezone(first.tzinfo)
    if first == last:
        return first.strftime('%d.%m.%Y %H:%M:%S')
    if first.date() == last.date():
        return first.strftime('%d.%m.%Y %H:%M:%S') + '–' + last.strftime('%H:%M:%S')
    return first.strftime('%d.%m.%Y %H:%M:%S') + ' — ' + last.strftime('%d.%m.%Y %H:%M:%S')
print('Строк: %s из %s · учтено: %s · не распознано: %s · белый список: %s' % tuple(
    value(stats.get(key, 0)) for key in ('lines', 'requested_lines', 'parsed', 'skipped', 'excluded')))
print('Уникальных IP: %s · показано: %s из %s%s' % (
    value(stats['unique']), value(len(stats['rows'])), value(stats.get('top', 20)),
    ' · достигнут предел ' + yellow + '32 МиБ' + reset if stats['byte_limited'] else ''))
print(period())
print(render('IP', 'Бан', 'Запросов', 'Доля', '4xx/5xx', 'Сеть / ASN / страна'))
for row in stats['rows']:
    item = owners.get(row['ip'], {})
    owner = ' / '.join(value for value in (item.get('organization') or item.get('name') or 'нет данных', item.get('asn'), item.get('country')) if value)
    print(render(row['ip'], ban_status(row['ip']), row['requests'], '%.1f%%' % row['share'], '%s/%s' % (row['errors4'], row['errors5']), owner) + '\t' + row['ip'])
PY
  ) || return 1
  while IFS= read -r line; do
    case "$stage" in
      0) RISH_FW_ACCESS_SUMMARY="$line" ;;
      1) RISH_FW_ACCESS_COUNTS="$line" ;;
      2) RISH_FW_ACCESS_PERIOD="$line" ;;
      3) RISH_FW_ACCESS_HEADER="$line" ;;
      *) RISH_FW_ACCESS_LABELS+=("${line%%$'\t'*}"); RISH_FW_ACCESS_IPS+=("${line#*$'\t'}") ;;
    esac
    stage=$((stage+1))
  done <<<"$result"
}

rish_fw_access_prefix() {
  python3 - "$1" "$2" <<'PY'
import ipaddress, json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        owners = json.load(handle)
    address = ipaddress.ip_address(sys.argv[2])
    prefix = owners.get(str(address), {}).get('prefix', '')
    if not isinstance(prefix, str) or '%' in prefix:
        sys.exit(1)
    network = ipaddress.ip_network(prefix, strict=False)
    loopback = ipaddress.ip_network('127.0.0.0/8' if network.version == 4 else '::1/128')
    if (network.version != address.version or address not in network or
            not 0 < network.prefixlen < address.max_prefixlen or
            network.network_address.is_unspecified or network.overlaps(loopback)):
        sys.exit(1)
    print(network)
except (OSError, ValueError, TypeError, AttributeError):
    sys.exit(1)
PY
}

rish_fw_access_details() {
  python3 - "$1" "$2" "$3" "$RISH_FW_GREEN" "$RISH_FW_YELLOW" "$RISH_FW_RESET" <<'PY'
import json, sys
source, ownership, address, green, yellow, reset = sys.argv[1:]
with open(source, encoding='utf-8') as handle:
    stats = json.load(handle)
with open(ownership, encoding='utf-8') as handle:
    owners = json.load(handle)
row = next(row for row in stats['rows'] if row['ip'] == address)
item = owners.get(address, {})
def value(text, available=True):
    return '%s%s%s' % (green if available else yellow, text, reset)
def field(label, text, available=True):
    print('%s: %s' % (label, value(text, available)))
field('IP', address)
print('Запросов: %s (%s)\nОшибки: 4xx=%s; 5xx=%s' % (
    value(row['requests']), value('%.2f%%' % row['share']), value(row['errors4']), value(row['errors5'])))
for label, key in (('Организация', 'organization'), ('Название сети', 'name'), ('Страна регистрации', 'country'), ('ASN', 'asn'), ('Анонсируемая сеть', 'prefix')):
    field(label, item.get(key) or 'нет данных', bool(item.get(key)))
status = item.get('status')
if status in ('ok', 'partial'):
    print('Источник: %s / %s%s' % (value('RIPEstat'), value('RIPE Database'),
        ' (%s)' % value('частичные сведения', False) if status == 'partial' else ''))
elif status == 'special':
    print('%s; внешний запрос не выполнялся.' % value('Локальный или специальный адрес', False))
else:
    print('Сведения о сети не получены: %s или %s.' % (
        value('справочник недоступен', False), value('истёк общий срок ожидания', False)))
for label, key in (('Частые URL', 'urls'), ('Частые User-Agent (как записаны в логе)', 'agents')):
    print('\n%s:' % label)
    for text, count in row[key]:
        print('  %s × %s' % (value(count), value(text)))
PY
}

rish_fw_access_menu() (
  local work lines=20000 top=20 refresh=1 bans_refresh=1 columns height choice count new_lines new_top exported export_dir=/root
  local address prefix detail_choice result
  local -a detail_labels=() detail_targets=()
  [[ -n "$RISH_FW_SITE_NAME" && -n "$RISH_FW_SITE_LOG" ]] || return 1
  work=$(mktemp -d) || return 1
  trap 'rm -rf -- "$work"' EXIT
  if [[ "${RISH_FIREWALL_TEST_MODE:-0}" == 1 ]]; then export_dir="${RISH_FIREWALL_IMPORT_DIR:-/root}"; fi
  while true; do
    rish_fw_whitelist_read "${work}/whitelist-current" || { rish_fw_pause; return 1; }
    if [[ ! -f "${work}/whitelist-used" ]] || ! cmp -s -- "${work}/whitelist-current" "${work}/whitelist-used"; then
      refresh=1
    fi
    if [[ "$refresh" == 1 ]]; then
      clear
      rish_fw_field "Самые активные IP" "$RISH_FW_SITE_NAME"
      printf 'Читаю последние %s%s%s строк; определяю сети для %s%s%s IP…\n' \
        "$RISH_FW_GREEN" "$lines" "$RISH_FW_RESET" "$RISH_FW_GREEN" "$top" "$RISH_FW_RESET"
      RISH_FW_WHITELIST_SOURCE="${work}/whitelist-current" rish_fw_access_stats "$RISH_FW_SITE_LOG" "$RISH_FW_SITE_NAME" "$lines" "$top" "${work}/stats.json" || { rish_fw_pause; return 1; }
      cp -- "${work}/whitelist-current" "${work}/whitelist-used" || return 1
      rish_fw_ip_lookups "${work}/stats.json" "${work}/owners.json" "${work}/cache.json" || printf '{}\n' >"${work}/owners.json"
      refresh=0; bans_refresh=1
    fi
    if [[ "$bans_refresh" == 1 ]]; then
      # Never keep a previous positive/negative result after a failed refresh.
      rm -f -- "${work}/bans.json"
      if ! rish_fw_collect_blocks "${work}/blocks" "" "${work}/bans.json"; then
        rm -f -- "${work}/bans.json"
      fi
      bans_refresh=0
    fi
    columns=$(tput cols 2>/dev/null) || columns=80
    height=$(tput lines 2>/dev/null) || height=24
    height=$((height-15)); ((height > 3)) || height=3
    rish_fw_access_table "${work}/stats.json" "${work}/owners.json" "$columns" "${work}/bans.json" || return 1
    count=${#RISH_FW_ACCESS_IPS[@]}
    clear
    rish_fw_field "Самые активные IP" "$RISH_FW_SITE_NAME"
    rish_fw_field "Текущий лог" "$RISH_FW_SITE_LOG"
    printf '%s\n%s\n' "$RISH_FW_ACCESS_SUMMARY" "$RISH_FW_ACCESS_COUNTS"
    if ((count > 0)); then rish_fw_field "Период" "$RISH_FW_ACCESS_PERIOD";
    else rish_fw_field "Период" "$RISH_FW_ACCESS_PERIOD" "$RISH_FW_YELLOW"; fi
    printf 'Enter — полные сведения, URL и User-Agent.\n'
    printf 'Бан RISH в зоне %s%s%s: пост. / врем. / не сохр.\n' "$RISH_FW_GREEN" "$RISH_FW_ZONE" "$RISH_FW_RESET"
    printf 'не сохр. — действует, но не сохранён; — нет; ? неизвестно.\n'
    printf 'Частота запросов сама по себе не доказывает атаку.\n\n    %s\n' "$RISH_FW_ACCESS_HEADER"
    choice=0
    vertical_menu current_noclear 2 "$height" 30 "default=$((count > 0 ? 0 : 3))" "${RISH_FW_ACCESS_LABELS[@]}" "Экспортировать показанные IP" "Изменить число строк / IP" "Обновить" "Назад" || choice=$?
    # A menu can remain open while another session changes the whitelist.
    rish_fw_whitelist_read "${work}/whitelist-current" || { rish_fw_pause; return 1; }
    if ! cmp -s -- "${work}/whitelist-current" "${work}/whitelist-used"; then
      refresh=1
      continue
    fi
    if ((choice < count)); then
      address="${RISH_FW_ACCESS_IPS[$choice]}"
      clear
      rish_fw_access_details "${work}/stats.json" "${work}/owners.json" "$address"
      detail_labels=("Назад" "Заблокировать $address")
      detail_targets=("" "$address")
      prefix=$(rish_fw_access_prefix "${work}/owners.json" "$address") || prefix=""
      if [[ -n "$prefix" ]]; then
        detail_labels+=("Заблокировать подсеть $prefix"); detail_targets+=("$prefix")
      fi
      detail_choice=0
      vertical_menu current 2 0 25 nomouse default=0 "${detail_labels[@]}" || detail_choice=$?
      if ((detail_choice > 0 && detail_choice < ${#detail_targets[@]})); then
        result=0
        rish_fw_block_menu "${detail_targets[$detail_choice]}" || result=$?
        bans_refresh=1
        if [[ "$result" != 2 ]]; then vertical_menu current 2 0 25 nomouse "Нажмите Enter"; fi
      fi
    else
      case "$((choice-count))" in
        0)
          if exported=$(rish_fw_access_export "${work}/stats.json" "${work}/owners.json" "$export_dir"); then
            rish_fw_field "Файл экспорта" "$exported"
            printf 'Отредактируйте файл и выберите «Импорт списка» в меню Firewall.\n'
          fi
          rish_fw_pause ;;
        1)
          read -r -p "Последних строк (1–200000, Enter — ${RISH_FW_GREEN}${lines}${RISH_FW_RESET}): " new_lines || return 0
          read -r -p "Показать IP (1–200, Enter — ${RISH_FW_GREEN}${top}${RISH_FW_RESET}): " new_top || return 0
          new_lines="${new_lines:-$lines}"; new_top="${new_top:-$top}"
          if [[ "$new_lines" =~ ^[0-9]{1,6}$ && "$new_top" =~ ^[0-9]{1,3}$ ]] &&
              ((10#$new_lines >= 1 && 10#$new_lines <= 200000 && 10#$new_top >= 1 && 10#$new_top <= 200)); then
            lines=$((10#$new_lines)); top=$((10#$new_top)); refresh=1
          else rish_fw_error "Требуются числа: строки 1–200000, IP 1–200."; rish_fw_pause; fi ;;
        2) refresh=1 ;;
        *) return 0 ;;
      esac
    fi
  done
)

rish_fw_menu() {
  local choice columns width menu_width site_label i server_lock_state
  local -a labels=() actions=()
  if ! declare -F vertical_menu >/dev/null 2>&1; then
    source "${RISH_FIREWALL_HOME}/windows.sh" || return 1
  fi
  while true; do
    clear
    rish_fw_header
    server_lock_state="$RISH_FW_SERVER_LOCK_STATE"
    columns=$(tput cols 2>/dev/null) || columns=80
    [[ "$columns" =~ ^[0-9]{1,5}$ ]] || columns=80
    width=$((columns-9)); ((width >= 1)) || width=1
    menu_width=46; ((menu_width <= width)) || menu_width="$width"
    labels=("Заблокировать адрес / подсеть" "Списки блокировок" "Импорт списка" "Редактирование белого списка" "Добавить свой IP в белый список" "Порты и службы" "Проверить IP")
    actions=(block lists import whitelist whitelist-peer ports lookup)
    case "$RISH_FW_SERVER_LOCK_STATE" in
      off) labels+=("Блокировка сервера кроме моего IP и белого списка") ;;
      active) labels+=("Снять блокировку сервера") ;;
      *) labels+=("Проверить состояние блокировки сервера") ;;
    esac
    actions+=(server-lock)
    if [[ -n "$RISH_FW_SITE_NAME" ]]; then
      site_label="Самые активные IP ${RISH_FW_SITE_NAME}"
      if ((${#site_label} > width)); then rish_fw_field "Сайт" "$RISH_FW_SITE_NAME"; fi
      labels+=("$site_label"); actions+=(access)
    fi
    labels+=("Проверить конфигурацию" "Выйти"); actions+=(check back)
    for ((i=0; i<${#labels[@]}; i++)); do
      if ((${#labels[i]} > width)); then labels[i]="${labels[i]:0:$((width-1))}…"; fi
    done
    choice=0
    vertical_menu current 2 0 "$menu_width" "default=$((${#labels[@]}-1))" "${labels[@]}" || choice=$?
    case "${actions[$choice]:-back}" in
      block) rish_fw_block_menu ;;
      lists) rish_fw_lists_menu && continue ;;
      import) rish_fw_import_menu ;;
      whitelist) rish_fw_whitelist_edit ;;
      whitelist-peer) rish_fw_whitelist_add_peer ;;
      ports) rish_fw_ports_menu; continue ;;
      server-lock)
        rish_fw_server_lock_menu "$server_lock_state"
        vertical_menu current 2 0 25 nomouse "Нажмите Enter"
        continue ;;
      lookup) rish_fw_ip_lookup_menu; continue ;;
      access) rish_fw_access_menu; continue ;;
      check) rish_fw_check_config ;;
      *) return 0 ;;
    esac
    vertical_menu current 2 0 25 "Нажмите Enter"
  done
}

rish_fw_main() {
  local action="${1:-menu}"
  RISH_FW_SITE_NAME=""; RISH_FW_SITE_LOG=""
  case "$action" in
    -h|--help) printf 'Использование: bash %s [menu|status|check-config|menu-from-mc <каталог> <сайт>]\n' "$0"; return 0 ;;
    --status) action=status ;;
    --check-config) action=check-config ;;
    menu-from-mc) rish_fw_site_context "${2:-}" "${3:-}" || true; action=menu ;;
    menu|status|check-config) ;;
    *) rish_fw_error "Неизвестная команда ${action}."; return 2 ;;
  esac
  rish_fw_require || return 1
  RISH_FW_ZONE=$(rish_fw_cmd --get-default-zone 2>/dev/null) || RISH_FW_ZONE=""
  case "$action" in
    status) rish_fw_status ;;
    check-config) rish_fw_check_config ;;
    menu) rish_fw_menu ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rish_fw_main "$@"
fi
