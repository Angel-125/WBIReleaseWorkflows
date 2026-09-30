Set-StrictMode -Version Latest

function ConvertFrom-WbiVersionTag {
    param([Parameter(Mandatory)][string]$Tag)

    if ($Tag -notmatch '^v?(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
        throw "Version tag must use [v]<major>.<minor>.<patch>; received '$Tag'."
    }

    [pscustomobject]@{
        Major = [int]$Matches.major
        Minor = [int]$Matches.minor
        Patch = [int]$Matches.patch
        Version = "$($Matches.major).$($Matches.minor).$($Matches.patch)"
        Prefix = if ($Tag.StartsWith('v')) { 'v' } else { '' }
    }
}

function Get-WbiVersionFromContent {
    param([Parameter(Mandatory)][string]$Content)

    try {
        $document = $Content | ConvertFrom-Json -ErrorAction Stop
        $version = $document.VERSION
        if ($null -eq $version) { throw 'Missing VERSION object.' }
        [pscustomobject]@{
            Major = [int]$version.MAJOR
            Minor = [int]$version.MINOR
            Patch = [int]$version.PATCH
            Version = "$([int]$version.MAJOR).$([int]$version.MINOR).$([int]$version.PATCH)"
        }
    }
    catch {
        throw "Could not read VERSION.MAJOR, VERSION.MINOR, and VERSION.PATCH: $($_.Exception.Message)"
    }
}

function Get-WbiNextPatchVersion {
    param([Parameter(Mandatory)][string]$Content)

    $current = Get-WbiVersionFromContent -Content $Content
    [pscustomobject]@{
        Major = $current.Major
        Minor = $current.Minor
        Patch = $current.Patch + 1
        Version = "$($current.Major).$($current.Minor).$($current.Patch + 1)"
    }
}

function Set-WbiVersionContent {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][int]$Major,
        [Parameter(Mandatory)][int]$Minor,
        [Parameter(Mandatory)][int]$Patch
    )

    # Validate before editing, then preserve the repository's existing formatting.
    $null = Get-WbiVersionFromContent -Content $Content
    $result = $Content
    foreach ($field in @(
        @{ Name = 'MAJOR'; Value = $Major },
        @{ Name = 'MINOR'; Value = $Minor },
        @{ Name = 'PATCH'; Value = $Patch }
    )) {
        $pattern = '(?m)("' + $field.Name + '"\s*:\s*)\d+'
        $matches = [regex]::Matches($result, $pattern)
        if ($matches.Count -lt 1) {
            throw "Could not find VERSION.$($field.Name) in the version file."
        }

        # Only replace the first occurrence: later MAJOR/MINOR/PATCH fields commonly
        # belong to KSP_VERSION and must remain unchanged.
        $regex = [regex]::new($pattern)
        $result = $regex.Replace(
            $result,
            { param($match) $match.Groups[1].Value + [string]$field.Value },
            1
        )
    }

    $updated = Get-WbiVersionFromContent -Content $result
    if ($updated.Version -ne "$Major.$Minor.$Patch") {
        throw "Version-file update verification failed; expected $Major.$Minor.$Patch but read $($updated.Version)."
    }
    $result
}

function Add-WbiReleaseNote {
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Note,
        [string]$StartMarker = '---CHANGES---',
        [string]$EndMarker = '---END CHANGES---'
    )

    if ($Content.Contains($Note, [System.StringComparison]::Ordinal)) {
        return $Content
    }

    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $startPattern = '(?m)^' + [regex]::Escape($StartMarker) + '\r?$'
    $endPattern = '(?m)^' + [regex]::Escape($EndMarker) + '\r?$'
    $start = [regex]::Match($Content, $startPattern)
    $end = [regex]::Match($Content, $endPattern)
    if (-not $start.Success -or -not $end.Success -or $end.Index -le $start.Index) {
        throw "Could not find an ordered '$StartMarker' / '$EndMarker' release-note section."
    }

    $insertAt = $start.Index + $start.Length
    $before = $Content.Substring(0, $insertAt)
    $after = $Content.Substring($insertAt).TrimStart("`r", "`n")
    "$before$newline$newline- $Note$newline$newline$after"
}

function Test-WbiSafeRelativePath {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path)) { return $false }
    $normalized = $Path.Replace('\', '/')
    if ($normalized -match '(^|/)\.\.(/|$)') { return $false }
    return $true
}

function Assert-WbiDependencyRegistry {
    param([Parameter(Mandatory)]$Registry)

    if ([int]$Registry.schema_version -ne 1) { throw 'Registry schema_version must be 1.' }
    if ($null -eq $Registry.upstreams -or @($Registry.upstreams).Count -eq 0) {
        throw 'Registry must contain at least one upstream.'
    }

    $upstreamNames = @{}
    $graph = @{}
    foreach ($upstream in @($Registry.upstreams)) {
        $name = [string]$upstream.repository
        if ($name -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid upstream repository '$name'." }
        $key = $name.ToLowerInvariant()
        if ($upstreamNames.ContainsKey($key)) { throw "Duplicate upstream repository '$name'." }
        $upstreamNames[$key] = $true
        if ([string]$upstream.cascade_mode -notin @('automatic', 'manual', 'disabled')) {
            throw "Upstream '$name' has invalid cascade_mode '$($upstream.cascade_mode)'."
        }

        $graph[$key] = @()
        $dependentNames = @{}
        foreach ($dependent in @($upstream.dependents)) {
            $dependentName = [string]$dependent.repository
            if ($dependentName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
                throw "Invalid dependent repository '$dependentName'."
            }
            $dependentKey = $dependentName.ToLowerInvariant()
            if ($dependentNames.ContainsKey($dependentKey)) {
                throw "Upstream '$name' contains duplicate dependent '$dependentName'."
            }
            $dependentNames[$dependentKey] = $true
            $graph[$key] += $dependentKey

            foreach ($pathName in @('version_file', 'release_notes_path', 'dependency_manifest_path')) {
                $pathValue = [string]$dependent.$pathName
                if (-not (Test-WbiSafeRelativePath -Path $pathValue)) {
                    throw "Dependent '$dependentName' has unsafe $pathName '$pathValue'."
                }
            }
            foreach ($additionalPath in @($dependent.additional_version_files)) {
                if (-not (Test-WbiSafeRelativePath -Path ([string]$additionalPath))) {
                    throw "Dependent '$dependentName' has unsafe additional_version_files entry '$additionalPath'."
                }
            }
            foreach ($pathName in @('source_path', 'destination_path')) {
                $pathValue = [string]$dependent.dependency.$pathName
                if (-not (Test-WbiSafeRelativePath -Path $pathValue)) {
                    throw "Dependent '$dependentName' has unsafe dependency.$pathName '$pathValue'."
                }
            }
            if (-not ([string]$dependent.dependency.destination_path).Replace('\', '/').StartsWith('ReleaseFolder/GameData/')) {
                throw "Dependent '$dependentName' dependency destination must be inside ReleaseFolder/GameData."
            }
            if ([string]::IsNullOrWhiteSpace([string]$dependent.dependency.asset_pattern)) {
                throw "Dependent '$dependentName' must define dependency.asset_pattern."
            }
        }
    }

    # Detect cycles among repositories that are also registered upstreams.
    $visiting = @{}
    $visited = @{}
    function Visit-RegistryNode([string]$Node) {
        if ($visiting.ContainsKey($Node)) { throw "Dependency cycle detected at '$Node'." }
        if ($visited.ContainsKey($Node)) { return }
        $visiting[$Node] = $true
        foreach ($next in @($graph[$Node])) {
            if ($graph.ContainsKey($next)) { Visit-RegistryNode $next }
        }
        $visiting.Remove($Node)
        $visited[$Node] = $true
    }
    foreach ($node in @($graph.Keys)) { Visit-RegistryNode $node }

    $true
}

function Get-WbiSelectedDependents {
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$UpstreamRepository,
        [string]$IncludeDependents = '',
        [string]$ExcludeDependents = '',
        [switch]$Automatic
    )

    $null = Assert-WbiDependencyRegistry -Registry $Registry
    $upstream = @($Registry.upstreams) | Where-Object {
        [string]::Equals([string]$_.repository, $UpstreamRepository, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ($null -eq $upstream) { throw "Upstream '$UpstreamRepository' is not registered." }
    if ([string]$upstream.cascade_mode -eq 'disabled') { return @() }
    if ($Automatic -and [string]$upstream.cascade_mode -ne 'automatic') { return @() }

    $dependents = @($upstream.dependents)
    if ($Automatic) {
        $dependents = @($dependents | Where-Object { [bool]$_.automatic_cascade })
    }

    function Split-Selection([string]$Value) {
        @($Value.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    function Matches-Selection($Dependent, [string]$Value) {
        $repository = [string]$Dependent.repository
        $shortName = $repository.Split('/')[-1]
        [string]::Equals($repository, $Value, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($shortName, $Value, [System.StringComparison]::OrdinalIgnoreCase)
    }

    $include = @(Split-Selection $IncludeDependents)
    $exclude = @(Split-Selection $ExcludeDependents)
    $allRegistered = @($upstream.dependents)
    foreach ($selection in @($include + $exclude)) {
        if (-not ($allRegistered | Where-Object { Matches-Selection $_ $selection })) {
            throw "Dependent selection '$selection' is not registered for '$UpstreamRepository'."
        }
    }
    if ($include.Count -gt 0) {
        $dependents = @($dependents | Where-Object {
            $candidate = $_
            $include | Where-Object { Matches-Selection $candidate $_ }
        })
    }
    if ($exclude.Count -gt 0) {
        $dependents = @($dependents | Where-Object {
            $candidate = $_
            -not ($exclude | Where-Object { Matches-Selection $candidate $_ })
        })
    }
    @($dependents)
}

function Get-WbiDependencyOrder {
    param([Parameter(Mandatory)]$Registry)

    $null = Assert-WbiDependencyRegistry $Registry
    $displayNames = @{}
    $edges = @{}
    $inDegree = @{}
    foreach ($upstream in @($Registry.upstreams)) {
        $upstreamKey = ([string]$upstream.repository).ToLowerInvariant()
        $displayNames[$upstreamKey] = [string]$upstream.repository
        if (-not $edges.ContainsKey($upstreamKey)) { $edges[$upstreamKey] = @() }
        if (-not $inDegree.ContainsKey($upstreamKey)) { $inDegree[$upstreamKey] = 0 }
        foreach ($dependent in @($upstream.dependents)) {
            $dependentKey = ([string]$dependent.repository).ToLowerInvariant()
            $displayNames[$dependentKey] = [string]$dependent.repository
            if (-not $edges.ContainsKey($dependentKey)) { $edges[$dependentKey] = @() }
            if (-not $inDegree.ContainsKey($dependentKey)) { $inDegree[$dependentKey] = 0 }
            if ($dependentKey -notin $edges[$upstreamKey]) {
                $edges[$upstreamKey] += $dependentKey
                $inDegree[$dependentKey]++
            }
        }
    }

    $queue = [System.Collections.Generic.List[string]]::new()
    foreach ($node in @($inDegree.Keys | Sort-Object)) {
        if ($inDegree[$node] -eq 0) { $queue.Add($node) }
    }
    $ordered = [System.Collections.Generic.List[string]]::new()
    while ($queue.Count) {
        $node = $queue[0]
        $queue.RemoveAt(0)
        $ordered.Add($displayNames[$node])
        foreach ($next in @($edges[$node] | Sort-Object)) {
            $inDegree[$next]--
            if ($inDegree[$next] -eq 0) { $queue.Add($next) }
        }
        $queue.Sort()
    }
    if ($ordered.Count -ne $inDegree.Count) { throw 'Dependency cycle prevented release ordering.' }
    @($ordered)
}

function Get-WbiCascadeCommitMetadata {
    param([Parameter(Mandatory)][string]$Message)

    if ($Message -notmatch '(?m)^WBI-Dependency-Release:\s*(?<upstream>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@(?<upstreamTag>v?\d+\.\d+\.\d+)\s*$') {
        return $null
    }
    $upstream = $Matches.upstream
    $upstreamTag = $Matches.upstreamTag
    if ($Message -notmatch '(?m)^WBI-Release-Tag:\s*(?<releaseTag>v?\d+\.\d+\.\d+)\s*$') {
        throw 'Cascade commit records WBI-Dependency-Release but not WBI-Release-Tag.'
    }
    [pscustomobject]@{
        UpstreamRepository = $upstream
        UpstreamTag = $upstreamTag
        ReleaseTag = $Matches.releaseTag
    }
}

function Set-WbiDependencyManifestContent {
    param(
        [string]$Content,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$AssetName,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $manifest = if ([string]::IsNullOrWhiteSpace($Content)) {
        [pscustomobject]@{ schema_version = 1; dependencies = @() }
    } else {
        $Content | ConvertFrom-Json -ErrorAction Stop
    }
    if ([int]$manifest.schema_version -ne 1) { throw 'Dependency manifest schema_version must be 1.' }

    $dependencies = @($manifest.dependencies | Where-Object {
        -not [string]::Equals([string]$_.repository, $Repository, [System.StringComparison]::OrdinalIgnoreCase)
    })
    $dependencies += [pscustomobject]@{
        repository = $Repository
        tag = $Tag
        asset_name = $AssetName
        source_path = $SourcePath
        destination_path = $DestinationPath
    }
    $manifest.dependencies = @($dependencies | Sort-Object repository)
    $manifest | ConvertTo-Json -Depth 10
}

Export-ModuleMember -Function @(
    'ConvertFrom-WbiVersionTag',
    'Get-WbiVersionFromContent',
    'Get-WbiNextPatchVersion',
    'Set-WbiVersionContent',
    'Add-WbiReleaseNote',
    'Test-WbiSafeRelativePath',
    'Assert-WbiDependencyRegistry',
    'Get-WbiSelectedDependents',
    'Get-WbiDependencyOrder',
    'Get-WbiCascadeCommitMetadata',
    'Set-WbiDependencyManifestContent'
)
