# Sparkle Updates

Phone Relay is self-distributed. First-time users can keep downloading the DMG
from the website; installed apps update through Sparkle.

## One-time setup

- Sparkle feed URL: `https://phonerelay.mallenkb.com/appcast.xml`
- Public EdDSA key embedded in the app: `BRG3UL9d/8qtx7RJdobbGi1q87hpbEflfn1izHj/qgc=`
- The matching private key is stored in the local login keychain under Sparkle's
  default `ed25519` account.

For GitHub Actions releases, export the private key from Sparkle and store it as
the repository secret `SPARKLE_PRIVATE_ED_KEY`.

## Release outputs

Each tagged release publishes:

- `PhoneRelay-{version}.dmg` for website/manual installation.
- `PhoneRelay-{version}.zip` for Sparkle in-app updates.
- `appcast.xml` for Sparkle update discovery.

The Pages workflow copies the latest release's `appcast.xml` into `docs/` so the
stable appcast URL stays available on the hosted site.

## Local command

After packaging a signed app:

```bash
scripts/make_sparkle_update.sh dist/PhoneRelay.app
```

This creates `dist/sparkle/PhoneRelay-{version}.zip` and
`dist/sparkle/appcast.xml`.
