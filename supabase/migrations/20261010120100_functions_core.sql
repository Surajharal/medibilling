-- Transaction helpers, tax calculation, and immutability guards.
-- calculate_invoice_totals mirrors src/lib/gst/engine.ts. Keep the two in sync.

CREATE OR REPLACE FUNCTION public.require_role(p_pharmacy uuid, p_roles text[])
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT role INTO v_role
  FROM public.pharmacy_memberships
  WHERE pharmacy_id = p_pharmacy AND user_id = auth.uid() AND is_active = true;
  IF v_role IS NULL OR NOT (v_role = ANY (p_roles)) THEN
    RAISE EXCEPTION 'not_authorized' USING ERRCODE = '42501';
  END IF;
  RETURN v_role;
END;
$$;

CREATE OR REPLACE FUNCTION public.auth_has_role(p_pharmacy uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.pharmacy_memberships
    WHERE pharmacy_id = p_pharmacy
      AND user_id = auth.uid()
      AND is_active = true
      AND role = ANY (p_roles)
  );
$$;

CREATE OR REPLACE FUNCTION public.auth_pharmacy_ids()
RETURNS SETOF uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT pharmacy_id FROM public.pharmacy_memberships
  WHERE user_id = auth.uid() AND is_active = true;
$$;

CREATE OR REPLACE FUNCTION public.consume_rate_limit(p_key text, p_limit integer, p_window_seconds integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count integer;
BEGIN
  INSERT INTO public.rate_limit_buckets AS bucket (bucket_key, window_start, hit_count)
  VALUES (p_key, now(), 1)
  ON CONFLICT (bucket_key) DO UPDATE
    SET
      hit_count = CASE
        WHEN bucket.window_start < now() - make_interval(secs => p_window_seconds) THEN 1
        ELSE bucket.hit_count + 1
      END,
      window_start = CASE
        WHEN bucket.window_start < now() - make_interval(secs => p_window_seconds) THEN now()
        ELSE bucket.window_start
      END
  RETURNING hit_count INTO v_count;
  IF v_count > p_limit THEN
    RAISE EXCEPTION 'rate_limited';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.write_audit(
  p_pharmacy uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_metadata jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM set_config('medibilling.allow_audit', 'on', true);
  INSERT INTO public.audit_logs (pharmacy_id, actor_id, action, entity_type, entity_id, metadata)
  VALUES (p_pharmacy, auth.uid(), p_action, p_entity_type, p_entity_id, COALESCE(p_metadata, '{}'::jsonb));
END;
$$;

CREATE OR REPLACE FUNCTION public.allocate_number(p_pharmacy uuid, p_doc_type text, p_on date)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prefix text;
  v_start integer;
  v_fy text;
  v_seq integer;
BEGIN
  SELECT invoice_prefix, financial_year_start_month INTO v_prefix, v_start
  FROM public.pharmacies WHERE id = p_pharmacy;
  IF v_prefix IS NULL THEN
    RAISE EXCEPTION 'pharmacy_not_found';
  END IF;
  v_fy := public.financial_year_label(p_on, v_start);
  IF p_doc_type = 'sale_return' THEN
    v_prefix := 'CN';
  ELSIF p_doc_type = 'purchase_return' THEN
    v_prefix := 'DN';
  ELSIF p_doc_type = 'adjustment' THEN
    v_prefix := 'ADJ';
  ELSIF p_doc_type <> 'sale' THEN
    RAISE EXCEPTION 'unknown_document';
  END IF;

  INSERT INTO public.invoice_counters AS counter (pharmacy_id, financial_year, doc_type, last_number)
  VALUES (p_pharmacy, v_fy, p_doc_type, 1)
  ON CONFLICT (pharmacy_id, financial_year, doc_type)
  DO UPDATE SET last_number = counter.last_number + 1, updated_at = now()
  RETURNING last_number INTO v_seq;

  RETURN v_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 6, '0');
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_invoice_totals(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_mode text := p_payload ->> 'pricing_mode';
  v_supply text := p_payload ->> 'supply_type';
  v_bill_discount numeric := round(COALESCE((p_payload ->> 'bill_discount_amount')::numeric, 0), 2);
  v_round boolean := COALESCE((p_payload ->> 'round_to_rupee')::boolean, false);
  v_count integer;
  v_i integer;
  v_line jsonb;
  v_qty numeric;
  v_price numeric;
  v_gross numeric;
  v_discount numeric;
  v_percent text;
  v_amount numeric;
  v_base_sum numeric := 0;
  v_allocated numeric := 0;
  v_share numeric;
  v_net numeric;
  v_rate numeric;
  v_class text;
  v_taxable numeric;
  v_gst numeric;
  v_cgst numeric;
  v_sgst numeric;
  v_igst numeric;
  v_line_total numeric;
  v_bases numeric[] := ARRAY[]::numeric[];
  v_grosses numeric[] := ARRAY[]::numeric[];
  v_discounts numeric[] := ARRAY[]::numeric[];
  v_rates numeric[] := ARRAY[]::numeric[];
  v_classes text[] := ARRAY[]::text[];
  v_nets numeric[] := ARRAY[]::numeric[];
  v_results jsonb := '[]'::jsonb;
  v_sum_gross numeric := 0;
  v_sum_discount numeric := 0;
  v_sum_taxable numeric := 0;
  v_sum_cgst numeric := 0;
  v_sum_sgst numeric := 0;
  v_sum_igst numeric := 0;
  v_sum_gst numeric := 0;
  v_exact numeric := 0;
  v_rounded numeric;
  v_round_off numeric;
BEGIN
  IF v_mode NOT IN ('inclusive', 'exclusive') THEN
    RAISE EXCEPTION 'invalid_pricing_mode';
  END IF;
  IF v_supply NOT IN ('intra', 'inter') THEN
    RAISE EXCEPTION 'invalid_supply_type';
  END IF;
  v_count := COALESCE(jsonb_array_length(p_payload -> 'lines'), 0);
  IF v_count = 0 THEN
    RAISE EXCEPTION 'lines_required';
  END IF;

  FOR v_i IN 0..v_count - 1 LOOP
    v_line := p_payload -> 'lines' -> v_i;
    v_qty := (v_line ->> 'quantity')::numeric;
    v_price := (v_line ->> 'unit_price')::numeric;
    IF v_qty IS NULL OR v_price IS NULL OR v_qty <= 0 OR v_price < 0 THEN
      RAISE EXCEPTION 'invalid_line';
    END IF;
    v_gross := round(v_qty * v_price, 2);
    v_percent := NULLIF(v_line ->> 'discount_percent', '');
    v_amount := round(COALESCE(NULLIF(v_line ->> 'discount_amount', '')::numeric, 0), 2);
    IF v_percent IS NOT NULL AND v_amount > 0 THEN
      RAISE EXCEPTION 'discount_conflict';
    END IF;
    IF v_percent IS NOT NULL THEN
      v_discount := round(v_gross * v_percent::numeric / 100, 2);
    ELSE
      v_discount := v_amount;
    END IF;
    IF v_discount < 0 OR v_discount > v_gross THEN
      RAISE EXCEPTION 'discount_exceeds_gross';
    END IF;
    v_grosses[v_i + 1] := v_gross;
    v_discounts[v_i + 1] := v_discount;
    v_bases[v_i + 1] := v_gross - v_discount;
    v_rates[v_i + 1] := COALESCE((v_line ->> 'gst_rate')::numeric, 0);
    v_classes[v_i + 1] := COALESCE(v_line ->> 'tax_classification', 'taxable');
    v_base_sum := v_base_sum + (v_gross - v_discount);
  END LOOP;

  IF v_bill_discount < 0 OR v_bill_discount > v_base_sum THEN
    RAISE EXCEPTION 'bill_discount_exceeds_total';
  END IF;

  FOR v_i IN 1..v_count LOOP
    IF v_i = v_count THEN
      v_share := v_bill_discount - v_allocated;
    ELSIF v_base_sum = 0 THEN
      v_share := 0;
    ELSE
      v_share := round(v_bill_discount * v_bases[v_i] / v_base_sum, 2);
      v_allocated := v_allocated + v_share;
    END IF;
    IF v_share < 0 OR v_share > v_bases[v_i] THEN
      RAISE EXCEPTION 'bill_discount_allocation_failed';
    END IF;
    v_nets[v_i] := v_bases[v_i] - v_share;
  END LOOP;

  FOR v_i IN 1..v_count LOOP
    v_net := v_nets[v_i];
    v_rate := v_rates[v_i];
    v_class := v_classes[v_i];
    IF v_class IS DISTINCT FROM 'taxable' OR v_rate <= 0 THEN
      v_taxable := v_net;
      v_gst := 0;
    ELSIF v_mode = 'exclusive' THEN
      v_taxable := v_net;
      v_gst := round(v_taxable * v_rate / 100, 2);
    ELSE
      v_taxable := round(v_net / (1 + v_rate / 100), 2);
      v_gst := v_net - v_taxable;
    END IF;
    IF v_supply = 'inter' THEN
      v_igst := v_gst;
      v_cgst := 0;
      v_sgst := 0;
    ELSE
      v_cgst := round(v_gst / 2, 2);
      v_sgst := v_gst - v_cgst;
      v_igst := 0;
    END IF;
    v_line_total := v_taxable + v_gst;
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'gross', public.money_text(v_grosses[v_i]),
      'discount', public.money_text(v_discounts[v_i]),
      'bill_discount_share', public.money_text(v_bases[v_i] - v_net),
      'taxable_value', public.money_text(v_taxable),
      'gst_rate', public.money_text(v_rate),
      'cgst', public.money_text(v_cgst),
      'sgst', public.money_text(v_sgst),
      'igst', public.money_text(v_igst),
      'gst_amount', public.money_text(v_gst),
      'line_total', public.money_text(v_line_total)
    ));
    v_sum_gross := v_sum_gross + v_grosses[v_i];
    v_sum_discount := v_sum_discount + v_discounts[v_i];
    v_sum_taxable := v_sum_taxable + v_taxable;
    v_sum_cgst := v_sum_cgst + v_cgst;
    v_sum_sgst := v_sum_sgst + v_sgst;
    v_sum_igst := v_sum_igst + v_igst;
    v_sum_gst := v_sum_gst + v_gst;
    v_exact := v_exact + v_line_total;
  END LOOP;

  -- The last loop overwrites v_share. Bill discount shares were already stored per line above.
  v_sum_discount := v_sum_discount + v_bill_discount;
  IF v_round THEN
    v_rounded := round(v_exact, 0);
  ELSE
    v_rounded := v_exact;
  END IF;
  v_round_off := v_rounded - v_exact;

  RETURN jsonb_build_object(
    'lines', v_results,
    'gross', public.money_text(v_sum_gross),
    'discount_total', public.money_text(v_sum_discount),
    'taxable_value', public.money_text(v_sum_taxable),
    'cgst', public.money_text(v_sum_cgst),
    'sgst', public.money_text(v_sum_sgst),
    'igst', public.money_text(v_sum_igst),
    'gst_amount', public.money_text(v_sum_gst),
    'round_off', public.money_text(v_round_off),
    'grand_total', public.money_text(v_rounded)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_sales_invoice()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting('medibilling.allow_financial_write', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'posted_invoice_immutable';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'posted_invoice_delete_forbidden';
  END IF;
  IF TG_OP = 'UPDATE' AND (
    NEW.invoice_number IS DISTINCT FROM OLD.invoice_number
    OR NEW.grand_total IS DISTINCT FROM OLD.grand_total
    OR NEW.taxable_value IS DISTINCT FROM OLD.taxable_value
    OR NEW.cgst IS DISTINCT FROM OLD.cgst
    OR NEW.sgst IS DISTINCT FROM OLD.sgst
    OR NEW.igst IS DISTINCT FROM OLD.igst
    OR NEW.discount_amount IS DISTINCT FROM OLD.discount_amount
    OR NEW.subtotal IS DISTINCT FROM OLD.subtotal
    OR NEW.round_off IS DISTINCT FROM OLD.round_off
    OR NEW.pricing_mode IS DISTINCT FROM OLD.pricing_mode
    OR NEW.supply_type IS DISTINCT FROM OLD.supply_type
    OR NEW.invoice_kind IS DISTINCT FROM OLD.invoice_kind
    OR NEW.customer_name_snapshot IS DISTINCT FROM OLD.customer_name_snapshot
    OR NEW.seller_name IS DISTINCT FROM OLD.seller_name
    OR NEW.seller_gstin IS DISTINCT FROM OLD.seller_gstin
    OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
  ) THEN
    RAISE EXCEPTION 'posted_invoice_amounts_immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER sales_invoices_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.sales_invoices
  FOR EACH ROW EXECUTE FUNCTION public.guard_sales_invoice();

CREATE OR REPLACE FUNCTION public.guard_supplier_invoice()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'posted_document_delete_forbidden';
  END IF;
  IF current_setting('medibilling.allow_financial_write', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'posted_document_immutable';
  END IF;
  IF TG_OP = 'UPDATE' AND (
    to_jsonb(NEW) - 'payment_status' - 'amount_paid'
  ) IS DISTINCT FROM (
    to_jsonb(OLD) - 'payment_status' - 'amount_paid'
  ) THEN
    RAISE EXCEPTION 'posted_document_immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_returned_qty()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'posted_document_delete_forbidden';
  END IF;
  IF current_setting('medibilling.allow_financial_write', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'posted_document_immutable';
  END IF;
  IF TG_OP = 'UPDATE' AND (to_jsonb(NEW) - 'returned_qty') IS DISTINCT FROM (to_jsonb(OLD) - 'returned_qty') THEN
    RAISE EXCEPTION 'posted_document_immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_insert_only()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'posted_document_immutable';
  END IF;
  IF current_setting('medibilling.allow_financial_write', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'posted_document_immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER sales_items_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.sales_invoice_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_returned_qty();
CREATE TRIGGER sales_payments_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.sales_payments
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();
CREATE TRIGGER sales_returns_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.sales_returns
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();
CREATE TRIGGER sales_return_items_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.sales_return_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();
CREATE TRIGGER sales_refunds_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.sales_refunds
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();
CREATE TRIGGER supplier_invoices_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_invoices
  FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_invoice();
CREATE TRIGGER purchase_items_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_returned_qty();
CREATE TRIGGER supplier_returns_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_returns
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();
CREATE TRIGGER supplier_return_items_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_return_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();
CREATE TRIGGER stock_movements_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.stock_movements
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();
CREATE TRIGGER stock_adjustments_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.stock_adjustments
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();
CREATE TRIGGER customer_ledger_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.customer_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();
CREATE TRIGGER supplier_ledger_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.supplier_ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public.guard_insert_only();

CREATE OR REPLACE FUNCTION public.guard_audit()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP <> 'INSERT' OR current_setting('medibilling.allow_audit', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'audit_immutable';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER audit_logs_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.audit_logs
  FOR EACH ROW EXECUTE FUNCTION public.guard_audit();

CREATE OR REPLACE FUNCTION public.guard_batch_stock()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.selling_price > NEW.mrp THEN
    RAISE EXCEPTION 'price_above_mrp';
  END IF;
  IF TG_OP = 'UPDATE' AND (
    NEW.qty_available IS DISTINCT FROM OLD.qty_available
    OR NEW.qty_quarantine IS DISTINCT FROM OLD.qty_quarantine
    OR NEW.qty_received IS DISTINCT FROM OLD.qty_received
    OR NEW.free_qty IS DISTINCT FROM OLD.free_qty
    OR NEW.unit_cost IS DISTINCT FROM OLD.unit_cost
    OR NEW.status IS DISTINCT FROM OLD.status
  ) AND current_setting('medibilling.allow_financial_write', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'stock_change_forbidden';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER batches_stock_guard
  BEFORE INSERT OR UPDATE ON public.inventory_batches
  FOR EACH ROW EXECUTE FUNCTION public.guard_batch_stock();

CREATE OR REPLACE FUNCTION public.guard_party_balance()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF TG_TABLE_NAME = 'customers' THEN
      NEW.outstanding_balance := COALESCE(NEW.opening_balance, 0);
    ELSE
      NEW.current_balance := COALESCE(NEW.opening_balance, 0);
    END IF;
  ELSIF TG_TABLE_NAME = 'customers' THEN
    IF NEW.outstanding_balance IS DISTINCT FROM OLD.outstanding_balance
      AND current_setting('medibilling.allow_financial_write', true) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'balance_change_forbidden';
    END IF;
  ELSIF TG_TABLE_NAME = 'suppliers' THEN
    IF NEW.current_balance IS DISTINCT FROM OLD.current_balance
      AND current_setting('medibilling.allow_financial_write', true) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'balance_change_forbidden';
    END IF;
  END IF;
  IF TG_TABLE_NAME = 'customers' THEN
    IF (
      (TG_OP = 'INSERT' AND NEW.credit_limit > 0)
      OR (TG_OP = 'UPDATE' AND NEW.credit_limit IS DISTINCT FROM OLD.credit_limit)
    ) AND auth.uid() IS NOT NULL
      AND NOT public.auth_has_role(NEW.pharmacy_id, ARRAY['owner', 'pharmacist'])
      AND current_setting('medibilling.allow_financial_write', true) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'not_authorized';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.party_opening_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF COALESCE(NEW.opening_balance, 0) = 0 THEN
    RETURN NEW;
  END IF;
  PERFORM set_config('medibilling.allow_financial_write', 'on', true);
  IF TG_TABLE_NAME = 'customers' THEN
    INSERT INTO public.customer_ledger_entries (pharmacy_id, customer_id, entry_type, debit, notes, created_by)
    VALUES (NEW.pharmacy_id, NEW.id, 'opening', NEW.opening_balance, 'Opening balance', auth.uid());
  ELSIF NEW.opening_balance > 0 THEN
    INSERT INTO public.supplier_ledger_entries (pharmacy_id, supplier_id, entry_type, debit, notes, created_by)
    VALUES (NEW.pharmacy_id, NEW.id, 'opening', NEW.opening_balance, 'Opening balance', auth.uid());
  ELSE
    INSERT INTO public.supplier_ledger_entries (pharmacy_id, supplier_id, entry_type, credit, notes, created_by)
    VALUES (NEW.pharmacy_id, NEW.id, 'opening', abs(NEW.opening_balance), 'Opening balance', auth.uid());
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER customers_opening_ledger
  AFTER INSERT ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.party_opening_ledger();
CREATE TRIGGER suppliers_opening_ledger
  AFTER INSERT ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION public.party_opening_ledger();

CREATE TRIGGER customers_balance_guard
  BEFORE INSERT OR UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.guard_party_balance();
CREATE TRIGGER suppliers_balance_guard
  BEFORE INSERT OR UPDATE ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION public.guard_party_balance();

CREATE OR REPLACE FUNCTION public.audit_row_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.write_audit(
    COALESCE(NEW.pharmacy_id, OLD.pharmacy_id),
    TG_ARGV[0],
    TG_TABLE_NAME,
    COALESCE(NEW.id, OLD.id),
    jsonb_build_object('operation', TG_OP)
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER medicines_audit
  AFTER INSERT OR UPDATE ON public.medicines
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('medicine_change');
CREATE TRIGGER pharmacies_audit
  AFTER UPDATE ON public.pharmacies
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('pharmacy_settings_change');
CREATE TRIGGER memberships_audit
  AFTER INSERT OR UPDATE ON public.pharmacy_memberships
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('membership_change');
