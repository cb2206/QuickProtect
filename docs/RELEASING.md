# Releasing QuickProtect

How a version reaches the three channels, and how to switch the GitHub DMG
from ad-hoc signing to a Developer ID-signed, notarized build.

## Cutting a release

1. Bump the version in `macos/project.yml` (`CFBundleShortVersionString` and
   `CFBundleVersion`) and `dotnet/Directory.Build.props` (`<Version>`), run
   `xcodegen generate` in `macos/` and commit the regenerated `Info.plist`.
   The release workflow refuses a tag whose version disagrees with either file.
2. Merge `dev` into `main` (`git merge --no-ff dev`), tag `main` as `vX.Y.Z`
   and push `main` and the tag.
3. The tag runs `.github/workflows/release.yml`: both test suites, then the
   macOS DMG, the Windows installer and the Linux tarball, then a **draft**
   GitHub release with the three assets and `SHA256SUMS`.
4. Review the draft and publish it. Publishing is what the in-app update
   checks see, so the asset names are a de facto API (see the workflow header).
5. Store builds are separate: Mac App Store via fastlane
   (`macos/fastlane/PIPELINE.md`), Microsoft Store via
   `dotnet/scripts/package-msix.ps1` and Partner Center.

`workflow_dispatch` on any branch builds the same artifacts without creating a
release. Use it to exercise a change to the workflow or the packaging scripts
before tagging:

```bash
gh workflow run release.yml --ref dev
```

## Developer ID signing and notarization for the DMG

The `macos-dmg` job has two modes, selected by whether the secrets below
exist. With no secrets it ad-hoc signs the app (the current GitHub build).
With all five secrets it signs the app with a Developer ID Application
certificate (hardened runtime, secure timestamp), signs the DMG, submits it
to Apple's notary service, staples the ticket and verifies the result with the
same assessment Gatekeeper runs. Nothing else in the workflow changes.

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | The Developer ID Application certificate with its private key, as a base64-encoded `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The password chosen when exporting that `.p12` |
| `NOTARY_KEY_ID` | App Store Connect API key ID |
| `NOTARY_ISSUER_ID` | App Store Connect API issuer ID |
| `NOTARY_KEY_P8` | The API key's `.p8` file, base64-encoded |

The team ID (`K2LM9FSU6C`) is not secret; it is already in `macos/project.yml`.

### 1. Create the Developer ID Application certificate

Only the **Account Holder** of the developer account can create Developer ID
certificates, and they are not covered by Xcode's cloud signing, so this is a
one-time manual step. The certificate is valid for five years.

1. On the Mac, open **Keychain Access → Certificate Assistant → Request a
   Certificate From a Certificate Authority…**. Enter the Apple ID email,
   any common name, leave the CA email empty, choose **Saved to disk**, and
   save the `.certSigningRequest` file.
2. Sign in at <https://developer.apple.com/account/resources/certificates/add>
   as the Account Holder, choose **Developer ID Application**, the current
   **G2 Sub-CA** profile type, upload the request file and download the
   resulting `developerID_application.cer`.
3. Double-click the `.cer` so Keychain Access pairs it with the private key
   the request created. In the **My Certificates** category it must now show
   as *Developer ID Application: Christian Bartels (K2LM9FSU6C)* with a
   disclosure triangle revealing the key.
4. Right-click that entry, **Export…**, format *Personal Information Exchange
   (.p12)*, and set a strong password. Keep the file out of the repository.

Encode it and add the two secrets:

```bash
base64 -i DeveloperID.p12 | pbcopy
gh secret set MACOS_CERTIFICATE_P12   # paste
gh secret set MACOS_CERTIFICATE_PASSWORD
```

### 2. Provide the notary API key

`notarytool` accepts an App Store Connect API key with the **Developer**
role or higher. The Admin key fastlane already uses for App Store uploads
works (its ID, issuer and `.p8` path are in `macos/fastlane/.env`, which is
gitignored). Reusing it means one key to rotate; creating a dedicated
Developer-role key at
<https://appstoreconnect.apple.com/access/integrations/api> is the
least-privilege option and is what these instructions assume.

```bash
gh secret set NOTARY_KEY_ID --body "<key id>"
gh secret set NOTARY_ISSUER_ID --body "<issuer id>"
base64 -i ~/.appstoreconnect/AuthKey_<key id>.p8 | gh secret set NOTARY_KEY_P8
```

### 3. Dry-run before tagging

```bash
gh workflow run release.yml --ref dev
gh run watch
```

In the run's `macos-dmg` job the steps *Import Developer ID certificate*,
*Build Release (Developer ID signed)* and *Notarize and staple* must have run
and the ad-hoc build step must be skipped. Download the `macos-dmg` artifact
and confirm on a Mac that it opens without a Gatekeeper warning:

```bash
spctl --assess --type open --context context:primary-signature -v QuickProtect-*.dmg
```

### 4. Update what the app and docs say

Once a notarized DMG has shipped, the "not code-signed" wording is wrong and
must be changed in the same release:

- `macos/README.md`: the signed-binary note near the top and the
  *Installing the GitHub build* section (the Gatekeeper workaround no longer
  applies; keep the `SHA256SUMS` verification).
- `macos/QuickProtect/Services/UpdateChecker.swift`: the class comment about
  the GitHub build not being code-signed. The update check stays notify-only
  regardless; that decision is independent of signing.
- `docs/HANDOFF.md`: the Windows line says the installer is not code-signed,
  which stays true; nothing to change there unless Windows signing follows.
- The `macos-dmg` job comment in `release.yml` that still describes the
  ad-hoc build as "the GitHub build".

### Rotation and revocation

- A revoked or expired Developer ID certificate does not invalidate already
  notarized, stapled DMGs. Replace `MACOS_CERTIFICATE_P12` and
  `MACOS_CERTIFICATE_PASSWORD`; the next tag uses the new certificate.
- Revoking the API key breaks notarization only; the workflow fails at
  *Notarize and staple* with Apple's error text. Replace the three
  `NOTARY_*` secrets.
- Removing any of the five secrets switches the job back to the ad-hoc build.
