# Verifiable Security Skills for Claude Code

**English** · [Français](README.md)

![Claude Code](https://img.shields.io/badge/Claude_Code-Skills-6D5DFF)
![DevSecOps](https://img.shields.io/badge/DevSecOps-security--by--default-0A7B83)
![License](https://img.shields.io/badge/license-CC_BY_4.0-blue)

Six open-source Claude Code skills for secure coding, Docker, Terraform, CI/CD pipelines, and Linux server audits.

> Do not trust the configuration. Verify the observable effect.

Most security guidance checks whether a rule exists in source code or configuration. This project checks whether the protection actually works at runtime: whether the container is really non-root, whether traffic crosses the firewall chain, whether a rotated credential is truly invalid, and whether a scanner finding is unique and actionable.

Created by **[Tahina Fabien RANDRIAMAMPIANINA](https://www.linkedin.com/in/fabien-tahina-8317b7344/)**, a DevOps & Cloud Engineer based in Madagascar and open to international remote opportunities · [GitHub @txRandria](https://github.com/txRandria).

If this project helps your team, please give it a star and share concrete feedback through [GitHub Issues](https://github.com/txRandria/skills/issues).

## Skills

| Skill | Trigger | Coverage |
|---|---|---|
| **[secure-coding](secure-coding/)** | Code handles user input, authentication, databases, uploads, secrets, or logs | 14 cross-cutting rules, Node.js/Express, React/Next.js, Python, PHP, Java, and a review checklist |
| **[secure-docker](secure-docker/)** | A Dockerfile, Compose file, or `.dockerignore` is created or changed | 12 rules, hardened multi-stage templates, Compose hardening, and verified scans |
| **[secure-terraform](secure-terraform/)** | Terraform configuration, state, providers, or an apply workflow is involved | 12 rules, secrets and state, AWS, GCP, Azure, scanning, and delivery pipelines |
| **[secure-cicd](secure-cicd/)** | A CI/CD pipeline, deployment step, or CI variable is changed | 12 rules, GitLab CI, GitHub Actions, SBOMs, signing, and dependency pinning |
| **[server-security-audit](server-security-audit/)** | A live server is audited, investigated, or onboarded | Read-only discovery followed by exposure, effective configuration, privilege, compromise, remediation, and reporting phases |
| **[security-audit-review](security-audit-review/)** | A SAST, SCA, vulnerability scan, or penetration-test report must be reviewed | Triage, deduplication, remediation validation, score recalculation, and false-positive patterns |

The skills load automatically when Claude Code detects a matching task. They can also be invoked explicitly.

## Quick start

### Linux and macOS

```bash
git clone https://github.com/txRandria/skills.git
cd skills
./install.sh
```

### Windows PowerShell

```powershell
git clone https://github.com/txRandria/skills.git
cd skills
.\install.ps1
```

The installer copies all six skills to the global Claude Code skills directory. Run `/skills` inside Claude Code to verify the installation.

## Example prompts

```text
Create a production-ready Dockerfile for this Node.js service.
Review this Terraform module before apply.
Audit this Linux server through SSH without changing anything.
Review this SAST report, remove duplicates, and validate the proposed fixes.
```

## What makes this project different

- **Runtime evidence over configuration claims.** A declared control is not considered effective until its behavior is observed.
- **Version-aware guidance.** Each skill reads the project manifest before proposing framework-specific code.
- **Read-only audit collection.** Observation and remediation are separated so evidence is not destroyed.
- **No invented digests or commit SHAs.** Resolution commands are supplied where immutable identifiers are required.
- **Progressive disclosure.** Small `SKILL.md` entry points route to detailed references only when needed.
- **Production-inspired failure modes.** The checks cover real gaps involving containers, firewall paths, proxies, credentials, and duplicated findings.

## Verification example

```bash
docker run --rm -i hadolint/hadolint:latest-alpine < Dockerfile
MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD:/src" aquasec/trivy:latest config /src
docker run --rm --entrypoint id app:audit
docker history --no-trunc app:audit | grep -i secret
```

The `id` check proves the effective runtime user. Merely finding a `USER` instruction in a Dockerfile does not.

## What this repository demonstrates

This project is also a practical DevSecOps portfolio: secure-by-default engineering, Linux operations, Docker hardening, multi-cloud Terraform, CI/CD supply-chain controls, incident investigation, and evidence-based security reviews.

## Contributing

Concrete failure cases are especially valuable: a rule that does not apply, a verification command that produces a false negative, or a security mechanism that is not covered. Please open an issue with reproducible context.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow.

## License

[CC BY 4.0](LICENSE) — sharing and adaptation are allowed, including commercial use, with attribution.
