/* Truffl — app-wide session/token refresh.
 *
 * Supabase access tokens expire after ~1h. The app previously discarded the refresh token and
 * had no refresh logic, so after an hour every authed call 401'd (users effectively logged out)
 * and native background GPS died. This wraps window.fetch: for Supabase requests carrying a user
 * token, on a 401 it refreshes the access token (via the stored refresh token) once and retries.
 *
 * Include it as a BLOCKING script high in <head> so window.fetch is patched before page scripts
 * run. Pages need no other change — they keep using their own sb* helpers.
 */
(function () {
  'use strict';

  var SUPABASE_URL = 'https://gadflsntbnbnnxbpiral.supabase.co';
  var ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdhZGZsc250Ym5ibm54YnBpcmFsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUwNjcwNTcsImV4cCI6MjA5MDY0MzA1N30.g5ZrqeAX9U5l7oDZEbQFrU5j10828dUF0QuJ0ZlHXK8';
  var ANON_BEARER = 'Bearer ' + ANON_KEY;
  var KEY = 'truffl_session';
  var origFetch = window.fetch.bind(window);
  var refreshing = null; // shared in-flight refresh so concurrent 401s trigger one POST

  function session() {
    try { return JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (e) { return null; }
  }
  function store(access, refresh) {
    var s = session() || {};
    s.access_token = access;
    if (refresh) s.refresh_token = refresh; // Supabase rotates the refresh token — keep the newest
    try { localStorage.setItem(KEY, JSON.stringify(s)); } catch (e) {}
  }
  function toLogin() {
    try { localStorage.removeItem(KEY); } catch (e) {}
    if (!/^\/login\/?/.test(location.pathname)) {
      location.href = '/login/?redirect=' + encodeURIComponent(location.pathname + location.search);
    }
  }
  function refresh() {
    if (refreshing) return refreshing;
    var s = session();
    if (!s || !s.refresh_token) return Promise.resolve(false);
    refreshing = origFetch(SUPABASE_URL + '/auth/v1/token?grant_type=refresh_token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'apikey': ANON_KEY },
      body: JSON.stringify({ refresh_token: s.refresh_token })
    })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) { if (d && d.access_token) { store(d.access_token, d.refresh_token); return true; } return false; })
      .catch(function () { return false; })
      .then(function (ok) { refreshing = null; return ok; });
    return refreshing;
  }

  window.fetch = function (input, init) {
    var url = (typeof input === 'string') ? input : null;
    // Only manage Supabase requests; never the token endpoint itself (would recurse).
    if (url === null || url.indexOf(SUPABASE_URL) !== 0 || url.indexOf('/auth/v1/token') !== -1) {
      return origFetch(input, init);
    }
    init = init || {};
    var auth = new Headers(init.headers || {}).get('Authorization');
    // Leave anon / unauthed requests alone (a 401 there isn't token expiry).
    if (!auth || auth === ANON_BEARER) return origFetch(input, init);

    function retry(token) {
      var h = new Headers(init.headers || {});
      if (token) h.set('Authorization', 'Bearer ' + token);
      return origFetch(url, Object.assign({}, init, { headers: h }));
    }

    return origFetch(input, init).then(function (res) {
      if (res.status !== 401) return res;
      var used = auth.replace(/^Bearer\s+/i, '');
      var cur = session();
      // Another request already refreshed past this token — just retry with the current one.
      if (cur && cur.access_token && cur.access_token !== used) return retry(cur.access_token);
      return refresh().then(function (ok) {
        if (!ok) { toLogin(); return res; }
        var s2 = session();
        return retry(s2 && s2.access_token);
      });
    });
  };
})();
