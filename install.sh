#!/usr/bin/env bash
# Installe les skills de sécurité dans ~/.claude/skills/
# Usage : ./install.sh [--project] [--force]
#   (sans option) : installation globale dans ~/.claude/skills/
#   --project     : installation locale dans ./.claude/skills/ (partagée par git)
#   --force       : écrase un skill déjà présent

set -euo pipefail

SKILLS=(secure-coding secure-docker secure-terraform secure-cicd
        server-security-audit security-audit-review)

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/skills"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --project) DEST="$PWD/.claude/skills" ;;
    --force)   FORCE=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "Option inconnue : $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$DEST"
echo "Source      : $SRC"
echo "Destination : $DEST"
echo

installes=0
ignores=0

for s in "${SKILLS[@]}"; do
  if [ ! -f "$SRC/$s/SKILL.md" ]; then
    echo "  ABSENT   $s (SKILL.md introuvable dans la source)"
    continue
  fi

  # Ne jamais écraser sans le demander : un skill présent peut avoir été modifié.
  if [ -e "$DEST/$s" ] && [ "$FORCE" -eq 0 ]; then
    echo "  IGNORÉ   $s (déjà présent — relancer avec --force pour écraser)"
    ignores=$((ignores + 1))
    continue
  fi

  rm -rf "$DEST/$s"
  cp -r "$SRC/$s" "$DEST/$s"
  echo "  INSTALLÉ $s"
  installes=$((installes + 1))
done

echo
echo "--- $installes installé(s), $ignores ignoré(s) ---"

# Contrôle d'intégrité : un \r en fin de ligne casse l'analyse de l'en-tête YAML,
# le skill se charge alors sans sa description et ne se déclenche plus tout seul.
echo
echo "Contrôle des fins de ligne :"
probleme=0
for s in "${SKILLS[@]}"; do
  f="$DEST/$s/SKILL.md"
  [ -f "$f" ] || continue
  if grep -qU $'\r' "$f" 2>/dev/null || grep -q $'\r' "$f" 2>/dev/null; then
    echo "  CRLF DÉTECTÉ dans $f — corriger avec : sed -i 's/\r$//' \"$f\""
    probleme=1
  fi
done
[ "$probleme" -eq 0 ] && echo "  OK — tous les SKILL.md sont en LF"

echo
echo "Vérifier dans Claude Code avec : /skills"
echo "Les six skills doivent apparaître avec leur description complète."
