/* Shared theme toggle. Default = OS preference, override stored locally. */
(function () {
  'use strict';
  var KEY = 'aq-theme';
  var ICON_MOON = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg>';
  var ICON_SUN = '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>';
  function preferred() {
    try {
      var saved = localStorage.getItem(KEY);
      if (saved === 'light' || saved === 'dark') return saved;
    } catch (_) {}
    return window.matchMedia &&
      window.matchMedia('(prefers-color-scheme: light)').matches
      ? 'light'
      : 'dark';
  }
  function apply(t) {
    document.documentElement.setAttribute('data-theme', t);
    var btns = document.querySelectorAll('[data-theme-toggle]');
    for (var i = 0; i < btns.length; i++) {
      btns[i].innerHTML = t === 'light' ? ICON_MOON : ICON_SUN;
      btns[i].setAttribute('aria-label', t === 'light' ? 'Switch to dark mode' : 'Switch to light mode');
      btns[i].setAttribute('title', btns[i].getAttribute('aria-label'));
    }
  }
  // Apply before first paint (script loads in <head>).
  apply(preferred());
  document.addEventListener('DOMContentLoaded', function () {
    apply(preferred());
    document.querySelectorAll('[data-theme-toggle]').forEach(function (b) {
      b.addEventListener('click', function () {
        var next = document.documentElement.getAttribute('data-theme') === 'light' ? 'dark' : 'light';
        try { localStorage.setItem(KEY, next); } catch (_) {}
        apply(next);
      });
    });
  });
})();
