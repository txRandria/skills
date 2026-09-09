# Phase 6 — remédiation

Cette phase n'existe qu'après validation explicite du client sur la liste des
constats et l'ordre des corrections. Trois règles la gouvernent :

1. **Une correction n'est acquise que prouvée par son effet**, pas par le succès
   de la commande qui l'a appliquée.
2. **Vérifier qu'une remédiation est réalisable avant de la promettre.**
3. **Une correction à la fois**, avec sa vérification, avant la suivante. Deux
   changements simultanés rendent un échec inattribuable.

Avant toute écriture : sauvegarde vérifiée, fenêtre de retour arrière définie,
et — sur un serveur potentiellement compromis — accord du client sur le fait que
l'écriture détruira des traces.

## Rotation de secret

### Le piège

Les variables d'environnement définissant un compte d'administration ne sont lues
qu'à la **toute première initialisation** du magasin de données. Sur une
installation existante, recréer le conteneur avec de nouvelles valeurs ne change
rien : le compte d'usine et son mot de passe trivial restent valides. Sans test
explicite, la rotation est comptée comme faite alors qu'elle ne l'est pas.

### Protocole

```bash
# 1. AVANT : prouver que l'ancien secret fonctionne (sinon on ne saura rien prouver après)
curl -s -o /dev/null -w 'ancien: %{http_code}\n' -u admin:<ancien> https://<cible>/<admin>

# 2. Changer le secret PAR L'OUTIL D'ADMINISTRATION DU PRODUIT,
#    pas par la variable d'environnement.

# 3. APRÈS : l'ancien doit être REFUSÉ
curl -s -o /dev/null -w 'ancien: %{http_code} (attendu 401/403)\n' -u admin:<ancien> https://<cible>/<admin>

# 4. APRÈS : le nouveau doit être ACCEPTÉ
curl -s -o /dev/null -w 'nouveau: %{http_code} (attendu 200)\n' -u admin:<nouveau> https://<cible>/<admin>
```

Les quatre étapes sont nécessaires. Sans l'étape 1, un « 401 » à l'étape 3 peut
signifier que le compte n'a jamais existé sous ce nom. Sans l'étape 4, on a peut-être
seulement cassé l'authentification.

**Une rotation n'est acquise que lorsque l'ancien secret est prouvé refusé.**

Prévoir que les outils d'administration comportent des défauts : dans le cas
observé, la commande de mise à jour du mot de passe échouait ; le contournement a
été de créer un nouveau compte, d'y migrer les données rattachées, puis de
supprimer l'ancien. Vérifier alors que l'ancien compte n'existe plus, pas
seulement qu'il est désactivé.

### Portée de la rotation

Un secret exposé est compromis, pas « à changer un jour ». Énumérer tout ce qui a
pu être atteint avec lui, et tout ce qui le contient encore :

- copies dans les fichiers de configuration, y compris les vestiges non montés ;
- historique des shells (`~/.bash_history`) ;
- variables d'environnement des processus en cours (le changement n'atteint pas un
  processus déjà démarré : redémarrer) ;
- sauvegardes contenant l'ancienne valeur ;
- variables de CI, coffres, documentation interne.

## Suppression en masse d'enregistrements

### Le piège

Des motifs de sélection jugés très spécifiques ont capturé des enregistrements
légitimes du produit, parce qu'ils contenaient des caractères qui sont des
**jokers** dans le langage de correspondance utilisé — en SQL, le tiret bas `_`
remplace un caractère quelconque, `%` une chaîne quelconque. La sélection était
plus large que sa lecture ne le suggérait. Un enregistrement légitime a été
détecté et exclu de justesse avant la suppression.

### Protocole

```sql
-- 1. COMPTER avant de supprimer, avec le motif exact envisagé
SELECT count(*) FROM <table> WHERE <colonne> LIKE 'prefixe\_malveillant%' ESCAPE '\';

-- 2. LISTER intégralement ce qui serait supprimé, et le relire ligne à ligne
SELECT id, <colonne>, create_date, create_uid
FROM <table> WHERE <colonne> LIKE 'prefixe\_malveillant%' ESCAPE '\'
ORDER BY create_date;

-- 3. Préférer une correspondance littérale à un motif quand c'est possible
SELECT count(*) FROM <table> WHERE <colonne> = ANY(ARRAY['<valeur1>','<valeur2>']);

-- 4. Garde-fou structurel : exclure les objets fournis par le produit ou ses modules
--    (adapter le critère au produit : présence d'un identifiant externe, d'un
--    module d'origine, d'un indicateur « système »)
... AND id NOT IN (SELECT res_id FROM ir_model_data WHERE model = '<modele>')
```

Échapper les jokers (`ESCAPE`), ou utiliser un opérateur de correspondance
littérale. Un filtre de sélection est du code : il se vérifie sur les données
réelles avant de servir à détruire.

### Preuve après suppression

La relecture du critère ne prouve rien. La preuve s'obtient par comparaison
avant/après :

1. Sauvegarder avant la suppression.
2. Supprimer.
3. Restaurer la sauvegarde dans un emplacement temporaire.
4. Énumérer un à un les enregistrements présents dans la sauvegarde et absents de
   la base courante.
5. Confirmer que chacun était bien une cible, et qu'aucun élément légitime n'a été
   touché.

## Réduction de privilèges

Voir `privileges-bdd.md` pour le cas où l'attribut est structurellement
irrévocable — la remédiation consiste alors à changer d'identité, pas d'attribut.

Vérification après bascule :

```sql
-- Aucun objet applicatif ne doit rester rattaché à l'ancien compte
SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE pg_get_userbyid(c.relowner) = '<ancien>'
  AND n.nspname NOT IN ('pg_catalog','information_schema');
-- attendu : 0
```

Puis vérifier que l'application fonctionne toujours sous le nouveau compte —
une réduction de privilèges qui casse la production sera annulée en urgence, donc
n'aura servi à rien.

## Règles de filtrage réseau

Voir `exposition-reseau.md` pour la vérification. Trois points spécifiques à la
remédiation :

- Poser la règle dans la chaîne que le trafic **traverse réellement** — pour des
  services conteneurisés, la chaîne dédiée aux règles de l'opérateur, pas la
  chaîne d'entrée.
- Vérifier par les **compteurs de paquets**, pas par le succès de la commande.
- Vérifier la **persistance après redémarrage du démon** de conteneurs, qui purge
  ses chaînes : une règle qui disparaît silencieusement est pire qu'une règle
  absente, parce qu'elle est comptée comme appliquée.

```bash
systemctl restart docker      # fenêtre de maintenance requise
iptables -S DOCKER-USER | grep '<ip-bloquee>' || echo "RÈGLE PERDUE au redémarrage"
```

## Protections interposées

Une protection interposée (reverse proxy durci, filtre applicatif) n'est effective
qu'une fois le chemin direct fermé. L'ordre est imposé :

1. Déployer et vérifier la protection sur son propre chemin.
2. Vérifier que le trafic légitime passe bien par elle.
3. **Fermer le chemin direct.**
4. Re-mesurer depuis l'extérieur : le port direct doit être refusé.

Tant que l'étape 3 n'est pas faite, la mesure est *préparée*, pas *appliquée*, et
se rapporte comme telle. Ne jamais la compter parmi les mesures en place.

## Journal de remédiation

Une ligne par action, avec sa preuve. C'est le livrable de la phase 6, et ce qui
permet de répondre plus tard à « qu'est-ce qui a été changé sur ce serveur ? ».

```
2026-09-09T14:05Z  Rotation du compte admin de la console X
                   Preuve : ancien identifiant -> 401 ; nouveau -> 200 (captures jointes)
                   Retour arrière : néant (l'ancien secret est compromis)

2026-09-09T14:40Z  Fermeture du port 8069 direct (publication limitée à 127.0.0.1)
                   Preuve : nmap depuis <ip-externe> : 8069 filtré ; 443 ouvert ;
                            application joignable par le proxy (code 200)
                   Retour arrière : rétablir la publication 0.0.0.0:8069 dans compose

2026-09-09T15:10Z  NON APPLIQUÉ — retrait de l'attribut superutilisateur du rôle applicatif
                   Motif : compte d'initialisation, retrait refusé par le moteur.
                   Proposition : création d'un rôle applicatif distinct + transfert
                   de propriété (charge estimée : 1 j, fenêtre requise).
```

Les actions **non appliquées** figurent au même titre que les autres, avec leur
motif technique. Un plan de remédiation dont on ignore ce qui n'a pas été fait est
inutilisable.
