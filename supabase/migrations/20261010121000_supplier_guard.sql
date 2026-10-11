-- Supplier inserts were rejected because the shared balance guard read credit_limit,
-- a column that exists only on customers.

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
