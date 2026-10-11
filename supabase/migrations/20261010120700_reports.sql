-- Report totals cover the full filter. Row limits never change the totals.

CREATE OR REPLACE FUNCTION public.report_query(
  p_pharmacy uuid,
  p_report text,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL,
  p_extra jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tz text;
  v_today date;
  v_from date;
  v_to date;
  v_limit integer := LEAST(GREATEST(COALESCE((p_extra ->> 'limit')::integer, 200), 1), 1000);
  v_offset integer := GREATEST(COALESCE((p_extra ->> 'offset')::integer, 0), 0);
  v_window text := COALESCE(p_extra ->> 'window', '30');
  v_group text := COALESCE(p_extra ->> 'group', 'week');
  v_threshold numeric;
  v_rows jsonb;
  v_totals jsonb;
  v_title text;
  v_note text := '';
BEGIN
  PERFORM public.require_role(p_pharmacy, ARRAY['owner', 'pharmacist']);
  SELECT timezone, low_stock_threshold INTO v_tz, v_threshold FROM public.pharmacies WHERE id = p_pharmacy;
  v_today := public.pharmacy_today(v_tz);
  v_from := COALESCE(p_from, v_today - 30);
  v_to := COALESCE(p_to, v_today);
  IF v_to < v_from OR v_to - v_from > 400 THEN RAISE EXCEPTION 'invalid_date_range'; END IF;

  IF p_report = 'daily_sales' THEN
    v_title := 'Daily sales';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'period', business_date, 'invoices', invoices, 'sales', public.money_text(sales),
      'discounts', public.money_text(discounts), 'returns', public.money_text(returns)
    ) ORDER BY business_date), '[]') INTO v_rows
    FROM (
      SELECT s.business_date, COUNT(*) AS invoices, SUM(s.grand_total) AS sales, SUM(s.discount_amount) AS discounts,
             COALESCE((SELECT SUM(r.grand_total) FROM public.sales_returns r WHERE r.pharmacy_id = p_pharmacy AND r.business_date = s.business_date), 0) AS returns
      FROM public.sales_invoices s
      WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to
      GROUP BY s.business_date
      ORDER BY s.business_date
      LIMIT v_limit OFFSET v_offset
    ) days;
    SELECT jsonb_build_object('sales', public.money_text(COALESCE(SUM(grand_total), 0)), 'invoices', COUNT(*))
      INTO v_totals FROM public.sales_invoices
    WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to;

  ELSIF p_report = 'period_sales' THEN
    v_title := CASE WHEN v_group = 'month' THEN 'Monthly sales' ELSE 'Weekly sales' END;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('period', period, 'invoices', invoices, 'sales', public.money_text(sales)) ORDER BY period), '[]')
      INTO v_rows
    FROM (
      SELECT CASE WHEN v_group = 'month' THEN date_trunc('month', business_date)::date ELSE date_trunc('week', business_date)::date END AS period,
             COUNT(*) AS invoices, SUM(grand_total) AS sales
      FROM public.sales_invoices
      WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to
      GROUP BY 1 ORDER BY 1 LIMIT v_limit OFFSET v_offset
    ) periods;
    SELECT jsonb_build_object('sales', public.money_text(COALESCE(SUM(grand_total), 0))) INTO v_totals
    FROM public.sales_invoices WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to;

  ELSIF p_report = 'sales_by_medicine' THEN
    v_title := 'Sales by medicine';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'medicine', medicine_name, 'quantity', trim(to_char(qty, 'FM999999990.000')), 'taxable', public.money_text(taxable), 'total', public.money_text(total)
    ) ORDER BY total DESC), '[]') INTO v_rows
    FROM (
      SELECT i.medicine_name, SUM(i.quantity_in_packs) AS qty, SUM(i.taxable_value) AS taxable, SUM(i.line_total) AS total
      FROM public.sales_invoice_items i JOIN public.sales_invoices s ON s.id = i.invoice_id
      WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to
      GROUP BY i.medicine_name ORDER BY SUM(i.line_total) DESC LIMIT v_limit OFFSET v_offset
    ) meds;
    SELECT jsonb_build_object('total', public.money_text(COALESCE(SUM(i.line_total), 0))) INTO v_totals
    FROM public.sales_invoice_items i JOIN public.sales_invoices s ON s.id = i.invoice_id
    WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to;

  ELSIF p_report = 'sales_by_batch' THEN
    v_title := 'Sales by batch';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'medicine', medicine_name, 'batch', batch_number, 'expiry', expiry_date,
      'quantity', trim(to_char(qty, 'FM999999990.000')), 'total', public.money_text(total)
    ) ORDER BY total DESC), '[]') INTO v_rows
    FROM (
      SELECT i.medicine_name, i.batch_number, i.expiry_date, SUM(i.quantity_in_packs) qty, SUM(i.line_total) total
      FROM public.sales_invoice_items i JOIN public.sales_invoices s ON s.id = i.invoice_id
      WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to
      GROUP BY i.medicine_name, i.batch_number, i.expiry_date
      ORDER BY SUM(i.line_total) DESC LIMIT v_limit OFFSET v_offset
    ) batches;
    v_totals := '{}'::jsonb;

  ELSIF p_report = 'sales_by_customer' THEN
    v_title := 'Sales by customer';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'customer', customer_name_snapshot, 'invoices', invoices, 'total', public.money_text(total)
    ) ORDER BY total DESC), '[]') INTO v_rows
    FROM (
      SELECT customer_name_snapshot, COUNT(*) invoices, SUM(grand_total) total
      FROM public.sales_invoices
      WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to
      GROUP BY customer_name_snapshot ORDER BY SUM(grand_total) DESC LIMIT v_limit OFFSET v_offset
    ) customers;
    v_totals := '{}'::jsonb;

  ELSIF p_report = 'sales_by_operator' THEN
    v_title := 'Sales by operator';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'operator', operator_name, 'invoices', invoices, 'total', public.money_text(total)
    ) ORDER BY total DESC), '[]') INTO v_rows
    FROM (
      SELECT COALESCE(u.full_name, 'Unknown') AS operator_name, COUNT(*) invoices, SUM(s.grand_total) total
      FROM public.sales_invoices s LEFT JOIN public.user_profiles u ON u.id = s.created_by
      WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to
      GROUP BY COALESCE(u.full_name, 'Unknown') ORDER BY SUM(s.grand_total) DESC
    ) operators;
    v_totals := '{}'::jsonb;

  ELSIF p_report = 'gst_summary' THEN
    v_title := 'GST summary';
    v_note := 'Net of credit notes in the same period. Historical rates are the snapshots stored on each invoice.';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'gst_rate', public.money_text(gst_rate), 'taxable', public.money_text(taxable),
      'cgst', public.money_text(cgst), 'sgst', public.money_text(sgst), 'igst', public.money_text(igst)
    ) ORDER BY gst_rate), '[]') INTO v_rows
    FROM (
      SELECT gst_rate,
             SUM(taxable_value) AS taxable, SUM(cgst) AS cgst, SUM(sgst) AS sgst, SUM(igst) AS igst
      FROM (
        SELECT i.gst_rate, i.taxable_value, i.cgst, i.sgst, i.igst
        FROM public.sales_invoice_items i JOIN public.sales_invoices s ON s.id = i.invoice_id
        WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to
        UNION ALL
        SELECT i.gst_rate, -ri.taxable_value, -ri.cgst, -ri.sgst, -ri.igst
        FROM public.sales_return_items ri
        JOIN public.sales_returns r ON r.id = ri.return_id
        JOIN public.sales_invoice_items i ON i.id = ri.invoice_item_id
        WHERE r.pharmacy_id = p_pharmacy AND r.business_date BETWEEN v_from AND v_to
      ) net
      GROUP BY gst_rate
    ) rates;
    SELECT jsonb_build_object(
      'taxable', public.money_text(COALESCE(SUM((row ->> 'taxable')::numeric), 0)),
      'cgst', public.money_text(COALESCE(SUM((row ->> 'cgst')::numeric), 0)),
      'sgst', public.money_text(COALESCE(SUM((row ->> 'sgst')::numeric), 0)),
      'igst', public.money_text(COALESCE(SUM((row ->> 'igst')::numeric), 0))
    ) INTO v_totals FROM jsonb_array_elements(COALESCE(v_rows, '[]'::jsonb)) row;

  ELSIF p_report = 'purchases' THEN
    v_title := 'Purchases';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'date', invoice_date, 'supplier', name, 'invoice', supplier_invoice_number,
      'total', public.money_text(grand_total), 'paid', public.money_text(amount_paid), 'status', payment_status
    ) ORDER BY invoice_date DESC), '[]') INTO v_rows
    FROM (
      SELECT si.invoice_date, s.name, si.supplier_invoice_number, si.grand_total, si.amount_paid, si.payment_status
      FROM public.supplier_invoices si JOIN public.suppliers s ON s.id = si.supplier_id
      WHERE si.pharmacy_id = p_pharmacy AND si.invoice_date BETWEEN v_from AND v_to
      ORDER BY si.invoice_date DESC LIMIT v_limit OFFSET v_offset
    ) purchases;
    SELECT jsonb_build_object('total', public.money_text(COALESCE(SUM(grand_total), 0))) INTO v_totals
    FROM public.supplier_invoices WHERE pharmacy_id = p_pharmacy AND invoice_date BETWEEN v_from AND v_to;

  ELSIF p_report = 'supplier_outstanding' THEN
    v_title := 'Supplier outstanding';
    SELECT COALESCE(jsonb_agg(jsonb_build_object('supplier', name, 'phone', phone, 'balance', public.money_text(current_balance)) ORDER BY current_balance DESC), '[]')
      INTO v_rows FROM public.suppliers WHERE pharmacy_id = p_pharmacy AND current_balance <> 0;
    SELECT jsonb_build_object('balance', public.money_text(COALESCE(SUM(current_balance), 0))) INTO v_totals
    FROM public.suppliers WHERE pharmacy_id = p_pharmacy AND current_balance > 0;

  ELSIF p_report = 'customer_outstanding' THEN
    v_title := 'Customer outstanding';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'customer', name, 'phone', phone, 'limit', public.money_text(credit_limit), 'balance', public.money_text(outstanding_balance)
    ) ORDER BY outstanding_balance DESC), '[]') INTO v_rows
    FROM public.customers WHERE pharmacy_id = p_pharmacy AND outstanding_balance > 0;
    SELECT jsonb_build_object('balance', public.money_text(COALESCE(SUM(outstanding_balance), 0))) INTO v_totals
    FROM public.customers WHERE pharmacy_id = p_pharmacy;

  ELSIF p_report = 'low_stock' THEN
    v_title := 'Low stock';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'code', medicine_code, 'medicine', name, 'strength', strength, 'saleable', trim(to_char(saleable, 'FM999999990.000')),
      'reorder', trim(to_char(reorder_level, 'FM999999990.000'))
    ) ORDER BY name), '[]') INTO v_rows
    FROM (
      SELECT m.medicine_code, m.name, m.strength, m.reorder_level, COALESCE(SUM(b.qty_available), 0) AS saleable
      FROM public.medicines m
      LEFT JOIN public.inventory_batches b ON b.medicine_id = m.id AND b.status = 'active' AND b.expiry_date >= v_today
      WHERE m.pharmacy_id = p_pharmacy AND m.is_active
      GROUP BY m.id
      HAVING COALESCE(SUM(b.qty_available), 0) <= CASE WHEN m.reorder_level > 0 THEN m.reorder_level ELSE v_threshold END
      ORDER BY m.name LIMIT v_limit OFFSET v_offset
    ) low_rows;
    v_totals := '{}'::jsonb;

  ELSIF p_report = 'expiry' THEN
    v_title := CASE v_window
      WHEN 'expired' THEN 'Expired stock' WHEN 'quarantine' THEN 'Quarantined or recalled stock'
      ELSE 'Expiring within ' || v_window || ' days' END;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'medicine', m.name, 'strength', m.strength, 'batch', b.batch_number, 'expiry', b.expiry_date,
      'quantity', trim(to_char(b.qty_available, 'FM999999990.000')),
      'cost_value', public.money_text(round(b.qty_available * b.unit_cost, 2)),
      'mrp_value', public.money_text(round(b.qty_available * b.mrp, 2)), 'status', b.status
    ) ORDER BY b.expiry_date), '[]') INTO v_rows
    FROM public.inventory_batches b JOIN public.medicines m ON m.id = b.medicine_id
    WHERE b.pharmacy_id = p_pharmacy AND b.qty_available > 0 AND (
      (v_window = 'expired' AND b.expiry_date < v_today)
      OR (v_window = 'quarantine' AND b.status IN ('quarantined', 'recalled', 'blocked'))
      OR (v_window IN ('30', '60', '90') AND b.status = 'active' AND b.expiry_date >= v_today AND b.expiry_date <= v_today + v_window::integer)
    );
    v_totals := '{}'::jsonb;

  ELSIF p_report = 'stock_valuation' THEN
    v_title := 'Stock valuation';
    v_note := 'Saleable stock only. Expired, quarantined, recalled, and blocked batches are excluded. Cost is the batch unit cost.';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'medicine', name, 'quantity', trim(to_char(qty, 'FM999999990.000')),
      'cost_value', public.money_text(cost_value), 'mrp_value', public.money_text(mrp_value)
    ) ORDER BY name), '[]') INTO v_rows
    FROM (
      SELECT m.name, SUM(b.qty_available) qty, SUM(round(b.qty_available * b.unit_cost, 2)) cost_value, SUM(round(b.qty_available * b.mrp, 2)) mrp_value
      FROM public.inventory_batches b JOIN public.medicines m ON m.id = b.medicine_id
      WHERE b.pharmacy_id = p_pharmacy AND b.status = 'active' AND b.qty_available > 0 AND b.expiry_date >= v_today
      GROUP BY m.name ORDER BY m.name LIMIT v_limit OFFSET v_offset
    ) valued;
    SELECT jsonb_build_object(
      'cost_value', public.money_text(COALESCE(SUM(round(qty_available * unit_cost, 2)), 0)),
      'mrp_value', public.money_text(COALESCE(SUM(round(qty_available * mrp, 2)), 0))
    ) INTO v_totals FROM public.inventory_batches
    WHERE pharmacy_id = p_pharmacy AND status = 'active' AND qty_available > 0 AND expiry_date >= v_today;

  ELSIF p_report = 'returns' THEN
    v_title := 'Sales returns and refunds';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'date', business_date, 'credit_note', credit_note_number, 'total', public.money_text(grand_total),
      'refund', public.money_text(refund_amount), 'balance_credit', public.money_text(balance_credit), 'reason', reason
    ) ORDER BY business_date DESC), '[]') INTO v_rows
    FROM (
      SELECT business_date, credit_note_number, grand_total, refund_amount, balance_credit, reason
      FROM public.sales_returns WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to
      ORDER BY business_date DESC LIMIT v_limit OFFSET v_offset
    ) returns_rows;
    SELECT jsonb_build_object('total', public.money_text(COALESCE(SUM(grand_total), 0))) INTO v_totals
    FROM public.sales_returns WHERE pharmacy_id = p_pharmacy AND business_date BETWEEN v_from AND v_to;

  ELSIF p_report = 'payments' THEN
    v_title := 'Payment methods';
    SELECT COALESCE(jsonb_agg(jsonb_build_object('method', method, 'amount', public.money_text(amount)) ORDER BY method), '[]')
      INTO v_rows
    FROM (
      SELECT p.method, SUM(p.amount) amount
      FROM public.sales_payments p JOIN public.sales_invoices s ON s.id = p.invoice_id
      WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to
      GROUP BY p.method
    ) methods;
    SELECT jsonb_build_object('amount', public.money_text(COALESCE(SUM(p.amount), 0))) INTO v_totals
    FROM public.sales_payments p JOIN public.sales_invoices s ON s.id = p.invoice_id
    WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to;

  ELSIF p_report = 'gross_profit' THEN
    v_title := 'Estimated gross profit';
    v_note := 'Taxable value minus batch unit cost for the quantity sold. Saleable returns reverse revenue and cost. Quarantined returns reverse revenue only. This is not net profit.';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'medicine', medicine_name, 'quantity', trim(to_char(qty, 'FM999999990.000')),
      'taxable', public.money_text(taxable), 'cost', public.money_text(cost), 'gross_profit', public.money_text(taxable - cost)
    ) ORDER BY medicine_name), '[]') INTO v_rows
    FROM (
      SELECT i.medicine_name, SUM(i.quantity_in_packs) qty, SUM(i.taxable_value) taxable, SUM(round(i.unit_cost * i.quantity_in_packs, 2)) cost
      FROM public.sales_invoice_items i JOIN public.sales_invoices s ON s.id = i.invoice_id
      WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to
      GROUP BY i.medicine_name ORDER BY i.medicine_name LIMIT v_limit OFFSET v_offset
    ) profit_rows;
    SELECT jsonb_build_object('gross_profit', public.money_text(COALESCE(SUM(i.taxable_value - round(i.unit_cost * i.quantity_in_packs, 2)), 0)))
      INTO v_totals
    FROM public.sales_invoice_items i JOIN public.sales_invoices s ON s.id = i.invoice_id
    WHERE s.pharmacy_id = p_pharmacy AND s.business_date BETWEEN v_from AND v_to;
  ELSE
    RAISE EXCEPTION 'unknown_report';
  END IF;

  RETURN jsonb_build_object(
    'title', v_title, 'note', v_note, 'from', v_from, 'to', v_to,
    'rows', COALESCE(v_rows, '[]'::jsonb), 'totals', COALESCE(v_totals, '{}'::jsonb)
  );
END;
$$;
