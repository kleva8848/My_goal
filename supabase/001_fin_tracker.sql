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
  where kind = k and fin_local(at) >= m and fin_local(at) < m + interval '1 month'
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
  free := cash + greatest(plan - inc, 0) - cat_left - debt_left - goal_res - debt_res;
  return jsonb_build_object('cash', cash, 'income_left', greatest(plan - inc, 0), 'cat_left', cat_left,
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
    || E'\n➖ Ще заплановано: категорії ' || fin_m((f->>'cat_left')::numeric) || ', борги ' || fin_m((f->>'debt_left')::numeric)
    || case when (f->>'goal_res')::numeric > 0 then ', цілі ' || fin_m((f->>'goal_res')::numeric) else '' end
    || case when (f->>'debt_res')::numeric > 0 then E'\n🏦 Відкласти з дод. доходу на борги: ' || fin_m((f->>'debt_res')::numeric) else '' end
    || case when (f->>'free')::numeric >= 0 then E'\n✅ Вільно до кінця місяця: ' || fin_m((f->>'free')::numeric)
            else E'\n🚨 План у мінусі: ' || fin_m((f->>'free')::numeric) || ' — треба урізати витрати' end;
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

create or replace function fin_help_text() returns text language sql immutable as $$ select
'🧾 Фін трекер — шпаргалка

Щодня:
-390 ютуб — витрата (👍 = записано, 👌 = пішло в «інше»)
+5000 зп — дохід
-3000 тас — платіж по боргу (якщо «тас» — назва/аліас боргу)
-2к сільпо — можна з «к»
відміна — видалити останній запис (або відповіддю на повідомлення)

Один раз / раз на місяць:
залишок 12000 — фактичні гроші зараз (з цього все рахується)
дохід 40000 — орієнтовний дохід на місяць
категорія їжа 8000 сільпо атб обід — ліміт + слова, по яких ловити витрати
категорія комуналка 3000 ! — «!» = обов''язкова, не радити урізати
борг тас 25000 3000 таскомбанк — залишок боргу, платіж/міс, аліаси
ціль резина 8000 01.11.2027 — обов''язкова витрата, відкладаю щомісяця

Питання:
можу 5000 — чи потягну зараз без нового доходу і що урізати
стан — скільки грошей і скільки вільно
звіт — звірка як щотижня
план — план місяця

Після 25-го «дохід/категорія» пишуться в план наступного місяця.' $$;

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

-- запис руху; повертає (reaction, reply)
create or replace function fin_record(p_chat bigint, p_msg bigint, p_sign text, p_amount numeric, p_note text, out reaction text, out reply text)
language plpgsql as $$
declare
  m date := fin_month();
  tok text[] := fin_tokens(p_note);
  free_before numeric := (fin_forecast()->>'free')::numeric;
  free_after numeric;
  d fin_debts; g fin_goals; c fin_categories;
  plan numeric; inc_before numeric; extra numeric; lim numeric; left_ numeric; msgs text[] := '{}';
begin
  if exists (select 1 from fin_tx where chat_id = p_chat and message_id = p_msg) then reaction := '👍'; return; end if;

  if p_sign = '+' then
    plan := fin_income_plan(m);
    inc_before := fin_sum(m, 'income');
    insert into fin_tx(amount, kind, note, chat_id, message_id) values (p_amount, 'income', p_note, p_chat, p_msg);
    reaction := '🔥';
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
  if cardinality(msgs) > 0 then reply := array_to_string(msgs, E'\n\n'); end if;
end $$;

-- ───────────── Роутер ─────────────
create or replace function fin_handle(n fin_inbox) returns fin_inbox language plpgsql as $$
declare
  t text := lower(trim(coalesce(n.text, '')));
  r record; pm date := fin_plan_month(); nums numeric[]; words text[]; nm text; cid int; dt date; f jsonb;
begin
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
    n.reaction := r.reaction; n.reply := r.reply;
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
  elsif words[1] in ('стан', 'баланс', 'скільки') then
    n.reply := fin_status_text();
  elsif words[1] in ('звіт', 'звірка') then
    n.reply := fin_weekly_text();
  elsif words[1] = 'план' then
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
