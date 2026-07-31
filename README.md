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

- n8n: heap cap ২০০MB
- video-edit (Node): heap cap ৯৬MB (ffmpeg নিজে আলাদা OS প্রসেস, এর
  বাইরে চলে, ভিডিও এনকোডের সময় সাময়িক স্পাইক করবে)
- tts (Python, ডিফল্ট বন্ধ): চালু করলে সাধারণত ৪০-৭০MB
- বাকিটা OS/বাফার

সিরিয়াল queue থাকায় video-edit একবারে একটার বেশি ffmpeg জব চালায় না,
তাই স্পাইক নিয়ন্ত্রিত থাকে। তারপরও যদি মাঝেমধ্যে OOM (out-of-memory)
রিস্টার্ট হয়:
- `ENABLE_TTS_SERVICE` বন্ধই রাখুন (ডিফল্ট)
- `VIDEO_EDIT_NODE_OPTIONS` আরেকটু কমান (যেমন `--max-old-space-size=64`)
- workflow-এ ভিডিওর width/height/fps কমিয়ে দেখুন

স্লো হওয়াটা এক্সপেক্টেড — লক্ষ্য এখানে খরচ ও usage কমিয়ে স্থিরভাবে
চালু রাখা, স্পিড না।
