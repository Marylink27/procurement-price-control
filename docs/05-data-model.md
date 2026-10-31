# 5. Модель данных

Физическая модель для PostgreSQL: [`sql/01_schema.sql`](../sql/01_schema.sql). Ниже логическая модель, словарь ключевых полей и статусная модель предложения.

## ER-диаграмма

```mermaid
erDiagram
    SUPPLIER ||--o{ PRICE_SOURCE : "присылает через"
    SUPPLIER ||--o{ SUPPLIER_ITEM : "ведёт каталог"
    PRICE_SOURCE ||--o{ PRICE_IMPORT : "загрузки"
    PRICE_IMPORT ||--o{ IMPORT_ERROR : "ошибки строк"
    PRICE_IMPORT ||--o{ PRICE_OFFER : "строки прайса"
    SUPPLIER_ITEM ||--o{ PRICE_OFFER : "цена позиции"
    SUPPLIER_ITEM ||--o| ITEM_MATCH : "сопоставлена"
    SUPPLIER_ITEM ||--o| EXCLUSION : "исключена"
    PRODUCT ||--o{ ITEM_MATCH : "товар каталога"
    PRODUCT ||--o{ BARCODE : "штрихкоды"
    PRODUCT ||--o{ PRICE_OFFER : "по товару"
    PRODUCT ||--o{ PURCHASE_PRICE : "история цен"
    SUPPLIER ||--o{ PURCHASE_PRICE : "цена поставщика"
    PRICE_OFFER ||--o{ APPROVAL : "решения"
    PRICE_OFFER ||--o{ EXPORT_ITEM : "в пакете"
    EXPORT_BATCH ||--o{ EXPORT_ITEM : "строки"
    APP_USER ||--o{ APPROVAL : "принимает"

    SUPPLIER {
        bigint id PK
        text name
        varchar inn UK
        text code_1c UK
    }
    PRICE_SOURCE {
        bigint id PK
        bigint supplier_id FK
        enum channel
        jsonb column_map
    }
    PRICE_IMPORT {
        bigint id PK
        bigint source_id FK
        char file_sha256
        enum status
    }
    SUPPLIER_ITEM {
        bigint id PK
        bigint supplier_id FK
        text supplier_sku
        varchar barcode
        text name
    }
    PRODUCT {
        bigint id PK
        text code_1c UK
        text name
        text category
    }
    ITEM_MATCH {
        bigint id PK
        bigint supplier_item_id FK
        bigint product_id FK
        enum method
        numeric confidence
    }
    PRICE_OFFER {
        bigint id PK
        bigint import_id FK
        bigint supplier_item_id FK
        bigint product_id FK
        numeric price
        numeric current_price
        numeric deviation_pct
        enum status
    }
    APPROVAL {
        bigint id PK
        bigint offer_id FK
        bigint actor_id FK
        enum stage
        enum decision
        text comment
    }
    PURCHASE_PRICE {
        bigint id PK
        bigint product_id FK
        bigint supplier_id FK
        numeric price
        date valid_from
        date valid_to
    }
```

## Ключевые решения

| Решение | Почему |
|---|---|
| Позиция поставщика (`supplier_item`) отделена от предложения (`price_offer`) | сопоставление делается один раз на позицию, а не на каждую строку каждого прайса |
| Одно действующее сопоставление на позицию (`UNIQUE supplier_item_id`) | однозначно, какой товар получит цену |
| ШК может висеть на нескольких товарах (`PK barcode, product_id`) | так бывает в 1С; правило BR-01 не сопоставляет по неоднозначному ШК |
| `purchase_price` с `valid_from` / `valid_to` и частичным уникальным индексом | история цен; на пару товар + поставщик не больше одной действующей цены |
| `file_sha256` уникален в рамках источника | защита от повторной загрузки того же файла |
| Отказ в `approval` только с комментарием (`CHECK`) | у поставщика и аудита всегда есть причина |
| `export_batch.idempotency_key` | повторная отправка пакета не создаёт цены дважды |
| `dictionary_version` | клиент догружает только изменения справочников (NFR-01) |

## Словарь данных: PRICE_OFFER

| Поле | Тип | Обяз. | Описание | Правило |
|---|---|---|---|---|
| id | bigint | да | идентификатор | |
| import_id | bigint | да | загрузка, из которой пришла строка | |
| supplier_item_id | bigint | да | позиция поставщика | уникально в рамках загрузки |
| product_id | bigint | нет | товар каталога | обязателен во всех статусах, кроме `unmatched` и `excluded` |
| price | numeric(12,2) | да | новая цена за единицу с НДС, руб | больше 0; если в источнике без НДС, пересчитывается при импорте |
| vat_rate | numeric(4,2) | да | ставка НДС | 0, 10 или 20 |
| valid_from | date | да | дата начала действия | из файла или дата загрузки + 1 день |
| current_price | numeric(12,2) | нет | действующая закупочная цена этого поставщика | пусто для новой позиции |
| deviation_pct | numeric(7,2) | нет | отклонение, % | (price - current_price) / current_price × 100, до сотых |
| status | enum | да | статус | см. статусную модель |
| reason | text | нет | обоснование закупщика | обязательно при передаче руководителю |

## Статусная модель предложения

```mermaid
stateDiagram-v2
    [*] --> unmatched : строка прайса разобрана
    unmatched --> matched : сопоставлено (авто или вручную)
    unmatched --> excluded : позиция в исключённых
    matched --> approved : снижение или рост не выше порога автоприёма
    matched --> pending_review : рост выше порога или новая позиция
    pending_review --> approved : закупщик принял, рост не выше порога руководителя
    pending_review --> pending_approval : закупщик принял с обоснованием
    pending_review --> rejected : закупщик отклонил с комментарием
    pending_approval --> approved : руководитель согласовал
    pending_approval --> rejected : руководитель отклонил
    approved --> exported : 1С загрузила цену
    approved --> export_failed : 1С вернула ошибку
    export_failed --> approved : причина устранена, повторная выгрузка
    exported --> [*]
    rejected --> [*]
    excluded --> [*]
```

Переходы проверяются на стороне сервера: функция `decide_offer` в [`sql/02_business_rules.sql`](../sql/02_business_rules.sql) отклоняет решение не той роли или из не того статуса.
