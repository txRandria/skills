# Motifs de non-applicabilité les plus fréquents

Chaque entrée donne : ce que la règle suppose, comment vérifier si cette
supposition tient, et ce qui reste vrai malgré la non-applicabilité. Un constat
écarté doit l'être pour une raison technique écrite, jamais par confort.

---

## CSRF signalé sur une API à jeton porteur

**Ce que la règle suppose :** que l'authentification soit portée par un cookie, que
le navigateur attache automatiquement en requête cross-site.

**Vérifier :**

```bash
grep -rn 'cookie\|session\|express-session\|connect\.sid' server/ --include='*.js' | head
grep -rn 'Authorization\|Bearer\|req\.headers\.authorization' server/ --include='*.js' | head
```

**Non applicable si** l'authentification repose exclusivement sur un en-tête
`Authorization`, jamais sur un cookie : un navigateur n'attache pas cet en-tête à
une requête déclenchée depuis un autre site, donc il n'y a pas de requête
authentifiée involontaire à protéger.

**Reste vrai :** si un seul endpoint accepte un cookie de session, ou si le jeton
est stocké en cookie « pour la commodité », la règle redevient applicable. Vérifier
tous les chemins d'authentification, pas le principal.

**Piège de remédiation :** les middlewares CSRF historiques de plusieurs
écosystèmes sont archivés ou non maintenus. Vérifier avant d'ajouter la
dépendance — appliquer une correction inutile via un paquet abandonné ajoute du
risque net.

---

## Traversée de chemin sur une entrée déjà contrainte

**Ce que la règle suppose :** que la valeur atteignant la construction du chemin
puisse contenir des séparateurs et des séquences de remontée.

**Vérifier :** remonter de la ligne signalée jusqu'à l'entrée, et chercher la
contrainte de format en amont.

```bash
sed -n '<ligne-30>,<ligne+10>p' <fichier>
grep -rn 'uuid\|regex\|matches\|z\.string()\.uuid\|Pattern' <fichier> | head
```

**Non applicable si** la valeur est validée en amont contre un format qui exclut
`/`, `\` et `.` — un UUID, un identifiant numérique, une énumération.

**Reste vrai :** la validation doit être **sur le chemin emprunté**, pas dans une
fonction voisine. Si un second appelant construit le même chemin sans passer par
la validation, le défaut existe. Chercher tous les appelants avant d'écarter.

**Renforcement recommandé même en cas de non-applicabilité :** ajouter la
résolution puis le contrôle de préfixe. Il coûte trois lignes et rend le constat
définitivement clos, y compris pour les appelants futurs.

---

## Dépendance vulnérable non importée

**Ce que la règle suppose :** que le paquet soit chargé à l'exécution.

**Vérifier :**

```bash
grep -rn "require(['\"]<paquet>\|from ['\"]<paquet>" --include='*.js' --include='*.ts' . | grep -v node_modules
npm ls <paquet>            # dépendance directe ou transitive ?
```

**Trois cas distincts, trois actions différentes :**

| Cas | Action |
|---|---|
| Dépendance directe, importée | Mettre à jour |
| Dépendance directe, jamais importée | **Supprimer**, pas mettre à jour |
| Dépendance transitive | Mettre à jour le parent ; si impossible, surcharge de résolution documentée |

Un outil de scan ne distingue pas ces cas : il lit le manifeste. La bonne action
pour le deuxième cas réduit la surface au lieu de la déplacer.

**Vérifier aussi que la version prescrite existe :**

```bash
npm view <paquet> versions --json | tail -20
```

Un numéro de version cité par un rapport et contredit par le gestionnaire de
paquets signale un rapport construit sur une base d'avis périmée — traiter alors
tous ses constats SCA avec la même méfiance.

---

## Secret détecté dans un fichier d'exemple ou un test

**Vérifier :** le fichier est-il `*.example`, une fixture de test, un jeu de
données de démonstration ? La valeur est-elle réellement valide quelque part ?

**Non applicable si** la valeur est un jeton factice et que le fichier n'est
jamais chargé en production.

**Reste vrai, et souvent négligé :** un secret d'exemple qui ressemble à un vrai
finit copié en production. Remplacer par une valeur manifestement fausse
(`REMPLACER_MOI`) plutôt que par un faux réaliste — et vérifier que le fichier
réel (`.env`) est bien ignoré par le gestionnaire de versions.

---

## Injection SQL sur une requête paramétrée

**Ce que la règle suppose :** une concaténation atteignant l'interpréteur.

**Vérifier :** la valeur signalée alimente-t-elle un paramètre lié, ou le corps de
la requête ?

**Non applicable si** la valeur est passée en paramètre (`?`, `$1`, `:nom`).

**Reste vrai :** les identifiants (nom de colonne, sens de tri) ne sont pas
paramétrables. Si la valeur signalée est un nom de colonne interpolé, le constat
est **confirmé**, même si le reste de la requête est paramétré — et le correctif
est une liste blanche, pas un paramètre.

---

## Conteneur en root signalé sur une image qui bascule d'utilisateur

**Vérifier l'objet, pas le fichier :**

```bash
docker run --rm --entrypoint id <image>
docker inspect --format '{{.Config.User}}' <image>
```

**Non applicable si** `USER` est bien positionné et que `id` le confirme.

**Reste vrai :** une instruction `USER` peut être annulée par un `ENTRYPOINT` qui
rebascule, par `user: root` dans un fichier compose, ou par un orchestrateur.
Vérifier aussi le conteneur **en fonctionnement**, pas seulement l'image.

---

## Chiffrement au repos signalé absent alors qu'il est actif par défaut

**Vérifier auprès du fournisseur, pas dans le code :**

```bash
aws s3api get-bucket-encryption --bucket <nom>
gcloud storage buckets describe gs://<nom> --format='value(encryption)'
```

**Non applicable si** le chiffrement est actif au niveau du compte ou par défaut
du service.

**Reste vrai :** un défaut de fournisseur change sans préavis, et une déclaration
explicite documente l'intention et rend le contrôle auditable. Le constat passe de
« vulnérabilité » à « durcissement recommandé » — il change de gravité, il ne
disparaît pas.

---

## En-têtes de sécurité signalés absents derrière un reverse proxy

**Vérifier l'en-tête réellement servi au client, pas la configuration :**

```bash
curl -sI https://<cible>/ | grep -iE 'strict-transport|content-security|x-content-type|x-frame'
```

**Non applicable si** le proxy les injecte et que `curl` le confirme depuis
l'extérieur.

**Reste vrai :** si le service est aussi joignable en direct, en contournant le
proxy, les en-têtes manquent sur ce chemin. Vérifier les deux chemins — c'est le
même piège que celui d'une protection interposée mais contournable.

---

## Règle OWASP LLM appliquée à un appel de modèle sans entrée utilisateur

**Ce que la règle suppose :** qu'une entrée contrôlée par l'utilisateur atteigne
l'invite du modèle.

**Vérifier :** remonter de l'appel jusqu'à l'origine de chaque partie de l'invite.

**Non applicable si** l'invite est entièrement construite de constantes et de
données internes.

**Reste vrai :** une donnée « interne » écrite par un utilisateur à un autre moment
(un champ de profil, un document téléversé) est une entrée utilisateur différée.
L'origine se remonte jusqu'à la saisie, pas jusqu'à la lecture en base.

---

## Formulation d'un écartement

Modèle à reprendre, pour que le constat écarté reste traçable :

```
V-04  Absence de protection CSRF — NON APPLICABLE

Motif : l'authentification de l'application repose exclusivement sur l'en-tête
`Authorization: Bearer` (server/middleware/auth.js:14). Aucun cookie de session
n'est émis (aucune occurrence de express-session ni de res.cookie dans server/).
Un navigateur n'attachant pas cet en-tête aux requêtes cross-site, il n'existe
pas de requête authentifiée involontaire à protéger.

Vérifié le : 2026-09-09
Condition de réouverture : introduction d'un cookie d'authentification, ou d'un
endpoint acceptant la session en cookie.
```

La **condition de réouverture** est ce qui distingue un constat instruit d'un
constat balayé : elle dit à quoi il faudra faire attention pour que l'écartement
reste valide.
