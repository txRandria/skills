# Phase 3 — mesurer l'exposition réseau

## Le constat qui motive ce fichier

Sur un hôte publiant des services par un moteur de conteneurs, `ufw status`
affichait `deny incoming` avec seulement 22/80/443 autorisés — et six services
conteneurisés étaient joignables depuis Internet. La politique était lue
correctement ; elle ne décrivait simplement pas le chemin emprunté par le trafic.

Cause : le moteur de conteneurs insère ses propres règles de traduction d'adresse
**en amont** de la chaîne où le pare-feu applicatif écrit. Le trafic vers un port
publié est redirigé puis routé — il ne traverse jamais la chaîne d'entrée où la
politique est déclarée.

Conséquence de méthode : **la politique déclarée n'est pas probante**. Seule une
observation depuis l'extérieur du périmètre fait foi.

## Étape 1 — inventorier ce qui écoute (sur l'hôte)

```bash
ss -tulpn
ss -tulpn | grep -E '0\.0\.0\.0:|\*:|\[::\]:' || echo "aucun socket sur toutes interfaces"
```

Un socket lié à `127.0.0.1` n'est pas exposable ; un socket lié à `0.0.0.0` ou
`::` est candidat. Cette liste est l'entrée de l'étape 3, pas une conclusion.

Pour les conteneurs, la publication est visible côté moteur :

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}'
```

`0.0.0.0:5432->5432/tcp` publie sur toutes les interfaces de l'hôte.
`127.0.0.1:5432->5432/tcp` ne publie que localement. La distinction est le
constat ; la mesure externe est la preuve.

## Étape 2 — lire la politique déclarée (sans conclure)

```bash
ufw status verbose 2>/dev/null
firewall-cmd --list-all 2>/dev/null
iptables -S 2>/dev/null
iptables -t nat -S 2>/dev/null      # la chaîne où le moteur de conteneurs écrit
nft list ruleset 2>/dev/null | head -60
```

Sur un hôte avec conteneurs, inspecter explicitement les chaînes du moteur
(`DOCKER`, `DOCKER-USER`, `DOCKER-ISOLATION-*`) et leur **ordre relatif** par
rapport aux chaînes du pare-feu applicatif. L'ordre est l'information : une règle
correcte placée après la redirection ne voit passer aucun paquet.

Rapporter cette lecture comme « politique déclarée », jamais comme « exposition ».

## Étape 3 — mesurer depuis l'extérieur (obligatoire, non substituable)

Depuis une machine **hors du serveur**, hors de son réseau local :

```bash
# Balayage des ports courants + ceux relevés à l'étape 1
nmap -Pn -sT -p 22,80,443,3000,3306,5432,5601,6379,8000,8069,8080,9000,9200,27017 <ip-cible>

# Vérification ciblée, sans nmap
for p in 22 80 443 5432 6379 8069; do
  timeout 3 bash -c "echo > /dev/tcp/<ip-cible>/$p" 2>/dev/null \
    && echo "OUVERT   $p" || echo "fermé    $p"
done
```

Le balayage de ports est une action visible et parfois encadrée
contractuellement : vérifier que la phase 0 l'a couvert avant de le lancer.

**Livrable de cette étape : le tableau d'écart.**

| Port | Écoute (hôte) | Politique déclarée | Mesuré depuis l'extérieur | Écart |
|---|---|---|---|---|
| 22 | 0.0.0.0 | autorisé | ouvert | conforme |
| 5432 | 0.0.0.0 (conteneur) | non autorisé | **ouvert** | **contournement du pare-feu** |
| 6379 | 127.0.0.1 | non autorisé | fermé | conforme |

La colonne « Écart » est le constat. Les trois autres ne sont que des mesures.

## Étape 4 — vérifier qu'un blocage bloque réellement

Poser une règle et constater le succès de la commande ne prouve rien. Deux
vérifications, dans l'ordre :

### 4a. La règle est-elle dans la chaîne que le trafic traverse ?

```bash
# Où la règle a-t-elle atterri ?
iptables -S | grep -n '<ip-de-test>'
iptables -t nat -S | grep -n '<ip-de-test>'
# Pour les services conteneurisés, la chaîne prévue pour les règles de l'opérateur
iptables -S DOCKER-USER
```

`DOCKER-USER` est la chaîne traversée par le trafic vers les conteneurs et
préservée par le moteur : c'est là que les règles de blocage doivent aller, pas
dans la chaîne d'entrée.

### 4b. Les compteurs de paquets augmentent-ils ?

```bash
iptables -L INPUT -v -n --line-numbers | head -20
iptables -L DOCKER-USER -v -n --line-numbers
# Générer du trafic depuis la source visée, puis relire : les colonnes pkts/bytes
# de la règle doivent avoir augmenté.
```

Un compteur qui reste à zéro alors que la source émet signifie que le paquet ne
traverse pas cette règle. C'est le seul test qui distingue une règle *posée* d'une
règle *appliquée*.

### 4c. Test de bout en bout, sur une adresse jetable

```bash
# Depuis la machine externe, avant : le port répond
timeout 3 bash -c 'echo > /dev/tcp/<cible>/443' && echo "avant: ouvert"
# Bannir l'adresse de la machine externe, puis re-tester : elle doit être refusée
# Retirer la règle immédiatement après.
```

Bannir une adresse de test puis la retirer donne la preuve directe. Ne jamais
laisser la règle de test en place.

## Étape 5 — outil de bannissement automatique

### Le piège de vocabulaire

Vérifier un bannissement en comptant les occurrences de `deny` dans la sortie du
pare-feu a produit `0` alors que plusieurs adresses étaient effectivement
bloquées : l'action de bannissement écrivait des règles `REJECT`, pas `deny`. Le
contrôle testait un vocabulaire supposé, pas l'effet recherché.

```bash
# FAIBLE : teste une convention de nommage
ufw status | grep -c deny

# JUSTE : teste l'état de bas niveau, quel que soit le mot employé
fail2ban-client status
fail2ban-client status sshd            # liste nommément les IP bannies
iptables -S | grep -cE 'REJECT|DROP'   # règles effectivement installées
```

Puis croiser : chaque adresse listée par l'outil de bannissement doit apparaître
dans une règle installée, et cette règle doit être dans une chaîne traversée.

### Règle de conduite

Quand un contrôle de vérification contredit l'outil qu'il vérifie, l'hypothèse par
défaut est que **le contrôle est faux**. Le confirmer par une seconde méthode
indépendante avant de conclure à une défaillance. Un faux négatif coûte deux fois :
le temps perdu, puis le réflexe d'écarter la prochaine alerte du même contrôle
comme un nouveau faux positif.

### Volatilité des règles

Le moteur de conteneurs purge sa chaîne de points d'accroche à chaque redémarrage
du démon : les règles ajoutées à la main disparaissent silencieusement. Toute
règle posée hors d'un mécanisme persistant doit être :

- soit placée dans une chaîne préservée (`DOCKER-USER`),
- soit gérée par un service qui la réapplique au démarrage,
- soit inscrite au rapport comme **temporaire**, avec sa date d'expiration
  effective.

Vérifier après un redémarrage du démon, pas seulement après la pose.

## Étape 6 — protections interposées : actives ou inertes ?

Un filtre applicatif (reverse proxy durci, limitation de débit, blocage d'URL)
correctement configuré ne protège rien si les utilisateurs atteignent encore le
service en direct sur son port d'origine.

Pour chaque protection interposée, documenter :

| Protection | Chemin protégé | Chemin direct encore ouvert ? | Statut |
|---|---|---|---|
| Reverse proxy durci | 443 → app | oui, port 8069 exposé | **préparée, inerte** |

Une protection inerte ne compte pas parmi les mesures appliquées. Elle figure au
rapport comme tâche ouverte, avec la condition précise qui la rendrait effective
(fermer le port direct, basculer le point d'entrée).

## Étape 7 — sortie et chiffrement

```bash
# Que le serveur peut-il joindre vers l'extérieur ?
ss -tnp state established | awk '{print $5}' | sort -u | head -30

# Certificats servis : expiration, émetteur, nom
echo | openssl s_client -connect <cible>:443 -servername <nom> 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# Protocoles et suites acceptés
nmap --script ssl-enum-ciphers -p 443 <cible> 2>/dev/null | head -40
```

Un serveur applicatif qui peut joindre Internet en sortie sans restriction est un
constat : c'est le canal d'exfiltration et de récupération de charge utile. La
contre-mesure (réseau interne sans route sortante) figure dans le skill
`secure-docker`.

## Note sur les mesures de latence

Si l'audit compare deux chemins réseau (tunnel chiffré contre trafic en clair, par
exemple), un chiffre isolé n'informe pas. Deux exigences avant d'annoncer une
conclusion :

- **Une référence mesurée dans le même régime** : le même trajet, la même cadence,
  au même moment.
- **Un régime qui ressemble à l'usage réel** : une rafale à cadence maximale
  mesure la file d'attente de l'instrument, pas la latence que la production
  rencontrera.

Un échantillon de 3 paquets ne conclut rien ; 200 paquets à cadence maximale
concluent sur un régime que personne ne rencontre. Mesurer les deux chemins, dans
le régime visé, avant d'énoncer quoi que ce soit.
