// ============================================================
// Supabase Edge Function: send-push
// Receives { user_id, title, body, type, icon, url } and sends
// Web Push notifications to every subscription the user has.
//
// Deploy via Supabase Dashboard → Edge Functions → Create new
// function → name it "send-push" → paste this file.
// ============================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import webpush from 'https://esm.sh/web-push@3.6.7';

const VAPID_PUBLIC = Deno.env.get('VAPID_PUBLIC_KEY')!;
const VAPID_PRIVATE = Deno.env.get('VAPID_PRIVATE_KEY')!;
const VAPID_SUBJECT = Deno.env.get('VAPID_SUBJECT') || 'mailto:support@skillclash.in';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

Deno.serve(async (req) => {
  try {
    const payload = await req.json();
    const { user_id, title, body, type, icon, url } = payload;

    if (!title) {
      return new Response(JSON.stringify({ ok: false, error: 'title required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    let query = supabase.from('push_subscriptions').select('*');
    if (user_id) query = query.eq('user_id', user_id);
    const { data: subs, error } = await query;

    if (error) {
      return new Response(JSON.stringify({ ok: false, error: error.message }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    if (!subs || subs.length === 0) {
      return new Response(JSON.stringify({ ok: true, sent: 0, message: 'no subscriptions' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    const notifPayload = JSON.stringify({
      title,
      body: body || '',
      type: type || 'info',
      icon: icon || '/icon-192.png',
      badge: '/icon-192.png',
      url: url || '/'
    });

    let sent = 0;
    let failed = 0;
    const staleEndpoints: string[] = [];

    for (const sub of subs) {
      try {
        const pushSub = {
          endpoint: sub.endpoint,
          keys: { p256dh: sub.p256dh, auth: sub.auth }
        };
        await webpush.sendNotification(pushSub, notifPayload);
        sent++;
      } catch (err: any) {
        failed++;
        if (err?.statusCode === 404 || err?.statusCode === 410) {
          staleEndpoints.push(sub.endpoint);
        }
        console.error('Push failed for endpoint:', sub.endpoint, err?.message);
      }
    }

    if (staleEndpoints.length > 0) {
      await supabase.from('push_subscriptions').delete().in('endpoint', staleEndpoints);
    }

    return new Response(JSON.stringify({
      ok: true,
      sent,
      failed,
      cleaned: staleEndpoints.length
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });

  } catch (e: any) {
    console.error('send-push error:', e);
    return new Response(JSON.stringify({ ok: false, error: e.message }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    });
  }
});
