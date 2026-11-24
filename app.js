// El Sauce · Propinas — punto de entrada: sesión, espacio de trabajo, pestañas y tiempo real.
import { createClient } from './js/supabase.js';
import { $, show, notice, guard, check } from './js/util.js';
import { DraftSync } from './js/sync.js';
import { createDraftView } from './js/draft-view.js';
import { createPanels } from './js/panels.js';

// Revisa config.js y explica exactamente qué falta, para no adivinar.
function configProblem() {
  const url = typeof window.SAUCE_SUPABASE_URL === 'string' ? window.SAUCE_SUPABASE_URL.trim() : null;
  const key = typeof window.SAUCE_SUPABASE_KEY === 'string' ? window.SAUCE_SUPABASE_KEY.trim() : null;
  if (url === null && key === null) return 'No se encontró el archivo config.js en el sitio publicado (o tiene otro nombre, por ejemplo config.js.txt). Súbelo junto a index.html.';
  if (!url || /TU_PROYECTO|YOUR_PROJECT/.test(url)) return 'config.js todavía tiene la URL de ejemplo. Pon la Project URL de tu proyecto de Supabase.';
  if (/\/rest\/v1/.test(url)) return 'La URL de config.js termina en /rest/v1/. Bórrale esa parte: debe quedar como https://xxxx.supabase.co';
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/i.test(url)) return 'La URL de config.js no tiene la forma https://xxxx.supabase.co (revisa espacios o caracteres de más). Valor actual: ' + url;
  if (!key || /TU_CLAVE|YOUR_PUBLIC_KEY|^PEGA/.test(key)) return 'config.js todavía tiene la clave de ejemplo. Pon la publishable key de tu proyecto.';
  if (/^sb_secret_/.test(key)) return 'Pusiste la clave SECRETA en config.js. Bórrala de inmediato, regénérala en Supabase y usa la publishable key.';
  if (key.length < 20) return 'La clave de config.js parece incompleta.';
  return null;
}
const problem = configProblem();
const configured = !problem;

let supabase = null, user = null, workspace = null, sync = null, channel = null, recovering = false, pollTimer = null;
const ctx = () => ({ user, workspace });
const draftView = createDraftView({ getSync: () => sync, getEmail: () => user?.email });
let panels = null;

// ---------------- vistas ----------------
function layout() {
  show('setup', !configured);
  show('auth', configured && !user && !recovering);
  show('recovery', configured && recovering);
  show('session', Boolean(user));
  show('onboarding', Boolean(user) && !workspace && !recovering);
  show('workspaceApp', Boolean(user && workspace) && !recovering);
  $('who').textContent = user ? user.email + (workspace ? ' · ' + workspace.name : '') : '';
}

function selectTab(name) {
  for (const id of ['calc', 'templates', 'history', 'users']) show(id, id === name);
  document.querySelectorAll('[data-tab]').forEach((b) => { b.classList.toggle('selected', b.dataset.tab === name); b.setAttribute('aria-selected', b.dataset.tab === name); });
}

// ---------------- datos ----------------
async function rpcCall(fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw Object.assign(new Error(error.message || 'Error de conexión'), { code: error.code || '' });
  return data;
}

async function stopSync() {
  sync?.stop(); sync = null;
  clearInterval(pollTimer);
  if (channel) { await supabase.removeChannel(channel); channel = null; }
  $('liveDot').classList.remove('on');
  draftView.render();
}

async function enterWorkspace() {
  await stopSync();
  workspace = null;
  if (!user) return layout();
  const rows = check(await supabase.from('memberships').select('role, workspaces(id, name)').eq('user_id', user.id).limit(1));
  if (rows[0]?.workspaces) workspace = { ...rows[0].workspaces, role: rows[0].role };
  layout();
  if (!workspace) return;
  selectTab('calc');
  await panels.loadMembers();
  await Promise.all([panels.loadTemplates(), panels.loadHistory()]);
  panels.openTemplate(null);
  await startSync();
}

async function startSync() {
  const ws = workspace;
  sync = new DraftSync({ workspaceId: ws.id, call: rpcCall, onChange: () => draftView.render(), onMessage: (m, err) => notice(m, err) });
  sync.onClosedRemotely = () => guard(panels.loadHistory);
  draftView.render();
  await sync.load();
  draftView.render();

  channel = supabase.channel('draft-' + ws.id, { config: { presence: { key: user.id } } })
    .on('postgres_changes', { event: '*', schema: 'public', table: 'drafts', filter: `workspace_id=eq.${ws.id}` },
      (payload) => sync?.refresh(payload.new?.revision))
    .on('presence', { event: 'sync' }, () => {
      const state = channel.presenceState();
      const others = Object.entries(state).filter(([key]) => key !== user.id).map(([, metas]) => metas[0]?.email).filter(Boolean);
      draftView.setPresence([...new Set(others)]);
    })
    .subscribe(async (status) => {
      const live = status === 'SUBSCRIBED';
      $('liveDot').classList.toggle('on', live);
      $('liveDot').title = live ? 'Conectado en tiempo real' : 'Reconectando…';
      if (live) { await channel.track({ email: user.email }); sync?.refresh(); }
    });
  // Respaldo por si el tiempo real se cae: revisar cada 20 s.
  pollTimer = setInterval(() => { if (!$('liveDot').classList.contains('on')) sync?.refresh(); }, 20000);
}

// ---------------- sesión ----------------
async function onSession(session, event) {
  if (event === 'PASSWORD_RECOVERY') { recovering = true; user = session?.user || null; layout(); return; }
  const prev = user?.id;
  user = session?.user || null;
  if (!user) { await stopSync(); workspace = null; layout(); return; }
  if (prev !== user.id) await guard(enterWorkspace);
  else layout();
}

function bindAuth() {
  const creds = () => ({ email: $('email').value.trim(), password: $('password').value });
  const redirectTo = location.origin + location.pathname;
  $('authForm').addEventListener('submit', (e) => { e.preventDefault(); guard(async () => { check(await supabase.auth.signInWithPassword(creds())); }); });
  $('signup').onclick = () => guard(async () => {
    const c = creds();
    if (!c.email || c.password.length < 8) throw new Error('Escribe tu correo y una contraseña de al menos 8 caracteres');
    const data = check(await supabase.auth.signUp({ ...c, options: { emailRedirectTo: redirectTo } }));
    notice(data.session ? 'Cuenta creada' : 'Cuenta creada. Revisa tu correo para confirmarla y luego inicia sesión.');
  });
  $('forgot').onclick = () => guard(async () => {
    const email = $('email').value.trim();
    if (!email) throw new Error('Escribe tu correo primero');
    check(await supabase.auth.resetPasswordForEmail(email, { redirectTo }));
    notice('Si el correo está registrado, te llegará un enlace para cambiar la contraseña.');
  });
  $('recoveryForm').addEventListener('submit', (e) => { e.preventDefault(); guard(async () => {
    check(await supabase.auth.updateUser({ password: $('newPassword').value }));
    recovering = false; notice('Contraseña actualizada'); history.replaceState(null, '', location.pathname);
    await enterWorkspace();
  }); });
  $('logout').onclick = () => guard(async () => {
    if (sync?.dirty && !confirm('Hay cambios que aún no se guardan. ¿Salir de todos modos?')) return;
    check(await supabase.auth.signOut());
  });
  $('joinForm').addEventListener('submit', (e) => { e.preventDefault(); guard(async () => {
    check(await supabase.rpc('redeem_invite', { p_code: $('inviteCode').value.trim() }));
    notice('Te uniste a El Sauce'); await enterWorkspace();
  }); });
  $('createForm').addEventListener('submit', (e) => { e.preventDefault(); guard(async () => {
    check(await supabase.rpc('create_workspace', { p_name: $('newWorkspace').value }));
    notice('Espacio creado'); await enterWorkspace();
  }); });
}

// ---------------- arranque ----------------
layout();
if (configured) {
  supabase = createClient(window.SAUCE_SUPABASE_URL.replace(/\/$/, ''), window.SAUCE_SUPABASE_KEY);
  panels = createPanels({ supabase, getCtx: ctx, draftView });
  panels.bind();
  draftView.bind({ getTemplates: () => panels.getTemplates() });
  bindAuth();
  document.querySelectorAll('[data-tab]').forEach((b) => (b.onclick = () => {
    selectTab(b.dataset.tab);
    if (b.dataset.tab === 'history') guard(panels.loadHistory);
    if (b.dataset.tab === 'users') guard(panels.loadMembers);
  }));
  supabase.auth.onAuthStateChange((event, session) => { setTimeout(() => onSession(session, event), 0); });
  const refreshNow = () => { if (sync) { sync.refresh(); sync.flush(); } };
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') refreshNow(); });
  window.addEventListener('online', refreshNow);
  window.addEventListener('beforeunload', (e) => { if (sync?.dirty) { e.preventDefault(); e.returnValue = ''; } });
} else {
  $('setup').querySelector('p').textContent = problem;
}
