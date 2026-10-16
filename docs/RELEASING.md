# Releasing Keepers

Everything runs in one workflow, `.github/workflows/build.yml`, on
GitHub-hosted `macos-15` runners (free for this public repo):

| Job | When | What it does |
|---|---|---|
| **test** | Every PR, push to `main`, tag, and manual run | Runs the tests on Apple Silicon and on Intel under Rosetta. On PRs and `main`, also checks that a Release build is universal. |
| **build** | `vX.Y.Z` tags and manual runs | Builds the universal (arm64 + x86_64) app, signs it, submits it to Apple, uploads the signed `.app`. |
| **publish** | After **build** | Waits for Apple's verdict (up to 5.5 h), staples, builds `Keepers-X.Y.Z.dmg`. On a tag it creates the GitHub Release; on a manual run it only uploads the `.dmg` as an artifact. |

There is one build for both architectures: Xcode compiles a universal
binary, and `scripts/build_and_sign.sh` fails if any Mach-O in the bundle
is missing a slice.

## Per-release flow

```bash
# 1. Make sure CHANGELOG.md "[Unreleased]" reflects what's actually shipping.
$EDITOR CHANGELOG.md

# 2. Bump (writes VERSION, rewrites CHANGELOG, commits, creates tag).
scripts/bump.sh patch    # or minor / major / 1.5.0

# 3. Push commit + tag together. The tag starts test → build → publish.
git push --follow-tags
```

When **publish** finishes, the GitHub Release exists with the `.dmg`
attached. There is no manual step in between.

### When Apple is slow

Notarization on this account has taken from minutes to over 4 hours. If
**publish** hits its timeout, open the run later and click **Re-run failed
jobs**. Only **publish** runs again; it reuses the submission ID and the
signed `.app` from **build**, so nothing is rebuilt or resubmitted. (Re-runs
are possible for 14 days, the artifact retention.)

To see what Apple is doing in the meantime, from any Mac:

```bash
xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
xcrun notarytool log <submission-id> --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
```

If Apple rejects the submission, **publish** fails and prints Apple's log.

### Dry runs

Run the **Build** workflow manually (**Actions → Build → Run workflow**) on
any branch. It tests, builds, signs, notarizes, and uploads the `.dmg` as an
artifact without creating a GitHub Release.

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
scripts/build_and_sign.sh
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
from a previous build. `rm -rf build dist` and rebuild. `build_and_sign.sh`
does this for you on every run.

**"Not universal: …" from `build_and_sign.sh`.** Something in the bundle was
built for one architecture only. Today the bundle has a single executable
built from source, so this means a newly added prebuilt binary or framework
ships only one slice. Replace it with a universal build.

**Notarization rejected with `Hardened Runtime` errors.** The app needs no
entitlements. Check the signature has the runtime flag:
```bash
codesign -dv dist/Keepers.app 2>&1 | grep flags   # expect "runtime"
```

**Notarization is "In Progress" forever.** Apple occasionally backs up.
Wait, then **Re-run failed jobs** on the run (see "When Apple is slow").
Only if the submission is truly stuck, resubmit by deleting the tag locally
and remotely (`git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`) and
re-tagging.

**Tag/VERSION mismatch.** The workflow refuses to build if the pushed tag
doesn't match the contents of `VERSION`. Always use `scripts/bump.sh` to
make a release — it writes both atomically.
