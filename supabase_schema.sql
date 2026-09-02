-- ============================================================
-- نظام دراكون للمقاولات — هيكلة قاعدة بيانات Supabase (النسخة الكاملة v4.5)
-- شغّلي الملف ده كامل مرة واحدة من: Supabase Dashboard > SQL Editor > New query
-- ============================================================

-- ---------- جداول دليل الأكواد (Master Data) ----------
create table if not exists projects (
  code integer primary key,
  name text not null unique,
  capital numeric, -- إجمالي التمويل المستهدف للمشروع (لحساب نسبة كل مستثمر تلقائياً)
  status text default 'active' -- active / completed
);

create table if not exists supplies (
  code integer primary key,
  name text not null unique,
  unit text
);

create table if not exists suppliers (
  code integer primary key,
  name text not null unique,
  items text[],
  opening_balance numeric -- رصيد افتتاحي مستحق للمورد قبل بدء استخدام النظام
);

create table if not exists expense_categories (
  code integer primary key,
  name text not null unique,
  pl_type text not null check (pl_type in ('revenue','other_revenue','direct','operating','other','excluded')),
  pl_bucket text check (pl_bucket in ('admin','selling','other_operating')),
  name_type text default 'any' -- من يظهر في حقل "المستفيد" لهذا التبويب: names / clients / any
);

create table if not exists activities (
  code integer primary key,
  name text not null unique,
  categories text[], -- التبويبات المرتبطة بهذا النشاط (فاضي = يظهر مع كل التبويبات)
  linked_names text[] -- الأفراد/العملاء المرتبطين بهذا النشاط تحديداً
);

create table if not exists names (
  code integer primary key,
  name text not null unique,
  contract_value numeric,
  activities text[], -- الأنشطة المرتبطة بهذا الفرد/المقاول
  opening_balance numeric, -- رصيد افتتاحي مستحق للمقاول قبل بدء استخدام النظام
  executed_override numeric -- تعديل يدوي للقيمة المنفذة (بدل الاحتساب التلقائي من الحركات)
);

create table if not exists clients (
  code integer primary key,
  name text not null unique,
  contract_value numeric,
  activities text[]
);

create table if not exists investors (
  code integer primary key,
  name text not null unique,
  management_fee_pct numeric -- نسبة إدارة أموال هذا المستثمر تُخصم من نصيبه في الربح فقط
);

create table if not exists accounts (
  code integer primary key,
  name text not null unique,
  opening_balance numeric default 0
);

create table if not exists employees (
  code integer primary key,
  name text not null unique,
  monthly_salary numeric default 0
);

create table if not exists asset_types (
  code integer primary key,
  name text not null unique
);

create table if not exists units (
  code integer primary key,
  name text not null unique
);

create table if not exists taxes (
  code integer primary key,
  name text not null,
  rate numeric default 0,
  active boolean default true
);

-- ---------- جداول الحركات (Transactions) ----------
create table if not exists procurements (
  id bigint generated always as identity primary key,
  group_id uuid, -- يربط سطور نفس فاتورة التوريد ببعض
  invoice_number text,
  item text not null,
  supplier text not null,
  project text not null,
  qty numeric not null default 0,
  unit text,
  price numeric not null default 0,
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists sales (
  id bigint generated always as identity primary key,
  group_id uuid not null, -- يربط سطور نفس فاتورة البيع ببعض
  invoice_number text,
  item text not null,
  client text not null,
  qty numeric not null default 1,
  unit text,
  price numeric not null default 0,
  total numeric not null default 0,
  project text,
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists expense_entries (
  id bigint generated always as identity primary key,
  category text not null,
  activity text,
  name text not null,
  project text not null,
  total numeric not null default 0,
  paid numeric not null default 0,
  remaining numeric not null default 0,
  executed_value numeric, -- القيمة المنفذة فعلياً (المستخلص) لقيود المقاولين فقط
  custody_id bigint, -- رابط للعهدة المؤقتة إذا نشأ هذا القيد من تسوية عهدة
  sale_id uuid, -- رابط لفاتورة البيع إذا نشأ هذا القيد من تسجيل مبيعات
  account text, -- الحساب البنكي/النقدي المرتبط بالحركة
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now(),
  -- الجدول ده مشترك بين 4 تبويبات مختلفة (مصروفات/رواتب/مبيعات/عهد) — العمود ده بيوضّح
  -- مصدر كل حركة عشان RLS تقدر تفرض صلاحية التبويب الحقيقي بدل موديول واحد ثابت
  source_module text not null check (source_module in ('expenses','payroll','sales','custody')),
  payroll_batch_id uuid -- معرّف موحّد لكل عملية ترحيل رواتب شهرية، عشان نلاقي كل القيود المرتبطة بترحيل معيّن بسهولة
);
alter table expense_entries add column if not exists payroll_batch_id uuid;

-- توزيع كل موظف على مشروع أو أكتر (نسبة % أو مبلغ ثابت شهري) — يُستخدم وقت ترحيل الرواتب
-- بدل ما الراتب كله يترحّل بمشروع واحد أو "-"
create table if not exists employee_project_allocations (
  id bigint generated always as identity primary key,
  employee text not null,
  project text not null,
  allocation_type text not null default 'percentage' check (allocation_type in ('percentage', 'fixed')),
  allocation_value numeric not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
-- مينفعش يتسجّل تخصيصين فعّالين لنفس (الموظف, المشروع) في نفس الوقت
create unique index if not exists uq_employee_project_active
  on employee_project_allocations (employee, project) where active = true;

create table if not exists payments (
  id bigint generated always as identity primary key,
  supplier text not null,
  project text,
  amount numeric not null default 0,
  account text,
  items text[], -- أوصاف الفواتير المحددة اللي اتسددت بالدفعة دي (اختياري)
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now(),
  discount numeric not null default 0 -- خصم مكتسب من المورد عند السداد — إيراد إضافي، مش تخفيض في المستحق الأصلي
);

create table if not exists contractor_payments (
  id bigint generated always as identity primary key,
  name text not null,
  amount numeric not null default 0,
  project text,
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now(),
  discount numeric not null default 0 -- خصم مكتسب من المقاول عند السداد — إيراد إضافي، مش تخفيض في المستحق الأصلي
);

create table if not exists refunds (
  id bigint generated always as identity primary key,
  party_type text not null check (party_type in ('supplier','contractor')),
  name text not null,
  amount numeric not null default 0,
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists investor_funding (
  id bigint generated always as identity primary key,
  investor text not null,
  project text not null,
  amount numeric default 0,
  pct numeric default 0,
  date date default current_date,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists profit_distributions (
  id bigint generated always as identity primary key,
  investor text not null,
  project text not null default 'ALL',
  amount numeric not null default 0,
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists investor_liabilities (
  id bigint generated always as identity primary key,
  investor text not null,
  project text,
  amount numeric not null default 0,
  date date not null default current_date,
  status text not null default 'pending',
  paid_amount numeric default 0,
  paid_date date,
  created_at timestamptz not null default now()
);

create table if not exists manager_liabilities (
  id bigint generated always as identity primary key,
  investor text not null,
  project text,
  amount numeric not null default 0,
  date date not null default current_date,
  status text not null default 'pending',
  paid_amount numeric default 0,
  paid_date date,
  created_at timestamptz not null default now()
);

create table if not exists manager_payments (
  id bigint generated always as identity primary key,
  liability_id bigint,
  amount numeric not null default 0,
  date date not null default current_date,
  account text,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists custodies (
  id bigint generated always as identity primary key,
  name text not null,
  amount numeric not null default 0,
  project text,
  account text,
  date date not null default current_date,
  purpose text,
  status text not null default 'pending',
  spent_amount numeric,
  returned_amount numeric,
  type text,
  created_at timestamptz not null default now()
);

create table if not exists employee_advances (
  id bigint generated always as identity primary key,
  employee text not null,
  amount numeric not null default 0,
  date date not null default current_date,
  account text,
  notes text,
  deducted_amount numeric not null default 0,
  status text not null default 'pending',
  settlements jsonb not null default '[]'::jsonb,
  settled_date date,
  created_at timestamptz not null default now()
);

create table if not exists attendance (
  id bigint generated always as identity primary key,
  employee text not null,
  date date not null default current_date,
  status text not null default 'present',
  time_in time,
  time_out time,
  created_at timestamptz not null default now()
);

create table if not exists assets (
  id bigint generated always as identity primary key,
  name text not null,
  cost numeric not null default 0,
  date date not null default current_date,
  dep_rate numeric default 0,
  location text,
  status text not null default 'working',
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists daily_journals (
  id bigint generated always as identity primary key,
  project text not null,
  date date not null default current_date,
  day text,
  supplies jsonb default '[]'::jsonb,
  execution jsonb default '[]'::jsonb,
  orders text,
  expenses text,
  notes text,
  time_in time,
  time_out time,
  engineer text,
  created_at timestamptz not null default now()
);

create table if not exists obligations (
  id bigint generated always as identity primary key,
  type text not null,
  description text not null,
  party text,
  notes text,
  installments jsonb not null default '[]'::jsonb,
  total_amount numeric default 0,
  created_at timestamptz not null default now()
);

create table if not exists external_investments (
  id bigint generated always as identity primary key,
  description text not null,
  project text,
  amount numeric not null default 0,
  date date not null default current_date,
  account text,
  notes text,
  status text not null default 'pending',
  returned_amount numeric default 0,
  settle_date date,
  created_at timestamptz not null default now()
);

create table if not exists audit_log (
  id bigint generated always as identity primary key,
  action text not null,
  entity text not null,
  entity_name text,
  old_value jsonb,
  new_value jsonb,
  user_label text, -- اسم المستخدم الحقيقي وقت الحركة (عرض سريع بدون join، وسجل تاريخي يفضل موجود حتى لو المستخدم اتحذف)
  user_id uuid references auth.users(id) on delete set null, -- مرجع حقيقي للمستخدم؛ يتفرغ لو المستخدم اتحذف بدل ما يمنع حذفه
  created_at timestamptz not null default now()
);

-- pending_changes: طلبات موافقة المدير — لأي مستخدم عنده profiles.requires_approval = true.
-- بدل ما تتنفذ إضافة/تعديل/حذف على طول، بتتسجل هنا كطلب معلّق (before/after كـ JSON)، وتتنفذ فعليًا
-- بس لما المدير يوافق عليها (عن طريق admin-users Edge Function، action=approve_change/reject_change).
create table if not exists pending_changes (
  id bigint generated always as identity primary key,
  user_id uuid references profiles(id) on delete set null, -- مرجع للمستخدم الطالب؛ يتفرغ لو اتحذف حسابه بدل ما يمنع الحذف
  action_type text not null, -- create / update / delete
  module text not null, -- نفس معرّف التبويب (procurement, expenses, ...) لتحديد صلاحية التنفيذ والتنقل
  target_record_id text, -- لعمليات update/delete: هوية السجل الأصلي المستهدف
  before_data jsonb, -- نسخة من السجل قبل التعديل (للمقارنة/التراجع)
  after_data jsonb, -- تفاصيل العملية المطلوبة (اسم العنصر + عمليات insert/update/delete الفعلية)
  status text not null default 'pending', -- pending / approved / rejected
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

-- ---------- إعدادات عامة (متبقية للتوافق، غير مستخدمة في التصميم الجديد) ----------
create table if not exists app_settings (
  key text primary key,
  value jsonb not null
);

-- ---------- تسلسلات ترقيم الفواتير (آمنة تحت التزامن بين عدة مستخدمين) ----------
create sequence if not exists purchase_invoice_seq start 1;
create sequence if not exists sale_invoice_seq start 1;

create or replace function next_invoice_number(prefix text, seq_name text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  n bigint;
begin
  execute format('select nextval(%L)', seq_name) into n;
  return prefix || '-' || lpad(n::text, 5, '0');
end;
$$;

grant execute on function next_invoice_number(text, text) to anon, authenticated;

-- ---------- بيانات ابتدائية ----------
insert into accounts (code, name, opening_balance) values (9501, 'الخزينة النقدية', 0) on conflict (code) do nothing;
insert into taxes (code, name, rate, active) values
  (9001, 'ضريبة الدخل', 1, true),
  (9002, 'ضريبة القيمة المضافة (VAT)', 14, false),
  (9003, 'ضريبة الدمغة', 0.3, false)
on conflict (code) do nothing;
insert into units (code, name) values
  (9800, 'طن'), (9801, 'م3'), (9802, 'ألف'), (9803, 'بند'), (9804, 'متر'),
  (9805, 'كجم'), (9806, 'عدد'), (9807, 'فاتورة'), (9808, 'كيس'), (9809, 'م2'),
  (9810, 'متر طولي'), (9811, 'لتر'), (9812, 'شيكارة'), (9813, 'رول'), (9814, 'جركن'),
  (9815, 'برميل'), (9816, 'باستلة')
on conflict (code) do nothing;

-- ---------- فهارس لتسريع الفلاتر الشائعة ----------
create index if not exists idx_procurements_project on procurements(project);
create index if not exists idx_procurements_date on procurements(date);
create index if not exists idx_procurements_group on procurements(group_id);
create index if not exists idx_sales_project on sales(project);
create index if not exists idx_sales_date on sales(date);
create index if not exists idx_sales_group on sales(group_id);
create index if not exists idx_expense_entries_project on expense_entries(project);
create index if not exists idx_expense_entries_date on expense_entries(date);
create index if not exists idx_payments_supplier on payments(supplier);
create index if not exists idx_attendance_employee_date on attendance(employee, date);
create index if not exists idx_daily_journals_project_date on daily_journals(project, date);
create index if not exists idx_audit_log_created_at on audit_log(created_at desc);

-- ============================================================
-- المستخدمين والصلاحيات (Supabase Auth + RLS حقيقي)
-- ============================================================
-- profiles: صف واحد لكل مستخدم Auth، فيه اسم المستخدم وحالة التفعيل وصلاحياته.
-- الكتابة عليه ممنوعة تمامًا من المتصفح — بتتم فقط عن طريق Edge Function
-- (admin-users) اللي بتستخدم service_role جوّاها (مش في المتصفح أبدًا).
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  is_admin boolean not null default false,
  active boolean not null default true,
  permissions jsonb not null default '{}'::jsonb, -- مفتاح مستقل لكل تبويب: {"procurement":{"view":true,"edit":true,"delete":false}, "sales":{...}, ..., "masterdata":{...}} (18 مفتاح)
  created_at timestamptz not null default now(),
  requires_approval boolean not null default false, -- لو true: أي إضافة/تعديل/حذف من المستخدم ده بيتسجل في pending_changes بدل التنفيذ المباشر، لحد ما المدير يوافق
  allowed_projects int[] not null default '{}' -- أكواد المشاريع المسموح لهذا المستخدم (غير الأدمن) يشتغل عليها؛ فاضية = صفر مشاريع. المدير دايمًا بيشوف الكل بصرف النظر عن العمود ده.
);
alter table profiles enable row level security;
alter table profiles add column if not exists allowed_projects int[] not null default '{}'; -- لتحديث القواعد القديمة اللي اتعملها الجدول قبل إضافة العمود ده
grant select, insert, update, delete on profiles to service_role; -- جدول جديد محتاج المنحة دي صراحةً عشان الـ Edge Function تقدر تكتب فيه

create or replace function is_admin_user()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid() and active), false);
$$;

create or replace function is_active_user()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and active);
$$;

-- الدالة دي هي الحماية الحقيقية: أي عملية إضافة/تعديل/حذف بتتحقق منها قبل ما تتنفذ فعليًا في القاعدة
create or replace function has_permission(p_module text, p_action text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles p
    where p.id = auth.uid() and p.active
      and (p.is_admin or coalesce((p.permissions -> p_module ->> p_action)::boolean, false))
  );
$$;

-- تقييد المشاريع: المستخدم غير الأدمن يشتغل بس على المشاريع المدرجة في profiles.allowed_projects بتاعه.
-- p_project = null (سجل مش مرتبط بمشروع محدد، زي مصروف عام) يفضل ظاهر للجميع بصرف النظر عن التقييد.
create or replace function has_project_access(p_project text)
returns boolean language sql stable security definer set search_path = public as $$
  select
    p_project is null
    or is_admin_user()
    or exists (
      select 1 from projects pr
      join profiles pf on pf.id = auth.uid()
      where pr.name = p_project and pr.code = any(pf.allowed_projects)
    );
$$;

drop policy if exists "read own or admin" on profiles;
create policy "read own or admin" on profiles for select using (id = auth.uid() or is_admin_user());

-- ============================================================
-- Row Level Security لجداول العمل
-- القراءة: متاحة لأي مستخدم مسجّل دخول وحسابه مفعّل (شاشات التقارير بتجمع بيانات
-- من كل الموديولات مع بعض، فمنع القراءة الجزئية هيدّي أرقام غلط بصمت).
-- الكتابة (إضافة/تعديل/حذف): مربوطة فعليًا بصلاحية التبويب المحدد نفسه (18 تبويب،
-- كل واحد مفتاح مستقل) — دي الحماية الحقيقية اللي متقدرش تتخطاها حتى لو حد فتح
-- Console وحاول يستدعي Supabase مباشرة.
-- ============================================================
do $$
declare
  rec record;
begin
  for rec in
    -- has_project: هل الجدول ده فيه عمود project لازم يتفلتر بيه على مستوى القاعدة نفسها؟
    select * from (values
      ('procurements','procurement', true),
      ('sales','sales', true),
      ('custodies','custody', true),
      ('employee_advances','payroll', false),
      ('attendance','payroll', false),
      ('assets','assets', false), -- الأصول مربوطة بعمود location مش project — بيتفلتر client-side بس حاليًا
      ('daily_journals','dailyjournal', true),
      ('payments','payments', true),
      ('contractor_payments','payments', true),
      ('refunds','payments', false),
      ('obligations','payments', false),
      ('investor_funding','investors', true),
      ('profit_distributions','investors', true),
      ('investor_liabilities','investors', true),
      ('manager_liabilities','investors', true),
      ('manager_payments','investors', false),
      ('external_investments','extinvest', true),
      ('taxes','pl', false),
      ('projects','masterdata', false), -- المشروع نفسه ليه سياسة خاصة تحت (بالكود مش بالاسم)
      ('supplies','masterdata', false),
      ('suppliers','masterdata', false),
      ('expense_categories','masterdata', false),
      ('activities','masterdata', false),
      ('names','masterdata', false),
      ('clients','masterdata', false),
      ('investors','masterdata', false),
      ('accounts','masterdata', false),
      ('employees','masterdata', false),
      ('asset_types','masterdata', false),
      ('units','masterdata', false)
    ) as t(tbl, module, has_project)
  loop
    execute format('alter table %I enable row level security;', rec.tbl);
    execute format('drop policy if exists "public full access" on %I;', rec.tbl);
    execute format('drop policy if exists "select_active" on %I;', rec.tbl);
    execute format('drop policy if exists "insert_module" on %I;', rec.tbl);
    execute format('drop policy if exists "update_module" on %I;', rec.tbl);
    execute format('drop policy if exists "delete_module" on %I;', rec.tbl);
    if rec.has_project then
      execute format('create policy "select_active" on %I for select using (is_active_user() and has_project_access(project));', rec.tbl);
      execute format('create policy "insert_module" on %I for insert with check (has_permission(%L, ''edit'') and has_project_access(project));', rec.tbl, rec.module);
      execute format('create policy "update_module" on %I for update using (has_permission(%L, ''edit'') and has_project_access(project)) with check (has_permission(%L, ''edit'') and has_project_access(project));', rec.tbl, rec.module, rec.module);
      execute format('create policy "delete_module" on %I for delete using (has_permission(%L, ''delete'') and has_project_access(project));', rec.tbl, rec.module);
    else
      execute format('create policy "select_active" on %I for select using (is_active_user());', rec.tbl);
      execute format('create policy "insert_module" on %I for insert with check (has_permission(%L, ''edit''));', rec.tbl, rec.module);
      execute format('create policy "update_module" on %I for update using (has_permission(%L, ''edit'')) with check (has_permission(%L, ''edit''));', rec.tbl, rec.module, rec.module);
      execute format('create policy "delete_module" on %I for delete using (has_permission(%L, ''delete''));', rec.tbl, rec.module);
    end if;
  end loop;

  -- المشاريع نفسها (دليل الأكواد → المشاريع): غير الأدمن يشوف/يعدّل/يحذف بس المشاريع المدرجة
  -- في allowed_projects بتاعه. الإضافة (insert) تفضل مربوطة بصلاحية دليل الأكواد العادية بس
  -- (مشروع جديد لسه معندوش كود يتقارن بيه أصلاً وقت الإنشاء).
  execute 'drop policy if exists "select_active" on projects;';
  execute 'drop policy if exists "update_module" on projects;';
  execute 'drop policy if exists "delete_module" on projects;';
  execute $q$create policy "select_active" on projects for select using (
    is_active_user() and (is_admin_user() or code = any((select allowed_projects from profiles where id = auth.uid())))
  );$q$;
  execute $q$create policy "update_module" on projects for update using (
    has_permission('masterdata','edit') and (is_admin_user() or code = any((select allowed_projects from profiles where id = auth.uid())))
  ) with check (
    has_permission('masterdata','edit') and (is_admin_user() or code = any((select allowed_projects from profiles where id = auth.uid())))
  );$q$;
  execute $q$create policy "delete_module" on projects for delete using (
    has_permission('masterdata','delete') and (is_admin_user() or code = any((select allowed_projects from profiles where id = auth.uid())))
  );$q$;

  -- expense_entries: مشترك بين 4 تبويبات (مصروفات/رواتب/مبيعات/عهد) — الصلاحية
  -- تُفحص ديناميكيًا من عمود source_module في كل صف بدل موديول ثابت، وبرضه مقيّدة بالمشروع
  execute 'alter table expense_entries enable row level security;';
  execute 'drop policy if exists "public full access" on expense_entries;';
  execute 'drop policy if exists "select_active" on expense_entries;';
  execute 'drop policy if exists "insert_module" on expense_entries;';
  execute 'drop policy if exists "update_module" on expense_entries;';
  execute 'drop policy if exists "delete_module" on expense_entries;';
  execute 'create policy "select_active" on expense_entries for select using (is_active_user() and has_project_access(project));';
  execute 'create policy "insert_module" on expense_entries for insert with check (has_permission(source_module, ''edit'') and has_project_access(project));';
  execute 'create policy "update_module" on expense_entries for update using (has_permission(source_module, ''edit'') and has_project_access(project)) with check (has_permission(source_module, ''edit'') and has_project_access(project));';
  execute 'create policy "delete_module" on expense_entries for delete using (has_permission(source_module, ''delete'') and has_project_access(project));';
end $$;

-- employee_project_allocations: إعداد إداري لتوزيع الرواتب — مربوط بصلاحية تبويب "الرواتب" العادية
-- (view/edit/delete)، من غير تقييد مشروع إضافي (هو أصلاً بيوصف العلاقة موظف↔مشروع نفسها).
alter table employee_project_allocations enable row level security;
drop policy if exists "select_active" on employee_project_allocations;
drop policy if exists "insert_module" on employee_project_allocations;
drop policy if exists "update_module" on employee_project_allocations;
drop policy if exists "delete_module" on employee_project_allocations;
create policy "select_active" on employee_project_allocations for select using (is_active_user());
create policy "insert_module" on employee_project_allocations for insert with check (has_permission('payroll', 'edit'));
create policy "update_module" on employee_project_allocations for update using (has_permission('payroll', 'edit')) with check (has_permission('payroll', 'edit'));
create policy "delete_module" on employee_project_allocations for delete using (has_permission('payroll', 'delete'));

-- audit_log: أي مستخدم مفعّل يقدر يسجّل حركاته هو (INSERT)، لكن القراءة مقفولة
-- على المدير بس، ومفيش تعديل أو حذف لأي حد — سجل غير قابل للتلاعب.
alter table audit_log enable row level security;
drop policy if exists "public full access" on audit_log;
drop policy if exists "insert own log" on audit_log;
drop policy if exists "select admin only" on audit_log;
create policy "insert own log" on audit_log for insert with check (is_active_user());
create policy "select admin only" on audit_log for select using (is_admin_user());

-- pending_changes: المستخدم يقدر يسجّل طلب باسمه هو بس، وبشرط يكون عنده أصلاً صلاحية edit/delete
-- على الموديول ده (منعًا لطلب حركة هو أصلاً ممنوع منها) — القراءة له طلباته بس أو للمدير كل الطلبات —
-- والتعديل (الموافقة/الرفض) للمدير بس، مفيش حذف خالص (سجل تاريخي دايمًا).
alter table pending_changes enable row level security;
drop policy if exists "insert own pending change" on pending_changes;
drop policy if exists "select own or admin" on pending_changes;
drop policy if exists "admin resolves" on pending_changes;
create policy "insert own pending change" on pending_changes for insert
  with check (user_id = auth.uid() and has_permission(module, case when action_type = 'delete' then 'delete' else 'edit' end));
create policy "select own or admin" on pending_changes for select using (user_id = auth.uid() or is_admin_user());
create policy "admin resolves" on pending_changes for update using (is_admin_user());

-- app_settings: جدول قديم غير مستخدم في التصميم الحالي — قراءة فقط للمفعّلين، بدون كتابة من المتصفح.
alter table app_settings enable row level security;
drop policy if exists "public full access" on app_settings;
drop policy if exists "select_active" on app_settings;
create policy "select_active" on app_settings for select using (is_active_user());

-- ---------- تفعيل Realtime عشان كل المستخدمين يشوفوا تحديثات بعض لحظياً ----------
do $$
declare t text;
begin
  for t in select unnest(array[
    'projects','supplies','suppliers','expense_categories','activities',
    'names','clients','investors','accounts','employees','asset_types','taxes','units',
    'procurements','sales','expense_entries','payments','contractor_payments',
    'refunds','investor_funding','profit_distributions','investor_liabilities',
    'manager_liabilities','manager_payments','custodies','employee_advances',
    'attendance','assets','daily_journals','obligations','external_investments',
    'audit_log','app_settings','employee_project_allocations'
  ])
  loop
    begin
      execute format('alter publication supabase_realtime add table %I;', t);
    exception when duplicate_object then
      null; -- الجدول متضاف بالفعل، تجاهل
    end;
  end loop;
end $$;

-- ============================================================
-- تتبّع "مين أضاف / مين آخر واحد عدّل" لكل سجل (تلقائي بالكامل من القاعدة نفسها،
-- عشان يبان في تلميح صغير (tooltip) عند الوقوف بالماوس على أي عملية في الواجهة)
-- ============================================================
create or replace function set_audit_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  uname text;
begin
  select username into uname from profiles where id = auth.uid();
  if TG_OP = 'INSERT' then
    new.created_by := coalesce(uname, new.created_by);
    new.updated_by := coalesce(uname, new.updated_by);
    new.updated_at := now();
  elsif TG_OP = 'UPDATE' then
    new.created_by := old.created_by; -- الحفاظ على أول من أضاف السجل
    new.updated_by := coalesce(uname, new.updated_by);
    new.updated_at := now();
  end if;
  return new;
end;
$$;

do $$
declare
  t text;
  tables_all text[] := array[
    'procurements','sales','expense_entries','payments','contractor_payments','refunds',
    'custodies','employee_advances','attendance','assets','daily_journals','obligations',
    'investor_funding','profit_distributions','investor_liabilities','manager_liabilities',
    'manager_payments','external_investments','taxes',
    'projects','supplies','suppliers','expense_categories','activities','names','clients',
    'investors','accounts','employees','asset_types','units','employee_project_allocations'
  ];
begin
  foreach t in array tables_all loop
    execute format('alter table %I add column if not exists created_by text;', t);
    execute format('alter table %I add column if not exists updated_by text;', t);
    execute format('alter table %I add column if not exists updated_at timestamptz;', t);
    execute format('drop trigger if exists trg_set_audit_columns on %I;', t);
    execute format('create trigger trg_set_audit_columns before insert or update on %I for each row execute function set_audit_columns();', t);
  end loop;
end $$;

-- ============================================================
-- ملاحظة تنصيب مهمة: الملف ده بيغطي قاعدة البيانات بس. عشان نظام المستخدمين
-- يشتغل كامل لازم كمان:
-- 1) نشر Edge Function اسمها "admin-users" (كودها في supabase/functions/admin-users
--    جوّه المشروع) — دي اللي بتنشئ/تعدّل/تعطّل/تمسح حسابات المستخدمين
--    باستخدام service_role بأمان من غير ما المفتاح يوصل للمتصفح أبدًا.
-- 2) بعد نشر الفنكشن، تشغيل أكشن "bootstrap_admin" مرة واحدة بس (عن طريق
--    طلب HTTPS مباشر للفنكشن، مش من الواجهة) عشان ينشئ حساب المدير الافتراضي.
--    بعد أول مرة، الأكشن ده بيتقفل تلقائيًا ومش هيشتغل تاني.
-- ============================================================
