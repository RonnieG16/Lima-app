// Runs schema.sql in an in-process Postgres (pglite) and exercises the escrow workflow + access control.
// Usage: npm i @electric-sql/pglite && node supabase/tests/escrow_test.mjs
import {PGlite} from '@electric-sql/pglite';
import fs from 'fs';
const db = new PGlite();
await db.exec(`create role anon; create role authenticated; create schema auth; create schema storage;
create table auth.users(id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb, raw_app_meta_data jsonb);
create table storage.buckets(id text primary key, name text, public boolean);
create table storage.objects(id uuid, bucket_id text);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid',true),'')::uuid $$;
grant usage on schema auth, public to authenticated, anon;`);
await db.exec(fs.readFileSync(new URL('../schema.sql', import.meta.url),'utf8'));
await db.exec(`grant select, insert, update, delete on all tables in schema public to authenticated;
revoke insert, update, delete on orders, payments, deliveries, ratings, disputes, audit_log from authenticated;`);
const mk=async(role,n)=> (await db.query(`insert into auth.users(email,raw_user_meta_data) values ($1,$2) returning id`,[n+'@x',JSON.stringify({role,name:n+' user',phone_no:'0700000001'})])).rows[0].id;
const [F,B,R,A,X]=[await mk('farmer','f'),await mk('buyer','b'),await mk('rider','r'),await mk('admin','a'),await mk('buyer','b2')];
console.log('admin self-signup role =', (await db.query(`select role from profiles where user_id=$1`,[A])).rows[0].role);
await db.query(`update profiles set role='admin' where user_id=$1`,[A]);
const as=async(u,sql,p=[])=>{await db.exec(`set role authenticated; set request.uid='${u}'`); try{return await db.query(sql,p)} finally{await db.exec('reset role')}};
const ok=async(label,u,sql,p)=>{try{const r=await as(u,sql,p);console.log('OK  ',label);return r}catch(e){console.log('FAIL',label,'->',e.message);}};
const expectFail=async(label,u,sql,p)=>{try{await as(u,sql,p);console.log('BAD ',label,'(should have failed)')}catch(e){console.log('OK  ',label,'blocked:',e.message)}};
const l=(await ok('farmer lists',F,`insert into listings(farmer_id,posted_by,produce,qty_kg,price_ugx,harvest_date,district,town) values ($1,$1,'Maize',100,1200,current_date,'Mukono','Mukono') returning listing_id`,[F])).rows[0].listing_id;
await expectFail('buyer cannot list',B,`insert into listings(farmer_id,posted_by,produce,qty_kg,price_ugx,harvest_date,district,town) values ($1,$1,'x',1,1,current_date,'a','b')`,[B]);
await expectFail('buyer direct update order table',B,`update orders set stage=7`);
await expectFail('over-order',B,`select place_order($1,500,'delivery')`,[l]);
const o=(await ok('place order',B,`select place_order($1,10,'delivery') as id`,[l])).rows[0].id;
await expectFail('simulated payment failure',B,`select pay_order($1,true)`,[o]);
await ok('pay (escrow)',B,`select pay_order($1)`,[o]);
await expectFail('other buyer cannot see order?',X,`select 1/(select count(*)::int from orders where order_id='${o}')`);
await ok('farmer accept',F,`select farmer_step($1,3::smallint)`,[o]);
await ok('farmer ready',F,`select farmer_step($1,4::smallint)`,[o]);
await ok('rider sees job',R,`select 1/(select count(*)::int from orders where order_id='${o}')`);
await ok('rider collects',R,`select rider_step($1,5::smallint)`,[o]);
await ok('rider delivers',R,`select rider_step($1,6::smallint)`,[o]);
await ok('buyer confirms',B,`select confirm_receipt($1)`,[o]);
console.log('payment ->',(await db.query(`select status,amount_ugx,fee_ugx from payments where order_id=$1`,[o])).rows[0]);
await ok('rate',B,`select rate_order($1,$2,5::smallint,'good')`,[o,F]);
// dispute path
const o2=(await as(B,`select place_order($1,5,'delivery') as id`,[l])).rows[0].id;
await as(B,`select pay_order($1)`,[o2]);await as(F,`select farmer_step($1,3::smallint)`,[o2]);await as(F,`select farmer_step($1,4::smallint)`,[o2]);
await as(R,`select rider_step($1,5::smallint)`,[o2]);await as(R,`select rider_step($1,6::smallint)`,[o2]);
await ok('report problem',B,`select report_problem($1,'Wrong quantity delivered','photo.jpg')`,[o2]);
console.log('payment frozen? ',(await db.query(`select status from payments where order_id=$1`,[o2])).rows[0].status);
const d=(await db.query(`select dispute_id from disputes where order_id=$1`,[o2])).rows[0].dispute_id;
await expectFail('buyer cannot decide',B,`select admin_decide($1,'refund')`,[d]);
await ok('admin refunds',A,`select admin_decide($1,'refund')`,[d]);
console.log('after refund:',(await db.query(`select o.status os,p.status ps,l.qty_kg from orders o join payments p using(order_id) join listings l using(listing_id) where o.order_id=$1`,[o2])).rows[0]);
await expectFail('non-admin reads audit',B,`select 1/(select count(*)::int from audit_log)`);
console.log('audit rows:',(await db.query(`select count(*) from audit_log`)).rows[0].count);

// ---- v2 features: cart, delivery fee, notifications, chat, auto-release, helper lockdown
const l2=(await as(F,`insert into listings(farmer_id,posted_by,produce,qty_kg,price_ugx,harvest_date,district,town,category) values ($1,$1,'Beans',50,3000,current_date,'Mukono','Mukono','Grains') returning listing_id`,[F])).rows[0].listing_id;
await ok('add to cart (maize)',B,`insert into cart_items(listing_id,qty) values ($1,4)`,[l]);
await ok('add to cart (beans)',B,`insert into cart_items(listing_id,qty) values ($1,2)`,[l2]);
await expectFail('other user cannot read my cart',X,`select 1/(select count(*)::int from cart_items)`);
await expectFail('farmer cannot use cart',F,`insert into cart_items(listing_id,qty) values ($1,1)`,[l]);
console.log('checkout orders =',(await as(B,`select checkout('delivery') n`)).rows[0].n);
console.log('cart left =',(await db.query(`select count(*) from cart_items`)).rows[0].count);
await expectFail('empty cart checkout',B,`select checkout('delivery')`);
console.log('pay_all =',(await as(B,`select pay_all() n`)).rows[0].n);
console.log('totals incl delivery fee:',(await db.query(`select o.delivery_fee_ugx df,p.amount_ugx amt,p.fee_ugx fee from orders o join payments p using(order_id) where o.created_at > now() - interval '1 minute' and o.qty_kg in (4,2) order by o.qty_kg`)).rows);
console.log('farmer notifications:',(await as(F,`select count(*) c from notifications`)).rows[0].c);
await expectFail('call notify from browser',B,`select notify($1,'spam')`,[F]);
await expectFail('call log_action from browser',B,`select log_action('x',null)`);
await expectFail('call auto_release from browser',B,`select auto_release_overdue()`);
const o3=(await db.query(`select order_id from orders where qty_kg=4`)).rows[0].order_id;
await ok('party sends message',B,`select send_message($1,'Is it fresh?')`,[o3]);
await expectFail('stranger cannot message',X,`select send_message($1,'hi')`,[o3]);
await expectFail('stranger cannot read messages',X,`select 1/(select count(*)::int from messages)`);
await ok('farmer reads message',F,`select 1/(select count(*)::int from messages)`);
// auto-release: drive o3 to delivered, age it, run cron function
await as(F,`select farmer_step($1,3::smallint)`,[o3]);await as(F,`select farmer_step($1,4::smallint)`,[o3]);
await as(R,`select rider_step($1,5::smallint)`,[o3]);await as(R,`select rider_step($1,6::smallint)`,[o3]);
console.log('auto-release before 48h =',(await db.query(`select auto_release_overdue() n`)).rows[0].n);
await db.query(`update orders set delivered_at = now() - interval '49 hours' where order_id=$1`,[o3]);
console.log('auto-release after 49h  =',(await db.query(`select auto_release_overdue() n`)).rows[0].n);
console.log('o3 now:',(await db.query(`select o.status,p.status ps from orders o join payments p using(order_id) where o.order_id=$1`,[o3])).rows[0]);
await ok('mark read',F,`select mark_read()`);

// ---- v3 features: site settings, feedback, SMS queue, market filter column
await expectFail('buyer cannot change settings',B,`select admin_set_setting('delivery_fee_ugx','1')`);
await as(B,`update site_settings set value='1' where key='delivery_fee_ugx'`).catch(()=>{});   // RLS matches no rows, so this changes nothing (or is refused)
console.log((await db.query(`select value from site_settings where key='delivery_fee_ugx'`)).rows[0].value==='3000' ? 'OK   buyer cannot write settings table (value unchanged)' : 'BAD  buyer changed a setting');
await expectFail('admin: fee above limit rejected',A,`select admin_set_setting('platform_fee_pct','50')`);
await expectFail('admin: unknown setting rejected',A,`select admin_set_setting('drop_tables','1')`);
await ok('admin sets delivery fee 5000',A,`select admin_set_setting('delivery_fee_ugx','5000')`);
await ok('admin sets platform fee 8%',A,`select admin_set_setting('platform_fee_pct','8')`);
await ok('anyone signed in reads settings',B,`select 1/(select count(*)::int from site_settings)`);
const l3=(await as(F,`insert into listings(farmer_id,posted_by,produce,qty_kg,price_ugx,harvest_date,district,town,market) values ($1,$1,'Onions',20,2000,current_date,'Mukono','Mukono','Seeta Market') returning listing_id`,[F])).rows[0].listing_id;
const o4=(await as(B,`select place_order($1,10,'delivery') as id`,[l3])).rows[0].id;
console.log('new fees (expect fee 1600, total 25000):',(await db.query(`select o.delivery_fee_ugx df,p.amount_ugx amt,p.fee_ugx fee from orders o join payments p using(order_id) where o.order_id=$1`,[o4])).rows[0]);
console.log('market saved =',(await db.query(`select market from listings where listing_id=$1`,[l3])).rows[0].market);
await ok('feedback sent',B,`select send_feedback('idea','Please add a Luganda option')`);
await expectFail('feedback too short',B,`select send_feedback('idea','hi')`);
await expectFail('feedback bad type',B,`select send_feedback('spam','long enough text')`);
await expectFail('other buyer cannot read my feedback',X,`select 1/(select count(*)::int from feedback)`);
await ok('admin reads feedback',A,`select 1/(select count(*)::int from feedback)`);
await expectFail('buyer cannot change feedback status',B,`select admin_feedback_status(1,'resolved')`);
await ok('admin resolves feedback',A,`select admin_feedback_status(1,'resolved')`);
// SMS queue: only opted-in users get a queued SMS
await ok('farmer opts in to SMS',F,`update profiles set sms_opt_in = true where user_id = '${F}'`);
const smsBefore=+(await db.query(`select count(*) c from sms_outbox`)).rows[0].c;
await as(B,`select pay_order($1)`,[o4]);   // notifies the farmer
console.log('SMS queued for opted-in farmer =',+(await db.query(`select count(*) c from sms_outbox`)).rows[0].c - smsBefore,'(expect 1)');
await expectFail('browser cannot read sms_outbox',F,`select 1/(select count(*)::int from sms_outbox)`);

// ---- v4: Google sign-up, onboarding
const G=(await db.query(`insert into auth.users(email,raw_user_meta_data,raw_app_meta_data) values ('g@x',$1,$2) returning id`,[JSON.stringify({full_name:'Grace Google'}),JSON.stringify({provider:'google'})])).rows[0].id;
console.log('google profile:',(await db.query(`select name,role,onboarded from profiles where user_id=$1`,[G])).rows[0],'(expect Grace Google, buyer, false)');
await expectFail('bad role at onboarding (admin)',G,`select complete_profile('admin','0700000009','Central','Mukono','Mukono','Seeta Market')`);
await expectFail('bad phone at onboarding',G,`select complete_profile('farmer','123','Central','Mukono','Mukono','Seeta Market')`);
await ok('google user completes profile as farmer',G,`select complete_profile('farmer','0700000009','Central','Mukono','Mukono','Seeta Market')`);
console.log('after onboarding:',(await db.query(`select role,onboarded from profiles where user_id=$1`,[G])).rows[0],'(expect farmer, true)');
await expectFail('cannot onboard twice',G,`select complete_profile('rider','0700000009','Central','Mukono','Mukono','Seeta Market')`);
