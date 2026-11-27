/**
 * 跨平台歌词兜底（LyricResolver）—— 解决「本平台没有这首歌的歌词就显示暂无歌词」。
 *
 * 背景（2026-11-16 实测）：
 * - 酷我 m.kuwo.cn/newh5/singles/songinfoandlrc 已整体失效（返回 status 301 音乐查询失败），
 *   酷我网页版 /api/www/music/lyric 需要 kw_token + csrf 头（illegal），侧载 App 拿不到 → 酷我歌全都无歌词；
 * - 网易 eapi 签名链路不稳定，而**明文**接口 music.163.com/api/song/lyric 与 api/search/get 一直可用；
 * - 酷狗 lyrics.kugou.com 的 keyword 搜索歌手字段不可靠（"晴天 | 晴天"），当兜底会串歌词，故不做兜底源。
 *
 * 策略：本平台取不到 → 用「歌名 + 歌手 + 时长」到网易明文接口搜索，
 * 严格打分（标题必须匹配、歌手需有交集、时长偏差超限直接拒绝）取最高分候选的歌词，
 * 命中/未命中都缓存，避免同一首歌反复发请求。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LyricInfo } from '../model/MusicTypes';
import { HttpClient, HttpResult, Json, encodeQuery } from './net/HttpClient';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

const WY_HEADERS: Record<string, string> = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Referer': 'https://music.163.com/',
};

/** 一次搜索取的候选条数（放大，给严格打分留足命中空间） */
const SEARCH_LIMIT: number = 20;
/** 缓存上限（含未命中，避免同一首反复搜索） */
const CACHE_MAX: number = 400;
/** 时长偏差容忍：超过该值认为是同曲不同版本（Live/伴奏/加长版），直接拒绝 */
const DURATION_REJECT_MS: number = 25000;
/** 时长很接近的阈值 */
const DURATION_TIGHT_MS: number = 3000;
/** 时长较接近的阈值 */
const DURATION_LOOSE_MS: number = 9000;

export interface LyricTarget {
  name: string;
  singer: string;
  /** 目标歌曲时长（ms），<=0 表示未知 */
  durationMs: number;
}

/** 通用歌词候选（网易/QQ 等来源共用同一套严格打分） */
export interface LyricCandidate {
  id: string;
  name: string;
  singers: string[];
  durationMs: number;
}

interface ScoredSong {
  song: LyricCandidate;
  score: number;
  diffMs: number;
}

/** 标题归一化：小写、去括号内容、去版本后缀、只保留中英文数字 */
export function normalizeLyricTitle(raw: string): string {
  let t: string = raw.toLowerCase();
  // 去掉括号内容（中英文全半角）
  t = t.replace(/[（(\[【《][^）)\]】》]*[）)\]】》]/g, ' ');
  // 去掉 feat./ft. 之后的内容
  t = t.replace(/\b(feat|ft|featuring)\b[\s\S]*$/g, ' ');
  // 去掉「 - 版本标记」整段后缀（Remastered 2019 / Live at xxx / Instrumental 之类）
  t = t.replace(/\s*[-–—]\s*(remaster\w*|live|remix|version|edit|acoustic|instrumental|伴奏|翻唱|纯音乐)[\s\S]*$/g, ' ');
  // 去掉常见版本后缀词
  t = t.replace(/(live|remix|伴奏|纯音乐|dj|原唱|翻唱|cover|instrumental|acoustic|remaster\w*|版|片段)/g, ' ');
  // 只删标点/空白/符号，保留所有语言文字（中文、日文假名、韩文、西里尔等都要留着，
  // 否则「残酷な天使のテーゼ」这类会被清成空串，直接判为不匹配）
  t = t.replace(/[\s\-_.,!?'"“”‘’·、，。！？；：（）()【】\[\]《》〈〉<>/\\|~`@#$%^&*+=×]+/g, '');
  return t;
}

/** 歌手名归一化拆分：支持 / 、 , & ; + · 与 feat./ft. 分隔 */
export function splitSingerNames(raw: string): string[] {
  const out: string[] = [];
  if (raw.length === 0) {
    return out;
  }
  const parts: string[] = raw.split(/[\/、,&;+·×]|feat\.?|ft\.?/i);
  for (const p of parts) {
    const n: string = p.replace(/[\s\-_.,!?'"“”‘’·、，。！？；：（）()【】\[\]《》〈〉<>/\\|~`@#$%^&*+=]+/g, '').toLowerCase();
    if (n.length > 0 && n !== '未知歌手' && n !== 'unknown') {
      out.push(n);
    }
  }
  return out;
}

/** "03:55" → 235000ms；解析不出来返回 0 */
export function parseIntervalMs(interval: string | null): number {
  if (interval === null || interval.length === 0) {
    return 0;
  }
  const parts: string[] = interval.split(':');
  if (parts.length === 2) {
    const m: number = parseInt(parts[0], 10);
    const s: number = parseInt(parts[1], 10);
    if (!isNaN(m) && !isNaN(s)) {
      return (m * 60 + s) * 1000;
    }
  }
  if (parts.length === 3) {
    const h: number = parseInt(parts[0], 10);
    const m: number = parseInt(parts[1], 10);
    const s: number = parseInt(parts[2], 10);
    if (!isNaN(h) && !isNaN(m) && !isNaN(s)) {
      return (h * 3600 + m * 60 + s) * 1000;
    }
  }
  return 0;
}

/** 标题匹配度：100 = 归一化后完全一致；40 = 互相包含且长度比足够；0 = 不匹配 */
function titleScore(a: string, b: string): number {
  if (a.length === 0 || b.length === 0) {
    return 0;
  }
  if (a === b) {
    return 100;
  }
  const shortLen: number = a.length < b.length ? a.length : b.length;
  const longLen: number = a.length < b.length ? b.length : a.length;
  const contained: boolean = a.indexOf(b) >= 0 || b.indexOf(a) >= 0;
  if (contained && shortLen >= 3 && shortLen / longLen >= 0.6) {
    return 40;
  }
  return 0;
}

/**
 * 版本标记惩罚：候选标题带 Live / 伴奏 / 纯音乐 / DJ 等标记时扣分，
 * 保证「原唱版」优先于同名不同版本（时间轴往往对不上，串了会明显错位）。
 */
export function versionPenalty(rawName: string): number {
  const t: string = rawName.toLowerCase();
  if (/(伴奏|纯音乐|instrumental|karaoke|off ?vocal|无人声)/.test(t)) {
    return 45;
  }
  if (/(live|演唱会|现场|concert)/.test(t)) {
    return 25;
  }
  if (/(remix|dj|加快|降调|慢速|倍速|cover|翻唱|片段|新版|重制)/.test(t)) {
    return 30;
  }
  return 0;
}

/** 歌手是否有交集（相等或互相包含，长度 >= 2 才算，避免 "jay" 之类误命中） */
export function singerMatched(targets: string[], cands: string[]): boolean {
  for (const t of targets) {
    for (const c of cands) {
      if (t === c) {
        return true;
      }
      const shortLen: number = t.length < c.length ? t.length : c.length;
      if (shortLen >= 2 && (t.indexOf(c) >= 0 || c.indexOf(t) >= 0)) {
        return true;
      }
    }
  }
  return false;
}

/**
 * 从候选里挑最可信的一首：
 * - 标题必须匹配（否则直接丢弃）；
 * - 时长未知时不做时长判定，时长已知且偏差过大直接丢弃；
 * - 标题完全一致 → 只要有歌手交集或时长接近即可；标题只是包含关系 → 必须歌手有交集。
 */
export function pickBestCandidate(songs: LyricCandidate[], target: LyricTarget): LyricCandidate | null {
  const titleNorm: string = normalizeLyricTitle(target.name);
  const targetSingers: string[] = splitSingerNames(target.singer);
  const scored: ScoredSong[] = [];
  for (const s of songs) {
    const ts: number = titleScore(titleNorm, normalizeLyricTitle(s.name));
    if (ts === 0) {
      continue;
    }
    const diffMs: number = target.durationMs > 0 && s.durationMs > 0
      ? Math.abs(s.durationMs - target.durationMs) : -1;
    if (diffMs > DURATION_REJECT_MS) {
      continue;
    }
    const sHit: boolean = targetSingers.length === 0 ? true : singerMatched(targetSingers, s.singers);
    let durationScore: number = 0;
    if (diffMs >= 0) {
      if (diffMs <= DURATION_TIGHT_MS) {
        durationScore = 20;
      } else if (diffMs <= DURATION_LOOSE_MS) {
        durationScore = 10;
      }
    } else {
      // 时长未知：给中性分，避免把正常候选压到阈值以下
      durationScore = 10;
    }
    if (ts === 40 && !sHit) {
      continue;
    }
    if (ts === 100 && !sHit && durationScore < 10) {
      continue;
    }
    let score: number = ts + durationScore + (sHit ? 30 : 0) - versionPenalty(s.name);
    // 同分时优先时长更接近：把偏差作为小数扣减，排序即可自然体现
    if (diffMs > 0) {
      score -= diffMs / 100000;
    }
    scored.push({ song: s, score, diffMs });
  }
  if (scored.length === 0) {
    return null;
  }
  scored.sort((a: ScoredSong, b: ScoredSong): number => b.score - a.score);
  return scored[0].song;
}

export class LyricResolver {
  private static sInstance: LyricResolver | null = null;
  /** key = 归一化歌名|歌手|时长，value 为命中的歌词（null 表示确认没有） */
  private cache: Map<string, LyricInfo | null> = new Map();
  /** 正在进行的查询（并发去重，避免同时点两次发两遍请求） */
  private pending: Map<string, Promise<LyricInfo | null>> = new Map();

  static getInstance(): LyricResolver {
    if (LyricResolver.sInstance === null) {
      LyricResolver.sInstance = new LyricResolver();
    }
    return LyricResolver.sInstance;
  }

  /** 是否已经查过（命中或确认没有） */
  isResolved(target: LyricTarget): boolean {
    return this.cache.has(this.keyOf(target));
  }

  /** 忘掉某首歌的匹配结果（手动「自动匹配」时调用，让下一次真正重新联网） */
  forget(target: LyricTarget): void {
    const key: string = this.keyOf(target);
    this.cache.delete(key);
    this.pending.delete(key);
  }

  /**
   * 按「歌名 + 歌手 + 时长」到网易明文接口取歌词。
   * 命中返回歌词；确认没有返回 null（并缓存），后续同曲不再请求。
   */
  async resolve(target: LyricTarget): Promise<LyricInfo | null> {
    const key: string = this.keyOf(target);
    if (this.cache.has(key)) {
      return this.cache.get(key) ?? null;
    }
    const running: Promise<LyricInfo | null> | undefined = this.pending.get(key);
    if (running !== undefined) {
      return await running;
    }
    const task: Promise<LyricInfo | null> = this.doResolve(target);
    this.pending.set(key, task);
    let result: LyricInfo | null = null;
    let transientFailure: boolean = false;
    try {
      result = await task;
    } catch (e) {
      // 网络失败 / 异常是瞬时状态，不能当「确认无歌词」写入负缓存，
      // 否则下次断网恢复后同曲再也不会重试，封面/歌词永久空白。
      void e;
      transientFailure = true;
      result = null;
    }
    this.pending.delete(key);
    // 只有正常完成（命中或确认没有）才记缓存；异常失败留给下次重试
    if (!transientFailure) {
      this.remember(key, result);
    }
    return result;
  }

  private keyOf(t: LyricTarget): string {
    const dur: number = t.durationMs > 0 ? Math.round(t.durationMs / 1000) : 0;
    return normalizeLyricTitle(t.name) + '|' +
      splitSingerNames(t.singer).join(',') + '|' + dur.toString();
  }

  private remember(key: string, value: LyricInfo | null): void {
    if (this.cache.size >= CACHE_MAX) {
      // 简单淘汰：清掉最早插入的一批（Map 保持插入顺序）
      let i: number = 0;
      const keys: string[] = [];
      for (const k of this.cache.keys()) {
        keys.push(k);
        i++;
        if (i >= 100) {
          break;
        }
      }
      for (const k of keys) {
        this.cache.delete(k);
      }
    }
    this.cache.set(key, value);
  }

  private async doResolve(target: LyricTarget): Promise<LyricInfo | null> {
    const name: string = target.name.trim();
    if (name.length === 0) {
      return null;
    }
    const singer: string = target.singer.replace(/\s+/g, ' ').trim();
    // 第一轮：歌名 + 歌手（最准）
    if (singer.length > 0 && singer !== '未知歌手') {
      const hit: LyricInfo | null = await this.searchAndFetch(name + ' ' + singer, target);
      if (hit !== null) {
        return hit;
      }
    }
    // 第二轮：只用歌名（覆盖歌手填错 / 翻唱 / 多歌手署名差异，靠严格时长把关）
    const fallback: LyricInfo | null = await this.searchAndFetch(name, target);
    if (fallback !== null) {
      return fallback;
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'lyric fallback miss: %{public}s - %{public}s',
      name, target.singer);
    return null;
  }

  private async searchAndFetch(keyword: string, target: LyricTarget): Promise<LyricInfo | null> {
    const songs: LyricCandidate[] = await this.searchWy(keyword);
    if (songs.length === 0) {
      return null;
    }
    const best: LyricCandidate | null = pickBestCandidate(songs, target);
    if (best === null) {
      return null;
    }
    const lyric: LyricInfo | null = await this.fetchWyLyric(best.id);
    if (lyric !== null) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'lyric fallback hit: %{public}s - %{public}s (wy %{public}s)',
        target.name, target.singer, best.id);
    }
    return lyric;
  }

  private async searchWy(keyword: string): Promise<LyricCandidate[]> {
    const url: string = 'https://music.163.com/api/search/get?s=' + encodeQuery(keyword) +
      '&type=1&limit=' + SEARCH_LIMIT.toString() + '&offset=0';
    const resp: HttpResult = await HttpClient.get(url, WY_HEADERS);
    if (!resp.ok) {
      // 网络失败是瞬时故障：抛给 resolve() 的 catch，避免被当成「确认无歌词」永久负缓存
      throw new Error('wy lyric search failed: ' + resp.error);
    }
    const j: Object | null = resp.json;
    const result: Object | null = Json.obj(j, 'result');
    const items: Object[] = Json.arr(result, 'songs');
    const out: LyricCandidate[] = [];
    for (const it of items) {
      const id: string = Json.str(it, 'id', '');
      const nm: string = Json.str(it, 'name', '');
      if (id.length === 0 || nm.length === 0) {
        continue;
      }
      const artists: Object[] = Json.arr(it, 'artists');
      const singers: string[] = [];
      for (const a of artists) {
        const n: string = Json.str(a, 'name', '');
        if (n.length > 0) {
          singers.push(...splitSingerNames(n));
        }
      }
      out.push({ id, name: nm, singers, durationMs: Json.num(it, 'duration', 0) });
    }
    return out;
  }

  /** 网易明文歌词：lrc 主歌词 + tlyric 翻译（含逐字时不使用，避免格式差异） */
  private async fetchWyLyric(id: string): Promise<LyricInfo | null> {
    const url: string = 'https://music.163.com/api/song/lyric?id=' + encodeQuery(id) +
      '&lv=-1&kv=-1&tv=-1';
    const resp: HttpResult = await HttpClient.get(url, WY_HEADERS);
    if (!resp.ok) {
      throw new Error('wy lyric fetch failed: ' + resp.error);
    }
    const j: Object | null = resp.json;
    if (j === null) {
      return null;
    }
    const lrcObj: Object | null = Json.obj(j, 'lrc');
    const tObj: Object | null = Json.obj(j, 'tlyric');
    const lrc: string = Json.str(lrcObj, 'lyric', '');
    if (lrc.length === 0 || lrc.indexOf('[') < 0) {
      return null;
    }
    const trans: string = Json.str(tObj, 'lyric', '');
    return {
      lyric: lrc,
      tlyric: trans.includes('[') ? trans : null,
      rlyric: null,
      lxlyric: null,
    };
  }
}
