"""
Tiny web tool: browse recorded meeting audio (MinIO), listen, and transcribe
with one or two models (Whisper / Qwen) side by side.

Runs on the compose network so it reaches minio:9000 internally and the STT
services over the LAN. Proxy is disabled (NO_PROXY=*) so internal calls work.
"""
import os
import boto3
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, Response, JSONResponse

S3_ENDPOINT = os.getenv("MINIO_ENDPOINT", "minio:9000")
S3_KEY      = os.getenv("MINIO_ACCESS_KEY", "vexa-access-key")
S3_SECRET   = os.getenv("MINIO_SECRET_KEY", "vexa-secret-key")
BUCKET      = os.getenv("MINIO_BUCKET", "vexa")

MODELS = {
    "whisper": (os.getenv("TRANSCRIPTION_SERVICE_URL", ""),      os.getenv("TRANSCRIPTION_SERVICE_TOKEN", "")),
    "qwen":    (os.getenv("QWEN_TRANSCRIPTION_SERVICE_URL", ""), os.getenv("QWEN_TRANSCRIPTION_SERVICE_TOKEN", "")),
}

s3 = boto3.client(
    "s3", endpoint_url=f"http://{S3_ENDPOINT}",
    aws_access_key_id=S3_KEY, aws_secret_access_key=S3_SECRET,
)
app = FastAPI(title="Vexa Transcribe UI")
AUDIO_EXT = (".webm", ".wav", ".m4a", ".mp4", ".ogg", ".opus", ".mka")


@app.get("/api/recordings")
def recordings():
    out = []
    try:
        p = s3.get_paginator("list_objects_v2")
        for page in p.paginate(Bucket=BUCKET, Prefix="recordings/"):
            for o in page.get("Contents", []):
                if o["Key"].lower().endswith(AUDIO_EXT):
                    out.append({"key": o["Key"], "size": o["Size"], "modified": o["LastModified"].isoformat()})
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)
    out.sort(key=lambda x: x["modified"], reverse=True)
    return out


@app.get("/api/audio")
def audio(key: str):
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=key)
        return Response(content=obj["Body"].read(), media_type="audio/webm")
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=404)


@app.post("/api/transcribe")
async def transcribe(req: Request):
    body = await req.json()
    key = body["key"]
    models = body.get("models", ["whisper"])
    language = (body.get("language") or "tr").strip()
    try:
        data = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    except Exception as e:
        return JSONResponse({"error": f"audio fetch: {e}"}, status_code=404)

    res = {}
    async with httpx.AsyncClient(timeout=600) as c:
        for m in models:
            url, tok = MODELS.get(m, ("", ""))
            if not url:
                res[m] = {"error": f"{m} URL not configured"}
                continue
            import time as _t
            t0 = _t.time()
            try:
                r = await c.post(
                    url, headers={"X-API-Key": tok},
                    files={"file": ("audio.webm", data, "audio/webm")},
                    data={"model": "whisper-1", "language": language, "response_format": "verbose_json"},
                )
                j = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
                res[m] = {"http": r.status_code, "secs": round(_t.time() - t0, 1),
                          "text": (j.get("text") or "").strip(), "lang": j.get("language")}
            except Exception as e:
                res[m] = {"error": str(e)}
    return res


@app.get("/", response_class=HTMLResponse)
def index():
    return HTML


HTML = """<!doctype html><html lang="tr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Vexa Transcribe UI</title>
<style>
 body{font-family:system-ui,Arial;margin:0;background:#0f1115;color:#e6e6e6}
 header{padding:14px 20px;background:#171a21;border-bottom:1px solid #262b36;position:sticky;top:0}
 h1{font-size:18px;margin:0}
 .wrap{padding:16px 20px;max-width:1200px;margin:0 auto}
 .bar{display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin:12px 0}
 .bar label{font-size:14px} input[type=text]{background:#0f1115;border:1px solid #333;color:#eee;padding:6px 8px;border-radius:6px;width:70px}
 button{background:#2d6cdf;color:#fff;border:0;padding:8px 14px;border-radius:7px;cursor:pointer;font-size:14px}
 button:disabled{opacity:.5;cursor:default}
 button.sec{background:#2a2f3a}
 table{width:100%;border-collapse:collapse;font-size:13px}
 th,td{text-align:left;padding:7px 8px;border-bottom:1px solid #222833;vertical-align:top}
 td.k{font-family:monospace;font-size:11px;color:#9fb4d8;max-width:340px;word-break:break-all}
 audio{height:30px}
 .res{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-top:16px}
 .card{background:#141821;border:1px solid #262b36;border-radius:8px;padding:12px}
 .card h3{margin:0 0 6px;font-size:14px;color:#7fd3a0}
 .card .meta{font-size:11px;color:#8a93a6;margin-bottom:8px}
 .card pre{white-space:pre-wrap;font-family:inherit;font-size:13px;line-height:1.45;margin:0}
 .muted{color:#8a93a6}
</style></head><body>
<header><h1>🎙️ Vexa Transcribe UI <span class="muted" style="font-size:12px">— kayıtları dinle + modele gönder</span></h1></header>
<div class="wrap">
 <div class="bar">
   <button class="sec" onclick="load()">↻ Kayıtları yenile</button>
   <label><input type="checkbox" id="m_whisper" checked> Whisper</label>
   <label><input type="checkbox" id="m_qwen"> Qwen</label>
   <label>Dil: <input type="text" id="lang" value="tr"></label>
   <button id="go" onclick="run()">▶ Seçili kaydı çevir</button>
   <span id="status" class="muted"></span>
 </div>
 <table id="tbl"><thead><tr><th></th><th>Kayıt</th><th>Boyut</th><th>Tarih</th><th>Dinle</th></tr></thead><tbody></tbody></table>
 <div id="results" class="res"></div>
</div>
<script>
let recs=[];
function fmtSize(b){return b>1e6?(b/1e6).toFixed(1)+'MB':(b/1e3).toFixed(0)+'KB'}
async function load(){
  document.getElementById('status').textContent='yükleniyor...';
  const r=await fetch('/api/recordings'); recs=await r.json();
  const tb=document.querySelector('#tbl tbody'); tb.innerHTML='';
  if(recs.error){document.getElementById('status').textContent='HATA: '+recs.error;return}
  recs.forEach((x,i)=>{
    const tr=document.createElement('tr');
    const short=x.key.split('/').slice(-3).join('/');
    tr.innerHTML=`<td><input type="radio" name="rec" value="${i}" ${i==0?'checked':''}></td>
      <td class="k" title="${x.key}">${short}</td><td>${fmtSize(x.size)}</td>
      <td class="muted">${x.modified.replace('T',' ').slice(0,19)}</td>
      <td><audio controls preload="none" src="/api/audio?key=${encodeURIComponent(x.key)}"></audio></td>`;
    tb.appendChild(tr);
  });
  document.getElementById('status').textContent=recs.length+' kayıt';
}
async function run(){
  const sel=document.querySelector('input[name=rec]:checked');
  if(!sel){alert('Bir kayıt seç');return}
  const key=recs[+sel.value].key;
  const models=[]; if(m_whisper.checked)models.push('whisper'); if(m_qwen.checked)models.push('qwen');
  if(!models.length){alert('En az bir model seç');return}
  const go=document.getElementById('go'); go.disabled=true;
  document.getElementById('status').textContent='çeviriliyor ('+models.join(', ')+')...';
  document.getElementById('results').innerHTML='';
  try{
    const r=await fetch('/api/transcribe',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({key,models,language:document.getElementById('lang').value})});
    const j=await r.json();
    const box=document.getElementById('results');
    box.style.gridTemplateColumns=models.length>1?'1fr 1fr':'1fr';
    models.forEach(m=>{
      const d=j[m]||{}; const c=document.createElement('div'); c.className='card';
      c.innerHTML=`<h3>${m.toUpperCase()}</h3>
        <div class="meta">${d.error?('HATA: '+d.error):('HTTP '+d.http+' · '+d.secs+'s · dil:'+(d.lang||'?'))}</div>
        <pre>${(d.text||'').replace(/</g,'&lt;')||'<span class=muted>(boş)</span>'}</pre>`;
      box.appendChild(c);
    });
    document.getElementById('status').textContent='tamam';
  }catch(e){document.getElementById('status').textContent='HATA: '+e}
  go.disabled=false;
}
load();
</script></body></html>"""
