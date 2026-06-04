"""
Vexa Transcribe UI — browse recordings, listen, transcribe with Whisper/Qwen.
Features: duration column (ffprobe), sortable, lazy audio, segmented streaming
transcription with live progress + stop, and a live-mic real-time mode.
"""
import os
import glob
import json
import time
import tempfile
import subprocess
import threading

import boto3
import httpx
from fastapi import FastAPI, Request, UploadFile, File, Form
from fastapi.responses import HTMLResponse, Response, JSONResponse, StreamingResponse

S3_ENDPOINT = os.getenv("MINIO_ENDPOINT", "minio:9000")
S3_KEY      = os.getenv("MINIO_ACCESS_KEY", "vexa-access-key")
S3_SECRET   = os.getenv("MINIO_SECRET_KEY", "vexa-secret-key")
BUCKET      = os.getenv("MINIO_BUCKET", "vexa")
MODELS = {
    "whisper": (os.getenv("TRANSCRIPTION_SERVICE_URL", ""),      os.getenv("TRANSCRIPTION_SERVICE_TOKEN", "")),
    "qwen":    (os.getenv("QWEN_TRANSCRIPTION_SERVICE_URL", ""), os.getenv("QWEN_TRANSCRIPTION_SERVICE_TOKEN", "")),
}
s3 = boto3.client("s3", endpoint_url=f"http://{S3_ENDPOINT}",
                  aws_access_key_id=S3_KEY, aws_secret_access_key=S3_SECRET)
app = FastAPI(title="Vexa Transcribe UI")
AUDIO_EXT = (".webm", ".wav", ".m4a", ".mp4", ".ogg", ".opus", ".mka")
_dur_cache: dict[str, float] = {}


def _get(key): return s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
def sse(o): return f"data: {json.dumps(o, ensure_ascii=False)}\n\n"


@app.get("/api/recordings")
def recordings():
    out = []
    try:
        for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix="recordings/"):
            for o in page.get("Contents", []):
                if o["Key"].lower().endswith(AUDIO_EXT):
                    out.append({"key": o["Key"], "size": o["Size"],
                                "modified": o["LastModified"].isoformat(), "duration": _dur_cache.get(o["Key"])})
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)
    out.sort(key=lambda x: x["modified"], reverse=True)
    return out


def _probe_duration(data: bytes):
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as t:
        t.write(data); p = t.name
    try:
        r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", p],
                           capture_output=True, text=True, timeout=30)
        v = (r.stdout or "").strip()
        if v and v.upper() != "N/A":
            return round(float(v), 1)
        r2 = subprocess.run(["ffmpeg", "-nostdin", "-i", p, "-f", "null", "-"], capture_output=True, text=True, timeout=120)
        for line in reversed(r2.stderr.splitlines()):
            if "time=" in line:
                h, m, s = line.split("time=")[1].split(" ")[0].split(":")
                return round(int(h) * 3600 + int(m) * 60 + float(s), 1)
    except Exception:
        return None
    finally:
        try: os.unlink(p)
        except Exception: pass
    return None


@app.get("/api/duration")
def duration(key: str):
    if key in _dur_cache:
        return {"duration": _dur_cache[key]}
    try:
        d = _probe_duration(_get(key))
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=404)
    _dur_cache[key] = d
    return {"duration": d}


@app.get("/api/audio")
def audio(key: str):
    try:
        return Response(content=_get(key), media_type="audio/webm")
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=404)


def _segment(data: bytes, seg_sec: int):
    d = tempfile.mkdtemp()
    src = os.path.join(d, "in.bin")
    with open(src, "wb") as f: f.write(data)
    subprocess.run(["ffmpeg", "-nostdin", "-i", src, "-ar", "16000", "-ac", "1",
                    "-f", "segment", "-segment_time", str(seg_sec), os.path.join(d, "s_%04d.wav")],
                   capture_output=True, timeout=600)
    out = []
    for f in sorted(glob.glob(os.path.join(d, "s_*.wav"))):
        try:
            with open(f, "rb") as fh: out.append(fh.read())
            os.unlink(f)
        except Exception: pass
    try: os.unlink(src); os.rmdir(d)
    except Exception: pass
    return out


@app.get("/api/transcribe-stream")
async def transcribe_stream(request: Request, key: str, models: str = "whisper", language: str = "tr", seg: int = 30):
    mlist = [m for m in models.split(",") if m]
    lang = (language or "tr").strip()

    async def gen():
        try:
            data = _get(key)
        except Exception as e:
            yield sse({"type": "error", "error": str(e)}); return
        yield sse({"type": "stage", "msg": "ses parçalara bölünüyor..."})
        try:
            segs = _segment(data, seg)
        except Exception as e:
            yield sse({"type": "error", "error": f"segment: {e}"}); return
        total = len(segs)
        if not total:
            yield sse({"type": "error", "error": "parça üretilemedi"}); return
        yield sse({"type": "start", "total": total, "models": mlist})
        async with httpx.AsyncClient(timeout=300) as c:
            for idx, seg_bytes in enumerate(segs):
                if await request.is_disconnected():
                    return
                for m in mlist:
                    url, tok = MODELS.get(m, ("", ""))
                    if not url:
                        yield sse({"type": "seg", "idx": idx, "total": total, "model": m, "text": "[URL yok]"}); continue
                    t0 = time.time()
                    try:
                        r = await c.post(url, headers={"X-API-Key": tok},
                                         files={"file": ("a.wav", seg_bytes, "audio/wav")},
                                         data={"model": "whisper-1", "language": lang, "response_format": "verbose_json"})
                        txt = (r.json().get("text") or "").strip()
                    except Exception as e:
                        txt = f"[hata: {e}]"
                    yield sse({"type": "seg", "idx": idx, "total": total, "model": m,
                               "text": txt, "secs": round(time.time() - t0, 1)})
        yield sse({"type": "done"})

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@app.post("/api/transcribe-blob")
async def transcribe_blob(file: UploadFile = File(...), models: str = Form("whisper"), language: str = Form("tr")):
    data = await file.read()
    res = {}
    async with httpx.AsyncClient(timeout=300) as c:
        for m in [x for x in models.split(",") if x]:
            url, tok = MODELS.get(m, ("", ""))
            if not url:
                res[m] = {"error": "URL yok"}; continue
            try:
                r = await c.post(url, headers={"X-API-Key": tok}, files={"file": ("a.webm", data, "audio/webm")},
                                 data={"model": "whisper-1", "language": (language or "tr"), "response_format": "verbose_json"})
                res[m] = {"text": (r.json().get("text") or "").strip()}
            except Exception as e:
                res[m] = {"error": str(e)}
    return res


@app.get("/", response_class=HTMLResponse)
def index():
    return HTML


HTML = r"""<!doctype html><html lang="tr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Vexa Transcribe UI</title>
<style>
 body{font-family:system-ui,Arial;margin:0;background:#0f1115;color:#e6e6e6}
 header{padding:12px 20px;background:#171a21;border-bottom:1px solid #262b36} h1{font-size:17px;margin:0}
 .wrap{padding:14px 20px;max-width:1200px;margin:0 auto}
 .bar{display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin:10px 0}
 input[type=text]{background:#0f1115;border:1px solid #333;color:#eee;padding:6px 8px;border-radius:6px;width:60px}
 button{background:#2d6cdf;color:#fff;border:0;padding:7px 13px;border-radius:7px;cursor:pointer;font-size:14px}
 button:disabled{opacity:.5;cursor:default} button.sec{background:#2a2f3a} button.stop{background:#d4392b} button.rec{background:#d4392b}
 table{width:100%;border-collapse:collapse;font-size:13px} th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #222833;vertical-align:top}
 th{cursor:pointer;user-select:none;color:#9fb4d8} th:hover{color:#fff}
 td.k{font-family:monospace;font-size:11px;color:#9fb4d8;max-width:280px;word-break:break-all}
 .prog{height:8px;background:#222833;border-radius:5px;overflow:hidden;margin:8px 0;display:none}
 .prog>div{height:100%;background:#2d6cdf;width:0%;transition:width .2s}
 .res{display:grid;gap:14px;margin-top:14px} .card{background:#141821;border:1px solid #262b36;border-radius:8px;padding:12px}
 .card h3{margin:0 0 6px;font-size:14px;color:#7fd3a0} .card pre{white-space:pre-wrap;font:inherit;font-size:13px;line-height:1.45;margin:0}
 .muted{color:#8a93a6} .tabs{display:flex;gap:8px;margin:6px 0} .tab{padding:6px 12px;border-radius:7px 7px 0 0;background:#1a1e27;cursor:pointer} .tab.on{background:#2d6cdf}
 .live{font-size:14px;line-height:1.6;background:#141821;border:1px solid #262b36;border-radius:8px;padding:12px;min-height:120px;white-space:pre-wrap}
</style></head><body>
<header><h1>🎙️ Vexa Transcribe UI</h1></header>
<div class="wrap">
 <div class="tabs"><div class="tab on" id="t1" onclick="tab(1)">Kayıtlar</div><div class="tab" id="t2" onclick="tab(2)">🔴 Canlı mikrofon</div></div>
 <div id="p1">
  <div class="bar">
   <button class="sec" onclick="load()">↻ Yenile</button>
   <label><input type="checkbox" id="m_whisper" checked> Whisper</label>
   <label><input type="checkbox" id="m_qwen"> Qwen</label>
   <label>Dil <input type="text" id="lang" value="tr"></label>
   <label>Parça(sn) <input type="text" id="seg" value="30"></label>
   <button id="go" onclick="run()">▶ Çevir</button>
   <button id="stopb" class="stop" onclick="stop()" style="display:none">■ Durdur</button>
   <span id="status" class="muted"></span>
  </div>
  <div class="prog" id="prog"><div id="bar"></div></div>
  <div id="results" class="res"></div>
  <table id="tbl"><thead><tr><th></th><th onclick="sortBy('key')">Kayıt</th>
    <th onclick="sortBy('size')">Boyut ⇅</th><th onclick="sortBy('duration')">Süre ⇅</th>
    <th onclick="sortBy('modified')">Tarih ⇅</th><th>Dinle</th></tr></thead><tbody></tbody></table>
 </div>
 <div id="p2" style="display:none">
  <div class="bar">
   <label><input type="checkbox" id="lm_whisper" checked> Whisper</label>
   <label><input type="checkbox" id="lm_qwen"> Qwen</label>
   <label>Dil <input type="text" id="lm_lang" value="tr"></label>
   <button id="recbtn" class="rec" onclick="toggleRec()">● Kaydı başlat</button>
   <span id="lm_status" class="muted">mikrofon hazır</span>
  </div>
  <div class="muted" style="font-size:12px;margin-bottom:6px">~4 sn'lik parçalar canlı modele gönderilir.</div>
  <div id="live" class="live"></div>
 </div>
</div>
<script>
let recs=[], sortKey='modified', sortDir=-1, es=null;
const $=id=>document.getElementById(id);
function fmtSize(b){return b>1e6?(b/1e6).toFixed(1)+'MB':(b/1e3).toFixed(0)+'KB'}
function fmtDur(d){return d==null?'<span class=muted>—</span>':(d>=60?Math.floor(d/60)+'m'+Math.round(d%60)+'s':d+'s')}
function tab(n){t1.classList.toggle('on',n==1);t2.classList.toggle('on',n==2);p1.style.display=n==1?'':'none';p2.style.display=n==2?'':'none'}
function sortBy(k){sortDir=(sortKey===k)?-sortDir:1;sortKey=k;render()}
function render(){
  const tb=document.querySelector('#tbl tbody');tb.innerHTML='';
  const arr=[...recs].sort((a,b)=>{let x=a[sortKey],y=b[sortKey];if(x==null)return 1;if(y==null)return -1;return (x>y?1:x<y?-1:0)*sortDir});
  arr.forEach(x=>{const i=recs.indexOf(x),sh=x.key.split('/').slice(-3).join('/');const tr=document.createElement('tr');
    tr.innerHTML=`<td><input type="radio" name="rec" value="${i}"></td><td class="k" title="${x.key}">${sh}</td>
      <td>${fmtSize(x.size)}</td><td data-dur="${x.key}">${fmtDur(x.duration)}</td>
      <td class="muted">${x.modified.replace('T',' ').slice(0,19)}</td>
      <td><button class="sec" onclick="play(this,'${encodeURIComponent(x.key)}')">▶</button></td>`;tb.appendChild(tr);});
  const r=document.querySelector('input[name=rec]');if(r)r.checked=true;loadDurations();
}
function play(b,k){const a=document.createElement('audio');a.controls=true;a.src='/api/audio?key='+k;a.style.height='30px';b.replaceWith(a);a.play()}
let dq=[];
function loadDurations(){dq=recs.filter(x=>x.duration==null).map(x=>x.key);pump();pump()}
async function pump(){const k=dq.shift();if(!k)return;try{const j=await(await fetch('/api/duration?key='+encodeURIComponent(k))).json();
  const r=recs.find(x=>x.key===k);if(r)r.duration=j.duration;document.querySelectorAll(`td[data-dur="${k}"]`).forEach(td=>td.innerHTML=fmtDur(j.duration));}catch(e){}pump()}
async function load(){status.textContent='yükleniyor...';recs=await(await fetch('/api/recordings')).json();
  if(recs.error){status.textContent='HATA: '+recs.error;return}render();status.textContent=recs.length+' kayıt'}
function run(){
  const sel=document.querySelector('input[name=rec]:checked');if(!sel){alert('Kayıt seç');return}
  const key=recs[+sel.value].key,models=[];if(m_whisper.checked)models.push('whisper');if(m_qwen.checked)models.push('qwen');
  if(!models.length){alert('Model seç');return}
  go.disabled=true;stopb.style.display='';prog.style.display='block';bar.style.width='0%';
  results.innerHTML='';const cards={},texts={};
  results.style.gridTemplateColumns=models.length>1?'1fr 1fr':'1fr';
  models.forEach(m=>{const c=document.createElement('div');c.className='card';c.innerHTML=`<h3>${m.toUpperCase()}</h3><pre></pre>`;results.appendChild(c);cards[m]=c.querySelector('pre');texts[m]=''});
  let total=0,done=0;
  const u='/api/transcribe-stream?key='+encodeURIComponent(key)+'&models='+models.join(',')+'&language='+encodeURIComponent(lang.value)+'&seg='+encodeURIComponent(seg.value);
  es=new EventSource(u);
  es.onmessage=ev=>{const j=JSON.parse(ev.data);
    if(j.type==='stage'){status.textContent=j.msg}
    else if(j.type==='start'){total=j.total;status.textContent='0/'+total+' segment'}
    else if(j.type==='seg'){texts[j.model]=(texts[j.model]+' '+j.text).trim();cards[j.model].textContent=texts[j.model];
      done++;const segDone=Math.ceil(done/models.length);bar.style.width=(segDone/total*100)+'%';status.textContent=segDone+'/'+total+' segment'}
    else if(j.type==='done'){status.textContent='✓ tamam ('+total+' segment)';finish()}
    else if(j.type==='error'){status.textContent='HATA: '+j.error;finish()}
  };
  es.onerror=()=>{if(es){status.textContent='bağlantı kapandı';finish()}};
}
function stop(){if(es){es.close();es=null;status.textContent='■ durduruldu';}finish()}
function finish(){if(es){es.close();es=null}go.disabled=false;stopb.style.display='none'}
// live mic
let mr=null,recording=false,iv=null;
async function toggleRec(){
  if(recording){recording=false;clearInterval(iv);if(mr&&mr.state!=='inactive')mr.stop();recbtn.textContent='● Kaydı başlat';recbtn.classList.add('rec');lm_status.textContent='durdu';return}
  let st;try{st=await navigator.mediaDevices.getUserMedia({audio:true})}catch(e){alert('mikrofon: '+e);return}
  const models=[];if(lm_whisper.checked)models.push('whisper');if(lm_qwen.checked)models.push('qwen');if(!models.length){alert('Model seç');return}
  live.textContent='';recording=true;recbtn.textContent='■ Durdur';recbtn.classList.remove('rec');lm_status.textContent='kaydediliyor...';
  mr=new MediaRecorder(st,{mimeType:'audio/webm'});
  mr.ondataavailable=async e=>{if(!e.data||e.data.size<2500)return;const fd=new FormData();fd.append('file',e.data,'l.webm');fd.append('models',models.join(','));fd.append('language',lm_lang.value);
    try{const j=await(await fetch('/api/transcribe-blob',{method:'POST',body:fd})).json();models.forEach(m=>{const t=(j[m]&&j[m].text)||'';if(t)live.textContent+=`[${m}] ${t}\n`});live.scrollTop=live.scrollHeight}catch(err){}};
  mr.start();iv=setInterval(()=>{if(recording&&mr.state==='recording'){mr.stop();mr.start()}},4000);
}
load();
</script></body></html>"""
