-- Store isolation. Financial tables are readable by members and writable only by definer functions.

ALTER TABLE public.pharmacies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pharmacy_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medicine_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medicines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_invoice_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_return_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_return_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.application_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_counters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rate_limit_buckets ENABLE ROW LEVEL SECURITY;

CREATE POLICY pharmacies_select ON public.pharmacies FOR SELECT TO authenticated
  USING (id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY pharmacies_update ON public.pharmacies FOR UPDATE TO authenticated
  USING (public.auth_has_role(id, ARRAY['owner']))
  WITH CHECK (public.auth_has_role(id, ARRAY['owner']));

CREATE POLICY profiles_select ON public.user_profiles FOR SELECT TO authenticated
  USING (
    id = auth.uid()
    OR id IN (
      SELECT user_id FROM public.pharmacy_memberships
      WHERE pharmacy_id IN (SELECT public.auth_pharmacy_ids())
    )
  );
CREATE POLICY profiles_update ON public.user_profiles FOR UPDATE TO authenticated
  USING (id = auth.uid()) WITH CHECK (id = auth.uid());

CREATE POLICY memberships_select ON public.pharmacy_memberships FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.auth_has_role(pharmacy_id, ARRAY['owner']));
CREATE POLICY memberships_insert ON public.pharmacy_memberships FOR INSERT TO authenticated
  WITH CHECK (public.auth_has_role(pharmacy_id, ARRAY['owner']));
CREATE POLICY memberships_update ON public.pharmacy_memberships FOR UPDATE TO authenticated
  USING (public.auth_has_role(pharmacy_id, ARRAY['owner']))
  WITH CHECK (public.auth_has_role(pharmacy_id, ARRAY['owner']));

CREATE POLICY categories_select ON public.medicine_categories FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY categories_write ON public.medicine_categories FOR ALL TO authenticated
  USING (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']))
  WITH CHECK (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']));

CREATE POLICY medicines_select ON public.medicines FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY medicines_insert ON public.medicines FOR INSERT TO authenticated
  WITH CHECK (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']));
CREATE POLICY medicines_update ON public.medicines FOR UPDATE TO authenticated
  USING (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']))
  WITH CHECK (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']));

CREATE POLICY suppliers_select ON public.suppliers FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY suppliers_insert ON public.suppliers FOR INSERT TO authenticated
  WITH CHECK (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']));
CREATE POLICY suppliers_update ON public.suppliers FOR UPDATE TO authenticated
  USING (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']))
  WITH CHECK (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']));

CREATE POLICY customers_select ON public.customers FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY customers_insert ON public.customers FOR INSERT TO authenticated
  WITH CHECK (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY customers_update ON public.customers FOR UPDATE TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()))
  WITH CHECK (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));

CREATE POLICY batches_select ON public.inventory_batches FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY batches_update ON public.inventory_batches FOR UPDATE TO authenticated
  USING (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']))
  WITH CHECK (public.auth_has_role(pharmacy_id, ARRAY['owner', 'pharmacist']));

CREATE POLICY read_supplier_invoices ON public.supplier_invoices FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_purchase_items ON public.purchase_items FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_movements ON public.stock_movements FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_sales ON public.sales_invoices FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_sale_items ON public.sales_invoice_items FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_payments ON public.sales_payments FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_sale_returns ON public.sales_returns FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_sale_return_items ON public.sales_return_items FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_refunds ON public.sales_refunds FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_supplier_returns ON public.supplier_returns FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_supplier_return_items ON public.supplier_return_items FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_customer_ledger ON public.customer_ledger_entries FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_supplier_ledger ON public.supplier_ledger_entries FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));
CREATE POLICY read_adjustments ON public.stock_adjustments FOR SELECT TO authenticated
  USING (pharmacy_id IN (SELECT public.auth_pharmacy_ids()));

CREATE POLICY drafts_all ON public.sales_drafts FOR ALL TO authenticated
  USING (user_id = auth.uid() AND pharmacy_id IN (SELECT public.auth_pharmacy_ids()))
  WITH CHECK (user_id = auth.uid() AND pharmacy_id IN (SELECT public.auth_pharmacy_ids()));

CREATE POLICY settings_owner ON public.application_settings FOR ALL TO authenticated
  USING (public.auth_has_role(pharmacy_id, ARRAY['owner']))
  WITH CHECK (public.auth_has_role(pharmacy_id, ARRAY['owner']));

CREATE POLICY audit_owner ON public.audit_logs FOR SELECT TO authenticated
  USING (pharmacy_id IS NOT NULL AND public.auth_has_role(pharmacy_id, ARRAY['owner']));

GRANT SELECT ON public.batch_stock_reconciliation TO authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
REVOKE ALL ON public.rate_limit_buckets FROM authenticated;
REVOKE ALL ON public.invoice_counters FROM authenticated;
REVOKE ALL ON FUNCTION public.write_audit(uuid, text, text, uuid, jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION public.allocate_number(uuid, text, date) FROM authenticated;
REVOKE ALL ON FUNCTION public.consume_rate_limit(text, integer, integer) FROM authenticated;
REVOKE ALL ON FUNCTION public.prepare_sale(jsonb, boolean) FROM authenticated;

REVOKE INSERT, UPDATE, DELETE ON
  public.sales_invoices,
  public.sales_invoice_items,
  public.sales_payments,
  public.sales_returns,
  public.sales_return_items,
  public.sales_refunds,
  public.supplier_invoices,
  public.purchase_items,
  public.supplier_returns,
  public.supplier_return_items,
  public.stock_movements,
  public.stock_adjustments,
  public.customer_ledger_entries,
  public.supplier_ledger_entries,
  public.audit_logs
FROM authenticated, anon;
