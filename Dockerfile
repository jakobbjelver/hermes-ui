# Stage 1: Build hermes-ui static dist from the monorepo extraction
FROM oven/bun:1 AS builder
WORKDIR /build

# Copy shared types/utilities (the @hermes/shared package referenced by app)
COPY shared/ /build/shared/

# Copy app (the Vite React app) and install + build
COPY app/ /build/app/
WORKDIR /build/app
RUN bun install
RUN bun run build

# Stage 2: Serve via nginx
FROM nginx:alpine
COPY --from=builder /build/app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
