# Grille de revue de sécurité — code existant ou diff

À charger quand la tâche est d'auditer, pas d'écrire. Ordre imposé : du plus grave
au plus cosmétique, pour que l'audit reste utile même s'il est interrompu.

## Règle de conduite

**Constater d'abord, corriger ensuite.** Livrer la liste des défauts (fichier,
ligne, scénario d'exploitation concret, gravité) avant d'appliquer le moindre
correctif. Une correction appliquée pendant l'audit brouille la frontière entre ce
qui a été observé et ce qui a été modifié, et empêche l'auteur du code de valider
le constat.

**Valider chaque correctif sur le cas signalé.** Un correctif éprouvé sur un cas
sain ne prouve rien : le cas de test doit être celui dont l'issue est connue à
l'avance et actuellement fausse.

**Chercher l'effet, pas le mot-clé.** La présence de `helmet()`, `@PreAuthorize`,
`csrf`, `rateLimit` dans le code ne prouve pas que le contrôle s'applique sur le
chemin réel de la requête. Vérifier l'en-tête réellement servi, l'IP réellement
comptée, l'annotation réellement activée.

## Passe 1 — accès aux données (gravité maximale)

| Point | Comment vérifier |
|---|---|
| IDOR | Pour chaque route qui prend un identifiant : le propriétaire figure-t-il dans la clause `WHERE` / le filtre ORM ? Une vérification faite après le chargement en mémoire compte comme un défaut si elle peut être contournée par un autre chemin de code. |
| Route non protégée | Lister toutes les routes et confronter à la configuration d'authentification. Une route ajoutée après la configuration est souvent ouverte. |
| Élévation de privilège | Le rôle est-il lu depuis le jeton/la session côté serveur, ou depuis le corps de la requête ? |
| Injection SQL | Rechercher les concaténations : `grep -rnE "(SELECT\|INSERT\|UPDATE\|DELETE).*(\+\|\\$\{\|%s\|f\")" --include='*.js' --include='*.ts' --include='*.py' --include='*.php' --include='*.java'` |
| Mass assignment | `fields = "__all__"`, `$guarded = []`, `create($request->all())`, `@RequestBody` sur une entité, spread d'objet dans un `update` |

## Passe 2 — secrets et configuration

```bash
# Valeurs secrètes littérales dans le code suivi
git grep -nIE '(password|secret|api[_-]?key|token|passwd)\s*[:=]\s*["'"'"'][^"'"'"']{8,}' -- . ':!*.lock' ':!*test*'

# Clés privées
git grep -nI 'BEGIN .*PRIVATE KEY'

# Fichiers d'environnement suivis par erreur
git ls-files | grep -E '^\.env($|\.)' | grep -v example
```

Un secret trouvé dans l'historique reste compromis même supprimé de `HEAD` :
le constat est « à rotationner », pas « à supprimer ».

À vérifier aussi : mode debug actif en production (`APP_DEBUG`, `DEBUG`,
`include-stacktrace`), endpoints d'administration exposés (`/actuator/*`, `/docs`,
`/debug`), valeurs par défaut restées en place (secret d'exemple, mot de passe
d'amorçage).

## Passe 3 — entrées et sorties

| Point | Signal de défaut |
|---|---|
| Validation | Un handler qui lit `req.body` / `request.POST` / `$request->all()` après une étape de validation |
| Champs inconnus acceptés | Absence de `.strict()`, `extra="forbid"`, `fail-on-unknown-properties` |
| XSS | `dangerouslySetInnerHTML`, `{!! !!}`, `\|raw`, `\|safe`, `mark_safe`, `innerHTML =`, `th:utext` |
| Path traversal | Concaténation de chemin avec une entrée utilisateur sans résolution puis test de préfixe |
| Upload | Type déterminé par extension ou `Content-Type` client ; nom client réutilisé ; stockage sous la racine web |
| Injection de commande | `shell=True`, `Runtime.exec(chaîne)`, `exec($cmd)`, `child_process.exec` |
| SSRF | Requête sortante dont l'hôte vient de l'utilisateur, sans liste blanche ni blocage des adresses privées |
| Désérialisation | `pickle`, `unserialize`, `ObjectInputStream`, `yaml.load` sans chargeur sûr |
| Redirection ouverte | `redirect(param)` sans contrainte de chemin relatif interne |

## Passe 4 — transport, session, en-têtes

Vérifier sur le service en fonctionnement, pas dans le fichier de configuration :

```bash
curl -sI https://cible/ | grep -iE 'strict-transport|content-security|x-content-type|referrer-policy|x-frame|set-cookie'
```

- Cookie de session : `HttpOnly`, `Secure`, `SameSite` présents ?
- CSP : contient-elle `unsafe-inline` ou `unsafe-eval` ?
- CORS : `Access-Control-Allow-Origin` reflète-t-il l'origine envoyée ? Tester avec
  une origine arbitraire — un reflet inconditionnel combiné à
  `Allow-Credentials: true` est un défaut grave.
- CSRF : les routes d'écriture exigent-elles un jeton quand la session est en cookie ?
- Limitation de débit : l'IP comptée est-elle celle du client ou celle du proxy ?

## Passe 5 — journalisation et gestion d'erreur

- Une réponse d'erreur renvoie-t-elle une trace de pile, une requête SQL, un chemin
  absolu, une version de composant ?
- Le message d'échec d'authentification distingue-t-il compte inconnu et mot de
  passe faux (par le texte ou par le temps de réponse) ?
- Les opérations sensibles laissent-elles une trace (acteur, ressource, horodatage) ?
- Un secret, un jeton ou un contenu de document apparaît-il dans un appel de log ?
- Les valeurs utilisateur écrites dans un log sont-elles neutralisées des retours
  à la ligne ?

## Passe 6 — dépendances

```bash
npm audit --audit-level=high        # Node
pip-audit                           # Python
composer audit                      # PHP
mvn org.owasp:dependency-check-maven:check   # Java
```

Vérifier aussi : fichier de verrouillage commité, installation reproductible en CI
et dans le Dockerfile (`npm ci`, `composer install --no-dev`, `--require-hashes`),
absence de dépendance non maintenue sur un chemin sensible (cryptographie,
analyse de fichier, authentification).

## Format de restitution

Un défaut par entrée, trié par gravité décroissante :

```
[CRITIQUE] server/routes/documents.js:42 — IDOR
Scénario : un collaborateur authentifié appelle GET /api/documents/<id> avec
l'identifiant d'un document appartenant à un autre matricule et reçoit le PDF.
La requête filtre sur `id` seul ; `req.user.matricule` n'entre pas dans la clause.
Correctif : ajouter `AND matricule = ?` et répondre 404 (pas 403).
```

Ce qui rend une entrée exploitable par le développeur : le scénario concret. Une
entrée du type « validation d'entrée insuffisante » sans chemin d'exploitation est
une opinion, pas un constat.

## Ce qu'un audit statique ne peut pas conclure

Un inventaire de code ne prouve pas l'absence de compromission, ni l'absence de
défaut : il ne couvre ni la configuration réellement déployée, ni les données
existantes, ni les composants tiers en fonctionnement. Le dire explicitement dans
la restitution, plutôt que de laisser croire à une couverture complète.
