# standalone-slim — Next.js standalone output. Runtime drops node_modules
# entirely; only the standalone bundle (server.js + minimal vendored deps) ships.
# next.config.ts is replaced inside the build with one that enables standalone.
# This is a Dockerfile-only edit — the host repo's next.config.ts is unchanged.

FROM node:22-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --include=dev

FROM node:22-slim AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
# Override next config: drop any existing next.config.* and write a standalone-enabled one.
RUN rm -f next.config.ts next.config.js next.config.mjs next.config.cjs && \
    printf 'module.exports = { output: "standalone" };\n' > next.config.js
RUN npm run build

FROM node:22-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
# standalone bundle contains its own minimal node_modules — no npm needed at runtime.
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
EXPOSE 3000
CMD ["node", "server.js"]
