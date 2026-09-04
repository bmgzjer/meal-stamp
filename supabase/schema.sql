-- 准时吃饭打卡 · Supabase 云端初始化脚本
-- 在一个全新的 Supabase 项目 -> SQL Editor 中整段运行一次。

create extension if not exists pgcrypto;

create table if not exists public.spaces (
  id uuid primary key default gen_random_uuid(),
  name text not null default '我们的打卡空间',
  invite_code text not null unique,
  target_days integer not null default 22 check (target_days between 1 and 31),
  reward_every integer not null default 15 check (reward_every between 1 and 999),
  start_date date,
  demo boolean not null default false,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.space_members (
  space_id uuid not null references public.spaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','member')),
  joined_at timestamptz not null default now(),
  primary key (space_id, user_id)
);
create unique index if not exists one_space_per_user on public.space_members(user_id);

create table if not exists public.admin_secrets (
  space_id uuid primary key references public.spaces(id) on delete cascade,
  password_hash text not null default '',
  updated_at timestamptz not null default now()
);

create table if not exists public.checkins (
  space_id uuid not null references public.spaces(id) on delete cascade,
  day date not null,
  meal text not null check (meal in ('lunch','dinner')),
  status text not null check (status in ('onTime','makeup')),
  checkin_time timestamptz not null default now(),
  photo_id text,
  photo_path text,
  bytes integer not null default 0,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (space_id, day, meal)
);

create table if not exists public.rewards (
  id text not null,
  space_id uuid not null references public.spaces(id) on delete cascade,
  name text not null,
  enabled boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  primary key (space_id, id)
);

create table if not exists public.reward_draws (
  id text not null,
  space_id uuid not null references public.spaces(id) on delete cascade,
  reward text not null,
  mode text not null check (mode in ('wheel','flip')),
  is_test boolean not null default false,
  drawn_at timestamptz not null default now(),
  completed boolean not null default false,
  completed_at timestamptz,
  user_id uuid references auth.users(id) on delete set null,
  primary key (space_id, id)
);

create table if not exists public.makeup_requests (
  id text not null,
  space_id uuid not null references public.spaces(id) on delete cascade,
  day date not null,
  meal text not null check (meal in ('lunch','dinner')),
  reason text not null default '',
  auto_detected boolean not null default true,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_at timestamptz not null default now(),
  requested_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  primary key (space_id, id)
);

create table if not exists public.chores (
  id text not null,
  space_id uuid not null references public.spaces(id) on delete cascade,
  name text not null,
  credit integer not null default 1 check (credit between 1 and 31),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  primary key (space_id, id)
);

create table if not exists public.chore_requests (
  id text not null,
  space_id uuid not null references public.spaces(id) on delete cascade,
  month text not null check (month ~ '^[0-9]{4}-[0-9]{2}$'),
  chore_id text,
  chore_name text not null,
  credit integer not null default 1 check (credit between 1 and 31),
  note text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_at timestamptz not null default now(),
  requested_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  primary key (space_id, id)
);

create index if not exists idx_checkins_space_day on public.checkins(space_id, day desc);
create index if not exists idx_reward_draws_space_time on public.reward_draws(space_id, drawn_at desc);
create index if not exists idx_makeups_space_status on public.makeup_requests(space_id, status);
create index if not exists idx_chore_requests_space_status on public.chore_requests(space_id, status);

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists trg_spaces_updated on public.spaces;
create trigger trg_spaces_updated before update on public.spaces
for each row execute function public.touch_updated_at();

drop trigger if exists trg_admin_secrets_updated on public.admin_secrets;
create trigger trg_admin_secrets_updated before update on public.admin_secrets
for each row execute function public.touch_updated_at();

drop trigger if exists trg_checkins_updated on public.checkins;
create trigger trg_checkins_updated before update on public.checkins
for each row execute function public.touch_updated_at();

-- Security-definer helper: RLS policies use this to avoid recursive policies.
create or replace function public.is_space_member(p_space uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.space_members m where m.space_id = p_space and m.user_id = auth.uid());
$$;

create or replace function public.is_space_admin(p_space uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.space_members m where m.space_id = p_space and m.user_id = auth.uid() and m.role = 'admin');
$$;

create or replace function public.is_space_member_text(p_space text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.space_members m where m.space_id::text = p_space and m.user_id = auth.uid());
$$;

-- 创建情侣空间：创建者自动成为管理员，并写入默认奖励/家务。
create or replace function public.create_space(p_name text default '我们的打卡空间')
returns table(space_id uuid, invite_code text, role text)
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_space uuid;
  v_code text;
begin
  if v_user is null then raise exception '请先登录'; end if;
  if exists(select 1 from public.space_members where user_id = v_user) then
    raise exception '当前账号已经加入一个情侣空间';
  end if;
  v_code := upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
  insert into public.spaces(name, invite_code, created_by)
  values(coalesce(nullif(trim(p_name),''),'我们的打卡空间'), v_code, v_user)
  returning id into v_space;
  insert into public.space_members(space_id,user_id,role) values(v_space,v_user,'admin');
  insert into public.admin_secrets(space_id,password_hash) values(v_space,'');
  insert into public.rewards(id,space_id,name,enabled,sort_order) values
    (gen_random_uuid()::text,v_space,'奶茶一杯',true,1),
    (gen_random_uuid()::text,v_space,'按摩 20 分钟',true,2),
    (gen_random_uuid()::text,v_space,'指定一顿想吃的',true,3),
    (gen_random_uuid()::text,v_space,'免做一次家务',true,4);
  insert into public.chores(id,space_id,name,credit,sort_order) values
    (gen_random_uuid()::text,v_space,'洗碗 + 收厨房',1,1),
    (gen_random_uuid()::text,v_space,'扫地拖地',1,2),
    (gen_random_uuid()::text,v_space,'整理衣物',1,3),
    (gen_random_uuid()::text,v_space,'深度收纳一块区域',2,4);
  return query select v_space, v_code, 'admin'::text;
end $$;

-- 对象通过邀请码加入。为了符合当前产品模型，一个空间最多 2 人。
create or replace function public.join_space(p_invite_code text)
returns table(space_id uuid, invite_code text, role text)
language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  v_space uuid;
  v_code text := upper(trim(p_invite_code));
begin
  if v_user is null then raise exception '请先登录'; end if;
  if exists(select 1 from public.space_members where user_id = v_user) then
    raise exception '当前账号已经加入一个情侣空间';
  end if;
  select id into v_space from public.spaces where spaces.invite_code = v_code;
  if v_space is null then raise exception '邀请码不存在'; end if;
  if (select count(*) from public.space_members where space_members.space_id=v_space) >= 2 then
    raise exception '这个情侣空间已经有两位成员';
  end if;
  insert into public.space_members(space_id,user_id,role) values(v_space,v_user,'member');
  return query select v_space, v_code, 'member'::text;
end $$;

-- RLS
alter table public.spaces enable row level security;
alter table public.space_members enable row level security;
alter table public.admin_secrets enable row level security;
alter table public.checkins enable row level security;
alter table public.rewards enable row level security;
alter table public.reward_draws enable row level security;
alter table public.makeup_requests enable row level security;
alter table public.chores enable row level security;
alter table public.chore_requests enable row level security;

-- Re-create policies idempotently.
do $$ declare r record; begin
  for r in select schemaname, tablename, policyname from pg_policies
    where schemaname='public' and tablename in ('spaces','space_members','admin_secrets','checkins','rewards','reward_draws','makeup_requests','chores','chore_requests')
  loop execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename); end loop;
end $$;

create policy spaces_read on public.spaces for select to authenticated using (public.is_space_member(id));
create policy spaces_admin_update on public.spaces for update to authenticated using (public.is_space_admin(id)) with check (public.is_space_admin(id));

create policy members_read on public.space_members for select to authenticated using (public.is_space_member(space_id));

create policy admin_secret_read on public.admin_secrets for select to authenticated using (public.is_space_admin(space_id));
create policy admin_secret_insert on public.admin_secrets for insert to authenticated with check (public.is_space_admin(space_id));
create policy admin_secret_update on public.admin_secrets for update to authenticated using (public.is_space_admin(space_id)) with check (public.is_space_admin(space_id));

create policy checkins_read on public.checkins for select to authenticated using (public.is_space_member(space_id));
create policy checkins_insert on public.checkins for insert to authenticated with check (public.is_space_member(space_id));
create policy checkins_update on public.checkins for update to authenticated using (public.is_space_member(space_id)) with check (public.is_space_member(space_id));
create policy checkins_delete on public.checkins for delete to authenticated using (public.is_space_member(space_id));

create policy rewards_read on public.rewards for select to authenticated using (public.is_space_member(space_id));
create policy rewards_admin_insert on public.rewards for insert to authenticated with check (public.is_space_admin(space_id));
create policy rewards_admin_update on public.rewards for update to authenticated using (public.is_space_admin(space_id)) with check (public.is_space_admin(space_id));
create policy rewards_admin_delete on public.rewards for delete to authenticated using (public.is_space_admin(space_id));

create policy draws_read on public.reward_draws for select to authenticated using (public.is_space_member(space_id));
create policy draws_insert on public.reward_draws for insert to authenticated with check (public.is_space_member(space_id));
create policy draws_update on public.reward_draws for update to authenticated using (public.is_space_member(space_id)) with check (public.is_space_member(space_id));

create policy makeup_read on public.makeup_requests for select to authenticated using (public.is_space_member(space_id));
create policy makeup_insert on public.makeup_requests for insert to authenticated with check (public.is_space_member(space_id) and status='pending');
create policy makeup_admin_insert on public.makeup_requests for insert to authenticated with check (public.is_space_admin(space_id));
create policy makeup_admin_update on public.makeup_requests for update to authenticated using (public.is_space_admin(space_id)) with check (public.is_space_admin(space_id));

create policy chores_read on public.chores for select to authenticated using (public.is_space_member(space_id));
create policy chores_admin_insert on public.chores for insert to authenticated with check (public.is_space_admin(space_id));
create policy chores_admin_update on public.chores for update to authenticated using (public.is_space_admin(space_id)) with check (public.is_space_admin(space_id));
create policy chores_admin_delete on public.chores for delete to authenticated using (public.is_space_admin(space_id));

create policy chore_req_read on public.chore_requests for select to authenticated using (public.is_space_member(space_id));
create policy chore_req_insert on public.chore_requests for insert to authenticated with check (public.is_space_member(space_id) and status='pending');
create policy chore_req_admin_insert on public.chore_requests for insert to authenticated with check (public.is_space_admin(space_id));
create policy chore_req_admin_update on public.chore_requests for update to authenticated using (public.is_space_admin(space_id)) with check (public.is_space_admin(space_id));

-- Least-privilege grants for Data API.
revoke all on public.spaces, public.space_members, public.admin_secrets, public.checkins, public.rewards, public.reward_draws, public.makeup_requests, public.chores, public.chore_requests from anon;
grant select, update on public.spaces to authenticated;
grant select on public.space_members to authenticated;
grant select, insert, update on public.admin_secrets to authenticated;
grant select, insert, update, delete on public.checkins to authenticated;
grant select, insert, update, delete on public.rewards to authenticated;
grant select, insert, update on public.reward_draws to authenticated;
grant select, insert, update on public.makeup_requests to authenticated;
grant select, insert, update, delete on public.chores to authenticated;
grant select, insert, update on public.chore_requests to authenticated;
revoke all on function public.create_space(text), public.join_space(text) from public, anon;
grant execute on function public.create_space(text), public.join_space(text) to authenticated;

-- 私密照片 Bucket，6MB 上限。客户端会在上传前再压缩到 JPEG。
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('checkin-photos','checkin-photos',false,6291456,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=false,file_size_limit=6291456,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

do $$ declare r record; begin
  for r in select policyname from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'meal_stamp_%'
  loop execute format('drop policy if exists %I on storage.objects', r.policyname); end loop;
end $$;

create policy meal_stamp_photo_read on storage.objects for select to authenticated
using (bucket_id='checkin-photos' and public.is_space_member_text((storage.foldername(name))[1]));
create policy meal_stamp_photo_insert on storage.objects for insert to authenticated
with check (bucket_id='checkin-photos' and public.is_space_member_text((storage.foldername(name))[1]));
create policy meal_stamp_photo_update on storage.objects for update to authenticated
using (bucket_id='checkin-photos' and public.is_space_member_text((storage.foldername(name))[1]))
with check (bucket_id='checkin-photos' and public.is_space_member_text((storage.foldername(name))[1]));
create policy meal_stamp_photo_delete on storage.objects for delete to authenticated
using (bucket_id='checkin-photos' and public.is_space_member_text((storage.foldername(name))[1]));

-- Realtime: 自动把业务表加入 supabase_realtime publication（已加入则跳过）。
do $$
declare t text;
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime') then
    foreach t in array array['spaces','checkins','rewards','reward_draws','makeup_requests','chores','chore_requests'] loop
      if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
