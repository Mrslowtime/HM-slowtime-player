/**
 * 播放 URL 解析 —— 独立实现协议「自定义音源脚本 musicUrl action」的能力。
 *
 * 协议这条链是 QuickJS 执行脚本 → 脚本 lx.request 发 HTTP → 宿主代发；
 * 鸿蒙版直接由本模块用 @ohos.net.http 请求用户配置的音源端点，协议完全一致：
 *   GET /url/{source}/{songId}/{quality}  或  /url?source=&songId=&quality=
 *   X-Request-Key: {apiKey}
 *   → { code, url }，code 0/200 成功
 *
 * 包含：URL 缓存（按 @music_url__${id}_${type}）、音质降级、换源重试、
 * 业务错误码映射（不把限流误判成可换源失败）、<10s 预取。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { getAppContext } from '../../common/AppContext';
import { MusicInfo, MusicInfoMetaOnline } from '../../model/MusicTypes';
import { Quality, OnlineSource, TRY_QUALITYS_LIST } from '../../config/AppConstants';
import { LOG_DOMAIN, LOG_TAG } from '../../common/Constants';
import { HttpClient, HttpResult, Json, encodeQuery, makeHttpOptions } from './HttpClient';
import { SourceConfig, SourceEndpoint } from './SourceConfig';
import { CustomScriptRunner, ScriptUrlResult } from './CustomScriptRunner';

/** 客户端品牌标识。协议请求头沿用既有格式，仅替换自有品牌字样 */
const CLIENT_ID: string = 'slowtime-hm';
/** 签名鉴权协议（auth='lx'）请求头版本，由脚本从宿主约定的字段读取的版本号 */
const PROTOCOL_VER: string = '2.6.0';

/**
 * 签名鉴权类（flower / grass 同模板）请求签名头 tag：
 * 协议脚本对单音质恒定发送 tag = hex(JSON.stringify([quality], null, 2))，
 * 例 quality='128k' → "5b0a20223132386b220a5d"。该头为服务端校验必填项，缺失会 404。
 */
export function lxTag(quality: string): string {
  const payload: string = '[\n  "' + quality + '"\n]';
  let hex: string = '';
  for (let i: number = 0; i < payload.length; i++) {
    let s: string = payload.charCodeAt(i).toString(16);
    if (s.length < 2) {
      s = '0' + s;
    }
    hex += s;
  }
  return hex;
}

/** 签名鉴权协议（flower / grass 同模板）请求头：UA/ver + 必填 tag 签名（无 source-ver） */
export function lxHeaders(quality: string): Record<string, string> {
  return {
    'User-Agent': CLIENT_ID + '/mobile',
    'ver': PROTOCOL_VER,
    'tag': lxTag(quality),
  };
}

/** 固定密钥协议（ikun / huibq 等）请求头：X-Request-Key 放密钥 */
export function keyHeaders(apiKey: string): Record<string, string> {
  return {
    'Content-Type': 'application/json',
    'User-Agent': CLIENT_ID + '-mobile/' + PROTOCOL_VER,
    'X-Request-Key': apiKey,
  };
}

export interface UrlResolveResult {
  ok: boolean;
  url: string;
  /** 实际使用的音质（可能已降级） */
  quality: Quality;
  /** 实际使用的源（可能已换源） */
  source: OnlineSource;
  error: string;
  /** 限流类错误，不应继续换源重试 */
  tooManyRequests: boolean;
}

/** 音源服务业务错误码映射结果 */
export interface MappedError {
  error: string;
  tooMany: boolean;
}

function makeMappedError(error: string, tooMany: boolean): MappedError {
  const r: MappedError = { error, tooMany };
  return r;
}

let sInstance: MusicUrlResolver | null = null;

/** 播放直链缓存项：自定义音源/公开接口返回的链通常带签名有效期，必须记时间 */
interface UrlCacheEntry {
  url: string;
  at: number;
}

/** 直链缓存有效期：10 分钟。超过后重新取链，避免播到过期地址被判成「播放失败」 */
const CACHE_TTL_MS: number = 10 * 60 * 1000;

/** URL 缓存磁盘文件（放在 cacheDir，系统可回收；独立文件不污染音频缓存索引） */
const URL_CACHE_FILE: string = 'url_cache_v1.json';
/** 磁盘最多保留的链接条数：按取链时间淘汰最旧的，避免文件无限膨胀 */
const URL_CACHE_MAX_ENTRIES: number = 500;
/** 写盘节流：连续取链合并成一次落盘，不打断播放链路 */
const URL_CACHE_FLUSH_MS: number = 2000;

/** 磁盘文件格式：数组而非 Map，ArkTS 严格模式下遍历/反序列化更稳 */
interface UrlCacheFileEntry {
  k: string;
  url: string;
  at: number;
}

function fileStr(r: Record<string, Object>, key: string): string {
  const v: Object = r[key] as Object;
  return typeof v === 'string' ? v as string : '';
}

function fileNum(r: Record<string, Object>, key: string): number {
  const v: Object = r[key] as Object;
  return typeof v === 'number' ? v as number : 0;
}

export class MusicUrlResolver {
  private cache: Map<string, UrlCacheEntry> = new Map();
  /** 磁盘缓存是否已懒加载过（冷启动首次读缓存时才读文件，不拖慢启动） */
  private diskLoaded: boolean = false;
  private diskTimer: number = -1;
  /** 失败负缓存：info.id -> 失败时间戳，60s 内不重复取链，避免把服务端打成限流 */
  private failedAt: Map<string, number> = new Map();
  /** 连续失败次数，达到阈值进入全局冷却 */
  private failStreak: number = 0;
  private cooldownUntil: number = 0;
  private config: SourceConfig = SourceConfig.getInstance();

  static getInstance(): MusicUrlResolver {
    if (sInstance === null) {
      sInstance = new MusicUrlResolver();
    }
    return sInstance;
  }

  /** 按源 + 音质取用于换链的 songId（按脚本 musicInfo._qualitys[type].hash） */
  private songKey(info: MusicInfo, quality: Quality): string {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    // kg 各音质对应不同 hash（FileHash / HQFileHash / SQFileHash / ResFileHash）
    const qhash: string | null | undefined = meta._qualitys.get(quality);
    if (qhash !== undefined && qhash !== null && qhash.length > 0) {
      return qhash;
    }
    if (info.source === 'kg' && meta.hash !== undefined && meta.hash.length > 0) {
      return meta.hash;
    }
    // QQ 音乐换链必须用「歌曲 mid」（meta.songId）；strMediaMid 是文件级 media id，
    // 经公共服务常被忽略或误映射成其它源的链，导致 QQ 源取不到正确直链（已实测验证）。
    if (info.source === 'tx') {
      if (meta.songId.length > 0) {
        return meta.songId;
      }
      if (meta.strMediaMid !== undefined && meta.strMediaMid.length > 0) {
        return meta.strMediaMid;
      }
    }
    if (meta.hash !== undefined && meta.hash.length > 0) {
      return meta.hash;
    }
    if (meta.songId.length > 0) {
      return meta.songId;
    }
    return info.id;
  }

  private cacheKey(id: string, quality: Quality): string {
    return id + '_' + quality;
  }

  /** 该歌曲在音源端点上可用的最高音质（按音质选择逻辑 的取最高可用逻辑） */
  private pickQuality(info: MusicInfo, prefer: Quality, endpoint: SourceEndpoint): Quality | null {
    const start: number = TRY_QUALITYS_LIST.indexOf(prefer);
    const order: Quality[] = start >= 0
      ? TRY_QUALITYS_LIST.slice(start)
      : [prefer, ...TRY_QUALITYS_LIST];
    for (const q of order) {
      if (this.config.supports(endpoint, info.source as OnlineSource, q)) {
        return q;
      }
    }
    return null;
  }

  /** 构造音源端点 URL */
  private buildUrl(e: SourceEndpoint, source: OnlineSource, songId: string, quality: Quality): string {
    if (e.style === 'query') {
      return e.apiUrl + '/url?source=' + encodeQuery(source) +
        '&songId=' + encodeQuery(songId) + '&quality=' + encodeQuery(quality);
    }
    return e.apiUrl + '/url/' + source + '/' + encodeQuery(songId) + '/' + quality;
  }

  private mapError(code: number, msg: string): MappedError {
    switch (code) {
      case 1:
        // 不同音源脚本的 code 1 含义不统一（可能是无版权 / 参数 / 限流），
        // 不再武断写成「IP 被限制」，也**不再按限流处理**：
        // 以前 tooMany=true 会导致「一次 code 1 就全局冷却 60 秒」，
        // 版权缺失的冷门歌很容易连续踩中，表现就是听几首突然全停。
        // 现在只当普通失败：单曲负缓存 + 全局计数 +1，连续 3 次才熔断。
        return makeMappedError('音源服务拒绝取链' + (msg.length > 0 ? '：' + msg : '（code 1）'), false);
      case 2:
        return makeMappedError('音源服务：获取播放链接失败', false);
      case 4:
        return makeMappedError('音源服务：内部错误', false);
      case 5:
      case 429:
        return makeMappedError('音源服务：请求过于频繁，请稍后再试', true);
      case 6:
        return makeMappedError('音源服务：参数错误', false);
      case 403:
        return makeMappedError('音源服务：Key 失效或鉴权失败', false);
      case 500:
        return makeMappedError('音源服务：获取 URL 失败', false);
      default:
        return makeMappedError(msg.length > 0 ? msg : ('音源服务返回 code ' + code.toString()), false);
    }
  }

  /** 单次请求（不含缓存与降级）；e 为本次实际使用的音源服务端点，timeoutMs 控制兜底时长短连 */
  private async fetchOnce(info: MusicInfo, quality: Quality, source: OnlineSource,
    e: SourceEndpoint, timeoutMs: number): Promise<UrlResolveResult> {
    const fail = (err: string, tooMany: boolean = false): UrlResolveResult => {
      return { ok: false, url: '', quality, source, error: err, tooManyRequests: tooMany };
    };
    const songId: string = this.songKey(info, quality);
    const url: string = this.buildUrl(e, source, songId, quality);
    // lx 系（flower/grass）无固定 key，带 UA/ver + 必填 tag 签名；其余走 X-Request-Key
    const isLx: boolean = e.auth === 'signed' || e.auth === 'lx';
    const headers: Record<string, string> = isLx ? lxHeaders(quality) : keyHeaders(e.apiKey);
    // 端点本身为 http 明文（如 97.64.37.235）时保留原样，避免升级 https 后连不上
    const allowHttp: boolean = e.apiUrl.startsWith('http://');
    const opts = makeHttpOptions();
    opts.method = 'GET';
    opts.headers = headers;
    opts.allowHttp = allowHttp;
    opts.timeoutMs = timeoutMs;
    const r: HttpResult = await HttpClient.request(url, opts);
    if (!r.ok || r.json === null) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'music url request failed [%{public}s]: %{public}s', e.id, url);
      return fail('音源服务[' + e.name + ']请求失败：' + (r.error.length > 0 ? r.error : '响应不是 JSON'));
    }
    const code: number = Json.num(r.json, 'code', -1);
    const playUrl: string = Json.str(r.json, 'url', Json.str(r.json, 'data', ''));
    const msg: string = Json.str(r.json, 'msg', Json.str(r.json, 'message', ''));
    // 本协议 约定：服务返回的直链原样交给播放器，不做 scheme 改写
    // （避免误伤只监听明文端口的 CDN，如酷我/酷狗返回 http:// 直链经改写 https 后可能连不上）
    const finalUrl: string = playUrl;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'music url resp [%{public}s] code=%{public}d msg=%{public}s req=%{public}s body=%{public}s',
      e.id, code, msg, url, r.text.substring(0, 180));
    if ((e.successCodes.includes(code) || code === 0) && finalUrl.startsWith('http')) {
      return { ok: true, url: finalUrl, quality, source, error: '', tooManyRequests: false };
    }
    const mapped = this.mapError(code, msg);
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'music url code=%{public}d %{public}s', code, mapped.error);
    return fail(mapped.error, mapped.tooMany);
  }

  /**
   * 失败记账：负缓存 + 连续失败熔断（避免自己把服务端 IP 打进限流）。
   *
   * isPreload=true 时只返回失败，**不写负缓存、不计全局熔断**：
   * 预取只是「提前 10 秒试一下下一首」，失败多半是瞬时抖动，
   * 不该因为它把整条播放链锁 60 秒（这正是「听五六首就停」的来源之一）。
   * 用户真正切到那首歌时会重新正常取一次链。
   */
  private markFail(info: MusicInfo, r: UrlResolveResult, isPreload: boolean = false): UrlResolveResult {
    if (isPreload) {
      return r;
    }
    this.failedAt.set(info.id, Date.now());
    this.failStreak++;
    if (r.tooManyRequests || this.failStreak >= 3) {
      this.cooldownUntil = Date.now() + 60000;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'music url 连续失败，冷却 60s');
      this.failStreak = 0;
    }
    return r;
  }

  /**
   * 候选音源服务：当前生效的排最前，其余「已启用且支持该音源」的服务按序兜底。
   * 本协议 的多公共服务自动切换——某一公共服务不可达/被限流/不支持该平台时，
   * 自动尝试下一个，而不是整条播放链路一起失败。
   */
  private candidateEndpoints(source: OnlineSource): SourceEndpoint[] {
    const active: SourceEndpoint | null = this.config.getActive();
    const order: SourceEndpoint[] = [];
    if (active !== null && active.enabled && active.apiUrl.length > 0) {
      order.push(active);
    }
    for (const e of this.config.getEndpoints()) {
      if (order.indexOf(e) >= 0) {
        continue;
      }
      if (!e.enabled || e.apiUrl.length === 0) {
        continue;
      }
      if (e.sources.indexOf(source) < 0) {
        continue;
      }
      order.push(e);
    }
    return order;
  }

  /**
   * 解析播放链接：缓存 → 多音源服务兜底 → 每服务内音质降级。
   * isPreload=true 表示这是「下一首预取」：失败不落负缓存、不计全局熔断。
   */
  async resolve(info: MusicInfo, prefer: Quality, isPreload: boolean = false,
    forDownload: boolean = false): Promise<UrlResolveResult> {
    if (info.source === 'local') {
      return { ok: false, url: '', quality: prefer, source: 'kw', error: '本地歌曲无需解析', tooManyRequests: false };
    }
    // 缓存命中优先于一切失败状态：手里有未过期的可用链接就直接返回，
    // 不被 60s 全局冷却 / 单曲负缓存误伤（「缓存优先于请求」的核心，也少发一次取链请求）。
    const cached: string | undefined = this.cacheGet(this.cacheKey(info.id, prefer));
    if (cached !== undefined && cached.length > 0) {
      return {
        ok: true, url: cached, quality: prefer, source: info.source as OnlineSource,
        error: '', tooManyRequests: false,
      };
    }
    const now: number = Date.now();
    // 下载链路独立于播放熔断：既不写负缓存/冷却，也不被播放的冷却挡住；
    // 请求频率由 DownloadSourceFallback 自己的低风控上限控制。
    if (!forDownload) {
      if (this.cooldownUntil > now) {
        const wait: number = Math.ceil((this.cooldownUntil - now) / 1000);
        return {
          ok: false, url: '', quality: prefer, source: info.source as OnlineSource,
          error: '取链失败次数过多，请 ' + wait.toString() + ' 秒后再试', tooManyRequests: true,
        };
      }
      const failedAt: number | undefined = this.failedAt.get(info.id);
      if (failedAt !== undefined && now - failedAt < 60000) {
        return {
          ok: false, url: '', quality: prefer, source: info.source as OnlineSource,
          error: '这首歌刚刚取链失败，60 秒内不再重试', tooManyRequests: true,
        };
      }
    }

    // 自定义音源脚本优先（按：导入的 .js 由独立沙箱执行）。
    // 未导入 / 未初始化 / 不支持该源 / 取链失败都返回 null，静默回落到下方 HTTP 音源服务，
    // 保证没有自定义源时播放链路与改造前完全等价。
    const custom: ScriptUrlResult | null =
      await CustomScriptRunner.getInstance().tryResolve(info, prefer, forDownload);
    if (custom !== null && custom.ok && custom.url.length > 0) {
      this.cacheSet(this.cacheKey(info.id, custom.quality), custom.url);
      this.failStreak = 0;
      this.failedAt.delete(info.id);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'music url resolved by custom script: %{public}s @%{public}s',
        info.name, custom.quality);
      return {
        ok: true, url: custom.url, quality: custom.quality,
        source: info.source as OnlineSource, error: '', tooManyRequests: false,
      };
    }

    const candidates: SourceEndpoint[] = this.candidateEndpoints(info.source as OnlineSource);
    if (candidates.length === 0) {
      return {
        ok: false, url: '', quality: prefer, source: info.source as OnlineSource,
        error: '尚未配置音源服务，请在「设置 → 音源服务」中填写', tooManyRequests: false,
      };
    }
    let last: UrlResolveResult = {
      ok: false, url: '', quality: prefer, source: info.source as OnlineSource,
      error: '未知错误', tooManyRequests: false,
    };
    let triedAny: boolean = false;
    for (let ci = 0; ci < candidates.length; ci++) {
      const e: SourceEndpoint = candidates[ci];
      const timeoutMs: number = ci === 0 ? 15000 : 8000;
      const picked: Quality | null = this.pickQuality(info, prefer, e);
      if (picked === null) {
        continue;
      }
      triedAny = true;
      // 优先请求目标音质，失败则按 TRY_QUALITYS_LIST 向后降级
      const start: number = TRY_QUALITYS_LIST.indexOf(picked);
      const order: Quality[] = start >= 0 ? TRY_QUALITYS_LIST.slice(start) : [picked];
      for (const q of order) {
        if (!this.config.supports(e, info.source as OnlineSource, q)) {
          continue;
        }
        const c: string | undefined = this.cacheGet(this.cacheKey(info.id, q));
        if (c !== undefined && c.length > 0) {
          return { ok: true, url: c, quality: q, source: info.source as OnlineSource, error: '', tooManyRequests: false };
        }
        last = await this.fetchOnce(info, q, info.source as OnlineSource, e, timeoutMs);
        if (last.ok) {
          this.cacheSet(this.cacheKey(info.id, q), last.url);
          this.failStreak = 0;
          this.failedAt.delete(info.id);
          hilog.info(LOG_DOMAIN, LOG_TAG, 'music url resolved: %{public}s @%{public}s via %{public}s',
            info.name, q, e.id);
          return last;
        }
        if (last.tooManyRequests) {
          // 限流：本服务停止，但尝试其它服务（限流是服务级而非全局）
          break;
        }
      }
    }
    if (!last.ok && !triedAny) {
      last.error = '所有已配置音源服务都不支持音源「' + (info.source as OnlineSource) + '」';
    } else if (!last.ok && last.error === '未知错误') {
      last.error = '所有音源服务都未能为「' + (info.source as OnlineSource) + '」取到播放链接';
    }
    if (forDownload) {
      return last;
    }
    return this.markFail(info, last, isPreload);
  }

  /** 磁盘文件路径：放在 cacheDir（系统可回收），独立文件不与音频缓存索引混在一起 */
  private diskPath(): string {
    const ctx = getAppContext();
    if (ctx === null) {
      return '';
    }
    return ctx.cacheDir + '/' + URL_CACHE_FILE;
  }

  /**
   * 冷启动懒加载：首次读缓存时把磁盘上未过期的链接灌回内存。
   * 过期条目直接丢弃；超出上限的按取链时间保留最新的一批。
   * 不放在构造里，是为了不拖慢启动（首播前 prepare 会 await 一堆初始化）。
   */
  private loadDisk(): void {
    if (this.diskLoaded) {
      return;
    }
    this.diskLoaded = true;
    const p: string = this.diskPath();
    if (p.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(p)) {
        return;
      }
      const text: string = fs.readTextSync(p);
      const obj: Object = JSON.parse(text) as Object;
      if (obj === null || obj === undefined || !Array.isArray(obj)) {
        return;
      }
      const now: number = Date.now();
      for (const it of obj as Object[]) {
        const r: Record<string, Object> = it as Record<string, Object>;
        const k: string = fileStr(r, 'k');
        const url: string = fileStr(r, 'url');
        const at: number = fileNum(r, 'at');
        if (k.length === 0 || url.length === 0 || at <= 0 || now - at > CACHE_TTL_MS) {
          continue;
        }
        this.cache.set(k, { url: url, at: at });
      }
      this.trimCache();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'url cache loaded from disk: %{public}d entries', this.cache.size);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'url cache load failed, start empty');
    }
  }

  /** 内存/磁盘条目上限：按取链时间保留最新的 URL_CACHE_MAX_ENTRIES 条 */
  private trimCache(): void {
    if (this.cache.size <= URL_CACHE_MAX_ENTRIES) {
      return;
    }
    const sorted: UrlCacheFileEntry[] = [];
    this.cache.forEach((v: UrlCacheEntry, k: string): void => {
      sorted.push({ k: k, url: v.url, at: v.at });
    });
    sorted.sort((a: UrlCacheFileEntry, b: UrlCacheFileEntry): number => b.at - a.at);
    for (let i: number = URL_CACHE_MAX_ENTRIES; i < sorted.length; i++) {
      this.cache.delete(sorted[i].k);
    }
  }

  /** 磁盘落盘（临时文件 + rename，避免中途被杀留下半截 JSON） */
  private flushDisk(): void {
    if (this.diskTimer >= 0) {
      clearTimeout(this.diskTimer);
      this.diskTimer = -1;
    }
    const p: string = this.diskPath();
    if (p.length === 0) {
      return;
    }
    const now: number = Date.now();
    const arr: UrlCacheFileEntry[] = [];
    this.cache.forEach((v: UrlCacheEntry, k: string): void => {
      if (v.url.length > 0 && now - v.at <= CACHE_TTL_MS) {
        arr.push({ k: k, url: v.url, at: v.at });
      }
    });
    arr.sort((a: UrlCacheFileEntry, b: UrlCacheFileEntry): number => b.at - a.at);
    const out: UrlCacheFileEntry[] = arr.length > URL_CACHE_MAX_ENTRIES
      ? arr.slice(0, URL_CACHE_MAX_ENTRIES) : arr;
    try {
      const tmp: string = p + '.tmp';
      const f: fs.File = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(out));
      } finally {
        fs.closeSync(f);
      }
      fs.renameSync(tmp, p);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'url cache flush failed');
    }
  }

  /** 写盘节流：一首歌可能连续降级取多次链，合并成一次落盘 */
  private markDiskDirty(): void {
    if (this.diskTimer >= 0) {
      return;
    }
    this.diskTimer = setTimeout((): void => {
      this.diskTimer = -1;
      this.flushDisk();
    }, URL_CACHE_FLUSH_MS);
  }

  /** 切后台 / 退出时强制落盘，避免节流窗口内被杀丢掉刚取的链接 */
  flushNow(): void {
    this.flushDisk();
  }

  /** 读缓存（过期即丢弃，返回 undefined 让调用方重新取链） */
  private cacheGet(key: string): string | undefined {
    this.loadDisk();
    const e: UrlCacheEntry | undefined = this.cache.get(key);
    if (e === undefined) {
      return undefined;
    }
    if (Date.now() - e.at > CACHE_TTL_MS) {
      this.cache.delete(key);
      this.markDiskDirty();
      return undefined;
    }
    return e.url.length > 0 ? e.url : undefined;
  }

  private cacheSet(key: string, url: string): void {
    if (url.length === 0) {
      return;
    }
    this.cache.set(key, { url: url, at: Date.now() });
    this.trimCache();
    this.markDiskDirty();
  }

  /** 缓存失效（切音质 / URL 过期 / 播放失败重取） */
  invalidate(id: string): void {
    const keys: string[] = [];
    this.cache.forEach((_v: UrlCacheEntry, k: string): void => {
      if (k.startsWith(id + '_')) {
        keys.push(k);
      }
    });
    for (const k of keys) {
      this.cache.delete(k);
    }
    if (keys.length > 0) {
      this.markDiskDirty();
    }
  }

  /** 剩余 <10s 预取下一首 */
  preload(info: MusicInfo, quality: Quality): void {
    if (info.source === 'local') {
      return;
    }
    const key: string = this.cacheKey(info.id, quality);
    if (this.cacheGet(key) !== undefined) {
      return;
    }
    // 只用自定义源、没配 HTTP 端点时也要预取：这一路是沙箱唯一的「提前自愈」窗口，
    // 提前 10s 就会触发探活 + 后台重建，切歌时环境已经好了；
    // 否则只能等切歌那一刻在 6s 预算里现等，失败一次就整首停住。
    if (!this.config.isConfigured() && !CustomScriptRunner.getInstance().hasActiveScript()) {
      return;
    }
    this.resolve(info, quality, true).then((r: UrlResolveResult): void => {
      if (r.ok) {
        this.cacheSet(this.cacheKey(info.id, r.quality), r.url);
      }
    }).catch((): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'preload failed');
    });
  }

  /**
   * 切换音源 / 音质 / 重新导入脚本时调用。
   * 除了直链缓存，必须一并重置失败计数与冷却：切换音源是用户主动行为，
   * 旧音源攒下的熔断不该跨源继续拦住新音源（否则切源后仍要干等 60 秒，
   * 用户只能重启应用——这正是「切换其他源不生效」的原因）。
   */
  clearCache(): void {
    this.cache.clear();
    this.failedAt.clear();
    this.failStreak = 0;
    this.cooldownUntil = 0;
    // 磁盘缓存一并清掉：切源/切音质后不能让重启又把旧源的链接加载回来
    this.flushDisk();
  }

  /** 全局取链冷却剩余毫秒（0 = 未冷却）；供播放器安排「冷却到期自动恢复」 */
  getCooldownRemainMs(): number {
    const left: number = this.cooldownUntil - Date.now();
    return left > 0 ? left : 0;
  }
}
