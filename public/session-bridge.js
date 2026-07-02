/*
 * Svipe session bridge — lets Telegram Web A (telegram-tt fork) and Web K (tweb fork)
 * share one MTProto login when served from the same origin (…/a/ and …/k/).
 *
 * Both clients already store the auth material in localStorage with the same key
 * names and the same 512-hex-char auth_key encoding (K's updateStorageForLegacy()
 * was built by upstream exactly for A↔K handoff). The remaining gaps this script
 * closes, synchronously before either app boots:
 *   1. A stores account1.userId as a string, K expects a number (K decides
 *      "already signed in" by account1.userId in loadStateForAccount).
 *   2. A may leave account1.userId unset early in its lifecycle — recover it
 *      from legacy user_auth.
 *   3. If only the flat legacy keys exist, synthesize account1 from them.
 *
 * Must stay a classic (non-module) script so it blocks until done.
 * Never throws: a broken bridge must not take the messenger down with it.
 */
(function() {
  try {
    var isK = /\/k\//.test(location.pathname) || /\/k$/.test(location.pathname);

    function readJSON(key) {
      try {
        var raw = localStorage.getItem(key);
        return raw ? JSON.parse(raw) : null;
      } catch (e) {
        return null;
      }
    }

    var HEX_KEY_LEN = 512; // 256-byte MTProto auth_key as hex
    var acc = readJSON('account1');
    var userAuth = readJSON('user_auth');
    var changed = false;

    function hasAuthKey(obj) {
      if (!obj) return false;
      for (var i = 1; i <= 5; i++) {
        var v = obj['dc' + i + '_auth_key'];
        if (typeof v === 'string' && v.length === HEX_KEY_LEN) return true;
      }
      return false;
    }

    // 3. Synthesize account1 from flat legacy keys if it's absent/empty.
    if (!hasAuthKey(acc)) {
      var legacy = {};
      var found = false;
      for (var i = 1; i <= 5; i++) {
        var v = readJSON('dc' + i + '_auth_key');
        if (typeof v === 'string' && v.length === HEX_KEY_LEN) {
          legacy['dc' + i + '_auth_key'] = v;
          found = true;
        }
      }
      if (found && userAuth && userAuth.id) {
        acc = acc || {};
        for (var k in legacy) acc[k] = legacy[k];
        acc.dcId = Number(userAuth.dcID) || Number(localStorage.getItem('dc')) || 2;
        acc.userId = userAuth.id;
        acc.date = Math.floor(Date.now() / 1000);
        changed = true;
      }
    }

    if (acc && hasAuthKey(acc)) {
      // 2. Recover userId from user_auth when the slot lacks it.
      if (!acc.userId && userAuth && userAuth.id) {
        acc.userId = userAuth.id;
        changed = true;
      }

      // 1. Normalize userId type for the app that is about to boot.
      if (acc.userId != null) {
        if (isK && typeof acc.userId === 'string' && /^\d+$/.test(acc.userId)) {
          acc.userId = Number(acc.userId);
          changed = true;
        } else if (!isK && typeof acc.userId === 'number') {
          acc.userId = String(acc.userId);
          changed = true;
        }
      }

      if (!acc.dcId) {
        var dc = Number(localStorage.getItem('dc')) || (userAuth && Number(userAuth.dcID));
        if (dc) {
          acc.dcId = dc;
          changed = true;
        }
      }

      if (changed) localStorage.setItem('account1', JSON.stringify(acc));

      // Mirror the slot back into the flat legacy keys so the other client's
      // legacy read path also works (works for both: A reads them at boot,
      // K's fingerprint check in CHANGED_AUTH reads dc{baseDc}_auth_key).
      if (acc.userId && !localStorage.getItem('user_auth')) {
        localStorage.setItem('user_auth', JSON.stringify({
          dcID: acc.dcId || 2,
          date: Math.floor(Date.now() / 1000),
          id: typeof acc.userId === 'string' && /^\d+$/.test(acc.userId) ? Number(acc.userId) : acc.userId
        }));
      }
      if (!localStorage.getItem('dc') && acc.dcId) {
        localStorage.setItem('dc', String(acc.dcId));
      }
      for (var j = 1; j <= 5; j++) {
        var name = 'dc' + j + '_auth_key';
        if (acc[name] && !localStorage.getItem(name)) {
          localStorage.setItem(name, JSON.stringify(acc[name]));
        }
      }
    }
  } catch (e) {
    /* never break app boot */
  }
})();
