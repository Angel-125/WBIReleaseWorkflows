[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$Workspace = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DependencyCascade.psm1') -Force

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    Write-Host "No exact dependency manifest found at $ManifestPath."
    if ($env:GITHUB_OUTPUT) { Add-Content $env:GITHUB_OUTPUT 'wildbluecore_managed=false' }
    return
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
if ([int]$manifest.schema_version -ne 1) { throw 'Dependency manifest schema_version must be 1.' }
$wildBlueCoreManaged = $false
$index = 0
foreach ($dependency in @($manifest.dependencies)) {
    $index++
    $repository = [string]$dependency.repository
    $tag = [string]$dependency.tag
    $assetName = [string]$dependency.asset_name
    $sourcePath = [string]$dependency.source_path
    $destinationPath = [string]$dependency.destination_path
    if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid dependency repository '$repository'." }
    $null = ConvertFrom-WbiVersionTag $tag
    foreach ($path in @($sourcePath, $destinationPath)) {
        if (-not (Test-WbiSafeRelativePath $path)) { throw "Unsafe dependency path '$path'." }
    }
    if (-not $destinationPath.Replace('\', '/').StartsWith('ReleaseFolder/GameData/')) {
        throw "Dependency destination must be inside ReleaseFolder/GameData: '$destinationPath'."
    }
    if ($assetName -notmatch '^[A-Za-z0-9._-]+\.zip$') { throw "Unsafe dependency asset name '$assetName'." }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "wbi-release-dependency-$index-$([guid]::NewGuid().ToString('N'))"
    $download = Join-Path $tempRoot 'download'
    $expanded = Join-Path $tempRoot 'expanded'
    New-Item -ItemType Directory -Path $download, $expanded -Force | Out-Null
    try {
        $output = & gh release download $tag --repo $repository --pattern $assetName --dir $download 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not download ${repository}@${tag} asset '$assetName': $($output -join "`n")" }
        $assets = @(Get-ChildItem -LiteralPath $download -File)
        if ($assets.Count -ne 1 -or $assets[0].Name -ne $assetName) {
            throw "Expected exactly '$assetName' from ${repository}@${tag}."
        }
        Expand-Archive -LiteralPath $assets[0].FullName -DestinationPath $expanded -Force
        $source = Join-Path $expanded $sourcePath
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            throw "Dependency asset '$assetName' does not contain '$sourcePath'."
        }
        $destination = Join-Path $Workspace $destinationPath
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
        Write-Host "Installed $repository@$tag from $assetName into $destinationPath."
        if ([string]::Equals($repository, 'Angel-125/WildBlueCore', [System.StringComparison]::OrdinalIgnoreCase)) {
            $wildBlueCoreManaged = $true
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}
if ($env:GITHUB_OUTPUT) { Add-Content $env:GITHUB_OUTPUT "wildbluecore_managed=$($wildBlueCoreManaged.ToString().ToLowerInvariant())" }
