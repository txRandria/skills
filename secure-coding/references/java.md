# Java / Spring Boot — implémentation des règles

Vérifier d'abord la version majeure :

```bash
grep -A2 'spring-boot-starter-parent' pom.xml
grep -E 'springBootVersion|org.springframework.boot' build.gradle 2>/dev/null
java -version 2>&1 | head -1
```

Spring Boot 2 utilise `javax.*` et la configuration de sécurité par
`WebSecurityConfigurerAdapter` ; Spring Boot 3 utilise `jakarta.*` et une
`SecurityFilterChain` en bean. Les snippets ci-dessous visent **Spring Boot 3**.

## Validation d'entrée — Bean Validation

```java
public record CreateDocumentRequest(
    @NotBlank @Pattern(regexp = "^[A-Z0-9-]{3,20}$") String matricule,
    @NotNull Categorie categorie,
    @Min(2000) @Max(2100) int annee
) {}

@PostMapping("/api/documents")
public ResponseEntity<?> create(@Valid @RequestBody CreateDocumentRequest req) { ... }
```

`@Valid` est obligatoire — sans lui les annotations ne sont pas évaluées.
Rejeter les champs inconnus plutôt que les ignorer :

```yaml
spring:
  jackson:
    deserialization:
      fail-on-unknown-properties: true
```

Ne jamais lier une requête HTTP directement à une entité JPA (`@RequestBody Document`) :
c'est du mass assignment, le client peut poser `id`, `ownerId`, `role`. Passer par
un DTO puis recopier explicitement les champs autorisés.

## SQL / JPA

```java
// JPQL paramétré
@Query("SELECT d FROM Document d WHERE d.matricule = :m AND d.owner.id = :o")
List<Document> findByMatricule(@Param("m") String matricule, @Param("o") Long ownerId);

// JDBC paramétré
jdbcTemplate.query("SELECT id FROM documents WHERE matricule = ?", rowMapper, matricule);
```

Interdits : concaténation dans `@Query`, `createQuery("... " + valeur)`,
`nativeQuery` construit par chaîne. Le tri dynamique passe par une liste blanche :

```java
private static final Set<String> TRI = Set.of("createdAt", "nom");
String colonne = TRI.contains(demande) ? demande : "createdAt";
Sort sort = Sort.by(Sort.Direction.fromOptionalString(sens).orElse(Sort.Direction.DESC), colonne);
```

`Sort.by` avec une chaîne non validée permet d'atteindre des propriétés non prévues.

## Autorisation sur l'objet

```java
// FAUX : IDOR
@GetMapping("/api/documents/{id}")
public Document get(@PathVariable Long id) {
    return repo.findById(id).orElseThrow();
}

// JUSTE : le propriétaire fait partie de la requête
@GetMapping("/api/documents/{id}")
public Document get(@PathVariable Long id, @AuthenticationPrincipal UserDetails user) {
    return repo.findByIdAndOwnerUsername(id, user.getUsername())
               .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND));
}
```

Variante par expression, quand la ressource doit être chargée d'abord :

```java
@PreAuthorize("@documentSecurity.peutLire(#id, authentication)")
```

`@PreAuthorize` exige `@EnableMethodSecurity` — sans cette annotation, les règles
sont silencieusement ignorées. Vérifier sa présence, ne pas la supposer.

## Configuration Spring Security 6

```java
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {

    @Bean
    SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            .authorizeHttpRequests(auth -> auth
                .requestMatchers("/actuator/health", "/login").permitAll()
                .requestMatchers("/api/admin/**").hasRole("ADMIN")
                .anyRequest().authenticated())          // défaut fermé, en dernier
            .headers(h -> h
                .contentSecurityPolicy(csp -> csp.policyDirectives(
                    "default-src 'self'; object-src 'none'; frame-ancestors 'none'"))
                .httpStrictTransportSecurity(hsts -> hsts.maxAgeInSeconds(31536000)))
            .sessionManagement(s -> s
                .sessionFixation(SessionFixationConfigurer::newSession)
                .maximumSessions(1));
        return http.build();
    }

    @Bean
    PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder(12);
    }
}
```

`.anyRequest().authenticated()` en dernière position est ce qui rend la
configuration « fermée par défaut » : toute route ajoutée plus tard est protégée
tant qu'elle n'est pas explicitement ouverte.

**CSRF** : ne pas appeler `.csrf(csrf -> csrf.disable())` par réflexe. La
protection n'est inutile que si l'authentification ne repose sur aucun cookie
(jeton Bearer uniquement). Avec une session en cookie, la désactiver ouvre la
CSRF sur toutes les routes d'écriture.

## Mots de passe et aléa

```java
new BCryptPasswordEncoder(12)                     // ou Argon2PasswordEncoder
SecureRandom random = new SecureRandom();         // jamais java.util.Random
byte[] jeton = new byte[32];
random.nextBytes(jeton);
```

Comparaison de secrets : `MessageDigest.isEqual(a, b)` (temps constant), jamais
`Arrays.equals` ni `String.equals` sur un jeton.

## Désérialisation

```java
// INTERDIT sur données non fiables
new ObjectInputStream(in).readObject();
```

La désérialisation Java native est une exécution de code dès qu'une chaîne de
gadgets existe dans le classpath. Utiliser JSON. Et ne pas activer le typage
polymorphe global de Jackson :

```java
mapper.activateDefaultTyping(...);   // INTERDIT
```

## XML — XXE

```java
DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
dbf.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
dbf.setFeature("http://xml.org/sax/features/external-general-entities", false);
dbf.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
dbf.setXIncludeAware(false);
dbf.setExpandEntityReferences(false);
```

Appliquer le même durcissement à `SAXParserFactory`, `XMLInputFactory`
(`IS_SUPPORTING_EXTERNAL_ENTITIES=false`), `TransformerFactory` et `SchemaFactory`.

## Chemin de fichier

```java
Path racine = Paths.get(racineConfig).toAbsolutePath().normalize();
Path cible  = racine.resolve(nomFourni).normalize();
if (!cible.startsWith(racine)) {
    throw new SecurityException("Chemin hors racine autorisée");
}
```

`normalize()` avant le test est indispensable : sans lui, `../../etc/passwd`
passe le `startsWith`.

## Upload

```java
@PostMapping(value = "/api/documents", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
public ResponseEntity<?> upload(@RequestPart MultipartFile fichier) throws IOException {
    if (fichier.getSize() > 10L * 1024 * 1024) return ResponseEntity.badRequest().build();

    // Le Content-Type client est falsifiable : lire les magic bytes.
    byte[] entete = new byte[5];
    try (InputStream in = fichier.getInputStream()) { in.read(entete); }
    if (!new String(entete, StandardCharsets.ISO_8859_1).equals("%PDF-")) {
        return ResponseEntity.unprocessableEntity().build();
    }
    Path dest = cheminSur(racine, UUID.randomUUID() + ".pdf");
    fichier.transferTo(dest);
    return ResponseEntity.ok().build();
}
```

Limites côté serveur aussi :

```yaml
spring:
  servlet:
    multipart:
      max-file-size: 10MB
      max-request-size: 12MB
```

## Exécution de commande

```java
new ProcessBuilder("pdftotext", chemin, "-").start();   // liste d'arguments
Runtime.getRuntime().exec("pdftotext " + chemin);       // INTERDIT
```

## SSRF

```java
URI uri = URI.create(brut);
if (!"https".equals(uri.getScheme())) throw new IllegalArgumentException();
InetAddress addr = InetAddress.getByName(uri.getHost());
if (addr.isSiteLocalAddress() || addr.isLoopbackAddress() || addr.isLinkLocalAddress()) {
    throw new IllegalArgumentException("Destination interne refusée");
}
HttpClient client = HttpClient.newBuilder()
    .followRedirects(HttpClient.Redirect.NEVER)
    .connectTimeout(Duration.ofSeconds(5))
    .build();
```

## Erreurs et Actuator

```yaml
server:
  error:
    include-stacktrace: never
    include-message: never
management:
  endpoints:
    web:
      exposure:
        include: health,info      # jamais '*'
  endpoint:
    health:
      show-details: when-authorized
```

`/actuator/env`, `/actuator/heapdump` et `/actuator/mappings` exposés
publiquement divulguent les secrets de configuration. C'est une cause récurrente
de compromission d'applications Spring Boot exposées.

## Journalisation

Neutraliser les retours à la ligne dans toute valeur venant de l'utilisateur avant
de l'écrire (log injection / forgerie d'entrées de journal) :

```java
log.info("Téléchargement doc={} par={}", id, username.replaceAll("[\r\n]", "_"));
```

Ne jamais journaliser un objet requête complet ni une entité utilisateur : leur
`toString()` embarque souvent le hachage du mot de passe ou un jeton.

## Audit de dépendances

```bash
mvn org.owasp:dependency-check-maven:check
mvn versions:display-dependency-updates
# ou, si le projet est sous Gradle
./gradlew dependencyCheckAnalyze
```

Vérifier en particulier les versions de `jackson-databind`, `snakeyaml`,
`log4j-core` et `spring-*` : ce sont les composants historiquement porteurs de
vulnérabilités critiques exploitées à distance.
