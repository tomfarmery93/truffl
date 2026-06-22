import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  // TODO(TRU-128): confirm the final bundle ID + app name before store submission.
  // This must match the App ID registered in Apple Developer + the Android applicationId.
  appId: 'com.trufflpets.app',
  appName: 'Truffl Pets',

  // Capacitor requires a webDir even when loading a remote server.url. We point it
  // at www/, which holds a tiny offline fallback shown only if the remote can't load.
  webDir: 'www',

  server: {
    // Remote WebView: the app always loads the live GitHub Pages site, so content
    // changes ship without an app-store resubmit. Auth/session (localStorage) is
    // scoped to this origin and persists across launches.
    url: 'https://trufflpets.com',
    cleartext: false,
    // Keep navigations to our own origin inside the WebView. Anything else (external
    // links such as oaic.gov.au) opens in the system browser. Supabase REST/auth
    // calls are XHR/fetch, not navigations, so they aren't gated by this list.
    allowNavigation: ['trufflpets.com', 'www.trufflpets.com'],
  },

  ios: {
    // Let the WebView manage safe-area insets so sticky navs sit below the notch.
    contentInset: 'always',
  },
};

export default config;
