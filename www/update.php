<?php
/**
 * OpenAMD dialer updater — /srv/www/htdocs/update.php
 *
 * First install is via PuTTY (vicibox_install.sh + oam_ key).
 * This page shows the installed key, lets you change it, and updates
 * AGI scripts from GitHub when a newer commit is available — no SSH.
 */
declare(strict_types=1);

const HELPER = '/usr/local/sbin/openamd_web_update.sh';

function json_out(array $data, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function run_helper(string $cmd, string $arg = ''): array {
    if (!is_file(HELPER)) {
        return [
            'ok' => false,
            'error' => 'Helper missing: ' . HELPER . ' — finish first-time install via PuTTY (vicibox_install.sh).',
        ];
    }
    $full = 'sudo -n ' . escapeshellarg(HELPER) . ' ' . escapeshellarg($cmd);
    if ($arg !== '') {
        $full .= ' ' . escapeshellarg($arg);
    }
    $full .= ' 2>&1';
    $lines = [];
    $code = 0;
    exec($full, $lines, $code);
    $raw = implode("\n", $lines);
    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        return [
            'ok' => false,
            'error' => 'Helper did not return JSON. Check passwordless sudo for the web user.',
            'raw' => $raw,
            'exit_code' => $code,
        ];
    }
    if ($code !== 0 && empty($decoded['ok'])) {
        $decoded['ok'] = false;
    }
    return $decoded;
}

$action = $_GET['action'] ?? $_POST['action'] ?? '';

if ($action === 'status') {
    json_out(run_helper('status'));
}

if ($action === 'set_key' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $key = trim((string)($_POST['api_key'] ?? ''));
    if ($key === '') {
        json_out(['ok' => false, 'error' => 'API key required'], 400);
    }
    json_out(run_helper('set_key', $key));
}

if ($action === 'apply' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    @set_time_limit(600);
    @ignore_user_abort(true);
    $key = trim((string)($_POST['api_key'] ?? ''));
    json_out(run_helper('apply', $key));
}
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
    margin: 0; min-height: 100vh;
    font-family: "Segoe UI", "Helvetica Neue", sans-serif;
    background:
      radial-gradient(1200px 600px at 10% -10%, #1c3a5c 0%, transparent 55%),
      radial-gradient(900px 500px at 100% 0%, #163028 0%, transparent 50%),
      var(--bg);
    color: var(--text);
  }
  main { max-width: 740px; margin: 0 auto; padding: 2.5rem 1.25rem 3rem; }
  h1 { font-size: 1.65rem; font-weight: 650; letter-spacing: -0.02em; margin: 0 0 0.35rem; }
  .sub { color: var(--muted); margin: 0 0 1.75rem; font-size: 0.95rem; }
  .card {
    background: color-mix(in srgb, var(--panel) 92%, transparent);
    border: 1px solid var(--line); border-radius: 12px;
    padding: 1.25rem 1.35rem; margin-bottom: 1rem;
  }
  h2 { font-size: 1rem; margin: 0 0 0.85rem; font-weight: 650; }
  .row {
    display: flex; justify-content: space-between; gap: 1rem;
    padding: 0.55rem 0; border-bottom: 1px solid var(--line); font-size: 0.92rem;
  }
  .row:last-child { border-bottom: 0; }
  .label { color: var(--muted); flex-shrink: 0; }
  .val { font-family: ui-monospace, Consolas, monospace; text-align: right; word-break: break-all; }
  .badge {
    display: inline-block; padding: 0.2rem 0.55rem; border-radius: 6px;
    font-size: 0.78rem; font-weight: 600;
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
  label.field { display: block; color: var(--muted); font-size: 0.85rem; margin-top: 0.35rem; }
  input[type=text], input[type=password] {
    width: 100%; padding: 0.7rem 0.85rem; border-radius: 8px; border: 1px solid var(--line);
    background: #0c1118; color: var(--text); font-size: 0.95rem; margin: 0.4rem 0 0;
    font-family: ui-monospace, Consolas, monospace;
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
  .headrow { display:flex; justify-content:space-between; align-items:center; gap:1rem; margin-bottom:0.5rem; }
</style>
</head>
<body>
<main>
  <h1>OpenAMD Dialer Update</h1>
  <p class="sub">Installed key from PuTTY install. Change the key if needed, or update AGI scripts from GitHub — no SSH.</p>

  <section class="card">
    <h2>Installed OAM key</h2>
    <label class="field" for="apiKey">API key used by this dialer</label>
    <input type="text" id="apiKey" placeholder="oam_…" spellcheck="false" autocomplete="off">
    <div class="actions">
      <button type="button" id="btnSaveKey" class="secondary">Save key only</button>
      <button type="button" id="btnUpdate" class="danger" disabled>Update AGI from GitHub</button>
      <button type="button" id="btnRefresh" class="secondary">Refresh</button>
    </div>
    <div id="keyMsg" class="msg"></div>
  </section>

  <section class="card">
    <div class="headrow">
      <h2 style="margin:0">GitHub status</h2>
      <span id="badge" class="badge warn">Loading…</span>
    </div>
    <div class="row"><span class="label">AIAMD URL</span><span class="val" id="baseUrl">—</span></div>
    <div class="row"><span class="label">Repository</span><span class="val" id="repo">—</span></div>
    <div class="row"><span class="label">Installed commit</span><span class="val" id="local">—</span></div>
    <div class="row"><span class="label">Installed message</span><span class="val" id="localMsg">—</span></div>
    <div class="row"><span class="label">Latest on GitHub</span><span class="val" id="remote">—</span></div>
    <div class="row"><span class="label">Latest message</span><span class="val" id="remoteMsg">—</span></div>
    <div id="dashMsg" class="msg"></div>
    <pre id="log" class="hidden"></pre>
  </section>
</main>
<script>
(function () {
  const $ = (id) => document.getElementById(id);
  let installedKey = '';

  async function api(action, body) {
    const fd = new FormData();
    fd.append('action', action);
    if (body) Object.keys(body).forEach((k) => fd.append(k, body[k]));
    const r = await fetch('update.php', { method: 'POST', body: fd, credentials: 'same-origin' });
    return r.json().catch(() => ({ ok: false, error: 'Bad JSON from server' }));
  }

  function setBadge(kind, text) {
    const b = $('badge');
    b.className = 'badge ' + kind;
    b.textContent = text;
  }

  function showStatus(d) {
    installedKey = d.api_key || '';
    if (document.activeElement !== $('apiKey')) {
      $('apiKey').value = installedKey;
    }
    $('baseUrl').textContent = d.base_url || d.analyze_url || '—';
    $('repo').textContent = d.repo ? (d.repo + (d.branch ? ' @ ' + d.branch : '')) : '—';
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
      $('dashMsg').textContent = 'Newer AGI code is on GitHub. Update uses the key shown above (or a new key you type).';
    } else if (d.local_commit && d.remote_commit) {
      setBadge('ok', 'Up to date');
      $('btnUpdate').disabled = true;
      $('dashMsg').className = 'msg ok';
      $('dashMsg').textContent = 'AGI scripts already match the latest GitHub commit.';
    } else {
      setBadge('warn', 'Incomplete');
      $('btnUpdate').disabled = !!d.remote_commit;
      $('dashMsg').textContent = d.error || 'Could not fully compare commits.';
    }
  }

  async function refresh() {
    setBadge('warn', 'Checking…');
    $('dashMsg').textContent = '';
    $('keyMsg').textContent = '';
    const d = await api('status');
    showStatus(d);
  }

  $('btnRefresh').addEventListener('click', refresh);

  $('btnSaveKey').addEventListener('click', async () => {
    const key = $('apiKey').value.trim();
    $('keyMsg').textContent = '';
    const d = await api('set_key', { api_key: key });
    if (!d.ok) {
      $('keyMsg').className = 'msg err';
      $('keyMsg').textContent = d.error || 'Could not save key';
      return;
    }
    $('keyMsg').className = 'msg ok';
    $('keyMsg').textContent = 'Key saved to openamd.conf';
    installedKey = d.api_key || key;
    $('apiKey').value = installedKey;
  });

  $('btnUpdate').addEventListener('click', async () => {
    const key = $('apiKey').value.trim();
    const usingNew = key && key !== installedKey;
    const msg = usingNew
      ? 'Save this new OAM key and pull/update AGI scripts from GitHub?'
      : 'Pull latest from GitHub and update AGI scripts using the existing OAM key?';
    if (!confirm(msg)) return;

    $('btnUpdate').disabled = true;
    $('btnSaveKey').disabled = true;
    $('btnRefresh').disabled = true;
    setBadge('warn', 'Updating…');
    $('dashMsg').className = 'msg';
    $('dashMsg').textContent = 'Pulling GitHub and installing AGI scripts…';
    $('log').classList.add('hidden');
    $('keyMsg').textContent = '';

    const body = {};
    if (usingNew) body.api_key = key;
    const d = await api('apply', body);

    $('btnSaveKey').disabled = false;
    $('btnRefresh').disabled = false;
    if (d.log) {
      $('log').textContent = d.log;
      $('log').classList.remove('hidden');
    }
    if (d.ok) {
      setBadge('ok', 'Updated');
      $('dashMsg').className = 'msg ok';
      $('dashMsg').textContent = 'AGI updated to ' + (d.local_commit || 'latest') +
        (d.local_message ? ' — ' + d.local_message : '');
      if (d.api_key) {
        installedKey = d.api_key;
        $('apiKey').value = installedKey;
      }
      await refresh();
    } else {
      setBadge('bad', 'Failed');
      $('dashMsg').className = 'msg err';
      $('dashMsg').textContent = d.error || 'Update failed';
      $('btnUpdate').disabled = false;
    }
  });

  refresh();
})();
</script>
</body>
</html>
