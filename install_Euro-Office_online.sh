#!/bin/bash

# ==============================================================================
# Script d'installation automatisé d'Euro-Office & Docker
# Destiné à : Debian 12 (Bookworm) / Debian 13 (Trixie)
# ==============================================================================

# Arrêt immédiat du script en cas d'erreur
set -e

CONTAINER_NAME="euro-office-server"
CONFIG_FILE="default.json"
LOCAL_CONFIG_FILE="local.json"
GITHUB_CONFIG_URL="https://raw.githubusercontent.com/pagna69/eurooffice-deploy/refs/heads/main/default_Euro-Office.json"
IMAGE="ghcr.io/euro-office/documentserver:latest"

# Définition des codes couleurs ANSI
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DARKGRAY='\033[1;30m'
NC='\033[0m' # Reset

# Restauration du terminal en cas d'interruption
trap 'echo -e "${NC}"; exit 1' INT TERM

# --- Fonctions utilitaires ---
fail() {
    echo -e "${RED}Erreur : $1${NC}" >&2
    exit 1
}

assert_port() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        fail "$name doit être un numéro de port compris entre 1 et 65535. Valeur reçue : '$value'."
    fi
}

usage() {
    echo "Usage : $0 [-r <RepEuroOffice>] -d <NomDnsServeur> -p <PortHttp> -s <PortHttps>"
    echo "  -r : Répertoire de déploiement compose (optionnel, défaut : /var/www/euro-office)"
    echo "  -d : Nom DNS / FQDN / IP du serveur (obligatoire)"
    echo "  -p : Port HTTP externe (obligatoire)"
    echo "  -s : Port HTTPS externe (obligatoire)"
    exit 1
}

# --- Vérification des privilèges root ---
if [ "$EUID" -ne 0 ]; then
    fail "Ce script doit être exécuté avec des privilèges d'administrateur (sudo)."
fi

# --- Traitement des arguments ---
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
    fail "Les paramètres -d, -p et -s sont obligatoires."
fi

# --- Validation des variables ---
assert_port "PORT_HTTP" "$PORT_HTTP"
assert_port "PORT_HTTPS" "$PORT_HTTPS"

NOM_DNS_SERVEUR="$(echo "$NOM_DNS_SERVEUR" | xargs)"
if [[ -z "$NOM_DNS_SERVEUR" ]]; then
    fail "NOM_DNS_SERVEUR ne peut pas être vide."
fi

# --- Initialisation des dossiers de travail et de l'arborescence fixe ---
BASE_DIR="$(realpath -m "$REP_EURO_OFFICE")"
CONFIG_PATH="/etc/euro-office/documentserver"
DATA_PATH="/var/lib/euro-office/documentserver"
LOGS_PATH="/var/log/euro-office/documentserver"
PRIVATE_PATH="/var/www/euro-office/Data"
CERT_PATH="$CONFIG_PATH/nginx/certificats"
DS_CONF_PATH="$CONFIG_PATH/nginx/ds.conf"
COMPOSE_PATH="$BASE_DIR/docker-compose.yml"

mkdir -p "$CONFIG_PATH" "$DATA_PATH" "$LOGS_PATH" "$PRIVATE_PATH" "$CERT_PATH" "$(dirname "$DS_CONF_PATH")" "$BASE_DIR"

# --- [1/4] Vérification / Installation de Docker & dépendances ---
echo -e "${BLUE}=== [1/4] Vérification des dépendances et de Docker ===${NC}"

# Installation de jq si absent
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}[- ] Installation de jq...${NC}"
    apt update && apt install -y jq
fi

if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}[- ] Docker n'est pas détecté sur cette machine.${NC}"
    echo -e "${CYAN}--> Lancement de la procédure d'installation de Docker...${NC}"
    
    echo "   * Mise à jour des index des paquets et installation des dépendances..."
    apt update
    apt install -y ca-certificates curl gnupg

    echo "   * Ajout de la clé GPG officielle de Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "   * Configuration du dépôt officiel Docker (DEB822)..."
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    echo "   * Installation de Docker Engine..."
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if [ -n "$SUDO_USER" ]; then
        echo "   * Ajout de l'utilisateur '$SUDO_USER' au groupe docker..."
        usermod -aG docker "$SUDO_USER"
    fi
    
    echo -e "${GREEN}[✓] Docker a été installé et configuré avec succès !${NC}"
else
    echo -e "${GREEN}[✓] Docker est déjà installé sur cette machine.${NC}"
fi

# --- [2/4] Préparation des fichiers de configuration locale ---
echo -e "${BLUE}=== [2/4] Préparation de la configuration locale ===${NC}"

# 1. Téléchargement de default.json dans /etc/euro-office/documentserver/
DEFAULT_JSON_PATH="$CONFIG_PATH/$CONFIG_FILE"
if [ ! -f "$DEFAULT_JSON_PATH" ]; then
    echo -e "${CYAN}--> Téléchargement de $CONFIG_FILE depuis GitHub dans $CONFIG_PATH...${NC}"
    if curl -sS -o "$DEFAULT_JSON_PATH" "$GITHUB_CONFIG_URL"; then
        echo -e "${GREEN}[✓] Fichier de configuration par défaut récupéré avec succès.${NC}"
    else
        fail "Impossible de télécharger le fichier de configuration depuis GitHub."
    fi
else
    echo -e "${DARKGRAY}Fichier de configuration $DEFAULT_JSON_PATH déjà présent.${NC}"
fi

# 2. Initialisation obligatoire de local.json pour éviter les erreurs jq
LOCAL_JSON_PATH="$CONFIG_PATH/$LOCAL_CONFIG_FILE"
if [ ! -f "$LOCAL_JSON_PATH" ]; then
    echo -e "${CYAN}--> Initialisation du fichier $LOCAL_CONFIG_FILE...${NC}"
    echo "{}" > "$LOCAL_JSON_PATH"
    echo -e "${GREEN}[✓] Fichier $LOCAL_JSON_PATH créé.${NC}"
else
    echo -e "${DARKGRAY}Fichier $LOCAL_JSON_PATH déjà présent.${NC}"
fi

# Certificat TLS Auto-signé
CERTIFICATE_FILE="$CERT_PATH/euro-office.crt"
KEY_FILE="$CERT_PATH/euro-office.key"

if [[ ! -f "$CERTIFICATE_FILE" || ! -f "$KEY_FILE" ]]; then
    echo -e "${YELLOW}Génération du certificat auto-signé HTTPS...${NC}"
    SUBJECT_ALT_NAME="DNS:$NOM_DNS_SERVEUR,DNS:localhost,IP:127.0.0.1"
    docker run --rm \
        -v "$CERT_PATH:/certs" \
        alpine/openssl req -x509 -nodes \
        -days 3650 -newkey rsa:2048 \
        -keyout /certs/euro-office.key \
        -out /certs/euro-office.crt \
        -subj "/CN=$NOM_DNS_SERVEUR" \
        -addext "subjectAltName=$SUBJECT_ALT_NAME"
    echo -e "${GREEN}[✓] Certificat généré.${NC}"
else
    echo -e "${DARKGRAY}Certificat existant conservé.${NC}"
fi

# Configuration Nginx (ds.conf)
if [ ! -f "$DS_CONF_PATH" ] || ! grep -q "listen 0\.0\.0\.0:443" "$DS_CONF_PATH"; then
    echo -e "${YELLOW}Ajout du bloc HTTPS dans ds.conf...${NC}"
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
    echo -e "${GREEN}[✓] Bloc HTTPS ajouté.${NC}"
else
    echo -e "${DARKGRAY}Bloc HTTPS déjà présent dans ds.conf.${NC}"
fi

# --- [3/4] Génération Docker Compose & Déploiement ---
echo -e "${BLUE}=== [3/4] Déploiement du conteneur via Docker Compose ===${NC}"

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

echo -e "${CYAN}--> Démarrage de la stack avec Docker Compose...${NC}"
docker compose -f "$COMPOSE_PATH" up -d --force-recreate

# --- [4/4] Bilan d'installation ---
echo -e "${BLUE}=== [4/4] Finalisation ===${NC}"

ADD_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "IP_SERVEUR")

echo -e "${GREEN}=========================================================================="
echo "                  Installation terminée avec succès !"
echo " Euro-Office DocumentServer est accessible sur :"
echo "  - HTTP  : http://${ADD_IP}:${PORT_HTTP} (ou http://${NOM_DNS_SERVEUR}:${PORT_HTTP})"
echo "  - HTTPS : https://${ADD_IP}:${PORT_HTTPS} (ou https://${NOM_DNS_SERVEUR}:${PORT_HTTPS})"
echo -e "==========================================================================${NC}"

echo "Affichage des logs du conteneur en temps réel (Ctrl+C pour quitter)..."
docker logs -f "$CONTAINER_NAME"
