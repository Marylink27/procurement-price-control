-- Сквозной сценарий: маршрутизация -> решения -> выгрузка в 1С.
-- Ожидаемый результат каждого шага указан в комментарии.

-- Шаг 1. Маршрутизация загрузок
SELECT * FROM route_offers(1);
-- approved 2 (Dr Pepper Classic +2,2%, Arizona Mango -4,2%),
-- pending_review 2 (Dr Pepper Cherry +10%, Arizona Green Tea +13,75%), unmatched 1 (Arizona Watermelon)
SELECT * FROM route_offers(2);
-- approved 1 (Takis Fuego +4,76%, порог Бакалеи 5%), excluded 1 (стойка), pending_review 1 (Takis Blue Heat, новая цена)

-- Шаг 2. Решения
SELECT decide_offer(2, 1, 'approve', NULL);                                    -- approved: +10% не выше порога руководителя
SELECT decide_offer(3, 1, 'approve', 'Поставщик поднял базовую цену на 12%, аналог дороже');  -- pending_approval
SELECT decide_offer(3, 2, 'approve', NULL);                                    -- approved
SELECT decide_offer(7, 1, 'reject', 'Цена выше рынка на 18%, запросить пересмотр');            -- rejected

-- Повторное решение по уже отклонённому предложению: ошибка «Переход недопустим»
DO $$ BEGIN
    PERFORM decide_offer(7, 2, 'approve', NULL);
EXCEPTION WHEN raise_exception THEN RAISE NOTICE 'Ожидаемая ошибка: %', SQLERRM;
END $$;

-- Шаг 3. Выгрузка в 1С: всё approved; одна позиция 1С вернула ошибку
SELECT apply_export_result(id, id <> 6, CASE WHEN id = 6 THEN 'Номенклатура заблокирована в 1С' END)
  FROM price_offer WHERE status = 'approved' ORDER BY id;

SELECT o.id, si.name, o.price, o.current_price, o.deviation_pct, o.status
  FROM price_offer o JOIN supplier_item si ON si.id = o.supplier_item_id
 ORDER BY o.id;
