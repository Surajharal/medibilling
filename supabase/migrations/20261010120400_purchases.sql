-- Purchases, returns, adjustments, receipts, dashboard, and reports.

CREATE OR REPLACE FUNCTION public.next_medicine_code(p_pharmacy uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_seq integer;
BEGIN
  PERFORM public.require_role(p_pharmacy, ARRAY['owner', 'pharmacist']);
  INSERT INTO public.invoice_counters AS counter (pharmacy_id, financial_year, doc_type, last_number)
  VALUES (p_pharmacy, '', 'medicine', 1)
  ON CONFLICT (pharmacy_id, financial_year, doc_type)
  DO UPDATE SET last_number = counter.last_number + 1, updated_at = now()
  RETURNING last_number INTO v_seq;
  RETURN 'MED-' || lpad(v_seq::text, 5, '0');
END;
$$;

CREATE OR REPLACE FUNCTION public.find_medicine_duplicates(
  p_pharmacy uuid,
  p_name text,
  p_strength text,
  p_dosage_form text,
  p_pack_size text,
  p_barcode text,
  p_exclude uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.require_role(p_pharmacy, ARRAY['owner', 'pharmacist', 'billing_operator']);
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', id, 'medicine_code', medicine_code, 'name', name, 'strength', strength,
      'dosage_form', dosage_form, 'pack_size', pack_size, 'barcode', barcode
    ))
    FROM public.medicines
    WHERE pharmacy_id = p_pharmacy
      AND is_active = true
      AND (p_exclude IS NULL OR id <> p_exclude)
      AND (
        (NULLIF(btrim(COALESCE(p_barcode, '')), '') IS NOT NULL AND barcode = btrim(p_barcode))
        OR (
          lower(name) = lower(btrim(p_name))
          AND lower(strength) = lower(btrim(COALESCE(p_strength, '')))
          AND lower(dosage_form) = lower(btrim(COALESCE(p_dosage_form, '')))
          AND lower(pack_size) = lower(btrim(COALESCE(p_pack_size, '')))
        )
      )
  ), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.post_purchase(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy public.pharmacies%ROWTYPE;
  v_supplier public.suppliers%ROWTYPE;
  v_role text;
  v_key text := btrim(COALESCE(p_payload ->> 'idempotency_key', ''));
  v_existing public.supplier_invoices%ROWTYPE;
  v_invoice_id uuid := gen_random_uuid();
  v_count integer;
  v_i integer;
  v_line jsonb;
  v_medicine public.medicines%ROWTYPE;
  v_batch public.inventory_batches%ROWTYPE;
  v_paid_qty numeric;
  v_free numeric;
  v_rate numeric;
  v_mrp numeric;
  v_sell numeric;
  v_gst numeric;
  v_supply text;
  v_calc jsonb;
  v_calc_lines jsonb := '[]'::jsonb;
  v_totals jsonb;
  v_amount_paid numeric;
  v_cost numeric;
  v_batch_cost numeric;
  v_total_qty numeric;
  v_new_qty numeric;
  v_batch_id uuid;
  v_taxable numeric;
  v_gst_amount numeric;
  v_line_total numeric;
  v_discount numeric;
  v_override boolean;
BEGIN
  IF char_length(v_key) < 8 THEN
    RAISE EXCEPTION 'idempotency_key_required';
  END IF;
  SELECT * INTO v_pharmacy FROM public.pharmacies WHERE id = (p_payload ->> 'pharmacy_id')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'pharmacy_not_found'; END IF;
  v_role := public.require_role(v_pharmacy.id, ARRAY['owner', 'pharmacist']);
  SELECT * INTO v_existing FROM public.supplier_invoices
  WHERE pharmacy_id = v_pharmacy.id AND idempotency_key = v_key;
  IF FOUND THEN
    RETURN jsonb_build_object('replayed', true, 'invoice_id', v_existing.id, 'grand_total', public.money_text(v_existing.grand_total));
  END IF;
  SELECT * INTO v_supplier FROM public.suppliers
  WHERE id = (p_payload ->> 'supplier_id')::uuid AND pharmacy_id = v_pharmacy.id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'supplier_not_found'; END IF;
  v_override := COALESCE((p_payload ->> 'override_duplicate')::boolean, false);
  IF v_override AND v_role <> 'owner' THEN RAISE EXCEPTION 'not_authorized'; END IF;
  IF NOT v_override AND EXISTS (
    SELECT 1 FROM public.supplier_invoices
    WHERE pharmacy_id = v_pharmacy.id AND supplier_id = v_supplier.id
      AND supplier_invoice_number = btrim(p_payload ->> 'supplier_invoice_number')
      AND duplicate_override = false
  ) THEN
    RAISE EXCEPTION 'duplicate_supplier_invoice';
  END IF;
  IF v_supplier.state_code IS NOT NULL AND v_supplier.state_code <> v_pharmacy.state_code THEN
    v_supply := 'inter';
  ELSE
    v_supply := 'intra';
  END IF;
  v_count := COALESCE(jsonb_array_length(p_payload -> 'lines'), 0);
  IF v_count = 0 THEN RAISE EXCEPTION 'lines_required'; END IF;

  DROP TABLE IF EXISTS pg_temp.mb_purchase_lines;
  CREATE TEMP TABLE mb_purchase_lines (
    line_no integer, medicine_id uuid, medicine_name text, hsn_code text, batch_number text,
    expiry_date date, mfg_date date, qty numeric, free_qty numeric, purchase_rate numeric,
    mrp numeric, selling_price numeric, gst_rate numeric, tax_classification text,
    pack_to_unit numeric, shelf text, manufacturer text, discount_percent numeric
  ) ON COMMIT DROP;

  FOR v_i IN 0..v_count - 1 LOOP
    v_line := p_payload -> 'lines' -> v_i;
    SELECT * INTO v_medicine FROM public.medicines
    WHERE id = (v_line ->> 'medicine_id')::uuid AND pharmacy_id = v_pharmacy.id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'medicine_not_found'; END IF;
    v_paid_qty := round((v_line ->> 'qty')::numeric, 3);
    v_free := round(COALESCE(NULLIF(v_line ->> 'free_qty', '')::numeric, 0), 3);
    v_rate := round((v_line ->> 'purchase_rate')::numeric, 4);
    v_mrp := round((v_line ->> 'mrp')::numeric, 2);
    v_sell := round((v_line ->> 'selling_price')::numeric, 2);
    v_gst := COALESCE(NULLIF(v_line ->> 'gst_rate', '')::numeric, v_medicine.gst_rate);
    IF v_paid_qty <= 0 OR v_free < 0 OR v_rate < 0 OR v_mrp < 0 OR v_sell < 0 OR v_sell > v_mrp
      OR COALESCE(NULLIF(v_line ->> 'pack_to_unit', '')::numeric, 1) <= 0 THEN
      RAISE EXCEPTION 'invalid_purchase_line';
    END IF;
    IF (v_line ->> 'expiry_date') IS NULL THEN RAISE EXCEPTION 'expiry_required'; END IF;
    IF NULLIF(v_line ->> 'mfg_date', '') IS NOT NULL AND (v_line ->> 'mfg_date')::date > (v_line ->> 'expiry_date')::date THEN
      RAISE EXCEPTION 'invalid_dates';
    END IF;
    INSERT INTO mb_purchase_lines VALUES (
      v_i + 1, v_medicine.id, v_medicine.name, v_medicine.hsn_code, btrim(v_line ->> 'batch_number'),
      (v_line ->> 'expiry_date')::date, NULLIF(v_line ->> 'mfg_date', '')::date, v_paid_qty, v_free, v_rate,
      v_mrp, v_sell, v_gst, v_medicine.tax_classification, COALESCE(NULLIF(v_line ->> 'pack_to_unit', '')::numeric, 1),
      left(COALESCE(v_line ->> 'shelf', ''), 40), left(COALESCE(v_line ->> 'manufacturer', v_medicine.manufacturer), 160),
      NULLIF(v_line ->> 'discount_percent', '')::numeric
    );
    v_calc_lines := v_calc_lines || jsonb_build_array(jsonb_build_object(
      'quantity', v_paid_qty, 'unit_price', v_rate, 'discount_amount', 0,
      'discount_percent', NULLIF(v_line ->> 'discount_percent', ''),
      'gst_rate', v_gst, 'tax_classification', v_medicine.tax_classification
    ));
  END LOOP;

  v_totals := public.calculate_invoice_totals(jsonb_build_object(
    'pricing_mode', 'exclusive', 'supply_type', v_supply, 'bill_discount_amount', 0,
    'round_to_rupee', false, 'lines', v_calc_lines
  ));
  v_amount_paid := round(COALESCE(NULLIF(p_payload ->> 'amount_paid', '')::numeric, 0), 2);
  IF v_amount_paid < 0 OR v_amount_paid > (v_totals ->> 'grand_total')::numeric THEN
    RAISE EXCEPTION 'payment_amount_invalid';
  END IF;

  PERFORM set_config('medibilling.allow_financial_write', 'on', true);
  INSERT INTO public.supplier_invoices (
    id, pharmacy_id, supplier_id, supplier_invoice_number, invoice_date, payment_status, supply_type,
    subtotal, discount_amount, taxable_value, cgst, sgst, igst, grand_total, amount_paid,
    duplicate_override, idempotency_key, notes, posted_by
  ) VALUES (
    v_invoice_id, v_pharmacy.id, v_supplier.id, btrim(p_payload ->> 'supplier_invoice_number'),
    (p_payload ->> 'invoice_date')::date,
    CASE WHEN v_amount_paid = 0 THEN 'unpaid' WHEN v_amount_paid = (v_totals ->> 'grand_total')::numeric THEN 'paid' ELSE 'partial' END,
    v_supply, (v_totals ->> 'gross')::numeric, (v_totals ->> 'discount_total')::numeric,
    (v_totals ->> 'taxable_value')::numeric, (v_totals ->> 'cgst')::numeric, (v_totals ->> 'sgst')::numeric,
    (v_totals ->> 'igst')::numeric, (v_totals ->> 'grand_total')::numeric, v_amount_paid,
    v_override, v_key, left(COALESCE(p_payload ->> 'notes', ''), 500), auth.uid()
  );

  FOR v_i IN 0..v_count - 1 LOOP
    SELECT to_jsonb(s) INTO v_line FROM mb_purchase_lines s WHERE s.line_no = v_i + 1;
    v_calc := v_totals -> 'lines' -> v_i;
    v_paid_qty := (v_line ->> 'qty')::numeric;
    v_free := (v_line ->> 'free_qty')::numeric;
    v_total_qty := v_paid_qty + v_free;
    v_taxable := (v_calc ->> 'taxable_value')::numeric;
    v_gst_amount := (v_calc ->> 'gst_amount')::numeric;
    v_line_total := (v_calc ->> 'line_total')::numeric;
    v_discount := (v_calc ->> 'discount')::numeric;
    v_cost := round((CASE WHEN v_pharmacy.gst_registered THEN v_taxable ELSE v_taxable + v_gst_amount END) / v_total_qty, 4);
    v_batch_cost := v_cost;
    SELECT * INTO v_batch FROM public.inventory_batches
    WHERE pharmacy_id = v_pharmacy.id AND medicine_id = (v_line ->> 'medicine_id')::uuid
      AND batch_number = v_line ->> 'batch_number' AND expiry_date = (v_line ->> 'expiry_date')::date
    FOR UPDATE;
    IF FOUND THEN
      IF v_batch.status IN ('recalled', 'blocked', 'quarantined', 'written_off') THEN
        RAISE EXCEPTION 'batch_not_receivable';
      END IF;
      v_new_qty := v_batch.qty_available + v_total_qty;
      IF v_batch.qty_available > 0 THEN
        v_batch_cost := round(((v_batch.qty_available * v_batch.unit_cost) + (v_total_qty * v_cost)) / v_new_qty, 4);
      END IF;
      UPDATE public.inventory_batches
      SET qty_available = v_new_qty,
          qty_received = qty_received + v_paid_qty,
          free_qty = free_qty + v_free,
          unit_cost = v_batch_cost,
          purchase_price = (v_line ->> 'purchase_rate')::numeric,
          mrp = (v_line ->> 'mrp')::numeric,
          selling_price = (v_line ->> 'selling_price')::numeric,
          status = CASE WHEN status = 'depleted' THEN 'active' ELSE status END,
          supplier_id = v_supplier.id,
          shelf = COALESCE(NULLIF(v_line ->> 'shelf', ''), shelf)
      WHERE id = v_batch.id;
      v_batch_id := v_batch.id;
    ELSE
      INSERT INTO public.inventory_batches (
        pharmacy_id, medicine_id, batch_number, manufacturer, supplier_id, mfg_date, expiry_date,
        purchase_price, unit_cost, mrp, selling_price, qty_received, free_qty, qty_available,
        pack_to_unit, gst_rate, purchase_discount, shelf, status
      ) VALUES (
        v_pharmacy.id, (v_line ->> 'medicine_id')::uuid, v_line ->> 'batch_number', COALESCE(v_line ->> 'manufacturer', ''),
        v_supplier.id, NULLIF(v_line ->> 'mfg_date', '')::date, (v_line ->> 'expiry_date')::date,
        (v_line ->> 'purchase_rate')::numeric, v_cost, (v_line ->> 'mrp')::numeric, (v_line ->> 'selling_price')::numeric,
        v_paid_qty, v_free, v_total_qty, (v_line ->> 'pack_to_unit')::numeric, (v_line ->> 'gst_rate')::numeric,
        v_discount, COALESCE(v_line ->> 'shelf', ''), 'active'
      ) RETURNING id INTO v_batch_id;
      v_new_qty := v_total_qty;
    END IF;
    INSERT INTO public.purchase_items (
      pharmacy_id, supplier_invoice_id, medicine_id, batch_id, medicine_name, batch_number, expiry_date,
      hsn_code, qty, free_qty, purchase_rate, mrp, selling_price, discount_amount, gst_rate, taxable_value,
      cgst, sgst, igst, line_total, unit_cost, pack_to_unit, shelf
    ) VALUES (
      v_pharmacy.id, v_invoice_id, (v_line ->> 'medicine_id')::uuid, v_batch_id, v_line ->> 'medicine_name',
      v_line ->> 'batch_number', (v_line ->> 'expiry_date')::date, COALESCE(v_line ->> 'hsn_code', ''),
      v_paid_qty, v_free, (v_line ->> 'purchase_rate')::numeric, (v_line ->> 'mrp')::numeric,
      (v_line ->> 'selling_price')::numeric, v_discount, (v_line ->> 'gst_rate')::numeric, v_taxable,
      (v_calc ->> 'cgst')::numeric, (v_calc ->> 'sgst')::numeric, (v_calc ->> 'igst')::numeric,
      v_line_total, v_cost, (v_line ->> 'pack_to_unit')::numeric, COALESCE(v_line ->> 'shelf', '')
    );
    INSERT INTO public.stock_movements (
      pharmacy_id, batch_id, medicine_id, movement_type, quantity_delta, quantity_after,
      reference_type, reference_id, created_by
    ) VALUES (
      v_pharmacy.id, v_batch_id, (v_line ->> 'medicine_id')::uuid, 'purchase', v_total_qty, v_new_qty,
      'supplier_invoice', v_invoice_id, auth.uid()
    );
  END LOOP;

  UPDATE public.suppliers
  SET current_balance = current_balance + (v_totals ->> 'grand_total')::numeric - v_amount_paid
  WHERE id = v_supplier.id;
  INSERT INTO public.supplier_ledger_entries (pharmacy_id, supplier_id, entry_type, debit, reference_type, reference_id, created_by)
  VALUES (v_pharmacy.id, v_supplier.id, 'purchase', (v_totals ->> 'grand_total')::numeric, 'supplier_invoice', v_invoice_id, auth.uid());
  IF v_amount_paid > 0 THEN
    INSERT INTO public.supplier_ledger_entries (pharmacy_id, supplier_id, entry_type, credit, reference_type, reference_id, created_by)
    VALUES (v_pharmacy.id, v_supplier.id, 'payment', v_amount_paid, 'supplier_invoice', v_invoice_id, auth.uid());
  END IF;
  PERFORM public.write_audit(v_pharmacy.id, 'purchase_posted', 'supplier_invoices', v_invoice_id,
    jsonb_build_object('supplier_invoice_number', p_payload ->> 'supplier_invoice_number', 'duplicate_override', v_override));
  RETURN jsonb_build_object('replayed', false, 'invoice_id', v_invoice_id, 'grand_total', v_totals ->> 'grand_total');
EXCEPTION
  WHEN unique_violation THEN
    SELECT * INTO v_existing FROM public.supplier_invoices WHERE pharmacy_id = v_pharmacy.id AND idempotency_key = v_key;
    IF FOUND THEN
      RETURN jsonb_build_object('replayed', true, 'invoice_id', v_existing.id, 'grand_total', public.money_text(v_existing.grand_total));
    END IF;
    RAISE;
END;
$$;
