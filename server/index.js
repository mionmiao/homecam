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
const dbFile = path.join(dataDir, 'homecam.json');
const adminPassword = process.env.ADMIN_PASSWORD;
const tokenSecret = process.env.TOKEN_SECRET;
if (!adminPassword || !tokenSecret) throw new Error('ADMIN_PASSWORD and TOKEN_SECRET must be set in .env');
let iceServers;
try { iceServers = JSON.parse(process.env.ICE_SERVERS || '[{"urls":["stun:stun.l.google.com:19302"]}]'); } catch { throw new Error('ICE_SERVERS must be valid JSON'); }
fs.mkdirSync(dataDir, { recursive: true });
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
// 统一设备状态视图：所有下发到观看端的列表都带 online/status，避免状态错乱
function deviceView(d) {
  return { ...publicDevice(d), online: deviceSockets.has(d.id), status: activeViews.has(d.id) ? 'streaming' : (deviceSockets.has(d.id) ? 'idle' : 'offline') };
}
function broadcastDevices() { io.to('viewers').emit('devices', db.devices.map(deviceView)); }

const app = express();
app.use(express.json());
app.use(express.static(path.join(root, 'web')));
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
    if (!deviceId || activeViews.get(deviceId) !== viewerId) return;
    activeViews.delete(deviceId); deviceSockets.get(deviceId)?.emit('watch:stop'); viewerSockets.get(viewerId)?.emit('watch:stopped', { deviceId }); notify(deviceId, 'idle');
  };
  socket.on('watch:stop', ({ deviceId }) => stop(deviceId, socket.id));
  socket.on('stream:state', ({ state }) => {
    if (socket.data.role !== 'device') return;
    deviceStatus(socket.data.deviceId, state);
    // The device stops capture on its own (e.g. iOS enters background). Release the
    // reservation so the viewer is notified and a later watch attempt is not blocked.
    if (state === 'idle') stop(socket.data.deviceId, activeViews.get(socket.data.deviceId));
    broadcastDevices();
  });
  socket.on('disconnect', () => {
    if (socket.data.role === 'device') { deviceSockets.delete(socket.data.deviceId); const viewerId = activeViews.get(socket.data.deviceId); stop(socket.data.deviceId, viewerId); notify(socket.data.deviceId, 'offline'); }
    if (socket.data.role === 'viewer') { viewerSockets.delete(socket.id); for (const [deviceId, viewerId] of activeViews) if (viewerId === socket.id) stop(deviceId, viewerId); }
  });
});
