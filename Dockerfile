# ── Stage 1: build frontend assets (Vite + Tailwind) ─────────────────────
FROM node:22-bookworm-slim AS frontend
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY resources resources
COPY vite.config.js ./
RUN npm run build

# ── Stage 2: PHP runtime ──────────────────────────────────────────────────
FROM php:8.3-cli-bookworm

# tesseract-ocr: OcrService shells out to the `tesseract` binary for
# receipt scanning — without it, POST /api/receipts/scan 500s.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git unzip libzip-dev libpng-dev libonig-dev libxml2-dev libsqlite3-dev \
        tesseract-ocr \
    && docker-php-ext-install pdo pdo_sqlite mbstring exif pcntl bcmath gd zip \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html
COPY . .
COPY --from=frontend /app/public/build ./public/build

RUN composer install --no-dev --optimize-autoloader --no-interaction \
    && chmod -R 775 storage bootstrap/cache

# Render injects $PORT at runtime (like Railway). SQLite has no persistent
# disk on the free tier, so it's recreated fresh on every boot — same
# accepted trade-off as the Railway deploy; DatabaseSeeder is idempotent.
CMD touch database/database.sqlite \
    && php artisan migrate --force \
    && php artisan db:seed --force \
    && (php artisan storage:link || true) \
    && (php artisan schedule:work &) \
    && (php artisan queue:work --tries=3 --timeout=90 &) \
    && exec php artisan serve --host=0.0.0.0 --port=$PORT
