"""Internal, credential-free Chromium bridge for the public-web built-in.

HTTP, document parsing and workflow policy live in the native node. This helper
only supplies the optional Playwright renderer; authors never provide scripts.
Every browser request is intercepted and fulfilled through pinned HTTPS.
"""
import http.client
import ipaddress
import json
import re
import socket
import ssl
import sys
import time
import urllib.parse


def public_address(value):
    ip=ipaddress.ip_address(value)
    if ip.version==6 and ip.ipv4_mapped:return public_address(str(ip.ipv4_mapped))
    if ip.version==6:
        return ip in ipaddress.ip_network('2000::/3') and not any(ip in ipaddress.ip_network(x)
            for x in ('2001::/23','2001:db8::/32','2002::/16','3fff::/20'))
    if value in ('192.0.0.9','192.0.0.10'):return True
    return not any(ip in ipaddress.ip_network(x)for x in (
        '0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16','172.16.0.0/12',
        '192.0.0.0/24','192.0.2.0/24','192.88.99.0/24','192.168.0.0/16','198.18.0.0/15',
        '198.51.100.0/24','203.0.113.0/24','224.0.0.0/4','240.0.0.0/4'))


def destination(url,blocked):
    if not isinstance(url,str)or len(url.encode())>4096 or any(ord(x)<32 or ord(x)==127 for x in url):raise ValueError('invalid-url')
    p=urllib.parse.urlsplit(url)
    if p.scheme!='https'or not p.hostname or p.username is not None or p.password is not None or p.port not in (None,443):raise ValueError('invalid-url')
    host=p.hostname.encode('idna').decode('ascii').lower().rstrip('.')
    if any(host==value or host.endswith('.'+value)for value in blocked):raise ValueError('blocked')
    addresses=socket.getaddrinfo(host,443,type=socket.SOCK_STREAM)
    if not addresses or any(not public_address(row[4][0])for row in addresses):raise ValueError('nonpublic')
    return p,host,addresses[0][4][0]


class PinnedHTTPS(http.client.HTTPSConnection):
    def __init__(self,host,ip,timeout):
        super().__init__(host,timeout=timeout,context=ssl.create_default_context());self.ip=ip
    def connect(self):
        sock=socket.create_connection((self.ip,443),self.timeout)
        self.sock=self._context.wrap_socket(sock,server_hostname=self.host)


def render(url,opts,blocked,*,transport=None,playwright=None):
    if playwright is None:
        from playwright.sync_api import sync_playwright
        playwright=sync_playwright
    deadline=time.monotonic()+opts['timeout_ms']/1000
    budget={'requests':0,'bytes':0}
    def fetch(target,method='GET',headers=None,body=None):
        for hop in range(4):
            p,host,ip=destination(target,blocked)
            budget['requests']+=1
            left=deadline-time.monotonic()
            if left<=0 or budget['requests']>100 or budget['bytes']>=20_000_000:raise ValueError('budget')
            maximum=min(2_000_000,20_000_000-budget['bytes'])
            if transport is not None:status,response_headers,raw=transport(target,method,headers,body,maximum)
            else:
                conn=PinnedHTTPS(host,ip,min(left,25))
                try:
                    conn.request(method,urllib.parse.urlunsplit(('', '',p.path or '/',p.query,'')),body,
                        {'User-Agent':'Riela-Public-Web/1','Accept-Encoding':'identity',**(headers or {})})
                    response=conn.getresponse();status=response.status;response_headers=dict(response.getheaders())
                    raw=response.read(maximum+1)
                finally:conn.close()
            if len(raw)>maximum:raise ValueError('oversized')
            budget['bytes']+=len(raw)
            if status in (301,302,303,307,308):
                if hop==3 or method not in ('GET','HEAD'):raise ValueError('redirect')
                location=next((v for k,v in response_headers.items()if k.lower()=='location'),'')
                target=urllib.parse.urljoin(target,location)
                continue
            return target,status,response_headers,raw
        raise ValueError('redirect')
    destination(url,blocked)
    with playwright()as pw:
        browser=pw.chromium.launch(headless=True,chromium_sandbox=True,args=['--disable-background-networking','--disable-component-update',
            '--disable-domain-reliability','--disable-sync','--no-pings','--dns-prefetch-disable',
            '--force-webrtc-ip-handling-policy=disable_non_proxied_udp'])
        context=browser.new_context(service_workers='block',accept_downloads=False,offline=True)
        context.set_default_timeout(opts['timeout_ms'])
        context.add_init_script("""Object.defineProperty(Navigator.prototype,'onLine',{get:()=>true,configurable:false});
          for(const name of ['RTCPeerConnection','webkitRTCPeerConnection','WebTransport'])
          Object.defineProperty(globalThis,name,{value:undefined,writable:false,configurable:false});""")
        final,status,headers,raw=fetch(url);cached=[status,headers,raw]
        def route_request(route):
            req=route.request
            if req.resource_type in ('image','media','font')or req.method not in ('GET','HEAD','POST'):
                route.abort();return
            try:
                if req.url==final and req.is_navigation_request()and cached:
                    status,response_headers,raw=cached[:];cached.clear()
                else:
                    headers={'Accept':req.headers.get('accept','*/*')}
                    if 'content-type'in req.headers:headers['Content-Type']=req.headers['content-type']
                    body=req.post_data_buffer
                    if body and len(body)>65536:raise ValueError('oversized')
                    _,status,response_headers,raw=fetch(req.url,req.method,headers,body)
                response_headers={k:v for k,v in response_headers.items()if k.lower()not in
                    ('set-cookie','content-encoding','content-length','transfer-encoding')}
                route.fulfill(status=status,headers=response_headers,body=raw)
            except Exception:route.abort()
        context.route('**/*',route_request)
        context.route_web_socket('**/*',lambda socket:socket.close())
        page=context.new_page()
        page.goto(final,wait_until='domcontentloaded',timeout=max(1,int((deadline-time.monotonic())*1000)))
        page.wait_for_timeout(min(opts['wait_ms'],max(0,int((deadline-time.monotonic())*1000))))
        value=page.evaluate(r'''() => {
          const visible=el=>{const s=getComputedStyle(el);return !el.hidden&&el.getAttribute('aria-hidden')!=='true'&&s.display!=='none'&&s.visibility!=='hidden'&&el.getClientRects().length>0;};
          let root=document.body;
          for(const selector of ['article','main, [role="main"]']){
            const found=Array.from(document.querySelectorAll(selector)).slice(0,20).filter(el=>visible(el)&&(el.innerText||'').replace(/\s/g,'').length>=80).sort((a,b)=>b.innerText.length-a.innerText.length);
            if(found.length){root=found[0];break;}}
          return {url:location.href,title:document.title,text:(root?.innerText||'').slice(0,50000),
            published_at:document.querySelector('meta[property="article:published_time"],meta[name="datePublished"],meta[name="date"]')?.content?.slice(0,80)||null,
            links:Array.from((root||document).querySelectorAll('a[href]')).slice(0,200).map(a=>a.href)};
        }''')
        browser.close()
        return value


if __name__=='__main__':
    try:
        value=json.loads(sys.stdin.buffer.read(100001))
        blocked=value.get('blocked_hosts',[])
        if not isinstance(blocked,list)or len(blocked)>20 or any(not isinstance(x,str)or not re.fullmatch(r'[a-z0-9.-]{1,253}',x)for x in blocked):raise ValueError('policy')
        print(json.dumps(render(value['url'],value['options'],blocked)))
    except Exception:sys.exit(1)
