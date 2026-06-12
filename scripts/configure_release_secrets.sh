#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-mallenkb/phone-mirroring}"
TEAM_ID="${TEAM_ID:-982T43ATCM}"
TEAM_NAME="${TEAM_NAME:-Nokofio Platforms Ltd}"
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Nokofio Platforms Ltd (982T43ATCM)}"

usage() {
  cat <<USAGE
Usage: scripts/configure_release_secrets.sh /path/to/developer-id.p12

Uploads the GitHub secrets required by the Release workflow.

Required before running:
  - Create a Developer ID Application certificate for "$TEAM_NAME" in Apple Developer.
  - Export it from Keychain Access as a password-protected .p12.
  - Create an Apple app-specific password for notarization.
  - Install and authenticate the GitHub CLI: gh auth login.

Environment overrides:
  REPO          GitHub repo, default: $REPO
  TEAM_ID       Apple team id, default: $TEAM_ID
  DEVELOPER_ID  Signing identity, default: $DEVELOPER_ID
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

P12_PATH="${1:-}"
if [ -z "$P12_PATH" ]; then
  usage >&2
  exit 2
fi

if [ ! -f "$P12_PATH" ]; then
  echo "Developer ID .p12 not found: $P12_PATH" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required. Install gh and run gh auth login." >&2
  exit 1
fi

read -r -p "Apple ID email for notarization: " APPLE_ID
if [ -z "$APPLE_ID" ]; then
  echo "Apple ID email is required." >&2
  exit 1
fi

read -r -s -p "Password used when exporting the .p12: " P12_PASSWORD
printf '\n'
if [ -z "$P12_PASSWORD" ]; then
  echo ".p12 password is required." >&2
  exit 1
fi

read -r -s -p "Apple app-specific password for notarization: " APP_PASSWORD
printf '\n'
if [ -z "$APP_PASSWORD" ]; then
  echo "Apple app-specific password is required." >&2
  exit 1
fi

CERT_SUBJECT="$(openssl pkcs12 -in "$P12_PATH" -nokeys -clcerts -passin "pass:$P12_PASSWORD" 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null || true)"

if [ -z "$CERT_SUBJECT" ]; then
  echo "Could not read the .p12 certificate. Check the path and export password." >&2
  exit 1
fi

if [[ "$CERT_SUBJECT" != *"Developer ID Application"* || "$CERT_SUBJECT" != *"$TEAM_ID"* ]]; then
  echo "The .p12 does not look like a Developer ID Application certificate for team $TEAM_ID." >&2
  echo "Certificate subject:" >&2
  echo "  $CERT_SUBJECT" >&2
  exit 1
fi

TMP_CERT="$(mktemp)"
cleanup() {
  rm -f "$TMP_CERT"
}
trap cleanup EXIT

base64 < "$P12_PATH" | tr -d '\n' > "$TMP_CERT"

echo "Uploading release secrets to $REPO..."
gh secret set DEVELOPER_ID_CERTIFICATE_BASE64 --repo "$REPO" < "$TMP_CERT"
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD --repo "$REPO"
printf '%s' "$DEVELOPER_ID" | gh secret set DEVELOPER_ID --repo "$REPO"
printf '%s' "$APPLE_ID" | gh secret set APPLE_ID --repo "$REPO"
printf '%s' "$TEAM_ID" | gh secret set TEAM_ID --repo "$REPO"
printf '%s' "$APP_PASSWORD" | gh secret set APP_PASSWORD --repo "$REPO"

echo "Release signing/notarization secrets uploaded."
echo "Sparkle and website secrets are managed separately:"
echo "  SPARKLE_PUBLIC_ED_KEY"
echo "  SPARKLE_PRIVATE_ED_KEY"
echo "  WEBSITE_REPO_TOKEN"
