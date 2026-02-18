#!/usr/bin/env bash

REMOTE_NAME="${1:-${RCLONE_REMOTE:-ydisk}}"
COLOR_GREEN="\033[0;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_RESET="\033[0m"
SCOPES="${YANDEX_SCOPES:-cloud_api:disk.read cloud_api:disk.write cloud_api:disk.info}"
DEFAULT_YANDEX_CLIENT_ID="df3690bb894848c18fc25a4be575ee13"
DEFAULT_YANDEX_CLIENT_SECRET="310862a82b4c44b79032eed57d0eb27c"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "/root/rish/windows.sh" ]]; then
  # shellcheck disable=SC1091
  source /root/rish/windows.sh
elif [[ -f "${SCRIPT_DIR}/windows.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/windows.sh"
else
  echo "ОШИБКА: не найден /root/rish/windows.sh или ${SCRIPT_DIR}/windows.sh" >&2
  exit 1
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ОШИБКА: команда '$cmd' не установлена" >&2
    exit 1
  fi
}

require_cmd rclone
require_cmd jq

YANDEX_CLIENT_ID="${YANDEX_CLIENT_ID:-$DEFAULT_YANDEX_CLIENT_ID}"
YANDEX_CLIENT_SECRET="${YANDEX_CLIENT_SECRET:-$DEFAULT_YANDEX_CLIENT_SECRET}"

if [[ -z "$YANDEX_CLIENT_ID" ]]; then
  read -r -p "Введите YANDEX_CLIENT_ID: " YANDEX_CLIENT_ID
fi

if [[ -z "$YANDEX_CLIENT_SECRET" ]]; then
  read -r -s -p "Введите YANDEX_CLIENT_SECRET: " YANDEX_CLIENT_SECRET
  echo
fi

if [[ -z "$YANDEX_CLIENT_ID" || -z "$YANDEX_CLIENT_SECRET" ]]; then
  echo "ОШИБКА: требуются YANDEX_CLIENT_ID и YANDEX_CLIENT_SECRET." >&2
  exit 1
fi

echo "Конфигурация подключения к Yandex Disk по ссылке и коду."
echo
echo "Вы можете создать новое подключение или изменить существующее (например сменить диск)"

mkdir -p "${HOME}/.config/rclone"
touch "${HOME}/.config/rclone/rclone.conf"
chmod 600 "${HOME}/.config/rclone/rclone.conf" 2>/dev/null
REMOTE_LIST_RAW="$(rclone config dump 2>/dev/null || true)"
REMOTE_ITEMS=()
REMOTE_NAMES=()
if [[ -n "$REMOTE_LIST_RAW" ]]; then
  while IFS= read -r rem; do
    [[ -z "$rem" ]] && continue
    REMOTE_NAMES+=("$rem")
  done < <(printf '%s' "$REMOTE_LIST_RAW" | jq -r 'to_entries[] | select(.value.type == "yandex") | .key' 2>/dev/null || true)
fi

REMOTE_SET="|"
for rem in "${REMOTE_NAMES[@]}"; do
  REMOTE_SET+="${rem}|"
done

if [[ -n "$REMOTE_LIST_RAW" ]]; then
  base="${REMOTE_NAME}"
  if [[ "$REMOTE_SET" == *"|${base}|"* ]]; then
    i=2
    while [[ "$REMOTE_SET" == *"|${base}${i}|"* ]]; do
      ((i++))
    done
    REMOTE_NAME="${base}${i}"
  fi
fi

REMOTE_ITEMS+=("Создать новое подключение yandex disk")
for rem in "${REMOTE_NAMES[@]}"; do
  REMOTE_ITEMS+=("Изменить ${rem}")
done
REMOTE_ITEMS+=("Выйти")

vertical_menu "current" 1 0 0 "${REMOTE_ITEMS[@]}"
MENU_CHOICE=$?

if [[ "$MENU_CHOICE" -eq 255 ]]; then
  echo "Отменено."
  exit 0
fi

if [[ "$MENU_CHOICE" -eq $((${#REMOTE_ITEMS[@]} - 1)) ]]; then
  echo "Отменено."
  exit 0
fi

if [[ "$MENU_CHOICE" -eq 0 ]]; then
  echo -e -n "Введите имя подключения (${COLOR_GREEN}${REMOTE_NAME}${COLOR_RESET} по умолчанию):${COLOR_GREEN}"
  read -r -e -i "$REMOTE_NAME" -p " " INPUT_REMOTE
  echo -en "${COLOR_RESET}"
  if [[ -n "$INPUT_REMOTE" ]]; then
    REMOTE_NAME="$INPUT_REMOTE"
  fi

  while [[ "$REMOTE_SET" == *"|${REMOTE_NAME}|"* ]]; do
    echo -e "${COLOR_YELLOW}ВНИМАНИЕ:${COLOR_RESET} подключение ${COLOR_YELLOW}${REMOTE_NAME}${COLOR_RESET} уже существует."
    base="${REMOTE_NAME}"
    i=2
    while [[ "$REMOTE_SET" == *"|${base}${i}|"* ]]; do
      ((i++))
    done
    SUGGESTED="${base}${i}"
    echo -e "Предложение: ${COLOR_GREEN}${SUGGESTED}${COLOR_RESET}"
    vertical_menu "current" 1 0 0 "Использовать ${SUGGESTED}" "Ввести свое имя" "Выйти"
    CHOICE_CONFIRM=$?
    if [[ "$CHOICE_CONFIRM" -eq 255 ]]; then
      echo -e "Операция ${COLOR_YELLOW}отменена${COLOR_RESET}."
      exit 0
    fi
    if [[ "$CHOICE_CONFIRM" -eq 0 ]]; then
      REMOTE_NAME="$SUGGESTED"
    elif [[ "$CHOICE_CONFIRM" -eq 1 ]]; then
      echo -e -n "Введите имя подключения:${COLOR_GREEN} "
      read -r INPUT_REMOTE2
      echo -en "${COLOR_RESET}"
      if [[ -z "$INPUT_REMOTE2" ]]; then
        echo -e "Операция ${COLOR_YELLOW}отменена${COLOR_RESET}."
        exit 0
      fi
      REMOTE_NAME="$INPUT_REMOTE2"
    else
      echo -e "Операция ${COLOR_YELLOW}отменена${COLOR_RESET}."
      exit 0
    fi
  done
else
  idx=$((MENU_CHOICE - 1))
  REMOTE_NAME="${REMOTE_NAMES[$idx]}"
fi

echo -e "Будет настроено подключение: ${COLOR_YELLOW}${REMOTE_NAME}${COLOR_RESET}"

echo "Запрашиваю device-код у Yandex OAuth..."
DEVICE_RAW="$(curl -sS -X POST 'https://oauth.yandex.com/device/code' \
  --data-urlencode "client_id=${YANDEX_CLIENT_ID}" \
  --data-urlencode 'response_type=device_code' \
  --data-urlencode "scope=${SCOPES}")"

DEVICE_ERROR="$(printf '%s' "$DEVICE_RAW" | jq -r '.error // empty' 2>/dev/null || true)"
if [[ -n "$DEVICE_ERROR" ]]; then
  DESC="$(printf '%s' "$DEVICE_RAW" | jq -r '.error_description // .message // empty' 2>/dev/null || true)"
  echo "ОШИБКА: не удалось получить device-код: ${DEVICE_ERROR} ${DESC}" >&2
  exit 1
fi

DEVICE_CODE="$(printf '%s' "$DEVICE_RAW" | jq -r '.device_code // empty')"
USER_CODE="$(printf '%s' "$DEVICE_RAW" | jq -r '.user_code // empty')"
VERIFY_URL="$(printf '%s' "$DEVICE_RAW" | jq -r '.verification_url // .verification_uri // "https://oauth.yandex.com/device"')"
EXPIRES_IN="$(printf '%s' "$DEVICE_RAW" | jq -r '.expires_in // 600')"
INTERVAL="$(printf '%s' "$DEVICE_RAW" | jq -r '.interval // 5')"

if [[ -z "$DEVICE_CODE" || -z "$USER_CODE" ]]; then
  echo "ОШИБКА: некорректный ответ от Yandex OAuth (нет device_code/user_code)." >&2
  exit 1
fi

echo
echo "Откройте в любом браузере URL:"
echo "  $VERIFY_URL"
echo "И введите код:"
echo "  $USER_CODE"
echo

echo "Ожидаю подтверждение (до ${EXPIRES_IN} сек)..."
START_TS="$(date +%s)"
TOKEN_RAW=""

while true; do
  NOW_TS="$(date +%s)"
  ELAPSED="$((NOW_TS - START_TS))"
  if (( ELAPSED >= EXPIRES_IN )); then
    echo "ОШИБКА: срок действия кода истёк. Запустите снова." >&2
    exit 1
  fi

  TOKEN_RAW="$(curl -sS -u "${YANDEX_CLIENT_ID}:${YANDEX_CLIENT_SECRET}" \
    -X POST 'https://oauth.yandex.com/token' \
    --data-urlencode 'grant_type=device_code' \
    --data-urlencode "code=${DEVICE_CODE}")"

  ACCESS_TOKEN="$(printf '%s' "$TOKEN_RAW" | jq -r '.access_token // empty' 2>/dev/null || true)"
  if [[ -n "$ACCESS_TOKEN" ]]; then
    break
  fi

  ERR="$(printf '%s' "$TOKEN_RAW" | jq -r '.error // empty' 2>/dev/null || true)"

  case "$ERR" in
    authorization_pending)
      sleep "$INTERVAL"
      ;;
    slow_down)
      INTERVAL="$((INTERVAL + 5))"
      sleep "$INTERVAL"
      ;;
    access_denied|expired_token|invalid_grant)
      DESC="$(printf '%s' "$TOKEN_RAW" | jq -r '.error_description // empty' 2>/dev/null || true)"
      echo "ОШИБКА: авторизация не удалась: ${ERR} ${DESC}" >&2
      exit 1
      ;;
    *)
      DESC="$(printf '%s' "$TOKEN_RAW" | jq -r '.error_description // .message // empty' 2>/dev/null || true)"
      if [[ -n "$ERR" ]]; then
        echo "ОШИБКА: не удалось получить токен: ${ERR} ${DESC}" >&2
        exit 1
      fi
      sleep "$INTERVAL"
      ;;
  esac
done

TOKEN_TYPE="$(printf '%s' "$TOKEN_RAW" | jq -r '.token_type // "OAuth"')"
REFRESH_TOKEN="$(printf '%s' "$TOKEN_RAW" | jq -r '.refresh_token // empty')"
EXPIRES_TOKEN_SEC="$(printf '%s' "$TOKEN_RAW" | jq -r '.expires_in // 0')"
EXPIRY=""
if [[ "$EXPIRES_TOKEN_SEC" =~ ^[0-9]+$ ]] && (( EXPIRES_TOKEN_SEC > 0 )); then
  EXPIRY="$(date -u -d "+${EXPIRES_TOKEN_SEC} seconds" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
  if [[ -z "$EXPIRY" ]]; then
    EXPIRY="$(date -u -v+"${EXPIRES_TOKEN_SEC}"S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
  fi
fi
RCLONE_TOKEN_JSON="$(jq -cn \
  --arg at "$ACCESS_TOKEN" \
  --arg tt "$TOKEN_TYPE" \
  --arg rt "$REFRESH_TOKEN" \
  --arg ex "$EXPIRY" \
  '{access_token:$at,token_type:$tt,refresh_token:$rt,expiry:$ex}')"

echo -e "Создаю/обновляю подключение ${COLOR_GREEN}${REMOTE_NAME}${COLOR_RESET}..."
rclone config create "$REMOTE_NAME" yandex \
  client_id "$YANDEX_CLIENT_ID" \
  client_secret "$YANDEX_CLIENT_SECRET" \
  token "$RCLONE_TOKEN_JSON" \
  --non-interactive >/dev/null

echo "Проверяю доступность подключения..."
ABOUT_OUT="$(rclone about "${REMOTE_NAME}:" 2>/dev/null || true)"
if [[ -n "$ABOUT_OUT" ]]; then
  printf '%s\n' "$ABOUT_OUT"
fi

echo
echo "ГОТОВО"
echo -e "Подключение настроено: ${COLOR_GREEN}${REMOTE_NAME}${COLOR_RESET}"
