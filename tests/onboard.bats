#!/usr/bin/env bats
# Tests de scripts/onboard-users.sh (se ejecutan como root dentro del contenedor).

load test_helper

setup() { setup_env; }
teardown() { cleanup_env; }

# expect_rejected <mensaje esperado> — el CSV actual debe fallar con 2 sin crear nada.
expect_rejected() {
  local before
  before="$(snapshot_accounts)"
  run "$ONBOARD" --csv "$CSV_FILE" --config "$POLICY" --apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"$1"* ]]
  [ "$(snapshot_accounts)" = "$before" ]
}

# --- Uso y entorno -----------------------------------------------------------

@test "--help muestra el uso y sale con 0" {
  run "$ONBOARD" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso: onboard-users.sh"* ]]
}

@test "sin --csv sale con 64" {
  run "$ONBOARD"
  [ "$status" -eq 64 ]
}

@test "una opción desconocida sale con 64" {
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --nope
  [ "$status" -eq 64 ]
}

@test "una política inexistente sale con 64" {
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --config /no/existe.conf
  [ "$status" -eq 64 ]
}

@test "--apply sin root sale con 3 y no cambia nada" {
  local before
  before="$(snapshot_accounts)"
  run runuser -u nobody -- "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"requiere ejecutarse como root"* ]]
  [ "$(snapshot_accounts)" = "$before" ]
}

# --- Simulación --------------------------------------------------------------

@test "la simulación es el modo por defecto y no cambia nada" {
  local before
  before="$(snapshot_accounts)"
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] crearía ana.ruiz"* ]]
  [[ "$output" == *"a_crear=5 omitidos=0"* ]]
  [ "$(snapshot_accounts)" = "$before" ]
  [ ! -e "$REPORT_DIR" ]
  [ ! -d /home/ana.ruiz ]
}

# --- Validación (todo o nada) ------------------------------------------------

@test "rechaza un usuario que incumple la expresión regular" {
  make_csv bad.csv <<'EOF'
username,full_name,department,groups,shell
Bad.User,Nombre Falso,Soporte,support,/bin/bash
EOF
  expect_rejected "no cumple"
}

@test "rechaza usuarios duplicados" {
  make_csv dup.csv <<'EOF'
username,full_name,department,groups,shell
ana.ruiz,Ana Ruiz,Soporte,support,/bin/bash
ana.ruiz,Otra Ana,Soporte,support,/bin/bash
EOF
  expect_rejected "duplicado"
}

@test "rechaza un grupo fuera de la lista permitida" {
  make_csv grp.csv <<'EOF'
username,full_name,department,groups,shell
ana.ruiz,Ana Ruiz,Soporte,root;support,/bin/bash
EOF
  expect_rejected "grupo 'root' no permitido"
}

@test "rechaza una shell fuera de la lista permitida" {
  make_csv shell.csv <<'EOF'
username,full_name,department,groups,shell
ana.ruiz,Ana Ruiz,Soporte,support,/bin/zsh
EOF
  expect_rejected "shell '/bin/zsh' no permitida"
}

@test "rechaza un nombre completo con dos puntos (rompería /etc/passwd)" {
  make_csv gecos.csv <<'EOF'
username,full_name,department,groups,shell
ana.ruiz,Ana:0:0,Soporte,support,/bin/bash
EOF
  expect_rejected "full_name"
}

@test "rechaza filas con un número de campos incorrecto" {
  make_csv fields.csv <<'EOF'
username,full_name,department,groups,shell
ana.ruiz,Ana Ruiz,Soporte,support
EOF
  expect_rejected "se esperaban 5 campos"
}

@test "rechaza una cabecera incorrecta" {
  make_csv header.csv <<'EOF'
user,name,dept,groups,shell
ana.ruiz,Ana Ruiz,Soporte,support,/bin/bash
EOF
  expect_rejected "Cabecera inválida"
}

@test "no toca cuentas de sistema aunque estén en el CSV" {
  make_csv sys.csv <<'EOF'
username,full_name,department,groups,shell
daemon,Intento Malicioso,Soporte,support,/bin/bash
EOF
  expect_rejected "cuenta de sistema"
}

@test "rechaza un usuario cuyo nombre ya es un grupo sin usuario" {
  groupadd lucia.mora
  make_csv grpcol.csv <<'EOF'
username,full_name,department,groups,shell
lucia.mora,Lucía Mora,Soporte,support,/bin/bash
EOF
  expect_rejected "ya existe un grupo"
}

@test "una sola fila inválida impide crear también las filas válidas" {
  make_csv mixed.csv <<'EOF'
username,full_name,department,groups,shell
ana.ruiz,Ana Ruiz,Soporte,support,/bin/bash
Mal.Usuario,Nombre,Soporte,support,/bin/bash
EOF
  expect_rejected "No se ha modificado nada"
  ! getent passwd ana.ruiz
}

@test "acepta CRLF, comentarios, líneas vacías y shell vacía (usa la de la política)" {
  make_csv crlf.csv < <(printf 'username,full_name,department,groups,shell\r\n# comentario\r\n\r\nzoe.diaz,Zoë Díaz,Soporte,support,\r\n')
  run "$ONBOARD" --csv "$CSV_FILE" --config "$POLICY" --apply
  [ "$status" -eq 0 ]
  [ "$(getent passwd zoe.diaz | cut -d: -f7)" = "/bin/bash" ]
}

# --- Alta real ---------------------------------------------------------------

@test "--apply crea cuentas con home, shell, grupos y GECOS correctos" {
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"creados=5 omitidos=0 errores=0"* ]]
  [ "$(getent passwd ana.ruiz | cut -d: -f5)" = "Ana Ruiz Molina,,,Desarrollo" ]
  [ "$(getent passwd pablo.rey | cut -d: -f7)" = "/bin/sh" ]
  [ "$(getent passwd marta.sanz | cut -d: -f7)" = "/usr/sbin/nologin" ]
  run id -nG carlos.vega
  [[ " $output " == *" sysadmin "* && " $output " == *" support "* ]]
  [ "$(stat -c '%a %U' /home/ana.ruiz)" = "750 ana.ruiz" ]
}

@test "crea los grupos permitidos que no existían" {
  ! getent group developers
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply
  [ "$status" -eq 0 ]
  getent group developers
}

@test "fuerza el cambio de contraseña en el primer login y deja una contraseña válida" {
  "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply >/dev/null 2>&1
  [ "$(shadow_of ana.ruiz 3)" = "0" ]
  [[ "$(shadow_of ana.ruiz 2)" == \$* ]]
}

@test "aplica el envejecimiento y la caducidad de la política" {
  set_policy PASS_MAX_DAYS 60
  set_policy PASS_WARN_DAYS 7
  set_policy ACCOUNT_EXPIRY_DAYS 30
  "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply >/dev/null 2>&1
  [ "$(shadow_of ana.ruiz 4)" = "1" ]
  [ "$(shadow_of ana.ruiz 5)" = "60" ]
  [ "$(shadow_of ana.ruiz 6)" = "7" ]
  [ "$(shadow_of ana.ruiz 7)" = "30" ]
  local expected actual
  expected=$(($(date -d '+30 days' +%s) / 86400))
  actual="$(shadow_of ana.ruiz 8)"
  ((actual >= expected - 1 && actual <= expected + 1))
}

@test "ACCOUNT_EXPIRY_DAYS=0 crea cuentas que no caducan" {
  set_policy ACCOUNT_EXPIRY_DAYS 0
  "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply >/dev/null 2>&1
  [ -z "$(shadow_of ana.ruiz 8)" ]
}

# --- Contraseñas temporales --------------------------------------------------

@test "el informe es solo de root y tiene una contraseña distinta por usuario" {
  "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply >/dev/null 2>&1
  local report
  report="$(ls "$REPORT_DIR"/onboarding-*.csv)"
  [ "$(stat -c %a "$REPORT_DIR")" = "700" ]
  [ "$(stat -c '%a %U' "$report")" = "600 root" ]
  [ "$(head -1 "$report")" = "username,temporary_password,account_expires,created_at" ]
  [ "$(tail -n +2 "$report" | wc -l)" -eq 5 ]
  [ "$(tail -n +2 "$report" | cut -d, -f2 | sort -u | wc -l)" -eq 5 ]
  [ "$(tail -n +2 "$report" | head -1 | cut -d, -f2 | tr -d '\n' | wc -c)" -eq 20 ]
}

@test "las contraseñas temporales nunca salen por stdout ni stderr" {
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply
  [ "$status" -eq 0 ]
  local pw report
  report="$(ls "$REPORT_DIR"/onboarding-*.csv)"
  [[ "$output" == *"$report"* ]]
  while IFS=, read -r _ pw _; do
    [[ "$output" != *"$pw"* ]]
  done < <(tail -n +2 "$report")
}

# --- Idempotencia y fallos ---------------------------------------------------

@test "una segunda ejecución con --apply no cambia nada" {
  "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply >/dev/null 2>&1
  local before reports
  before="$(snapshot_accounts)"
  reports="$(ls "$REPORT_DIR" | wc -l)"
  run "$ONBOARD" --csv "$EXAMPLE_CSV" --config "$POLICY" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"creados=0 omitidos=5 errores=0"* ]]
  [[ "$output" != *"Informe"* ]]
  [ "$(snapshot_accounts)" = "$before" ]
  [ "$(ls "$REPORT_DIR" | wc -l)" -eq "$reports" ]
}

@test "si falla el informe, deshace la cuenta a medias y sale con 2" {
  set_policy REPORT_DIR /proc/imposible
  make_csv one.csv <<'EOF'
username,full_name,department,groups,shell
ana.ruiz,Ana Ruiz,Soporte,support,/bin/bash
EOF
  run "$ONBOARD" --csv "$CSV_FILE" --config "$POLICY" --apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"Deshaciendo la creación parcial de ana.ruiz"* ]]
  ! getent passwd ana.ruiz
  [ ! -d /home/ana.ruiz ]
}
