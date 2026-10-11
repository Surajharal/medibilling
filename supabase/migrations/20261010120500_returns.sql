-- Returns, adjustments, and receipts.
-- Credit notes are inserted once with final totals. Posted rows are not rewritten.

CREATE OR REPLACE FUNCTION public.post_sale_return(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy uuid := (p_payload ->> 'pharmacy_id')::uuid;
  v_key text := btrim(COALESCE(p_payload ->> 'idempotency_key', ''));
  v_existing public.sales_returns%ROWTYPE;
  v_invoice public.sales_invoices%ROWTYPE;
  v_item public.sales_invoice_items%ROWTYPE;
  v_batch public.inventory_batches%ROWTYPE;
  v_today date;
  v_return_id uuid := gen_random_uuid();
  v_number text;
  v_i integer;
  v_line jsonb;
  v_qty numeric;
  v_already_packs numeric;
  v_packs numeric;
  v_closes boolean;
  v_prev_taxable numeric;
  v_prev_cgst numeric;
  v_prev_sgst numeric;
  v_prev_igst numeric;
  v_taxable numeric;
  v_cgst numeric;
  v_sgst numeric;
  v_igst numeric;
  v_total numeric;
  v_sum_taxable numeric := 0;
  v_sum_cgst numeric := 0;
  v_sum_sgst numeric := 0;
  v_sum_igst numeric := 0;
  v_sum_total numeric := 0;
  v_disp text;
  v_refund numeric := 0;
  v_balance_credit numeric;
  v_method text;
  v_amt numeric;
  v_after numeric;
  v_work record;
  v_customer_outstanding numeric;
BEGIN
  IF char_length(v_key) < 8 THEN RAISE EXCEPTION 'idempotency_key_required'; END IF;
  PERFORM public.require_role(v_pharmacy, ARRAY['owner', 'pharmacist']);
  SELECT * INTO v_existing FROM public.sales_returns WHERE pharmacy_id = v_pharmacy AND idempotency_key = v_key;
  IF FOUND THEN
    RETURN jsonb_build_object('replayed', true, 'return_id', v_existing.id, 'credit_note_number', v_existing.credit_note_number);
  END IF;
  SELECT * INTO v_invoice FROM public.sales_invoices
  WHERE id = (p_payload ->> 'invoice_id')::uuid AND pharmacy_id = v_pharmacy FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'invoice_not_found'; END IF;
  IF char_length(COALESCE(p_payload ->> 'reason', '')) < 3 THEN RAISE EXCEPTION 'reason_required'; END IF;
  SELECT public.pharmacy_today(timezone) INTO v_today FROM public.pharmacies WHERE id = v_pharmacy;

  DROP TABLE IF EXISTS pg_temp.mb_return_lines;
  CREATE TEMP TABLE mb_return_lines (
    invoice_item_id uuid, batch_id uuid, medicine_id uuid, quantity numeric, packs numeric,
    disposition text, taxable numeric, cgst numeric, sgst numeric, igst numeric, line_total numeric
  ) ON COMMIT DROP;

  FOR v_i IN 0..COALESCE(jsonb_array_length(p_payload -> 'lines'), 0) - 1 LOOP
    v_line := p_payload -> 'lines' -> v_i;
    SELECT * INTO v_item FROM public.sales_invoice_items
    WHERE id = (v_line ->> 'invoice_item_id')::uuid AND invoice_id = v_invoice.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'invoice_line_not_found'; END IF;
    v_qty := round((v_line ->> 'quantity')::numeric, 3);
    IF v_qty IS NULL OR v_qty <= 0 OR v_qty > (v_item.quantity - v_item.returned_qty) THEN
      RAISE EXCEPTION 'return_qty_exceeded';
    END IF;
    v_closes := v_qty = (v_item.quantity - v_item.returned_qty);
    SELECT COALESCE(SUM(quantity_in_packs), 0), COALESCE(SUM(taxable_value), 0),
           COALESCE(SUM(cgst), 0), COALESCE(SUM(sgst), 0), COALESCE(SUM(igst), 0)
      INTO v_already_packs, v_prev_taxable, v_prev_cgst, v_prev_sgst, v_prev_igst
    FROM public.sales_return_items WHERE invoice_item_id = v_item.id;
    IF v_closes THEN
      v_packs := v_item.quantity_in_packs - v_already_packs;
      v_taxable := round(v_item.taxable_value - v_prev_taxable, 2);
      v_cgst := round(v_item.cgst - v_prev_cgst, 2);
      v_sgst := round(v_item.sgst - v_prev_sgst, 2);
      v_igst := round(v_item.igst - v_prev_igst, 2);
    ELSE
      v_packs := round(v_item.quantity_in_packs * v_qty / v_item.quantity, 3);
      v_taxable := round(v_item.taxable_value * v_qty / v_item.quantity, 2);
      v_cgst := round(v_item.cgst * v_qty / v_item.quantity, 2);
      v_sgst := round(v_item.sgst * v_qty / v_item.quantity, 2);
      v_igst := round(v_item.igst * v_qty / v_item.quantity, 2);
    END IF;
    IF v_packs <= 0 THEN RAISE EXCEPTION 'return_qty_invalid'; END IF;
    v_total := v_taxable + v_cgst + v_sgst + v_igst;
    SELECT * INTO v_batch FROM public.inventory_batches WHERE id = v_item.batch_id FOR UPDATE;
    v_disp := COALESCE(v_line ->> 'disposition', 'resale');
    IF v_batch.expiry_date < v_today OR v_batch.status IN ('recalled', 'blocked', 'quarantined', 'written_off') THEN
      v_disp := 'quarantine';
    ELSIF v_disp NOT IN ('resale', 'quarantine') THEN
      RAISE EXCEPTION 'invalid_disposition';
    END IF;
    INSERT INTO mb_return_lines VALUES (
      v_item.id, v_batch.id, v_item.medicine_id, v_qty, v_packs, v_disp, v_taxable, v_cgst, v_sgst, v_igst, v_total
    );
    v_sum_taxable := v_sum_taxable + v_taxable;
    v_sum_cgst := v_sum_cgst + v_cgst;
    v_sum_sgst := v_sum_sgst + v_sgst;
    v_sum_igst := v_sum_igst + v_igst;
    v_sum_total := v_sum_total + v_total;
  END LOOP;
  IF v_sum_total = 0 THEN RAISE EXCEPTION 'lines_required'; END IF;

  FOR v_i IN 0..COALESCE(jsonb_array_length(p_payload -> 'refunds'), 0) - 1 LOOP
    v_line := p_payload -> 'refunds' -> v_i;
    v_method := v_line ->> 'method';
    v_amt := round((v_line ->> 'amount')::numeric, 2);
    IF v_method NOT IN ('cash', 'upi', 'card', 'bank_transfer') OR v_amt IS NULL OR v_amt <= 0 THEN
      RAISE EXCEPTION 'payment_amount_invalid';
    END IF;
    v_refund := v_refund + v_amt;
  END LOOP;
  v_balance_credit := round(COALESCE(NULLIF(p_payload ->> 'balance_credit', '')::numeric, 0), 2);
  IF v_refund = 0 AND v_balance_credit = 0 THEN
    IF v_invoice.balance_due > 0 AND v_invoice.customer_id IS NOT NULL THEN
      v_balance_credit := LEAST(round(v_sum_total, 2), v_invoice.balance_due);
      v_refund := round(v_sum_total - v_balance_credit, 2);
    ELSE
      v_refund := round(v_sum_total, 2);
    END IF;
  END IF;
  IF v_balance_credit < 0 OR round(v_refund + v_balance_credit, 2) <> round(v_sum_total, 2) THEN
    RAISE EXCEPTION 'payment_mismatch';
  END IF;
  IF v_refund > v_invoice.amount_paid OR v_balance_credit > v_invoice.balance_due THEN
    RAISE EXCEPTION 'refund_exceeds_paid';
  END IF;
  IF v_balance_credit > 0 AND v_invoice.customer_id IS NULL THEN RAISE EXCEPTION 'credit_not_allowed'; END IF;

  PERFORM set_config('medibilling.allow_financial_write', 'on', true);
  v_number := public.allocate_number(v_pharmacy, 'sale_return', v_today);
  INSERT INTO public.sales_returns (
    id, pharmacy_id, credit_note_number, original_invoice_id, customer_id, business_date, reason,
    taxable_value, cgst, sgst, igst, grand_total, refund_amount, balance_credit, idempotency_key, created_by
  ) VALUES (
    v_return_id, v_pharmacy, v_number, v_invoice.id, v_invoice.customer_id, v_today, btrim(p_payload ->> 'reason'),
    v_sum_taxable, v_sum_cgst, v_sum_sgst, v_sum_igst, v_sum_total, v_refund, v_balance_credit, v_key, auth.uid()
  );

  FOR v_work IN SELECT * FROM mb_return_lines LOOP
    IF v_work.disposition = 'resale' THEN
      UPDATE public.inventory_batches
      SET qty_available = qty_available + v_work.packs,
          status = CASE WHEN status = 'depleted' THEN 'active' ELSE status END
      WHERE id = v_work.batch_id RETURNING qty_available INTO v_after;
      INSERT INTO public.stock_movements (
        pharmacy_id, batch_id, medicine_id, movement_type, quantity_delta, quantity_after,
        reference_type, reference_id, reason, created_by
      ) VALUES (
        v_pharmacy, v_work.batch_id, v_work.medicine_id, 'sale_return', v_work.packs, v_after,
        'sales_return', v_return_id, btrim(p_payload ->> 'reason'), auth.uid()
      );
    ELSE
      UPDATE public.inventory_batches SET qty_quarantine = qty_quarantine + v_work.packs
      WHERE id = v_work.batch_id RETURNING qty_available INTO v_after;
      INSERT INTO public.stock_movements (
        pharmacy_id, batch_id, medicine_id, movement_type, quantity_delta, quarantine_delta, quantity_after,
        reference_type, reference_id, reason, created_by
      ) VALUES (
        v_pharmacy, v_work.batch_id, v_work.medicine_id, 'sale_return_quarantine', 0, v_work.packs, v_after,
        'sales_return', v_return_id, btrim(p_payload ->> 'reason'), auth.uid()
      );
    END IF;
    UPDATE public.sales_invoice_items SET returned_qty = returned_qty + v_work.quantity WHERE id = v_work.invoice_item_id;
    INSERT INTO public.sales_return_items (
      pharmacy_id, return_id, invoice_item_id, batch_id, quantity, quantity_in_packs, disposition,
      taxable_value, gst_amount, cgst, sgst, igst, line_total
    ) VALUES (
      v_pharmacy, v_return_id, v_work.invoice_item_id, v_work.batch_id, v_work.quantity, v_work.packs,
      v_work.disposition, v_work.taxable, v_work.cgst + v_work.sgst + v_work.igst, v_work.cgst, v_work.sgst,
      v_work.igst, v_work.line_total
    );
  END LOOP;

  FOR v_i IN 0..COALESCE(jsonb_array_length(p_payload -> 'refunds'), 0) - 1 LOOP
    v_line := p_payload -> 'refunds' -> v_i;
    INSERT INTO public.sales_refunds (pharmacy_id, return_id, method, amount, reference)
    VALUES (
      v_pharmacy, v_return_id, v_line ->> 'method', round((v_line ->> 'amount')::numeric, 2),
      left(COALESCE(v_line ->> 'reference', ''), 80)
    );
  END LOOP;

  UPDATE public.sales_invoices
  SET amount_paid = amount_paid - v_refund,
      balance_due = balance_due - v_balance_credit,
      payment_status = CASE
        WHEN balance_due - v_balance_credit = 0 THEN 'paid'
        WHEN amount_paid - v_refund = 0 THEN 'credit'
        ELSE 'partial'
      END,
      return_status = CASE
        WHEN NOT EXISTS (
          SELECT 1 FROM public.sales_invoice_items
          WHERE invoice_id = v_invoice.id AND returned_qty < quantity
        ) THEN 'full' ELSE 'partial'
      END
  WHERE id = v_invoice.id;

  IF v_balance_credit > 0 THEN
    SELECT outstanding_balance INTO v_customer_outstanding
    FROM public.customers WHERE id = v_invoice.customer_id FOR UPDATE;
    IF v_customer_outstanding < v_balance_credit THEN RAISE EXCEPTION 'balance_credit_exceeds_due'; END IF;
    UPDATE public.customers SET outstanding_balance = outstanding_balance - v_balance_credit WHERE id = v_invoice.customer_id;
    INSERT INTO public.customer_ledger_entries (
      pharmacy_id, customer_id, entry_type, credit, reference_type, reference_id, created_by
    ) VALUES (
      v_pharmacy, v_invoice.customer_id, 'return', v_balance_credit, 'sales_return', v_return_id, auth.uid()
    );
  END IF;

  PERFORM public.write_audit(v_pharmacy, 'sale_return_posted', 'sales_returns', v_return_id,
    jsonb_build_object('credit_note_number', v_number, 'grand_total', public.money_text(v_sum_total)));
  RETURN jsonb_build_object(
    'replayed', false, 'return_id', v_return_id, 'credit_note_number', v_number,
    'grand_total', public.money_text(v_sum_total)
  );
EXCEPTION
  WHEN unique_violation THEN
    SELECT * INTO v_existing FROM public.sales_returns WHERE pharmacy_id = v_pharmacy AND idempotency_key = v_key;
    IF FOUND THEN
      RETURN jsonb_build_object('replayed', true, 'return_id', v_existing.id, 'credit_note_number', v_existing.credit_note_number);
    END IF;
    RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.post_purchase_return(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy uuid := (p_payload ->> 'pharmacy_id')::uuid;
  v_key text := btrim(COALESCE(p_payload ->> 'idempotency_key', ''));
  v_existing public.supplier_returns%ROWTYPE;
  v_invoice public.supplier_invoices%ROWTYPE;
  v_item public.purchase_items%ROWTYPE;
  v_batch public.inventory_batches%ROWTYPE;
  v_today date;
  v_return_id uuid := gen_random_uuid();
  v_number text;
  v_i integer;
  v_line jsonb;
  v_qty numeric;
  v_received numeric;
  v_closes boolean;
  v_prev_taxable numeric;
  v_prev_total numeric;
  v_taxable numeric;
  v_total numeric;
  v_gst numeric;
  v_sum_taxable numeric := 0;
  v_sum_cgst numeric := 0;
  v_sum_sgst numeric := 0;
  v_sum_igst numeric := 0;
  v_sum_total numeric := 0;
  v_cgst numeric;
  v_sgst numeric;
  v_igst numeric;
  v_prev_cgst numeric;
  v_prev_sgst numeric;
  v_prev_igst numeric;
  v_after numeric;
  v_work record;
BEGIN
  IF char_length(v_key) < 8 THEN RAISE EXCEPTION 'idempotency_key_required'; END IF;
  PERFORM public.require_role(v_pharmacy, ARRAY['owner', 'pharmacist']);
  SELECT * INTO v_existing FROM public.supplier_returns WHERE pharmacy_id = v_pharmacy AND idempotency_key = v_key;
  IF FOUND THEN
    RETURN jsonb_build_object('replayed', true, 'return_id', v_existing.id, 'debit_note_number', v_existing.debit_note_number);
  END IF;
  SELECT * INTO v_invoice FROM public.supplier_invoices
  WHERE id = (p_payload ->> 'supplier_invoice_id')::uuid AND pharmacy_id = v_pharmacy FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'invoice_not_found'; END IF;
  IF char_length(COALESCE(p_payload ->> 'reason', '')) < 3 THEN RAISE EXCEPTION 'reason_required'; END IF;
  SELECT public.pharmacy_today(timezone) INTO v_today FROM public.pharmacies WHERE id = v_pharmacy;
  DROP TABLE IF EXISTS pg_temp.mb_preturn_lines;
  CREATE TEMP TABLE mb_preturn_lines (
    purchase_item_id uuid, batch_id uuid, medicine_id uuid, quantity numeric,
    taxable numeric, cgst numeric, sgst numeric, igst numeric, line_total numeric
  ) ON COMMIT DROP;

  FOR v_i IN 0..COALESCE(jsonb_array_length(p_payload -> 'lines'), 0) - 1 LOOP
    v_line := p_payload -> 'lines' -> v_i;
    SELECT * INTO v_item FROM public.purchase_items
    WHERE id = (v_line ->> 'purchase_item_id')::uuid AND supplier_invoice_id = v_invoice.id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'invoice_line_not_found'; END IF;
    v_qty := round((v_line ->> 'quantity')::numeric, 3);
    v_received := v_item.qty + v_item.free_qty;
    IF v_qty IS NULL OR v_qty <= 0 OR v_qty > (v_received - v_item.returned_qty) THEN
      RAISE EXCEPTION 'return_qty_exceeded';
    END IF;
    SELECT * INTO v_batch FROM public.inventory_batches WHERE id = v_item.batch_id FOR UPDATE;
    IF v_qty > v_batch.qty_available THEN RAISE EXCEPTION 'insufficient_stock'; END IF;
    v_closes := v_qty = (v_received - v_item.returned_qty);
    SELECT COALESCE(SUM(taxable_value), 0), COALESCE(SUM(line_total), 0)
      INTO v_prev_taxable, v_prev_total
    FROM public.supplier_return_items WHERE purchase_item_id = v_item.id;
    SELECT COALESCE(SUM(cgst), 0), COALESCE(SUM(sgst), 0), COALESCE(SUM(igst), 0)
      INTO v_prev_cgst, v_prev_sgst, v_prev_igst
    FROM public.supplier_return_items sri
    JOIN public.purchase_items pi ON pi.id = sri.purchase_item_id
    WHERE sri.purchase_item_id = v_item.id;
    IF v_closes THEN
      v_taxable := round(v_item.taxable_value - v_prev_taxable, 2);
      v_cgst := round(v_item.cgst - v_prev_cgst, 2);
      v_sgst := round(v_item.sgst - v_prev_sgst, 2);
      v_igst := round(v_item.igst - v_prev_igst, 2);
    ELSE
      v_taxable := round(v_item.taxable_value * v_qty / v_received, 2);
      v_cgst := round(v_item.cgst * v_qty / v_received, 2);
      v_sgst := round(v_item.sgst * v_qty / v_received, 2);
      v_igst := round(v_item.igst * v_qty / v_received, 2);
    END IF;
    v_total := v_taxable + v_cgst + v_sgst + v_igst;
    INSERT INTO mb_preturn_lines VALUES (v_item.id, v_batch.id, v_item.medicine_id, v_qty, v_taxable, v_cgst, v_sgst, v_igst, v_total);
    v_sum_taxable := v_sum_taxable + v_taxable;
    v_sum_cgst := v_sum_cgst + v_cgst;
    v_sum_sgst := v_sum_sgst + v_sgst;
    v_sum_igst := v_sum_igst + v_igst;
    v_sum_total := v_sum_total + v_total;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM mb_preturn_lines) THEN RAISE EXCEPTION 'lines_required'; END IF;

  PERFORM set_config('medibilling.allow_financial_write', 'on', true);
  v_number := public.allocate_number(v_pharmacy, 'purchase_return', v_today);
  INSERT INTO public.supplier_returns (
    id, pharmacy_id, debit_note_number, supplier_id, supplier_invoice_id, business_date, reason,
    taxable_value, cgst, sgst, igst, grand_total, idempotency_key, created_by
  ) VALUES (
    v_return_id, v_pharmacy, v_number, v_invoice.supplier_id, v_invoice.id, v_today, btrim(p_payload ->> 'reason'),
    v_sum_taxable, v_sum_cgst, v_sum_sgst, v_sum_igst, v_sum_total, v_key, auth.uid()
  );
  FOR v_work IN SELECT * FROM mb_preturn_lines LOOP
    UPDATE public.inventory_batches
    SET qty_available = qty_available - v_work.quantity,
        status = CASE WHEN qty_available - v_work.quantity = 0 AND status = 'active' THEN 'depleted' ELSE status END
    WHERE id = v_work.batch_id RETURNING qty_available INTO v_after;
    UPDATE public.purchase_items SET returned_qty = returned_qty + v_work.quantity WHERE id = v_work.purchase_item_id;
    INSERT INTO public.supplier_return_items (
      pharmacy_id, return_id, purchase_item_id, batch_id, quantity, taxable_value, cgst, sgst, igst, gst_amount, line_total
    ) VALUES (
      v_pharmacy, v_return_id, v_work.purchase_item_id, v_work.batch_id, v_work.quantity,
      v_work.taxable, v_work.cgst, v_work.sgst, v_work.igst, v_work.cgst + v_work.sgst + v_work.igst, v_work.line_total
    );
    INSERT INTO public.stock_movements (
      pharmacy_id, batch_id, medicine_id, movement_type, quantity_delta, quantity_after,
      reference_type, reference_id, reason, created_by
    ) VALUES (
      v_pharmacy, v_work.batch_id, v_work.medicine_id, 'purchase_return', -v_work.quantity, v_after,
      'supplier_return', v_return_id, btrim(p_payload ->> 'reason'), auth.uid()
    );
  END LOOP;
  UPDATE public.suppliers SET current_balance = current_balance - v_sum_total WHERE id = v_invoice.supplier_id;
  INSERT INTO public.supplier_ledger_entries (
    pharmacy_id, supplier_id, entry_type, credit, reference_type, reference_id, notes, created_by
  ) VALUES (
    v_pharmacy, v_invoice.supplier_id, 'return', v_sum_total, 'supplier_return', v_return_id,
    btrim(p_payload ->> 'reason'), auth.uid()
  );
  PERFORM public.write_audit(v_pharmacy, 'purchase_return_posted', 'supplier_returns', v_return_id,
    jsonb_build_object('debit_note_number', v_number, 'grand_total', public.money_text(v_sum_total)));
  RETURN jsonb_build_object('replayed', false, 'return_id', v_return_id, 'debit_note_number', v_number, 'grand_total', public.money_text(v_sum_total));
EXCEPTION
  WHEN unique_violation THEN
    SELECT * INTO v_existing FROM public.supplier_returns WHERE pharmacy_id = v_pharmacy AND idempotency_key = v_key;
    IF FOUND THEN
      RETURN jsonb_build_object('replayed', true, 'return_id', v_existing.id, 'debit_note_number', v_existing.debit_note_number);
    END IF;
    RAISE;
END;
$$;

CREATE OR REPLACE FUNCTION public.post_stock_adjustment(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy public.pharmacies%ROWTYPE;
  v_role text;
  v_batch public.inventory_batches%ROWTYPE;
  v_type text := p_payload ->> 'adjustment_type';
  v_delta numeric := round((p_payload ->> 'quantity_delta')::numeric, 3);
  v_after numeric;
  v_quarantine numeric := 0;
  v_today date;
  v_id uuid := gen_random_uuid();
  v_number text;
  v_movement text;
BEGIN
  SELECT * INTO v_pharmacy FROM public.pharmacies WHERE id = (p_payload ->> 'pharmacy_id')::uuid;
  v_role := public.require_role(v_pharmacy.id, ARRAY['owner', 'pharmacist']);
  IF v_type NOT IN ('correction', 'write_off', 'damage', 'quarantine', 'recall') THEN
    RAISE EXCEPTION 'invalid_adjustment';
  END IF;
  IF char_length(COALESCE(p_payload ->> 'reason', '')) < 5 THEN RAISE EXCEPTION 'reason_required'; END IF;
  IF v_delta = 0 THEN RAISE EXCEPTION 'invalid_line'; END IF;
  IF v_type <> 'correction' AND v_delta > 0 THEN RAISE EXCEPTION 'invalid_adjustment'; END IF;
  SELECT * INTO v_batch FROM public.inventory_batches
  WHERE id = (p_payload ->> 'batch_id')::uuid AND pharmacy_id = v_pharmacy.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'batch_not_found'; END IF;
  v_after := v_batch.qty_available + v_delta;
  IF v_after < 0 AND NOT (v_pharmacy.allow_negative_stock AND v_role = 'owner' AND v_type = 'correction') THEN
    RAISE EXCEPTION 'negative_stock_not_allowed';
  END IF;
  v_today := public.pharmacy_today(v_pharmacy.timezone);
  PERFORM set_config('medibilling.allow_financial_write', 'on', true);
  v_number := public.allocate_number(v_pharmacy.id, 'adjustment', v_today);
  IF v_type IN ('quarantine', 'recall') THEN
    v_quarantine := abs(v_delta);
    v_movement := 'adjustment';
    UPDATE public.inventory_batches
    SET qty_available = v_after,
        qty_quarantine = qty_quarantine + v_quarantine,
        status = CASE
          WHEN v_after = 0 AND v_type = 'recall' THEN 'recalled'
          WHEN v_after = 0 AND v_type = 'quarantine' THEN 'quarantined'
          ELSE status
        END
    WHERE id = v_batch.id;
  ELSIF v_type IN ('write_off', 'damage') THEN
    v_movement := 'write_off';
    UPDATE public.inventory_batches
    SET qty_available = v_after,
        status = CASE WHEN v_after = 0 THEN 'written_off' ELSE status END
    WHERE id = v_batch.id;
  ELSE
    v_movement := 'adjustment';
    UPDATE public.inventory_batches
    SET qty_available = v_after,
        status = CASE
          WHEN v_after > 0 AND status = 'depleted' THEN 'active'
          WHEN v_after = 0 AND status = 'active' THEN 'depleted'
          ELSE status
        END
    WHERE id = v_batch.id;
  END IF;
  INSERT INTO public.stock_adjustments (
    id, pharmacy_id, adjustment_number, batch_id, medicine_id, adjustment_type,
    quantity_before, quantity_delta, quantity_after, reason, business_date, created_by
  ) VALUES (
    v_id, v_pharmacy.id, v_number, v_batch.id, v_batch.medicine_id, v_type,
    v_batch.qty_available, v_delta, v_after, btrim(p_payload ->> 'reason'), v_today, auth.uid()
  );
  INSERT INTO public.stock_movements (
    pharmacy_id, batch_id, medicine_id, movement_type, quantity_delta, quarantine_delta, quantity_after,
    reference_type, reference_id, reason, created_by
  ) VALUES (
    v_pharmacy.id, v_batch.id, v_batch.medicine_id, v_movement, v_delta, v_quarantine, v_after,
    'stock_adjustment', v_id, btrim(p_payload ->> 'reason'), auth.uid()
  );
  PERFORM public.write_audit(v_pharmacy.id, 'stock_adjusted', 'stock_adjustments', v_id,
    jsonb_build_object('type', v_type, 'delta', v_delta, 'reason', btrim(p_payload ->> 'reason')));
  RETURN jsonb_build_object('adjustment_id', v_id, 'adjustment_number', v_number, 'quantity_after', v_after);
END;
$$;

CREATE OR REPLACE FUNCTION public.record_supplier_payment(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy uuid := (p_payload ->> 'pharmacy_id')::uuid;
  v_supplier uuid := (p_payload ->> 'supplier_id')::uuid;
  v_amount numeric := round((p_payload ->> 'amount')::numeric, 2);
  v_left numeric;
  v_apply numeric;
  v_invoice public.supplier_invoices%ROWTYPE;
  v_id uuid := gen_random_uuid();
BEGIN
  PERFORM public.require_role(v_pharmacy, ARRAY['owner', 'pharmacist']);
  IF v_amount IS NULL OR v_amount <= 0 THEN RAISE EXCEPTION 'payment_amount_invalid'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = v_supplier AND pharmacy_id = v_pharmacy) THEN
    RAISE EXCEPTION 'supplier_not_found';
  END IF;
  PERFORM set_config('medibilling.allow_financial_write', 'on', true);
  UPDATE public.suppliers SET current_balance = current_balance - v_amount WHERE id = v_supplier;
  INSERT INTO public.supplier_ledger_entries (
    id, pharmacy_id, supplier_id, entry_type, credit, reference_type, notes, created_by
  ) VALUES (
    v_id, v_pharmacy, v_supplier, 'payment', v_amount, 'supplier_payment',
    left(COALESCE(p_payload ->> 'notes', ''), 200), auth.uid()
  );
  v_left := v_amount;
  FOR v_invoice IN
    SELECT * FROM public.supplier_invoices
    WHERE supplier_id = v_supplier AND amount_paid < grand_total
    ORDER BY invoice_date, created_at
    FOR UPDATE
  LOOP
    EXIT WHEN v_left <= 0;
    v_apply := LEAST(v_invoice.grand_total - v_invoice.amount_paid, v_left);
    UPDATE public.supplier_invoices
    SET amount_paid = amount_paid + v_apply,
        payment_status = CASE WHEN amount_paid + v_apply >= grand_total THEN 'paid' ELSE 'partial' END
    WHERE id = v_invoice.id;
    v_left := v_left - v_apply;
  END LOOP;
  PERFORM public.write_audit(v_pharmacy, 'supplier_payment', 'suppliers', v_supplier, jsonb_build_object('amount', public.money_text(v_amount)));
  RETURN jsonb_build_object('ok', true, 'amount', public.money_text(v_amount));
END;
$$;

CREATE OR REPLACE FUNCTION public.record_customer_receipt(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pharmacy uuid := (p_payload ->> 'pharmacy_id')::uuid;
  v_customer uuid := (p_payload ->> 'customer_id')::uuid;
  v_amount numeric := round((p_payload ->> 'amount')::numeric, 2);
  v_outstanding numeric;
  v_left numeric;
  v_apply numeric;
  v_invoice public.sales_invoices%ROWTYPE;
  v_id uuid := gen_random_uuid();
BEGIN
  PERFORM public.require_role(v_pharmacy, ARRAY['owner', 'pharmacist', 'billing_operator']);
  IF v_amount IS NULL OR v_amount <= 0 THEN RAISE EXCEPTION 'payment_amount_invalid'; END IF;
  SELECT outstanding_balance INTO v_outstanding FROM public.customers
  WHERE id = v_customer AND pharmacy_id = v_pharmacy FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'customer_not_found'; END IF;
  IF v_amount > v_outstanding THEN RAISE EXCEPTION 'receipt_exceeds_outstanding'; END IF;
  PERFORM set_config('medibilling.allow_financial_write', 'on', true);
  UPDATE public.customers SET outstanding_balance = outstanding_balance - v_amount WHERE id = v_customer;
  INSERT INTO public.customer_ledger_entries (
    id, pharmacy_id, customer_id, entry_type, credit, reference_type, notes, created_by
  ) VALUES (
    v_id, v_pharmacy, v_customer, 'receipt', v_amount, 'customer_receipt',
    left(COALESCE(p_payload ->> 'notes', ''), 200), auth.uid()
  );
  v_left := v_amount;
  FOR v_invoice IN
    SELECT * FROM public.sales_invoices
    WHERE customer_id = v_customer AND balance_due > 0
    ORDER BY business_date, created_at
    FOR UPDATE
  LOOP
    EXIT WHEN v_left <= 0;
    v_apply := LEAST(v_invoice.balance_due, v_left);
    UPDATE public.sales_invoices
    SET balance_due = balance_due - v_apply,
        amount_paid = amount_paid + v_apply,
        payment_status = CASE WHEN balance_due - v_apply = 0 THEN 'paid' ELSE 'partial' END
    WHERE id = v_invoice.id;
    INSERT INTO public.sales_payments (pharmacy_id, invoice_id, method, amount, reference)
    VALUES (v_pharmacy, v_invoice.id, COALESCE(p_payload ->> 'method', 'cash'), v_apply, 'Receipt');
    v_left := v_left - v_apply;
  END LOOP;
  PERFORM public.write_audit(v_pharmacy, 'customer_receipt', 'customers', v_customer, jsonb_build_object('amount', public.money_text(v_amount)));
  RETURN jsonb_build_object('ok', true, 'amount', public.money_text(v_amount));
END;
$$;
