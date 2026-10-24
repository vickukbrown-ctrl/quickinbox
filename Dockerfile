# Self-hosted Quickinbox: runs the Cloudflare Worker on workerd (via
# `wrangler dev --local`) with D1 and R2 persisted under /data.
FROM node:22-bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl \
	&& rm -rf /var/lib/apt/lists/* \
	&& npm install -g bun@1.3.14

WORKDIR /app
ENV WRANGLER_SEND_METRICS=false \
	CI=true \
	PORT=8787 \
	WRANGLER_PERSIST_DIR=/data

COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

COPY . .
RUN bun run build

VOLUME /data
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
	CMD curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/login" || exit 1

ENTRYPOINT ["/app/docker/entrypoint.sh"]
