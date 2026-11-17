// Runs inside the web page before it loads. It gives the site the same `window.Capacitor` plugin surface the
// Capacitor shell had (app/js/native.js and social.js call it), and forwards each call to the Expo app.
export const SHIM = `(function(){
  if(window.Capacitor&&window.Capacitor.__expo)return;
  var pend={},seq=0,L={};
  function post(m){window.ReactNativeWebView.postMessage(JSON.stringify(m))}
  function call(p,m,a){return new Promise(function(res,rej){var id=++seq;pend[id]={res:res,rej:rej};post({t:'call',id:id,p:p,m:m,a:a===undefined?null:a})})}
  window.__crReply=function(id,ok,v){var h=pend[id];if(!h)return;delete pend[id];ok?h.res(v):h.rej(v)};
  window.__crEmit=function(p,e,d){var k=p+':'+e;(L[k]||[]).slice().forEach(function(f){try{f(d)}catch(x){}})};
  var cache={};
  function plugin(name){
    if(cache[name])return cache[name];
    var o={addListener:function(ev,fn){var k=name+':'+ev;(L[k]=L[k]||[]).push(fn);post({t:'listen',p:name,e:ev});
      return Promise.resolve({remove:function(){L[k]=(L[k]||[]).filter(function(f){return f!==fn})}})}};
    return cache[name]=new Proxy(o,{get:function(t,k){
      if(k in t)return t[k];
      if(typeof k!=='string'||k==='then'||k==='toJSON')return undefined;
      return function(a){return call(name,k,a)}}});
  }
  window.Capacitor={__expo:true,isNativePlatform:function(){return true},getPlatform:function(){return 'ios'},
    registerPlugin:plugin,Plugins:new Proxy({},{get:function(t,k){return typeof k==='string'?plugin(k):undefined}})};
  true;
})();`;
