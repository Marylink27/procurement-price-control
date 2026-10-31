-- Демо-данные: сеть магазинов, два поставщика напитков, одна загрузка прайса.
-- Все названия и ИНН вымышленные.

BEGIN;

INSERT INTO app_user (login, full_name, role) VALUES
    ('buyer.ivanova', 'Иванова А.', 'buyer'),
    ('head.petrov',   'Петров С.',  'head'),
    ('admin',         'Администратор', 'admin');

INSERT INTO supplier (name, inn, code_1c) VALUES
    ('ООО «Альфа Импорт»', '7700000001', 'П-0001'),
    ('ООО «Бета Дистрибуция»', '7800000002', 'П-0002');

INSERT INTO price_source (supplier_id, channel, name, column_map, header_row) VALUES
    (1, 'email',  'Альфа: прайс по почте',
     '{"sku": "Код", "barcode": "Штрихкод", "name": "Наименование", "price": "Цена, руб с НДС", "pack_qty": "В коробе"}', 3),
    (2, 'upload', 'Бета: загрузка в портале',
     '{"sku": "Артикул", "barcode": "EAN", "name": "Товар", "price": "Цена"}', 1);

INSERT INTO product (code_1c, name, category) VALUES
    ('Т1-00022622', 'Dr Pepper Classic 0,355 л ж/б',   'Напитки'),
    ('Т1-00049460', 'Dr Pepper Cherry 0,355 л ж/б',    'Напитки'),
    ('Т1-00031001', 'Arizona Green Tea 0,68 л ж/б',    'Напитки'),
    ('Т1-00031002', 'Arizona Mucho Mango 0,68 л ж/б',  'Напитки'),
    ('Т1-00040015', 'Чипсы Takis Fuego 92,3 г',        'Бакалея'),
    ('Т1-00040016', 'Чипсы Takis Blue Heat 92,3 г',    'Бакалея');

INSERT INTO barcode (barcode, product_id) VALUES
    ('0078000082166', 1), ('0078000082401', 2), ('0613008715281', 3),
    ('0613008724320', 4), ('0757528028411', 5), ('0757528044213', 6);

INSERT INTO approval_threshold (category, auto_approve_pct, head_approve_pct) VALUES
    ('*',       3, 10),
    ('Бакалея', 5, 15);

-- Действующие закупочные цены
INSERT INTO purchase_price (product_id, supplier_id, price, valid_from) VALUES
    (1, 1,  90.00, '2026-06-01'),
    (2, 1,  95.00, '2026-06-01'),
    (3, 1, 160.00, '2026-06-01'),
    (4, 1, 165.00, '2026-06-01'),
    (5, 2, 210.00, '2026-07-01');

-- Каталог поставщиков
INSERT INTO supplier_item (supplier_id, supplier_sku, barcode, name, pack_qty) VALUES
    (1, 'DP-CL-355',  '0078000082166', 'DR PEPPER CLASSIC CAN 355ML', 12),
    (1, 'DP-CH-355',  '0078000082401', 'DR PEPPER CHERRY CAN 355ML',  12),
    (1, 'AZ-GT-680',  NULL,            'ARIZONA GREEN TEA 680ML',     24),
    (1, 'AZ-MM-680',  '0613008724320', 'ARIZONA MUCHO MANGO 680ML',   24),
    (1, 'AZ-WM-680',  NULL,            'ARIZONA WATERMELON 680ML',    24),
    (2, 'TK-FU-92',   '0757528028411', 'Takis Fuego 92.3g',           20),
    (2, 'TK-BH-92',   '0757528044213', 'Takis Blue Heat 92.3g',       20),
    (2, 'PROMO-STAND',NULL,              'Стойка рекламная Takis',      1);

-- Сопоставления: по ШК автоматически, Arizona Green Tea без ШК закупщик сопоставил вручную
INSERT INTO item_match (supplier_item_id, product_id, method, confidence, status, matched_by) VALUES
    (1, 1, 'barcode', 1.000, 'auto', NULL),
    (2, 2, 'barcode', 1.000, 'auto', NULL),
    (3, 3, 'manual',  1.000, 'confirmed', 1),
    (4, 4, 'barcode', 1.000, 'auto', NULL),
    (6, 5, 'barcode', 1.000, 'auto', NULL),
    (7, 6, 'barcode', 1.000, 'auto', NULL);

INSERT INTO exclusion (supplier_item_id, reason, created_by) VALUES
    (8, 'Рекламное оборудование, не товар для перепродажи', 1);

-- Загрузки прайсов
INSERT INTO price_import (source_id, file_name, file_sha256, status, rows_total, rows_error, uploaded_by) VALUES
    (1, 'Альфа_прайс_октябрь.xlsx', repeat('a', 64), 'received', 6, 1, NULL),
    (2, 'takis_oct.csv',            repeat('b', 64), 'received', 3, 0, NULL);

INSERT INTO import_error (import_id, row_num, field, code, message) VALUES
    (1, 9, 'price', 'PRICE_NOT_NUMBER', 'В колонке «Цена, руб с НДС» значение «по запросу»');

INSERT INTO price_offer (import_id, supplier_item_id, price, valid_from) VALUES
    (1, 1,  92.00, '2026-11-01'),   -- +2,2%: автоматически
    (1, 2, 104.50, '2026-11-01'),   -- +10%: закупщик, без руководителя (порог 10%)
    (1, 3, 182.00, '2026-11-01'),   -- +13,8%: закупщик, затем руководитель
    (1, 4, 158.00, '2026-11-01'),   -- снижение: автоматически
    (1, 5, 170.00, '2026-11-01'),   -- нет сопоставления: остаётся unmatched
    (2, 6, 220.00, '2026-11-01'),   -- +4,8% в Бакалее: автоматически (порог 5%)
    (2, 7, 225.00, '2026-11-01'),   -- новая позиция без текущей цены: закупщик
    (2, 8,   1.00, '2026-11-01');   -- исключённая позиция

INSERT INTO dictionary_version (dictionary, version) VALUES
    ('product', 1), ('barcode', 1), ('supplier_item', 1);

COMMIT;
