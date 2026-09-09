# Phase 3 — configuration réellement appliquée

## Le constat qui motive ce fichier

Sur un serveur applicatif conteneurisé, le fichier de configuration présent sur
l'hôte annonçait un mot de passe maître laissé à sa valeur d'usine et un chemin de
modules erroné. Ce fichier n'était monté dans aucun conteneur. La configuration
effective, lue depuis l'intérieur du conteneur, contenait un mot de passe haché et
un chemin correct.

Conclure depuis le fichier de l'hôte aurait produit un constat « critique »
factuellement faux — et un rapport dont la première recommandation est fausse perd
la confiance sur toutes les suivantes.

**Règle : un audit décrit l'état exécuté, pas l'état versionné.**

## Procédure, pour chaque fichier de configuration lu

### 1. Est-il monté quelque part ?

```bash
# Volumes déclarés par conteneur
docker inspect --format '{{.Name}} {{range .Mounts}}{{.Source}}:{{.Destination}}:{{.Mode}} {{end}}' $(docker ps -q)

# Où le fichier suspect est-il monté, s'il l'est ?
docker inspect $(docker ps -q) --format '{{.Name}}{{range .Mounts}} {{.Source}}{{end}}' | grep '<chemin-hote>'
```

Absent des montages : le fichier n'a aucun effet. Il peut être un vestige, une
copie de travail, ou un leurre. Le noter comme tel, pas comme une vulnérabilité.

### 2. Relire depuis le contexte qui consomme

```bash
# Le fichier tel que le processus le voit
docker exec <conteneur> cat /etc/<app>/<app>.conf

# La configuration réellement chargée, quand l'application sait la restituer
docker exec <conteneur> <app> --print-config 2>/dev/null
docker exec <conteneur> env | sort            # variables effectives du processus
```

Sur un service non conteneurisé, la même règle s'applique : interroger le service,
pas le fichier.

| Composant | Fichier (à ne pas conclure) | Configuration effective |
|---|---|---|
| OpenSSH | `/etc/ssh/sshd_config` | `sshd -T` |
| nginx | `/etc/nginx/nginx.conf` | `nginx -T` |
| Apache | `/etc/apache2/apache2.conf` | `apachectl -S` et `apachectl -t -D DUMP_MODULES` |
| PostgreSQL | `postgresql.conf` | `SHOW ALL;` ou `pg_settings` |
| PHP | `php.ini` | `php -i` du bon SAPI (CLI ≠ FPM) |
| systemd | fichier d'unité | `systemctl show <unité>` |
| Pare-feu | fichier de règles | `iptables -S` / `nft list ruleset` |

Le cas PHP est représentatif : le `php.ini` de la ligne de commande et celui du
processus FPM sont deux fichiers différents. Auditer le mauvais donne un rapport
juste sur un composant que personne n'utilise.

### 3. Confronter aux valeurs par défaut du produit

Un mot de passe d'administration resté à sa valeur d'usine ne se détecte pas en
lisant la configuration — il se détecte en **essayant de s'authentifier avec**.

```bash
# Test d'authentification avec l'identifiant d'usine documenté du produit
curl -s -o /dev/null -w '%{http_code}\n' -u admin:admin https://<cible>/<chemin-admin>
```

C'est une action visible et journalisée côté cible : la couvrir en phase 0. Un
code de retour indiquant une authentification réussie est un constat critique
immédiat.

## Couche inscriptible d'un conteneur

L'image est immuable ; ce qui a été écrit après le démarrage ne l'est pas. C'est
un emplacement que l'inventaire système ne couvre pas.

```bash
# Fichiers ajoutés ou modifiés depuis la création du conteneur
docker diff <conteneur> | head -60
# A = ajouté, C = modifié, D = supprimé
docker diff <conteneur> | grep '^A' | head -40
```

Une charge malveillante s'y installe volontiers sous un nom mimant un fichier
système. `docker diff` est le seul moyen simple de la distinguer du contenu de
l'image.

```bash
# Processus réellement en cours dans le conteneur, y compris hors point d'entrée
docker top <conteneur>
docker exec <conteneur> ps aux 2>/dev/null
```

## Secrets matérialisés

Une variable d'environnement fuit par plusieurs chemins ; les énumérer est un
constat en soi.

```bash
# Variables du processus, y compris les secrets injectés
docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' <conteneur>
# Sur l'hôte, pour un processus classique (lisible par le même utilisateur)
tr '\0' '\n' < /proc/<pid>/environ
```

Un secret présent ici est lisible par `docker inspect` (donc par tout membre du
groupe docker, équivalent root), par les rapports d'erreur d'un framework en mode
debug, et par les sous-processus. Le constat n'est pas « le secret est faible »
mais « le secret est exposé par construction ».

Chercher aussi les secrets sur disque :

```bash
grep -rIl --exclude-dir=node_modules --exclude-dir=.git \
  -E '(password|secret|token|api[_-]?key)\s*[:=]' /opt /srv /home /var/www 2>/dev/null | head -20
ls -la /root/.ssh /home/*/.ssh /root/.aws /home/*/.aws 2>/dev/null
```

Attention au retour de flamme : une commande de recherche de secret peut afficher
le secret dans la sortie, qui finit dans le rapport et dans l'historique. Utiliser
`grep -l` (noms de fichiers seulement) pendant la collecte, et ne lire le contenu
que pour qualifier, sans le recopier dans le livrable.

## Mode debug et pages d'erreur

```bash
# Réponse d'erreur : une trace de pile ou une version divulguée est un constat
curl -sk -o /dev/null -w 'code=%{http_code}\n' https://<cible>/chemin-inexistant
curl -sk https://<cible>/chemin-inexistant | head -20
curl -skI https://<cible>/ | grep -iE '^(server|x-powered-by|x-aspnet)'
```

Les endpoints d'administration exposés relèvent de la même famille et se testent,
pas se déduisent : consoles applicatives, `/actuator/env`, `/debug`, `/docs`,
`/phpmyadmin`, `/.git/config`, `/.env`.

```bash
for p in /.env /.git/config /actuator/env /debug /server-status /phpinfo.php; do
  printf '%-20s %s\n' "$p" "$(curl -sk -o /dev/null -w '%{http_code}' "https://<cible>$p")"
done
```

Un code 200 sur `/.env` ou `/.git/config` est une divulgation complète des
secrets et du code : constat critique, remédiation immédiate.

## Sauvegardes

```bash
ls -la /var/backups /opt/backups /srv/backups 2>/dev/null
find / -xdev -name '*.sql' -o -name '*.dump' -o -name '*.tar.gz' 2>/dev/null \
  | grep -iE 'backup|dump' | head -20
```

Trois questions par sauvegarde trouvée : est-elle chiffrée, est-elle lisible par
un compte non privilégié, et est-elle accessible depuis le réseau ? Une sauvegarde
en clair et lisible par tous annule toutes les protections de la base qu'elle
contient.
