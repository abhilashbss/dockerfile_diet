# alpine-base — node:22-alpine + libc6-compat (some native modules need glibc shims).
FROM node:22-alpine
WORKDIR /app
RUN apk add --no-cache libc6-compat
COPY . .
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production
RUN npm ci --include=dev && npm run build
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
EXPOSE 3000
CMD ["npx", "next", "start", "-H", "0.0.0.0", "-p", "3000"]
