# MediBilling

MediBilling is a pharmacy billing and inventory application for an Indian retail medical store. It covers medicines, batch stock, GST billing, purchases, customers, returns, expiry alerts, and reports. Posted invoices, stock movements, and tax amounts are stored in PostgreSQL and are not recalculated from later master-data edits.

## What you need to do first

The application cannot create a Supabase project or a Vercel account for you. Complete these steps, then run the app.

1. Create a project at [supabase.com](https://supabase.com).
2. In the Supabase SQL editor, run every file in `supabase/migrations` in filename order:
   - `20261010120000_schema.sql`
   - `20261010120100_functions_core.sql`
   - `20261010120200_sales.sql`
   - `20261010120300_post_sale.sql`
   - `20261010120400_purchases.sql`
   - `20261010120500_returns.sql`
   - `20261010120600_dashboard.sql`
   - `20261010120700_reports.sql`
   - `20261010120800_rls.sql`
   - `20261010120900_seed.sql`
3. In Supabase Auth, enable email and password. Add `http://localhost:3000/auth/callback` and your production URL plus `/auth/callback` to the redirect allow list.
4. Copy `.env.example` to `.env.local`. Fill in the project URL, the publishable key, the service-role key, and a long random `BOOTSTRAP_SECRET`. The service-role key must never use the `NEXT_PUBLIC_` prefix.
5. Install Node.js 22 or newer, then install and start the app:

```powershell
npm install
npm run dev
```

6. Open `http://localhost:3000/setup`, enter the bootstrap secret, and create the first owner. Sign in at `/login`. Add pharmacists and billing operators from Settings.
7. Optional demo catalogue, only on a development store: set `ALLOW_DEMO_SEED=1` and run `npm run seed:demo`. This adds three sample medicines, one supplier, and one customer. It does not post invoices.

## Local checks

```powershell
npm run typecheck
npm test
npm run build
```

## GST and stock rules

- Each medicine has its own GST rate. Intra-state supplies split GST into CGST and SGST. A customer GSTIN from another state uses IGST.
- Inclusive mode removes GST from the entered price. Exclusive mode adds GST after discounts. Amounts round half-up to the paise. A bill discount is shared across lines, and the last line takes the remainder.
- The server recalculates every posted bill. Invoice lines store the description, HSN, rate, prices, and tax amounts from that moment.
- A tax invoice is issued only when the pharmacy is marked GST registered and has a 15-character GSTIN. Otherwise the printout is a retail bill.
- Invoice numbers are `{prefix}/{financial year}/{sequence}` and are allocated inside the posting transaction. The default financial year starts in April.
- Stock is held by batch. Billing prefers the earliest eligible expiry. Expired, quarantined, recalled, and blocked batches cannot be sold. A medicine is not treated as expired when only one of its batches has expired.
- Expiry dates are date-only. The expiry date itself is still saleable in the pharmacy time zone, which defaults to Asia/Kolkata.
- Estimated gross profit is taxable value minus the batch unit cost of the quantity sold. Free quantity is included in that unit cost. This is not net profit.
- Schedule H, H1, X, and G lines can be sold only by a pharmacist or owner. The application does not recommend medicines or substitute one product for another.

## GitHub

```powershell
git init
git add .
git commit -m "Add MediBilling pharmacy application"
git branch -M main
git remote add origin https://github.com/YOUR_ACCOUNT/medibilling.git
git push -u origin main
```

Do not commit `.env.local`.

## Vercel

1. Import the GitHub repository in Vercel.
2. Set the same environment variables as `.env.local`, using the production app URL for `NEXT_PUBLIC_APP_URL`.
3. Add the production `/auth/callback` URL in Supabase Auth.
4. Deploy. After the first successful deploy, remove or rotate `BOOTSTRAP_SECRET` if the owner account already exists.
5. Back up the Supabase database from the Supabase dashboard. Point-in-time recovery depends on the Supabase plan.

Apply later SQL files in the Supabase SQL editor before using the new application version. There is no long-running job inside Vercel; expiry and low-stock figures are calculated when a page or report is opened.

## Smoke test

- Sign in, sign out, and request a password reset.
- Confirm a billing operator cannot open Settings or Audit.
- Add a medicine, a supplier, and a purchase with batch and expiry. Confirm stock increases.
- Bill that batch with cash, then reprint the invoice and refresh the page. The invoice number and amounts stay the same.
- Try to sell an expired batch and confirm the sale is refused.
- Return part of the bill to saleable stock and confirm the batch quantity increases.
- Return another quantity as quarantine and confirm it does not become saleable.
- Open the dashboard and the GST summary for the same day and confirm the totals match the posted bill.
- Export the medicine CSV.

## Roles

Owners configure the store, tax display, invoice prefix, users, and can view profit and the audit log. Pharmacists manage medicines, purchases, stock, returns, and reports. Billing operators create bills, take payments, and print invoices. They cannot change GST settings, delete a posted invoice, or change permissions. Those limits are enforced in the database, not only in the menu.
