# Déploiement automatisé — Euro-Office Document Server (Docker)

Ce dépôt contient le script d'installation automatisé pour déployer **Euro-Office Document Server** (`ghcr.io/euro-office/documentserver:v9.3.7`) sous Docker sur un serveur Linux.

Le script gère l'intégralité du déploiement : installation de Docker & Docker Compose v2 (si absents), préparation des répertoires, récupération de l'image, génération d'un certificat HTTPS auto-signé, adaptation de la configuration (`ds.conf` et `default.json`), génération du fichier `docker-compose.yml` et vérification du *healthcheck*.

---

## ⚠️ Important — Validation éditeur avant production

Les réglages appliqués par défaut par le script (notamment la désactivation de JWT et l'autorisation des adresses IP privées) facilitent l'intégration initiale avec une application cliente (ex. Multigest version 9.6), mais réduisent les protections de sécurité. **Ces paramètres doivent être validés avec l'éditeur ou l'intégrateur avant toute mise en production.**

---

## 1. Prérequis

### 1.1 Systèmes d'exploitation supportés

- **AlmaLinux 8, 9 ou 10** (installation 64 bits — `x86_64` / `x86_64_v2` / `x86_64_v3`, maintenue à jour)
- **Debian 12 (Bookworm) ou Debian 13 (Trixie)** (installation 64 bits — `x86_64`, maintenue à jour)
- **Ubuntu 22.04 LTS (Jammy) ou Ubuntu 24.04 LTS (Noble)** (installation 64 bits — `x86_64`, maintenue à jour)

> **Note :** Le script détecte automatiquement la distribution via `/etc/os-release` et installe Docker Engine ainsi que Docker Compose v2 via le dépôt officiel adapté (`apt-get` pour Debian/Ubuntu, `dnf` pour AlmaLinux/RHEL). Sur AlmaLinux/RHEL, il gère également automatiquement l'étiquetage SELinux des volumes (`:Z`), le module noyau `xt_addrtype` (`kernel-modules-extra`) et le pare-feu `firewalld` sans nécessiter de redémarrage préalable.

### 1.2 Dimensionnement matériel recommandé

| Ressource | Test / Faible charge | Production (base conseillée) |
| :--- | :--- | :--- |
| **Processeur** | 2 vCPU (`x86_64`) | 4 vCPU (`x86_64`) |
| **Mémoire RAM** | 8 Go | 16 Go |
| **Stockage SSD** | 50 Go | 100 Go (extensibles, hors sauvegardes) |

* **Mémoire partagée Docker :** Le script configure automatiquement `shm_size: "1g"` dans le `docker-compose.yml` pour `/dev/shm`.
* **Stockage :** Prévoir suffisamment d'espace sur `/var/lib/docker` (images/couches) et `/opt/euro-office` (volumes persistants et journaux).

### 1.3 Prérequis réseau & système
* Accès `root` ou privilèges `sudo`.
* Adresse IP fixe et résolution DNS fonctionnelle pointant vers le serveur.
* Paquets de base : `curl`, `openssl`, `python3` (utilisés par le script pour les contrôles, le certificat et la manipulation JSON).

#### Flux réseau à ouvrir

| Flux | Port | Protocole | Usage / Destination |
| :--- | :--- | :--- | :--- |
| **Administration** | `22` | TCP | SSH (à restreindre au réseau d'administration) |
| **Euro-Office HTTP** | `8085` | TCP | Port HTTP exposé par défaut (modifiable via `--http`) |
| **Euro-Office HTTPS** | `8443` | TCP | Port HTTPS exposé par défaut (modifiable via `--https`) |
| **Flux sortants** | `443` | TCP | Accès à `ghcr.io` (image Docker) et `download.docker.com` |

---

## 2. Installation rapide (Commande unique)

Connectez-vous en SSH sur votre serveur et exécutez la commande suivante en adaptant les paramètres à votre environnement :

```bash
curl -fsSL "https://raw.githubusercontent.com/pagna69/eurooffice-deploy/main/install-euro-office-linux.sh?t=$(date +%s)" | tr -d '\r' | sudo bash -s -- --dns localhost --http 8085 --https 8443
````
### Options disponibles

| Option | Valeur par défaut | Description |
| :--- | :--- | :--- |
| `--dir PATH` | `/opt/euro-office` | Répertoire racine d'installation et des volumes |
| `--dns NAME` | `localhost` | Nom DNS du serveur (utilisé pour le certificat SSL et `extra_hosts`) |
| `--http PORT` | `8085` | Port HTTP exposé sur l'hôte (redirigé vers le port `80` du conteneur) |
| `--https PORT` | `8443` | Port HTTPS exposé sur l'hôte (redirigé vers le port `443` du conteneur) |
| `--help` | — | Affiche l'aide du script sans lancer l'installation |

## 3. Configuration du pare-feu (UFW)
Si le pare-feu UFW est actif sur votre serveur Debian/Ubuntu, autorisez les ports configurés :

````Bash
sudo ufw allow OpenSSH
sudo ufw allow 8085/tcp
sudo ufw allow 8443/tcp
sudo ufw enable
sudo ufw status verbose
````
## 4. Vérifications post-installation
#### 4.1 Contrôle de l'état du conteneur
````Bash
cd /opt/euro-office
sudo docker compose ps
sudo docker inspect euro-office --format '{{.State.Status}} / {{.State.Health.Status}}'
````
#### 4.2 Tests d'accès HTTP / HTTPS
````Bash
# Test du healthcheck interne en HTTP
curl -i http://127.0.0.1:8085/healthcheck

# Test du healthcheck en HTTPS (option -k requise tant que le certificat est auto-signé)
curl -k -i https://127.0.0.1:8443/healthcheck

# Test via le nom DNS
curl -k -I https://euro-office.efalia.com:8443/
````
## 5. Architecture des fichiers et sécurisation
#### 5.1 Arborescence générée (/opt/euro-office)
Chemin	Rôle
| Chemin | Rôle |
| :--- | :--- |
| `/opt/euro-office/docker-compose.yml` | Définition de la stack Docker et des variables d'environnement |
| `/opt/euro-office/data/` | Données persistantes de Document Server |
| `/opt/euro-office/private/` | Données privées applicatives |
| `/opt/euro-office/logs/` | Journaux applicatifs et Nginx du conteneur |
| `/opt/euro-office/config/` | Fichiers de configuration (`default.json`, `nginx/ds.conf`, etc.) |
| `/opt/euro-office/config/nginx/certificats/` | Certificat (`euro-office.crt`) et clé privée (`euro-office.key`) |
#### 5.2 Paramètres appliqués par le script
| Paramètre | Valeur | Impact / Point d'attention |
| :--- | :--- | :--- |
| `JWT_ENABLED` / `jwtToken` | `false` | Désactive la validation des jetons JWT. À activer en production si l'application cliente le supporte. |
| `ALLOW_PRIVATE_IP_ADDRESS` | `true` | Autorise la communication avec des serveurs sur le réseau interne (RFC 1918). |
| `blockPrivateIP` | `false` | Désactive le blocage des IP privées dans `default.json`. |
| `rejectUnauthorized` | `false` | Désactive la vérification stricte des certificats TLS sortants. |
| `EXAMPLE_ENABLED` | `false` | Désactive l'interface d'exemple intégrée. |
| `WOPI_ENABLED` | `false` | Désactive le protocole WOPI. |

#### 5.3 Mise en place d'un certificat SSL valide (Production)

Le script génère un certificat auto-signé valable 10 ans. Pour le remplacer par un certificat signé par une autorité de certification (AC) :

1. Remplacez les fichiers dans `/opt/euro-office/config/nginx/certificats/` en conservant les noms exacts :
   * `euro-office.crt` (certificat + chaîne intermédiaire)
   * `euro-office.key` (clé privée)
2. Appliquez les permissions strictes sur la clé privée :
   ```bash
   sudo chown root:root /opt/euro-office/config/nginx/certificats/euro-office.key
   sudo chmod 600 /opt/euro-office/config/nginx/certificats/euro-office.key

3. Redémarrez le service :
````Bash
sudo docker compose -f /opt/euro-office/docker-compose.yml restart
````
## 6. Exploitation, sauvegarde et dépannage
#### 6.1 Sauvegarde complète
````Bash
cd /opt/euro-office
sudo tar czf /var/backups/euro-office-$(date +%F).tar.gz data private config docker-compose.yml
````
#### 6.2 Commandes de diagnostic
````Bash
# Consulter les logs en temps réel
sudo docker compose -f /opt/euro-office/docker-compose.yml logs -f

# Vérifier les conflits de ports sur l'hôte
ss -lntp | grep -E ':(8085|8443)\b'

# Vérifier le démon Docker
sudo journalctl -u docker -n 200 --no-pager
````
#### 6.3 Désinstallation
````Bash
cd /opt/euro-office
sudo docker compose down
# Vérifiez vos sauvegardes avant d'exécuter la suppression :
sudo rm -rf /opt/euro-office
````
