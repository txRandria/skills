<#
.SYNOPSIS
  Installe les skills de sécurité pour Claude Code.
.DESCRIPTION
  Sans option : installation globale dans %USERPROFILE%\.claude\skills\
  -Project     : installation locale dans .\.claude\skills\ (partagée par git)
  -Force       : écrase un skill déjà présent
.EXAMPLE
  .\install.ps1
  .\install.ps1 -Project
  .\install.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Project,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$Skills = @(
    'secure-coding', 'secure-docker', 'secure-terraform',
    'secure-cicd', 'server-security-audit', 'security-audit-review'
)

$Src = $PSScriptRoot
$Dest = if ($Project) {
    Join-Path (Get-Location) '.claude\skills'
} else {
    Join-Path $env:USERPROFILE '.claude\skills'
}

if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Force -Path $Dest | Out-Null }

Write-Host "Source      : $Src"
Write-Host "Destination : $Dest"
Write-Host ""

$installes = 0
$ignores = 0

foreach ($s in $Skills) {
    $source = Join-Path $Src $s
    $cible = Join-Path $Dest $s

    if (-not (Test-Path (Join-Path $source 'SKILL.md'))) {
        Write-Host "  ABSENT   $s (SKILL.md introuvable dans la source)"
        continue
    }

    # Ne jamais écraser sans le demander : un skill présent peut avoir été modifié.
    if ((Test-Path $cible) -and (-not $Force)) {
        Write-Host "  IGNORE   $s (deja present -- relancer avec -Force pour ecraser)"
        $ignores++
        continue
    }

    if (Test-Path $cible) { Remove-Item -Recurse -Force $cible }
    Copy-Item -Recurse $source $cible
    Write-Host "  INSTALLE $s"
    $installes++
}

Write-Host ""
Write-Host "--- $installes installe(s), $ignores ignore(s) ---"

# Controle d'integrite : un \r en fin de ligne casse l'analyse de l'en-tete YAML.
# Le skill se charge alors sans sa description et ne se declenche plus tout seul.
Write-Host ""
Write-Host "Controle des fins de ligne :"
$probleme = $false
foreach ($s in $Skills) {
    $f = Join-Path $Dest "$s\SKILL.md"
    if (-not (Test-Path $f)) { continue }
    $octets = [System.IO.File]::ReadAllBytes($f)
    if ($octets -contains 13) {
        Write-Host "  CRLF DETECTE dans $f"
        Write-Host "    Corriger : [System.IO.File]::WriteAllText('$f', ((Get-Content -Raw '$f') -replace \"`r`n\", \"`n\"))"
        $probleme = $true
    }
}
if (-not $probleme) { Write-Host "  OK -- tous les SKILL.md sont en LF" }

Write-Host ""
Write-Host "Verifier dans Claude Code avec : /skills"
Write-Host "Les six skills doivent apparaitre avec leur description complete."
