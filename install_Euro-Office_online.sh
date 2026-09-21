#!/usr/bin/env bash

set -euo pipefail

# --- Couleurs pour l'affichage ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DARKGRAY='\033[1;30m'
NC='\033[0m' # No Color

# --- Fonctions utilitaires ---
fail() {
    echo -e "${RED}ERREUR : $1${NC}" >&2
    exit 1
}

invoke_docker() {
    local description="$1"
    shift
    echo -e "${DARKGRAY}> docker $*${NC}"
    if ! docker "$@"; then
        fail "Échec lors de l'étape : $description."
    fi
}

assert_port() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        fail "$name doit être un numéro de port compris entre 1 et 65535. Valeur reçue : '$value'."
    fi
}

# --- Vérification des privilèges root ---
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Erreur : Ce script doit être exécuté avec des privilèges d'administrateur (sudo).${NC}"
    exit 1
fi

# --- Traitement des arguments ---
usage() {
    echo "Usage : $0 [-r <RepEuroOffice>] -d <NomDnsServeur> -p <PortHttp> -s <PortHttps>"
    echo "  -r : Répertoire d'installation (optionnel, défaut : /var/www/euro-office)"
    echo "  -d : Nom DNS / FQDN / IP du serveur (obligatoire)"
    echo "  -p : Port HTTP externe (obligatoire)"
    echo "  -s : Port HTTPS externe (obligatoire)"
    exit 1
}

REP_EURO_OFFICE="/var/www/euro-office"
NOM_DNS_SERVEUR=""
PORT_HTTP=""
PORT_HTTPS=""

while getopts "r:d:p:s:" opt; do
    case "$opt" in
        r) REP_EURO_OFFICE="$OPTARG" ;;
        d) NOM_DNS_SERVEUR="$OPTARG" ;;
        p) PORT_HTTP="$OPTARG" ;;
        s) PORT_HTTPS="$OPTARG" ;;
        *) usage ;;
    esac
done

if [[ -z "$NOM_DNS_SERVEUR" || -z "$PORT_HTTP" || -z "$PORT_HTTPS" ]]; then
    fail "Les paramètres (-d, -p, -s) sont obligatoires."
fi

# --- Validation des variables ---
assert_port "PORTHTTP" "$PORT_HTTP"
assert_port "PORTHTTPS" "$PORT_HTTPS"

NOM_DNS_SERVEUR="$(echo "$NOM_DNS_SERVEUR" | xargs)"
if [[ -z "$NOM_DNS_SERVEUR" ]]; then
    fail "NOMDNSSERVEUR ne peut pas être vide."
fi

if [[ ! "$NOM_DNS_SERVEUR" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; then
    fail "NOMDNSSERVEUR contient des caractères invalides : '$NOM_DNS_SERVEUR'."
fi

# --- [1/4] Vérification et installation de Docker et dépendances ---
echo -e "${BLUE}=== [1/4] Vérification de la présence de Docker et des outils ===${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}[- ] Docker n'est pas détecté sur cette machine.${NC}"
    echo -e "${CYAN}--> Lancement de la procédure d'installation de Docker...${NC}"
    
    OS_ID="$(. /etc/os-release && echo "$ID")"
    if [[ "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" ]]; then
        fail "Distribution non prise en charge ('$OS_ID'). Ce script nécessite Debian ou Ubuntu."
    fi

    echo "   * Mise à jour des index des paquets et installation des dépendances..."
    apt update
    apt install -y ca-certificates curl gnupg jq

    echo "   * Ajout de la clé GPG officielle de Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "   * Configuration du dépôt officiel Docker ($OS_ID - DEB822)..."
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${OS_ID}
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    echo "   * Installation de Docker Engine et des composants..."
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if [ -n "${SUDO_USER:-}" ]; then
        echo "   * Ajout de l'utilisateur '$SUDO_USER' au groupe docker..."
        usermod -aG docker "$SUDO_USER"
    fi
    
    echo -e "${GREEN}[✓] Docker a été installé et configuré avec succès !${NC}"
else
    echo -e "${GREEN}[✓] Docker est déjà installé sur cette machine.${NC}"
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        apt update && apt install -y jq curl
    fi
fi

if ! docker compose version &>/dev/null; then
    fail "Docker Compose v2 est indisponible. Vérifiez que le service Docker est démarré."
fi

# --- Préparation des chemins ---
IMAGE="ghcr.io/euro-office/documentserver:v9.3.3"
CONTAINER_NAME="euro-office"
TEMP_CONTAINER_NAME="eo-temp"

ROOT="$(realpath -m "$REP_EURO_OFFICE")"
DATA_PATH="$ROOT/data"
PRIVATE_PATH="$ROOT/private"
LOGS_PATH="$ROOT/logs"
CONFIG_PATH="$ROOT/config"
CERT_PATH="$CONFIG_PATH/nginx/certificats"
COMPOSE_PATH="$ROOT/docker-compose.yml"
DS_CONF_PATH="$CONFIG_PATH/nginx/ds.conf"
DEFAULT_JSON_PATH="$CONFIG_PATH/default.json"

echo -e "${CYAN}=== Configuration EuroOffice Docker ===${NC}"
echo "Répertoire : $ROOT"
echo "Nom DNS    : $NOM_DNS_SERVEUR"
echo "Port HTTP  : $PORT_HTTP"
echo "Port HTTPS : $PORT_HTTPS"

mkdir -p "$ROOT" "$DATA_PATH" "$PRIVATE_PATH" "$LOGS_PATH" "$CONFIG_PATH" "$CERT_PATH"

# --- [2/4] Récupération de l'image et préparation de la conf ---
echo -e "${BLUE}=== [2/4] Préparation de la configuration ===${NC}"
echo -e "${YELLOW}Téléchargement de l'image EuroOffice...${NC}"
invoke_docker "téléchargement de l'image Docker" pull "$IMAGE"

echo -e "${YELLOW}Nettoyage du conteneur temporaire éventuel '$TEMP_CONTAINER_NAME'.${NC}"
docker rm -f "$TEMP_CONTAINER_NAME" &>/dev/null || true

echo -e "${YELLOW}Initialisation des répertoires config et logs depuis l'image...${NC}"
invoke_docker "création du conteneur temporaire" create --name "$TEMP_CONTAINER_NAME" "$IMAGE"
invoke_docker "copie de la configuration depuis l'image" cp "$TEMP_CONTAINER_NAME:/etc/euro-office/documentserver/." "$CONFIG_PATH"
invoke_docker "copie des logs depuis l'image" cp "$TEMP_CONTAINER_NAME:/var/log/euro-office/documentserver/." "$LOGS_PATH"
docker rm -f "$TEMP_CONTAINER_NAME" &>/dev/null || true

if [[ ! -f "$DS_CONF_PATH" ]]; then
    fail "Fichier introuvable après initialisation : $DS_CONF_PATH"
fi
if [[ ! -f "$DEFAULT_JSON_PATH" ]]; then
    fail "Fichier introuvable après initialisation : $DEFAULT_JSON_PATH"
fi

# --- Certificat TLS Auto-signé ---
echo -e "${YELLOW}Génération du certificat auto-signé HTTPS...${NC}"
CERTIFICATE_FILE="$CERT_PATH/euro-office.crt"
KEY_FILE="$CERT_PATH/euro-office.key"

if [[ ! -f "$CERTIFICATE_FILE" || ! -f "$KEY_FILE" ]]; then
    SUBJECT_ALT_NAME="DNS:$NOM_DNS_SERVEUR,DNS:localhost,IP:127.0.0.1"
    invoke_docker "génération du certificat auto-signé" run --rm \
        -v "$CERT_PATH:/certs" \
        alpine/openssl req -x509 -nodes \
        -days 3650 -newkey rsa:2048 \
        -keyout /certs/euro-office.key \
        -out /certs/euro-office.crt \
        -subj "/CN=$NOM_DNS_SERVEUR" \
        -addext "subjectAltName=$SUBJECT_ALT_NAME"
else
    echo -e "${DARKGRAY}Certificat existant conservé.${NC}"
fi

# --- Configuration Nginx (ds.conf) ---
echo -e "${YELLOW}Ajout du bloc HTTPS dans ds.conf...${NC}"
if ! grep -q "listen 0\.0\.0\.0:443" "$DS_CONF_PATH"; then
    cat << 'EOF' >> "$DS_CONF_PATH"

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
EOF
    echo -e "${GREEN}Bloc HTTPS ajouté.${NC}"
else
    echo -e "${DARKGRAY}Bloc HTTPS déjà présent, ajout ignoré.${NC}"
fi

# --- Modification et enrichissement de default.json ---
echo -e "${YELLOW}Modification et validation de default.json...${NC}"

# 1. Remplacements globaux (regex)
sed -i -E 's/("rejectUnauthorized"[[:space:]]*:[[:space:]]*)true/\1false/g' "$DEFAULT_JSON_PATH"
sed -i -E 's/("mode"[[:space:]]*:[[:space:]]*)"development"/\1"production"/g' "$DEFAULT_JSON_PATH"
sed -i -E 's/("jwtToken"[[:space:]]*:[[:space:]]*)true/\1false/g' "$DEFAULT_JSON_PATH"
sed -i -E 's/("blockPrivateIP"[[:space:]]*:[[:space:]]*)true/\1false/g' "$DEFAULT_JSON_PATH"

# 2. Ajout du bloc FileStorage à la fin du JSON
TMP_JSON="$(mktemp)"
if jq '.FileStorage = {
  "host": "",
  "port": 4567,
  "directory": "",
  "silent": true
}' "$DEFAULT_JSON_PATH" > "$TMP_JSON"; then
    mv "$TMP_JSON" "$DEFAULT_JSON_PATH"
    echo -e "${GREEN}default.json validé, mis à jour et augmenté de FileStorage.${NC}"
else
    rm -f "$TMP_JSON"
    fail "default.json n'est plus un JSON valide après modification."
fi

# --- Gestion des droits sur les dossiers montés ---
echo -e "${YELLOW}Ajustement des permissions des dossiers montés...${NC}"
chmod -R 777 "$DATA_PATH" "$PRIVATE_PATH" "$LOGS_PATH" "$CONFIG_PATH"

# --- Génération du secret JWT et création de docker-compose.yml ---
echo -e "${YELLOW}Génération du secret JWT et création de docker-compose.yml...${NC}"
JWT="$(head -c 500 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 40)"

cat << EOF > "$COMPOSE_PATH"
services:
  euro-office:
    image: "$IMAGE"
    container_name: "$CONTAINER_NAME"
    restart: "unless-stopped"
    ports:
      - "${PORT_HTTP}:80"
      - "${PORT_HTTPS}:443"
    environment:
      JWT_ENABLED: "false"
      JWT_SECRET: "$JWT"
      ALLOW_PRIVATE_IP_ADDRESS: "true"
      EXAMPLE_ENABLED: "false"
      WOPI_ENABLED: "false"
      NGINX_WORKER_PROCESSES: "2"
    extra_hosts:
      - "${NOM_DNS_SERVEUR}:host-gateway"
    volumes:
      - "${DATA_PATH}:/var/lib/euro-office/documentserver"
      - "${PRIVATE_PATH}:/var/www/euro-office/Data"
      - "${LOGS_PATH}:/var/log/euro-office/documentserver"
      - "${CONFIG_PATH}:/etc/euro-office/documentserver"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

# --- [3/4] Déploiement du conteneur ---
echo -e "${BLUE}=== [3/4] Déploiement du conteneur Euro-Office ===${NC}"
if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
    echo -e "${YELLOW}--> Suppression de l'ancien conteneur détecté...${NC}"
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
fi

(
    cd "$ROOT"
    invoke_docker "démarrage du service EuroOffice" compose up -d
)

# --- [4/4] Vérification du Healthcheck ---
echo -e "${BLUE}=== [4/4] Vérification de l'état du service ===${NC}"
echo -e "${YELLOW}Attente de la réponse du healthcheck HTTP (démarrage des services internes)...${NC}"
HEALTHY=false

for ((attempt=1; attempt<=30; attempt++)); do
    echo -ne "   * Vérification en cours... ($attempt/30)\r"
    if HEALTH_RESPONSE=$(curl --silent --fail "http://localhost:${PORT_HTTP}/healthcheck" 2>/dev/null); then
        if [[ "$HEALTH_RESPONSE" =~ "true" ]]; then
            HEALTHY=true
            echo -e "\n${GREEN}[✓] Healthcheck OK : le service répond.${NC}"
            break
        fi
    fi
    sleep 5
done

echo ""
(
    cd "$ROOT"
    docker compose ps
)

# Détection dynamique de l'IP active du serveur
ADD_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}')

if [ "$HEALTHY" = true ]; then
    echo -e "${GREEN}=========================================================================="
    echo "                  Installation terminée avec succès !"
    echo " Euro-Office DocumentServer est accessible sur :"
    echo "  - HTTP  : http://${ADD_IP}:${PORT_HTTP}  (ou http://${NOM_DNS_SERVEUR}:${PORT_HTTP})"
    echo "  - HTTPS : https://${ADD_IP}:${PORT_HTTPS} (ou https://${NOM_DNS_SERVEUR}:${PORT_HTTPS})"
    echo -e "==========================================================================${NC}"
else
    echo -e "${RED}[X] Le healthcheck n'a pas répondu après 2 minutes. Affichage des derniers logs du conteneur :${NC}"
    echo "----------------------------------------------------------------------"
    docker logs --tail 30 "$CONTAINER_NAME" || true
    echo "----------------------------------------------------------------------"
    echo -e "${YELLOW}Si une erreur apparaît ci-dessus, supprime le dossier d'installation et relance le script.${NC}"
fi
