#!/usr/bin/env bash
# Generates VAPID keys for desktop notifications, stores them on the Coolify
# app, and redeploys. Skips generation if keys already exist (rotating them
# would break every existing subscription). Secrets are never printed.
#
#   bash docker/coolify-vapid.sh
set -euo pipefail

COOLIFY_URL="${COOLIFY_URL:-http://169.58.213.197:8000}"
APP_UUID="${APP_UUID:-wesyf38r1nxdjyqorx6axs6s}"
API="$COOLIFY_URL/api/v1"

for bin in curl jq npx; do command -v "$bin" >/dev/null || { echo "$bin is required"; exit 1; }; done
read -rsp "Coolify API token: " TOKEN; echo
read -rp "Contact for push services [mailto:admin@udala.pro]: " SUBJECT
SUBJECT="${SUBJECT:-mailto:admin@udala.pro}"

auth=(-H "Authorization: Bearer $TOKEN" -H 'Accept: application/json')

EXISTING=$(curl -fsS "${auth[@]}" "$API/applications/$APP_UUID/envs" | jq -r '.[].key')
if grep -qx VAPID_PRIVATE_KEY <<<"$EXISTING" && grep -qx VAPID_PUBLIC_KEY <<<"$EXISTING"; then
	echo "→ VAPID keys already set; keeping them (only updating VAPID_SUBJECT)"
	DATA=$(jq -nc --arg s "$SUBJECT" '[{key:"VAPID_SUBJECT", value:$s, is_literal:true}]')
else
	KEYS=$(npx --yes web-push@3.6.7 generate-vapid-keys --json)
	DATA=$(echo "$KEYS" | jq -c --arg s "$SUBJECT" '[
		{key:"VAPID_PUBLIC_KEY", value:.publicKey, is_literal:true},
		{key:"VAPID_PRIVATE_KEY", value:.privateKey, is_literal:true},
		{key:"VAPID_SUBJECT", value:$s, is_literal:true}]')
	echo "→ Generated new VAPID key pair"
fi

curl -fsS -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
	"$API/applications/$APP_UUID/envs/bulk" -d "$(jq -nc --argjson d "$DATA" '{data:$d}')" >/dev/null
echo "→ Saved env: $(echo "$DATA" | jq -r 'map(.key) | join(", ")')"

DEPLOY=$(curl -fsS -X POST "${auth[@]}" -H 'Content-Type: application/json' -d '{}' "$API/deploy?uuid=$APP_UUID&force=false")
echo "→ Redeploy queued: $(echo "$DEPLOY" | jq -r '.deployments[0].deployment_uuid // .message // .')"
echo "When it's live (~3 min), reload Settings → Notifications and turn it on."
