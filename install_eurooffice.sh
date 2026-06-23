#!/bin/bash

# ==============================================================================
# Script d'installation automatisé d'Euro-Office (Déploiement distant via GitHub)
# Destiné à : Debian 13 (Trixie) avec affichage IP ens160 ciblé
# Exécution requise : sudo ./install_eurooffice.sh
# ==============================================================================

# Arrêt immédiat du script en cas d'erreur
set -e

CONTAINER_NAME="euro-office-server"
CONFIG_FILE="default_Euro-Office.json"

echo "=== [*] Déploiement du conteneur Euro-Office ==="
docker pull ghcr.io/euro-office/documentserver:latest

# Nettoyage d'une éventuelle instance précédente
if [ "$(docker ps -aq -f name=^/${CONTAINER_NAME}$)" ]; then
    echo "Suppression de l'ancien conteneur..."
    docker rm -f "$CONTAINER_NAME" 2>/dev/null
fi

# Lancement du conteneur
docker run -d -p 8085:80 --name "$CONTAINER_NAME" --restart=always \
  -e EXAMPLE_ENABLED=true \
  -e JWT_ENABLED=false \
  ghcr.io/euro-office/documentserver:latest

echo "Attente de l'initialisation du conteneur (10 secondes)..."
sleep 10

echo "=== [**] Injection de la configuration default.json dans le conteneur ==="
# Vérification de la présence du fichier JSON téléchargé en amont
if [ -f "./$CONFIG_FILE" ]; then
    docker cp "./$CONFIG_FILE" "${CONTAINER_NAME}":/etc/euro-office/documentserver/default.json
else
    echo "Erreur : Le fichier $CONFIG_FILE est introuvable dans le répertoire courant."
    exit 1
fi

echo "=== [***] Redémarrage du conteneur Euro-Office ==="
docker restart "$CONTAINER_NAME"

# Récupération dynamique de l'adresse IP de l'interface ens160
INTERFACE="ens160"
ADD_IP=$(ip -4 addr show dev "$INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "[ADD_IP]")

# Affichage du message final de validation
echo "=========================================================================="
echo "                 Installation terminée avec succès !"
echo " Euro-Office DocumentServer est accessible sur l'adresse http://${ADD_IP}:8085"
echo "=========================================================================="

# Affichage des logs du conteneur
echo "Affichage des logs du conteneur en temps réel (Ctrl+C pour quitter)..."
docker logs -f "$CONTAINER_NAME"
