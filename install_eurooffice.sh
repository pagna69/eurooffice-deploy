#!/bin/bash

# ==============================================================================
# Script d'installation automatisé d'Euro-Office & Docker (Unifié avec Couleurs)
# Destiné à : Debian 12 (Bookworm) / Debian 13 (Trixie)
# Exécution requise : Exécuté directement via curl ou avec sudo ./install_eurooffice.sh
# ==============================================================================

# Arrêt immédiat du script en cas d'erreur
set -e

CONTAINER_NAME="euro-office-server"
CONFIG_FILE="default_Euro-Office.json"
GITHUB_CONFIG_URL="https://raw.githubusercontent.com/pagna69/eurooffice-deploy/refs/heads/main/default_Euro-Office.json"

# Définition des codes couleurs ANSI pour un affichage professionnel
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # Pas de couleur (Reset)

# Gestion propre de l'interruption Ctrl+C pour restaurer les couleurs du terminal
trap 'echo -e "${NC}"; exit 0' INT TERM

echo -e "${BLUE}=== [1/4] Contrôle des privilèges d'administration ===${NC}"
# Vérification des droits root indispensables pour l'installation système et Docker
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Erreur : Ce script doit être exécuté avec des privilèges d'administrateur (sudo).${NC}"
  exit 1
fi

echo -e "${BLUE}=== [2/4] Vérification de la présence de Docker ===${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}[- ] Docker n'est pas détecté sur cette machine.${NC}"
    echo -e "${CYAN}--> Lancement de la procédure d'installation de Docker...${NC}"
    
    # Mise à jour des index de paquets et installation des dépendances minimales
    echo "   * Mise à jour des index des paquets et installation des dépendances..."
    apt update
    apt install -y ca-certificates curl gnupg

    # Configuration de la clé GPG officielle de Docker (Utilisation du format standard .asc)
    echo "   * Ajout de la clé GPG officielle de Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Ajout du dépôt Docker officiel au format DEB822 (Recommandé pour Debian 12/13)
    echo "   * Configuration du dépôt officiel Docker..."
    tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # Installation de Docker Engine et de ses composants indispensables
    echo "   * Installation de Docker Engine et de ses composants..."
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Configuration du groupe Docker pour l'utilisateur non-root d'origine (si applicable)
    if [ -n "$SUDO_USER" ]; then
        echo "   * Ajout de l'utilisateur '$SUDO_USER' au groupe docker..."
        usermod -aG docker "$SUDO_USER"
    fi
    
    echo -e "${GREEN}[✓] Docker a été installé et configuré avec succès !${NC}"
else
    echo -e "${GREEN}[✓] Docker est déjà installé sur cette machine. Étape ignorée.${NC}"
fi

echo -e "${BLUE}=== [3/4] Déploiement du conteneur Euro-Office ===${NC}"
echo -e "${CYAN}--> Récupération de l'image officielle...${NC}"
docker pull ghcr.io/euro-office/documentserver:latest

# Nettoyage d'une éventuelle instance précédente du conteneur
if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
    echo -e "${YELLOW}--> Suppression de l'ancien conteneur détecté...${NC}"
    docker rm -f "$CONTAINER_NAME" 2>/dev/null
fi

# Lancement du nouveau conteneur Euro-Office
echo -e "${CYAN}--> Lancement du conteneur...${NC}"
docker run -d -p 8085:80 --name "$CONTAINER_NAME" --restart=always \
  -e EXAMPLE_ENABLED=true \
  -e JWT_ENABLED=false \
  ghcr.io/euro-office/documentserver:latest

echo -e "${CYAN}--> Attente de l'initialisation du conteneur (10 secondes)...${NC}"
sleep 10

echo -e "${BLUE}=== [4/4] Injection de la configuration default.json ===${NC}"

# Téléchargement automatique du JSON s'il n'est pas présent dans le répertoire courant
if [ ! -f "./$CONFIG_FILE" ]; then
    echo -e "${YELLOW}[- ] Fichier $CONFIG_FILE introuvable localement.${NC}"
    echo -e "${CYAN}--> Téléchargement automatique depuis GitHub...${NC}"
    if curl -sS -o "./$CONFIG_FILE" "$GITHUB_CONFIG_URL"; then
        echo -e "${GREEN}[✓] Fichier de configuration récupéré avec succès depuis GitHub.${NC}"
    else
        echo -e "${RED}Erreur : Impossible de télécharger le fichier de configuration depuis GitHub.${NC}"
        exit 1
    fi
fi

# Injection sécurisée de la configuration personnalisée
if [ -f "./$CONFIG_FILE" ]; then
    echo -e "${CYAN}--> Vérification et création des répertoires cibles dans le conteneur...${NC}"
    # Force la création de l'arborescence complète dans le conteneur pour éviter l'erreur de daemon
    docker exec "$CONTAINER_NAME" mkdir -p /etc/euro-office/documentserver/
    
    # Copie du fichier local vers le chemin absolu du conteneur
    docker cp "./$CONFIG_FILE" "${CONTAINER_NAME}":/etc/euro-office/documentserver/default.json
    echo -e "${GREEN}[✓] Fichier de configuration injecté avec succès.${NC}"
else
    echo -e "${RED}Erreur critique : Le fichier de configuration local $CONFIG_FILE reste introuvable.${NC}"
    exit 1
fi

echo -e "${CYAN}--> Redémarrage du conteneur Euro-Office pour appliquer les modifications...${NC}"
docker restart "$CONTAINER_NAME"

# Récupération dynamique de l'adresse IP de l'interface ens160
INTERFACE="ens160"
ADD_IP=$(ip -4 addr show dev "$INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "[ADD_IP]")

# Affichage du message final de validation en vert
echo -e "${GREEN}=========================================================================="
echo "                 Installation terminée avec succès !"
echo " Euro-Office DocumentServer est accessible sur l'adresse : http://${ADD_IP}:8085"
echo -e "==========================================================================${NC}"

# Affichage des logs en temps réel
echo "Affichage des logs du conteneur en temps réel (Ctrl+C pour quitter)..."
docker logs -f "$CONTAINER_NAME"
