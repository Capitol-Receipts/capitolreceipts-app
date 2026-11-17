# Capitol Receipts, Expo app

Expo app that loads https://app.capitolreceipts.com in a WebView and gives the site the native pieces it needs:
Apple in-app purchase (RevenueCat), push alerts, Face ID lock, Apple and Google sign-in, share sheet, links that open the app.
`src/shim.ts` recreates the `window.Capacitor` plugin calls the web code already makes, and `src/handlers.ts` answers them natively,
so the website code is shared with the old Capacitor shell in `apps/mobile` (kept until this build is proven).

## Build without a Mac (EAS)
```sh
cd apps/mobile-expo
npm i -g eas-cli && eas login
eas init                       # links the Expo project
eas env:create --name EXPO_PUBLIC_RC_IOS_KEY --value appl_xxx --environment production --visibility plaintext
eas build --platform ios --profile production   # asks for your Apple login once, makes certificates and profiles
eas submit --platform ios --latest              # sends it to App Store Connect / TestFlight
```
Not in this build yet: the home-screen widget (needs a native extension). The site hides nothing for it; the app just doesn't send widget data.

Account settings (RevenueCat entitlement `pro`, offering `default`, webhook, APNs key, Team ID) are the same as in `apps/mobile/README.md`.
