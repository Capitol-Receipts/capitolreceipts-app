import React, { useCallback, useEffect, useRef, useState } from 'react';
import { ActivityIndicator, Linking, Pressable, StyleSheet, Text, View } from 'react-native';
import { StatusBar } from 'expo-status-bar';
import { WebView as RNWebView, WebViewMessageEvent } from 'react-native-webview';

// react-native-webview's class typings don't resolve against React 19's JSX types, so the component is typed loosely here
const WebView = RNWebView as unknown as React.ComponentType<any>;
import * as Notifications from 'expo-notifications';
import * as SplashScreen from 'expo-splash-screen';
import { SHIM } from './src/shim';
import { attach, handle } from './src/handlers';

SplashScreen.preventAutoHideAsync().catch(() => {});
Notifications.setNotificationHandler({
  handleNotification: async () => ({ shouldShowBanner: true, shouldShowList: true, shouldPlaySound: true, shouldSetBadge: false }),
});

const HOME = process.env.EXPO_PUBLIC_WEB_URL || 'https://app.capitolreceipts.com/?src=app';
const NAVY = '#14274e';
// pages that stay inside the app; everything else opens in Safari
const INSIDE = /^https:\/\/(app\.capitolreceipts\.com|[a-z0-9-]+\.supabase\.co|accounts\.google\.com|appleid\.apple\.com)(\/|$)/i;

export default function App() {
  const web = useRef<any>(null);
  const subs = useRef<Record<string, () => void>>({});
  const [failed, setFailed] = useState(false);
  const [loading, setLoading] = useState(true);

  const emit = useCallback((p: string, e: string, d: unknown) => {
    web.current?.injectJavaScript(`window.__crEmit&&window.__crEmit(${JSON.stringify(p)},${JSON.stringify(e)},${JSON.stringify(d)});true;`);
  }, []);

  const reply = useCallback((id: number, ok: boolean, v: unknown) => {
    web.current?.injectJavaScript(`window.__crReply(${id},${ok},${JSON.stringify(v ?? {})});true;`);
  }, []);

  const onMessage = useCallback((ev: WebViewMessageEvent) => {
    let m: any; try { m = JSON.parse(ev.nativeEvent.data); } catch { return; }
    if (m.t === 'listen') {
      const k = m.p + ':' + m.e;
      if (!subs.current[k]) subs.current[k] = attach(m.p, m.e, emit);
    } else if (m.t === 'call') {
      handle(m.p, m.m, m.a, emit).then((v) => reply(m.id, true, v), (e) => reply(m.id, false, e));
    }
  }, [emit, reply]);

  useEffect(() => () => { Object.values(subs.current).forEach((f) => f()); }, []);

  const hideSplash = () => { setLoading(false); SplashScreen.hideAsync().catch(() => {}); };

  return (
    <View style={s.root}>
      <StatusBar style="light" />
      {failed ? (
        <View style={s.center}>
          <Text style={s.h}>Can’t reach Capitol Receipts</Text>
          <Text style={s.p}>Check your connection and try again.</Text>
          <Pressable style={s.btn} onPress={() => { setFailed(false); setLoading(true); }}><Text style={s.bt}>Try again</Text></Pressable>
        </View>
      ) : (
        <WebView
          ref={web}
          source={{ uri: HOME }}
          style={s.web}
          injectedJavaScriptBeforeContentLoaded={`window.__CR_RC_KEY=${JSON.stringify(process.env.EXPO_PUBLIC_RC_IOS_KEY || '')};` + SHIM}
          onMessage={onMessage}
          onLoadEnd={hideSplash}
          onError={() => { setFailed(true); hideSplash(); }}
          onHttpError={(e: any) => { if (e.nativeEvent.statusCode >= 500) { setFailed(true); hideSplash(); } }}
          onShouldStartLoadWithRequest={(r: any) => {
            if (INSIDE.test(r.url) || r.url.startsWith('about:')) return true;
            Linking.openURL(r.url).catch(() => {});
            return false;
          }}
          onOpenWindow={(e: any) => { Linking.openURL(e.nativeEvent.targetUrl).catch(() => {}); }}
          contentInsetAdjustmentBehavior="never"
          allowsBackForwardNavigationGestures
          sharedCookiesEnabled
          pullToRefreshEnabled
          setSupportMultipleWindows
          applicationNameForUserAgent="CapitolReceiptsApp"
          backgroundColor={NAVY}
        />
      )}
      {loading && !failed && <View style={s.load} pointerEvents="none"><ActivityIndicator color="#fff" /></View>}
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: NAVY },
  web: { flex: 1, backgroundColor: NAVY },
  load: { ...StyleSheet.absoluteFill as object, alignItems: 'center', justifyContent: 'center' },
  center: { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 32 },
  h: { color: '#fff', fontSize: 22, fontWeight: '700', textAlign: 'center' },
  p: { color: '#fff', opacity: 0.85, marginTop: 8, textAlign: 'center' },
  btn: { marginTop: 20, backgroundColor: '#fff', borderRadius: 999, paddingVertical: 14, paddingHorizontal: 28 },
  bt: { color: NAVY, fontWeight: '700', fontSize: 16 },
});
