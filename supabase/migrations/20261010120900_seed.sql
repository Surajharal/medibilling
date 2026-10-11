-- Explicit development seed. Callable only with the service-role key.

CREATE OR REPLACE FUNCTION public.seed_demo(p_pharmacy uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_category uuid;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'not_authorized';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pharmacies WHERE id = p_pharmacy) THEN
    RAISE EXCEPTION 'pharmacy_not_found';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.application_settings
    WHERE pharmacy_id = p_pharmacy AND key = 'demo_seeded'
  ) THEN
    RETURN jsonb_build_object('status', 'already_seeded');
  END IF;

  INSERT INTO public.medicine_categories (pharmacy_id, name, description)
  VALUES (p_pharmacy, 'General', 'Demo category')
  ON CONFLICT (pharmacy_id, name) DO UPDATE SET description = EXCLUDED.description
  RETURNING id INTO v_category;

  INSERT INTO public.medicines (
    pharmacy_id, category_id, medicine_code, name, generic_name, brand_name, manufacturer,
    strength, dosage_form, pack_size, hsn_code, gst_rate, mrp, default_selling_price, reorder_level
  ) VALUES
    (p_pharmacy, v_category, 'MED-DEMO-001', 'Paracetamol 500 mg Tablet', 'Paracetamol', 'Crocin', 'Demo Labs', '500 mg', 'tablet', '10 tablets', '3004', 5, 25, 22, 5),
    (p_pharmacy, v_category, 'MED-DEMO-002', 'Paracetamol 650 mg Tablet', 'Paracetamol', 'Dolo', 'Demo Labs', '650 mg', 'tablet', '15 tablets', '3004', 5, 40, 36, 5),
    (p_pharmacy, v_category, 'MED-DEMO-003', 'ORS Powder', 'Oral rehydration salts', 'Electral', 'Demo Labs', '21.8 g', 'sachet', '1 sachet', '3004', 5, 22, 20, 10)
  ON CONFLICT (pharmacy_id, medicine_code) DO NOTHING;

  INSERT INTO public.suppliers (pharmacy_id, name, contact_person, phone, state, state_code, payment_terms)
  SELECT p_pharmacy, 'Demo Wholesale', 'Accounts', '9999999999', state, state_code, '30 days'
  FROM public.pharmacies WHERE id = p_pharmacy
    AND NOT EXISTS (SELECT 1 FROM public.suppliers WHERE pharmacy_id = p_pharmacy AND name = 'Demo Wholesale');

  INSERT INTO public.customers (pharmacy_id, name, phone, credit_limit)
  SELECT p_pharmacy, 'Walk-in demo customer', '9888888888', 0
  WHERE NOT EXISTS (SELECT 1 FROM public.customers WHERE pharmacy_id = p_pharmacy AND name = 'Walk-in demo customer');

  INSERT INTO public.application_settings (pharmacy_id, key, value)
  VALUES (p_pharmacy, 'demo_seeded', jsonb_build_object('at', now()))
  ON CONFLICT (pharmacy_id, key) DO NOTHING;

  RETURN jsonb_build_object('status', 'seeded');
END;
$$;

REVOKE ALL ON FUNCTION public.seed_demo(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.seed_demo(uuid) TO service_role;
