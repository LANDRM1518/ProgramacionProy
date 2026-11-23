#!/bin/bash

set -Eeuo pipefail

DIRECTORIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_LOCAL="$DIRECTORIO/configuracion_ssh.log"

CLAVE_PRIVADA="$HOME/.ssh/id_ed25519"
CLAVE_PUBLICA="$HOME/.ssh/id_ed25519.pub"

manejar_error() {
    local codigo="$1"
    local linea="$2"
    local comando="$3"
    local mensaje

    mensaje="ERROR: Código $codigo. Línea $linea. Comando: $comando"

    trap - ERR

    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" \
        >> "$LOG_LOCAL" 2>/dev/null || true

    logger -t despliegue_noc "$mensaje" || true

    echo "$mensaje"
    exit "$codigo"
}

trap 'manejar_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

registrarOperacion() {
    local mensaje="$1"

    printf '[%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" \
        >> "$LOG_LOCAL"

    logger -t despliegue_noc "$mensaje" || true

    echo "$mensaje"
}

registrarOperacion "Preparando directorio SSH"

for comando in ssh-keygen chmod mkdir; do
    if ! command -v "$comando" >/dev/null 2>&1; then
        manejar_error 1 "$LINENO" "Comando no disponible: $comando"
    fi
done

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

registrarOperacion "Directorio SSH preparado"

if [[ -f "$CLAVE_PRIVADA" && -f "$CLAVE_PUBLICA" ]]; then

    registrarOperacion "Las claves SSH ya existen y se reutilizarán"

elif [[ -f "$CLAVE_PRIVADA" ]]; then

    registrarOperacion "Existe clave privada, reconstruyendo clave pública"

    ssh-keygen -y -f "$CLAVE_PRIVADA" > "$CLAVE_PUBLICA"

elif [[ -f "$CLAVE_PUBLICA" ]]; then

    manejar_error 1 "$LINENO" "Existe clave pública, pero falta la privada"

else

    registrarOperacion "Generando par de claves SSH Ed25519"

    ssh-keygen -t ed25519 -f "$CLAVE_PRIVADA" -N ""

fi

chmod 600 "$CLAVE_PRIVADA"
chmod 644 "$CLAVE_PUBLICA"

registrarOperacion "Permisos SSH configurados correctamente"

if ! ssh-keygen -y -f "$CLAVE_PRIVADA" >/dev/null 2>&1; then
    manejar_error 1 "$LINENO" "La clave privada no es válida"
fi

if [[ ! -s "$CLAVE_PUBLICA" ]]; then
    manejar_error 1 "$LINENO" "La clave pública está vacía"
fi

if ! ssh-keygen -l -f "$CLAVE_PUBLICA" >/dev/null 2>&1; then
    manejar_error 1 "$LINENO" "La clave pública no es válida"
fi

registrarOperacion "Claves SSH verificadas correctamente"

ls -l "$CLAVE_PRIVADA" "$CLAVE_PUBLICA"

registrarOperacion "Proceso de generación de claves SSH finalizado correctamente"

echo ""
echo "======================================"
echo "    CLAVES SSH CONFIGURADAS"
echo "======================================"
echo "Clave privada: $CLAVE_PRIVADA"
echo "Clave pública: $CLAVE_PUBLICA"
echo "Algoritmo: Ed25519"
echo "Permisos: Configurados"
echo "Registro: $LOG_LOCAL"
echo "======================================"

exit 0
