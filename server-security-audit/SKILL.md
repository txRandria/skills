---
name: server-security-audit
description: Auditer la sécurité d'un serveur en fonctionnement — vérification d'accès, inventaire en lecture seule, posture de sécurité, mesure de l'exposition réseau réelle, privilèges des comptes de service, recherche d'indicateurs de compromission — puis produire un constat et un plan de remédiation vérifié. À utiliser pour l'onboarding d'un serveur dans un parc, un audit de sécurité sur accès SSH, une réponse à incident, ou la vérification qu'une mesure de durcissement déployée est réellement effective. Ne pas utiliser pour l'audit de code source (voir secure-coding) ni pour la relecture d'un rapport d'audit déjà produit (voir security-audit-review).
---

# Server Security Audit

**Créé par Tahina Fabien**

Skill open-source. Il fige la séquence d'audit d'un serveur en fonctionnement et,
surtout, la frontière entre constat et intervention — la partie qui se dégrade
quand la séquence est improvisée.

**Licence :** CC BY 4.0 — partage et adaptation libres avec attribution.

**Retours :** si la méthodologie pose question ou si un retour constructif est
formulé sur une sortie produite par ce skill, le consigner et proposer de le
partager avec l'auteur. Si le problème vient de l'agent qui n'a pas suivi les
règles du skill, le reconnaître et corriger.

**Dépôt :** https://github.com/txRandria/skills — signaler un problème de méthodologie via une issue publique bénéficie à tous les utilisateurs du skill.

---

## La règle qui gouverne tout le reste

**Un audit est un acte de constat, pas d'intervention.** Les phases 1 à 4 sont
strictement en lecture seule. Aucune modification n'est appliquée sur un serveur
tiers pendant la collecte, même face à un défaut évident, même « pendant qu'on y
est ». La remédiation est une phase distincte, validée, avec ses propres
vérifications.

Deux raisons, également décisives : une modification pendant la collecte rend
impossible de distinguer ce qui a été observé de ce qui a été changé ; et sur un
serveur potentiellement compromis, elle détruit les traces.

## Les 8 principes de vérification

Ils s'appliquent à chaque phase et sont ce qui distingue un audit d'une lecture de
fichiers de configuration.

1. **Auditer l'état exécuté, jamais l'état versionné.** Un fichier de
   configuration présent sur l'hôte peut n'être monté nulle part. Relire la
   configuration depuis le contexte qui la consomme réellement — l'intérieur du
   conteneur, le processus, la base — avant de classer une vulnérabilité.

2. **L'exposition réseau se mesure, elle ne se lit pas.** Une politique de
   pare-feu déclarée n'est pas une exposition constatée. Tester l'atteignabilité
   depuis une machine hors du serveur, et rapporter l'écart comme un constat à
   part entière.

3. **Un contrôle se vérifie par son effet, pas par son vocabulaire.** Chercher le
   mot attendu dans une sortie de haut niveau vérifie une convention de nommage.
   Inspecter l'état de bas niveau — règles installées, compteurs de paquets,
   ordre des chaînes — vérifie le comportement.

4. **Quand le vérificateur contredit le vérifié, suspecter le vérificateur.**
   Confirmer par une seconde méthode indépendante avant de conclure à une
   défaillance. Un faux négatif coûte double : du temps, puis le réflexe de ne
   plus croire l'alerte suivante.

5. **L'absence de preuve n'est pas une preuve d'absence.** Un inventaire statique
   ne peut pas conclure « pas de compromission ». La formulation correcte est
   « aucun indicateur trouvé par ces méthodes », suivie de la liste des méthodes.

6. **La gravité se mesure à ce qu'un accès permet, pas à sa difficulté
   d'obtention.** Auditer les privilèges effectifs d'un compte de service avec la
   même rigueur que ses identifiants.

7. **Une protection ne vaut que sur le chemin réellement emprunté.** Tant qu'un
   contournement subsiste, la mesure est *préparée*, pas *appliquée* — et se
   rapporte comme tâche ouverte, jamais parmi les mesures en place.

8. **Ne jamais tester un capteur en endommageant ce qu'il protège.** Déclencher
   l'événement sur une ressource jetable placée dans le périmètre surveillé donne
   la même preuve, à risque nul.

## Séquence

| Phase | Objet | Écriture autorisée |
|---|---|---|
| 0 | Cadrage : périmètre, autorisation, fenêtre, contacts | non |
| 1 | Vérification d'accès : joignabilité, puis authentification | non |
| 2 | Inventaire : système, matériel, réseau, services, comptes | non |
| 3 | Posture : configuration effective, privilèges, exposition mesurée | non |
| 4 | Indicateurs de compromission, dont observation dynamique | non |
| 5 | Restitution : constats, gravité, scénarios | non |
| 6 | Remédiation, après validation explicite | oui, avec vérification |

Ne jamais fusionner 5 et 6. Le client valide l'ordre des corrections ; ce n'est
pas la décision de l'auditeur.

## Phase 0 — cadrage, avant toute connexion

À établir par écrit :

- Quels hôtes, quelles adresses, quelle fenêtre horaire.
- Qui autorise, et l'autorisation couvre-t-elle le test d'exposition depuis
  l'extérieur (un balayage de ports est une action visible et parfois contractuelle).
- Le serveur est-il en production ? Y a-t-il un témoin (serveur identique non
  modifié) disponible pour comparaison ?
- Existe-t-il une sauvegarde récente et testée ? Sans elle, la phase 6 change de
  nature.
- Quelles anomalies ont motivé l'audit, avec leur périodicité si elle est connue —
  c'est l'entrée de la phase 4.

## Phase 1 — vérification d'accès

Ordre imposé : la joignabilité du port se teste **avant** toute tentative
d'authentification. Un échec d'authentification sur un port fermé est
indiscernable d'un mauvais identifiant, et fait perdre le premier diagnostic.

```bash
# 1. Joignabilité TCP, sans authentification
nc -zv -w 5 <hote> 22

# 2. Bannière du service, sans s'authentifier
ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new <hote> 2>&1 | head -3

# 3. Authentification
ssh -o ConnectTimeout=10 -o BatchMode=yes <user>@<hote> 'echo OK'
```

Sur plusieurs hôtes, exécuter en parallèle avec une bibliothèque SSH plutôt qu'un
client interactif : un client interactif bloque sur une invite et le lot s'arrête.

Consigner pour chaque hôte : joignable / authentifié / privilèges obtenus. Un hôte
inaccessible est un constat, pas un échec de l'audit.

## Phases 2 à 6 — références

Charger le fichier de la phase en cours, pas l'ensemble.

| Fichier | Phase | Contenu |
|---|---|---|
| `references/reconnaissance.md` | 2 | Batteries de commandes en lecture seule : système, réseau, services, comptes, planification, paquets |
| `references/exposition-reseau.md` | 3 | Mesure de l'exposition depuis l'extérieur, chaînes de filtrage contournées par les conteneurs, vérification d'un bannissement |
| `references/config-effective.md` | 3 | Configuration réellement appliquée vs fichier de l'hôte, conteneurs, couche inscriptible, secrets matérialisés |
| `references/privileges-bdd.md` | 3 | Attributs de rôle, primitives d'exécution depuis un moteur de base, comptes d'initialisation |
| `references/compromission.md` | 4 | Indicateurs, observation dynamique d'un cycle complet, où la charge se cache réellement |
| `references/remediation.md` | 6 | Suppression en masse sûre, rotation de secrets prouvée, réduction de privilèges réalisable, réapplication des règles volatiles |
| `references/restitution.md` | 5 | Format des constats, gravité, ce qu'on ne peut pas conclure |

## Contrôle avant livraison (obligatoire)

Relire cette liste avant d'envoyer le rapport :

- [ ] Aucune modification n'a été appliquée pendant les phases 1 à 4. Si une l'a
      été, elle est explicitement listée en tête du rapport.
- [ ] Chaque constat de configuration a été validé depuis le contexte d'exécution
      qui lit réellement cette configuration.
- [ ] L'exposition réseau a été **mesurée depuis l'extérieur**, pas déduite de la
      politique de pare-feu.
- [ ] Les privilèges des comptes de service (système et base de données) ont été
      relevés, pas seulement la robustesse de leurs mots de passe.
- [ ] Chaque protection listée comme « en place » a été vérifiée sur le chemin
      réel du trafic ; celles qui sont contournables sont listées comme
      « préparées, non effectives ».
- [ ] La conclusion sur la compromission est formulée en « aucun indicateur trouvé
      par ces méthodes : … », jamais en « pas de compromission ».
- [ ] Les recommandations sont des propositions datées et priorisées, non des
      actions déjà appliquées.
- [ ] Toute mesure de performance citée s'accompagne d'une référence mesurée dans
      le même régime (voir la note ci-dessous).

## Note sur les chiffres de performance

Un chiffre sans référence mesurée dans le même régime n'informe pas : il mesure le
système et l'instrument confondus. Avant d'annoncer une conclusion de performance
— surcoût d'un tunnel chiffré, latence d'un chemin réseau, coût d'une protection —
il faut deux choses : un chemin de comparaison mesuré dans des conditions
identiques, et un régime de sollicitation qui ressemble à l'usage réel (requête
isolée, pas rafale à cadence maximale).

Ne pas annoncer avant d'avoir la référence. Deux corrections successives d'une
même mesure coûtent plus de crédibilité qu'une mesure attendue.
