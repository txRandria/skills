# Phase 4 — indicateurs de compromission

## Le constat qui motive ce fichier

Un premier passage — comptes système, tâches planifiées, processus, listes
d'objets applicatifs — avait conclu « aucun indicateur de compromission ». Une
observation du comportement en cours d'exécution a ensuite révélé une
compromission active vieille de dix mois.

La charge ne vivait dans aucun emplacement canonique. Elle était logée dans des
enregistrements applicatifs d'apparence légitime, et dans la couche inscriptible
d'un conteneur sous des noms mimant des fichiers système. Elle n'était visible que
pendant son exécution, déclenchée périodiquement depuis l'extérieur.

**Règle : l'absence de preuve dans un inventaire statique n'est pas une preuve
d'absence.** La conclusion se formule « aucun indicateur trouvé par ces méthodes :
[liste] », jamais « pas de compromission ».

## Passe 1 — emplacements canoniques

Nécessaire, jamais suffisant.

```bash
echo "=== COMPTES AJOUTÉS RÉCEMMENT ==="
ls -la --time-style=long-iso /home/ 2>/dev/null
awk -F: '$3>=1000 {print $1" uid="$3}' /etc/passwd
stat -c '%n modifié %y' /etc/passwd /etc/shadow /etc/sudoers 2>/dev/null

echo "=== CLÉS SSH ==="
find / -xdev -name authorized_keys -newermt '-365 days' 2>/dev/null -exec ls -la {} \;

echo "=== PERSISTANCE PLANIFIÉE ==="
grep -rhv '^\s*#' /etc/cron.d/* /etc/crontab 2>/dev/null | grep -vE '^\s*$'
systemctl list-timers --all --no-pager --no-legend
ls -la /etc/systemd/system/*.service /etc/systemd/system/*.timer 2>/dev/null

echo "=== PROCESSUS SANS BINAIRE SUR DISQUE ==="
for p in /proc/[0-9]*; do
  exe=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$exe" in *"(deleted)"*) echo "SUPPRIMÉ ${p##*/} $exe";; esac
done

echo "=== BINAIRES DANS DES CHEMINS INHABITUELS ==="
find /tmp /var/tmp /dev/shm /run -xdev -type f -executable 2>/dev/null | head -30

echo "=== CONNEXIONS SORTANTES ÉTABLIES ==="
ss -tnp state established
```

`/tmp`, `/var/tmp` et `/dev/shm` sont inscriptibles par tous et souvent montés
sans `noexec` : ce sont les premiers emplacements où atterrit une charge.

## Passe 2 — les emplacements que l'inventaire ne couvre pas

### Couche inscriptible des conteneurs

```bash
for c in $(docker ps -q); do
  n=$(docker inspect --format '{{.Name}}' "$c")
  printf '=== %s ===\n' "$n"
  docker diff "$c" | grep -E '^[AC]' | head -30
done
```

Un fichier ajouté dans un chemin système d'un conteneur, sous un nom plausible,
est invisible pour tout scan de l'hôte.

### Enregistrements applicatifs

La charge peut être stockée dans la base, sous forme d'enregistrement légitime en
apparence : action planifiée, règle automatisée, gabarit, champ de code exécuté
par le produit. Les emplacements dépendent du produit, mais la question est
générique : **quels enregistrements de cette base sont évalués comme du code ?**

Pour chaque emplacement identifié, lister les enregistrements et trier par date de
création et d'écriture, puis inspecter ceux dont l'auteur, la date ou le contenu
détonnent par rapport au reste. Ne pas se limiter aux noms suspects : la charge
observée portait des noms mimant des objets du produit.

### Journaux — ce qui manque autant que ce qui est présent

```bash
echo "=== TROUS DE JOURNALISATION ==="
journalctl --list-boots | head -10
ls -la /var/log/ | head -30
# Un fichier de journal tronqué à 0, ou dont la date de modification est
# antérieure à la dernière activité du service, signale un effacement.
find /var/log -type f -size 0 2>/dev/null

echo "=== AUTHENTIFICATIONS ==="
grep -aiE 'accepted|failed password|invalid user' /var/log/auth.log 2>/dev/null | tail -50
last -n 50 2>/dev/null
lastb -n 30 2>/dev/null
```

Un journal vide n'est pas rassurant : il faut savoir s'il est vide parce qu'il ne
s'est rien passé, ou parce qu'il a été purgé. Comparer la taille et la date des
fichiers de journal à ceux d'un serveur témoin comparable quand il en existe un.

## Passe 3 — observation dynamique

C'est la phase que l'inventaire ne remplace pas. Elle est **obligatoire dès qu'une
anomalie périodique inexpliquée est constatée** : redémarrages de service, pics de
charge réguliers, erreurs récurrentes, trafic sortant cyclique.

### Protocole

1. **Établir la périodicité.** Extraire les horodatages de l'anomalie déjà
   constatée et calculer l'intervalle.

   ```bash
   grep -a '<motif-anomalie>' /var/log/<fichier> | awk '{print $1,$2,$3}' | tail -20
   journalctl -u <service> --since '-7 days' | grep -c '<motif>'
   ```

2. **Activer une journalisation détaillée sur la couche concernée**, et seulement
   sur elle. C'est une écriture : elle sort du périmètre lecture seule et exige
   l'accord explicite du client, ainsi qu'une date de retrait.

3. **Attendre au moins un cycle complet**, plus une marge. Observer un demi-cycle
   ne prouve rien.

4. **Capturer pendant le déclenchement.**

   ```bash
   # Processus apparaissant puis disparaissant
   while true; do ps -eo pid,ppid,user,lstart,args --sort=start_time | tail -5; sleep 2; done

   # Connexions au moment du cycle
   ss -tnp state established

   # Écritures dans les emplacements inscriptibles
   inotifywait -m -r /tmp /var/tmp /dev/shm 2>/dev/null
   ```

5. **Désactiver la journalisation détaillée** dès l'observation faite, et le
   consigner.

### Vérifier un dispositif de surveillance sans casser ce qu'il protège

Pour prouver qu'un service d'audit capture bien les événements, ne jamais
déclencher l'événement sur la ressource réelle. Écrire dans le fichier des comptes
du système pour « générer un événement » a laissé planer un doute sérieux sur
l'intégrité de ce fichier quand la commande a expiré en cours d'exécution.

La preuve s'obtient à risque nul :

```bash
# Créer une ressource jetable DANS le périmètre surveillé
touch /etc/audit-test-$$
# Vérifier qu'elle apparaît nommément dans la piste d'audit
ausearch -f "/etc/audit-test-$$" 2>/dev/null | tail -20
# Supprimer
rm -f /etc/audit-test-$$
```

Corollaire : quand un doute d'intégrité surgit sur un fichier système, comparer
son empreinte à celle d'un **serveur témoin** avant d'annoncer une corruption.
L'instrument de vérification se trompe plus souvent que le système vérifié — dans
le cas cité, une redirection mal placée dans les commandes de contrôle renvoyait
des résultats vides, ce qui a d'abord semblé confirmer le pire alors que le
fichier était intact.

```bash
sha256sum /etc/passwd                       # sur l'hôte suspect
ssh <temoin> sha256sum /etc/passwd          # sur le témoin
```

## Ce qui déclenche une escalade immédiate

Interrompre l'audit et alerter le client sans attendre la fin des phases si l'un
de ces éléments est constaté :

- Processus en cours dont le binaire a été supprimé du disque.
- Compte UID 0 autre que `root`, ou clé SSH non attribuable dans
  `authorized_keys`.
- Connexion sortante établie vers une destination non identifiée, persistante ou
  périodique.
- Journaux tronqués ou dont la continuité est rompue.
- Endpoint d'administration accessible sans authentification depuis l'extérieur.
- Identifiants d'usine encore valides sur une console d'administration exposée.

Sur un serveur potentiellement compromis, toute écriture détruit des traces :
c'est le client, pas l'auditeur, qui arbitre entre préservation des preuves et
remise en service.

## Formulation de la conclusion

```
Aucun indicateur de compromission trouvé par les méthodes suivantes :
inventaire des comptes, des tâches planifiées et des unités systemd ; inspection
des processus et de leurs binaires ; couche inscriptible des N conteneurs
(docker diff) ; journaux d'authentification sur 90 jours ; connexions sortantes
établies au moment de la collecte.

Méthodes NON employées, et angles morts correspondants : pas d'analyse mémoire,
pas de comparaison d'empreintes avec les paquets d'origine (debsums non
installé), pas d'observation dynamique sur un cycle complet, pas d'inspection
des enregistrements applicatifs évalués comme du code.
```

La seconde partie est ce qui rend la première honnête. Un rapport qui n'énumère
pas ses angles morts affirme davantage qu'il n'a vérifié.
