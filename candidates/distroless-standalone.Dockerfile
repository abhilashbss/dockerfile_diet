# distroless-standalone — distroless/nodejs22 runtime over standalone bundle.
# distroless has node + a minimal glibc userland — no shell, no apt, no curl.
# Build still happens on slim. The image's ENTRYPOINT is node, so CMD is just
# the script path.

FROM node:22-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --include=dev

FROM node:22-slim AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN rm -f next.config.ts next.config.js next.config.mjs next.config.cjs && \
    printf 'module.exports = { output: "standalone" };\n' > next.config.js
RUN npm run build

FROM gcr.io/distroless/nodejs22-debian12:nonroot AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
COPY --from=builder --chown=nonroot:nonroot /app/public ./public
COPY --from=builder --chown=nonroot:nonroot /app/.next/standalone ./
COPY --from=builder --chown=nonroot:nonroot /app/.next/static ./.next/static
EXPOSE 3000
# distroless nodejs22 has node as the ENTRYPOINT — CMD is the script to run.
CMD ["server.js"]
