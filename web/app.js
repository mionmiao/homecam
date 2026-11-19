const $ = (selector) => document.querySelector(selector);
let token = localStorage.getItem('homecam-token'); let socket; let selected; let peer; let recorder; let chunks = []; let recTimer = null; let recStart = 0; let watching = false; let pendingCandidates = []; let resumeTimer = null;
const ui = { login: $('#login'), dashboard: $('#dashboard'), error: $('#loginError'), devices: $('#devices'), video: $('#video'), placeholder: $('#placeholder'), status: $('#watchStatus'), connection: $('#connection'), watch: $('#watchButton'), stop: $('#stopButton'), mute: $('#muteButton'), record: $('#recordButton'), password: $('#password'), switchCamera: $('#switchCameraButton'), fullscreen: $('#fullscreenButton'), recBadge: $('#recBadge'), recTime: $('#recTime'), videoWrap: $('#videoWrap') };
const view = { rotation: 0, zoom: 1, mirrored: false, exposure: 0 }; // exposure in EV (stops)
function applyView() {
  ui.video.style.transform = `rotate(${view.rotation}deg) scale(${view.zoom}) scaleX(${view.mirrored ? -1 : 1})`;
  ui.video.style.filter = `brightness(${Math.pow(2, view.exposure)})`;
  const ev = view.exposure;
  $('#exposureInfo').textContent = `${ev > 0 ? '+' : ''}${ev.toFixed(1)} EV`;
  $('#viewInfo').textContent = `${Math.round(view.zoom * 100)}%${view.mirrored ? ' 镜像' : ''}${view.rotation ? ' ' + view.rotation + '°' : ''}`;
}
function resetView() { view.rotation = 0; view.zoom = 1; view.mirrored = false; view.exposure = 0; $('#exposure').value = 0; applyView(); }
const authHeaders = () => ({ 'Content-Type': 'application/json', Authorization: `Bearer ${token}` });
function expire() { localStorage.removeItem('homecam-token'); sessionStorage.setItem('homecam-expired', '1'); location.reload(); }
async function api(url, options = {}) { const response = await fetch(url, { ...options, headers: { ...authHeaders(), ...options.headers } }); if (response.status === 401) { expire(); throw new Error('登录已过期'); } if (!response.ok) throw new Error((await response.json()).error || '请求失败'); return response.json(); }
function setWatchUi(active) { watching = active; ui.watch.disabled = !selected || active; ui.stop.disabled = !active; ui.mute.disabled = !active; ui.record.disabled = !active; ui.switchCamera.disabled = !active; ui.fullscreen.disabled = !active; ui.placeholder.hidden = active; }
function statusLabel(status) {
  return ({ streaming: '观看中', connecting: '连接中', idle: '待命', offline: '离线', started: '连接中', live: '观看中', active: '观看中' })[status] || '待命';
}
function select(device) { selected = device; document.querySelectorAll('.device').forEach((e) => e.classList.toggle('selected', e.dataset.id === device.id)); ui.status.textContent = `${device.name}：${statusLabel(device.status)}`; setWatchUi(false); }
function renderDevices(devices) {
  if (selected && !devices.some((d) => d.id === selected.id)) { selected = null; cleanup(); }
  ui.devices.innerHTML = '';
  devices.forEach((device) => {
    const el = document.createElement('article'); el.className = 'device'; el.dataset.id = device.id;
    el.innerHTML = `<div class="device-info"><strong>${escapeHtml(device.name)}</strong><p class="status">${statusLabel(device.status)}</p><small>${new Date(device.createdAt).toLocaleDateString()}</small></div><div class="device-actions"><button class="ghost rename" title="重命名">重命名</button><button class="ghost danger remove" title="删除">删除</button></div>`;
    el.querySelector('.device-info').onclick = () => select(device);
    el.querySelector('.rename').onclick = () => renameDevice(device);
    el.querySelector('.remove').onclick = () => removeDevice(device);
    ui.devices.append(el);
  });
  if (selected) document.querySelectorAll('.device').forEach((e) => e.classList.toggle('selected', e.dataset.id === selected.id));
}
function escapeHtml(value) { const div = document.createElement('div'); div.textContent = value; return div.innerHTML; }
async function loadDevices() { renderDevices(await api('/api/devices')); }
async function renameDevice(device) { const name = prompt('设备新名称（最多 50 字）', device.name); if (name === null) return; try { await api(`/api/devices/${encodeURIComponent(device.id)}`, { method: 'PATCH', body: JSON.stringify({ name }) }); await loadDevices(); } catch (e) { alert(e.message); } }
async function removeDevice(device) { if (!confirm(`删除设备「${device.name}」？\n手机端会收到通知并解除配对，需要重新配对才能使用。`)) return; try { await api(`/api/devices/${encodeURIComponent(device.id)}`, { method: 'DELETE' }); if (selected?.id === device.id) { selected = null; cleanup(); } await loadDevices(); } catch (e) { alert(e.message); } }
function connect() { socket = io({ auth: { token } }); socket.on('connect', () => { ui.connection.textContent = '已连接'; loadDevices(); }); socket.on('connect_error', (err) => { if (err?.message === 'Unauthorized') return expire(); ui.connection.textContent = '连接失败'; }); socket.on('devices', renderDevices); socket.on('device:status', ({ deviceId, status }) => { if (selected?.id === deviceId) { selected.status = status; ui.status.textContent = `${selected.name}：${statusLabel(status)}`; } loadDevices(); }); socket.on('watch:accepted', ({ deviceId }) => { if (deviceId !== selected?.id) return; appendDiag('手机已接受，等待其 offer'); }); socket.on('signal', async ({ fromId, data }) => receiveSignal(fromId, data)); socket.on('watch:stopped', () => cleanup()); socket.on('watch:resume', ({ deviceId }) => { if (deviceId !== selected?.id) return; appendDiag('手机网络切换，准备重新协商'); setWatchUi(true); ui.status.textContent = '手机网络切换中，正在重连…'; clearTimeout(resumeTimer); resumeTimer = setTimeout(() => { if (peer && peer.connectionState !== 'connected') { appendDiag('重建前清理旧连接'); cleanup(); setWatchUi(true); } }, 3000); }); socket.on('device:removed', ({ deviceId }) => { if (selected?.id === deviceId) { selected = null; cleanup(); } loadDevices(); }); socket.on('device:diagnostic', ({ deviceId, message }) => { if (deviceId === selected?.id) appendDiag('手机端: ' + message); }); }
function initPeer(iceServers) { peer = new RTCPeerConnection({ iceServers }); pendingCandidates = []; appendDiag(`ICE servers: ${iceServers.map(s => (Array.isArray(s.urls) ? s.urls : [s.urls]).join(',')).join(' | ')}`); peer.onicecandidate = ({ candidate }) => { if (candidate) { const t = (candidate.type || '').toLowerCase(); appendDiag(`my candidate: ${t || '?'} ${String(candidate.candidate).slice(0, 40)}`); socket.emit('signal', { targetId: selected.id, data: { type: 'candidate', candidate } }); } }; peer.ontrack = ({ streams }) => { ui.video.srcObject = streams[0]; ui.status.textContent = '正在观看'; appendDiag('ontrack: 收到媒体流'); }; peer.onconnectionstatechange = () => { const s = peer?.connectionState; appendDiag(`peer: ${s}`); if (s === 'closed') cleanup(); else if (s === 'failed' || s === 'disconnected') setTimeout(() => { if (peer && (peer.connectionState === 'failed' || peer.connectionState === 'disconnected')) { appendDiag('ICE 断开超时，清理'); cleanup(); } }, 25000); }; peer.oniceconnectionstatechange = () => appendDiag(`ice: ${peer.iceConnectionState}`); }
async function handleOffer(sdp) {
  const isRestart = !!peer && peer.signalingState !== 'closed';
  appendDiag(`${isRestart ? 'ICE restart offer' : 'offer'} received: ${(sdp.match(/a=candidate/g) || []).length} candidates`);
  if (!isRestart) { const { iceServers } = await api('/api/ice'); initPeer(iceServers); }
  await peer.setRemoteDescription({ type: 'offer', sdp });
  for (const c of pendingCandidates) await peer.addIceCandidate(c); pendingCandidates = [];
  const answer = await peer.createAnswer();
  await peer.setLocalDescription(answer);
  // non-trickle：等 ICE 收集完成，candidate 内嵌进 SDP 一次性发出
  if (peer.iceGatheringState !== 'complete') await new Promise((resolve) => { const timer = setTimeout(resolve, 8000); peer.onicegatheringstatechange = () => { if (peer.iceGatheringState === 'complete') { clearTimeout(timer); resolve(); } }; });
  const answerSdp = peer.localDescription?.sdp || answer.sdp;
  appendDiag(`sending answer: ${(answerSdp.match(/a=candidate/g) || []).length} candidates`);
  socket.emit('signal', { targetId: selected.id, data: { type: 'answer', sdp: answerSdp } });
}
function appendDiag(msg) { const box = document.getElementById('diag'); if (!box) return; const line = document.createElement('div'); line.textContent = `[${new Date().toLocaleTimeString()}] ${msg}`; box.prepend(line); }
// 观看端自动更新：轮询 web 资源指纹，未在观看时自动刷新；正在观看则提示用户
const currentWebVersion = document.querySelector('meta[name="web-version"]')?.content || '';
let updateDismissed = false;
async function checkWebVersion() {
  try {
    const res = await fetch('/api/web-version', { cache: 'no-store' });
    if (!res.ok) return;
    const { version } = await res.json();
    if (!version || version === currentWebVersion) return;
    const banner = document.getElementById('updateBanner');
    if (!banner) return;
    // 正在观看：不能自动刷新（会断流），提示用户手动刷新
    if (watching || peer) {
      banner.hidden = false;
      if (!updateDismissed) appendDiag('观看端有新版本，停止观看后会自动刷新');
      return;
    }
    location.reload();
  } catch { /* 网络波动忽略 */ }
}
setInterval(checkWebVersion, 20000);

async function loadPhotos() {
  try {
    const data = await api('/api/photos?count=5');
    for (const [camera, elId] of [['back', 'backPhotos'], ['front', 'frontPhotos']]) {
      const box = document.getElementById(elId); if (!box) continue;
      const list = data[camera] || [];
      box.innerHTML = list.length ? '' : '<span class="photo-empty">暂无照片</span>';
      for (const p of list) {
        const fig = document.createElement('figure'); fig.className = 'photo';
        const img = document.createElement('img'); img.src = p.url; img.alt = new Date(p.takenAt).toLocaleString(); img.loading = 'lazy';
        img.onclick = () => window.open(p.url, '_blank');
        const cap = document.createElement('figcaption'); cap.textContent = new Date(p.takenAt).toLocaleString();
        fig.append(img, cap); box.append(fig);
      }
    }
  } catch (e) { appendDiag('照片加载失败: ' + e.message); }
}
function copyDiag() {
  const box = document.getElementById('diag'); if (!box) return;
  const text = [...box.children].map(e => e.textContent).reverse().join('\n') || '(暂无日志)';
  const done = () => { const b = document.getElementById('copyDiagButton'); b.textContent = '已复制'; setTimeout(() => b.textContent = '复制全部', 1500); };
  if (navigator.clipboard?.writeText) navigator.clipboard.writeText(text).then(done).catch(() => fallbackCopy(text, done));
  else fallbackCopy(text, done);
}
function fallbackCopy(text, done) { const ta = document.createElement('textarea'); ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0'; document.body.append(ta); ta.select(); try { document.execCommand('copy'); done(); } catch { alert(text); } ta.remove(); }
document.getElementById('diagBox')?.querySelector('summary')?.addEventListener('click', (e) => { if (e.target.id === 'copyDiagButton') e.preventDefault(); });
async function receiveSignal(fromId, data) { if (fromId !== selected?.id) return; if (data.type === 'offer') await handleOffer(data.sdp); else if (data.type === 'candidate') { if (peer?.remoteDescription) await peer.addIceCandidate(data.candidate); else pendingCandidates.push(data.candidate); } }
function cleanup() { recorder?.state === 'recording' && recorder.stop(); recorder = null; stopRecUi(); peer?.close(); peer = null; pendingCandidates = []; ui.video.srcObject = null; resetView(); setWatchUi(false); ui.status.textContent = selected ? `${selected.name}：已停止` : '待命'; setTimeout(checkWebVersion, 500); }
async function login() { try { const data = await fetch('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: $('#password').value }) }).then(async (r) => { if (!r.ok) throw new Error('密码错误'); return r.json(); }); token = data.token; localStorage.setItem('homecam-token', token); ui.error.textContent = ''; ui.login.hidden = true; ui.dashboard.hidden = false; connect(); loadPhotos(); } catch (e) { ui.error.textContent = e.message; } }
function logout() { cleanup(); socket?.disconnect(); socket = null; selected = null; token = null; localStorage.removeItem('homecam-token'); ui.devices.innerHTML = ''; ui.connection.textContent = '未登录'; ui.password.value = ''; ui.error.textContent = ''; ui.dashboard.hidden = true; ui.login.hidden = false; }
$('#loginButton').onclick = login;
$('#password').addEventListener('keydown', (e) => { if (e.key === 'Enter') login(); });
$('#togglePassword').onclick = () => { const input = $('#password'); const show = input.type === 'password'; input.type = show ? 'text' : 'password'; $('#togglePassword').textContent = show ? '隐藏' : '显示'; };
$('#logoutButton').onclick = logout;
$('#copyDiagButton').onclick = copyDiag;
$('#pairButton').onclick = async () => { try { const { code } = await api('/api/pairing-codes', { method: 'POST' }); const notice = $('#pairing'); notice.hidden = false; notice.textContent = `在手机摄像头应用输入此配对码：${code}（10 分钟有效）`; } catch (e) { alert(e.message); } };
$('#refreshButton').onclick = loadDevices;
ui.watch.onclick = () => socket.emit('watch:start', { deviceId: selected.id }, (reply) => { if (reply.error) return alert(reply.error); setWatchUi(true); ui.status.textContent = '正在连接手机…'; });
ui.stop.onclick = () => { if (selected) socket.emit('watch:stop', { deviceId: selected.id }); cleanup(); };
$('#switchCameraButton').onclick = () => { if (selected && watching) { socket.emit('camera:switch', { deviceId: selected.id }); appendDiag('已发送切换摄像头指令'); } };
$('#rotateButton').onclick = () => { view.rotation = (view.rotation + 90) % 360; applyView(); };
$('#zoomInButton').onclick = () => { view.zoom = Math.min(3, +(view.zoom + 0.2).toFixed(2)); applyView(); };
$('#zoomOutButton').onclick = () => { view.zoom = Math.max(0.5, +(view.zoom - 0.2).toFixed(2)); applyView(); };
$('#mirrorButton').onclick = () => { view.mirrored = !view.mirrored; applyView(); };
$('#resetViewButton').onclick = resetView;
$('#exposure').oninput = (e) => { view.exposure = +e.target.value; applyView(); };
ui.mute.onclick = () => { ui.video.muted = !ui.video.muted; ui.mute.textContent = ui.video.muted ? '打开声音' : '静音'; };
function updateRecTime() { const s = Math.floor((Date.now() - recStart) / 1000); ui.recTime.textContent = `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`; }
function stopRecUi() { clearInterval(recTimer); recTimer = null; ui.recBadge.hidden = true; ui.record.textContent = '开始本地录像'; }
ui.record.onclick = () => {
  if (recorder?.state === 'recording') return recorder.stop();
  chunks = [];
  recorder = new MediaRecorder(ui.video.srcObject, { mimeType: MediaRecorder.isTypeSupported('video/webm;codecs=vp9,opus') ? 'video/webm;codecs=vp9,opus' : 'video/webm' });
  recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  recorder.onstop = () => {
    const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(chunks, { type: 'video/webm' }));
    a.download = `homecam-${new Date().toISOString().replaceAll(':', '-')}.webm`; a.click(); URL.revokeObjectURL(a.href);
    stopRecUi();
  };
  recorder.start(5000);
  recStart = Date.now(); updateRecTime(); ui.recBadge.hidden = false;
  recTimer = setInterval(updateRecTime, 1000);
  ui.record.textContent = '结束并保存录像';
};
ui.fullscreen.onclick = () => {
  if (document.fullscreenElement) document.exitFullscreen();
  else ui.videoWrap.requestFullscreen?.();
};
if (sessionStorage.getItem('homecam-expired')) { sessionStorage.removeItem('homecam-expired'); ui.error.textContent = '登录已过期，请重新输入密码'; }
$('#refreshPhotosButton').onclick = loadPhotos;
$('#reloadButton').onclick = () => location.reload();
$('#dismissUpdate').onclick = () => { document.getElementById('updateBanner').hidden = true; updateDismissed = true; };
if (token) { ui.login.hidden = true; ui.dashboard.hidden = false; connect(); loadPhotos(); }
