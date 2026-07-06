# linux-hardening-tool

Un outil simple en Bash pour sécuriser rapidement un serveur Linux (Debian/Ubuntu) fraîchement installé.

Je recommande actuellement de l'utiliser uniquement pour un usage personnel type HomeLab ou autre.
⚠️ Ne fonctionne pas dans un conteneur 

## ⚠️ Avertissement

Ce projet est en développement actif. **Teste-le toujours sur une VM avant de l'utiliser sur une machine en production.** Un bug dans la configuration SSH peut te couper l'accès distant à ta machine si tu n'as pas d'accès console physique/hyperviseur de secours.


## Scripts inclus

- **`harden.sh`** — sécurise la machine
- **`unharden.sh`** — annule les modifications de `harden.sh`, avec deux modes au choix

## Ce que fait `harden.sh`

- Deux modes d'utilisation :
  - **Simple** : tout est généré automatiquement (recommandé si tu débutes)
  - **Avancé** : tu choisis le port SSH, le mot de passe root, le mot de passe GRUB, et les réglages fins — Entrée à chaque question garde la valeur par défaut recommandée
- Mot de passe root et port SSH (aléatoires ou personnalisés)
- Durcissement SSH : `MaxAuthTries`, `ClientAliveCountMax`, `MaxSessions`, désactivation de `X11Forwarding`/`AllowTcpForwarding`/`AllowAgentForwarding`/`Compression`
- Choix d'authentification :
  - **Clé SSH** : ajoute ta clé publique, teste la connexion avant de désactiver le mot de passe (aucun risque de blocage)
  - **Mot de passe** : garde le mot de passe actif
- **fail2ban** (paramètres personnalisables en mode avancé)
- **Politique de mots de passe** : expiration 90j, umask 027, rounds de hashage SHA512 (`login.defs` + `chage`)
- **Complexité des mots de passe** (`pam_pwquality`) : 12 caractères min, majuscule/minuscule/chiffre/symbole
- **auditd** : trace les accès aux fichiers sensibles (`passwd`, `shadow`, `sshd_config`, `sudoers`) et les exécutions de `passwd`/`sudo`
- **AIDE** : intégrité des fichiers système (checksum SHA256/SHA512)
- **rkhunter** : scanner de malware/rootkit
- Core dumps désactivés, stockage USB/Firewire désactivé, protocoles réseau rares bloqués (dccp/sctp/rds/tipc)
- Mises à jour de sécurité automatiques (`unattended-upgrades`)
- Process accounting (`acct`) + `sysstat`
- Bannière légale SSH (bilingue, conforme aux exigences des audits de sécurité type Lynis)
- Synchronisation NTP (`systemd-timesyncd`)
- **Mot de passe GRUB** : protège l'édition des entrées de boot et la console GRUB, **sans** bloquer le démarrage normal
- **PermitRootLogin=prohibit-password** : appliqué uniquement si l'authentification par clé a été confirmée fonctionnelle dans la même exécution (sinon laissé inchangé, pour éviter tout blocage)
- Vérifie la validité de la configuration SSH avant chaque redémarrage (`sshd -t`), restaure automatiquement en cas d'erreur
- Chaque durcissement complémentaire s'exécute de façon isolée : un échec n'interrompt jamais le reste du script
- Sauvegarde l'état d'origine de la machine (une seule fois, au tout premier lancement) pour permettre un rollback complet via `unharden.sh`
- Affiche les informations sensibles **une seule fois**, jamais stockées sur disque

## Ce que fait `unharden.sh`

⚠️ Je l'ai retirer car instable pour le moment 

Menu à deux modes :

- **[1] Reset complet par défaut** : port 22, mot de passe root `root` (volontairement faible), retire la clé SSH, désinstalle fail2ban.
  ⚠️ Usage labo/test **uniquement**.
- **[2] Restauration de l'état exact d'avant `harden.sh`** : redonne à `sshd_config` sa configuration d'origine (le port redevient celui d'avant), restaure/supprime `authorized_keys`, gère fail2ban en conséquence.
  - Si la référence d'origine est absente (ancienne version de `harden.sh`), le script propose de choisir parmi les sauvegardes `.bak.*` disponibles.
  - **Limite connue** : le mot de passe root d'origine ne peut jamais être restauré (jamais stocké). Un nouveau mot de passe aléatoire est généré à la place.

## Prérequis

- Debian ou Ubuntu (testé sur Debian 12)
- Accès root ou sudo
- OpenSSH installé (`openssh-server`)
- Accès internet (installation de fail2ban, pam_pwquality, auditd, AIDE, rkhunter, etc.)

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

**Important :** garde ta session SSH actuelle ouverte et teste la connexion sur le nouveau port dans un second terminal avant de la fermer.

```bash
ssh -p <nouveau_port> root@<ip_de_la_machine>
```

Si tu choisis l'authentification par clé, le mot de passe reste actif en fallback jusqu'à confirmation que la clé fonctionne. L'initialisation d'AIDE peut prendre plusieurs minutes.

### Annuler les modifications

```bash
sudo ./unharden.sh
```

### Consulter les logs d'audit (auditd)

```bash
sudo ausearch -k sshd_config_changes
sudo aureport --summary
```

### Vérifier l'intégrité des fichiers (AIDE)

```bash
sudo aide --check
```

### Scanner les malwares (rkhunter)

```bash
sudo rkhunter --check
```

## Contribuer

Les contributions sont bienvenues ! Ouvre une issue avant de proposer une PR importante pour qu'on puisse discuter de l'approche.

## Licence

MIT — voir [LICENSE](LICENSE)
