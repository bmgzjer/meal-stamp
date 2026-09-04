import { createClient } from '@supabase/supabase-js';

const CONFIG_KEY = 'meal_stamp_cloud_config_v1';
const ACTIVE_SPACE_KEY = 'meal_stamp_active_space_v1';
const ROLE_KEY = 'meal_stamp_cached_role_v1';
const SPACE_META_KEY = 'meal_stamp_cached_space_meta_v1';

const DEFAULT_CLOUD_CONFIG = {
  url: 'https://rtnfpdnvxfcdbneefhqt.supabase.co',
  key: 'sb_publishable_jxz9pHBxwsLN2xBHjlZuXw_5a2ya2AZ'
};

const jsonGet = (key, fallback=null) => { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; } };
const must = (data, error) => { if (error) throw error; return data; };

export class CloudBridge {
  constructor(){
    this.config = jsonGet(CONFIG_KEY, DEFAULT_CLOUD_CONFIG) || DEFAULT_CLOUD_CONFIG;
    this.client = null;
    this.user = null;
    this.space = null;
    this.role = localStorage.getItem(ROLE_KEY) || '';
    this.channel = null;
    this._lockLoginUI();
    if (this.config?.url && this.config?.key) this._createClient();
  }

_lockLoginUI(){
    const apply = () => {
      const signup = document.getElementById('signupBtn');
      const changeConfig = document.getElementById('changeCloudConfig');
      const login = document.getElementById('loginBtn');

      if (signup) signup.style.display = 'none';
      if (changeConfig) changeConfig.style.display = 'none';
      if (login) login.style.width = '100%';
    };

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', apply, { once:true });
    } else {
      apply();
    }
  }
  
  _createClient(){
    this.client = createClient(this.config.url, this.config.key, {
      auth: { persistSession:true, autoRefreshToken:true, detectSessionInUrl:true },
      realtime: { params: { eventsPerSecond: 8 } }
    });
  }

  hasConfig(){ return !!(this.config?.url && this.config?.key); }
  getCachedSpace(){ return jsonGet(SPACE_META_KEY, null); }
  setConfig(url,key){
    url = String(url||'').trim().replace(/\/+$/,''); key = String(key||'').trim();
    if (!/^https:\/\/.+\.supabase\.co$/i.test(url) && !/^https:\/\//i.test(url)) throw new Error('Supabase URL 格式不正确');
    if (key.length < 20) throw new Error('Publishable key 看起来不完整');
    this.config={url,key}; localStorage.setItem(CONFIG_KEY,JSON.stringify(this.config)); this._createClient();
  }
  clearConfig(){ localStorage.removeItem(CONFIG_KEY); localStorage.removeItem(ACTIVE_SPACE_KEY); localStorage.removeItem(ROLE_KEY); localStorage.removeItem(SPACE_META_KEY); this.config={...DEFAULT_CLOUD_CONFIG}; this.client=null; this.user=null; this.space=null; this.role=''; this._createClient(); }

  async getSession(){
    if(!this.client) return null;
    const {data,error}=await this.client.auth.getSession(); if(error) throw error;
    this.user=data.session?.user||null; return data.session||null;
  }
  async signIn(email,password){ const {data,error}=await this.client.auth.signInWithPassword({email:email.trim(),password}); must(data,error); this.user=data.user; return data; }
  async signUp(){ throw new Error('注册功能已关闭，仅允许现有账号登录。'); }
  async signOut(){ if(this.channel) await this.client.removeChannel(this.channel).catch(()=>{}); await this.client.auth.signOut(); this.user=null; this.space=null; this.role=''; localStorage.removeItem(ACTIVE_SPACE_KEY); localStorage.removeItem(ROLE_KEY); localStorage.removeItem(SPACE_META_KEY); }

  async loadMembership(){
    if(!this.user) await this.getSession(); if(!this.user) return null;
    const {data,error}=await this.client.from('space_members').select('space_id,role').eq('user_id',this.user.id).maybeSingle(); must(data,error);
    if(!data){ this.space=null; this.role=''; return null; }
    const {data:space,error:se}=await this.client.from('spaces').select('*').eq('id',data.space_id).single(); must(space,se);
    this.space=space; this.role=data.role;
    localStorage.setItem(ACTIVE_SPACE_KEY,space.id); localStorage.setItem(ROLE_KEY,this.role); localStorage.setItem(SPACE_META_KEY,JSON.stringify(space));
    return {space,role:this.role};
  }
  async createSpace(name){ const {data,error}=await this.client.rpc('create_space',{p_name:name||'我们的打卡空间'}); must(data,error); await this.loadMembership(); return Array.isArray(data)?data[0]:data; }
  async joinSpace(code){ const {data,error}=await this.client.rpc('join_space',{p_invite_code:String(code||'').trim().toUpperCase()}); must(data,error); await this.loadMembership(); return Array.isArray(data)?data[0]:data; }

  cacheKey(){ return `meal_stamp_state_v4_${this.space?.id || localStorage.getItem(ACTIVE_SPACE_KEY) || 'unknown'}`; }

  async loadState(defaultState){
    if(!this.space) await this.loadMembership(); if(!this.space) throw new Error('尚未加入情侣空间');
    const sid=this.space.id;
    const [sp,checkins,rewards,draws,makeups,chores,choreReqs] = await Promise.all([
      this.client.from('spaces').select('*').eq('id',sid).single(),
      this.client.from('checkins').select('*').eq('space_id',sid),
      this.client.from('rewards').select('*').eq('space_id',sid).order('sort_order'),
      this.client.from('reward_draws').select('*').eq('space_id',sid).order('drawn_at'),
      this.client.from('makeup_requests').select('*').eq('space_id',sid).order('requested_at'),
      this.client.from('chores').select('*').eq('space_id',sid).order('sort_order'),
      this.client.from('chore_requests').select('*').eq('space_id',sid).order('requested_at')
    ]);
    [sp,checkins,rewards,draws,makeups,chores,choreReqs].forEach(x=>{if(x.error)throw x.error});
    this.space=sp.data; localStorage.setItem(SPACE_META_KEY,JSON.stringify(this.space));
    let passwordHash='';
    if(this.role==='admin'){
      const sec=await this.client.from('admin_secrets').select('password_hash').eq('space_id',sid).maybeSingle();
      if(sec.error) throw sec.error; passwordHash=sec.data?.password_hash||'';
    }
    const s=JSON.parse(JSON.stringify(defaultState));
    s.settings={...s.settings,targetDays:sp.data.target_days,rewardEvery:sp.data.reward_every,demo:sp.data.demo,startDate:sp.data.start_date||'',passwordHash};
    s.checkins={};
    for(const r of checkins.data||[]){ const d=String(r.day); s.checkins[d]=s.checkins[d]||{}; s.checkins[d][r.meal]={status:r.status,time:r.checkin_time,photoId:r.photo_id||null,photoPath:r.photo_path||null,bytes:r.bytes||0}; }
    s.rewards=(rewards.data||[]).map(r=>({id:r.id,name:r.name,enabled:r.enabled}));
    s.rewardHistory=(draws.data||[]).map(r=>({id:r.id,reward:r.reward,time:r.drawn_at,mode:r.mode,test:r.is_test,completed:r.completed,completedAt:r.completed_at}));
    s.makeups=(makeups.data||[]).map(r=>({id:r.id,date:String(r.day),meal:r.meal,reason:r.reason,auto:r.auto_detected,status:r.status,time:r.requested_at,reviewedAt:r.reviewed_at}));
    s.chores=(chores.data||[]).map(r=>({id:r.id,name:r.name,credit:r.credit}));
    s.choreRequests=(choreReqs.data||[]).map(r=>({id:r.id,month:r.month,choreId:r.chore_id,choreName:r.chore_name,credit:r.credit,note:r.note,status:r.status,time:r.requested_at,reviewedAt:r.reviewed_at}));
    return s;
  }

  async syncState(state){
    if(!this.space || !this.user) return;
    const sid=this.space.id, uid=this.user.id, ops=[];
    if(this.role==='admin'){
      ops.push(this.client.from('spaces').update({target_days:+state.settings.targetDays||22,reward_every:+state.settings.rewardEvery||15,start_date:state.settings.startDate||null,demo:!!state.settings.demo}).eq('id',sid));
      ops.push(this.client.from('admin_secrets').upsert({space_id:sid,password_hash:state.settings.passwordHash||''},{onConflict:'space_id'}));
      if(state.rewards.length) ops.push(this.client.from('rewards').upsert(state.rewards.map((r,i)=>({id:r.id,space_id:sid,name:r.name,enabled:!!r.enabled,sort_order:i})),{onConflict:'space_id,id'}));
      if(state.chores.length) ops.push(this.client.from('chores').upsert(state.chores.map((r,i)=>({id:r.id,space_id:sid,name:r.name,credit:+r.credit||1,sort_order:i})),{onConflict:'space_id,id'}));
    }
    const checkRows=[]; for(const [day,v] of Object.entries(state.checkins||{})) for(const meal of ['lunch','dinner']) if(v?.[meal]?.status){ const x=v[meal]; checkRows.push({space_id:sid,day,meal,status:x.status,checkin_time:x.time||new Date().toISOString(),photo_id:x.photoId||null,photo_path:x.photoPath||null,bytes:+x.bytes||0,updated_by:uid}); }
    if(checkRows.length) ops.push(this.client.from('checkins').upsert(checkRows,{onConflict:'space_id,day,meal'}));
    if(state.rewardHistory.length) ops.push(this.client.from('reward_draws').upsert(state.rewardHistory.map(x=>({id:x.id,space_id:sid,reward:x.reward,mode:x.mode,is_test:!!x.test,drawn_at:x.time,completed:!!x.completed,completed_at:x.completedAt||null,user_id:uid})),{onConflict:'space_id,id'}));
    if(this.role==='admin') {
      if(state.makeups.length) ops.push(this.client.from('makeup_requests').upsert(state.makeups.map(x=>({id:x.id,space_id:sid,day:x.date,meal:x.meal,reason:x.reason||'',auto_detected:!!x.auto,status:x.status,requested_at:x.time,reviewed_at:x.reviewedAt||null,reviewed_by:x.reviewedAt?uid:null})),{onConflict:'space_id,id'}));
      if(state.choreRequests.length) ops.push(this.client.from('chore_requests').upsert(state.choreRequests.map(x=>({id:x.id,space_id:sid,month:x.month,chore_id:x.choreId||null,chore_name:x.choreName,credit:+x.credit||1,note:x.note||'',status:x.status,requested_at:x.time,reviewed_at:x.reviewedAt||null,reviewed_by:x.reviewedAt?uid:null})),{onConflict:'space_id,id'}));
    } else {
      const [mr,cr]=await Promise.all([
        this.client.from('makeup_requests').select('id').eq('space_id',sid),
        this.client.from('chore_requests').select('id').eq('space_id',sid)
      ]);
      if(mr.error)throw mr.error; if(cr.error)throw cr.error;
      const haveM=new Set((mr.data||[]).map(x=>x.id)), haveC=new Set((cr.data||[]).map(x=>x.id));
      const newM=state.makeups.filter(x=>x.status==='pending'&&!haveM.has(x.id)).map(x=>({id:x.id,space_id:sid,day:x.date,meal:x.meal,reason:x.reason||'',auto_detected:!!x.auto,status:'pending',requested_at:x.time,requested_by:uid}));
      const newC=state.choreRequests.filter(x=>x.status==='pending'&&!haveC.has(x.id)).map(x=>({id:x.id,space_id:sid,month:x.month,chore_id:x.choreId||null,chore_name:x.choreName,credit:+x.credit||1,note:x.note||'',status:'pending',requested_at:x.time,requested_by:uid}));
      if(newM.length) ops.push(this.client.from('makeup_requests').insert(newM));
      if(newC.length) ops.push(this.client.from('chore_requests').insert(newC));
    }
    const results=await Promise.all(ops); const bad=results.find(x=>x.error); if(bad) throw bad.error;
  }

  async deleteCheckin(day,meal){ if(!this.space)return; const {error}=await this.client.from('checkins').delete().eq('space_id',this.space.id).eq('day',day).eq('meal',meal); if(error)throw error; }
  async deleteReward(id){ if(this.role!=='admin')return; const {error}=await this.client.from('rewards').delete().eq('space_id',this.space.id).eq('id',id); if(error)throw error; }
  async deleteChore(id){ if(this.role!=='admin')return; const {error}=await this.client.from('chores').delete().eq('space_id',this.space.id).eq('id',id); if(error)throw error; }

  async uploadPhoto(day,meal,photoId,blob){
    if(!this.space) throw new Error('没有情侣空间');
    const path=`${this.space.id}/${day}/${meal}/${photoId}.jpg`;
    const {error}=await this.client.storage.from('checkin-photos').upload(path,blob,{contentType:'image/jpeg',upsert:true,cacheControl:'3600'}); if(error)throw error; return path;
  }
  async downloadPhoto(path){ const {data,error}=await this.client.storage.from('checkin-photos').download(path); if(error)throw error; return data; }
  async deletePhoto(path){ if(!path)return; const {error}=await this.client.storage.from('checkin-photos').remove([path]); if(error)throw error; }

  async resetSpaceData(){
    if(this.role!=='admin') throw new Error('只有管理员可以清空空间');
    const sid=this.space.id;
    const {data:photos,error:pe}=await this.client.from('checkins').select('photo_path').eq('space_id',sid).not('photo_path','is',null); if(pe)throw pe;
    const paths=(photos||[]).map(x=>x.photo_path).filter(Boolean); if(paths.length){const r=await this.client.storage.from('checkin-photos').remove(paths); if(r.error)throw r.error;}
    for(const t of ['reward_draws','makeup_requests','chore_requests','checkins','rewards','chores']){ const {error}=await this.client.from(t).delete().eq('space_id',sid); if(error)throw error; }
  }

  subscribe(onChange){
    if(!this.client||!this.space)return null; if(this.channel)this.client.removeChannel(this.channel).catch(()=>{});
    const sid=this.space.id, ch=this.client.channel(`meal-stamp-${sid}`);
    const tables=['checkins','rewards','reward_draws','makeup_requests','chores','chore_requests'];
    tables.forEach(table=>ch.on('postgres_changes',{event:'*',schema:'public',table,filter:`space_id=eq.${sid}`},payload=>onChange(payload)));
    ch.on('postgres_changes',{event:'UPDATE',schema:'public',table:'spaces',filter:`id=eq.${sid}`},payload=>onChange(payload));
    this.channel=ch.subscribe(); return this.channel;
  }
}
