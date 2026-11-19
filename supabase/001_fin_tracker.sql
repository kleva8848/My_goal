-- Фін трекер: вся логіка тут. n8n лише вставляє рядок у fin_inbox, а BEFORE INSERT тригер
-- заповнює reaction (емодзі на повідомлення) і reply (текст відповіді або null = мовчати).
-- Запуск: Supabase → SQL Editor → виконати весь файл. Повторний запуск безпечний (create or replace / if not exists).

-- ───────────── Таблиці ─────────────
create table if not exists fin_settings (key text primary key, value text);
insert into fin_settings(key, value) values
  ('owner_chat_id', ''),     -- заповниться саме першим повідомленням боту
  ('tz', 'Europe/Kyiv'),
  ('debt_share', '80'),      -- % додаткового доходу на борги
  ('warn_pct', '25'),        -- попередження, коли в категорії лишилось ≤ N%
  ('plan_from_day', '25')    -- з цього числа «категорія/дохід» пишуться в план НАСТУПНОГО місяця
on conflict (key) do nothing;

create table if not exists fin_categories (
  id serial primary key,
  name text unique not null,
  aliases text[] not null default '{}',
  fixed boolean not null default false,       -- обов'язкова (комуналка, зв'язок): не радимо урізати
  created_at timestamptz not null default now()
);
insert into fin_categories(name) values ('інше') on conflict (name) do nothing;

create table if not exists fin_budgets (       -- ліміт категорії на місяць; діє до наступного запису
  month date not null,
  category_id int not null references fin_categories(id) on delete cascade,
  amount numeric not null,
  primary key (month, category_id)
);

create table if not exists fin_months (        -- план доходу; діє до наступного запису
  month date primary key,
  income_plan numeric not null default 0
);

create table if not exists fin_debts (
  id serial primary key,
  name text unique not null,
  aliases text[] not null default '{}',
  start_balance numeric not null,
  balance numeric not null,
  monthly_payment numeric not null default 0,
  closed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists fin_goals (         -- обов'язкові майбутні витрати: на них відкладаємо щомісяця
  id serial primary key,
  name text unique not null,
  aliases text[] not null default '{}',
  amount numeric not null,
  due_date date not null,
  saved numeric not null default 0,
  done_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists fin_balance (       -- фактичні залишки, які ти вносиш
  id serial primary key,
  at timestamptz not null default now(),
  amount numeric not null
);

create table if not exists fin_tx (
  id bigserial primary key,
  at timestamptz not null default now(),
  amount numeric not null,                     -- витрати/платежі < 0, доходи > 0
  kind text not null check (kind in ('expense', 'income', 'debt', 'goal')),
  category_id int references fin_categories(id) on delete set null,
  debt_id int references fin_debts(id) on delete set null,
  goal_id int references fin_goals(id) on delete set null,
  note text,
  chat_id bigint,
  message_id bigint,
  unique (chat_id, message_id)
);
alter table fin_tx add column if not exists period date;   -- місяць, якому належить дохід (якщо не за датою запису)
create index if not exists fin_tx_at on fin_tx(at);

create table if not exists fin_alerts (        -- щоб не спамити одним і тим самим попередженням
  month date not null,
  key text not null,
  primary key (month, key)
);

create table if not exists fin_inbox (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  kind text not null default 'msg',            -- msg | weekly | plan | month
  chat_id bigint,
  message_id bigint,
  reply_to bigint,
  text text,
  reaction text,
  reply text
);
alter table fin_inbox add column if not exists keyboard jsonb;   -- inline-кнопки до reply (reply_markup)
alter table fin_inbox add column if not exists cb_id text;       -- id натискання кнопки (callback_query)

alter table fin_settings enable row level security;
alter table fin_categories enable row level security;
alter table fin_budgets enable row level security;
alter table fin_months enable row level security;
alter table fin_debts enable row level security;
alter table fin_goals enable row level security;
alter table fin_balance enable row level security;
alter table fin_tx enable row level security;
alter table fin_alerts enable row level security;
alter table fin_inbox enable row level security;

-- ───────────── Хелпери ─────────────
create or replace function fin_set(k text) returns text language sql stable as
$$ select value from fin_settings where key = k $$;

create or replace function fin_now() returns timestamp language sql stable as
$$ select now() at time zone coalesce(fin_set('tz'), 'Europe/Kyiv') $$;

create or replace function fin_local(t timestamptz) returns timestamp language sql stable as
$$ select t at time zone coalesce(fin_set('tz'), 'Europe/Kyiv') $$;

create or replace function fin_month() returns date language sql stable as
$$ select date_trunc('month', fin_now())::date $$;

-- місяць, у який пишуть команди планування
create or replace function fin_plan_month() returns date language sql stable as $$
  select case when extract(day from fin_now()) >= coalesce(fin_set('plan_from_day'), '25')::int
              then (fin_month() + interval '1 month')::date else fin_month() end
$$;

create or replace function fin_m(n numeric) returns text language sql immutable as
$$ select replace(to_char(round(coalesce(n, 0)), 'FM999,999,999,990'), ',', ' ') $$;

create or replace function fin_mname(m date) returns text language sql immutable as $$
  select (array['січень','лютий','березень','квітень','травень','червень','липень','серпень','вересень','жовтень','листопад','грудень'])[extract(month from m)::int]
$$;

create or replace function fin_limit(cat int, m date) returns numeric language sql stable as $$
  select coalesce((select amount from fin_budgets where category_id = cat and month <= m order by month desc limit 1), 0)
$$;

create or replace function fin_income_plan(m date) returns numeric language sql stable as $$
  select coalesce((select income_plan from fin_months where month <= m order by month desc limit 1), 0)
$$;

-- сума руху за місяць (за київським часом)
create or replace function fin_sum(m date, k text, cat int default null, debt int default null) returns numeric language sql stable as $$
  select coalesce(sum(amount), 0) from fin_tx
  where kind = k and coalesce(period, date_trunc('month', fin_local(at))::date) = m
    and (cat is null or category_id = cat) and (debt is null or debt_id = debt)
$$;

create or replace function fin_cash() returns numeric language sql stable as $$
  select b.amount + coalesce((select sum(t.amount) from fin_tx t where t.at > b.at), 0)
  from fin_balance b order by b.at desc limit 1
$$;

-- скільки треба відкласти на ціль у місяці m
create or replace function fin_goal_contrib(g fin_goals, m date) returns numeric language sql stable as $$
  select case when g.done_at is not null or g.amount - greatest(g.saved, 0) <= 0 then 0
    else ceil((g.amount - greatest(g.saved, 0)) / greatest(
      (extract(year from g.due_date) * 12 + extract(month from g.due_date)) - (extract(year from m) * 12 + extract(month from m)), 1))
  end
$$;

-- запланований платіж по боргу в місяці m (не більше залишку боргу)
create or replace function fin_debt_planned(d fin_debts, m date) returns numeric language sql stable as $$
  select least(d.monthly_payment, d.balance + (-fin_sum(m, 'debt', null, d.id)))
$$;

-- головний розрахунок: скільки реально вільно до кінця місяця
create or replace function fin_forecast() returns jsonb language plpgsql stable as $$
declare
  m date := fin_month();
  cash numeric := fin_cash();
  plan numeric := fin_income_plan(m);
  inc numeric := fin_sum(m, 'income');
  cat_left numeric := 0; debt_left numeric := 0; goal_res numeric := 0;
  planned_pay numeric := 0; paid numeric := -fin_sum(m, 'debt');
  extra numeric; debt_res numeric; free numeric;
  earm numeric := coalesce((select sum(amount) from fin_tx where kind = 'income' and period > m), 0);   -- дохід, що вже тут, але належить наступним місяцям
  r record;
begin
  for r in select id from fin_categories loop
    cat_left := cat_left + greatest(fin_limit(r.id, m) + fin_sum(m, 'expense', r.id), 0);
  end loop;
  for r in select d from fin_debts d where d.closed_at is null or fin_local(d.closed_at) >= m loop
    planned_pay := planned_pay + fin_debt_planned(r.d, m);
    debt_left := debt_left + greatest(fin_debt_planned(r.d, m) + fin_sum(m, 'debt', null, (r.d).id), 0);
  end loop;
  for r in select g from fin_goals g where g.done_at is null loop
    goal_res := goal_res + greatest((r.g).saved, 0) + fin_goal_contrib(r.g, m);
  end loop;
  extra := case when plan > 0 then greatest(inc - plan, 0) else 0 end;
  debt_res := greatest(extra * coalesce(fin_set('debt_share'), '80')::numeric / 100 - greatest(paid - planned_pay, 0), 0);
  free := cash + greatest(plan - inc, 0) - cat_left - debt_left - goal_res - debt_res - earm;
  return jsonb_build_object('cash', cash, 'earmarked', earm, 'income_left', greatest(plan - inc, 0), 'cat_left', cat_left,
    'debt_left', debt_left, 'goal_res', goal_res, 'debt_res', debt_res, 'free', free);
end $$;

-- токени для пошуку категорії/боргу/цілі
create or replace function fin_tokens(t text) returns text[] language sql immutable as
$$ select array_remove(regexp_split_to_array(lower(coalesce(t, '')), '[^[:alnum:]]+'), '') $$;

-- аліас ≥4 літер — збіг за початком слова («обід» → «обіди»), коротший — тільки точний («тас»)
create or replace function fin_hit(tokens text[], name text, aliases text[]) returns int language sql immutable as $$
  select coalesce(max(length(a)), 0) from unnest(array_append(aliases, lower(name))) a, unnest(tokens) t
  where t = a or (length(a) >= 4 and t like a || '%')
$$;

create or replace function fin_ensure_owner(chat bigint) returns boolean language plpgsql as $$
declare o text := fin_set('owner_chat_id');
begin
  if coalesce(o, '') = '' then
    update fin_settings set value = chat::text where key = 'owner_chat_id';
    return true;
  end if;
  return o = chat::text;
end $$;

-- одноразове попередження за місяць; true = ще не було
create or replace function fin_alert_once(k text) returns boolean language plpgsql as $$
begin
  insert into fin_alerts(month, key) values (fin_month(), k);
  return true;
exception when unique_violation then return false;
end $$;

-- ───────────── Звіти ─────────────
create or replace function fin_debts_text() returns text language sql stable as $$
  select coalesce(string_agg('• ' || name || ': ' || fin_m(balance) || ' з ' || fin_m(start_balance)
    || case when monthly_payment > 0 then ' (платіж ' || fin_m(monthly_payment) || ')' else '' end, E'\n' order by balance), '—')
  from fin_debts where closed_at is null
$$;

create or replace function fin_goals_text() returns text language sql stable as $$
  select coalesce(string_agg('• ' || name || ': відкладено ' || fin_m(greatest(saved, 0)) || ' з ' || fin_m(amount)
    || ' до ' || to_char(due_date, 'DD.MM.YYYY') || ' (цього міс. ' || fin_m(fin_goal_contrib(g, fin_month())) || ')', E'\n' order by due_date), '—')
  from fin_goals g where done_at is null
$$;

create or replace function fin_status_text() returns text language plpgsql stable as $$
declare f jsonb := fin_forecast();
begin
  if f->>'cash' is null then return '💵 Фактичний залишок ще не внесено — напиши: залишок 12000'; end if;
  return '💵 Гроші зараз: ' || fin_m((f->>'cash')::numeric)
    || case when (f->>'income_left')::numeric > 0 then E'\n➕ Ще очікується дохід: ' || fin_m((f->>'income_left')::numeric) else '' end
    || case when (f->>'earmarked')::numeric > 0 then E'\n📅 З цих грошей не мої цього місяця (дохід наперед): ' || fin_m((f->>'earmarked')::numeric) else '' end
    || E'\n➖ Ще заплановано: категорії ' || fin_m((f->>'cat_left')::numeric) || ', борги ' || fin_m((f->>'debt_left')::numeric)
    || case when (f->>'goal_res')::numeric > 0 then ', цілі ' || fin_m((f->>'goal_res')::numeric) else '' end
    || case when (f->>'debt_res')::numeric > 0 then E'\n🏦 Відкласти з дод. доходу на борги: ' || fin_m((f->>'debt_res')::numeric) else '' end
    || case when (f->>'free')::numeric >= 0 then E'\n✅ Вільно до кінця місяця: ' || fin_m((f->>'free')::numeric)
            else E'\n🚨 План у мінусі: ' || fin_m((f->>'free')::numeric) || ' — треба урізати витрати' end
    || case when exists (select 1 from fin_categories c where fin_limit(c.id, fin_month()) + fin_sum(fin_month(), 'expense', c.id) < 0)
            then E'\n👉 Є категорії понад ліміт — напиши «вирівняй», покриємо з іншої' else '' end;
end $$;

create or replace function fin_weekly_text() returns text language plpgsql stable as $$
declare
  m date := fin_month();
  since timestamptz := now() - interval '7 days';
  week numeric; lines text; inc numeric;
begin
  select -coalesce(sum(amount), 0) into week from fin_tx where at > since and kind in ('expense', 'goal');
  select coalesce(sum(amount), 0) into inc from fin_tx where at > since and kind = 'income';
  select string_agg(l, E'\n' order by s desc) into lines from (
    select -coalesce(sum(t.amount) filter (where t.at > since), 0) s,
      '• ' || c.name || ': ' || fin_m(-coalesce(sum(t.amount) filter (where t.at > since), 0))
      || case when fin_limit(c.id, m) > 0 then ' · за місяць ' || fin_m(-fin_sum(m, 'expense', c.id)) || '/' || fin_m(fin_limit(c.id, m))
           || ' · лишилось ' || fin_m(fin_limit(c.id, m) + fin_sum(m, 'expense', c.id))
           || ' (' || greatest(round(100 * (fin_limit(c.id, m) + fin_sum(m, 'expense', c.id)) / fin_limit(c.id, m)), 0) || '%)'
         else '' end l
    from fin_categories c left join fin_tx t on t.category_id = c.id and t.kind = 'expense' and fin_local(t.at) >= m
    group by c.id, c.name
    having coalesce(sum(t.amount) filter (where t.at > since), 0) <> 0 or fin_limit(c.id, m) > 0
  ) x;
  return '📊 Звірка за тиждень (' || to_char(fin_local(since), 'DD.MM') || '–' || to_char(fin_now(), 'DD.MM') || E')\n'
    || 'Витрачено: ' || fin_m(week) || case when inc > 0 then ' · дохід: +' || fin_m(inc) else '' end
    || E'\n\n' || coalesce(lines, 'Витрат не було')
    || E'\n\n💳 Борги (сплачено цього міс. ' || fin_m(-fin_sum(m, 'debt')) || E'):\n' || fin_debts_text()
    || case when exists (select 1 from fin_goals where done_at is null) then E'\n\n🎯 Цілі:\n' || fin_goals_text() else '' end
    || E'\n\n' || fin_status_text();
end $$;

create or replace function fin_plan_text(m date) returns text language sql stable as $$
  select '📝 План на ' || fin_mname(m) || E'\n'
    || 'Дохід: ' || fin_m(fin_income_plan(m))
    || E'\n\nКатегорії:\n' || coalesce((select string_agg('• ' || name || ': ' || fin_m(fin_limit(id, m)) || case when fixed then ' (обов''язкова)' else '' end
         || case when cardinality(aliases) > 0 then ' — ' || array_to_string(aliases, ', ') else '' end, E'\n' order by fin_limit(id, m) desc)
         from fin_categories), '—')
    || E'\n\n💳 Борги:\n' || fin_debts_text()
    || E'\n\n🎯 Цілі:\n' || fin_goals_text()
    || E'\n\nВитрати за планом: ' || fin_m(
         coalesce((select sum(fin_limit(id, m)) from fin_categories), 0)
       + coalesce((select sum(least(monthly_payment, balance)) from fin_debts where closed_at is null), 0)
       + coalesce((select sum(fin_goal_contrib(g, m)) from fin_goals g where done_at is null), 0))
$$;

-- бюджет місяця: план / факт по категоріях, окремо обов'язкові (fixed + борги) і гнучкі, скільки можна на день
create or replace function fin_bline(nm text, p numeric, f numeric) returns text language sql immutable as $$
  select '• ' || nm || ': ' || fin_m(f) || ' / ' || fin_m(p)
    || case when f > p then ' 🔴 +' || fin_m(f - p) when p > 0 and f = p then ' ✅' else ' · ще ' || fin_m(p - f) end
$$;

create or replace function fin_budget_text() returns text language plpgsql stable as $$
declare
  m date := fin_month();
  days int := greatest((m + interval '1 month')::date - fin_now()::date, 1);   -- з сьогоднішнім включно
  fc jsonb := fin_forecast();
  fix_lines text; flex_lines text; debt_lines text;
  fix_p numeric; fix_f numeric; fix_l numeric; flex_p numeric; flex_f numeric; flex_l numeric;
  d_p numeric; d_f numeric; d_l numeric; real_l numeric;
begin
  select string_agg(fin_bline(name, p, f), E'\n' order by p desc) filter (where fixed),
         string_agg(fin_bline(name, p, f), E'\n' order by p desc) filter (where not fixed),
         coalesce(sum(p) filter (where fixed), 0), coalesce(sum(f) filter (where fixed), 0), coalesce(sum(greatest(p - f, 0)) filter (where fixed), 0),
         coalesce(sum(p) filter (where not fixed), 0), coalesce(sum(f) filter (where not fixed), 0), coalesce(sum(greatest(p - f, 0)) filter (where not fixed), 0)
    into fix_lines, flex_lines, fix_p, fix_f, fix_l, flex_p, flex_f, flex_l
    from (select name, fixed, fin_limit(id, m) p, -fin_sum(m, 'expense', id) f from fin_categories) c
   where p > 0 or f > 0;

  select string_agg(fin_bline('💳 ' || name, p, f), E'\n' order by p desc),
         coalesce(sum(p), 0), coalesce(sum(f), 0), coalesce(sum(greatest(p - f, 0)), 0)
    into debt_lines, d_p, d_f, d_l
    from (select d.name, fin_debt_planned(d, m) p, -fin_sum(m, 'debt', null, d.id) f
            from fin_debts d where d.closed_at is null or fin_local(d.closed_at) >= m) x
   where p > 0 or f > 0;

  fix_lines := concat_ws(E'\n', fix_lines, debt_lines);
  fix_p := fix_p + d_p; fix_f := fix_f + d_f; fix_l := fix_l + d_l;

  return '📊 Бюджет · ' || fin_mname(m) || E' (факт / план)\n'
    || E'\n📌 Обов''язкові\n' || coalesce(nullif(fix_lines, ''), '—')
    || E'\nРазом: ' || fin_m(fix_f) || ' / ' || fin_m(fix_p) || ' · ще ' || fin_m(fix_l)
    || E'\n\n🛒 Гнучкі\n' || coalesce(flex_lines, '—')
    || E'\nРазом: ' || fin_m(flex_f) || ' / ' || fin_m(flex_p) || ' · ще ' || fin_m(flex_l)
    || E'\n\n📅 До кінця місяця: ' || days || ' дн. (з сьогодні)'
    || E'\n👉 На гнучкі: ' || fin_m(flex_l) || ' ÷ ' || days || ' = ' || fin_m(floor(flex_l / days)) || ' на день'
    || case when fc->>'cash' is null then E'\n\n💵 Залишок не внесено — напиши: залишок 12000'
       else E'\n\n💵 Гроші зараз: ' || fin_m((fc->>'cash')::numeric)
         || case when (fc->>'free')::numeric >= 0 then E'\n✅ Поза планом вільно: ' || fin_m((fc->>'free')::numeric)
            else E'\n⚠️ Грошей менше, ніж треба за планом, на ' || fin_m(-(fc->>'free')::numeric)
              || E'\nРеально на гнучкі: ' || fin_m(greatest(flex_l + (fc->>'free')::numeric, 0)) || ' → '
              || fin_m(floor(greatest(flex_l + (fc->>'free')::numeric, 0) / days)) || ' на день' end end;
end $$;

create or replace function fin_help_text() returns text language sql immutable as $$ select
'🧾 Фін трекер — шпаргалка

🚀 Старт (один раз)
1️⃣ Категорії: категорія їжа 8000 сільпо атб
2️⃣ Сьогоднішні витрати: -390 ютуб
3️⃣ Залишок останнім: залишок 12000

✍️ Щодня
➖ -390 ютуб — витрата
➕ +5000 зп — дохід
💳 -3000 тас — платіж по боргу
🔢 -2к сільпо — можна з «к»
↩️ відміна — прибрати останній запис (або відповіддю на потрібне повідомлення)

👀 Реакції
👍 записано в категорію
👌 записано в «інше»
🔥 дохід

⚙️ Налаштування
💵 залишок 12000 — скільки грошей зараз (від цього все рахується)
📈 дохід 40000 — план доходу на місяць
🗂 категорія їжа 8000 сільпо атб обід — ліміт + слова-підказки
📌 категорія комуналка 3000 ! — «!» = обов''язкова, не радити урізати
🏦 борг тас 25000 3000 таскомбанк — залишок боргу, платіж/міс, назви
🎯 ціль резина 8000 01.11.2027 — відкладаю щомісяця

❓ Питання
📊 бюджет — план / факт, обов''язкові окремо, скільки можна на день
💰 стан — скільки грошей і скільки вільно
🤔 можу 5000 — чи потягну і що урізати
⚖️ вирівняй — категорія понад ліміт? обери кнопкою, з якої покрити
📊 звіт — звірка за тиждень
🗓 план — план місяця

💡 Після 25-го «дохід» і «категорія» йдуть у план наступного місяця.' $$;

-- ───────────── Дії ─────────────
create or replace function fin_afford(x numeric) returns text language plpgsql stable as $$
declare
  m date := fin_month();
  f jsonb := fin_forecast();
  free numeric := (f->>'free')::numeric;
  short numeric; take numeric; tips text := ''; cashnote text := ''; r record;
begin
  if f->>'cash' is null then return 'Спершу внеси фактичний залишок: залишок 12000'; end if;
  if (f->>'cash')::numeric < x then
    cashnote := E'\n⚠️ На руках зараз ' || fin_m((f->>'cash')::numeric) || ' — частину доведеться чекати з доходу.';
  end if;
  if free >= x then
    return '✅ Можна. Після оплати ' || fin_m(x) || ' вільно до кінця місяця лишиться ' || fin_m(free - x) || '.' || cashnote;
  end if;
  short := x - greatest(free, 0);
  tips := E'Вільно до кінця місяця: ' || fin_m(free) || ', треба ' || fin_m(x) || ' → бракує ' || fin_m(short) || E'.\nЩо можна вивільнити:';
  -- 1) гнучкі категорії: найбільший залишок першим
  for r in select c.name, fin_limit(c.id, m) + fin_sum(m, 'expense', c.id) left_ from fin_categories c
           where not c.fixed and fin_limit(c.id, m) + fin_sum(m, 'expense', c.id) > 0 order by 2 desc loop
    exit when short <= 0;
    take := least(r.left_, short);
    tips := tips || E'\n• урізати «' || r.name || '» на ' || fin_m(take) || ' (з ' || fin_m(r.left_) || ' залишку)';
    short := short - take;
  end loop;
  -- 2) відкласти внесок у ціль цього місяця
  for r in select g.name, fin_goal_contrib(g, m) c from fin_goals g where g.done_at is null and fin_goal_contrib(g, m) > 0 order by g.due_date desc loop
    exit when short <= 0;
    take := least(r.c, short);
    tips := tips || E'\n• цього місяця не відкладати на «' || r.name || '» ' || fin_m(take) || ' (доженеш пізніше)';
    short := short - take;
  end loop;
  -- 3) гроші, відкладені з додаткового доходу на борги
  if short > 0 and (f->>'debt_res')::numeric > 0 then
    take := least((f->>'debt_res')::numeric, short);
    tips := tips || E'\n• взяти ' || fin_m(take) || ' з того, що відкладено на дострокове погашення';
    short := short - take;
  end if;
  if short > 0 then
    return '❌ Без нового доходу не вийде.' || E'\n' || tips || E'\n\nНавіть після цього бракує ' || fin_m(short)
      || E'.\nЦе мінус = знову кредит. Варіанти: відкласти, знайти дод. дохід або платити частинами.' || cashnote;
  end if;
  return '🟡 Можна, але тільки якщо урізати.' || E'\n' || tips || cashnote;
end $$;

-- ───────────── Вирівняти перевищення: кнопками обрати категорію, з якої покрити ─────────────
-- кнопки: гнучкі категорії з залишком (найбільший першим), по 2 в ряд + «Лишити як є»; null = нема з чого покрити
create or replace function fin_fix_kb(cat int) returns jsonb language sql stable as $$
  with c as (
    select id, name, fin_limit(id, fin_month()) + fin_sum(fin_month(), 'expense', id) left_
    from fin_categories where id <> cat and not fixed
  ), b as (
    select (row_number() over (order by left_ desc, id) - 1)::int rn,
      jsonb_build_object('text', name || ' · ще ' || fin_m(left_), 'callback_data', 'mv:' || cat || ':' || id) btn
    from c where left_ > 0 order by left_ desc, id limit 6
  ), r as (
    select rn / 2 k, jsonb_agg(btn order by rn) row_ from b group by rn / 2
  )
  select case when exists (select 1 from b) then jsonb_build_object('inline_keyboard',
    (select jsonb_agg(row_ order by k) from r)
    || jsonb_build_array(jsonb_build_array(jsonb_build_object('text', 'Лишити як є', 'callback_data', 'mv:no')))) end
$$;

-- «вирівняй»: найбільше перевищення цього місяця + кнопки
create or replace function fin_fix_offer(out reply text, out keyboard jsonb) language plpgsql stable as $$
declare m date := fin_month(); r record; others text;
begin
  select id, name, -(fin_limit(id, m) + fin_sum(m, 'expense', id)) over_ into r
    from fin_categories where fin_limit(id, m) + fin_sum(m, 'expense', id) < 0 order by 3 desc limit 1;
  if r.id is null then reply := E'✅ Усі категорії в межах ліміту.\n\n' || fin_status_text(); return; end if;
  keyboard := fin_fix_kb(r.id);
  select string_agg('«' || name || '» ' || fin_m(-(fin_limit(id, m) + fin_sum(m, 'expense', id))), ', ') into others
    from fin_categories where id <> r.id and fin_limit(id, m) + fin_sum(m, 'expense', id) < 0;
  reply := '🔴 «' || r.name || '» понад ліміт на ' || fin_m(r.over_)
    || case when keyboard is null then E'.\nНема гнучких категорій із залишком — покрити нічим 😕'
            else E'\n👇 З якої категорії покрити ' || fin_m(r.over_) || '?' end
    || case when others is not null then E'\n\nТакож понад ліміт: ' || others || E' — потім ще раз «вирівняй»' else '' end;
end $$;

-- натиснули кнопку: ліміт перевищеної категорії += перевищення, ліміт обраної −= стільки ж (лише цей місяць)
create or replace function fin_cover(over_cat int, src int) returns text language plpgsql as $$
declare
  m date := fin_month(); nx date := (fin_month() + interval '1 month')::date;
  a fin_categories; b fin_categories; amt numeric; b_left numeric;
begin
  select * into a from fin_categories where id = over_cat;
  select * into b from fin_categories where id = src;
  if a.id is null or b.id is null then return 'Категорію не знайдено 🤷'; end if;
  amt := -(fin_limit(a.id, m) + fin_sum(m, 'expense', a.id));
  if amt <= 0 then return '✅ «' || a.name || '» вже в межах ліміту.' || E'\n\n' || fin_status_text(); end if;
  -- ліміт «діє до наступного запису» → фіксуємо наступний місяць як був, щоб зміна не перейшла далі
  insert into fin_budgets(month, category_id, amount)
    values (nx, a.id, fin_limit(a.id, nx)), (nx, b.id, fin_limit(b.id, nx)) on conflict do nothing;
  insert into fin_budgets(month, category_id, amount)
    values (m, a.id, fin_limit(a.id, m) + amt), (m, b.id, fin_limit(b.id, m) - amt)
    on conflict (month, category_id) do update set amount = excluded.amount;
  delete from fin_alerts where month = m and key in ('over:' || a.id, 'warn:' || a.id);   -- щоб нове перевищення знову попередило
  b_left := fin_limit(b.id, m) + fin_sum(m, 'expense', b.id);
  return '⚖️ Покрив ' || fin_m(amt) || ' з «' || b.name || '»'
    || E'\n✅ «' || a.name || '»: ліміт ' || fin_m(fin_limit(a.id, m)) || ' — в межах'
    || E'\n➖ «' || b.name || '»: ліміт ' || fin_m(fin_limit(b.id, m)) || ', '
    || case when b_left >= 0 then 'лишилось ' || fin_m(b_left) else '🔴 понад ліміт на ' || fin_m(-b_left) end
    || E'\n\n' || fin_status_text();
end $$;

create or replace function fin_upsert_aliases(old text[], words text[]) returns text[] language sql immutable as
$$ select case when cardinality(words) > 0 then words else old end $$;

create or replace function fin_undo(chat bigint, reply_to bigint) returns text language plpgsql as $$
declare t fin_tx;
begin
  if reply_to is not null then select * into t from fin_tx where chat_id = chat and message_id = reply_to;
  else select * into t from fin_tx order by id desc limit 1; end if;
  if t.id is null then return 'Нема що видаляти'; end if;
  if t.kind = 'debt' then
    update fin_debts set balance = balance - t.amount, closed_at = null where id = t.debt_id;
  elsif t.kind = 'goal' then
    update fin_goals set saved = saved - t.amount, done_at = null where id = t.goal_id;
  end if;
  delete from fin_tx where id = t.id;
  return '↩️ Видалив: ' || case when t.amount > 0 then '+' else '' end || fin_m(t.amount) || ' ' || coalesce(t.note, '');
end $$;

-- «грудень»/«грудня»/«груд» у примітці доходу → перше число найближчого такого місяця (не раніше поточного)
create or replace function fin_month_word(tok text[]) returns date language plpgsql stable as $$
declare
  pats text[] := array['^(січ|січня|січень)$', '^(лют|лютого|лютий)$', '^(бер|березня|березень)$', '^(кві|квіт|квітня|квітень)$',
    '^(тра|трав|травня|травень)$', '^(чер|черв|червня|червень)$', '^(лип|липня|липень)$', '^(сер|серп|серпня|серпень)$',
    '^(вер|вересня|вересень)$', '^(жов|жовт|жовтня|жовтень)$', '^(лис|листопада|листопад)$', '^(гру|груд|грудня|грудень)$'];
  i int; t text; cur date := fin_month(); y int := extract(year from cur)::int; d date;
begin
  foreach t in array tok loop
    for i in 1..12 loop
      if t ~ pats[i] then
        d := make_date(y, i, 1);
        if d < cur then d := make_date(y + 1, i, 1); end if;
        return d;
      end if;
    end loop;
  end loop;
  return null;
end $$;

-- запис руху; повертає (reaction, reply, keyboard)
drop function if exists fin_record(bigint, bigint, text, numeric, text);   -- стара версія без keyboard
create or replace function fin_record(p_chat bigint, p_msg bigint, p_sign text, p_amount numeric, p_note text,
  out reaction text, out reply text, out keyboard jsonb)
language plpgsql as $$
declare
  m date := fin_month();
  tok text[] := fin_tokens(p_note);
  free_before numeric := (fin_forecast()->>'free')::numeric;
  free_after numeric;
  d fin_debts; g fin_goals; c fin_categories; im date;
  plan numeric; inc_before numeric; extra numeric; lim numeric; left_ numeric; msgs text[] := '{}';
begin
  if exists (select 1 from fin_tx where chat_id = p_chat and message_id = p_msg) then reaction := '👍'; return; end if;

  if p_sign = '+' then
    im := coalesce(fin_month_word(tok), m);
    plan := fin_income_plan(im);
    inc_before := fin_sum(im, 'income');
    insert into fin_tx(amount, kind, note, chat_id, message_id, period) values (p_amount, 'income', p_note, p_chat, p_msg, case when im <> m then im end);
    reaction := '🔥';
    if im <> m then
      reply := '📅 Дохід ' || fin_m(p_amount) || ' записано на ' || to_char(im, 'MM.YYYY') || ' — у поточний місяць не рахується (гроші вже в «зараз»).';
      return;
    end if;
    extra := case when plan > 0 then greatest(inc_before + p_amount - plan, 0) - greatest(inc_before - plan, 0) else 0 end;
    if extra > 0 then
      select * into d from fin_debts where closed_at is null order by balance limit 1;
      reply := '💰 Понад план: +' || fin_m(extra) || E'\n'
        || coalesce(fin_set('debt_share'), '80') || '% = ' || fin_m(extra * coalesce(fin_set('debt_share'), '80')::numeric / 100) || ' → на борги'
        || case when d.id is not null then ' (найближче до закриття: ' || d.name || ', лишилось ' || fin_m(d.balance) || ')' else '' end
        || E'\n' || (100 - coalesce(fin_set('debt_share'), '80')::int) || '% = ' || fin_m(extra * (100 - coalesce(fin_set('debt_share'), '80')::numeric) / 100) || ' → на життя';
    end if;
    return;
  end if;

  -- витрата: борг > ціль > категорія
  select * into d from fin_debts where closed_at is null and fin_hit(tok, name, aliases) > 0 order by fin_hit(tok, name, aliases) desc limit 1;
  if d.id is not null then
    insert into fin_tx(amount, kind, debt_id, note, chat_id, message_id) values (-p_amount, 'debt', d.id, p_note, p_chat, p_msg);
    update fin_debts set balance = balance - p_amount where id = d.id returning * into d;
    reaction := '👍';
    if d.balance <= 0 then
      update fin_debts set closed_at = now(), balance = 0 where id = d.id;
      reaction := '🎉';
      msgs := msgs || ('🎉🎉🎉 ' || upper(d.name) || ' ЗАКРИТО! 🎉🎉🎉' || E'\n\nМінус ' || fin_m(d.start_balance) || ' боргу. Ти красава 💪'
        || coalesce(E'\nЛишилось боргів: ' || (select count(*) || ' на ' || fin_m(sum(balance)) from fin_debts where closed_at is null having count(*) > 0),
                    E'\nЦЕ БУВ ОСТАННІЙ БОРГ. Ти вільний! 🏁🥂')
        || E'\nПлатіж ' || fin_m(d.monthly_payment) || '/міс тепер твій — кидай на наступний борг або в подушку.');
    end if;
  else
    select * into g from fin_goals where done_at is null and fin_hit(tok, name, aliases) > 0 order by fin_hit(tok, name, aliases) desc limit 1;
    if g.id is not null then
      insert into fin_tx(amount, kind, goal_id, note, chat_id, message_id) values (-p_amount, 'goal', g.id, p_note, p_chat, p_msg);
      update fin_goals set saved = saved - p_amount, done_at = now() where id = g.id;
      reaction := '👍';
      msgs := msgs || ('🎯 «' || g.name || '» оплачено: ' || fin_m(p_amount) || ' з запланованих ' || fin_m(g.amount)
        || case when p_amount > g.amount then ' (дорожче на ' || fin_m(p_amount - g.amount) || ')' else '' end);
    else
      select * into c from fin_categories where fin_hit(tok, name, aliases) > 0 order by fin_hit(tok, name, aliases) desc limit 1;
      reaction := '👍';
      if c.id is null then select * into c from fin_categories where name = 'інше'; reaction := '👌'; end if;
      insert into fin_tx(amount, kind, category_id, note, chat_id, message_id) values (-p_amount, 'expense', c.id, p_note, p_chat, p_msg);
      lim := fin_limit(c.id, m);
      if lim > 0 then
        left_ := lim + fin_sum(m, 'expense', c.id);
        if left_ < 0 then
          if fin_alert_once('over:' || c.id) then
            msgs := msgs || ('🔴 «' || c.name || '» перевищено: ' || fin_m(-left_) || ' понад ліміт ' || fin_m(lim));
            keyboard := fin_fix_kb(c.id);
          end if;
        elsif left_ <= lim * coalesce(fin_set('warn_pct'), '25')::numeric / 100 then
          if fin_alert_once('warn:' || c.id) then
            msgs := msgs || ('⚠️ «' || c.name || '»: лишилось ' || fin_m(left_) || ' з ' || fin_m(lim) || ' (' || round(100 * left_ / lim) || '%)');
          end if;
        end if;
      end if;
    end if;
  end if;

  free_after := (fin_forecast()->>'free')::numeric;
  if free_after < 0 and coalesce(free_before, 0) >= 0 then
    msgs := msgs || ('🚨 План місяця пішов у мінус: ' || fin_m(free_after) || E'.\nДо кінця місяця треба урізати витрати, інакше знову кредит. Напиши «стан».');
  end if;
  if keyboard is not null then
    msgs := msgs || ('👇 З якої категорії покрити ' || fin_m(-left_) || '? Її ліміт зменшиться на цю суму, а «' || c.name || '» стане в межах.');
  end if;
  if cardinality(msgs) > 0 then reply := array_to_string(msgs, E'\n\n'); end if;
end $$;

-- ───────────── Роутер ─────────────
create or replace function fin_handle(n fin_inbox) returns fin_inbox language plpgsql as $$
declare
  t text := lower(trim(coalesce(n.text, '')));
  r record; pm date := fin_plan_month(); nums numeric[]; words text[]; nm text; cid int; dt date; f jsonb;
begin
  -- натиснули inline-кнопку: text = callback_data, message_id = повідомлення бота (його n8n відредагує на reply)
  if n.kind = 'cb' then
    if n.chat_id is null or coalesce(fin_set('owner_chat_id'), '') <> n.chat_id::text then return n; end if;
    if t ~ '^mv:\d+:\d+$' then
      nums := regexp_match(t, '^mv:(\d+):(\d+)$')::numeric[];
      n.reply := fin_cover(nums[1]::int, nums[2]::int);
    end if;   -- mv:no → reply null: n8n лише прибере кнопки
    return n;
  end if;

  -- розклад: шлемо власнику
  if n.kind <> 'msg' then
    if coalesce(fin_set('owner_chat_id'), '') = '' then return n; end if;
    n.chat_id := fin_set('owner_chat_id')::bigint;
    if n.kind = 'weekly' then
      n.reply := fin_weekly_text();
    elsif n.kind = 'plan' then
      n.reply := '🗓 Через кілька днів новий місяць — склади план.' || E'\n\nЗараз так:\n' || fin_plan_text((fin_month() + interval '1 month')::date)
        || E'\n\nЩо змінити — пиши як завжди:\nдохід 40000\nкатегорія їжа 7000\nборг тас 20000 3000\nціль стоматолог 6000 01.03.2027'
        || E'\n\nЯкщо все ок — нічого не пиши, план перейде як є.';
    elsif n.kind = 'month' then
      -- закриваємо минулий місяць: внески в цілі вважаємо відкладеними
      dt := (fin_month() - interval '1 month')::date;
      if fin_alert_once('rollover') then
        update fin_goals g set saved = g.saved + fin_goal_contrib(g, dt) where done_at is null and fin_local(created_at) < fin_month();
      end if;
      n.reply := '📅 Підсумок за ' || fin_mname(dt) || E':\n'
        || 'Дохід: ' || fin_m(fin_sum(dt, 'income')) || ' (план ' || fin_m(fin_income_plan(dt)) || E')\n'
        || 'Витрати: ' || fin_m(-fin_sum(dt, 'expense') - fin_sum(dt, 'goal')) || E'\n'
        || 'На борги: ' || fin_m(-fin_sum(dt, 'debt'))
        || E'\n\n' || fin_plan_text(fin_month())
        || E'\n\n👉 Напиши фактичний залишок грошей на всіх картках/готівці: залишок 12000';
    end if;
    return n;
  end if;

  if n.chat_id is null or not fin_ensure_owner(n.chat_id) then return n; end if;
  if t = '' then return n; end if;

  -- рух грошей: -390 ютуб / +5000 зп / 390 ютуб / -2к сільпо
  if t ~ '^[+-]?\s*\d' then
    r := null;
    select m[1] s, replace(replace(m[2], ' ', ''), ',', '.')::numeric * case when m[3] is not null then 1000 else 1 end a, trim(coalesce(m[4], '')) note
      into r from regexp_match(t, '^([+-]?)\s*(\d+(?: \d{3})*(?:[.,]\d+)?)\s*(?:(к|k|тис)(?=\s|$))?(?:\s+(.*))?$') m;
    if r is null or r.a is null or r.a <= 0 then n.reply := 'Не зрозумів суму. Приклад: -390 ютуб'; return n; end if;
    select * into r from fin_record(n.chat_id, n.message_id, case when r.s = '+' then '+' else '-' end, r.a, nullif(r.note, ''));
    n.reaction := r.reaction; n.reply := r.reply; n.keyboard := r.keyboard;
    return n;
  end if;

  words := fin_tokens(t);
  select array_agg(replace(x[1], ',', '.')::numeric) into nums
    from regexp_matches(case when words[1] = 'ціль' then regexp_replace(t, '\d{1,2}\.\d{1,2}(\.\d{2,4})?', '', 'g') else t end,
                        '(\d+(?:[.,]\d+)?)', 'g') x;

  if words[1] in ('/start', 'start', 'help', 'допомога', 'хелп') or t in ('/start', '/help') then
    n.reply := fin_help_text();
  elsif words[1] in ('залишок', 'баланс') and nums is not null then
    insert into fin_balance(amount) values (nums[1]);
    n.reaction := '👍';
    n.reply := 'Записав залишок ' || fin_m(nums[1]) || E'\n\n' || fin_status_text();
  elsif words[1] = 'дохід' and nums is not null then
    insert into fin_months(month, income_plan) values (pm, nums[1]) on conflict (month) do update set income_plan = excluded.income_plan;
    n.reaction := '👍';
    n.reply := 'Дохід на ' || fin_mname(pm) || ': ' || fin_m(nums[1]);
  elsif words[1] = 'категорія' and cardinality(words) >= 2 then
    nm := words[2];
    insert into fin_categories(name) values (nm) on conflict (name) do nothing;
    update fin_categories set
      aliases = fin_upsert_aliases(aliases, array(select w from unnest(words[3:]) w where w !~ '^\d')),
      fixed = fixed or t ~ '!'
    where name = nm returning id into cid;
    if nums is not null then
      insert into fin_budgets(month, category_id, amount) values (pm, cid, nums[1])
        on conflict (month, category_id) do update set amount = excluded.amount;
    end if;
    n.reaction := '👍';
    select '«' || name || '»: ' || fin_m(fin_limit(id, pm)) || '/міс на ' || fin_mname(pm) || case when fixed then ' · обов''язкова' else '' end
      || case when cardinality(aliases) > 0 then E'\nЛовлю по словах: ' || array_to_string(aliases, ', ') else '' end
      into n.reply from fin_categories where id = cid;
  elsif words[1] = 'борг' and cardinality(words) >= 2 and nums is not null then
    nm := words[2];
    insert into fin_debts(name, start_balance, balance, monthly_payment, aliases)
      values (nm, nums[1], nums[1], coalesce(nums[2], 0), array(select w from unnest(words[3:]) w where w !~ '^\d'))
    on conflict (name) do update set balance = excluded.balance,
      start_balance = greatest(fin_debts.start_balance, excluded.balance),
      monthly_payment = case when nums[2] is not null then excluded.monthly_payment else fin_debts.monthly_payment end,
      aliases = fin_upsert_aliases(fin_debts.aliases, excluded.aliases),
      closed_at = case when excluded.balance > 0 then null else fin_debts.closed_at end;
    n.reaction := '👍';
    select '💳 Борг «' || name || '»: ' || fin_m(balance) || ', платіж ' || fin_m(monthly_payment) || '/міс'
      || case when cardinality(aliases) > 0 then E'\nЛовлю по словах: ' || name || ', ' || array_to_string(aliases, ', ') else E'\nЛовлю по слову: ' || name end
      into n.reply from fin_debts where name = nm;
  elsif words[1] = 'ціль' and cardinality(words) >= 2 and nums is not null then
    nm := words[2];
    dt := coalesce(
      (select case when x[3] is not null then to_date(x[1] || '.' || x[2] || '.' || case when length(x[3]) = 2 then '20' || x[3] else x[3] end, 'DD.MM.YYYY')
              when to_date(x[1] || '.' || x[2] || '.' || extract(year from fin_now()), 'DD.MM.YYYY') >= fin_now()::date
              then to_date(x[1] || '.' || x[2] || '.' || extract(year from fin_now()), 'DD.MM.YYYY')
              else to_date(x[1] || '.' || x[2] || '.' || (extract(year from fin_now()) + 1), 'DD.MM.YYYY') end
         from regexp_match(t, '(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?') x),
      (fin_month() + interval '1 month')::date);
    insert into fin_goals(name, amount, due_date, aliases)
      values (nm, nums[1], dt, array(select w from unnest(words[3:]) w where w !~ '^\d'))
    on conflict (name) do update set amount = excluded.amount, due_date = excluded.due_date, done_at = null,
      aliases = fin_upsert_aliases(fin_goals.aliases, excluded.aliases);
    n.reaction := '👍';
    select '🎯 «' || name || '»: ' || fin_m(amount) || ' до ' || to_char(due_date, 'DD.MM.YYYY')
      || E'\nВідкладаю ' || fin_m(fin_goal_contrib(g, fin_month())) || ' цього місяця'
      into n.reply from fin_goals g where name = nm;
  elsif words[1] in ('відміна', 'скасуй', 'видали', 'undo') then
    n.reply := fin_undo(n.chat_id, n.reply_to);
  elsif words[1] in ('вирівняй', 'вирівняти', 'вирівнять', 'fix') then
    select * into r from fin_fix_offer();
    n.reply := r.reply; n.keyboard := r.keyboard;
  elsif words[1] in ('бюджет', 'budget') then
    n.reply := fin_budget_text();
  elsif words[1] in ('стан', 'баланс', 'скільки', 'status') then
    n.reply := fin_status_text();
  elsif words[1] in ('звіт', 'звірка', 'report') then
    n.reply := fin_weekly_text();
  elsif words[1] in ('план', 'plan') then
    n.reply := fin_plan_text(pm);
  elsif (words[1] in ('можу', 'чи') or t ~ '\?') and nums is not null then
    n.reply := fin_afford(nums[1]);
  else
    n.reply := 'Не зрозумів 🤷 Напиши «допомога».';
  end if;
  return n;
end $$;

create or replace function fin_inbox_trg() returns trigger language plpgsql as $$
begin
  return fin_handle(new);
end $$;

drop trigger if exists fin_inbox_process on fin_inbox;
create trigger fin_inbox_process before insert on fin_inbox for each row execute function fin_inbox_trg();
