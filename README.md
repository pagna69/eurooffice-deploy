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

L'installation s'effectue directement via une commande unique, compatible avec les systèmes Debian et Ubuntu.
Connectez-vous en SSH sur votre serveur et exécutez la commande suivante (en adaptant les valeurs à votre environnement) :
```bash
curl -sSL https://raw.githubusercontent.com/pagna69/eurooffice-deploy/refs/heads/main/install_Euro-Office_online.sh | sudo bash -s -- -d mon-serveur.domaine.local -p 8085 -s 8443
```
Détail des paramètres :
* d : Nom DNS, FQDN ou adresse IP du serveur (obligatoire).
* p : Port HTTP externe (obligatoire).
* s : Port HTTPS externe (obligatoire).
* r : Répertoire d'installation (optionnel, valeur par défaut : /var/www/euro-office).

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
👉 **https://[IP_DU_SERVEUR_EURO-OFFICE]:8443**

## 🛠️ Commandes utiles pour le support (sur le serveur)
* **Vérifier l'état du conteneur :**
```bash
sudo docker ps -f name=euro-office
```
* **Consulter manuellement les logs en cas de dysfonctionnement :**
```bash
sudo docker logs -f euro-office
```
* **Vérifier l'application de la configuration dans le conteneur :**
```bash
sudo docker exec -it euro-office cat /etc/euro-office/documentserver/default.json
```
* **Mise à jour :**
```bash
docker rm -f euro-office && curl -sSL https://raw.githubusercontent.com/pagna69/eurooffice-deploy/main/install_Euro-Office_online.sh | sudo bash -s -- -d mon-serveur.domaine.local -p 8085 -s 8443
```
* **Désinstallation :**
```bash
sudo docker stop euro-office
sudo docker rm euro-office
sudo docker rmi ghcr.io/euro-office/documentserver:v9.3.3
```
## 🔗 Liens utiles
* **Documentation :** https://euro-office.github.io/documentation/
* **Licence :** https://euro-office.github.io/documentation/introduction/licensing/
