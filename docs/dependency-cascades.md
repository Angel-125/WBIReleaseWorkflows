# Dependency cascade design

## Components

- [`config/dependency-registry.json`](../config/dependency-registry.json) declares upstream/dependent relationships and repository-specific paths.
- [`scripts/DependencyCascade.psm1`](../scripts/DependencyCascade.psm1) contains tested parsing, editing, selection, ordering, and validation functions.
- [`scripts/Invoke-DependencyCascade.ps1`](../scripts/Invoke-DependencyCascade.ps1) performs dry runs or authenticated commits and tags.
- [`scripts/Install-ReleaseDependencies.ps1`](../scripts/Install-ReleaseDependencies.ps1) downloads exact published dependency assets during packaging.
- [`.github/workflows/dependency-cascade.yml`](../.github/workflows/dependency-cascade.yml) is the reusable GitHub App-backed cascade.
- [`.github/workflows/publish-ksp-mod.yml`](../.github/workflows/publish-ksp-mod.yml) remains backward-compatible with `bundle_wildbluecore` and also consumes exact dependency manifests.

## Registry policy

Each upstream has one of three modes:

- `automatic`: a chained tag job selects dependents with `automatic_cascade: true`.
- `manual`: automatic calls select nothing; a manual caller can select all, include names, or exclude names.
- `disabled`: neither automatic nor manual selection produces dependents.

The initial WildBlueCore entry is `manual`. Buffalo2, Sandcastle, and SunkWorks are eligible; Blueshift is intentionally absent.

Selection names may be full repositories (`Angel-125/Sandcastle`) or short names (`Sandcastle`). An empty manual include list means all registered dependents, and exclusions are applied afterward.

## Authoritative version locations

The September 29, 2026 audit found:

| Repository | Authoritative packaged version | Release notes | Latest local tag during audit | Binary rebuild needed for dependency-only patch |
| --- | --- | --- | --- | --- |
| Buffalo2 | `ReleaseFolder/GameData/WildBlueIndustries/Buffalo2/Buffalo2.version` | `ReleaseFolder/GameData/WildBlueIndustries/Buffalo2/Readme.txt` | `v1.9.1` | No; assembly version is fixed at `1.0.0.0` |
| Sandcastle | `ReleaseFolder/GameData/WildBlueIndustries/Sandcastle/Sandcastle.version` | `ReleaseFolder/GameData/WildBlueIndustries/Sandcastle/Readme.txt` | `v1.5.1` | No; assembly version is fixed at `1.0.0.0` |
| SunkWorks | `ReleaseFolder/GameData/WildBlueIndustries/SunkWorks/SunkWorks.version` | `ReleaseFolder/GameData/WildBlueIndustries/SunkWorks/Readme.txt` | `v1.3.1` | No; assembly version is fixed at `1.0.0.0` |

Root-level `.version` files in these repositories are stale historical copies and are not changed. Compiled DLLs and PDBs are never edited.

PointsOfInterest and Rockhound have no release layout or version metadata in their current local repositories. They must not be added to the live registry until those paths and release conventions exist and are audited.

## Exact dependency manifests

The cascade writes `.wbi-release/dependencies.json` into the dependent release commit. Each entry pins:

- repository;
- exact tag;
- exact ZIP asset name;
- source path inside the ZIP; and
- destination inside `ReleaseFolder/GameData`.

Packaging downloads that exact asset. It does not ask for “latest,” so a newer upstream release cannot race or alter the dependent package.

The legacy `bundle_wildbluecore: true` behavior remains available. If an exact manifest already manages `Angel-125/WildBlueCore`, the legacy latest-release replacement is skipped.

## Version and note changes

A dependency-only release increments only the dependent's patch number. Its KSP compatibility fields are preserved. The inserted note is:

```text
- Updated bundled WildBlueCore to version 1.6.0.
```

The note is inserted immediately after `---CHANGES---`; reruns do not duplicate it.

## Retry behavior

The operation never force-pushes. Before creating changes, it searches history for the exact upstream repository/tag trailer.

- Commit and tag already exist: skip as complete.
- Commit exists but tag is missing: recreate only the recorded tag at that commit.
- Proposed tag already exists without matching cascade metadata: fail rather than overwrite it.
- Branch changed concurrently: the normal non-force push fails, and the job reports recovery instructions.

All cascades share a GitHub Actions concurrency group, preventing two central cascade jobs from editing dependents simultaneously. Registry validation also rejects cycles before any repository is touched.

## Adding PointsOfInterest → Rockhound

After both repositories have real release layouts:

1. Add PointsOfInterest as an upstream in the registry.
2. Add Rockhound as its dependent with audited version and readme paths.
3. Define the PointsOfInterest asset name template and source/destination paths.
4. Add tag publishing callers to both repositories.
5. Install the GitHub App on both.
6. Store the App Client ID and private key in PointsOfInterest because it initiates the cascade.
7. Install the manual caller example and run a one-dependent dry run.

If Rockhound has multiple dependencies, its manifest may contain multiple entries. Updating one dependency replaces only that repository's manifest entry and preserves the others.
