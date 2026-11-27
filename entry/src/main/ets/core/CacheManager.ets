/**
 * ============================================================================
 * 注意：本模块当前未接入（已全仓确认零引用）。
 * 产品决策：在线播放直连网络流、不落盘（缓存设置已整体撤销），
 * 因此 CacheManager 及其落盘逻辑不再使用。保留本文件仅作备查，勿直接使用，
 * 也不要据此重新实现在线播放缓存。下载请用 DownloadManager，封面缓存用 ImageCache。
 * ============================================================================
 *
 * 缓存管理 —— 阶段二「缓存设置」落地核心。
 *
 * 现状：本项目在线播放是播放器直连网络流，全程不落盘；原 `cache.maxSize` /
 * `cache.autoClean` 两个设置项纯摆设。本类把「在线播放缓存」真正落地：
 *   - 在线曲目播放时后台落盘到应用沙箱 filesDir/cache/（不影响主播放，失败降级）；
 *   - 下次同曲优先读本地缓存（file:// 秒开，省流量）；
 *   - 受 `cache.maxSize`(GB) 阈值约束，`cache.autoClean` 开启时超阈值自动清理最旧；
 *   - 设置页可查看当前占用并「立即清理」。
 * 与 downloads/ 区分：downloads 是用户主动下载的永久文件，cache 是自动临时缓存，
 * 自动清理只动 cache，绝不误删用户下载。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingStore } from '../store/SettingStore';
import { getAppContext } from '../common/AppContext';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

const DIR_NAME: string = 'cache';
const GB: number = 1024 * 1024 * 1024;
const MB: number = 1024 * 1024;

/** 文件元信息（用于排序与淘汰） */
export interface CacheFile {
  path: string;
  mtime: number;
  size: number;
}

/** 把任意 id 规整为文件名安全字符（避免 '/'、中文等破坏路径） */
export function safeName(s: string): string {
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
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

/** 字节数格式化为人类可读文本（GB / MB / KB） */
export function formatSize(bytes: number): string {
  if (bytes >= GB) {
    return (bytes / GB).toFixed(2) + ' GB';
  }
  if (bytes >= MB) {
    return (bytes / MB).toFixed(1) + ' MB';
  }
  if (bytes >= 1024) {
    return (bytes / 1024).toFixed(0) + ' KB';
  }
  return bytes.toString() + ' B';
}

/**
 * 选择需要淘汰的文件：按 mtime 升序（最旧优先），
 * 从总字节里扣减直到 ≤ limit，返回应删除的路径列表。
 * 纯函数，便于单测，不触碰文件系统。
 */
export function selectForEviction(files: CacheFile[], limit: number): string[] {
  const ordered: CacheFile[] = files.slice().sort((a: CacheFile, b: CacheFile): number => a.mtime - b.mtime);
  let cur: number = 0;
  for (const f of ordered) {
    cur += f.size;
  }
  const toDelete: string[] = [];
  if (cur <= limit) {
    return toDelete;
  }
  for (const f of ordered) {
    if (cur <= limit) {
      break;
    }
    toDelete.push(f.path);
    cur -= f.size;
  }
  return toDelete;
}

export class CacheManager {
  private static sInstance: CacheManager | null = null;

  static getInstance(): CacheManager {
    if (CacheManager.sInstance === null) {
      CacheManager.sInstance = new CacheManager();
    }
    return CacheManager.sInstance;
  }

  /** 缓存目录绝对路径（context 未就绪时返回空串） */
  private dir(): string {
    const ctx = getAppContext();
    if (ctx === null) {
      return '';
    }
    return ctx.filesDir + '/' + DIR_NAME;
  }

  private ensureDir(): void {
    const d: string = this.dir();
    if (d.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(d)) {
        fs.mkdirSync(d);
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache ensureDir failed');
    }
  }

  /** 列出缓存文件（按 mtime 升序：最旧在前） */
  private list(): CacheFile[] {
    const d: string = this.dir();
    const out: CacheFile[] = [];
    if (d.length === 0) {
      return out;
    }
    try {
      if (!fs.accessSync(d)) {
        return out;
      }
      const names: string[] = fs.listFileSync(d);
      for (const n of names) {
        const p: string = d + '/' + n;
        try {
          const st = fs.statSync(p);
          out.push({ path: p, mtime: st.mtime, size: st.size });
        } catch (e) {
          // 跳过无法 stat 的条目
        }
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache list failed');
    }
    out.sort((a: CacheFile, b: CacheFile): number => a.mtime - b.mtime);
    return out;
  }

  /** 当前缓存总字节 */
  sizeBytes(): number {
    let total: number = 0;
    for (const f of this.list()) {
      total += f.size;
    }
    return total;
  }

  /** 当前缓存可读文本 */
  sizeText(): string {
    return formatSize(this.sizeBytes());
  }

  /**
   * 超限自动清理：autoClean 开启且当前 > maxSize(GB) 时，删最旧直到达标。
   * 失败被吞掉，不影响主流程。
   */
  enforceLimit(): void {
    const store: SettingStore = SettingStore.getInstance();
    const auto: boolean = store.getBoolean('cache.autoClean', true);
    const maxGb: number = store.getNumber('cache.maxSize', 2);
    if (!auto) {
      return;
    }
    const limit: number = Math.max(1, maxGb) * GB;
    const files: CacheFile[] = this.list();
    let cur: number = 0;
    for (const f of files) {
      cur += f.size;
    }
    if (cur <= limit) {
      return;
    }
    for (const p of selectForEviction(files, limit)) {
      try {
        fs.unlinkSync(p);
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache evict failed');
      }
    }
  }

  /** 立即清空全部缓存，返回释放的字节数 */
  async clearAll(): Promise<number> {
    const before: number = this.sizeBytes();
    for (const f of this.list()) {
      try {
        fs.unlinkSync(f.path);
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache clear one failed');
      }
    }
    return before;
  }

  /**
   * 单曲缓存上限（字节）。对应 `player.cacheSize`（单位 MB，'2048' 视为不限制）。
   * 返回 0 表示不限制。
   */
  maxSingleBytes(): number {
    const mbStr: string = SettingStore.getInstance().getString('player.cacheSize', '2048');
    const mb: number = parseInt(mbStr);
    if (isNaN(mb) || mb <= 0 || mb >= 2048) {
      return 0;
    }
    return mb * 1024 * 1024;
  }

  /** 缓存文件名：c_<id>_<quality>.cache */
  cacheFileName(id: string, quality: string): string {    return 'c_' + safeName(id) + '_' + safeName(quality) + '.cache';
  }

  cacheFilePath(id: string, quality: string): string {
    return this.dir() + '/' + this.cacheFileName(id, quality);
  }

  /** 是否已缓存（文件存在且 > 0 字节） */
  hasCache(id: string, quality: string): boolean {
    const p: string = this.cacheFilePath(id, quality);
    try {
      if (!fs.accessSync(p)) {
        return false;
      }
      return fs.statSync(p).size > 0;
    } catch (e) {
      return false;
    }
  }

  /** 读取缓存文件的 file:// 路径（供播放优先使用） */
  getCacheFileUrl(id: string, quality: string): string {
    return 'file://' + this.cacheFilePath(id, quality);
  }

  /** 异步落盘一首在线曲到缓存（fire-and-forget，失败不影响播放） */
  cacheOnline(id: string, quality: string, url: string): void {
    if (id.length === 0 || url.length === 0) {
      return;
    }
    if (this.hasCache(id, quality)) {
      return;
    }
    this.ensureDir();
    const dest: string = this.cacheFilePath(id, quality);
    const req: http.HttpRequest = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': 'Mozilla/5.0 (compatible; SlowTimeCache/1.0)' },
      // 必须显式声明期望二进制，否则 resp.result 默认是字符串，下面当 ArrayBuffer 写入会损坏文件
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 20000,
      readTimeout: 20000,
    };
    req.request(url, options).then((resp: http.HttpResponse): void => {
      const code: number = Number(resp.responseCode);
      if (code >= 200 && code < 300) {
        try {
          const ab: ArrayBuffer = resp.result as ArrayBuffer;
          const data: Uint8Array = new Uint8Array(ab);
          const limit: number = this.maxSingleBytes();
          if (limit > 0 && data.byteLength > limit) {
            // 超过「单曲缓存上限」的大文件不缓存，省流量也省空间（下次直接播网络流）
            hilog.info(LOG_DOMAIN, LOG_TAG, 'cache skip: %{public}d > %{public}d', data.byteLength, limit);
            req.destroy();
            return;
          }
          let f: fs.File | null = null;
          try {
            f = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            // 传原始 ArrayBuffer；SDK 的 writeSync 不接受 Uint8Array
            fs.writeSync(f.fd, ab);
            this.enforceLimit();
          } catch (e) {
            hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache write failed');
          } finally {
            if (f !== null) {
              fs.closeSync(f);
            }
          }
        } catch (e) {
          // result 非二进制，忽略
        }
      }
      req.destroy();
    }).catch((_e: Error): void => {
      try {
        req.destroy();
      } catch (e2) {
        // ignore
      }
    });
  }
}
