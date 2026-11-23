#!/bin/bash

set -Eeuo pipefail

DIRECTORIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_LOCAL="$DIRECTORIO/despliegue_docker.log"
RED="red-segura"
VOLUMEN_WEB="volumen_web"
VOLUMEN_ARCHIVOS="volumen_archivos"
CLAVE_PUBLICA="$HOME/.ssh/id_ed25519.pub"

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
    echo "El despliegue no pudo completarse."
    exit "$codigo"
}

trap 'manejar_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

registrarOperacion() {
    local mensaje="$1"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mensaje" >> "$LOG_LOCAL"
    logger -t despliegue_noc "$mensaje" || true
    echo "$mensaje"
}

registrarOperacion "INICIANDO DESPLIEGUE DOCKER"

if ! command -v docker >/dev/null 2>&1; then
    manejar_error 1 "$LINENO" "Docker no está instalado"
fi

registrarOperacion "Docker detectado"

if ! docker info >/dev/null 2>&1; then
    manejar_error 1 "$LINENO" "Docker no está funcionando o no hay permisos"
fi

registrarOperacion "Docker está funcionando correctamente"

for comando in ssh-keygen; do
    if ! command -v "$comando" >/dev/null 2>&1; then
        manejar_error 1 "$LINENO" "Comando no disponible: $comando"
    fi
done

if [[ ! -f "$CLAVE_PUBLICA" || ! -r "$CLAVE_PUBLICA" || ! -s "$CLAVE_PUBLICA" ]]; then
    manejar_error 1 "$LINENO" "Clave pública SSH inexistente, vacía o ilegible"
fi

if ! ssh-keygen -l -f "$CLAVE_PUBLICA" >/dev/null 2>&1; then
    manejar_error 1 "$LINENO" "La clave pública SSH no tiene un formato válido"
fi

PUBLIC_KEY="$(cat "$CLAVE_PUBLICA")"
registrarOperacion "Clave pública SSH verificada"
registrarOperacion "Descargando imágenes de contenedores"
docker pull lscr.io/linuxserver/openssh-server:latest
docker pull nginx:alpine
docker pull alpine:latest

registrarOperacion "Imágenes descargadas correctamente"

if ! docker network inspect "$RED" >/dev/null 2>&1; then
    registrarOperacion "Creando red interna $RED"
    docker network create --driver bridge --internal "$RED"
else

    INTERNA="$(docker network inspect -f '{{.Internal}}' "$RED")"

    if [[ "$INTERNA" != "true" ]]; then
        manejar_error 1 "$LINENO" "La red existente $RED no es interna"
    fi
    registrarOperacion "La red interna $RED ya existe"
fi

for volumen in "$VOLUMEN_WEB" "$VOLUMEN_ARCHIVOS"; do
    if ! docker volume inspect "$volumen" >/dev/null 2>&1; then
        docker volume create "$volumen"
        registrarOperacion "Volumen $volumen creado"
    else
        registrarOperacion "Volumen $volumen ya existe"
    fi
done

iniciarContenedor() {
    local nombre="$1"
    shift
    if docker container inspect "$nombre" >/dev/null 2>&1; then
        local estado
        estado="$(docker inspect -f '{{.State.Status}}' "$nombre")"

        if [[ "$estado" == "running" ]]; then
            registrarOperacion "$nombre ya está funcionando"
        else
            registrarOperacion "Iniciando contenedor detenido: $nombre"
            docker start "$nombre"
        fi
        registrarOperacion "ADVERTENCIA: No se modificó la configuración de $nombre si ya existía"
    else
        registrarOperacion "Creando contenedor: $nombre"
        "$@"
        registrarOperacion "Contenedor $nombre creado correctamente"

    fi
}

registrarOperacion "CONFIGURANDO SERVIDOR SSH - BASTION HOST"
iniciarContenedor servidor-ssh docker run -d --restart unless-stopped --name servidor-ssh --network "$RED" -p 2222:2222 -e PUID=1000 -e PGID=1000 -e TZ=America/Mexico_City -e USER_NAME=bastion -e PASSWORD_ACCESS=false -e PUBLIC_KEY="$PUBLIC_KEY" -v "$VOLUMEN_WEB:/mnt/web" -v "$VOLUMEN_ARCHIVOS:/mnt/archivos" lscr.io/linuxserver/openssh-server:latest
registrarOperacion "CONFIGURANDO SERVIDOR WEB - NGINX"
iniciarContenedor servidor-web docker run -d --restart unless-stopped --name servidor-web --network "$RED" -p 8080:80 -v "$VOLUMEN_WEB:/usr/share/nginx/html" nginx:alpine
registrarOperacion "CONFIGURANDO SERVIDOR DE ARCHIVOS - ALPINE + OPENSSH"

if docker container inspect servidor-archivos >/dev/null 2>&1; then
    estado="$(docker inspect -f '{{.State.Status}}' servidor-archivos)"
    if [[ "$estado" == "running" ]]; then
        registrarOperacion "Servidor de archivos ya está funcionando"
    else
        registrarOperacion "Iniciando servidor de archivos detenido"
        docker start servidor-archivos
    fi
    registrarOperacion "ADVERTENCIA: Se conserva la configuración del servidor de archivos existente"
else
    registrarOperacion "Creando Alpine temporalmente conectado a bridge"
    docker run -d --name servidor-archivos --restart unless-stopped --network bridge -p 2223:2223 -v "$CLAVE_PUBLICA:/tmp/key.pub:ro" -v "$VOLUMEN_ARCHIVOS:/archivos" alpine:latest \
        sh -c '
            apk update &&
            apk add --no-cache openssh-server &&
            ssh-keygen -A &&
            mkdir -p /root/.ssh /run/sshd /archivos &&
            cat /tmp/key.pub > /root/.ssh/authorized_keys &&
            chmod 700 /root/.ssh &&
            chmod 600 /root/.ssh/authorized_keys &&
            printf "%s\n" \
                "Port 2223" \
                "PermitRootLogin prohibit-password" \
                "PubkeyAuthentication yes" \
                "AuthorizedKeysFile .ssh/authorized_keys" \
                "PasswordAuthentication no" \
                > /etc/ssh/sshd_config &&
            exec /usr/sbin/sshd -D -e
        '

    registrarOperacion "Esperando instalación y configuración de OpenSSH"
    ssh_listo=false
    for intento in {1..60}; do
        if docker exec servidor-archivos /usr/sbin/sshd -t >/dev/null 2>&1; then
            ssh_listo=true
            break
        fi

        if [[ "$(docker inspect -f '{{.State.Status}}' servidor-archivos)" != "running" ]]; then
            break
        fi
        sleep 2
    done

    if [[ "$ssh_listo" != true ]]; then
        docker logs servidor-archivos || true
        manejar_error 1 "$LINENO" "No fue posible instalar o iniciar OpenSSH en Alpine"
    fi

    registrarOperacion "OpenSSH instalado y configurado correctamente"
    registrarOperacion "Desconectando Alpine de la red bridge"
    docker network disconnect bridge servidor-archivos
    registrarOperacion "Conectando Alpine a la red interna"
    docker network connect "$RED" servidor-archivos
    registrarOperacion "Servidor Alpine conectado a $RED"
fi

registrarOperacion "VERIFICANDO ESTADO DE LOS CONTENEDORES"

for nombre in servidor-ssh servidor-web servidor-archivos; do
    if ! docker container inspect "$nombre" >/dev/null 2>&1; then
        manejar_error 1 "$LINENO" "No existe el contenedor $nombre"
    fi

    estado="$(docker inspect -f '{{.State.Status}}' "$nombre")"

    if [[ "$estado" != "running" ]]; then
        manejar_error 1 "$LINENO" "El contenedor $nombre no está funcionando"
    fi
    registrarOperacion "Contenedor $nombre operativo"
done

registrarOperacion "Verificando conectividad de la red interna"
docker network inspect "$RED" >/dev/null
registrarOperacion "Red interna verificada"
registrarOperacion "DESPLIEGUE FINALIZADO CORRECTAMENTE"

echo ""
echo "=============================================="
echo "       DESPLIEGUE FINALIZADO"
echo "=============================================="
echo "Red: $RED"
echo "Volumen web: $VOLUMEN_WEB"
echo "Volumen archivos: $VOLUMEN_ARCHIVOS"
echo ""
echo "Bastion SSH: puerto 2222"
echo "Servidor web: puerto 8080"
echo "Servidor archivos: puerto 2223"
echo ""
echo "Contenedores:"
docker ps --filter name=servidor-ssh --filter name=servidor-web --filter name=servidor-archivos
echo ""
echo "Registro local: $LOG_LOCAL"
echo "=============================================="

exit 0
