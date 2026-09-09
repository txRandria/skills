# PHP — implémentation des règles

Vérifier d'abord le framework et la version :

```bash
grep -E '"(php|laravel/framework|symfony/framework-bundle)"' composer.json
php -v 2>/dev/null
```

Laravel 10 et 11 diffèrent sur la structure (`bootstrap/app.php`, middleware).
Symfony 6 et 7 diffèrent sur les attributs et la configuration de sécurité.

## Validation d'entrée

### Laravel — Form Request

```php
class StoreDocumentRequest extends FormRequest
{
    public function authorize(): bool
    {
        // L'autorisation se décide ici, pas dans le contrôleur.
        return $this->user()->can('create', Document::class);
    }

    public function rules(): array
    {
        return [
            'matricule' => ['required', 'string', 'regex:/^[A-Z0-9-]{3,20}$/'],
            'categorie' => ['required', Rule::in(['bulletin', 'contrat', 'attestation'])],
            'annee'     => ['required', 'integer', 'between:2000,2100'],
            'fichier'   => ['required', 'file', 'mimetypes:application/pdf', 'max:10240'],
        ];
    }
}
```

Dans le contrôleur, n'utiliser que `$request->validated()` — jamais `$request->all()`
ni `$request->input()`, qui contournent la validation.

### Symfony — contraintes

```php
use Symfony\Component\Validator\Constraints as Assert;

class DocumentDto
{
    #[Assert\NotBlank, Assert\Regex('/^[A-Z0-9-]{3,20}$/')]
    public string $matricule;

    #[Assert\Choice(['bulletin', 'contrat', 'attestation'])]
    public string $categorie;
}
```

## Mass assignment

```php
// INTERDIT : le client peut poser is_admin, owner_id, etc.
Document::create($request->all());

// JUSTE
Document::create($request->validated());
```

Sur le modèle, déclarer `$fillable` (liste blanche) plutôt que `$guarded` (liste
noire) ; `protected $guarded = [];` désactive toute protection.

```php
protected $fillable = ['matricule', 'categorie', 'annee'];
protected $hidden   = ['password', 'remember_token'];   // exclus de la sérialisation JSON
```

## SQL

```php
// PDO
$stmt = $pdo->prepare('SELECT id FROM documents WHERE matricule = :m');
$stmt->execute(['m' => $matricule]);

// Laravel — liaison positionnelle
DB::select('SELECT id FROM documents WHERE matricule = ?', [$matricule]);

// Eloquent / Query Builder — paramétré par construction
Document::where('matricule', $matricule)->get();
```

Points d'injection résiduels en Laravel : `whereRaw`, `selectRaw`, `orderByRaw`,
`havingRaw`. Ils acceptent des liaisons — les utiliser :

```php
->whereRaw('LOWER(nom) = ?', [strtolower($nom)])         // correct
->orderByRaw("created_at {$sens}")                        // INTERDIT
->orderBy('created_at', $sens === 'asc' ? 'asc' : 'desc') // correct
```

Toujours activer `PDO::ATTR_EMULATE_PREPARES => false` : l'émulation construit la
requête côté client et a déjà ouvert des injections via des jeux de caractères
particuliers.

## Autorisation sur l'objet

```php
// FAUX : IDOR
$doc = Document::findOrFail($id);

// JUSTE, variante 1 : le propriétaire est dans la requête
$doc = Document::where('id', $id)->where('owner_id', $request->user()->id)->firstOrFail();

// JUSTE, variante 2 : Policy
$doc = Document::findOrFail($id);
$this->authorize('view', $doc);
```

Symfony : `#[IsGranted('VIEW', subject: 'document')]` avec un Voter. L'attribut
sur le contrôleur sans `subject` ne protège que la route, pas la ressource.

## Mots de passe

```php
$hash = password_hash($motDePasse, PASSWORD_ARGON2ID);
if (password_verify($saisie, $hash)) { /* ... */ }
if (password_needs_rehash($hash, PASSWORD_ARGON2ID)) { /* re-hacher */ }
```

Jamais `md5()`, `sha1()`, ni `hash('sha256', ...)` pour un mot de passe.
Aléa de sécurité : `random_bytes()` / `random_int()`, jamais `rand()`, `mt_rand()`
ni `uniqid()`.

Comparaison de secrets (jeton, signature) : `hash_equals()`, jamais `===`, pour
éviter la fuite par temps de comparaison.

## XSS

```blade
{{ $valeur }}      {{-- échappé --}}
{!! $valeur !!}    {{-- NON échappé — interdit sans assainisseur --}}
```

Twig : `{{ valeur }}` est échappé ; `{{ valeur|raw }}` ne l'est pas.
Pour du HTML riche accepté de l'utilisateur, passer par HTMLPurifier avec une
liste blanche de balises et d'attributs.

Injection de gabarit : ne jamais construire un template à partir d'une entrée
utilisateur (`Blade::render($entree)`, `$twig->createTemplate($entree)`) — c'est
une exécution de code à distance.

## Upload de fichier

```php
$fichier = $request->file('fichier');

// Le type déclaré par le client est falsifiable : lire le contenu.
$mime = (new \finfo(FILEINFO_MIME_TYPE))->file($fichier->getRealPath());
if ($mime !== 'application/pdf') {
    abort(422, 'Type de fichier non autorisé');
}

// Nom généré, stockage hors racine web (disque `local`, pas `public`).
$nom = Str::uuid()->toString() . '.pdf';
$fichier->storeAs('documents', $nom, 'local');
```

Ne jamais réutiliser `getClientOriginalName()` comme nom de stockage, ne jamais
stocker sous `public/`, ne jamais servir le dossier d'upload en statique. La
diffusion passe par un contrôleur qui vérifie l'autorisation :

```php
return Storage::disk('local')->download("documents/{$doc->nom_stockage}", $doc->nom_affiche);
```

## Chemin de fichier

```php
function cheminSur(string $racine, string $nom): string
{
    $racine = realpath($racine);
    $cible  = realpath($racine . DIRECTORY_SEPARATOR . $nom);
    if ($cible === false || !str_starts_with($cible, $racine . DIRECTORY_SEPARATOR)) {
        throw new \RuntimeException('Chemin hors racine autorisée');
    }
    return $cible;
}
```

Interdits absolus sur une entrée utilisateur : `include`, `require`, `file_get_contents`,
`unlink`, `fopen` avec un chemin non validé (inclusion de fichier locale/distante).

## Exécution de commande

```php
$cmd = 'pdftotext ' . escapeshellarg($chemin) . ' -';
exec($cmd, $sortie, $code);
```

Interdits sur données non fiables : `eval`, `assert` avec chaîne, `system`,
`shell_exec`, `passthru`, `popen`, `preg_replace` avec modificateur `/e` (retiré
depuis PHP 7), et les fonctions de rappel construites dynamiquement.

## Désérialisation

```php
unserialize($donnees);                                  // INTERDIT sur données non fiables
json_decode($donnees, true, 512, JSON_THROW_ON_ERROR);  // sûr
```

`unserialize()` déclenche des méthodes magiques (`__wakeup`, `__destruct`) et
permet des chaînes d'exploitation (POP chains) via les classes chargées.

## Sessions et CSRF

```php
// php.ini / configuration de session
session.cookie_httponly = 1
session.cookie_secure   = 1
session.cookie_samesite = Lax
session.use_strict_mode = 1     // refuse un identifiant de session non généré par le serveur
```

Régénérer l'identifiant de session à la connexion (`session_regenerate_id(true)`,
fait automatiquement par Laravel), sinon fixation de session.

CSRF : jeton obligatoire sur toute méthode modifiant l'état. Laravel l'applique
via le middleware `VerifyCsrfToken` — vérifier qu'aucune route sensible n'est
dans `$except`. Symfony : `csrf_protection: true` et `csrf_token()` dans les
formulaires.

## Configuration de production

```php
// .env — jamais commité
APP_DEBUG=false
APP_ENV=production
```

`APP_DEBUG=true` en production expose la trace de pile, les variables
d'environnement et donc les secrets sur la page d'erreur. C'est l'un des défauts
les plus exploités sur les applications Laravel exposées.

`display_errors = Off` et `expose_php = Off` dans `php.ini`.

## Audit de dépendances

```bash
composer audit
composer install --no-dev --optimize-autoloader   # en production
```

Le fichier `composer.lock` est commité ; `composer update` ne se lance pas en
déploiement.
