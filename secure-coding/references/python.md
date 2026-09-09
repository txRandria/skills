# Python — implémentation des règles

Vérifier d'abord le framework et sa version majeure :

```bash
grep -iE 'fastapi|django|flask|sqlalchemy|pydantic' pyproject.toml requirements.txt 2>/dev/null
```

Pydantic v1 et v2 ont des API incompatibles (`@validator` vs `@field_validator`,
`.dict()` vs `.model_dump()`). Django 4 et 5 diffèrent sur les réglages de
sécurité par défaut. Ne pas produire de snippet sans avoir lu la version.

## Validation d'entrée

### FastAPI + Pydantic v2

```python
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal

class CreateDocument(BaseModel):
    model_config = ConfigDict(extra="forbid")   # rejette tout champ non déclaré

    matricule: str = Field(pattern=r"^[A-Z0-9-]{3,20}$")
    categorie: Literal["bulletin", "contrat", "attestation"]
    annee: int = Field(ge=2000, le=2100)
```

`extra="forbid"` est le point important : sans lui, un champ inattendu est
silencieusement ignoré, ce qui masque les erreurs et facilite le mass assignment
quand le modèle est réutilisé en écriture.

### Django

Passer par un `Form` ou un `Serializer` DRF, jamais par `request.POST` directement,
et ne jamais utiliser `fields = "__all__"` sur un ModelForm/ModelSerializer :
c'est la forme canonique du mass assignment (un champ `is_staff` ou `owner_id`
devient modifiable par le client).

```python
class DocumentSerializer(serializers.ModelSerializer):
    class Meta:
        model = Document
        fields = ["nom", "categorie", "annee"]     # liste explicite
        read_only_fields = ["owner", "created_at"]
```

## SQL

```python
# psycopg — paramétrage par le driver
cur.execute("SELECT id FROM documents WHERE matricule = %s", (matricule,))

# SQLAlchemy Core / text()
from sqlalchemy import text
conn.execute(text("SELECT id FROM documents WHERE matricule = :m"), {"m": matricule})

# Django ORM — paramétré par construction
Document.objects.filter(matricule=matricule)
```

Interdits : f-strings et `%` dans une requête, `.raw()` ou `.extra()` avec
interpolation, `cur.execute(f"... {valeur}")`. Un identifiant de colonne se
valide par dictionnaire de liste blanche, comme en Node.

## Autorisation sur l'objet

```python
# FAUX : IDOR
doc = Document.objects.get(pk=pk)

# JUSTE : le propriétaire fait partie du filtre
doc = get_object_or_404(Document, pk=pk, owner=request.user)
```

En DRF, `permission_classes` protège la vue ; c'est `get_queryset` qui protège
l'objet :

```python
def get_queryset(self):
    return Document.objects.filter(owner=self.request.user)
```

## Mots de passe

```python
from argon2 import PasswordHasher          # argon2-cffi
ph = PasswordHasher()
hash_ = ph.hash(mot_de_passe)
ph.verify(hash_, saisie)                   # lève VerifyMismatchError si faux
```

Django : utiliser `make_password` / `check_password`, jamais un hachage maison.
Aléa de sécurité : `secrets.token_urlsafe(32)`, jamais `random`.

## Désérialisation

```python
import yaml, json

yaml.safe_load(donnees)        # JUSTE
yaml.load(donnees)             # INTERDIT sans Loader sûr — exécution de code
pickle.loads(donnees)          # INTERDIT sur toute donnée non fiable
json.loads(donnees)            # sûr
```

`pickle`, `marshal`, `shelve`, `dill` désérialisent du code arbitraire. Ne jamais
les appliquer à une donnée traversant une frontière de confiance, y compris un
cache partagé ou une file de messages.

## Exécution de commande

```python
import subprocess

# JUSTE : liste d'arguments, pas de shell
subprocess.run(["pdftotext", chemin, "-"], check=True, capture_output=True, timeout=30)

# INTERDIT
subprocess.run(f"pdftotext {chemin}", shell=True)
```

`shell=True` avec une valeur non constante est une injection de commande. Si le
shell est vraiment nécessaire, `shlex.quote()` chaque argument — mais préférer la
forme liste.

## Chemins de fichiers

```python
from pathlib import Path

def chemin_sur(racine: Path, nom: str) -> Path:
    racine = racine.resolve()
    cible = (racine / nom).resolve()
    if not cible.is_relative_to(racine):     # Python 3.9+
        raise ValueError("Chemin hors racine autorisée")
    return cible
```

`is_relative_to` opère sur les chemins résolus, donc après suppression des `..` et
des liens symboliques — c'est ce qui rend le contrôle valide.

## Templates Jinja / Django

L'échappement automatique est actif par défaut. Ne pas le désactiver :

- Jinja : `{{ valeur | safe }}`, `Markup(...)`, `autoescape=False`
- Django : `{{ valeur|safe }}`, `mark_safe(...)`

L'injection de gabarit côté serveur (SSTI) survient quand une entrée utilisateur
devient le **template** et non la variable :

```python
Template(entree_utilisateur).render()      # INTERDIT — exécution de code
Template(GABARIT_FIXE).render(v=entree)    # correct
```

## SSRF

```python
import ipaddress, socket
from urllib.parse import urlparse

def url_sortante_autorisee(brut: str) -> str:
    u = urlparse(brut)
    if u.scheme != "https":
        raise ValueError("Schéma non autorisé")
    ip = ipaddress.ip_address(socket.gethostbyname(u.hostname))
    if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
        raise ValueError("Destination interne refusée")
    return brut

requests.get(url_sortante_autorisee(url), timeout=5, allow_redirects=False)
```

`timeout` est obligatoire : sans lui, `requests` attend indéfiniment et une
destination lente devient un déni de service sur le service appelant.

## XML

```python
from defusedxml.ElementTree import fromstring   # au lieu de xml.etree
```

Les parseurs XML de la bibliothèque standard sont vulnérables à XXE et aux bombes
d'entités sur données non fiables.

## Réglages Django à vérifier en production

```python
DEBUG = False                       # DEBUG=True expose la configuration et les requêtes
ALLOWED_HOSTS = ["portail.exemple.tld"]
SECURE_SSL_REDIRECT = True
SESSION_COOKIE_SECURE = True
CSRF_COOKIE_SECURE = True
SESSION_COOKIE_HTTPONLY = True
SECURE_HSTS_SECONDS = 31536000
SECURE_HSTS_INCLUDE_SUBDOMAINS = True
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = "DENY"
```

Contrôle automatisé fourni par le framework :

```bash
python manage.py check --deploy
```

## FastAPI — quelques pièges

- La documentation interactive (`/docs`, `/openapi.json`) est publique par défaut :
  la désactiver en production (`docs_url=None, redoc_url=None`) ou l'authentifier.
- `CORSMiddleware(allow_origins=["*"], allow_credentials=True)` est refusé par les
  navigateurs et signale une configuration non réfléchie : lister les origines.
- Une dépendance d'authentification déclarée sur le routeur ne dispense pas de
  filtrer par propriétaire dans la requête.

## Audit de dépendances

```bash
pip-audit                       # vulnérabilités connues
bandit -r . -ll                 # défauts de code Python fréquents
```

Installation reproductible : fichier de verrouillage commité (`poetry.lock`,
`uv.lock`, ou `requirements.txt` avec versions figées et hachages), et
`pip install --require-hashes` en CI.
