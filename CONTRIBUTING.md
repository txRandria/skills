# Contributing

Thank you for helping improve these security skills.

## Useful contributions

The most valuable reports describe a concrete gap between a declared control and its effective behavior:

- a verification command that misses a real issue;
- a reproducible false positive;
- a framework, cloud provider, or runtime version that changes the expected behavior;
- a security mechanism that is not yet covered;
- a command that succeeds but provides incomplete or misleading evidence.

Please avoid generic rule lists without an executable validation method.

## Before opening an issue

1. Remove credentials, customer data, internal hostnames, and other sensitive information.
2. Identify the affected skill and reference file.
3. Describe the environment and relevant versions.
4. Provide the expected behavior, observed behavior, and a minimal reproduction when possible.
5. Explain how the proposed check proves the effective result.

## Pull requests

1. Create a focused branch.
2. Keep the main `SKILL.md` concise and route detailed material to `references/`.
3. Preserve LF line endings in all Markdown files.
4. Do not invent image digests, action SHAs, or external identifiers.
5. Anchor framework-specific guidance to the applicable version.
6. Test every executable command and inspect its output, not only its exit code.
7. Update both README files when user-facing behavior changes.

## Local checks

```bash
# No CRLF in skill entry points
if grep -Il $'\r' */SKILL.md; then
  echo "CRLF detected in SKILL.md"
  exit 1
fi

# Every skill must declare name and description
for file in */SKILL.md; do
  grep -q '^name: ' "$file"
  grep -q '^description: ' "$file"
done
```

By contributing, you agree that your work is provided under the repository's
[CC BY 4.0 license](LICENSE).
