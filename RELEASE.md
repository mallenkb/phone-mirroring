# PhoneRelay Release Flow

PhoneRelay is distributed outside the Mac App Store. Releases must be signed with a Developer ID Application certificate, notarized by Apple, packaged as a DMG, and published with a Sparkle appcast.

## Release Architecture

```text
main
  -> tag vX.Y.Z
  -> GitHub Actions: Release
  -> build and test
  -> build PhoneRelay.app
  -> Developer ID sign
  -> Apple notarize and staple
  -> create PhoneRelay.dmg
  -> generate signed appcast.xml
  -> publish GitHub Release
  -> sync public downloads
  -> Sparkle updates installed apps
```

## One-Time Setup

Create these GitHub repository secrets:

```text
DEVELOPER_ID_CERTIFICATE_BASE64
DEVELOPER_ID_CERTIFICATE_PASSWORD
DEVELOPER_ID
APPLE_ID
TEAM_ID
APP_PASSWORD
SPARKLE_PUBLIC_ED_KEY
SPARKLE_PRIVATE_ED_KEY
WEBSITE_REPO_TOKEN
```

Use the Nokofio Apple Developer team for Apple credentials:

```text
Team: Nokofio Platforms Ltd
Certificate type: Developer ID Application
```

The signing identity should look like:

```text
Developer ID Application: Nokofio Platforms Ltd (TEAM_ID)
```

Do not use Apple Development or Apple Distribution certificates for direct Mac app updates. Sparkle releases need Developer ID Application signing.

## Normal Release

1. Update the app version and build number:

```text
Sources/PhoneRelay/Info.plist
scripts/package_app.sh
scripts/build_and_run.sh
```

2. Verify locally:

```bash
swift build
swift test
plutil -lint Sources/PhoneRelay/Info.plist App/Info.plist
```

3. Commit the release change:

```bash
git add .
git commit -m "Release vX.Y.Z"
```

4. Create and push the tag:

```bash
git tag -a vX.Y.Z -m "PhoneRelay X.Y.Z"
git push origin main
git push origin vX.Y.Z
```

5. Watch the release workflow:

```bash
gh run list --workflow release.yml --limit 5
gh run watch <run-id> --exit-status
```

6. Confirm the release exists:

```bash
gh release view vX.Y.Z
```

## Success Criteria

A release is complete only when all of these are true:

- `Release` workflow passes.
- GitHub Release contains `PhoneRelay.dmg`, `PhoneRelay.dmg.sha256`, and `appcast.xml`.
- `PhoneRelay.app` and `PhoneRelay.dmg` are both notarized and stapled.
- `appcast.xml` contains a Sparkle EdDSA signature.
- The public appcast URL responds:

```text
https://phonerelay.mallenkb.com/downloads/appcast.xml
```

- `Check for Updates...` in the app reports either the new update or a clean "no update" message.

## Do Not Ship

Do not ship:

- Unsigned apps.
- Development-signed apps.
- Unnotarized apps.
- Private GitHub release asset URLs in Sparkle appcasts.
- A manually replaced DMG without regenerating `appcast.xml`.
- A release where Sparkle reports an invalid public key.

## Workflow

This repo intentionally has one workflow:

- `.github/workflows/release.yml`

It does two things:

- Validates every pull request and `main` push with build, tests, and a packaging dry run.
- Publishes signed/notarized releases only from a `vX.Y.Z` tag or a manual workflow dispatch.

The public download mirror is not deployed from this repo. The release workflow triggers `mallenkb/phonerelay-website` after publishing the GitHub Release.
