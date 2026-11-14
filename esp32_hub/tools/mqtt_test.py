#!/usr/bin/env python3
"""End-to-end MQTT test with a tiny built-in broker (no extra software needed).
Usage:  python3 tools/mqtt_test.py <board-ip> <this-computer-ip>
The board must be on the same network and reachable by HTTP. The script starts a broker on port 1883 of this
computer, tells the board to use it, sends commands through MQTT and checks the board obeys (and ignores a wrong token).
Run it from a network where the board can reach this computer. It turns MQTT off again at the end."""
import json, socket, struct, sys, threading, time, base64, urllib.request, socketserver
if len(sys.argv) < 3: sys.exit(__doc__)
BOARD=sys.argv[1]; PCIP=sys.argv[2]
def http(path,data=None):
    r=urllib.request.Request('http://'+BOARD+path,data=(json.dumps(data).encode() if data is not None else None),headers={'Content-Type':'application/json'},method='POST' if data is not None else 'GET')
    return json.loads(urllib.request.urlopen(r,timeout=15).read())
# ---------- tiny MQTT 3.1.1 broker (QoS0 only, exact-topic subscriptions) ----------
def enc_len(n):
    out=b''
    while True:
        b=n%128; n//=128
        if n: b|=128
        out+=bytes([b])
        if not n: return out
def pkt(first,body): return bytes([first])+enc_len(len(body))+body
subs={}; retained={}; lock=threading.Lock(); log=[]
class H(socketserver.BaseRequestHandler):
    def read_pkt(self):
        h=self.request.recv(1)
        if not h: return None
        mult,n=1,0
        while True:
            b=self.request.recv(1)[0]; n+=(b&127)*mult; mult*=128
            if not b&128: break
        body=b''
        while len(body)<n:
            c=self.request.recv(n-len(body))
            if not c: return None
            body+=c
        return h[0],body
    def handle(self):
        self.request.settimeout(120)
        try:
            while True:
                p=self.read_pkt()
                if p is None: break
                t=p[0]>>4; body=p[1]
                if t==1:
                    name=body[2:2+struct.unpack('>H',body[:2])[0]]
                    log.append('CONNECT'); self.request.sendall(bytes([0x20,2,0,0]))
                elif t==3:
                    tl=struct.unpack('>H',body[:2])[0]; topic=body[2:2+tl].decode(); payload=body[2+tl:]
                    if p[0]&1: retained[topic]=payload
                    with lock: targets=list(subs.get(topic,[]))
                    for s in targets:
                        try: s.sendall(pkt(0x30,struct.pack('>H',len(topic.encode()))+topic.encode()+payload))
                        except Exception: pass
                elif t==8:
                    pid=body[:2]; i=2; granted=b''
                    while i<len(body):
                        tl=struct.unpack('>H',body[i:i+2])[0]; topic=body[i+2:i+2+tl].decode(); i+=3+tl
                        with lock: subs.setdefault(topic,[]).append(self.request)
                        granted+=b'\x00'
                        log.append('SUB '+topic)
                        if topic in retained: self.request.sendall(pkt(0x30,struct.pack('>H',len(topic.encode()))+topic.encode()+retained[topic]))
                    self.request.sendall(pkt(0x90,pid+granted))
                elif t==12: self.request.sendall(bytes([0xD0,0]))
                elif t==14: break
        except Exception: pass
class S(socketserver.ThreadingTCPServer): allow_reuse_address=True; daemon_threads=True
srv=S(('0.0.0.0',1883),H); threading.Thread(target=srv.serve_forever,daemon=True).start()
print('broker up on :1883')
# ---------- configure the board ----------
tok=http('/api/cmd',{'cmd':'token'})['token']; hid=http('/api/list')['id']
print('device id',hid,'token',tok)
print('mqtt cfg ->',http('/api/cmd',{'cmd':'mqtt','on':True,'host':PCIP,'port':1883,'user':'','pass':'','tls':False}))
for i in range(30):
    time.sleep(1)
    if any(l.startswith('SUB esp32hub/%s/cmd'%hid) for l in log): break
print('board connected & subscribed:',any(l.startswith('SUB esp32hub/%s/cmd'%hid) for l in log))
time.sleep(1.5)
print('retained list published:', ('esp32hub/%s/list'%hid) in retained, '| state:', retained.get('esp32hub/%s/state'%hid))
print('online flag:', retained.get('esp32hub/%s/online'%hid))
# ---------- test client ----------
c=socket.create_connection(('127.0.0.1',1883)); c.settimeout(8)
def send(p): c.sendall(p)
send(pkt(0x10,b'\x00\x04MQTT\x04\x02\x00\x3c'+struct.pack('>H',4)+b'test')); c.recv(4)
topic_res='esp32hub/%s/res'%hid
t=topic_res.encode(); send(pkt(0x82,b'\x00\x01'+struct.pack('>H',len(t))+t+b'\x00')); c.recv(5)   # SUBACK
def publish(obj):
    topic=('esp32hub/%s/cmd'%hid).encode(); payload=json.dumps(obj).encode()
    send(pkt(0x30,struct.pack('>H',len(topic))+topic+payload))
def get_res(timeout=6):
    c.settimeout(timeout)
    try:
        h=c.recv(1)
        if not h: return None
        mult,n=1,0
        while True:
            b=c.recv(1)[0]; n+=(b&127)*mult; mult*=128
            if not b&128: break
        body=b''
        while len(body)<n: body+=c.recv(n-len(body))
        tl=struct.unpack('>H',body[:2])[0]; return json.loads(body[2+tl:])
    except Exception as e: return None
publish({'cmd':'scene','id':'stars','t':tok}); print('scene via MQTT   ->',get_res())
print('status says scene:',http('/api/status')['scene'])
publish({'cmd':'scene','id':'plasma','t':'wrongtoken'}); print('wrong token      ->',get_res(4),'(expect None = ignored)')
print('status still     :',http('/api/status')['scene'],'(expect stars)')
publish({'cmd':'msg','text':'Hello over MQTT','ttl':3,'t':tok}); print('msg via MQTT     ->',get_res())
strip=base64.b64encode(bytes(160*16*2)).decode()
publish({'cmd':'pixels','x':0,'y':0,'w':160,'h':16,'data':strip,'t':tok}); print('6.8KB pixel strip ->',get_res())
print('heap now',http('/api/status')['heap'])
print('MQTT test done'); srv.shutdown()
print('mqtt off ->',http('/api/cmd',{'cmd':'mqtt','on':False}))
