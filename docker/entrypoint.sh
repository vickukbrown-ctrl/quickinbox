#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
CONFIG=wrangler.selfhost.jsonc
PERSIST="${WRANGLER_PERSIST_DIR:-/data}"
mkdir -p "$PERSIST"

# Worker secrets and vars come from the container environment. wrangler dev
# reads them from .dev.vars, so write every known key that is set.
: > .dev.vars
for key in EMAIL_PROVIDER CLOUDFLARE_MAIL_DOMAINS RESEND_API_KEY RESEND_WEBHOOK_SECRET \
	TYPESAFE_API_KEY ENCRYPTION_KEY APP_URL TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID \
	TELEGRAM_THREAD_ID VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT; do
	eval "value=\${$key:-}"
	if [ -n "$value" ]; then
		escaped=$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
		printf '%s="%s"\n' "$key" "$escaped" >> .dev.vars
	fi
done
chmod 600 .dev.vars

npx wrangler d1 migrations apply DB --local -c "$CONFIG" --persist-to "$PERSIST"

# PUBLIC_HOST makes request.url (and so OAuth issuer, links, CSRF checks)
# match the public https hostname instead of the container address.
set -- --local -c "$CONFIG" --persist-to "$PERSIST" --ip 0.0.0.0 --port "${PORT:-8787}" \
	--show-interactive-dev-session=false --log-level "${LOG_LEVEL:-info}"
if [ -n "${PUBLIC_HOST:-}" ]; then
	set -- "$@" --host "$PUBLIC_HOST" --upstream-protocol "${PUBLIC_PROTOCOL:-https}"
fi

exec npx wrangler dev "$@"
