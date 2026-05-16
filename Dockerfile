FROM node:24-slim AS builder

WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY tsconfig.json ./
COPY src/ ./src/
RUN npx tsc

FROM node:24-slim

WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev
COPY --from=builder /app/dist ./dist/
COPY src/db/migrations ./dist/db/migrations/

ENV NODE_ENV=production
EXPOSE 3000

CMD ["node", "dist/index.js"]
