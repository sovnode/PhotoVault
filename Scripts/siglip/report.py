"""Builds the review page for SigLIP 2's tags: tools/siglip/report/review.html.

    Scripts/siglip/report.sh --vault "/path/to/vault"

One self-contained HTML file, opened locally (never uploaded: it holds the
vault's thumbnails). Each item shows its thumbnail, SigLIP 2's tags at the
thresholds set by the sliders, and JoyTag's tags if joytag_compare.py has run.

A tag is shown when either rule holds:
- absolute: SigLIP's own score is above the "score" slider; or
- relative: the score is unusually high for that tag in this vault — its
  logit is more than the "relative" slider's number of spreads above the
  tag's median over the vault (spread = median − 16th percentile, which the
  tag's positives don't inflate) — and the score is above 0.002.

Clicking a tag marks it wrong; each item has a box for tags it's missing.
"Save feedback" downloads review-feedback.json.
"""

import argparse
import base64
import html
import io
import json
import os
import sqlite3
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

FLOOR = 0.002


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vault", required=True, type=Path)
    args = ap.parse_args()
    rep = Path(__file__).resolve().parents[2] / "tools" / "siglip" / "report"
    d = np.load(rep / "scores.npz")
    s = d["scores"].astype(np.float64).clip(1e-7, 1 - 1e-7)
    tags, groups, ids, paths, media = d["tags"], d["groups"], d["ids"], d["paths"], d["media"]
    logit = np.log(s / (1 - s))
    med = np.percentile(logit, 50, axis=0)
    # A tag scored near zero on almost everything has no spread to speak of;
    # a floor keeps it from looking "unusually high" on noise.
    spread = np.maximum(med - np.percentile(logit, 16, axis=0), 0.25)
    z = (logit - med) / spread
    jt = json.loads((rep / "joytag.json").read_text()) if (rep / "joytag.json").exists() else {}

    cat = args.vault / ".catalog"
    db = sqlite3.connect((cat / "catalog.sqlite").as_uri() + "?mode=ro", uri=True)
    thumbs = {r[0]: (r[1], r[2]) for r in db.execute("SELECT id, thumb_off, thumb_len FROM photo")}
    db.close()
    fd = os.open(cat / "thumbs.pack", os.O_RDONLY)

    items = []
    for i in range(len(ids)):
        pid = int(ids[i])
        off, length = thumbs[pid]
        img = ImageOps.exif_transpose(Image.open(io.BytesIO(os.pread(fd, length, off)))).convert("RGB")
        img.thumbnail((240, 240))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=68)
        cand = np.where((s[i] > FLOOR) & ((z[i] > 1.5) | (s[i] > 0.01)))[0]
        cand = cand[np.argsort(-s[i, cand])][:60]
        parts = str(paths[i]).split("/")
        items.append({
            "id": pid,
            "trip": parts[-2] if len(parts) > 1 else "",
            "name": parts[-1],
            "video": int(media[i]) == 1,
            "img": base64.b64encode(buf.getvalue()).decode(),
            "c": [[int(j), round(float(s[i, j]), 4), round(float(z[i, j]), 2)] for j in cand],
            "jt": [t for t, _ in jt.get(str(pid), [])],
        })
    os.close(fd)

    data = {"tags": [str(t) for t in tags], "groups": [str(g) for g in groups], "items": items,
            "joytag": bool(jt)}
    page = TEMPLATE.replace("__DATA__", json.dumps(data, separators=(",", ":")).replace("</", "<\\/"))
    (rep / "review.html").write_text(page)
    print(f"saved {rep / 'review.html'} ({(rep / 'review.html').stat().st_size / 1e6:.1f} MB, {len(items)} items)")


TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SigLIP Tag Review</title>
<style>
:root{--bg:#f7f7f5;--card:#fff;--fg:#1d1d1b;--muted:#6b6b66;--line:#e2e1dc;--chip:#eef2f7;--chipfg:#1f3a5c;
--jt:#f3eee6;--jtfg:#5a4524;--wrong:#fbe3e1;--wrongfg:#9b2c22;--accent:#2f6fb3;}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#161615;--card:#20201e;--fg:#ecebe6;--muted:#9a9993;
--line:#34332f;--chip:#22324a;--chipfg:#cfe0f5;--jt:#3a3124;--jtfg:#ecdcc0;--wrong:#4a2522;--wrongfg:#f3c2bc;--accent:#7fb0e6;}}
:root[data-theme=dark]{--bg:#161615;--card:#20201e;--fg:#ecebe6;--muted:#9a9993;--line:#34332f;--chip:#22324a;--chipfg:#cfe0f5;
--jt:#3a3124;--jtfg:#ecdcc0;--wrong:#4a2522;--wrongfg:#f3c2bc;--accent:#7fb0e6;}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.4 -apple-system,system-ui,sans-serif}
header{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:10px 16px}
h1{font-size:17px;margin:0 0 6px}.row{display:flex;flex-wrap:wrap;gap:10px 18px;align-items:center}
label{color:var(--muted);font-size:13px}input[type=range]{vertical-align:middle;width:140px}
select,input[type=search],button{font:inherit;padding:4px 8px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg)}
button{cursor:pointer}.stat{color:var(--muted);font-size:13px}
main{display:grid;grid-template-columns:260px 1fr;gap:16px;padding:16px}
@media (max-width:760px){main{grid-template-columns:1fr}aside{max-height:240px}}
aside{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px;overflow:auto;max-height:calc(100vh - 150px);position:sticky;top:130px}
aside h2{font-size:13px;margin:8px 0 4px;color:var(--muted);font-weight:600}
.tc{display:flex;justify-content:space-between;cursor:pointer;padding:1px 4px;border-radius:4px}.tc:hover,.tc.on{background:var(--chip)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden;display:flex;flex-direction:column}
.card img{width:100%;height:190px;object-fit:contain;background:#000}
.meta{font-size:12px;color:var(--muted);padding:6px 8px 0}
.tags{padding:6px 8px;display:flex;flex-wrap:wrap;gap:4px}
.t{background:var(--chip);color:var(--chipfg);border-radius:10px;padding:1px 7px;font-size:12px;cursor:pointer;user-select:none}
.t small{opacity:.6;margin-left:3px}.t.w{background:var(--wrong);color:var(--wrongfg);text-decoration:line-through}
.j{background:var(--jt);color:var(--jtfg);border-radius:10px;padding:1px 7px;font-size:12px}
.lbl{font-size:11px;color:var(--muted);width:100%;margin-top:2px}
.card input{margin:4px 8px 8px;width:calc(100% - 16px);font-size:12px;padding:3px 6px;border:1px solid var(--line);border-radius:5px;background:var(--bg);color:var(--fg)}
.pager{display:flex;gap:8px;justify-content:center;margin:16px 0}
.none{color:var(--muted);font-size:12px;font-style:italic}
</style></head><body>
<header>
<h1>SigLIP 2 tags: review</h1>
<div class="row">
<label>Score above <input id="abs" type="range" min="0.01" max="0.5" step="0.01" value="0.05"> <b id="absv"></b></label>
<label>Relative above <input id="rel" type="range" min="2" max="10" step="0.5" value="4"> <b id="relv"></b> spreads</label>
<label><input id="showjt" type="checkbox" checked> JoyTag beside</label>
<label><input id="scores" type="checkbox"> scores</label>
<select id="trip"></select>
<input id="q" type="search" placeholder="Show photos with tag…">
<button id="save">Save feedback</button>
<span class="stat" id="stat"></span>
</div></header>
<main><aside id="side"></aside><section><div class="grid" id="grid"></div><div class="pager" id="pager"></div></section></main>
<script>
const D=__DATA__;const PER=96;let page=0,onlyTag=null;
const $=id=>document.getElementById(id);
let fb={};try{fb=JSON.parse(localStorage.getItem('siglip-fb')||'{}')}catch(e){}
function keep(){try{localStorage.setItem('siglip-fb',JSON.stringify(fb))}catch(e){}}
function shown(it){const a=+$('abs').value,r=+$('rel').value;return it.c.filter(([j,p,z])=>p>a||(z>r&&p>0.002))}
function view(){const trip=$('trip').value;let xs=D.items.filter(it=>!trip||it.trip===trip);
 const q=$('q').value.trim().toLowerCase();const want=onlyTag!==null?onlyTag:(q?D.tags.findIndex(t=>t.toLowerCase()===q):-1);
 if(want>=0)xs=xs.filter(it=>shown(it).some(c=>c[0]===want));return xs}
function render(){$('absv').textContent=(+$('abs').value).toFixed(2);$('relv').textContent=$('rel').value;
 const xs=view();const pages=Math.max(1,Math.ceil(xs.length/PER));page=Math.min(page,pages-1);
 const counts=new Map();let tot=0,empty=0;const trip=$('trip').value;
 for(const it of D.items){if(trip&&it.trip!==trip)continue;const s=shown(it);tot+=s.length;if(!s.length)empty++;for(const c of s)counts.set(c[0],(counts.get(c[0])||0)+1)}
 const n=D.items.filter(it=>!trip||it.trip===trip).length;
 $('stat').textContent=`${xs.length} shown · ${(tot/n).toFixed(1)} tags per item · ${empty} with none`;
 const g=new Map();for(const [j,c] of counts){const k=D.groups[j];if(!g.has(k))g.set(k,[]);g.get(k).push([j,c])}
 let sh='<div class="stat">Tags in use: '+counts.size+' of '+D.tags.length+'. Click one to filter.</div>';
 for(const k of [...new Set(D.groups)]){if(!g.has(k))continue;sh+=`<h2>${k}</h2>`;
  for(const [j,c] of g.get(k).sort((a,b)=>b[1]-a[1]))sh+=`<div class="tc${onlyTag===j?' on':''}" data-j="${j}"><span>${D.tags[j]}</span><span>${c}</span></div>`}
 $('side').innerHTML=sh;
 const sc=$('scores').checked,jt=$('showjt').checked&&D.joytag;
 $('grid').innerHTML=xs.slice(page*PER,(page+1)*PER).map(it=>{const f=fb[it.id]||{};const s=shown(it);
  const tg=s.map(([j,p,z])=>`<span class="t${(f.wrong||[]).includes(D.tags[j])?' w':''}" data-id="${it.id}" data-t="${D.tags[j]}">${D.tags[j]}${sc?`<small>${p.toFixed(3)} · ${z.toFixed(1)}</small>`:''}</span>`).join('')||'<span class="none">no SigLIP tags</span>';
  const jj=jt?`<span class="lbl">JoyTag</span>`+(it.jt.slice(0,14).map(t=>`<span class="j">${t}</span>`).join('')||'<span class="none">none</span>'):'';
  return `<div class="card"><img loading="lazy" src="data:image/jpeg;base64,${it.img}"><div class="meta">${it.video?'▶ video · ':''}${it.trip} · ${it.name}</div>
  <div class="tags">${tg}${jj}</div><input data-id="${it.id}" placeholder="Missing tags (comma separated)" value="${(f.missing||'').replace(/"/g,'&quot;')}"></div>`}).join('');
 let p='';if(pages>1)for(let i=0;i<pages;i++)p+=`<button data-p="${i}"${i===page?' disabled':''}>${i+1}</button>`;$('pager').innerHTML=p}
const trips=[...new Set(D.items.map(i=>i.trip))].sort();
$('trip').innerHTML='<option value="">All trips ('+D.items.length+')</option>'+trips.map(t=>`<option>${t}</option>`).join('');
for(const id of ['abs','rel','scores','showjt','trip'])$(id).addEventListener('input',()=>{page=0;render()});
$('q').addEventListener('input',()=>{onlyTag=null;page=0;render()});
$('side').addEventListener('click',e=>{const el=e.target.closest('.tc');if(!el)return;const j=+el.dataset.j;onlyTag=onlyTag===j?null:j;$('q').value='';page=0;render();scrollTo(0,0)});
$('pager').addEventListener('click',e=>{if(e.target.dataset.p){page=+e.target.dataset.p;render();scrollTo(0,0)}});
$('grid').addEventListener('click',e=>{const el=e.target.closest('.t');if(!el)return;const f=fb[el.dataset.id]||(fb[el.dataset.id]={});
 f.wrong=f.wrong||[];const t=el.dataset.t;f.wrong=f.wrong.includes(t)?f.wrong.filter(x=>x!==t):[...f.wrong,t];el.classList.toggle('w');keep()});
$('grid').addEventListener('change',e=>{if(e.target.tagName!=='INPUT')return;const f=fb[e.target.dataset.id]||(fb[e.target.dataset.id]={});f.missing=e.target.value;keep()});
$('save').addEventListener('click',()=>{const out={settings:{score:+$('abs').value,relative:+$('rel').value},feedback:fb};
 const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify(out,null,1)],{type:'application/json'}));a.download='review-feedback.json';a.click()});
render();
</script></body></html>
"""

if __name__ == "__main__":
    main()
