# Self-hosting with Docker (Coolify)

The image runs the Worker on workerd through `wrangler dev --local`, using
`wrangler.selfhost.jsonc`. D1 (SQLite) and R2 (attachments) live under `/data`
— mount a persistent volume there. Migrations run on every start.

Mail must use **Resend** (`EMAIL_PROVIDER=resend`); Cloudflare Email Service and
Workers AI are not available outside Cloudflare.

## Environment

| Variable | Required | Notes |
| --- | --- | --- |
| `PUBLIC_HOST` | yes | Public hostname, e.g. `mail.example.com`. Makes the app see `https://<host>` URLs. |
| `RESEND_API_KEY` | yes | Full-access Resend key |
| `RESEND_WEBHOOK_SECRET` | yes | From the Resend webhook pointed at `https://<host>/api/webhooks/resend` |
| `ENCRYPTION_KEY` | yes | 32+ random chars; never change it |
| `APP_URL` | recommended | `https://<host>` |
| `TYPESAFE_API_KEY`, `TELEGRAM_*`, `VAPID_*` | optional | See the main README |
| `PORT` | no | Default `8787` |

Back up `/data` — it holds every message and attachment.
