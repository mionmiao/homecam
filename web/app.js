const $ = (selector) => document.querySelector(selector);
let token = localStorage.getItem('homecam-token'); let socket; let selected; let peer; let recorder; let chunks = []; let watching = false; let pendingCandidates = [];
const ui = { login: $('#login'), dashboard: $('#dashboard'), error: $('#loginError'), devices: $('#devices'), video: $('#video'), placeholder: $('#placeholder'), status: $('#watchStatus'), connection: $('#connection'), watch: $('#watchButton'), stop: $('#stopButton'), mute: $('#muteButton'), record: $('#recordButton'), password: $('#password'), switchCamera: $('#switchCameraButton') };
const authHeaders = () => ({ 'Content-Type': 'application/json', Authorization: `Bearer ${token}` });
function expire() { localStorage.removeItem('homecam-token'); sessionStorage.setItem('homecam-expired', '1'); location.reload(); }
async function api(url, options = {}) { const response = await fetch(url, { ...options, headers: { ...authHeaders(), ...options.headers } }); if (response.status === 401) { expire(); throw new Error('登录已过期'); } if (!response.ok) throw new Error((await response.json()).error || '请求失败'); return response.json(); }
function setWatchUi(active) { watching = active; ui.watch.disabled = !selected || active; ui.stop.disabled = !active; ui.mute.disabled = !active; ui.record.disabled = !active; ui.switchCamera.disabled = !active; ui.placeholder.hidden = active; }
function statusLabel(device) { return device.status === 'streaming' ? '观看中' : device.status === 'connecting' ? '连接中' : device.status === 'idle' ? '待命' : '离线'; }
function select(device) { selected = device; document.querySelectorAll('.device').forEach((e) => e.classList.toggle('selected', e.dataset.id === device.id)); ui.status.textContent = `${device.name}：${statusLabel(device)}`; setWatchUi(false); }
function renderDevices(devices) {
  if (selected && !devices.some((d) => d.id === selected.id)) { selected = null; cleanup(); }
  ui.devices.innerHTML = '';
  devices.forEach((device) => {
    const el = document.createElement('article'); el.className = 'device'; el.dataset.id = device.id;
    el.innerHTML = `<div class="device-info"><strong>${escapeHtml(device.name)}</strong><p class="status">${statusLabel(device)}</p><small>${new Date(device.createdAt).toLocaleDateString()}</small></div><div class="device-actions"><button class="ghost rename" title="重命名">重命名</button><button class="ghost danger remove" title="删除">删除</button></div>`;
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
function connect() { socket = io({ auth: { token } }); socket.on('connect', () => { ui.connection.textContent = '已连接'; loadDevices(); }); socket.on('connect_error', (err) => { if (err?.message === 'Unauthorized') return expire(); ui.connection.textContent = '连接失败'; }); socket.on('devices', renderDevices); socket.on('device:status', ({ deviceId, status }) => { if (selected?.id === deviceId) { selected.status = status; ui.status.textContent = `${selected.name}：${status}`; } loadDevices(); }); socket.on('watch:accepted', async ({ deviceId }) => { if (deviceId !== selected?.id) return; await createOffer(); }); socket.on('signal', async ({ fromId, data }) => receiveSignal(fromId, data)); socket.on('watch:stopped', () => cleanup()); socket.on('device:removed', ({ deviceId }) => { if (selected?.id === deviceId) { selected = null; cleanup(); } loadDevices(); }); socket.on('device:diagnostic', ({ deviceId, message }) => { if (deviceId === selected?.id) appendDiag('手机端: ' + message); }); }
function initPeer(iceServers) { peer = new RTCPeerConnection({ iceServers }); pendingCandidates = []; appendDiag(`ICE servers: ${iceServers.map(s => (Array.isArray(s.urls) ? s.urls : [s.urls]).join(',')).join(' | ')}`); peer.onicecandidate = ({ candidate }) => { if (candidate) { const t = (candidate.type || '').toLowerCase(); appendDiag(`my candidate: ${t || '?'} ${String(candidate.candidate).slice(0, 40)}`); socket.emit('signal', { targetId: selected.id, data: { type: 'candidate', candidate } }); } }; peer.ontrack = ({ streams }) => { ui.video.srcObject = streams[0]; ui.status.textContent = '正在观看'; appendDiag('ontrack: 收到媒体流'); }; peer.onconnectionstatechange = () => { appendDiag(`peer: ${peer.connectionState}`); if (['failed', 'closed', 'disconnected'].includes(peer.connectionState)) cleanup(); }; peer.oniceconnectionstatechange = () => appendDiag(`ice: ${peer.iceConnectionState}`); }
async function createOffer() {
  const { iceServers } = await api('/api/ice'); initPeer(iceServers);
  const offer = await peer.createOffer({ offerToReceiveAudio: true, offerToReceiveVideo: true });
  await peer.setLocalDescription(offer);
  // non-trickle：等 ICE 收集完成，把 candidate 内嵌进 SDP 一次性发出
  if (peer.iceGatheringState !== 'complete') await new Promise((resolve) => { const timer = setTimeout(resolve, 12000); peer.onicegatheringstatechange = () => { if (peer.iceGatheringState === 'complete') { clearTimeout(timer); resolve(); } }; });
  const sdp = peer.localDescription?.sdp || offer.sdp;
  appendDiag(`offer: ${(sdp.match(/a=candidate/g) || []).length} candidates`);
  socket.emit('signal', { targetId: selected.id, data: { type: 'offer', sdp } });
}
function appendDiag(msg) { const box = document.getElementById('diag'); if (!box) return; const line = document.createElement('div'); line.textContent = `[${new Date().toLocaleTimeString()}] ${msg}`; box.prepend(line); }
function copyDiag() {
  const box = document.getElementById('diag'); if (!box) return;
  const text = [...box.children].map(e => e.textContent).reverse().join('\n') || '(暂无日志)';
  const done = () => { const b = document.getElementById('copyDiagButton'); b.textContent = '已复制'; setTimeout(() => b.textContent = '复制全部', 1500); };
  if (navigator.clipboard?.writeText) navigator.clipboard.writeText(text).then(done).catch(() => fallbackCopy(text, done));
  else fallbackCopy(text, done);
}
function fallbackCopy(text, done) { const ta = document.createElement('textarea'); ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0'; document.body.append(ta); ta.select(); try { document.execCommand('copy'); done(); } catch { alert(text); } ta.remove(); }
document.getElementById('diagBox')?.querySelector('summary')?.addEventListener('click', (e) => { if (e.target.id === 'copyDiagButton') e.preventDefault(); });
async function receiveSignal(fromId, data) { if (fromId !== selected?.id && data.type !== 'offer') return; if (data.type === 'answer') { await peer.setRemoteDescription({ type: 'answer', sdp: data.sdp }); for (const c of pendingCandidates) await peer.addIceCandidate(c); pendingCandidates = []; } if (data.type === 'candidate') { if (peer?.remoteDescription) await peer.addIceCandidate(data.candidate); else pendingCandidates.push(data.candidate); } }
function cleanup() { recorder?.state === 'recording' && recorder.stop(); recorder = null; peer?.close(); peer = null; pendingCandidates = []; ui.video.srcObject = null; setWatchUi(false); ui.status.textContent = selected ? `${selected.name}：已停止` : '待命'; }
async function login() { try { const data = await fetch('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password: $('#password').value }) }).then(async (r) => { if (!r.ok) throw new Error('密码错误'); return r.json(); }); token = data.token; localStorage.setItem('homecam-token', token); ui.error.textContent = ''; ui.login.hidden = true; ui.dashboard.hidden = false; connect(); } catch (e) { ui.error.textContent = e.message; } }
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
ui.mute.onclick = () => { ui.video.muted = !ui.video.muted; ui.mute.textContent = ui.video.muted ? '打开声音' : '静音'; };
ui.record.onclick = () => { if (recorder?.state === 'recording') return recorder.stop(); chunks = []; recorder = new MediaRecorder(ui.video.srcObject, { mimeType: MediaRecorder.isTypeSupported('video/webm;codecs=vp9,opus') ? 'video/webm;codecs=vp9,opus' : 'video/webm' }); recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data); recorder.onstop = () => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(chunks, { type: 'video/webm' })); a.download = `homecam-${new Date().toISOString().replaceAll(':', '-')}.webm`; a.click(); URL.revokeObjectURL(a.href); ui.record.textContent = '开始本地录像'; }; recorder.start(5000); ui.record.textContent = '结束并保存录像'; };
if (sessionStorage.getItem('homecam-expired')) { sessionStorage.removeItem('homecam-expired'); ui.error.textContent = '登录已过期，请重新输入密码'; }
if (token) { ui.login.hidden = true; ui.dashboard.hidden = false; connect(); }
