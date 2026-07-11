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
      token+="$char"
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

zonefile_validate_quoting() {
  local line="$1"
  local char
  local in_quote=0
  local escaped=0
  local i

  for ((i = 0; i < ${#line}; i++)); do
    char="${line:i:1}"
    if ((escaped)); then
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
    fi
  done

  ((in_quote == 0 && escaped == 0))
}

zonefile_is_type() {
  case "$1" in
    A | AAAA | ALIAS | CAA | CERT | CNAME | DNAME | DS | HINFO | HTTPS | LOC | MX | NAPTR | NS | OPENPGPKEY | PTR | RP | SMIMEA | SOA | SPF | SRV | SSHFP | SVCB | TLSA | TXT | WR)
      return 0
      ;;
  esac

  return 1
}

zonefile_is_ttl() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

zonefile_rewrite_origin_name() {
  local name="$1"
  local source_origin="${ZONEFILE_REWRITE_SOURCE_ORIGIN:-}"
  local target_origin="${ZONEFILE_REWRITE_TARGET_ORIGIN:-}"
  local suffix

  [[ -n "$source_origin" && -n "$target_origin" ]] || {
    printf '%s' "$name"
    return
  }

  source_origin="$(dns_fqdn "$source_origin")"
  target_origin="$(dns_fqdn "$target_origin")"

  if [[ "$name" == "$source_origin" ]]; then
    printf '%s' "$target_origin"
    return
  fi

  suffix=".$source_origin"
  if [[ "$name" == *"$suffix" ]]; then
    printf '%s.%s' "${name%"$suffix"}" "$target_origin"
    return
  fi

  printf '%s' "$name"
}

zonefile_abs_origin() {
  local origin="$1"
  local current_origin="$2"

  if [[ "$origin" == "@" ]]; then
    printf '%s' "$current_origin"
  elif [[ "$origin" == *"." ]]; then
    dns_fqdn "$origin"
  else
    dns_fqdn "${origin}.${current_origin}"
  fi
}

zonefile_abs_name() {
  local name="$1"
  local origin="$2"
  local absolute

  if [[ "$name" == "@" ]]; then
    absolute="$origin"
  elif [[ "$name" == *"." ]]; then
    absolute="$name"
  else
    absolute="${name}.${origin}"
  fi

  zonefile_rewrite_origin_name "$absolute"
}

zonefile_unquote_token() {
  local token="$1"

  if ((${#token} >= 2)) && [[ "$token" == '"'*'"' ]]; then
    token="${token:1:${#token}-2}"
  fi
  printf '%s' "$token"
}

zonefile_strip_grouping_parentheses() {
  local result_var="$1"
  local delta_var="$2"
  local line="$3"
  local output=""
  local char
  local in_quote=0
  local escaped=0
  local delta=0
  local i

  for ((i = 0; i < ${#line}; i++)); do
    char="${line:i:1}"
    if ((escaped)); then
      output+="$char"
      escaped=0
      continue
    fi
    if [[ "$char" == "\\" ]]; then
      output+="$char"
      escaped=1
      continue
    fi
    if [[ "$char" == '"' ]]; then
      output+="$char"
      if ((in_quote)); then
        in_quote=0
      else
        in_quote=1
      fi
      continue
    fi
    if ((in_quote == 0)); then
      if [[ "$char" == "(" ]]; then
        delta=$((delta + 1))
        continue
      fi
      if [[ "$char" == ")" ]]; then
        delta=$((delta - 1))
        continue
      fi
    fi
    output+="$char"
  done

  printf -v "$result_var" '%s' "$output"
  printf -v "$delta_var" '%s' "$delta"
}

zonefile_detect_origin() {
  local zone_file="$1"
  local default_origin="$2"
  local raw_line
  local line
  local -a tokens=()
  local origin

  if [[ ! -f "$zone_file" ]]; then
    echo -e "Файл зоны ${YELLOW}${zone_file}${WHITE} не найден." >&2
    return 1
  fi

  origin="$(dns_fqdn "$default_origin")"

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="$(zonefile_strip_comment "$raw_line")"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue

    mapfile -t tokens < <(zonefile_tokenize "$line")
    ((${#tokens[@]} > 0)) || continue

    if [[ "${tokens[0]}" == '$ORIGIN' && -n "${tokens[1]:-}" ]]; then
      zonefile_abs_origin "${tokens[1]}" "$origin"
      return 0
    fi
  done < "$zone_file"

  dns_fqdn "$default_origin"
}

zonefile_record_value() {
  local type="$1"
  local part
  local value
  shift

  case "$type" in
    MX)
      if (($# < 2)); then
        return 1
      fi
      printf '%s %s' "$1" "$(zonefile_abs_name "$2" "$ZONEFILE_ORIGIN")"
      ;;
    ALIAS | CNAME | DNAME | NS | PTR)
      if (($# < 1)); then
        return 1
      fi
      printf '%s' "$(zonefile_abs_name "$1" "$ZONEFILE_ORIGIN")"
      ;;
    SRV)
      if (($# < 4)); then
        return 1
      fi
      printf '%s %s %s %s' "$1" "$2" "$3" "$(zonefile_abs_name "$4" "$ZONEFILE_ORIGIN")"
      ;;
    HTTPS | SVCB)
      if (($# < 2)); then
        return 1
      fi
      printf '%s %s' "$1" "$(zonefile_abs_name "$2" "$ZONEFILE_ORIGIN")"
      shift 2
      for part in "$@"; do
        printf ' %s' "$part"
      done
      ;;
    RP)
      if (($# < 2)); then
        return 1
      fi
      printf '%s %s' "$(zonefile_abs_name "$1" "$ZONEFILE_ORIGIN")" "$(zonefile_abs_name "$2" "$ZONEFILE_ORIGIN")"
      ;;
    NAPTR)
      if (($# < 6)); then
        return 1
      fi
      printf '%s %s %s %s %s %s' "$1" "$2" "$3" "$4" "$5" "$(zonefile_abs_name "$6" "$ZONEFILE_ORIGIN")"
      ;;
    TXT)
      if (($# < 1)); then
        return 1
      fi
      value=""
      for part in "$@"; do
        value+="$(zonefile_unquote_token "$part")"
      done
      printf '%s' "$value"
      ;;
    A | AAAA)
      if (($# < 1)); then
        return 1
      fi
      printf '%s' "$1"
      ;;
    CAA | CERT | DS | HINFO | LOC | OPENPGPKEY | SMIMEA | SPF | SSHFP | TLSA | WR)
      if (($# < 1)); then
        return 1
      fi
      printf '%s' "$*"
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
  local folded_line
  local logical_line=""
  local line_parenthesis_delta
  local parenthesis_depth=0
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

    zonefile_strip_grouping_parentheses folded_line line_parenthesis_delta "$line"
    if [[ -n "$logical_line" ]]; then
      logical_line+=" ${folded_line}"
    else
      logical_line="$folded_line"
    fi
    parenthesis_depth=$((parenthesis_depth + line_parenthesis_delta))
    if ((parenthesis_depth < 0)); then
      echo -e "Лишняя закрывающая скобка в строке: ${YELLOW}${raw_line}${WHITE}" >&2
      rm -f "$records_tmp"
      return 1
    fi
    if ((parenthesis_depth > 0)); then
      continue
    fi
    line="$logical_line"
    logical_line=""

    if ! zonefile_validate_quoting "$line"; then
      echo -e "В записи DNS-зоны не закрыта кавычка или escape-последовательность: ${YELLOW}${line}${WHITE}" >&2
      rm -f "$records_tmp"
      return 1
    fi

    mapfile -t tokens < <(zonefile_tokenize "$line")
    ((${#tokens[@]} > 0)) || continue

    case "${tokens[0]}" in
      '$ORIGIN')
        if [[ -n "${tokens[1]:-}" ]]; then
          origin="$(zonefile_abs_origin "${tokens[1]}" "$origin")"
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

    if [[ "$type" == "SOA" || "$type" == "NS" ]]; then
      echo -e "${YELLOW}${type}${WHITE} пропущена: ${line}" >&2
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

  if ((parenthesis_depth != 0)); then
    echo -e "В файле зоны не закрыта группа в круглых скобках." >&2
    rm -f "$records_tmp"
    return 1
  fi

  zonefile_emit_grouped < "$records_tmp"
  rm -f "$records_tmp"
}
