# React / Next.js — implémentation des règles

Vérifier d'abord le routeur utilisé : `app/` (App Router, Next.js 13+) ou `pages/`
(Pages Router). Les mécanismes d'authentification, de rendu et de frontière
serveur/client diffèrent radicalement entre les deux.

```bash
ls -d app pages src/app src/pages 2>/dev/null
grep '"next"' package.json
```

## 1. XSS — l'échappement automatique et ses trous

React échappe le contenu textuel. Trois portes de sortie l'annulent :

```jsx
// INTERDIT sans assainissement
<div dangerouslySetInnerHTML={{ __html: contenuUtilisateur }} />

// Si le HTML riche est une exigence produit : assainir, côté serveur de préférence
import DOMPurify from 'isomorphic-dompurify';
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(contenu, {
  ALLOWED_TAGS: ['p', 'b', 'i', 'ul', 'li', 'a'],
  ALLOWED_ATTR: ['href'],
}) }} />
```

```jsx
// INTERDIT : une URL utilisateur peut valoir "javascript:alert(1)"
<a href={urlUtilisateur}>lien</a>

// Valider le schéma avant de rendre
function lienSur(brut) {
  try {
    const u = new URL(brut, 'https://exemple.invalid');
    return ['http:', 'https:', 'mailto:'].includes(u.protocol) ? u.href : null;
  } catch { return null; }
}
```

Troisième porte : injecter une valeur utilisateur dans un `<script>`, un
`style={{}}` construit par chaîne, ou un attribut d'événement généré. Ne pas le
faire.

## 2. La frontière serveur / client

C'est la source d'incident la plus fréquente en Next.js : une donnée sensible
récupérée côté serveur puis passée en props à un composant client se retrouve
sérialisée dans le HTML envoyé au navigateur.

```jsx
// FAUX : l'objet entier est sérialisé dans le payload RSC, hash inclus
const user = await db.user.findUnique({ where: { id } });
return <ProfilClient user={user} />;

// JUSTE : ne transmettre que les champs nécessaires à l'affichage
return <ProfilClient user={{ id: user.id, nom: user.nom, role: user.role }} />;
```

Vérification concrète : charger la page et chercher la valeur sensible dans la
source HTML.

```bash
curl -s http://localhost:3000/profil | grep -iE 'hash|password|secret|token' && echo "FUITE" || echo "propre"
```

## 3. Variables d'environnement

Tout ce qui est préfixé `NEXT_PUBLIC_` est **inliné dans le bundle client** et
donc public. Aucun secret ne porte ce préfixe. Les autres variables ne sont
lisibles que dans du code serveur (Server Component, Route Handler, Server Action,
`getServerSideProps`).

```bash
# Contrôle : aucun secret préfixé NEXT_PUBLIC_
grep -rE 'NEXT_PUBLIC_[A-Z_]*(SECRET|KEY|TOKEN|PASSWORD|DSN)' . --include='*.ts*' --include='*.js*' --include='.env*'
```

Marquer les modules strictement serveur pour que l'import depuis un composant
client échoue à la compilation plutôt qu'à l'exécution :

```ts
// lib/db.ts
import 'server-only';
```

## 4. Server Actions — ce sont des endpoints HTTP publics

Une Server Action est exposée par une route générée. Le fait qu'elle ne soit
appelée que depuis un bouton visible par un administrateur ne la protège pas :
elle est appelable directement.

```ts
'use server';
import { z } from 'zod';

const Schema = z.object({ documentId: z.string().uuid() }).strict();

export async function supprimerDocument(formData: FormData) {
  // 1. Authentification — dans l'action, pas dans le composant appelant
  const session = await getSession();
  if (!session) throw new Error('Non authentifié');

  // 2. Validation
  const { documentId } = Schema.parse({ documentId: formData.get('documentId') });

  // 3. Autorisation sur l'objet — le propriétaire est dans la requête
  const res = await db.document.deleteMany({
    where: { id: documentId, ownerId: session.userId },
  });
  if (res.count === 0) throw new Error('Introuvable');
}
```

Les trois étapes se font **dans** l'action. Une vérification faite dans le
composant parent, dans un layout, ou dans le middleware ne protège pas l'action.

## 5. Middleware — filtre, pas barrière d'autorisation

`middleware.ts` est utile pour rediriger un utilisateur non connecté, mais ne doit
jamais être l'unique contrôle d'autorisation : il ne s'exécute pas sur tous les
chemins (correspondance du `matcher`), et des contournements de correspondance de
chemin ont existé dans plusieurs versions. Chaque Route Handler, Server Action et
Server Component sensible refait sa propre vérification.

```ts
export const config = { matcher: ['/admin/:path*', '/api/admin/:path*'] };
```

## 6. Route Handlers

```ts
// app/api/documents/[id]/route.ts
export async function GET(req: Request, { params }: { params: { id: string } }) {
  const session = await getSession();
  if (!session) return new Response('Non authentifié', { status: 401 });

  const parsed = z.string().uuid().safeParse(params.id);
  if (!parsed.success) return new Response('Requête invalide', { status: 400 });

  const doc = await db.document.findFirst({
    where: { id: parsed.data, ownerId: session.userId },
  });
  if (!doc) return new Response('Introuvable', { status: 404 });
  return Response.json(doc);
}
```

Sur les routes authentifiées, empêcher toute mise en cache d'une réponse
personnalisée : `export const dynamic = 'force-dynamic';` ou en-tête
`Cache-Control: private, no-store`. Une réponse personnalisée mise en cache par un
CDN se sert à d'autres utilisateurs.

## 7. Sessions par cookie

```ts
cookies().set('session', jeton, {
  httpOnly: true,
  secure: process.env.NODE_ENV === 'production',
  sameSite: 'lax',
  path: '/',
  maxAge: 60 * 60,
});
```

`httpOnly` rend le cookie inaccessible au JavaScript, ce qui limite l'impact d'un
XSS. Un jeton stocké dans `localStorage` est lisible par tout script de la page,
y compris un script tiers compromis.

`SameSite=Lax` couvre les cas courants de CSRF sur les requêtes cross-site, mais
pas les requêtes same-site. Pour les Route Handlers modifiant l'état, ajouter une
vérification de l'en-tête `Origin` :

```ts
const origin = req.headers.get('origin');
if (origin && !ALLOWED_ORIGINS.includes(origin)) {
  return new Response('Origine refusée', { status: 403 });
}
```

## 8. CSP avec nonce

Next.js injecte des scripts inline ; une CSP stricte exige donc un nonce généré
par requête dans le middleware.

```ts
// middleware.ts
const nonce = Buffer.from(crypto.randomUUID()).toString('base64');
const csp = [
  `default-src 'self'`,
  `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
  `style-src 'self' 'nonce-${nonce}'`,
  `object-src 'none'`,
  `base-uri 'self'`,
  `frame-ancestors 'none'`,
].join('; ');

const res = NextResponse.next({ request: { headers: new Headers({ ...Object.fromEntries(req.headers), 'x-nonce': nonce }) } });
res.headers.set('Content-Security-Policy', csp);
```

Vérifier la CSP réellement servie, jamais le fichier de configuration :

```bash
curl -sI http://localhost:3000/ | grep -i content-security-policy
```

## 9. Redirections ouvertes

```ts
// FAUX
redirect(searchParams.get('next'));

// JUSTE : seuls les chemins relatifs internes sont acceptés
const next = searchParams.get('next') ?? '/';
redirect(next.startsWith('/') && !next.startsWith('//') ? next : '/');
```

Le test `!next.startsWith('//')` est indispensable : `//evil.example` est une URL
absolue protocol-relative et passerait un simple test « commence par `/` ».

## 10. Dépendances front

```bash
npm audit --audit-level=high
npx depcheck            # dépendances déclarées mais non utilisées
```

Toute balise `<script src>` pointant vers un domaine tiers doit être justifiée et,
si possible, portée par une intégrité de sous-ressource (`integrity` + `crossorigin`).
