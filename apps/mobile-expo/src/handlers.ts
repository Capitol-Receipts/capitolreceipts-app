import { Platform, Share, AppState, Linking } from 'react-native';
import * as Application from 'expo-application';
import * as Notifications from 'expo-notifications';
import * as LocalAuthentication from 'expo-local-authentication';
import * as AppleAuthentication from 'expo-apple-authentication';
import * as SplashScreen from 'expo-splash-screen';
import Purchases from 'react-native-purchases';
import { GoogleSignin } from '@react-native-google-signin/google-signin';

type Emit = (plugin: string, event: string, data: unknown) => void;
type Args = any;

let packages: Record<string, any> = {};

const handlers: Record<string, Record<string, (a: Args) => Promise<unknown> | unknown>> = {
  App: {
    getInfo: () => ({ version: Application.nativeApplicationVersion || '1.0.0', build: Application.nativeBuildVersion || '1' }),
  },
  SplashScreen: { hide: () => SplashScreen.hideAsync().catch(() => {}) },
  Share: {
    share: (a) => Share.share({ title: a?.title, message: a?.text, url: a?.url }).then(() => ({})),
  },
  PushNotifications: {
    checkPermissions: async () => ({ receive: map((await Notifications.getPermissionsAsync()).status) }),
    requestPermissions: async () => ({ receive: map((await Notifications.requestPermissionsAsync()).status) }),
    // registration is answered through the 'registration' event, like the Capacitor plugin
    register: () => { /* handled in attach() so it can emit */ },
    createChannel: () => ({}),
  },
  Purchases: {
    configure: async (a) => { Purchases.configure({ apiKey: a.apiKey, appUserID: a.appUserID }); return {}; },
    logIn: async (a) => ({ ...(await Purchases.logIn(a.appUserID)) }),
    logOut: async () => ({ customerInfo: await Purchases.logOut() }),
    getOfferings: async () => {
      const o = await Purchases.getOfferings();
      packages = {};
      (o.current?.availablePackages || []).forEach((p) => { packages[p.identifier] = p; });
      return o;
    },
    purchasePackage: async (a) => {
      const pk = packages[a?.aPackage?.identifier];
      if (!pk) throw { message: 'package not found', code: 'unavailable' };
      try { return await Purchases.purchasePackage(pk); }
      catch (e: any) { throw { message: e?.message, code: e?.code, userCancelled: !!e?.userCancelled }; }
    },
    restorePurchases: async () => ({ customerInfo: await Purchases.restorePurchases() }),
  },
  CRNative: {
    biometricStatus: async () => {
      const has = await LocalAuthentication.hasHardwareAsync();
      const on = has && (await LocalAuthentication.isEnrolledAsync());
      const types = await LocalAuthentication.supportedAuthenticationTypesAsync();
      const face = types.includes(LocalAuthentication.AuthenticationType.FACIAL_RECOGNITION);
      return { available: !!on, type: face ? 'faceID' : 'touchID' };
    },
    authenticate: async (a) => {
      const r = await LocalAuthentication.authenticateAsync({ promptMessage: a?.reason || 'Unlock Capitol Receipts' });
      return { ok: r.success };
    },
    // the home-screen widget needs a native extension; the Expo shell doesn't ship one yet
    setWidgetData: () => ({}),
  },
  SocialLogin: {
    initialize: () => ({}),
    login: async (a) => {
      const hashedNonce = a?.options?.nonce;
      if (a.provider === 'apple') {
        const c = await AppleAuthentication.signInAsync({
          requestedScopes: [AppleAuthentication.AppleAuthenticationScope.EMAIL, AppleAuthentication.AppleAuthenticationScope.FULL_NAME],
          nonce: hashedNonce,
        });
        return { result: { idToken: c.identityToken, authorizationCode: c.authorizationCode, profile: { givenName: c.fullName?.givenName, familyName: c.fullName?.familyName } } };
      }
      GoogleSignin.configure({
        iosClientId: '37666810110-g2jmvu9tfn58qr1hhb448mvghmefce2j.apps.googleusercontent.com',
        webClientId: '37666810110-kd1vc52i3qpeq1rt3gkba3rmhrfqm07h.apps.googleusercontent.com',
      });
      await GoogleSignin.hasPlayServices().catch(() => {});
      const r: any = await GoogleSignin.signIn({ nonce: hashedNonce } as any);
      if (r?.type === 'cancelled') throw { message: 'cancelled' };
      const d = r?.data || r;
      return { result: { idToken: d?.idToken, profile: { givenName: d?.user?.givenName, familyName: d?.user?.familyName } } };
    },
  },
};

const map = (s: string) => (s === 'granted' ? 'granted' : s === 'denied' ? 'denied' : 'prompt');

export async function handle(plugin: string, method: string, args: Args, emit: Emit) {
  if (plugin === 'PushNotifications' && method === 'register') {
    try {
      const t = await Notifications.getDevicePushTokenAsync(); // the raw APNs token, which send-alerts delivers to
      emit('PushNotifications', 'registration', { value: String(t.data) });
    } catch (e) { emit('PushNotifications', 'registrationError', { error: String(e) }); }
    return {};
  }
  const fn = handlers[plugin]?.[method];
  if (!fn) return {};
  return (await fn(args)) ?? {};
}

// events the page listens for
export function attach(plugin: string, event: string, emit: Emit): () => void {
  if (plugin === 'App' && event === 'appStateChange') {
    const s = AppState.addEventListener('change', (st) => emit('App', 'appStateChange', { isActive: st === 'active' }));
    return () => s.remove();
  }
  if (plugin === 'App' && event === 'appUrlOpen') {
    const s = Linking.addEventListener('url', (e) => emit('App', 'appUrlOpen', { url: e.url }));
    Linking.getInitialURL().then((u) => { if (u) emit('App', 'appUrlOpen', { url: u }); });
    return () => s.remove();
  }
  if (plugin === 'PushNotifications' && event === 'pushNotificationActionPerformed') {
    const s = Notifications.addNotificationResponseReceivedListener((r) =>
      emit('PushNotifications', 'pushNotificationActionPerformed', { notification: { data: r.notification.request.content.data } }));
    return () => s.remove();
  }
  return () => {};
}

export const isIOS = Platform.OS === 'ios';
