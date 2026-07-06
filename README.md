# linux-hardening-tool

Un outil simple en Bash pour sécuriser rapidement un serveur Linux (Debian/Ubuntu) fraîchement installé.
Je recommande personnellement de l'utiliser uniquement pour le moment dans un usage personelle type HomeLab ou autre.
## ⚠️ Avertissement

Ce projet est en développement actif. **Teste-le toujours sur une VM ou un conteneur jetable avant de l'utiliser.** Un bug dans la configuration SSH peut te couper l'accès distant à ta machine si tu n'as pas d'accès console physique/hyperviseur de secours.

## Scripts inclus

- **`harden.sh`** — sécurise la machine (mot de passe root, port SSH, durcissement, authentification, fail2ban)
- **`unharden.sh`** — annule les modifications de `harden.sh`, avec deux modes au choix

## Ce que fait `harden.sh`

- Propose deux modes d'utilisation :
  - **Simple** : tout est généré automatiquement (recommandé si tu débutes)
  - **Avancé** : tu choisis toi-même le port SSH, le mot de passe root, et les réglages fins (MaxAuthTries, fail2ban, etc.) — Entrée à chaque question garde la valeur par défaut recommandée
- Sauvegarde automatique de `/etc/ssh/sshd_config` avant toute modification
- Génère (ou définit, en mode avancé) un mot de passe root sécurisé
- Génère (ou définit, en mode avancé) un port SSH
- Durcit les paramètres SSH communs : `MaxAuthTries`, `ClientAliveCountMax`, `MaxSessions`, désactivation de `X11Forwarding`/`AllowTcpForwarding`/`AllowAgentForwarding`/`Compression`
- Propose un choix d'authentification :
  - **Clé SSH** : ajoute ta clé publique, teste la connexion avant de désactiver le mot de passe (aucun risque de blocage)
  - **Mot de passe** : garde le mot de passe actif
- **fail2ban** installé et configuré dans les deux cas (paramètres personnalisables en mode avancé)
- Vérifie la validité de la configuration SSH avant chaque redémarrage du service (`sshd -t`)
- Restaure automatiquement la sauvegarde en cas d'erreur
- Sauvegarde l'état d'origine de la machine (une seule fois, lors du tout premier lancement) pour permettre un rollback complet via `unharden.sh`
- Affiche les nouvelles informations **une seule fois** à l'écran, jamais stockées sur disque

## Ce que fait `unharden.sh`

Propose un menu à deux modes :

- **[1] Reset complet par défaut** : port 22, mot de passe root `root` (volontairement faible), retire la clé SSH ajoutée, désinstalle fail2ban.
  ⚠️ Usage labo/test **uniquement**, jamais sur une machine exposée.
- **[2] Restauration de l'état exact d'avant `harden.sh`** : redonne à `sshd_config` sa configuration d'origine (le port redevient celui d'avant, quel qu'il ait été), restaure ou supprime `authorized_keys` selon l'état d'origine, gère fail2ban en conséquence.
  - Si la référence d'origine n'est pas disponible (ex : machine ayant utilisé une version de `harden.sh` antérieure à cette fonctionnalité), le script propose automatiquement de choisir parmi les sauvegardes `.bak.*` disponibles.
  - **Limite connue** : le mot de passe root d'origine ne peut jamais être restauré (jamais stocké nulle part, par sécurité). Un nouveau mot de passe aléatoire est généré à la place, affiché une seule fois.

## Prérequis

- Debian ou Ubuntu (testé sur Debian 12)
- Accès root ou sudo
- OpenSSH installé (`openssh-server`)
- Accès internet pour l'installation de fail2ban

## Installation

```bash
git clone https://github.com/smqkeddd/linux-hardening-tool.git
cd linux-hardening-tool
chmod +x harden.sh unharden.sh
```

## Utilisation

### Sécuriser la machine

```bash
sudo ./harden.sh
```

Le script te demandera confirmation avant d'appliquer le moindre changement, puis te proposera de choisir entre le mode simple et le mode avancé.

**Important :** garde ta session SSH actuelle ouverte et teste la connexion sur le nouveau port dans un second terminal avant de fermer la session en cours.

```bash
ssh -p <nouveau_port> root@<ip_de_la_machine>
```

Si tu choisis l'authentification par clé SSH, le script garde le mot de passe actif en fallback jusqu'à ce que tu confirmes que ta clé fonctionne dans un second terminal — aucun risque de te retrouver bloqué dehors.

### Annuler les modifications

```bash
sudo ./unharden.sh
```

Choisis ensuite le mode de restauration souhaité (reset par défaut, ou retour à l'état d'avant `harden.sh`).

## Contribuer

Les contributions sont bienvenues ! Ouvre une issue avant de proposer une PR importante pour qu'on puisse discuter de l'approche.

## Licence

MIT — voir [LICENSE](LICENSE)
