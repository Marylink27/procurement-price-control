-- Бизнес-правила маршрутизации предложений (BR-03, BR-04 в docs/09-business-rules.md)

BEGIN;

-- Порог для категории товара: своя строка или строка по умолчанию '*'
CREATE OR REPLACE FUNCTION threshold_for(p_category text)
RETURNS approval_threshold LANGUAGE sql STABLE AS $$
    SELECT * FROM approval_threshold
    WHERE category IN (p_category, '*')
    ORDER BY (category = '*')          -- своя категория приоритетнее
    LIMIT 1;
$$;

-- Рассчитать отклонение и определить маршрут для всех предложений загрузки
CREATE OR REPLACE FUNCTION route_offers(p_import_id bigint)
RETURNS TABLE (status offer_status, offers bigint) LANGUAGE plpgsql AS $$
BEGIN
    -- 1. Подставить товар по действующему сопоставлению (кроме исключённых)
    UPDATE price_offer o
       SET product_id = m.product_id, updated_at = now()
      FROM item_match m
     WHERE o.import_id = p_import_id
       AND m.supplier_item_id = o.supplier_item_id
       AND m.status <> 'rejected'
       AND o.status = 'unmatched';

    UPDATE price_offer o
       SET status = 'excluded', updated_at = now()
     WHERE o.import_id = p_import_id
       AND EXISTS (SELECT 1 FROM exclusion e WHERE e.supplier_item_id = o.supplier_item_id);

    -- 2. Текущая цена этого поставщика и отклонение
    UPDATE price_offer o
       SET current_price = (SELECT pp.price
                              FROM purchase_price pp
                              JOIN supplier_item si ON si.supplier_id = pp.supplier_id
                             WHERE si.id = o.supplier_item_id
                               AND pp.product_id = o.product_id
                               AND pp.valid_to IS NULL),
           status = 'matched',
           updated_at = now()
     WHERE o.import_id = p_import_id
       AND o.product_id IS NOT NULL
       AND o.status = 'unmatched';

    UPDATE price_offer o
       SET deviation_pct = round((o.price - o.current_price) / o.current_price * 100, 2)
     WHERE o.import_id = p_import_id
       AND o.status = 'matched'
       AND o.current_price IS NOT NULL;

    -- 3. Маршрут по порогу категории
    --    новая позиция (нет текущей цены) -> закупщику;
    --    снижение или рост в пределах auto_approve_pct -> автоматически;
    --    иначе -> закупщику (руководитель подключается после него, если рост > head_approve_pct)
    UPDATE price_offer o
       SET status = CASE
                      WHEN o.current_price IS NULL                         THEN 'pending_review'
                      WHEN o.deviation_pct <= (threshold_for(p.category)).auto_approve_pct THEN 'approved'
                      ELSE 'pending_review'
                    END::offer_status,
           updated_at = now()
      FROM product p
     WHERE o.import_id = p_import_id
       AND p.id = o.product_id
       AND o.status = 'matched';

    UPDATE price_import SET status = 'processed', processed_at = now() WHERE id = p_import_id;

    RETURN QUERY
        SELECT o.status, count(*) FROM price_offer o
         WHERE o.import_id = p_import_id GROUP BY o.status ORDER BY o.status;
END;
$$;

-- Решение закупщика или руководителя с проверкой допустимого перехода статуса (docs/05-data-model.md, статусная модель)
CREATE OR REPLACE FUNCTION decide_offer(p_offer_id bigint, p_actor_id bigint, p_decision decision_type, p_comment text)
RETURNS offer_status LANGUAGE plpgsql AS $$
DECLARE
    v_offer  price_offer;
    v_role   user_role;
    v_head   numeric;
    v_new    offer_status;
BEGIN
    SELECT * INTO v_offer FROM price_offer WHERE id = p_offer_id FOR UPDATE;
    SELECT role INTO v_role FROM app_user WHERE id = p_actor_id AND is_active;
    SELECT (threshold_for(p.category)).head_approve_pct INTO v_head FROM product p WHERE p.id = v_offer.product_id;

    IF v_offer.status = 'pending_review' AND v_role = 'buyer' THEN
        IF p_decision = 'reject' THEN
            v_new := 'rejected';
        ELSIF v_offer.current_price IS NULL OR v_offer.deviation_pct > v_head THEN
            IF coalesce(p_comment, '') = '' THEN
                RAISE EXCEPTION 'Для передачи руководителю нужно обоснование роста цены';
            END IF;
            v_new := 'pending_approval';
        ELSE
            v_new := 'approved';
        END IF;
    ELSIF v_offer.status = 'pending_approval' AND v_role = 'head' THEN
        v_new := CASE p_decision WHEN 'approve' THEN 'approved' ELSE 'rejected' END;
    ELSE
        RAISE EXCEPTION 'Переход недопустим: статус %, роль %', v_offer.status, v_role;
    END IF;

    INSERT INTO approval(offer_id, actor_id, stage, decision, comment)
    VALUES (p_offer_id, p_actor_id, CASE v_role WHEN 'head' THEN 'head' ELSE 'buyer' END::user_role, p_decision, p_comment);

    UPDATE price_offer
       SET status = v_new,
           reason = CASE WHEN v_role = 'buyer' THEN coalesce(p_comment, reason) ELSE reason END,
           updated_at = now()
     WHERE id = p_offer_id;
    RETURN v_new;
END;
$$;

-- Применить результат выгрузки в 1С: закрыть старую цену, открыть новую
CREATE OR REPLACE FUNCTION apply_export_result(p_offer_id bigint, p_ok boolean, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_offer price_offer;
    v_supplier bigint;
BEGIN
    SELECT * INTO v_offer FROM price_offer WHERE id = p_offer_id AND status = 'approved' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Предложение % не в статусе approved', p_offer_id;
    END IF;
    IF NOT p_ok THEN
        UPDATE price_offer SET status = 'export_failed', updated_at = now() WHERE id = p_offer_id;
        RETURN;
    END IF;
    SELECT supplier_id INTO v_supplier FROM supplier_item WHERE id = v_offer.supplier_item_id;

    UPDATE purchase_price
       SET valid_to = v_offer.valid_from
     WHERE product_id = v_offer.product_id AND supplier_id = v_supplier AND valid_to IS NULL;

    INSERT INTO purchase_price(product_id, supplier_id, price, valid_from, source_offer_id)
    VALUES (v_offer.product_id, v_supplier, v_offer.price, v_offer.valid_from, v_offer.id);

    UPDATE price_offer SET status = 'exported', updated_at = now() WHERE id = p_offer_id;
END;
$$;

COMMIT;
