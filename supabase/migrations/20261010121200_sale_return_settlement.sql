-- Settle a sale return automatically when the refund and balance credit are left at zero.
-- Safe to run again. Do not re-run the earlier migration files.
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
GRANT EXECUTE ON FUNCTION public.post_sale_return(jsonb) TO authenticated, service_role;
NOTIFY pgrst, 'reload schema';
