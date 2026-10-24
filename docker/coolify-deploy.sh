#!/usr/bin/env bash
# Creates (or updates) the Quickinbox app on a Coolify server and deploys it.
# Secrets are read from the terminal without echo and are never printed.
#
#   bash docker/coolify-deploy.sh
#
# Overridable: COOLIFY_URL, APP_DOMAIN, GIT_REPO, GIT_BRANCH, PROJECT_NAME, SERVER_UUID
set -euo pipefail

COOLIFY_URL="${COOLIFY_URL:-http://169.58.213.197:8000}"
APP_DOMAIN="${APP_DOMAIN:-mail.udala.pro}"
GIT_REPO="${GIT_REPO:-https://github.com/vickukbrown-ctrl/quickinbox}"
GIT_BRANCH="${GIT_BRANCH:-main}"
PROJECT_NAME="${PROJECT_NAME:-Quickinbox}"
APP_NAME="quickinbox"
API="$COOLIFY_URL/api/v1"

command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }

read -rsp "Coolify API token: " TOKEN; echo
read -rsp "Resend API key (Enter to skip for now): " RESEND_KEY; echo
read -rsp "Resend webhook secret whsec_... (Enter to skip for now): " RESEND_WEBHOOK; echo

call() { # method path [json]
	local method="$1" path="$2" body="${3:-}" out code
	out=$(mktemp)
	if [ -n "$body" ]; then
		code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$API$path" \
			-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json' -d "$body")
	else
		code=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "$API$path" \
			-H "Authorization: Bearer $TOKEN" -H 'Accept: application/json')
	fi
	if [ "${code:0:1}" != "2" ]; then
		echo "✘ $method $path -> HTTP $code" >&2
		jq -c . "$out" 2>/dev/null >&2 || cat "$out" >&2
		rm -f "$out"
		return 1
	fi
	cat "$out"; rm -f "$out"
}

echo "→ Coolify $(call GET /version)"

# Server: the one Coolify itself runs on unless SERVER_UUID is given.
SERVERS=$(call GET /servers)
if [ -z "${SERVER_UUID:-}" ]; then
	SERVER_UUID=$(echo "$SERVERS" | jq -r '(map(select(.ip=="host.docker.internal" or .name=="localhost")) + .)[0].uuid')
fi
echo "→ Server: $(echo "$SERVERS" | jq -r --arg u "$SERVER_UUID" '.[] | select(.uuid==$u) | "\(.name) (\(.ip))"')"

# Project + production environment.
PROJECT_UUID=$(call GET /projects | jq -r --arg n "$PROJECT_NAME" '.[] | select(.name==$n) | .uuid' | head -1)
if [ -z "$PROJECT_UUID" ]; then
	PROJECT_UUID=$(call POST /projects "$(jq -nc --arg n "$PROJECT_NAME" '{name:$n, description:"Self-hosted email"}')" | jq -r .uuid)
	echo "→ Created project $PROJECT_NAME"
else
	echo "→ Using project $PROJECT_NAME"
fi
ENV_UUID=$(call GET "/projects/$PROJECT_UUID/environments" | jq -r '(map(select(.name=="production")) + .)[0].uuid')

# Application (reuse if it already exists).
APP_UUID=$(call GET /applications | jq -r --arg n "$APP_NAME" --arg r "$GIT_REPO" \
	'.[] | select(.name==$n or (.git_repository|tostring|test($r|split("github.com/")[1]))) | .uuid' | head -1)
if [ -z "$APP_UUID" ]; then
	APP_UUID=$(call POST /applications/public "$(jq -nc \
		--arg p "$PROJECT_UUID" --arg s "$SERVER_UUID" --arg e "$ENV_UUID" \
		--arg repo "$GIT_REPO" --arg br "$GIT_BRANCH" --arg d "https://$APP_DOMAIN" --arg n "$APP_NAME" \
		'{project_uuid:$p, server_uuid:$s, environment_uuid:$e, environment_name:"production",
		  git_repository:$repo, git_branch:$br, build_pack:"dockerfile", ports_exposes:"8787",
		  name:$n, description:"Quickinbox mail (workerd + Resend)", domains:$d,
		  is_force_https_enabled:true, instant_deploy:false}')" | jq -r .uuid)
	echo "→ Created application $APP_UUID"
else
	echo "→ Using existing application $APP_UUID"
fi

# Persistent volume for D1 (SQLite) + R2 attachments.
if call GET "/applications/$APP_UUID/storages" 2>/dev/null | jq -e '.persistent_storages[]? | select(.mount_path=="/data")' >/dev/null; then
	echo "→ /data volume already attached"
elif call POST "/applications/$APP_UUID/storages" '{"type":"persistent","name":"quickinbox-data","mount_path":"/data"}' >/dev/null; then
	echo "→ Attached volume quickinbox-data at /data"
else
	echo "⚠ Could not add the volume via API. In Coolify open the app → Persistent Storage →"
	echo "  add Volume name 'quickinbox-data', destination '/data', BEFORE you create mail."
fi

# Environment. ENCRYPTION_KEY is only generated the first time and never rotated.
EXISTING_KEYS=$(call GET "/applications/$APP_UUID/envs" | jq -r '.[].key' || true)
ENVS=$(jq -nc --arg h "$APP_DOMAIN" '[
	{key:"PUBLIC_HOST", value:$h},
	{key:"APP_URL", value:("https://"+$h)},
	{key:"EMAIL_PROVIDER", value:"resend"}]')
add_env() { ENVS=$(echo "$ENVS" | jq -c --arg k "$1" --arg v "$2" '. + [{key:$k, value:$v, is_literal:true}]'); }
if ! grep -qx ENCRYPTION_KEY <<<"$EXISTING_KEYS"; then add_env ENCRYPTION_KEY "$(openssl rand -base64 36 | tr -d '\n')"; fi
[ -n "$RESEND_KEY" ] && add_env RESEND_API_KEY "$RESEND_KEY"
[ -n "$RESEND_WEBHOOK" ] && add_env RESEND_WEBHOOK_SECRET "$RESEND_WEBHOOK"
call PATCH "/applications/$APP_UUID/envs/bulk" "$(jq -nc --argjson d "$ENVS" '{data:$d}')" >/dev/null
echo "→ Set env: $(echo "$ENVS" | jq -r 'map(.key) | join(", ")')"

DEPLOY=$(call GET "/deploy?uuid=$APP_UUID&force=false")
echo "→ Deploy queued: $(echo "$DEPLOY" | jq -r '.deployments[0].deployment_uuid // .message // .')"
echo
echo "App UUID: $APP_UUID"
echo "Watch it in Coolify: $COOLIFY_URL/project/$PROJECT_UUID/environment/$ENV_UUID/application/$APP_UUID"
