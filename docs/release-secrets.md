# Release secrets

The Release workflow (`.github/workflows/release.yml`) needs seven GitHub
Actions secrets. As of 2026-07-04 four are set; **three are missing**, which
is why every tagged release fails in the "Preflight release secrets" step.

| Secret | Status | What it is |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12_BASE64` | ❌ missing | Base64 of the exported Developer ID Application certificate (.p12) |
| `APPLE_CERTIFICATE_PASSWORD` | ❌ missing | Password chosen when exporting that .p12 |
| `APP_SPECIFIC_PASSWORD` | ❌ missing | App-specific password for the Apple ID (notarization) |
| `APPLE_ID` | ✅ set | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | ✅ set | Team ID (982T43ATCM, Nokofio Platforms Ltd) |
| `SPARKLE_PRIVATE_ED_KEY` | ✅ set | Sparkle EdDSA private key for appcast signing |
| `WEBSITE_REPO_TOKEN` | ✅ set | Token for publishing to the website repo |

## Producing the missing three (owner-only, ~10 minutes)

1. **Developer ID certificate (.p12).** You need a **Developer ID
   Application** certificate — note this is a *different type* from the
   "Apple Development"/"Apple Distribution" certs currently in the local
   keychain. Create/download it at
   <https://developer.apple.com/account/resources/certificates> (type:
   Developer ID Application), double-click to install, then in Keychain
   Access: right-click the certificate → Export → .p12 with a password.

   ```sh
   base64 -i DeveloperID.p12 | gh secret set APPLE_CERTIFICATE_P12_BASE64
   gh secret set APPLE_CERTIFICATE_PASSWORD   # paste the export password
   ```

2. **App-specific password.** Create at <https://account.apple.com> →
   Sign-In and Security → App-Specific Passwords.

   ```sh
   gh secret set APP_SPECIFIC_PASSWORD        # paste the xxxx-xxxx-xxxx-xxxx value
   ```

3. Re-run the failed Release run (or push the tag again). The preflight
   passes, the workflow imports the cert into a throwaway keychain, signs,
   notarizes, staples, and asserts the signature's `TeamIdentifier` matches
   `APPLE_TEAM_ID` before anything is published.

## Why this matters beyond distribution

A stable Developer ID signature is also the permanent fix for the recurring
macOS **Local Network / TCC identity churn** (INVARIANTS.md rules 8–9): the
permission grant is keyed to the signing identity, so ad-hoc or
per-machine-cert builds keep resetting it.
