import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
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
const adminPassword = process.env.ADMIN_PASSWORD;
const tokenSecret = process.env.TOKEN_SECRET;
if (!adminPassword || !tokenSecret) throw new Error('ADMIN_PASSWORD and TOKEN_SECRET must be set in .env');
let iceServers;
try { iceServers = JSON.parse(process.env.ICE_SERVERS || '[{"urls":["stun:stun.l.google.com:19302"]}]'); } catch { throw new Error('ICE_SERVERS must be valid JSON'); }
fs.mkdirSync(dataDir, { recursive: true });
fs.mkdirSync(path.join(photosDir, 'front'), { recursive: true });
fs.mkdirSync(path.join(photosDir, 'back'), { recursive: true });
let db = fs.existsSync(dbFile) ? JSON.parse(fs.readFileSync(dbFile, 'utf8')) : { devices: [], pairingCodes: [] };
const save = () => fs.writeFileSync(dbFile, JSON.stringify(db, null, 2), { mode: 0o600 });
const id = () => crypto.randomUUID();
const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');
const safeEqual = (a, b) => crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
const sign = (payload) => {
  const body = Buffer.from(JSON.stringify({ ...payload, exp: Date.now() + 30 * 24 * 60 * 60 * 1000 })).toString('base64url');
  return `${body}.${crypto.createHmac('sha256', tokenSecret).update(body).digest('base64url')}`;
};
const verify = (token) => {
  const [body, signature] = String(token || '').split('.');
  if (!body || !signature) return null;
  const expected = crypto.createHmac('sha256', tokenSecret).update(body).digest('base64url');
  if (expected.length !== signature.length || !safeEqual(expected, signature)) return null;
  try { const value = JSON.parse(Buffer.from(body, 'base64url')); return value.exp > Date.now() ? value : null; } catch { return null; }
};
const publicDevice = ({ secretHash, ...device }) => device;
// 运行时配置：存在 data/runtime-config.json，改文件或调 PUT 接口即生效，无需重启、无需重装 App
const defaultRuntimeConfig = {
  schemaVersion: 1,
  iceServers: null,          // null = 用服务端 .env 的 ICE_SERVERS
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
// 统一设备状态视图：所有下发到观看端的列表都带 online/status，避免状态错乱
function deviceView(d) {
  return { ...publicDevice(d), online: deviceSockets.has(d.id), status: activeViews.has(d.id) ? 'streaming' : (deviceSockets.has(d.id) ? 'idle' : 'offline') };
}
function broadcastDevices() { io.to('viewers').emit('devices', db.devices.map(deviceView)); }

const app = express();
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
  let html = fs.readFileSync(path.join(root, 'web', 'index.html'), 'utf8');
  html = html.replace('</head>', `<meta name="web-version" content="${webVersion()}">\n</head>`);
  res.set('Cache-Control', 'no-store').type('html').send(html);
});
app.get('/api/web-version', (_req, res) => res.json({ version: webVersion() }));
app.use(express.static(path.join(root, 'web')));
app.use('/photos', express.static(photosDir, { maxAge: 0, index: false }));
const requireUser = (req, res, next) => {
  const auth = verify(req.headers.authorization?.replace(/^Bearer /, ''));
  if (!auth?.role || auth.role !== 'viewer') return res.status(401).json({ error: 'Unauthorized' });
  req.user = auth; next();
};
app.post('/api/auth/login', (req, res) => {
  const attempt = String(req.body?.password || '');
  if (attempt.length !== adminPassword.length || !safeEqual(attempt, adminPassword)) return res.status(401).json({ error: 'Incorrect password' });
  res.json({ token: sign({ role: 'viewer' }) });
});
app.get('/api/devices', requireUser, (_req, res) => res.json(db.devices.map(deviceView)));
app.get('/api/ice', requireUser, (_req, res) => res.json({ iceServers }));
// 运行时配置：App 启动拉取；管理员可改，改完立即生效
app.get('/api/config', (_req, res) => {
  const cfg = readRuntimeConfig();
  res.json({ ...cfg, iceServers: cfg.iceServers || iceServers });
});
app.put('/api/config', requireUser, (req, res) => {
  const body = req.body && typeof req.body === 'object' ? req.body : {};
  const patch = {};
  if (body.iceServers !== undefined) patch.iceServers = body.iceServers;
  if (body.features !== undefined) patch.features = { ...readRuntimeConfig().features, ...body.features };
  if (body.photoSettings !== undefined) patch.photoSettings = { ...readRuntimeConfig().photoSettings, ...body.photoSettings };
  if (body.captureThresholdSeconds !== undefined) patch.captureThresholdSeconds = Number(body.captureThresholdSeconds);
  if (body.ui !== undefined) patch.ui = { ...readRuntimeConfig().ui, ...body.ui };
  res.json(writeRuntimeConfig(patch));
});
// 设备上传照片：raw JPEG body，用 deviceId + deviceSecret 认证；每类只保留最新 50 张
app.post('/api/photos', express.raw({ type: 'image/jpeg', limit: '10mb' }), (req, res) => {
  const deviceId = String(req.headers['x-device-id'] || '');
  const secret = String(req.headers['x-device-secret'] || '');
  const camera = req.headers['x-camera'] === 'front' ? 'front' : 'back';
  const device = db.devices.find((d) => d.id === deviceId);
  if (!device || !secret || digest(secret) !== device.secretHash) return res.status(401).json({ error: 'Unauthorized' });
  const body = req.body;
  if (!Buffer.isBuffer(body) || body.length < 100 || body.length > 10 * 1024 * 1024) return res.status(400).json({ error: 'Invalid image' });
  const dir = path.join(photosDir, camera);
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
// 观看端取最近 N 张照片元信息（默认每类 5 张）
app.get('/api/photos', requireUser, (req, res) => {
  const count = Math.min(20, Math.max(1, Number(req.query.count) || 5));
  const list = (camera) => {
    const dir = path.join(photosDir, camera);
    if (!fs.existsSync(dir)) return [];
    return fs.readdirSync(dir).filter((f) => f.endsWith('.jpg'))
      .map((f) => { const st = fs.statSync(path.join(dir, f)); return { name: f, url: `/photos/${camera}/${f}`, takenAt: st.mtimeMs }; })
      .sort((a, b) => b.takenAt - a.takenAt).slice(0, count);
  };
  res.json({ front: list('front'), back: list('back') });
});
app.post('/api/pairing-codes', requireUser, (_req, res) => {
  db.pairingCodes = db.pairingCodes.filter((p) => p.expiresAt > Date.now());
  const code = String(crypto.randomInt(100000, 1000000));
  db.pairingCodes.push({ codeHash: digest(code), expiresAt: Date.now() + 10 * 60 * 1000 }); save();
  res.status(201).json({ code, expiresAt: Date.now() + 10 * 60 * 1000 });
});
app.post('/api/devices/pair', (req, res) => {
  const index = db.pairingCodes.findIndex((p) => p.expiresAt > Date.now() && p.codeHash === digest(String(req.body?.code || '')));
  if (index < 0) return res.status(400).json({ error: 'Code expired or invalid' });
  db.pairingCodes.splice(index, 1);
  const secret = crypto.randomBytes(32).toString('base64url');
  const device = { id: id(), name: String(req.body?.name || 'Home camera').slice(0, 50), createdAt: Date.now(), secretHash: digest(secret) };
  db.devices.push(device); save();
  broadcastDevices();
  res.status(201).json({ device: publicDevice(device), deviceSecret: secret, iceServers });
});
app.patch('/api/devices/:id', requireUser, (req, res) => {
  const device = db.devices.find((d) => d.id === req.params.id);
  if (!device) return res.status(404).json({ error: '设备不存在' });
  const name = String(req.body?.name ?? '').trim().slice(0, 50);
  if (!name) return res.status(400).json({ error: '名称不能为空' });
  device.name = name; save(); broadcastDevices();
  res.json({ device: publicDevice(device) });
});
app.delete('/api/devices/:id', requireUser, (req, res) => {
  const index = db.devices.findIndex((d) => d.id === req.params.id);
  if (index < 0) return res.status(404).json({ error: '设备不存在' });
  const deviceId = req.params.id;
  db.devices.splice(index, 1); save();
  // 释放观看会话，通知观看端停止；通知设备端清除本地配对
  const viewerId = activeViews.get(deviceId);
  if (viewerId) { activeViews.delete(deviceId); viewerSockets.get(viewerId)?.emit('device:removed', { deviceId }); }
  const deviceSocket = deviceSockets.get(deviceId);
  if (deviceSocket) { deviceSocket.emit('device:removed'); deviceSocket.disconnect(true); deviceSockets.delete(deviceId); }
  broadcastDevices();
  res.json({ ok: true });
});

const httpServer = app.listen(port, () => console.log(`HomeCam listening on :${port}`));
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
  const auth = verify(socket.handshake.auth?.token);
  if (auth?.role === 'viewer') { socket.data.role = 'viewer'; return next(); }
  // The Swift Socket.IO client supplies credentials as connection parameters;
  // browser and Android clients use the Socket.IO auth object.
  const deviceId = socket.handshake.auth?.deviceId ?? socket.handshake.query?.deviceId;
  const secret = socket.handshake.auth?.deviceSecret ?? socket.handshake.query?.deviceSecret;
  const device = db.devices.find((d) => d.id === deviceId);
  if (device && secret && digest(secret) === device.secretHash) { socket.data.role = 'device'; socket.data.deviceId = deviceId; return next(); }
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
        socket.emit('watch:resumed', { viewerId: activeViewerId, iceServers });
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
    activeViews.set(deviceId, socket.id); device.emit('watch:start', { viewerId: socket.id, iceServers }); deviceStatus(deviceId, 'connecting'); callback({ ok: true });
  });
  socket.on('watch:accepted', ({ viewerId }) => {
    if (socket.data.role === 'device' && activeViews.get(socket.data.deviceId) === viewerId) viewerSockets.get(viewerId)?.emit('watch:accepted', { deviceId: socket.data.deviceId });
  });
  socket.on('device:diagnostic', ({ deviceId, message }) => {
    if (socket.data.role !== 'device') return;
    io.to('viewers').emit('device:diagnostic', { deviceId, message: String(message || '').slice(0, 300) });
  });
  socket.on('camera:switch', ({ deviceId }) => {
    if (socket.data.role !== 'viewer' || activeViews.get(deviceId) !== socket.id) return;
    deviceSockets.get(deviceId)?.emit('camera:switch');
  });
  socket.on('signal', ({ targetId, data }) => {
    if (!targetId || !data) return;
    const target = socket.data.role === 'device' ? viewerSockets.get(targetId) : deviceSockets.get(targetId);
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
  socket.on('watch:resume', ({ deviceId }) => {
    if (socket.data.role !== 'device') return;
    const target = deviceId || socket.data.deviceId;
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
    socket.emit('watch:resumed', { viewerId, iceServers });
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
