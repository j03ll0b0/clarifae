/* Clarifae WebUI logic — talks to clarifae-ctl through the KernelSU bridge. */
(function () {
  'use strict';

  var KSU = window.ClarifaeKSU;
  var $ = function (id) { return document.getElementById(id); };
  var setTimers = {};
  var refreshTimer = null;

  function ctl(args) { return KSU.exec('clarifae-ctl ' + args); }

  function toast(msg) { KSU.toast(msg); showToast(msg); }
  function showToast(msg) {
    var t = $('toast');
    t.textContent = msg;
    t.classList.remove('hidden');
    clearTimeout(t._t);
    t._t = setTimeout(function () { t.classList.add('hidden'); }, 2200);
  }

  function parse(stdout) {
    try { return JSON.parse(stdout); } catch (e) { return null; }
  }

  /* push a single setting and surface failures */
  function setKey(key, value, label) {
    return ctl('set ' + key + ' ' + value).then(function (r) {
      if (r.errno !== 0) toast('Failed: ' + key + ' (' + (r.stderr || r.errno) + ')');
      else if (label) toast(label);
      return r;
    });
  }

  function debouncedSet(key, value, label) {
    clearTimeout(setTimers[key]);
    setTimers[key] = setTimeout(function () { setKey(key, value, label); }, 280);
  }

  /* ---------- rendering ---------- */
  function renderControls(s) {
    $('enable-toggle').checked = !!s.enabled;
    setActiveMode(s.mode);

    $('strength').value = s.strength; $('strength-val').textContent = s.strength;
    $('atten_db').value = s.atten_db; $('atten_db-val').textContent = s.atten_db + ' dB';
    $('vad').value = s.vad;           $('vad-val').textContent = s.vad;

    $('highpass').checked = !!s.highpass;
    $('autogain').checked = !!s.autogain;

    var targets = (s.targets || '').split(',');
    document.querySelectorAll('.chip').forEach(function (c) {
      c.classList.toggle('active', targets.indexOf(c.dataset.target) !== -1);
    });
  }

  function setActiveMode(mode) {
    document.querySelectorAll('.mode-card').forEach(function (c) {
      c.classList.toggle('active', String(mode) === c.dataset.mode);
    });
    updateFallbackHint(mode);
  }

  var lastStatus = {};
  function updateFallbackHint(mode) {
    var s = lastStatus;
    var hint = $('mode-fallback-hint');
    if (String(mode) === '2' && s.model_dtln === false) {
      hint.textContent = 'DTLN models not installed — Clarifae will fall back to RNNoise. See INSTALL.md.';
    } else if (String(mode) === '3' && s.model_df === false) {
      hint.textContent = 'DeepFilterNet (libdf/model) not installed — Clarifae will fall back to RNNoise. See INSTALL.md.';
    } else { hint.textContent = ''; }
  }

  function modelReady(s, which) {
    if (which === 'rnnoise') return s.model_rnnoise;
    if (which === 'dtln') return s.model_dtln;
    if (which === 'df') return s.model_df;
    return false;
  }

  function renderStatus(s) {
    lastStatus = s;
    $('master-sub').textContent = s.enabled
      ? 'Active — ' + (s.mode_name || 'cleaning your microphone') + '.'
      : 'Paused. Toggle on to clean your microphone.';
    if (s.version) $('version').textContent = 'Clarifae ' + s.version;

    document.querySelectorAll('.mode-status').forEach(function (el) {
      var ready = modelReady(s, el.dataset.model);
      el.classList.remove('ready', 'missing');
      if (el.dataset.model === 'rnnoise') {
        el.textContent = ready ? '● installed' : '● library missing';
        el.classList.add(ready ? 'ready' : 'missing');
      } else {
        el.textContent = ready ? '● model ready' : '● model not installed';
        el.classList.add(ready ? 'ready' : 'missing');
      }
    });
    updateFallbackHint(s.mode);

    var rows = [
      ['Enabled', bool(s.enabled)],
      ['Effect loaded', triState(s.effect_loaded)],
      ['audio_effects patched', bool(s.xml_patched)],
      ['Library (64-bit)', bool(s.lib64)],
      ['Library (32-bit)', s.lib32 ? yes('yes') : neutral('—')],
      ['audioserver', bool(s.audioserver)],
      ['RNNoise', bool(s.model_rnnoise)],
      ['DTLN model', s.model_dtln ? yes('yes') : warn('no')],
      ['DeepFilterNet', s.model_df ? yes('yes') : warn('no')]
    ];
    $('status-grid').innerHTML = rows.map(function (r) {
      return '<div class="status-item"><span class="k">' + r[0] + '</span>' + r[1] + '</div>';
    }).join('');
  }

  function yes(t) { return '<span class="v yes">' + t + '</span>'; }
  function no(t) { return '<span class="v no">' + t + '</span>'; }
  function warn(t) { return '<span class="v warn">' + t + '</span>'; }
  function neutral(t) { return '<span class="v">' + t + '</span>'; }
  function bool(b) { return b ? yes('yes') : no('no'); }
  function triState(b) { return b ? yes('loaded') : warn('not detected'); }

  /* ---------- data flow ---------- */
  function loadAll() {
    return ctl('status-json').then(function (r) {
      var s = parse(r.stdout);
      if (!s) { toast('Could not read status'); return; }
      renderControls(s);
      renderStatus(s);
    });
  }

  function refreshStatus() {
    ctl('status-json').then(function (r) {
      var s = parse(r.stdout);
      if (s) renderStatus(s);
    });
  }

  /* ---------- wiring ---------- */
  function wire() {
    $('enable-toggle').addEventListener('change', function () {
      setKey('enabled', this.checked ? 1 : 0, this.checked ? 'Clarity on' : 'Clarity paused')
        .then(refreshStatus);
    });

    document.querySelectorAll('.mode-card').forEach(function (card) {
      card.addEventListener('click', function () {
        var m = card.dataset.mode;
        setActiveMode(m);
        setKey('mode', m, 'Mode: ' + card.querySelector('.mode-name').textContent).then(refreshStatus);
      });
    });

    [['strength', ''], ['atten_db', ' dB'], ['vad', '']].forEach(function (pair) {
      var id = pair[0], suffix = pair[1];
      var el = $(id);
      el.addEventListener('input', function () {
        $(id + '-val').textContent = el.value + suffix;
        debouncedSet(id, el.value, null);
      });
    });

    $('highpass').addEventListener('change', function () { setKey('highpass', this.checked ? 1 : 0, 'Saved'); });
    $('autogain').addEventListener('change', function () { setKey('autogain', this.checked ? 1 : 0, 'Saved'); });

    document.querySelectorAll('.chip').forEach(function (chip) {
      chip.addEventListener('click', function () {
        chip.classList.toggle('active');
        var sel = [];
        document.querySelectorAll('.chip.active').forEach(function (c) { sel.push(c.dataset.target); });
        if (sel.length === 0) { chip.classList.add('active'); sel.push(chip.dataset.target); toast('Keep at least one source'); }
        setKey('targets', sel.join(','), 'Sources updated (re-flash to fully apply)');
      });
    });

    $('btn-apply').addEventListener('click', function () {
      ctl('apply').then(function () { toast('Applied'); refreshStatus(); });
    });
    $('btn-restart').addEventListener('click', function () {
      if (typeof confirm === 'function' && !confirm('Restart audioserver? Active recordings/calls will glitch briefly.')) return;
      toast('Restarting audio…');
      ctl('restart-audio').then(function () { setTimeout(refreshStatus, 1500); });
    });
    $('btn-log').addEventListener('click', function () {
      ctl('log').then(function (r) { $('log-content').textContent = r.stdout || r.stderr || '(empty)'; $('log-modal').classList.remove('hidden'); });
    });
    $('log-close').addEventListener('click', function () { $('log-modal').classList.add('hidden'); });
    $('log-modal').addEventListener('click', function (e) { if (e.target === this) this.classList.add('hidden'); });
    $('btn-reset').addEventListener('click', function () {
      if (typeof confirm === 'function' && !confirm('Reset all Clarifae settings to defaults?')) return;
      ctl('reset').then(function () { toast('Reset to defaults'); loadAll(); });
    });
    $('btn-refresh').addEventListener('click', refreshStatus);
  }

  /* ---------- init ---------- */
  document.addEventListener('DOMContentLoaded', function () {
    if (KSU.isMock) { var b = $('env-badge'); b.textContent = 'preview'; b.classList.remove('hidden'); }
    wire();
    loadAll();
    refreshTimer = setInterval(refreshStatus, 5000);
  });
})();
