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

// جداول دليل الأكواد الموحد (المفتاح الأساسي فيها code، مش id) — الكود بيتحسب مرة تانية هنا وقت
// الموافقة نفسها بدل ما نثق في القيمة اللي حجزها الطالِب وقت الإرسال، عشان ممكن تتاخد من حد تاني
// (المدير مباشرة أو طلب آخر اتوافق عليه) في الفترة ما بين الطلب والموافقة، وده كان هيسبب تعارض PK
const MASTER_DATA_TABLES = new Set([
  'projects', 'supplies', 'suppliers', 'expense_categories', 'activities', 'names',
  'clients', 'investors', 'accounts', 'employees', 'asset_types', 'taxes'
]);
async function reassignMasterDataCodes(admin: ReturnType<typeof createClient>, ops: any[]) {
  for (const op of ops) {
    if (op.op !== 'insert' || !MASTER_DATA_TABLES.has(op.table)) continue;
    const { data: maxRow } = await admin.from(op.table).select('code').order('code', { ascending: false }).limit(1).maybeSingle();
    op.row = { ...op.row, code: (maxRow?.code || 0) + 1 };
  }
}

// ---------- تطبيق الطلبات المعتمدة (approve_change) ----------
// كل نوع عملية (kind) ليه معالج مخصص بيعيد قراءة السجل الحالي من القاعدة وقت الموافقة نفسها،
// مش بيثق في نسخة الطالِب المحفوظة وقت الإرسال — عشان ميحصلش فقدان بيانات لو حصل تعديل تاني
// على نفس السجل (من المدير مباشرة أو من طلب آخر اتوافق عليه) في الفترة ما بين الطلب والموافقة.
async function applyAccrualChange(admin: ReturnType<typeof createClient>, after: any) {
  const { kind } = after;

  if (kind === 'pay_investor_liability') {
    const { liabilityId, amount, date, notes } = after;
    const { data: lib, error: e0 } = await admin.from('investor_liabilities').select('*').eq('id', liabilityId).single();
    if (e0 || !lib) throw new Error(e0?.message || 'الالتزام غير موجود');
    const paidAmount = (lib.paid_amount || 0) + amount;
    const patch: Record<string, unknown> = { paid_amount: paidAmount };
    if (paidAmount >= lib.amount) { patch.status = 'paid'; patch.paid_date = date; }
    const { error: e1 } = await admin.from('investor_liabilities').update(patch).eq('id', liabilityId);
    if (e1) throw e1;
    const { error: e2 } = await admin.from('profit_distributions').insert({
      investor: lib.investor, project: lib.project, amount, date, notes: notes || 'دفعة من التزام معتمد'
    });
    if (e2) throw e2;
    return;
  }

  if (kind === 'pay_manager_liability') {
    const { liabilityId, amount, date, account, notes } = after;
    const { data: lib, error: e0 } = await admin.from('manager_liabilities').select('*').eq('id', liabilityId).single();
    if (e0 || !lib) throw new Error(e0?.message || 'الالتزام غير موجود');
    const paidAmount = (lib.paid_amount || 0) + amount;
    const patch: Record<string, unknown> = { paid_amount: paidAmount };
    if (paidAmount >= lib.amount) { patch.status = 'paid'; patch.paid_date = date; }
    const { error: e1 } = await admin.from('manager_liabilities').update(patch).eq('id', liabilityId);
    if (e1) throw e1;
    const { error: e2 } = await admin.from('manager_payments').insert({ liability_id: liabilityId, amount, date, account, notes: notes || 'سداد التزام مدير' });
    if (e2) throw e2;
    return;
  }

  if (kind === 'settle_employee_advance') {
    const { advanceId, amount, date } = after;
    const { data: rec, error: e0 } = await admin.from('employee_advances').select('*').eq('id', advanceId).single();
    if (e0 || !rec) throw new Error(e0?.message || 'السلفة غير موجودة');
    const settlements = [...(rec.settlements || []), { amount, date }];
    const deductedAmount = (rec.deducted_amount || 0) + amount;
    const patch: Record<string, unknown> = { settlements, deducted_amount: deductedAmount };
    if (deductedAmount >= rec.amount) { patch.status = 'settled'; patch.settled_date = date; }
    const { error: e1 } = await admin.from('employee_advances').update(patch).eq('id', advanceId);
    if (e1) throw e1;
    return;
  }

  if (kind === 'pay_obligation_installment') {
    const { obligId, instId, date, notes } = after;
    const { data: rec, error: e0 } = await admin.from('obligations').select('*').eq('id', obligId).single();
    if (e0 || !rec) throw new Error(e0?.message || 'الالتزام غير موجود');
    const installments = (rec.installments || []).map((i: any) => i.id === instId ? { ...i, status: 'paid', paidDate: date, paidNotes: notes } : i);
    const { error: e1 } = await admin.from('obligations').update({ installments }).eq('id', obligId);
    if (e1) throw e1;
    return;
  }

  if (kind === 'post_payroll') {
    const { month, rows } = after;
    // نفس حماية الترحيل المزدوج الموجودة في الواجهة، بس بنعيدها هنا وقت الموافقة نفسها —
    // عشان لو حصل ترحيل تاني لنفس الشهر (من المدير مباشرة أو طلب آخر) في الفترة ما بين الطلب والموافقة
    const notesMarker = `راتب شهر ${month}`;
    const { data: existing } = await admin.from('expense_entries').select('id').eq('category', 'أجور').eq('notes', notesMarker).limit(1);
    if (existing && existing.length) throw new Error(`رواتب شهر ${month} مترحّلة بالفعل من مصدر تاني — الطلب اتلغى تلقائيًا`);
    const { error } = await admin.from('expense_entries').insert(rows);
    if (error) throw error;
    return;
  }

  if (kind === 'reopen_obligation_installment') {
    const { obligId, instId } = after;
    const { data: rec, error: e0 } = await admin.from('obligations').select('*').eq('id', obligId).single();
    if (e0 || !rec) throw new Error(e0?.message || 'الالتزام غير موجود');
    const installments = (rec.installments || []).map((i: any) => {
      if (i.id !== instId) return i;
      const { paidDate, ...restInst } = i;
      return { ...restInst, status: 'pending' };
    });
    const { error: e1 } = await admin.from('obligations').update({ installments }).eq('id', obligId);
    if (e1) throw e1;
    return;
  }

  throw new Error(`unknown accrual kind: ${kind}`);
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

  // ---------- كل الحاجات التانية محتاجة على الأقل مستخدم مسجّل دخول وحسابه مفعّل ----------
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
  if (callerErr || !callerProfile?.active) return json({ error: 'forbidden' }, 403);

  // ---------- تغيير اسم المستخدم الذاتي: متاح لأي مستخدم مفعّل (مدير أو عادي) لحسابه هو بس ----------
  if (action === 'update_own_username') {
    const username = String(body.username || '').trim();
    if (!isValidUsername(username)) return json({ error: 'invalid username' }, 400);

    const { error: emailErr } = await admin.auth.admin.updateUserById(user.id, {
      email: `${username}@dracon.local`
    });
    if (emailErr) {
      return json({ error: emailErr.message?.includes('already been registered') ? 'اسم المستخدم ده مستخدم بالفعل' : emailErr.message }, 500);
    }
    const { error: profileErr } = await admin.from('profiles').update({ username }).eq('id', user.id);
    if (profileErr) {
      // رجّع الإيميل زي ما كان لو فشل تحديث بروفايل عشان الحسابين يفضلوا متطابقين
      await admin.auth.admin.updateUserById(user.id, { email: user.email });
      return json({ error: profileErr.message?.includes('duplicate') ? 'اسم المستخدم ده مستخدم بالفعل' : profileErr.message }, 500);
    }
    return json({ ok: true });
  }

  // ---------- باقي العمليات (إدارة المستخدمين + موافقات الطلبات المعلّقة) محتاجة إن المتصل يكون مدير ----------
  if (!callerProfile.is_admin) return json({ error: 'forbidden' }, 403);

  if (action === 'create_user') {
    const username = String(body.username || '').trim();
    const password = String(body.password || '');
    const permissions = body.permissions && typeof body.permissions === 'object' ? body.permissions : {};
    const requiresApproval = !!body.requiresApproval;
    const allowedProjects = Array.isArray(body.allowedProjects) ? body.allowedProjects.map(Number).filter(Number.isFinite) : [];
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
      permissions,
      requires_approval: requiresApproval,
      allowed_projects: allowedProjects
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
    const { data: target } = await admin.from('profiles').select('is_admin, username').eq('id', userId).single();
    if (target?.is_admin) return json({ error: 'cannot modify the admin account' }, 403);
    const patch: Record<string, unknown> = {};
    if (body.permissions && typeof body.permissions === 'object') patch.permissions = body.permissions;
    if (typeof body.requiresApproval === 'boolean') patch.requires_approval = body.requiresApproval;
    if (Array.isArray(body.allowedProjects)) patch.allowed_projects = body.allowedProjects.map(Number).filter(Number.isFinite);
    let usernameChanged = false;
    if (body.username) {
      const username = String(body.username).trim();
      if (!isValidUsername(username)) return json({ error: 'invalid username' }, 400);
      if (target && username !== target.username) usernameChanged = true;
      patch.username = username;
    }
    if (Object.keys(patch).length === 0) return json({ error: 'nothing to update' }, 400);
    // لازم إيميل تسجيل الدخول (auth.users) يتحدّث برضه لما اسم المستخدم يتغيّر، وإلا هيتقفل عليه ميقدرش يدخل تاني
    if (usernameChanged) {
      const { error: emailErr } = await admin.auth.admin.updateUserById(userId, { email: `${patch.username}@dracon.local` });
      if (emailErr) return json({ error: emailErr.message?.includes('already been registered') ? 'اسم المستخدم ده مستخدم بالفعل' : emailErr.message }, 500);
    }
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

  // ---------- موافقة/رفض طلبات "requiresApproval" المعلّقة ----------
  if (action === 'approve_change') {
    const changeId = body.changeId;
    if (!changeId) return json({ error: 'missing changeId' }, 400);

    // نحجز الطلب بشرط إنه لسه pending — يمنع دبل-كليك أو موافقة مزدوجة من تطبيق نفس التغيير مرتين
    const { data: claimed, error: claimErr } = await admin
      .from('pending_changes')
      .update({ status: 'approved', resolved_at: new Date().toISOString() })
      .eq('id', changeId).eq('status', 'pending')
      .select().single();
    if (claimErr || !claimed) return json({ error: 'الطلب ده اتعالج قبل كده أو مش موجود' }, 409);

    try {
      const after = claimed.after_data || {};
      if (after.kind) {
        await applyAccrualChange(admin, after);
      } else if (Array.isArray(after.operations)) {
        const insertsAndDeletes = after.operations.filter((o: any) => o.op === 'insert' || o.op === 'delete');
        const updates = after.operations.filter((o: any) => o.op === 'update');
        if (insertsAndDeletes.length) {
          await reassignMasterDataCodes(admin, insertsAndDeletes);
          const { error } = await admin.rpc('apply_pending_operations', { p_operations: insertsAndDeletes });
          if (error) throw error;
        }
        for (const op of updates) {
          const { error } = await admin.from(op.table).update(op.row).eq(op.pk_col, op.pk_value);
          if (error) throw error;
        }
      }

      // نسجّل الحركة في سجل التعديلات الموجود بالفعل، منسوبة للمستخدم الأصلي اللي طلبها
      const { data: requester } = await admin.from('profiles').select('username').eq('id', claimed.user_id).single();
      await admin.from('audit_log').insert({
        action: claimed.action_type,
        entity: claimed.module,
        entity_name: `${after.entityName || claimed.target_record_id || ''} (بموافقة المدير)`,
        old_value: claimed.before_data,
        new_value: after,
        user_label: requester?.username || 'غير معروف',
        user_id: claimed.user_id
      });
      return json({ ok: true });
    } catch (err) {
      // لو حصل خطأ أثناء التطبيق، نرجّع الطلب لحالة "معلّق" تاني عشان المدير يقدر يحاول تاني بدل ما الطلب يضيع
      await admin.from('pending_changes').update({ status: 'pending', resolved_at: null }).eq('id', changeId);
      return json({ error: (err as Error).message }, 500);
    }
  }

  if (action === 'reject_change') {
    const changeId = body.changeId;
    if (!changeId) return json({ error: 'missing changeId' }, 400);
    const { data: claimed, error } = await admin
      .from('pending_changes')
      .update({ status: 'rejected', resolved_at: new Date().toISOString() })
      .eq('id', changeId).eq('status', 'pending')
      .select().single();
    if (error || !claimed) return json({ error: 'الطلب ده اتعالج قبل كده أو مش موجود' }, 409);

    const after = claimed.after_data || {};
    const { data: requester } = await admin.from('profiles').select('username').eq('id', claimed.user_id).single();
    await admin.from('audit_log').insert({
      action: 'reject',
      entity: claimed.module,
      entity_name: `${after.entityName || claimed.target_record_id || ''} (مرفوض من المدير)`,
      old_value: claimed.before_data,
      new_value: null,
      user_label: requester?.username || 'غير معروف',
      user_id: claimed.user_id
    });
    return json({ ok: true });
  }

  return json({ error: 'unknown action' }, 400);
});
