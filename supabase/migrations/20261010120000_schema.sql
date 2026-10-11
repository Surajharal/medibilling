-- MediBilling schema
-- Money uses numeric. Quantities use 3 decimal places. Expiry values are dates.
-- A batch remains saleable through its expiry date in the pharmacy time zone.
-- Estimated gross profit uses batch unit cost and is not net profit.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.pharmacy_today(p_timezone text)
RETURNS date
LANGUAGE sql
STABLE
AS $$
  SELECT (now() AT TIME ZONE COALESCE(NULLIF(p_timezone, ''), 'Asia/Kolkata'))::date;
$$;

CREATE OR REPLACE FUNCTION public.financial_year_label(p_date date, p_start_month integer)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_year integer := EXTRACT(YEAR FROM p_date)::integer;
  v_month integer := EXTRACT(MONTH FROM p_date)::integer;
  v_start integer;
BEGIN
  IF p_start_month < 1 OR p_start_month > 12 THEN
    RAISE EXCEPTION 'invalid_financial_year';
  END IF;
  v_start := CASE WHEN v_month >= p_start_month THEN v_year ELSE v_year - 1 END;
  RETURN v_start::text || '-' || lpad(((v_start + 1) % 100)::text, 2, '0');
END;
$$;

CREATE OR REPLACE FUNCTION public.money_text(p_amount numeric)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (round(COALESCE(p_amount, 0), 2))::numeric(14, 2)::text;
$$;

CREATE TABLE public.pharmacies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
  owner_name text NOT NULL DEFAULT '',
  address_line1 text NOT NULL DEFAULT '',
  address_line2 text NOT NULL DEFAULT '',
  city text NOT NULL DEFAULT '',
  state text NOT NULL DEFAULT '',
  state_code char(2) NOT NULL DEFAULT '27',
  pincode text NOT NULL DEFAULT '',
  gstin text,
  gst_registered boolean NOT NULL DEFAULT false,
  drug_licence_numbers text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  logo_url text,
  timezone text NOT NULL DEFAULT 'Asia/Kolkata',
  invoice_prefix text NOT NULL DEFAULT 'MB' CHECK (invoice_prefix ~ '^[A-Z0-9]{1,8}$'),
  financial_year_start_month integer NOT NULL DEFAULT 4 CHECK (financial_year_start_month BETWEEN 1 AND 12),
  pricing_mode text NOT NULL DEFAULT 'inclusive' CHECK (pricing_mode IN ('inclusive', 'exclusive')),
  default_payment_method text NOT NULL DEFAULT 'cash' CHECK (default_payment_method IN ('cash', 'upi', 'card', 'bank_transfer')),
  round_invoice_to_rupee boolean NOT NULL DEFAULT false,
  low_stock_threshold numeric(14, 3) NOT NULL DEFAULT 10 CHECK (low_stock_threshold >= 0),
  near_expiry_days integer NOT NULL DEFAULT 90 CHECK (near_expiry_days BETWEEN 1 AND 365),
  allow_negative_stock boolean NOT NULL DEFAULT false,
  allow_credit_sales boolean NOT NULL DEFAULT false,
  max_operator_discount_percent numeric(5, 2) NOT NULL DEFAULT 5 CHECK (max_operator_discount_percent BETWEEN 0 AND 100),
  max_pharmacist_discount_percent numeric(5, 2) NOT NULL DEFAULT 100 CHECK (max_pharmacist_discount_percent BETWEEN 0 AND 100),
  invoice_footer text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.user_profiles (
  id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  full_name text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.pharmacy_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('owner', 'pharmacist', 'billing_operator')),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, user_id)
);

CREATE TABLE public.medicine_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
  description text NOT NULL DEFAULT '',
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, name)
);

CREATE TABLE public.medicines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  category_id uuid REFERENCES public.medicine_categories (id) ON DELETE SET NULL,
  medicine_code text NOT NULL CHECK (char_length(medicine_code) BETWEEN 1 AND 40),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  generic_name text NOT NULL DEFAULT '',
  brand_name text NOT NULL DEFAULT '',
  manufacturer text NOT NULL DEFAULT '',
  composition text NOT NULL DEFAULT '',
  strength text NOT NULL DEFAULT '',
  dosage_form text NOT NULL DEFAULT 'tablet',
  pack_size text NOT NULL DEFAULT '',
  unit_of_measure text NOT NULL DEFAULT 'pack',
  hsn_code text NOT NULL DEFAULT '',
  gst_rate numeric(5, 2) NOT NULL DEFAULT 0 CHECK (gst_rate >= 0 AND gst_rate <= 100),
  tax_classification text NOT NULL DEFAULT 'taxable' CHECK (tax_classification IN ('taxable', 'exempt', 'nil', 'zero')),
  barcode text,
  schedule_category text NOT NULL DEFAULT 'OTC' CHECK (schedule_category IN ('OTC', 'H', 'H1', 'X', 'G')),
  prescription_required boolean NOT NULL DEFAULT false,
  mrp numeric(14, 2) NOT NULL DEFAULT 0 CHECK (mrp >= 0),
  default_selling_price numeric(14, 2) NOT NULL DEFAULT 0 CHECK (default_selling_price >= 0),
  reorder_level numeric(14, 3) NOT NULL DEFAULT 0 CHECK (reorder_level >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, medicine_code)
);

CREATE UNIQUE INDEX medicines_barcode_unique
  ON public.medicines (pharmacy_id, barcode)
  WHERE barcode IS NOT NULL AND barcode <> '';

CREATE INDEX medicines_search_idx ON public.medicines USING gin (
  (name || ' ' || generic_name || ' ' || brand_name || ' ' || manufacturer) gin_trgm_ops
);
CREATE INDEX medicines_pharmacy_name_idx ON public.medicines (pharmacy_id, name);

CREATE TABLE public.suppliers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
  contact_person text NOT NULL DEFAULT '',
  phone text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  address text NOT NULL DEFAULT '',
  state text NOT NULL DEFAULT '',
  state_code char(2),
  gstin text,
  drug_licence text NOT NULL DEFAULT '',
  payment_terms text NOT NULL DEFAULT '',
  opening_balance numeric(14, 2) NOT NULL DEFAULT 0,
  current_balance numeric(14, 2) NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX suppliers_pharmacy_idx ON public.suppliers (pharmacy_id, name);

CREATE TABLE public.customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
  phone text NOT NULL DEFAULT '',
  address text NOT NULL DEFAULT '',
  gstin text,
  state_code char(2),
  credit_limit numeric(14, 2) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
  opening_balance numeric(14, 2) NOT NULL DEFAULT 0 CHECK (opening_balance >= 0),
  outstanding_balance numeric(14, 2) NOT NULL DEFAULT 0 CHECK (outstanding_balance >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX customers_phone_unique
  ON public.customers (pharmacy_id, phone)
  WHERE phone <> '';
CREATE INDEX customers_pharmacy_idx ON public.customers (pharmacy_id, name);

CREATE TABLE public.invoice_counters (
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  financial_year text NOT NULL,
  doc_type text NOT NULL,
  last_number integer NOT NULL DEFAULT 0 CHECK (last_number >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (pharmacy_id, financial_year, doc_type)
);

CREATE TABLE public.supplier_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  supplier_id uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE RESTRICT,
  supplier_invoice_number text NOT NULL CHECK (char_length(supplier_invoice_number) BETWEEN 1 AND 60),
  invoice_date date NOT NULL,
  status text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted')),
  payment_status text NOT NULL CHECK (payment_status IN ('unpaid', 'partial', 'paid')),
  supply_type text NOT NULL CHECK (supply_type IN ('intra', 'inter')),
  subtotal numeric(14, 2) NOT NULL CHECK (subtotal >= 0),
  discount_amount numeric(14, 2) NOT NULL CHECK (discount_amount >= 0),
  taxable_value numeric(14, 2) NOT NULL CHECK (taxable_value >= 0),
  cgst numeric(14, 2) NOT NULL DEFAULT 0 CHECK (cgst >= 0),
  sgst numeric(14, 2) NOT NULL DEFAULT 0 CHECK (sgst >= 0),
  igst numeric(14, 2) NOT NULL DEFAULT 0 CHECK (igst >= 0),
  grand_total numeric(14, 2) NOT NULL CHECK (grand_total >= 0),
  amount_paid numeric(14, 2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
  duplicate_override boolean NOT NULL DEFAULT false,
  idempotency_key text NOT NULL,
  notes text NOT NULL DEFAULT '',
  posted_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, idempotency_key)
);

CREATE UNIQUE INDEX supplier_invoice_number_unique
  ON public.supplier_invoices (pharmacy_id, supplier_id, supplier_invoice_number)
  WHERE duplicate_override = false;
CREATE INDEX supplier_invoices_date_idx ON public.supplier_invoices (pharmacy_id, invoice_date DESC);

CREATE TABLE public.inventory_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  medicine_id uuid NOT NULL REFERENCES public.medicines (id) ON DELETE RESTRICT,
  batch_number text NOT NULL CHECK (char_length(batch_number) BETWEEN 1 AND 60),
  manufacturer text NOT NULL DEFAULT '',
  supplier_id uuid REFERENCES public.suppliers (id) ON DELETE SET NULL,
  mfg_date date,
  expiry_date date NOT NULL,
  purchase_price numeric(14, 4) NOT NULL DEFAULT 0 CHECK (purchase_price >= 0),
  unit_cost numeric(14, 4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  mrp numeric(14, 2) NOT NULL CHECK (mrp >= 0),
  selling_price numeric(14, 2) NOT NULL CHECK (selling_price >= 0),
  qty_received numeric(14, 3) NOT NULL DEFAULT 0 CHECK (qty_received >= 0),
  free_qty numeric(14, 3) NOT NULL DEFAULT 0 CHECK (free_qty >= 0),
  qty_available numeric(14, 3) NOT NULL DEFAULT 0,
  qty_quarantine numeric(14, 3) NOT NULL DEFAULT 0 CHECK (qty_quarantine >= 0),
  pack_to_unit numeric(14, 3) NOT NULL DEFAULT 1 CHECK (pack_to_unit > 0),
  gst_rate numeric(5, 2) NOT NULL DEFAULT 0 CHECK (gst_rate >= 0 AND gst_rate <= 100),
  purchase_discount numeric(14, 2) NOT NULL DEFAULT 0 CHECK (purchase_discount >= 0),
  shelf text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'quarantined', 'recalled', 'blocked', 'depleted', 'written_off')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (mfg_date IS NULL OR mfg_date <= expiry_date),
  UNIQUE (pharmacy_id, medicine_id, batch_number, expiry_date)
);

CREATE INDEX batches_expiry_idx ON public.inventory_batches (pharmacy_id, expiry_date);
CREATE INDEX batches_medicine_idx ON public.inventory_batches (pharmacy_id, medicine_id, expiry_date);

CREATE TABLE public.purchase_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices (id) ON DELETE RESTRICT,
  medicine_id uuid NOT NULL REFERENCES public.medicines (id) ON DELETE RESTRICT,
  batch_id uuid REFERENCES public.inventory_batches (id) ON DELETE RESTRICT,
  medicine_name text NOT NULL,
  batch_number text NOT NULL,
  expiry_date date NOT NULL,
  hsn_code text NOT NULL DEFAULT '',
  qty numeric(14, 3) NOT NULL CHECK (qty > 0),
  free_qty numeric(14, 3) NOT NULL DEFAULT 0 CHECK (free_qty >= 0),
  purchase_rate numeric(14, 4) NOT NULL CHECK (purchase_rate >= 0),
  mrp numeric(14, 2) NOT NULL CHECK (mrp >= 0),
  selling_price numeric(14, 2) NOT NULL CHECK (selling_price >= 0),
  discount_amount numeric(14, 2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  gst_rate numeric(5, 2) NOT NULL CHECK (gst_rate >= 0),
  taxable_value numeric(14, 2) NOT NULL CHECK (taxable_value >= 0),
  cgst numeric(14, 2) NOT NULL DEFAULT 0,
  sgst numeric(14, 2) NOT NULL DEFAULT 0,
  igst numeric(14, 2) NOT NULL DEFAULT 0,
  line_total numeric(14, 2) NOT NULL CHECK (line_total >= 0),
  unit_cost numeric(14, 4) NOT NULL CHECK (unit_cost >= 0),
  pack_to_unit numeric(14, 3) NOT NULL DEFAULT 1 CHECK (pack_to_unit > 0),
  shelf text NOT NULL DEFAULT '',
  returned_qty numeric(14, 3) NOT NULL DEFAULT 0 CHECK (returned_qty >= 0),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX purchase_items_invoice_idx ON public.purchase_items (supplier_invoice_id);

CREATE TABLE public.sales_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  invoice_number text NOT NULL,
  financial_year text NOT NULL,
  business_date date NOT NULL,
  invoice_kind text NOT NULL CHECK (invoice_kind IN ('tax_invoice', 'retail_bill')),
  customer_id uuid REFERENCES public.customers (id) ON DELETE SET NULL,
  customer_name_snapshot text NOT NULL DEFAULT 'Walk-in',
  customer_phone_snapshot text NOT NULL DEFAULT '',
  customer_gstin_snapshot text NOT NULL DEFAULT '',
  seller_name text NOT NULL,
  seller_address text NOT NULL DEFAULT '',
  seller_phone text NOT NULL DEFAULT '',
  seller_gstin text NOT NULL DEFAULT '',
  seller_drug_licences text NOT NULL DEFAULT '',
  seller_state text NOT NULL DEFAULT '',
  seller_state_code char(2) NOT NULL,
  place_of_supply_code char(2) NOT NULL,
  pricing_mode text NOT NULL CHECK (pricing_mode IN ('inclusive', 'exclusive')),
  supply_type text NOT NULL CHECK (supply_type IN ('intra', 'inter')),
  subtotal numeric(14, 2) NOT NULL,
  discount_amount numeric(14, 2) NOT NULL,
  taxable_value numeric(14, 2) NOT NULL,
  cgst numeric(14, 2) NOT NULL,
  sgst numeric(14, 2) NOT NULL,
  igst numeric(14, 2) NOT NULL,
  round_off numeric(14, 2) NOT NULL DEFAULT 0,
  grand_total numeric(14, 2) NOT NULL,
  amount_paid numeric(14, 2) NOT NULL,
  balance_due numeric(14, 2) NOT NULL,
  amount_tendered numeric(14, 2) NOT NULL DEFAULT 0,
  change_due numeric(14, 2) NOT NULL DEFAULT 0,
  payment_status text NOT NULL CHECK (payment_status IN ('paid', 'partial', 'credit')),
  return_status text NOT NULL DEFAULT 'none' CHECK (return_status IN ('none', 'partial', 'full')),
  prescription_note text NOT NULL DEFAULT '',
  notes text NOT NULL DEFAULT '',
  footer_snapshot text NOT NULL DEFAULT '',
  idempotency_key text NOT NULL,
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, invoice_number),
  UNIQUE (pharmacy_id, idempotency_key)
);

CREATE INDEX sales_invoices_date_idx ON public.sales_invoices (pharmacy_id, business_date DESC);
CREATE INDEX sales_invoices_customer_idx ON public.sales_invoices (pharmacy_id, customer_id);

CREATE TABLE public.sales_invoice_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  invoice_id uuid NOT NULL REFERENCES public.sales_invoices (id) ON DELETE RESTRICT,
  line_no integer NOT NULL CHECK (line_no > 0),
  medicine_id uuid NOT NULL REFERENCES public.medicines (id) ON DELETE RESTRICT,
  batch_id uuid NOT NULL REFERENCES public.inventory_batches (id) ON DELETE RESTRICT,
  medicine_name text NOT NULL,
  generic_name text NOT NULL DEFAULT '',
  strength text NOT NULL DEFAULT '',
  dosage_form text NOT NULL DEFAULT '',
  pack_size text NOT NULL DEFAULT '',
  hsn_code text NOT NULL DEFAULT '',
  batch_number text NOT NULL,
  expiry_date date NOT NULL,
  schedule_category text NOT NULL DEFAULT 'OTC',
  sold_unit text NOT NULL CHECK (sold_unit IN ('pack', 'unit')),
  quantity numeric(14, 3) NOT NULL CHECK (quantity > 0),
  pack_to_unit numeric(14, 3) NOT NULL CHECK (pack_to_unit > 0),
  quantity_in_packs numeric(14, 3) NOT NULL CHECK (quantity_in_packs > 0),
  mrp numeric(14, 2) NOT NULL,
  unit_price numeric(14, 4) NOT NULL,
  unit_cost numeric(14, 4) NOT NULL,
  discount_amount numeric(14, 2) NOT NULL DEFAULT 0,
  bill_discount_share numeric(14, 2) NOT NULL DEFAULT 0,
  gst_rate numeric(5, 2) NOT NULL,
  tax_classification text NOT NULL,
  taxable_value numeric(14, 2) NOT NULL,
  cgst numeric(14, 2) NOT NULL DEFAULT 0,
  sgst numeric(14, 2) NOT NULL DEFAULT 0,
  igst numeric(14, 2) NOT NULL DEFAULT 0,
  line_total numeric(14, 2) NOT NULL,
  returned_qty numeric(14, 3) NOT NULL DEFAULT 0 CHECK (returned_qty >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (invoice_id, line_no)
);

CREATE INDEX sales_items_medicine_idx ON public.sales_invoice_items (pharmacy_id, medicine_id);
CREATE INDEX sales_items_batch_idx ON public.sales_invoice_items (batch_id);

CREATE TABLE public.sales_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  invoice_id uuid NOT NULL REFERENCES public.sales_invoices (id) ON DELETE RESTRICT,
  method text NOT NULL CHECK (method IN ('cash', 'upi', 'card', 'bank_transfer', 'credit')),
  amount numeric(14, 2) NOT NULL CHECK (amount > 0),
  reference text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX sales_payments_invoice_idx ON public.sales_payments (invoice_id);
CREATE INDEX sales_payments_method_idx ON public.sales_payments (pharmacy_id, method, created_at);

CREATE TABLE public.sales_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.sales_returns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  credit_note_number text NOT NULL,
  original_invoice_id uuid NOT NULL REFERENCES public.sales_invoices (id) ON DELETE RESTRICT,
  customer_id uuid REFERENCES public.customers (id) ON DELETE SET NULL,
  business_date date NOT NULL,
  reason text NOT NULL CHECK (char_length(reason) >= 3),
  taxable_value numeric(14, 2) NOT NULL,
  cgst numeric(14, 2) NOT NULL DEFAULT 0,
  sgst numeric(14, 2) NOT NULL DEFAULT 0,
  igst numeric(14, 2) NOT NULL DEFAULT 0,
  grand_total numeric(14, 2) NOT NULL,
  refund_amount numeric(14, 2) NOT NULL DEFAULT 0,
  balance_credit numeric(14, 2) NOT NULL DEFAULT 0,
  idempotency_key text NOT NULL,
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, credit_note_number),
  UNIQUE (pharmacy_id, idempotency_key)
);

CREATE INDEX sales_returns_invoice_idx ON public.sales_returns (original_invoice_id);

CREATE TABLE public.sales_return_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  return_id uuid NOT NULL REFERENCES public.sales_returns (id) ON DELETE RESTRICT,
  invoice_item_id uuid NOT NULL REFERENCES public.sales_invoice_items (id) ON DELETE RESTRICT,
  batch_id uuid NOT NULL REFERENCES public.inventory_batches (id) ON DELETE RESTRICT,
  quantity numeric(14, 3) NOT NULL CHECK (quantity > 0),
  quantity_in_packs numeric(14, 3) NOT NULL CHECK (quantity_in_packs > 0),
  disposition text NOT NULL CHECK (disposition IN ('resale', 'quarantine')),
  taxable_value numeric(14, 2) NOT NULL,
  gst_amount numeric(14, 2) NOT NULL,
  cgst numeric(14, 2) NOT NULL DEFAULT 0,
  sgst numeric(14, 2) NOT NULL DEFAULT 0,
  igst numeric(14, 2) NOT NULL DEFAULT 0,
  line_total numeric(14, 2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.sales_refunds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  return_id uuid NOT NULL REFERENCES public.sales_returns (id) ON DELETE RESTRICT,
  method text NOT NULL CHECK (method IN ('cash', 'upi', 'card', 'bank_transfer')),
  amount numeric(14, 2) NOT NULL CHECK (amount > 0),
  reference text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.supplier_returns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  debit_note_number text NOT NULL,
  supplier_id uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE RESTRICT,
  supplier_invoice_id uuid NOT NULL REFERENCES public.supplier_invoices (id) ON DELETE RESTRICT,
  business_date date NOT NULL,
  reason text NOT NULL CHECK (char_length(reason) >= 3),
  taxable_value numeric(14, 2) NOT NULL,
  cgst numeric(14, 2) NOT NULL DEFAULT 0,
  sgst numeric(14, 2) NOT NULL DEFAULT 0,
  igst numeric(14, 2) NOT NULL DEFAULT 0,
  grand_total numeric(14, 2) NOT NULL,
  idempotency_key text NOT NULL,
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, debit_note_number),
  UNIQUE (pharmacy_id, idempotency_key)
);

CREATE TABLE public.supplier_return_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  return_id uuid NOT NULL REFERENCES public.supplier_returns (id) ON DELETE RESTRICT,
  purchase_item_id uuid NOT NULL REFERENCES public.purchase_items (id) ON DELETE RESTRICT,
  batch_id uuid NOT NULL REFERENCES public.inventory_batches (id) ON DELETE RESTRICT,
  quantity numeric(14, 3) NOT NULL CHECK (quantity > 0),
  taxable_value numeric(14, 2) NOT NULL,
  cgst numeric(14, 2) NOT NULL DEFAULT 0,
  sgst numeric(14, 2) NOT NULL DEFAULT 0,
  igst numeric(14, 2) NOT NULL DEFAULT 0,
  gst_amount numeric(14, 2) NOT NULL,
  line_total numeric(14, 2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.customer_ledger_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  customer_id uuid NOT NULL REFERENCES public.customers (id) ON DELETE RESTRICT,
  entry_type text NOT NULL CHECK (entry_type IN ('opening', 'sale', 'receipt', 'return', 'adjustment')),
  debit numeric(14, 2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit numeric(14, 2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  reference_type text,
  reference_id uuid,
  notes text NOT NULL DEFAULT '',
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX customer_ledger_idx ON public.customer_ledger_entries (customer_id, created_at);

CREATE TABLE public.supplier_ledger_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  supplier_id uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE RESTRICT,
  entry_type text NOT NULL CHECK (entry_type IN ('opening', 'purchase', 'payment', 'return', 'adjustment')),
  debit numeric(14, 2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit numeric(14, 2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  reference_type text,
  reference_id uuid,
  notes text NOT NULL DEFAULT '',
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX supplier_ledger_idx ON public.supplier_ledger_entries (supplier_id, created_at);

CREATE TABLE public.stock_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  batch_id uuid NOT NULL REFERENCES public.inventory_batches (id) ON DELETE RESTRICT,
  medicine_id uuid NOT NULL REFERENCES public.medicines (id) ON DELETE RESTRICT,
  movement_type text NOT NULL CHECK (movement_type IN (
    'purchase', 'sale', 'sale_return', 'sale_return_quarantine', 'purchase_return', 'adjustment', 'write_off', 'opening'
  )),
  quantity_delta numeric(14, 3) NOT NULL,
  quarantine_delta numeric(14, 3) NOT NULL DEFAULT 0,
  quantity_after numeric(14, 3) NOT NULL,
  reference_type text,
  reference_id uuid,
  reason text NOT NULL DEFAULT '',
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX stock_movements_batch_idx ON public.stock_movements (batch_id, created_at);
CREATE INDEX stock_movements_medicine_idx ON public.stock_movements (pharmacy_id, medicine_id, created_at DESC);

CREATE TABLE public.stock_adjustments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  adjustment_number text NOT NULL,
  batch_id uuid NOT NULL REFERENCES public.inventory_batches (id) ON DELETE RESTRICT,
  medicine_id uuid NOT NULL REFERENCES public.medicines (id) ON DELETE RESTRICT,
  adjustment_type text NOT NULL CHECK (adjustment_type IN ('correction', 'write_off', 'damage', 'quarantine', 'recall')),
  quantity_before numeric(14, 3) NOT NULL,
  quantity_delta numeric(14, 3) NOT NULL,
  quantity_after numeric(14, 3) NOT NULL,
  reason text NOT NULL CHECK (char_length(reason) >= 5),
  business_date date NOT NULL,
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, adjustment_number)
);

CREATE TABLE public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id uuid REFERENCES public.pharmacies (id) ON DELETE RESTRICT,
  actor_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX audit_logs_pharmacy_idx ON public.audit_logs (pharmacy_id, created_at DESC);

CREATE TABLE public.application_settings (
  pharmacy_id uuid NOT NULL REFERENCES public.pharmacies (id) ON DELETE CASCADE,
  key text NOT NULL,
  value jsonb NOT NULL,
  updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (pharmacy_id, key)
);

CREATE TABLE public.rate_limit_buckets (
  bucket_key text PRIMARY KEY,
  window_start timestamptz NOT NULL,
  hit_count integer NOT NULL
);

CREATE OR REPLACE VIEW public.batch_stock_reconciliation
WITH (security_invoker = true) AS
SELECT
  b.pharmacy_id,
  b.id AS batch_id,
  b.medicine_id,
  b.batch_number,
  b.qty_available,
  b.qty_quarantine,
  COALESCE(SUM(m.quantity_delta), 0) AS movement_qty,
  COALESCE(SUM(m.quarantine_delta), 0) AS movement_quarantine,
  (b.qty_available = COALESCE(SUM(m.quantity_delta), 0)
    AND b.qty_quarantine = COALESCE(SUM(m.quarantine_delta), 0)) AS reconciled
FROM public.inventory_batches b
LEFT JOIN public.stock_movements m ON m.batch_id = b.id
GROUP BY b.id;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_profiles (id, full_name, email)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data ->> 'full_name', ''),
    COALESCE(NEW.email, '')
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE TRIGGER pharmacies_updated BEFORE UPDATE ON public.pharmacies
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER profiles_updated BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER memberships_updated BEFORE UPDATE ON public.pharmacy_memberships
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER categories_updated BEFORE UPDATE ON public.medicine_categories
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER medicines_updated BEFORE UPDATE ON public.medicines
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER suppliers_updated BEFORE UPDATE ON public.suppliers
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER customers_updated BEFORE UPDATE ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER batches_updated BEFORE UPDATE ON public.inventory_batches
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER drafts_updated BEFORE UPDATE ON public.sales_drafts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER settings_updated BEFORE UPDATE ON public.application_settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
