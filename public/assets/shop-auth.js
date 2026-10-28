/* AnimeQuiz website identity — shared by the shop (index.html) and the
 * post-payment page (success.html).
 *
 * Loaded as a CLASSIC script AFTER the Firebase compat SDK, BEFORE the page's
 * own script:
 *
 *   firebase-app-compat.js
 *   firebase-auth-compat.js
 *   /assets/shop-auth.js     <- this file
 *   <inline page script>
 *
 * Classic scripts execute in document order, so `window.ShopAuth` is ready
 * synchronously when page logic runs. That is deliberate: an ESM module would
 * be deferred and every page would need a ready-promise dance, and both pages
 * already have a poll/retry loop that does not need another one.
 *
 * The API key below is public by design — it identifies the Firebase project,
 * not a user. Auth requires the hosting domain to be in the project's
 * authorized domains, which anime-quiz-1ab1b.web.app already is.
 */
(function () {
  'use strict';

  var config = {
    apiKey: 'AIzaSyBTjNAnbxqRVT99MoUhTXkUXaHsA7bx0Fw',
    authDomain: 'anime-quiz-1ab1b.firebaseapp.com',
    projectId: 'anime-quiz-1ab1b',
    appId: '1:342531348832:web:cd22eda602fd1cc2982605',
    messagingSenderId: '342531348832'
  };

  // Errors a shopper can actually act on, in their words. Anything else falls
  // back to a generic line rather than leaking Firebase's internals.
  var FRIENDLY = {
    'auth/invalid-email': 'That email address is not valid.',
    'auth/invalid-credential': 'Email or password is incorrect.',
    'auth/wrong-password': 'Email or password is incorrect.',
    'auth/user-not-found': 'Email or password is incorrect.',
    'auth/user-disabled': 'This account has been disabled.',
    'auth/missing-password': 'Enter your password.',
    'auth/too-many-requests': 'Too many attempts. Wait a few minutes and try again.',
    'auth/network-request-failed': 'No connection. Check your internet and try again.'
  };

  // The SDK can fail to load (offline, CSP, an aggressive ad-blocker). Expose
  // null so the pages render "sign-in unavailable" instead of throwing and
  // leaving a dead buy button.
  if (!window.firebase || !window.firebase.auth) {
    window.ShopAuth = null;
    return;
  }

  var app;
  try {
    app = window.firebase.app();
  } catch (_) {
    app = window.firebase.initializeApp(config);
  }
  var auth = window.firebase.auth(app);

  // Explicit, not just default: the buyer must still be signed in when
  // Flutterwave redirects back to success.html, often in the same tab.
  auth.setPersistence(window.firebase.auth.Auth.Persistence.LOCAL).catch(function () {});

  var listeners = [];
  var currentUser = auth.currentUser;
  var resolveReady;
  var ready = new Promise(function (resolve) { resolveReady = resolve; });
  var first = true;

  auth.onAuthStateChanged(function (user) {
    currentUser = user;
    if (first) {
      first = false;
      resolveReady(user);
    }
    for (var i = 0; i < listeners.length; i++) {
      try { listeners[i](user); } catch (_) { /* a page handler must not break auth */ }
    }
  });

  window.ShopAuth = {
    // Resolves once the persisted session has been restored (or found absent).
    ready: ready,

    user: function () { return currentUser; },
    isSignedIn: function () { return !!currentUser; },

    email: function () { return (currentUser && currentUser.email) || ''; },

    isVerified: function () { return !!(currentUser && currentUser.emailVerified); },

    reload: function () {
      return currentUser
        ? currentUser.reload().then(function () {
            currentUser = auth.currentUser;
            return currentUser;
          })
        : Promise.resolve(null);
    },

    sendVerification: function () {
      return currentUser ? currentUser.sendEmailVerification() : Promise.reject(new Error('not_signed_in'));
    },

    // Always ask the SDK: it returns the cached token until it is about to
    // expire, then refreshes. A stale token is the main source of 401s here.
    getIdToken: function () {
      return currentUser ? currentUser.getIdToken() : Promise.resolve(null);
    },

    signIn: function (email, password) {
      return auth.signInWithEmailAndPassword(String(email).trim(), password);
    },

    // Accounts are created in the app only. The reset mail still works for
    // them because it is the same Firebase Auth user.
    sendReset: function (email) {
      return auth.sendPasswordResetEmail(String(email).trim());
    },

    signOut: function () { return auth.signOut(); },

    // Fires immediately with the current state, then on every change.
    onChange: function (fn) {
      listeners.push(fn);
      try { fn(currentUser); } catch (_) {}
      return function () {
        var i = listeners.indexOf(fn);
        if (i >= 0) listeners.splice(i, 1);
      };
    },

    errorMessage: function (err) {
      return FRIENDLY[err && err.code] || 'Could not sign you in. Please try again.';
    }
  };
})();
