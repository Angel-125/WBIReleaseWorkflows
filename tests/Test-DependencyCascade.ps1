$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\DependencyCascade.psm1') -Force

$script:Failures = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failures++
        Write-Host "FAIL $Name`n  $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Assert-Equal($Expected, $Actual) {
    if ($Expected -ne $Actual) { throw "Expected '$Expected', received '$Actual'." }
}
function Assert-Throws([scriptblock]$Body) {
    try { & $Body; throw 'Expected an exception, but none was thrown.' }
    catch {
        if ($_.Exception.Message -eq 'Expected an exception, but none was thrown.') { throw }
    }
}

$versionContent = @'
{
  "VERSION": { "MAJOR": 1, "MINOR": 5, "PATCH": 1 },
  "KSP_VERSION": { "MAJOR": 1, "MINOR": 12, "PATCH": 5 }
}
'@

Test-Case 'parses tags with and without v' {
    Assert-Equal '1.5.1' (ConvertFrom-WbiVersionTag 'v1.5.1').Version
    Assert-Equal '' (ConvertFrom-WbiVersionTag '1.5.1').Prefix
    Assert-Throws { ConvertFrom-WbiVersionTag 'v1.5.1.1' }
}
Test-Case 'increments only the patch version' {
    Assert-Equal '1.5.2' (Get-WbiNextPatchVersion $versionContent).Version
}
Test-Case 'updates mod version without changing KSP version' {
    $updated = Set-WbiVersionContent $versionContent 2 3 4
    Assert-Equal '2.3.4' (Get-WbiVersionFromContent $updated).Version
    Assert-Equal 12 (($updated | ConvertFrom-Json).KSP_VERSION.MINOR)
}
Test-Case 'inserts release notes once and preserves CRLF' {
    $content = "Header`r`n---CHANGES---`r`n`r`n- Existing`r`n`r`n---END CHANGES---`r`n"
    $updated = Add-WbiReleaseNote $content 'Updated bundled WildBlueCore to version 1.6.0.'
    if (-not $updated.Contains("`r`n")) { throw 'CRLF was not preserved.' }
    Assert-Equal 1 ([regex]::Matches($updated, 'Updated bundled').Count)
    $again = Add-WbiReleaseNote $updated 'Updated bundled WildBlueCore to version 1.6.0.'
    Assert-Equal $updated $again
}
Test-Case 'rejects missing release-note markers' {
    Assert-Throws { Add-WbiReleaseNote 'No markers' 'A note.' }
}

$registry = @'
{
  "schema_version": 1,
  "upstreams": [{
    "repository": "Angel-125/WildBlueCore",
    "cascade_mode": "manual",
    "dependents": [{
      "repository": "Angel-125/Sandcastle",
      "default_branch": "main",
      "product_name": "Sandcastle",
      "version_file": "ReleaseFolder/GameData/WildBlueIndustries/Sandcastle/Sandcastle.version",
      "additional_version_files": [],
      "release_notes_path": "ReleaseFolder/GameData/WildBlueIndustries/Sandcastle/Readme.txt",
      "dependency_manifest_path": ".wbi-release/dependencies.json",
      "tag_prefix": "v",
      "automatic_cascade": true,
      "dependency": {
        "product_name": "WildBlueCore",
        "asset_pattern": "WildBlueCore_{version_underscored}.zip",
        "source_path": "GameData/WildBlueIndustries/00WildBlueCore",
        "destination_path": "ReleaseFolder/GameData/WildBlueIndustries/00WildBlueCore"
      }
    }]
  }]
}
'@ | ConvertFrom-Json

Test-Case 'validates and selects registered dependents' {
    Assert-Equal $true (Assert-WbiDependencyRegistry $registry)
    Assert-Equal 1 @(Get-WbiSelectedDependents $registry 'Angel-125/WildBlueCore' 'Sandcastle').Count
    Assert-Equal 0 @(Get-WbiSelectedDependents $registry 'Angel-125/WildBlueCore' -Automatic).Count
    Assert-Equal 0 @(Get-WbiSelectedDependents $registry 'Angel-125/WildBlueCore' -ExcludeDependents 'Sandcastle').Count
    Assert-Throws { Get-WbiSelectedDependents $registry 'Angel-125/WildBlueCore' 'UnknownMod' }
}
Test-Case 'orders upstreams before dependents' {
    $order = @(Get-WbiDependencyOrder $registry)
    if ([array]::IndexOf($order, 'Angel-125/WildBlueCore') -gt [array]::IndexOf($order, 'Angel-125/Sandcastle')) {
        throw 'Dependent was ordered before its upstream.'
    }
}
Test-Case 'detects dependency cycles' {
    $cyclic = $registry | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $cyclic.upstreams += [pscustomobject]@{
        repository = 'Angel-125/Sandcastle'; cascade_mode = 'manual'; dependents = @(
            [pscustomobject]@{
                repository='Angel-125/WildBlueCore'; default_branch='main'; product_name='WildBlueCore'
                version_file='ReleaseFolder/GameData/a.version'; release_notes_path='ReleaseFolder/GameData/Readme.txt'
                dependency_manifest_path='.wbi-release/dependencies.json'; tag_prefix='v'; automatic_cascade=$false
                dependency=[pscustomobject]@{ product_name='Sandcastle'; asset_pattern='Sandcastle_*.zip'; source_path='GameData/a'; destination_path='ReleaseFolder/GameData/a' }
            }
        )
    }
    Assert-Throws { Assert-WbiDependencyRegistry $cyclic }
}
Test-Case 'parses retry metadata from a cascade commit' {
    $metadata = Get-WbiCascadeCommitMetadata "Bundle WildBlueCore v1.6.0`n`nWBI-Dependency-Release: Angel-125/WildBlueCore@v1.6.0`nWBI-Release-Tag: v1.5.2"
    Assert-Equal 'Angel-125/WildBlueCore' $metadata.UpstreamRepository
    Assert-Equal 'v1.6.0' $metadata.UpstreamTag
    Assert-Equal 'v1.5.2' $metadata.ReleaseTag
    Assert-Equal $null (Get-WbiCascadeCommitMetadata 'Ordinary commit')
}
Test-Case 'updates dependency manifest idempotently' {
    $first = Set-WbiDependencyManifestContent '' 'Angel-125/WildBlueCore' 'v1.6.0' 'WildBlueCore_1_6_0.zip' 'GameData/WildBlueIndustries/00WildBlueCore' 'ReleaseFolder/GameData/WildBlueIndustries/00WildBlueCore'
    $second = Set-WbiDependencyManifestContent $first 'Angel-125/WildBlueCore' 'v1.6.0' 'WildBlueCore_1_6_0.zip' 'GameData/WildBlueIndustries/00WildBlueCore' 'ReleaseFolder/GameData/WildBlueIndustries/00WildBlueCore'
    Assert-Equal 1 @(($second | ConvertFrom-Json).dependencies).Count
}

Test-Case 'splats git add paths as separate arguments' {
    $cascadeScript = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-DependencyCascade.ps1') -Raw
    if ($cascadeScript -notmatch [regex]::Escape('Invoke-Git $repoPath add -- @expectedPaths')) {
        throw 'Dependency cascade does not splat expected git-add paths.'
    }
    if ($cascadeScript -match [regex]::Escape('Invoke-Git $repoPath add -- @($expectedPaths)')) {
        throw 'Dependency cascade passes git-add paths as a nested array.'
    }
}

Test-Case 'splats annotated-tag arguments to avoid parameter binding' {
    $cascadeScript = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-DependencyCascade.ps1') -Raw
    Assert-Equal 2 ([regex]::Matches($cascadeScript, [regex]::Escape('Invoke-Git $repoPath @tagArguments')).Count)
    if ($cascadeScript -match [regex]::Escape('Invoke-Git $repoPath tag -a')) {
        throw 'Dependency cascade passes annotated-tag switches through PowerShell parameter binding.'
    }
}

if ($script:Failures -gt 0) { throw "$script:Failures dependency-cascade test(s) failed." }
Write-Host 'All dependency-cascade tests passed.'
