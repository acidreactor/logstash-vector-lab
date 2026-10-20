#!/bin/sh
# Создаёт data views в Kibana. Запускать, когда в Elasticsearch уже есть данные.
KIBANA="${KIBANA_URL:-http://localhost:5601}"

create() {
  curl -sS -f -X POST "$KIBANA/api/data_views/data_view" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -d "{\"override\":true,\"data_view\":{\"id\":\"$1\",\"name\":\"$2\",\"title\":\"$3\",\"timeFieldName\":\"@timestamp\"}}" >/dev/null \
    && echo "ok: $2"
}

create lab-ls-all     "logstash: all"      "lab-nginx-*,lab-php-fpm-*,lab-mysql-*"
create lab-ls-nginx   "logstash: nginx"    "lab-nginx-*"
create lab-ls-php     "logstash: php-fpm"  "lab-php-fpm-*"
create lab-ls-mysql   "logstash: mysql"    "lab-mysql-*"
create lab-vec-all    "vector: all"        "lab-vector-*"
create lab-vec-nginx  "vector: nginx"      "lab-vector-nginx-*"
create lab-vec-php    "vector: php-fpm"    "lab-vector-php-fpm-*"
create lab-vec-mysql  "vector: mysql"      "lab-vector-mysql-*"
create lab-dlq        "logstash: DLQ"      "lab-dlq-*"
