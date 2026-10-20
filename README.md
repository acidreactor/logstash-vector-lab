# Преобразование логов с помощью Logstash и Vector

Продолжение стенда из предыдущей работы (две ВМ: CMS и мониторинг). Filebeat теперь отправляет
**сырые** строки логов, а разбор на поля выполняет Logstash (grok) или Vector (VRL), после чего данные
попадают в Elasticsearch и отображаются в Kibana.

| Стек | Роль | Компоненты |
|------|------|------------|
| `vm1-cms` | ВМ с CMS | WordPress (php-fpm), nginx, MySQL, filebeat |
| `vm2-elk` | ВМ мониторинга | Elasticsearch, Kibana, **Logstash** или **Vector** |

```
vm1-cms                                  vm2-elk
nginx / php-fpm / mysql                  +--> Logstash (grok, DLQ, ILM) --+
        |  файлы логов                   |                                +--> Elasticsearch <-- Kibana
     filebeat --- сырые строки :5044 ----+--> Vector   (VRL)  ------------+
```

Logstash и Vector запускаются как два варианта одного приёмника (compose-профили `logstash` и `vector`),
оба слушают порт 5044 и доступны в сети под именем `ingest`, поэтому одновременно работает только один из них.

## Структура

```
vm1-cms/
  docker-compose.yml
  .env.example
  nginx/default.conf
  php-fpm/zzz-logs.conf        # формат access-лога php-fpm
  mysql/lab.cnf                # error и slow log MySQL в файлы
  filebeat/filebeat.yml        # без разбора, output.logstash
vm2-elk/
  docker-compose.yml
  .env.example
  logstash/
    config/logstash.yml        # включён Dead Letter Queue
    config/pipelines.yml
    pipeline/main.conf         # beats -> grok -> elasticsearch (ILM)
    pipeline/dlq.conf          # чтение DLQ -> индекс lab-dlq-*
  vector/vector.yaml           # logstash source -> VRL -> elasticsearch, плюс unit-тесты
  scripts/
    setup-es.sh                # ILM-политики и шаблоны индексов
    create-data-views.sh       # data views в Kibana
    dlq-test.sh                # событие для проверки DLQ
screenshots/
```

## Требования

- Docker с Compose v2
- около 4 ГБ свободной памяти и 4 ГБ на диске под образы
- на Linux-хосте: `sudo sysctl -w vm.max_map_count=262144`
- если на машине ещё работает стенд из предыдущей работы, его нужно остановить (те же порты 8080, 9200, 5601):
  `docker compose down -v` в каталогах `vm1-cms` и `vm2-elk` предыдущего репозитория

## Запуск

Общая сеть:

```bash
docker network create lab2-net
```

Вторая ВМ: Elasticsearch, Kibana, ILM-политики и шаблоны, приёмник логов.
Сначала вариант с Logstash:

```bash
cd vm2-elk
cp .env.example .env
docker compose --profile logstash up -d
```

Первая ВМ:

```bash
cd ../vm1-cms
cp .env.example .env
docker compose up -d
```

Вторую ВМ нужно запускать первой: ILM-политики и шаблоны индексов должны существовать до того,
как Logstash начнёт создавать индексы. Logstash стартует около минуты, пока он недоступен,
Filebeat повторяет подключение сам.

WordPress: http://localhost:8080 (мастер установки при первом открытии), Kibana: http://localhost:5601.

## Генерация данных

```bash
# access-логи nginx и php-fpm
for i in $(seq 1 30); do curl -s -o /dev/null http://localhost:8080/; done

# 404 и запись в error-лог nginx
curl -s -o /dev/null http://localhost:8080/missing.php

# запись в slow log MySQL (порог 1 секунда)
cd vm1-cms
docker compose exec mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT SLEEP(2);"'
cd ..
```

После появления данных создать data views:

```bash
./vm2-elk/scripts/create-data-views.sh
```

## Что настроено

### Filebeat

`vm1-cms/filebeat/filebeat.yml` читает шесть файлов (access и error nginx и php-fpm, error и slow MySQL)
и отправляет строки без изменений через `output.logstash`. Для slow log MySQL используется multiline,
чтобы многострочная запись приходила одним событием. К событию добавляются только поля
`service.name` и `log_type`, по ним приёмник выбирает правило разбора.

### Logstash: grok

`vm2-elk/logstash/pipeline/main.conf`. Для каждой пары `service.name` / `log_type` свой фильтр `grok`
и `date`, который берёт `@timestamp` из времени записи в логе:

| Лог | Основные поля |
|-----|---------------|
| nginx access | `client.ip`, `http.request.method`, `url.original`, `http.response.status_code`, `http.response.body.bytes`, `user_agent.original` |
| nginx error | `log.level`, `process.pid`, `error.message`, `client.ip`, `nginx.request`, `nginx.host` |
| php-fpm access | `client.ip`, `http.request.method`, `url.original`, `http.response.status_code`, `php.duration_ms`, `php.memory_kb` |
| php-fpm error | `log.level`, `error.message` |
| mysql error | `log.level`, `mysql.error_code`, `mysql.subsystem`, `error.message` |
| mysql slow | `user.name`, `mysql.query_time`, `mysql.lock_time`, `mysql.rows_sent`, `mysql.rows_examined`, `mysql.query` |

Строки, не подошедшие под шаблон, сохраняются как есть с тегом `_grokparsefailure`.
Формат access-лога php-fpm задан в `vm1-cms/php-fpm/zzz-logs.conf`.

### Vector: VRL

`vm2-elk/vector/vector.yaml`. Источник `logstash` принимает данные Filebeat, transform `remap`
разбирает строки теми же правилами на VRL (`parse_regex`, `parse_timestamp`, `to_int` и т.д.),
sink `elasticsearch` пишет в индексы `lab-vector-<сервис>-ГГГГ.ММ.ДД`. Имена полей совпадают с Logstash.
Непарсящиеся строки получают тег `_parsefailure`.

В конфиг встроены unit-тесты на все шесть форматов логов:

```bash
cd vm2-elk
docker compose --profile vector run --rm --no-deps vector test /etc/vector/vector.yaml
```

### Переключение на Vector

```bash
cd vm2-elk
docker compose stop logstash
docker compose --profile vector up -d
cd ../vm1-cms && docker compose restart filebeat
```

После этого снова сгенерировать трафик (раздел «Генерация данных»). Данные Vector видны в индексах `lab-vector-*`
(data views `vector: *`), данные Logstash - в `lab-nginx-*`, `lab-php-fpm-*`, `lab-mysql-*` (data views `logstash: *`).
Обратно: `docker compose stop vector && docker compose --profile logstash up -d`.

### Dead Letter Queue (Logstash)

В `logstash.yml` включён `dead_letter_queue.enable`, очередь хранится в `/usr/share/logstash/data/dlq`
(именованный том `logstash_data`). Туда попадают события, которые Elasticsearch отклонил
из-за ошибки маппинга (HTTP 400). Второй пайплайн `dlq-reader` (`pipeline/dlq.conf`) читает очередь
и сохраняет записи в индекс `lab-dlq-*` вместе с причиной отказа (`dlq.reason`).

Поле `client.ip` в шаблонах индексов имеет тип `ip`. Для проверки в access-лог добавляется строка,
в которой вместо адреса стоит имя хоста:

```bash
./vm2-elk/scripts/dlq-test.sh
```

Результат:

```bash
cd vm2-elk
docker compose exec logstash ls -R /usr/share/logstash/data/dlq
curl -s 'localhost:9200/lab-dlq-*/_search?pretty'
```

В Kibana - data view `logstash: DLQ`, поле `dlq.reason` содержит текст ошибки `failed to parse field [client.ip] of type [ip]`.
Проверка относится к Logstash: sink Vector такие ответы Elasticsearch только логирует.

### ILM (Logstash)

В каждом `elasticsearch` output в `main.conf` включён ILM (`ilm_enabled`, `ilm_rollover_alias`, `ilm_policy`):
Logstash создаёт первый индекс и пишет в rollover-алиас. Политики и шаблоны индексов создаются при старте
скриптом `scripts/setup-es.sh` (Logstash не создаёт пользовательские политики сам):

| Алиас | Политика | Хранение |
|-------|----------|----------|
| `lab-nginx` | `lab-logs-30d` | 30 дней |
| `lab-mysql` | `lab-logs-30d` | 30 дней |
| `lab-php-fpm` | `lab-logs-14d` | 14 дней |

Политика состоит из фаз `hot` (rollover раз в сутки или при 5 ГБ) и `delete` (через 30 или 14 дней после rollover).
Для индексов Vector созданы аналогичные политики `lab-vector-30d` / `lab-vector-14d` с одной фазой `delete`.

Проверка:

```bash
curl -s 'localhost:9200/_cat/aliases/lab-*?v'
curl -s 'localhost:9200/_ilm/policy/lab-logs-30d?pretty'
curl -s 'localhost:9200/_ilm/policy/lab-logs-14d?pretty'
curl -s 'localhost:9200/lab-*/_ilm/explain?pretty' | grep -E '"index"|"policy"|"phase"'
```

## Проверка в Kibana

Discover, data view `logstash: nginx` (или другой). Примеры запросов KQL:

```
http.response.status_code >= 400
mysql.query_time > 1
not tags : "_grokparsefailure"
```

Колонки для скриншота: `client.ip`, `http.request.method`, `url.original`, `http.response.status_code`
для nginx; `log.level`, `error.message` для error-логов; `mysql.query_time`, `mysql.query` для slow log.
Полученные скриншоты положить в каталог `screenshots/`.

## Запуск на отдельных ВМ

Общая сеть `lab2-net` в этом случае не нужна:

- в `vm1-cms/.env`: `PIPELINE_HOST=<IP второй ВМ>:5044`;
- убрать секцию `networks` из compose-файлов и из сервисов;
- порт 5044 у Logstash и Vector уже опубликован.

## Примечания

- Аутентификация Elasticsearch отключена (`xpack.security.enabled=false`) для упрощения стенда.
- Пароли в `.env.example` учебные.

## Остановка

```bash
docker compose -f vm1-cms/docker-compose.yml down
docker compose -f vm2-elk/docker-compose.yml --profile logstash --profile vector down
docker network rm lab2-net
```

Флаг `-v` дополнительно удалит тома с данными.
