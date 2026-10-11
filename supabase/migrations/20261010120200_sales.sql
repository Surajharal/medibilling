-- Sales, purchases, returns, stock changes, dashboard, and reports.
-- Financial writes set medibilling.allow_financial_write for the current transaction only.

CREATE OR REPLACE FUNCTION public.search_medicines(p_pharmacy uuid, p_query text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_query text := btrim(COALESCE(p_query, ''));
  v_today date;
  v_days integer;
  v_result jsonb;
BEGIN
  PERFORM public.require_role(p_pharmacy, ARRAY['owner', 'pharmacist', 'billing_operator']);
  IF char_length(v_query) < 1 THEN
    RETURN '[]'::jsonb;
  END IF;
  SELECT public.pharmacy_today(timezone), near_expiry_days INTO v_today, v_days
  FROM public.pharmacies WHERE id = p_pharmacy;

  SELECT COALESCE(jsonb_agg(item ORDER BY item ->> 'sort', item ->> 'name'), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'sort', CASE WHEN m.barcode = v_query OR lower(m.medicine_code) = lower(v_query) THEN '0' ELSE '1' END,
      'id', m.id,
      'medicine_code', m.medicine_code,
      'name', m.name,
      'generic_name', m.generic_name,
      'brand_name', m.brand_name,
      'strength', m.strength,
      'dosage_form', m.dosage_form,
      'pack_size', m.pack_size,
      'manufacturer', m.manufacturer,
      'hsn_code', m.hsn_code,
      'gst_rate', public.money_text(m.gst_rate),
      'tax_classification', m.tax_classification,
      'schedule_category', m.schedule_category,
      'prescription_required', m.prescription_required,
      'mrp', public.money_text(m.mrp),
      'default_selling_price', public.money_text(m.default_selling_price),
      'barcode', m.barcode,
      'batches', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'id', b.id,
          'batch_number', b.batch_number,
          'expiry_date', b.expiry_date,
          'qty_available', trim(to_char(b.qty_available, 'FM999999990.000')),
          'mrp', public.money_text(b.mrp),
          'selling_price', public.money_text(b.selling_price),
          'pack_to_unit', trim(to_char(b.pack_to_unit, 'FM999999990.000')),
          'shelf', b.shelf,
          'unit_cost', trim(to_char(b.unit_cost, 'FM999999990.0000')),
          'near_expiry', b.expiry_date <= (v_today + v_days)
        ) ORDER BY b.expiry_date, b.created_at)
        FROM public.inventory_batches b
        WHERE b.medicine_id = m.id
          AND b.pharmacy_id = p_pharmacy
          AND b.status = 'active'
          AND b.qty_available > 0
          AND b.expiry_date >= v_today
      ), '[]'::jsonb)
    ) AS item
    FROM public.medicines m
    WHERE m.pharmacy_id = p_pharmacy
      AND m.is_active = true
      AND (
        m.barcode = v_query
        OR lower(m.medicine_code) = lower(v_query)
        OR m.name ILIKE '%' || v_query || '%'
        OR m.generic_name ILIKE '%' || v_query || '%'
        OR m.brand_name ILIKE '%' || v_query || '%'
        OR m.manufacturer ILIKE '%' || v_query || '%'
      )
    ORDER BY CASE WHEN m.barcode = v_query OR lower(m.medicine_code) = lower(v_query) THEN 0 ELSE 1 END, m.name
    LIMIT 15
  ) found;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.prepare_sale(p_payload jsonb, p_post boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy public.pharmacies%ROWTYPE;
  v_customer public.customers%ROWTYPE;
  v_role text;
  v_today date;
  v_count integer;
  v_i integer;
  v_line jsonb;
  v_medicine public.medicines%ROWTYPE;
  v_batch public.inventory_batches%ROWTYPE;
  v_sold_unit text;
  v_qty numeric;
  v_packs numeric;
  v_price numeric;
  v_expected numeric;
  v_customer_id uuid;
  v_ack boolean;
  v_rx boolean := false;
  v_near boolean := false;
  v_warnings jsonb := '[]'::jsonb;
  v_calc_lines jsonb;
  v_totals jsonb;
  v_supply text;
  v_gstin text;
  v_max numeric;
  v_calc_line jsonb;
  v_effective numeric;
  v_paid numeric := 0;
  v_credit numeric := 0;
  v_cash numeric := 0;
  v_pay jsonb;
  v_method text;
  v_amt numeric;
  v_grand numeric;
  v_tender numeric;
  v_preview boolean;
  v_change numeric;
  v_need numeric;
  v_batch_id uuid;
  v_lines jsonb := '[]'::jsonb;
  v_payments jsonb := '[]'::jsonb;
  v_kind text;
  v_place char(2);
BEGIN
  IF p_payload ->> 'pharmacy_id' IS NULL THEN
    RAISE EXCEPTION 'pharmacy_required';
  END IF;
  SELECT * INTO v_pharmacy FROM public.pharmacies WHERE id = (p_payload ->> 'pharmacy_id')::uuid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pharmacy_not_found';
  END IF;
  v_role := public.require_role(v_pharmacy.id, ARRAY['owner', 'pharmacist', 'billing_operator']);
  v_today := public.pharmacy_today(v_pharmacy.timezone);
  v_ack := COALESCE((p_payload ->> 'acknowledge_near_expiry')::boolean, false);
  v_count := COALESCE(jsonb_array_length(p_payload -> 'lines'), 0);
  IF v_count = 0 OR v_count > 80 THEN
    RAISE EXCEPTION 'lines_required';
  END IF;

  DROP TABLE IF EXISTS pg_temp.mb_sale_lines;
  CREATE TEMP TABLE mb_sale_lines (
    line_no integer,
    medicine_id uuid,
    batch_id uuid,
    quantity numeric,
    sold_unit text,
    unit_price numeric,
    discount_amount numeric,
    discount_percent numeric,
    quantity_in_packs numeric,
    medicine_name text,
    generic_name text,
    strength text,
    dosage_form text,
    pack_size text,
    hsn_code text,
    batch_number text,
    expiry_date date,
    schedule_category text,
    mrp numeric,
    unit_cost numeric,
    gst_rate numeric,
    tax_classification text,
    pack_to_unit numeric
  ) ON COMMIT DROP;

  FOR v_i IN 0..v_count - 1 LOOP
    v_line := p_payload -> 'lines' -> v_i;
    SELECT * INTO v_medicine FROM public.medicines
    WHERE id = (v_line ->> 'medicine_id')::uuid AND pharmacy_id = v_pharmacy.id AND is_active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'medicine_not_found';
    END IF;
    SELECT * INTO v_batch FROM public.inventory_batches
    WHERE id = (v_line ->> 'batch_id')::uuid AND pharmacy_id = v_pharmacy.id AND medicine_id = v_medicine.id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'batch_not_found';
    END IF;
    v_sold_unit := COALESCE(v_line ->> 'sold_unit', 'pack');
    IF v_sold_unit NOT IN ('pack', 'unit') THEN
      RAISE EXCEPTION 'invalid_line';
    END IF;
    v_qty := round((v_line ->> 'quantity')::numeric, 3);
    v_price := round((v_line ->> 'unit_price')::numeric, 2);
    IF v_qty IS NULL OR v_qty <= 0 OR v_price IS NULL OR v_price < 0 THEN
      RAISE EXCEPTION 'invalid_line';
    END IF;
    IF v_sold_unit = 'pack' THEN
      v_packs := v_qty;
      v_expected := v_batch.selling_price;
      IF v_price > v_batch.mrp THEN
        RAISE EXCEPTION 'price_above_mrp';
      END IF;
    ELSE
      v_packs := round(v_qty / v_batch.pack_to_unit, 3);
      v_expected := round(v_batch.selling_price / v_batch.pack_to_unit, 2);
      IF (v_price * v_batch.pack_to_unit) > v_batch.mrp THEN
        RAISE EXCEPTION 'price_above_mrp';
      END IF;
    END IF;
    IF v_packs <= 0 THEN
      RAISE EXCEPTION 'invalid_line';
    END IF;
    IF v_role = 'billing_operator' AND v_price <> v_expected THEN
      RAISE EXCEPTION 'price_override_not_allowed';
    END IF;
    IF v_medicine.schedule_category IN ('H', 'H1', 'X', 'G') OR v_medicine.prescription_required THEN
      v_rx := true;
    END IF;
    IF v_batch.expiry_date <= (v_today + v_pharmacy.near_expiry_days) AND v_batch.expiry_date >= v_today THEN
      v_near := true;
    END IF;
    INSERT INTO mb_sale_lines VALUES (
      v_i + 1, v_medicine.id, v_batch.id, v_qty, v_sold_unit, v_price,
      round(COALESCE(NULLIF(v_line ->> 'discount_amount', '')::numeric, 0), 2),
      NULLIF(v_line ->> 'discount_percent', '')::numeric,
      v_packs, v_medicine.name, v_medicine.generic_name, v_medicine.strength, v_medicine.dosage_form,
      v_medicine.pack_size, v_medicine.hsn_code, v_batch.batch_number, v_batch.expiry_date,
      v_medicine.schedule_category, v_batch.mrp, v_batch.unit_cost, v_medicine.gst_rate,
      v_medicine.tax_classification, v_batch.pack_to_unit
    );
  END LOOP;

  IF v_rx AND v_role NOT IN ('owner', 'pharmacist') THEN
    RAISE EXCEPTION 'prescription_role_required';
  END IF;
  IF v_near AND p_post AND NOT v_ack THEN
    RAISE EXCEPTION 'near_expiry_acknowledgement_required';
  END IF;
  IF v_near AND NOT v_ack THEN
    v_warnings := v_warnings || jsonb_build_array('near_expiry');
  END IF;

  IF p_post THEN
    PERFORM 1 FROM public.inventory_batches
    WHERE id IN (SELECT batch_id FROM mb_sale_lines)
    ORDER BY id
    FOR UPDATE;
  END IF;

  FOR v_batch_id, v_need IN
    SELECT batch_id, SUM(quantity_in_packs) FROM mb_sale_lines GROUP BY batch_id
  LOOP
    SELECT * INTO v_batch FROM public.inventory_batches WHERE id = v_batch_id;
    IF v_batch.status <> 'active' OR v_batch.expiry_date < v_today THEN
      RAISE EXCEPTION 'batch_not_saleable';
    END IF;
    IF v_need > v_batch.qty_available THEN
      IF NOT (v_pharmacy.allow_negative_stock AND v_role = 'owner') THEN
        RAISE EXCEPTION 'insufficient_stock';
      END IF;
    END IF;
  END LOOP;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'quantity', quantity,
    'unit_price', unit_price,
    'discount_amount', discount_amount,
    'discount_percent', discount_percent,
    'gst_rate', gst_rate,
    'tax_classification', tax_classification
  ) ORDER BY line_no), '[]'::jsonb)
  INTO v_calc_lines
  FROM mb_sale_lines;

  v_customer_id := NULLIF(p_payload ->> 'customer_id', '')::uuid;
  v_gstin := '';
  IF v_customer_id IS NOT NULL THEN
    SELECT * INTO v_customer FROM public.customers
    WHERE id = v_customer_id AND pharmacy_id = v_pharmacy.id AND is_active = true;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'customer_not_found';
    END IF;
    v_gstin := COALESCE(v_customer.gstin, '');
  END IF;
  IF v_gstin <> '' AND left(v_gstin, 2) <> v_pharmacy.state_code THEN
    v_supply := 'inter';
    v_place := left(v_gstin, 2);
  ELSE
    v_supply := 'intra';
    v_place := v_pharmacy.state_code;
  END IF;

  v_totals := public.calculate_invoice_totals(jsonb_build_object(
    'pricing_mode', v_pharmacy.pricing_mode,
    'supply_type', v_supply,
    'bill_discount_amount', COALESCE(p_payload ->> 'bill_discount_amount', '0'),
    'round_to_rupee', v_pharmacy.round_invoice_to_rupee,
    'lines', v_calc_lines
  ));

  v_max := CASE v_role
    WHEN 'owner' THEN 100
    WHEN 'pharmacist' THEN v_pharmacy.max_pharmacist_discount_percent
    ELSE v_pharmacy.max_operator_discount_percent
  END;
  FOR v_i IN 0..v_count - 1 LOOP
    v_calc_line := v_totals -> 'lines' -> v_i;
    IF (v_calc_line ->> 'gross')::numeric > 0 THEN
      v_effective := ((v_calc_line ->> 'discount')::numeric + (v_calc_line ->> 'bill_discount_share')::numeric)
        / (v_calc_line ->> 'gross')::numeric * 100;
      IF v_effective > v_max + 0.001 THEN
        RAISE EXCEPTION 'discount_not_permitted';
      END IF;
    END IF;
    SELECT to_jsonb(s) INTO v_line FROM mb_sale_lines s WHERE s.line_no = v_i + 1;
    v_lines := v_lines || jsonb_build_array(v_line || jsonb_build_object('amounts', v_calc_line));
  END LOOP;

  v_grand := (v_totals ->> 'grand_total')::numeric;
  v_preview := (NOT p_post) AND COALESCE((p_payload ->> 'preview')::boolean, false);
  v_count := COALESCE(jsonb_array_length(p_payload -> 'payments'), 0);
  IF v_preview THEN
    v_count := 0;
  ELSIF v_count = 0 THEN
    RAISE EXCEPTION 'payment_required';
  END IF;
  FOR v_i IN 0..v_count - 1 LOOP
    v_pay := p_payload -> 'payments' -> v_i;
    v_method := v_pay ->> 'method';
    v_amt := round((v_pay ->> 'amount')::numeric, 2);
    IF v_method NOT IN ('cash', 'upi', 'card', 'bank_transfer', 'credit') OR v_amt IS NULL OR v_amt <= 0 THEN
      RAISE EXCEPTION 'payment_amount_invalid';
    END IF;
    IF v_method = 'credit' THEN
      v_credit := v_credit + v_amt;
    ELSE
      v_paid := v_paid + v_amt;
    END IF;
    IF v_method = 'cash' THEN
      v_cash := v_cash + v_amt;
    END IF;
    v_payments := v_payments || jsonb_build_array(jsonb_build_object(
      'method', v_method,
      'amount', public.money_text(v_amt),
      'reference', left(COALESCE(v_pay ->> 'reference', ''), 80)
    ));
  END LOOP;
  v_tender := round(COALESCE(NULLIF(p_payload ->> 'amount_tendered', '')::numeric, 0), 2);
  v_change := 0;
  IF NOT v_preview THEN
    IF round(v_paid + v_credit, 2) <> round(v_grand, 2) THEN
      RAISE EXCEPTION 'payment_mismatch';
    END IF;
    IF v_credit > 0 AND (NOT v_pharmacy.allow_credit_sales OR v_customer_id IS NULL) THEN
      RAISE EXCEPTION 'credit_not_allowed';
    END IF;
    IF v_credit > 0 AND (v_customer.credit_limit <= 0 OR v_customer.outstanding_balance + v_credit > v_customer.credit_limit) THEN
      RAISE EXCEPTION 'credit_limit_exceeded';
    END IF;
    IF v_cash > 0 AND v_tender < v_cash THEN
      RAISE EXCEPTION 'insufficient_tender';
    END IF;
    v_change := CASE WHEN v_cash > 0 THEN v_tender - v_cash ELSE 0 END;
  END IF;
  IF v_pharmacy.gst_registered AND v_pharmacy.gstin IS NOT NULL AND char_length(v_pharmacy.gstin) = 15 THEN
    v_kind := 'tax_invoice';
  ELSE
    v_kind := 'retail_bill';
  END IF;

  RETURN jsonb_build_object(
    'pharmacy_id', v_pharmacy.id,
    'warnings', v_warnings,
    'prescription_required', v_rx,
    'totals', v_totals,
    'lines', v_lines,
    'payments', v_payments,
    'customer_id', v_customer_id,
    'customer_name', COALESCE(NULLIF(v_customer.name, ''), NULLIF(p_payload ->> 'customer_name', ''), 'Walk-in'),
    'customer_phone', COALESCE(NULLIF(v_customer.phone, ''), ''),
    'customer_gstin', COALESCE(v_gstin, ''),
    'seller_name', v_pharmacy.name,
    'seller_address', concat_ws(', ', NULLIF(v_pharmacy.address_line1, ''), NULLIF(v_pharmacy.address_line2, ''), NULLIF(v_pharmacy.city, ''), NULLIF(v_pharmacy.state, ''), NULLIF(v_pharmacy.pincode, '')),
    'seller_phone', v_pharmacy.phone,
    'seller_gstin', COALESCE(v_pharmacy.gstin, ''),
    'seller_drug_licences', v_pharmacy.drug_licence_numbers,
    'seller_state', v_pharmacy.state,
    'seller_state_code', v_pharmacy.state_code,
    'place_of_supply_code', v_place,
    'pricing_mode', v_pharmacy.pricing_mode,
    'supply_type', v_supply,
    'invoice_kind', v_kind,
    'business_date', v_today,
    'amount_paid', public.money_text(v_paid),
    'balance_due', public.money_text(v_credit),
    'amount_tendered', public.money_text(v_tender),
    'change_due', public.money_text(v_change),
    'notes', left(COALESCE(p_payload ->> 'notes', ''), 500),
    'prescription_note', left(COALESCE(p_payload ->> 'prescription_note', ''), 200),
    'footer', v_pharmacy.invoice_footer,
    'financial_year', public.financial_year_label(v_today, v_pharmacy.financial_year_start_month)
  );
END;
$$;
