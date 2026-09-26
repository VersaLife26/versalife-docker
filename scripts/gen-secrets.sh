#!/usr/bin/env bash
#
# Generate the machine-generated half of secrets/secrets.env.
#
# IDEMPOTENT AND NON-DESTRUCTIVE. It only fills keys that are missing or
# empty, so re-running it never rotates anything. Crypto__BankDataKey and
# Prescriptions__HmacKey in particular are one-way doors: rotating them
# orphans stored bank details and invalidates every issued prescription QR.
#
#   ./scripts/gen-secrets.sh
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=secrets/secrets.env

mkdir -p secrets
if [[ ! -f "$OUT" ]]; then
  cp env/secrets.env.example "$OUT"
  echo "created $OUT from the example"
fi
chmod 600 "$OUT"

# URL-safe and unpadded: TELEMED_API_DB_PASSWORD is spliced into a Npgsql
# connection string, where `;` and `=` would be read as separators.
rand()  { openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'; }
hex32() { openssl rand -hex 32 | tr -d '\n'; }
# Standard base64 WITH padding: Crypto__BankDataKey is decoded, and must be exactly 32 bytes.
b64key() { openssl rand -base64 32 | tr -d '\n'; }

# fill KEY VALUE -- sets KEY only when it is missing or empty.
fill() {
  local key=$1 value=$2
  if ! grep -q "^${key}=" "$OUT"; then
    printf '%s=%s\n' "$key" "$value" >> "$OUT"
    echo "  added   $key"
    return
  fi
  if [[ -n "$(sed -n "s/^${key}=//p" "$OUT")" ]]; then
    echo "  keep    $key (already set)"
    return
  fi
  local esc=${value//\\/\\\\}
  esc=${esc//|/\\|}
  esc=${esc//&/\\&}
  sed -i "s|^${key}=.*|${key}=${esc}|" "$OUT"
  echo "  set     $key"
}

echo "database"
fill POSTGRES_PASSWORD       "$(rand)"
fill TELEMED_API_DB_PASSWORD "$(rand)"

echo "application keys"
fill Auth__Jwt__SigningKey   "$(rand)"
fill Otp__HmacKey            "$(rand)"
fill Storage__SigningKey     "$(rand)"
fill Video__RoomTokenKey     "$(rand)"
fill Crypto__BankDataKey     "$(b64key)"
fill Prescriptions__HmacKey  "$(hex32)"

cat <<'NEXT'

Done. Not generated -- versalife-ansible writes these from its vault, or fill
them in by hand:

  Cloudflare Access  AdminAuth__CloudflareAccess__{TeamDomain,Audience}, AdminAuth__IpAllowlist__0
  Origins            Cors__Origins__*, Cors__AdminOrigins__*, AppLinks__PatientAppUrl
  Rails              Turn__Cloudflare__*, Sms__*, Email__*, Payments__PayHere__*
  Test inbox         Testing__SharedSecret (16+ chars; the frontend sends it as X-Test-Secret)

and secrets/tunnel-credentials.json from `cloudflared tunnel create`.
NEXT
