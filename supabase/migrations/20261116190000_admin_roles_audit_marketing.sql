-- Admin build for Capitol Receipts (same steps as the Andamos pilot). The admin already has personal
-- logins and the authenticator step (supabase/functions/admin). This adds:
-- 1. Roles on admins (owner, admin, support, marketing, readonly), enforced in the admin function.
-- 2. admin_log becomes append-only and records who (by id), before, after and why.
-- 3. Ad spend, campaigns and one row of metrics per day for the central dashboard.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- 1. Roles. Everyone who is an admin today stays an owner.
alter table public.admins add column if not exists role text not null default 'owner'
  check (role in ('owner', 'admin', 'support', 'marketing', 'readonly'));

-- 2. Audit log.
alter table public.admin_log
  add column if not exists admin_id uuid,
  add column if not exists before jsonb,
  add column if not exists after jsonb,
  add column if not exists reason text;

create or replace function private.audit_log_is_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'admin_log is append-only' using errcode = '42501';
end;
$$;
create trigger admin_log_append_only before update or delete on public.admin_log
  for each row execute function private.audit_log_is_append_only();
create trigger admin_log_no_truncate before truncate on public.admin_log
  for each statement execute function private.audit_log_is_append_only();
revoke update, delete, truncate on public.admin_log from anon, authenticated, service_role;

-- 3. Marketing and daily metrics. The app does not record where a person came from yet, so signups
-- have no channel until it does (on the roadmap).
create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  channel text not null default 'paid',
  platform text,
  objective text,
  budget_cents bigint,
  daily_budget_cents bigint,
  target_cac_cents bigint,
  utm_campaign text unique,
  start_date date,
  end_date date,
  owner text,
  status text not null default 'active' check (status in ('draft', 'active', 'paused', 'ended')),
  creative_url text,
  created_at timestamptz not null default now()
);
alter table public.campaigns enable row level security;
revoke all on public.campaigns from anon, authenticated;

create table if not exists public.marketing_spend_daily (
  date date not null,
  platform text not null,
  campaign_key text not null default '',
  campaign_id uuid references public.campaigns (id) on delete set null,
  spend_cents bigint not null default 0,
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  conversions bigint not null default 0,
  currency text not null default 'USD',
  source text not null default 'csv',
  imported_at timestamptz not null default now(),
  primary key (date, platform, campaign_key)
);
alter table public.marketing_spend_daily enable row level security;
revoke all on public.marketing_spend_daily from anon, authenticated;

create table if not exists public.app_daily_metrics (
  date date primary key,
  app text not null default 'capitolreceipts',
  mrr_cents bigint not null default 0,
  new_mrr_cents bigint not null default 0,
  churned_mrr_cents bigint not null default 0,
  paying_customers integer not null default 0,
  new_signups integer not null default 0,
  active_users integer not null default 0,
  trials_started integer not null default 0,
  spend_cents bigint not null default 0,
  tickets_open integer not null default 0,
  refunds_cents bigint not null default 0,
  computed_at timestamptz not null default now()
);
alter table public.app_daily_metrics enable row level security;
revoke all on public.app_daily_metrics from anon, authenticated;

-- Paying = Pro that is paid for (comped excluded). Active = signed in that day (exact for today and later).
create or replace function private.compute_daily_metrics(p_from date, p_to date)
returns integer language plpgsql security definer set search_path to '' as $$
declare n integer;
begin
  insert into public.app_daily_metrics as m
    (date, paying_customers, new_signups, active_users, trials_started, spend_cents, tickets_open, computed_at)
  select
    d::date,
    (select count(*) from public.subscriptions s where s.status in ('active', 'past_due') and coalesce(s.plan, '') <> 'comp' and s.created_at::date <= d::date),
    (select count(*) from auth.users u where u.created_at::date = d::date),
    (select count(*) from auth.users u where u.last_sign_in_at::date = d::date),
    (select count(*) from public.subscriptions s where s.created_at::date = d::date and s.trial_ends is not null),
    coalesce((select sum(x.spend_cents) from public.marketing_spend_daily x where x.date = d::date), 0),
    (select count(*) from public.support_requests r where r.created_at::date <= d::date and (r.status = 'open' or r.updated_at::date > d::date)),
    now()
  from generate_series(p_from, p_to, interval '1 day') d
  on conflict (date) do update set
    paying_customers = excluded.paying_customers, new_signups = excluded.new_signups,
    active_users = case when excluded.date >= current_date - 1 then excluded.active_users else m.active_users end,
    trials_started = excluded.trials_started, spend_cents = excluded.spend_cents, tickets_open = excluded.tickets_open,
    computed_at = excluded.computed_at;
  get diagnostics n = row_count;
  return n;
end;
$$;

select private.compute_daily_metrics((current_date - interval '365 days')::date, current_date);
select cron.schedule('capitolreceipts-daily-metrics', '30 1 * * *', $$select private.compute_daily_metrics(current_date - 3, current_date)$$);

-- Read by the admin function with the server key (it checks the caller's role first).
create or replace function public.admin_marketing(p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_from date := current_date - greatest(1, least(coalesce(p_days, 30), 730)) + 1;
begin
  return jsonb_build_object(
    'from', v_from,
    'signups', (select count(*) from auth.users where created_at::date >= v_from),
    'new_paying', (select count(*) from public.subscriptions where status in ('active', 'past_due') and coalesce(plan, '') <> 'comp' and created_at::date >= v_from),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('date', m.date, 'signups', m.new_signups, 'trials', m.trials_started, 'spend_cents', m.spend_cents, 'active', m.active_users) order by m.date)
      from public.app_daily_metrics m where m.date >= v_from), '[]'::jsonb),
    'spend', coalesce((select jsonb_agg(jsonb_build_object('platform', s.platform, 'spend_cents', s.spend, 'impressions', s.imp, 'clicks', s.clk, 'conversions', s.conv) order by s.spend desc)
      from (select platform, sum(spend_cents) spend, sum(impressions) imp, sum(clicks) clk, sum(conversions) conv
            from public.marketing_spend_daily where date >= v_from group by platform) s), '[]'::jsonb),
    'by_campaign', coalesce((select jsonb_agg(jsonb_build_object('campaign', s.campaign_key, 'platform', s.platform, 'spend_cents', s.spend, 'clicks', s.clk, 'conversions', s.conv) order by s.spend desc)
      from (select campaign_key, platform, sum(spend_cents) spend, sum(clicks) clk, sum(conversions) conv
            from public.marketing_spend_daily where date >= v_from group by campaign_key, platform) s), '[]'::jsonb),
    'campaign_list', coalesce((select jsonb_agg(to_jsonb(c) order by c.created_at desc) from public.campaigns c), '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_import_spend(p_rows jsonb)
returns integer language plpgsql security definer set search_path to '' as $$
declare n integer;
begin
  insert into public.marketing_spend_daily as m (date, platform, campaign_key, campaign_id, spend_cents, impressions, clicks, conversions, source, imported_at)
  select (r ->> 'date')::date, lower(left(r ->> 'platform', 40)), coalesce(left(r ->> 'campaign', 200), ''),
    (select c.id from public.campaigns c where c.utm_campaign = r ->> 'campaign'),
    round(coalesce((r ->> 'spend')::numeric, 0) * 100)::bigint, coalesce((r ->> 'impressions')::bigint, 0),
    coalesce((r ->> 'clicks')::bigint, 0), coalesce((r ->> 'conversions')::bigint, 0), 'csv', now()
  from jsonb_array_elements(p_rows) r
  where (r ->> 'date') is not null and (r ->> 'platform') is not null
  on conflict (date, platform, campaign_key) do update set
    spend_cents = excluded.spend_cents, impressions = excluded.impressions, clicks = excluded.clicks,
    conversions = excluded.conversions, campaign_id = excluded.campaign_id, source = excluded.source, imported_at = now();
  get diagnostics n = row_count;
  perform private.compute_daily_metrics(
    (select min((r ->> 'date')::date) from jsonb_array_elements(p_rows) r),
    (select max((r ->> 'date')::date) from jsonb_array_elements(p_rows) r));
  return n;
end;
$$;

revoke all on function public.admin_marketing(integer) from public, anon, authenticated;
revoke all on function public.admin_import_spend(jsonb) from public, anon, authenticated;
grant execute on function public.admin_marketing(integer) to service_role;
grant execute on function public.admin_import_spend(jsonb) to service_role;
