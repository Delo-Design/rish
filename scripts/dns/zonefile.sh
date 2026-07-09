#!/usr/bin/env bash

zonefile_strip_comment() {
  local line="$1"
  local out=""
  local char
  local in_quote=0
  local escaped=0
  local i

  for ((i = 0; i < ${#line}; i++)); do
    char="${line:i:1}"
    if ((escaped)); then
      out+="$char"
      escaped=0
      continue
    fi
    if [[ "$char" == "\\" ]]; then
      out+="$char"
      escaped=1
      continue
    fi
    if [[ "$char" == '"' ]]; then
      out+="$char"
      if ((in_quote)); then
        in_quote=0
      else
        in_quote=1
      fi
      continue
    fi
    if [[ "$char" == ";" && "$in_quote" -eq 0 ]]; then
      break
    fi
    out+="$char"
  done

  printf '%s' "$out"
}

zonefile_tokenize() {
  local line="$1"
  local token=""
  local char
  local in_quote=0
  local escaped=0
  local -a tokens=()
  local i

  for ((i = 0; i < ${#line}; i++)); do
    char="${line:i:1}"
    if ((escaped)); then
      token+="$char"
      escaped=0
      continue
    fi
    if [[ "$char" == "\\" ]]; then
      escaped=1
      continue
    fi
    if [[ "$char" == '"' ]]; then
      if ((in_quote)); then
        in_quote=0
      else
        in_quote=1
      fi
      continue
    fi
    if [[ "$char" =~ [[:space:]] && "$in_quote" -eq 0 ]]; then
      if [[ -n "$token" ]]; then
        tokens+=("$token")
        token=""
      fi
      continue
    fi
    token+="$char"
  done

  if [[ -n "$token" ]]; then
    tokens+=("$token")
  fi

  printf '%s\n' "${tokens[@]}"
}

zonefile_is_type() {
  case "$1" in
    A | AAAA | CNAME | MX | TXT | NS | CAA | SOA)
      return 0
      ;;
  esac

  return 1
}

zonefile_is_ttl() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

zonefile_abs_name() {
  local name="$1"
  local origin="$2"

  if [[ "$name" == "@" ]]; then
    printf '%s' "$origin"
  elif [[ "$name" == *"." ]]; then
    printf '%s' "$name"
  else
    printf '%s.%s' "$name" "$origin"
  fi
}

zonefile_record_value() {
  local type="$1"
  shift

  case "$type" in
    MX)
      if (($# < 2)); then
        return 1
      fi
      printf '%s %s' "$1" "$(zonefile_abs_name "$2" "$ZONEFILE_ORIGIN")"
      ;;
    CNAME | NS)
      if (($# < 1)); then
        return 1
      fi
      printf '%s' "$(zonefile_abs_name "$1" "$ZONEFILE_ORIGIN")"
      ;;
    TXT | CAA)
      if (($# < 1)); then
        return 1
      fi
      printf '%s' "$*"
      ;;
    A | AAAA)
      if (($# < 1)); then
        return 1
      fi
      printf '%s' "$1"
      ;;
    *)
      return 1
      ;;
  esac
}

zonefile_emit_grouped() {
  local line

  sort | awk -F '\t' '
    function json_escape(value, out, i, c) {
      out = ""
      for (i = 1; i <= length(value); i++) {
        c = substr(value, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else out = out c
      }
      return out
    }
    function flush() {
      if (key == "") return
      printf "%s\t%s\t%s\t[", type, ttl, name
      for (i = 1; i <= value_count; i++) {
        if (i > 1) printf ","
        printf "\"%s\"", json_escape(values[i])
      }
      printf "]\n"
    }
    {
      current_key = $1 "\t" $2
      if (key != "" && current_key != key) {
        flush()
        delete values
        value_count = 0
      }
      key = current_key
      name = $1
      type = $2
      ttl = $3
      value_count++
      values[value_count] = $4
    }
    END {
      flush()
    }
  ' | while IFS= read -r line; do
    printf '%s\n' "$line"
  done
}

parse_zonefile() {
  local zone_file="$1"
  local default_origin="$2"
  local origin
  local ttl=3600
  local last_name="@"
  local raw_line
  local line
  local token
  local -a tokens=()
  local name
  local type
  local value
  local index
  local record_ttl
  local records_tmp

  if [[ ! -f "$zone_file" ]]; then
    echo -e "Файл зоны ${YELLOW}${zone_file}${WHITE} не найден." >&2
    return 1
  fi

  records_tmp="$(mktemp)" || return 1

  origin="$(dns_fqdn "$default_origin")"
  ZONEFILE_ORIGIN="$origin"

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="$(zonefile_strip_comment "$raw_line")"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue

    mapfile -t tokens < <(zonefile_tokenize "$line")
    ((${#tokens[@]} > 0)) || continue

    case "${tokens[0]}" in
      '$ORIGIN')
        if [[ -n "${tokens[1]:-}" ]]; then
          origin="$(dns_fqdn "${tokens[1]}")"
          ZONEFILE_ORIGIN="$origin"
        fi
        continue
        ;;
      '$TTL')
        if [[ -n "${tokens[1]:-}" && "${tokens[1]}" =~ ^[0-9]+$ ]]; then
          ttl="${tokens[1]}"
        fi
        continue
        ;;
      '$INCLUDE' | '$GENERATE')
        echo -e "Zone file содержит ${YELLOW}${tokens[0]}${WHITE}, это не поддерживается в MVP." >&2
        rm -f "$records_tmp"
        return 1
        ;;
    esac

    name=""
    type=""
    record_ttl="$ttl"
    index=0

    if zonefile_is_type "${tokens[0]}" || zonefile_is_ttl "${tokens[0]}" || [[ "${tokens[0]}" == "IN" ]]; then
      name="$last_name"
    else
      name="${tokens[0]}"
      last_name="$name"
      index=1
    fi

    while ((index < ${#tokens[@]})); do
      token="${tokens[$index]}"
      if [[ "$token" == "IN" ]]; then
        index=$((index + 1))
        continue
      fi
      if zonefile_is_ttl "$token"; then
        record_ttl="$token"
        index=$((index + 1))
        continue
      fi
      if zonefile_is_type "$token"; then
        type="$token"
        index=$((index + 1))
        break
      fi
      break
    done

    if [[ -z "$type" ]]; then
      echo -e "Не удалось определить тип записи в строке: ${YELLOW}${raw_line}${WHITE}" >&2
      rm -f "$records_tmp"
      return 1
    fi

    if [[ "$type" == "SOA" ]]; then
      echo -e "${YELLOW}SOA${WHITE} пропущена: ${raw_line}"
      continue
    fi

    if ! dns_record_type_allowed "$type"; then
      echo -e "Тип ${YELLOW}${type}${WHITE} не поддерживается." >&2
      rm -f "$records_tmp"
      return 1
    fi

    value="$(zonefile_record_value "$type" "${tokens[@]:$index}")" || {
      echo -e "Некорректное значение ${YELLOW}${type}${WHITE} в строке: ${YELLOW}${raw_line}${WHITE}" >&2
      rm -f "$records_tmp"
      return 1
    }

    printf '%s\t%s\t%s\t%s\n' "$(zonefile_abs_name "$name" "$origin")" "$type" "$record_ttl" "$value" >> "$records_tmp"
  done < "$zone_file"

  zonefile_emit_grouped < "$records_tmp"
  rm -f "$records_tmp"
}
