# --- Build stage ---
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

# --- Runtime stage ---
FROM node:20-alpine
WORKDIR /app

# Run as non-root user (numeric UID/GID so Kubernetes runAsNonRoot can verify it)
RUN addgroup -g 1001 -S appgroup && adduser -u 1001 -S appuser -G appgroup

COPY --from=builder /app/node_modules ./node_modules
COPY package.json ./
COPY server.js ./

ENV PORT=8080
EXPOSE 8080

USER 1001

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1

CMD ["node", "server.js"]
