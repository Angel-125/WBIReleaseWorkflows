# GitHub App setup for dependency cascades

The dependency cascade uses a private GitHub App only as a release-bot identity. There is no program to install or server to run. A GitHub Actions job creates a short-lived installation token when it needs to commit and tag a dependent repository.

The current `actions/create-github-app-token@v3` interface uses the App **Client ID**. The Client ID is not the numeric App ID. This repository therefore uses the variable name `WBI_RELEASE_APP_CLIENT_ID`.

Official references:

- [Registering a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)
- [Installing your own GitHub App](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app)
- [Using a GitHub App from Actions](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/making-authenticated-api-requests-with-a-github-app-in-a-github-actions-workflow)
- [Creating repository Actions secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets#creating-secrets-for-a-repository)

## 1. Register the App

1. Sign in to GitHub as `Angel-125`.
2. Select the profile picture in the upper-right corner, then **Settings**.
3. In the left sidebar, select **Developer settings**.
4. Select **GitHub Apps**, then **New GitHub App**.
5. Enter a globally unique name. `wbi-release-bot` is preferred; if it is unavailable, choose another name and update the callers' `app_slug` input.
6. Enter a homepage URL, such as `https://github.com/Angel-125/WBIReleaseWorkflows`.
7. Leave callback and setup URLs empty. Do not request user authorization during installation.
8. Under **Webhook**, clear **Active**. This App is used only for authentication and has no webhook receiver.
9. Under **Repository permissions**, set:
   - **Contents:** Read and write.
   - **Metadata:** Read-only. GitHub normally selects this automatically.
   - Every other repository permission: **No access**.
10. Do not grant organization or account permissions.
11. Under **Where can this GitHub App be installed?**, select **Only on this account**.
12. Select **Create GitHub App**.

`Workflows` permission is deliberately omitted because the bot does not edit `.github/workflows`. `Actions` permission is also omitted because a bot-pushed version tag starts the existing tag workflow without an API workflow dispatch.

## 2. Record the Client ID and create a private key

1. On the App's settings page, copy **Client ID**. Do not copy **App ID** for `actions/create-github-app-token@v3`.
2. Scroll to **Private keys** and select **Generate a private key**.
3. GitHub downloads a `.pem` file. Keep it outside every Git repository.
4. Never paste the private key into a workflow, issue, commit, or chat. The Actions secret must contain the complete file, including:

   ```text
   -----BEGIN RSA PRIVATE KEY-----
   ...
   -----END RSA PRIVATE KEY-----
   ```

GitHub may generate a key whose BEGIN line names a different private-key format. Preserve the downloaded file exactly.

## 3. Install the App on selected repositories

1. Return to **Settings → Developer settings → GitHub Apps**.
2. Select **Edit** beside the App, then **Install App**.
3. Select **Install** beside the `Angel-125` account.
4. Select **Only select repositories**.
5. For the first controlled test, select:
   - `WildBlueCore`
   - one dependent, preferably `Sandcastle`
6. After the controlled test, add:
   - `Buffalo2`
   - `SunkWorks`
7. When the second dependency family is ready, add:
   - `PointsOfInterest`
   - `Rockhound`

`WBIReleaseWorkflows` does not need to be selected because the bot never writes to it. Its public workflows and scripts are checked out read-only.

## 4. Store the Actions credentials

Credentials belong in every **upstream repository that initiates a cascade**. Initially that is `WildBlueCore`; later it may also be `PointsOfInterest`. Secrets stored in `WBIReleaseWorkflows` are not automatically exposed to reusable-workflow callers.

For each upstream repository:

1. Open the repository on GitHub.
2. Select **Settings**.
3. In the **Security** section, select **Secrets and variables → Actions**.
4. Select the **Variables** tab and create:
   - Name: `WBI_RELEASE_APP_CLIENT_ID`
   - Value: the App's Client ID.
5. Select the **Secrets** tab, select **New repository secret**, and create:
   - Name: `WBI_RELEASE_APP_PRIVATE_KEY`
   - Value: the complete private-key file contents.

The Client ID is not secret, so a variable is appropriate. The private key must be a secret.

## 5. Install the caller workflows

Do this only after publishing and approving the central `v2` tag.

In `WildBlueCore`:

1. Replace `.github/workflows/tag-release.yml` with [`examples/wildbluecore-tag-release.yml`](../examples/wildbluecore-tag-release.yml).
2. Add [`examples/wildbluecore-dependency-cascade.yml`](../examples/wildbluecore-dependency-cascade.yml) as `.github/workflows/dependency-cascade.yml`.

Update dependent callers from `publish-ksp-mod.yml@v1` to `publish-ksp-mod.yml@v2` so that exact dependency manifests are honored.

## 6. First dry run

The initial registry sets WildBlueCore to `cascade_mode: manual`, so publishing a WildBlueCore tag will not automatically alter dependents.

1. Publish or identify an existing WildBlueCore release that uses the new asset name, such as `WildBlueCore_1_6_0.zip`.
2. Open **WildBlueCore → Actions → Dependency Cascade**.
3. Select **Run workflow**.
4. Enter the exact published tag.
5. Enter one dependent, such as `Sandcastle`, in `include_dependents`.
6. Leave `exclude_dependents` empty.
7. Keep `dry_run` selected.
8. Run the workflow and inspect its job summary. It should show the current and proposed patch versions without pushing anything.

For the first live test, run the same inputs with `dry_run` cleared. The expected commit author is `wbi-release-bot[bot]` (or the selected App name), followed by a new dependent tag and its normal tag-release workflow.

## 7. Enable automatic operation

After controlled tests succeed, change WildBlueCore's registry entry from:

```json
"cascade_mode": "manual"
```

to:

```json
"cascade_mode": "automatic"
```

Only dependents with `"automatic_cascade": true` participate. A tag release then follows this sequence:

1. WildBlueCore publishes successfully.
2. The `cascade` job starts because it has `needs: publish`.
3. The App receives a short-lived token.
4. Selected dependents receive patch-version commits and tags.
5. Their existing tag workflows publish new ZIPs containing the exact initiating WildBlueCore release.

Nothing is launched locally.

## Key rotation and revocation

To rotate a key:

1. Generate a second private key on the App settings page.
2. Replace `WBI_RELEASE_APP_PRIVATE_KEY` in every upstream repository.
3. Complete a dry run.
4. Delete the old key from the App settings page.

To revoke one repository, edit the App installation and remove that repository. To revoke all automation, uninstall the App or delete all of its private keys.

## Branch and tag protection

Repository rules still apply to the App. If a dependent's default branch or version tags are protected, prefer a narrowly scoped ruleset bypass entry for this App. Do not grant repository administration permission merely to bypass a rule. If policy does not permit a narrow bypass, change the cascade to create an approval pull request instead of pushing directly.

## Recognizing and recovering releases

Bot commits contain these trailers:

```text
WBI-Dependency-Release: Angel-125/WildBlueCore@v1.6.0
WBI-Release-Tag: v1.5.2
```

These make retries idempotent. If the commit was pushed but tag creation failed, rerunning the same upstream tag finds the commit and creates only the missing tag. Existing tags are never moved or force-pushed.
