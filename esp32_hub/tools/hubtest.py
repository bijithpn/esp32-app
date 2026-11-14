#!/usr/bin/env python3
"""Smoke-test the ESP32 Hub HTTP API: starts every scene and sends every command.
Usage:  python3 tools/hubtest.py [device-ip]      (default 192.168.4.1 = setup hotspot)
Watch the display while it runs. Ends with FAILED: none when everything passes.
(The 'expect FAIL' lines are deliberate bad inputs and are not counted.)"""
import json, sys, time, base64, struct, urllib.request
B='http://'+(sys.argv[1] if len(sys.argv)>1 else '192.168.4.1')
def get(p): return json.loads(urllib.request.urlopen(B+p,timeout=6).read())
def cmd(o):
    r=urllib.request.Request(B+'/api/cmd',data=json.dumps(o).encode(),method='POST',headers={'Content-Type':'application/json'})
    return json.loads(urllib.request.urlopen(r,timeout=8).read())
fails=[]
LOW=False   # set below: setup mode with Bluetooth on leaves only ~30 KB RAM, too little for image payloads
def t(name,o,wait=0.6):
    if LOW and (name.startswith('pixels') or name.startswith('anim frame') or name=='anim play'):
        print('SKIP',name,'(low RAM: setup mode with Bluetooth on)'); return
    try:
        r=cmd(o); ok=r.get('ok') is True
    except Exception as e: ok=False; r=str(e)
    print(('PASS' if ok else 'FAIL'),name,'' if ok else r)
    if not ok: fails.append(name)
    time.sleep(wait)
for _try in range(10):                       # the first request after joining a network is often slow
    try: st0=get('/api/status'); break
    except Exception: time.sleep(2)
else: sys.exit('Cannot reach the board at '+B)
print('start uptime',st0['uptime'],'heap',st0['heap'])
LOW = st0['heap'] < 60000
if LOW: print('NOTE: low free RAM (setup mode with Bluetooth on): image/animation tests are skipped. Run again once the board is on your Wi-Fi.')
for s in get('/api/list')['scenes']:
    if s['id']=='message': continue
    t('scene '+s['id'],{'cmd':'scene','id':s['id']},1.2)
t('eyes happy',{'cmd':'scene','id':'eyes','args':{'mood':'happy'}})
t('eyes angry',{'cmd':'scene','id':'eyes','args':{'mood':'angry'}})
t('bounce text',{'cmd':'scene','id':'bounce','args':{'text':'HELLO'}})
t('name text',{'cmd':'scene','id':'name','args':{'text':'Afsal'}})
t('msg',{'cmd':'msg','text':'Good morning!','ttl':3},1.5)
t('pomo start',{'cmd':'pomo','action':'start','work':25,'brk':5},1.5)
t('pomo pause',{'cmd':'pomo','action':'pause'})
t('pet feed',{'cmd':'pet','action':'feed'},2.5)
t('pet sleep',{'cmd':'pet','action':'sleep'},1)
t('say',{'cmd':'say','text':'Hello! I am your tiny desk buddy and I can talk about anything you like.'},2)
for i in range(6): t('bands %d'%i,{'cmd':'bands','v':[(i*40+j*15)%255 for j in range(16)]},0.15)
t('nowplaying',{'cmd':'nowplaying','title':'Midnight City','artist':'M83','dur':243,'pos':30,'playing':True},1.5)
t('loc',{'cmd':'loc','lat':9.93,'lon':76.27})
t('tz',{'cmd':'tz','sec':19800})
t('auto on',{'cmd':'auto','sec':5}); t('auto off',{'cmd':'auto','sec':0}); t('next',{'cmd':'next'})
# pixel frame: horizontal rainbow gradient, 8 strips of 16 rows, RGB565 little-endian
def px(r,g,b): return ((r&0xF8)<<8)|((g&0xFC)<<3)|(b>>3)
for y in range(0,128,16):
    row=b''.join(struct.pack('<H',px(int(255*x/159),int(255*(y/127)),255-int(255*x/159))) for x in range(160))
    t('pixels y=%d'%y,{'cmd':'pixels','x':0,'y':y,'w':160,'h':16,'data':base64.b64encode(row*16).decode()},0.05)
time.sleep(2)
t('bad rect (expect FAIL)',{'cmd':'pixels','x':200,'y':0,'w':16,'h':16,'data':''},0.1)
fails=[f for f in fails if 'expect' not in f]
t('unknown cmd (expect FAIL)',{'cmd':'nope'},0.1); fails=[f for f in fails if 'expect' not in f]
t('clear',{'cmd':'clear'})
t('notify card',{'cmd':'notify','app':'WhatsApp','title':'Dad','text':'Dinner is ready, come home soon!','ttl':3},3.5)
t('nowplaying quiet',{'cmd':'nowplaying','title':'Song','artist':'Band','dur':200,'pos':10,'playing':True,'quiet':True})
t('pair QR',{'cmd':'pair'},2)
t('lock on',{'cmd':'lock','on':True}); t('lock off',{'cmd':'lock','on':False})
def c332(r,g,b): return (r&0xE0)|((g&0xE0)>>3)|(b>>6)
t('anim clear',{'cmd':'anim','action':'clear'})
for f in range(5):
    for y0 in (0,32):
        rows=bytearray(c332(255,60,60) if abs(x-(6+f*14))<6 else c332(0,20*f,90) for y in range(32) for x in range(80))
        t('anim frame %d/%d'%(f,y0),{'cmd':'anim','action':'frame','i':f,'y':y0,'h':32,'data':base64.b64encode(bytes(rows)).decode()},0.02)
t('anim play',{'cmd':'anim','action':'play','delay':150},3)
t('anim bad frame (expect FAIL)',{'cmd':'anim','action':'frame','i':99,'y':0,'h':32,'data':''},0.1); fails=[f for f in fails if 'expect' not in f]
t('back to eyes',{'cmd':'scene','id':'eyes'})
st=get('/api/status'); print('end uptime',st['uptime'],'heap',st['heap'],'(uptime kept rising => no reboot)')
print('FAILED:',fails if fails else 'none')
