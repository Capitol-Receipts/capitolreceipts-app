import { Html, Head, Main, NextScript } from 'next/document';

// Where a visitor first came from (UTM tags, ad click IDs, referrer, first page), kept in one cookie for
// capitolreceipts.com and its subdomains so a sign-up on the app can be credited to it. Set once.
const FIRST_TOUCH = "(function(){try{var C='cr_ft',d=document;if(d.cookie.split('; ').some(function(c){return c.indexOf(C+'=')===0}))return;var u=new URL(location.href);if(/^admin\\./.test(u.hostname))return;var t={},k,v,ids={};['utm_source','utm_medium','utm_campaign','utm_content','utm_term'].forEach(function(k){var v=u.searchParams.get(k);if(v)t[k]=v.slice(0,200)});['gclid','fbclid','ttclid','msclkid','gbraid','wbraid'].forEach(function(k){var v=u.searchParams.get(k);if(v)ids[k]=v.slice(0,200)});if(Object.keys(ids).length)t.click_ids=ids;var own=/(^|\\.)capitolreceipts\\.com$/i;if(d.referrer&&!own.test(new URL(d.referrer).hostname))t.referrer=d.referrer.slice(0,500);t.landing_page=(u.pathname+u.search).slice(0,500);t.at=new Date().toISOString();d.cookie=C+'='+encodeURIComponent(JSON.stringify(t))+'; max-age=7776000; path=/; samesite=lax'+(own.test(u.hostname)?'; domain=.capitolreceipts.com':'')+(u.protocol==='https:'?'; secure':'')}catch(e){}})();";

export default function Document() {
  return (
    <Html lang="en">
      <Head />
      <body>
        <Main />
        <NextScript />
        <script dangerouslySetInnerHTML={{ __html: FIRST_TOUCH }} />
      </body>
    </Html>
  );
}
