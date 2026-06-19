# Releasing Keepers

Releases are split across two workflows because Apple's notarization queue
takes 1–4 hours per submission on this account, and holding a macOS runner
during the wait would burn money for no reason.

| Workflow | When | What it does |
|---|---|---|
| **Release (build + submit)** | On `vX.Y.Z` tag push, or manual | Matrix builds for x86_64 (`macos-13`) and arm64 (`macos-14`). Each arch: build, sign, submit to Apple, upload signed `.app` artifact. Exits in ~30–60 min. |
| **Notarization status** | Manual, anytime | Calls `notarytool history` and `notarytool log` so you can ask Apple what state your submissions are in. Both arch submissions show up here. |
| **Finalize release** | Manual, once Apple accepts BOTH archs | Matrix downloads each signed `.app`, staples, builds per-arch `.dmg`. A final job creates one GitHub Release with both `.dmg`s attached. ~20 min. |

## Per-release flow

```bash
# 1. Make sure CHANGELOG.md "[Unreleased]" reflects what's actually shipping.
$EDITOR CHANGELOG.md

# 2. Bump (writes VERSION, rewrites CHANGELOG, commits, creates tag).
scripts/bump.sh patch    # or minor / major / 1.5.0

# 3. Push commit + tag together. The tag push triggers the build workflow.
git push --follow-tags
```

The build workflow runs two arch jobs in parallel and finishes in ~30–60 min.
Each arch's job ends with a log message listing the inputs Finalize needs:

```
submission_id_x86_64: <uuid>     (from the macos-13 job)
submission_id_arm64:  <uuid>     (from the macos-14 job)
build_run_id:         <run id>   (same for both jobs)
tag:                  v1.3.2
```

Wait for Apple to Accept **both** submissions (check via Notarization status).
Then open **Actions → Finalize release → Run workflow**, paste all four values,
and run it. ~20 minutes later one GitHub Release exists with both .dmgs:
`Keepers-1.3.2-x86_64.dmg` and `Keepers-1.3.2-arm64.dmg`.

### Dry runs

Trigger the **Release (build + submit)** workflow manually (no tag needed)
to test the bundling pipeline. The signed `.app` is uploaded as an artifact.
You can then run **Finalize release** with an empty `tag` input to produce
a `.dmg` artifact without publishing a GitHub Release.

## One-time setup

Before the first release works, the following GitHub repository secrets must
exist in **Settings → Secrets and variables → Actions**:

| Secret name                       | What it is                                                  |
|-----------------------------------|-------------------------------------------------------------|
| `MACOS_CERTIFICATE_P12_BASE64`    | Developer ID Application cert, exported as `.p12`, base64-encoded |
| `MACOS_CERTIFICATE_P12_PASSWORD`  | Password used when exporting the `.p12`                     |
| `KEYCHAIN_PASSWORD`               | Any random string — used to lock the ephemeral CI keychain  |
| `MACOS_DEVELOPER_ID`              | `Developer ID Application: Alin Banuta (TEAMID12345)`       |
| `APPLE_ID`                        | Apple developer account email                               |
| `APPLE_TEAM_ID`                   | 10-character team ID (visible in the Apple Developer portal)|
| `APPLE_APP_PASSWORD`              | App-specific password generated at appleid.apple.com        |

### Exporting the Developer ID certificate

1. Open **Keychain Access** → **login** keychain → **My Certificates**.
2. Find `Developer ID Application: <your name> (TEAMID)`. The arrow next to it
   should expand to reveal a private key — if it doesn't, the cert can't sign
   and you need to install the WWDR intermediate from Apple's website.
3. Right-click the certificate → **Export** → save as `keepers-codesign.p12`.
   Set a strong password — this becomes `MACOS_CERTIFICATE_P12_PASSWORD`.
4. Base64-encode it for the secret:
   ```bash
   base64 -i keepers-codesign.p12 | pbcopy
   ```
5. Paste the result into the `MACOS_CERTIFICATE_P12_BASE64` secret.
6. **Delete the `.p12` file from your machine** once both secrets are set.
   Anyone with it can sign software as you.

### Generating the app-specific password

1. Sign in at <https://appleid.apple.com>.
2. **Sign-In and Security → App-Specific Passwords → Generate**.
3. Label it `Keepers notarization (GitHub Actions)`.
4. Paste the password into `APPLE_APP_PASSWORD`.
5. The password is only shown once. If you lose it, revoke and regenerate.

`APPLE_TEAM_ID` is at the top right of <https://developer.apple.com/account/>.

## Local releases (without CI)

You don't need to use the GitHub workflows if you'd rather build locally.
Set the four env vars first:

```bash
export DEVELOPER_ID="Developer ID Application: Alin Banuta (TEAMID12345)"
export APPLE_ID="you@example.com"
export APPLE_TEAM_ID="TEAMID12345"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

Then either run the full one-shot pipeline (blocks for hours during
notarization):

```bash
scripts/build_dmg.sh
```

Or split it the same way CI does, so you can walk away during the wait:

```bash
scripts/build_and_sign.sh                                 # ~5 min
SUBMISSION_ID="$(scripts/submit_notarization.sh)"         # ~30 s
echo "$SUBMISSION_ID"   # save this somewhere
# ... walk away. Check periodically:
xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
# Once Accepted:
SUBMISSION_ID="$SUBMISSION_ID" scripts/finalize_release.sh   # ~5 min
```

Either path produces `dist/Keepers-<version>.dmg`. Upload it manually to
the GitHub Release if you want it published.

## Troubleshooting

**"errSecInternalComponent" during `codesign`.** The runner keychain wasn't
unlocked for the codesign tool. Re-check that the `set-key-partition-list`
step ran and that `KEYCHAIN_PASSWORD` matches across all the steps.

**"The signature of the binary is invalid."** Almost always a stale `.app`
from a previous build. `rm -rf build dist` and rebuild. `build_dmg.sh` does
this for you on every run.

**Notarization rejected with `Hardened Runtime` errors.** Check
`Entitlements.plist` is being applied. Inspect with:
```bash
codesign -d --entitlements - dist/Keepers.app
```
Every entry in the entitlements file must be present in that output.

**Notarization is "In Progress" forever.** Apple occasionally backs up.
`notarytool submit --wait` has its own timeout, but the workflow `timeout-minutes`
will fail the job before that. Retry the release by deleting the tag locally
and remotely (`git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`), then
re-tagging.

**Tag/VERSION mismatch.** The workflow refuses to build if the pushed tag
doesn't match the contents of `VERSION`. Always use `scripts/bump.sh` to
make a release — it writes both atomically.
