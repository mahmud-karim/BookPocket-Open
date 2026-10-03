// Exact source coordinates, not rendered page numbers. Also runs on detached original XHTML.
function bookPocketDocument(doc, captureVisible) {
  if (!doc.documentElement || doc.getElementsByTagName('parsererror').length) throw Error('The original chapter markup could not be parsed safely. Generate its current page instead.');
  const tags = new Set(['p','h1','h2','h3','h4','h5','h6','li','blockquote','pre']);
  const whitespace = /^[\u0009-\u000d\u001c-\u0020\u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]$/u;
  const elements = [];
  const tag = e => (e.localName || '').toLowerCase();
  const excluded = e => e.closest && e.closest('[id^="r2-decoration-"], [data-readium="true"]');
  function walk(e) {
    if (['head','script','style'].includes(tag(e)) || excluded(e)) return;
    if (tags.has(tag(e)) && !Array.from(e.querySelectorAll('*')).some(c => tags.has(tag(c)))) { elements.push(e); return; }
    for (const c of e.children) walk(c);
  }
  walk(doc.documentElement);
  if (!elements.length) elements.push(doc.body || doc.documentElement);
  function intersects(rect, clip) { return rect.width > 0 && rect.height > 0 && Math.min(rect.right,clip.right)-Math.max(rect.left,clip.left)>0.25 && Math.min(rect.bottom,clip.bottom)-Math.max(rect.top,clip.top)>0.25; }
  function clipFor(e) {
    let clip = {left:0,top:0,right:window.innerWidth,bottom:window.innerHeight};
    for (let p=e;p && p.nodeType===1;p=p.parentElement) {
      const s = getComputedStyle(p);
      if (s.display==='none' || s.visibility==='hidden' || s.visibility==='collapse' || Number(s.opacity)===0 || p.hidden) return null;
      if (s.clipPath && s.clipPath!=='none') throw Error('This page uses clipped text. Change reading appearance or generate its chapter.');
      if (p!==doc.documentElement && p!==doc.body) {
        const r=p.getBoundingClientRect();
        if (['hidden','clip','scroll','auto'].includes(s.overflowX)) { clip.left=Math.max(clip.left,r.left);clip.right=Math.min(clip.right,r.right); }
        if (['hidden','clip','scroll','auto'].includes(s.overflowY)) { clip.top=Math.max(clip.top,r.top);clip.bottom=Math.min(clip.bottom,r.bottom); }
      }
    }
    return clip;
  }
  const rawMaps=[];
  const blocks=elements.map(e => {
    const raw=[];
    const walker=doc.createTreeWalker(e,NodeFilter.SHOW_TEXT);
    let node;
    while ((node=walker.nextNode())) {
      const clip=captureVisible ? clipFor(node.parentElement) : null;
      const whole=doc.createRange();whole.selectNodeContents(node);
      const couldSee=clip && Array.from(whole.getClientRects()).some(r=>intersects(r,clip));
      let utf16=0;
      for (const ch of node.data) {
        let visible=false;
        if (couldSee) {
          const glyph=doc.createRange();glyph.setStart(node,utf16);glyph.setEnd(node,utf16+ch.length);
          visible=Array.from(glyph.getClientRects()).some(r=>intersects(r,clip));
        }
        raw.push({ch,visible});utf16+=ch.length;
      }
    }
    const normalized=[];
    for(let i=0;i<raw.length;i++) {
      const item=raw[i];
      if(whitespace.test(item.ch)) {
        if(!normalized.length) continue;
        const last=normalized[normalized.length-1];
        if(last.ch===' ') { last.end=i+1;last.visible ||= item.visible; }
        else normalized.push({ch:' ',visible:item.visible,start:i,end:i+1});
      } else normalized.push({...item,start:i,end:i+1});
    }
    if(normalized.at(-1)?.ch===' ') normalized.pop();
    rawMaps.push(normalized);
    const visible=[];let start=null,last=null;
    for(let i=0;i<normalized.length;i++) {
      const item=normalized[i];
      if(item.visible && item.ch!==' ') { if(start===null)start=i;last=i+1; }
      else if(item.ch!==' ' && start!==null) { visible.push({start,end:last});start=null; }
    }
    if(start!==null)visible.push({start,end:last});
    return {text:normalized.map(x=>x.ch).join(''),visible};
  });
  const anchors=[];
  for(const anchor of doc.querySelectorAll('[id]')) {
    if(excluded(anchor))continue;
    let block=elements.findIndex(e=>e===anchor || e.contains(anchor));let offset=0;
    if(block>=0) {
      const prefix=doc.createRange();prefix.setStart(elements[block],0);prefix.setEnd(anchor,0);
      const rawOffset=Array.from(prefix.toString()).length;
      offset=rawMaps[block].filter(x=>x.end<=rawOffset).length;
    } else {
      block=elements.findIndex(e=>anchor.contains(e) || (anchor.compareDocumentPosition(e)&Node.DOCUMENT_POSITION_FOLLOWING));
      if(block<0)block=elements.length;
    }
    anchors.push({id:anchor.id,block,offset});
  }
  // Empty block elements do not create server segments. Remap anchors to the next segment.
  const nonempty=blocks.map((b,i)=>b.text?i:-1).filter(i=>i>=0);
  for(const a of anchors) { const original=a.block;a.block=nonempty.filter(i=>i<original).length;if(!blocks[original]?.text)a.offset=0; }
  return {blocks:blocks.filter(b=>b.text),anchors};
}
