#!/bin/bash
# Creates a local self-signed code-signing certificate in the login keychain.
# Signing with a *stable* identity (instead of ad-hoc) keeps the macOS
# Accessibility grant across rebuilds, so you only authorize the app once.
#
# Usage:  ./scripts/create-signing-cert.sh ["Cert Name"]
# Then:   make app SIGN_ID="MacTranslator Dev"
set -euo pipefail

CERT_NAME="${1:-MacTranslator Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Use macOS's system LibreSSL: its PKCS#12 defaults import cleanly into the
# keychain (Homebrew OpenSSL 3 uses algorithms `security` can't verify).
OPENSSL="${OPENSSL:-/usr/bin/openssl}"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "ℹ️  证书「$CERT_NAME」已存在，跳过创建。"
    security find-identity -v -p codesigning | grep "$CERT_NAME" || true
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) OpenSSL config describing a code-signing leaf certificate.
cat > "$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3_codesign
prompt             = no

[ dn ]
CN = $CERT_NAME

[ v3_codesign ]
basicConstraints   = critical, CA:FALSE
keyUsage           = critical, digitalSignature
extendedKeyUsage   = critical, codeSigning
EOF

# 2) Generate key + self-signed cert (valid 10 years).
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -config "$TMP/openssl.cnf"

# 3) Bundle into a PKCS#12. A non-empty transport password avoids a keychain
#    "MAC verification failed" quirk with empty-password bundles.
P12_PASS="mactranslator-import"
"$OPENSSL" pkcs12 -export -name "$CERT_NAME" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:"$P12_PASS"

# 4) Import into the login keychain; -A lets codesign use the key without prompts.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A

echo "✅ 已创建并导入证书：$CERT_NAME"
security find-identity -v -p codesigning | grep "$CERT_NAME" \
    || echo "⚠️  未在 codesigning 身份列表中看到它（签名时仍可能可用，下一步会验证）。"
