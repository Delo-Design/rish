#!/usr/bin/env bash

GREEN="${GREEN:-$'\033[0;32m'}"
RED="${RED:-$'\033[0;31m'}"
WHITE="${WHITE:-$'\033[0m'}"
YELLOW="${YELLOW:-$'\033[0;33m'}"

RISH_HOME="${RISH_HOME:-/root/rish}"
source "${RISH_HOME}/scripts/user_credentials.sh"

function normalize_relative_document_root() {
  local document_root="$1"

  document_root="${document_root#/}"
  if [[ -n "$document_root" ]]; then
    if [[ "$document_root" == "." || "$document_root" == ".." || "$document_root" == *"/../"* || "$document_root" == "../"* || "$document_root" == *"/.." ]]; then
      echo -e "DocumentRoot ${RED}некорректный${WHITE}: ${document_root}" >&2
      return 1
    fi
  fi

  printf '%s' "$document_root"
}

function validate_site_name() {
  local name="$1"

  echo "$name" | grep -Eq '^([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\.)+[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$' || return 1

  if [[ "$name" =~ (^|\.)xn-- ]]; then
    idn2 -d "$name" > /dev/null 2>&1 || return 1
  fi

  return 0
}

# --strict requires one explicit DocumentRoot in each matching vhost.
# --inherit also matches www and exact aliases and uses the main DocumentRoot
# from the same file for a matching vhost without an explicit root.
# Roots of an exact ServerName are returned before alias roots.
function rish_read_vhost_document_roots() {
  local site_name="$1" strict=0 inherit=0
  shift
  case "${1:-}" in
    --strict) strict=1; shift ;;
    --inherit) inherit=1; shift; (($# == 1)) || return 1 ;;
  esac
  (($#)) || return 1

  awk -v site="$site_name" -v strict="$strict" -v inherit="$inherit" '
    function directive_value(line, quote, length_to_quote) {
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", line)
      quote = substr(line, 1, 1)
      if (quote == "\"" || quote == "\047") {
        line = substr(line, 2)
        length_to_quote = index(line, quote)
        return length_to_quote ? substr(line, 1, length_to_quote - 1) : ""
      }
      sub(/[[:space:]].*$/, "", line)
      return line
    }
    BEGIN {site = tolower(site)}
    FNR == 1 {in_vhost = 0}
    tolower($1) == "<virtualhost" {
      in_vhost = 1; name = ""; root = ""; root_count = 0; alias_matches = 0; next
    }
    tolower($0) ~ /^[[:space:]]*<\/virtualhost[[:space:]]*>/ {
      if (in_vhost && (name == site || ((strict || inherit) && (name == "www." site || alias_matches)))) {
        found = 1
        if (name == site) found_exact = 1
        if (strict && (root_count != 1 || root == "")) invalid = 1
        roots[++count] = root
        priority[count] = name == site ? 1 : 2
        uses_main_root[count] = inherit && root_count == 0
      }
      in_vhost = 0
      next
    }
    in_vhost && tolower($1) == "servername" && NF >= 2 {
      name = tolower(directive_value($0))
      sub(/^[^:]+:\/\//, "", name)
      sub(/:[0-9]+$/, "", name)
      sub(/\.$/, "", name)
    }
    in_vhost && (strict || inherit) && tolower($1) == "serveralias" {
      for (i = 2; i <= NF && $i !~ /^#/; i++) {
        alias = tolower($i)
        gsub(/^["\047]|["\047]$/, "", alias)
        sub(/\.$/, "", alias)
        if (alias == site || alias == "www." site) alias_matches = 1
      }
    }
    tolower($1) == "documentroot" {
      if (in_vhost) {
        root_count++
        if (NF >= 2) root = directive_value($0)
      } else if (inherit && NF >= 2) {
        main_root = directive_value($0)
      }
    }
    END {
      if (invalid) exit 2
      if (!found) exit 1
      for (rank = 1; rank <= 2; rank++) {
        # An alias is not a fallback for an exact vhost with an unknown root.
        if (inherit && rank == 2 && found_exact && !printed_exact) break
        for (i = 1; i <= count; i++) {
          if (priority[i] != rank) continue
          root = uses_main_root[i] ? main_root : roots[i]
          if (root == "" || (root in printed)) continue
          printed[root] = 1
          if (rank == 1) printed_exact = 1
          print root
        }
      }
    }
  ' "$@"
}

function rish_get_site_document_root() {
  local site_name="$1"
  local vhost_file="/etc/httpd/conf.d/${site_name}.conf"
  local document_root

  validate_site_name "$site_name" || return 1
  [[ -f "$vhost_file" ]] || return 1

  document_root="$(rish_read_vhost_document_roots "$site_name" --inherit "$vhost_file")" || return 1
  document_root="${document_root%%$'\n'*}"
  document_root="$(realpath -e -- "$document_root" 2>/dev/null)" || return 1
  [[ -d "$document_root" ]] || return 1
  [[ "$document_root" == /var/www/* ]] || return 1

  printf '%s\n' "$document_root"
}

function rish_get_site_user() {
  local site_path="$1"
  local user
  local user_id
  local user_home
  local credentials_file

  if [[ "$site_path" =~ ^/var/www/([^/]+)/www(/.*)?$ ]]; then
    user="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  user_id="$(id -u "$user" 2>/dev/null)" || return 1
  [[ "$user_id" =~ ^[0-9]+$ ]] || return 1
  ((user_id > 0)) || return 1

  if ! id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq sftp; then
    return 1
  fi

  user_home="$(getent passwd "$user" | awk -F: '{ print $6; exit }')"
  [[ "$user_home" == "/home/${user}" && -d "$user_home" && ! -L "$user_home" ]] || return 1

  credentials_file="$(rish_credentials_file "$user")" || return 1
  rish_credentials_file_is_secure "$credentials_file" || return 1

  printf '%s\n' "$user"
}

function db_exists() {
  local dbname="$1"
  local found

  found="$(mariadb -N -e "SHOW DATABASES LIKE '${dbname}'" 2>/dev/null)"
  [[ "$found" == "$dbname" ]]
}

function create_database_for_user() {
  local dbname="$1"
  local user="$2"

  if db_exists "$dbname"; then
    echo -e "База данных ${GREEN}${dbname}${WHITE} уже существует."
  else
    echo -e "Создаем базу данных ${GREEN}${dbname}${WHITE}."
    if ! mariadb -e "CREATE DATABASE \`${dbname}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
      echo -e "Не удалось создать базу данных ${RED}${dbname}${WHITE}."
      return 1
    fi
  fi

  echo -e "Выдаем права на базу ${GREEN}${dbname}${WHITE} пользователю ${GREEN}${user}${WHITE}."
  if ! mariadb -e "GRANT ALL PRIVILEGES ON \`${dbname}\`.* TO '${user}'@'localhost';"; then
    echo -e "Не удалось выдать права на базу ${RED}${dbname}${WHITE} пользователю ${RED}${user}${WHITE}."
    return 1
  fi
  mariadb -e "FLUSH PRIVILEGES;"
}

function import_database_file() {
  local file="$1"
  local dbname="$2"
  local -a import_cmd=(mariadb)

  if [[ ! -f "$file" ]]; then
    echo -e "Файл дампа базы не найден: ${RED}${file}${WHITE}"
    return 1
  fi

  if mariadb --help | grep -q -- "--sandbox"; then
    import_cmd+=(--sandbox)
  fi
  import_cmd+=("$dbname")

  echo -e "Импортируем базу ${GREEN}${dbname}${WHITE} из файла ${GREEN}$(basename "$file")${WHITE}."

  if [[ "$file" == *.gz ]]; then
    if ! gzip -t "$file"; then
      echo -e "Файл ${RED}$(basename "$file")${WHITE} поврежден или не является gzip-архивом."
      return 1
    fi
    if ! (set -o pipefail; gunzip -c "$file" | "${import_cmd[@]}"); then
      echo -e "Произошла ${RED}ошибка${WHITE} при импорте базы ${RED}${dbname}${WHITE}."
      return 1
    fi
  else
    if ! "${import_cmd[@]}" < "$file"; then
      echo -e "Произошла ${RED}ошибка${WHITE} при импорте базы ${RED}${dbname}${WHITE}."
      return 1
    fi
  fi

  echo -e "База данных ${GREEN}${dbname}${WHITE} успешно импортирована."
}

function fix_joomla_configuration() {
  local site_path="$1"
  local site_name="$2"
  local db_name="${3:-$site_name}"

  local config_file="${site_path}/${site_name}/configuration.php"
  local site_full_path="${site_path}/${site_name}"

  echo -e "Настройка файла ${GREEN}configuration.php${WHITE}..."

  local user="${site_path#/var/www/}"
  user="${user%%/*}"

  local database_pass=""
  local credentials_file

  credentials_file="$(rish_credentials_file "$user")" || return 1
  if ! database_pass="$(read_user_credential "$user" "MariaDB" "Password")" || [[ -z "$database_pass" ]]; then
    echo -e "${RED}Не удалось прочитать пароль базы данных:${WHITE} ${credentials_file}"
    return 1
  fi

  sed -i "s|\$password.*$|\$password = '${database_pass}';|" "$config_file"
  echo -e "Пароль базы данных обновлен."

  sed -i "s|\$user.*$|\$user = '${user}';|" "$config_file"
  echo -e "Имя пользователя БД: ${GREEN}${user}${WHITE}"

  sed -i "s|\$db .*$|\$db = '${db_name}';|" "$config_file"
  echo -e "Имя базы данных: ${GREEN}${db_name}${WHITE}"

  sed -i "s|\$log_path .*$|\$log_path = '${site_full_path}/administrator/logs';|" "$config_file"
  echo -e "log_path: ${GREEN}${site_full_path}/administrator/logs${WHITE}"

  sed -i "s|\$tmp_path .*$|\$tmp_path = '${site_full_path}/tmp';|" "$config_file"
  echo -e "tmp_path: ${GREEN}${site_full_path}/tmp${WHITE}"

  sed -i "s|\$host.*$|\$host = 'localhost';|" "$config_file"
  echo -e "Хост базы данных установлен в: ${GREEN}localhost${WHITE}"

  local live_site_line=""
  local live_site_value=""

  live_site_line="$(grep -m 1 '^[[:space:]]*\(public[[:space:]]\+\)\?\$live_site[[:space:]]*=' "$config_file" || true)"
  if [[ -z "$live_site_line" ]]; then
    echo -e "Строка ${YELLOW}live_site${WHITE} не найдена."
  elif printf '%s\n' "$live_site_line" | grep -q "^[[:space:]]*\\(public[[:space:]]\\+\\)\\?\\\$live_site[[:space:]]*=[[:space:]]*''"; then
    echo -e "${YELLOW}live_site${WHITE} пустой, сброс не требуется."
  else
    live_site_value="$(printf '%s\n' "$live_site_line" | sed -n "s/^[[:space:]]*\\(public[[:space:]]\\+\\)\\?\\\$live_site[[:space:]]*=[[:space:]]*'\\([^']*\\)'.*/\\2/p")"
    if ! sed -i "s|\$live_site[[:space:]]*=.*$|\$live_site = '';|" "$config_file"; then
      echo -e "Не удалось сбросить ${RED}live_site${WHITE}."
      return 1
    fi
    if [[ -n "$live_site_value" ]]; then
      echo -e "${YELLOW}live_site${WHITE} сброшен: ${GREEN}${live_site_value}${WHITE} -> пусто."
    else
      echo -e "${YELLOW}live_site${WHITE} сброшен."
    fi
  fi
}

function rish_joomla_root_from_public_directory() {
  local joomla_root="$1" public_path="$2"
  local index_file="$public_path/index.php" defines_file="$public_path/defines.php"
  local relative_path line root_expression="" public_expression="" public_base=""
  local bound_root bound_public resolved_root resolved_public
  local define_pattern="^[[:space:]]*\\\\?define[[:space:]]*\([[:space:]]*('JPATH_ROOT'|\"JPATH_ROOT\"|'JPATH_PUBLIC'|\"JPATH_PUBLIC\")[[:space:]]*,[[:space:]]*(.*[^[:space:]])[[:space:]]*\)[[:space:]]*;[[:space:]]*$"
  local relative_root_pattern='^\\?dirname[[:space:]]*\([[:space:]]*__DIR__[[:space:]]*\)$'
  local relative_public_pattern='^JPATH_ROOT[[:space:]]*\.[[:space:]]*(.+)$'
  local path_pattern="^('(/[^']*)'|\"(/[^\"\$]*)\")$"

  [[ "$public_path" == "$joomla_root/"* ]] || return 1
  relative_path="${public_path#"$joomla_root/"}"
  [[ "$relative_path" != */* && "$public_path" != *[[:cntrl:]]* &&
    -f "$index_file" && ! -L "$index_file" && -f "$defines_file" && ! -L "$defines_file" ]] || return 1
  grep -Eq -- "^[[:space:]]*require_once[[:space:]]+__DIR__[[:space:]]*\.[[:space:]]*('/defines\.php'|\"/defines\.php\")[[:space:]]*;" "$index_file" &&
    grep -Eq -- "^[[:space:]]*require_once[[:space:]]+JPATH_BASE[[:space:]]*\.[[:space:]]*('/index\.php'|\"/index\.php\")[[:space:]]*;" "$index_file" || return 1

  # Читаем только стандартные объявления Joomla, без выполнения PHP.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $define_pattern ]] || continue
    case "${BASH_REMATCH[1]}" in
      *JPATH_ROOT*)
        [[ -z "$root_expression" ]] || return 1
        root_expression="${BASH_REMATCH[2]}"
        ;;
      *JPATH_PUBLIC*)
        [[ -z "$public_expression" ]] || return 1
        public_expression="${BASH_REMATCH[2]}"
        ;;
    esac
  done < "$defines_file"

  if [[ "$root_expression" =~ $relative_root_pattern && "$public_expression" =~ $relative_public_pattern ]]; then
    public_expression="${BASH_REMATCH[1]}"
    bound_root="$joomla_root"
    public_base="$joomla_root"
  elif [[ "$root_expression" =~ $path_pattern ]]; then
    bound_root="${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
  else
    return 1
  fi
  [[ "$public_expression" =~ $path_pattern ]] || return 1
  bound_public="${public_base}${BASH_REMATCH[2]:-${BASH_REMATCH[3]}}"
  [[ "$bound_root$bound_public" != *\\* && "$bound_root$bound_public" != *[[:cntrl:]]* ]] || return 1

  if resolved_root="$(realpath -e -- "$bound_root" 2>/dev/null)" &&
    resolved_public="$(realpath -e -- "$bound_public" 2>/dev/null)" &&
    [[ "$resolved_root" == "$joomla_root" && "$resolved_public" == "$public_path" ]]; then
    printf '%s\n' "$joomla_root"
    return 0
  fi

  # При абсолютной установке обе декларации могут указывать на исходное размещение сайта.
  [[ -z "$public_base" && "$resolved_root" != "$joomla_root" ]] || return 1
  bound_root="$(realpath -ms -- "$bound_root")" || return 1
  bound_public="$(realpath -ms -- "$bound_public")" || return 1
  [[ "$bound_root" != "$joomla_root" && "$bound_public" == "${bound_root%/}/$relative_path" ]] || return 1
  printf '%s\n' "$bound_root"
}

function fix_site_configuration() {
  local site_path="$1"
  local site_name="$2"
  local public_folder_result="${3:-}"
  local full_path="${site_path}/${site_name}"
  local joomla_root document_root resolved_root vhost_file vhost_paths defines_file public_path bound_root
  local candidate public_path_color="$GREEN" document_root_mismatch=0
  local -a vhost_files=() public_paths=() active_paths=()
  local -a vhost_options=()
  local -A bound_roots=() apache_roots=()

  if [[ ! -f "$full_path/configuration.php" ]]; then
    echo -e "CMS config для автоматической настройки не найден в ${YELLOW}${full_path}${WHITE}."
    return 0
  fi

  if [[ -f "$full_path/administrator/manifests/files/joomla.xml" ]] &&
    joomla_root="$(realpath -e -- "$full_path" 2>/dev/null)"; then
    while IFS= read -r -d '' defines_file; do
      public_path="${defines_file%/*}"
      if bound_root="$(rish_joomla_root_from_public_directory "$joomla_root" "$public_path")"; then
        public_paths+=("$public_path")
        bound_roots["$public_path"]="$bound_root"
      fi
    done < <(find -P "$joomla_root" -mindepth 2 -maxdepth 2 -name defines.php -type f -print0)
  fi

  echo
  if ((${#public_paths[@]})); then
    echo -e "CMS определена как ${GREEN}Joomla с отдельной публичной папкой${WHITE}."
  else
    echo -e "CMS определена как ${GREEN}Joomla${WHITE} - выполняем настройку..."
  fi
  fix_joomla_configuration "$site_path" "$site_name" || return
  ((${#public_paths[@]})) || return 0

  for vhost_file in /etc/httpd/conf.d/*.conf; do
    [[ -f "$vhost_file" && -r "$vhost_file" ]] && vhost_files+=("$vhost_file")
  done
  [[ -z "$public_folder_result" ]] || vhost_options=(--strict)
  if vhost_paths="$(rish_read_vhost_document_roots "$site_name" "${vhost_options[@]}" "${vhost_files[@]}")"; then
    while IFS= read -r document_root; do
      [[ -n "$document_root" ]] || continue
      resolved_root="$document_root"
      if [[ "$document_root" == /* ]]; then
        resolved_root="$(realpath -e -- "$document_root" 2>/dev/null)" || resolved_root="$document_root"
      fi
      apache_roots["$resolved_root"]="$document_root"
    done <<< "$vhost_paths"
  fi

  for public_path in "${public_paths[@]}"; do
    if [[ "${bound_roots[$public_path]}" == "$joomla_root" && -n "${apache_roots[$public_path]:-}" ]]; then
      active_paths+=("$public_path")
    fi
  done
  if ((${#active_paths[@]} == 1)); then
    public_paths=("${active_paths[0]}")
  fi

  candidate="${public_paths[0]}"
  if ((${#public_paths[@]} > 1 || ${#apache_roots[@]} != 1)) || [[ -z "${apache_roots[$candidate]:-}" ]]; then
    document_root_mismatch=1
    public_path_color="$YELLOW"
    printf '\n'
  fi
  for public_path in "${public_paths[@]}"; do
    printf 'Публичная папка Joomla: %b%s%b\n' "$public_path_color" "$public_path" "$WHITE"
    if [[ "${bound_roots[$public_path]}" != "$joomla_root" ]]; then
      printf 'В %b%s%b указаны абсолютные пути исходной установки. Проверьте их и ссылки на публичные файлы.\n' \
        "$YELLOW" "$public_path/defines.php" "$WHITE"
    fi
  done

  if ((document_root_mismatch)); then
    if [[ -n "$public_folder_result" && "${#public_paths[@]}" == 1 && "${bound_roots[$candidate]}" == "$joomla_root" ]]; then
      printf -v "$public_folder_result" '%s' "$candidate"
      printf '\n'
      return 0
    fi
    if ((${#apache_roots[@]})); then
      for document_root in "${apache_roots[@]}"; do
        printf 'Текущий DocumentRoot: %b%s%b\n' "$YELLOW" "$document_root" "$WHITE"
      done
    else
      echo 'Не удалось определить текущий DocumentRoot.'
    fi
    echo 'Укажите нужную папку через F2 → Публичная папка сайта (DocumentRoot).'
  fi
}
