"""BOOKMATE AI 핵심부: Claude 호출, Google STT, 오디오 분할, 프롬프트. (DB와 무관한 부분만 모았어요)
모든 키는 .env(환경변수)에서만 읽고, 키 값은 로그에 출력하지 않아요."""
import os, json, time, threading, queue, subprocess, shutil, uuid, re, glob, tempfile, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))


def load_env(path=None):
    path = path or os.path.join(HERE, ".env")
    # .env가 없어도(호스팅 환경변수만 쓰는 경우) 아래 서비스 계정 처리는 계속 진행
    for line in (open(path, encoding="utf-8") if os.path.exists(path) else []):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        if v:  # 비어 있는 값(예: SIGNUP_CODE=)은 무시해서 호스팅 환경변수를 덮어쓰지 않음
            os.environ.setdefault(k, v)
    gj = os.environ.get("GOOGLE_CREDENTIALS_JSON")
    if gj and not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
        try:
            json.loads(gj)  # 호스팅 환경: 키 파일 대신 환경변수에 JSON 내용을 넣을 수 있음
            kp = os.path.join(tempfile.gettempdir(), "bm_gcp_key.json")
            fd = os.open(kp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(gj)
            os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = kp
        except ValueError:
            print("GOOGLE_CREDENTIALS_JSON 형식이 올바른 JSON이 아니에요.")
    g = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if g and not os.path.isabs(g):
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = os.path.join(HERE, g)


load_env()
E = lambda k, d="": os.environ.get(k, d)
nid = lambda: str(uuid.uuid4())
SEG = int(E("SEGMENT_SECONDS", "3000"))  # Chirp 3 BatchRecognize는 1시간 이하 권장
STATUSES = "'uploaded','transcribing','transcribed','summarizing','completed','failed'"
SECTIONS = ["topics", "opinions", "differences", "quotes", "questions", "conclusions", "next_topics"]


class AiFail(Exception):
    """사용자에게 그대로 보여줘도 되는 처리 실패 사유."""


# ---------- 준비 상태 ----------
def google_ready():
    try:
        import google.cloud.speech_v2, google.cloud.storage  # noqa
    except Exception:
        return False
    cred = E("GOOGLE_APPLICATION_CREDENTIALS")
    return bool(E("GCS_BUCKET") and E("GCP_PROJECT") and cred and os.path.exists(cred))


def claude_ready():
    return bool(E("ANTHROPIC_API_KEY"))


def status_info():
    return {"claude": claude_ready(), "google": google_ready(), "ffmpeg": bool(shutil.which("ffmpeg")),
            "retention_days": int(E("RETENTION_DAYS", "0") or 0), "chat_daily_limit": int(E("CHAT_DAILY_LIMIT", "40")),
            "stt_monthly_min": int(E("STT_MONTHLY_MIN_LIMIT", "600"))}


# ---------- Claude 호출 (표준 라이브러리만 사용) ----------
def call_claude(system, messages, max_tokens=4000, timeout=240):
    key = E("ANTHROPIC_API_KEY")
    if not key:
        raise AiFail("ANTHROPIC_API_KEY가 설정되지 않았어요. .env 파일을 확인해 주세요.")
    body = json.dumps({"model": E("ANTHROPIC_MODEL", "claude-sonnet-5-5"), "max_tokens": max_tokens, "system": system, "messages": messages}).encode()
    last = None
    for i in range(3):
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", body, {"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                j = json.loads(r.read())
            return "".join(b.get("text", "") for b in j.get("content", []) if b.get("type") == "text"), j.get("usage", {})
        except urllib.error.HTTPError as e:
            last = e.code
            if e.code in (401, 403):
                raise AiFail("Anthropic API 키가 올바르지 않거나 권한이 없어요. .env를 확인해 주세요.")
            if e.code not in (429, 500, 502, 503, 529):
                raise AiFail(f"AI 서비스 요청이 거부됐어요 (코드 {e.code}).")
        except Exception:
            last = "network"
        time.sleep(2 * (i + 1))
    raise AiFail(f"AI 서비스에 연결하지 못했어요 ({last}). 잠시 뒤 다시 시도해 주세요.")


def parse_json(t):
    m = re.search(r"\{.*\}|\[.*\]", t.strip(), re.S)
    if not m:
        raise AiFail("AI 응답을 해석하지 못했어요. 다시 시도해 주세요.")
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        raise AiFail("AI 응답 형식이 올바르지 않았어요. 다시 시도해 주세요.")



# ---------- 음성 인식 ----------
def prepare(r):
    src, ff = r["file_path"], shutil.which("ffmpeg")
    if not ff:
        if (r["duration_sec"] or 0) > SEG + 300:
            raise AiFail("1시간이 넘는 녹음은 서버에 ffmpeg가 있어야 나눠서 처리할 수 있어요. ffmpeg를 설치하거나 1시간 이하로 나눠 올려 주세요.")
        return [(src, 0)], None
    tmp = tempfile.mkdtemp(prefix="bm_")
    try:
        subprocess.run([ff, "-y", "-i", src, "-vn", "-ac", "1", "-ar", "16000", "-f", "segment", "-segment_time", str(SEG), "-c:a", "flac", os.path.join(tmp, "s_%03d.flac")], capture_output=True, timeout=3600, check=True)
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise AiFail("오디오 파일을 읽을 수 없어요. 파일 형식을 확인해 주세요.")
    fs = sorted(glob.glob(os.path.join(tmp, "s_*.flac")))
    if not fs:
        shutil.rmtree(tmp, ignore_errors=True)
        raise AiFail("오디오에서 소리를 찾지 못했어요.")
    return [(f, i * SEG * 1000) for i, f in enumerate(fs)], tmp


def stt(path, offset_ms):
    from google.api_core.client_options import ClientOptions
    from google.cloud import storage
    from google.cloud.speech_v2 import SpeechClient
    from google.cloud.speech_v2.types import cloud_speech as cs
    proj, region, bucket = E("GCP_PROJECT"), E("GCP_REGION", "asia-northeast1"), E("GCS_BUCKET")
    blob = storage.Client().bucket(bucket).blob(f"bookmate-tmp/{uuid.uuid4()}{os.path.splitext(path)[1]}")
    blob.upload_from_filename(path)
    uri = f"gs://{bucket}/{blob.name}"
    try:
        client = SpeechClient(client_options=ClientOptions(api_endpoint=f"{region}-speech.googleapis.com"))
        cfg = cs.RecognitionConfig(auto_decoding_config=cs.AutoDetectDecodingConfig(), language_codes=["ko-KR"], model="chirp_3",
                                   features=cs.RecognitionFeatures(diarization_config=cs.SpeakerDiarizationConfig(), enable_automatic_punctuation=True))
        kw = {}
        if E("STT_MODE", "batch").lower() != "fast":
            # 절약 모드: 가격이 약 80% 낮은 대신 결과가 몇 분~최대 24시간 걸릴 수 있어요. (STT_MODE=fast 이면 일반 방식)
            kw["processing_strategy"] = cs.BatchRecognizeRequest.ProcessingStrategy.DYNAMIC_BATCHING
        req = cs.BatchRecognizeRequest(recognizer=f"projects/{proj}/locations/{region}/recognizers/_", config=cfg,
                                       files=[cs.BatchRecognizeFileMetadata(uri=uri)],
                                       recognition_output_config=cs.RecognitionOutputConfig(inline_response_config=cs.InlineOutputConfig()), **kw)
        res = client.batch_recognize(request=req).result(timeout=26 * 3600)
    finally:
        try:
            blob.delete()  # 임시 업로드 파일은 즉시 삭제
        except Exception:
            pass
    fr = res.results[uri]
    if fr.error and fr.error.code:
        raise AiFail("음성 인식 서비스가 오류를 돌려줬어요. 잠시 뒤 다시 시도해 주세요.")
    out, prev = [], offset_ms
    for r in fr.transcript.results:
        alt = r.alternatives[0] if r.alternatives else None
        if not alt or not alt.transcript.strip():
            continue
        try:
            end = offset_ms + int(r.result_end_offset.total_seconds() * 1000)
        except Exception:
            end = prev
        words = [w for w in alt.words if getattr(w, "speaker_label", "")]
        if words and len({w.speaker_label for w in words}) > 1:
            grp = []
            for w in words:
                if grp and grp[-1][0] == w.speaker_label:
                    grp[-1][1].append(w.word)
                else:
                    grp.append([w.speaker_label, [w.word]])
            out += [{"speaker": sp, "text": " ".join(ws), "start": prev, "end": end} for sp, ws in grp]
        else:
            out.append({"speaker": words[0].speaker_label if words else "", "text": alt.transcript.strip(), "start": prev, "end": end})
        prev = end
    return out



# ---------- 요약 ----------
SUMMARY_SYSTEM = """당신은 독서 모임 토론 기록을 정리하는 서기입니다. 반드시 제공된 대화 기록에 있는 내용만 사용하세요.
규칙:
- 대화에 없는 발언, 의견, 사실을 만들지 마세요. 확실하지 않으면 해당 항목을 비우세요.
- 참가자가 실제로 말한 내용을 정리한 항목은 basis를 "statement", 당신의 해석·추론·종합은 basis를 "interpretation"으로 표시하세요.
- "quotes"의 quote는 대화 기록의 문장을 한 글자도 바꾸지 말고 그대로 옮기세요. speaker는 기록에 적힌 화자 라벨입니다.
- 화자 구분은 부정확할 수 있으니 화자를 단정하지 말고 라벨 그대로만 쓰세요.
- 한국어로 간결하게 쓰세요.
출력은 아래 JSON 하나만 출력하세요(설명·코드블록 금지):
{"overview":"전체 토론 요약 3~6문장","topics":[{"text":"","basis":""}],"opinions":[{"text":"","basis":""}],"differences":[{"text":"","basis":""}],
"quotes":[{"speaker":"","quote":"","basis":"statement"}],"questions":[{"text":"","basis":""}],"conclusions":[{"text":"","basis":""}],"next_topics":[{"text":"","basis":""}]}
각 배열은 해당하는 내용이 없으면 빈 배열로 두세요."""

norm = lambda s: re.sub(r"[^\w가-힣]", "", s or "")


REC_SYSTEM = """당신은 독서 모임의 다음 책을 제안하는 사서입니다. 제공된 토론 요약, 멤버들이 직접 적은 독서 취향, 이미 다룬 책과 이미 추천한 책을 바탕으로 최대 5권을 추천하세요.
규칙:
- 실제로 존재한다고 확신하는 책만 추천하세요. 제목과 저자가 정확하지 않거나 확신이 없으면 그 책은 빼고 더 적게 추천하세요.
- 출판사, 쪽수, ISBN, 표지 같은 서지정보는 쓰지 마세요. 제목과 저자만 쓰세요.
- 추천은 다음 중 하나 이상에 해당해야 합니다: 지난 토론을 이어감(continue), 대조되는 관점(contrast), 새로운 관점(new), 모임의 관심사(interest).
- connection에는 지난 토론의 어떤 내용과 이어지는지 요약에 근거해 쓰세요. 요약에 없는 내용을 지어내지 마세요.
- 이미 다룬 책, 이미 추천한 책은 제외하세요.
출력은 JSON 배열 하나만(설명·코드블록 금지): [{"title":"","author":"","angle":"continue|contrast|new|interest","reason":"","connection":"","questions":["토론 질문 2~3개"]}]"""


CHAT_SYSTEM = """당신은 사용자의 독서를 돕는 사려 깊은 토론 파트너입니다. 한국어로 대화하세요.
원칙:
- 정답을 바로 알려주기보다 열린 질문으로 사용자의 해석을 끌어내세요. 한 번에 질문은 1~2개만 하세요.
- 사용자의 해석에 무조건 동의하지 말고, 다른 관점을 제시하고, 전제나 논리의 빈틈을 정중하게 짚으세요.
- 사용자가 스스로 해석을 발전시키도록 도우세요.
지식과 근거의 구분 (가장 중요):
- 아래 [제공된 자료]에 있는 사용자의 메모·서평·일지·모임 요약은 확실한 근거입니다. 이것을 우선해서 활용하세요.
- 널리 알려진 책이라면 당신이 학습으로 알고 있는 줄거리, 주제, 등장인물, 작가와 시대적 배경, 비평에서 자주 논의되는 쟁점은 대화에 사용해도 됩니다. 단, 그런 내용은 "제가 알고 있는 일반적인 내용으로는" 처럼 일반 지식임을 밝히고, 틀릴 수 있으니 사용자의 읽은 경험이 우선이라고 분명히 하세요.
- 확신이 없거나 잘 알려지지 않은 책이면 모른다고 솔직히 말하고, 사용자가 들려주는 내용에서 출발하세요. 구체적인 장면, 쪽수, 대사, 등장인물 이름을 짐작으로 지어내지 마세요.
- 책의 본문 문장을 그대로 길게 인용하거나 재현하지 마세요. 필요하면 짧게 요약하거나 말바꿈하세요.
- 최신 정보(출간 정보, 수상, 새 서평 등)는 검색할 수 없으니 알지 못한다고 말하세요.
- 모임 토론 요약이 제공된 경우에만 지난 모임 논점과 연결하세요.
- 답변은 간결하게, 모바일 화면에서 읽기 좋게 쓰세요."""
