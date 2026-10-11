-- Posting, returns, payments, dashboard, and reports.

CREATE OR REPLACE FUNCTION public.quote_sale(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.prepare_sale(p_payload, false);
END;
$$;

CREATE OR REPLACE FUNCTION public.post_sale(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy uuid := (p_payload ->> 'pharmacy_id')::uuid;
  v_key text := btrim(COALESCE(p_payload ->> 'idempotency_key', ''));
  v_existing public.sales_invoices%ROWTYPE;
  v_prepared jsonb;
  v_invoice_id uuid := gen_random_uuid();
  v_number text;
  v_line jsonb;
  v_amounts jsonb;
  v_i integer;
  v_packs numeric;
  v_after numeric;
  v_customer uuid;
  v_balance numeric;
  v_paid numeric;
  v_credit numeric;
  v_status text;
  v_outstanding numeric;
  v_limit numeric;
BEGIN
  IF char_length(v_key) < 8 THEN
    RAISE EXCEPTION 'idempotency_key_required';
  END IF;
  PERFORM public.require_role(v_pharmacy, ARRAY['owner', 'pharmacist', 'billing_operator']);
  SELECT * INTO v_existing FROM public.sales_invoices
  WHERE pharmacy_id = v_pharmacy AND idempotency_key = v_key;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'replayed', true,
      'invoice_id', v_existing.id,
      'invoice_number', v_existing.invoice_number,
      'grand_total', public.money_text(v_existing.grand_total),
      'amount_paid', public.money_text(v_existing.amount_paid),
      'balance_due', public.money_text(v_existing.balance_due),
      'change_due', public.money_text(v_existing.change_due)
    );
  END IF;
  PERFORM public.consume_rate_limit('sale:' || auth.uid()::text, 120, 60);
  v_prepared := public.prepare_sale(p_payload, true);
  v_customer := NULLIF(v_prepared ->> 'customer_id', '')::uuid;
  v_balance := (v_prepared ->> 'balance_due')::numeric;
  v_paid := (v_prepared ->> 'amount_paid')::numeric;
  IF v_balance > 0 AND v_customer IS NOT NULL THEN
    SELECT credit_limit, outstanding_balance INTO v_limit, v_outstanding
    FROM public.customers WHERE id = v_customer FOR UPDATE;
    IF v_limit <= 0 OR v_outstanding + v_balance > v_limit THEN
      RAISE EXCEPTION 'credit_limit_exceeded';
    END IF;
  END IF;

  PERFORM set_config('medibilling.allow_financial_write', 'on', true);
  v_number := public.allocate_number(v_pharmacy, 'sale', (v_prepared ->> 'business_date')::date);
  v_status := CASE
    WHEN v_balance = 0 THEN 'paid'
    WHEN v_paid = 0 THEN 'credit'
    ELSE 'partial'
  END;

  INSERT INTO public.sales_invoices (
    id, pharmacy_id, invoice_number, financial_year, business_date, invoice_kind,
    customer_id, customer_name_snapshot, customer_phone_snapshot, customer_gstin_snapshot,
    seller_name, seller_address, seller_phone, seller_gstin, seller_drug_licences,
    seller_state, seller_state_code, place_of_supply_code, pricing_mode, supply_type,
    subtotal, discount_amount, taxable_value, cgst, sgst, igst, round_off, grand_total,
    amount_paid, balance_due, amount_tendered, change_due, payment_status,
    prescription_note, notes, footer_snapshot, idempotency_key, created_by
  ) VALUES (
    v_invoice_id, v_pharmacy, v_number, v_prepared ->> 'financial_year', (v_prepared ->> 'business_date')::date,
    v_prepared ->> 'invoice_kind', v_customer, v_prepared ->> 'customer_name', v_prepared ->> 'customer_phone',
    v_prepared ->> 'customer_gstin', v_prepared ->> 'seller_name', v_prepared ->> 'seller_address',
    v_prepared ->> 'seller_phone', v_prepared ->> 'seller_gstin', v_prepared ->> 'seller_drug_licences',
    v_prepared ->> 'seller_state', v_prepared ->> 'seller_state_code', v_prepared ->> 'place_of_supply_code',
    v_prepared ->> 'pricing_mode', v_prepared ->> 'supply_type',
    (v_prepared -> 'totals' ->> 'gross')::numeric,
    (v_prepared -> 'totals' ->> 'discount_total')::numeric,
    (v_prepared -> 'totals' ->> 'taxable_value')::numeric,
    (v_prepared -> 'totals' ->> 'cgst')::numeric,
    (v_prepared -> 'totals' ->> 'sgst')::numeric,
    (v_prepared -> 'totals' ->> 'igst')::numeric,
    (v_prepared -> 'totals' ->> 'round_off')::numeric,
    (v_prepared -> 'totals' ->> 'grand_total')::numeric,
    v_paid, v_balance,
    (v_prepared ->> 'amount_tendered')::numeric,
    (v_prepared ->> 'change_due')::numeric,
    v_status, v_prepared ->> 'prescription_note', v_prepared ->> 'notes', v_prepared ->> 'footer',
    v_key, auth.uid()
  );

  FOR v_i IN 0..jsonb_array_length(v_prepared -> 'lines') - 1 LOOP
    v_line := v_prepared -> 'lines' -> v_i;
    v_amounts := v_line -> 'amounts';
    v_packs := (v_line ->> 'quantity_in_packs')::numeric;
    INSERT INTO public.sales_invoice_items (
      pharmacy_id, invoice_id, line_no, medicine_id, batch_id, medicine_name, generic_name,
      strength, dosage_form, pack_size, hsn_code, batch_number, expiry_date, schedule_category,
      sold_unit, quantity, pack_to_unit, quantity_in_packs, mrp, unit_price, unit_cost,
      discount_amount, bill_discount_share, gst_rate, tax_classification, taxable_value,
      cgst, sgst, igst, line_total
    ) VALUES (
      v_pharmacy, v_invoice_id, v_i + 1, (v_line ->> 'medicine_id')::uuid, (v_line ->> 'batch_id')::uuid,
      v_line ->> 'medicine_name', COALESCE(v_line ->> 'generic_name', ''), COALESCE(v_line ->> 'strength', ''),
      COALESCE(v_line ->> 'dosage_form', ''), COALESCE(v_line ->> 'pack_size', ''), COALESCE(v_line ->> 'hsn_code', ''),
      v_line ->> 'batch_number', (v_line ->> 'expiry_date')::date, COALESCE(v_line ->> 'schedule_category', 'OTC'),
      v_line ->> 'sold_unit', (v_line ->> 'quantity')::numeric, (v_line ->> 'pack_to_unit')::numeric, v_packs,
      (v_line ->> 'mrp')::numeric, (v_line ->> 'unit_price')::numeric, (v_line ->> 'unit_cost')::numeric,
      (v_amounts ->> 'discount')::numeric, (v_amounts ->> 'bill_discount_share')::numeric,
      (v_amounts ->> 'gst_rate')::numeric, v_line ->> 'tax_classification', (v_amounts ->> 'taxable_value')::numeric,
      (v_amounts ->> 'cgst')::numeric, (v_amounts ->> 'sgst')::numeric, (v_amounts ->> 'igst')::numeric,
      (v_amounts ->> 'line_total')::numeric
    );
    UPDATE public.inventory_batches
    SET qty_available = qty_available - v_packs,
        status = CASE
          WHEN qty_available - v_packs = 0 AND status = 'active' THEN 'depleted'
          ELSE status
        END
    WHERE id = (v_line ->> 'batch_id')::uuid
    RETURNING qty_available INTO v_after;
    INSERT INTO public.stock_movements (
      pharmacy_id, batch_id, medicine_id, movement_type, quantity_delta, quantity_after,
      reference_type, reference_id, created_by
    ) VALUES (
      v_pharmacy, (v_line ->> 'batch_id')::uuid, (v_line ->> 'medicine_id')::uuid, 'sale',
      -v_packs, v_after, 'sales_invoice', v_invoice_id, auth.uid()
    );
  END LOOP;

  FOR v_i IN 0..jsonb_array_length(v_prepared -> 'payments') - 1 LOOP
    v_line := v_prepared -> 'payments' -> v_i;
    INSERT INTO public.sales_payments (pharmacy_id, invoice_id, method, amount, reference)
    VALUES (v_pharmacy, v_invoice_id, v_line ->> 'method', (v_line ->> 'amount')::numeric, COALESCE(v_line ->> 'reference', ''));
  END LOOP;

  IF v_balance > 0 AND v_customer IS NOT NULL THEN
    UPDATE public.customers
    SET outstanding_balance = outstanding_balance + v_balance
    WHERE id = v_customer;
    INSERT INTO public.customer_ledger_entries (pharmacy_id, customer_id, entry_type, debit, reference_type, reference_id, created_by)
    VALUES (v_pharmacy, v_customer, 'sale', v_balance, 'sales_invoice', v_invoice_id, auth.uid());
  END IF;

  PERFORM public.write_audit(v_pharmacy, 'sale_posted', 'sales_invoices', v_invoice_id,
    jsonb_build_object('invoice_number', v_number, 'grand_total', v_prepared -> 'totals' ->> 'grand_total'));

  RETURN jsonb_build_object(
    'replayed', false,
    'invoice_id', v_invoice_id,
    'invoice_number', v_number,
    'grand_total', v_prepared -> 'totals' ->> 'grand_total',
    'amount_paid', v_prepared ->> 'amount_paid',
    'balance_due', v_prepared ->> 'balance_due',
    'change_due', v_prepared ->> 'change_due',
    'invoice_kind', v_prepared ->> 'invoice_kind'
  );
EXCEPTION
  WHEN unique_violation THEN
    SELECT * INTO v_existing FROM public.sales_invoices
    WHERE pharmacy_id = v_pharmacy AND idempotency_key = v_key;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'replayed', true,
        'invoice_id', v_existing.id,
        'invoice_number', v_existing.invoice_number,
        'grand_total', public.money_text(v_existing.grand_total),
        'amount_paid', public.money_text(v_existing.amount_paid),
        'balance_due', public.money_text(v_existing.balance_due),
        'change_due', public.money_text(v_existing.change_due)
      );
    END IF;
    RAISE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.quote_sale(jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.post_sale(jsonb) TO authenticated, service_role;
NOTIFY pgrst, 'reload schema';
