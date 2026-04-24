// builder-api/browser.js — tunnel browser console + uncaught errors to the
// builder-api `POST /log` endpoint, so anyone connected to `/ws` sees them
// live via {"type":"event","record":{"type":"browser_log",...}} frames.
//
// Paste into a <script> tag (or import) in your dev page. Edit the three
// constants below for your setup.
//
// USAGE
//   <script src="http://localhost:6666/../browser.js"></script>  <!-- NOT served by the API; copy the file -->
//   <script>BuilderAPILog.init({
//     url: 'http://localhost:6666',
//     password: 'your-builder-api-password',
//     source: 'my-web-app',            // becomes /events?type=my-web-app_log
//     levels: ['log','warn','error','info','debug']
//   });</script>
//
// SECURITY
//   The password ends up in your page's JS — so this is ONLY safe for local
//   dev where the page and the builder-api run on the same trusted machine
//   or LAN. Do NOT paste this into a production-facing site.

(function (global) {
  'use strict';

  var DEFAULT_LEVELS = ['log', 'warn', 'error', 'info', 'debug'];
  var initialized = false;

  function safeStringify(v) {
    if (typeof v === 'string') return v;
    if (v instanceof Error) return v.stack || String(v);
    try { return JSON.stringify(v); } catch (_) { return String(v); }
  }

  function serialize(args) {
    return Array.prototype.map.call(args, safeStringify).join(' ');
  }

  function init(opts) {
    if (initialized) return;
    initialized = true;

    opts = opts || {};
    var url      = (opts.url || '').replace(/\/+$/, '');
    var endpoint = url + '/log';
    var password = opts.password || '';
    var source   = opts.source || 'browser';
    var levels   = opts.levels || DEFAULT_LEVELS;
    var hookErrors = opts.hookErrors !== false;   // default on

    if (!url) {
      // Don't throw — the user might inject this before setting URL. Just
      // no-op silently rather than flooding the real console on every log.
      return;
    }

    function send(level, message, extra) {
      var body = {
        level: level,
        message: message,
        source: source,
        url: global.location ? global.location.href : '',
        timestamp: Date.now() / 1000,
      };
      if (extra) {
        for (var k in extra) {
          if (Object.prototype.hasOwnProperty.call(extra, k)) body[k] = extra[k];
        }
      }
      try {
        fetch(endpoint, {
          method: 'POST',
          mode: 'cors',
          credentials: 'omit',
          keepalive: true,       // delivery survives page unload
          headers: {
            'Content-Type': 'application/json',
            'X-Builder-API-Password': password,
          },
          body: JSON.stringify(body),
        }).catch(function () { /* swallow — don't recurse via console */ });
      } catch (_) { /* fetch not available, or offline */ }
    }

    // Wrap console methods. Each wrapped fn still calls the original so the
    // developer sees the log in their browser devtools too.
    levels.forEach(function (level) {
      var orig = global.console && global.console[level];
      if (typeof orig !== 'function') return;
      global.console[level] = function () {
        send(level, serialize(arguments));
        try { orig.apply(global.console, arguments); } catch (_) {}
      };
    });

    // Uncaught errors + unhandled promise rejections — arguably the most
    // useful things to see remotely. Stack traces go into `stack` so the
    // filter shows them without truncating the message.
    if (hookErrors && global.addEventListener) {
      global.addEventListener('error', function (e) {
        var msg = e.message || 'uncaught error';
        var stack = (e.error && e.error.stack) || '';
        send('error', msg, {
          stack: stack,
          filename: e.filename,
          lineno: e.lineno,
          colno: e.colno,
        });
      });
      global.addEventListener('unhandledrejection', function (e) {
        var r = e.reason;
        var msg = (r && (r.message || r.toString())) || 'unhandled rejection';
        var stack = (r && r.stack) || '';
        send('error', 'unhandledrejection: ' + msg, { stack: stack });
      });
    }
  }

  global.BuilderAPILog = { init: init };
})(typeof window !== 'undefined' ? window : this);
