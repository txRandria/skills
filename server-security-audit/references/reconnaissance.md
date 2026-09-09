# Phase 2 — inventaire en lecture seule

Toutes les commandes de ce fichier sont en lecture seule. Aucune n'écrit, ne
modifie un service ni n'installe quoi que ce soit. C'est la propriété qui rend la
phase rejouable et sûre sur un serveur tiers.

## Principe de forme des commandes

Une commande d'inspection dont la sortie « rien trouvé » est identique à la sortie
« la commande a échoué » n'a rien vérifié. Émettre un compte ou un marqueur
explicite plutôt qu'un listage dont le rendu vide est le silence :

```bash
# Faible : vide = introuvable = pas de droit = ambigu
ls /etc/cron.d/

# Bon : le résultat porte son propre signal
printf 'cron.d: %s entrées\n' "$(ls -1 /etc/cron.d/ 2>/dev/null | wc -l)"
```

## Passe A — système et matériel

```bash
echo "=== IDENTITÉ ==="
hostnamectl 2>/dev/null || { uname -a; cat /etc/os-release; }
uptime
date -u; timedatectl 2>/dev/null | head -5

echo "=== MATÉRIEL ==="
nproc
free -h
df -hT -x tmpfs -x devtmpfs
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null

echo "=== NOYAU ET CORRECTIFS ==="
uname -r
# Redémarrage en attente après mise à jour du noyau (Debian/Ubuntu)
printf 'reboot-required: %s\n' "$(test -f /var/run/reboot-required && echo OUI || echo non)"
# Correctifs de sécurité en attente
(apt-get -s upgrade 2>/dev/null | grep -ci '^Inst.*security') || true
```

L'horloge (`date -u`) compte : toute corrélation entre journaux d'hôtes
différents est fausse si les horloges divergent. Le relever pour chaque hôte,
avant de comparer des journaux.

## Passe B — réseau

```bash
echo "=== INTERFACES ET ROUTES ==="
ip -br addr
ip route

echo "=== SOCKETS EN ÉCOUTE ==="
# -n : pas de résolution DNS (plus rapide, et ne génère pas de trafic sortant)
ss -tulpn

echo "=== ÉCOUTE SUR TOUTES LES INTERFACES ==="
# Le sous-ensemble qui compte : ce qui écoute sur 0.0.0.0 ou :: est candidat
# à l'exposition publique. À confronter à la mesure externe (phase 3).
ss -tulpn | grep -E '0\.0\.0\.0:|\*:|\[::\]:' || echo "aucun socket sur toutes interfaces"

echo "=== CONNEXIONS ÉTABLIES SORTANTES ==="
ss -tnp state established | head -40

echo "=== POLITIQUE DE FILTRAGE DÉCLARÉE ==="
# DÉCLARÉE, pas effective : ne jamais conclure ici (voir exposition-reseau.md)
(ufw status verbose 2>/dev/null || firewall-cmd --list-all 2>/dev/null || iptables -S 2>/dev/null | head -40)
```

`ss -tulpn` exige les privilèges pour afficher la colonne processus. Sans eux, les
sockets apparaissent sans propriétaire : le noter dans le rapport plutôt que de
laisser croire à un inventaire complet.

## Passe C — services et processus

```bash
echo "=== SERVICES ACTIFS ==="
systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}'

echo "=== SERVICES EN ÉCHEC ==="
systemctl --failed --no-pager --no-legend

echo "=== SERVICES ACTIVÉS AU DÉMARRAGE ==="
systemctl list-unit-files --state=enabled --no-pager --no-legend | awk '{print $1}'

echo "=== PROCESSUS PAR CONSOMMATION ==="
ps -eo pid,ppid,user,etime,pcpu,pmem,args --sort=-pcpu | head -25

echo "=== PROCESSUS SANS BINAIRE SUR DISQUE ==="
# Un processus dont l'exécutable a été supprimé après lancement est un
# indicateur classique : la charge s'exécute sans laisser de fichier.
for p in /proc/[0-9]*; do
  exe=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$exe" in *"(deleted)"*) echo "SUPPRIMÉ: ${p##*/} $exe";; esac
done | head -20
```

## Passe D — comptes et authentification

```bash
echo "=== COMPTES AVEC SHELL DE CONNEXION ==="
awk -F: '$7 !~ /(nologin|false|sync)$/ {print $1" uid="$3" shell="$7}' /etc/passwd

echo "=== COMPTES UID 0 (doit être root seul) ==="
awk -F: '$3==0 {print $1}' /etc/passwd

echo "=== COMPTES SANS MOT DE PASSE ==="
awk -F: '($2=="" ) {print "VIDE: "$1}' /etc/shadow 2>/dev/null || echo "shadow illisible (droits insuffisants)"

echo "=== SUDOERS ==="
printf 'sudo: %s\n' "$(getent group sudo wheel 2>/dev/null | cut -d: -f4 | paste -sd,)"
ls -l /etc/sudoers.d/ 2>/dev/null
grep -rhE '^[^#]*NOPASSWD' /etc/sudoers /etc/sudoers.d/ 2>/dev/null || echo "aucune règle NOPASSWD"

echo "=== CLÉS SSH AUTORISÉES ==="
# Chaque clé est un accès permanent : les énumérer nommément, avec leur commentaire.
for h in /root /home/*; do
  f="$h/.ssh/authorized_keys"
  [ -f "$f" ] && { echo "--- $f"; awk '{print $1" "substr($2,1,20)"... "$3}' "$f"; }
done

echo "=== CONNEXIONS RÉCENTES ==="
last -n 30 2>/dev/null | head -30
lastb -n 20 2>/dev/null | head -20 || echo "btmp illisible"
```

Une clé `authorized_keys` sans commentaire identifiable, ou dont le commentaire ne
correspond à aucune personne connue de l'équipe, est un constat à part entière —
c'est le mécanisme de persistance le plus discret et le plus courant.

## Passe E — configuration SSH effective

```bash
echo "=== CONFIGURATION SSHD RÉELLEMENT APPLIQUÉE ==="
# sshd -T affiche la configuration EFFECTIVE, après inclusion des fichiers
# de /etc/ssh/sshd_config.d/ et application des valeurs par défaut.
# Lire sshd_config seul donne une image fausse dès qu'un fichier d'inclusion existe.
#
# La capture en variable est délibérée. Dans `sshd -T | grep ... || repli`, le
# code de retour du pipeline est celui du DERNIER élément : le repli se déclenche
# quand grep ne trouve rien, que sshd ait échoué ou qu'il ait réussi sans ligne
# correspondante. Les deux cas — « contrôle impossible » et « contrôle fait, rien
# à signaler » — deviennent indiscernables, et c'est exactement l'ambiguïté qu'une
# étape de vérification ne doit pas produire. Pire avec un filtre qui sort
# toujours 0 (`head`, `tee`, `awk` sans exit) : le repli ne se déclenche jamais et
# l'échec est silencieux. La capture en variable teste sshd lui-même.
if SSHD_EFF=$(sshd -T 2>/dev/null); then
  printf '%s\n' "$SSHD_EFF" | grep -iE '^(permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|x11forwarding|allowtcpforwarding|maxauthtries|clientaliveinterval|port|allowusers|allowgroups)'
else
  echo "sshd -T indisponible (sshd absent ou droits insuffisants) — contrôle NON effectué"
fi
```

La même précaution vaut partout dans cette phase : une garde `commande | filtre ||
repli` ne protège rien. Soit capturer en variable comme ci-dessus, soit tester
d'abord la disponibilité (`command -v outil >/dev/null && …`).

C'est l'application directe du principe 1 : `sshd -T` interroge le service,
`cat sshd_config` interroge un fichier. Les deux divergent dès qu'un
`Include /etc/ssh/sshd_config.d/*.conf` est présent — ce qui est le défaut sur les
distributions récentes.

## Passe F — planification et persistance

```bash
echo "=== CRON SYSTÈME ==="
printf 'cron.d: %s | cron.daily: %s | cron.hourly: %s\n' \
  "$(ls -1 /etc/cron.d 2>/dev/null | wc -l)" \
  "$(ls -1 /etc/cron.daily 2>/dev/null | wc -l)" \
  "$(ls -1 /etc/cron.hourly 2>/dev/null | wc -l)"
grep -rhv '^\s*#' /etc/cron.d/* /etc/crontab 2>/dev/null | grep -v '^\s*$'

echo "=== CRON UTILISATEUR ==="
for u in $(cut -d: -f1 /etc/passwd); do
  c=$(crontab -l -u "$u" 2>/dev/null | grep -cv '^\s*#') || continue
  [ "${c:-0}" -gt 0 ] && echo "$u: $c entrées"
done

echo "=== MINUTEURS SYSTEMD ==="
systemctl list-timers --all --no-pager --no-legend

echo "=== SCRIPTS DE DÉMARRAGE ==="
ls -la /etc/rc.local /etc/profile.d/ /etc/init.d/ 2>/dev/null | head -30
```

## Passe G — paquets et intégrité

```bash
echo "=== BINAIRES SETUID ==="
# Comparer à la liste attendue de la distribution : un setuid hors liste
# standard est un constat de gravité élevée.
find / -xdev -perm -4000 -type f 2>/dev/null | sort

echo "=== FICHIERS MODIFIÉS RÉCEMMENT DANS LES CHEMINS SYSTÈME ==="
find /etc /usr/bin /usr/sbin /usr/local -xdev -mtime -30 -type f 2>/dev/null | head -40

echo "=== INTÉGRITÉ DES PAQUETS (Debian/Ubuntu) ==="
# Signale les fichiers de paquets dont l'empreinte diffère de celle du paquet.
(command -v debsums >/dev/null && debsums -cs 2>&1 | head -20) || echo "debsums non installé — contrôle non effectué"

echo "=== INTÉGRITÉ DES PAQUETS (RHEL/CentOS) ==="
(command -v rpm >/dev/null && rpm -Va --nomtime --nomode --nordev 2>/dev/null | head -20) || true
```

`debsums` n'est pas installé par défaut. **Ne pas l'installer** pendant l'audit :
c'est une écriture sur un serveur tiers. Noter le contrôle comme non effectué et
le proposer en phase 6.

## Exécution sur plusieurs hôtes

Regrouper les passes en un seul script transmis par l'entrée standard, plutôt que
d'ouvrir une session par commande : moins de connexions, une sortie horodatée
cohérente, et l'ensemble reste rejouable à l'identique.

```bash
ssh <user>@<hote> 'bash -s' < inventaire.sh > "inventaire-<hote>-$(date -u +%Y%m%dT%H%M%SZ).txt" 2>&1
```

Horodater le fichier en UTC : une preuve de collecte doit porter son propre
horodatage, sinon elle n'est pas corrélable avec les journaux de l'incident.

Pour un parc, exécuter en parallèle avec une bibliothèque SSH (paramiko, fabric,
ou `ssh` en tâches de fond bornées) plutôt qu'un client interactif : un client
interactif bloque sur une invite d'hôte inconnu et arrête le lot.

## Ce que cette phase ne peut pas conclure

L'inventaire décrit des emplacements canoniques. Il ne couvre ni la couche
inscriptible des conteneurs, ni les enregistrements applicatifs en base, ni les
charges qui n'existent que pendant leur exécution. La conclusion de phase 2 est
« inventaire établi », jamais « serveur sain » — voir `compromission.md`.
