# Makefile para microdeploy (binario Go)
#
# Targets:
#   make build    -> compila el binario 'microdeploy' en el directorio actual
#   make install  -> instala el binario en PREFIX/bin (por defecto /usr/local/bin)
#   make test     -> compila y ejecuta --help / --list para verificar
#   make clean    -> elimina el binario compilado

PREFIX ?= /usr/local
BINARY := microdeploy

.PHONY: all build install test clean

all: build

build:
	go build -o $(BINARY) main.go

install: build
	install -m 0755 $(BINARY) $(PREFIX)/bin/$(BINARY)

test: build
	@./$(BINARY) --help >/dev/null && echo "help: OK"
	@./$(BINARY) --list 2>&1 || true
	@echo "test completo"

clean:
	rm -f $(BINARY)