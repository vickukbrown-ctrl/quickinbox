#!/usr/bin/env bash
# Checks that Resend can send and receive for your domains:
#   - each domain's verification status in Resend
#   - every DNS record Resend expects (MX, SPF, DKIM) vs what public DNS has now
#   - the Quickinbox webhook is reachable
#   - optionally sends one test email
# The API key is read without echo and never printed.
#
#   bash docker/resend-check.sh
set -uo pipefail

APP_URL="${APP_URL:-https://mail.udala.pro}"
DNS="${DNS_SERVER:-1.1.1.1}"
API=https://api.resend.com

for bin in curl jq dig; do command -v "$bin" >/dev/null || { echo "$bin is required"; exit 1; }; done
read -rsp "Resend API key: " KEY; echo

ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✘\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
PROBLEMS=0

get() { curl -sS -H "Authorization: Bearer $KEY" -H 'Accept: application/json' "$API$1"; }
norm() { tr 'A-Z' 'a-z' | sed 's/\.$//; s/^"//; s/"$//' | tr -d '" '; }

DOMAINS=$(get /domains)
if ! echo "$DOMAINS" | jq -e '.data' >/dev/null 2>&1; then
	echo "Resend API error: $(echo "$DOMAINS" | jq -r '.message // .' 2>/dev/null)"
	exit 1
fi
[ "$(echo "$DOMAINS" | jq '.data | length')" = 0 ] && { echo "No domains in this Resend account."; exit 1; }

for id in $(echo "$DOMAINS" | jq -r '.data[].id'); do
	D=$(get "/domains/$id")
	domain=$(echo "$D" | jq -r .name)
	echo
	echo "== $domain  (Resend status: $(echo "$D" | jq -r .status), region: $(echo "$D" | jq -r '.region // "?"'))"
	echo "$D" | jq -c '.capabilities // empty' | sed 's/^/  capabilities: /'
	[ "$(echo "$D" | jq -r .status)" = verified ] && ok "domain verified" || bad "domain is not verified in Resend"

	while read -r rec; do
		[ -n "$rec" ] || continue
		label=$(echo "$rec" | jq -r '.record // "?"')
		type=$(echo "$rec" | jq -r .type)
		name=$(echo "$rec" | jq -r '.name // ""')
		want=$(echo "$rec" | jq -r .value | norm)
		prio=$(echo "$rec" | jq -r '.priority // empty')
		rstatus=$(echo "$rec" | jq -r '.status // "?"')
		case "$name" in
			''|'@') fqdn=$domain ;;
			*."$domain"|"$domain") fqdn=$name ;;
			*) fqdn="$name.$domain" ;;
		esac
		if [ "$type" = MX ]; then
			have=$(dig +short MX "$fqdn" @"$DNS" | awk '{print $2}' | norm)
		else
			have=$(dig +short "$type" "$fqdn" @"$DNS" | tr -d '\n' | norm)
		fi
		desc="$label $type $fqdn${prio:+ (prio $prio)} [Resend: $rstatus]"
		if [ -z "$have" ]; then
			bad "$desc — MISSING in DNS (expected: $want)"
		elif grep -qxF "$want" <<<"$have" || [ "$have" = "$want" ]; then
			ok "$desc"
		else
			bad "$desc — DNS has: $(echo "$have" | tr '\n' ' '| cut -c1-120) expected: $(echo "$want" | cut -c1-120)"
		fi
		if [ "$type" = MX ]; then
			others=$(dig +short MX "$fqdn" @"$DNS" | awk '{print $2}' | norm | grep -vxF "$want" || true)
			[ -n "$others" ] && warn "$fqdn also has other MX hosts (mail may go there instead): $(echo $others)"
		fi
	done < <(echo "$D" | jq -c '.records[]?')
done

echo
echo "== Webhook"
WH=$(get /webhooks 2>/dev/null)
if echo "$WH" | jq -e '.data' >/dev/null 2>&1; then
	echo "$WH" | jq -r '.data[] | "  \(.status // "?")  \(.endpoint // .url)  events: \((.events // []) | join(","))"'
	echo "$WH" | jq -e --arg u "$APP_URL/api/webhooks/resend" '.data[] | select((.endpoint // .url) == $u)' >/dev/null \
		&& ok "webhook to $APP_URL/api/webhooks/resend exists" \
		|| bad "no webhook points to $APP_URL/api/webhooks/resend"
else
	warn "could not list webhooks via API; check https://resend.com/webhooks by hand"
fi
code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$APP_URL/api/webhooks/resend")
[ "$code" = 401 ] && ok "endpoint reachable (rejects unsigned calls with 401, as it should)" || bad "endpoint returned HTTP $code (expected 401)"

echo
read -rp "Send a test email now? Enter 'from' address (blank to skip): " FROM
if [ -n "$FROM" ]; then
	read -rp "Send it to: " TO
	R=$(curl -sS -X POST "$API/emails" -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
		-d "$(jq -nc --arg f "$FROM" --arg t "$TO" '{from:$f, to:[$t], subject:"Resend check", text:"Test from resend-check.sh"}')")
	EID=$(echo "$R" | jq -r '.id // empty')
	if [ -n "$EID" ]; then
		ok "accepted by Resend (id $EID); checking status in 10s"
		sleep 10
		ok "last event: $(get "/emails/$EID" | jq -r '.last_event // "unknown"')"
	else
		bad "send failed: $(echo "$R" | jq -r '.message // .')"
	fi
fi

echo
[ "$PROBLEMS" -eq 0 ] && echo "All checks passed." || echo "$PROBLEMS problem(s) found — see ✘ lines above."
