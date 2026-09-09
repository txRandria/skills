# Gabarits de Dockerfile durcis

## Obtenir le digest à épingler

Ne jamais inventer un digest. Le résoudre, puis le coller :

```bash
# Sur une image déjà tirée localement
docker pull node:22-bookworm-slim
docker inspect --format='{{index .RepoDigests 0}}' node:22-bookworm-slim

# Sans tirer l'image (nécessite buildx)
docker buildx imagetools inspect node:22-bookworm-slim --format '{{.Manifest.Digest}}'
```

Le résultat s'écrit `FROM node:22-bookworm-slim@sha256:<digest>`. Garder le tag à
côté du digest : il documente ce que le digest représente. La mise à jour du digest
devient un commit explicite — c'est le but.

---

## Node.js — dépendances natives (better-sqlite3, sharp, bcrypt…)

Cas fréquent : la compilation exige `python3`, `make`, `g++`. Sans multi-étapes,
toute cette chaîne reste dans l'image de production.

```dockerfile
# syntax=docker/dockerfile:1

########## Étape 1 : compilation des dépendances ##########
FROM node:22-bookworm-slim@sha256:<digest> AS deps

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3=3.11.2-1+b1 make=4.3-4.1 g++=4:12.2.0-3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./
# npm ci respecte le fichier de verrouillage ; npm install peut le modifier.
RUN npm ci --omit=dev && npm cache clean --force

########## Étape 2 : image d'exécution ##########
FROM node:22-bookworm-slim@sha256:<digest> AS runtime

ENV NODE_ENV=production \
    PORT=3000 \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# UID/GID numériques fixes, propriétaire des chemins de données.
RUN groupadd --gid 10001 app \
 && useradd --uid 10001 --gid 10001 --home-dir /app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

# Les dépendances compilées viennent de l'étape 1 ; la chaîne de build reste derrière.
COPY --from=deps --chown=10001:10001 /app/node_modules ./node_modules
COPY --chown=10001:10001 package.json ./
COPY --chown=10001:10001 server ./server
COPY --chown=10001:10001 public ./public

# Points de montage des volumes, créés avec le bon propriétaire AVANT le USER.
RUN mkdir -p /app/data /app/storage/uploads && chown -R 10001:10001 /app/data /app/storage

USER 10001:10001

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.PORT+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# Forme exec : le processus reçoit SIGTERM et peut s'arrêter proprement.
CMD ["node", "server/index.js"]
```

Points d'attention :

- L'épinglage de version des paquets `apt` (règle `DL3008` de hadolint) rend le
  build reproductible mais casse dès que le dépôt Debian tourne. Compromis
  acceptable : épingler dans l'étape de build, où l'échec est visible tout de
  suite, et ne pas installer de paquet du tout dans l'étape d'exécution.
- `mkdir` + `chown` doivent précéder `USER` : après le basculement, l'utilisateur
  non privilégié ne peut plus créer ces chemins.
- Un volume monté sur `/app/data` **écrase** le propriétaire défini dans l'image :
  vérifier les droits après montage, pas seulement dans le Dockerfile.

### Variante distroless (surface minimale, pas de shell)

```dockerfile
FROM gcr.io/distroless/nodejs22-debian12:nonroot@sha256:<digest> AS runtime
WORKDIR /app
COPY --from=deps --chown=nonroot:nonroot /app/node_modules ./node_modules
COPY --chown=nonroot:nonroot server ./server
USER nonroot
CMD ["server/index.js"]
```

Contrepartie : plus de shell, donc plus de `docker exec -it ... sh` pour
diagnostiquer, et le `HEALTHCHECK` doit être un binaire ou un script Node.

---

## Python

```dockerfile
# syntax=docker/dockerfile:1
FROM python:3.13-slim@sha256:<digest> AS builder

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt ./
# --require-hashes échoue si une dépendance n'est pas épinglée par hachage :
# c'est la protection contre la substitution de paquet.
RUN pip install --require-hashes -r requirements.txt

FROM python:3.13-slim@sha256:<digest> AS runtime

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN groupadd --gid 10001 app && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=10001:10001 app ./app

USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health').status==200 else 1)"
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "4", "-k", "uvicorn.workers.UvicornWorker", "app.main:app"]
```

---

## PHP-FPM (Laravel / Symfony)

```dockerfile
# syntax=docker/dockerfile:1
FROM composer:2@sha256:<digest> AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist
COPY . .
RUN composer dump-autoload --optimize --no-dev

FROM php:8.3-fpm-alpine@sha256:<digest> AS runtime

RUN docker-php-ext-install pdo_mysql opcache \
 && mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Durcissement de l'interpréteur
RUN { \
      echo 'expose_php=Off'; \
      echo 'display_errors=Off'; \
      echo 'log_errors=On'; \
      echo 'opcache.validate_timestamps=0'; \
      echo 'disable_functions=exec,passthru,shell_exec,system,proc_open,popen'; \
    } > "$PHP_INI_DIR/conf.d/99-hardening.ini"

WORKDIR /var/www
COPY --from=vendor --chown=82:82 /app /var/www
# 82 = www-data dans les images Alpine officielles PHP
USER 82:82
EXPOSE 9000
CMD ["php-fpm"]
```

`disable_functions` neutralise les fonctions d'exécution de commande : à faire
seulement si l'application ne s'en sert pas — le vérifier
(`grep -rE '\b(exec|shell_exec|system|proc_open|popen)\s*\('`), pas le supposer.

---

## Java / Spring Boot

```dockerfile
# syntax=docker/dockerfile:1
FROM maven:3.9-eclipse-temurin-21@sha256:<digest> AS build
WORKDIR /src
COPY pom.xml ./
RUN mvn -B dependency:go-offline
COPY src ./src
RUN mvn -B -DskipTests package

FROM eclipse-temurin:21-jre-alpine@sha256:<digest> AS runtime
RUN addgroup -g 10001 app && adduser -u 10001 -G app -D -H -s /sbin/nologin app
WORKDIR /app
COPY --from=build --chown=10001:10001 /src/target/*.jar app.jar
USER 10001:10001
EXPOSE 8080
# Respect des limites mémoire du conteneur : la JVM lit les cgroups depuis Java 10,
# MaxRAMPercentage évite qu'elle vise la RAM de l'hôte.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/actuator/health | grep -q '"status":"UP"'
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

---

## Front statique (React / Next.js export) servi par nginx

```dockerfile
# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim@sha256:<digest> AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.27-alpine@sha256:<digest> AS runtime
# L'image "unprivileged" tourne en UID 101 et écoute sur 8080 : pas de setuid,
# pas besoin de capacité NET_BIND_SERVICE.
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
```

`nginx.conf` minimal durci :

```nginx
server {
    listen 8080;
    server_tokens off;                     # ne pas divulguer la version
    root /usr/share/nginx/html;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'" always;

    location / { try_files $uri $uri/ /index.html; }
    location ~ /\.(?!well-known) { deny all; }   # bloque .git, .env, .htaccess
}
```

Vérifier les en-têtes servis, pas le fichier de configuration :

```bash
curl -sI http://localhost:8080/ | grep -iE 'content-security|x-frame|nosniff|server'
```

---

## Secrets pendant le build (BuildKit)

```dockerfile
# syntax=docker/dockerfile:1
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc,mode=0400 \
    npm ci --omit=dev
```

```bash
DOCKER_BUILDKIT=1 docker build --secret id=npmrc,src=$HOME/.npmrc -t app:1.0 .
```

Le fichier n'existe que pendant l'instruction `RUN` et n'apparaît dans aucune
couche. Vérification :

```bash
docker history --no-trunc app:1.0 | grep -iE 'npmrc|token|_auth' || echo "aucune fuite dans l'historique"
```

À proscrire : `ARG NPM_TOKEN` puis `ENV NPM_TOKEN=$NPM_TOKEN`, ou un `COPY .npmrc`
suivi d'un `RUN rm .npmrc` — la valeur reste dans la couche précédente.

---

## `.dockerignore` de référence

```
.git
.gitignore
.github
.gitlab-ci.yml
node_modules
npm-debug.log
.env
.env.*
!.env.example
*.pem
*.key
*.p12
id_rsa*
.aws
.ssh
.vscode
.idea
coverage
dist
tests
__pycache__
*.pyc
.venv
venv
vendor
docker-compose*.yml
Dockerfile*
README.md
*.sqlite
*.db
storage/uploads
```

Le contrôle qui compte n'est pas la lecture du fichier mais le contenu réel de
l'image :

```bash
docker build -t app:audit .
docker run --rm --entrypoint sh app:audit -c 'ls -la /app; ls -la /app/.git 2>/dev/null && echo "FUITE .git"'
```

Sur une image distroless sans shell, inspecter l'archive à la place :

```bash
docker save app:audit -o /tmp/img.tar && tar -tf /tmp/img.tar | head -50
```
