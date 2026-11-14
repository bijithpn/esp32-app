// Built-in web UI served at http://<device-ip>/  (works in any browser, no app needed)
#pragma once
const char PAGE_HTML[] PROGMEM = R"HTML(<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ESP32 Hub</title>
<style>
:root{color-scheme:dark}
body{font-family:system-ui,sans-serif;background:#0e1420;color:#e8eef8;margin:0;padding:16px;max-width:520px;margin:0 auto}
h1{font-size:22px;margin:4px 0 2px}h2{font-size:16px;margin:22px 0 8px;color:#7fd8ff}
.sub{color:#8896ad;font-size:13px;margin-bottom:12px}
input,select,button{font:inherit;border-radius:10px;border:1px solid #2a3750;background:#16202f;color:#e8eef8;padding:10px 12px}
input{width:100%;box-sizing:border-box;margin:4px 0 10px}
button{cursor:pointer;background:#1b6f8a;border-color:#1b6f8a}
button.s{background:#16202f;border-color:#2a3750}
button.on{outline:2px solid #7fd8ff}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
.grid button{padding:14px 4px;font-size:13px}
.row{display:flex;gap:8px}.row input{margin:0}
#msg{color:#7fd8ff;min-height:20px;font-size:13px;margin-top:8px}
.card{background:#121b2a;border:1px solid #223048;border-radius:14px;padding:14px;margin-top:12px}
</style></head><body>
<h1>ESP32 Hub</h1><div class="sub" id="st">connecting...</div>

<div id="setup" style="display:none" class="card">
  <h2 style="margin-top:0">Wi-Fi setup</h2>
  <div class="sub">Pick your home Wi-Fi (2.4 GHz). The board will reboot and join it, then show its IP on the screen.</div>
  <label>Network</label>
  <input id="ssid" list="nets" placeholder="Network name" autocapitalize="none" autocomplete="off">
  <datalist id="nets"></datalist>
  <label>Password</label>
  <input id="pass" type="password" placeholder="Password">
  <button onclick="saveWifi()">Save &amp; connect</button>
</div>

<div id="ctl" style="display:none">
  <h2>Scenes</h2><div class="grid" id="scenes"></div>
  <h2>Send a message</h2>
  <div class="row"><input id="text" maxlength="60" placeholder="Good morning!"><button onclick="sendMsg()">Send</button></div>
  <h2>Other</h2>
  <div class="row"><button class="s" onclick="cmd({cmd:'auto',sec:15});say('Auto-rotate every 15 s')">Auto-rotate</button>
  <button class="s" onclick="cmd({cmd:'auto',sec:0});say('Auto-rotate off')">Stop rotate</button>
  <button class="s" onclick="if(confirm('Forget Wi-Fi and reboot into setup mode?'))cmd({cmd:'forget'})">Forget Wi-Fi</button></div>
  <div class="row" style="margin-top:8px"><button class="s" onclick="cmd({cmd:'pair'});say('Pairing QR is on the display')">Show pairing QR</button>
  <button class="s" onclick="lockIt()">Lock with token</button></div>
  <h2>Firmware update</h2>
  <form id="upd" method="post" enctype="multipart/form-data" onsubmit="this.action='/update?t='+encodeURIComponent(tok())"><input type="file" name="fw" accept=".bin"><button>Upload .bin</button></form>
</div>
<div id="msg"></div>

<script>
const $=id=>document.getElementById(id);
function say(t){$('msg').textContent=t}
function tok(){try{return localStorage.getItem('tok')||''}catch(e){return ''}}
async function cmd(o){
  try{
    const r=await fetch('/api/cmd',{method:'POST',headers:{'X-Hub-Token':tok()},body:JSON.stringify(o)});
    if(r.status==401){
      const t=prompt('This hub is locked. Enter its token (it is shown in the app, or scan the Pair QR scene):');
      if(t){try{localStorage.setItem('tok',t.trim())}catch(e){}return cmd(o)}
      return {ok:false};
    }
    return r.json();
  }catch(e){say('Request failed');return {ok:false}}
}
async function load(){
  try{
    const d=await (await fetch('/api/list')).json();
    $('st').textContent=(d.ap?'Setup mode':'Connected')+'  ·  '+d.ip+'  ·  fw '+d.fw+'  ·  id '+d.id+(d.lock?'  ·  locked':'')+(d.ap?'':'  ·  scene: '+d.scene);
    if(d.ap){$('setup').style.display='block';scan();}
    else{
      $('ctl').style.display='block';
      const g=$('scenes');g.innerHTML='';
      d.scenes.filter(s=>s.id!='message').forEach(s=>{
        const b=document.createElement('button');b.textContent=s.name;if(s.id==d.scene)b.className='on';
        b.onclick=()=>cmd({cmd:'scene',id:s.id}).then(load);g.appendChild(b);
      });
    }
  }catch(e){$('st').textContent='Cannot reach the device';}
}
async function scan(){
  try{
    const r=await (await fetch('/api/scan')).json();
    $('nets').innerHTML=r.map(n=>'<option value="'+n.replace(/"/g,'&quot;')+'">').join('');
    if(!r.length)setTimeout(scan,2500);
  }catch(e){}
}
async function lockIt(){
  const r=await cmd({cmd:'lock',on:true});
  if(r&&r.token){try{localStorage.setItem('tok',r.token)}catch(e){};prompt('Locked. Save this token (needed by the app, MQTT and new browsers):',r.token);load()}
}
function sendMsg(){const t=$('text').value.trim();if(t){cmd({cmd:'msg',text:t,ttl:10});$('text').value='';say('Sent')}}
async function saveWifi(){
  const ssid=$('ssid').value.trim();if(!ssid){say('Enter the network name');return}
  say('Saving... the board will reboot. Rejoin your normal Wi-Fi and open the IP shown on the screen.');
  fetch('/api/wifi',{method:'POST',headers:{'X-Hub-Token':tok()},body:JSON.stringify({ssid:ssid,pass:$('pass').value})}).catch(()=>{});
}
load();setInterval(()=>{if($('ctl').style.display=='block')load()},8000);
</script></body></html>)HTML";
