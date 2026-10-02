const SESSION_KEY='book-pocket.admin.v1';
export function bootstrapSession():boolean {
  const params=new URLSearchParams(window.location.hash.slice(1));
  const token=params.get('session');
  if(token){sessionStorage.setItem(SESSION_KEY,token);history.replaceState(null,'',window.location.pathname+window.location.search);}
  return Boolean(sessionStorage.getItem(SESSION_KEY));
}
export class APIError extends Error {constructor(message:string,public status:number){super(message)}}
export async function request(path:string,options:RequestInit={}):Promise<Response>{
  const headers=new Headers(options.headers); const token=sessionStorage.getItem(SESSION_KEY);
  if(token)headers.set('Authorization',`Bearer ${token}`);
  const response=await fetch(path,{...options,headers,credentials:'omit',cache:'no-store'});
  if(!response.ok){
    const body=await response.json().catch(()=>null);
    const detail=typeof body?.detail==='string'?body.detail:`Request failed (${response.status}). Please try again.`;
    throw new APIError(detail,response.status);
  }
  return response;
}
export async function api<T>(path:string,options:RequestInit={}):Promise<T>{const response=await request(path,options);return response.status===204?undefined as T:response.json();}
export function post<T>(path:string,body:unknown={}):Promise<T>{return api(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});}
export async function mediaURL(path:string):Promise<string>{
  if(!path.startsWith('/v1/'))throw new Error('Invalid media location.');
  return URL.createObjectURL(await (await request(path)).blob());
}
export async function saveAsset(path:string,filename:string){const url=await mediaURL(path);const a=document.createElement('a');a.href=url;a.download=filename;a.click();setTimeout(()=>URL.revokeObjectURL(url),10000);}
