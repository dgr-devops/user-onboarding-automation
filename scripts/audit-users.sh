#!/usr/bin/env bash
# audit-users.sh — compara las cuentas del sistema con el CSV y la política.
#
# Uso: audit-users.sh --csv FICHERO [--config POLITICA] [-h]
# Solo lee: no modifica nada. Necesita root para leer /etc/shadow.
#
# Hallazgos:
#   CRITICAL  usuario del CSV que no existe; cuenta fuera del CSV y sin bloquear
#   WARNING   cuenta bloqueada o caducada, contraseña más vieja que PASS_MAX_DAYS,
#             política de envejecimiento distinta, shell/grupos/home distintos del CSV,
#             cuenta fuera del CSV pero ya bloqueada (baja pendiente de limpiar)
#
# Códigos de salida (convenio Nagios): 0 = OK, 1 = WARNING, 2 = CRITICAL,
# 3 = desconocido (falta root o una dependencia), 64 = uso incorrecto.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/policy.sh
source "${SCRIPT_DIR}/../lib/policy.sh"
# shellcheck source=../lib/csv.sh
source "${SCRIPT_DIR}/../lib/csv.sh"

readonly DEFAULT_CONFIG="${SCRIPT_DIR}/../config/policy.conf"
# Por encima de este UID están nobody y cuentas especiales, no usuarios humanos.
readonly MAX_HUMAN_UID=60000
# Valor de PASS_MAX_DAYS que Debian usa para "sin límite".
readonly NO_LIMIT_DAYS=99999

WORST=$EXIT_OK
COUNT_WARNING=0
COUNT_CRITICAL=0
USER_STATUS_WARN=0
OK_USERS=0

usage() {
  cat <<EOF
Uso: audit-users.sh --csv FICHERO [--config POLITICA] [-h]

Audita las cuentas frente al CSV y la política (solo lectura, requiere root).

Opciones:
  --csv FICHERO     CSV de referencia (obligatorio)
  --config FICHERO  Política de cuentas (por defecto config/policy.conf)
  -h, --help        Muestra esta ayuda

Códigos de salida: 0 = OK, 1 = WARNING, 2 = CRITICAL, 3 = desconocido, 64 = uso incorrecto.
EOF
}

# finding <WARNING|CRITICAL> <usuario> <mensaje> — registra y muestra un hallazgo.
finding() {
  local level="$1" user="$2" msg="$3"
  printf '%-8s %-16s %s\n' "$level" "$user" "$msg"
  if [[ "$level" == "CRITICAL" ]]; then
    COUNT_CRITICAL=$((COUNT_CRITICAL + 1))
    WORST=$EXIT_CRITICAL
  else
    COUNT_WARNING=$((COUNT_WARNING + 1))
    ((WORST >= EXIT_WARNING)) || WORST=$EXIT_WARNING
  fi
  USER_STATUS_WARN=1
}

# sorted_csv <lista separada por comas> — ordena y deduplica para comparar conjuntos.
sorted_csv() {
  tr ',' '\n' <<<"$1" | sed '/^$/d' | sort -u | paste -sd, -
}

# actual_groups <usuario> — grupos suplementarios (sin el grupo primario), separados por coma.
actual_groups() {
  local user="$1" primary group out=""
  primary="$(id -gn "$user")"
  for group in $(id -nG "$user"); do
    [[ "$group" == "$primary" ]] || out+="${out:+,}${group}"
  done
  printf '%s' "$out"
}

# check_password <usuario> <hash> <último cambio> <máx. días> — bloqueo y envejecimiento.
check_password() {
  local user="$1" pw="$2" lastchg="$3" max_days="$4" age
  [[ "$pw" == '!'* ]] && finding WARNING "$user" "cuenta bloqueada"
  if [[ "$lastchg" == "0" ]]; then
    # Estado normal de una cuenta recién creada: se informa pero no es un hallazgo.
    printf '%-8s %-16s %s\n' "INFO" "$user" "cambio de contraseña pendiente (aún no ha entrado)"
  elif [[ "$lastchg" =~ ^[0-9]+$ && -n "$max_days" && "$max_days" -lt "$NO_LIMIT_DAYS" ]]; then
    age=$(($(today_days) - lastchg))
    ((age > max_days)) && finding WARNING "$user" "contraseña de ${age} días (máximo ${max_days})"
  fi
  if ((PASS_MAX_DAYS > 0)) && [[ "$max_days" != "$PASS_MAX_DAYS" ]]; then
    finding WARNING "$user" "PASS_MAX_DAYS=${max_days:-vacío}, la política exige ${PASS_MAX_DAYS}"
  fi
}

# check_expiry <usuario> <expire> — caducidad de la cuenta.
check_expiry() {
  local user="$1" expire="$2"
  if [[ "$expire" =~ ^[0-9]+$ ]] && (($(today_days) >= expire)); then
    finding WARNING "$user" "cuenta caducada el $(date -d "@$((expire * 86400))" '+%F')"
  fi
}

# check_account <usuario> <índice CSV> — compara una cuenta existente con su fila del CSV.
check_account() {
  local user="$1" i="$2" uid shell home expected_shell expected_groups actual
  local sh_pw sh_lastchg sh_max sh_expire
  IFS=: read -r _ _ uid _ _ home shell <<<"$(getent passwd "$user")"
  if ((uid < MIN_UID)); then
    finding CRITICAL "$user" "es una cuenta de sistema (UID ${uid}), no debería estar en el CSV"
    return
  fi
  IFS=: read -r _ sh_pw sh_lastchg _ sh_max _ _ sh_expire <<<"$(getent shadow "$user")"
  check_password "$user" "$sh_pw" "$sh_lastchg" "$sh_max"
  check_expiry "$user" "$sh_expire"
  expected_shell="${CSV_SHELL[$i]:-$DEFAULT_SHELL}"
  [[ "$shell" == "$expected_shell" ]] || finding WARNING "$user" "shell ${shell} (CSV: ${expected_shell})"
  expected_groups="$(sorted_csv "$(csv_normalized_groups "$i")")"
  actual="$(sorted_csv "$(actual_groups "$user")")"
  [[ "$actual" == "$expected_groups" ]] ||
    finding WARNING "$user" "grupos '${actual:--}' (CSV: '${expected_groups:--}')"
  [[ -d "$home" ]] || finding WARNING "$user" "el home ${home} no existe"
}

# audit_csv_users — cada usuario del CSV: existencia y estado.
audit_csv_users() {
  local i user ok=0
  for i in "${!CSV_USERNAME[@]}"; do
    user="${CSV_USERNAME[$i]}"
    USER_STATUS_WARN=0
    if ! getent passwd "$user" >/dev/null; then
      finding CRITICAL "$user" "falta: está en el CSV pero no existe en el sistema"
    else
      check_account "$user" "$i"
    fi
    if ((USER_STATUS_WARN == 0)); then
      printf '%-8s %-16s %s\n' "OK" "$user" "conforme con el CSV y la política"
      ok=$((ok + 1))
    fi
  done
  OK_USERS=$ok
}

# audit_extra_users — cuentas con UID de usuario que no están en el CSV.
audit_extra_users() {
  local name uid pw
  declare -A in_csv=()
  for name in "${CSV_USERNAME[@]}"; do in_csv[$name]=1; done
  while IFS=: read -r name _ uid _; do
    ((uid >= MIN_UID && uid < MAX_HUMAN_UID)) || continue
    [[ -z "${in_csv[$name]:-}" ]] || continue
    pw="$(getent shadow "$name" | cut -d: -f2)"
    if [[ "$pw" == '!'* ]]; then
      finding WARNING "$name" "fuera del CSV pero bloqueada (baja pendiente de limpiar)"
    else
      finding CRITICAL "$name" "fuera del CSV y con la cuenta activa"
    fi
  done < <(getent passwd)
}

main() {
  local csv="" config="$DEFAULT_CONFIG"
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

  require_cmd getent id sed sort paste tr cut date
  require_root "La auditoría (lee /etc/shadow)"
  load_policy "$config"
  csv_load "$csv"
  csv_validate_usernames
  if ((CSV_ERRORS > 0)); then
    log_error "CSV inválido: ${CSV_ERRORS} error(es). No se puede auditar."
    exit "$EXIT_CRITICAL"
  fi

  audit_csv_users
  audit_extra_users
  printf 'Resumen: usuarios_csv=%d conformes=%d warning=%d critical=%d\n' \
    "${#CSV_USERNAME[@]}" "$OK_USERS" "$COUNT_WARNING" "$COUNT_CRITICAL"
  exit "$WORST"
}

main "$@"
