# linux-hardening-tool

Un outil simple en Bash pour sécuriser rapidement un serveur Linux (Debian/Ubuntu) fraîchement installé.

## ⚠️ Avertissement

Ce projet est en développement actif (V1). **Teste-le toujours sur une VM ou un conteneur jetable avant de l'utiliser sur une machine en production.** Un bug dans la configuration SSH peut te couper l'accès distant à ta machine si tu n'as pas d'accès console physique/hyperviseur de secours.

## Ce que fait la V1.2

- Sauvegarde automatique de `/etc/ssh/sshd_config` avant toute modification
- Génère un nouveau mot de passe root aléatoire et sécurisé (via `openssl rand`)
- Génère un nouveau port SSH aléatoire (entre 1025 et 65535)
- Durcit les paramètres SSH communs : `MaxAuthTries`, `ClientAliveCountMax`, désactivation de `X11Forwarding`/`AllowTcpForwarding`/`AllowAgentForwarding`/`Compression`
- Propose un choix d'authentification :
  - **Clé SSH** : ajoute ta clé publique, teste la connexion avant de désactiver le mot de passe (aucun risque de blocage)
  - **Mot de passe** : garde le mot de passe actif
- **fail2ban est installé et configuré dans les deux cas** (3 tentatives max, ban d'1h) — utile même en authentification par clé pour limiter le bruit des scans automatisés
- Vérifie la validité de la configuration SSH avant chaque redémarrage du service (`sshd -t`)
- Restaure automatiquement la sauvegarde en cas d'erreur
- Affiche les nouvelles informations **une seule fois** à l'écran, jamais stockées sur disque

## Prérequis

- Debian ou Ubuntu (testé sur Debian 12)
- Accès root ou sudo
- OpenSSH installé (`openssh-server`)
- Accès internet pour l'installation de fail2ban (si tu choisis cette option)

## Installation

```bash
git clone https://github.com/<ton-user>/linux-hardening-tool.git
cd linux-hardening-tool
chmod +x harden.sh
```

## Utilisation

```bash
sudo ./harden.sh
```

Le script te demandera confirmation avant d'appliquer le moindre changement.

**Important :** garde ta session SSH actuelle ouverte et teste la connexion sur le nouveau port dans un second terminal avant de fermer la session en cours.

```bash
ssh -p <nouveau_port> root@<ip_de_la_machine>
```

Si tu choisis l'authentification par clé SSH, le script garde le mot de passe actif en fallback jusqu'à ce que tu confirmes que ta clé fonctionne dans un second terminal — aucun risque de te retrouver bloqué dehors.

## Contribuer

Les contributions sont bienvenues ! Ouvre une issue avant de proposer une PR importante pour qu'on puisse discuter de l'approche.

## Licence

MIT — voir [LICENSE](LICENSE)
