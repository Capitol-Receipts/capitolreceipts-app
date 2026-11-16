-- Where each account came from (first touch), recorded once by the signed-in person's browser,
-- and the admin Marketing section split by channel and campaign.

create table if not exists public.signup_attribution (
  user_id uuid primary key references auth.users (id) on delete cascade,
  signup_source text not null,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  utm_term text,
  referrer text,
  landing_page text,
  click_ids jsonb,
  created_at timestamptz not null default now()
);
alter table public.signup_attribution enable row level security;
revoke all on public.signup_attribution from anon, authenticated;

create or replace function private.channel_for(p jsonb)
returns text language sql immutable set search_path to '' as $$
  select case
    when coalesce(p -> 'click_ids', '{}'::jsonb) ?| array['gclid', 'fbclid', 'ttclid', 'msclkid', 'gbraid', 'wbraid'] then 'paid'
    when lower(coalesce(p ->> 'utm_medium', '')) in ('cpc', 'ppc', 'paid', 'paid_social', 'paidsocial', 'display', 'cpm') then 'paid'
    when lower(coalesce(p ->> 'utm_medium', '')) in ('email', 'newsletter') or lower(coalesce(p ->> 'utm_source', '')) in ('email', 'newsletter', 'resend') then 'email'
    when lower(coalesce(p ->> 'utm_medium', '')) in ('partner', 'affiliate') then 'partner'
    when lower(coalesce(p ->> 'utm_medium', '')) in ('social', 'organic_social') then 'social'
    when lower(coalesce(p ->> 'utm_medium', '')) = 'referral' then 'referral'
    when coalesce(p ->> 'referrer', '') ~* '(google|bing|duckduckgo|yahoo|ecosia|baidu|yandex)\.' then 'organic'
    when coalesce(p ->> 'referrer', '') ~* '(facebook|instagram|tiktok|twitter|x\.com|t\.co|linkedin|reddit|pinterest|youtube|threads)\.' then 'social'
    when coalesce(p ->> 'referrer', '') <> '' and coalesce(p ->> 'referrer', '') !~* 'capitolreceipts\.com' then 'referral'
    else 'direct'
  end;
$$;

create or replace function public.record_attribution(p jsonb)
returns void language plpgsql security definer set search_path to '' as $$
declare ids jsonb := '{}'::jsonb; k text;
begin
  if auth.uid() is null or p is null or jsonb_typeof(p) <> 'object' then return; end if;
  foreach k in array array['gclid', 'fbclid', 'ttclid', 'msclkid', 'gbraid', 'wbraid'] loop
    if coalesce(p -> 'click_ids' ->> k, '') <> '' then ids := ids || jsonb_build_object(k, left(p -> 'click_ids' ->> k, 200)); end if;
  end loop;
  insert into public.signup_attribution (user_id, signup_source, utm_source, utm_medium, utm_campaign, utm_content, utm_term, referrer, landing_page, click_ids)
  values (auth.uid(), private.channel_for(p || jsonb_build_object('click_ids', ids)),
    left(nullif(p ->> 'utm_source', ''), 120), left(nullif(p ->> 'utm_medium', ''), 120), left(nullif(p ->> 'utm_campaign', ''), 200),
    left(nullif(p ->> 'utm_content', ''), 200), left(nullif(p ->> 'utm_term', ''), 200), left(nullif(p ->> 'referrer', ''), 500),
    left(nullif(p ->> 'landing_page', ''), 500), case when ids = '{}'::jsonb then null else ids end)
  on conflict (user_id) do nothing;
end;
$$;
revoke all on function public.record_attribution(jsonb) from public, anon;
grant execute on function public.record_attribution(jsonb) to authenticated;

-- The Marketing section: the same as before plus channels and tagged campaigns.
create or replace function public.admin_marketing(p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_from date := current_date - greatest(1, least(coalesce(p_days, 30), 730)) + 1;
begin
  return jsonb_build_object(
    'from', v_from,
    'signups', (select count(*) from auth.users where created_at::date >= v_from),
    'attributed_share', (select round(100.0 * count(a.user_id) / nullif(count(*), 0)) from auth.users u left join public.signup_attribution a on a.user_id = u.id where u.created_at::date >= v_from),
    'new_paying', (select count(*) from public.subscriptions where status in ('active', 'past_due') and coalesce(plan, '') <> 'comp' and created_at::date >= v_from),
    'channels', coalesce((select jsonb_agg(jsonb_build_object('channel', c, 'signups', n, 'paid', paid) order by n desc) from (
      select coalesce(a.signup_source, 'unknown') c, count(*) n,
        count(*) filter (where exists (select 1 from public.subscriptions s where s.user_id = u.id and s.status in ('active', 'past_due') and coalesce(s.plan, '') <> 'comp')) paid
      from auth.users u left join public.signup_attribution a on a.user_id = u.id
      where u.created_at::date >= v_from group by 1) x), '[]'::jsonb),
    'campaigns', coalesce((select jsonb_agg(r order by (r ->> 'signups')::int desc) from (
      select jsonb_build_object('campaign', a.utm_campaign, 'source', a.utm_source, 'signups', count(*),
        'paid', count(*) filter (where exists (select 1 from public.subscriptions s where s.user_id = a.user_id and s.status in ('active', 'past_due') and coalesce(s.plan, '') <> 'comp')),
        'spend_cents', coalesce((select sum(x.spend_cents) from public.marketing_spend_daily x where x.campaign_key = a.utm_campaign and x.date >= v_from), 0)) r
      from public.signup_attribution a where a.created_at::date >= v_from and a.utm_campaign is not null group by a.utm_campaign, a.utm_source) y), '[]'::jsonb),
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
