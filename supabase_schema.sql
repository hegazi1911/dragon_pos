-- ============================================================
-- نظام دراكون للمقاولات — هيكلة قاعدة بيانات Supabase
-- شغّلي الملف ده كامل مرة واحدة من: Supabase Dashboard > SQL Editor > New query
-- ============================================================

-- ---------- جداول دليل الأكواد (Master Data) ----------
create table if not exists projects (
  code integer primary key,
  name text not null unique,
  capital numeric -- إجمالي التمويل المستهدف للمشروع (لحساب نسبة كل مستثمر تلقائياً لاحقاً)
);

create table if not exists supplies (
  code integer primary key,
  name text not null unique,
  unit text
);

create table if not exists suppliers (
  code integer primary key,
  name text not null unique,
  items text[]
);

create table if not exists expense_categories (
  code integer primary key,
  name text not null unique,
  pl_type text not null check (pl_type in ('revenue','direct','operating','other','excluded')),
  pl_bucket text check (pl_bucket in ('admin','selling','other_operating'))
);

create table if not exists activities (
  code integer primary key,
  name text not null unique
);

create table if not exists names (
  code integer primary key,
  name text not null unique,
  contract_value numeric
);

create table if not exists clients (
  code integer primary key,
  name text not null unique,
  contract_value numeric
);

create table if not exists investors (
  code integer primary key,
  name text not null unique
);

-- ---------- جداول الحركات (Transactions) ----------
create table if not exists procurements (
  id bigint generated always as identity primary key,
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

create table if not exists expense_entries (
  id bigint generated always as identity primary key,
  category text not null,
  activity text,
  name text not null,
  project text not null,
  total numeric not null default 0,
  paid numeric not null default 0,
  remaining numeric not null default 0,
  executed_value numeric, -- القيمة المنفذة فعلياً (المستخلص) لقيود المقاولين فقط: الدين = executed_value - paid
  custody_id bigint, -- رابط للعهدة المؤقتة إذا نشأ هذا القيد من تسوية عهدة
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists payments (
  id bigint generated always as identity primary key,
  supplier text not null,
  project text,
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

-- ---------- إعدادات عامة (نسبة الضريبة إلخ) ----------
create table if not exists app_settings (
  key text primary key,
  value jsonb not null
);

insert into app_settings (key, value) values ('taxRate', '22.5') on conflict (key) do nothing;
insert into app_settings (key, value) values ('taxes', '[]') on conflict (key) do nothing;
insert into app_settings (key, value) values ('custodies', '[]') on conflict (key) do nothing;
insert into app_settings (key, value) values ('investorLiabilities', '[]') on conflict (key) do nothing;

-- ---------- فهارس لتسريع الفلاتر الشائعة ----------
create index if not exists idx_procurements_project on procurements(project);
create index if not exists idx_procurements_date on procurements(date);
create index if not exists idx_expense_entries_project on expense_entries(project);
create index if not exists idx_expense_entries_date on expense_entries(date);
create index if not exists idx_payments_supplier on payments(supplier);

-- ============================================================
-- Row Level Security
-- ملاحظة أمان مهمة: التطبيق ده بيستخدم مفتاح publishable (client-side) بدون
-- نظام تسجيل دخول مستخدمين حقيقي — بوابة الدخول هي كود تفعيل واحد مشترك.
-- عشان التطبيق يقدر يقرا/يكتب البيانات من المتصفح، السياسات هنا بتسمح
-- بالقراءة والكتابة الكاملة لأي حد معاه الـ URL والمفتاح (زي أي حد يعرف
-- كود التفعيل). ده نفس مستوى الحماية اللي كان موجود قبل كده تقريباً، لكن
-- خليكي عارفة إن ده مش عزل بيانات لكل مستخدم لوحده.
-- ============================================================
alter table projects enable row level security;
alter table supplies enable row level security;
alter table suppliers enable row level security;
alter table expense_categories enable row level security;
alter table activities enable row level security;
alter table names enable row level security;
alter table clients enable row level security;
alter table investors enable row level security;
alter table procurements enable row level security;
alter table expense_entries enable row level security;
alter table payments enable row level security;
alter table investor_funding enable row level security;
alter table profit_distributions enable row level security;
alter table app_settings enable row level security;

do $$
declare t text;
begin
  for t in select unnest(array[
    'projects','supplies','suppliers','expense_categories','activities',
    'names','clients','investors','procurements','expense_entries',
    'payments','investor_funding','profit_distributions','app_settings'
  ])
  loop
    execute format('drop policy if exists "public full access" on %I;', t);
    execute format('create policy "public full access" on %I for all using (true) with check (true);', t);
  end loop;
end $$;

-- ---------- تفعيل Realtime عشان كل المستخدمين يشوفوا تحديثات بعض لحظياً ----------
do $$
declare t text;
begin
  for t in select unnest(array[
    'projects','supplies','suppliers','expense_categories','activities',
    'names','clients','investors','procurements','expense_entries',
    'payments','investor_funding','profit_distributions','app_settings'
  ])
  loop
    begin
      execute format('alter publication supabase_realtime add table %I;', t);
    exception when duplicate_object then
      null; -- الجدول متضاف بالفعل، تجاهل
    end;
  end loop;
end $$;

-- ---------- ترحيل: إضافة عمود custody_id إن لم يكن موجوداً (لقواعد البيانات القديمة) ----------
alter table expense_entries add column if not exists custody_id bigint;
