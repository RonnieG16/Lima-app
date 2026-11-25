# Lima: farmer-to-buyer marketplace (Supabase backend)

Group 5, MGT3151. Prototype with fictitious data and **Pesapal sandbox payments** held in an escrow workflow. No real card, PIN, OTP or ID data is stored by Lima: payment details are entered only on Pesapal's own hosted checkout page.

## Layout
- `web/` static front end (no build step), installable as a PWA (`manifest.webmanifest`, `sw.js`, icons). `web/config.js` holds your Supabase URL and anon key.
- `supabase/schema.sql` tables, Row Level Security, escrow functions, settings, feedback, SMS queue, realtime, storage bucket, price seed.
- `supabase/functions/pay-start/` Edge Function that creates a Pesapal payment for one order and returns the Pesapal checkout link.
- `supabase/functions/pay-webhook/` Edge Function that receives Pesapal's payment notification (IPN), checks the real status with Pesapal, and only then moves the order into escrow.
- `supabase/functions/send-sms/` optional Edge Function that sends queued SMS through Africa's Talking (untested, needs an account).
- `supabase/tests/escrow_test.mjs` runs the schema in an in-memory Postgres and checks the workflow and access control.
- `docs/LIMA_DESIGNS.drawio` your five draw.io pages plus a new **Architecture** page (trust boundaries, protocols, deployment).

## Setup (about 10 minutes, plus Pesapal in the next section)
1. Create a project at supabase.com.
2. **Authentication > Providers > Email**: turn off "Confirm email" (demo only, so test accounts can sign in at once).
3. **SQL Editor**: paste all of `supabase/schema.sql` and run it once.
4. **Project Settings > API**: copy the Project URL and anon key into `web/config.js`.
5. Run locally: `cd web && npx serve` (or `python3 -m http.server`) and open the printed address. Or deploy the `web/` folder to Netlify, Vercel or GitHub Pages.

## Payments with Pesapal (sandbox)
Lima uses Pesapal API 3.0. The browser never marks an order as paid: only the server-side functions do, after Pesapal confirms the payment.

**One-time setup**
1. Get Pesapal **sandbox** credentials (a Consumer Key and Consumer Secret) from Pesapal's developer pages. Sandbox runs at `https://cybqa.pesapal.com/pesapalv3`; live runs at `https://pay.pesapal.com/v3`. Use sandbox only for the prototype.
2. In Supabase, open **Edge Functions > Secrets** and add `PESAPAL_CONSUMER_KEY`, `PESAPAL_CONSUMER_SECRET` and `PESAPAL_IPN_ID` (step 4). Never put these in `web/config.js` or in GitHub.
3. Deploy the two functions `pay-start` and `pay-webhook`. Turn **off** "Verify JWT" for `pay-webhook`, because Pesapal calls it without a Supabase login. It is protected by checking every notification with Pesapal itself.
4. Register the IPN once with Pesapal's `RegisterIPN`, using the address `https://YOUR-PROJECT-REF.supabase.co/functions/v1/pay-webhook`. Pesapal returns an IPN id; save it as the `PESAPAL_IPN_ID` secret.
5. Run the SQL that adds the payment columns to `orders` (payment status, payment reference, phone) and the service-only function that confirms a payment. It reuses the same escrow logic as `pay_order`.

**How a payment flows**
1. Buyer taps **Pay with mobile money** on an order (or **Pay all**, which pays the orders one after another).
2. `pay-start` checks the order belongs to the buyer and is unpaid, works out the amount on the server (kg x price + delivery fee), requests a Pesapal token, and submits the order to Pesapal. It returns Pesapal's hosted checkout link.
3. The buyer opens the link and pays with mobile money (MTN or Airtel) or card on Pesapal's page, then returns to Lima.
4. Pesapal sends a notification to `pay-webhook`. The function asks Pesapal for the transaction status, checks the amount and the order reference, and if the payment is complete, runs the escrow logic: the order moves to stage 2 "Paid (escrow)".
5. Lima's payment window watches the order and shows the receipt as soon as it is in escrow.


## Admin customization, field-agent approval and media limits

After the existing Lima database schema has been installed, run
`supabase/migrations/20261125_lima_customization_and_agent_approval.sql` in the Supabase SQL Editor.

- New village-agent profiles are marked `pending`. The admin receives an inbox notification for new agent accounts, orders, disputes and feedback, and can approve an agent in **Admin > Users**. Pending agents see an approval screen until an admin approves them.
- Admins can upload or reset the header logo from **Admin > Site and look**. The in-app header logo and browser favicon use the uploaded image. The installed PWA launcher icon still uses the static `icon-192.png` / `icon-512.png` assets; changing those requires replacing the assets and reinstalling/updating the home-screen shortcut.
- Site and look supports image uploads up to **10 MB**. Weather background videos support MP4, WebM or MOV up to **30 MB**. The migration updates the existing `photos` Storage bucket cap to 30 MB; the app applies the stricter per-file limits.
- Weather forecasts continue to use **Open-Meteo**. Admins can change the weather background image or upload/remove a muted, looping background video.
- Mobile product cards use content-based height on narrow screens, with entrance animations that respect the device's reduced-motion preference.
- Admin listing removal preserves order history: listings linked to orders are hidden by setting their remaining quantity to zero rather than deleting a referenced row. This prevents the `orders_listing_id_fkey` error shown in the admin screenshot.

The source ZIP provided for this update did not contain the original `supabase/schema.sql` or Edge Function source folders mentioned above. This update includes the new migration and front-end changes; apply them to the already configured Supabase project. The deployed Pesapal `pay-start` and `pay-webhook` functions must be the Pesapal versions described in the payment section.

After updating the files, redeploy the **contents of `web/`** to Netlify. The service-worker cache version was bumped so installed PWAs fetch the updated app shell on their next refresh.

## Install on a phone (PWA)
Deploy `web/` to an HTTPS host (Netlify, Vercel or GitHub Pages). Open the link in Chrome on Android and choose **Add to Home screen** (on iPhone: Safari > Share > Add to Home Screen). Lima then opens full-screen like an app. Service workers need HTTPS, so this does not work from a plain `http://` address (`localhost` is fine for testing). Only the app shell is cached; orders and payments always go live to Supabase.

## Demo accounts
Register these in the app (password `Lima-demo-2026`; phone `0700000001`…; verification code is always `123456`):
`buyer@lima.test` (Buyer), `farmer@lima.test` (Farmer), `agent@lima.test` (Village agent), `rider@lima.test` (Rider), `admin@lima.test` (register as Buyer first).
Then promote the admin once in the SQL Editor (an admin can never be created from the sign-up form):
```sql
update profiles set role = 'admin' where user_id = (select id from auth.users where email = 'admin@lima.test');
```

## Demo walk-through (matches the flowchart page)
1. Farmer: Sell > publish maize. 2. Buyer: Market > search by district or distance > View & order. 3. Buyer: Orders > Pay with mobile money > complete the sandbox payment on Pesapal's page (escrow held once Pesapal confirms). 4. Farmer: Accept > Mark ready. 5. Rider: Collect > Mark delivered. 6. Buyer: Confirm (escrow released, fee 5%) > Rate.
Dispute path: Buyer reports a problem with a photo at step 5 or 6 > payment frozen > Admin: Refund buyer or Pay farmer.

## Traceability to the designs
| Design page | Where it lives |
|---|---|
| ERD (9 tables) | `schema.sql` tables of the same names |
| Flowchart / DFD 1 processes 1.0 to 6.0 | `viewAuth`, `viewMarket`/`viewSell`, `place_order` then `pay-start`/`pay-webhook` (payment), `farmer_step`/`rider_step`, `confirm_receipt`/`rate_order`, `report_problem`/`admin_decide` |
| Use case: roles and least privilege | RLS policies + role checks inside every function |
| Use case: View audit log | Admin screen reads `audit_log` (written by every state change) |
| Architecture | `docs/LIMA_DESIGNS.drawio`, page "Architecture" |

### Differences from the original ERD
The draw.io file now has an **ERD (as built)** page generated from `schema.sql` (16 tables, new ones in green). Keep it, or copy it over the original ERD page. Summary of the differences:
- IDs are `uuid` (Supabase standard), not `INT`. `USER` is `profiles`, linked to `auth.users`.
- Seven tables added: `cart_items`, `wishlist`, `notifications`, `messages`, `site_settings`, `feedback`, `sms_outbox`.
- Columns added: `listings.posted_by` (agent listing for a farmer), `listings.category/district/town/market/photo_url`, `orders.delivery_fee_ugx/delivered_at`, `orders` payment columns (payment status, Pesapal reference, phone), `payments.fee_ugx`, `disputes.reason`, `ratings.comment`, `profiles.region/market/phone_verified/sms_opt_in`.
- Order stage 1 to 7 plus an `orders.status` (open, completed, cancelled, disputed).

## Security controls (for the Phase 4 report)
Direct writes to orders, payments, deliveries, ratings, disputes and audit_log are revoked; only `SECURITY DEFINER` functions change them, and each checks the caller's role, ownership and current stage. Profiles hide phone numbers from other users (`public_profiles` view). Inputs are validated in the browser and by CHECK constraints. All output is HTML-escaped. Uploads are limited to images up to 10 MB; weather background video is limited to 30 MB.

Payment-specific controls:
- Pesapal keys live only in Supabase Edge Function secrets, never in the browser or the repository.
- The amount charged is calculated on the server from the order, so the browser cannot change it.
- The browser cannot mark an order as paid. `pay-webhook` does not trust the notification itself: it asks Pesapal for the transaction status and compares the amount and order reference before confirming escrow.
- The confirm-payment SQL function is callable only by the server (service role), not by signed-in users.
- Repeated notifications are harmless: an order already in escrow is not paid twice.
- Card and mobile money details are entered on Pesapal's hosted page, so Lima never handles them.

## Money rules (sandbox)
Order total = produce + flat delivery fee of UGX 3,000 for rider delivery (none for pickup). Lima's 5% platform fee comes out of the farmer's produce sale at release. The rider keeps 90% of the delivery fee, Lima 10%. Each farmer's produce is its own order with its own escrow, and so its own Pesapal payment; a cart with several listings creates several orders, and the **Pay all** button walks the buyer through paying them one after another.

## Screens by role
- **Everyone:** home (search, categories, price strip, fresh listings), market search (produce, category, district, town, distance, price range, sort), prices, inbox, profile, receipts, order chat, forgot password.
- **Buyer:** listing detail with reviews, cart and checkout, saved list, orders, pay, confirm, report problem, rate and review, order again.
- **Farmer:** sell, orders (accept, ready, handover), sales records with CSV export. **Agent:** sell for a farmer, orders. **Rider:** jobs (collect, deliver), earnings. **Admin:** disputes, prices, audit log.

## Auto-confirm after 48 hours
`auto_release_overdue()` releases escrow for orders delivered more than 48 hours ago with no confirmation or dispute. Enable the `pg_cron` extension (Dashboard > Database > Extensions) and run the `cron.schedule(...)` line shown above that function in `schema.sql`.

## Tests
`supabase/tests/escrow_test.mjs` (run `npm i @electric-sql/pglite` then `node supabase/tests/escrow_test.mjs`) covers the order and escrow flow, dispute refund, delivery fee totals, cart checkout, notifications, chat access, auto-release and access control. It does not call Pesapal. Use it as part of your test evidence, and record your own browser test cases (5 positive, 2 validation, 1 access-control) from the demo walk-through. Add a payment test case: pay one order in the Pesapal sandbox and confirm it moves to "Paid (escrow)" only after Pesapal's notification.

## Admin account and Google sign-in
- **Admin:** no admin exists until you make one, on purpose: a public sign-up form must never be able to create an admin. Register `admin@lima.test` as a Buyer, then run the one-line `update profiles set role = 'admin' ...` shown under Demo accounts. Sign out and in again.
- **Google sign-in:** the button is in the app, but it only works after you set Google up (about 10 minutes):
  1. Google Cloud Console > APIs & Services > Credentials > Create OAuth client ID (Web application). Add the authorised redirect URI `https://YOUR-PROJECT-REF.supabase.co/auth/v1/callback`.
  2. Supabase > Authentication > Providers > Google: switch on, paste the Client ID and Client Secret.
  3. Supabase > Authentication > URL Configuration: set Site URL to your hosted address, and add it (and `http://localhost:3000`) to Redirect URLs.
  New Google users land on a "Finish setting up" screen to choose buyer, farmer, village agent or rider, enter a phone and pick their town. Google users can never become admin through the app.
- **Location at sign-up:** the register, finish-setup and profile forms have "Use my location to fill the town". It picks the nearest of the sample towns; you can change it.

## Added in version 3
- **Weather and advice:** 5-day forecast for your town (Open-Meteo, no key) with simple rule-based tips per role (rain, heat, dry spell).
- **Location:** "Use my location" on the Market page finds the nearest listed town and measures distance from where you are. "Show map" plots matching listings by town on an OpenStreetMap map (needs internet).
- **Market filter:** listings now store a market, and search can filter by it.
- **Settings:** each user can turn on larger text, phone alerts and SMS copies. Admin can change delivery fee, platform fee, rider share, auto-confirm hours and a banner message, all validated in the database and written to the audit log.
- **Send feedback:** every user can send feedback; admin sees it and marks it seen or resolved.
- **Alerts:** new notifications appear instantly (Supabase Realtime) as a toast, and as a phone notification if allowed and the app is in the background.
- **SMS:** alerts are queued in `sms_outbox` for users who opt in. Deploy `supabase/functions/send-sms` (see its header) to actually send them.
- If you already ran an earlier schema, run the new `schema.sql` again: it uses `if not exists` and adds the new columns.

## Not built / known limits
- **Pesapal is sandbox only.** No live keys, so no real money moves. Going live needs a Pesapal business account approved for live payments, live keys, and the live base URL.
- **One payment per farmer order.** A cart with several farmers means several Pesapal payments, one after another. A single combined payment for the whole cart is not built.
- **Releasing money to farmers is simulated.** Pesapal collects the buyer's payment; the escrow release, platform fee and farmer or rider payouts are recorded in Lima's database only. Real payouts to farmers and riders are not built.
- **Refunds are recorded in Lima only.** An admin "Refund buyer" decision updates escrow in the database but does not send money back through Pesapal.
- **SMS** only works after you deploy the Edge Function and add Africa's Talking keys; **USSD** is not built (farmers without smartphones go through a village agent).
- **Map/GPS:** pins are per town (nine sample towns), not exact farm locations. Browsers only share GPS on HTTPS and with permission.
- Web push while the app is fully closed is not built; alerts show while Lima is open or in the background of the browser.
- Agents cannot see payment amounts (farmers only). Sales records are for farmers.
- Tested: the schema was written to be run by `escrow_test.mjs`, and the page script passes a JavaScript syntax check. **Not run in this environment:** the database tests (no network to install pglite), a live Supabase project, the Pesapal sandbox calls, the new screens in a browser, photo upload, the weather call, geolocation, the map, Realtime, SMS, and PWA install on a phone.


## Upgrade v2: new look, public browsing, admin dashboard

1. In the Supabase SQL Editor run `supabase/upgrade_v2.sql` once, after `schema.sql` (safe to run again).
   It lets visitors who are not signed in browse listings, ratings and prices, adds admin tools
   (`admin_stats`, `admin_set_role`, the home-page picture and headline settings) and turns on live updates.
2. Hard-refresh the app (Ctrl+Shift+R) so the new service worker loads.
3. Visitors can browse Home, Market, Prices and each listing without an account. Adding to cart or ordering asks them to sign in, then returns them to where they were.
4. Admin dashboard (`#/admin`): Overview numbers and a 7-day orders chart, Users (change roles), Listings (edit price and quantity, delete), Orders, Disputes, Prices, Site and look (home headline, background picture upload, fees, banner), Feedback and Audit log. It refreshes itself when orders or disputes change.
5. `supabase/tests/escrow_test.mjs` does not cover `upgrade_v2.sql` yet.

## Upgrade v3: theme, shop layout, pictures

1. Run `supabase/upgrade_v3.sql` once in the Supabase SQL Editor (after `upgrade_v2.sql`).
2. Light and dark theme: the moon/sun button in the header, saved per browser, works for guests too.
3. Market page: categories and filters on the left, all produce on the right, 24 at a time with "Show more".
4. Prices scroll in a ticker on Home and Prices (hover to pause). Price tiles lift on hover and show the update date.
5. Admin, Site and look: change the home headline, promo banner wording, and pictures for the home background, promo banner, price ticker, sign-in panel and each category. Produce without its own photo shows its category picture. Sample pictures are drawn in the app, so nothing to download.
