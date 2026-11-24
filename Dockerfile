# Entorno de pruebas: Debian 12 como root, aislado del host.
# Aquí es donde los scripts crean y borran usuarios de verdad; nunca en la máquina anfitriona.
FROM debian:12-slim

# UOA_IN_CONTAINER: los tests se niegan a ejecutarse si falta esta marca (tests/test_helper.bash).
ENV DEBIAN_FRONTEND=noninteractive \
    UOA_IN_CONTAINER=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends bats shellcheck passwd tar gzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# El repositorio se monta aquí en solo lectura (ver docker-compose.yml).
WORKDIR /opt/uoa

CMD ["bats", "--print-output-on-failure", "tests"]
