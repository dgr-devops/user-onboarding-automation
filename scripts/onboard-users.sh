#!/usr/bin/env bash
# onboard-users.sh — da de alta usuarios a partir de un CSV aplicando una política.
#
# Uso: onboard-users.sh --csv FICHERO [--config POLITICA] [--apply] [-h]
# Por defecto trabaja en modo simulación (--dry-run): valida y muestra qué haría.
# Con --apply (y como root) crea las cuentas. Es idempotente: los usuarios que ya
# existen se omiten sin tocarlos, así que repetir la ejecución no cambia nada.
#
# Las contraseñas temporales NUNCA se muestran ni se registran: solo se escriben en
# un informe accesible únicamente por root (REPORT_DIR, modo 0600).
#
# Códigos de salida: 0 = OK, 2 = validación o creación fallida, 3 = desconocido
# (falta root o una dependencia), 64 = uso incorrecto.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/policy.sh
source "${SCRIPT_DIR}/../lib/policy.sh"
# shellcheck source=../lib/csv.sh
source "${SCRIPT_DIR}/../lib/csv.sh"

readonly DEFAULT_CONFIG="${SCRIPT_DIR}/../config/policy.conf"
# Alfabeto de contraseñas sin caracteres ambiguos (0/O, 1/l/I).
readonly PASSWORD_ALPHABET='A-HJ-NP-Za-km-z2-9'

REPORT_FILE=""
declare -A ALREADY_EXISTS=()

usage() {
  cat <<EOF
Uso: onboard-users.sh --csv FICHERO [--config POLITICA] [--apply] [-h]

Da de alta usuarios desde un CSV (${CSV_HEADER}).

Opciones:
  --csv FICHERO     CSV de entrada (obligatorio)
  --config FICHERO  Política de cuentas (por defecto config/policy.conf)
  --dry-run         Solo valida y muestra lo que haría (modo por defecto)
  --apply           Crea las cuentas de verdad (requiere root)
  -h, --help        Muestra esta ayuda

Códigos de salida: 0 = OK, 2 = error de validación o creación, 3 = desconocido, 64 = uso incorrecto.
EOF
}

# generate_password — contraseña aleatoria que cumple longitud y mezcla de clases.
generate_password() {
  local pw
  while :; do
    # El pipe se corta al llegar a la longitud pedida: SIGPIPE es esperado aquí.
    pw="$(
      set +o pipefail
      head -c 4096 /dev/urandom | LC_ALL=C tr -dc "$PASSWORD_ALPHABET" | head -c "$PASSWORD_LENGTH"
    )"
    if [[ ${#pw} -eq $PASSWORD_LENGTH && "$pw" =~ [A-Z] && "$pw" =~ [a-z] && "$pw" =~ [0-9] ]]; then
      break
    fi
  done
  printf '%s' "$pw"
}

# init_report — crea el informe de contraseñas (solo root) la primera vez que hace falta.
init_report() {
  [[ -n "$REPORT_FILE" ]] && return 0
  mkdir -p "$REPORT_DIR" || return 1
  chmod 0700 "$REPORT_DIR" || return 1
  REPORT_FILE="${REPORT_DIR}/onboarding-$(date '+%Y%m%d-%H%M%S')-$$.csv"
  (umask 077 && printf 'username,temporary_password,account_expires,created_at\n' >"$REPORT_FILE") || return 1
  chmod 0600 "$REPORT_FILE"
}

# report_append <usuario> <contraseña> <caducidad> — añade una línea al informe.
report_append() {
  init_report || return 1
  printf '%s,%s,%s,%s\n' "$1" "$2" "$3" "$(date '+%Y-%m-%dT%H:%M:%S')" >>"$REPORT_FILE"
}

# account_expiry_date — fecha de caducidad de cuentas nuevas, o "-1" si no caducan.
account_expiry_date() {
  if ((ACCOUNT_EXPIRY_DAYS == 0)); then
    echo "-1"
  else
    date -d "+${ACCOUNT_EXPIRY_DAYS} days" '+%F'
  fi
}

# ensure_groups <grupo,grupo...> — crea los grupos permitidos que aún no existen.
ensure_groups() {
  local group
  local IFS=','
  for group in $1; do
    getent group "$group" >/dev/null || groupadd "$group" || return 1
  done
}

# configure_account <usuario> <home> <caducidad> — permisos, contraseña y envejecimiento.
configure_account() {
  local user="$1" home="$2" expiry="$3" password max_days inactive
  max_days="$PASS_MAX_DAYS"
  ((max_days == 0)) && max_days=99999
  inactive="$INACTIVE_DAYS"
  ((inactive == 0)) && inactive=-1
  chmod "$HOME_MODE" "$home" || return 1
  password="$(generate_password)"
  # printf es una función interna de bash: la contraseña no aparece en la lista de procesos.
  printf '%s:%s\n' "$user" "$password" | chpasswd || return 1
  report_append "$user" "$password" "$expiry" || return 1
  chage -m "$PASS_MIN_DAYS" -M "$max_days" -W "$PASS_WARN_DAYS" -I "$inactive" -E "$expiry" "$user" || return 1
  # Último paso: forzar el cambio en el primer inicio de sesión.
  chage -d 0 "$user" || return 1
}

# provision_user <índice> — crea una cuenta; si algo falla a medias, la deshace.
provision_user() {
  local i="$1" user="${CSV_USERNAME[$1]}" shell groups home expiry
  shell="${CSV_SHELL[$i]:-$DEFAULT_SHELL}"
  home="${HOME_BASE}/${user}"
  groups="$(csv_normalized_groups "$i")"
  expiry="$(account_expiry_date)"
  local args=(-m -d "$home" -U -s "$shell" -c "${CSV_FULLNAME[$i]},,,${CSV_DEPARTMENT[$i]}")
  [[ -n "$groups" ]] && args+=(-G "$groups")
  ensure_groups "$groups" || return 1
  useradd "${args[@]}" "$user" || return 1
  if ! configure_account "$user" "$home" "$expiry"; then
    log_warn "Deshaciendo la creación parcial de ${user}"
    userdel -r "$user" >/dev/null 2>&1 || log_error "No se pudo deshacer ${user}; revísalo a mano"
    return 1
  fi
}

# classify_rows — marca los usuarios que ya existen y detecta colisiones peligrosas.
classify_rows() {
  local i user uid
  for i in "${!CSV_USERNAME[@]}"; do
    user="${CSV_USERNAME[$i]}"
    if uid="$(getent passwd "$user" | cut -d: -f3)" && [[ -n "$uid" ]]; then
      if ((uid < MIN_UID)); then
        csv_error "${CSV_LINE[$i]}" "'${user}' es una cuenta de sistema (UID ${uid} < ${MIN_UID}); no se toca"
      else
        ALREADY_EXISTS[$user]=1
      fi
    elif getent group "$user" >/dev/null; then
      csv_error "${CSV_LINE[$i]}" "ya existe un grupo llamado '${user}' sin usuario asociado"
    fi
  done
}

# describe_plan <índice> — línea de simulación para un usuario nuevo.
describe_plan() {
  local i="$1" user="${CSV_USERNAME[$1]}" groups
  groups="$(csv_normalized_groups "$i")"
  emit "crearía ${user} (${CSV_FULLNAME[$i]}, ${CSV_DEPARTMENT[$i]}) grupos=${groups:--} shell=${CSV_SHELL[$i]:-$DEFAULT_SHELL} home=${HOME_BASE}/${user} caduca=$(account_expiry_date)"
}

main() {
  local csv="" config="$DEFAULT_CONFIG" apply=0 i user created=0 skipped=0 failed=0
  while (($# > 0)); do
    case "$1" in
      --csv)
        [[ $# -ge 2 ]] || die "--csv necesita un valor" "$EXIT_USAGE"
        csv="$2"
        shift 2
        ;;
      --config)
        [[ $# -ge 2 ]] || die "--config necesita un valor" "$EXIT_USAGE"
        config="$2"
        shift 2
        ;;
      --apply)
        apply=1
        shift
        ;;
      --dry-run)
        apply=0
        shift
        ;;
      -h | --help)
        usage
        exit "$EXIT_OK"
        ;;
      *)
        log_error "Opción desconocida: $1"
        usage >&2
        exit "$EXIT_USAGE"
        ;;
    esac
  done
  [[ -n "$csv" ]] || {
    usage >&2
    exit "$EXIT_USAGE"
  }

  require_cmd getent useradd userdel groupadd chage chpasswd date tr head cut
  load_policy "$config"
  csv_load "$csv"
  csv_validate_all
  classify_rows
  if ((CSV_ERRORS > 0)); then
    log_error "Validación fallida: ${CSV_ERRORS} error(es). No se ha modificado nada."
    exit "$EXIT_CRITICAL"
  fi

  if ((apply)); then
    require_root "--apply"
    set_mode apply
  else
    set_mode dry-run
  fi

  for i in "${!CSV_USERNAME[@]}"; do
    user="${CSV_USERNAME[$i]}"
    if [[ -n "${ALREADY_EXISTS[$user]:-}" ]]; then
      emit_skip "omitido ${user}: ya existe"
      skipped=$((skipped + 1))
    elif ((apply)); then
      if provision_user "$i"; then
        emit "creado ${user}"
        created=$((created + 1))
      else
        log_error "Falló la creación de ${user}"
        failed=$((failed + 1))
      fi
    else
      describe_plan "$i"
      created=$((created + 1))
    fi
  done

  if ((apply)); then
    printf 'Resumen: creados=%d omitidos=%d errores=%d\n' "$created" "$skipped" "$failed"
    [[ -n "$REPORT_FILE" ]] && printf 'Informe con las contraseñas temporales (solo root): %s\n' "$REPORT_FILE"
  else
    printf 'Resumen (simulación): a_crear=%d omitidos=%d. Usa --apply para ejecutar.\n' "$created" "$skipped"
  fi
  ((failed == 0)) || exit "$EXIT_CRITICAL"
}

main "$@"
