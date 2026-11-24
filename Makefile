# Todo se ejecuta dentro de Docker: nunca se crean ni borran usuarios en el host.
COMPOSE ?= docker compose

.PHONY: help build lint test demo shell clean

help: ## Muestra esta ayuda
	@grep -E '^[a-z]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

build: ## Construye la imagen de pruebas (Debian 12)
	$(COMPOSE) build test

lint: build ## shellcheck de todos los scripts, en el contenedor
	$(COMPOSE) run --rm lint

test: build ## Ejecuta los tests bats en el contenedor
	$(COMPOSE) run --rm test

demo: build ## Recorre alta, auditoría y baja en un contenedor desechable
	$(COMPOSE) run --rm shell bash examples/demo.sh

shell: build ## Abre una shell root en el contenedor para probar a mano
	$(COMPOSE) run --rm shell

clean: ## Elimina contenedores e imagen de pruebas
	$(COMPOSE) down --rmi local --remove-orphans
