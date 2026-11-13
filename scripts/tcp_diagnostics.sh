#!/usr/bin/env bash

rish_tcp_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) || return 1
  printf '%d\n' "$((10#$1))"
}

rish_tcp_sample() {
  PYTHONIOENCODING=utf-8 python3 - "$@" <<'PY'
from collections import Counter
from datetime import datetime
from heapq import nsmallest
from ipaddress import ip_address
import os
import subprocess
import sys
import time


COUNTERS = ('ListenOverflows', 'ListenDrops')
STATES = {'ESTAB': 'ESTABLISHED', 'SYN-RECV': 'SYN-RECV'}
INTERVAL = 5


def kernel_sample():
    stamp = time.monotonic()
    values = {}
    try:
        with open('/proc/net/netstat', encoding='ascii') as handle:
            for line in handle:
                if line.startswith('TcpExt:'):
                    names = line.split()[1:]
                    numbers = next(handle, '').split()
                    if numbers[:1] == ['TcpExt:'] and len(numbers) == len(names) + 1:
                        values = dict(zip(names, numbers[1:]))
                    break
    except OSError:
        pass
    return stamp, [int(values[name]) if values.get(name, '').isdigit() else None
                   for name in COUNTERS]


def socket_sample(port):
    command = ['ss', '-Hnt', 'state', 'listening', 'state', 'established',
               'state', 'syn-recv', 'sport', '=', ':' + port]
    environment = dict(os.environ, LC_ALL='C')
    environment.pop('COLUMNS', None)
    result = subprocess.run(command, env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            encoding='utf-8', errors='replace', timeout=4)
    if result.returncode or result.stderr.strip():
        raise RuntimeError('Не удалось получить список TCP-сокетов через ss.')

    listeners = []
    peers = {state: Counter() for state in STATES}
    for line in result.stdout.splitlines():
        state, recv, send, local, remote = line.split()[:5]
        if local.rsplit(':', 1)[-1] != port:
            raise ValueError('local port')
        if state == 'LISTEN':
            listeners.append((local, int(recv), int(send)))
            continue
        host, remote_port = remote.rsplit(':', 1)
        if not remote_port.isdecimal():
            raise ValueError('remote port')
        host, scope_separator, scope = host.replace(']', '').lstrip('[').partition('%')
        address = ip_address(host)
        if address.version == 6 and address.ipv4_mapped:
            address = address.ipv4_mapped
        key = (address.version, str(address) + scope_separator + scope)
        peers[state][key] += 1
    return sorted(listeners), peers


def paint(text, color):
    return palette[color] + text + palette['reset'] if palette else text


def table(headers, rows, right, width):
    widths = [max(len(header), *(len(row[i][0]) for row in rows))
              for i, header in enumerate(headers)]
    widths[0] = min(widths[0], max(8, width - sum(widths[1:]) - 3 * (len(widths) - 1)))

    def render(cells):
        fields = []
        for index, ((text, color), size) in enumerate(zip(cells, widths)):
            if len(text) > size:
                left = (size - 1) // 2
                text = text[:left] + '…' + text[-(size - left - 1):]
            value = paint(text, color) if color else text
            padding = ' ' * (size - len(text))
            fields.append(padding + value if index in right else value + padding)
        return ' │ '.join(fields).rstrip()

    return (render([(header, '') for header in headers]),
            '─┼─'.join('─' * size for size in widths),
            [render(row) for row in rows])


def screen(lines):
    for line in lines:
        print('screen\t' + ('  ' + line if line else '-'))


port, previous, mode, width, height, color_enabled = sys.argv[1:]
width, height = int(width), int(height)
palette = {'green': '\033[0;32m', 'yellow': '\033[0;33m', 'red': '\033[0;31m',
           'bold': '\033[1m', 'reset': '\033[0m'} if color_enabled == '1' else {}
stamp, values = kernel_sample()
captured_at = datetime.now().astimezone()
listeners, peers = [], {}
socket_error = ''
try:
    listeners, peers = socket_sample(port)
except subprocess.TimeoutExpired:
    socket_error = 'Команда ss не ответила за 4 секунды.'
except OSError:
    socket_error = 'Не удалось запустить ss.'
except RuntimeError as error:
    socket_error = str(error)
except (ValueError, KeyError):
    socket_error = 'Не удалось разобрать вывод ss для выбранного порта.'

if mode == 'once':
    previous_stamp, previous_values = stamp, values
    time.sleep(max(0, stamp + INTERVAL - time.monotonic()))
    stamp, values = kernel_sample()
elif previous:
    previous_stamp, *previous_values = previous.split()
    previous_stamp = float(previous_stamp)
    previous_values = [None if value == '-' else int(value) for value in previous_values]
else:
    previous_stamp, previous_values = None, [None] * len(COUNTERS)

print('sample\t{} {}'.format(stamp, ' '.join('-' if value is None else str(value) for value in values)))
timestamp = captured_at.strftime('%H:%M:%S' if mode == 'monitor' else '%Y-%m-%d %H:%M:%S %z')
screen([paint('TCP-соединения', 'bold') + '  ' + paint(port + '/tcp', 'green') +
        '    Обновлено ' + timestamp])

if socket_error:
    print('incomplete\t1')
    screen(['', paint('Очередь приёма и соединения', 'bold'), paint(socket_error, 'yellow')])
else:
    screen(['', paint('Очередь приёма', 'bold')])

queue_lines = 1
if listeners:
    listener_rows = []
    for local, recv, send in listeners:
        status, tone = 'Свободна', 'green'
        if recv > send:
            status, tone = 'Заполнена', 'red'
        elif recv == send and recv > 0:
            status, tone = 'На пределе', 'yellow'
        listener_rows.append(((local, 'green'), (str(recv), tone), (str(send), ''), (status, tone)))
    # Put a full accept queue first when several sockets listen on this port.
    listener_rows.sort(key=lambda row: {'red': 0, 'yellow': 1, 'green': 2}[row[3][1]])
    queue_slots = max(2, height - 25)
    limited = mode == 'monitor' and len(listener_rows) > queue_slots
    visible = listener_rows[:queue_slots - 1] if limited else listener_rows
    header, line, rows = table(('Локальный адрес', 'В очереди', 'Лимит', 'Состояние'),
                               visible, (1, 2), width - 3)
    screen([header, line, *rows])
    if limited:
        screen(['Слушающих сокетов показано {} из {}.'.format(len(visible), len(listener_rows))])
    queue_lines = 2 + len(visible) + limited
elif not socket_error:
    screen([paint('Порт не прослушивается', 'yellow')])

if not socket_error:
    screen(['', paint('Соединения', 'bold'),
            'Установлено ' + paint(str(sum(peers['ESTAB'].values())), 'green') +
            '  ·  Ожидают подтверждения ' + paint(str(sum(peers['SYN-RECV'].values())), 'green')])
peer_rows = []
for state, counts in peers.items():
    label = STATES[state]
    total = sum(counts.values())
    top = []
    for family in (4, 6):
        entries = (item for item in counts.items() if item[0][0] == family)
        top.extend(nsmallest(3, entries, key=lambda item: (-item[1], item[0][1])))
    for (_, address), count in sorted(top, key=lambda item: (-item[1], item[0][1])):
        percent = ('{:.1f} %'.format(100 * count / total)).replace('.', ',')
        peer_rows.append(((address, 'green'), (label, ''), (str(count), ''), (percent, '')))

if peer_rows:
    headers = ('IP-адрес', 'Состояние', 'Количество', 'Доля')
    if mode == 'once':
        visible = peer_rows
    else:
        # Leave room for the fixed sections, footer, and a firewall status line.
        slots = max(2, height - queue_lines - 21)
        # Reserve the first row of each state before filling the remaining slots.
        first_syn = next((i for i, row in enumerate(peer_rows) if row[1][0] == 'SYN-RECV'), 0)
        indices = set(range(min(slots, len(peer_rows))))
        if first_syn and first_syn not in indices:
            indices.remove(max(indices))
            indices.add(first_syn)
        visible = [peer_rows[i] for i in sorted(indices)]
    header, line, rows = table(headers, visible, (2, 3), width - 3)
    screen([header, line, *rows])
    plain_rows = [tuple((text, '') for text, _ in row) for row in peer_rows]
    header, _, rows = table(headers, plain_rows, (2, 3), width - 9)
    print('peer-header\t' + header)
    for row, cells in zip(rows, peer_rows):
        print('peer\t{}\t{}'.format(cells[0][0], row))
elif not socket_error:
    screen(['Нет соединений для показа по IP.'])

counter_rows = []
labels = ('Переполнения очереди', 'Отброшено при приёме')
for name, value, earlier in zip(labels, values, previous_values):
    if value is None:
        change, tone = 'нет данных', 'yellow'
    elif previous_stamp is None:
        change, tone = 'первый замер', 'yellow'
    elif earlier is None or value < earlier:
        change, tone = 'нет данных', 'yellow'
    else:
        change, tone = '+{}'.format(value - earlier), 'yellow' if value > earlier else 'green'
    counter_rows.append(((name, ''), (change, tone)))
interval = ' за {:.1f} с'.format(stamp - previous_stamp).replace('.', ',') if previous_stamp is not None else ''
header, line, rows = table(('Показатель', 'Прирост'), counter_rows, (1,), width - 3)
screen(['', paint('Счётчики ядра' + interval, 'bold'), header, line, *rows, '',
        'Счётчики общие для всех портов текущего сетевого пространства имён.'])
print('delay\t{}'.format(max(50, int(1000 * (stamp + INTERVAL - time.monotonic())))))
PY
}

rish_tcp_key() {
  local LC_ALL=C output="$1" input suffix status
  local -a timeout=()

  if [[ -n "${2:-}" ]]; then timeout=(-t "$2"); fi
  IFS= read -r -s -N 1 "${timeout[@]}" input
  status=$?
  if ((status != 0)); then
    ((status > 128)) && return 1
    return 2
  fi
  if [[ "$input" == $'\e' ]]; then
    # CSI and SS3 sequences also start with Esc (for example, arrow keys).
    IFS= read -r -s -N 1 -t 0.08 suffix || return 2
    if [[ "$suffix" == $'\e' ]]; then return 2; fi
    if [[ "$suffix" == '[' || "$suffix" == 'O' ]]; then
      while IFS= read -r -s -N 1 -t 0.08 suffix; do
        [[ "$suffix" == [@-~] ]] && break
      done
    fi
    return 1
  fi
  printf -v "$output" '%s' "$input"
}

rish_tcp_live_key() {
  local delay="$1" deadline remaining timeout key status

  deadline=$(($(get_time_ms) + delay))
  while true; do
    remaining=$((deadline - $(get_time_ms)))
    ((remaining > 0)) || return 1
    printf -v timeout '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
    status=0
    rish_tcp_key key "$timeout" || status=$?
    if ((status == 2)); then return 2; fi
    if ((status == 0)) && [[ "$key" == $'\n' || "$key" == $'\r' ]]; then return 0; fi
  done
}

rish_tcp_read_port() {
  local key status typed=''

  printf '  TCP-порт (1–65535) · Esc — выход\n  '
  while true; do
    status=0
    rish_tcp_key key || status=$?
    if ((status == 2)); then return 2; fi
    ((status == 0)) || continue
    case "$key" in
      [0-9])
        if ((${#typed} < 6)); then typed+="$key"; printf '%s' "$key"; fi
        ;;
      $'\x7f'|$'\b')
        if [[ -n "$typed" ]]; then typed=${typed%?}; printf '\b \b'; fi
        ;;
      $'\n'|$'\r')
        printf '\n'
        new_port=$(rish_tcp_port "$typed")
        return $?
        ;;
      $'\x04') return 2 ;;
    esac
  done
}

rish_tcp_main() {
  local mode=monitor port sample type value label previous='' delay notice='' choice read_status address new_port rish_home
  local color=0 width=80 height=24 dimensions peer_header incomplete green='' yellow='' bold='' reset=''
  local -a report=() peer_labels=() peer_addresses=() actions

  case "${1:-}" in
    --once) mode=once; shift ;;
    -h|--help) printf 'Использование: bash %s [--once] [порт]\n' "$0"; return 0 ;;
  esac
  if (($# > 1)) || ! port=$(rish_tcp_port "${1-443}"); then
    printf 'Укажите TCP-порт от 1 до 65535.\n' >&2
    return 2
  fi
  if ! command -v ss >/dev/null || ! command -v python3 >/dev/null; then
    printf 'Для диагностики требуются ss (iproute) и python3.\n' >&2
    return 1
  fi
  if [[ "$mode" == monitor ]]; then
    if [[ ! -t 0 || ! -t 1 ]]; then
      printf 'Для наблюдения нужен терминал. Для одного замера используйте --once.\n' >&2
      return 1
    fi
    rish_home=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P) || return 1
    source "$rish_home/windows.sh" || return 1
    color=1
    green=$'\033[0;32m' yellow=$'\033[0;33m' bold=$'\033[1m' reset=$'\033[0m'
  fi

  while true; do
    report=() peer_labels=() peer_addresses=()
    incomplete=0
    delay=5000
    if [[ "$mode" == monitor ]] && dimensions=$(stty size 2>/dev/null); then
      read -r height width <<<"$dimensions"
      ((height > 0)) || height=24
      ((width > 0)) || width=80
    fi
    if sample=$(rish_tcp_sample "$port" "$previous" "$mode" "$width" "$height" "$color" 2>&1); then
      while IFS=$'\t' read -r type value label; do
        case "$type" in
          sample) previous="$value" ;;
          delay) delay="$value" ;;
          incomplete) incomplete=1 ;;
          screen)
            [[ "$value" != '-' ]] || value=''
            report+=("$value")
            ;;
          peer-header) peer_header="$value" ;;
          peer)
            peer_addresses+=("$value")
            peer_labels+=("$label")
            ;;
        esac
      done <<<"$sample"
    else
      if [[ "$mode" == once ]]; then printf '%s\n' "$sample" >&2; return 1; fi
      previous=''
      report=("  TCP-соединения  ${green}${port}/tcp${reset}" "" "  ${yellow}${sample}${reset}")
    fi
    if [[ "$mode" == once ]]; then printf '%s\n' "${report[@]}"; return "$incomplete"; fi

    clear
    printf '%s\n' "${report[@]}"
    if [[ -n "$notice" ]]; then printf '\n  %s\n' "$notice"; notice=''; fi
    printf '\n  Обновление каждые 5 с · %sEnter%s — действия · %sEsc%s — выход\n' \
      "$bold" "$reset" "$bold" "$reset"
    read_status=0
    rish_tcp_live_key "$delay" || read_status=$?
    case "$read_status" in
      1) continue ;;
      2) return 0 ;;
    esac
    previous=''

    while true; do
      clear
      printf '\n  TCP-соединения  %s%s/tcp%s   %sПауза%s\n\n' "$green" "$port" "$reset" "$yellow" "$reset"
      actions=("Продолжить наблюдение" "Порт 443" "Порт 80" "Другой порт")
      if ((${#peer_addresses[@]})); then actions+=("Выбрать IP для блокировки"); fi
      actions+=("Выход")
      choice=0
      vertical_menu current 2 0 26 default=0 "${actions[@]}" || choice=$?
      case "${actions[choice]:-Выход}" in
        "Продолжить наблюдение") break ;;
        "Порт 443") port=443; break ;;
        "Порт 80") port=80; break ;;
        "Другой порт")
          read_status=0
          rish_tcp_read_port || read_status=$?
          if ((read_status == 2)); then return 0; fi
          if ((read_status == 0)); then port="$new_port"; break; fi
          printf 'Укажите TCP-порт от 1 до 65535.\n'
          choice=0
          vertical_menu current 2 0 20 "Нажмите Enter" || choice=$?
          if ((choice == 255)); then return 0; fi
          ;;
        "Выбрать IP для блокировки")
          clear
          printf '\n  Временная блокировка\n  Выберите IP, затем укажите срок и подтвердите блокировку.\n\n'
          printf '    %s\n' "$peer_header"
          choice=0
          vertical_menu current 2 10 20 "default=${#peer_labels[@]}" "${peer_labels[@]}" "Выход" || choice=$?
          ((choice < ${#peer_addresses[@]})) || return 0
          address=${peer_addresses[choice]}
          clear
          if bash "$rish_home/scripts/firewall_management.sh" block-from-monitor "$address"; then
            notice="Временное правило для ${green}${address}${reset} подтверждено."
            break
          elif [[ $? != 2 ]]; then
            choice=0
            vertical_menu current 2 0 20 "Нажмите Enter" || choice=$?
            if ((choice == 255)); then return 0; fi
          fi
          ;;
        *) return 0 ;;
      esac
    done
  done
}

rish_tcp_main "$@"
