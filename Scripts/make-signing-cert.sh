#!/bin/bash
#
# make-signing-cert.sh — create a local code-signing identity for development.
#
# WHY THIS EXISTS
#
# macOS grants Screen Recording to a *code requirement*, not to an app name or
# path. For an ad-hoc signed build that requirement is literally the hash of the
# binary:
#
#     designated => cdhash H"32e887fa7b8f8caf54b006b5300f7588b9dcef00"
#
# Every rebuild changes that hash, so every rebuild is a different app as far as
# TCC is concerned. The old permission row survives in System Settings, still
# switched on, attached to a rule the new binary can never satisfy — which is
# why toggling it off and on again does nothing.
#
# Signing with a certificate instead produces a stable requirement:
#
#     designated => identifier "app.vestige.Vestige" and certificate leaf = H"..."
#
# The leaf hash belongs to the certificate, not the binary, so it survives
# rebuilds and the permission sticks. This script creates a self-signed local
# identity for that purpose.
#
# SCOPE
#
# The certificate is self-signed and trusted by nothing. It is useless for
# distribution — its only job is to give this Mac a stable identity for Vestige.
# It is imported into your login keychain and can be removed at any time with
# Keychain Access, or with:
#
#     security delete-certificate -c "Vestige Local Signing"
#
set -euo pipefail

COMMON_NAME="Vestige Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$COMMON_NAME" >/dev/null 2>&1; then
    echo "==> '$COMMON_NAME' already exists in your keychain; nothing to do."
    echo "    To recreate it with the latest keychain access rules, run:"
    echo "    security delete-certificate -c \"$COMMON_NAME\""
    echo "    ./Scripts/make-signing-cert.sh"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"

# A config file rather than -addext, so this works with both LibreSSL (which
# macOS ships as /usr/bin/openssl) and a Homebrew OpenSSL earlier in PATH.
cat > "$WORK/cert.conf" <<'CONF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = Vestige Local Signing

[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CONF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "$WORK/cert.conf" \
    -keyout "$WORK/key.pem" \
    -out "$WORK/cert.pem" 2>/dev/null

# The legacy PBE algorithms are required. OpenSSL 3 defaults to AES-256-CBC with
# PBKDF2, which Apple's Security framework cannot unwrap — `security import`
# fails with "MAC verification failed" and misreports it as a wrong password.
openssl pkcs12 -export \
    -certpbe PBE-SHA1-3DES \
    -keypbe PBE-SHA1-3DES \
    -macalg sha1 \
    -inkey "$WORK/key.pem" \
    -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" \
    -passout pass:vestige 2>/dev/null

echo "==> Importing into your login keychain"

# Only codesign gets automatic access to the private key. Even though this is a
# throwaway self-signed development identity, keeping the ACL narrow prevents
# unrelated local tools from signing arbitrary code with it.
security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" \
    -P vestige \
    -T /usr/bin/codesign \
    >/dev/null

echo "==> Verifying the identity is usable"
if ! security find-identity -p codesigning | grep -q "$COMMON_NAME"; then
    echo "    Certificate imported but not visible as a signing identity." >&2
    echo "    Open Keychain Access and check the 'login' keychain." >&2
    exit 1
fi

echo "==> Done. '$COMMON_NAME' is ready."
echo "    build-app.sh will now use it automatically."
