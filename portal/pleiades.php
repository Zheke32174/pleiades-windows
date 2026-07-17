<?php
// Pleiades Command Deck — read-only rendering of the host-published snapshot.

declare(strict_types=1);
date_default_timezone_set('UTC');
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store, max-age=0');
header('Pragma: no-cache');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; base-uri 'none'; frame-ancestors 'self'; form-action 'none'");

$snapshotPath = 'C:/pleiades/portal/status.json';
$data = null;
$error = null;

if (is_file($snapshotPath)) {
    $raw = file_get_contents($snapshotPath);
    $decoded = is_string($raw) ? json_decode($raw, true) : null;
    if (!is_array($decoded)) {
        $error = 'Snapshot exists but is not valid JSON.';
    } elseif (($decoded['schema'] ?? null) !== 'pleiades.status/v1') {
        $error = 'Snapshot schema is missing or unsupported.';
    } else {
        $data = $decoded;
    }
}

$age = $data ? max(0, time() - (int)($data['timestamp'] ?? filemtime($snapshotPath))) : null;
$stale = $age !== null && $age > 1200;

function h(mixed $value): string {
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function event_class(string $event): string {
    if (str_contains($event, 'swarm_alert') || str_contains($event, 'failed')) return 'crit';
    if (str_contains($event, 'windows_event') || str_contains($event, 'windows-')) return 'win';
    if (str_contains($event, 'hostile_recon') || str_contains($event, 'decoy_hit')) return 'warn';
    return 'info';
}

function status_class(string $status): string {
    return match ($status) {
        'ok' => 'ok',
        'stopped' => 'muted',
        default => 'crit',
    };
}

function ledger_class(string $state): string {
    return match ($state) {
        'VALID' => 'ok',
        'EMPTY' => 'warn',
        default => 'crit',
    };
}
?>
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta http-equiv="refresh" content="60">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pleiades — Command Deck</title>
<style>
  :root{--bg:#0b0e14;--card:#141a24;--line:#222c3a;--txt:#cdd6e4;--mut:#6b7888;
    --ok:#3fb950;--warn:#d29922;--crit:#f85149;--win:#58a6ff;--info:#8b949e}
  *{box-sizing:border-box} body{margin:0;background:var(--bg);color:var(--txt);
    font:14px/1.5 ui-monospace,Consolas,monospace;padding:24px}
  h1{font-size:20px;margin:0 0 4px} h2{font-size:13px;color:var(--mut);
    text-transform:uppercase;letter-spacing:.08em;margin:24px 0 8px}
  .sub{color:var(--mut);margin-bottom:20px}.row{display:flex;gap:12px;flex-wrap:wrap}
  .card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:14px 18px;min-width:150px}
  .k{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.05em}.v{font-size:22px;font-weight:600;margin-top:4px}
  .ok{color:var(--ok)}.warn{color:var(--warn)}.crit{color:var(--crit)}.win{color:var(--win)}.muted{color:var(--mut)}
  .agents{display:flex;gap:8px;flex-wrap:wrap}.chip{background:var(--card);border:1px solid var(--line);border-radius:20px;padding:5px 12px;font-size:13px}
  .chip.ok{border-color:#1f4d2a}.chip.crit{border-color:#5a2422}
  table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden}
  td{padding:7px 12px;border-bottom:1px solid var(--line);vertical-align:top}tr:last-child td{border-bottom:0}
  td.seq{color:var(--mut);width:64px}td.t{color:var(--mut);width:90px;white-space:nowrap}
  tr.crit td{background:rgba(248,81,73,.07)}tr.warn td{background:rgba(210,153,34,.06)}tr.win td{background:rgba(88,166,255,.06)}
  .foot{color:var(--mut);margin-top:24px;font-size:12px}.stalebadge{color:var(--warn);font-weight:600}
</style></head><body>
<h1>&#128752; Pleiades Defensive Network</h1>
<div class="sub">Command Deck &middot; read-only view of tamper-evident telemetry</div>

<?php if ($error): ?>
  <div class="card crit"><?= h($error) ?></div>
<?php elseif (!$data): ?>
  <div class="card">No snapshot yet. The Windows supervisor publishes one after the registered Pleiades machine is available.</div>
<?php else:
  $ledger = is_array($data['ledger'] ?? null) ? $data['ledger'] : [];
  $ledgerState = (string)($ledger['state'] ?? 'UNKNOWN');
?>
  <div class="row">
    <div class="card"><div class="k">Container</div><div class="v <?= ($data['container'] ?? '') === 'running' ? 'ok' : ((($data['container'] ?? '') === 'degraded') ? 'warn' : 'crit') ?>"><?= h($data['container'] ?? 'unknown') ?></div></div>
    <div class="card"><div class="k">Ledger</div><div class="v <?= ledger_class($ledgerState) ?>"><?= h($ledgerState) ?></div></div>
    <div class="card"><div class="k">Signed records</div><div class="v"><?= (int)($ledger['records'] ?? 0) ?></div></div>
    <div class="card"><div class="k">Snapshot age</div><div class="v <?= $stale ? 'warn' : 'ok' ?>"><?= (int)$age ?>s<?= $stale ? ' <span class="stalebadge">stale</span>' : '' ?></div></div>
  </div>

  <h2>Agents</h2>
  <div class="agents">
    <?php foreach (($data['agents'] ?? []) as $agent): if (!is_array($agent)) continue; ?>
      <?php $class = status_class((string)($agent['status'] ?? '')); ?>
      <span class="chip <?= $class ?>"><?= h($agent['agent'] ?? '?') ?>: <span class="<?= $class ?>"><?= h($agent['status'] ?? '?') ?></span></span>
    <?php endforeach; ?>
    <?php if (empty($data['agents'])): ?><span class="chip muted">none reporting</span><?php endif; ?>
  </div>

  <h2>Recent signed events</h2>
  <table>
    <?php foreach (array_reverse($data['events'] ?? []) as $event): if (!is_array($event)) continue; ?>
      <?php $eventText = (string)($event['event'] ?? ''); ?>
      <tr class="<?= event_class($eventText) ?>">
        <td class="seq">#<?= (int)($event['seq'] ?? 0) ?></td>
        <td class="t"><?= gmdate('H:i:s', (int)($event['timestamp'] ?? 0)) ?></td>
        <td><?= h($eventText) ?></td>
      </tr>
    <?php endforeach; ?>
    <?php if (empty($data['events'])): ?><tr><td colspan="3" class="muted">no events sealed yet</td></tr><?php endif; ?>
  </table>
<?php endif; ?>

<div class="foot">auto-refresh 60s &middot; rendered <?= gmdate('Y-m-d H:i:s') ?> UTC</div>
</body></html>
