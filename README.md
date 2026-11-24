# user-onboarding-automation

![Licencia: MIT](https://img.shields.io/badge/licencia-MIT-green)

Alta, auditoría y baja de **usuarios Linux** a partir de un CSV, aplicando una política de cuentas
(grupos permitidos, shells, caducidad y envejecimiento de contraseñas). Son tres scripts de Bash con
`--dry-run` por defecto, códigos de salida al estilo Nagios y **66 tests con bats que se ejecutan en un
contenedor Debian**, nunca sobre las cuentas de tu máquina.

> **Alcance:** solo cuentas locales de Linux (`useradd`, `chage`, `/etc/shadow`). **No cubre Windows ni
> Active Directory**, ni LDAP, ni SSO. Está pensado para servidores, laboratorios y contenedores donde
> las cuentas son locales.

## Qué hace

| Script | Función |
| --- | --- |
| `scripts/onboard-users.sh` | Valida el CSV entero y crea los usuarios: grupos, home, shell, contraseña temporal aleatoria, cambio forzado en el primer login, caducidad y envejecimiento según la política. |
| `scripts/offboard-users.sh` | Bloquea la cuenta, la caduca y archiva el home en un `tar.gz` verificado. Solo con `--delete-home` elimina cuenta y home. |
| `scripts/audit-users.sh` | Compara el sistema con el CSV: usuarios que faltan, sobrantes, bloqueados, caducados, contraseñas viejas, shell/grupos distintos. |

Principios de diseño (detalle en [docs/decisiones.md](docs/decisiones.md)):

- **Seguro por defecto:** sin `--apply` solo se simula. Con `--apply` se exige root.
- **Todo o nada al validar:** si una sola fila es inválida no se crea ninguna cuenta.
- **Idempotente:** repetir el alta no cambia nada; los usuarios existentes se omiten, no se modifican.
- **Contraseñas fuera de los logs:** la contraseña temporal solo se escribe en un informe `0600` de root.
- **No toca cuentas de sistema:** nada con UID inferior a `MIN_UID` ni homes fuera de `HOME_BASE`.

## Requisitos

- Para ejecutar los scripts: Bash 4.4+, `useradd`/`usermod`/`userdel`/`chage`/`chpasswd` (paquete `passwd` de
  Debian/Ubuntu), `getent`, `tar` y root. Probado únicamente sobre Debian 12.
- Para las pruebas: **Docker** con el plugin `docker compose` y `make`. No hace falta instalar nada más.

## Uso rápido

```bash
# Todo ocurre dentro de un contenedor Debian 12; tu máquina no se toca.
make lint     # shellcheck
make test     # 66 tests de bats
make demo     # recorrido completo alta -> auditoría -> baja
make shell    # shell de root en el contenedor para probar a mano
```

En un servidor real (como root, tras revisar la simulación):

```bash
cp config/policy.conf.example config/policy.conf   # y ajústala
scripts/onboard-users.sh --csv examples/users.csv                # simulación
scripts/onboard-users.sh --csv examples/users.csv --apply        # alta real
scripts/audit-users.sh   --csv examples/users.csv                # auditoría
scripts/offboard-users.sh --user ana.ruiz --apply                # baja (bloquea, caduca, archiva)
scripts/offboard-users.sh --user ana.ruiz --apply --delete-home  # baja y eliminación
```

## Formato del CSV

```csv
username,full_name,department,groups,shell
ana.ruiz,Ana Ruiz Molina,Desarrollo,developers,/bin/bash
carlos.vega,Carlos Vega Prieto,Sistemas,sysadmin;support,/bin/bash
marta.sanz,Marta Sanz Ortega,Finanzas,,/usr/sbin/nologin
```

- Cabecera obligatoria exacta. Varios grupos separados por `;`. `shell` vacío usa `DEFAULT_SHELL`.
- No se admiten comas dentro de un campo. Líneas vacías, comentarios con `#` y CRLF se toleran.
- Los datos de `examples/users.csv` son **ficticios**.

## Política

`config/policy.conf` (`KEY=value`, **no se ejecuta como shell**). Valores por defecto: usuarios
`^[a-z][a-z0-9._-]{2,31}$`, contraseña temporal de 20 caracteres, máximo 90 días, mínimo 1, aviso 14,
inactividad 30, cuenta caduca a los 365 días. Todas las claves están explicadas en
[config/policy.conf.example](config/policy.conf.example) y en [docs/politicas.md](docs/politicas.md).

## Salida real

Capturada con `make demo` en un contenedor Debian 12 (completa en [docs/ejemplo-salida.txt](docs/ejemplo-salida.txt)).

**Simulación (por defecto) y alta real, seguida de una segunda ejecución idempotente:**

```text
$ scripts/onboard-users.sh --csv examples/users.csv --config /tmp/policy.conf
[DRY-RUN] crearía ana.ruiz (Ana Ruiz Molina, Desarrollo) grupos=developers shell=/bin/bash home=/home/ana.ruiz caduca=2027-11-24
[DRY-RUN] crearía carlos.vega (Carlos Vega Prieto, Sistemas) grupos=sysadmin,support shell=/bin/bash home=/home/carlos.vega caduca=2027-11-24
...
Resumen (simulación): a_crear=5 omitidos=0. Usa --apply para ejecutar.

$ scripts/onboard-users.sh --csv examples/users.csv --config /tmp/policy.conf --apply
[HECHO] creado ana.ruiz
[HECHO] creado carlos.vega
[HECHO] creado lucia.mora
[HECHO] creado pablo.rey
[HECHO] creado marta.sanz
Resumen: creados=5 omitidos=0 errores=0
Informe con las contraseñas temporales (solo root): /var/lib/user-onboarding/onboarding-20261124-082714-169.csv

$ scripts/onboard-users.sh --csv examples/users.csv --config /tmp/policy.conf --apply
[SIN CAMBIOS] omitido ana.ruiz: ya existe
...
Resumen: creados=0 omitidos=5 errores=0
```

**Las contraseñas solo viven en el informe de root** (aquí ocultadas con `sed`; en la salida de los scripts no aparecen nunca):

```text
$ ls -ld /var/lib/user-onboarding
drwx------ 1 root root 68 Nov 24 08:27 /var/lib/user-onboarding
$ ls -l /var/lib/user-onboarding | tail -n +2 | awk '{print $1, $3, $4, $NF}'
-rw------- root root onboarding-20261124-082714-169.csv
$ sed -E '2,$ s/^([^,]+),[^,]+,/\1,********,/' /var/lib/user-onboarding/*.csv
username,temporary_password,account_expires,created_at
ana.ruiz,********,2027-11-24,2026-11-24T08:27:14
```

**Política aplicada y cambio forzado en el primer login** (`chage -d 0`):

```text
$ chage -l ana.ruiz
Last password change					: password must be changed
Password expires					: password must be changed
Password inactive					: password must be changed
Account expires						: Nov 24, 2027
Minimum number of days between password change		: 1
Maximum number of days between password change		: 90
Number of days of warning before password expires	: 14
```

**Validación todo o nada** (5 errores: no se crea nada, ni siquiera la fila válida):

```text
$ scripts/onboard-users.sh --csv mal.csv --apply
[ERROR] línea 3: usuario 'Ana.Ruiz' no cumple ^[a-z][a-z0-9._-]{2,31}$
[ERROR] línea 4: usuario 'ana.ruiz' duplicado (primera vez en la línea 2)
[ERROR] línea 3: grupo 'root' no permitido (permitidos: developers sysadmin support)
[ERROR] línea 3: shell '/bin/zsh' no permitida (permitidas: /bin/bash /bin/sh /usr/sbin/nologin)
[ERROR] línea 5: 'daemon' es una cuenta de sistema (UID 1 < 1000); no se toca
[ERROR] Validación fallida: 5 error(es). No se ha modificado nada.
(código de salida: 2)
```

**Auditoría con desvíos** (cuenta ajena al CSV y activa, cuenta bloqueada, grupo añadido a mano):

```text
$ scripts/audit-users.sh --csv examples/users.csv --config /tmp/policy.conf
OK       carlos.vega      conforme con el CSV y la política
WARNING  lucia.mora       cuenta bloqueada
WARNING  pablo.rey        grupos 'developers,support,sysadmin' (CSV: 'developers,support')
CRITICAL intruso          fuera del CSV y con la cuenta activa
Resumen: usuarios_csv=5 conformes=3 warning=2 critical=1
(código de salida: 2)
```

(Extracto: la salida completa también incluye una línea `INFO` por cuenta con el cambio de contraseña pendiente.)

**Baja:** primero bloquea, caduca y archiva; repetirla no hace nada; con `--delete-home` archiva antes de borrar:

```text
$ scripts/offboard-users.sh --config /tmp/policy.conf --user pablo.rey --apply --delete-home
[HECHO] bloqueo de pablo.rey
[HECHO] caducidad de pablo.rey (ayer)
[HECHO] archivado /home/pablo.rey -> /var/backups/offboarding/pablo.rey-20261124-082715.tar.gz
[HECHO] eliminada la cuenta pablo.rey y su home
Resumen: procesados=1 errores=0
```

## Códigos de salida

| Script | 0 | 1 | 2 | 3 | 64 |
| --- | --- | --- | --- | --- | --- |
| `onboard-users.sh` | OK | — | validación o creación fallida | falta root o una dependencia | uso incorrecto |
| `offboard-users.sh` | OK | — | error en alguna cuenta | falta root o una dependencia | uso incorrecto |
| `audit-users.sh` | conforme | WARNING | CRITICAL | falta root o una dependencia | uso incorrecto |

## Pruebas

`make test` construye la imagen `debian:12-slim` (con `bats` y `shellcheck`) y ejecuta como root dentro del
contenedor, **sin red** y con el repositorio montado en solo lectura:

- `tests/onboard.bats` (26): validación, simulación, alta, política aplicada, informe, idempotencia, rollback.
- `tests/offboard.bats` (13): simulación, bloqueo, caducidad, archivo, `--delete-home`, protecciones.
- `tests/audit.bats` (15): cada tipo de hallazgo y su código de salida.
- `tests/policy.bats` (12): carga y validación de la política, sin ejecución de código incrustado.

Los tests crean y borran usuarios reales, por eso `tests/test_helper.bash` **aborta si no está la marca
`UOA_IN_CONTAINER`**, que solo define el `Dockerfile`. La integración continua
([.github/workflows/ci.yml](.github/workflows/ci.yml)) ejecuta `make lint` y `make test`.

## Estructura

```text
scripts/    onboard-users.sh, offboard-users.sh, audit-users.sh
lib/        common.sh (logs, códigos de salida), policy.sh (política), csv.sh (lectura y validación)
config/     policy.conf.example
examples/   users.csv (ficticio), demo.sh (recorrido para el contenedor)
tests/      *.bats y test_helper.bash
docs/       politicas.md, decisiones.md, ejemplo-salida.txt
Dockerfile, docker-compose.yml, Makefile
```

## Limitaciones conocidas

- Solo cuentas locales de Linux; sin Windows, Active Directory, LDAP ni SSO.
- Un usuario que ya existe se omite: no se reconcilian sus grupos ni su shell (eso lo señala `audit-users.sh`).
- No hay bloqueo contra ejecuciones simultáneas: no lances dos altas a la vez.
- Con `UsePAM yes` una contraseña bloqueada (`usermod -L`) no impide entrar por clave SSH; por eso la baja
  también caduca la cuenta. No se ha probado un login SSH real.
- La entrega de la contraseña temporal al usuario (correo cifrado, gestor de secretos…) queda fuera del proyecto.

## Licencia

[MIT](LICENSE) © 2026 Daniel García Rodríguez
