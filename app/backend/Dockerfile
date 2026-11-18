FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:20-alpine AS production
RUN addgroup -g 1001 -S ecm && adduser -S -u 1001 -G ecm ecm
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY --chown=ecm:ecm src/ ./src/
COPY --chown=ecm:ecm package.json ./
USER ecm
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "src/index.js"]
