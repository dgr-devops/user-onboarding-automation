# Decisiones de diseño

Registro corto de las decisiones que más condicionan el proyecto, con su motivo y lo que se descarta.

## 1. Bash y herramientas estándar del sistema

**Decisión:** Bash con `useradd`, `chage`, `chpasswd` y `getent`, en el mismo estilo que
`bash-sysadmin-toolkit` (`set -euo pipefail`, códigos de salida de Nagios, `--dry-run`).
**Motivo:** son las herramientas que hay en cualquier servidor Linux, sin dependencias que instalar. Lo que se
automatiza es justo lo que hace un administrador a mano.
**Descartado:** Python o Ansible. Ansible sería lo natural para una flota; aquí el objetivo es mostrar que se
entiende qué hace cada comando por debajo.

## 2. Simulación por defecto, `--apply` explícito

**Decisión:** sin `--apply` nunca se modifica nada; con `--apply` se exige root. La baja destructiva necesita
además `--delete-home`.
**Motivo:** un script que crea y borra cuentas debe fallar hacia el lado seguro. El riesgo no es un error de
sintaxis, es lanzar el comando equivocado en el servidor equivocado.

## 3. Validar todo antes de cambiar nada

**Decisión:** el CSV se valida completo (formato, duplicados, grupos, shells, colisiones con cuentas de sistema
o grupos existentes) y, si hay un solo error, no se crea ninguna cuenta. Se informan todos los errores a la vez.
**Motivo:** un alta a medias deja el sistema en un estado difícil de razonar y obliga a limpiar a mano.

## 4. Idempotencia por omisión, no por reconciliación

**Decisión:** si el usuario ya existe (con UID ≥ `MIN_UID`) se omite sin tocarlo.
**Motivo:** "repetir no cambia nada" es una garantía simple y comprobable (los tests comparan una huella de
`/etc/passwd`, `/etc/shadow` y `/etc/group`). Modificar cuentas existentes para igualarlas al CSV podría
quitar grupos o cambiar shells sin que nadie lo haya pedido.
**Contrapartida:** las diferencias no se corrigen solas; `audit-users.sh` las detecta y avisa.

## 5. Contraseñas: informe de root, nunca por pantalla

**Decisión:** la contraseña temporal solo se escribe en un fichero `0600` dentro de un directorio `0700`. Se
asigna con `chpasswd` por entrada estándar, y se fuerza el cambio en el primer login con `chage -d 0`.
**Motivo:** lo que sale por stdout/stderr acaba en historiales de shell, logs de cron, CI y tickets. En el
informe, solo lo lee root.
**Descartado:** contraseña igual al usuario, fija o derivada del nombre; imprimirla "solo esta vez".

## 6. Política en `KEY=value` sin ejecutarla

**Decisión:** el fichero de política se parsea línea a línea con una lista cerrada de claves; no se hace
`source`.
**Motivo:** `source` ejecutaría cualquier cosa que alguien dejase en el fichero, con los privilegios de root.
Hay un test que intenta incrustar `$(...)` y comprueba que no se ejecuta.

## 7. Protecciones para no tocar lo que no es nuestro

- `MIN_UID` (≥ 500): ni el alta ni la baja operan sobre cuentas de sistema.
- `HOME_BASE`: ni se archiva ni se borra un home fuera de esa ruta; evita que un `passwd` manipulado apunte a `/`.
- Alta: si falla un paso tras `useradd` (p. ej. el informe), se deshace solo esa cuenta con `userdel -r`.
- Baja: no se borra nada si el archivo no se creó y verificó con `tar -tzf`.

## 8. La baja bloquea Y caduca

**Decisión:** `usermod -L` más `chage -E` con la fecha de ayer.
**Motivo:** con `UsePAM yes` (lo habitual en Debian y Ubuntu) bloquear la contraseña no impide entrar por
clave SSH; la caducidad de cuenta sí la comprueba `pam_unix` en la fase `account`. Hacer las dos cosas cubre
ambos casos. Cada paso se omite si ya estaba hecho. No se ha probado un login SSH real en los tests: la
justificación es de diseño, no un resultado medido.

## 9. Las pruebas solo corren en un contenedor

**Decisión:** `make test` ejecuta `bats` como root en `debian:12-slim`, sin red y con el repositorio en solo
lectura. El helper de tests aborta si falta `UOA_IN_CONTAINER`, que define el `Dockerfile`; la demo hace lo mismo.
**Motivo:** probar un alta/baja de usuarios exige crear y borrar cuentas reales. Se hace donde equivocarse no
cuesta nada: ejecutar `bats tests` por error en el portátil no llega a tocar ningún usuario.
**Descartado:** stubs de `useradd` (probarían los stubs, no el comportamiento real de `chage` y `/etc/shadow`).

## 10. Fuera de alcance

- **Windows y Active Directory:** otro modelo de cuentas, otras herramientas (PowerShell, `ActiveDirectory`
  module). No se simulan ni se afirma soporte.
- **LDAP/SSO, claves SSH y sudoers:** el alta crea cuentas locales; el acceso remoto y la elevación de privilegios
  se gestionan aparte.
- **Concurrencia:** no hay `flock`; la operación asume un único administrador a la vez.
- **Entrega de la contraseña temporal:** queda en manos del operador (canal seguro, gestor de secretos).
- **CSV con comas o saltos de línea dentro de campos:** se rechazan por simplicidad; un parser completo de CSV
  no es proporcionado para cinco columnas controladas.
