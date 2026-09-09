---
name: secure-cicd
description: Écrire ou durcir un pipeline d'intégration et de déploiement continus (GitLab CI .gitlab-ci.yml, GitHub Actions workflows) en respectant les exigences de sécurité — permissions minimales, fédération d'identité OIDC au lieu de clés statiques, épinglage des actions par SHA, secrets masqués et non exfiltrables, isolation des contributions externes, portes de scan SAST/secrets/dépendances/conteneur, approbation humaine avant production, SBOM et signature d'artefact. À utiliser dès qu'on crée ou modifie un fichier de pipeline, une variable de CI, un runner, ou une étape de déploiement.
---

# Secure CI/CD

**Créé par Tahina Fabien**

Skill open-source. Il fixe les exigences de sécurité d'une chaîne d'intégration et
de déploiement, et fournit les gabarits GitLab CI et GitHub Actions correspondants.

**Licence :** CC BY 4.0 — partage et adaptation libres avec attribution.

**Retours :** si la méthodologie pose question ou si un retour constructif est
formulé sur une sortie produite par ce skill, le consigner et proposer de le
partager avec l'auteur. Si le problème vient de l'agent qui n'a pas suivi les
règles du skill, le reconnaître et corriger.

**Dépôt :** https://github.com/txRandria/skills — signaler un problème de méthodologie via une issue publique bénéficie à tous les utilisateurs du skill.

---

## Le modèle de menace, en une phrase

Un pipeline est une machine qui exécute du code arbitraire avec les identifiants
de production. Toute la sécurité d'une CI découle de cette phrase : ce qui est
exécuté doit être contrôlé, et ce qui est accessible pendant l'exécution doit être
minimal.

Les trois compromissions les plus fréquentes, dans l'ordre :

1. Une contribution externe fait exécuter son propre code avec les secrets du dépôt.
2. Une dépendance ou une action tierce, référencée par un tag mutable, est
   remplacée en amont.
3. Un identifiant cloud à longue durée de vie, stocké en variable de CI, est
   exfiltré par un job — puis réutilisé longtemps après, hors de toute traçabilité.

## Étape 0 — lire l'existant

```bash
ls -la .gitlab-ci.yml .github/workflows/ 2>/dev/null
cat .gitlab-ci.yml 2>/dev/null | head -40
grep -rn 'secrets\.\|\$CI_\|\${{' .github/workflows/ .gitlab-ci.yml 2>/dev/null | head -20
```

Identifier la plateforme, les déclencheurs, les endroits où un secret est
référencé, et les jobs qui tournent sur une contribution externe.

## Les 12 règles non négociables

1. **Aucun identifiant cloud à longue durée de vie en variable de CI.**
   Authentification par fédération d'identité (OIDC) : le job reçoit un jeton
   court, signé, lié au dépôt, à la branche et à l'environnement, et l'échange
   contre des identifiants temporaires. Une clé statique est un secret permanent
   qu'aucune rotation ne suit et qu'aucun journal ne relie à un job précis.

2. **Restreindre la confiance côté fournisseur, pas seulement côté CI.** Le rôle
   fédéré doit contraindre le `sub` du jeton (dépôt **et** branche ou
   environnement). Sans cette condition, tout projet de la même instance peut
   assumer le rôle. C'est l'erreur la plus courante et la plus grave de la mise en
   place OIDC.

3. **Permissions minimales par défaut, élargies au job.** GitHub :
   `permissions: contents: read` au niveau du workflow, ajouts explicites par job.
   GitLab : jeton de job à portée réduite, variables limitées aux environnements
   qui en ont besoin.

4. **Épingler tout ce qui est exécuté.** Actions par SHA de commit complet, images
   de conteneur par digest, versions d'outils figées. Un tag est réattribuable :
   `@v4` aujourd'hui et `@v4` demain peuvent être deux codes différents.

5. **Ne jamais exécuter du code non fiable avec accès aux secrets.** Sur une
   contribution externe, le job de construction et de test tourne **sans** secret.
   Sur GitHub, `pull_request_target` exécute le workflow avec les secrets du dépôt
   sur du code proposé de l'extérieur : c'est le motif d'exécution de code à
   distance le plus documenté de la plateforme.

6. **Secrets masqués, jamais imprimés, jamais dans un artefact.** Vérifier que
   les variables sont marquées masquées et protégées. Interdire `set -x` sur un
   bloc manipulant un secret, et ne jamais écrire un secret dans un fichier
   conservé en artefact.

7. **Aucune interpolation de valeur contrôlée par l'utilisateur dans un script.**
   Un titre de merge request ou un nom de branche injecté directement dans un
   `run:` est une injection de commande dans le contexte du runner. Passer par une
   variable d'environnement, jamais par substitution dans le corps du script.

8. **Portes de scan bloquantes.** Secrets, dépendances vulnérables, SAST, et scan
   de l'image construite. Un scan non bloquant n'est pas un contrôle : c'est une
   décoration de journal.

9. **Séparation construction / déploiement.** Le job qui construit n'a pas les
   droits de déployer. Le job qui déploie ne reconstruit pas : il déploie
   l'artefact déjà scanné, désigné par son digest.

10. **Approbation humaine et environnement protégé avant la production.** Aucun
    `apply` ni déploiement automatique en production sur simple fusion. Le
    déploiement laisse une trace nominative.

11. **Runners isolés pour les tâches privilégiées.** Un runner partagé qui déploie
    en production est joignable par tout projet autorisé à l'utiliser. Runner
    dédié, étiqueté, restreint aux projets protégés, sans mode privilégié.

12. **Provenance de l'artefact.** SBOM générée à la construction, image signée,
    déploiement par digest. C'est ce qui permet de répondre « qu'est-ce qui tourne
    exactement en production ? » lors de la publication d'une vulnérabilité.

## Références — charger à la demande

| Fichier | Contenu |
|---|---|
| `references/gitlab-ci.md` | Pipeline GitLab durci complet, `id_tokens` OIDC, variables protégées/masquées, `rules` et contributions externes, runners, scanners intégrés |
| `references/github-actions.md` | Workflow durci complet, `permissions`, OIDC, épinglage par SHA, `pull_request_target`, injection de script, environnements protégés |
| `references/supply-chain.md` | Épinglage et reproductibilité, SBOM, signature cosign, vérification à l'admission, détection de secrets sur l'historique |

## Résoudre un SHA d'action à épingler

Ne jamais inventer un SHA. Le résoudre, et vérifier le type de l'objet :

```bash
curl -sS -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/actions/checkout/git/ref/tags/v4
```

```json
{ "ref": "refs/tags/v4",
  "object": { "sha": "11d5960a326750d5838078e36cf38b85af677262", "type": "commit" } }
```

Si `"type": "commit"`, ce SHA s'épingle directement. Si `"type": "tag"` (tag
annoté), il désigne l'objet tag et **non** le commit : le déréférencer via
`object.url` avant d'épingler, sinon la référence est invalide.

Avec le CLI GitHub, quand il est disponible :

```bash
gh api repos/actions/checkout/git/ref/tags/v4 --jq '.object | "\(.type) \(.sha)"'
```

Écrire ensuite le SHA avec la version en commentaire — le commentaire est ce qui
rend la mise à jour lisible en revue :

```yaml
- uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
```

Automatiser la mise à jour des SHA avec Dependabot ou Renovate : l'épinglage sans
mécanisme de mise à jour produit des actions figées et vulnérables.

## Contrôle avant livraison (obligatoire)

```bash
# 1. Aucune action référencée par tag ou par branche
grep -rnE 'uses:\s*[^@]+@(v[0-9]|main|master)' .github/workflows/ && echo "NON ÉPINGLÉ" || echo "épinglé"

# 2. Aucun déclencheur exécutant du code externe avec les secrets
grep -rn 'pull_request_target\|workflow_run' .github/workflows/

# 3. Permissions déclarées explicitement
grep -rn 'permissions:' .github/workflows/ || echo "AUCUNE PERMISSION DÉCLARÉE — défaut trop large"

# 4. Aucun secret littéral dans les pipelines
git grep -nIE '(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|glpat-[A-Za-z0-9_-]{20}|-----BEGIN)' -- .github .gitlab-ci.yml

# 5. Aucune interpolation d'entrée utilisateur dans un script
grep -rnE '\$\{\{\s*github\.event\.(pull_request\.title|pull_request\.body|issue\.title|comment\.body|head_ref)' .github/workflows/

# 6. Validation syntaxique GitLab (nécessite un jeton d'API)
# glab ci lint  --  ou l'éditeur de pipeline de l'interface web
```

Liste à cocher sur le pipeline réellement écrit :

- [ ] Authentification cloud par OIDC ; aucune clé statique en variable.
- [ ] Le rôle côté fournisseur contraint le dépôt **et** la branche/l'environnement.
- [ ] `permissions` déclarées au minimum, élargies par job seulement si nécessaire.
- [ ] Toutes les actions épinglées par SHA de commit, avec la version en commentaire.
- [ ] Toutes les images de conteneur épinglées par digest.
- [ ] Les jobs tournant sur une contribution externe n'ont accès à aucun secret.
- [ ] Aucune interpolation de champ contrôlé par l'utilisateur dans un `run`/`script`.
- [ ] Scans secrets + dépendances + SAST + image, bloquants au niveau défini.
- [ ] Déploiement en production manuel, sur environnement protégé, par digest.
- [ ] Artefacts contenant des données sensibles : expiration courte, accès restreint.
- [ ] Concurrence maîtrisée : deux déploiements ne peuvent pas s'exécuter en parallèle.

## Ce qu'un pipeline vert ne prouve pas

Un scanner peut sortir en succès après avoir échoué à charger ses règles (proxy
d'entreprise, quota d'API, image de scanner obsolète) : la couverture est réduite,
le code de retour reste 0. Lire les avertissements du journal de scan, et vérifier
qu'un rapport non vide est bien produit et publié comme artefact — un contrôle
dont la sortie « rien trouvé » est identique à la sortie « n'a pas tourné » n'a
rien vérifié.
