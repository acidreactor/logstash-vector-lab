#!/bin/sh
# Добавляет в access-лог nginx строку, которую Elasticsearch отклонит:
# в поле client.ip (тип ip) попадёт имя хоста. Событие уходит в Dead Letter Queue Logstash.
# Запускать из любого места, стек vm1-cms должен работать.
cd "$(dirname "$0")/../../vm1-cms" || exit 1

ts=$(date -u +%d/%b/%Y:%H:%M:%S)
line="bad.host.example - - [$ts +0000] \"GET /dlq-test HTTP/1.1\" 200 5 \"-\" \"dlq-test\""

docker compose exec -T nginx sh -c "printf '%s\n' '$line' >> /var/log/lab-nginx/access.log"
echo "строка добавлена: $line"
