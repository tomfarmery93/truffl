# Truffl Pets — native app (Capacitor)

The Truffl Pets iOS and Android apps are a thin [Capacitor](https://capacitorjs.com)
WebView shell around the existing site. The WebView loads the live site at
`https://trufflpets.com` (see `server.url` in `capacitor.config.json`), so **content
changes ship via the normal GitHub Pages deploy — no app-store resubmit needed**
for site updates. A resubmit is only required when native code, plugins,
permissions, icons/splash, or the app version change.

This doc is the runbook for the parts that must happen on a Mac with the native
toolchains (see **TRU-129**). The config and scaffold in this repo are ready;
the steps below add the platforms and build.

## Prerequisites (TRU-129)

- **macOS** with **Xcode** (+ Command Line Tools, an iOS simulator or device).
- **Android Studio** (+ an SDK and an emulator or device).
- **Node 18+**. (Capacitor 8 manages iOS dependencies with Swift Package
  Manager, so **CocoaPods is not required** — Xcode opens `App.xcodeproj` directly.)
- If git/build tooling errors with *"You have not agreed to the Xcode license"*,
  run `sudo xcodebuild -license accept`.

## First-time setup

From the repo root (`~/truffl`):

```bash
# 1. Install the Capacitor tooling pinned in package.json
npm install

# 2. Initialise Capacitor (only if capacitor.config.json were missing — it isn't,
#    so you can normally SKIP this. Listed for completeness.)
# npx cap init "Truffl Pets" com.trufflpets.app --web-dir=www

# 3. Add the native platforms (creates ios/ and android/, which we commit)
npx cap add ios
npx cap add android

# 4. Copy config + the offline fallback (www/) into the native projects
npx cap sync
```

## Open / run

```bash
npm run open:ios       # opens ios/App/App.xcworkspace in Xcode
npm run open:android   # opens android/ in Android Studio
# or run straight onto a device/simulator:
npm run run:ios
npm run run:android
```

In Xcode/Android Studio, pick a simulator/emulator or a connected device and Run.
The app should boot straight into the live Truffl site.

## What to verify (TRU-55 acceptance)

- All pages render with no layout regressions (home, search, booking, dashboard,
  messages, track, walk, trust-and-safety, privacy).
- **Auth has no regression:** sign in, confirm the session persists across an app
  relaunch (localStorage is scoped to `trufflpets.com` and survives).
- In-app navigation to deep paths works, e.g. `/track/?booking=<id>` and
  `/book/?provider=<id>` load correctly within the WebView.
- External links (e.g. the OAIC link on the privacy page) open in the system
  browser, not inside the app.
- Offline behaviour: with no network, the bundled `www/index.html` fallback shows
  a retry; reconnecting returns to the live site.

## Notes / follow-ups

- **Bundle ID / app name** (`com.trufflpets.app`, "Truffl Pets") are placeholders
  pending **TRU-128**. Change `appId`/`appName` in `capacitor.config.json`, then
  `npx cap sync`, before any store submission.
- **Background geolocation** on `/walk/` is **TRU-56** (separate plugin + native
  permission setup) — out of scope here.
- **Universal/App Links** (cold-opening a tapped `https://trufflpets.com/...` link
  from outside the app into the app) need an `apple-app-site-association` file and
  Android `assetlinks.json` hosted on the domain, plus associated-domains/intent
  filters. In-app routing already works since the WebView shares the origin; true
  universal links can be set up alongside the store submissions (TRU-57/TRU-58).
- App icons and splash screens are added at submission time (TRU-57/TRU-58),
  typically via `@capacitor/assets`.
