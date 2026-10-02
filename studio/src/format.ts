export function duration(seconds:number){if(!Number.isFinite(seconds)||seconds<0)return '0:00';const s=Math.floor(seconds);return s>=3600?`${Math.floor(s/3600)}:${String(Math.floor(s%3600/60)).padStart(2,'0')}:${String(s%60).padStart(2,'0')}`:`${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}`;}
export function jobProgress(done:number,total:number){return total>0?Math.max(0,Math.min(100,Math.round(done/total*100))):0;}
export function bookColor(id:string){let n=0;for(const c of id)n=(n*31+c.charCodeAt(0))>>>0;return ['pine','ochre','slate','plum'][n%4];}
export function initials(name:string){return name.split(/\s+/).slice(0,2).map(x=>x[0]).join('').toUpperCase();}
