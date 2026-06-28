<?php
// Pleiades Command Deck — reads the signed status snapshot written by the
// Windows supervisor (out of webroot) and renders the defensive-network state.
$snap = 'C:/pleiades/portal/status.json';
$d = is_file($snap) ? json_decode(file_get_contents($snap), true) : null;
$age = $d ? time() - filemtime($snap) : null;
$stale = ($age !== null && $age > 1500);
function ev_class($e){
  if (strpos($e,'swarm_alert')!==false) return 'crit';
  if (strpos($e,'windows_event')!==false) return 'win';
  if (strpos($e,'hostile_recon')!==false || strpos($e,'decoy_hit')!==false) return 'warn';
  return 'info';
}
function st_class($s){ return $s==='ok' ? 'ok' : ($s==='stopped' ? 'muted' : 'crit'); }
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
  .sub{color:var(--mut);margin-bottom:20px}
  .row{display:flex;gap:12px;flex-wrap:wrap}
  .card{background:var(--card);border:1px solid var(--line);border-radius:8px;
    padding:14px 18px;min-width:150px}
  .k{color:var(--mut);font-size:11px;text-transform:uppercase;letter-spacing:.05em}
  .v{font-size:22px;font-weight:600;margin-top:4px}
  .ok{color:var(--ok)} .warn{color:var(--warn)} .crit{color:var(--crit)}
  .win{color:var(--win)} .muted{color:var(--mut)}
  .agents{display:flex;gap:8px;flex-wrap:wrap}
  .chip{background:var(--card);border:1px solid var(--line);border-radius:20px;
    padding:5px 12px;font-size:13px}
  .chip.ok{border-color:#1f4d2a} .chip.crit{border-color:#5a2422}
  table{width:100%;border-collapse:collapse;background:var(--card);
    border:1px solid var(--line);border-radius:8px;overflow:hidden}
  td{padding:7px 12px;border-bottom:1px solid var(--line);vertical-align:top}
  tr:last-child td{border-bottom:0}
  td.seq{color:var(--mut);width:48px} td.t{color:var(--mut);width:72px;white-space:nowrap}
  tr.crit td{background:rgba(248,81,73,.07)} tr.warn td{background:rgba(210,153,34,.06)}
  tr.win td{background:rgba(88,166,255,.06)}
  .foot{color:var(--mut);margin-top:24px;font-size:12px}
  .stalebadge{color:var(--warn);font-weight:600}
</style></head><body>

<h1>&#128752; Pleiades Defensive Network</h1>
<div class="sub">Command Deck &middot; signed, tamper-evident telemetry</div>

<?php if(!$d): ?>
  <div class="card">No snapshot yet &mdash; the supervisor publishes one once the container is up.</div>
<?php else: ?>
  <div class="row">
    <div class="card"><div class="k">Container</div>
      <div class="v <?= $d['container']==='up'?'ok':'crit' ?>"><?= htmlspecialchars($d['container']) ?></div></div>
    <div class="card"><div class="k">Ledger integrity</div>
      <div class="v <?= $d['verify']==='ok'?'ok':'crit' ?>"><?= $d['verify']==='ok'?'&#10003; valid':'&#10007; TAMPER' ?></div></div>
    <div class="card"><div class="k">Signed records</div>
      <div class="v"><?= (int)$d['records'] ?></div></div>
    <div class="card"><div class="k">Snapshot age</div>
      <div class="v <?= $stale?'warn':'ok' ?>"><?= (int)$age ?>s<?= $stale?' <span class="stalebadge">stale</span>':'' ?></div></div>
  </div>

  <h2>Agents</h2>
  <div class="agents">
    <?php foreach(($d['agents']??[]) as $a): ?>
      <span class="chip <?= st_class($a['status']??'') ?>">
        <?= htmlspecialchars($a['agent']??'?') ?>: <span class="<?= st_class($a['status']??'') ?>"><?= htmlspecialchars($a['status']??'?') ?></span></span>
    <?php endforeach; ?>
    <?php if(empty($d['agents'])): ?><span class="chip muted">none reporting</span><?php endif; ?>
  </div>

  <h2>Recent signed events</h2>
  <table>
    <?php foreach(array_reverse($d['events']??[]) as $e): ?>
      <tr class="<?= ev_class($e['event']??'') ?>">
        <td class="seq">#<?= (int)$e['seq'] ?></td>
        <td class="t"><?= date('H:i:s',(int)$e['ts']) ?></td>
        <td><?= htmlspecialchars($e['event']??'') ?></td></tr>
    <?php endforeach; ?>
    <?php if(empty($d['events'])): ?><tr><td colspan="3" class="muted">no events sealed yet</td></tr><?php endif; ?>
  </table>
<?php endif; ?>

<div class="foot">auto-refresh 60s &middot; rendered <?= date('Y-m-d H:i:s') ?></div>
</body></html>
