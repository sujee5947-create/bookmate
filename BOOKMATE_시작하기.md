# BOOKMATE (Supabase 버전) 시작하기

구성은 세 조각이에요.

| 조각 | 위치 | 역할 |
|---|---|---|
| 데이터 저장소 | Supabase | 계정, 서재, 모임, 일정, 토론, 녹음 파일, 요약. **영구 보존** |
| 앱 화면 | `bookmate_web/` 폴더 → 무료 호스팅에 올림 | 친구들이 휴대폰에서 여는 주소 (HTTPS) |
| AI 처리 서버 | `bookmate_worker/` 폴더 → 내 PC에서 실행 | 녹음 → 대화 기록 → 요약, 책 추천, AI 토론 |

AI 처리 서버가 꺼져 있어도 서재·모임·일정·토론·녹음 업로드는 모두 돼요. 서버를 켜면 밀린 AI 작업을 이어서 처리해요.

## 1. Supabase 준비
Supabase에서 프로젝트를 만들고, SQL Editor에 `supabase_schema.sql` 파일 전체를 붙여 넣어 Run 하세요. 여러 번 실행해도 안전해요. 기존 데이터는 지워지지 않아요.
Authentication 설정에서 Confirm email은 꺼 주세요(닉네임 + 비밀번호로 로그인해요).

## 2. 앱 화면 올리기
먼저 `bookmate_web/api.js` 맨 위의 `SB_URL`, `SB_KEY`를 내 Supabase 프로젝트 값으로 바꿔요. (publishable key는 공개용 값이에요. 데이터 보호는 DB의 RLS 규칙이 담당해요.)

- **Vercel (지금 쓰는 방식)**: `bookmate_web` 폴더에서 `npx vercel --prod` 를 실행하면 HTTPS 주소가 생겨요.
- 그 밖에 Netlify Drop, Cloudflare Pages처럼 폴더를 그대로 올리는 무료 호스팅도 쓸 수 있어요. 빌드 과정이 없는 정적 파일이에요.

그 주소를 모임 친구들에게 보내면 돼요. 휴대폰 브라우저에서 "홈 화면에 추가"를 하면 앱처럼 쓸 수 있어요. HTTPS라서 마이크 녹음도 돼요.
친구들 가입이 끝나면 Supabase 대시보드 Authentication 설정에서 **Allow new users to sign up**을 꺼 두세요.

## 3. AI 처리 서버 켜기
1. Python 3.10+ 과 ffmpeg 를 설치해요.
2. `bookmate_worker` 폴더에서: `pip install -r requirements.txt`
3. `.env.example` 을 `.env` 로 복사해서 채워요: SUPABASE_SECRET_KEY, ANTHROPIC_API_KEY, GCP_PROJECT, GCS_BUCKET, 구글 서비스 계정 키 파일(`google-key.json`).
4. `python bookmate_worker.py` (Windows는 `run_worker.bat` 더블클릭)
5. 첫 줄에 `Claude 키: 있음 | Google STT: 준비됨` 이 보이면 정상이에요.

이 서버는 **밖으로 나가는 요청만** 해서, 공유기 설정이나 터널이 필요 없어요.

## 알아둘 점
- **로그인**: 닉네임 + 비밀번호. 비밀번호를 잊으면 복구 방법이 없어요(이메일을 쓰지 않아서). 필요하면 Supabase 대시보드 Authentication → Users 에서 지울 수 있어요.
- **녹음 한도**: Supabase 무료 플랜은 파일 1개당 50MB예요. 앱 녹음은 음성용 저용량(약 0.25MB/분)이라 2시간쯤까지 괜찮아요. 업로드 파일이 크면 압축해서 올려 주세요.
- **저장 용량**: 무료 플랜은 DB 500MB, 파일 1GB예요. 원본 오디오는 `RETENTION_DAYS` 뒤에 지워지고 대화 기록과 요약은 남아요.
- **7일 일시정지**: 무료 프로젝트는 7일 동안 접속이 전혀 없으면 일시정지돼요. 대시보드에서 다시 켜면 자료는 그대로예요.
- **AI 비용 한도**: `.env`의 `STT_MONTHLY_MIN_LIMIT`(음성 인식, 모임 전체 월 합계 분), `CHAT_DAILY_LIMIT`(AI 토론, 한 사람 하루), `REC_DAILY_LIMIT`(책 추천, 한 사람 하루)로 조절해요. 기본값은 100 / 10 / 5예요.
- **음성 인식 절약 모드**: 기본값(`STT_MODE=batch`)은 가격이 약 80% 저렴한 대신 결과가 몇 분~최대 24시간 걸릴 수 있어요. 바로 결과가 필요하면 `STT_MODE=fast`로 바꾸세요.
