# docker-compose durci

## Gabarit complet

Application applicative derrière un reverse proxy, base de données non exposée,
secrets par fichier.

```yaml
# La clé `version:` est obsolète depuis Compose v2 : ne pas l'écrire.

x-durcissement: &durcissement
  restart: unless-stopped
  read_only: true
  security_opt:
    - no-new-privileges:true
  cap_drop:
    - ALL
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"

services:
  reverse-proxy:
    <<: *durcissement
    image: caddy:2-alpine@sha256:<digest>
    # Seul service publiant des ports vers l'extérieur.
    ports:
      - "80:80"
      - "443:443"
    cap_add:
      - NET_BIND_SERVICE       # nécessaire pour écouter sur 80/443, et rien d'autre
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - frontal
    depends_on:
      app:
        condition: service_healthy

  app:
    <<: *durcissement
    build:
      context: .
      args:
        # Jamais de secret ici : les ARG restent dans l'historique de l'image.
        BUILD_REF: ${GIT_SHA:-dev}
    image: registry.exemple.tld/mon-app:${TAG:-dev}
    # AUCUN `ports:` — le service n'est joignable que par le réseau interne.
    expose:
      - "3000"
    user: "10001:10001"
    environment:
      NODE_ENV: production
      PORT: "3000"
      # Le secret est lu depuis un fichier, pas depuis une variable :
      # une variable d'environnement est visible dans `docker inspect`,
      # dans /proc/<pid>/environ, et dans les traces d'erreur.
      JWT_SECRET_FILE: /run/secrets/jwt_secret
      DB_PASSWORD_FILE: /run/secrets/db_password
      CORS_ORIGIN: ${CORS_ORIGIN:?CORS_ORIGIN doit être défini}
    secrets:
      - jwt_secret
      - db_password
    volumes:
      - app-data:/app/data
      - app-uploads:/app/storage/uploads
    tmpfs:
      # read_only: true impose de déclarer les chemins réellement inscriptibles.
      - /tmp:size=64m,mode=1777,noexec,nosuid,nodev
    networks:
      - frontal
      - interne
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 15s
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
        reservations:
          memory: 128M

  db:
    <<: *durcissement
    image: postgres:16-alpine@sha256:<digest>
    read_only: false            # PostgreSQL écrit hors volume (sockets, fichiers temporaires)
    user: "70:70"               # postgres dans les images Alpine
    environment:
      POSTGRES_DB: hrportal
      POSTGRES_USER: hrportal
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
      # Refuse l'authentification en confiance, qui est le défaut historique.
      POSTGRES_INITDB_ARGS: "--auth-host=scram-sha-256"
    secrets:
      - db_password
    volumes:
      - db-data:/var/lib/postgresql/data
    networks:
      - interne                 # jamais sur le réseau frontal, jamais de ports publiés
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U hrportal -d hrportal"]
      interval: 10s
      timeout: 5s
      retries: 5

secrets:
  jwt_secret:
    file: ./secrets/jwt_secret.txt      # hors dépôt, droits 600
  db_password:
    file: ./secrets/db_password.txt

networks:
  frontal:
    driver: bridge
  interne:
    driver: bridge
    internal: true              # aucun accès sortant vers Internet depuis ce réseau

volumes:
  app-data:
  app-uploads:
  db-data:
  caddy-data:
  caddy-config:
```

## Les décisions qui comptent

### `internal: true` sur le réseau des données

Un réseau `internal` n'a pas de route sortante. Une base de données ou un service
interne compromis ne peut donc pas exfiltrer vers l'extérieur ni tirer une charge
utile. C'est l'une des mesures les moins coûteuses et les plus efficaces d'un
fichier compose.

### Ne publier que ce qui doit l'être

`ports: ["3000:3000"]` publie sur **0.0.0.0**. Sur beaucoup de configurations,
Docker écrit ses règles de redirection avant celles du pare-feu de l'hôte : le
port est joignable depuis le réseau même si `ufw` ou `firewalld` prétendent le
bloquer. Trois formes possibles, par ordre de préférence :

```yaml
expose: ["3000"]              # joignable seulement par les autres conteneurs
ports: ["127.0.0.1:3000:3000"]  # joignable seulement depuis l'hôte
ports: ["3000:3000"]          # joignable depuis le réseau — à justifier
```

Contrôle réel, depuis une autre machine, jamais depuis l'hôte lui-même :

```bash
nmap -Pn -p 3000,5432,6379 <ip-de-l-hote>
```

Un pare-feu déclaré n'est pas un pare-feu vérifié.

### Secrets par fichier, pas par variable

Une variable d'environnement fuit par `docker inspect`, par `/proc/<pid>/environ`
(lisible par tout processus du même utilisateur), par les rapports d'erreur des
frameworks en mode debug et par les sous-processus. Un secret monté en fichier
(`/run/secrets/...`, en tmpfs) n'a aucun de ces chemins de fuite.

Côté application, lire le fichier avec repli sur la variable pendant la migration :

```js
const fs = require('fs');
function secret(nom) {
  const chemin = process.env[`${nom}_FILE`];
  if (chemin) return fs.readFileSync(chemin, 'utf8').trim();
  const val = process.env[nom];
  if (!val) throw new Error(`${nom} absent — démarrage refusé`);
  return val;
}
const JWT_SECRET = secret('JWT_SECRET');
```

### `${VAR:?message}` pour les valeurs obligatoires

```yaml
CORS_ORIGIN: ${CORS_ORIGIN:?CORS_ORIGIN doit être défini}
```

Compose refuse de démarrer si la variable est absente. Sans cette syntaxe, la
valeur devient une chaîne vide et le service démarre dans une configuration
dégradée — un CORS vide, un secret vide — sans aucun signal.

### `depends_on` avec `condition: service_healthy`

`depends_on` seul n'attend que le démarrage du conteneur, pas la disponibilité du
service. La forme longue avec `service_healthy` attend le `healthcheck`, ce qui
évite les échecs de migration au premier démarrage.

### `read_only: true` et ses exceptions

Le passage en lecture seule révèle les chemins que l'application écrit réellement.
Procéder ainsi : activer `read_only`, démarrer, lire les erreurs `EROFS`, ajouter
un `tmpfs` (données jetables) ou un volume nommé (données à conserver) pour chaque
chemin, jamais désactiver `read_only` pour faire passer le démarrage.

Options `tmpfs` recommandées : `noexec,nosuid,nodev` — un `/tmp` inscriptible et
exécutable est l'endroit où atterrit une charge utile.

## Interdits absolus

```yaml
privileged: true                      # équivaut à root sur l'hôte
volumes:
  - /var/run/docker.sock:/var/run/docker.sock   # permet de créer un conteneur privilégié
  - /:/host                            # montage de la racine hôte
network_mode: host                     # supprime l'isolation réseau
pid: host                              # accès aux processus de l'hôte
cap_add: [SYS_ADMIN]                   # évasion de conteneur documentée
security_opt: [seccomp:unconfined, apparmor:unconfined]
```

Si un outil réclame le socket Docker (agent de CI, conteneur de supervision),
passer par un proxy de socket à liste blanche d'API plutôt que par un montage
direct, et le placer sur un réseau interne.

## Fichier de surcharge pour le développement

Garder le fichier principal durci et mettre les assouplissements dans un fichier
séparé, jamais utilisé en production :

```yaml
# docker-compose.override.yml — chargé automatiquement en local
services:
  app:
    read_only: false
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - ./server:/app/server:ro
    environment:
      NODE_ENV: development
```

En production, lancer explicitement sans la surcharge :

```bash
docker compose -f docker-compose.yml up -d
```

## Contrôle avant livraison

```bash
# La configuration effectivement résolue (variables substituées, surcharges appliquées)
docker compose config

# Aucun secret n'a fuité dans la configuration résolue
docker compose config | grep -iE 'password|secret|token' | grep -v '_FILE\|/run/secrets'

# Ce qui est réellement publié sur l'hôte
docker compose ps --format 'table {{.Name}}\t{{.Ports}}'

# L'utilisateur réel du processus
docker compose exec app id
```

`docker compose config` est la seule source de vérité : c'est ce qui sera appliqué
après substitution des variables et fusion des fichiers de surcharge. Auditer ce
rendu, pas le fichier source.
