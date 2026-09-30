[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RegistryPath,
    [Parameter(Mandatory)][string]$UpstreamRepository,
    [Parameter(Mandatory)][string]$UpstreamTag,
    [string]$IncludeDependents = '',
    [string]$ExcludeDependents = '',
    [switch]$Automatic,
    [switch]$DryRun,
    [string]$AppSlug = 'wbi-release-bot',
    [string]$WorkingDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'wbi-dependency-cascade')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DependencyCascade.psm1') -Force

function Add-SummaryLine([string]$Text = '') {
    $script:Summary.Add($Text)
}
function Invoke-Git {
    param([Parameter(Mandatory)][string]$RepositoryPath, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed:`n$($output -join "`n")" }
    $output
}
function Resolve-AssetName($Dependency, $VersionInfo, [string]$Tag) {
    ([string]$Dependency.asset_pattern).
        Replace('{version}', $VersionInfo.Version).
        Replace('{version_underscored}', $VersionInfo.Version.Replace('.', '_')).
        Replace('{tag}', $Tag)
}

$script:Summary = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
$registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json -ErrorAction Stop
$null = Assert-WbiDependencyRegistry $registry
$versionInfo = ConvertFrom-WbiVersionTag $UpstreamTag
$selected = @(Get-WbiSelectedDependents -Registry $registry -UpstreamRepository $UpstreamRepository `
    -IncludeDependents $IncludeDependents -ExcludeDependents $ExcludeDependents -Automatic:$Automatic)

Add-SummaryLine '# Dependency cascade'
Add-SummaryLine ''
Add-SummaryLine "- Upstream: ``$UpstreamRepository``"
Add-SummaryLine "- Release tag: ``$UpstreamTag``"
Add-SummaryLine "- Mode: $(if ($Automatic) { 'automatic' } else { 'selected/manual' })"
Add-SummaryLine "- Dry run: ``$($DryRun.IsPresent.ToString().ToLowerInvariant())``"
Add-SummaryLine "- Selected dependents: $(if ($selected.Count) { ($selected.repository -join ', ') } else { '(none)' })"
Add-SummaryLine ''
Add-SummaryLine '| Dependent | Old version | New version | Result |'
Add-SummaryLine '| --- | --- | --- | --- |'

if ($selected.Count -eq 0) {
    Add-SummaryLine '| — | — | — | No dependents selected |'
}

# Verify that the exact upstream release is published before touching any repository.
$releaseJson = & gh release view $UpstreamTag --repo $UpstreamRepository --json tagName,isDraft,isPrerelease,assets 2>&1
if ($LASTEXITCODE -ne 0) { throw "Could not read published release $UpstreamRepository@${UpstreamTag}: $($releaseJson -join "`n")" }
$release = $releaseJson | ConvertFrom-Json
if ([bool]$release.isDraft) { throw "Upstream release $UpstreamRepository@$UpstreamTag is still a draft." }

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$resolvedWorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
$workingLeaf = Split-Path -Leaf $resolvedWorkingDirectory
if (-not $resolvedWorkingDirectory.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -or
    $workingLeaf -notlike 'wbi-dependency-cascade*') {
    throw "WorkingDirectory must be a wbi-dependency-cascade directory beneath the system temporary directory."
}
if (Test-Path -LiteralPath $resolvedWorkingDirectory) {
    Remove-Item -LiteralPath $resolvedWorkingDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedWorkingDirectory -Force | Out-Null

foreach ($dependent in $selected) {
    $repository = [string]$dependent.repository
    $shortName = $repository.Split('/')[-1]
    $repoPath = Join-Path $resolvedWorkingDirectory $shortName
    $oldVersion = '—'
    $newVersion = '—'
    try {
        $assetName = Resolve-AssetName $dependent.dependency $versionInfo $UpstreamTag
        if (-not (@($release.assets).name -contains $assetName)) {
            throw "Published upstream release does not contain expected asset '$assetName'."
        }

        $cloneOutput = & gh repo clone $repository $repoPath -- --branch ([string]$dependent.default_branch) --single-branch 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not clone ${repository}: $($cloneOutput -join "`n")" }
        $null = Invoke-Git $repoPath fetch --tags --force

        $marker = "WBI-Dependency-Release: $UpstreamRepository@$UpstreamTag"
        $existingCommit = (& git -C $repoPath log --all --fixed-strings --grep=$marker --format=%H -1 2>$null | Select-Object -First 1)
        if ($existingCommit) {
            $message = (Invoke-Git $repoPath show -s --format=%B $existingCommit) -join "`n"
            $metadata = Get-WbiCascadeCommitMetadata $message
            if ($null -eq $metadata) { throw "Existing cascade commit $existingCommit has invalid retry metadata." }
            $targetTag = $metadata.ReleaseTag
            $newVersion = (ConvertFrom-WbiVersionTag $targetTag).Version
            $remoteTag = & git -C $repoPath ls-remote --tags origin "refs/tags/$targetTag" 2>$null
            if ($LASTEXITCODE -ne 0) { throw "Could not query remote tag '$targetTag'." }
            if ($remoteTag) {
                Add-SummaryLine "| ``$repository`` | — | ``$newVersion`` | Already completed; tag ``$targetTag`` exists |"
                continue
            }
            if ($DryRun) {
                Add-SummaryLine "| ``$repository`` | — | ``$newVersion`` | Would recover missing tag ``$targetTag`` at ``$existingCommit`` |"
                continue
            }
            $null = Invoke-Git $repoPath tag -a $targetTag $existingCommit -m "Release $newVersion"
            $null = Invoke-Git $repoPath push origin "refs/tags/$targetTag"
            Add-SummaryLine "| ``$repository`` | — | ``$newVersion`` | Recovered and pushed missing tag ``$targetTag`` |"
            continue
        }

        $versionPath = Join-Path $repoPath ([string]$dependent.version_file)
        $notesPath = Join-Path $repoPath ([string]$dependent.release_notes_path)
        $manifestPath = Join-Path $repoPath ([string]$dependent.dependency_manifest_path)
        foreach ($requiredPath in @($versionPath, $notesPath)) {
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Missing required file '$requiredPath'." }
        }

        $versionContent = Get-Content -LiteralPath $versionPath -Raw
        $current = Get-WbiVersionFromContent $versionContent
        $next = Get-WbiNextPatchVersion $versionContent
        $oldVersion = $current.Version
        $newVersion = $next.Version
        $targetTag = "$(if ($null -eq $dependent.tag_prefix) { '' } else { [string]$dependent.tag_prefix })$newVersion"

        $remoteTag = & git -C $repoPath ls-remote --tags origin "refs/tags/$targetTag" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not query remote tag '$targetTag'." }
        if ($remoteTag) { throw "Refusing to overwrite existing tag '$targetTag'." }

        $note = "Updated bundled $([string]$dependent.dependency.product_name) to version $($versionInfo.Version)."
        $updatedVersion = Set-WbiVersionContent $versionContent $next.Major $next.Minor $next.Patch
        $updatedNotes = Add-WbiReleaseNote (Get-Content -LiteralPath $notesPath -Raw) $note
        $existingManifest = if (Test-Path -LiteralPath $manifestPath) { Get-Content -LiteralPath $manifestPath -Raw } else { '' }
        $updatedManifest = Set-WbiDependencyManifestContent $existingManifest $UpstreamRepository $UpstreamTag $assetName `
            ([string]$dependent.dependency.source_path) ([string]$dependent.dependency.destination_path)

        [IO.File]::WriteAllText($versionPath, $updatedVersion)
        foreach ($additionalVersionFile in @($dependent.additional_version_files)) {
            $additionalPath = Join-Path $repoPath ([string]$additionalVersionFile)
            if (-not (Test-Path -LiteralPath $additionalPath -PathType Leaf)) {
                throw "Missing additional version file '$additionalPath'."
            }
            $additionalContent = Get-Content -LiteralPath $additionalPath -Raw
            [IO.File]::WriteAllText($additionalPath, (Set-WbiVersionContent $additionalContent $next.Major $next.Minor $next.Patch))
        }
        [IO.File]::WriteAllText($notesPath, $updatedNotes)
        New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force | Out-Null
        [IO.File]::WriteAllText($manifestPath, $updatedManifest + [Environment]::NewLine)

        $expectedPaths = @(
            ([string]$dependent.version_file).Replace('\', '/'),
            ([string]$dependent.release_notes_path).Replace('\', '/'),
            ([string]$dependent.dependency_manifest_path).Replace('\', '/')
        )
        $expectedPaths += @($dependent.additional_version_files | ForEach-Object { ([string]$_).Replace('\', '/') })
        $changedPaths = @(Invoke-Git $repoPath status --porcelain --untracked-files=all | ForEach-Object { $_.Substring(3).Replace('\', '/') })
        $unexpected = @($changedPaths | Where-Object { $_ -notin $expectedPaths })
        if ($unexpected.Count) { throw "Unexpected changed paths: $($unexpected -join ', ')." }
        if ($changedPaths.Count -eq 0) { throw 'No dependency-release changes were produced.' }

        if ($DryRun) {
            Add-SummaryLine "| ``$repository`` | ``$oldVersion`` | ``$newVersion`` | Would commit and push ``$targetTag`` |"
            continue
        }

        $botLogin = "$AppSlug[bot]"
        $botIdOutput = & gh api "/users/$botLogin" --jq .id 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Could not resolve GitHub App bot identity '$botLogin': $($botIdOutput -join "`n")" }
        $botId = ($botIdOutput | Select-Object -First 1).Trim()
        $null = Invoke-Git $repoPath config user.name $botLogin
        $null = Invoke-Git $repoPath config user.email "$botId+$botLogin@users.noreply.github.com"
        $null = Invoke-Git $repoPath add -- @($expectedPaths)
        $commitBody = @(
            "Bundle $([string]$dependent.dependency.product_name) $UpstreamTag",
            '',
            $marker,
            "WBI-Release-Tag: $targetTag"
        ) -join "`n"
        $null = Invoke-Git $repoPath commit -m $commitBody
        $commitSha = (Invoke-Git $repoPath rev-parse HEAD | Select-Object -First 1).Trim()
        $null = Invoke-Git $repoPath push origin "HEAD:refs/heads/$([string]$dependent.default_branch)"
        $null = Invoke-Git $repoPath tag -a $targetTag $commitSha -m "Release $newVersion"
        $null = Invoke-Git $repoPath push origin "refs/tags/$targetTag"
        Add-SummaryLine "| ``$repository`` | ``$oldVersion`` | ``$newVersion`` | Pushed commit ``$($commitSha.Substring(0, 7))`` and tag ``$targetTag`` |"
    }
    catch {
        $failures.Add("${repository}: $($_.Exception.Message)")
        Add-SummaryLine "| ``$repository`` | ``$oldVersion`` | ``$newVersion`` | **Failed:** $($_.Exception.Message.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')) |"
    }
}

Add-SummaryLine ''
if ($failures.Count) {
    Add-SummaryLine '## Recovery'
    Add-SummaryLine ''
    Add-SummaryLine 'Correct the reported cause and rerun with the same upstream repository and tag. Existing cascade commits and tags are detected and will not be duplicated.'
}
$summaryText = $script:Summary -join [Environment]::NewLine
Write-Host $summaryText
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summaryText }
if (Test-Path -LiteralPath $resolvedWorkingDirectory) {
    Remove-Item -LiteralPath $resolvedWorkingDirectory -Recurse -Force
}
if ($failures.Count) { throw "$($failures.Count) dependent release(s) failed: $($failures -join ' | ')" }
