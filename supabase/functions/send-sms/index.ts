// Supabase Edge Function: sends queued SMS alerts (sms_outbox) through Africa's Talking.
// UNTESTED against the live API. Needs an Africa's Talking account (sandbox works) and these secrets:
//   supabase secrets set AT_USERNAME=sandbox AT_API_KEY=xxxx
// Deploy:  supabase functions deploy send-sms --no-verify-jwt   (protect it with the SEND_SMS_TOKEN secret below)
// Run it on a schedule (Dashboard > Edge Functions > Schedule, or pg_cron + pg_net) every minute.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  if (req.headers.get('authorization') !== `Bearer ${Deno.env.get('SEND_SMS_TOKEN')}`) return new Response('Forbidden', { status: 403 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: rows } = await db.from('sms_outbox').select('*').eq('status', 'queued').order('id').limit(50);
  let sent = 0;
  for (const r of rows ?? []) {
    const to = '+256' + String(r.phone_no).replace(/^0/, '');          // Ugandan numbers: 07XXXXXXXX -> +2567XXXXXXXX
    const res = await fetch('https://api.africastalking.com/version1/messaging', {
      method: 'POST',
      headers: { apiKey: Deno.env.get('AT_API_KEY')!, 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: new URLSearchParams({ username: Deno.env.get('AT_USERNAME')!, to, message: r.message }),
    });
    await db.from('sms_outbox').update({ status: res.ok ? 'sent' : 'failed', sent_at: res.ok ? new Date().toISOString() : null }).eq('id', r.id);
    if (res.ok) sent++;
  }
  return Response.json({ queued: rows?.length ?? 0, sent });
});
