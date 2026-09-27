#!/usr/bin/env bash

# OS resolver settings. Domain DNS/API management lives in scripts/dns/.
EDNS_STATE_DIR="/var/lib/rish/external-dns"
EDNS_LOCK_FILE="/run/lock/rish-external-dns.lock"
EDNS_RESOLV_CONF="/etc/resolv.conf"
EDNS_MSK="9.9.9.9 62.76.76.62 62.76.62.76"
EDNS_YANDEX="9.9.9.9 77.88.8.8 77.88.8.1"
EDNS_GREEN=$'\033[0;32m'
EDNS_YELLOW=$'\033[0;33m'
EDNS_RED=$'\033[0;31m'
EDNS_RESET=$'\033[0m'

edns_error() { printf '%sОшибка:%s %s\n' "$EDNS_RED" "$EDNS_RESET" "$*" >&2; }
edns_nmcli() { LC_ALL=C timeout 12 nmcli --wait 8 --escape no "$@"; }

edns_normalize() {
  # nmcli uses commas, pipes or newlines between DNS addresses.
  printf '%s\n' "$*" | awk 'BEGIN { RS="[ ,|\n\t]+" }
    NF && !seen[$0]++ { printf "%s%s", sep, $0; sep=" " }'
}

edns_ipv4_list_valid() {
  local address octet
  local -a octets
  for address in $1; do
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
      [[ ${#octet} -le 3 ]] && ((10#$octet <= 255)) || return 1
    done
  done
}

edns_known_name() {
  case "$1" in
    9.9.9.9|149.112.112.112) printf 'Quad9' ;;
    62.76.76.62|62.76.62.76) printf 'MSK-IX' ;;
    77.88.8.8|77.88.8.1) printf 'Яндекс DNS (базовый)' ;;
    127.*|::1) printf 'DNS на этом сервере' ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) printf 'DNS локальной сети' ;;
    *) printf 'название DNS-службы неизвестно' ;;
  esac
}

edns_profile_dns() {
  local value
  value=$(edns_nmcli -g ipv4.dns connection show uuid "$EDNS_UUID") || return 1
  edns_normalize "$value"
}

edns_applied_dns() {
  local path reply encoded kind values number dns="" byte_order
  path=$(edns_nmcli -g GENERAL.DBUS-PATH device show "$EDNS_DEVICE") || return 1
  [[ "$path" =~ ^/org/freedesktop/NetworkManager/Devices/[0-9]+$ ]] || return 1
  reply=$(LC_ALL=C timeout 8 busctl --system --verbose --timeout=5 call \
    org.freedesktop.NetworkManager "$path" \
    org.freedesktop.NetworkManager.Device GetAppliedConnection u 0) || return 1
  # busctl --verbose also works with systemd 239 (AlmaLinux 8), which lacks
  # --json. Inspect typed fields at their nesting depth, never evaluate text.
  encoded=$(awk -v uuid="$EDNS_UUID" '
    function string_value(line) {
      sub(/^[[:space:]]*STRING "/, "", line); sub(/";$/, "", line); return line
    }
    /^[[:space:]]*};$/ {depth--; next}
    /{$/ {
      if ($1 == "MESSAGE" && $2 == "\"a{sa{sv}}t\"") message=1
      if (section == "ipv4" && depth == 5 && $1 == "VARIANT") {
        if (key == "dns" || key == "dns-data") {
          if ((key == "dns" && $2 != "\"au\"") ||
              (key == "dns-data" && $2 != "\"as\"")) bad=1
          types[key]=1
        }
      }
      depth++; next
    }
    $1 == "STRING" && depth == 3 {
      section=string_value($0); key=""
      if (section == "ipv4") ipv4=1
      next
    }
    $1 == "STRING" && depth == 5 {key=string_value($0); next}
    section == "connection" && key == "uuid" && depth == 6 && $1 == "STRING" {
      if (string_value($0) == uuid) same_uuid=1
    }
    section == "ipv4" && depth == 7 {
      if (key == "dns" && $1 == "UINT32") {
        value=$2; sub(/;$/, "", value); values[key]=values[key] " " value
      }
      if (key == "dns-data" && $1 == "STRING") values[key]=values[key] " " string_value($0)
    }
    END {
      if (!message || !same_uuid || !ipv4 || depth != 0 || bad) exit 1
      if ("dns-data" in types) print "as:" values["dns-data"]
      else print "au:" values["dns"]
    }
  ' <<< "$reply") || return 1
  kind=${encoded%%:*}
  values=${encoded#*:}
  if [[ "$kind" == as ]]; then
    dns=$(edns_normalize "$values")
    edns_ipv4_list_valid "$dns" || return 1
  else
    # The legacy au property stores IPv4 in native integers containing bytes
    # in network order. Detect host endianness rather than assuming x86.
    byte_order=$(printf '\1\0\0\0' | od -An -tu4 | tr -d ' ') || return 1
    [[ "$byte_order" == 1 || "$byte_order" == 16777216 ]] || return 1
    for number in $values; do
      [[ "$number" =~ ^[0-9]{1,10}$ ]] && ((10#$number <= 4294967295)) || return 1
      number=$((10#$number))
      if [[ "$byte_order" == 1 ]]; then
        dns+=" $((number & 255)).$(((number >> 8) & 255)).$(((number >> 16) & 255)).$(((number >> 24) & 255))"
      else
        dns+=" $(((number >> 24) & 255)).$(((number >> 16) & 255)).$(((number >> 8) & 255)).$((number & 255))"
      fi
    done
  fi
  edns_normalize "$dns"
}

edns_lock() {
  [[ ! -L "$EDNS_LOCK_FILE" ]] || return 1
  exec 9>"$EDNS_LOCK_FILE" || return 1
  flock -n 9 || { edns_error "Сейчас другой процесс изменяет DNS. Повторите операцию позже."; return 1; }
}

edns_detect() {
  local route method managed
  route=$(ip -4 route get 1.1.1.1 2>/dev/null) || {
    edns_error "Не удалось определить основной IPv4-интерфейс."; return 1;
  }
  EDNS_DEVICE=$(awk '{for(i=1;i<NF;i++) if($i=="dev") {print $(i+1); exit}}' <<< "$route")
  [[ -n "$EDNS_DEVICE" ]] || return 1
  managed=$(edns_nmcli -g GENERAL.NM-MANAGED device show "$EDNS_DEVICE") || return 1
  EDNS_UUID=$(edns_nmcli -g GENERAL.CON-UUID device show "$EDNS_DEVICE") || return 1
  if [[ "$managed" != yes || ! "$EDNS_UUID" =~ ^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$ ]]; then
    edns_error "Для $EDNS_DEVICE не найден активный профиль NetworkManager."
    return 1
  fi
  method=$(edns_nmcli -g ipv4.method connection show uuid "$EDNS_UUID") || return 1
  case "$method" in
    auto|manual) ;;
    *) edns_error "Режим IPv4 $method не поддерживается этим меню."; return 1 ;;
  esac
  EDNS_DNS=$(edns_profile_dns) || return 1
  if ! edns_ipv4_list_valid "$EDNS_DNS"; then
    edns_error "Профиль содержит особый формат DNS. Измените его средствами NetworkManager."
    return 1
  fi
  EDNS_AUTO=$(edns_nmcli -g ipv4.ignore-auto-dns connection show uuid "$EDNS_UUID") || return 1
  EDNS_PROFILE=$(edns_nmcli -g connection.id connection show uuid "$EDNS_UUID") || return 1
  EDNS_BACKUP="$EDNS_STATE_DIR/$EDNS_UUID.json"
}

edns_same_connection() {
  local uuid
  uuid=$(edns_nmcli -g GENERAL.CON-UUID device show "$EDNS_DEVICE") || return 1
  [[ "$uuid" == "$EDNS_UUID" ]]
}

edns_read_backup() {
  [[ -f "$EDNS_BACKUP" && ! -L "$EDNS_BACKUP" ]] || return 1
  jq -e --arg uuid "$EDNS_UUID" '
    .version == 1 and .uuid == $uuid and (.dns | type == "string")
  ' "$EDNS_BACKUP" >/dev/null 2>&1 || return 1
  EDNS_ORIGINAL=$(jq -r '.dns' "$EDNS_BACKUP") || return 1
  edns_ipv4_list_valid "$EDNS_ORIGINAL"
}

edns_backup_date() {
  # Display only: a missing/invalid date must not prevent restoring old copies.
  jq -er '.created | fromdateiso8601 | strflocaltime("%d.%m.%Y %H:%M %Z")' \
    "$EDNS_BACKUP" 2>/dev/null || printf 'дата неизвестна'
}

edns_save_backup() {
  local temporary
  if [[ -e "$EDNS_BACKUP" || -L "$EDNS_BACKUP" ]]; then
    edns_read_backup || { edns_error "Исходная копия повреждена: $EDNS_BACKUP"; return 1; }
    return 0
  fi
  [[ ! -L "$EDNS_STATE_DIR" ]] || return 1
  mkdir -p -- "$EDNS_STATE_DIR" && chmod 700 "$EDNS_STATE_DIR" || return 1
  temporary=$(mktemp "$EDNS_STATE_DIR/.backup.XXXXXX") || return 1
  if jq -n --arg uuid "$EDNS_UUID" --arg profile "$EDNS_PROFILE" \
    --arg dns "$EDNS_DNS" --arg created "$(date -u +%FT%TZ)" \
    '{version:1, uuid:$uuid, profile:$profile, dns:$dns, created:$created}' > "$temporary" &&
    chmod 600 "$temporary" && mv -- "$temporary" "$EDNS_BACKUP"; then
    return 0
  fi
  rm -f -- "$temporary"
  edns_error "Не удалось сохранить исходные DNS. Настройки не изменены."
  return 1
}

edns_target() {
  local preset="$1" baseline="$2" current="$3" address extra=""
  # Keep original/manual addresses, but do not accumulate earlier presets.
  for address in $current; do
    case " $EDNS_MSK $EDNS_YANDEX " in
      *" $address "*) ;;
      *) extra+=" $address" ;;
    esac
  done
  edns_normalize "$preset $baseline $extra"
}

edns_show() {
  local value address
  printf 'Профиль: %s%s%s (%s%s%s)\n' \
    "$EDNS_GREEN" "$EDNS_PROFILE" "$EDNS_RESET" "$EDNS_GREEN" "$EDNS_DEVICE" "$EDNS_RESET"
  if [[ -n "$EDNS_DNS" ]]; then
    printf 'DNS в профиле:\n'
    for address in $EDNS_DNS; do
      printf '  %s%-15s%s — %s\n' "$EDNS_GREEN" "$address" "$EDNS_RESET" "$(edns_known_name "$address")"
    done
  else
    printf 'DNS в профиле: %sне заданы вручную%s\n' "$EDNS_GREEN" "$EDNS_RESET"
  fi
  if [[ "$EDNS_AUTO" == no ]]; then
    printf 'Автоматические DNS %sразрешены%s; их получение сохраняется.\n' "$EDNS_GREEN" "$EDNS_RESET"
  else
    printf 'Автоматические DNS %sотключены%s в профиле.\n' "$EDNS_YELLOW" "$EDNS_RESET"
  fi
  value=$(edns_nmcli -g IP4.DNS,IP6.DNS device show "$EDNS_DEVICE") || return 1
  printf '\nDNS подключения сейчас:\n'
  for address in $(edns_normalize "$value"); do
    printf '  %s%-15s%s — %s\n' "$EDNS_GREEN" "$address" "$EDNS_RESET" "$(edns_known_name "$address")"
  done
  if edns_read_backup; then
    printf '\nИсходные настройки сохранены: %s%s%s\n' "$EDNS_YELLOW" "$(edns_backup_date)" "$EDNS_RESET"
  fi
}

edns_probe() {
  local server="$1" output status elapsed
  output=$(LC_ALL=C timeout 5 dig "@$server" example.com. A \
    +time=2 +tries=1 +noall +comments +answer +stats 2>/dev/null) || {
    printf '%s%s%s: %sнет ответа%s за отведённое время или ошибка запроса\n' \
      "$EDNS_GREEN" "$server" "$EDNS_RESET" "$EDNS_RED" "$EDNS_RESET"; return 1;
  }
  status=$(sed -n 's/.*status: \([A-Z0-9]*\),.*/\1/p' <<< "$output" | head -n 1)
  elapsed=$(awk '/Query time:/ {print $4 " мс"; exit}' <<< "$output")
  if [[ "$status" == NOERROR ]] && awk '$4=="A" {found=1} END {exit !found}' <<< "$output"; then
    printf '%s%s%s: разрешение имени %sработает%s, %s%s%s\n' \
      "$EDNS_GREEN" "$server" "$EDNS_RESET" "$EDNS_GREEN" "$EDNS_RESET" \
      "$EDNS_YELLOW" "${elapsed:-время неизвестно}" "$EDNS_RESET"
    return 0
  fi
  printf '%s%s%s: ответ %s%s%s, адрес не получен\n' \
    "$EDNS_GREEN" "$server" "$EDNS_RESET" "$EDNS_RED" "${status:-не распознан}" "$EDNS_RESET"
  return 1
}

edns_system_resolves() {
  local output
  output=$(LC_ALL=C timeout 6 dig example.com. A +time=2 +tries=1 +noall +comments +answer 2>/dev/null) || return 1
  [[ "$output" == *"status: NOERROR,"* ]] || return 1
  awk '$4=="A" {found=1} END {exit !found}' <<< "$output" || return 1
  timeout 6 getent ahostsv4 example.com >/dev/null 2>&1
}

edns_resolver_has_preset() {
  local servers address
  if awk '$1=="nameserver" && $2=="127.0.0.53" {found=1} END {exit !found}' "$EDNS_RESOLV_CONF"; then
    command -v resolvectl >/dev/null 2>&1 || return 1
    servers=$(LC_ALL=C timeout 5 resolvectl dns "$EDNS_DEVICE" 2>/dev/null) || return 1
    servers=${servers#*:}
  else
    servers=$(awk '$1=="nameserver" {print $2}' "$EDNS_RESOLV_CONF") || return 1
  fi
  servers=" $(edns_normalize "$servers") "
  for address in $1; do
    [[ "$servers" == *" $address "* ]] || return 1
  done
}

edns_write_dns() {
  local actual
  edns_same_connection || { edns_error "Активный профиль сменился. Операция остановлена."; return 1; }
  edns_nmcli connection modify uuid "$EDNS_UUID" ipv4.dns "$1" || return 1
  edns_same_connection || return 1
  # Only DNS is reapplied; do not activate unrelated pending IP/route edits.
  edns_nmcli device modify "$EDNS_DEVICE" ipv4.dns "$1" || return 1
  actual=$(edns_profile_dns) || return 1
  [[ "$actual" == "$1" ]] || return 1
  actual=$(edns_applied_dns) || return 1
  [[ "$actual" == "$1" ]]
}

edns_rollback() {
  local actual failed=0
  printf '\nВозвращаем DNS, действовавшие перед этой операцией.\n'
  # The saved profile can still be restored if another connection took over.
  edns_nmcli connection modify uuid "$EDNS_UUID" ipv4.dns "$EDNS_PREVIOUS" || failed=1
  if edns_same_connection; then
    edns_nmcli device modify "$EDNS_DEVICE" ipv4.dns "$EDNS_PREVIOUS_APPLIED" || failed=1
    actual=$(edns_applied_dns) && [[ "$actual" == "$EDNS_PREVIOUS_APPLIED" ]] || failed=1
  else
    failed=1
  fi
  actual=$(edns_profile_dns) && [[ "$actual" == "$EDNS_PREVIOUS" ]] || failed=1
  if ((failed == 0)); then
    printf 'Предыдущие настройки DNS %sвосстановлены%s.\n' "$EDNS_GREEN" "$EDNS_RESET"
  else
    edns_error "Не удалось полностью откатить DNS. Исходная копия: $EDNS_BACKUP"
    edns_error "Проверьте профиль $EDNS_UUID и интерфейс $EDNS_DEVICE."
    return 1
  fi
}

edns_transaction() (
  local target="$1" preset="${2:-}" actual
  # shellcheck disable=SC2034 # Read by the EXIT trap, including on signals.
  local changed=0
  edns_lock || return 1
  EDNS_PREVIOUS=$EDNS_DNS
  # A failed change or interruption rolls back to the immediately previous
  # state, not the immutable original snapshot used by the restore command.
  trap 'if ((changed)); then edns_rollback; fi' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if ! edns_same_connection || ! actual=$(edns_profile_dns) || [[ "$actual" != "$EDNS_PREVIOUS" ]]; then
    edns_error "Настройки изменились после открытия меню. Откройте меню заново."
    return 1
  fi
  # Read applied *settings*, excluding DHCP-learned addresses. Keep this
  # rollback snapshot only in memory; the original on-disk backup is immutable.
  EDNS_PREVIOUS_APPLIED=$(edns_applied_dns) || {
    edns_error "Не удалось прочитать применённые DNS. Настройки не изменены."; return 1;
  }
  if [[ -n "$preset" ]]; then
    edns_save_backup || return 1
    edns_read_backup || return 1
    actual=$(edns_target "$preset" "$EDNS_ORIGINAL" "$EDNS_DNS")
  else
    edns_read_backup || return 1
    actual=$EDNS_ORIGINAL
  fi
  if [[ "$actual" != "$target" ]]; then
    edns_error "Исходная копия изменилась после открытия меню. Откройте меню заново."
    return 1
  fi
  changed=1
  edns_write_dns "$target" || return 1
  if [[ -n "$preset" ]]; then
    if ! edns_resolver_has_preset "$preset" || ! edns_system_resolves; then
      edns_error "Новые DNS не появились в системном резолвере или проверка разрешения имён не прошла."
      return 1
    fi
  fi
  # shellcheck disable=SC2034
  changed=0
)

edns_restore() {
  edns_read_backup || {
    edns_error "Нет корректной исходной копии для профиля $EDNS_UUID: $EDNS_BACKUP"; return 1;
  }
  printf 'Дата исходной копии: %s%s%s\n' "$EDNS_YELLOW" "$(edns_backup_date)" "$EDNS_RESET"
  printf 'Возвращаем исходные DNS: %s%s%s\n' \
    "$EDNS_GREEN" "${EDNS_ORIGINAL:-автоматическое получение без ручных адресов}" "$EDNS_RESET"
  edns_transaction "$EDNS_ORIGINAL" || return 1
  printf 'Исходные настройки DNS %sвосстановлены%s и сохранены в профиле.\n' "$EDNS_GREEN" "$EDNS_RESET"
  # An explicit restore must remain possible even while original DNS are down.
  if command -v dig >/dev/null 2>&1 && command -v getent >/dev/null 2>&1; then
    edns_system_resolves || printf 'Настройки возвращены, но проверка разрешения имён %sне прошла%s.\n' \
      "$EDNS_YELLOW" "$EDNS_RESET"
  fi
}

edns_apply() {
  local preset="$1" baseline="$EDNS_DNS" target address backup_date="" failed=0
  command -v dig >/dev/null 2>&1 && command -v getent >/dev/null 2>&1 || {
    edns_error "Для проверки нужны dig и getent."; return 1;
  }
  if [[ -e "$EDNS_BACKUP" || -L "$EDNS_BACKUP" ]]; then
    edns_read_backup || { edns_error "Исходная копия повреждена: $EDNS_BACKUP"; return 1; }
    baseline=$EDNS_ORIGINAL
    backup_date=$(edns_backup_date)
  fi
  target=$(edns_target "$preset" "$baseline" "$EDNS_DNS")
  printf '\nБудет записано в профиль: %s%s%s\n' "$EDNS_GREEN" "$target" "$EDNS_RESET"
  printf 'Выбранные DNS идут первыми. Исходные адреса сохраняются без дублей.\n'
  if [[ -n "$backup_date" ]]; then
    printf 'Исходные настройки сохранены: %s%s%s\n' "$EDNS_YELLOW" "$backup_date" "$EDNS_RESET"
  else
    printf 'Исходные настройки будут сохранены перед применением.\n'
  fi
  printf 'Для отката: %sУправление сервером → Добавить внешние DNS → Вернуть исходные DNS…%s\n\n' \
    "$EDNS_YELLOW" "$EDNS_RESET"
  for address in $preset; do
    edns_probe "$address" || failed=1
  done
  if ((failed)); then
    edns_error "Не все DNS выбранного набора разрешают имя. Настройки не изменены."
    return 1
  fi
  if ! vertical_menu current 2 0 40 default=1 "Применить" "Отмена"; then
    printf 'Настройки DNS не изменены.\n'
    return 0
  fi
  # The transaction acquires the lock after confirmation, rechecks the state,
  # and saves the original backup while still holding that same lock.
  edns_transaction "$target" "$preset" || return 1
  printf 'DNS %sприменены%s. Настройки сохранятся после перезагрузки.\n' "$EDNS_GREEN" "$EDNS_RESET"
}

edns_public_ip() {
  # Do not send local/private addresses to external registry services.
  if [[ "$1" == *:* ]]; then
    [[ "$1" =~ ^[23][[:xdigit:]]{3}: && "$1" != 2001:db8:* ]]
    return
  fi
  edns_ipv4_list_valid "$1" || return 1
  local a b c
  IFS=. read -r a b c _ <<< "$1"
  a=$((10#$a)); b=$((10#$b)); c=$((10#$c))
  ((a!=0 && a!=10 && a!=127 && a<224 &&
    !(a==100 && b>=64 && b<=127) && !(a==169 && b==254) &&
    !(a==172 && b>=16 && b<=31) && !(a==192 && b==168) &&
    !(a==192 && b==0) && !(a==198 && (b==18 || b==19)) &&
    !(a==198 && b==51 && c==100) && !(a==203 && b==0 && c==113)))
}

edns_info() {
  local servers address data ptr remaining budget start=$SECONDS
  command -v curl >/dev/null 2>&1 && command -v dig >/dev/null 2>&1 || {
    edns_error "Для получения сведений нужны curl и dig."; return 1;
  }
  servers=$(edns_nmcli -g IP4.DNS,IP6.DNS device show "$EDNS_DEVICE") || return 1
  printf '\nСведения из реестра IP; организация может отличаться от оператора DNS.\n'
  printf 'Общий лимит ожидания — 15 секунд.\n'
  for address in $(edns_normalize "$servers"); do
    printf '\n%s%s%s — %s\n' "$EDNS_GREEN" "$address" "$EDNS_RESET" "$(edns_known_name "$address")"
    if ! edns_public_ip "$address"; then
      printf 'Локальный или специальный адрес; внешний поиск пропущен.\n'
      continue
    fi
    remaining=$((15 - SECONDS + start))
    if ((remaining <= 0)); then printf 'Лимит ожидания исчерпан.\n'; continue; fi
    budget=$remaining
    ((budget > 3)) && budget=3
    data=$(timeout "$budget" curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 2 \
      --max-time "$budget" --max-filesize 262144 "https://rdap.db.ripe.net/ip/$address" 2>/dev/null) || data=""
    # Registry strings are untrusted terminal text. Drop control characters.
    if ! jq -er --arg green "$EDNS_GREEN" --arg reset "$EDNS_RESET" '
      def clean: tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; " ") | .[0:160];
      select(.objectClassName == "ip network") |
      "Сеть: \($green)\((.name // "не указана") | clean)\($reset)",
      "Диапазон: \($green)\((.startAddress // "?") | clean) — \((.endAddress // "?") | clean)\($reset)",
      ([.entities[]? | select((.roles // []) | index("registrant")) | .vcardArray[1][]? |
        select(.[0] == "fn") | .[3] | clean] | unique | .[0:2] |
        if length > 0 then "Зарегистрировано за: " + $green + join("; ") + $reset else empty end)
    ' <<< "$data" 2>/dev/null; then
      printf 'Сведения из реестра %sнедоступны%s.\n' "$EDNS_YELLOW" "$EDNS_RESET"
    fi
    remaining=$((15 - SECONDS + start))
    if ((remaining <= 0)); then continue; fi
    budget=$remaining
    ((budget > 2)) && budget=2
    ptr=$(timeout "$budget" dig -x "$address" +short +time=1 +tries=1 2>/dev/null) || ptr=""
    ptr=$(printf '%s' "$ptr" | LC_ALL=C tr -cd 'A-Za-z0-9._\n-' | head -n 2)
    printf 'PTR: %s%s%s\n' "$EDNS_GREEN" "${ptr:-не получен}" "$EDNS_RESET"
  done
}

edns_check_current() {
  local servers address
  command -v dig >/dev/null 2>&1 || { edns_error "Не найдена команда dig."; return 1; }
  servers=$(edns_nmcli -g IP4.DNS,IP6.DNS device show "$EDNS_DEVICE") || return 1
  printf '\nПроверка разрешения %sexample.com%s каждым DNS:\n' "$EDNS_GREEN" "$EDNS_RESET"
  for address in $(edns_normalize "$servers"); do
    edns_probe "$address"
  done
}

edns_menu() {
  local choice backup_date restore_label
  local -a items actions
  # shellcheck source=../windows.sh
  source "${RISH_HOME:-/root/rish}/windows.sh" || return 1
  while true; do
    clear
    edns_detect && edns_show || return 1
    printf '\n'
    items=("Quad9 + MSK-IX (${EDNS_MSK// /, })" "Quad9 + Яндекс DNS (${EDNS_YANDEX// /, })")
    actions=(msk yandex)
    if edns_read_backup; then
      backup_date=$(edns_backup_date)
      if [[ "$backup_date" == 'дата неизвестна' ]]; then
        restore_label="Вернуть исходные DNS ($backup_date)"
      else
        restore_label="Вернуть исходные DNS от $backup_date"
      fi
      items+=("$restore_label")
      actions+=(restore)
    fi
    items+=("Проверить текущие DNS" "Получить сведения о текущих DNS" "Назад")
    actions+=(check info back)
    choice=0
    vertical_menu current 2 0 48 "${items[@]}" || choice=$?
    case "${actions[$choice]:-back}" in
      msk) edns_apply "$EDNS_MSK" ;;
      yandex) edns_apply "$EDNS_YANDEX" ;;
      restore)
        if edns_read_backup; then
          printf '\nДата исходной копии: %s%s%s\n' "$EDNS_YELLOW" "$(edns_backup_date)" "$EDNS_RESET"
          printf 'Исходные DNS: %s%s%s\n' "$EDNS_GREEN" "${EDNS_ORIGINAL:-без ручных адресов}" "$EDNS_RESET"
          if vertical_menu current 2 0 40 default=1 "Восстановить" "Отмена"; then
            edns_restore
          else
            printf 'Настройки DNS не изменены.\n'
          fi
        else
          edns_error "Для этого профиля нет корректной исходной копии."
        fi
        ;;
      check) edns_check_current ;;
      info) edns_info ;;
      *) return 0 ;;
    esac
    vertical_menu current 2 0 20 "Нажмите Enter"
  done
}

edns_main() (
  local action="${1:-menu}" dependency
  case "$action" in
    -h|--help) printf 'Использование: bash %s [menu|restore]\n' "$0"; return 0 ;;
    menu|restore) ;;
    *) edns_error "Неизвестная команда: $action"; return 2 ;;
  esac
  [[ $EUID == 0 ]] || { edns_error "Запустите от root."; return 1; }
  for dependency in nmcli ip timeout jq flock busctl od; do
    command -v "$dependency" >/dev/null 2>&1 || { edns_error "Не найдена команда: $dependency"; return 1; }
  done
  umask 077
  if [[ "$action" == restore ]]; then
    edns_detect && edns_restore
  else
    edns_menu
  fi
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  edns_main "$@"
fi
