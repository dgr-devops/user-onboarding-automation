#!/usr/bin/env bash
# lib/policy.sh — carga y valida el fichero de política (config/policy.conf).
# Requiere lib/common.sh. El fichero es KEY=value: NO se ejecuta (sin source/eval).

# shellcheck disable=SC2034

readonly POLICY_KEYS=(
  USERNAME_REGEX ALLOWED_GROUPS ALLOWED_SHELLS DEFAULT_SHELL MIN_UID HOME_BASE
  HOME_MODE PASSWORD_LENGTH PASS_MAX_DAYS PASS_MIN_DAYS PASS_WARN_DAYS
  INACTIVE_DAYS ACCOUNT_EXPIRY_DAYS REPORT_DIR ARCHIVE_DIR
)

# Valores por defecto: los mismos que config/policy.conf.example.
policy_defaults() {
  USERNAME_REGEX='^[a-z][a-z0-9._-]{2,31}$'
  ALLOWED_GROUPS="developers sysadmin support"
  ALLOWED_SHELLS="/bin/bash /bin/sh /usr/sbin/nologin"
  DEFAULT_SHELL="/bin/bash"
  MIN_UID=1000
  HOME_BASE="/home"
  HOME_MODE="0750"
  PASSWORD_LENGTH=20
  PASS_MAX_DAYS=90
  PASS_MIN_DAYS=1
  PASS_WARN_DAYS=14
  INACTIVE_DAYS=30
  ACCOUNT_EXPIRY_DAYS=365
  REPORT_DIR="/var/lib/user-onboarding"
  ARCHIVE_DIR="/var/backups/offboarding"
}

# policy_set <clave> <valor> — asigna una clave permitida; ignora cualquier otra con error.
policy_set() {
  local key="$1" value="$2"
  in_list "$key" "${POLICY_KEYS[*]}" || return 1
  # Comillas simples o dobles envolventes opcionales.
  if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  printf -v "$key" '%s' "$value"
}

# validate_policy — comprueba tipos y rangos; aborta con el primer problema.
validate_policy() {
  local key
  for key in MIN_UID PASSWORD_LENGTH PASS_MAX_DAYS PASS_MIN_DAYS PASS_WARN_DAYS \
    INACTIVE_DAYS ACCOUNT_EXPIRY_DAYS; do
    is_uint "${!key}" || die "Política: ${key} debe ser un entero no negativo (valor: '${!key}')" "$EXIT_USAGE"
  done
  ((PASSWORD_LENGTH >= 12 && PASSWORD_LENGTH <= 64)) ||
    die "Política: PASSWORD_LENGTH debe estar entre 12 y 64" "$EXIT_USAGE"
  ((PASS_MIN_DAYS <= PASS_MAX_DAYS)) ||
    die "Política: PASS_MIN_DAYS no puede superar PASS_MAX_DAYS" "$EXIT_USAGE"
  ((MIN_UID >= 500)) || die "Política: MIN_UID debe ser >= 500 (protege cuentas de sistema)" "$EXIT_USAGE"
  [[ "$HOME_MODE" =~ ^[0-7]{3,4}$ ]] || die "Política: HOME_MODE no es un modo octal válido" "$EXIT_USAGE"
  [[ "$HOME_BASE" =~ ^/[^[:space:]]+$ && "$HOME_BASE" != *".."* ]] ||
    die "Política: HOME_BASE debe ser una ruta absoluta distinta de /" "$EXIT_USAGE"
  [[ "$REPORT_DIR" == /* && "$ARCHIVE_DIR" == /* ]] ||
    die "Política: REPORT_DIR y ARCHIVE_DIR deben ser rutas absolutas" "$EXIT_USAGE"
  in_list "$DEFAULT_SHELL" "$ALLOWED_SHELLS" ||
    die "Política: DEFAULT_SHELL (${DEFAULT_SHELL}) no está en ALLOWED_SHELLS" "$EXIT_USAGE"
  # grep -E devuelve 2 ante una expresión regular inválida (1 = sin coincidencia, es válido).
  local rc=0
  grep -Eq -- "$USERNAME_REGEX" <<<"" || rc=$?
  ((rc != 2)) || die "Política: USERNAME_REGEX no es una expresión regular válida" "$EXIT_USAGE"
}

# load_policy <fichero> — carga el fichero sobre los valores por defecto y lo valida.
load_policy() {
  local file="$1" line key value lineno=0
  [[ -r "$file" ]] || die "No se puede leer la política: ${file} (copia config/policy.conf.example)" "$EXIT_USAGE"
  policy_defaults
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "Política: línea ${lineno} no tiene formato CLAVE=valor" "$EXIT_USAGE"
    key="${BASH_REMATCH[1]}"
    value="$(trim "${BASH_REMATCH[2]}")"
    policy_set "$key" "$value" || die "Política: clave desconocida '${key}' (línea ${lineno})" "$EXIT_USAGE"
  done <"$file"
  validate_policy
}
