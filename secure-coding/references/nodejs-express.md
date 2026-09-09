# Node.js / Express — implémentation des règles

Extraits ancrés sur **Express 4.x + CommonJS**. Pour Express 5, `req.query` est en
lecture seule et les erreurs asynchrones remontent automatiquement (plus besoin
d'`express-async-errors`). Vérifier `package.json` avant de copier.

## Amorçage sécurisé d'une application Express 4

```js
const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const rateLimit = require('express-rate-limit');

const app = express();

// Derrière un reverse proxy : nombre EXACT de proxys de confiance devant l'app.
// `true` fait confiance à tout X-Forwarded-For et rend l'IP falsifiable.
// 1 nginx devant l'app => 1. Aucun proxy => ne pas définir cette option.
app.set('trust proxy', Number(process.env.TRUSTED_PROXY_HOPS ?? 0));

app.disable('x-powered-by');
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'"],          // pas de 'unsafe-inline'
      styleSrc: ["'self'"],
      imgSrc: ["'self'", 'data:'],
      objectSrc: ["'none'"],
      frameAncestors: ["'none'"],
      baseUri: ["'self'"],
    },
  },
  hsts: { maxAge: 31536000, includeSubDomains: true },
}));

// Liste blanche d'origines. Jamais `origin: true` ni '*' avec credentials.
const ALLOWED = (process.env.CORS_ORIGIN ?? '').split(',').filter(Boolean);
app.use(cors({
  origin(origin, cb) {
    if (!origin || ALLOWED.includes(origin)) return cb(null, true);
    return cb(new Error('Origin non autorisée'));
  },
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE'],
}));

// Limite de taille du corps : sans elle, un POST de 500 Mo est accepté.
app.use(express.json({ limit: '100kb' }));
app.use(express.urlencoded({ extended: false, limit: '100kb' }));
```

### Vérifier que le rate limiting voit la bonne IP

```js
const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5,
  standardHeaders: true,
  legacyHeaders: false,
  // Clé explicite : rend visible ce qui est réellement compté.
  keyGenerator: (req) => req.ip,
});
app.post('/api/auth/login', loginLimiter, loginHandler);
```

Contrôle réel, pas déclaratif — ajouter temporairement une route de diagnostic ou
un log, et confirmer que des clients distincts produisent des IP distinctes :

```js
app.get('/__whoami', (req, res) => res.json({ ip: req.ip, xff: req.headers['x-forwarded-for'] }));
```

Si tous les appels renvoient la même IP (celle du proxy), `trust proxy` est trop
bas. Si un client peut changer `req.ip` en envoyant `X-Forwarded-For: 1.2.3.4`,
il est trop haut. Retirer la route de diagnostic avant livraison.

## Validation d'entrée (Zod)

```js
const { z } = require('zod');

const CreateDocumentSchema = z.object({
  matricule: z.string().trim().regex(/^[A-Z0-9-]{3,20}$/),
  categorie: z.enum(['bulletin', 'contrat', 'attestation']),
  annee: z.coerce.number().int().min(2000).max(2100),
}).strict();  // .strict() rejette toute propriété non déclarée

function validate(schema, source = 'body') {
  return (req, res, next) => {
    const result = schema.safeParse(req[source]);
    if (!result.success) {
      return res.status(400).json({ error: 'Requête invalide' }); // pas de détail interne
    }
    req.validated = result.data;   // n'utiliser QUE req.validated ensuite
    next();
  };
}
```

Règle d'usage : après validation, le handler ne lit plus jamais `req.body` /
`req.query` / `req.params` directement. Lire la source brute annule la validation.

## SQL — paramétrage et identifiants

```js
// better-sqlite3
const stmt = db.prepare('SELECT id, nom FROM documents WHERE matricule = ?');
const rows = stmt.all(matricule);

// pg
await client.query('SELECT id FROM documents WHERE matricule = $1', [matricule]);
```

Un identifiant (colonne de tri) ne se paramètre pas — liste blanche obligatoire :

```js
const TRI_AUTORISE = { date: 'created_at', nom: 'nom_fichier' };
const colonne = TRI_AUTORISE[req.validated.tri] ?? 'created_at';
const sens = req.validated.sens === 'asc' ? 'ASC' : 'DESC';
db.prepare(`SELECT * FROM documents ORDER BY ${colonne} ${sens}`).all();
```

## Autorisation sur l'objet

```js
// FAUX : la route est protégée, la ressource ne l'est pas (IDOR).
router.get('/api/documents/:id', requireAuth, (req, res) => {
  const doc = db.prepare('SELECT * FROM documents WHERE id = ?').get(req.params.id);
  res.json(doc);
});

// JUSTE : le propriétaire fait partie de la clause WHERE.
router.get('/api/documents/:id', requireAuth, (req, res) => {
  const doc = db.prepare(
    'SELECT * FROM documents WHERE id = ? AND matricule = ?'
  ).get(req.validated.id, req.user.matricule);
  if (!doc) return res.status(404).json({ error: 'Introuvable' }); // 404, pas 403 : ne pas divulguer l'existence
  res.json(doc);
});
```

## JWT

```js
const jwt = require('jsonwebtoken');

// Signature : algorithme explicite, durée courte, audience et émetteur.
const token = jwt.sign(
  { sub: user.id, role: user.role },
  process.env.JWT_SECRET,
  { algorithm: 'HS256', expiresIn: '15m', issuer: 'mon-app', audience: 'mon-app-api' }
);

// Vérification : TOUJOURS contraindre `algorithms`, sinon un jeton `alg: none`
// ou un basculement HS/RS peut être accepté.
const payload = jwt.verify(token, process.env.JWT_SECRET, {
  algorithms: ['HS256'], issuer: 'mon-app', audience: 'mon-app-api',
});
```

Contrôles : secret d'au moins 32 octets aléatoires, refus de démarrage si absent
ou égal à une valeur d'exemple, pas de donnée sensible dans le payload (il est
seulement signé, pas chiffré), stockage côté client en cookie `HttpOnly` plutôt
qu'en `localStorage` quand le contexte le permet.

```js
if (!process.env.JWT_SECRET || process.env.JWT_SECRET.length < 32) {
  throw new Error('JWT_SECRET absent ou trop court — démarrage refusé');
}
```

## Upload de fichier (multer)

```js
const multer = require('multer');
const crypto = require('crypto');
const path = require('path');
const fs = require('fs');

const UPLOAD_DIR = path.resolve(process.env.UPLOAD_DIR); // hors racine web

const upload = multer({
  storage: multer.diskStorage({
    destination: UPLOAD_DIR,
    // Nom généré : le nom client n'est jamais réutilisé sur le disque.
    filename: (_req, _file, cb) => cb(null, `${crypto.randomUUID()}.pdf`),
  }),
  limits: { fileSize: 10 * 1024 * 1024, files: 1 },
  fileFilter: (_req, file, cb) => {
    if (file.mimetype !== 'application/pdf') return cb(new Error('Type non autorisé'));
    cb(null, true);
  },
});

// fileFilter lit le Content-Type ENVOYÉ PAR LE CLIENT : il est falsifiable.
// Vérifier les magic bytes après écriture, et supprimer le fichier si le
// contenu ne correspond pas.
async function assertPdf(filePath) {
  const fd = await fs.promises.open(filePath, 'r');
  try {
    const buf = Buffer.alloc(5);
    await fd.read(buf, 0, 5, 0);
    if (buf.toString('latin1') !== '%PDF-') {
      await fs.promises.unlink(filePath);
      throw new Error('Contenu non conforme au type déclaré');
    }
  } finally { await fd.close(); }
}
```

## Path traversal — résoudre puis vérifier le préfixe

```js
function cheminSur(racine, nomFournis) {
  const racineAbs = path.resolve(racine);
  const cible = path.resolve(racineAbs, nomFournis);
  // Le séparateur final évite qu'un dossier "uploads-evil" passe le test de préfixe.
  if (cible !== racineAbs && !cible.startsWith(racineAbs + path.sep)) {
    throw new Error('Chemin hors racine autorisée');
  }
  return cible;
}
```

Servir un fichier téléversé passe par un contrôleur, jamais par `express.static`
sur le dossier d'upload : un dossier servi en statique contourne toute
autorisation.

```js
router.get('/api/documents/:id/download', requireAuth, (req, res) => {
  const doc = db.prepare('SELECT * FROM documents WHERE id = ? AND matricule = ?')
    .get(req.validated.id, req.user.matricule);
  if (!doc) return res.sendStatus(404);
  res.setHeader('Content-Type', 'application/pdf');
  res.setHeader('Content-Disposition', `attachment; filename="${encodeURIComponent(doc.nom_affiche)}"`);
  res.sendFile(cheminSur(UPLOAD_DIR, doc.nom_stockage));
});
```

## SSRF

```js
const dns = require('node:dns/promises');
const net = require('node:net');

async function urlSortanteAutorisee(brut) {
  const u = new URL(brut);
  if (u.protocol !== 'https:') throw new Error('Schéma non autorisé');
  const { address } = await dns.lookup(u.hostname);
  const priv = net.isIPv4(address) && (
    address.startsWith('10.') || address.startsWith('127.') ||
    address.startsWith('192.168.') || address.startsWith('169.254.') ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(address)
  );
  if (priv) throw new Error('Destination privée refusée');
  return u;
}
```

Limite connue : entre la résolution et la requête, le nom peut être re-résolu vers
une autre adresse (DNS rebinding). En contexte sensible, faire sortir les appels
par un proxy sortant à liste blanche plutôt que de valider dans l'application.

## Gestionnaire d'erreurs terminal

```js
app.use((err, req, res, _next) => {
  const id = crypto.randomUUID();
  console.error(JSON.stringify({ id, msg: err.message, stack: err.stack, path: req.path }));
  res.status(err.status ?? 500).json({ error: 'Erreur interne', reference: id });
});
```

Le client reçoit un identifiant corrélable, jamais le détail.

## Mots de passe

```js
const bcrypt = require('bcryptjs');
const hash = await bcrypt.hash(motDePasse, 12);
const ok = await bcrypt.compare(saisie, hash);
```

Comparer systématiquement, même quand l'utilisateur n'existe pas (hachage factice),
pour ne pas révéler l'existence du compte par le temps de réponse.

## Audit de dépendances

```bash
npm ci
npm audit --audit-level=high
```

Vérifier aussi que le fichier de verrouillage est bien commité et que
`npm ci` — et non `npm install` — est utilisé en CI et dans le Dockerfile.
