/* BOOKMATE · Supabase 연결 계층
 * 화면(index.html)은 api('이름', 값) 형태로 호출하고, 여기서 Supabase로 바꿔 요청해요.
 * 아래 두 값은 '공개용'이에요. (데이터 보호는 DB의 RLS 규칙이 담당해요.)
 * 절대로 secret key / service_role 키를 이 파일에 넣지 마세요.
 */
const SB_URL = 'https://YOUR-PROJECT-REF.supabase.co';   // 내 Supabase 프로젝트 주소로 바꾸세요
const SB_KEY = 'sb_publishable_YOUR_KEY';                  // Project Settings > API Keys 의 publishable key
const BUCKET = 'recordings', MAX_UPLOAD_MB = 50;   // Supabase 무료 플랜의 파일 1개 한도

const sb = supabase.createClient(SB_URL, SB_KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false } });

class ApiErr extends Error {}
const fail = m => { throw new ApiErr(m); };
function msg(e) {
  const m = (e && e.message) || '';
  if (e && e.status === 429) return '시도가 너무 많아요. 잠시 뒤 다시 시도해 주세요.';
  if (e && e.code === '23505') return '이미 등록되어 있어요.';
  if (e && (e.code === '42501' || /row-level security|permission denied/i.test(m))) return '권한이 없어요.';
  if (/[가-힣]/.test(m)) return m;                  // DB 함수가 돌려준 한국어 안내문
  if (e && e.code === '23514') return '입력값을 확인해 주세요.';
  if (e && e.code === '23503') return '연결된 데이터를 찾을 수 없어요.';
  if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return '서버에 연결할 수 없어요. 네트워크를 확인해 주세요.';
  console.error('[bookmate]', e);
  return '오류가 발생했어요.';
}
const q = async p => { const { data, error } = await p; if (error) { console.error('[bookmate]', error); throw new ApiErr(msg(error)); } return data; };
const one = x => Array.isArray(x) ? x[0] : x;
const kst = t => t ? new Date(t).toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' }).slice(0, 16) : '';
const dstr = t => new Date(t).toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' });
const RESP = { yes: 'attending', no: 'not_attending', maybe: 'undecided' };
const RESPR = { attending: 'yes', not_attending: 'no', undecided: 'maybe' };
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function pageAll(build) { const out = []; for (let f = 0; ; f += 1000) { const d = await q(build().range(f, f + 999)); out.push(...d); if (d.length < 1000) break; } return out; }

let ME = null;
async function loadMe() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) { ME = null; return null; }
  const { data: p } = await sb.from('profiles').select('id,nickname').eq('id', session.user.id).maybeSingle();
  if (!p) { ME = null; return null; }
  return (ME = { id: p.id, nick: p.nickname });
}
const need = () => ME || fail('로그인이 필요해요.');
async function emailFor(nick) {   // 닉네임 로그인: 닉네임에서 가짜 이메일 주소를 만들어 Supabase 인증에 사용
  const n = nick.trim().toLowerCase().normalize('NFC');
  const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('bookmate:' + n));
  return 'u' + [...new Uint8Array(b)].slice(0, 16).map(x => x.toString(16).padStart(2, '0')).join('') + '@bookmate.app';
}

const H = {
  /* ---------- 계정 ---------- */
  me: async () => ({ me: await loadMe(), need_code: false }),
  login: async ({ nick, pw }) => {
    if (!nick || !pw) fail('닉네임과 비밀번호를 입력해 주세요.');
    const { error } = await sb.auth.signInWithPassword({ email: await emailFor(nick), password: pw });
    if (error) fail(/invalid/i.test(error.message) ? '닉네임 또는 비밀번호가 맞지 않아요.' : msg(error));
    const m = await loadMe(); if (!m) fail('프로필을 찾을 수 없어요.');
    return { me: m };
  },
  signup: async ({ nick, pw }) => {
    nick = (nick || '').trim();
    if (!nick || nick.length > 16) fail('닉네임은 1~16자로 입력해 주세요.');
    if ((pw || '').length < 6) fail('비밀번호는 6자 이상이어야 해요.');
    const { data, error } = await sb.auth.signUp({ email: await emailFor(nick), password: pw, options: { data: { nickname: nick } } });
    if (error) fail(/already|registered/i.test(error.message) ? '이미 사용 중인 닉네임이에요.' : msg(error));
    if (!data.session) fail('가입은 됐지만 이메일 인증이 켜져 있어요. Supabase에서 Confirm email을 꺼 주세요.');
    await loadMe(); return {};
  },
  logout: async () => { await sb.auth.signOut(); ME = null; return {}; },

  /* ---------- 내 서재 ---------- */
  lib: async () => {
    need();
    const ub = await q(sb.from('user_books').select('id,book_id,status,current_page,books(title,author,pages,genre)').order('updated_at', { ascending: false }));
    const rv = await q(sb.from('book_reviews').select('book_id,rating,body,is_public').eq('user_id', ME.id));
    const rm = new Map(rv.map(r => [r.book_id, r]));
    const books = ub.map(x => { const r = rm.get(x.book_id) || {}; return { id: x.id, book_id: x.book_id, title: x.books.title, author: x.books.author, pages: x.books.pages, genre: x.books.genre, status: x.status, page: x.current_page, rating: r.rating || 0, review: r.body || '', review_public: !!r.is_public }; });
    const journals = (await q(sb.from('reading_logs').select('id,book_id,body,visibility,created_at').eq('user_id', ME.id).order('created_at', { ascending: false }).limit(100))).map(j => ({ ...j, created_at: kst(j.created_at) }));
    return { books, journals };
  },
  books_search: async ({ q: s = '' }) => {
    let b = sb.from('books').select('id,title,author,pages').order('title').limit(30);
    const t = (s || '').replace(/[,()%*\\"]/g, ' ').trim();
    if (t) b = b.or(`title.ilike.%${t}%,author.ilike.%${t}%`);
    return { books: await q(b) };
  },
  add_book: async d => {
    need(); let bid = d.book_id;
    if (!bid) {
      const title = (d.title || '').trim(), author = (d.author || '').trim(), pages = parseInt(d.pages, 10);
      if (!title || !author) fail('제목과 저자를 입력해 주세요.');
      if (!(pages > 0)) fail('쪽수는 1 이상의 숫자로 입력해 주세요.');
      const { data, error } = await sb.from('books').insert({ title, author, genre: d.genre || '기타', pages }).select('id').single();
      if (error) {
        if (error.code !== '23505') fail(msg(error));
        const ex = await q(sb.from('books').select('id').eq('title', title).eq('author', author).maybeSingle());   // 이미 등록된 책이면 그것을 사용
        if (!ex) fail(msg(error)); bid = ex.id;
      } else bid = data.id;
    }
    const { error } = await sb.from('user_books').insert({ book_id: bid, status: d.status || 'want' });
    if (error) fail(error.code === '23505' ? '이미 내 서재에 있는 책이에요.' : msg(error));
    return {};
  },
  upd_book: async d => {
    need();
    const ub = await q(sb.from('user_books').select('id,book_id,books(pages)').eq('id', d.id).maybeSingle());
    if (!ub) fail('책을 찾을 수 없어요.');
    const page = parseInt(d.page, 10) || 0;
    if (page < 0 || page > ub.books.pages) fail(`읽은 쪽수는 0~${ub.books.pages} 사이로 입력해 주세요.`);
    await q(sb.from('user_books').update({ status: d.status, current_page: page }).eq('id', d.id));
    const rating = parseInt(d.rating, 10) || 0, body = (d.review || '').trim();
    const ex = await q(sb.from('book_reviews').select('id').eq('book_id', ub.book_id).eq('user_id', ME.id).maybeSingle());
    if (!rating && !body) { if (ex) await q(sb.from('book_reviews').delete().eq('id', ex.id)); }
    else if (ex) await q(sb.from('book_reviews').update({ rating, body, is_public: !!d.public }).eq('id', ex.id));
    else await q(sb.from('book_reviews').insert({ book_id: ub.book_id, rating, body, is_public: !!d.public }));
    return {};
  },
  del_book: async ({ id }) => { need(); await q(sb.from('user_books').delete().eq('id', id)); return {}; },
  journal_add: async d => {
    need(); const body = (d.body || '').trim(); if (!body) fail('내용을 입력해 주세요.');
    const vis = d.vis || 'private';
    if (vis === 'club' && !d.club_id) fail('클럽 멤버에게 공개하려면 모임을 선택해 주세요.');
    await q(sb.from('reading_logs').insert({ book_id: d.book_id, body, visibility: vis, club_id: vis === 'club' ? d.club_id : null }));
    return {};
  },

  /* ---------- 모임 ---------- */
  clubs: async () => ({ clubs: (await q(sb.rpc('list_clubs'))).map(c => ({ id: c.id, name: c.name, descr: c.description, is_public: c.is_public, role: c.my_role, n: Number(c.member_count) })) }),
  club_create: async d => {
    need(); if (!(d.name || '').trim()) fail('모임 이름을 입력해 주세요.');
    const r = one(await q(sb.rpc('create_club', { p_name: d.name, p_description: d.descr || '', p_is_public: !!d.pub })));
    return { id: r.id, code: r.invite_code };
  },
  club_join: async d => {
    need();
    if (d.code) {
      const id = await q(sb.rpc('join_club_by_code', { p_code: d.code }));
      if (!id) fail('일치하는 초대 코드가 없어요.');
      return { id };
    }
    await q(sb.from('club_members').insert({ club_id: d.id, role: 'member' }));
    return { id: d.id };
  },
  club_leave: async ({ id }) => { await q(sb.rpc('leave_club', { p_club: id })); return {}; },
  set_role: async d => { await q(sb.rpc('set_member_role', { p_club: d.club_id, p_user: d.user_id, p_role: d.role })); return {}; },
  club_get: async ({ id }) => {
    need();
    const c = await q(sb.from('clubs').select('id,name,description,is_public').eq('id', id).maybeSingle());
    if (!c) fail('모임을 찾을 수 없어요.');
    const club = { id: c.id, name: c.name, descr: c.description, is_public: c.is_public };
    const mm = await q(sb.from('club_members').select('user_id,role,profiles(nickname)').eq('club_id', id));
    const mine = mm.find(m => m.user_id === ME.id);
    if (!mine) return { club, role: null, members: [], events: [], posts: [], journals: [] };
    const [sec, ev, po, jr] = await Promise.all([
      q(sb.from('club_secrets').select('invite_code').eq('club_id', id).maybeSingle()),
      q(sb.from('events').select('id,title,starts_at,location,description,books(title),event_rsvps(user_id,response,profiles(nickname))').eq('club_id', id).order('starts_at')),
      q(sb.from('discussion_posts').select('id,title,body,user_id,created_at,profiles(nickname),comments(id,body,created_at,profiles(nickname)),post_likes(user_id)').eq('club_id', id).order('created_at', { ascending: false }).limit(100)),
      q(sb.from('reading_logs').select('id,body,created_at,profiles(nickname),books(title)').eq('club_id', id).eq('visibility', 'club').order('created_at', { ascending: false }).limit(100)),
    ]);
    if (sec) club.code = sec.invite_code;
    return {
      club, role: mine.role,
      members: mm.map(m => ({ id: m.user_id, nick: m.profiles.nickname, role: m.role })).sort((a, b) => ({ owner: 0, admin: 1, member: 2 }[a.role] - { owner: 0, admin: 1, member: 2 }[b.role])),
      events: ev.map(e => {
        const rs = e.event_rsvps.map(x => ({ nick: x.profiles.nickname, resp: RESPR[x.response], uid: x.user_id }));
        const m = rs.find(x => x.uid === ME.id);
        return { id: e.id, title: e.title, date: dstr(e.starts_at), place: e.location, descr: e.description, book_title: e.books ? e.books.title : '', rsvps: rs, mine: m ? m.resp : '' };
      }),
      posts: po.map(p => ({ id: p.id, title: p.title, body: p.body, user_id: p.user_id, nick: p.profiles.nickname, created_at: kst(p.created_at), likes: p.post_likes.length, liked: p.post_likes.some(l => l.user_id === ME.id), comments: p.comments.sort((a, b) => a.created_at < b.created_at ? -1 : 1).map(x => ({ nick: x.profiles.nickname, body: x.body })) })),
      journals: jr.map(j => ({ nick: j.profiles.nickname, title: j.books ? j.books.title : '', body: j.body, created_at: kst(j.created_at) })),
    };
  },
  event_save: async d => {
    need();
    const title = (d.title || '').trim(); if (!title) fail('제목을 입력해 주세요.');
    if (!d.date) fail('날짜를 입력해 주세요.');
    await q(sb.from('events').insert({ club_id: d.club_id, title, starts_at: new Date(d.date + 'T12:00:00+09:00').toISOString(), location: d.place || '', book_id: d.book_id || null, description: d.descr || '' }));
    return {};
  },
  event_del: async ({ id }) => { const r = await q(sb.from('events').delete().eq('id', id).select('id')); if (!r.length) fail('삭제 권한이 없어요.'); return {}; },
  rsvp: async ({ event_id, resp }) => {
    need(); const response = RESP[resp]; if (!response) fail('올바르지 않은 응답이에요.');
    const ex = await q(sb.from('event_rsvps').select('id').eq('event_id', event_id).eq('user_id', ME.id).maybeSingle());
    if (ex) await q(sb.from('event_rsvps').update({ response }).eq('id', ex.id));
    else await q(sb.from('event_rsvps').insert({ event_id, response }));
    return {};
  },
  post_add: async d => {
    need(); const title = (d.title || '').trim(), body = (d.body || '').trim();
    if (!title || !body) fail('제목과 내용을 입력해 주세요.');
    await q(sb.from('discussion_posts').insert({ club_id: d.club_id, title, body })); return {};
  },
  post_del: async ({ id }) => { const r = await q(sb.from('discussion_posts').delete().eq('id', id).select('id')); if (!r.length) fail('삭제 권한이 없어요.'); return {}; },
  comment_add: async d => { need(); await q(sb.from('comments').insert({ post_id: d.post_id, body: d.body })); return {}; },
  like: async ({ post_id }) => {
    need();
    const ex = await q(sb.from('post_likes').select('id').eq('post_id', post_id).eq('user_id', ME.id).maybeSingle());
    if (ex) await q(sb.from('post_likes').delete().eq('id', ex.id)); else await q(sb.from('post_likes').insert({ post_id }));
    return {};
  },

  /* ---------- 모임 녹음 · AI ---------- */
  event_get: async ({ id }) => {
    need();
    const e = await q(sb.from('events').select('id,club_id,title,starts_at,location,books(title)').eq('id', id).maybeSingle());
    if (!e) fail('일정을 찾을 수 없어요.');
    const mr = await q(sb.from('club_members').select('role').eq('club_id', e.club_id).eq('user_id', ME.id).maybeSingle());
    if (!mr) fail('모임 멤버만 볼 수 있어요.');
    const adm = ['owner', 'admin'].includes(mr.role);
    const recs = await q(sb.from('meeting_recordings').select('id,created_at,status,error,duration_sec,storage_path,audio_deleted,uploaded_by,profiles(nickname),meeting_transcripts(id)').eq('event_id', id).order('created_at', { ascending: false }));
    const out = await Promise.all(recs.map(async r => {
      const tr = one(r.meeting_transcripts);
      const [segs, sm, audio] = await Promise.all([
        tr ? pageAll(() => sb.from('transcript_segments').select('idx,speaker,body,start_ms').eq('transcript_id', tr.id).order('idx')) : [],
        q(sb.from('meeting_summaries').select('id,overview,edited,dropped_quotes').eq('recording_id', r.id).maybeSingle()),
        (r.storage_path && !r.audio_deleted) ? sb.storage.from(BUCKET).createSignedUrl(r.storage_path, 3600).then(x => x.data ? x.data.signedUrl : '') : '',
      ]);
      let summary = null;
      if (sm) {
        const items = await q(sb.from('summary_insights').select('section,kind,body,position').eq('summary_id', sm.id).order('position'));
        summary = { id: sm.id, overview: sm.overview, edited: sm.edited, dropped: sm.dropped_quotes, items: items.map(i => ({ section: i.section, kind: i.kind, text: i.body })) };
      }
      return {
        id: r.id, created_at: kst(r.created_at), status: r.status, error: r.error, duration_sec: r.duration_sec, nick: r.profiles.nickname,
        audio, can_delete: r.uploaded_by === ME.id || adm,
        transcript: tr ? { id: tr.id, segments: segs.map(s => ({ speaker: s.speaker, text: s.body, start_ms: s.start_ms })) } : null,
        summary,
      };
    }));
    const pref = await q(sb.from('club_prefs').select('body').eq('club_id', e.club_id).eq('user_id', ME.id).maybeSingle());
    const rc = await q(sb.from('ai_book_recommendations').select('id,title,author,reason,connection,discussion_questions,verified,ai_rec_votes(user_id)').eq('event_id', id).order('created_at'));
    const job = one(await q(sb.from('ai_jobs').select('status,error').eq('ref_id', id).eq('kind', 'recommend').order('created_at', { ascending: false }).limit(1)));
    return {
      event: { id: e.id, club_id: e.club_id, title: e.title, date: dstr(e.starts_at), place: e.location, book: e.books ? { title: e.books.title } : null },
      status: { google: true, claude: true, retention_days: 0 },
      recordings: out, pref: pref ? pref.body : '', pending: !!job && ['queued', 'running'].includes(job.status), rec_error: job && job.status === 'failed' ? (job.error || '추천을 만들지 못했어요.') : '',
      recs: rc.map(r => ({ id: r.id, title: r.title, author: r.author, reason: r.reason || '', connection: r.connection || '', questions: r.discussion_questions || [], verified: r.verified, votes: r.ai_rec_votes.length, voted: r.ai_rec_votes.some(v => v.user_id === ME.id) })),
    };
  },
  rec_delete: async ({ id, all }) => {
    need();
    const r = await q(sb.from('meeting_recordings').select('id,storage_path').eq('id', id).maybeSingle());
    if (!r) fail('녹음을 찾을 수 없어요.');
    if (all) { const d = await q(sb.from('meeting_recordings').delete().eq('id', id).select('id')); if (!d.length) fail('삭제 권한이 없어요.'); }
    else await q(sb.rpc('delete_recording_audio', { p_recording: id }));
    if (r.storage_path) await sb.storage.from(BUCKET).remove([r.storage_path]);
    return {};
  },
  rec_retry: async ({ id }) => { await q(sb.rpc('retry_recording', { p_recording: id })); return {}; },
  summary_regen: async ({ id }) => { await q(sb.rpc('regenerate_summary', { p_recording: id })); return {}; },
  speaker_rename: async d => { await q(sb.rpc('rename_speaker', { p_transcript: d.transcript_id, p_old: d.old, p_new: d.new })); return {}; },
  summary_save: async d => {
    need();
    const upd = await q(sb.from('meeting_summaries').update({ overview: d.overview || '', edited: true }).eq('id', d.id).select('id'));
    if (!upd.length) fail('수정 권한이 없어요.');
    const old = await q(sb.from('summary_insights').select('id').eq('summary_id', d.id));
    if (d.items.length) await q(sb.from('summary_insights').insert(d.items.map((i, n) => ({ summary_id: d.id, section: i.section, kind: i.kind, body: i.text, position: n }))));
    if (old.length) await q(sb.from('summary_insights').delete().in('id', old.map(o => o.id)));
    return {};
  },
  pref_save: async ({ club_id, text }) => {
    need(); const body = (text || '').trim().slice(0, 500);
    const ex = await q(sb.from('club_prefs').select('id').eq('club_id', club_id).eq('user_id', ME.id).maybeSingle());
    if (!body) { if (ex) await q(sb.from('club_prefs').delete().eq('id', ex.id)); }
    else if (ex) await q(sb.from('club_prefs').update({ body }).eq('id', ex.id));
    else await q(sb.from('club_prefs').insert({ club_id, body }));
    return {};
  },
  rec_generate: async ({ event_id }) => { await q(sb.rpc('request_recommendations', { p_event: event_id })); return {}; },
  rec_vote: async ({ id }) => {
    need();
    const ex = await q(sb.from('ai_rec_votes').select('id').eq('rec_id', id).eq('user_id', ME.id).maybeSingle());
    if (ex) await q(sb.from('ai_rec_votes').delete().eq('id', ex.id)); else await q(sb.from('ai_rec_votes').insert({ rec_id: id }));
    return {};
  },

  /* ---------- 개인 AI 독서 토론 (나만 보임) ---------- */
  conv_list: async () => ({ convs: (await q(sb.from('ai_conversations').select('id,title,updated_at').order('updated_at', { ascending: false }).limit(50))).map(c => ({ ...c, updated_at: kst(c.updated_at) })) }),
  conv_new: async d => {
    need(); let book = d.book_id || null;
    if (d.journal_id) { const j = await q(sb.from('reading_logs').select('book_id').eq('id', d.journal_id).maybeSingle()); if (!j) fail('일지를 찾을 수 없어요.'); book = j.book_id; }
    return { id: await q(sb.rpc('create_conversation', { p_book: book, p_event: d.event_id || null })) };
  },
  conv_get: async ({ id }) => {
    need();
    const c = await q(sb.from('ai_conversations').select('id,title,book_id,event_id').eq('id', id).maybeSingle());
    if (!c) fail('대화를 찾을 수 없어요.');
    const messages = await q(sb.from('ai_messages').select('id,role,content').eq('conversation_id', id).order('created_at'));
    return { conv: c, messages };
  },
  conv_send: async ({ id, text }) => {
    need(); await q(sb.rpc('send_chat_message', { p_conversation: id, p_text: text }));
    for (let i = 0; i < 80; i++) {          // AI 서버가 답할 때까지 최대 ~2분 기다림
      await sleep(1500);
      const j = one(await q(sb.from('ai_jobs').select('status,error').eq('kind', 'chat').eq('ref_id', id).order('created_at', { ascending: false }).limit(1)));
      if (j && j.status === 'done') return {};
      if (j && j.status === 'failed') fail(j.error || 'AI 응답에 실패했어요. 잠시 뒤 다시 시도해 주세요.');
    }
    fail('AI 서버가 아직 응답하지 않아요. 잠시 뒤 이 대화를 다시 열어 확인해 주세요.');
  },
  conv_save: async ({ message_id }) => { await q(sb.rpc('save_chat_excerpt', { p_message: message_id })); return {}; },
  conv_delete: async ({ id }) => { await q(sb.from('ai_conversations').delete().eq('id', id)); return {}; },
};

async function api(n, d = {}) {
  try { return await H[n](d || {}); }
  catch (e) {
    const m = e instanceof ApiErr ? e.message : msg(e);
    if (n !== 'me') toast(m);
    throw e instanceof ApiErr ? e : new ApiErr(m);
  }
}

/* 녹음 업로드: Storage에 올리고 → 녹음 기록을 만들면 AI 처리 작업이 자동으로 대기열에 들어가요 */
async function uploadRecording(blob, type, dur, eventId, clubId) {
  need();
  if (blob.size > MAX_UPLOAD_MB * 1024 * 1024) fail(`파일이 ${MAX_UPLOAD_MB}MB를 넘어요. 더 짧게 나눠서 올려 주세요.`);
  const base = (type || 'audio/webm').split(';')[0];
  const ext = { 'audio/webm': 'webm', 'audio/mp4': 'm4a', 'audio/x-m4a': 'm4a', 'audio/mpeg': 'mp3', 'audio/ogg': 'ogg', 'audio/wav': 'wav', 'audio/x-wav': 'wav', 'audio/aac': 'aac' }[base] || 'bin';
  const path = `${clubId}/${eventId}/${crypto.randomUUID()}.${ext}`;
  const up = await sb.storage.from(BUCKET).upload(path, blob, { contentType: base, upsert: false });
  if (up.error) { console.error(up.error); fail(/exceed|too large|size/i.test(up.error.message || '') ? `파일이 너무 커요(최대 ${MAX_UPLOAD_MB}MB).` : '업로드에 실패했어요. 네트워크를 확인하고 다시 시도해 주세요.'); }
  const { error } = await sb.from('meeting_recordings').insert({ event_id: eventId, storage_path: path, mime: base, size_bytes: blob.size, duration_sec: dur || null, consent_confirmed: true });
  if (error) { await sb.storage.from(BUCKET).remove([path]); fail(msg(error)); }
}

sb.auth.onAuthStateChange(ev => { if (ev === 'SIGNED_OUT' && typeof S !== 'undefined' && S.me) { ME = null; S.me = null; render(); } });
