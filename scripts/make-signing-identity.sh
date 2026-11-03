#!/bin/zsh
# Create a self-signed code-signing identity, "VoiceCommand Local Signing", in your login
# keychain. build.sh uses it when you have no Apple Development certificate, so the app's
# signature (and therefore its Accessibility / Input Monitoring grants) stays the same
# across rebuilds. Run once. Remove it any time from Keychain Access.
set -euo pipefail
NAME="VoiceCommand Local Signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf $TMP' EXIT
cat > $TMP/cert.conf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config $TMP/cert.conf \
  -keyout $TMP/key.pem -out $TMP/cert.pem 2>/dev/null
PASS=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey $TMP/key.pem -in $TMP/cert.pem -name "$NAME" \
  -out $TMP/id.p12 -passout pass:$PASS 2>/dev/null
security import $TMP/id.p12 -k ~/Library/Keychains/login.keychain-db -P $PASS -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with ./build.sh; grant permissions once more, and they'll stick."
