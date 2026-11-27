/**
 * 统一缓存内核 —— 音频 / 歌词 / 封面 三层共用一套目录与淘汰策略。
 *
 * 目录（cacheDir，系统可回收）：
 *   music_cache/audio/<id>_<quality>.<ext>   整曲音频（只有「收藏的歌单」会落盘）
 *   music_cache/lyric/<id>.json              已匹配到的歌词（含翻译 / 音译）
 *   cover_cache/<urlHash>.jpg                歌单 / 榜单 / 歌曲封面（沿用原目录，老缓存不丢）
 *   music_cache/index.json                   音频索引：lastAccess / 落盘时间 / 关联封面歌词
 *
 * 淘汰规则（需求）：
 *   - 占用达到上限的 99% 触发；
 *   - 还能往上调（< 6G）时先问用户是否上调一档（+500MiB），后台不打扰、直接清；
 *   - 已是上限或用户拒绝 → 静默清理现有缓存的 49%；
 *   - 音频按「最近访问时间」从旧到新删，删音频时同步删它关联的封面与歌词；
 *   - 封面 / 歌词这类附属文件按「落盘时间」从旧到新删。
 *
 * 请求纪律：音频只在「收藏歌单」的预取窗口里下载一次（替换原本的流播请求，
 * 不额外增加对音源的请求次数）；命中缓存后播放不再发任何请求。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingStore } from '../store/SettingStore';
import { AppState } from '../store/AppState';
import { getAppContext } from '../common/AppContext';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { CoverCache, CacheStatsBrief } from './ImageCache';
import { LyricInfo } from '../model/MusicTypes';

const MB: number = 1024 * 1024;
const DIR_NAME: string = 'music_cache';
const AUDIO_DIR: string = 'audio';
const LYRIC_DIR: string = 'lyric';
const INDEX_FILE: string = 'index.json';

/** 缓存上限档位（MiB）：500 起步，每级 +500，最高 6G */
export const CACHE_LIMIT_STEPS: string[] = [
  '500', '1000', '1500', '2000', '2500', '3000',
  '3500', '4000', '4500', '5000', '5500', '6000',
];
export const CACHE_LIMIT_MAX_MB: number = 6000;
export const CACHE_LIMIT_STEP_MB: number = 500;

/**
 * 整曲音频缓存总开关（2026-11-20 用户拍板启用）。
 * 只对「收藏歌单」的下一首生效：在播放剩余 <30s 的预取窗口里，
 * 用音源返回的 CDN 直链把整曲下到 cacheDir，下一首起播时直接读本地文件。
 * 请求总数不变（原本「取链 + 边播边拉音频」变成「取链 + 提前拉完音频」），
 * 且下载目标是 CDN 直链而非官方 API；命中缓存后为 0 请求。
 * 歌词 / 封面的磁盘复用不受此开关影响（都是已有响应落盘，不额外请求）。
 */
export const AUDIO_CACHE_ENABLED: boolean = true;

/** 触发自动清理的水位：达到上限的 99% */
const TRIGGER_RATIO: number = 0.99;
/** 单次清理要释放的比例（现有缓存体积的 49%） */
const PURGE_RATIO: number = 0.49;

/** 单曲音频落盘上限（防止某些无损文件过大占满） */
const MAX_SINGLE_BYTES: number = 120 * MB;

/** 歌词缓存文件数上限：超过就按最旧清掉一批（每条约几 KB，2000 条约十几 MB） */
const LYRIC_MAX_FILES: number = 2000;
/** 回收后保留的条数（留出余量，避免每写一条就触发一次回收） */
const LYRIC_KEEP_FILES: number = 1600;

/** 歌词缓存文件（按 mtime 排序回收用） */
interface LyricFile {
  path: string;
  mtime: number;
}

/** 索引条目（持久化到 index.json，字段必须是基础类型） */
export interface CacheEntry {
  id: string;
  quality: string;
  path: string;
  size: number;
  /** 落盘时间戳 */
  created: number;
  /** 最近一次播放命中时间（淘汰排序用） */
  lastAccess: number;
  /** 关联封面 URL（删音频时同步删封面） */
  coverUrl: string;
  /** 关联歌词文件绝对路径 */
  lyricPath: string;
}

/** 缓存占用统计 */
export interface CacheStats {
  audioBytes: number;
  coverBytes: number;
  lyricBytes: number;
  totalBytes: number;
  audioCount: number;
  coverCount: number;
  lyricCount: number;
}

/** 索引落盘结构 */
interface CacheIndexFile {
  entries: CacheEntry[];
}

/** 把 id / quality 规整为安全文件名 */
export function cacheSafeName(s: string): string {
  let out: string = '';
  for (let i: number = 0; i < s.length; i++) {
    const c: string = s[i];
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
      c === '_' || c === '-' || c === '.') {
      out += c;
    } else {
      out += '_';
    }
  }
  return out.length > 0 ? out : 'x';
}

/** 字节数格式化 */
export function cacheFormatSize(bytes: number): string {
  if (bytes >= 1024 * MB) {
    return (bytes / (1024 * MB)).toFixed(2) + ' GB';
  }
  if (bytes >= MB) {
    return (bytes / MB).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return bytes.toString() + ' B';
}

export class CacheStore {
  private static sInstance: CacheStore | null = null;

  static getInstance(): CacheStore {
    if (CacheStore.sInstance === null) {
      CacheStore.sInstance = new CacheStore();
    }
    return CacheStore.sInstance;
  }

  private entries: CacheEntry[] = [];
  private loaded: boolean = false;
  /** 在途下载：同一首不重复下载；切歌时可取消，避免与流播重复消耗流量 */
  private inflight: Map<string, http.HttpRequest> = new Map<string, http.HttpRequest>();
  /** 是否处于「收藏歌单」播放上下文（决定是否做智能缓存） */
  private smartCacheOn: boolean = false;
  /** 索引写盘节流（访问时间更新很频繁，不必每次都写） */
  private dirty: boolean = false;
  private flushTimer: number = -1;
  /** 正在询问用户是否上调上限 */
  private asking: boolean = false;
  /** 最近一次是否卸载过（用于调试） */
  private lastPurgeBytes: number = 0;
  /** 水位检查节流：每次下载都全量扫目录太贵，60 秒内只查一次 */
  private lastEnforceAt: number = 0;
  /** 歌词写入计数：用来隔一段时间检查一次条数上限 */
  private lyricWrites: number = 0;

  // ------------------------------------------------------------ 目录

  private root(): string {
    const ctx = getAppContext();
    if (ctx === null) {
      return '';
    }
    return ctx.cacheDir + '/' + DIR_NAME;
  }

  private audioDir(): string {
    return this.root() + '/' + AUDIO_DIR;
  }

  private lyricDir(): string {
    return this.root() + '/' + LYRIC_DIR;
  }

  /** 创建目录（幂等） */
  private ensure(dir: string): string {
    if (dir.length === 0) {
      return '';
    }
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      return dir;
    } catch (e) {
      // 递归创建：cacheDir/music_cache 可能整体不存在
      try {
        const root: string = this.root();
        if (root.length > 0 && !fs.accessSync(root)) {
          fs.mkdirSync(root);
        }
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir);
        }
        return dir;
      } catch (e2) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache mkdir failed');
        return '';
      }
    }
  }

  // ------------------------------------------------------------ 索引

  private indexPath(): string {
    return this.root() + '/' + INDEX_FILE;
  }

  private loadIndex(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    const p: string = this.indexPath();
    if (p.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(p)) {
        return;
      }
      const text: string = fs.readTextSync(p);
      const obj: Object = JSON.parse(text) as Object;
      if (obj === null || obj === undefined) {
        return;
      }
      const rec: Record<string, Object> = obj as Record<string, Object>;
      const arr: Object = rec['entries'] as Object;
      if (arr === undefined || arr === null || !Array.isArray(arr)) {
        return;
      }
      const out: CacheEntry[] = [];
      for (const it of arr as Object[]) {
        const r: Record<string, Object> = it as Record<string, Object>;
        const id: string = this.strOf(r, 'id');
        const path: string = this.strOf(r, 'path');
        if (id.length === 0 || path.length === 0) {
          continue;
        }
        out.push({
          id: id,
          quality: this.strOf(r, 'quality'),
          path: path,
          size: this.numOf(r, 'size'),
          created: this.numOf(r, 'created'),
          lastAccess: this.numOf(r, 'lastAccess'),
          coverUrl: this.strOf(r, 'coverUrl'),
          lyricPath: this.strOf(r, 'lyricPath'),
        });
      }
      this.entries = out;
      // 清掉已被系统回收的条目（cacheDir 可能被系统清理）
      this.entries = this.entries.filter((e: CacheEntry): boolean => {
        try {
          return fs.accessSync(e.path);
        } catch (e2) {
          return false;
        }
      });
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache index load failed');
      this.entries = [];
    }
  }

  private strOf(r: Record<string, Object>, key: string): string {
    const v: Object = r[key] as Object;
    return typeof v === 'string' ? v as string : '';
  }

  private numOf(r: Record<string, Object>, key: string): number {
    const v: Object = r[key] as Object;
    return typeof v === 'number' ? v as number : 0;
  }

  /** 索引写盘（临时文件 + rename，避免中途被杀留下半截 JSON） */
  private flushIndex(): void {
    const p: string = this.indexPath();
    if (p.length === 0) {
      return;
    }
    this.ensure(this.root());
    const payload: CacheIndexFile = { entries: this.entries };
    const text: string = JSON.stringify(payload);
    const tmp: string = p + '.tmp';
    try {
      const f: fs.File = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, text);
      } finally {
        fs.closeSync(f);
      }
      fs.renameSync(tmp, p);
      this.dirty = false;
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache index flush failed');
    }
  }

  /** 访问时间更新节流：2 秒后合并写一次 */
  private markDirty(): void {
    this.dirty = true;
    if (this.flushTimer >= 0) {
      return;
    }
    this.flushTimer = setTimeout((): void => {
      this.flushTimer = -1;
      if (this.dirty) {
        this.flushIndex();
      }
    }, 2000);
  }

  /** 进程退出 / 切后台时强制落盘索引 */
  flushNow(): void {
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    if (this.dirty) {
      this.flushIndex();
    }
  }

  private find(id: string, quality: string): CacheEntry | null {
    this.loadIndex();
    for (const e of this.entries) {
      if (e.id === id && e.quality === quality) {
        return e;
      }
    }
    return null;
  }

  // ------------------------------------------------------------ 音频

  /** 命中返回可播放的绝对路径（并刷新访问时间），未命中空串 */
  hitAudio(id: string, quality: string): string {
    if (!AUDIO_CACHE_ENABLED) {
      return '';
    }
    const e: CacheEntry | null = this.find(id, quality);
    if (e === null) {
      return '';
    }
    try {
      if (!fs.accessSync(e.path) || fs.statSync(e.path).size <= 0) {
        return '';
      }
    } catch (err) {
      return '';
    }
    e.lastAccess = Date.now();
    this.markDirty();
    return e.path;
  }

  hasAudio(id: string, quality: string): boolean {
    return this.hitAudio(id, quality).length > 0;
  }

  /** 整曲缓存是否可用（调用方据此决定预取走「整曲下载」还是「只取链」） */
  isAudioCacheEnabled(): boolean {
    return AUDIO_CACHE_ENABLED;
  }

  /** 封面缓存上限设置变更后立即生效（设置页改完调用，超出的当场淘汰） */
  applyCoverLimit(): void {
    CoverCache.getInstance().reloadLimit();
  }

  /** 记录封面 / 歌词关联（供删音频时同步清理） */
  bindCover(id: string, quality: string, coverUrl: string): void {
    const e: CacheEntry | null = this.find(id, quality);
    if (e === null || coverUrl.length === 0) {
      return;
    }
    if (e.coverUrl !== coverUrl) {
      e.coverUrl = coverUrl;
      this.markDirty();
    }
  }

  bindLyric(id: string, lyricPath: string): void {
    this.loadIndex();
    let touched: boolean = false;
    for (const e of this.entries) {
      if (e.id === id && e.lyricPath !== lyricPath) {
        e.lyricPath = lyricPath;
        touched = true;
      }
    }
    if (touched) {
      this.markDirty();
    }
  }

  /**
   * 下载整曲并落盘。
   * 这是「收藏歌单智能缓存」的唯一入口：替代流播请求，请求次数不增加。
   * 返回落盘路径（失败返回空串，调用方回落到在线流播）。
   */
  async downloadAudio(id: string, quality: string, url: string, coverUrl: string,
    ext: string): Promise<string> {
    if (!AUDIO_CACHE_ENABLED) {
      return '';
    }
    if (id.length === 0 || url.length === 0) {
      return '';
    }
    const hit: string = this.hitAudio(id, quality);
    if (hit.length > 0) {
      return hit;
    }
    // 同一首已经在下载：不重复发请求
    if (this.inflight.has(id)) {
      return '';
    }
    const dir: string = this.ensure(this.audioDir());
    if (dir.length === 0) {
      return '';
    }
    const dest: string = dir + '/' + cacheSafeName(id) + '_' + cacheSafeName(quality) + '.' + ext;
    const tmp: string = dest + '.part';
    const req: http.HttpRequest = http.createHttp();
    this.inflight.set(id, req);
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) SlowTime/1.0' },
        connectTimeout: 15000,
        readTimeout: 60000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
      });
      const code: number = Number(resp.responseCode);
      if (code < 200 || code >= 300) {
        return '';
      }
      const ab: ArrayBuffer = resp.result as ArrayBuffer;
      if (ab === undefined || ab === null || ab.byteLength === 0) {
        return '';
      }
      // 太小多半是错误页（HTML / JSON），落盘只会得到一个播不了的假缓存
      if (ab.byteLength < 64 * 1024) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'cache skip tiny payload %{public}d', ab.byteLength);
        return '';
      }
      if (ab.byteLength > MAX_SINGLE_BYTES) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'cache skip oversized %{public}d', ab.byteLength);
        return '';
      }
      const f: fs.File = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        // writeSync 不接受 Uint8Array，必须给原始 ArrayBuffer
        fs.writeSync(f.fd, ab);
      } finally {
        fs.closeSync(f);
      }
      // 原子替换：下载中断只会留下 .part，不会污染正式缓存
      fs.renameSync(tmp, dest);
      const now: number = Date.now();
      this.loadIndex();
      const old: CacheEntry | null = this.find(id, quality);
      if (old !== null) {
        old.path = dest;
        old.size = ab.byteLength;
        old.lastAccess = now;
        old.created = now;
        old.coverUrl = coverUrl;
      } else {
        this.entries.push({
          id: id,
          quality: quality,
          path: dest,
          size: ab.byteLength,
          created: now,
          lastAccess: now,
          coverUrl: coverUrl,
          lyricPath: '',
        });
      }
      this.flushIndex();
      this.enforce();
      return dest;
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache download failed: %{public}s', (e as Error).message);
      try {
        if (fs.accessSync(tmp)) {
          fs.unlinkSync(tmp);
        }
      } catch (e2) {
        // ignore
      }
      return '';
    } finally {
      this.inflight.delete(id);
      try {
        req.destroy();
      } catch (e3) {
        // ignore
      }
    }
  }

  /** 取消某首在途下载（播放改用流播时调用，避免同一首歌被请求两次） */
  cancelAudio(id: string): void {
    const req: http.HttpRequest | undefined = this.inflight.get(id);
    if (req === undefined) {
      return;
    }
    this.inflight.delete(id);
    try {
      req.destroy();
    } catch (e) {
      // ignore
    }
  }

  /** 收藏歌单上下文开关：只有在这个上下文里才做音频智能缓存 */
  setSmartCacheOn(on: boolean): void {
    this.smartCacheOn = on;
  }

  isSmartCacheOn(): boolean {
    return this.smartCacheOn;
  }

  /** 从 URL 猜音频扩展名（缓存文件名用；播放器靠内容嗅探，不依赖后缀） */
  audioExtOf(url: string): string {
    const clean: string = url.split('?')[0].toLowerCase();
    const known: string[] = ['mp3', 'flac', 'm4a', 'aac', 'ogg', 'wav', 'ape'];
    for (const k of known) {
      if (clean.endsWith('.' + k)) {
        return k;
      }
    }
    return 'mp3';
  }

  // ------------------------------------------------------------ 歌词

  private lyricPathOf(id: string): string {
    return this.lyricDir() + '/' + cacheSafeName(id) + '.json';
  }

  /** 读磁盘歌词（命中即返回，重启后不再重新匹配） */
  readLyric(id: string): LyricInfo | null {
    if (id.length === 0) {
      return null;
    }
    const p: string = this.lyricPathOf(id);
    try {
      if (!fs.accessSync(p)) {
        return null;
      }
      const text: string = fs.readTextSync(p);
      const obj: Object = JSON.parse(text) as Object;
      if (obj === null || obj === undefined) {
        return null;
      }
      const r: Record<string, Object> = obj as Record<string, Object>;
      const lyric: string = this.strOf(r, 'lyric');
      if (lyric.length === 0) {
        return null;
      }
      const tl: string = this.strOf(r, 'tlyric');
      const rl: string = this.strOf(r, 'rlyric');
      const lx: string = this.strOf(r, 'lxlyric');
      const out: LyricInfo = {
        lyric: lyric,
        tlyric: tl.length > 0 ? tl : null,
        rlyric: rl.length > 0 ? rl : null,
        lxlyric: lx.length > 0 ? lx : null,
      };
      return out;
    } catch (e) {
      return null;
    }
  }

  /**
   * 删掉某首歌的磁盘歌词缓存（手动「自动匹配」时用）：
   * 不删的话重新匹配会先命中旧缓存，等于没换。
   */
  deleteLyric(id: string): void {
    if (id.length === 0) {
      return;
    }
    const p: string = this.lyricPathOf(id);
    try {
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
      }
    } catch (e) {
      // 删不掉就留着，不影响后续
    }
  }

  /** 写磁盘歌词（fire-and-forget，失败静默） */
  writeLyric(id: string, info: LyricInfo): void {    if (id.length === 0 || info.lyric.length === 0) {
      return;
    }
    const dir: string = this.ensure(this.lyricDir());
    if (dir.length === 0) {
      return;
    }
    const p: string = this.lyricPathOf(id);
    const payload: Record<string, string> = {
      'lyric': info.lyric,
      'tlyric': info.tlyric ?? '',
      'rlyric': info.rlyric ?? '',
      'lxlyric': info.lxlyric ?? '',
    };
    try {
      const f: fs.File = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, JSON.stringify(payload));
      } finally {
        fs.closeSync(f);
      }
      this.bindLyric(id, p);
      this.lyricWrites++;
      // 歌词缓存也要有上限：每写 50 条检查一次，超过 2000 条时按最旧清到 1600 条
      if (this.lyricWrites % 50 === 0) {
        this.trimLyric();
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'lyric cache write failed');
    }
  }

  /** 歌词缓存超量回收：按 mtime 从旧到新删到 LYRIC_KEEP 条 */
  private trimLyric(): void {
    try {
      const files: string[] = this.dirFiles(this.lyricDir());
      if (files.length <= LYRIC_MAX_FILES) {
        return;
      }
      const items: LyricFile[] = [];
      for (const p of files) {
        try {
          items.push({ path: p, mtime: fs.statSync(p).mtime });
        } catch (e) {
          // 读不到就跳过
        }
      }
      items.sort((a: LyricFile, b: LyricFile): number => a.mtime - b.mtime);
      const drop: number = items.length - LYRIC_KEEP_FILES;
      for (let i: number = 0; i < drop; i++) {
        try {
          fs.unlinkSync(items[i].path);
        } catch (e) {
          // 忽略
        }
      }
    } catch (e) {
      // 忽略
    }
  }

  lyricPath(id: string): string {
    return this.lyricPathOf(id);
  }

  // ------------------------------------------------------------ 统计

  private dirBytes(dir: string): number {
    let total: number = 0;
    try {
      if (dir.length === 0 || !fs.accessSync(dir)) {
        return 0;
      }
      for (const n of fs.listFileSync(dir)) {
        try {
          total += fs.statSync(dir + '/' + n).size;
        } catch (e) {
          // 跳过无法 stat 的条目
        }
      }
    } catch (e) {
      // ignore
    }
    return total;
  }

  private dirFiles(dir: string): string[] {
    const out: string[] = [];
    try {
      if (dir.length === 0 || !fs.accessSync(dir)) {
        return out;
      }
      for (const n of fs.listFileSync(dir)) {
        out.push(dir + '/' + n);
      }
    } catch (e) {
      // ignore
    }
    return out;
  }

  stats(): CacheStats {
    this.loadIndex();
    let audioBytes: number = 0;
    for (const e of this.entries) {
      audioBytes += e.size;
    }
    const lyricFiles: string[] = this.dirFiles(this.lyricDir());
    let lyricBytes: number = 0;
    for (const p of lyricFiles) {
      try {
        lyricBytes += fs.statSync(p).size;
      } catch (e) {
        // ignore
      }
    }
    const cover: CacheStatsBrief = CoverCache.getInstance().stats();
    return {
      audioBytes: audioBytes,
      coverBytes: cover.coverBytes,
      lyricBytes: lyricBytes,
      totalBytes: audioBytes + cover.coverBytes + lyricBytes,
      audioCount: this.entries.length,
      coverCount: cover.coverCount,
      lyricCount: lyricFiles.length,
    };
  }

  /** 设置里的上限（字节） */
  limitBytes(): number {
    const mbStr: string = SettingStore.getInstance().getString('cache.limitMb', '2000');
    let mb: number = parseInt(mbStr);
    if (isNaN(mb) || mb <= 0) {
      mb = 2000;
    }
    if (mb > CACHE_LIMIT_MAX_MB) {
      mb = CACHE_LIMIT_MAX_MB;
    }
    return mb * MB;
  }

  limitMb(): number {
    return Math.round(this.limitBytes() / MB);
  }

  // ------------------------------------------------------------ 清理

  /** 删除一个音频条目及其关联封面 / 歌词 */
  private dropEntry(e: CacheEntry): number {
    let freed: number = 0;
    try {
      if (fs.accessSync(e.path)) {
        freed += fs.statSync(e.path).size;
        fs.unlinkSync(e.path);
      }
    } catch (err) {
      // ignore
    }
    // 关联封面：只有不再被其它缓存条目引用时才删，避免误删还在用的图
    if (e.coverUrl.length > 0 && !this.coverStillUsed(e.coverUrl, e.id)) {
      CoverCache.getInstance().removeByUrl(e.coverUrl);
    }
    if (e.lyricPath.length > 0) {
      try {
        if (fs.accessSync(e.lyricPath)) {
          freed += fs.statSync(e.lyricPath).size;
          fs.unlinkSync(e.lyricPath);
        }
      } catch (err) {
        // ignore
      }
    }
    return freed;
  }

  private coverStillUsed(url: string, exceptId: string): boolean {
    for (const e of this.entries) {
      if (e.id !== exceptId && e.coverUrl === url) {
        return true;
      }
    }
    return false;
  }

  /**
   * 释放指定字节数：先动音频（按 lastAccess 旧→新），
   * 不够再动封面（落盘时间旧→新），最后动歌词（落盘时间旧→新）。
   * 返回实际释放字节。
   */
  private purge(targetBytes: number): number {
    this.loadIndex();
    let freed: number = 0;
    if (targetBytes <= 0) {
      return 0;
    }
    // 1) 音频：按最近访问时间升序（最久没听的最先走）
    const audios: CacheEntry[] = this.entries.slice()
      .sort((a: CacheEntry, b: CacheEntry): number => a.lastAccess - b.lastAccess);
    const kept: CacheEntry[] = [];
    for (const e of audios) {
      if (freed >= targetBytes) {
        kept.push(e);
        continue;
      }
      freed += this.dropEntry(e);
    }
    if (freed >= targetBytes) {
      this.entries = kept;
      this.flushIndex();
      return freed;
    }
    this.entries = kept;
    this.flushIndex();
    // 2) 封面：按落盘时间升序
    freed += CoverCache.getInstance().purgeOldest(targetBytes - freed);
    if (freed >= targetBytes) {
      return freed;
    }
    // 3) 歌词：按落盘时间升序
    const lyrics: string[] = this.dirFiles(this.lyricDir());
    const withTime: CacheEntry[] = [];
    for (const p of lyrics) {
      try {
        const st = fs.statSync(p);
        withTime.push({
          id: p, quality: '', path: p, size: st.size,
          created: st.mtime, lastAccess: st.mtime, coverUrl: '', lyricPath: '',
        });
      } catch (e) {
        // ignore
      }
    }
    withTime.sort((a: CacheEntry, b: CacheEntry): number => a.created - b.created);
    for (const it of withTime) {
      if (freed >= targetBytes) {
        break;
      }
      try {
        fs.unlinkSync(it.path);
        freed += it.size;
      } catch (e) {
        // ignore
      }
    }
    return freed;
  }

  /**
   * 清理「现有缓存的 49%」。
   * 注意目标按清理前的总体积算，避免一边删一边缩分母导致越删越多。
   */
  cleanByRatio(): number {
    const st: CacheStats = this.stats();
    const target: number = Math.floor(st.totalBytes * PURGE_RATIO);
    const before: number = st.totalBytes;
    const freed: number = this.purge(target);
    this.lastPurgeBytes = freed;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'cache purge %{public}d/%{public}d of %{public}d',
      freed, target, before);
    return freed;
  }

  /** 清空全部（音频 + 歌词 + 封面） */
  clearAll(): number {
    this.loadIndex();
    let freed: number = 0;
    for (const e of this.entries) {
      freed += this.dropEntry(e);
    }
    this.entries = [];
    this.flushIndex();
    for (const p of this.dirFiles(this.lyricDir())) {
      try {
        freed += fs.statSync(p).size;
        fs.unlinkSync(p);
      } catch (e) {
        // ignore
      }
    }
    freed += CoverCache.getInstance().clearDisk();
    return freed;
  }

  /**
   * 水位检查：占用 ≥ 上限 99% 时触发。
   * - 还能上调且在前台 → 发事件询问用户（+500MiB）
   * - 已是上限 / 后台 / 关闭了自动清理 → 静默清理 49%
   */
  enforce(): void {
    // 整曲缓存暂时搁置：没有音频缓存就没有需要按 99% 水位清理 / 询问上调的对象
    if (!AUDIO_CACHE_ENABLED) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastEnforceAt < 60000) {
      return;
    }
    this.lastEnforceAt = now;
    if (!SettingStore.getInstance().getBoolean('cache.autoClean', true)) {
      return;
    }
    const limit: number = this.limitBytes();
    const total: number = this.stats().totalBytes;
    if (total < limit * TRIGGER_RATIO) {
      return;
    }
    const mb: number = this.limitMb();
    const canRaise: boolean = mb < CACHE_LIMIT_MAX_MB;
    if (!canRaise) {
      this.cleanByRatio();
      return;
    }
    // 后台不打扰用户：直接清理，避免播放中弹窗
    if (!AppState.getInstance().appInBackground && !this.asking) {
      this.asking = true;
      CacheStore.askResolver = (raise: boolean): void => {
        this.asking = false;
        CacheStore.askResolver = null;
        if (raise) {
          const next: number = Math.min(CACHE_LIMIT_MAX_MB, mb + CACHE_LIMIT_STEP_MB);
          SettingStore.getInstance().set('cache.limitMb', next.toString());
          return;
        }
        this.cleanByRatio();
      };
      CacheAskHub.emit(mb);
      return;
    }
    this.cleanByRatio();
  }

  /** UI 回调：用户选择「上调」或「保持并清理」 */
  static askResolver: ((raise: boolean) => void) | null = null;

  static resolveAsk(raise: boolean): void {
    const r = CacheStore.askResolver;
    if (r !== null) {
      r(raise);
    }
  }
}

/**
 * 「是否上调缓存上限」询问入口。
 * 用独立的极简发布订阅，避免 CacheStore 反向依赖页面事件总线。
 */
export type CacheAskHandler = (limitMb: number) => void;

export class CacheAskHub {
  private static handler: CacheAskHandler | null = null;

  static bind(h: CacheAskHandler | null): void {
    CacheAskHub.handler = h;
  }

  static emit(limitMb: number): void {
    if (CacheAskHub.handler !== null) {
      CacheAskHub.handler(limitMb);
    }
  }
}
