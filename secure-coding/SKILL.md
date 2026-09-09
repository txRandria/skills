---
name: secure-coding
description: Écrire ou réviser du code applicatif en appliquant les exigences de sécurité (OWASP Top 10 / ASVS) et les bonnes pratiques. À utiliser dès qu'on écrit ou modifie du code qui traite une entrée utilisateur, une authentification, une autorisation, une requête base de données, un upload de fichier, un appel HTTP sortant, un secret, un log, ou une réponse HTTP — en Node.js/Express, React, Next.js, Python (FastAPI/Django/Flask), PHP (Laravel/Symfony) ou Java (Spring). Couvre aussi la revue de sécurité d'un fichier ou d'un diff existant. Ne pas utiliser pour l'infrastructure : voir secure-docker, secure-terraform, secure-cicd.
---

# Secure Coding

**Créé par Tahina Fabien**

Skill open-source. Il fige les exigences de sécurité applicables à tout code écrit
ou modifié, indépendamment du langage, et route vers les règles concrètes du
langage concerné.

**Licence :** CC BY 4.0 — partage et adaptation libres avec attribution.

**Retours :** si la méthodologie pose question ou si un retour constructif est
formulé sur une sortie produite par ce skill, le consigner et proposer de le
partager avec l'auteur. Si le problème vient de l'agent qui n'a pas suivi les
règles du skill, le reconnaître et corriger — ne pas modifier le skill.

**Dépôt :** https://github.com/txRandria/skills — signaler un problème de méthodologie via une issue publique bénéficie à tous les utilisateurs du skill.

---

## Portée et déclenchement

Charger ce skill **avant** d'écrire la première ligne, pas au moment de la revue.
Un contrôle de sécurité ajouté après coup est un correctif ; intégré dès
l'écriture, il est une propriété du code.

Déclencheurs : entrée utilisateur, authentification, autorisation, requête SQL ou
ORM, upload / téléchargement de fichier, appel HTTP sortant, secret, log, réponse
HTTP, sérialisation, gabarit (template), cryptographie, session, cookie.

## Étape 0 — verrouiller les versions avant d'écrire du code

Un extrait de code non ancré à une version est un motif, pas une implémentation.
Avant de produire un snippet destiné à être copié :

```bash
# Node
cat package.json && head -5 package-lock.json
# Python
cat pyproject.toml requirements.txt 2>/dev/null
# PHP
cat composer.json
# Java
cat pom.xml build.gradle 2>/dev/null | head -40
```

Relever : version majeure du framework (Express 4 vs 5, Django 4 vs 5, Spring Boot
2 vs 3, Laravel 10 vs 11, React 18 vs 19, Next.js Pages Router vs App Router),
système de modules (CommonJS vs ESM), version du langage. Sans dépôt accessible,
livrer uniquement le cœur indépendant du framework et étiqueter explicitement les
variantes de câblage par version.

## Les 14 règles non négociables

Elles s'appliquent à tous les langages. Les détails d'implémentation sont dans
`references/`.

1. **Valider toute entrée à la frontière, par liste blanche.** Un schéma déclaratif
   (Zod, Pydantic, Bean Validation, Form Request) sur chaque champ : type, format,
   longueur maximale, valeurs autorisées. Rejeter, ne pas « nettoyer ». Ce qui n'est
   pas déclaré n'entre pas — refuser les propriétés inconnues (mass assignment).

2. **Jamais de secret dans le code, le dépôt, l'image ou les logs.** Secrets par
   variable d'environnement ou gestionnaire de secrets. `.env` dans `.gitignore`,
   `.env.example` sans valeur réelle. Un secret commité une fois est compromis :
   le rotationner, ne pas se contenter de le retirer de `HEAD`.

3. **Requêtes paramétrées, toujours.** Aucune concaténation de chaîne dans une
   requête SQL, NoSQL, LDAP ou une commande shell. Les identifiants (nom de table,
   colonne, sens de tri) ne sont pas paramétrables : les valider contre une liste
   blanche explicite.

4. **Vérifier l'autorisation sur l'objet, à chaque requête, côté serveur.** Le
   défaut le plus fréquent en production n'est pas l'injection, c'est l'IDOR :
   l'utilisateur est authentifié, la route est protégée, mais la ressource
   demandée ne lui appartient pas. La règle : chaque lecture ou écriture d'une
   ressource porteuse d'un propriétaire filtre par ce propriétaire dans la requête
   elle-même, jamais après coup en mémoire.

5. **Encodage de sortie contextuel.** L'échappement dépend du contexte de
   destination (HTML, attribut, URL, JS, CSS, SQL). Utiliser l'échappement
   automatique du moteur de gabarits ; ne jamais le désactiver
   (`dangerouslySetInnerHTML`, `v-html`, `|safe`, `{!! !!}`, `th:utext`) sans
   assainissement par une bibliothèque dédiée (DOMPurify, bleach, HTMLPurifier).

6. **Cryptographie : n'en écrire aucune.** Mots de passe : argon2id ou bcrypt
   (coût ≥ 12), jamais SHA/MD5, même salés. Aléa de sécurité : le CSPRNG de la
   plateforme (`crypto.randomBytes`, `secrets`, `random_bytes`, `SecureRandom`),
   jamais `Math.random()`/`rand()`. Chiffrement : AEAD (AES-GCM, ChaCha20-Poly1305)
   via une bibliothèque maintenue.

7. **Uploads : traiter tout fichier reçu comme hostile.** Limite de taille imposée
   côté serveur, type déterminé par inspection du contenu (magic bytes) et non par
   l'extension ni le `Content-Type` client, nom de stockage généré (UUID) sans
   réutiliser le nom fourni, stockage **hors racine web**, service via un
   contrôleur qui vérifie l'autorisation. Ne jamais exécuter ni interpréter un
   fichier téléversé.

8. **Path traversal : résoudre puis vérifier le préfixe.** Toute construction de
   chemin à partir d'une entrée utilisateur passe par une résolution absolue suivie
   d'un contrôle que le chemin résolu est bien sous la racine autorisée. Le contrôle
   se fait **après** résolution, jamais par filtrage de `..` sur la chaîne brute.

9. **SSRF : liste blanche des destinations sortantes.** Un appel HTTP dont l'URL
   vient de l'utilisateur doit valider le schéma (`https` uniquement), résoudre le
   nom et rejeter les adresses privées, de bouclage et link-local — dont
   `169.254.169.254` (métadonnées cloud). Désactiver le suivi automatique de
   redirection, ou revalider à chaque saut.

10. **Erreurs : message générique au client, détail dans le log.** Aucune trace de
    pile, requête SQL, chemin de fichier ou version de composant dans une réponse.
    Les messages d'authentification ne distinguent pas « compte inconnu » de « mot
    de passe faux ».

11. **Logs : traçables, sans secret ni donnée personnelle inutile.** Journaliser
    les opérations sensibles (connexion, échec de connexion, changement de droit,
    accès à un document, suppression) avec horodatage, identité de l'acteur et
    identifiant de la ressource. Ne jamais journaliser mot de passe, jeton, cookie,
    numéro de carte, contenu de document. Neutraliser les retours à la ligne dans
    une valeur venant de l'utilisateur avant de l'écrire dans un log (log injection).

12. **En-têtes de sécurité, CORS explicite, CSRF quand la session est en cookie.**
    CSP sans `unsafe-inline`, HSTS, `X-Content-Type-Options: nosniff`,
    `Referrer-Policy`. CORS : liste blanche d'origines, jamais `*` avec
    `credentials: true`. Authentification par cookie : `HttpOnly`, `Secure`,
    `SameSite=Lax` ou `Strict`, **et** un jeton anti-CSRF sur toute méthode qui
    modifie l'état.

13. **Limitation de débit, et la vérifier réellement appliquée.** Limiter les
    routes d'authentification, de recherche et d'upload. Piège classique : derrière
    un reverse proxy, si `trust proxy` n'est pas configuré correctement, toutes les
    requêtes portent l'IP du proxy — la limitation existe et ne protège rien, ou
    bloque tout le monde. Inversement, `trust proxy` trop permissif rend l'IP
    falsifiable par un en-tête `X-Forwarded-For` client. Vérifier l'IP réellement
    vue par l'application, pas la présence de la configuration.

14. **Dépendances : verrouillées, auditées, minimales.** Fichier de verrouillage
    commité, installation reproductible (`npm ci`, `pip install -r` avec hachages,
    `composer install`), audit dans la CI, mise à jour des vulnérabilités critiques
    avant livraison. Toute nouvelle dépendance est une surface d'attaque : vérifier
    maintenance et popularité avant de l'ajouter.

## Références par langage — charger à la demande

Ne charger que le fichier correspondant à la stack effectivement utilisée.

| Fichier | Contenu |
|---|---|
| `references/nodejs-express.md` | Express/Fastify : helmet, CORS, JWT vs session, rate limit + trust proxy, multer, SQL/ORM, path traversal, secrets |
| `references/react-nextjs.md` | XSS côté client, Server Actions, frontière serveur/client, variables `NEXT_PUBLIC_`, middleware d'auth, CSP avec nonce |
| `references/python.md` | FastAPI/Django/Flask : Pydantic, ORM, CSRF, désérialisation, `subprocess`, templates Jinja |
| `references/php.md` | Laravel/Symfony : Eloquent/Doctrine, mass assignment, CSRF, upload, `escapeshellarg`, sessions |
| `references/java.md` | Spring Boot : Spring Security, JPA, Bean Validation, désérialisation, XXE, `@PreAuthorize` |
| `references/review-checklist.md` | Grille de revue d'un diff ou d'un fichier existant, par ordre de gravité |

## Contrôle avant livraison (obligatoire)

Une règle documentée n'est pas une règle appliquée. Avant de présenter du code,
relire cette section et vérifier point par point, sur le code réellement écrit :

- [ ] Chaque entrée externe passe par un schéma de validation par liste blanche.
- [ ] Aucune valeur secrète littérale dans le diff (`git diff | grep -iE 'password|secret|token|api[_-]?key|BEGIN .*PRIVATE KEY'`).
- [ ] Aucune requête construite par concaténation.
- [ ] Chaque accès à une ressource possédée filtre par propriétaire **dans la requête**.
- [ ] Aucun échappement automatique désactivé sans assainisseur.
- [ ] Uploads : taille, type par contenu, nom généré, stockage hors racine web.
- [ ] Chemins construits depuis une entrée : résolus puis vérifiés par préfixe.
- [ ] Réponses d'erreur sans trace de pile ni détail interne.
- [ ] Aucun secret ni donnée personnelle dans un appel de log ajouté.
- [ ] Les tests couvrent au moins un cas de refus (entrée invalide, accès non autorisé).

Le test négatif du dernier point est ce qui distingue un contrôle vérifié d'un
contrôle supposé : un correctif validé uniquement sur le cas nominal laisse passer
la régression.

## Quand un défaut est trouvé dans du code existant

Distinguer explicitement le constat de la remédiation. Livrer d'abord la liste des
défauts avec fichier, ligne, scénario d'exploitation concret et gravité ; appliquer
les correctifs ensuite, une fois l'ordre validé. Un correctif appliqué pendant
l'audit brouille la frontière entre ce qui a été observé et ce qui a été changé.

Toujours valider un correctif sur le cas signalé, pas sur un cas sain : un contrôle
prouvé sur un cas dont l'issue n'est pas connue à l'avance ne prouve rien.

### Quand les défauts viennent d'un rapport d'audit automatisé

Un rapport d'outil est une liste d'hypothèses à instruire, pas une liste de tâches
à exécuter. Trois choses y sont **indépendamment** faillibles : que le défaut
existe, que la correction proposée soit la bonne, et que le décompte soit juste —
or c'est le décompte qui décide seul, le plus souvent, du feu vert de mise en
production.

Trois validations avant la moindre correction, dans cet ordre :

1. **Applicabilité au mécanisme réellement employé.** Une règle CSRF n'a de sens
   que si l'authentification est portée par un cookie ; une règle de traversée de
   chemin ne vaut que si l'entrée n'est pas déjà contrainte par un format en
   amont. Ouvrir le fichier à la ligne citée et remonter jusqu'à l'origine de la
   valeur.

2. **Actualité de la remédiation prescrite.** Vérifier que le paquet recommandé
   est maintenu et que le numéro de version indiqué existe et corrige bien l'avis
   visé (`npm view <paquet> time.modified deprecated`). Vérifier aussi que le
   paquet est importé quelque part : s'il ne l'est pas, la bonne action est la
   suppression, pas la mise à jour.

3. **Unicité des constats.** Un même défaut détecté par deux règles, ou reporté
   dans deux domaines d'audit, ne compte qu'une fois — sinon il pèse double sur le
   score et peut à lui seul décider d'un feu vert ou rouge.

Documenter chaque constat écarté avec sa justification technique et sa condition
de réouverture, plutôt que de le laisser sans réponse : sans cela il revient au
prochain audit, et le doute avec lui.

Pour la procédure complète (réconciliation des sévérités, déduplication,
séparation des scénarios corrélés, recalcul du score et de la décision), charger le
skill `security-audit-review`.
