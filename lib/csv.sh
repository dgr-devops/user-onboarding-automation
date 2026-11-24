#!/usr/bin/env bash
# lib/csv.sh — lectura y validación del CSV de usuarios.
# Requiere lib/common.sh y lib/policy.sh (política ya cargada).
#
# Formato: username,full_name,department,groups,shell
#  - Separador de campos: coma. No se admiten comas dentro de un campo.
#  - Varios grupos en el campo groups: separados por ";" (p. ej. developers;support).
#  - Líneas vacías y que empiezan por "#" se ignoran. Se tolera fin de línea CRLF.

# shellcheck disable=SC2034

readonly CSV_HEADER="username,full_name,department,groups,shell"
readonly CSV_FIELDS=5

# Datos cargados, un elemento por fila de datos.
declare -a CSV_LINE=() CSV_USERNAME=() CSV_FULLNAME=() CSV_DEPARTMENT=() CSV_GROUPS=() CSV_SHELL=()
CSV_ERRORS=0

# csv_error <línea> <mensaje> — registra un error de validación.
csv_error() {
  log_error "línea $1: $2"
  CSV_ERRORS=$((CSV_ERRORS + 1))
}

# csv_load <fichero> — carga las filas en los arrays CSV_*. Errores estructurales
# (cabecera, nº de campos) se cuentan en CSV_ERRORS; la carga continúa para
# informar de todos los fallos a la vez.
csv_load() {
  local file="$1" line lineno=0 header_seen=0 commas
  local f_user f_name f_dept f_groups f_shell f_extra
  [[ -r "$file" ]] || die "No se puede leer el CSV: ${file}" "$EXIT_USAGE"
  CSV_LINE=() CSV_USERNAME=() CSV_FULLNAME=() CSV_DEPARTMENT=() CSV_GROUPS=() CSV_SHELL=()
  CSV_ERRORS=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    [[ -z "$(trim "$line")" || "$(trim "$line")" == \#* ]] && continue
    if ((header_seen == 0)); then
      header_seen=1
      [[ "$(trim "$line")" == "$CSV_HEADER" ]] ||
        die "Cabecera inválida en la línea ${lineno}. Se esperaba: ${CSV_HEADER}" "$EXIT_CRITICAL"
      continue
    fi
    commas="${line//[^,]/}"
    if ((${#commas} != CSV_FIELDS - 1)); then
      csv_error "$lineno" "se esperaban ${CSV_FIELDS} campos separados por coma"
      continue
    fi
    IFS=',' read -r f_user f_name f_dept f_groups f_shell f_extra <<<"$line"
    CSV_LINE+=("$lineno")
    CSV_USERNAME+=("$(trim "$f_user")")
    CSV_FULLNAME+=("$(trim "$f_name")")
    CSV_DEPARTMENT+=("$(trim "$f_dept")")
    CSV_GROUPS+=("$(trim "$f_groups")")
    CSV_SHELL+=("$(trim "$f_shell")")
  done <"$file"
  ((header_seen == 1)) || die "El CSV está vacío o no tiene cabecera: ${file}" "$EXIT_CRITICAL"
}

# csv_validate_usernames — solo formato y duplicados (offboard y audit).
csv_validate_usernames() {
  local i user
  declare -A seen=()
  for i in "${!CSV_USERNAME[@]}"; do
    user="${CSV_USERNAME[$i]}"
    if [[ ! "$user" =~ $USERNAME_REGEX ]]; then
      csv_error "${CSV_LINE[$i]}" "usuario '${user}' no cumple ${USERNAME_REGEX}"
    elif [[ -n "${seen[$user]:-}" ]]; then
      csv_error "${CSV_LINE[$i]}" "usuario '${user}' duplicado (primera vez en la línea ${seen[$user]})"
    else
      seen[$user]="${CSV_LINE[$i]}"
    fi
  done
}

# csv_validate_row <índice> — valida nombre, departamento, grupos y shell de una fila.
csv_validate_row() {
  local i="$1" line="${CSV_LINE[$1]}" name dept groups shell group
  name="${CSV_FULLNAME[$i]}"
  dept="${CSV_DEPARTMENT[$i]}"
  groups="${CSV_GROUPS[$i]}"
  shell="${CSV_SHELL[$i]:-$DEFAULT_SHELL}"
  # El nombre va al campo GECOS de /etc/passwd: ni ":" ni caracteres de control.
  if [[ -z "$name" || "$name" == *:* || "$name" =~ [[:cntrl:]] || ${#name} -gt 80 ]]; then
    csv_error "$line" "full_name vacío, de más de 80 caracteres o con caracteres no permitidos (':' o control)"
  fi
  if [[ ! "$dept" =~ ^[A-Za-z0-9\ _-]{1,40}$ ]]; then
    csv_error "$line" "department vacío o con caracteres no permitidos (letras, números, espacio, _ y -)"
  fi
  for group in $(split_groups "$groups"); do
    in_list "$group" "$ALLOWED_GROUPS" ||
      csv_error "$line" "grupo '${group}' no permitido (permitidos: ${ALLOWED_GROUPS})"
  done
  if ! in_list "$shell" "$ALLOWED_SHELLS"; then
    csv_error "$line" "shell '${shell}' no permitida (permitidas: ${ALLOWED_SHELLS})"
  elif [[ ! -x "$shell" ]]; then
    csv_error "$line" "shell '${shell}' no está instalada en este sistema"
  fi
}

# csv_validate_all — valida todas las filas (formato, duplicados, campos). Los usuarios
# ya existentes se tratan en onboard-users.sh, que es quien conoce el estado del sistema.
csv_validate_all() {
  local i
  csv_validate_usernames
  for i in "${!CSV_USERNAME[@]}"; do
    csv_validate_row "$i"
  done
}

# split_groups <a;b;c> — un grupo por línea, sin espacios ni vacíos.
split_groups() {
  local -a parts=()
  local part
  IFS=';' read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    part="$(trim "$part")"
    [[ -z "$part" ]] || printf '%s\n' "$part"
  done
}

# csv_normalized_groups <índice> — grupos de la fila separados por coma, sin espacios.
csv_normalized_groups() {
  split_groups "${CSV_GROUPS[$1]}" | paste -sd, -
}
