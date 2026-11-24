#!/usr/bin/env bats
# Tests de scripts/offboard-users.sh (se ejecutan como root dentro del contenedor).

load test_helper

setup() {
  setup_env
  onboard_example
  echo "datos de ana" >/home/ana.ruiz/notas.txt
}
teardown() { cleanup_env; }

today() { echo $(($(date +%s) / 86400)); }

@test "sin --csv ni --user sale con 64" {
  run "$OFFBOARD" --config "$POLICY"
  [ "$status" -eq 64 ]
}

@test "la simulación es el modo por defecto y no cambia nada" {
  local before
  before="$(snapshot_accounts)"
  run "$OFFBOARD" --user ana.ruiz --config "$POLICY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] bloqueo de ana.ruiz"* ]]
  [[ "$output" == *"[DRY-RUN] archivaría /home/ana.ruiz"* ]]
  [ "$(snapshot_accounts)" = "$before" ]
  [ ! -e "$ARCHIVE_DIR" ]
}

@test "--apply bloquea, caduca y archiva; la cuenta y el home se conservan" {
  run "$OFFBOARD" --user ana.ruiz --config "$POLICY" --apply
  [ "$status" -eq 0 ]
  [[ "$(shadow_of ana.ruiz 2)" == '!'* ]]
  local expire archive
  expire="$(shadow_of ana.ruiz 8)"
  [ -n "$expire" ] && [ "$expire" -le "$(today)" ]
  archive="$(ls "$ARCHIVE_DIR"/ana.ruiz-*.tar.gz)"
  [ "$(stat -c %a "$archive")" = "600" ]
  [ "$(stat -c %a "$ARCHIVE_DIR")" = "700" ]
  tar -tzf "$archive" | grep -q 'ana.ruiz/notas.txt'
  [ -f /home/ana.ruiz/notas.txt ]
}

@test "es idempotente: repetirlo no cambia nada ni duplica archivos" {
  "$OFFBOARD" --user ana.ruiz --config "$POLICY" --apply >/dev/null 2>&1
  local before
  before="$(snapshot_accounts)"
  run "$OFFBOARD" --user ana.ruiz --config "$POLICY" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"ya está bloqueada"* ]]
  [[ "$output" == *"ya está caducada"* ]]
  [[ "$output" == *"ya existe una copia"* ]]
  [ "$(snapshot_accounts)" = "$before" ]
  [ "$(ls "$ARCHIVE_DIR"/ana.ruiz-*.tar.gz | wc -l)" -eq 1 ]
}

@test "--delete-home archiva primero y luego elimina la cuenta y el home" {
  run "$OFFBOARD" --user ana.ruiz --config "$POLICY" --apply --delete-home
  [ "$status" -eq 0 ]
  ! getent passwd ana.ruiz
  [ ! -d /home/ana.ruiz ]
  tar -tzf "$ARCHIVE_DIR"/ana.ruiz-*.tar.gz | grep -q 'ana.ruiz/notas.txt'
}

@test "--delete-home sin --apply solo simula" {
  run "$OFFBOARD" --user ana.ruiz --config "$POLICY" --delete-home
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] eliminaría la cuenta ana.ruiz"* ]]
  getent passwd ana.ruiz
  [ -d /home/ana.ruiz ]
}

@test "con --delete-home rehace el archivo aunque ya hubiera uno anterior" {
  "$OFFBOARD" --user ana.ruiz --config "$POLICY" --apply >/dev/null 2>&1
  echo "dato nuevo" >/home/ana.ruiz/reciente.txt
  sleep 1
  run "$OFFBOARD" --user ana.ruiz --config "$POLICY" --apply --delete-home
  [ "$status" -eq 0 ]
  [ "$(ls "$ARCHIVE_DIR"/ana.ruiz-*.tar.gz | wc -l)" -eq 2 ]
  local newest
  newest="$(ls -1 "$ARCHIVE_DIR"/ana.ruiz-*.tar.gz | tail -1)"
  tar -tzf "$newest" | grep -q 'reciente.txt'
}

@test "un usuario que ya no existe se omite con éxito" {
  run "$OFFBOARD" --user fantasma --config "$POLICY" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"omitido fantasma: no existe"* ]]
}

@test "se niega a tocar cuentas de sistema" {
  local before
  before="$(snapshot_accounts)"
  run "$OFFBOARD" --user daemon --config "$POLICY" --apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"cuenta de sistema"* ]]
  [ "$(snapshot_accounts)" = "$before" ]
}

@test "no archiva ni borra un home fuera de HOME_BASE" {
  useradd -m -d /srv/extuser extuser
  run "$OFFBOARD" --user extuser --config "$POLICY" --apply --delete-home
  [ "$status" -eq 2 ]
  [[ "$output" == *"fuera de /home"* ]]
  getent passwd extuser
  [ -d /srv/extuser ]
  [ ! -e "$ARCHIVE_DIR" ]
}

@test "con --csv da de baja a todos los usuarios listados" {
  make_csv baja.csv <<'EOF'
username,full_name,department,groups,shell
ana.ruiz,Ana Ruiz Molina,Desarrollo,developers,/bin/bash
lucia.mora,Lucía Mora Gil,Soporte,support,/bin/bash
EOF
  run "$OFFBOARD" --csv "$CSV_FILE" --config "$POLICY" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"procesados=2 errores=0"* ]]
  [[ "$(shadow_of ana.ruiz 2)" == '!'* ]]
  [[ "$(shadow_of lucia.mora 2)" == '!'* ]]
  [[ "$(shadow_of carlos.vega 2)" != '!'* ]]
}

@test "un nombre de usuario inválido aborta antes de tocar nada" {
  local before
  before="$(snapshot_accounts)"
  run "$OFFBOARD" --user 'Mal Usuario' --user ana.ruiz --config "$POLICY" --apply
  [ "$status" -eq 2 ]
  [ "$(snapshot_accounts)" = "$before" ]
}

@test "--apply sin root sale con 3; la simulación sin root avisa pero funciona" {
  run runuser -u nobody -- "$OFFBOARD" --user ana.ruiz --config "$POLICY" --apply
  [ "$status" -eq 3 ]
  run runuser -u nobody -- "$OFFBOARD" --user ana.ruiz --config "$POLICY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sin root no se puede leer /etc/shadow"* ]]
}
