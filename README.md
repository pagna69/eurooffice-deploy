# Déploiement Automatisé d'Euro-Office DocumentServer

Ce dépôt contient la solution de déploiement automatisé et clé en main pour installer Euro-Office DocumentServer sur un environnement Debian 12 (Bookworm) ou Debian 13 (Trixie). Le script d'installation intègre un moteur de détection intelligent qui configure l'intégralité des prérequis (dont Docker) et récupère de manière autonome ses fichiers de configuration.

## 📋 Prérequis matériels et système

Avant de lancer le déploiement, assurez-vous que la machine cible respecte les conditions suivantes :

* **Système d'exploitation :** Debian 12 (Bookworm) ou Debian 13 (Trixie) – installation vierge ou existante.
* **Architecture & Privilèges :** Système 64-bit avec accès administrateur (`sudo` ou `root`) indispensable pour la configuration système et l'installation de Docker.
* **Ressources matérielles minimales :**
  * **Processeur :** CPU Dual-core (2 GHz ou plus).
  * **Mémoire vive :** 4 Go de RAM minimum (6 Go recommandés pour la production).
  * **Espace disque :** 40 Go d'espace libre (pour l'image Docker, le stockage des documents et les logs).
* **Réseau & Connectivité :**
  * Une interface réseau active nommée **`ens160`** (requise pour l'extraction et l'affichage dynamique de l'IP finale). *Note : Si votre interface porte un autre nom, modifiez la variable `INTERFACE` à la fin du script.*
  * Un **accès Internet sortant** actif (ports `80` et `443`) pour permettre le téléchargement de l'image officielle sur le registre GitHub (`ghcr.io`) et la récupération automatique du fichier de configuration de secours.

## 🚀 Procédure d'installation "En un clic"

Grâce aux sécurités intégrées dans le script, vous n'avez plus besoin de télécharger manuellement le fichier de configuration JSON en amont. Connectez-vous simplement en SSH sur votre serveur Debian et exécutez la commande unique suivante :
```bash
curl -sS https://raw.githubusercontent.com/pagna69/eurooffice-deploy/refs/heads/main/default_Euro-Office.json | sudo tee ./default_Euro-Office.json > /dev/null && curl -sS https://raw.githubusercontent.com/pagna69/eurooffice-deploy/refs/heads/main/install_eurooffice.sh | sudo bash
```

## 🧠 Intelligence et étapes du script

Lors de son exécution, le script réalise les actions suivantes de manière totalement autonome :

* **Contrôle d'accès :** Vérification de la présence des droits root.
* **Analyse de l'environnement (Docker) :**
  * **Si Docker est absent :** Ajout des clés GPG officielles, configuration des dépôts stables pour Debian 13, installation de Docker Engine / Compose, et configuration de l'utilisateur courant dans le groupe Docker.
  * **Si Docker est présent :** Passage immédiat à l'étape suivante.
* **Préparation du conteneur :**
  * Récupération (pull) de la dernière image officielle ghcr.io/euro-office/documentserver:latest.
  * Suppression et nettoyage d'une éventuelle ancienne instance d'Euro-Office portant le même nom pour éviter les conflits de port.
  * Initialisation du nouveau conteneur sur le port externe 8085.
* **Gestion de la configuration (default.json) :**
  * Le script vérifie la présence locale du fichier default_Euro-Office.json.
  * S'il est absent, il le télécharge automatiquement depuis votre dépôt GitHub.
  * Injection sécurisée du fichier dans le conteneur puis redémarrage de l'instance pour appliquer les modifications.
* **Livraison :** Calcul dynamique de l'adresse IP et affichage du tableau de bord d'accès, suivi du flux de logs en temps réel.

## 🔍 Validation et Diagnostic post-installation

Une fois l'installation terminée, le DocumentServer est immédiatement disponible à l'adresse :
👉 **http://[IP_DU_SERVEUR_EURO-OFFICE]:8085**

## Commandes utiles pour le support (sur le serveur)
* **Vérifier l'état du conteneur :**
```bash
sudo docker ps -f name=euro-office-server
```
* **Consulter manuellement les logs en cas de dysfonctionnement :**
```bash
sudo docker logs -f euro-office-server
```
* **Vérifier l'application de la configuration dans le conteneur :**
```bash
sudo docker exec -it euro-office-server cat /etc/euro-office/documentserver/default.json
```
## 🔗 Liens utiles
* **Mise à jour :** https://euro-office.github.io/documentation/installation/docker/#updating
* **Documentation :** https://euro-office.github.io/documentation/
* **Licence :** https://euro-office.github.io/documentation/introduction/licensing/
