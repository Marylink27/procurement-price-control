-- Портал контроля закупочных цен: физическая модель данных (PostgreSQL 14+)
-- Описание сущностей и полей: docs/05-data-model.md

BEGIN;

CREATE TYPE user_role       AS ENUM ('buyer', 'head', 'admin', 'supplier');
CREATE TYPE source_channel  AS ENUM ('upload', 'email', 'api');
CREATE TYPE import_status   AS ENUM ('received', 'failed', 'processed');
CREATE TYPE match_method    AS ENUM ('barcode', 'article', 'name', 'manual');
CREATE TYPE match_status    AS ENUM ('auto', 'confirmed', 'rejected');
CREATE TYPE offer_status    AS ENUM (
    'unmatched',          -- позиция поставщика не сопоставлена с каталогом
    'matched',            -- сопоставлена, отклонение рассчитано
    'pending_review',     -- отклонение выше порога, ждёт закупщика
    'pending_approval',   -- закупщик принял, ждёт руководителя
    'approved',           -- принято (автоматически или вручную), готово к выгрузке
    'rejected',           -- отклонено, возвращено поставщику
    'exported',           -- цена загружена в 1С
    'export_failed',      -- 1С вернула ошибку
    'excluded'            -- позиция в списке исключённых
);
CREATE TYPE decision_type   AS ENUM ('approve', 'reject');

CREATE TABLE app_user (
    id          bigserial PRIMARY KEY,
    login       text        NOT NULL UNIQUE,
    full_name   text        NOT NULL,
    role        user_role   NOT NULL,
    is_active   boolean     NOT NULL DEFAULT true
);

CREATE TABLE supplier (
    id          bigserial PRIMARY KEY,
    name        text        NOT NULL,
    inn         varchar(12) NOT NULL UNIQUE CHECK (inn ~ '^\d{10}(\d{2})?$'),
    code_1c     text        UNIQUE,
    is_active   boolean     NOT NULL DEFAULT true
);

-- Источник прайса: канал и шаблон разбора файла (какая колонка что значит)
CREATE TABLE price_source (
    id           bigserial PRIMARY KEY,
    supplier_id  bigint         NOT NULL REFERENCES supplier(id),
    channel      source_channel NOT NULL,
    name         text           NOT NULL,
    column_map   jsonb          NOT NULL,   -- {"sku": "Артикул", "barcode": "ШК", "price": "Цена с НДС", ...}
    sheet_name   text,
    header_row   int            NOT NULL DEFAULT 1 CHECK (header_row >= 1),
    prices_include_vat boolean  NOT NULL DEFAULT true,
    is_active    boolean        NOT NULL DEFAULT true
);

-- Каталог номенклатуры (зеркало справочника 1С)
CREATE TABLE product (
    id          bigserial PRIMARY KEY,
    code_1c     text        NOT NULL UNIQUE,
    name        text        NOT NULL,
    category    text        NOT NULL,
    unit        text        NOT NULL DEFAULT 'шт',
    is_active   boolean     NOT NULL DEFAULT true,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- База штрихкодов: у товара может быть несколько ШК
CREATE TABLE barcode (
    barcode     varchar(14) NOT NULL CHECK (barcode ~ '^\d{8,14}$'),
    product_id  bigint      NOT NULL REFERENCES product(id),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (barcode, product_id)    -- в 1С один ШК иногда висит на двух карточках: это ловит правило BR-01
);
CREATE INDEX ix_barcode_product ON barcode(product_id);

-- Каталог поставщика: позиции так, как их называет поставщик
CREATE TABLE supplier_item (
    id            bigserial PRIMARY KEY,
    supplier_id   bigint      NOT NULL REFERENCES supplier(id),
    supplier_sku  text        NOT NULL,
    barcode       varchar(14),
    name          text        NOT NULL,
    pack_qty      int         NOT NULL DEFAULT 1 CHECK (pack_qty > 0),
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (supplier_id, supplier_sku)
);
CREATE INDEX ix_supplier_item_barcode ON supplier_item(barcode);

-- Сопоставление позиции поставщика с товаром каталога (одно действующее на позицию)
CREATE TABLE item_match (
    id                bigserial PRIMARY KEY,
    supplier_item_id  bigint       NOT NULL UNIQUE REFERENCES supplier_item(id),
    product_id        bigint       NOT NULL REFERENCES product(id),
    method            match_method NOT NULL,
    confidence        numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    status            match_status NOT NULL DEFAULT 'auto',
    matched_by        bigint       REFERENCES app_user(id),
    matched_at        timestamptz  NOT NULL DEFAULT now(),
    CHECK (method <> 'manual' OR matched_by IS NOT NULL)
);

-- Загрузка прайса
CREATE TABLE price_import (
    id           bigserial PRIMARY KEY,
    source_id    bigint        NOT NULL REFERENCES price_source(id),
    file_name    text          NOT NULL,
    file_sha256  char(64)      NOT NULL,
    status       import_status NOT NULL DEFAULT 'received',
    rows_total   int,
    rows_error   int,
    uploaded_by  bigint        REFERENCES app_user(id),
    created_at   timestamptz   NOT NULL DEFAULT now(),
    processed_at timestamptz,
    UNIQUE (source_id, file_sha256)          -- повторная загрузка того же файла отклоняется
);

CREATE TABLE import_error (
    id         bigserial PRIMARY KEY,
    import_id  bigint NOT NULL REFERENCES price_import(id) ON DELETE CASCADE,
    row_num    int    NOT NULL,
    field      text,
    code       text   NOT NULL,     -- PRICE_NOT_NUMBER, BARCODE_INVALID, REQUIRED_EMPTY, ...
    message    text   NOT NULL
);
CREATE INDEX ix_import_error_import ON import_error(import_id);

-- Ценовое предложение: строка прайса после разбора
CREATE TABLE price_offer (
    id                bigserial PRIMARY KEY,
    import_id         bigint        NOT NULL REFERENCES price_import(id),
    supplier_item_id  bigint        NOT NULL REFERENCES supplier_item(id),
    product_id        bigint        REFERENCES product(id),
    price             numeric(12,2) NOT NULL CHECK (price > 0),   -- за единицу, с НДС
    vat_rate          numeric(4,2)  NOT NULL DEFAULT 20 CHECK (vat_rate IN (0, 10, 20)),
    valid_from        date          NOT NULL,
    current_price     numeric(12,2),
    deviation_pct     numeric(7,2),  -- (price - current_price) / current_price * 100
    status            offer_status  NOT NULL DEFAULT 'unmatched',
    reason            text,          -- обоснование закупщика при росте цены
    created_at        timestamptz   NOT NULL DEFAULT now(),
    updated_at        timestamptz   NOT NULL DEFAULT now(),
    UNIQUE (import_id, supplier_item_id),
    CHECK (status = 'unmatched' OR status = 'excluded' OR product_id IS NOT NULL)
);
CREATE INDEX ix_offer_status ON price_offer(status);
CREATE INDEX ix_offer_product ON price_offer(product_id);

-- Решения по предложению: кто, когда, что решил (аудит согласований)
CREATE TABLE approval (
    id          bigserial PRIMARY KEY,
    offer_id    bigint        NOT NULL REFERENCES price_offer(id),
    actor_id    bigint        NOT NULL REFERENCES app_user(id),
    stage       user_role     NOT NULL CHECK (stage IN ('buyer', 'head')),
    decision    decision_type NOT NULL,
    comment     text,
    decided_at  timestamptz   NOT NULL DEFAULT now(),
    CHECK (decision = 'approve' OR comment IS NOT NULL)   -- отказ всегда с причиной
);

-- Действующая и историческая закупочная цена по товару и поставщику
CREATE TABLE purchase_price (
    id              bigserial PRIMARY KEY,
    product_id      bigint        NOT NULL REFERENCES product(id),
    supplier_id     bigint        NOT NULL REFERENCES supplier(id),
    price           numeric(12,2) NOT NULL CHECK (price > 0),
    valid_from      date          NOT NULL,
    valid_to        date,
    source_offer_id bigint        REFERENCES price_offer(id),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);
-- на пару товар + поставщик не больше одной действующей цены
CREATE UNIQUE INDEX ux_purchase_price_current ON purchase_price(product_id, supplier_id) WHERE valid_to IS NULL;

-- Пакеты выгрузки в 1С
CREATE TABLE export_batch (
    id              bigserial PRIMARY KEY,
    idempotency_key uuid        NOT NULL UNIQUE,
    status          text        NOT NULL CHECK (status IN ('created', 'sent', 'done', 'partial', 'failed')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    sent_at         timestamptz,
    finished_at     timestamptz
);

CREATE TABLE export_item (
    batch_id  bigint NOT NULL REFERENCES export_batch(id),
    offer_id  bigint NOT NULL REFERENCES price_offer(id),
    status    text   NOT NULL CHECK (status IN ('pending', 'done', 'failed')),
    error     text,
    PRIMARY KEY (batch_id, offer_id)
);

-- Исключённые позиции: не участвуют в сопоставлении и выгрузке
CREATE TABLE exclusion (
    id               bigserial PRIMARY KEY,
    supplier_item_id bigint      NOT NULL UNIQUE REFERENCES supplier_item(id),
    reason           text        NOT NULL,
    created_by       bigint      NOT NULL REFERENCES app_user(id),
    created_at       timestamptz NOT NULL DEFAULT now()
);

-- Настройки: пороги согласования по категориям ('*' = по умолчанию)
CREATE TABLE approval_threshold (
    category          text         PRIMARY KEY,
    auto_approve_pct  numeric(5,2) NOT NULL CHECK (auto_approve_pct >= 0),  -- рост до этого % принимается автоматически
    head_approve_pct  numeric(5,2) NOT NULL,                                -- выше этого % нужен руководитель
    CHECK (head_approve_pct >= auto_approve_pct)
);

-- Версии справочников для инкрементальной синхронизации клиента (NFR-01)
CREATE TABLE dictionary_version (
    dictionary  text        PRIMARY KEY CHECK (dictionary IN ('product', 'barcode', 'supplier_item')),
    version     bigint      NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMIT;
