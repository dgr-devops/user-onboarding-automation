#!/usr/bin/env bash
# offboard-users.sh — da de baja usuarios: bloquea, caduca y archiva el home.
#
# Uso: offboard-users.sh (--csv FICHERO | --user NOMBRE ...) [--config POLITICA]
#                        [--apply] [--delete-home] [-h]
# Por defecto trabaja en modo simulación (--dry-run). Con --apply (como root):
#   1. bloquea la contraseña (usermod -L),
#   2. caduca la cuenta (chage -E fecha_de_ayer),
#   3. archiva el home en ARCHIVE_DIR como tar.gz (modo 0600) y lo verifica.
# Solo con --delete-home, y únicamente si el archivo es válido, elimina la cuenta y
# su home (userdel -r). Es idempotente: lo ya bloqueado, caducado o archivado se omite.
#
# Códigos de salida: 0 = OK, 2 = error en alguna cuenta, 3 = desconocido
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
# Campos de /etc/shadow que se consultan.
readonly SHADOW_PASSWORD=2 SHADOW_EXPIRE=8

APPLY=0
DELETE_HOME=0
SHADOW_READABLE=1

usage() {
  cat <<EOF
Uso: offboard-users.sh (--csv FICHERO | --user NOMBRE ...) [--config POLITICA]
                       [--apply] [--delete-home] [-h]

Bloquea y caduca cuentas y archiva sus homes. Nunca toca cuentas con UID < MIN_UID.

Opciones:
  --csv FICHERO     Da de baja a los usuarios listados en el CSV
  --user NOMBRE     Da de baja a un usuario (se puede repetir)
  --config FICHERO  Política de cuentas (por defecto config/policy.conf)
  --dry-run         Solo muestra lo que haría (modo por defecto)
  --apply           Ejecuta las acciones (requiere root)
  --delete-home     Tras archivar, elimina la cuenta y su home (explícito, irreversible)
  -h, --help        Muestra esta ayuda

Códigos de salida: 0 = OK, 2 = error en alguna cuenta, 3 = desconocido, 64 = uso incorrecto.
EOF
}

# shadow_field <usuario> <nº de campo> — campo de /etc/shadow (vacío si no se puede leer).
shadow_field() {
  local line
  line="$(getent shadow "$1" 2>/dev/null)" || return 0
  cut -d: -f"$2" <<<"$line"
}

# is_locked <usuario> — la contraseña empieza por "!" (usermod -L).
is_locked() {
  [[ "$(shadow_field "$1" "$SHADOW_PASSWORD")" == '!'* ]]
}

# is_expired <usuario> — la fecha de caducidad existe y ya ha pasado.
is_expired() {
  local expire
  expire="$(shadow_field "$1" "$SHADOW_EXPIRE")"
  [[ -n "$expire" && "$expire" =~ ^[0-9]+$ ]] && (($(today_days) >= expire))
}

# has_archive <usuario> — ya existe algún archivo de baja de ese usuario.
has_archive() {
  compgen -G "${ARCHIVE_DIR}/${1}-*.tar.gz" >/dev/null
}

# archive_home <usuario> <home> — tar.gz del home en ARCHIVE_DIR, verificado.
archive_home() {
  local user="$1" home="$2" out
  mkdir -p "$ARCHIVE_DIR" || return 1
  chmod 0700 "$ARCHIVE_DIR" || return 1
  out="${ARCHIVE_DIR}/${user}-$(date '+%Y%m%d-%H%M%S').tar.gz"
  if ! (umask 077 && tar --numeric-owner -czf "$out" -C "$(dirname "$home")" "$(basename "$home")") ||
    ! tar -tzf "$out" >/dev/null; then
    rm -f "$out"
    return 1
  fi
  emit "archivado ${home} -> ${out}"
}

# offboard_user <usuario> — devuelve 1 si algo falla; no sigue con el borrado.
offboard_user() {
  local user="$1" uid home
  if ! getent passwd "$user" >/dev/null; then
    emit_skip "omitido ${user}: no existe"
    return 0
  fi
  uid="$(getent passwd "$user" | cut -d: -f3)"
  if ((uid < MIN_UID)); then
    log_error "${user}: UID ${uid} < ${MIN_UID}, es una cuenta de sistema; no se toca"
    return 1
  fi
  home="$(getent passwd "$user" | cut -d: -f6)"

  if ((SHADOW_READABLE)) && is_locked "$user"; then
    emit_skip "omitido bloqueo de ${user}: ya está bloqueada"
  else
    ((APPLY)) && { usermod -L "$user" || return 1; }
    emit "bloqueo de ${user}"
  fi

  if ((SHADOW_READABLE)) && is_expired "$user"; then
    emit_skip "omitida caducidad de ${user}: ya está caducada"
  else
    ((APPLY)) && { chage -E "$(date -d yesterday '+%F')" "$user" || return 1; }
    emit "caducidad de ${user} (ayer)"
  fi

  offboard_home "$user" "$home"
}

# remove_account <usuario> — userdel -r; ignora el aviso inocuo de buzón de correo inexistente.
remove_account() {
  local user="$1" out
  if ! out="$(userdel -r "$user" 2>&1)"; then
    log_error "${user}: userdel falló (¿sesión abierta o procesos activos?): ${out}"
    return 1
  fi
  out="$(grep -v 'mail spool' <<<"$out" || true)"
  [[ -z "$out" ]] || log_warn "${user}: ${out}"
}

# offboard_home <usuario> <home> — archivo del home y, si se pidió, eliminación.
offboard_home() {
  local user="$1" home="$2"
  if ! home_is_safe "$home"; then
    log_error "${user}: el home '${home}' está fuera de ${HOME_BASE}; no se archiva ni se borra"
    return 1
  fi
  if [[ ! -d "$home" ]]; then
    emit_skip "omitido archivo de ${user}: el home ${home} no existe"
  elif ((DELETE_HOME == 0)) && has_archive "$user"; then
    emit_skip "omitido archivo de ${user}: ya existe una copia en ${ARCHIVE_DIR}"
  elif ((APPLY)); then
    archive_home "$user" "$home" || {
      log_error "${user}: falló el archivo del home; no se elimina nada"
      return 1
    }
  else
    emit "archivaría ${home} en ${ARCHIVE_DIR}"
  fi
  ((DELETE_HOME)) || return 0
  if ((APPLY)); then
    remove_account "$user" || return 1
    emit "eliminada la cuenta ${user} y su home"
  else
    emit "eliminaría la cuenta ${user} y su home ${home}"
  fi
}

main() {
  local csv="" config="$DEFAULT_CONFIG" user failed=0 done_count=0
  local -a targets=()
  while (($# > 0)); do
    case "$1" in
      --csv)
        [[ $# -ge 2 ]] || die "--csv necesita un valor" "$EXIT_USAGE"
        csv="$2"
        shift 2
        ;;
      --user)
        [[ $# -ge 2 ]] || die "--user necesita un valor" "$EXIT_USAGE"
        targets+=("$2")
        shift 2
        ;;
      --config)
        [[ $# -ge 2 ]] || die "--config necesita un valor" "$EXIT_USAGE"
        config="$2"
        shift 2
        ;;
      --apply)
        APPLY=1
        shift
        ;;
      --dry-run)
        APPLY=0
        shift
        ;;
      --delete-home)
        DELETE_HOME=1
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
  [[ -n "$csv" || ${#targets[@]} -gt 0 ]] || {
    usage >&2
    exit "$EXIT_USAGE"
  }

  require_cmd getent usermod userdel chage tar date cut compgen
  load_policy "$config"
  if [[ -n "$csv" ]]; then
    csv_load "$csv"
    csv_validate_usernames
    targets+=("${CSV_USERNAME[@]}")
  fi
  for user in "${targets[@]}"; do
    [[ "$user" =~ $USERNAME_REGEX ]] || csv_error "-" "usuario '${user}' no cumple ${USERNAME_REGEX}"
  done
  if ((CSV_ERRORS > 0)); then
    log_error "Validación fallida: ${CSV_ERRORS} error(es). No se ha modificado nada."
    exit "$EXIT_CRITICAL"
  fi

  if ((APPLY)); then
    require_root "--apply"
    set_mode apply
  else
    set_mode dry-run
    if ((EUID != 0)); then
      SHADOW_READABLE=0
      log_warn "Sin root no se puede leer /etc/shadow: la simulación no distingue lo ya bloqueado o caducado"
    fi
  fi

  declare -A seen=()
  for user in "${targets[@]}"; do
    [[ -z "${seen[$user]:-}" ]] || continue
    seen[$user]=1
    if offboard_user "$user"; then done_count=$((done_count + 1)); else failed=$((failed + 1)); fi
  done

  if ((APPLY)); then
    printf 'Resumen: procesados=%d errores=%d\n' "$done_count" "$failed"
  else
    printf 'Resumen (simulación): procesados=%d errores=%d. Usa --apply para ejecutar.\n' "$done_count" "$failed"
  fi
  ((failed == 0)) || exit "$EXIT_CRITICAL"
}

main "$@"
