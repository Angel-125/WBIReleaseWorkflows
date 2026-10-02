# Release caller inventory

Inventory originally completed September 12, 2026, and refreshed September 29, 2026 for dependency-cascade automation.

## Caller configuration

| Repository | Default branch | `product_name` | Primary release-notes readme | Bundle WildBlueCore |
| --- | --- | --- | --- | --- |
| Buffalo 2 | `main` | `Buffalo2` | `ReleaseFolder/GameData/WildBlueIndustries/Buffalo2/Readme.txt` | Yes |
| Sandcastle | `main` | `Sandcastle` | `ReleaseFolder/GameData/WildBlueIndustries/Sandcastle/Readme.txt` | Yes |
| SunkWorks | `main` | `SunkWorks` | `ReleaseFolder/GameData/WildBlueIndustries/SunkWorks/Readme.txt` | Yes |
| WildBlueCore | `main` | `WildBlueCore` | `ReleaseFolder/GameData/WildBlueIndustries/00WildBlueCore/Readme.txt` | No |
| Blueshift | `master` | `Blueshift` | `ReleaseFolder/GameData/WildBlueIndustries/Blueshift/Readme.txt` | No |
| Snacks | `master` | `Snacks` | `ReleaseFolder/GameData/WildBlueIndustries/Snacks/Readme.txt` | No |

All six primary readmes use the canonical `---CHANGES---` and `---END CHANGES---` markers. No marker overrides are required.

## Packaged GameData contents

The reusable workflow packages the complete `ReleaseFolder/GameData` directory, so these repository-specific payload differences require no workflow customization.

| Repository | Top-level payload |
| --- | --- |
| Buffalo 2 | `NearFutureProps`, `WildBlueIndustries/001KerbalActuators`, `WildBlueIndustries/00WildBlueCore`, `WildBlueIndustries/Buffalo2`, ModuleManager |
| Sandcastle | `NearFutureProps`, `WildBlueIndustries/00WildBlueCore`, `WildBlueIndustries/Sandcastle`, ModuleManager |
| SunkWorks | `WildBlueIndustries/00WildBlueCore`, `WildBlueIndustries/SunkWorks` |
| WildBlueCore | `WildBlueIndustries/00WildBlueCore` |
| Blueshift | `FireflyAPI`, `WildBlueIndustries/Blueshift`, ModuleManager |
| Snacks | `WildBlueIndustries/Snacks`, ModuleManager |

For Buffalo 2, Sandcastle, and SunkWorks, the reusable workflow replaces only `ReleaseFolder/GameData/WildBlueIndustries/00WildBlueCore`. Every other bundled folder remains as committed at the mod's release tag.

## Existing automation and releases

| Repository | Existing tag workflow | Latest published release found during inventory | Existing asset naming |
| --- | --- | --- | --- |
| Buffalo 2 | None | `v1.9.0` | `Buffalo2.zip` |
| Sandcastle | Full standalone `tag-release.yml` | `v1.5.0` | `Sandcastle_1_5_0_R1.zip` |
| SunkWorks | None | `v1.2.0` | `SunkWorks.zip` |
| WildBlueCore | None | `v1.6.0` | `WildBlueCore.zip` |
| Blueshift | None | `v1.17.2` | `Blueshift.zip` |

Reusable callers are now installed and have been proven by successful Blueshift and SunkWorks releases. Sandcastle `v1.5.1` also succeeded after its readme end marker was corrected. New releases consistently use `ProductName_major_minor_patch.zip`.

## Pre-release observations

- SunkWorks `v1.3.0` is an in-development release and requires no action during caller migration.
- SunkWorks and WildBlueCore now use their correct `main`-branch `.version` URLs.
- Blueshift intentionally remains on `master`; its current `.version` URL agrees with that branch.

## Dependency-cascade version audit

The packaged `.version` files are authoritative for Buffalo2, Sandcastle, and SunkWorks. Their root-level `.version` files contain older versions and are not suitable automation targets. All three assemblies use a fixed `1.0.0.0` assembly/file version, so dependency-only patch releases do not require DLL rebuilding.

PointsOfInterest currently contains design/reference material but no release layout, while Rockhound has no tracked release content in the local checkout. Their proposed dependency relationship remains documented but is not active in the registry.
