---
name: security-audit-review
description: Relire de manière critique un rapport d'audit de sécurité produit par un outil ou un tiers (SAST, SCA, scan d'infrastructure, OWASP LLM, pentest automatisé) avant d'agir dessus — instruire chaque constat contre le code réel, valider l'applicabilité au mécanisme employé, vérifier que la remédiation prescrite est à jour et maintenue, dédupliquer les détections redondantes, séparer vulnérabilités atomiques et scénarios corrélés, puis recalculer le score et la décision de mise en production. À utiliser dès qu'un rapport d'audit, un rapport de scan ou une liste de constats de sécurité arrive et doit être traité. Ne pas utiliser pour produire l'audit lui-même (voir secure-coding, server-security-audit).
---

# Security Audit Review

**Créé par Tahina Fabien**

Skill open-source. Il traite le rapport d'audit pour ce qu'il est : une liste
d'hypothèses à instruire, pas une liste de tâches à exécuter.

**Licence :** CC BY 4.0 — partage et adaptation libres avec attribution.

**Retours :** si la méthodologie pose question ou si un retour constructif est
formulé sur une sortie produite par ce skill, le consigner et proposer de le
partager avec l'auteur. Si le problème vient de l'agent qui n'a pas suivi les
règles du skill, le reconnaître et corriger.

**Dépôt :** https://github.com/txRandria/skills — signaler un problème de méthodologie via une issue publique bénéficie à tous les utilisateurs du skill.

---

## Pourquoi ce skill existe

Trois choses sont indépendamment faillibles dans un rapport d'audit automatisé :

1. **Que le défaut existe** — la règle peut ne pas s'appliquer au mécanisme
   réellement employé.
2. **Que la correction proposée soit la bonne** — le paquet prescrit peut être
   abandonné, la version indiquée peut ne pas exister.
3. **Que le décompte soit juste** — et c'est le décompte qui décide seul, la
   plupart du temps, du feu vert de mise en production.

Cas réel : les deux seuls constats « ÉLEVÉ » d'un rapport étaient le même faux
positif, compté une fois par domaine d'audit. Ce doublon déclenchait
mécaniquement une décision « GO CONDITIONNEL ». Appliquer sa remédiation aurait
ajouté au projet une dépendance archivée depuis plusieurs années pour couvrir un
risque inexistant.

**Appliquer une remédiation sans vérifier l'applicabilité du constat ajoute du
risque au lieu d'en retirer.**

## Ordre imposé

Ne pas corriger avant d'avoir instruit. Ne pas publier de score avant d'avoir
réconcilié. Chaque phase produit une sortie écrite ; on ne passe pas à la suivante
sans elle.

| Phase | Objet | Sortie |
|---|---|---|
| 1 | Inventaire des constats | Tableau identifiant → emplacement → sévérité déclarée |
| 2 | Cohérence interne du rapport | Liste des contradictions sévérité / prose / plan |
| 3 | Déduplication | Constats fusionnés, avec le motif de fusion |
| 4 | Applicabilité au code réel | Verdict par constat : confirmé / non applicable / à préciser |
| 5 | Validité de la remédiation | Correctif retenu, ou correctif de remplacement |
| 6 | Recomptage et décision | Score recalculé, liste réconciliée, décision motivée |
| 7 | Correction | Une correction, une preuve, à la fois |

## Phase 1 — inventaire

Extraire du rapport, sans interprétation :

| ID | Titre | Fichier:ligne | Règle / outil | Domaine | Sévérité déclarée |
|---|---|---|---|---|---|

Le domaine compte (SAST, SCA, infrastructure, conteneur, LLM…) : c'est l'axe le
long duquel un même défaut est le plus souvent compté deux fois.

## Phase 2 — cohérence interne

Un rapport se contredit fréquemment entre ses tableaux, sa synthèse et son plan de
remédiation. Constaté : une absence de protection CSRF classée « élevée » dans les
tableaux, décrite comme « critique » dans la synthèse et dans le plan.

Contrôles :

- [ ] Chaque identifiant porte **une** sévérité. Comparer toutes ses occurrences
      narratives (tableau, synthèse, plan, annexe).
- [ ] Le total annoncé correspond au nombre de lignes du tableau.
- [ ] Le score global se recalcule à partir des sévérités listées.
- [ ] La décision annoncée (GO / NO-GO / conditionnel) découle de règles énoncées,
      et non d'un seuil implicite.

Toute divergence est notée. Ne pas la corriger silencieusement : elle indique
souvent que le rapport a été assemblé depuis plusieurs sources sans réconciliation,
et que d'autres incohérences suivent.

## Phase 3 — déduplication

Deux constats fusionnent quand ils partagent **emplacement, mécanisme et
correctif**. Constaté : une même faiblesse de traversée de chemin comptée deux
fois parce que deux règles distinctes du même outil l'avaient détectée au même
endroit.

```
Critère de fusion :
  même fichier:ligne (ou même fonction)
  ET même mécanisme sous-jacent
  ET un seul correctif les fait disparaître toutes les deux
```

Trois motifs de doublon à chercher systématiquement :

1. **Deux règles, un défaut** — le même emplacement remonté par deux règles.
2. **Deux domaines, un défaut** — le même défaut compté en SAST et en
   infrastructure, ou en SCA et en conteneur.
3. **Scénario recompté** — voir phase 6.

Sortie : la liste fusionnée, avec pour chaque fusion les identifiants d'origine et
le motif. Ne jamais supprimer un identifiant sans trace : le client doit pouvoir
retrouver ce qu'est devenu chaque ligne du rapport initial.

## Phase 4 — applicabilité au code réel

**Le cœur du skill.** Chaque constat est une hypothèse à confronter au code.

Pour chaque constat, répondre à : *le mécanisme que cette règle suppose est-il
celui que l'application emploie réellement ?*

```bash
# Instruire, ne pas croire : ouvrir le fichier à la ligne citée
sed -n '<ligne-5>,<ligne+15>p' <fichier>
# Puis chercher le mécanisme que la règle présuppose
grep -rn 'cookie\|session\|Authorization' server/ --include='*.js' | head -20
```

Verdicts possibles, un seul par constat :

- **CONFIRMÉ** — le défaut existe, avec un scénario d'exploitation concret écrit.
- **NON APPLICABLE** — la règle suppose un mécanisme absent. Justification
  technique obligatoire.
- **À PRÉCISER** — l'information manque pour trancher ; dire laquelle.

Un constat écarté sans justification technique écrite est un constat non traité :
il reviendra au prochain audit, et le doute avec lui.

Les motifs de non-applicabilité les plus fréquents, par famille de règle, sont
dans `references/faux-positifs.md`.

## Phase 5 — validité de la remédiation

Le rapport peut avoir raison sur le défaut et tort sur la correction. Trois
vérifications, sur chaque remédiation prescrite :

```bash
# 1. Le paquet recommandé est-il maintenu ?
npm view <paquet> time.modified deprecated maintainers
pip index versions <paquet> 2>/dev/null
composer show <paquet> --all 2>/dev/null | head -20

# 2. La version indiquée existe-t-elle, et corrige-t-elle l'avis ?
npm view <paquet> versions --json | tail -20
npm audit --json | head -40

# 3. Le paquet est-il seulement utilisé ?
grep -rn "require(['\"]<paquet>\|from ['\"]<paquet>" --include='*.js' --include='*.ts' . | head
```

Constaté sur un même rapport : un middleware prescrit pointant vers un paquet
archivé depuis plusieurs années ; deux constats prescrivant une montée vers un
numéro de version que le gestionnaire de paquets contredisait ; et un constat
visant un paquet qui n'était importé nulle part — où la bonne action était la
**suppression**, pas la mise à jour.

Sortie par constat confirmé : le correctif retenu, qui peut différer de celui
prescrit, avec le motif du remplacement.

## Phase 6 — recomptage et décision

### Séparer les vulnérabilités des scénarios

Un scénario d'attaque qui enchaîne trois constats existants **n'est pas une
quatrième vulnérabilité**. Constaté : un scénario d'infrastructure agrégeant CSRF,
traversée de chemin et exécution en root, recompté comme constat « élevé »
distinct — donc pesant une seconde fois sur le score.

```
Vulnérabilités atomiques (comptées) :
  V-01  Traversée de chemin        ÉLEVÉ     confirmé
  V-02  Conteneur en root          MOYEN     confirmé

Scénarios corrélés (NON comptés, renvoient aux identifiants) :
  S-01  Écriture arbitraire puis exécution : V-01 + V-02
        Gravité du scénario : ÉLEVÉ — utilisée pour PRIORISER, pas pour compter.
```

Le scénario sert à ordonner les corrections, pas à gonfler le total.

### Score recalculé

Recalculer à partir de la seule liste réconciliée : constats confirmés,
dédupliqués, hors scénarios. Publier côte à côte :

| | Rapport initial | Après instruction |
|---|---|---|
| Critiques | 0 | 0 |
| Élevés | 2 | 0 |
| Moyens | 5 | 3 |
| Décision | GO conditionnel | GO |

Et l'explication de l'écart, ligne à ligne. C'est ce tableau que le décideur lit.

## Phase 7 — correction

Une correction, sa preuve, puis la suivante. Valider chaque correctif **sur le cas
signalé**, jamais sur un cas sain : un contrôle éprouvé sur un cas dont l'issue
n'était pas connue à l'avance ne prouve rien.

Pour le détail par langage, charger le skill `secure-coding`.

## Contrôle avant livraison (obligatoire)

- [ ] Chaque constat du rapport initial a un verdict écrit : confirmé, non
      applicable (avec motif technique), ou à préciser (avec l'information
      manquante).
- [ ] Chaque identifiant porte une sévérité unique, cohérente entre tableaux et
      prose.
- [ ] Les doublons sont fusionnés, avec les identifiants d'origine conservés.
- [ ] Les scénarios corrélés sont séparés des vulnérabilités atomiques et ne sont
      pas comptés dans le total.
- [ ] Chaque remédiation retenue a été vérifiée : paquet maintenu, version
      existante, correctif effectif sur l'avis visé.
- [ ] Le score et la décision sont recalculés depuis la liste réconciliée, avec le
      tableau d'écart avant/après.
- [ ] Aucun correctif n'a été appliqué avant que son constat ne soit confirmé.

## Ce qu'un rapport d'outil ne peut pas dire

Un outil compte des **alertes**. Un rapport de risque doit compter des **causes
racines**. Entre les deux, il y a exactement le travail décrit ici.

Et symétriquement : un rapport propre ne prouve pas l'absence de défaut. Les
règles couvrent ce qu'elles couvrent. Énumérer les angles morts — logique métier,
autorisation sur l'objet, chaînes multi-composants, configuration de production —
dans la restitution, plutôt que de laisser un score rassurant tenir lieu de
conclusion.
