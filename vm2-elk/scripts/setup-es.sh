#!/bin/sh
# ILM-политики и шаблоны индексов.
# nginx и mysql хранятся 30 дней, php-fpm - 14 дней.
#
# Logstash пишет в rollover-алиасы lab-nginx / lab-php-fpm / lab-mysql (политики с rollover + delete).
# Vector пишет в индексы по дням lab-vector-<сервис>-YYYY.MM.DD (политики только с delete).
set -e

ES="${ES_URL:-http://elasticsearch:9200}"

put() {
  curl -sS -f -X PUT "$ES$1" -H 'Content-Type: application/json' -d "$2"
  echo
}

policy_rollover() {  # имя, срок хранения после rollover
  put "/_ilm/policy/$1" "{\"policy\":{\"phases\":{\"hot\":{\"actions\":{\"rollover\":{\"max_age\":\"1d\",\"max_primary_shard_size\":\"5gb\"}}},\"delete\":{\"min_age\":\"$2\",\"actions\":{\"delete\":{}}}}}}"
}

policy_delete_only() {  # имя, срок хранения
  put "/_ilm/policy/$1" "{\"policy\":{\"phases\":{\"delete\":{\"min_age\":\"$2\",\"actions\":{\"delete\":{}}}}}}"
}

policy_rollover    lab-logs-30d   30d
policy_rollover    lab-logs-14d   14d
policy_delete_only lab-vector-30d 30d
policy_delete_only lab-vector-14d 14d

MAPPINGS='"mappings":{"properties":{"@timestamp":{"type":"date"},"client":{"properties":{"ip":{"type":"ip"}}}}}'

template() {  # имя шаблона, маска индексов, политика, rollover-алиас (может быть пустым)
  alias_setting=""
  [ -n "$4" ] && alias_setting=",\"index.lifecycle.rollover_alias\":\"$4\""
  put "/_index_template/$1" "{\"index_patterns\":[\"$2\"],\"priority\":200,\"template\":{\"settings\":{\"index.number_of_shards\":1,\"index.number_of_replicas\":0,\"index.lifecycle.name\":\"$3\"$alias_setting},$MAPPINGS}}"
}

# Logstash
template lab-nginx    'lab-nginx-*'    lab-logs-30d lab-nginx
template lab-php-fpm  'lab-php-fpm-*'  lab-logs-14d lab-php-fpm
template lab-mysql    'lab-mysql-*'    lab-logs-30d lab-mysql

# Vector
template lab-vector-nginx   'lab-vector-nginx-*'   lab-vector-30d ""
template lab-vector-php-fpm 'lab-vector-php-fpm-*' lab-vector-14d ""
template lab-vector-mysql   'lab-vector-mysql-*'   lab-vector-30d ""

# чаще проверять ILM, чтобы изменения были заметны быстрее
put /_cluster/settings '{"persistent":{"indices.lifecycle.poll_interval":"1m"}}'

echo "setup done"
