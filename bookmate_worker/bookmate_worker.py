"""BOOKMATE AI 처리 서버 (Supabase 연동 버전)

하는 일: Supabase의 ai_jobs 대기열을 계속 확인하다가 작업이 보이면 처리해요.
  recording  : 녹음 파일 받기 → 음성 인식(Google STT) → 요약(Claude) 저장
  summary    : 이미 있는 대화 기록으로 요약만 다시 만들기
  recommend  : 모임 요약을 바탕으로 다음 책 추천
  chat       : 개인 AI 독서 토론 답변
이 프로그램은 '밖으로 나가는 요청'만 해요. 그래서 공개 주소나 터널이 필요 없고, 내 PC에서 켜 둬도 돼요.
꺼져 있는 동안 쌓인 작업은 다시 켜면 이어서 처리돼요. (자료는 Supabase에 계속 보존돼요)
SUPABASE_SECRET_KEY는 모든 권한을 가진 열쇠예요. .env 파일에만 넣고 절대 공유하지 마세요.
"""
import os, sys, json, time, threading, shutil, tempfile, subprocess, urllib.request, urllib.error, urllib.parse
from datetime import datetime, timezone, timedelta
from concurrent.futures import ThreadPoolExecutor
import ai_core as A
from ai_core import E, AiFail

URL = E("SUPABASE_URL").rstrip("/")
KEY = E("SUPABASE_SECRET_KEY") or E("SUPABASE_SERVICE_ROLE_KEY")
BUCKET = "recordings"
POLL = int(E("POLL_SECONDS", "5"))


class RestErr(Exception):
    pass


def rest(method, path, body=None, prefer=None, raw=False, timeout=60):
    h = {"apikey": KEY, "Content-Type": "application/json"}
    if KEY.startswith("eyJ"):  # 예전 방식(JWT) service_role 키
        h["Authorization"] = "Bearer " + KEY
    if prefer:
        h["Prefer"] = prefer
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data, h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            b = r.read()
    except urllib.error.HTTPError as e:
        raise RestErr(f"{method} {path.split('?')[0]} -> HTTP {e.code}")  # 응답 본문(개인정보 가능)은 기록하지 않음
    except Exception as e:
        raise RestErr(f"{method} {path.split('?')[0]} -> {type(e).__name__}")
    if raw:
        return b
    return json.loads(b) if b else None


def get(table, query):
    return rest("GET", f"/rest/v1/{table}?{query}")


def get_all(table, query, page=1000):
    out, off = [], 0
    while True:
        r = rest("GET", f"/rest/v1/{table}?{query}&limit={page}&offset={off}")
        out += r
        if len(r) < page:
            return out
        off += page


def post(table, rows, ret=False):
    return rest("POST", f"/rest/v1/{table}", rows, "return=representation" if ret else "return=minimal")


def patch(table, query, vals, ret=False):
    return rest("PATCH", f"/rest/v1/{table}?{query}", vals, "return=representation" if ret else "return=minimal")


def delete(table, query):
    return rest("DELETE", f"/rest/v1/{table}?{query}", prefer="return=minimal")


Q = urllib.parse.quote
now = lambda: datetime.now(timezone.utc).isoformat()


# ---------- 사용량 제한 ----------
def used(uid, kind, since):
    rows = get("ai_usage", f"select=units&kind=eq.{kind}&created_at=gte.{Q(since)}" + (f"&user_id=eq.{uid}" if uid else ""))
    return sum(r["units"] for r in rows)


def add_usage(uid, kind, units=1):
    post("ai_usage", {"user_id": uid, "kind": kind, "units": units})


def day_start():
    return datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0).isoformat()


def month_start():
    return datetime.now(timezone.utc).replace(day=1, hour=0, minute=0, second=0, microsecond=0).isoformat()


def limit_check(uid, kind, cap):
    if used(uid, kind, day_start()) >= cap:
        raise AiFail("오늘 사용할 수 있는 AI 횟수를 모두 썼어요. 내일 다시 이용해 주세요.")


# ---------- 녹음 처리 ----------
def set_rec(rid, status, error=None):
    patch("meeting_recordings", f"id=eq.{rid}", {"status": status, "error": error})


def probe_minutes(path):
    if not shutil.which("ffprobe"):
        return 0
    try:
        o = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path], capture_output=True, timeout=60, text=True).stdout
        return float(o.strip()) / 60
    except Exception:
        return 0


def download(path, dest):
    b = rest("GET", f"/storage/v1/object/{BUCKET}/{Q(path, safe='/')}", raw=True, timeout=600)
    with open(dest, "wb") as f:
        f.write(b)


def transcript_text(tid):
    rows = get_all("transcript_segments", f"select=speaker,body&transcript_id=eq.{tid}&order=idx")
    return "\n".join(f"[{('화자 ' + r['speaker']) if (r['speaker'] or '').isdigit() else (r['speaker'] or '화자 미상')}] {r['body']}" for r in rows)


def do_transcribe(r, uid):
    if not A.google_ready():
        raise AiFail("음성 인식 설정이 필요해요. 처리 서버 .env의 GCP_PROJECT, GCS_BUCKET, GOOGLE_APPLICATION_CREDENTIALS를 확인해 주세요.")
    if r["audio_deleted"] or not r["storage_path"]:
        raise AiFail("원본 오디오가 삭제되어 음성 인식을 다시 할 수 없어요.")
    work = tempfile.mkdtemp(prefix="bmw_")
    try:
        src = os.path.join(work, "in" + os.path.splitext(r["storage_path"])[1])
        download(r["storage_path"], src)
        mins = (r["duration_sec"] or 0) / 60 or probe_minutes(src)
        if used(None, "stt", month_start()) + mins > int(E("STT_MONTHLY_MIN_LIMIT", "600")):
            raise AiFail("이번 달 음성 인식 사용 한도에 도달했어요. 한도는 처리 서버 .env의 STT_MONTHLY_MIN_LIMIT로 조정할 수 있어요.")
        parts, tmp = A.prepare({"file_path": src, "duration_sec": mins * 60})
        try:
            segs = []
            for p, off in parts:
                segs += A.stt(p, off)
        finally:
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if not segs:
        raise AiFail("대화를 인식하지 못했어요. 녹음 상태를 확인해 주세요.")
    t = post("meeting_transcripts", {"recording_id": r["id"]}, ret=True)[0]
    for i in range(0, len(segs), 500):
        post("transcript_segments", [{"transcript_id": t["id"], "idx": i + j, "speaker": s["speaker"], "body": s["text"], "start_ms": s["start"], "end_ms": s["end"]} for j, s in enumerate(segs[i:i + 500])])
    add_usage(uid, "stt", mins)
    return t["id"]


def do_summarize(r, tid, title, uid):
    text = transcript_text(tid)
    if not text.strip():
        raise AiFail("인식된 대화가 없어요. 녹음 상태와 마이크 위치를 확인해 주세요.")
    out, u = A.call_claude(A.SUMMARY_SYSTEM, [{"role": "user", "content": f"모임 제목: {title}\n\n[대화 기록]\n{text[:400000]}"}], 6000)
    j = A.parse_json(out)
    if not isinstance(j, dict):
        raise AiFail("AI 응답 형식이 올바르지 않았어요. 다시 시도해 주세요.")
    full, dropped, rows = A.norm(text), 0, []
    for sec in A.SECTIONS:
        for it in (j.get(sec) or []):
            if not isinstance(it, dict):
                continue
            if sec == "quotes":
                q = str(it.get("quote", "")).strip()
                if not q or A.norm(q) not in full:
                    dropped += 1  # 원문에서 확인되지 않는 인용은 버림(지어낸 발언 방지)
                    continue
                rows.append((sec, "statement", f"{it.get('speaker', '')}: {q}".strip(": ")))
            else:
                tx = str(it.get("text", "")).strip()
                if tx:
                    rows.append((sec, "statement" if it.get("basis") == "statement" else "interpretation", tx[:2000]))
    delete("meeting_summaries", f"recording_id=eq.{r['id']}")
    s = post("meeting_summaries", {"event_id": r["event_id"], "recording_id": r["id"], "overview": str(j.get("overview", "")).strip(), "model": E("ANTHROPIC_MODEL", "claude-sonnet-5-5"), "dropped_quotes": dropped}, ret=True)[0]
    if rows:
        post("summary_insights", [{"summary_id": s["id"], "section": a, "kind": k, "body": t, "position": i} for i, (a, k, t) in enumerate(rows)])
    add_usage(uid, "summary", u.get("input_tokens", 0) + u.get("output_tokens", 0))


def job_recording(job, stage):
    rid = job["ref_id"]
    r = (get("meeting_recordings", f"select=*&id=eq.{rid}") or [None])[0]
    if not r:
        return
    ev = (get("events", f"select=title&id=eq.{r['event_id']}") or [{}])[0]
    uid = job["requested_by"]
    try:
        t = (get("meeting_transcripts", f"select=id&recording_id=eq.{rid}") or [None])[0]
        if stage == "recording" and not t:
            set_rec(rid, "transcribing")
            tid = do_transcribe(r, uid)
            set_rec(rid, "transcribed")
        elif t:
            tid = t["id"]
        else:
            raise AiFail("대화 기록이 있어야 요약을 다시 만들 수 있어요.")
        set_rec(rid, "summarizing")
        do_summarize(r, tid, ev.get("title", ""), uid)
        set_rec(rid, "completed")
    except AiFail as e:
        set_rec(rid, "failed", str(e))
        raise
    except Exception as e:
        print("처리 오류:", type(e).__name__)
        set_rec(rid, "failed", "처리 중 오류가 발생했어요. 잠시 뒤 다시 시도해 주세요.")
        raise AiFail("처리 중 오류가 발생했어요. 잠시 뒤 다시 시도해 주세요.")


# ---------- 책 추천 ----------
def summary_text(event_id):
    s = (get("meeting_summaries", f"select=id,overview&event_id=eq.{event_id}&order=updated_at.desc&limit=1") or [None])[0]
    if not s:
        return None
    L = [f"[요약] {s['overview']}"]
    for x in get("summary_insights", f"select=section,kind,body&summary_id=eq.{s['id']}&order=position"):
        L.append(f"- ({x['section']}, {'참가자 발언' if x['kind'] == 'statement' else 'AI 해석'}) {x['body']}")
    return "\n".join(L)


def job_recommend(job):
    eid, uid = job["ref_id"], job["requested_by"]
    e = (get("events", f"select=id,club_id&id=eq.{eid}") or [None])[0]
    if not e:
        raise AiFail("일정을 찾을 수 없어요.")
    if not get("club_members", f"select=id&club_id=eq.{e['club_id']}&user_id=eq.{uid}"):
        raise AiFail("모임 멤버만 추천을 받을 수 있어요.")
    st = summary_text(eid)
    if not st:
        raise AiFail("모임 요약이 완료된 뒤에 책을 추천받을 수 있어요.")
    limit_check(uid, "rec", int(E("REC_DAILY_LIMIT", "5")))
    cid = e["club_id"]
    prefs = [r["body"] for r in get("club_prefs", f"select=body&club_id=eq.{cid}")]
    done = [f"{r['books']['title']} - {r['books']['author']}" for r in get("events", f"select=books(title,author)&club_id=eq.{cid}&book_id=not.is.null")]
    prev = [f"{r['title']} - {r['author']}" for r in get("ai_book_recommendations", f"select=title,author,events!inner(club_id)&events.club_id=eq.{cid}")]
    msg = f"[토론 요약]\n{st}\n\n[멤버가 직접 적은 독서 취향]\n{chr(10).join(prefs) or '(없음)'}\n\n[이미 다룬 책]\n{chr(10).join(done) or '(없음)'}\n\n[이미 추천한 책]\n{chr(10).join(prev) or '(없음)'}"
    out, u = A.call_claude(A.REC_SYSTEM, [{"role": "user", "content": msg}], 3000)
    arr = A.parse_json(out)
    if not isinstance(arr, list):
        raise AiFail("AI 응답 형식이 올바르지 않았어요. 다시 시도해 주세요.")
    seen, n = {p.lower() for p in prev + done}, 0
    for it in arr[:5]:
        if not isinstance(it, dict):
            continue
        t, a = str(it.get("title", "")).strip(), str(it.get("author", "")).strip()
        if not t or not a or f"{t} - {a}".lower() in seen:
            continue
        # 서재 DB에 같은 책이 있을 때만 '서지 확인됨'으로 표시. 그 외는 AI 제안(미확인)
        t_q, a_q = Q(t.replace("%", "").replace("*", "")), Q(a.replace("%", "").replace("*", ""))
        known = bool(get("books", f"select=id&title=ilike.{t_q}&author=ilike.{a_q}&limit=1"))
        qs = [str(x)[:300] for x in (it.get("questions") or [])][:3]
        post("ai_book_recommendations", {"event_id": eid, "title": t[:200], "author": a[:100], "reason": str(it.get("reason", ""))[:1000], "connection": str(it.get("connection", ""))[:1000], "discussion_questions": qs, "verified": known})
        n += 1
    add_usage(uid, "rec")
    if not n:
        raise AiFail("추천할 만한 책을 찾지 못했어요. 취향 메모를 추가하고 다시 시도해 보세요.")


# ---------- 개인 AI 토론 ----------
def chat_context(conv, uid):
    P = []
    if conv["book_id"]:
        b = (get("books", f"select=title,author,genre,pages&id=eq.{conv['book_id']}") or [None])[0]
        if b:
            P.append(f"[책 정보(공개 메타데이터)] 제목: {b['title']} / 저자: {b['author']} / 장르: {b['genre']} / {b['pages']}쪽")
            rv = (get("book_reviews", f"select=rating,body&user_id=eq.{uid}&book_id=eq.{conv['book_id']}") or [None])[0]
            if rv and rv["body"]:
                P.append(f"[사용자의 서평] 별점 {rv['rating']}/5: {rv['body']}")
            js = get("reading_logs", f"select=body,created_at&user_id=eq.{uid}&book_id=eq.{conv['book_id']}&order=created_at.desc&limit=10")
            if js:
                P.append("[사용자의 독서 일지]\n" + "\n".join(f"- {j['created_at'][:10]} {j['body']}" for j in js))
    if conv["event_id"]:
        ev = (get("events", f"select=club_id&id=eq.{conv['event_id']}") or [None])[0]
        if ev and get("club_members", f"select=id&club_id=eq.{ev['club_id']}&user_id=eq.{uid}"):  # 모임을 나갔다면 모임 자료는 쓰지 않음
            st = summary_text(conv["event_id"])
            if st:
                P.append("[모임 토론 요약 (모임 멤버에게 허용된 자료)]\n" + st)
    return "\n\n".join(P) or "(제공된 자료 없음)"


def job_chat(job):
    cid, uid = job["ref_id"], job["requested_by"]
    conv = (get("ai_conversations", f"select=id,user_id,book_id,event_id&id=eq.{cid}") or [None])[0]
    if not conv or conv["user_id"] != uid:
        raise AiFail("대화를 찾을 수 없어요.")
    msgs = get("ai_messages", f"select=role,content&conversation_id=eq.{cid}&order=created_at.desc&limit=30")[::-1]
    if not msgs or msgs[-1]["role"] != "user":
        return  # 앞선 작업이 이미 답했어요
    limit_check(uid, "chat", int(E("CHAT_DAILY_LIMIT", "40")))
    out, u = A.call_claude(A.CHAT_SYSTEM + "\n\n[제공된 자료]\n" + chat_context(conv, uid), msgs, 1200, 120)
    post("ai_messages", {"conversation_id": cid, "role": "assistant", "content": out.strip()[:8000]})
    patch("ai_conversations", f"id=eq.{cid}", {"updated_at": now()})
    add_usage(uid, "chat")


# ---------- 작업 루프 ----------
def run(job):
    k = job["kind"]
    if k in ("recording", "summary"):
        job_recording(job, k)
    elif k == "recommend":
        job_recommend(job)
    elif k == "chat":
        job_chat(job)


def finish_job(j):
    try:
        run(j)
        patch("ai_jobs", f"id=eq.{j['id']}", {"status": "done", "finished_at": now()})
    except AiFail as e:
        patch("ai_jobs", f"id=eq.{j['id']}", {"status": "failed", "error": str(e)[:500], "finished_at": now()})
    except Exception as e:
        print("작업 오류:", j["kind"], type(e).__name__, str(e)[:120])
        try:
            patch("ai_jobs", f"id=eq.{j['id']}", {"status": "failed", "error": "처리 중 오류가 발생했어요. 잠시 뒤 다시 시도해 주세요.", "finished_at": now()})
        except Exception:
            pass


# 녹음·요약은 오래 걸릴 수 있어서(절약 모드의 음성 인식은 최대 수 시간) 별도 스레드에서 처리하고,
# 그동안에도 AI 토론·책 추천 같은 짧은 작업은 바로바로 처리해요.
SLOTS = int(E("PARALLEL_RECORDINGS", "2"))
REC_SLOTS = threading.BoundedSemaphore(SLOTS)
EXEC = ThreadPoolExecutor(max_workers=SLOTS)
HEAVY = ("recording", "summary")


def drain():  # 진행 중인 긴 작업이 모두 끝날 때까지 기다림 (테스트용)
    for _ in range(SLOTS):
        REC_SLOTS.acquire()
    for _ in range(SLOTS):
        REC_SLOTS.release()


def step():
    have = REC_SLOTS.acquire(blocking=False)
    j = get("ai_jobs", "select=*&status=eq.queued&order=created_at&limit=1" + ("" if have else "&kind=not.in.(recording,summary)"))
    if not j:
        if have:
            REC_SLOTS.release()
        return False
    j = j[0]
    got = patch("ai_jobs", f"id=eq.{j['id']}&status=eq.queued", {"status": "running"}, ret=True)  # 선점
    if not got:
        if have:
            REC_SLOTS.release()
        return True
    if have and j["kind"] in HEAVY:
        def task():
            try:
                finish_job(j)
            finally:
                REC_SLOTS.release()
        EXEC.submit(task)
    else:
        if have:
            REC_SLOTS.release()
        finish_job(j)
    return True


def cleanup():
    days = int(E("RETENTION_DAYS", "0") or 0)
    if days <= 0:
        return
    cut = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    for r in get("meeting_recordings", f"select=id,storage_path&audio_deleted=eq.false&storage_path=not.is.null&created_at=lt.{Q(cut)}&limit=100"):
        try:
            rest("DELETE", f"/storage/v1/object/{BUCKET}/{Q(r['storage_path'], safe='/')}")
        except RestErr as e:
            if "404" not in str(e):
                continue
        patch("meeting_recordings", f"id=eq.{r['id']}", {"audio_deleted": True, "storage_path": None})


def main():
    if not URL or not KEY:
        sys.exit("SUPABASE_URL 과 SUPABASE_SECRET_KEY 를 .env 에 넣어 주세요. (.env.example 참고)")
    print(f"BOOKMATE 처리 서버 시작 | Claude 키: {'있음' if A.claude_ready() else '없음'} | Google STT: {'준비됨' if A.google_ready() else '미설정'} | ffmpeg: {'있음' if shutil.which('ffmpeg') else '없음'} | 오디오 보관: {E('RETENTION_DAYS', '0')}일(0=삭제 안 함)")
    try:
        patch("ai_jobs", "status=eq.running", {"status": "queued"})  # 비정상 종료로 멈춘 작업을 다시 대기열로
    except RestErr as e:
        sys.exit(f"Supabase에 연결하지 못했어요: {e}\nURL과 SECRET KEY를 확인해 주세요.")
    last_clean, fails = 0, 0
    while True:
        try:
            busy = step()
            fails = 0
            if time.time() - last_clean > 3600:
                cleanup()
                last_clean = time.time()
        except RestErr as e:
            fails += 1
            print("연결 오류:", e)
            time.sleep(min(60, 5 * fails))
            continue
        except KeyboardInterrupt:
            print("종료합니다.")
            return
        if not busy:
            time.sleep(POLL)


if __name__ == "__main__":
    main()
