-- Dashboard aggregates and business reports. Totals are SQL aggregates, not page sums.
-- Estimated gross profit = taxable value minus batch unit cost. It is not net profit.

CREATE OR REPLACE FUNCTION public.dashboard_summary(
  p_pharmacy uuid,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL,
  p_group text DEFAULT 'day'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_tz text;
  v_today date;
  v_from date;
  v_to date;
  v_days integer;
  v_sales numeric;
  v_count integer;
  v_discount numeric;
  v_returns numeric;
  v_profit numeric;
  v_sale_profit numeric;
  v_return_profit numeric;
  v_cash numeric;
  v_upi numeric;
  v_card numeric;
  v_bank numeric;
  v_credit numeric;
  v_cost_value numeric;
  v_mrp_value numeric;
  v_medicines integer;
  v_batches integer;
  v_low integer;
  v_e30 integer;
  v_e60 integer;
  v_e90 integer;
  v_expired_qty numeric;
  v_expired_value numeric;
  v_supplier_due numeric;
  v_threshold numeric;
BEGIN
  v_role := public.require_role(p_pharmacy, ARRAY['owner', 'pharmacist', 'billing_operator']);
  IF p_group NOT IN ('day', 'week', 'month') THEN RAISE EXCEPTION 'invalid_group'; END IF;
  SELECT timezone, near_expiry_days, low_stock_threshold INTO v_tz, v_days, v_threshold
  FROM public.pharmacies WHERE id = p_pharmacy;
  v_today := public.pharmacy_today(v_tz);
  v_from := COALESCE(p_from, v_today);
  v_to := COALESCE(p_to, v_today);
  IF v_to < v_from OR v_to - v_from > 400 THEN RAISE EXCEPTION 'invalid_date_range'; END IF;

  SELECT COALESCE(SUM(grand_total), 0), COUNT(*), COALESCE(SUM(discount_amount), 0)
    INTO v_sales, v_count, v_discount
  FROM public.sales_invoices
  WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(grand_total), 0) INTO v_returns
  FROM public.sales_returns
  WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to;

  SELECT
    COALESCE(SUM(amount) FILTER (WHERE method = 'cash'), 0),
    COALESCE(SUM(amount) FILTER (WHERE method = 'upi'), 0),
    COALESCE(SUM(amount) FILTER (WHERE method = 'card'), 0),
    COALESCE(SUM(amount) FILTER (WHERE method = 'bank_transfer'), 0),
    COALESCE(SUM(amount) FILTER (WHERE method = 'credit'), 0)
  INTO v_cash, v_upi, v_card, v_bank, v_credit
  FROM public.sales_payments p
  JOIN public.sales_invoices s ON s.id = p.invoice_id
  WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(i.taxable_value - round(i.unit_cost * i.quantity_in_packs, 2)), 0)
    INTO v_sale_profit
  FROM public.sales_invoice_items i
  JOIN public.sales_invoices s ON s.id = i.invoice_id
  WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to;

  SELECT COALESCE(SUM(
    CASE WHEN ri.disposition = 'resale'
      THEN ri.taxable_value - round(i.unit_cost * ri.quantity_in_packs, 2)
      ELSE ri.taxable_value END
  ), 0) INTO v_return_profit
  FROM public.sales_return_items ri
  JOIN public.sales_returns r ON r.id = ri.return_id
  JOIN public.sales_invoice_items i ON i.id = ri.invoice_item_id
  WHERE r.pharmacy_id = p_pharmacy AND r.business_date BETWEEN v_from AND v_to;
  v_profit := v_sale_profit - v_return_profit;

  SELECT COALESCE(SUM(round(qty_available * unit_cost, 2)), 0), COALESCE(SUM(round(qty_available * mrp, 2)), 0)
    INTO v_cost_value, v_mrp_value
  FROM public.inventory_batches
  WHERE pharmacy_id = p_pharmacy AND status = 'active' AND qty_available > 0 AND expiry_date >= v_today;

  SELECT COUNT(*) INTO v_medicines FROM public.medicines WHERE pharmacy_id = p_pharmacy AND is_active;
  SELECT COUNT(*) INTO v_batches FROM public.inventory_batches
  WHERE pharmacy_id = p_pharmacy AND status = 'active' AND qty_available > 0 AND expiry_date >= v_today;

  SELECT COUNT(*) INTO v_low FROM (
    SELECT m.id
    FROM public.medicines m
    LEFT JOIN public.inventory_batches b ON b.medicine_id = m.id AND b.status = 'active' AND b.expiry_date >= v_today
    WHERE m.pharmacy_id = p_pharmacy AND m.is_active
    GROUP BY m.id, m.reorder_level
    HAVING COALESCE(SUM(b.qty_available), 0) <= CASE WHEN m.reorder_level > 0 THEN m.reorder_level ELSE v_threshold END
  ) low_rows;

  SELECT
    COUNT(*) FILTER (WHERE expiry_date <= v_today + 30),
    COUNT(*) FILTER (WHERE expiry_date <= v_today + 60),
    COUNT(*) FILTER (WHERE expiry_date <= v_today + 90)
  INTO v_e30, v_e60, v_e90
  FROM public.inventory_batches
  WHERE pharmacy_id = p_pharmacy AND status = 'active' AND qty_available > 0
    AND expiry_date >= v_today;

  SELECT COALESCE(SUM(qty_available), 0), COALESCE(SUM(round(qty_available * unit_cost, 2)), 0)
    INTO v_expired_qty, v_expired_value
  FROM public.inventory_batches
  WHERE pharmacy_id = p_pharmacy AND qty_available > 0 AND expiry_date < v_today
    AND status NOT IN ('written_off');

  SELECT COALESCE(SUM(current_balance), 0) INTO v_supplier_due
  FROM public.suppliers WHERE pharmacy_id = p_pharmacy AND current_balance > 0;

  RETURN jsonb_build_object(
    'from', v_from, 'to', v_to, 'today', v_today,
    'sales_total', public.money_text(v_sales),
    'invoice_count', v_count,
    'cash', public.money_text(v_cash),
    'upi', public.money_text(v_upi),
    'card', public.money_text(v_card),
    'bank_transfer', public.money_text(v_bank),
    'credit', public.money_text(v_credit),
    'discounts', public.money_text(v_discount),
    'returns_total', public.money_text(v_returns),
    'net_sales', public.money_text(v_sales - v_returns),
    'gross_profit', CASE WHEN v_role = 'billing_operator' THEN NULL ELSE to_jsonb(public.money_text(v_profit)) END,
    'gross_profit_note', 'Estimated gross profit is taxable sales value minus the batch unit cost of the quantity sold, after saleable returns. Quarantined returns reverse revenue only. Operating expenses are not deducted, so this is not net profit.',
    'inventory_cost', public.money_text(v_cost_value),
    'inventory_mrp', public.money_text(v_mrp_value),
    'medicine_count', v_medicines,
    'active_batch_count', v_batches,
    'low_stock_count', v_low,
    'expiring_30', v_e30,
    'expiring_60', v_e60,
    'expiring_90', v_e90,
    'expired_qty', trim(to_char(v_expired_qty, 'FM999999990.000')),
    'expired_value', public.money_text(v_expired_value),
    'supplier_outstanding', public.money_text(v_supplier_due),
    'recent_invoices', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', id, 'invoice_number', invoice_number, 'business_date', business_date,
        'customer_name', customer_name_snapshot, 'grand_total', public.money_text(grand_total),
        'payment_status', payment_status
      ) ORDER BY created_at DESC)
      FROM (
        SELECT * FROM public.sales_invoices
        WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to
        ORDER BY created_at DESC LIMIT 8
      ) recent
    ), '[]'::jsonb),
    'recent_purchases', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', si.id, 'supplier_invoice_number', si.supplier_invoice_number, 'invoice_date', si.invoice_date,
        'supplier_name', s.name, 'grand_total', public.money_text(si.grand_total), 'payment_status', si.payment_status
      ) ORDER BY si.created_at DESC)
      FROM (
        SELECT * FROM public.supplier_invoices
        WHERE pharmacy_id = p_pharmacy AND invoice_date BETWEEN v_from AND v_to
        ORDER BY created_at DESC LIMIT 8
      ) si
      JOIN public.suppliers s ON s.id = si.supplier_id
    ), '[]'::jsonb),
    'top_medicines', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'name', medicine_name, 'quantity', trim(to_char(qty, 'FM999999990.000')),
        'amount', public.money_text(amount)
      ) ORDER BY qty DESC)
      FROM (
        SELECT i.medicine_name, SUM(i.quantity_in_packs) AS qty, SUM(i.line_total) AS amount
        FROM public.sales_invoice_items i
        JOIN public.sales_invoices s ON s.id = i.invoice_id
        WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to
        GROUP BY i.medicine_name
        ORDER BY SUM(i.quantity_in_packs) DESC
        LIMIT 5
      ) top_rows
    ), '[]'::jsonb),
    'trend', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('period', period, 'total', public.money_text(total)) ORDER BY period)
      FROM (
        SELECT CASE
          WHEN p_group = 'month' THEN date_trunc('month', business_date)::date
          WHEN p_group = 'week' THEN date_trunc('week', business_date)::date
          ELSE business_date
        END AS period, SUM(grand_total) AS total
        FROM public.sales_invoices
        WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to
        GROUP BY 1
      ) trend_rows
    ), '[]'::jsonb)
  );
END;
$$;
