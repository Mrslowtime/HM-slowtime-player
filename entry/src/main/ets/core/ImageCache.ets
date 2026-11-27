/**
 * 封面图缓存 —— 歌单网格 / 我的歌单 / 详情页头部共用。
 *
 * 为什么必须做：
 * - 咪咕歌单广场的单张封面就是 **1.8MB 的原图 PNG**，而且服务端不支持任何缩放参数
 *   （?param / x-oss-process / imageMogr2 全部被忽略原样返回，换 .webp 直接 404），
 *   一屏 12 张就是 22MB —— 这是「咪咕歌单下拉卡、封面总也出不来」的根因，不是接口慢。
 * - 酷我 40KB、酷狗 19KB 虽然不大，但每次滚回去都重新走网络 + 解码，也会掉帧。
 *
 * 做法：网络图下载一次 → 超过 64KB 的统一缩到 300px 压成 JPEG（约 15KB）→ 落盘，
 * 之后同 URL 直接读本地文件：没有网络、解码快、滚动不掉帧。
 *
 * 其他策略：
 * - 内存 Map<url, 本地路径>：本进程内二次使用同步命中（peek），避免占位闪一下。
 * - 在途去重：同一张图不会并发下载两次。
 * - 并发上限 4：咪咕单张 1.8MB，12 张并发只会互相抢带宽，整体更慢。
 * - 缓存目录用 cacheDir（系统可回收），张数上限默认 2000（设置可选到 4000），按 mtime 淘汰最旧。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getAppContext } from '../common/AppContext';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { DEFAULT_UA } from './net/HttpClient';
import { SettingStore } from '../store/SettingStore';

/** 超过这个体积才做「解码 + 重压缩」，小图直接原样落盘（省 CPU） */
const SHRINK_ABOVE: number = 64 * 1024;
/**
 * 压缩后的最长边（px）。
 * 列表网格单格约 100~275vp，播放页大封面为屏宽 72%（约 260vp，3x 屏 ≈ 780px），
 * 我的歌单卡片约 170vp（3x ≈ 510px）。
 * 统一按 800px 落盘：三类场景都够清晰，单张 60~90KB，2000 张约 180MB。
 */
const TARGET_PX: number = 800;
const JPEG_QUALITY: number = 82;
/** 同时下载数 */
const MAX_CONCURRENT: number = 4;
/** 默认张数上限（设置项 cache.coverLimit 可覆盖，最高 4000） */
const MAX_FILES: number = 2000;
/** 每写这么多张检查一次容量 */
const TRIM_EVERY: number = 60;
/**
 * 取图失败后的冷却时间：这段时间内同一 URL 不再发起请求。
 * 主要防「一张图 404/超时后，每次滚动或重新进页面都再打一次」的请求放大（风控考虑）。
 */
const FAIL_RETRY_MS: number = 10 * 60 * 1000;

/**
 * 封面缓存目录名。v2：压缩尺寸从 300 → 640 → 800 变过几次，
 * 旧目录里的小图不会自动重建（会一直糊），换目录名让新尺寸从零开始，
 * 旧目录在首次建目录时顺手删掉，不占空间。
 */
const COVER_DIR: string = 'cover_cache_v2';
const LEGACY_COVER_DIRS: string[] = ['cover_cache'];
/**
 * 本地歌曲封面单独一个目录，且放在 filesDir（不是 cacheDir）：
 *
 * - 在线封面可以随时按张数 / 容量淘汰，但本地歌的封面是「这首歌唯一的一张图」，
 *   被淘汰后界面就只剩占位图，用户体感是「封面拿到了又被删了」；
 * - 放 filesDir 系统不会当缓存回收，只有用户手动「清理缓存」时才清；
 * - 张数天然等于本地曲库大小，不会无限膨胀。
 */
const LOCAL_COVER_DIR: string = 'local_covers';

/** 待下载任务 */
interface CoverTask {
  url: string;
  done: (path: string) => void;
}

/** 目录扫描项（淘汰用） */
interface CoverFile {
  path: string;
  size: number;
  mtime: number;
}

/** URL → 文件名：djb2 哈希 + 长度，避免长 URL 直接当文件名 */
function hashUrl(u: string): string {
  let h: number = 5381;
  for (let i = 0; i < u.length; i++) {
    h = ((h * 33) ^ u.charCodeAt(i)) >>> 0;
  }
  return h.toString(16) + '_' + u.length.toString(16);
}

export class CoverCache {
  private static sInstance: CoverCache | null = null;

  static getInstance(): CoverCache {
    if (CoverCache.sInstance === null) {
      CoverCache.sInstance = new CoverCache();
    }
    return CoverCache.sInstance;
  }

  /** url → 'file://...' */
  private mem: Map<string, string> = new Map<string, string>();
  private inflight: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  /** url → 失败时间戳（冷却期内直接判失败，不再发请求） */
  private failed: Map<string, number> = new Map<string, number>();
  private tasks: CoverTask[] = [];
  private running: number = 0;
  private dirPath: string = '';
  private dirReady: boolean = false;
  /** 本地歌封面目录（独立于在线封面，不参与淘汰） */
  private localDirPath: string = '';
  private localDirReady: boolean = false;
  private writeCount: number = 0;
  private trimming: boolean = false;
  /** 张数上限：默认 MAX_FILES，可被设置项 cache.coverLimit 覆盖 */
  private maxFiles: number = MAX_FILES;

  /** 字节上限跟随张数档位：按单张 128 KiB 估算，封顶 512 MiB */
  private maxBytes(): number {
    return Math.min(this.maxFiles * 128 * 1024, 512 * 1024 * 1024);
  }

  /**
   * 重新读取「封面缓存上限」设置并立即按新上限裁剪。
   * 设置页改完调这里，不用等下一次写缓存。
   */
  reloadLimit(): void {
    let n: number = MAX_FILES;
    try {
      const raw: string = SettingStore.getInstance().getString('cache.coverLimit', '2000');
      const v: number = parseInt(raw, 10);
      if (!isNaN(v) && v >= 100) {
        n = v;
      }
    } catch (e) {
      n = MAX_FILES;
    }
    this.maxFiles = n;
    this.trim();
  }

  /**
   * 把本地图片字节直接存进封面缓存（本地歌的内嵌封面用）。
   *
   * 为什么不写到歌曲同目录：用户要求封面统一交给缓存系统管理 ——
   * 这里存进的就是「封面缓存目录」，和在线封面共用同一套张数 / 容量上限与清理逻辑，
   * 清缓存时一并清掉，也不会污染用户的音乐文件夹。
   *
   * @param key 稳定标识（用歌曲路径），同一首歌重复调用覆盖同一文件
   * @returns 'file://<缓存路径>'；失败返回空串
   */
  putBytes(key: string, buf: ArrayBuffer): string {
    const dir: string = this.ensureLocalDir();
    if (dir.length === 0 || buf.byteLength === 0 || key.length === 0) {
      return '';
    }
    const url: string = 'local:' + key;
    const p: string = dir + '/' + hashUrl(url) + '.jpg';
    if (!this.writeFile(p, buf)) {
      return '';
    }
    const uri: string = 'file://' + p;
    this.mem.set(url, uri);
    this.afterWrite();
    return uri;
  }

  /**
   * 下载在线封面并转存到**本地封面目录**（本地歌专用）。
   *
   * 为什么不直接用 get()：get 落在「在线封面目录」，那里按张数/容量淘汰，
   * 本地歌唯一的那张图会被别的歌挤掉（用户反复遇到的「封面听一会儿就没了」）。
   * 这里先把图下到在线缓存（复用压缩与并发控制），再复制进 local_covers。
   *
   * @returns 本地封面缓存路径（不含 file://）；失败空串
   */
  async putUrl(key: string, url: string): Promise<string> {
    if (key.length === 0 || url.length === 0) {
      return '';
    }
    const hit: string = this.peekLocal(key);
    if (hit.length > 0) {
      return hit.indexOf('file://') === 0 ? hit.substring('file://'.length) : hit;
    }
    const src: string = await this.get(url);
    if (src.length === 0) {
      return '';
    }
    const p: string = src.indexOf('file://') === 0 ? src.substring('file://'.length) : src;
    let fd: fs.File | null = null;
    try {
      fd = fs.openSync(p, fs.OpenMode.READ_ONLY);
      const st = fs.statSync(p);
      if (st.size < 128) {
        return '';
      }
      const buf: ArrayBuffer = new ArrayBuffer(st.size);
      fs.readSync(fd.fd, buf, { offset: 0, length: st.size });
      const uri: string = this.putBytes(key, buf);
      return uri.indexOf('file://') === 0 ? uri.substring('file://'.length) : uri;
    } catch (e) {
      return '';
    } finally {
      if (fd !== null) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /**
   * 本地封面是否已在缓存里（同步查，命中直接返回 'file://...'）。
   * 内存没命中还要查一次磁盘 —— 否则重启应用后每首都当成「没有封面」重新解码。
   */
  peekLocal(key: string): string {
    if (key.length === 0) {
      return '';
    }
    const url: string = 'local:' + key;
    const hit: string = this.peek(url);
    if (hit.length > 0) {
      return hit;
    }
    const dir: string = this.ensureLocalDir();
    if (dir.length === 0) {
      return '';
    }
    const name: string = hashUrl(url) + '.jpg';
    const p: string = dir + '/' + name;
    try {
      if (fs.accessSync(p) && fs.statSync(p).size > 1024) {
        const uri: string = 'file://' + p;
        this.mem.set(url, uri);
        return uri;
      }
    } catch (e) {
      // 不存在：继续看旧位置
    }
    // 旧版本把本地封面写进了「在线封面目录」，那里会被容量淘汰。
    // 命中就搬进独立目录（迁移是 O(1) 次 rename，不会有网络请求）。
    const legacyDir: string = this.dirPath.length > 0 ? this.dirPath : this.ensureDir();
    if (legacyDir.length === 0) {
      return '';
    }
    const old: string = legacyDir + '/' + name;
    try {
      if (!fs.accessSync(old) || fs.statSync(old).size <= 1024) {
        return '';
      }
      try {
        fs.renameSync(old, p);
      } catch (e) {
        fs.copyFileSync(old, p);
        try {
          fs.unlinkSync(old);
        } catch (e2) {
          // 忽略
        }
      }
      const uri: string = 'file://' + p;
      this.mem.set(url, uri);
      return uri;
    } catch (e) {
      return '';
    }
  }

  /** 删掉某个本地歌的封面（删歌时调用，避免同名路径重新下载后错用旧封面） */
  dropLocal(key: string): void {
    if (key.length === 0) {
      return;
    }
    const url: string = 'local:' + key;
    const dir: string = this.ensureLocalDir();
    this.mem.delete(url);
    if (dir.length === 0) {
      return;
    }
    try {
      const p: string = dir + '/' + hashUrl(url) + '.jpg';
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
      }
    } catch (e) {
      // ignore
    }
  }

  /** 本地封面目录：filesDir 下独立子目录，首次使用时创建 */
  private ensureLocalDir(): string {
    if (this.localDirReady) {
      return this.localDirPath;
    }
    const ctx = getAppContext();
    if (ctx === null) {
      return '';
    }
    const d: string = ctx.filesDir + '/' + LOCAL_COVER_DIR;
    try {
      if (!fs.accessSync(d)) {
        fs.mkdirSync(d);
      }
      this.localDirPath = d;
      this.localDirReady = true;
      return d;
    } catch (e) {
      return '';
    }
  }

  /** 本地封面目录占用（统计用，不计入在线封面的淘汰额度） */
  private localStats(): CacheStatsBrief {
    const dir: string = this.ensureLocalDir();
    if (dir.length === 0) {
      return { coverBytes: 0, coverCount: 0 };
    }
    let bytes: number = 0;
    let count: number = 0;
    try {
      for (const n of fs.listFileSync(dir)) {
        try {
          bytes += fs.statSync(dir + '/' + n).size;
          count++;
        } catch (e) {
          // ignore
        }
      }
    } catch (e) {
      // ignore
    }
    return { coverBytes: bytes, coverCount: count };
  }

  /** 同步命中（只查内存）：已加载过的图立刻出图，不走占位 */  peek(url: string): string {
    if (url.length === 0) {
      return '';
    }
    const hit: string | undefined = this.mem.get(url);
    if (hit === undefined) {
      return '';
    }
    // 系统清理缓存目录 / 容量淘汰后内存里可能还留着失效路径，
    // 这里顺手校验一次（accessSync 很便宜），避免显示空白图再也不重下。
    try {
      if (fs.accessSync(hit.substring('file://'.length))) {
        return hit;
      }
    } catch (e) {
      // 落到下面：当作未命中
    }
    this.mem.delete(url);
    return '';
  }

  /** 取本地可显示的地址；没有就下载（返回 Promise，失败给空串） */
  get(url: string): Promise<string> {
    if (url.length === 0) {
      return Promise.resolve('');
    }
    // 复用 peek() 的校验：命中后先 accessSync 确认文件还在（trim/系统清理可能已淘汰），
    // 失效则删掉 mem 里的旧 file:// 路径并继续走下载，避免封面永久空白。
    const hit: string = this.peek(url);
    if (hit.length > 0) {
      return Promise.resolve(hit);
    }
    const pending: Promise<string> | undefined = this.inflight.get(url);
    if (pending !== undefined) {
      return pending;
    }
    const at: number | undefined = this.failed.get(url);
    if (at !== undefined) {
      if (Date.now() - at < FAIL_RETRY_MS) {
        // 冷却期内：直接给空串，调用方可退回小图地址，避免同一坏链反复打网络
        return Promise.resolve('');
      }
      this.failed.delete(url);
    }
    // 磁盘上有（上次启动缓存的）→ 立即命中，不排队
    const cached: string = this.cachedPath(url);
    if (cached.length > 0) {
      const uri: string = 'file://' + cached;
      this.mem.set(url, uri);
      return Promise.resolve(uri);
    }
    const p: Promise<string> = new Promise<string>((resolve: (v: string) => void): void => {
      this.tasks.push({ url, done: resolve });
      this.pump();
    });
    this.inflight.set(url, p);
    return p;
  }

  /** 低优先级预取（滚动时提前把下一批封面备好） */
  prefetch(urls: string[]): void {
    for (const u of urls) {
      if (u.length === 0 || this.mem.has(u) || this.inflight.has(u)) {
        continue;
      }
      this.get(u).then((): void => {
        // 预取结果不用处理，缓存命中即可
      }).catch((): void => {
        // 预取失败静默忽略，真正上屏时还会再试
      });
    }
  }

  /** 释放某个 url 的记录（图片失效重试时用） */
  forget(url: string): void {
    this.mem.delete(url);
    this.failed.delete(url);
  }

  // ---------------------------------------------------------------- 内部

  private pump(): void {
    while (this.running < MAX_CONCURRENT && this.tasks.length > 0) {
      const t: CoverTask | undefined = this.tasks.shift();
      if (t === undefined) {
        return;
      }
      this.running++;
      this.runTask(t);
    }
  }

  private runTask(t: CoverTask): void {
    this.fetch(t.url).then((p: string): void => {
      if (p.length > 0) {
        const uri: string = 'file://' + p;
        this.mem.set(t.url, uri);
        this.failed.delete(t.url);
        t.done(uri);
      } else {
        this.failed.set(t.url, Date.now());
        t.done('');
      }
      this.finish(t.url);
    }).catch((): void => {
      this.failed.set(t.url, Date.now());
      t.done('');
      this.finish(t.url);
    });
  }

  private finish(url: string): void {
    this.inflight.delete(url);
    this.running--;
    this.pump();
  }

  private async fetch(url: string): Promise<string> {
    const dir: string = this.ensureDir();
    if (dir.length === 0) {
      return '';
    }
    const file: string = dir + '/' + hashUrl(url) + '.jpg';
    let req: http.HttpRequest | null = null;
    try {
      req = http.createHttp();
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': DEFAULT_UA,
          'Accept': 'image/*,*/*;q=0.8',
        },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 20000,
        usingCache: true,
      });
      const code: number = Number(resp.responseCode);
      if (code < 200 || code >= 300 || resp.result === null) {
        return '';
      }
      const raw: ArrayBuffer = resp.result as ArrayBuffer;
      if (raw.byteLength < 128) {
        return '';
      }
      let out: ArrayBuffer = raw;
      if (raw.byteLength > SHRINK_ABOVE) {
        const small: ArrayBuffer | null = await this.shrink(raw);
        if (small !== null) {
          out = small;
        }
      }
      if (!this.writeFile(file, out)) {
        return '';
      }
      this.afterWrite();
      return file;
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cover fetch failed: %{public}s',
        (e as Error).message !== undefined ? (e as Error).message : 'unknown');
      return '';
    } finally {
      if (req !== null) {
        try {
          req.destroy();
        } catch (e2) {
          // 已销毁
        }
      }
    }
  }

  /** 解码到 300px 再压成 JPEG。失败返回 null（外部退回原图落盘） */
  private async shrink(buf: ArrayBuffer): Promise<ArrayBuffer | null> {
    let src: image.ImageSource | null = null;
    let pm: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      src = image.createImageSource(buf);
      const info: image.ImageInfo = await src.getImageInfo();
      const w: number = info.size.width;
      const h: number = info.size.height;
      const longest: number = w > h ? w : h;
      const scale: number = longest > TARGET_PX ? TARGET_PX / longest : 1;
      const dw: number = Math.max(1, Math.round(w * scale));
      const dh: number = Math.max(1, Math.round(h * scale));
      pm = await src.createPixelMap({ desiredSize: { width: dw, height: dh } });
      packer = image.createImagePacker();
      const packed: ArrayBuffer = await packer.packing(pm, {
        format: 'image/jpeg',
        quality: JPEG_QUALITY,
      });
      return packed.byteLength > 128 ? packed : null;
    } catch (e) {
      return null;
    } finally {
      if (packer !== null) {
        try {
          await packer.release();
        } catch (e) {
          // 忽略
        }
      }
      if (pm !== null) {
        try {
          await pm.release();
        } catch (e) {
          // 忽略
        }
      }
      if (src !== null) {
        try {
          await src.release();
        } catch (e) {
          // 忽略
        }
      }
    }
  }

  /** 临时文件 + rename，避免中断留下半截图片被当成有效缓存 */
  private writeFile(path: string, buf: ArrayBuffer): boolean {
    const tmp: string = path + '.tmp';
    let f: fs.File | null = null;
    try {
      f = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      // SDK 签名：writeSync(fd: number, buffer: ArrayBuffer | string)，
      // 传 Uint8Array 会抛 Invalid argument；openSync 返回的是 File，取 .fd
      fs.writeSync(f.fd, buf);
      fs.closeSync(f);
      f = null;
      fs.renameSync(tmp, path);
      return true;
    } catch (e) {
      if (f !== null) {
        try {
          fs.closeSync(f);
        } catch (e2) {
          // 忽略
        }
      }
      try {
        fs.unlinkSync(tmp);
      } catch (e3) {
        // 忽略
      }
      return false;
    }
  }

  private afterWrite(): void {
    this.writeCount++;
    if (this.writeCount % TRIM_EVERY === 0) {
      this.trim();
    }
  }

  /** 超出上限时按 mtime 淘汰最旧的文件 */
  private trim(): void {
    if (this.trimming || this.dirPath.length === 0) {
      return;
    }
    this.trimming = true;
    try {
      const names: string[] = fs.listFileSync(this.dirPath);
      if (names.length <= this.maxFiles) {
        this.trimming = false;
        return;
      }
      const files: CoverFile[] = [];
      let total: number = 0;
      for (const n of names) {
        if (!n.endsWith('.jpg')) {
          continue;
        }
        const p: string = this.dirPath + '/' + n;
        try {
          const st = fs.statSync(p);
          total += st.size;
          files.push({ path: p, size: st.size, mtime: st.mtime });
        } catch (e) {
          // 跳过读不到的文件
        }
      }
      files.sort((a: CoverFile, b: CoverFile): number => a.mtime - b.mtime);
      let count: number = files.length;
      for (const f of files) {
        if (count <= this.maxFiles && total <= this.maxBytes()) {
          break;
        }
        try {
          fs.unlinkSync(f.path);
          total -= f.size;
          count--;
        } catch (e) {
          // 忽略单条删除失败
        }
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cover trim failed');
    }
    this.trimming = false;
  }

  private ensureDir(): string {
    if (this.dirReady) {
      return this.dirPath;
    }
    const ctx = getAppContext();
    if (ctx === null) {
      return '';
    }
    const d: string = ctx.cacheDir + '/' + COVER_DIR;
    try {
      const fresh: boolean = !fs.accessSync(d);
      if (fresh) {
        fs.mkdirSync(d);
      }
      this.dirPath = d;
      this.dirReady = true;
      // 新版目录首次建立：把旧尺寸的缓存目录整个删掉，避免旧小图继续占空间
      if (fresh) {
        for (const old of LEGACY_COVER_DIRS) {
          this.removeDirQuietly(ctx.cacheDir + '/' + old);
        }
      }
      // 目录就绪后按设置里的上限执行一次（重启后不需要先去设置页点一下）
      this.reloadLimit();
      return d;
    } catch (e) {
      return '';
    }
  }

  /** 删除一个缓存目录（失败静默：系统可能已回收或文件被占用） */
  private removeDirQuietly(dir: string): void {
    try {
      if (!fs.accessSync(dir)) {
        return;
      }
      const names: string[] = fs.listFileSync(dir);
      for (const n of names) {
        try {
          fs.unlinkSync(dir + '/' + n);
        } catch (e) {
          // 忽略单个文件
        }
      }
      fs.rmdirSync(dir);
    } catch (e) {
      // 忽略整个目录
    }
  }

  /** 磁盘上已有则返回绝对路径，否则空串 */
  private cachedPath(url: string): string {
    const dir: string = this.ensureDir();
    if (dir.length === 0) {
      return '';
    }
    const p: string = dir + '/' + hashUrl(url) + '.jpg';
    try {
      return fs.accessSync(p) ? p : '';
    } catch (e) {
      return '';
    }
  }

  // ------------------------------------------------------------ 缓存管理接入（CacheStore 用）

  /** 封面缓存占用统计 */
  stats(): CacheStatsBrief {
    const dir: string = this.ensureDir();
    let bytes: number = 0;
    let count: number = 0;
    if (dir.length === 0) {
      return { coverBytes: 0, coverCount: 0 };
    }
    try {
      for (const n of fs.listFileSync(dir)) {
        try {
          bytes += fs.statSync(dir + '/' + n).size;
          count++;
        } catch (e) {
          // ignore
        }
      }
    } catch (e) {
      // ignore
    }
    const loc: CacheStatsBrief = this.localStats();
    return { coverBytes: bytes + loc.coverBytes, coverCount: count + loc.coverCount };
  }

  /** 按 URL 删除磁盘封面（删音频缓存的联动清理） */
  removeByUrl(url: string): void {
    if (url.length === 0) {
      return;
    }
    const dir: string = this.ensureDir();
    if (dir.length === 0) {
      return;
    }
    const p: string = dir + '/' + hashUrl(url) + '.jpg';
    try {
      if (fs.accessSync(p)) {
        fs.unlinkSync(p);
      }
    } catch (e) {
      // ignore
    }
    this.mem.delete(url);
  }

  /** 按落盘时间从旧到新删，直到释放 reachBytes；返回实际释放字节 */
  purgeOldest(reachBytes: number): number {
    const dir: string = this.ensureDir();
    if (dir.length === 0 || reachBytes <= 0) {
      return 0;
    }
    let freed: number = 0;
    try {
      const items: CoverFile[] = [];
      for (const n of fs.listFileSync(dir)) {
        const p: string = dir + '/' + n;
        try {
          const st = fs.statSync(p);
          items.push({ path: p, size: st.size, mtime: st.mtime });
        } catch (e) {
          // ignore
        }
      }
      items.sort((a: CoverFile, b: CoverFile): number => a.mtime - b.mtime);
      for (const it of items) {
        if (freed >= reachBytes) {
          break;
        }
        try {
          fs.unlinkSync(it.path);
          freed += it.size;
        } catch (e) {
          // ignore
        }
      }
      // 内存映射已失效，整体清掉即可（后续按需重建）
      this.mem.clear();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cover purge failed');
    }
    return freed;
  }

  /** 清空磁盘封面，返回释放字节 */
  clearDisk(): number {
    const st: CacheStatsBrief = this.stats();
    const dir: string = this.ensureDir();
    if (dir.length === 0) {
      return 0;
    }
    try {
      for (const n of fs.listFileSync(dir)) {
        try {
          fs.unlinkSync(dir + '/' + n);
        } catch (e) {
          // ignore
        }
      }
      // 本地封面目录：只有用户手动「清理缓存」才清（在线淘汰不会碰它）
      const locDir: string = this.ensureLocalDir();
      if (locDir.length > 0) {
        for (const n of fs.listFileSync(locDir)) {
          try {
            fs.unlinkSync(locDir + '/' + n);
          } catch (e) {
            // ignore
          }
        }
      }
      this.mem.clear();
    } catch (e) {
      // ignore
    }
    return st.coverBytes;
  }
}

/** 封面缓存占用（CacheStore 统计用） */
export interface CacheStatsBrief {
  coverBytes: number;
  coverCount: number;
}
