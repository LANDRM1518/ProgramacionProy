#!/bin/bash

set -Eeuo pipefail

DIRECTORIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_LOCAL="$DIRECTORIO/despliegue_noc.log"

manejar_error() {
    local codigo="$1"
    local linea="$2"
    local comando="$3"
    local mensaje
    mensaje="ERROR: Código $codigo. Línea $linea. Comando: $comando"
    trap - ERR
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$LOG_LOCAL" 2>/dev/null || true
    logger -t despliegue_noc "$mensaje" || true
    echo "$mensaje"
    exit "$codigo"
}

trap 'manejar_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

registrarOperacion() {
    local mensaje="$1"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$LOG_LOCAL"
    logger -t despliegue_noc "$mensaje" || true
    echo "$mensaje"
}

verificarPrivilegios() {
    if [[ "$EUID" -ne 0 ]]; then
        manejar_error 1 "$LINENO" "Se requieren privilegios de administrador. Ejecuta con sudo."
    fi
}

instalardocker() {
    registrarOperacion "Iniciando instalación de Docker"
    verificarPrivilegios
    if ! command -v apt-get >/dev/null 2>&1; then
        manejar_error 1 "$LINENO" "No se encontró apt-get"
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        manejar_error 1 "$LINENO" "No se encontró systemctl"
    fi
    registrarOperacion "Actualizando repositorios de paquetes"
    apt-get update
    registrarOperacion "Instalando paquete docker.io"
    apt-get install -y docker.io
    registrarOperacion "Habilitando e iniciando servicio Docker"
    systemctl enable --now docker
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        registrarOperacion "Docker instalado y operativo"
        echo "Docker instalado y funcionando correctamente"
    else
        manejar_error 1 "$LINENO" "Docker no está funcionando después de la instalación"
    fi
}

instalarpodman() {
    registrarOperacion "Iniciando instalación de Podman"
    verificarPrivilegios
    if ! command -v apt-get >/dev/null 2>&1; then
        manejar_error 1 "$LINENO" "No se encontró apt-get"
    fi

    registrarOperacion "Actualizando repositorios de paquetes"
    apt-get update
    registrarOperacion "Instalando paquete Podman"
    apt-get install -y podman
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        registrarOperacion "Podman instalado y operativo"
        echo "Podman instalado y funcionando correctamente"
    else
        manejar_error 1 "$LINENO" "Podman no está funcionando después de la instalación"
    fi
}

detectarMotor() {
    if command -v docker >/dev/null 2>&1; then
        registrarOperacion "Docker detectado en el sistema"
        if docker info >/dev/null 2>&1; then
            registrarOperacion "Docker está instalado y operativo"
            echo "Docker está instalado y funcionando correctamente"
            return 0
        else
            registrarOperacion "ADVERTENCIA: Docker está instalado, pero no está operativo"
        fi
    fi

    if command -v podman >/dev/null 2>&1; then
        registrarOperacion "Podman detectado en el sistema"
        if podman info >/dev/null 2>&1; then
            registrarOperacion "Podman está instalado y operativo"
            echo "Podman está instalado y funcionando correctamente"
            return 0
        else
            registrarOperacion "ADVERTENCIA: Podman está instalado, pero no está operativo"
        fi
    fi
    return 1
}

registrarOperacion "Iniciando detección del motor de contenedores"
if detectarMotor; then
    registrarOperacion "Detección finalizada: existe un motor operativo"
    exit 0
fi

registrarOperacion "No se encontró un motor de contenedores operativo"
echo "En el sistema no hay un motor de contenedores operativo."
echo "¿Desea instalar Docker o Podman?"
read -r -p "Ingrese 'dk' para instalar Docker o 'pdn' para instalar Podman: " opt

case "$opt" in
    dk)
        instalardocker
        ;;
    pdn)
        instalarpodman
        ;;
    *)
        manejar_error 1 "$LINENO" "Opción de instalación no válida: $opt"
        ;;
esac

registrarOperacion "Detección y preparación del motor finalizada correctamente"
exit 0
