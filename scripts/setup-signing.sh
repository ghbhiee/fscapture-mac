#!/usr/bin/env bash
# Ensure the shared self-signed code-signing identity "Hongbo Dev" exists in the
# login keychain. This is a single stable identity shared across the user's local
# apps: a stable identity gives the code signature a stable Designated
# Requirement, so macOS keeps the Screen-Recording / Accessibility TCC grants
# across rebuilds.
#
# Normally the "Hongbo Dev" cert already exists (created once, reused by every
# app). This script only creates it if it's missing, and never overwrites an
# existing one — recreating it would mint a different key and break TCC grants.
#
# Run once (only needed on a fresh machine):  bash scripts/setup-signing.sh
set -euo pipefail

NAME="Hongbo Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "$NAME"; then
  echo "✅ Shared signing identity '$NAME' already exists — nothing to do."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

cat > ext.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Hongbo Dev
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -config ext.cnf
openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem -passout pass:hongbodev -name "$NAME"
security import id.p12 -k "$KEYCHAIN" -P hongbodev -T /usr/bin/codesign -A
security add-trusted-cert -p codeSign -k "$KEYCHAIN" cert.pem

echo ""
if security find-identity -p codesigning -v 2>/dev/null | grep -q "$NAME"; then
  echo "✅ Created shared signing identity '$NAME'."
else
  echo "⚠️  Identity created but not valid for code signing — check keychain trust settings."
fi
