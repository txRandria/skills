# Phase 3 — privilèges des comptes de service

## Le constat qui motive ce fichier

Un audit avait relevé la réutilisation et la faiblesse des mots de passe de base
de données, et s'était arrêté là. Le rôle utilisé par l'application était
**superutilisateur** : cet attribut transformait une simple authentification
applicative en primitive d'exécution de commandes shell sur l'hôte de la base.

La gravité ne venait pas de la difficulté d'obtenir l'accès, mais de ce que
l'accès permettait.

**Règle : auditer les privilèges effectifs d'un compte de service avec la même
rigueur que ses identifiants.**

## PostgreSQL

```sql
-- Attributs de rôle : superutilisateur, création de rôles, contournement RLS
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolbypassrls, rolreplication
FROM pg_roles
WHERE rolcanlogin
ORDER BY rolsuper DESC, rolname;

-- Appartenance à des rôles privilégiés : lecture/écriture de fichiers serveur,
-- exécution de programmes. Ces rôles donnent l'essentiel du pouvoir du
-- superutilisateur sans porter l'attribut.
SELECT r.rolname AS role, m.rolname AS membre
FROM pg_auth_members am
JOIN pg_roles r ON r.oid = am.roleid
JOIN pg_roles m ON m.oid = am.member
WHERE r.rolname IN ('pg_read_server_files','pg_write_server_files',
                    'pg_execute_server_program','pg_read_all_data','pg_write_all_data');

-- Extensions installées : certaines exposent des primitives d'exécution
SELECT extname FROM pg_extension;

-- Qui peut se connecter, et d'où
SHOW hba_file;          -- puis lire ce fichier : une ligne `trust` est critique
SHOW listen_addresses;  -- '*' expose au-delà de la boucle locale
SHOW ssl;
```

Constats de gravité élevée, indépendamment de la robustesse du mot de passe :

- Le rôle applicatif porte `rolsuper`.
- Le rôle applicatif est membre de `pg_execute_server_program`,
  `pg_read_server_files` ou `pg_write_server_files`.
- Une ligne `trust` dans `pg_hba.conf` (authentification sans mot de passe).
- `listen_addresses = '*'` combiné à un port joignable depuis l'extérieur
  (à croiser avec la mesure de la phase 3 réseau).

## MySQL / MariaDB

```sql
SELECT user, host, plugin FROM mysql.user;

-- Privilèges globaux : FILE permet la lecture/écriture de fichiers serveur,
-- SUPER et GRANT OPTION permettent l'escalade.
SELECT user, host, Super_priv, File_priv, Process_priv, Grant_priv, Shutdown_priv
FROM mysql.user;

SHOW GRANTS FOR '<compte-applicatif>'@'<hote>';

-- Comptes sans mot de passe
SELECT user, host FROM mysql.user WHERE authentication_string = '';

SHOW VARIABLES LIKE 'secure_file_priv';   -- vide = écriture de fichier sans limite
SHOW VARIABLES LIKE 'local_infile';
```

`GRANT ALL ON *.*` à un compte applicatif est le motif le plus courant : il
inclut `FILE` et `GRANT OPTION`, donc lecture de fichiers serveur et
auto-attribution de droits.

## MongoDB

```javascript
db.getSiblingDB("admin").system.users.find({}, {user:1, roles:1});
db.runCommand({connectionStatus: 1}).authInfo;
db.adminCommand({getParameter: 1, authenticationMechanisms: 1});
```

Points critiques : l'autorisation désactivée (`--noauth`, aucune valeur
`security.authorization: enabled`), un compte portant `root` ou `dbOwner` pour un
usage applicatif, une écoute sur toutes les interfaces.

## Redis

```bash
redis-cli -h <hote> INFO server
redis-cli -h <hote> CONFIG GET requirepass     # vide = aucune authentification
redis-cli -h <hote> ACL LIST                   # Redis 6+
redis-cli -h <hote> CONFIG GET dir
redis-cli -h <hote> CONFIG GET dbfilename
```

Redis sans mot de passe et joignable depuis l'extérieur est une exécution de code
à distance connue : `CONFIG SET dir` + `dbfilename` permettent d'écrire un fichier
arbitraire (clé SSH, tâche cron). Le constat n'est pas « pas de mot de passe »,
c'est « exécution de code à distance non authentifiée ».

## Comptes de service système

```bash
# Le service tourne-t-il en root alors qu'un compte dédié suffirait ?
ps -eo user,pid,comm --sort=user | awk '$1=="root"' | head -30

# Unités systemd : privilèges et durcissement
systemctl show <unité> -p User -p Group -p PrivateTmp -p ProtectSystem \
  -p ProtectHome -p NoNewPrivileges -p CapabilityBoundingSet

# Appartenance au groupe docker = équivalent root sur l'hôte
getent group docker
```

L'appartenance au groupe `docker` mérite un constat explicite : elle permet de
démarrer un conteneur privilégié montant la racine de l'hôte, donc d'obtenir root
sans passer par `sudo` ni laisser de trace dans les journaux `sudo`.

## Quand le privilège est structurellement irrévocable

Un privilège peut être impossible à retirer : le compte d'initialisation d'un
moteur de base de données doit conserver son attribut de superutilisateur ; le
moteur refuse le retrait.

Dans ce cas, la remédiation n'est pas « retirer l'attribut » mais **changer
d'identité** :

1. Créer un compte applicatif distinct, sans attribut privilégié.
2. Lui transférer la propriété des objets applicatifs — objet par objet, les
   conteneurs (schémas, bases) avant leurs dépendances. Une commande de transfert
   en masse échoue en général sur le compte d'initialisation et sur les objets
   dépendants d'autres objets.
3. Basculer la configuration de l'application vers le nouveau compte.
4. Vérifier qu'aucun objet applicatif ne reste rattaché à l'ancien compte.
5. Seulement alors, restreindre l'ancien compte au niveau réseau
   (`pg_hba.conf`, `host` MySQL) puisque son attribut ne peut pas être retiré.

**Vérifier qu'une réduction de privilèges est réalisable avant de la promettre.**
Une recommandation impossible à appliquer discrédite le rapport et fait perdre le
temps de l'équipe qui l'essaie.

Requête de contrôle finale (PostgreSQL) :

```sql
SELECT n.nspname, c.relname, pg_get_userbyid(c.relowner) AS proprietaire
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE pg_get_userbyid(c.relowner) = '<ancien-compte>'
  AND n.nspname NOT IN ('pg_catalog','information_schema');
```

Zéro ligne = transfert complet. Une seule ligne restante = l'ancien compte reste
nécessaire, donc la remédiation n'est pas terminée.
