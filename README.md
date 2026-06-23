# eurooffice-deploy
# Déploiement Automatisé d'Euro-Office DocumentServer

Ce dépôt contient les scripts et configurations nécessaires au déploiement automatisé d'Euro-Office DocumentServer sur un environnement Debian 13 (Trixie).

## Prérequis

* Un serveur installé sous **Debian 13**.
* **Docker** installé et fonctionnel sur la machine.
* Une interface réseau active nommée `ens160` (pour la récupération dynamique de l'adresse IP).

## Procédure d'installation "En un clic"

Pour lancer l'installation complète (téléchargement de la configuration, initialisation du conteneur Docker et injection des paramètres), connectez-vous en SSH sur votre serveur cible et exécutez la commande unique suivante :

## Actions réalisées par le script
1 - Téléchargement sécurisé du fichier de configuration global default_Euro-Office.json.
2 - Récupération et exécution du script de déploiement install_eurooffice.sh.
3 - Téléchargement de l'image officielle Euro-Office depuis le registre GitHub (ghcr.io).
4 - Nettoyage automatique si une ancienne instance du conteneur existe déjà.
5 - Configuration et démarrage du conteneur sur le port 8085.
6 - Injection de la configuration personnalisée dans le système de fichiers du conteneur.
7 - Affichage dynamique de l'URL d'accès et ouverture des logs en temps réel.

```bash
curl -sS [https://raw.githubusercontent.com/pagna69/eurooffice-deploy/refs/heads/main/default_Euro-Office.json](https://raw.githubusercontent.com/pagna69/eurooffice-deploy/refs/heads/main/default_Euro-Office.json) | sudo tee ./default_Euro-Office.json > /dev/null && curl -sS [https://raw.githubusercontent.com/pagna69/eurooffice-deploy/refs/heads/main/install_eurooffice.sh](https://raw.githubusercontent.com/pagna69/eurooffice-deploy/refs/heads/main/install_eurooffice.sh) | sudo bash

