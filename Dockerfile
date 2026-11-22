FROM php:8.2-cli-alpine

WORKDIR /app

COPY backend /app/backend

RUN mkdir -p /app/backend/database /app/backend/logs \
    && chmod -R 775 /app/backend/database /app/backend/logs

ENV APP_ENV=production
ENV DB_DRIVER=sqlite
ENV PORT=8080

EXPOSE 8080

CMD ["sh", "-c", "php -S 0.0.0.0:${PORT:-8080} -t /app/backend /app/backend/router.php"]
