# WBI Release Workflows

Reusable GitHub Actions automation for publishing Wild Blue Industries KSP mods.

The workflow:

- accepts version tags such as `1.6.0` and `v1.6.0`;
- validates a three-part numeric version and normalizes the release title to `1.6.0`;
- extracts release notes from a readme between configurable marker lines;
- optionally replaces a mod's bundled `00WildBlueCore` with the latest published WildBlueCore release;
- supports exact, version-pinned dependency assets created by a dependency cascade;
- packages `ReleaseFolder/GameData`, keeping `GameData` at the root of the ZIP; and
- creates a GitHub release with an asset such as `Sandcastle_1_6_0.zip` (no `_R1` suffix).

## Install in a mod repository

Copy the appropriate file from [`examples`](examples) into the mod repository as `.github/workflows/tag-release.yml`. The examples cover:

- [Sandcastle](examples/sandcastle-tag-release.yml), including WildBlueCore;
- [WildBlueCore](examples/wildbluecore-tag-release.yml), which publishes without bundling itself; and
- [Blueshift](examples/blueshift-tag-release.yml), which does not depend on WildBlueCore; and
- [Snacks](examples/snacks-tag-release.yml), which also publishes without WildBlueCore.

Buffalo 2, Sandcastle, and SunkWorks currently depend on WildBlueCore. Their callers should set `bundle_wildbluecore: true`. Blueshift and Snacks do not depend on WildBlueCore, and WildBlueCore must not attempt to bundle itself, so those callers use `false`.

The caller must grant `contents: write` so the reusable workflow can create the release and upload its ZIP. The central workflow repository must be public for callers in other public repositories to use it.

The current examples reference the dependency-aware major tag `@v2`. Existing `@v1` callers continue to work unchanged. Publish and test `v2` before installing the new examples; a version tag is safer than `@main` because changes to `main` cannot unexpectedly alter established release callers.

See the [repository inventory](docs/repository-inventory.md) for the caller values, packaged dependencies, and migration notes for Buffalo 2, Sandcastle, SunkWorks, WildBlueCore, Blueshift, and Snacks.

After installing a caller, create and push either form of a version tag:

```text
1.6.0
v1.6.0
```

Both forms create release title `1.6.0`. For Sandcastle, the uploaded asset is `Sandcastle_1_6_0.zip`.

## Reusable workflow inputs

| Input | Required | Default | Purpose |
| --- | --- | --- | --- |
| `product_name` | Yes | — | Filename prefix for the release ZIP. Letters, numbers, dots, underscores, and hyphens are accepted. |
| `readme_path` | Yes | — | Repository-relative readme containing marked release notes. |
| `changes_start_marker` | No | `---CHANGES---` | Exact line immediately before the release notes. |
| `changes_end_marker` | No | `---END CHANGES---` | Exact line immediately after the release notes. |
| `bundle_wildbluecore` | No | `false` | Whether to replace bundled WildBlueCore before packaging. |
| `wildbluecore_repository` | No | `Angel-125/WildBlueCore` | Repository whose latest published release tag is used. |
| `wildbluecore_source_path` | No | `ReleaseFolder/GameData/WildBlueIndustries/00WildBlueCore` | Dependency folder within WildBlueCore. |
| `wildbluecore_destination_path` | No | `ReleaseFolder/GameData/WildBlueIndustries/00WildBlueCore` | Folder replaced in the calling repository. |
| `dependency_manifest_path` | No | `.wbi-release/dependencies.json` | Exact dependency manifest created by a cascade. |
| `automation_ref` | No | `v2` | Central ref containing dependency installation scripts. |

Marker matching is exact after Windows carriage returns are removed. The canonical end marker is `---END CHANGES---`, which all caller examples use by default. A caller only needs `changes_end_marker` when supporting a readme that intentionally uses a different marker.

## Release behavior and safeguards

The caller's tag selects the exact source commit packaged by `actions/checkout`. If WildBlueCore bundling is enabled, the workflow asks GitHub for `Angel-125/WildBlueCore`'s latest non-draft, non-prerelease published release, checks out that release tag, and replaces only the configured `00WildBlueCore` destination.

The run stops without publishing if the tag is malformed, a required folder or marker is missing, the notes are empty, or the latest WildBlueCore release cannot be resolved. GitHub release creation occurs only after the ZIP has been built successfully.

Dependency cascades never rebuild an existing release. They create new patch versions of selected dependents. The initial WildBlueCore registry is deliberately in manual mode; automatic mode can be enabled after controlled testing.

- For a compatible WildBlueCore bug fix or enhancement, release WildBlueCore by itself. CKAN can update the dependency independently, and each dependent mod's next normal release will bundle the newer WildBlueCore for manual installers.
- If Buffalo 2, Sandcastle, or SunkWorks requires a new WildBlueCore API or minimum version, bump that mod's version and publish a new mod release. Its ZIP will then include the required WildBlueCore release, ensuring that manual installers receive a compatible pair.
- For a breaking WildBlueCore change, rebuild, test, version, and release every affected dependent mod rather than replacing an asset under an existing mod version.

Do not silently replace or add a rebuilt ZIP to an unchanged mod release. A new compatibility requirement is represented by a new mod version and tag.

## Dependency cascades and GitHub App

See the [dependency cascade design](docs/dependency-cascades.md) and the step-by-step [GitHub App setup guide](docs/github-app-setup.md). The App is only a short-lived authentication identity used by Actions; there is no service to host or local application to launch.

The manual WildBlueCore caller supports `include_dependents`, `exclude_dependents`, and a default-on dry run. In automatic mode, the tag workflow waits for WildBlueCore publication to succeed before updating dependents.
