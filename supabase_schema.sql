-- =====================================================================
-- BOOKMATE · Supabase 스키마 + 보안 정책(RLS)
-- 사용법: Supabase 대시보드 > SQL Editor 에 이 파일 전체를 붙여 넣고 Run.
--         (여러 번 실행해도 되도록 작성했어요)
-- 원칙: 모든 테이블에 RLS를 켜고, 클라이언트(authenticated)는 정책이 허용한 것만 할 수 있어요.
--       AI 처리 결과(전사·요약·추천)는 서버의 service_role 키로만 쓰고, 이 키는 프론트엔드에 절대 넣지 않아요.
-- =====================================================================

-- ---------- 공통 함수 ----------
create or replace function public.set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;

create or replace function public.safe_uuid(t text) returns uuid
language plpgsql immutable as $$ begin return t::uuid; exception when others then return null; end $$;

-- ---------- 프로필 ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null unique check (char_length(nickname) between 1 and 16),
  intro text not null default '' check (char_length(intro) <= 300),
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 가입 시 프로필 자동 생성 (닉네임이 겹치면 숫자를 붙임)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare nick text; n int := 0;
begin
  nick := left(coalesce(nullif(trim(new.raw_user_meta_data->>'nickname'), ''), 'user' || substr(new.id::text, 1, 6)), 16);
  loop
    begin
      insert into public.profiles(id, nickname) values (new.id, case when n = 0 then nick else left(nick, 13) || n end);
      exit;
    exception when unique_violation then
      n := n + 1;
      if n > 50 then raise; end if;
    end;
  end loop;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ---------- 책 / 내 서재 ----------
create table if not exists public.books (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 200),
  author text not null check (char_length(author) between 1 and 100),
  genre text not null default '기타',
  pages integer not null check (pages > 0),
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (title, author)
);

create table if not exists public.user_books (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  book_id uuid not null references public.books(id) on delete cascade,
  status text not null default 'want' check (status in ('want','reading','done','pause')),
  current_page integer not null default 0 check (current_page >= 0),
  started_on date,
  finished_on date,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, book_id)
);

create or replace function public.user_books_defaults() returns trigger
language plpgsql as $$
declare total int;
begin
  select pages into total from public.books where id = new.book_id;
  if new.current_page > total then raise exception '읽은 쪽수가 전체 쪽수보다 클 수 없어요.'; end if;
  if new.status = 'reading' and new.started_on is null then new.started_on := current_date; end if;
  if new.status = 'want' and new.current_page > 0 then new.status := 'reading'; new.started_on := coalesce(new.started_on, current_date); end if;
  if new.status = 'done' then
    new.current_page := total;
    new.finished_on := coalesce(new.finished_on, current_date);
    new.started_on := coalesce(new.started_on, new.finished_on);
  end if;
  return new;
end $$;
drop trigger if exists user_books_defaults on public.user_books;
create trigger user_books_defaults before insert or update on public.user_books for each row execute function public.user_books_defaults();

create table if not exists public.book_reviews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  book_id uuid not null references public.books(id) on delete cascade,
  rating smallint not null default 0 check (rating between 0 and 5),
  body text not null default '' check (char_length(body) <= 5000),
  is_public boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, book_id)
);

-- ---------- 모임 ----------
create table if not exists public.clubs (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  description text not null default '' check (char_length(description) <= 500),
  is_public boolean not null default true,
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.club_members (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','admin','member')),
  joined_at timestamptz not null default now(),
  unique (club_id, user_id)
);
create index if not exists ix_club_members_user on public.club_members(user_id);

-- 초대 코드는 별도 테이블에 두어 일반 멤버에게 노출하지 않음
create table if not exists public.club_secrets (
  club_id uuid primary key references public.clubs(id) on delete cascade,
  invite_code text not null unique
);

create table if not exists public.club_books (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  book_id uuid not null references public.books(id) on delete cascade,
  added_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (club_id, book_id)
);

-- 권한 확인 함수 (RLS 재귀를 피하려고 security definer)
create or replace function public.is_club_member(cid uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.club_members where club_id = cid and user_id = auth.uid()) $$;
create or replace function public.is_club_admin(cid uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.club_members where club_id = cid and user_id = auth.uid() and role in ('owner','admin')) $$;
create or replace function public.is_club_owner(cid uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.club_members where club_id = cid and user_id = auth.uid() and role = 'owner') $$;

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  book_id uuid references public.books(id) on delete set null,
  title text not null check (char_length(title) between 1 and 100),
  starts_at timestamptz not null,
  location text not null default '',
  description text not null default '' check (char_length(description) <= 1000),
  status text not null default 'scheduled' check (status in ('scheduled','cancelled')),
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ix_events_club on public.events(club_id, starts_at);

create or replace function public.event_club_id(eid uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$ select club_id from public.events where id = eid $$;

create table if not exists public.event_rsvps (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  response text not null check (response in ('attending','not_attending','undecided')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (event_id, user_id)
);

-- ---------- 토론 ----------
create table if not exists public.discussion_posts (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  book_id uuid references public.books(id) on delete set null,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  body text not null check (char_length(body) between 1 and 5000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ix_posts_club on public.discussion_posts(club_id, created_at desc);

create or replace function public.post_club_id(pid uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$ select club_id from public.discussion_posts where id = pid $$;

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.discussion_posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ix_comments_post on public.comments(post_id, created_at);

create table if not exists public.post_likes (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.discussion_posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (post_id, user_id)
);

-- ---------- 독서 일지 (기본 비공개) ----------
create table if not exists public.reading_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  book_id uuid not null references public.books(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 10000),
  visibility text not null default 'private' check (visibility in ('private','club','public')),
  club_id uuid references public.clubs(id) on delete set null,   -- 모임이 삭제되면 나만 보이는 상태가 됨
  source text not null default 'manual' check (source in ('manual','ai_chat')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ix_logs_user on public.reading_logs(user_id, created_at desc);

-- ---------- 공개 책 추천(사용자) ----------
create table if not exists public.book_recommendations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  book_id uuid not null references public.books(id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 200),
  created_at timestamptz not null default now(),
  unique (user_id, book_id)
);

-- ---------- AI: 녹음 / 전사 / 요약 / 추천 / 대화 ----------
create table if not exists public.meeting_recordings (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  uploaded_by uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  storage_path text,
  mime text,
  size_bytes bigint,
  duration_sec real,
  consent_confirmed boolean not null default false check (consent_confirmed),   -- 참석자 동의 확인 없이는 저장 불가
  status text not null default 'uploaded' check (status in ('uploaded','transcribing','transcribed','summarizing','completed','failed')),
  error text,
  audio_deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ix_rec_event on public.meeting_recordings(event_id, created_at desc);

create or replace function public.recording_club_id(rid uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select e.club_id from public.meeting_recordings r join public.events e on e.id = r.event_id where r.id = rid $$;

create table if not exists public.meeting_transcripts (
  id uuid primary key default gen_random_uuid(),
  recording_id uuid not null unique references public.meeting_recordings(id) on delete cascade,
  language text not null default 'ko-KR',
  created_at timestamptz not null default now()
);

create or replace function public.transcript_club_id(tid uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select e.club_id from public.meeting_transcripts t
  join public.meeting_recordings r on r.id = t.recording_id join public.events e on e.id = r.event_id where t.id = tid $$;

create table if not exists public.transcript_segments (
  id uuid primary key default gen_random_uuid(),
  transcript_id uuid not null references public.meeting_transcripts(id) on delete cascade,
  idx integer not null,
  speaker text not null default '',
  body text not null,
  start_ms integer,
  end_ms integer
);
create index if not exists ix_segments on public.transcript_segments(transcript_id, idx);

create table if not exists public.meeting_summaries (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  recording_id uuid not null unique references public.meeting_recordings(id) on delete cascade,
  overview text not null default '',
  model text,
  edited boolean not null default false,
  dropped_quotes integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.summary_club_id(sid uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select e.club_id from public.meeting_summaries s join public.events e on e.id = s.event_id where s.id = sid $$;

create table if not exists public.summary_insights (
  id uuid primary key default gen_random_uuid(),
  summary_id uuid not null references public.meeting_summaries(id) on delete cascade,
  section text not null check (section in ('topics','opinions','differences','quotes','questions','conclusions','next_topics')),
  kind text not null check (kind in ('statement','interpretation')),
  body text not null check (char_length(body) between 1 and 2000),
  position integer not null default 0
);
create index if not exists ix_insights on public.summary_insights(summary_id, section, position);

create table if not exists public.ai_book_recommendations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  title text not null,
  author text not null,
  reason text,
  connection text,
  discussion_questions jsonb not null default '[]',
  verified boolean not null default false,       -- 서재 DB에 등록된 책인지 (서지정보 확인 여부)
  created_at timestamptz not null default now()
);
create index if not exists ix_ai_recs on public.ai_book_recommendations(event_id);

create or replace function public.ai_rec_club_id(rid uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select e.club_id from public.ai_book_recommendations a join public.events e on e.id = a.event_id where a.id = rid $$;

create table if not exists public.ai_rec_votes (
  id uuid primary key default gen_random_uuid(),
  rec_id uuid not null references public.ai_book_recommendations(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  unique (rec_id, user_id)
);

create table if not exists public.club_prefs (
  id uuid primary key default gen_random_uuid(),
  club_id uuid not null references public.clubs(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  unique (club_id, user_id)
);

create table if not exists public.ai_conversations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  title text not null,
  book_id uuid references public.books(id) on delete set null,
  event_id uuid references public.events(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ix_conv_user on public.ai_conversations(user_id, updated_at desc);

create table if not exists public.ai_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  role text not null check (role in ('user','assistant')),
  content text not null check (char_length(content) between 1 and 8000),
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists ix_msgs on public.ai_messages(conversation_id, created_at);

-- AI 작업 대기열: 클라이언트는 아래 RPC로만 요청하고, 처리는 서버(service_role)의 worker가 해요.
create table if not exists public.ai_jobs (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('recording','summary','recommend','chat')),
  ref_id uuid not null,                         -- recording / event / conversation 의 id
  requested_by uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'queued' check (status in ('queued','running','done','failed')),
  error text,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists ix_jobs_queue on public.ai_jobs(status, created_at);

create table if not exists public.ai_usage (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles(id) on delete set null,
  kind text not null,
  units real not null default 1,
  created_at timestamptz not null default now()
);
create table if not exists public.join_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  at timestamptz not null default now()
);

-- ---------- updated_at 트리거 ----------
do $$ declare t text; begin
  foreach t in array array['profiles','user_books','book_reviews','clubs','events','event_rsvps','discussion_posts','comments','reading_logs','meeting_recordings','meeting_summaries','ai_conversations']
  loop
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    execute format('create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()', t);
  end loop;
end $$;

-- ---------- RPC (클라이언트가 호출하는 안전한 동작) ----------
create or replace function public.create_club(p_name text, p_description text default '', p_is_public boolean default true)
returns table (id uuid, invite_code text)
language plpgsql security definer set search_path = public, pg_temp as $$
declare cid uuid; code text;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  if char_length(trim(coalesce(p_name,''))) = 0 then raise exception '모임 이름을 입력해 주세요.'; end if;
  insert into public.clubs(name, description, is_public, created_by) values (trim(p_name), coalesce(p_description,''), p_is_public, auth.uid()) returning clubs.id into cid;
  insert into public.club_members(club_id, user_id, role) values (cid, auth.uid(), 'owner');
  if not p_is_public then
    code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    insert into public.club_secrets(club_id, invite_code) values (cid, code);
  end if;
  return query select cid, code;
end $$;

-- 반환: 가입한 모임 id, 코드가 틀리면 null (앱에서 '일치하는 초대 코드가 없어요'로 안내)
create or replace function public.join_club_by_code(p_code text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare cid uuid;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  if (select count(*) from public.join_attempts where user_id = auth.uid() and at > now() - interval '1 minute') >= 5 then
    raise exception '시도가 너무 많아요. 1분 뒤에 다시 시도해 주세요.';
  end if;
  insert into public.join_attempts(user_id) values (auth.uid());
  select club_id into cid from public.club_secrets where invite_code = upper(trim(coalesce(p_code,'')));
  -- 주의: 여기서 raise 하면 위의 시도 기록(insert)까지 롤백되어 횟수 제한이 무력화돼요. 그래서 실패는 null로 돌려줘요.
  if cid is null then return null; end if;
  insert into public.club_members(club_id, user_id, role) values (cid, auth.uid(), 'member') on conflict (club_id, user_id) do nothing;
  return cid;
end $$;

create or replace function public.leave_club(p_club uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r text; n int;
begin
  select role into r from public.club_members where club_id = p_club and user_id = auth.uid();
  if r is null then raise exception '참여 중인 모임이 아니에요.'; end if;
  select count(*) into n from public.club_members where club_id = p_club;
  if r = 'owner' and n > 1 then raise exception '모임장은 다른 멤버에게 모임장을 넘긴 뒤 나갈 수 있어요.'; end if;
  delete from public.club_members where club_id = p_club and user_id = auth.uid();
  if n = 1 then delete from public.clubs where id = p_club; end if;   -- 마지막 멤버면 모임도 삭제(하위 데이터는 cascade)
end $$;

create or replace function public.set_member_role(p_club uuid, p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_club_owner(p_club) then raise exception '모임장만 역할을 바꿀 수 있어요.'; end if;
  if p_role not in ('admin','member') then raise exception '올바르지 않은 역할이에요.'; end if;
  if p_user = auth.uid() then raise exception '자신의 역할은 바꿀 수 없어요.'; end if;
  update public.club_members set role = p_role where club_id = p_club and user_id = p_user and role <> 'owner';
end $$;

create or replace function public.list_clubs() returns table (id uuid, name text, description text, is_public boolean, my_role text, member_count bigint)
language sql stable security definer set search_path = public, pg_temp as $$
  select c.id, c.name, c.description, c.is_public,
         (select m.role from public.club_members m where m.club_id = c.id and m.user_id = auth.uid()),
         (select count(*) from public.club_members m where m.club_id = c.id)
  from public.clubs c
  where auth.uid() is not null and (c.is_public or exists (select 1 from public.club_members m where m.club_id = c.id and m.user_id = auth.uid()))
  order by c.name $$;

create or replace function public.popular_books(p_limit int default 10) returns table (book_id uuid, title text, author text, readers bigint)
language sql stable security definer set search_path = public, pg_temp as $$
  select b.id, b.title, b.author, count(ub.id) from public.books b join public.user_books ub on ub.book_id = b.id
  where auth.uid() is not null group by b.id order by count(ub.id) desc limit least(greatest(p_limit,1),50) $$;

create or replace function public.rename_speaker(p_transcript uuid, p_old text, p_new text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_club_member(public.transcript_club_id(p_transcript)) then raise exception '모임 멤버만 할 수 있어요.'; end if;
  if char_length(trim(coalesce(p_new,''))) = 0 then raise exception '새 이름을 입력해 주세요.'; end if;
  update public.transcript_segments set speaker = left(trim(p_new), 20) where transcript_id = p_transcript and speaker = p_old;
end $$;

create or replace function public._enqueue(p_kind text, p_ref uuid, p_user uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare jid uuid;
begin
  if (select count(*) from public.ai_jobs where requested_by = p_user and status in ('queued','running')) >= 5 then
    raise exception '처리 중인 AI 작업이 많아요. 잠시 뒤에 다시 시도해 주세요.';
  end if;
  insert into public.ai_jobs(kind, ref_id, requested_by) values (p_kind, p_ref, p_user) returning id into jid;
  return jid;
end $$;
revoke all on function public._enqueue(text, uuid, uuid) from public, anon, authenticated;

-- 녹음 등록 시 자동으로 AI 처리 작업을 대기열에 넣음
create or replace function public.on_recording_insert() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_club_member(public.event_club_id(new.event_id)) then raise exception '모임 멤버만 녹음을 올릴 수 있어요.'; end if;
  perform public._enqueue('recording', new.id, new.uploaded_by);
  return new;
end $$;
drop trigger if exists on_recording_insert on public.meeting_recordings;
create trigger on_recording_insert after insert on public.meeting_recordings for each row execute function public.on_recording_insert();

create or replace function public.retry_recording(p_recording uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s text;
begin
  if not public.is_club_member(public.recording_club_id(p_recording)) then raise exception '모임 멤버만 할 수 있어요.'; end if;
  select status into s from public.meeting_recordings where id = p_recording;
  if s <> 'failed' then raise exception '실패한 처리만 다시 시도할 수 있어요.'; end if;
  update public.meeting_recordings set status = 'uploaded', error = null where id = p_recording;
  perform public._enqueue('recording', p_recording, auth.uid());
end $$;

create or replace function public.regenerate_summary(p_recording uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s text;
begin
  if not public.is_club_member(public.recording_club_id(p_recording)) then raise exception '모임 멤버만 할 수 있어요.'; end if;
  if not exists (select 1 from public.meeting_transcripts where recording_id = p_recording) then raise exception '대화 기록이 있어야 요약을 다시 만들 수 있어요.'; end if;
  select status into s from public.meeting_recordings where id = p_recording;
  if s in ('transcribing','summarizing') then raise exception '지금 처리 중이에요. 잠시 뒤 다시 시도해 주세요.'; end if;
  update public.meeting_recordings set status = 'summarizing', error = null where id = p_recording;
  perform public._enqueue('summary', p_recording, auth.uid());
end $$;

create or replace function public.request_recommendations(p_event uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_club_member(public.event_club_id(p_event)) then raise exception '모임 멤버만 할 수 있어요.'; end if;
  if not exists (select 1 from public.meeting_summaries where event_id = p_event) then raise exception '모임 요약이 완료된 뒤에 추천받을 수 있어요.'; end if;
  perform public._enqueue('recommend', p_event, auth.uid());
end $$;

create or replace function public.create_conversation(p_book uuid default null, p_event uuid default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare cid uuid; t text; bid uuid := p_book;
begin
  if auth.uid() is null then raise exception '로그인이 필요해요.'; end if;
  if p_book is null and p_event is null then raise exception '책이나 모임을 선택해 주세요.'; end if;
  if p_event is not null then
    if not public.is_club_member(public.event_club_id(p_event)) then raise exception '모임 멤버만 할 수 있어요.'; end if;
    select title, coalesce(bid, book_id) into t, bid from public.events where id = p_event;
  end if;
  if bid is not null then
    select coalesce(t, title) into t from public.books where id = bid;
    if t is null then raise exception '책을 찾을 수 없어요.'; end if;
  end if;
  insert into public.ai_conversations(user_id, title, book_id, event_id) values (auth.uid(), left(t, 80), bid, p_event) returning id into cid;
  return cid;
end $$;

create or replace function public.send_chat_message(p_conversation uuid, p_text text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare mid uuid;
begin
  if not exists (select 1 from public.ai_conversations where id = p_conversation and user_id = auth.uid()) then raise exception '대화를 찾을 수 없어요.'; end if;
  if char_length(trim(coalesce(p_text,''))) = 0 then raise exception '내용을 입력해 주세요.'; end if;
  insert into public.ai_messages(conversation_id, role, content) values (p_conversation, 'user', left(trim(p_text), 4000)) returning id into mid;
  perform public._enqueue('chat', p_conversation, auth.uid());
  update public.ai_conversations set updated_at = now() where id = p_conversation;
  return mid;
end $$;

create or replace function public.save_chat_excerpt(p_message uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m record;
begin
  select am.content, c.book_id, c.user_id into m from public.ai_messages am join public.ai_conversations c on c.id = am.conversation_id where am.id = p_message;
  if m.user_id is distinct from auth.uid() then raise exception '메시지를 찾을 수 없어요.'; end if;
  if m.book_id is null or not exists (select 1 from public.user_books where user_id = auth.uid() and book_id = m.book_id) then raise exception '내 서재에 있는 책의 대화만 일지에 저장할 수 있어요.'; end if;
  insert into public.reading_logs(user_id, book_id, body, visibility, source) values (auth.uid(), m.book_id, '[AI 독서 토론에서 저장]' || E'\n' || m.content, 'private', 'ai_chat');
end $$;

create or replace function public.delete_recording_audio(p_recording uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record;
begin
  select r2.uploaded_by, e.club_id into r from public.meeting_recordings r2 join public.events e on e.id = r2.event_id where r2.id = p_recording;
  if not found then raise exception '녹음을 찾을 수 없어요.'; end if;
  if r.uploaded_by <> auth.uid() and not public.is_club_admin(r.club_id) then raise exception '올린 사람이나 운영진만 삭제할 수 있어요.'; end if;
  update public.meeting_recordings set audio_deleted = true, storage_path = null where id = p_recording;
end $$;

-- ---------- 권한(GRANT): 로그인한 사용자만. 비로그인(anon)에게는 아무것도 주지 않음 ----------
do $$ declare t text; begin
  foreach t in array array['profiles','books','user_books','book_reviews','clubs','club_members','club_secrets','club_books','events','event_rsvps','discussion_posts','comments','post_likes','reading_logs','book_recommendations','meeting_recordings','meeting_transcripts','transcript_segments','meeting_summaries','summary_insights','ai_book_recommendations','ai_rec_votes','club_prefs','ai_conversations','ai_messages','ai_jobs','ai_usage','join_attempts']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke all on public.%I from authenticated', t);
  end loop;
end $$;

grant select on public.profiles, public.books, public.club_secrets, public.club_books, public.events, public.event_rsvps, public.discussion_posts, public.comments, public.post_likes,
  public.reading_logs, public.book_recommendations, public.meeting_recordings, public.meeting_transcripts, public.transcript_segments, public.meeting_summaries, public.summary_insights,
  public.ai_book_recommendations, public.ai_rec_votes, public.club_prefs, public.ai_conversations, public.ai_messages, public.ai_jobs, public.clubs, public.club_members,
  public.user_books, public.book_reviews to authenticated;
grant update (nickname, intro, avatar_path) on public.profiles to authenticated;
grant insert (title, author, genre, pages) on public.books to authenticated;
grant insert, update, delete on public.user_books, public.book_reviews to authenticated;
grant update (name, description, is_public) on public.clubs to authenticated;
grant delete on public.clubs to authenticated;
grant insert (club_id, user_id, role) on public.club_members to authenticated;
grant insert, delete on public.club_books to authenticated;
grant insert (club_id, book_id, title, starts_at, location, description, status), update (book_id, title, starts_at, location, description, status), delete on public.events to authenticated;
grant insert (event_id, response), update (response), delete on public.event_rsvps to authenticated;
grant insert (club_id, book_id, title, body), update (book_id, title, body), delete on public.discussion_posts to authenticated;
grant insert (post_id, body), update (body), delete on public.comments to authenticated;
grant insert (post_id), delete on public.post_likes to authenticated;
grant insert (book_id, body, visibility, club_id), update (body, visibility, club_id), delete on public.reading_logs to authenticated;
grant insert (book_id, reason), update (reason), delete on public.book_recommendations to authenticated;
grant insert (event_id, storage_path, mime, size_bytes, duration_sec, consent_confirmed), delete on public.meeting_recordings to authenticated;
grant update (overview, edited) on public.meeting_summaries to authenticated;
grant insert, update, delete on public.summary_insights to authenticated;
grant insert (rec_id), delete on public.ai_rec_votes to authenticated;
grant insert (club_id, body), update (body), delete on public.club_prefs to authenticated;
grant update (title), delete on public.ai_conversations to authenticated;

revoke all on function public.create_club(text,text,boolean), public.join_club_by_code(text), public.leave_club(uuid), public.set_member_role(uuid,uuid,text),
  public.list_clubs(), public.popular_books(int), public.rename_speaker(uuid,text,text), public.retry_recording(uuid), public.regenerate_summary(uuid),
  public.request_recommendations(uuid), public.delete_recording_audio(uuid), public.create_conversation(uuid,uuid), public.send_chat_message(uuid,text), public.save_chat_excerpt(uuid),
  public.is_club_member(uuid), public.is_club_admin(uuid), public.is_club_owner(uuid), public.event_club_id(uuid), public.post_club_id(uuid), public.recording_club_id(uuid),
  public.transcript_club_id(uuid), public.summary_club_id(uuid), public.ai_rec_club_id(uuid) from public, anon;
grant execute on function public.create_club(text,text,boolean), public.join_club_by_code(text), public.leave_club(uuid), public.set_member_role(uuid,uuid,text),
  public.list_clubs(), public.popular_books(int), public.rename_speaker(uuid,text,text), public.retry_recording(uuid), public.regenerate_summary(uuid),
  public.request_recommendations(uuid), public.delete_recording_audio(uuid), public.create_conversation(uuid,uuid), public.send_chat_message(uuid,text), public.save_chat_excerpt(uuid),
  public.is_club_member(uuid), public.is_club_admin(uuid), public.is_club_owner(uuid), public.event_club_id(uuid), public.post_club_id(uuid), public.recording_club_id(uuid),
  public.transcript_club_id(uuid), public.summary_club_id(uuid), public.ai_rec_club_id(uuid) to authenticated;


-- AI 처리 서버(secret key = service_role)가 쓸 수 있도록 명시적으로 권한 부여
-- ('Automatically expose new tables'를 끈 프로젝트에서도 동작하게 하려는 거예요)
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;

-- ---------- RLS 정책 ----------
do $$ declare r record; begin
  for r in select schemaname, tablename, policyname from pg_policies where schemaname = 'public' loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- 프로필: 로그인한 사용자는 닉네임·소개를 볼 수 있고, 본인 것만 수정
create policy profiles_read on public.profiles for select to authenticated using (true);
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- 책 목록은 공용. 등록은 가능하지만 남의 책 정보를 수정/삭제할 수는 없음
create policy books_read on public.books for select to authenticated using (true);
create policy books_insert on public.books for insert to authenticated with check (created_by = auth.uid());

-- 내 서재/서평: 본인 것만 (공개 서평은 공개로 지정한 것만 타인에게 보임)
create policy user_books_own on public.user_books for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy reviews_read on public.book_reviews for select to authenticated using (user_id = auth.uid() or is_public);
create policy reviews_write on public.book_reviews for insert to authenticated with check (user_id = auth.uid());
create policy reviews_update on public.book_reviews for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy reviews_delete on public.book_reviews for delete to authenticated using (user_id = auth.uid());

-- 독서 일지: 비공개는 본인만, 클럽 공개는 해당 모임 멤버, 전체 공개는 로그인한 모두
create policy logs_read on public.reading_logs for select to authenticated using (
  user_id = auth.uid() or visibility = 'public' or (visibility = 'club' and club_id is not null and public.is_club_member(club_id)));
create policy logs_insert on public.reading_logs for insert to authenticated with check (
  user_id = auth.uid()
  and exists (select 1 from public.user_books ub where ub.user_id = auth.uid() and ub.book_id = reading_logs.book_id)
  and (visibility <> 'club' or (club_id is not null and public.is_club_member(club_id))));
create policy logs_update on public.reading_logs for update to authenticated using (user_id = auth.uid()) with check (
  user_id = auth.uid() and (visibility <> 'club' or (club_id is not null and public.is_club_member(club_id))));
create policy logs_delete on public.reading_logs for delete to authenticated using (user_id = auth.uid());

-- 모임: 공개 모임은 누구나 보고, 비공개 모임은 멤버만. 생성/가입/탈퇴는 RPC 또는 아래 정책으로만
create policy clubs_read on public.clubs for select to authenticated using (is_public or public.is_club_member(id));
create policy clubs_update on public.clubs for update to authenticated using (public.is_club_admin(id)) with check (public.is_club_admin(id));
create policy clubs_delete on public.clubs for delete to authenticated using (public.is_club_owner(id));
create policy secrets_read on public.club_secrets for select to authenticated using (public.is_club_admin(club_id));
create policy members_read on public.club_members for select to authenticated using (public.is_club_member(club_id));
create policy members_join_public on public.club_members for insert to authenticated with check (
  user_id = auth.uid() and role = 'member' and exists (select 1 from public.clubs c where c.id = club_id and c.is_public));
create policy club_books_read on public.club_books for select to authenticated using (exists (select 1 from public.clubs c where c.id = club_id));
create policy club_books_ins on public.club_books for insert to authenticated with check (public.is_club_admin(club_id) and added_by = auth.uid());
create policy club_books_del on public.club_books for delete to authenticated using (public.is_club_admin(club_id));

-- 일정: 멤버만 보고, 모임장/운영진만 관리
create policy events_read on public.events for select to authenticated using (public.is_club_member(club_id));
create policy events_ins on public.events for insert to authenticated with check (public.is_club_admin(club_id) and created_by = auth.uid());
create policy events_upd on public.events for update to authenticated using (public.is_club_admin(club_id)) with check (public.is_club_admin(club_id));
create policy events_del on public.events for delete to authenticated using (public.is_club_admin(club_id));
create policy rsvps_read on public.event_rsvps for select to authenticated using (public.is_club_member(public.event_club_id(event_id)));
create policy rsvps_ins on public.event_rsvps for insert to authenticated with check (user_id = auth.uid() and public.is_club_member(public.event_club_id(event_id)));
create policy rsvps_upd on public.event_rsvps for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy rsvps_del on public.event_rsvps for delete to authenticated using (user_id = auth.uid());

-- 토론: 멤버만. 작성/수정은 본인 것, 삭제는 본인 또는 운영진
create policy posts_read on public.discussion_posts for select to authenticated using (public.is_club_member(club_id));
create policy posts_ins on public.discussion_posts for insert to authenticated with check (user_id = auth.uid() and public.is_club_member(club_id));
create policy posts_upd on public.discussion_posts for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy posts_del on public.discussion_posts for delete to authenticated using (user_id = auth.uid() or public.is_club_admin(club_id));
create policy comments_read on public.comments for select to authenticated using (public.is_club_member(public.post_club_id(post_id)));
create policy comments_ins on public.comments for insert to authenticated with check (user_id = auth.uid() and public.is_club_member(public.post_club_id(post_id)));
create policy comments_upd on public.comments for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy comments_del on public.comments for delete to authenticated using (user_id = auth.uid() or public.is_club_admin(public.post_club_id(post_id)));
create policy likes_read on public.post_likes for select to authenticated using (public.is_club_member(public.post_club_id(post_id)));
create policy likes_ins on public.post_likes for insert to authenticated with check (user_id = auth.uid() and public.is_club_member(public.post_club_id(post_id)));
create policy likes_del on public.post_likes for delete to authenticated using (user_id = auth.uid());

-- 공개 책 추천
create policy brec_read on public.book_recommendations for select to authenticated using (true);
create policy brec_ins on public.book_recommendations for insert to authenticated with check (user_id = auth.uid());
create policy brec_upd on public.book_recommendations for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy brec_del on public.book_recommendations for delete to authenticated using (user_id = auth.uid());

-- AI: 녹음/전사/요약/추천은 모임 멤버만. 전사·요약 '생성'은 서버(service_role)만 가능 → 위조 불가
create policy rec_read on public.meeting_recordings for select to authenticated using (public.is_club_member(public.event_club_id(event_id)));
create policy rec_ins on public.meeting_recordings for insert to authenticated with check (
  uploaded_by = auth.uid() and consent_confirmed and status = 'uploaded' and public.is_club_member(public.event_club_id(event_id)));
create policy rec_del on public.meeting_recordings for delete to authenticated using (uploaded_by = auth.uid() or public.is_club_admin(public.event_club_id(event_id)));
create policy tr_read on public.meeting_transcripts for select to authenticated using (public.is_club_member(public.recording_club_id(recording_id)));
create policy seg_read on public.transcript_segments for select to authenticated using (public.is_club_member(public.transcript_club_id(transcript_id)));
create policy sum_read on public.meeting_summaries for select to authenticated using (public.is_club_member(public.event_club_id(event_id)));
create policy sum_upd on public.meeting_summaries for update to authenticated using (public.is_club_member(public.event_club_id(event_id))) with check (public.is_club_member(public.event_club_id(event_id)));
create policy ins_read on public.summary_insights for select to authenticated using (public.is_club_member(public.summary_club_id(summary_id)));
create policy ins_ins on public.summary_insights for insert to authenticated with check (public.is_club_member(public.summary_club_id(summary_id)));
create policy ins_upd on public.summary_insights for update to authenticated using (public.is_club_member(public.summary_club_id(summary_id))) with check (public.is_club_member(public.summary_club_id(summary_id)));
create policy ins_del on public.summary_insights for delete to authenticated using (public.is_club_member(public.summary_club_id(summary_id)));
create policy airec_read on public.ai_book_recommendations for select to authenticated using (public.is_club_member(public.event_club_id(event_id)));
create policy votes_read on public.ai_rec_votes for select to authenticated using (public.is_club_member(public.ai_rec_club_id(rec_id)));
create policy votes_ins on public.ai_rec_votes for insert to authenticated with check (user_id = auth.uid() and public.is_club_member(public.ai_rec_club_id(rec_id)));
create policy votes_del on public.ai_rec_votes for delete to authenticated using (user_id = auth.uid());
create policy prefs_own_read on public.club_prefs for select to authenticated using (user_id = auth.uid());
create policy prefs_ins on public.club_prefs for insert to authenticated with check (user_id = auth.uid() and public.is_club_member(club_id));
create policy prefs_upd on public.club_prefs for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy prefs_del on public.club_prefs for delete to authenticated using (user_id = auth.uid());

-- 개인 AI 대화: 본인만 (메시지는 RPC로만 추가)
create policy conv_own_read on public.ai_conversations for select to authenticated using (user_id = auth.uid());
create policy conv_own_upd on public.ai_conversations for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy conv_own_del on public.ai_conversations for delete to authenticated using (user_id = auth.uid());
create policy msg_own_read on public.ai_messages for select to authenticated using (exists (select 1 from public.ai_conversations c where c.id = conversation_id and c.user_id = auth.uid()));
create policy jobs_own_read on public.ai_jobs for select to authenticated using (requested_by = auth.uid());
-- ai_usage, join_attempts: 정책 없음 = 클라이언트는 접근 불가 (서버/RPC만)

-- ---------- 녹음 파일 저장소(Storage) ----------
-- 아래 부분만 권한 오류가 나면(storage 테이블 소유자 문제), 대시보드 Storage > Policies 에서 같은 규칙을 만들어도 돼요.
insert into storage.buckets (id, name, public) values ('recordings', 'recordings', false) on conflict (id) do nothing;
drop policy if exists rec_obj_select on storage.objects;
drop policy if exists rec_obj_insert on storage.objects;
drop policy if exists rec_obj_delete on storage.objects;
-- 파일 경로 규칙: {club_id}/{event_id}/{파일명}
create policy rec_obj_select on storage.objects for select to authenticated using (
  bucket_id = 'recordings' and public.is_club_member(public.safe_uuid((storage.foldername(name))[1])));
create policy rec_obj_insert on storage.objects for insert to authenticated with check (
  bucket_id = 'recordings' and public.is_club_member(public.safe_uuid((storage.foldername(name))[1])));
create policy rec_obj_delete on storage.objects for delete to authenticated using (
  bucket_id = 'recordings' and (owner = auth.uid() or public.is_club_admin(public.safe_uuid((storage.foldername(name))[1]))));
