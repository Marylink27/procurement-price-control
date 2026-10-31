-- Аналитические запросы для экранов портала

-- 1. «Сводка»: воронка предложений по поставщикам
SELECT s.name                                                     AS поставщик,
       count(*)                                                   AS предложений,
       count(*) FILTER (WHERE o.status = 'unmatched')             AS без_пары,
       count(*) FILTER (WHERE o.status IN ('pending_review', 'pending_approval')) AS ждут_решения,
       count(*) FILTER (WHERE o.status = 'exported')              AS в_1с,
       round(100.0 * count(*) FILTER (WHERE o.product_id IS NOT NULL)
             / nullif(count(*) FILTER (WHERE o.status <> 'excluded'), 0), 1) AS сопоставлено_проц
  FROM price_offer o
  JOIN supplier_item si ON si.id = o.supplier_item_id
  JOIN supplier s       ON s.id = si.supplier_id
 GROUP BY s.name
 ORDER BY s.name;

-- 2. Очередь закупщика: что ждёт решения, самый большой рост сверху
SELECT o.id, p.code_1c, p.name, s.name AS поставщик, o.current_price, o.price, o.deviation_pct,
       now() - o.created_at AS ждёт
  FROM price_offer o
  JOIN product p        ON p.id = o.product_id
  JOIN supplier_item si ON si.id = o.supplier_item_id
  JOIN supplier s       ON s.id = si.supplier_id
 WHERE o.status IN ('pending_review', 'pending_approval')
 ORDER BY o.deviation_pct DESC NULLS FIRST;

-- 3. История закупочной цены товара: кто и когда согласовал
SELECT p.name, pp.price, pp.valid_from, pp.valid_to,
       string_agg(u.full_name || ' (' || a.stage || ': ' || a.decision || ')', ', ' ORDER BY a.decided_at) AS решения
  FROM purchase_price pp
  JOIN product p ON p.id = pp.product_id
  LEFT JOIN approval a ON a.offer_id = pp.source_offer_id
  LEFT JOIN app_user u ON u.id = a.actor_id
 WHERE p.code_1c = 'Т1-00031001'
 GROUP BY p.name, pp.price, pp.valid_from, pp.valid_to
 ORDER BY pp.valid_from;

-- 4. Подсказки для ручного сопоставления: похожие названия (без ШК), нужен pg_trgm
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SELECT si.name AS позиция_поставщика, p.code_1c, p.name AS товар_каталога,
       round(similarity(lower(si.name), lower(p.name))::numeric, 2) AS схожесть
  FROM supplier_item si
  JOIN price_offer o ON o.supplier_item_id = si.id AND o.status = 'unmatched'
 CROSS JOIN LATERAL (
       SELECT * FROM product p
        ORDER BY similarity(lower(si.name), lower(p.name)) DESC
        LIMIT 3) p
 ORDER BY si.name, схожесть DESC;

-- 5. Время цикла: от загрузки прайса до цены в 1С (метрика M-1 из docs/01-vision-scope.md)
SELECT i.file_name,
       min(a.decided_at) - i.created_at  AS до_первого_решения,
       max(o.updated_at) - i.created_at  AS до_выгрузки
  FROM price_import i
  JOIN price_offer o ON o.import_id = i.id AND o.status = 'exported'
  LEFT JOIN approval a ON a.offer_id = o.id
 GROUP BY i.id, i.file_name, i.created_at;
