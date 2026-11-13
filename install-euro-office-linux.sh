#!/usr/bin/env bash
#
# Script d'installation combiné : Docker + Euro-Office Document Server
# Compatible 100% : Debian 12/13, Ubuntu 22.04/24.04, AlmaLinux 8/9/10 (toutes versions noyau)
#
set -Eeuo pipefail
IFS=$'\n\t'

log_step() {
    echo -e "\n\033[1;34m=== $* ===\033[0m"
}

fail() {
    echo "ERREUR : $*" >&2
    exit 1
}

log() {
    echo "[$(date '+%F %T')] $*"
}

[[ "${EUID}" -eq 0 ]] || fail "Lancez ce script avec sudo ou en tant que root."

# ==========================================
# 0. PARAMÈTRES, ARGUMENTS & DÉTECTION OS
# ==========================================
IMAGE="ghcr.io/euro-office/documentserver:v9.3.7"
CONTAINER_NAME="euro-office"
TEMP_CONTAINER_NAME="eo-temp"
ROOT="/opt/euro-office"
DNS_NAME="localhost"
PORT_HTTP="8085"
PORT_HTTPS="8443"

usage() {
    cat <<'EOF'
Usage:
  sudo ./install-euro-office-linux.sh [options]

Options:
  --dir PATH       Répertoire d'installation (défaut: /opt/euro-office)
  --dns NAME       Nom DNS du serveur (défaut: localhost)
  --http PORT      Port HTTP exposé par l'hôte (défaut: 8085)
  --https PORT     Port HTTPS exposé par l'hôte (défaut: 8443)
  --help           Afficher cette aide

Exemple:
  sudo ./install-euro-office-linux.sh --dns euro-office.efalia.com
EOF
}

assert_port() {
    local name="$1" value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$name doit être un numéro de port. Valeur reçue : '$value'."
    (( value >= 1 && value <= 65535 )) || fail "$name doit être compris entre 1 et 65535. Valeur reçue : '$value'."
}

validate_dns() {
    local value="$1"
    [[ -n "$value" ]] || fail "Le nom DNS ne peut pas être vide."
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || \
        fail "Le nom DNS contient des caractères invalides : '$value'."
}

# Nettoie les espaces insécables éventuels issus d'un copier-coller
CLEAN_ARGS=()
for arg in "$@"; do
    CLEAN_ARGS+=("${arg//$'\xc2\xa0'/}")
done
set -- "${CLEAN_ARGS[@]}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)
            [[ $# -ge 2 ]] || fail "Valeur manquante pour --dir."
            ROOT="$2"; shift 2 ;;
        --dns)
            [[ $# -ge 2 ]] || fail "Valeur manquante pour --dns."
            DNS_NAME="$2"; shift 2 ;;
        --http)
            [[ $# -ge 2 ]] || fail "Valeur manquante pour --http."
            PORT_HTTP="$2"; shift 2 ;;
        --https)
            [[ $# -ge 2 ]] || fail "Valeur manquante pour --https."
            PORT_HTTPS="$2"; shift 2 ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            usage >&2
            fail "Option inconnue : $1" ;;
    esac
done

assert_port PORTHTTP "$PORT_HTTP"
assert_port PORTHTTPS "$PORT_HTTPS"
validate_dns "$DNS_NAME"

OS_ID="unknown"
VERSION_MAJOR=""
CODENAME=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    VERSION_MAJOR="${VERSION_ID%%.*}"
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
fi

# ==========================================
# 1. PRÉREQUIS SYSTÈME & INSTALLATION DOCKER
# ==========================================
apt_update_clean() {
    local max_attempts=3
    local attempt=1
    while (( attempt <= max_attempts )); do
        rm -rf /var/lib/apt/lists/*
        apt-get clean
        if apt-get update -o Acquire::http::No-Cache=True -o Acquire::BrokenProxy=True; then
            return 0
        fi
        echo "[AVERTISSEMENT] Échec apt-get update (tentative $attempt/$max_attempts), nouvelle tentative dans 5s..." >&2
        sleep 5
        ((attempt++))
    done
    fail "Impossible de mettre à jour les index APT après $max_attempts tentatives."
}

case "$OS_ID" in
    debian|ubuntu)
        [[ -n "$CODENAME" ]] || fail "Impossible de déterminer le nom de code de la version ($OS_ID)."
        log_step "1. Mise à jour APT et installation des prérequis ($OS_ID $CODENAME)"
        apt_update_clean
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg openssl python3

        if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
            log_step "2. Configuration de la clé GPG et du dépôt Docker ($OS_ID)"
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} \
              ${CODENAME} stable" | \
              tee /etc/apt/sources.list.d/docker.list > /dev/null

            log_step "3. Installation de Docker Engine et Compose"
            apt_update_clean
            DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

            log_step "4. Démarrage et activation du service Docker"
            systemctl enable --now docker
        else
            echo "[INFO] Docker et Docker Compose sont déjà installés."
        fi
        ;;

    almalinux|rocky|rhel|centos)
        log_step "1. Installation des prérequis système ($OS_ID $VERSION_MAJOR)"
        dnf install -y --allowerasing ca-certificates curl openssl python3

        # Adaptation universelle toutes versions de noyau (EL8, EL9, EL10+) :
        # 1. On vérifie/charge xt_addrtype sur le noyau actif $(uname -r)
        # 2. Si absent (noyau mis à jour sans reboot), on contourne via firewalld sans bloquer
        if ! modprobe xt_addrtype 2>/dev/null; then
            dnf install -y "kernel-modules-extra-$(uname -r)" 2>/dev/null || dnf install -y kernel-modules-extra || true
            if ! modprobe xt_addrtype 2>/dev/null; then
                log "Module xt_addrtype indisponible sur le noyau actif ($(uname -r)) : activation du mode NAT compatible sans reboot..."
                mkdir -p /etc/docker
                printf '{\n  "iptables": false,\n  "ip6tables": false\n}\n' > /etc/docker/daemon.json
                if systemctl is-active --quiet firewalld; then
                    firewall-cmd --zone=public --add-masquerade --permanent >/dev/null 2>&1 || true
                    firewall-cmd --zone=public --add-port="${PORT_HTTP}/tcp" --permanent >/dev/null 2>&1 || true
                    firewall-cmd --zone=public --add-port="${PORT_HTTPS}/tcp" --permanent >/dev/null 2>&1 || true
                    firewall-cmd --reload >/dev/null 2>&1 || true
                fi
            fi
        fi

        if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
            log_step "2. Ajout du dépôt officiel Docker CE ($OS_ID)"
            curl -fsSL https://download.docker.com/linux/centos/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo

            log_step "3. Installation de Docker Engine et Compose"
            dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

            log_step "4. Démarrage et activation du service Docker"
            systemctl enable --now docker
        else
            echo "[INFO] Docker et Docker Compose sont déjà installés."
            systemctl enable --now docker
        fi
        ;;

    *)
        if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
            fail "Distribution '$OS_ID' non reconnue pour l'installation automatique. Installez Docker manuellement avant de relancer."
        fi
        echo "[INFO] Distribution '$OS_ID' : Docker déjà présent, poursuite du déploiement."
        ;;
esac

docker version --format 'Docker Engine Version: {{.Server.Version}}'
docker compose version

# ==========================================
# 2. INSTALLATION D'EURO-OFFICE
# ==========================================
run_docker() {
    log "+ docker $*"
    docker "$@"
}

normalize_volume_permissions() {
    log "Correction des propriétaires et permissions des volumes..."
    run_docker run --rm --user 0 \
        -v "$DATA_PATH:/var/lib/euro-office/documentserver${VOLUME_SUFFIX}" \
        -v "$PRIVATE_PATH:/var/www/euro-office/Data${VOLUME_SUFFIX}" \
        -v "$LOGS_PATH:/var/log/euro-office/documentserver${VOLUME_SUFFIX}" \
        -v "$CONFIG_PATH:/etc/euro-office/documentserver${VOLUME_SUFFIX}" \
        --entrypoint /bin/sh "$IMAGE" -c '
set -eu

chown -R ds:ds \
    /var/lib/euro-office/documentserver \
    /var/www/euro-office/Data \
    /var/log/euro-office/documentserver \
    /etc/euro-office/documentserver

find /etc/euro-office/documentserver \
    -type d -exec chmod 755 {} \;
find /etc/euro-office/documentserver \
    -type f -exec chmod 640 {} \;

find /var/lib/euro-office/documentserver \
    /var/www/euro-office/Data \
    /var/log/euro-office/documentserver \
    -type d -exec chmod 750 {} \;
find /var/lib/euro-office/documentserver \
    /var/www/euro-office/Data \
    /var/log/euro-office/documentserver \
    -type f -exec chmod 640 {} \;

if [ -f /etc/euro-office/documentserver/nginx/certificats/euro-office.key ]; then
    chown root:root /etc/euro-office/documentserver/nginx/certificats/euro-office.key
    chmod 600 /etc/euro-office/documentserver/nginx/certificats/euro-office.key
fi
'
}

assert_command() {
    command -v "$1" >/dev/null 2>&1 || fail "La commande '$1' est introuvable."
}

assert_command curl
assert_command openssl
assert_command python3

ROOT="$(readlink -f "$ROOT")"
DATA_PATH="$ROOT/data"
PRIVATE_PATH="$ROOT/private"
LOGS_PATH="$ROOT/logs"
CONFIG_PATH="$ROOT/config"
CERT_PATH="$CONFIG_PATH/nginx/certificats"
COMPOSE_PATH="$ROOT/docker-compose.yml"
DS_CONF_PATH="$CONFIG_PATH/nginx/ds.conf"
DEFAULT_JSON_PATH="$CONFIG_PATH/default.json"

log "=== Installation Euroffice Docker Linux ==="
log "OS détecté : $OS_ID $VERSION_MAJOR (noyau $(uname -r))"
log "Répertoire : $ROOT"
log "Nom DNS    : $DNS_NAME"
log "Port HTTP  : $PORT_HTTP"
log "Port HTTPS : $PORT_HTTPS"
log "Image      : $IMAGE"

install -d -m 0750 "$ROOT" "$DATA_PATH" "$PRIVATE_PATH" "$LOGS_PATH" "$CONFIG_PATH" "$CERT_PATH"

VOLUME_SUFFIX=""
if command -v getenforce >/dev/null 2>&1; then
    SELINUX_MODE="$(getenforce || true)"
    if [[ "$SELINUX_MODE" == "Enforcing" || "$SELINUX_MODE" == "Permissive" ]]; then
        VOLUME_SUFFIX=":Z"
        log "SELinux détecté ($SELINUX_MODE) : suffixe :Z appliqué aux volumes."
    fi
fi

log "Téléchargement de l'image Euroffice..."
run_docker pull "$IMAGE"

if [[ -f "$COMPOSE_PATH" ]]; then
    log "Arrêt de la stack Euroffice existante avant mise à jour..."
    docker compose -f "$COMPOSE_PATH" down --remove-orphans || true
fi

log "Nettoyage du conteneur temporaire éventuel '$TEMP_CONTAINER_NAME'."
docker rm -f "$TEMP_CONTAINER_NAME" >/dev/null 2>&1 || true

TEMP_CREATED=0
cleanup() {
    if [[ "$TEMP_CREATED" -eq 1 ]]; then
        docker rm -f "$TEMP_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

log "Initialisation de la configuration et des logs depuis l'image..."
run_docker create --name "$TEMP_CONTAINER_NAME" "$IMAGE" >/dev/null
TEMP_CREATED=1
run_docker cp "$TEMP_CONTAINER_NAME:/etc/euro-office/documentserver/." "$CONFIG_PATH/"
run_docker cp "$TEMP_CONTAINER_NAME:/var/log/euro-office/documentserver/." "$LOGS_PATH/"
mkdir -p "$CERT_PATH"

[[ -f "$DS_CONF_PATH" ]] || fail "Fichier introuvable après initialisation : $DS_CONF_PATH"
[[ -f "$DEFAULT_JSON_PATH" ]] || fail "Fichier introuvable après initialisation : $DEFAULT_JSON_PATH"

log "Génération du certificat auto-signé HTTPS si nécessaire..."
CERT_FILE="$CERT_PATH/euro-office.crt"
KEY_FILE="$CERT_PATH/euro-office.key"
if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
    run_docker run --rm \
        -v "$CERT_PATH:/certs${VOLUME_SUFFIX}" \
        alpine/openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /certs/euro-office.key \
        -out /certs/euro-office.crt \
        -subj "/CN=$DNS_NAME" \
        -addext "subjectAltName=DNS:$DNS_NAME,DNS:localhost,IP:127.0.0.1"
    chmod 0644 "$CERT_FILE"
    chmod 0600 "$KEY_FILE"
else
    log "Certificat existant conservé."
fi

log "Ajout du bloc HTTPS dans ds.conf si nécessaire..."
if ! grep -qE 'listen[[:space:]]+0\.0\.0\.0:443' "$DS_CONF_PATH"; then
    cat >> "$DS_CONF_PATH" <<'NGINX'

server {
    listen 0.0.0.0:443 ssl;
    listen [::]:443 ssl default_server;
    server_tokens off;

    ssl_certificate     /etc/euro-office/documentserver/nginx/certificats/euro-office.crt;
    ssl_certificate_key /etc/euro-office/documentserver/nginx/certificats/euro-office.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    set $secure_link_secret verysecretstring;
    include /etc/nginx/includes/ds-*.conf;
}
NGINX
    log "Bloc HTTPS ajouté."
else
    log "Bloc HTTPS déjà présent, ajout ignoré."
fi

log "Modification et validation de default.json..."
python3 - "$DEFAULT_JSON_PATH" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open('r', encoding='utf-8') as f:
    data = json.load(f)

targets = {
    'rejectUnauthorized': False,
    'mode': 'production',
    'jwtToken': False,
    'blockPrivateIP': False,
}
changed = 0

def walk(value):
    global changed
    if isinstance(value, dict):
        for key, child in list(value.items()):
            if key in targets:
                value[key] = targets[key]
                changed += 1
            else:
                walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)

walk(data)
with path.open('w', encoding='utf-8', newline='\n') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(f"Clés JSON mises à jour : {changed}")
PY

normalize_volume_permissions

log "Génération du secret JWT et création de docker-compose.yml..."
JWT_SECRET="$(openssl rand -hex 40)"
cat > "$COMPOSE_PATH" <<EOF
services:
  euro-office:
    image: "$IMAGE"
    container_name: "$CONTAINER_NAME"
    restart: "unless-stopped"
    shm_size: "1g"
    ports:
      - "$PORT_HTTP:80"
      - "$PORT_HTTPS:443"
    environment:
      JWT_ENABLED: "false"
      JWT_SECRET: "$JWT_SECRET"
      ALLOW_PRIVATE_IP_ADDRESS: "true"
      EXAMPLE_ENABLED: "false"
      WOPI_ENABLED: "false"
      NGINX_WORKER_PROCESSES: "2"
    extra_hosts:
      - "$DNS_NAME:host-gateway"
    volumes:
      - "$DATA_PATH:/var/lib/euro-office/documentserver$VOLUME_SUFFIX"
      - "$PRIVATE_PATH:/var/www/euro-office/Data$VOLUME_SUFFIX"
      - "$LOGS_PATH:/var/log/euro-office/documentserver$VOLUME_SUFFIX"
      - "$CONFIG_PATH:/etc/euro-office/documentserver$VOLUME_SUFFIX"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF
chmod 0600 "$COMPOSE_PATH"

log "Validation du fichier Compose..."
docker compose -f "$COMPOSE_PATH" config >/dev/null

log "Démarrage du service Euroffice..."
docker compose -f "$COMPOSE_PATH" up -d

log "Attente de la réponse du healthcheck HTTP..."
HEALTHY=0
response=""
for attempt in $(seq 1 60); do
    if response="$(curl --silent --show-error --fail "http://127.0.0.1:${PORT_HTTP}/healthcheck" 2>/dev/null)" && grep -q 'true' <<<"$response"; then
        HEALTHY=1
        break
    fi
    sleep 5
done

docker compose -f "$COMPOSE_PATH" ps

if [[ "$HEALTHY" -eq 1 ]]; then
    log "Healthcheck OK : le service répond."
else
    echo "AVERTISSEMENT : le service est démarré, mais le healthcheck n'est pas encore disponible." >&2
    echo "Consultez les logs avec : docker compose -f '$COMPOSE_PATH' logs -f" >&2
fi

log "Accès HTTP  : http://$DNS_NAME:$PORT_HTTP/"
log "Accès HTTPS : https://$DNS_NAME:$PORT_HTTPS/"
log "Installation terminée."
