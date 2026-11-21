# tw/build.ps1 — 区域构建入口；实际逻辑在 tools/build-core.ps1
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$RepoPath,
    [switch]$Force
)
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $root 'tools/build-core.ps1') -Region 'tw' -RepoPath $RepoPath -Force:$Force
if (-not $?) { exit 1 }
exit $LASTEXITCODE
