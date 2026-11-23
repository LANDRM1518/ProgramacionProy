#!/bin/bash

set -Eeuo pipefail

DIRECTORIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_LOCAL="$DIRECTORIO/configuracion_ssh.log"

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

registrarOperacion "Preparando directorio SSH"

for comando in ssh-keygen ssh-copy-id ssh chmod mkdir; do
    if ! command -v "$comando" >/dev/null 2>&1; then
        manejar_error 1 "$LINENO" "Comando no disponible: $comando"
    fi
done

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

registrarOperacion "Directorio SSH preparado"

CLAVE_PRIVADA="$HOME/.ssh/id_ed25519"
CLAVE_PUBLICA="$HOME/.ssh/id_ed25519.pub"

if [[ -f "$CLAVE_PRIVADA && -f "$CLAVE_PUBLICA" ]]; then
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

registrarOperacion "Claves SSH verificadas correctamente"

ls -l "$CLAVE_PRIVADA" "$CLAVE_PUBLICA"

read -r -p "Ingrese el usuario del Bastion: " usuario_bastion
read -r -p "Ingrese la IP: " ip_bastion

if [[ -z "$usuario_bastion" || -z "$ip_bastion" ]]; then
    manejar_error 1 "$LINENO" "Datos del Bastion incompletos"
fi

if [[ "$usuario_bastion" =~ [[:space:]] || "$ip_bastion" =~ [[:space:]] ]]; then
    manejar_error 1 "$LINENO" "El usuario o la dirección contienen espacios"
fi

registrarOperacion "Usuario y dirección del Bastion configurados"
registrarOperacion "Copiando clave pública al Bastion"
ssh-copy-id -i "$CLAVE_PUBLICA" "$usuario_bastion@$ip_bastion"
registrarOperacion "Clave pública copiada correctamente al Bastion"
registrarOperacion "Verificando autenticación SSH"
ssh -o BatchMode=yes "$usuario_bastion@$ip_bastion" "echo 'Autenticación SSH exitosa'"
registrarOperacion "Proceso de configuración SSH finalizado correctamente"
echo "Configuración SSH finalizada correctamente"
exit 0
