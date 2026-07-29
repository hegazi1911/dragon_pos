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
  created_at timestamptz not null default now()
);

create table if not exists payments (
  id bigint generated always as identity primary key,
  supplier text not null,
  project text,
  amount numeric not null default 0,
  account text,
  items text[], -- أوصاف الفواتير المحددة اللي اتسددت بالدفعة دي (اختياري)
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists contractor_payments (
  id bigint generated always as identity primary key,
  name text not null,
  amount numeric not null default 0,
  project text,
  date date not null default current_date,
  notes text,
  created_at timestamptz not null default now()
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
  user_label text,
  created_at timestamptz not null default now()
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
  execute format('select nextval(%I)', seq_name) into n;
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
-- Row Level Security
-- ملاحظة أمان مهمة: التطبيق ده بيستخدم مفتاح publishable (client-side) بدون
-- نظام تسجيل دخول مستخدمين حقيقي — بوابة الدخول هي أكواد تفعيل مشتركة (أدوار:
-- مدير/محاسب/مشاهدة) محفوظة في localStorage بالمتصفح فقط. عشان التطبيق يقدر
-- يقرا/يكتب البيانات من المتصفح، السياسات هنا بتسمح بالقراءة والكتابة الكاملة
-- لأي حد معاه الـ URL والمفتاح (زي أي حد يعرف كود التفعيل). ده مش عزل بيانات
-- لكل مستخدم لوحده أو فرض صلاحيات الأدوار على مستوى القاعدة — فرض الأدوار
-- (مشاهدة فقط مثلاً) بيحصل في واجهة المستخدم بس.
-- ============================================================
do $$
declare t text;
begin
  for t in select unnest(array[
    'projects','supplies','suppliers','expense_categories','activities',
    'names','clients','investors','accounts','employees','asset_types','taxes',
    'procurements','sales','expense_entries','payments','contractor_payments',
    'refunds','investor_funding','profit_distributions','investor_liabilities',
    'manager_liabilities','manager_payments','custodies','employee_advances',
    'attendance','assets','daily_journals','obligations','external_investments',
    'audit_log','app_settings'
  ])
  loop
    execute format('alter table %I enable row level security;', t);
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
    'names','clients','investors','accounts','employees','asset_types','taxes',
    'procurements','sales','expense_entries','payments','contractor_payments',
    'refunds','investor_funding','profit_distributions','investor_liabilities',
    'manager_liabilities','manager_payments','custodies','employee_advances',
    'attendance','assets','daily_journals','obligations','external_investments',
    'audit_log','app_settings'
  ])
  loop
    begin
      execute format('alter publication supabase_realtime add table %I;', t);
    exception when duplicate_object then
      null; -- الجدول متضاف بالفعل، تجاهل
    end;
  end loop;
end $$;
