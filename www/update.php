<?php
/**
 * OpenAMD / VICIdial dialer web updater
 * Installed to: /srv/www/htdocs/update.php
 *
 * Shows installed git commit vs latest on GitHub and applies update
 * without SSH (sudo helper /usr/local/sbin/openamd_web_update.sh).
 *
 * Auth: OPENAMD_API_KEY (validated by root helper — PHP never reads conf).
 */
declare(strict_types=1);
session_start();

const HELPER = '/usr/local/sbin/openamd_web_update.sh';

function json_out(array $data, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function session_key(): string {
    return (string)($_SESSION['openamd_api_key'] ?? '');
}

function run_helper(string $cmd, string $apiKey): array {
    if (!is_file(HELPER)) {
        return [
            'ok' => false,
            'error' => 'Helper missing: ' . HELPER . ' — re-run bash vicibox_install.sh once as root.',
        ];
    }
    $full = 'sudo -n ' . escapeshellarg(HELPER) . ' ' . escapeshellarg($cmd) . ' ' . escapeshellarg($apiKey) . ' 2>&1';
    $lines = [];
    $code = 0;
    exec($full, $lines, $code);
    $raw = implode("\n", $lines);
    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        return [
            'ok' => false,
            'error' => 'Helper did not return JSON. Install may need: passwordless sudo for web user → ' . HELPER,
            'raw' => $raw,
            'exit_code' => $code,
        ];
    }
    if ($code !== 0 && empty($decoded['ok'])) {
        $decoded['ok'] = false;
    }
    $decoded['exit_code'] = $code;
    return $decoded;
}

function require_session_key(): string {
    $key = session_key();
    if ($key === '') {
        json_out(['ok' => false, 'error' => 'Unauthorized — enter your OpenAMD API key (oam_…).'], 401);
    }
    return $key;
}

$action = $_GET['action'] ?? $_POST['action'] ?? '';

if ($action === 'login' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $got = trim((string)($_POST['api_key'] ?? ''));
    if ($got === '') {
        json_out(['ok' => false, 'error' => 'API key required'], 401);
    }
    $d = run_helper('verify', $got);
    if (empty($d['ok'])) {
        json_out(['ok' => false, 'error' => $d['error'] ?? 'Invalid API key'], 401);
    }
    $_SESSION['openamd_api_key'] = $got;
    json_out(['ok' => true]);
}

if ($action === 'logout') {
    $_SESSION = [];
    if (session_status() === PHP_SESSION_ACTIVE) {
        session_destroy();
    }
    json_out(['ok' => true]);
}

if ($action === 'status') {
    $key = require_session_key();
    json_out(run_helper('status', $key));
}

if ($action === 'apply') {
    $key = require_session_key();
    @set_time_limit(600);
    @ignore_user_abort(true);
    json_out(run_helper('apply', $key));
}

$authed = session_key() !== '';
?><!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenAMD Dialer Update</title>
<style>
  :root {
    --bg: #0f1419;
    --panel: #1a2332;
    --line: #2d3a4d;
    --text: #e7eef8;
    --muted: #8b9bb4;
    --accent: #3d9cf0;
    --ok: #3ecf8e;
    --warn: #f0b429;
    --bad: #f07178;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    font-family: "Segoe UI", "Helvetica Neue", sans-serif;
    background:
      radial-gradient(1200px 600px at 10% -10%, #1c3a5c 0%, transparent 55%),
      radial-gradient(900px 500px at 100% 0%, #163028 0%, transparent 50%),
      var(--bg);
    color: var(--text);
  }
  main { max-width: 720px; margin: 0 auto; padding: 2.5rem 1.25rem 3rem; }
  h1 { font-size: 1.65rem; font-weight: 650; letter-spacing: -0.02em; margin: 0 0 0.35rem; }
  .sub { color: var(--muted); margin: 0 0 1.75rem; font-size: 0.95rem; }
  .card {
    background: color-mix(in srgb, var(--panel) 92%, transparent);
    border: 1px solid var(--line);
    border-radius: 12px;
    padding: 1.25rem 1.35rem;
    margin-bottom: 1rem;
  }
  .row {
    display: flex; justify-content: space-between; gap: 1rem;
    padding: 0.55rem 0; border-bottom: 1px solid var(--line); font-size: 0.92rem;
  }
  .row:last-child { border-bottom: 0; }
  .label { color: var(--muted); }
  .val { font-family: ui-monospace, Consolas, monospace; text-align: right; word-break: break-all; }
  .badge {
    display: inline-block; padding: 0.2rem 0.55rem; border-radius: 6px;
    font-size: 0.78rem; font-weight: 600; letter-spacing: 0.02em;
  }
  .badge.ok { background: rgba(62,207,142,0.15); color: var(--ok); }
  .badge.warn { background: rgba(240,180,41,0.15); color: var(--warn); }
  .badge.bad { background: rgba(240,113,120,0.15); color: var(--bad); }
  .actions { display: flex; flex-wrap: wrap; gap: 0.65rem; margin-top: 1rem; }
  button {
    appearance: none; border: 0; border-radius: 8px; padding: 0.65rem 1.1rem;
    font-size: 0.92rem; font-weight: 600; cursor: pointer; color: #fff; background: var(--accent);
  }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  button.secondary { background: transparent; border: 1px solid var(--line); color: var(--text); }
  button.danger { background: #c45c26; }
  input[type=password] {
    width: 100%; padding: 0.7rem 0.85rem; border-radius: 8px; border: 1px solid var(--line);
    background: #0c1118; color: var(--text); font-size: 0.95rem; margin: 0.5rem 0 0.85rem;
  }
  pre {
    margin: 0.75rem 0 0; max-height: 280px; overflow: auto; background: #0c1118;
    border: 1px solid var(--line); border-radius: 8px; padding: 0.75rem;
    font-size: 0.78rem; color: #b8c7dc; white-space: pre-wrap;
  }
  .msg { margin-top: 0.75rem; font-size: 0.9rem; }
  .msg.err { color: var(--bad); }
  .msg.ok { color: var(--ok); }
  .hidden { display: none !important; }
</style>
</head>
<body>
<main>
  <h1>OpenAMD Dialer Update</h1>
  <p class="sub">Compare this VICIdial install to GitHub and apply updates from the browser (no SSH).</p>

  <section id="loginCard" class="card <?= $authed ? 'hidden' : '' ?>">
    <div class="label">Authorize with your OpenAMD API key</div>
    <input type="password" id="apiKey" placeholder="oam_…" autocomplete="current-password">
    <div class="actions">
      <button type="button" id="btnLogin">Unlock</button>
    </div>
    <div id="loginMsg" class="msg"></div>
  </section>

  <section id="dash" class="<?= $authed ? '' : 'hidden' ?>">
    <div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center;gap:1rem;margin-bottom:0.5rem;">
        <strong>Status</strong>
        <span id="badge" class="badge warn">Checking…</span>
      </div>
      <div class="row"><span class="label">Repository</span><span class="val" id="repo">—</span></div>
      <div class="row"><span class="label">Branch</span><span class="val" id="branch">—</span></div>
      <div class="row"><span class="label">Source dir</span><span class="val" id="source">—</span></div>
      <div class="row"><span class="label">Installed commit</span><span class="val" id="local">—</span></div>
      <div class="row"><span class="label">Installed message</span><span class="val" id="localMsg">—</span></div>
      <div class="row"><span class="label">Latest on GitHub</span><span class="val" id="remote">—</span></div>
      <div class="row"><span class="label">Latest message</span><span class="val" id="remoteMsg">—</span></div>
      <div class="actions">
        <button type="button" id="btnRefresh" class="secondary">Refresh</button>
        <button type="button" id="btnUpdate" class="danger" disabled>Update now</button>
        <button type="button" id="btnLogout" class="secondary">Lock</button>
      </div>
      <div id="dashMsg" class="msg"></div>
      <pre id="log" class="hidden"></pre>
    </div>
  </section>
</main>
<script>
(function () {
  const $ = (id) => document.getElementById(id);
  const authed = <?= $authed ? 'true' : 'false' ?>;

  async function api(action, body) {
    const fd = new FormData();
    fd.append('action', action);
    if (body) Object.keys(body).forEach((k) => fd.append(k, body[k]));
    const r = await fetch('update.php', { method: 'POST', body: fd, credentials: 'same-origin' });
    const data = await r.json().catch(() => ({ ok: false, error: 'Bad JSON from server' }));
    data._http = r.status;
    return data;
  }

  function setBadge(kind, text) {
    const b = $('badge');
    b.className = 'badge ' + kind;
    b.textContent = text;
  }

  function showStatus(d) {
    $('repo').textContent = d.repo || '—';
    $('branch').textContent = d.branch || '—';
    $('source').textContent = d.source_dir || '—';
    $('local').textContent = d.local_commit
      ? (d.local_commit + (d.local_date ? ' · ' + d.local_date : ''))
      : '—';
    $('localMsg').textContent = d.local_message || '—';
    $('remote').textContent = d.remote_commit
      ? (d.remote_commit + (d.remote_date ? ' · ' + d.remote_date : ''))
      : '—';
    $('remoteMsg').textContent = d.remote_message || '—';

    if (d.error && !d.local_commit) {
      setBadge('bad', 'Error');
      $('dashMsg').className = 'msg err';
      $('dashMsg').textContent = d.error;
      $('btnUpdate').disabled = true;
      return;
    }
    if (d.update_available) {
      setBadge('warn', 'Update available');
      $('btnUpdate').disabled = false;
      $('dashMsg').className = 'msg';
      $('dashMsg').textContent = 'A newer commit is on GitHub. Click Update now to pull and reinstall.';
    } else if (d.local_commit && d.remote_commit) {
      setBadge('ok', 'Up to date');
      $('btnUpdate').disabled = true;
      $('dashMsg').className = 'msg ok';
      $('dashMsg').textContent = 'This dialer matches the latest GitHub commit.';
    } else {
      setBadge('warn', 'Incomplete');
      $('btnUpdate').disabled = !d.remote_commit;
      $('dashMsg').textContent = d.error || 'Could not fully compare commits.';
    }
  }

  async function refresh() {
    setBadge('warn', 'Checking…');
    $('dashMsg').textContent = '';
    const d = await api('status');
    if (d._http === 401) {
      $('dash').classList.add('hidden');
      $('loginCard').classList.remove('hidden');
      return;
    }
    showStatus(d);
  }

  $('btnLogin').addEventListener('click', async () => {
    $('loginMsg').textContent = '';
    const d = await api('login', { api_key: $('apiKey').value.trim() });
    if (!d.ok) {
      $('loginMsg').className = 'msg err';
      $('loginMsg').textContent = d.error || 'Login failed';
      return;
    }
    $('loginCard').classList.add('hidden');
    $('dash').classList.remove('hidden');
    refresh();
  });
  $('apiKey').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') $('btnLogin').click();
  });

  $('btnRefresh').addEventListener('click', refresh);
  $('btnLogout').addEventListener('click', async () => {
    await api('logout');
    location.reload();
  });

  $('btnUpdate').addEventListener('click', async () => {
    if (!confirm('Pull latest from GitHub and re-run vicibox_install.sh on this server?')) return;
    $('btnUpdate').disabled = true;
    $('btnRefresh').disabled = true;
    setBadge('warn', 'Updating…');
    $('dashMsg').className = 'msg';
    $('dashMsg').textContent = 'Running git pull + install (may take 1–3 minutes)…';
    $('log').classList.add('hidden');
    const d = await api('apply');
    $('btnRefresh').disabled = false;
    if (d.log) {
      $('log').textContent = d.log;
      $('log').classList.remove('hidden');
    }
    if (d.ok) {
      setBadge('ok', 'Updated');
      $('dashMsg').className = 'msg ok';
      $('dashMsg').textContent = 'Updated to ' + (d.local_commit || 'latest') +
        (d.local_message ? ' — ' + d.local_message : '');
      await refresh();
    } else {
      setBadge('bad', 'Failed');
      $('dashMsg').className = 'msg err';
      $('dashMsg').textContent = d.error || 'Update failed';
      $('btnUpdate').disabled = false;
    }
  });

  if (authed) refresh();
})();
</script>
</body>
</html>
