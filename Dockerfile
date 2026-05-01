# Dockerfile — the mutable artifact under test.
#
# !! IMPORTANT: build context is the REPO ROOT (parent of this dir), not this dir.
# Use ./score.sh or ./loop.sh — they pass the right context. If you build by hand:
#   docker build -f dockerfile_autoresearch/Dockerfile -t app:autoresearch .
# from the repo root, NOT `docker build .` from inside dockerfile_autoresearch/.
#
# This file is rewritten by loop.sh on every iteration. After a full ratchet
# run it ends up containing the winning candidate. Out of the box it ships
# as a naive single-stage baseline so loop.sh has a real high-water mark to
# ratchet down from. If you're cloning this repo for a non-Node.js project,
# replace this with whatever a naive working Dockerfile looks like for your
# stack — the loop will swap in candidates from candidates/ regardless.

FROM node:22

WORKDIR /app

# Build context is the repo root; .dockerignore at the repo root keeps
# node_modules/ and build artifacts out of the build context.
COPY . .

ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production

# devDependencies are needed at build time (typescript, types, tailwind, etc.).
RUN npm ci --include=dev \
 && npm run build

ENV PORT=3000
ENV HOSTNAME=0.0.0.0
EXPOSE 3000

CMD ["npx", "next", "start", "-H", "0.0.0.0", "-p", "3000"]
