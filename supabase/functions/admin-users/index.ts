import { createClient } from 'jsr:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

function isValidUsername(u: string) {
  return /^[a-zA-Z0-9_.-]{3,32}$/.test(u);
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'invalid json' }, 400);
  }
  const action = body?.action;
  if (!action) return json({ error: 'missing action' }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false }
  });

  // ---------- bootstrap: creates the one default admin account, only while profiles is empty ----------
  if (action === 'bootstrap_admin') {
    const { count, error: countErr } = await admin
      .from('profiles')
      .select('*', { count: 'exact', head: true });
    if (countErr) return json({ error: countErr.message }, 500);
    if ((count ?? 0) > 0) return json({ error: 'already bootstrapped' }, 403);

    const username = String(body.username || '').trim();
    const password = String(body.password || '');
    if (!isValidUsername(username)) return json({ error: 'invalid username' }, 400);
    if (password.length < 8) return json({ error: 'password too short' }, 400);

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email: `${username}@dracon.local`,
      password,
      email_confirm: true
    });
    if (createErr) return json({ error: createErr.message }, 500);

    const { error: profileErr } = await admin.from('profiles').insert({
      id: created.user.id,
      username,
      is_admin: true,
      active: true,
      permissions: {}
    });
    if (profileErr) return json({ error: profileErr.message }, 500);

    return json({ ok: true });
  }

  // ---------- everything else requires an authenticated, active admin caller ----------
  const authHeader = req.headers.get('Authorization') || '';
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } }
  });
  const { data: userData, error: userErr } = await callerClient.auth.getUser();
  const user = userData?.user;
  if (userErr || !user) return json({ error: 'unauthorized' }, 401);

  const { data: callerProfile, error: callerErr } = await admin
    .from('profiles')
    .select('is_admin, active')
    .eq('id', user.id)
    .single();
  if (callerErr || !callerProfile?.is_admin || !callerProfile.active) {
    return json({ error: 'forbidden' }, 403);
  }

  if (action === 'create_user') {
    const username = String(body.username || '').trim();
    const password = String(body.password || '');
    const permissions = body.permissions && typeof body.permissions === 'object' ? body.permissions : {};
    if (!isValidUsername(username)) return json({ error: 'invalid username' }, 400);
    if (password.length < 8) return json({ error: 'password too short' }, 400);

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email: `${username}@dracon.local`,
      password,
      email_confirm: true
    });
    if (createErr) return json({ error: createErr.message }, 500);

    const { error: profileErr } = await admin.from('profiles').insert({
      id: created.user.id,
      username,
      is_admin: false,
      active: true,
      permissions
    });
    if (profileErr) {
      await admin.auth.admin.deleteUser(created.user.id);
      return json({ error: profileErr.message }, 500);
    }
    return json({ ok: true, id: created.user.id });
  }

  if (action === 'update_permissions') {
    const userId = body.userId;
    if (!userId) return json({ error: 'missing userId' }, 400);
    const { data: target } = await admin.from('profiles').select('is_admin').eq('id', userId).single();
    if (target?.is_admin) return json({ error: 'cannot modify the admin account' }, 403);
    const patch: Record<string, unknown> = {};
    if (body.permissions && typeof body.permissions === 'object') patch.permissions = body.permissions;
    if (body.username) {
      const username = String(body.username).trim();
      if (!isValidUsername(username)) return json({ error: 'invalid username' }, 400);
      patch.username = username;
    }
    if (Object.keys(patch).length === 0) return json({ error: 'nothing to update' }, 400);
    const { error } = await admin.from('profiles').update(patch).eq('id', userId);
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true });
  }

  if (action === 'reset_password') {
    const userId = body.userId;
    const newPassword = String(body.newPassword || '');
    if (!userId) return json({ error: 'missing userId' }, 400);
    if (newPassword.length < 8) return json({ error: 'password too short' }, 400);
    const { error } = await admin.auth.admin.updateUserById(userId, { password: newPassword });
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true });
  }

  if (action === 'set_active') {
    const userId = body.userId;
    const active = !!body.active;
    if (!userId) return json({ error: 'missing userId' }, 400);
    if (userId === user.id) return json({ error: 'cannot change your own status' }, 403);
    const { data: target } = await admin.from('profiles').select('is_admin').eq('id', userId).single();
    if (target?.is_admin) return json({ error: 'cannot modify the admin account' }, 403);
    const { error: banErr } = await admin.auth.admin.updateUserById(userId, {
      ban_duration: active ? 'none' : '876000h'
    });
    if (banErr) return json({ error: banErr.message }, 500);
    const { error } = await admin.from('profiles').update({ active }).eq('id', userId);
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true });
  }

  if (action === 'delete_user') {
    const userId = body.userId;
    if (!userId) return json({ error: 'missing userId' }, 400);
    if (userId === user.id) return json({ error: 'cannot delete your own account' }, 403);
    const { data: target } = await admin.from('profiles').select('is_admin').eq('id', userId).single();
    if (target?.is_admin) return json({ error: 'cannot delete the admin account' }, 403);
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true });
  }

  return json({ error: 'unknown action' }, 400);
});
