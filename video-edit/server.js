// n8n-video-render-service
// -------------------------------------------------------------------------
// Small HTTP wrapper around ffmpeg so a low-resource Render.com free web
// service (0.1 CPU / ~450MB RAM / no GPU) can do the heavy "editing" work
// for an n8n workflow. n8n stays responsible for: TTS, image generation,
// deciding scene durations, building the SRT text, etc (all cheap, no
// ffmpeg). This service only ever does ONE ffmpeg job at a time (a simple
// in-process queue below) so it never blows past the memory budget.
// -------------------------------------------------------------------------

const express = require('express');
const multer = require('multer');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
// System ffmpeg (installed via apt in the shared Dockerfile) instead of the
// ffmpeg-static npm binary — avoids downloading/storing a second ~80MB
// ffmpeg copy inside the same 512MB container.
const ffmpegPath = process.env.FFMPEG_PATH || 'ffmpeg';

const app = express();
// Internal-only port — this service is never exposed directly by Render;
// n8n (running in the same container) calls it over 127.0.0.1.
const PORT = process.env.VIDEO_EDIT_PORT || process.env.PORT || 3001;
const HOST = '127.0.0.1';
const API_KEY = process.env.API_KEY || ''; // optional, internal traffic only

app.use(express.json({ limit: '2mb' })); // small JSON bodies only (metadata)

// ---------------------------------------------------------------------
// Simple auth: if API_KEY is set, require header  x-api-key: <API_KEY>
// ---------------------------------------------------------------------
app.use((req, res, next) => {
  if (req.path === '/health') return next();
  if (!API_KEY) return next(); // no key configured -> open (not recommended)
  if (req.get('x-api-key') === API_KEY) return next();
  return res.status(401).json({ ok: false, error: 'missing/invalid x-api-key header' });
});

// ---------------------------------------------------------------------
// Uploads go straight to disk (NOT memory) — critical on a ~450MB box.
// ---------------------------------------------------------------------
const TMP_ROOT = path.join(os.tmpdir(), 'render-jobs');
fs.mkdirSync(TMP_ROOT, { recursive: true });

// ---------------------------------------------------------------------
// Stale job sweep. Normally cleanup(dir) removes a job's temp files as
// soon as it finishes, but if the process is killed mid-job (OOM, crash,
// Render restart) that cleanup never runs and the directory is orphaned.
// On a small container these silently eat into disk over days of 24/7
// operation. Sweep once at boot (catches anything left from before a
// crash) and again periodically while running (catches jobs orphaned by
// a bug rather than a full process restart).
// ---------------------------------------------------------------------
const STALE_JOB_MAX_AGE_MS = 30 * 60 * 1000; // 30 min — well past any single job's lifetime
function sweepStaleJobs() {
  fs.readdir(TMP_ROOT, (err, entries) => {
    if (err || !entries) return;
    const now = Date.now();
    for (const entry of entries) {
      const dir = path.join(TMP_ROOT, entry);
      fs.stat(dir, (statErr, stat) => {
        if (statErr || !stat.isDirectory()) return;
        if (now - stat.mtimeMs > STALE_JOB_MAX_AGE_MS) {
          fs.rm(dir, { recursive: true, force: true }, () => {});
        }
      });
    }
  });
}
sweepStaleJobs(); // boot-time sweep
setInterval(sweepStaleJobs, 10 * 60 * 1000).unref(); // safety-net sweep every 10 min

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, req.jobDir),
  filename: (req, file, cb) => cb(null, file.fieldname + '_' + file.originalname),
});
function makeJobDir(req, res, next) {
  const id = crypto.randomBytes(6).toString('hex');
  req.jobId = id;
  req.jobDir = path.join(TMP_ROOT, id);
  fs.mkdirSync(req.jobDir, { recursive: true });
  next();
}
// Generous but bounded — a single scene image/audio file or a fully
// concatenated short is always well under this. Guards disk, not RAM
// directly, but disk exhaustion on this box takes n8n's filesystem-mode
// binary data down with it, which is its own path to a stuck workflow.
const MAX_UPLOAD_BYTES = parseInt(process.env.MAX_UPLOAD_MB || '300', 10) * 1024 * 1024;
const upload = multer({ storage, limits: { fileSize: MAX_UPLOAD_BYTES } });

// ---------------------------------------------------------------------
// Memory guard. Everything else in this file (single-job queue, disk
// uploads, resolution cap, stale-job sweep) reduces how much memory a
// job uses — this is the last line of defense for when it's not
// enough: it checks the container's actual cgroup memory usage BEFORE
// starting a new ffmpeg job, and refuses (503) if already close to the
// limit, instead of starting the job and risking the OS OOM-killing
// the whole container (which takes n8n and the in-flight job down
// with it, mid-render, with no graceful recovery).
//
// n8n's "Make Clip (HTTP)" / "Concat + BGM + Subtitle (HTTP)" nodes
// already have retryOnFail + a wait-between-tries configured, so a 503
// here just becomes a retried request a bit later, after memory from
// the previous job has actually been freed — a real error surfaced
// early beats a silent restart-loop.
//
// Fails OPEN if cgroup memory files aren't readable (e.g. a different
// hosting platform) — this guard is a safety net on top of everything
// else, not the only thing standing between this service and OOM.
// ---------------------------------------------------------------------
function readCgroupMemory() {
  try {
    // cgroup v2 (current Docker/Render default)
    if (fs.existsSync('/sys/fs/cgroup/memory.max')) {
      const maxRaw = fs.readFileSync('/sys/fs/cgroup/memory.max', 'utf8').trim();
      if (maxRaw !== 'max') {
        const limitBytes = parseInt(maxRaw, 10);
        const usedBytes = parseInt(fs.readFileSync('/sys/fs/cgroup/memory.current', 'utf8').trim(), 10);
        if (limitBytes > 0 && usedBytes >= 0) return { usedBytes, limitBytes };
      }
    }
    // cgroup v1 fallback
    if (fs.existsSync('/sys/fs/cgroup/memory/memory.limit_in_bytes')) {
      const limitBytes = parseInt(fs.readFileSync('/sys/fs/cgroup/memory/memory.limit_in_bytes', 'utf8').trim(), 10);
      // an unset v1 limit reads back as a huge near-2^63 number — treat that as "no limit set"
      if (limitBytes > 0 && limitBytes < 1e15) {
        const usedBytes = parseInt(fs.readFileSync('/sys/fs/cgroup/memory/memory.usage_in_bytes', 'utf8').trim(), 10);
        if (usedBytes >= 0) return { usedBytes, limitBytes };
      }
    }
  } catch (_) {
    // unreadable on this platform — guard fails open below
  }
  return null;
}

const MEMORY_GUARD_MAX_PERCENT = parseFloat(process.env.MEMORY_GUARD_MAX_PERCENT || '88');
function memoryGuard(req, res, next) {
  const mem = readCgroupMemory();
  if (!mem) return next(); // can't see cgroup memory on this host — don't block over it
  const pct = (mem.usedBytes / mem.limitBytes) * 100;
  if (pct >= MEMORY_GUARD_MAX_PERCENT) {
    res.set('Retry-After', '15');
    return res.status(503).json({
      ok: false,
      error: 'low_memory',
      detail: `container memory at ${pct.toFixed(1)}% of its ${Math.round(mem.limitBytes / 1024 / 1024)}MB limit — refusing to start a new render job to avoid an OOM kill. Retry shortly.`,
    });
  }
  next();
}

// ---------------------------------------------------------------------
// Single-job-at-a-time queue. Free-tier CPU is only 0.1 vCPU — running
// two ffmpeg encodes at once just makes both slower and risks OOM. This
// serializes everything; the caller (n8n) can still fire scenes one by
// one in a loop like the original workflow already did.
// ---------------------------------------------------------------------
let queueTail = Promise.resolve();
function enqueue(job) {
  const run = queueTail.then(job, job);
  // swallow errors here so one failed job doesn't wedge the queue
  queueTail = run.catch(() => {});
  return run;
}

function runFfmpeg(args) {
  return new Promise((resolve, reject) => {
    execFile(
      ffmpegPath,
      args,
      { maxBuffer: 1024 * 1024 * 8, timeout: 5 * 60 * 1000 },
      (err, stdout, stderr) => {
        if (err) {
          err.stderr = stderr;
          return reject(err);
        }
        resolve({ stdout, stderr });
      }
    );
  });
}

function cleanup(dir) {
  fs.rm(dir, { recursive: true, force: true }, () => {});
}

// ---------------------------------------------------------------------
// Measure the real length of an audio file by asking ffmpeg to "decode"
// it with no output and reading the "Duration: HH:MM:SS.ms" line it
// prints to stderr. No ffprobe binary needed (keeps the free-tier image
// small), and it's the actual voice length rather than whatever value
// n8n calculated/passed along, so scene video length always matches the
// real TTS audio exactly.
// ---------------------------------------------------------------------
function getAudioDuration(filePath) {
  return new Promise((resolve) => {
    execFile(ffmpegPath, ['-i', filePath], { timeout: 20000 }, (err, stdout, stderr) => {
      const out = stderr || (err && err.message) || '';
      const match = out.match(/Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)/);
      if (!match) return resolve(null);
      const hours = parseFloat(match[1]);
      const minutes = parseFloat(match[2]);
      const seconds = parseFloat(match[3]);
      const total = hours * 3600 + minutes * 60 + seconds;
      resolve(total > 0 ? total : null);
    });
  });
}

// ---------------------------------------------------------------------
// GET /health  — also useful as a keep-alive ping target (see README)
// ---------------------------------------------------------------------
app.get('/health', (req, res) => {
  const mem = process.memoryUsage();
  const cg = readCgroupMemory();
  res.json({
    ok: true,
    service: 'n8n-video-render',
    time: Date.now(),
    memory: {
      rssMB: Math.round(mem.rss / 1024 / 1024),
      heapUsedMB: Math.round(mem.heapUsed / 1024 / 1024),
      containerUsedMB: cg ? Math.round(cg.usedBytes / 1024 / 1024) : null,
      containerLimitMB: cg ? Math.round(cg.limitBytes / 1024 / 1024) : null,
      containerUsedPercent: cg ? Math.round((cg.usedBytes / cg.limitBytes) * 1000) / 10 : null,
    },
  });
});

// ---------------------------------------------------------------------
// POST /make-clip   (multipart/form-data)
//   fields:
//     image        (file, required)  - jpg/png
//     audio        (file, required)  - mp3
//     duration     (text, optional)  - fallback clip length in seconds,
//                                      only used if the audio file's real
//                                      duration can't be measured. Normally
//                                      the server measures the actual audio
//                                      length itself and uses that instead.
//     width        (text, optional)  - default 720
//     height       (text, optional)  - default 1280
//     fps          (text, optional)  - default 24 (kept low for the CPU budget)
//     zoom         (text, optional)  - "in" | "out" | "none"  (default "in")
//     weather      (text, optional)  - "none" | "rain" | "snow"
//   returns: raw video/mp4 bytes
// ---------------------------------------------------------------------
app.post(
  '/make-clip',
  memoryGuard,
  makeJobDir,
  upload.fields([{ name: 'image', maxCount: 1 }, { name: 'audio', maxCount: 1 }]),
  (req, res) => {
    enqueue(async () => {
      try {
        const imgFile = req.files?.image?.[0];
        const audFile = req.files?.audio?.[0];
        if (!imgFile || !audFile) {
          res.status(400).json({ ok: false, error: 'image and audio files are both required' });
          return;
        }
        const passedDuration = parseFloat(req.body.duration || '0');
        const measuredDuration = await getAudioDuration(audFile.path);
        // Trust the actual audio file's length over whatever n8n calculated —
        // this is what guarantees the clip (and its zoom motion) always runs
        // exactly as long as the real voice track, with no drift.
        const duration = measuredDuration || passedDuration;
        if (!duration || duration <= 0) {
          res.status(400).json({ ok: false, error: 'could not determine duration: audio file unreadable and no valid duration field was sent' });
          return;
        }
        // Hard cap, independent of whatever width/height the caller sends.
        // Defaults match the workflow's own 720x1280 request, but this is
        // what actually prevents a RAM spike if a node gets edited later
        // (or a bug sends 1920x1080) — the cap is enforced here, not just
        // requested there.
        const MAX_WIDTH = parseInt(process.env.VIDEO_MAX_WIDTH || '720', 10);
        const MAX_HEIGHT = parseInt(process.env.VIDEO_MAX_HEIGHT || '1280', 10);
        const width = Math.min(parseInt(req.body.width || '720', 10), MAX_WIDTH);
        const height = Math.min(parseInt(req.body.height || '1280', 10), MAX_HEIGHT);
        const fps = Math.min(parseInt(req.body.fps || '24', 10), 30);
        const zoom = (req.body.zoom || 'in').toLowerCase();
        const weather = (req.body.weather || 'none').toLowerCase();

        const frames = Math.round(duration * fps) + 2;
        let zExpr = "if(eq(on,0),1.0,min(zoom+0.0015,1.15))"; // gentle zoom-in
        if (zoom === 'out') zExpr = "if(eq(on,0),1.15,max(1.0,zoom-0.0015))";
        if (zoom === 'none') zExpr = "1.0";

        let weatherVf = '';
        if (weather === 'rain') weatherVf = ',noise=alls=14:allf=t+u,boxblur=1:1:0:0';
        else if (weather === 'snow') weatherVf = ',noise=alls=20:allf=t+u';

        const vf =
          `scale=${width}:${height}:force_original_aspect_ratio=increase:flags=lanczos,` +
          `crop=${width}:${height},setsar=1,` +
          `zoompan=z='${zExpr}':d=${frames}:s=${width}x${height}:fps=${fps}${weatherVf},` +
          `eq=contrast=1.08:saturation=1.15:brightness=0.02`; // cheap "cinematic" color pop — negligible CPU cost, no resolution change

        const outPath = path.join(req.jobDir, 'clip.mp4');

        const args = [
          '-y', '-threads', '1', '-filter_threads', '1', '-filter_complex_threads', '1',
          '-loop', '1', '-i', imgFile.path,
          '-i', audFile.path,
          '-vf', vf,
          '-af', 'apad', // pad audio with silence up to full clip length (fixes voice cutting off short)
          '-c:v', 'libx264', '-tune', 'stillimage', '-preset', 'ultrafast', '-crf', '23',
          '-x264-params', 'ref=1:bframes=0:rc-lookahead=0',
          '-g', String(fps * 2),
          '-c:a', 'aac', '-b:a', '96k', '-ar', '44100', '-ac', '1',
          '-pix_fmt', 'yuv420p', '-r', String(fps),
          '-fps_mode', 'cfr', // lock to constant frame rate so zoompan frames don't get dropped/duplicated (fixes choppy/stuttering playback)
          '-t', String(duration),
          outPath,
        ];

        await runFfmpeg(args);

        res.setHeader('Content-Type', 'video/mp4');
        fs.createReadStream(outPath).pipe(res).on('close', () => cleanup(req.jobDir));
      } catch (err) {
        console.error('make-clip failed:', err.stderr || err.message);
        res.status(500).json({ ok: false, error: 'ffmpeg failed', detail: String(err.stderr || err.message).slice(0, 800) });
        cleanup(req.jobDir);
      }
    });
  }
);

// ---------------------------------------------------------------------
// POST /concat   (multipart/form-data)
//   fields:
//     clip_1, clip_2, clip_3, ... clip_N   (files, required, IN ORDER)
//     bgm          (file, optional)  - background music track
//     bgm_volume   (text, optional)  - 0..1, default 0.25
//     srt          (text, optional)  - full SRT subtitle content to burn in
//   returns: raw video/mp4 bytes
// ---------------------------------------------------------------------
app.post('/concat', memoryGuard, makeJobDir, upload.any(), (req, res) => {
  enqueue(async () => {
    try {
      const clipFiles = (req.files || [])
        .filter((f) => /^clip_\d+$/.test(f.fieldname))
        .sort((a, b) => {
          const na = parseInt(a.fieldname.split('_')[1], 10);
          const nb = parseInt(b.fieldname.split('_')[1], 10);
          return na - nb;
        });
      if (clipFiles.length === 0) {
        res.status(400).json({ ok: false, error: 'no clip_1, clip_2, ... files found' });
        return;
      }
      const bgmFile = (req.files || []).find((f) => f.fieldname === 'bgm');
      const bgmVolume = parseFloat(req.body.bgm_volume || '0.25');
      const srtText = req.body.srt;

      // 1) concat demuxer, stream copy (fast, no re-encode)
      const listPath = path.join(req.jobDir, 'list.txt');
      fs.writeFileSync(
        listPath,
        clipFiles.map((f) => `file '${f.path.replace(/'/g, "'\\''")}'`).join('\n')
      );
      const concatPath = path.join(req.jobDir, 'concat.mp4');
      await runFfmpeg(['-y', '-f', 'concat', '-safe', '0', '-i', listPath, '-c', 'copy', concatPath]);

      const outPath = path.join(req.jobDir, 'final.mp4');
      const needsSubs = !!srtText && srtText.trim().length > 0;
      const needsBgm = !!bgmFile;

      if (!needsSubs && !needsBgm) {
        // fast path: nothing else to do
        fs.copyFileSync(concatPath, outPath);
      } else {
        let srtPath = null;
        if (needsSubs) {
          srtPath = path.join(req.jobDir, 'subs.srt');
          fs.writeFileSync(srtPath, srtText, 'utf-8');
        }

        const args = ['-y', '-threads', '1', '-filter_threads', '1', '-filter_complex_threads', '1', '-i', concatPath];
        if (needsBgm) args.push('-i', bgmFile.path);

        const filters = [];
        if (needsSubs) {
          const escaped = srtPath.replace(/:/g, '\\:').replace(/'/g, "\\'");
          // force_style Alignment uses the ASS numpad layout (1-9 only):
          // 1-3 bottom, 4-6 middle, 7-9 top. 5 = middle-center of the frame (kept as requested).
          // Style upgraded to bold yellow + thick outline/shadow for a viral-caption "pop" —
          // libass still honors the per-word <font color=...> highlight tags already inside the SRT.
          const subStyle = "Alignment=5,PrimaryColour=&H0000FFFF,OutlineColour=&H00000000,BorderStyle=1,Outline=3,Shadow=2,Bold=1";
          filters.push(`[0:v]subtitles='${escaped}':force_style='${subStyle}'[vout]`);
        }
        if (needsBgm) {
          // mix voice + bgm, then loudness-normalize the mixed result to YouTube's broadcast target
          filters.push(`[0:a][1:a]amix=inputs=2:duration=first:weights=1 ${bgmVolume}[amixed]`);
          filters.push(`[amixed]loudnorm=I=-16:TP=-1.5:LRA=11[aout]`);
        } else {
          // still loudness-normalize the voice track even with no bgm (audio gets re-encoded either way)
          filters.push(`[0:a]loudnorm=I=-16:TP=-1.5:LRA=11[aout]`);
        }

        if (filters.length) args.push('-filter_complex', filters.join(';'));
        args.push('-map', needsSubs ? '[vout]' : '0:v');
        args.push('-map', '[aout]');

        if (needsSubs) {
          args.push('-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '23', '-fps_mode', 'cfr');
        } else {
          args.push('-c:v', 'copy');
        }
        args.push('-c:a', 'aac', '-b:a', '128k');
        args.push(outPath);

        await runFfmpeg(args);
      }

      res.setHeader('Content-Type', 'video/mp4');
      fs.createReadStream(outPath).pipe(res).on('close', () => cleanup(req.jobDir));
    } catch (err) {
      console.error('concat failed:', err.stderr || err.message);
      res.status(500).json({ ok: false, error: 'ffmpeg failed', detail: String(err.stderr || err.message).slice(0, 800) });
      cleanup(req.jobDir);
    }
  });
});

// Must be declared last, and with 4 args, for Express to treat it as an
// error handler. Catches multer's LIMIT_FILE_SIZE (and similar) so an
// oversized upload gets a clean response instead of a stack trace.
app.use((err, req, res, next) => {
  if (err && err.code === 'LIMIT_FILE_SIZE') {
    return res.status(413).json({ ok: false, error: 'file_too_large', detail: `exceeds ${MAX_UPLOAD_BYTES / 1024 / 1024}MB limit` });
  }
  console.error('unhandled error:', err && (err.stack || err.message || err));
  res.status(500).json({ ok: false, error: 'internal_error' });
});

app.listen(PORT, HOST, () => {
  console.log(`n8n-video-render listening on ${HOST}:${PORT} (internal only)`);
  console.log(`ffmpeg binary: ${ffmpegPath}`);
});
