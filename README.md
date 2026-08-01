# n8n + video-edit + tts — একটাই কন্টেইনার, একটাই Render deploy

আগে ৩টা আলাদা Render web service লাগত (n8n, video-edit, tts) — মানে
Render-এর Monthly Included Usage থেকে ৩টা instance-hour একসাথে কাটত।
এখন সবকিছু **একটাই Docker কন্টেইনারে** ঢুকিয়ে দেয়া হয়েছে — Render
Dashboard-এ ১টা মাত্র web service দেখবেন, ১টাই 512MB RAM / 0.1 CPU
বরাদ্দ পাবে, আর usage-ও ১টা সার্ভিসের মতোই কাটবে।

```
.
├── Dockerfile        <- একটাই ইমেজ: n8n + ffmpeg + python + video-edit + tts
├── start.sh           <- কন্টেইনার শুরু হলে ৩টা প্রসেস চালু করে
├── render.yaml         <- Render Blueprint (১টা মাত্র সার্ভিস)
├── video-edit/         <- ffmpeg render helper, শুধু 127.0.0.1:3001-এ চলে
├── tts/                <- edge-tts REST API, ঐচ্ছিক, ডিফল্ট বন্ধ
└── workflow/
    └── My_workflow_4.json
```

## এটা কীভাবে কাজ করে

কন্টেইনার চালু হলে `start.sh`:
1. `video-edit` (Node/Express/ffmpeg) ব্যাকগ্রাউন্ডে চালায়, শুধু
   `127.0.0.1:3001`-এ শোনে — বাইরের ইন্টারনেট থেকে এটা কখনো
   পৌঁছানো যায় না, Render শুধু n8n-এর পোর্টটাই বাইরে খুলে দেয়।
2. যদি `ENABLE_TTS_SERVICE=true` সেট করা থাকে, `tts` সার্ভিসও একইভাবে
   `127.0.0.1:3002`-এ চালায়। **ডিফল্ট বন্ধ থাকে**, কারণ আপনার
   workflow-টা চেক করে দেখেছি এটা ব্যবহার করে না — TTS নোড
   (`TTS (Eleven->Edge->Silent)`) আসলে n8n কন্টেইনারের ভেতরের
   `edge-tts` CLI দিয়েই কাজ চালায় (ElevenLabs ফেইল করলে ফলব্যাক
   হিসেবে)। ভবিষ্যতে অন্য কোনো automation থেকে HTTP দিয়ে TTS দরকার
   হলে এই ভ্যারিয়েবল `true` করে দিলেই চালু হয়ে যাবে।
3. সবশেষে n8n foreground-এ চালু হয় এবং Render-এর `$PORT`/৫৬৭৮ ধরে।

n8n-এর workflow-র মধ্যে `RENDER_VIDEO_EDIT_URL` এখন
`http://127.0.0.1:3001` (Dockerfile-এই বসানো আছে) — তাই "Make Clip"
আর "Concat" নোড দুটো ইন্টারনেট দিয়ে ঘুরে অন্য কোনো সার্ভিসে যাচ্ছে না,
সরাসরি একই কন্টেইনারের ভেতরের প্রসেসকে কল করছে। এতে করে নেটওয়ার্ক
হপ কমে, আর video-edit সার্ভিস আলাদাভাবে "ঘুমিয়ে" গিয়ে প্রথম রিকোয়েস্টে
টাইমআউট করার সমস্যাও থাকে না — পুরো কন্টেইনার একসাথে ঘুমায়, একসাথে
জাগে।

## ⚠️ Free plan-এ সবচেয়ে জরুরি জিনিস: sleep vs Schedule Trigger

এই workflow **Schedule Trigger** (cron) দিয়ে চলে — কোনো webhook না।
Cron logic n8n প্রসেসের **ভেতরে** থাকে; ঘড়ি মেলানোর কাজটা করে n8n
নিজেই, চলমান অবস্থায়। সমস্যাটা এখানে:

Render-এর Free web service ১৫ মিনিট কোনো ইনবাউন্ড ট্র্যাফিক (HTTP/WS)
না পেলে পুরো কন্টেইনার ঘুম পাড়িয়ে দেয়। কন্টেইনার ঘুমিয়ে থাকা মানে
**n8n প্রসেসটাই বন্ধ** — আর প্রসেস বন্ধ থাকলে ভেতরের cron ঘড়িও থেমে
থাকে। তার মানে সিডিউল করা সময় (যেমন শনি/রবি সকাল ৬টা) যখন আসবে,
কন্টেইনার যদি ঘুমিয়ে থাকে, তাহলে **workflow সেই রানটা একদমই miss
করে যাবে** — কোনো error ও দেখাবে না, শুধু চুপচাপ কিছুই হবে না।

**ফিক্স (বাধ্যতামূলক, ফ্রি-তেই সম্ভব):** একটা বাইরের keep-alive
pinger লাগাতে হবে যেটা প্রতি ৫-১০ মিনিটে আপনার n8n-এর পাবলিক URL-এ
রিকোয়েস্ট পাঠাবে, যাতে ১৫ মিনিটের ভেতরে ট্র্যাফিক আসতেই থাকে আর
কন্টেইনার কখনো ঘুমাতে না পারে:

1. [UptimeRobot](https://uptimerobot.com) (ফ্রি) বা
   [cron-job.org](https://cron-job.org) (ফ্রি) — যেকোনো একটায় সাইন আপ
   করুন।
2. একটা HTTP(S) monitor বানান, URL: `https://<আপনার-render-url>/healthz`,
   interval: ৫ মিনিট (UptimeRobot ফ্রি-তে সর্বনিম্ন ৫ মিনিট)।
3. ব্যস — এখন থেকে কন্টেইনার ২৪/৭ জেগে থাকবে, cron ঘড়ি ঠিক সময়ে
   ফায়ার করবে।

**এর একটা trade-off জেনে রাখা ভালো:** Render Free workspace-এ মাসে
৭৫০ instance-hour বরাদ্দ থাকে। একটা সার্ভিস ২৪/৭ (৩০ দিন × ২৪ ঘণ্টা
= ৭২০ ঘণ্টা, ৩১ দিনের মাসে ৭৪৪ ঘণ্টা) জাগিয়ে রাখলে সেটা প্রায় পুরো
মাসিক কোটাটাই খেয়ে ফেলে — কোটার মধ্যেই থাকবে, কিন্তু একই workspace-এ
আরেকটা ফ্রি web service একসাথে ২৪/৭ চালানোর মতো জায়গা থাকবে না।
এই repo-তে যেহেতু সবকিছু (n8n + video-edit + tts) এমনিতেই একটাই
সার্ভিসে বান্ডিল করা, এটা কোনো বাড়তি সমস্যা তৈরি করে না।

Render নিজে থেকেও মাঝেমধ্যে ফ্রি সার্ভিস restart করতে পারে (Render-এর
নিজস্ব নীতি, keep-alive দিয়েও এটা পুরোপুরি আটকানো যায় না) — এই জন্যই
`start.sh`-এর crash-loop supervisor আর externally-hosted Postgres
(`DB_POSTGRESDB_*`) আগে থেকেই রাখা আছে, যাতে এমন একটা রিস্টার্টে
workflow/credential হারিয়ে না যায়, শুধু চলমান একটা render/execution
থেমে গিয়ে retry হয়।

## YouTube policy — workflow যেগুলো এমনিতেই অটোমেটিক সামলায়

কোড খুঁটিয়ে দেখে যা পেলাম, এগুলো ইতিমধ্যে বিল্ট-ইন (নতুন করে কিছু
বদলাইনি, শুধু এখানে একসাথে লিখে রাখলাম যাতে নিশ্চিত থাকতে পারেন):

- **AI/Synthetic media disclosure** — আপলোডের পর `Set Synthetic Media Flag`
  node স্বয়ংক্রিয়ভাবে `status.containsSyntheticMedia=true` সেট করে
  (YouTube-এর AI-generated content নীতি অনুযায়ী বাধ্যতামূলক)।
- **Made for Kids** — আপলোড আর সিন্থেটিক-মিডিয়া কল দুটোতেই
  `selfDeclaredMadeForKids:false` পাঠানো হয় (একবার সেট করলেও পরের কলে
  আবার না পাঠালে YouTube সেটা রিসেট করে দেয় — এই bug আগেই ফিক্স করা
  ছিল, workflow note-এ ব্যাখ্যা আছে)।
- **Category** — `YOUTUBE_CATEGORY_ID` env var দিয়ে নিয়ন্ত্রিত (ডিফল্ট
  24 = Entertainment)।
- **Quota বাজেট** — প্রতি রানে মোটামুটি upload(1600) + thumbnail(50) +
  pinned comment(50) + synthetic-flag update(50) + trend lookup(1)
  ≈ ১৭৫০ ইউনিট। সপ্তাহে সাতটা cron রান (দিনে সর্বোচ্চ ১টা), ফ্রি
  ডেইলি কোটা (১০,০০০ ইউনিট) এর অনেক নিচেই থাকে — quota নিয়ে দুশ্চিন্তার
  কিছু নেই।
- **Content policy filter** — script জেনারেট হওয়ার পর `Policy & Safety
  Filter` + `Policy Safe?` node আপলোডের আগেই আটকায়, ফেল করলে upload-ই
  হয় না।

**যেটা এখনো ম্যানুয়াল, আমি করে দিতে পারি না:** YouTube-এর নিজের
OAuth2 credential n8n-এ কানেক্ট করা (Google Cloud Console-এ প্রজেক্ট
বানিয়ে YouTube Data API v3 enable + consent screen + credential —
এটা আপনার নিজের Google account-এর অনুমতি লাগে বলে আমি এই ধাপটা
সম্পন্ন করতে পারব না, শুধু কোড/workflow পর্যন্ত রেডি করে দিতে পারি)।

## Rewatch/retention — script pipeline-এ যা আগে থেকেই বিল্ট-ইন

"অডিয়েন্স বার বার দেখুক" — এটা মূলত content/algorithm-নির্ভর বিষয়,
কোনো নির্দিষ্ট রেজাল্ট আমি guarantee করতে পারি না। কিন্তু কোডে যা
পেলাম তাতে দেখলাম script-generation prompt-এ (Config Center-এর
`scriptPromptTemplate`) ইতিমধ্যেই কিছু retention-focused কৌশল বিল্ট-ইন
আছে — নতুন করে যোগ করিনি, শুধু চিহ্নিত করছি:
- প্রতিটা scene আগেরটার curiosity loop খুলে রাখে, পরেরটায় টানে।
- Scene 5 শেষ হয় twist/payoff দিয়ে, জেনেরিক "subscribe" CTA দিয়ে না।
- একটা optional "loop hack" আছে — scene 5-এর শেষ vs scene 1-এর শুরু
  এমনভাবে লেখা হয় যাতে ভিডিও রিপ্লে হলে বাক্যটা স্বাভাবিকভাবে চলতে
  থাকে (auto-loop platforms-এ)।
- Pinned comment হিসেবে একটা curiosity-driven প্রশ্ন/পোল অটো-পোস্ট হয়
  (reply/engagement বাড়ানোর জন্য)।
- একই ভয়েস/স্ক্রিপ্ট-স্ট্রাকচার বারবার না আসার জন্য voice pool +
  storytelling-angle randomization আছে।

## এই আপডেটের বাইরে যা ইচ্ছাকৃতভাবে বাদ দিলাম

এই repo একটাই জিনিস করে — একটা YouTube Shorts automation pipeline।
তাই finance/HR/legal/sales/bio-research ধরনের কোনো data বা workflow
এখানে নেই — সেই স্কিলগুলো প্রয়োগ করলে তা বাস্তব কিছুর ওপর ভিত্তি না
করে বানোয়াট output হতো, তাই সেগুলো এড়িয়ে গেছি এবং শুধু এই repo-র
জন্য বাস্তবিকভাবে প্রাসঙ্গিক জায়গাগুলোতেই (deploy/ops reliability,
YouTube policy, code-level RAM/crash safety) সময় দিয়েছি।

## Deploy ধাপ

1. এই ফোল্ডার একটা নতুন GitHub repo-তে পুশ করুন।
2. Render Dashboard -> **New** -> **Blueprint** -> repo সিলেক্ট করুন।
   `render.yaml` অটো-ডিটেক্ট হয়ে একটা মাত্র সার্ভিস (`n8n-allinone`)
   বানানোর প্রস্তাব দেবে — Apply করুন।
3. Environment ট্যাবে গিয়ে `sync: false` চিহ্নিত ভ্যারিয়েবলগুলো
   বসান (নিচে টেবিল)। `RENDER_VIDEO_EDIT_URL` / `RENDER_TTS_URL`
   টাচ করার দরকার নেই — এগুলো ইতিমধ্যে ঠিক বসানো আছে।
4. Deploy হয়ে গেলে n8n-এর URL-এ ঢুকে `workflow/My_workflow_4.json`
   import করুন, Google Sheets/Gmail/YouTube credentials নিজে কানেক্ট
   করে দিন।

## জরুরি env var

| Variable | কী |
|---|---|
| `N8N_HOST`, `WEBHOOK_URL`, `N8N_EDITOR_BASE_URL` | n8n-এর নিজের পাবলিক Render URL |
| `N8N_ENCRYPTION_KEY` | একটা র‍্যান্ডম লম্বা স্ট্রিং, একবার সেট করলে আর বদলাবেন না |
| `N8N_BASIC_AUTH_USER/PASSWORD` | এডিটরে লগইনের জন্য |
| `DB_POSTGRESDB_*` | বাইরের ফ্রি Postgres (Neon/Supabase) — না দিলে redeploy-তে workflow/credential হারিয়ে যাবে |
| `GEMINI_API_KEY` / `OPENROUTER_API_KEY` | স্ক্রিপ্ট জেনারেশনের জন্য অন্তত একটা |
| `GOOGLE_SHEET_ID` | টপিক/QC লগ শীট |
| `YOUTUBE_DATA_API_KEY` | + workflow-এর YouTube node-এ আলাদা OAuth credential |

## মেমরি বাজেট (512MB-এর মধ্যে ৩টা প্রসেস)

- n8n: heap cap ২০০MB (`NODE_OPTIONS`)
- video-edit (Node): heap cap ৯৬MB (`VIDEO_EDIT_NODE_OPTIONS`) — ffmpeg
  নিজে আলাদা OS প্রসেস, এই cap-এর বাইরে চলে, এনকোডের সময় সাময়িক
  স্পাইক করবে
- tts (Python, ডিফল্ট বন্ধ — `ENABLE_TTS_SERVICE=false`): চালু করলে
  সাধারণত ৪০-৭০MB
- বাকিটা OS/বাফার

512MB-এর মধ্যে স্থিরভাবে থাকার জন্য এই স্তরগুলো একসাথে কাজ করে:

1. **সিরিয়াল queue** — video-edit একবারে একটার বেশি ffmpeg জব চালায় না
   (`enqueue()`), তাই দুইটা render একসাথে RAM কাড়াকাড়ি করে না।
2. **Resolution cap** — `/make-clip`-এ `VIDEO_MAX_WIDTH`/`VIDEO_MAX_HEIGHT`
   (ডিফল্ট 720×1280) hard-enforced; n8n যা-ই পাঠাক, server নিজে clamp করে।
3. **Filesystem binary mode** — `N8N_DEFAULT_BINARY_DATA_MODE=filesystem`,
   তাই image/audio/video binary n8n-এর node-থেকে-node পাসের সময় RAM-এ না
   থেকে disk-এ থাকে (এইটাই সবচেয়ে বড় স্পাইক-প্রতিরোধক ফিক্স)।
4. **Execution data pruning + কম সেভ** — `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none`,
   `EXECUTIONS_DATA_PRUNE=true`, `EXECUTIONS_DATA_MAX_AGE=24`।
5. **Memory guard** — video-edit-এ নতুন render জব শুরুর আগে container-এর
   cgroup memory usage চেক করে; `MEMORY_GUARD_MAX_PERCENT` (ডিফল্ট ৮৮%)-এর
   বেশি হলে জব শুরুই করে না, `503` ফেরত দেয়। n8n-এর Make Clip/Concat
   node-এ আগে থেকেই retry+wait আছে, তাই এটা silent OOM-kill-এর বদলে একটা
   নিয়ন্ত্রিত retry হয়ে যায়।
6. **Stale-job sweep** — crash হলে যেসব `/tmp` ফাইল cleanup miss করে,
   ৩০ মিনিট পর auto মুছে যায় (RAM না, disk প্রোটেকশন)।
7. **Crash-loop supervisor** — `start.sh`-এ exponential backoff, তাই কোনো
   প্রসেস বারবার crash করলে CPU নষ্ট করে সব কিছু আরও চাপে ফেলে না।

তারপরও যদি মাঝেমধ্যে OOM (out-of-memory) রিস্টার্ট হয়:
- `VIDEO_EDIT_NODE_OPTIONS` আরেকটু কমান (যেমন `--max-old-space-size=64`)
- `MEMORY_GUARD_MAX_PERCENT` কমান (যেমন `80`) — আরও আগেই নতুন জব আটকাবে
- workflow-এ ভিডিওর width/height/fps কমিয়ে দেখুন
- `/health` endpoint (video-edit, `127.0.0.1:3001/health`)-এ
  `containerUsedPercent` দেখুন কোন সময় memory pressure বাড়ে

স্লো হওয়াটা এক্সপেক্টেড — লক্ষ্য এখানে খরচ ও usage কমিয়ে স্থিরভাবে
চালু রাখা, স্পিড না।
