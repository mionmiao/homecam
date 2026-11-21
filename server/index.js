import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import express from 'express';
import { Server } from 'socket.io';

dotenv.config();
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const port = Number(process.env.PORT || 3000);
const dataDir = path.resolve(root, process.env.DATA_DIR || 'data');
const photosDir = path.join(dataDir, 'photos');
const dbFile = path.join(dataDir, 'homecam.json');
const runtimeConfigFile = path.join(dataDir, 'runtime-config.json');
const releasesDir = path.join(dataDir, 'releases');
const adminPassword = process.env.ADMIN_PASSWORD;
const memberPassword = process.env.MEMBER_PASSWORD;
const tokenSecret = process.env.TOKEN_SECRET;
if (!adminPassword || !memberPassword || !tokenSecret) throw new Error('ADMIN_PASSWORD, MEMBER_PASSWORD and TOKEN_SECRET must be set in .env');
let iceServers;
try { iceServers = JSON.parse(process.env.ICE_SERVERS || '[{"urls":["stun:stun.l.google.com:19302"]}]'); } catch { throw new Error('ICE_SERVERS must be valid JSON'); }
// coturn REST API 临时凭据：TURN_SECRET 与 coturn 的 static-auth-secret 一致。
// 未配置时退回 ICE_SERVERS 里的静态凭据，兼容旧部署。
const turnSecret = process.env.TURN_SECRET || '';
const turnTtlSeconds = Number(process.env.TURN_TTL_SECONDS || 3600);
const activeIceServers = () => {
  if (!turnSecret) return iceServers;
  const exp = Math.floor(Date.now() / 1000) + turnTtlSeconds;
  const username = `${exp}:homecam`;
  const credential = crypto.createHmac('sha1', turnSecret).update(username).digest('base64');
  return iceServers.map((s) => {
    const urls = Array.isArray(s.urls) ? s.urls : [s.urls];
    const isTurn = urls.some((u) => /^turns?:/i.test(String(u)));
    return isTurn ? { ...s, username, credential } : { ...s };
  });
};
fs.mkdirSync(dataDir, { recursive: true });
fs.mkdirSync(releasesDir, { recursive: true });
fs.mkdirSync(path.join(photosDir, 'front'), { recursive: true });
fs.mkdirSync(path.join(photosDir, 'back'), { recursive: true });
let db = fs.existsSync(dbFile) ? JSON.parse(fs.readFileSync(dbFile, 'utf8')) : { devices: [], pairingCodes: [] };
if (!Array.isArray(db.devices)) db.devices = [];
if (!Array.isArray(db.pairingCodes)) db.pairingCodes = [];
db.tokenVersion = Number(db.tokenVersion) || 0;
if (!Array.isArray(db.revokedTokens)) db.revokedTokens = [];
const save = () => fs.writeFileSync(dbFile, JSON.stringify(db, null, 2), { mode: 0o600 });
const id = () => crypto.randomUUID();
const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');
const safeEqual = (a, b) => crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
const matchPassword = (attempt, expected) => {
  const a = String(attempt || ''), b = String(expected || '');
  return a.length === b.length && safeEqual(a, b);
};
// Cloudflare Tunnel 下 Node 看到的 remoteAddress 是隧道本机；只有来自可信代理时才采信转发头。
// 隧道跑在别的网段时，用 TRUST_PROXY_IPS 把该地址加进来（逗号分隔）。
const trustedProxies = new Set(
  (process.env.TRUST_PROXY_IPS || '127.0.0.1,::1,::ffff:127.0.0.1').split(',').map((s) => s.trim()).filter(Boolean)
);
const clientIp = (req) => {
  const remote = req.socket.remoteAddress || '';
  if (trustedProxies.has(remote)) {
    const cf = String(req.headers['cf-connecting-ip'] || '').trim();
    if (cf) return cf.split(',')[0].trim();
    const xff = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
    if (xff) return xff;
  }
  return remote;
};
// 轻量滑动窗口限流：只按 IP + 场景计数，无需新增依赖。
const rateHits = new Map();
const rateLimit = (key, limit, windowMs) => {
  const now = Date.now();
  const hits = rateHits.get(key) || [];
  while (hits.length && now - hits[0] >= windowMs) hits.shift();
  hits.push(now);
  rateHits.set(key, hits);
  if (rateHits.size > 20000) { const oldest = rateHits.keys().next().value; rateHits.delete(oldest); }
  return { ok: hits.length <= limit, retryAfter: Math.max(1, Math.ceil((hits[0] + windowMs - now) / 1000)) };
};
const resetRateLimit = (key) => rateHits.delete(key);
setInterval(() => {
  const now = Date.now();
  for (const [key, hits] of rateHits) if (!hits.length || now - hits[hits.length - 1] >= 900000) rateHits.delete(key);
}, 300000).unref();
const LOGIN_LIMIT = Number(process.env.LOGIN_LIMIT || 8);
const PAIR_LIMIT = Number(process.env.PAIR_LIMIT || 10);
const PAIR_WINDOW_MS = 10 * 60 * 1000;
const guard = (name, limit, windowMs, keyOf = clientIp) => (req, res, next) => {
  const result = rateLimit(`${name}:${keyOf(req)}`, limit, windowMs);
  if (result.ok) return next();
  res.set('Retry-After', String(result.retryAfter));
  res.status(429).json({ error: `尝试次数过多，请 ${Math.ceil(result.retryAfter / 60)} 分钟后再试` });
};
const TOKEN_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const sign = (payload) => {
  const body = Buffer.from(JSON.stringify({ ...payload, jti: id(), ver: db.tokenVersion || 0, exp: Date.now() + TOKEN_TTL_MS })).toString('base64url');
  return `${body}.${crypto.createHmac('sha256', tokenSecret).update(body).digest('base64url')}`;
};
const verify = (token) => {
  const [body, signature] = String(token || '').split('.');
  if (!body || !signature) return null;
  const expected = crypto.createHmac('sha256', tokenSecret).update(body).digest('base64url');
  if (expected.length !== signature.length || !safeEqual(expected, signature)) return null;
  try {
    const value = JSON.parse(Buffer.from(body, 'base64url'));
    if (!(value.exp > Date.now())) return null;
    if ((value.ver || 0) !== (db.tokenVersion || 0)) return null;
    if (value.jti && db.revokedTokens.some((r) => r.jti === value.jti && r.exp > Date.now())) return null;
    return value;
  } catch { return null; }
};
// 照片 URL 短期签名：只有登录用户拿到的 /api/photos 列表才给有效签名，破解文件名也无法直接访问。
const PHOTO_TTL_MS = 60 * 60 * 1000;
const photoSig = (urlPath, exp) => crypto.createHmac('sha256', tokenSecret).update(`${urlPath}|${exp}`).digest('base64url');
const signedPhotoUrl = (urlPath) => {
  const exp = Date.now() + PHOTO_TTL_MS;
  return `${urlPath}?exp=${exp}&sig=${photoSig(urlPath, exp)}`;
};
const publicDevice = ({ secretHash, ...device }) => device;
// 运行时配置：存在 data/runtime-config.json，改文件或调 PUT 接口即生效，无需重启、无需重装 App
const defaultRuntimeConfig = {
  schemaVersion: 1,
  iceServers: null,          // null = 设备使用信令下发（watch:start）的带时效 ICE，不再公开静态凭据
  features: { photos: true, burst: true, screenLockCapture: true, cameraSwitch: true, photoUpload: true },
  photoSettings: { burstCount: 5, intervalMs: 300, order: ['front', 'back'] },
  captureThresholdSeconds: 10,   // 离开前台超过多少秒才拍照（区分下拉状态栏与锁屏）
  ui: {}
};
function readRuntimeConfig() {
  try {
    if (!fs.existsSync(runtimeConfigFile)) return defaultRuntimeConfig;
    const raw = JSON.parse(fs.readFileSync(runtimeConfigFile, 'utf8'));
    return {
      ...defaultRuntimeConfig, ...raw,
      features: { ...defaultRuntimeConfig.features, ...(raw.features || {}) },
      photoSettings: { ...defaultRuntimeConfig.photoSettings, ...(raw.photoSettings || {}) },
      ui: { ...defaultRuntimeConfig.ui, ...(raw.ui || {}) }
    };
  } catch (e) { console.log('[config] parse failed, using defaults:', e.message); return defaultRuntimeConfig; }
}
function writeRuntimeConfig(patch) {
  const next = { ...readRuntimeConfig(), ...patch };
  fs.writeFileSync(runtimeConfigFile, JSON.stringify(next, null, 2), { mode: 0o600 });
  console.log('[config] updated');
  return next;
}
// 自动同步 GitHub Release 上的最新 unsigned IPA，供 App 检查更新与一键安装
const releaseRepo = process.env.RELEASE_REPO || 'mionmiao/homecam';
const releaseTag = process.env.RELEASE_TAG || 'ios-unsigned';
let latestRelease = null;
const parseBuild = (body) => {
  const m = /build=(\d+)/.exec(body || '');
  if (m) return Number(m[1]);
  const v = /1\.0\.(\d+)/.exec(body || '');
  return v ? Number(v[1]) : 0;
};
// 从 IPA 内部读取真实 CFBundleVersion（比 release body 更可信，避免 CDN 返回旧包）
function readBundleVersion(ipaPath) {
  try {
    const script = [
      'import zipfile,plistlib,sys',
      'z=zipfile.ZipFile(sys.argv[1])',
      'n=[x for x in z.namelist() if x.endswith(".app/Info.plist")][0]',
      'print(plistlib.loads(z.read(n)).get("CFBundleVersion",""))'
    ].join('\n');
    return execFileSync('python3', ['-c', script, ipaPath], { timeout: 20000 }).toString().trim();
  } catch { return ''; }
}
async function syncLatestRelease() {
  try {
    const headers = { 'User-Agent': 'homecam', 'Accept': 'application/vnd.github+json' };
    if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
    const res = await fetch(`https://api.github.com/repos/${releaseRepo}/releases/tags/${releaseTag}`, { headers });
    if (!res.ok) {
      const remaining = res.headers.get('x-ratelimit-remaining');
      console.log(`[release] fetch failed ${res.status}${remaining === '0' ? ' (rate limit exceeded)' : ''}`);
      return;
    }
    const rel = await res.json();
    const asset = (rel.assets || []).find((a) => a.name === 'HomeCamCamera.ipa');
    if (!asset) { console.log('[release] no ipa asset'); return; }
    if (latestRelease && latestRelease.assetId === asset.id) return;   // 没有新构建
    // 用 browser_download_url 下载（API asset 端点对匿名请求返回 403），
    // 带上 no-cache 头避免 CDN 命中旧缓存；再用 API 提供的 digest 校验内容
    const ipaRes = await fetch(asset.browser_download_url, {
      headers: { ...headers, 'Cache-Control': 'no-cache', Pragma: 'no-cache' }
    });
    if (!ipaRes.ok) { console.log('[release] download failed', ipaRes.status); return; }
    const buf = Buffer.from(await ipaRes.arrayBuffer());
    // 校验用 GitHub API 返回的 asset.digest（权威，不受 CDN 缓存影响）
    const expected = String(asset.digest || '').replace(/^sha256:/, '');
    const actual = digest(buf);
    if (expected && expected !== actual) {
      console.log(`[release] digest mismatch (cdn stale?), keep previous release; retry in 60s`);
      return;
    }
    fs.writeFileSync(path.join(releasesDir, 'HomeCamCamera.ipa'), buf, { mode: 0o644 });
    const body = rel.body || '';
    // 以 IPA 内部真实的 CFBundleVersion 为准，body 里的 build= 仅作兜底
    const realBuild = readBundleVersion(path.join(releasesDir, 'HomeCamCamera.ipa'));
    const bodyBuild = parseBuild(body);
    // body 通过 API 拿（新鲜），IPA 内容可能是陈旧 CDN 副本：两者不符说明内容过期，拒绝发布
    if (bodyBuild && realBuild && Number(realBuild) !== Number(bodyBuild)) {
      console.log(`[release] stale content (ipa build ${realBuild} != release build ${bodyBuild}), keep previous; retry in 60s`);
      return;
    }
    let build = realBuild ? Number(realBuild) : 0;
    if (!build) build = bodyBuild;
    // 只取「更新说明：」那一行作为弹窗文案，其余是发布流程说明，不适合展示给用户
    const noteMatch = /更新说明：(.+)/.exec(body);
    let notes = noteMatch ? noteMatch[1].trim().split('\n')[0].slice(0, 120) : '';
    if (!notes) {
      // 老版本 body 没有「更新说明」行，回退到首行非空内容（跳过导入教程类行）
      notes = body.split('\n').map((l) => l.trim())
        .filter((l) => l && !/^(下载|JIT-less|此包不含|未签名 IPA)/.test(l) && !/build=\d+/.test(l))[0] || '包含新功能与修复';
      notes = notes.slice(0, 120);
    }
    latestRelease = {
      build: parseBuild(body), version: (body.match(/1\.0\.\d+/) || ['1.0'])[0], notes,
      assetId: asset.id, sha256: digest(buf), size: buf.length, publishedAt: asset.updated_at
    };
    console.log(`[release] synced build=${latestRelease.build} size=${latestRelease.size}`);
  } catch (e) { console.log('[release] sync error', e.message); }
}
// 统一设备状态视图：所有下发到观看端的列表都带 online/status，避免状态错乱
function deviceView(d) {
  // 手机端主动解绑后保留设备记录，标记为失效（历史照片仍可查看；观看端手动删除才彻底移除）
  return { ...publicDevice(d), unpairedAt: d.unpairedAt || 0, online: !d.unpairedAt && deviceSockets.has(d.id), status: d.unpairedAt ? 'unpaired' : (activeViews.has(d.id) ? 'streaming' : (deviceSockets.has(d.id) ? 'idle' : 'offline')) };
}
function broadcastDevices() { io.to('viewers').emit('devices', db.devices.map(deviceView)); }

const app = express();
app.use((_req, res, next) => {
  res.set('X-Content-Type-Options', 'nosniff');
  res.set('X-Frame-Options', 'DENY');
  res.set('Referrer-Policy', 'no-referrer');
  res.set('Content-Security-Policy', [
    "default-src 'self' blob: data:",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' blob: data:",
    "media-src 'self' blob: mediastream:",
    "connect-src 'self' ws: wss:",
    "object-src 'none'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
    "form-action 'self'"
  ].join('; '));
  next();
});
app.use(express.json({ limit: '12mb' }));
// 观看端自动更新：计算 web 资源指纹，并在 index.html 注入当前版本，
// 前端据此比对判断是否有新版本（正在观看时不自动刷新，避免断流）
const webVersion = () => {
  const h = crypto.createHash('sha256');
  for (const f of ['index.html', 'app.js', 'style.css']) {
    try { h.update(fs.readFileSync(path.join(root, 'web', f))); } catch { /* 文件缺失则跳过 */ }
  }
  return h.digest('hex').slice(0, 12);
};
app.get(['/', '/index.html'], (_req, res) => {
  const version = webVersion();
  let html = fs.readFileSync(path.join(root, 'web', 'index.html'), 'utf8');
  html = html.replace('</head>', `<meta name="web-version" content="${version}">\n</head>`);
  // 带上版本号，避免浏览器沿用缓存的旧脚本/样式
  html = html.replace('href="/style.css"', `href="/style.css?v=${version}"`)
             .replace('src="/app.js"', `src="/app.js?v=${version}"`);
  res.set('Cache-Control', 'no-store').type('html').send(html);
});
app.get('/api/web-version', (_req, res) => res.json({ version: webVersion() }));
app.use('/releases', express.static(releasesDir, { maxAge: 0, index: false }));
// App 检查更新：返回最新可用构建与直链下载地址
app.get('/api/version', (_req, res) => {
  // 只返回相对路径：客户端用自己保存的 serverURL 拼绝对路径。
  // 这样 Cloudflare 临时域名每次变化都无需改配置，也彻底避开 Host 头注入。
  const ipaPath = '/releases/HomeCamCamera.ipa';
  if (!latestRelease) return res.json({ build: 0, version: '', notes: '', ipaPath, ipaUrl: '', ready: false });
  console.log(`[version] checked by ${clientIp(_req)} build=${latestRelease.build}`);
  res.json({
    build: latestRelease.build, version: latestRelease.version, notes: latestRelease.notes,
    ipaPath, ipaUrl: ipaPath, sha256: latestRelease.sha256,
    size: latestRelease.size, publishedAt: latestRelease.publishedAt, ready: true
  });
});
app.use(express.static(path.join(root, 'web')));
app.use('/photos', (req, res, next) => {
  const urlPath = req.originalUrl.split('?')[0];
  const exp = Number(req.query.exp || 0);
  const sig = String(req.query.sig || '');
  const expected = photoSig(urlPath, exp);
  if (!exp || exp < Date.now() || sig.length !== expected.length || !safeEqual(sig, expected)) return res.status(403).send('Forbidden');
  next();
}, express.static(photosDir, { maxAge: 0, index: false }));
// 观看端 token 走 HttpOnly Cookie，避免 localStorage 被 XSS 窃取；
// 同时保留 Authorization: Bearer 作为兼容（旧客户端/脚本）。
const parseCookies = (header) => Object.fromEntries(
  String(header || '').split(';').map((p) => p.trim().split('=')).filter(([k, v]) => k && v !== undefined)
    .map(([k, v]) => [k, decodeURIComponent(v)])
);
const tokenFrom = (headers) => parseCookies(headers?.cookie).homecam_token || String(headers?.authorization || '').replace(/^Bearer /, '');
const cookieOptions = (req) => ({
  httpOnly: true, sameSite: 'strict', path: '/', maxAge: TOKEN_TTL_MS,
  secure: !!req.secure || String(req.headers?.['x-forwarded-proto'] || '').toLowerCase() === 'https'
});
const requireUser = (req, res, next) => {
  const auth = verify(tokenFrom(req.headers));
  if (!auth?.role || !['admin', 'member'].includes(auth.role)) return res.status(401).json({ error: 'Unauthorized' });
  req.user = auth; next();
};
const requireAdmin = (req, res, next) => req.user?.role === 'admin' ? next() : res.status(403).json({ error: '仅开发者可用' });
app.post('/api/auth/login', guard('login', LOGIN_LIMIT, 15 * 60 * 1000), (req, res) => {
  const attempt = String(req.body?.password || '');
  const role = matchPassword(attempt, adminPassword) ? 'admin' : matchPassword(attempt, memberPassword) ? 'member' : null;
  if (!role) return res.status(401).json({ error: '密码错误' });
  resetRateLimit(`login:${clientIp(req)}`);
  const token = sign({ role });
  res.cookie('homecam_token', token, cookieOptions(req));
  res.json({ token, role });  // token 字段仅为兼容旧脚本；浏览器不再落地存储
});
app.post('/api/auth/logout', requireUser, (req, res) => {
  if (req.user.jti) { db.revokedTokens.push({ jti: req.user.jti, exp: req.user.exp }); save(); }
  res.clearCookie('homecam_token', { httpOnly: true, sameSite: 'strict', path: '/', secure: cookieOptions(req).secure });
  res.json({ ok: true });
});
app.post('/api/auth/revoke-all', requireUser, requireAdmin, (req, res) => {
  db.tokenVersion = (db.tokenVersion || 0) + 1;
  db.revokedTokens = [];
  save();
  for (const [socketId, socket] of viewerSockets) if ((socket.data.tokenVer || 0) < db.tokenVersion) socket.disconnect(true);
  res.json({ ok: true, tokenVersion: db.tokenVersion });
});
app.get('/api/devices', requireUser, (_req, res) => res.json(db.devices.map(deviceView)));
app.get('/api/ice', requireUser, (_req, res) => res.json({ iceServers: activeIceServers() }));
// 运行时配置：App 启动拉取；不再公开静态 ICE/TURN 凭据（设备走信令下发）
app.get('/api/config', (_req, res) => {
  const { iceServers: _stored, ...cfg } = readRuntimeConfig();
  res.json({ ...cfg, iceServers: [] });  // 历史文件里即使残留静态凭据也绝不下发
});
app.put('/api/config', requireUser, requireAdmin, (req, res) => {
  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const patch = {};
  // iceServers 不再接受外部写入，凭据由 TURN_SECRET 动态生成
  if (body.features !== undefined) patch.features = { ...readRuntimeConfig().features, ...body.features };
  if (body.photoSettings !== undefined) patch.photoSettings = { ...readRuntimeConfig().photoSettings, ...body.photoSettings };
  if (body.captureThresholdSeconds !== undefined) patch.captureThresholdSeconds = Number(body.captureThresholdSeconds);
  if (body.ui !== undefined) patch.ui = { ...readRuntimeConfig().ui, ...body.ui };
  res.json(writeRuntimeConfig(patch));
});
// 照片按设备隔离：photos/<deviceId>/<camera>/。旧版照片在 photos/<camera>/，读取时兼容回退。
const devicePhotosDir = (deviceId, camera) => path.join(photosDir, deviceId, camera);
// 设备上传照片：raw JPEG body，用 deviceId + deviceSecret 认证；每台每类只保留最新 50 张
app.post('/api/photos', express.raw({ type: 'image/jpeg', limit: '10mb' }), (req, res) => {
  const deviceId = String(req.headers['x-device-id'] || '');
  const secret = String(req.headers['x-device-secret'] || '');
  const camera = req.headers['x-camera'] === 'front' ? 'front' : 'back';
  const device = db.devices.find((d) => d.id === deviceId);
  const secretHash = secret ? digest(secret) : '';
  if (!device || device.unpairedAt || !secret || secretHash.length !== String(device.secretHash || '').length || !safeEqual(secretHash, device.secretHash)) return res.status(401).json({ error: 'Unauthorized' });
  const body = req.body;
  if (!Buffer.isBuffer(body) || body.length < 100 || body.length > 10 * 1024 * 1024) return res.status(400).json({ error: 'Invalid image' });
  const dir = devicePhotosDir(deviceId, camera);
  fs.mkdirSync(dir, { recursive: true });
  const name = `${Date.now()}-${crypto.randomBytes(4).toString('hex')}.jpg`;
  fs.writeFileSync(path.join(dir, name), body, { mode: 0o644 });
  // 轮转：按修改时间倒序，删除第 51 张及以后
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.jpg'))
    .map((f) => ({ f, m: fs.statSync(path.join(dir, f)).mtimeMs }))
    .sort((a, b) => b.m - a.m);
  for (const old of files.slice(50)) fs.unlinkSync(path.join(dir, old.f));
  res.status(201).json({ ok: true, name, camera });
});
// 把按时序排列的照片切成连拍组：相邻超过 GAP 视为新组（连拍 300ms 间隔，组间远大于此）
const PHOTO_GROUP_GAP_MS = 5000;
function groupPhotos(list) {
  const groups = [];
  for (const p of list) {
    const last = groups[groups.length - 1];
    if (!last || p.takenAt - last[last.length - 1].takenAt > PHOTO_GROUP_GAP_MS) groups.push([p]);
    else last.push(p);
  }
  return groups;
}
// 观看端取某设备最近 N 组照片（默认每类 5 组）：每组按拍摄时间升序，封面取该组第一张。
// deviceId 必填：未选中设备时不返回照片。该设备无照片时回退旧版全局目录（历史数据兼容）。
app.get('/api/photos', requireUser, (req, res) => {
  const count = Math.min(20, Math.max(1, Number(req.query.count) || 5));
  const deviceId = String(req.query.deviceId || '');
  if (!deviceId || !db.devices.some((d) => d.id === deviceId)) return res.json({ front: [], back: [] });
  const list = (camera) => {
    const scoped = devicePhotosDir(deviceId, camera);
    const legacy = path.join(photosDir, camera);
    const dir = fs.existsSync(scoped) ? scoped : legacy;
    const urlPrefix = dir === scoped ? `/photos/${deviceId}/${camera}` : `/photos/${camera}`;
    if (!fs.existsSync(dir)) return [];
    return fs.readdirSync(dir).filter((f) => f.endsWith('.jpg'))
      .map((f) => { const st = fs.statSync(path.join(dir, f)); return { name: f, url: signedPhotoUrl(`${urlPrefix}/${f}`), takenAt: st.mtimeMs }; })
      .sort((a, b) => a.takenAt - b.takenAt);
  };
  const groupsOf = (camera) => groupPhotos(list(camera)).slice(-count).reverse()
    .map((g) => ({ cover: g[0], photos: g, takenAt: g[0].takenAt }));
  res.json({ front: groupsOf('front'), back: groupsOf('back') });
});
app.post('/api/pairing-codes', requireUser, (_req, res) => {
  db.pairingCodes = db.pairingCodes.filter((p) => p.expiresAt > Date.now());
  const code = String(crypto.randomInt(100000, 1000000));
  // 只算一次有效期：ttlMs 给观看端做本地倒计时，避免两端时钟不一致导致多/少十几秒
  const ttlMs = 10 * 60 * 1000;
  const expiresAt = Date.now() + ttlMs;
  db.pairingCodes.push({ codeHash: digest(code), expiresAt }); save();
  res.status(201).json({ code, expiresAt, ttlMs });
});
app.post('/api/devices/pair', guard('pair', PAIR_LIMIT, PAIR_WINDOW_MS), guard('pair-global', 1000, PAIR_WINDOW_MS, () => '*'), (req, res) => {
  const index = db.pairingCodes.findIndex((p) => p.expiresAt > Date.now() && p.codeHash === digest(String(req.body?.code || '')));
  if (index < 0) return res.status(400).json({ error: 'Code expired or invalid' });
  db.pairingCodes.splice(index, 1);
  const secret = crypto.randomBytes(32).toString('base64url');
  const clean = (v, max) => String(v ?? '').trim().slice(0, max);
  const device = {
    id: id(), name: String(req.body?.name || 'Home camera').slice(0, 50), createdAt: Date.now(), secretHash: digest(secret),
    brand: clean(req.body?.brand, 40), model: clean(req.body?.model, 80), osVersion: clean(req.body?.osVersion, 40)
  };
  db.devices.push(device); save();
  broadcastDevices();
  // 配对码一次性：通知所有观看端该码已消费，隐藏配对提示并显示配对成功
  io.to('viewers').emit('pairing:result', { status: 'paired', code: String(req.body?.code || ''), deviceId: device.id, name: device.name });
  resetRateLimit(`pair:${clientIp(req)}`);
  res.status(201).json({ device: publicDevice(device), deviceSecret: secret, iceServers: activeIceServers() });
});
app.patch('/api/devices/:id', requireUser, (req, res) => {
  const device = db.devices.find((d) => d.id === req.params.id);
  if (!device) return res.status(404).json({ error: '设备不存在' });
  const name = String(req.body?.name ?? '').trim().slice(0, 50);
  if (!name) return res.status(400).json({ error: '名称不能为空' });
  device.name = name; save(); broadcastDevices();
  res.json({ device: publicDevice(device) });
});
// 统一的设备移除：无论观看端删除还是手机端主动解绑，都释放会话、通知两端、清凭据。
function removeDevice(deviceId, { notifyDevice = true, reason = 'viewer' } = {}) {
  const index = db.devices.findIndex((d) => d.id === deviceId);
  if (index < 0) return false;
  db.devices.splice(index, 1); save();
  const viewerId = activeViews.get(deviceId);
  if (viewerId) { activeViews.delete(deviceId); viewerSockets.get(viewerId)?.emit('device:removed', { deviceId }); }
  // 仅手机端主动解绑时广播提示；观看端自己删除时它已知道，无需提示
  if (reason === 'device') io.to('viewers').emit('device:unpaired', { deviceId });
  const deviceSocket = deviceSockets.get(deviceId);
  if (deviceSocket) {
    if (notifyDevice) deviceSocket.emit('device:removed');
    deviceSocket.disconnect(true); deviceSockets.delete(deviceId);
  }
  broadcastDevices();
  return true;
}
app.delete('/api/devices/:id', requireUser, (req, res) => {
  if (!removeDevice(req.params.id)) return res.status(404).json({ error: '设备不存在' });
  res.json({ ok: true });
});

const httpServer = app.listen(port, () => console.log(`HomeCam listening on :${port}`));
// 定期同步最新 IPA，供 App 一键更新
// 5 分钟一次：GitHub 匿名 API 配额只有 60 次/小时，1 分钟一次会直接打满
syncLatestRelease();
setInterval(syncLatestRelease, 300000).unref();
// 配对码过期清理：观看端按 expiresAt 本地倒计时提示失效，这里只负责清库
setInterval(() => {
  const before = db.pairingCodes.length + db.revokedTokens.length;
  db.pairingCodes = db.pairingCodes.filter((p) => p.expiresAt > Date.now());
  db.revokedTokens = db.revokedTokens.filter((r) => r.exp > Date.now());
  if (db.pairingCodes.length + db.revokedTokens.length !== before) save();
}, 30000).unref();
const io = new Server(httpServer, { cors: { origin: false } });
const deviceSockets = new Map();
const viewerSockets = new Map();
const activeViews = new Map();
// 设备连接代次：网络切换重连会递增代次，断开时的释放定时器只在自己代次仍最新时才生效，
// 避免「旧断开留下的定时器」把已重连并恢复的会话误释放。
const deviceGen = new Map();
const resumeTimers = new Map();  // 设备 -> 最近一次下发恢复通知的时间，用于去抖
const RESUME_DEBOUNCE_MS = 4000;
const deviceStatus = (deviceId, status) => io.to('viewers').emit('device:status', { deviceId, status });
// status 事件只作为轻量提示；权威状态走 devices 列表广播
const notify = (deviceId, status) => { deviceStatus(deviceId, status); broadcastDevices(); };

io.use((socket, next) => {
  const auth = verify(tokenFrom(socket.handshake.headers) || socket.handshake.auth?.token);
  if (auth?.role === 'admin' || auth?.role === 'member') { socket.data.role = 'viewer'; socket.data.viewerRole = auth.role; socket.data.tokenVer = auth.ver || 0; return next(); }
  // The Swift Socket.IO client supplies credentials as connection parameters;
  // browser and Android clients use the Socket.IO auth object.
  const deviceId = socket.handshake.auth?.deviceId ?? socket.handshake.query?.deviceId;
  const secret = socket.handshake.auth?.deviceSecret ?? socket.handshake.query?.deviceSecret;
  const device = db.devices.find((d) => d.id === deviceId);
  const secretHash = secret ? digest(secret) : '';
  if (device && !device.unpairedAt && secretHash.length === String(device.secretHash || '').length && safeEqual(secretHash, device.secretHash)) { socket.data.role = 'device'; socket.data.deviceId = deviceId; return next(); }
  next(new Error('Unauthorized'));
});
io.on('connection', (socket) => {
  if (socket.data.role === 'viewer') {
    socket.join('viewers'); viewerSockets.set(socket.id, socket);
    socket.emit('devices', db.devices.map(deviceView));
  } else {
    const deviceId = socket.data.deviceId;
    deviceSockets.set(deviceId, socket); notify(deviceId, 'idle');
    const gen = (deviceGen.get(deviceId) || 0) + 1;
    deviceGen.set(deviceId, gen);
    console.log(`[device] connected ${deviceId} gen=${gen} activeViews=${activeViews.has(deviceId)}`);
    // 重连且会话仍在：主动通知设备重建 peer 并重新协商（去抖，避免连续下发打断正在建立的连接）
    const activeViewerId = activeViews.get(deviceId);
    if (activeViewerId) {
      const last = resumeTimers.get(deviceId) || 0;
      if (Date.now() - last > RESUME_DEBOUNCE_MS) {
        resumeTimers.set(deviceId, Date.now());
        console.log(`[device] ${deviceId} resumed with viewer ${activeViewerId}`);
        socket.emit('watch:resumed', { viewerId: activeViewerId, iceServers: activeIceServers() });
        viewerSockets.get(activeViewerId)?.emit('watch:resume', { deviceId });
      } else {
        console.log(`[device] ${deviceId} resume suppressed (debounce)`);
      }
    }
  }
  socket.on('watch:start', ({ deviceId }, callback = () => {}) => {
    if (socket.data.role !== 'viewer') return callback({ error: 'Unauthorized' });
    const device = deviceSockets.get(deviceId);
    if (!device) return callback({ error: 'Device is offline' });
    if (activeViews.has(deviceId)) return callback({ error: 'Device is already being watched' });
    activeViews.set(deviceId, socket.id); device.emit('watch:start', { viewerId: socket.id, iceServers: activeIceServers() }); deviceStatus(deviceId, 'connecting'); callback({ ok: true });
  });
  socket.on('watch:accepted', ({ viewerId }) => {
    if (socket.data.role === 'device' && activeViews.get(socket.data.deviceId) === viewerId) viewerSockets.get(viewerId)?.emit('watch:accepted', { deviceId: socket.data.deviceId });
  });
  socket.on('device:diagnostic', ({ message }) => {
    if (socket.data.role !== 'device') return;
    io.to('viewers').emit('device:diagnostic', { deviceId: socket.data.deviceId, message: String(message || '').slice(0, 300) });
  });
  // 手机端主动「停止配对」：不再删除设备，改为标记失效；观看端保留卡片并标注「已失效·手机端已解绑」
  socket.on('device:unpair', () => {
    if (socket.data.role !== 'device') return;
    const deviceId = socket.data.deviceId;
    console.log(`[device] ${deviceId} self-unpaired`);
    const device = db.devices.find((d) => d.id === deviceId);
    if (device) { device.unpairedAt = Date.now(); save(); }
    const viewerId = activeViews.get(deviceId);
    if (viewerId) { activeViews.delete(deviceId); viewerSockets.get(viewerId)?.emit('device:removed', { deviceId }); }
    deviceSockets.delete(deviceId);
    io.to('viewers').emit('device:unpaired', { deviceId, name: device?.name || '' });
    broadcastDevices();
    socket.disconnect(true);  // 解绑后旧连接不能继续发 signal/state
  });
  socket.on('camera:switch', ({ deviceId }) => {
    if (socket.data.role !== 'viewer' || activeViews.get(deviceId) !== socket.id) return;
    deviceSockets.get(deviceId)?.emit('camera:switch');
  });
  socket.on('signal', ({ targetId, data }) => {
    if (!targetId || !data || typeof data !== 'object') return;
    let target;
    if (socket.data.role === 'viewer') {
      // 只能给「自己正在观看的设备」发信令，不能向他人会话注入 SDP
      if (activeViews.get(targetId) !== socket.id) return;
      target = deviceSockets.get(targetId);
    } else if (socket.data.role === 'device') {
      // 设备只能回给当前持有会话的那个观看端
      if (activeViews.get(socket.data.deviceId) !== targetId) return;
      target = viewerSockets.get(targetId);
    } else return;
    // 观看端按 deviceId 校验来源；socket.id 与配对生成的 deviceId 不同，必须发业务 id
    const fromId = socket.data.role === 'device' ? socket.data.deviceId : socket.id;
    target?.emit('signal', { fromId, data });
  });
  const stop = (deviceId, viewerId) => {
    // viewerId 为空（已释放/重复 idle 上报）直接返回，避免 idle↔watch:stop 死循环
    if (!deviceId || !viewerId || activeViews.get(deviceId) !== viewerId) return;
    activeViews.delete(deviceId); deviceSockets.get(deviceId)?.emit('watch:stop'); viewerSockets.get(viewerId)?.emit('watch:stopped', { deviceId }); notify(deviceId, 'idle');
  };
  socket.on('watch:stop', ({ deviceId }) => stop(deviceId, socket.id));
  // 设备因网络切换（WiFi↔蜂窝）重连后请求恢复观看会话：把当前 viewerId 回传，
  // 由设备重建 peer 并重新协商（ICE restart 在非 trickle 下不可靠）。
  socket.on('watch:resume', () => {
    if (socket.data.role !== 'device') return;
    // 只认连接认证出的设备，忽略客户端传来的 deviceId，防止跨设备探测/干扰他人会话
    const target = socket.data.deviceId;
    const viewerId = activeViews.get(target);
    if (!viewerId) {
      // 会话已释放：不要给设备发 watch:stop（那会彻底终止），让它继续等待并重试
      console.log(`[device] ${target} resume requested but no active session`);
      return;
    }
    const last = resumeTimers.get(target) || 0;
    if (Date.now() - last <= RESUME_DEBOUNCE_MS) { console.log(`[device] ${target} resume suppressed (debounce)`); return; }
    resumeTimers.set(target, Date.now());
    console.log(`[device] ${target} resume -> viewer ${viewerId}`);
    socket.emit('watch:resumed', { viewerId, iceServers: activeIceServers() });
    viewerSockets.get(viewerId)?.emit('watch:resume', { deviceId: target });
  });
  socket.on('stream:state', ({ state }) => {
    if (socket.data.role !== 'device') return;
    deviceStatus(socket.data.deviceId, state);
    // The device stops capture on its own (e.g. iOS enters background). Release the
    // reservation so the viewer is notified and a later watch attempt is not blocked.
    if (state === 'idle') stop(socket.data.deviceId, activeViews.get(socket.data.deviceId));
    broadcastDevices();
  });
  socket.on('disconnect', () => {
    if (socket.data.role === 'device') {
      // 网络切换（WiFi↔蜂窝）会短暂断线：延迟释放会话，期间重连则保留
      const deviceId = socket.data.deviceId;
      deviceSockets.delete(deviceId);
      const viewerId = activeViews.get(deviceId);
      if (viewerId) {
        const myGen = deviceGen.get(deviceId) || 0;
        console.log(`[device] ${deviceId} disconnected (gen=${myGen}), hold session ${viewerId} for 120s`);
        setTimeout(() => {
          // 仅当自己仍是最新的代次、且设备此刻确实离线、且会话没变时才释放
          const curGen = deviceGen.get(deviceId) || 0;
          if (curGen !== myGen) { console.log(`[device] ${deviceId} gen changed ${myGen}->${curGen}, session kept`); return; }
          if (deviceSockets.has(deviceId)) { console.log(`[device] ${deviceId} reconnected in time, session kept`); return; }
          if (activeViews.get(deviceId) !== viewerId) { console.log(`[device] ${deviceId} session already changed, skip`); return; }
          console.log(`[device] ${deviceId} still offline, keeping reservation; final release in 120s`);
          notify(deviceId, 'offline');
          // 再等一轮仍未重连才真正释放，避免设备长期离线占住设备
          setTimeout(() => {
            const g2 = deviceGen.get(deviceId) || 0;
            if (g2 !== myGen || deviceSockets.has(deviceId)) return;
            if (activeViews.get(deviceId) !== viewerId) return;
            console.log(`[device] ${deviceId} final release of session ${viewerId}`);
            stop(deviceId, viewerId);
          }, 120000);
        }, 120000);
      } else {
        notify(deviceId, 'offline');
      }
    }
    if (socket.data.role === 'viewer') { viewerSockets.delete(socket.id); for (const [deviceId, viewerId] of activeViews) if (viewerId === socket.id) stop(deviceId, viewerId); }
  });
});
