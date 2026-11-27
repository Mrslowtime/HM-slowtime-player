/**
 * 本地音乐扫描 —— M2-E④ 核心服务（单例）。
 *
 * 扫描应用沙箱 filesDir/downloads/ 下的音频文件，元数据来源优先级：
 *   1) 同名 <file>.meta.json 侧车（本应用下载时由 DownloadManager 写入，最准）；
 *   2) 音频内嵌标签（MP3 ID3v1/v2、FLAC VORBIS_COMMENT、M4A ilst，见 core/LocalTags）；
 *   3) 文件名「歌名 - 歌手」，兜底用文件名。
 * 标签里歌名/歌手填反的会被自动换回来（文件名交叉校验 + 同目录统计），
 * 避免「歌名位置显示成歌手名」。
 *
 * 元数据编辑：把用户修改（标题/歌手/专辑/封面）写入 <file>.override.json 侧车，
 * 扫描时优先合并覆盖。真实改写音频文件内嵌 ID3 属后续项（已在进度文档注明）。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MusicInfo, MusicInfoMetaLocal } from '../model/MusicTypes';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { getAppContext } from '../common/AppContext';
import { readLocalTags, parseLocalFileName, resolveNameAndSinger, fixSwappedBatch, LocalTags, FileNameParts, NamePair, NameEntry } from './LocalTags';
import { NameHints, LrcMeta, DirNameSample, collectNameHints, readLrcMeta, orderFromLrc, orderFromHints, detectDirOrder } from './LocalNameHints';
import { publicDownloadBase } from './DownloadStorage';
import { fillLocalDurations } from './LocalDuration';
import { CoverCache } from './ImageCache';

const AUDIO_EXT: string[] = ['mp3', 'flac', 'wav', 'm4a', 'ape', 'ogg', 'aac'];
const SCAN_DIR: string = '/downloads';
/** 已隐藏（从本地音乐列表移除，但不删文件）的歌曲路径清单 */
const HIDDEN_FILE: string = '/local_hidden.json';

/** 扫描中间态：带上「歌名/歌手是否已被文件名交叉校验」的标记 */
interface ScanEntry {
  info: MusicInfo;
  verified: boolean;
}

interface MetaOverride {
  name: string;
  singer: string;
  albumName: string;
  picUrl: string | null;
}

/** 隐藏清单的落盘格式 */
interface HiddenData {
  paths: string[];
}

export interface LocalMusicEdit {
  name?: string;
  singer?: string;
  albumName?: string;
  picUrl?: string;
}

function dir(): string {
  const ctx = getAppContext();
  if (ctx === null) {
    return '';
  }
  return ctx.filesDir + SCAN_DIR;
}

function extOf(name: string): string {
  const idx: number = name.lastIndexOf('.');
  if (idx >= 0) {
    return name.substring(idx + 1).toLowerCase();
  }
  return '';
}

function baseOf(name: string): string {
  const idx: number = name.lastIndexOf('.');
  return idx >= 0 ? name.substring(0, idx) : name;
}

/** 路径 → 8 位稳定短哈希（仅用于同名文件去重，避免不同文件夹的同名歌撞 id） */
function pathHash(path: string): string {
  let h: number = 5381;
  for (let i = 0; i < path.length; i++) {
    h = ((h * 33) ^ path.charCodeAt(i)) & 0x7FFFFFFF;
  }
  return h.toString(16);
}

let sInstance: LocalMusicScanner | null = null;

export class LocalMusicScanner {
  static getInstance(): LocalMusicScanner {
    if (sInstance === null) {
      sInstance = new LocalMusicScanner();
    }
    return sInstance;
  }

  /** 隐藏清单缓存（null = 尚未从磁盘加载） */
  private hidden: Set<string> | null = null;
  /** 本次扫描里被跳过的 0 字节文件（下载中断残留）：页面提示 + 一键清理用 */
  private emptyFiles: string[] = [];

  /** 本次扫描跳过的空文件数量 / 路径（本地页用来提示「为什么有的歌不在列表里」） */
  emptyFilePaths(): string[] {
    return this.emptyFiles.slice();
  }

  /**
   * 清理本次扫描发现的 0 字节空文件（下载没写完留下的残骸，播放不了）。
   * 只删「此刻仍是 0 字节」的文件，任何有内容的音频都不会被碰。
   */
  clearEmptyFiles(): number {
    let n: number = 0;
    for (const p of this.emptyFiles) {
      try {
        if (fs.accessSync(p) && fs.statSync(p).size === 0) {
          fs.unlinkSync(p);
          n++;
        }
      } catch (e) {
        void e;
      }
    }
    this.emptyFiles = [];
    return n;
  }

  /** 扫描沙箱 downloads 目录（含「保存位置」设置的子目录），返回本地 MusicInfo 列表 */
  async scan(): Promise<MusicInfo[]> {
    const d: string = dir();
    const out: MusicInfo[] = [];
    this.emptyFiles = [];
    if (d.length === 0) {
      return out;
    }
    try {
      if (!fs.accessSync(d)) {
        return out;
      }
      // 歌单 / 下载列表里的已知歌手是判定文件名顺序的本地证据（零网络请求）
      const hints: NameHints = collectNameHints();
      const usedIds: Set<string> = new Set<string>();
      // 目录去重：沙箱 / 公共目录 / 「下载」根目录会层层重叠，同一个目录只扫一次
      const visited: Set<string> = new Set<string>();
      this.scanDir(d, out, 0, 3, usedIds, visited, hints);
      // 同时扫描本应用的公共下载目录（含用户自建子文件夹）：
      // DOWNLOAD 模式已给这个目录持久化权限，直接读原文件即可，零复制、零新增权限。
      const pub: string = await publicDownloadBase();
      if (pub.length > 0 && pub !== d) {
        try {
          if (fs.accessSync(pub)) {
            this.scanDir(pub, out, 0, 3, usedIds, visited, hints);
          }
        } catch (e) {
          void e;
        }
        // 再向上看一层「下载」根目录（只下探一层）：用户在系统「文件」里把歌挪到
        // 别的文件夹后，刷新仍能看到它在新分组里。系统没给这个目录读权限时
        // listFileSync 会抛错，这里静默跳过，不影响原有扫描。
        const slash: number = pub.lastIndexOf('/');
        if (slash > 0) {
          const root: string = pub.substring(0, slash);
          try {
            if (root.length > 0 && !visited.has(root) && fs.accessSync(root)) {
              this.scanDir(root, out, 0, 1, usedIds, visited, hints);
            }
          } catch (e) {
            void e;
          }
        }
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'local scan failed: %{public}s', (e as Error).message);
    }
    // 同一路径只保留一条（多轮扫描目录有重叠时的兜底）
    const seen: Set<string> = new Set<string>();
    const uniq: MusicInfo[] = [];
    for (const m of out) {
      const p: string = (m.meta as MusicInfoMetaLocal).filePath;
      if (p.length > 0) {
        if (seen.has(p)) {
          continue;
        }
        seen.add(p);
      }
      uniq.push(m);
    }
    // 用户「从本地音乐移除」过的歌（只隐藏，文件还在）不再出现在列表里
    const hid: Set<string> = this.loadHidden();
    const list: MusicInfo[] = hid.size === 0
      ? uniq
      : uniq.filter((m: MusicInfo): boolean => {
          const p: string = (m.meta as MusicInfoMetaLocal).filePath;
          return p.length === 0 || !hid.has(p);
        });
    // 列表行要显示时长：内嵌标签一般不给，交给系统元数据提取器读（带磁盘缓存）
    await fillLocalDurations(list);
    // 没有同目录图片时，把音频内嵌封面导出成同名 jpg（零网络；取不到的记下来不再重试）
    return list;
  }

  // ─────────────────────── 隐藏（从列表移除，不删文件） ───────────────────────

  private hiddenFilePath(): string {
    const ctx = getAppContext();
    if (ctx === null) {
      return '';
    }
    return ctx.filesDir + HIDDEN_FILE;
  }

  /** 读取隐藏清单（内存缓存，首次从文件加载） */
  private loadHidden(): Set<string> {
    if (this.hidden !== null) {
      return this.hidden;
    }
    const set: Set<string> = new Set<string>();
    const p: string = this.hiddenFilePath();
    if (p.length > 0 && fs.accessSync(p)) {
      const obj: Object | null = this.readJsonObject(p);
      if (obj !== null) {
        const rec: Record<string, Object> = obj as Record<string, Object>;
        const raw: Object = rec['paths'];
        if (raw !== undefined && raw !== null && Array.isArray(raw)) {
          for (const item of raw as Array<Object>) {
            if (typeof item === 'string' && (item as string).length > 0) {
              set.add(item as string);
            }
          }
        }
      }
    }
    this.hidden = set;
    return set;
  }

  private saveHidden(): void {
    const p: string = this.hiddenFilePath();
    if (p.length === 0 || this.hidden === null) {
      return;
    }
    try {
      const data: HiddenData = { paths: Array.from(this.hidden) };
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      // SDK: writeSync(fd, ArrayBuffer | string)，传 Uint8Array 会抛 Invalid argument
      fs.writeSync(f.fd, JSON.stringify(data));
      fs.closeSync(f);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'save hidden failed: %{public}s', (e as Error).message);
    }
  }

  /** 已隐藏歌曲数量（本地页用来显示「恢复」入口） */
  hiddenCount(): number {
    return this.loadHidden().size;
  }

  /**
   * 从本地音乐列表移除若干首：只记录路径，不碰音频文件本身。
   * 返回本次新增隐藏的数量。
   */
  hide(infos: MusicInfo[]): number {
    const set: Set<string> = this.loadHidden();
    let added: number = 0;
    for (const m of infos) {
      if (m.source !== 'local') {
        continue;
      }
      const p: string = (m.meta as MusicInfoMetaLocal).filePath;
      if (p.length === 0 || set.has(p)) {
        continue;
      }
      set.add(p);
      added++;
    }
    if (added > 0) {
      this.saveHidden();
    }
    return added;
  }

  /** 恢复全部已隐藏歌曲，返回恢复数量 */
  restoreHidden(): number {
    const set: Set<string> = this.loadHidden();
    const n: number = set.size;
    if (n === 0) {
      return 0;
    }
    set.clear();
    this.saveHidden();
    return n;
  }

  /**
   * 导入用户从系统文件选择器挑中的音频：复制进沙箱 downloads 目录（扫描目标）。
   * 选择器返回的 uri 只有临时读权限，重启后失效，所以必须复制一份到沙箱。
   * 返回成功导入的文件数。
   */
  async importFiles(uris: string[]): Promise<number> {
    const d: string = dir();
    if (d.length === 0 || uris.length === 0) {
      return 0;
    }
    try {
      if (!fs.accessSync(d)) {
        fs.mkdirSync(d, true);
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'import: mkdir failed');
      return 0;
    }
    let ok: number = 0;
    for (const uri of uris) {
      try {
        const seg: string = uri.substring(uri.lastIndexOf('/') + 1);
        const name: string = decodeURIComponent(seg);
        if (AUDIO_EXT.indexOf(extOf(name)) < 0) {
          continue;
        }
        const dest: string = d + '/' + name;
        const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
        const dst = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        fs.copyFileSync(src.fd, dst.fd);
        fs.closeSync(src);
        fs.closeSync(dst);
        // 顺带把同目录的同名歌词 / 封面也复制进来：
        // 导入只拿到单个文件的读权限，同目录读不到就静默跳过
        this.copySidecars(uri, baseOf(name), d);
        ok++;
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'import file failed: %{public}s', (e as Error).message);
      }
    }
    return ok;
  }

  /**
   * 导入音频时顺带复制「同目录同名歌词 / 封面」。
   * 系统文件选择器只授予被选文件本身的读权限，同目录多半读不到 —— 读不到就静默跳过，
   * 不影响导入本身；能读到（例如 file://docs 下的音乐文件夹）就让本地歌带歌词和封面进来。
   */
  private copySidecars(srcUri: string, baseName: string, destDir: string): void {
    if (srcUri.indexOf('file://') !== 0 && srcUri.indexOf('/') !== 0) {
      // datashare:// 只授权单个文件，同目录必定读不到
      return;
    }
    const slash: number = srcUri.lastIndexOf('/');
    if (slash <= 0) {
      return;
    }
    const srcDir: string = srcUri.substring(0, slash);
    const candidates: string[] = [
      baseName + '.lrc', baseName + '.LRC',
      baseName + '.jpg', baseName + '.jpeg', baseName + '.png', baseName + '.webp',
      'cover.jpg', 'cover.png', 'folder.jpg', 'folder.png',
    ];
    for (const n of candidates) {
      const from: string = srcDir + '/' + n;
      const to: string = destDir + '/' + n;
      try {
        if (!fs.accessSync(from)) {
          continue;
        }
        if (fs.accessSync(to)) {
          continue;
        }
        fs.copyFileSync(from, to);
      } catch (e) {
        // 权限不足 / 已存在 / 不支持：忽略，不影响音频本身
      }
    }
  }

  /** 递归扫描单层（深度上限 3，与 DownloadManager.sanitizeSubDir 的层数上限一致） */
  private scanDir(d: string, out: MusicInfo[], depth: number, maxDepth: number,
    usedIds: Set<string>, visited: Set<string>, hints: NameHints): void {
    // 多个扫描根会层层重叠（沙箱 / 公共目录 / 「下载」根），同一目录只处理一次
    if (visited.has(d)) {
      return;
    }
    visited.add(d);
    let names: string[] = [];
    try {
      names = fs.listFileSync(d);
    } catch (e) {
      return;
    }
    // 目录内的图片文件名：给「同目录同名封面 / cover.jpg」探测用，避免每首歌都重新 listFile
    const images: string[] = [];
    for (const n of names) {
      const e: string = extOf(n).toLowerCase();
      if (e === 'jpg' || e === 'jpeg' || e === 'png' || e === 'webp' || e === 'bmp') {
        images.push(n);
      }
    }
    // 目录级顺序统计：同一文件夹里歌手名会重复、歌名几乎不重复。
    // 大量文件没有内嵌标签时，这是唯一能自动认出「歌手 - 歌名」还是「歌名 - 歌手」的
    // 本地证据（纯字符串统计，零网络）。混合命名的目录会返回空串，不做猜测。
    const samples: DirNameSample[] = [];
    for (const n of names) {
      if (AUDIO_EXT.indexOf(extOf(n)) < 0) {
        continue;
      }
      const parts: FileNameParts = parseLocalFileName(baseOf(n));
      if (parts.hasSeparator && parts.name.length > 0 && parts.singer.length > 0) {
        samples.push({ left: parts.name, right: parts.singer });
      }
    }
    const dirOrder: string = detectDirOrder(samples);
    // 同一目录先集中处理，才能做「歌名恒定、歌手各异 → 填反了」的目录级判断
    const entries: ScanEntry[] = [];
    for (const name of names) {
      const full: string = d + '/' + name;
      let isDir: boolean = false;
      try {
        isDir = fs.statSync(full).isDirectory();
      } catch (e) {
        isDir = false;
      }
      if (isDir) {
        if (depth < maxDepth) {
          this.scanDir(full, out, depth + 1, maxDepth, usedIds, visited, hints);
        }
        continue;
      }
      const ext: string = extOf(name);
      if (AUDIO_EXT.indexOf(ext) < 0) {
        continue;
      }
      // 0 字节文件是下载中断/失败留下的残骸，放进列表只会点开报
      //「5400106 Unsupported Format」，直接跳过
      try {
        if (fs.statSync(full).size === 0) {
          // 记下来：本地页会提示「有 N 个空文件（下载未完成）」，可一键清理
          this.emptyFiles.push(full);
          continue;
        }
      } catch (e) {
        continue;
      }
      const entry: ScanEntry | null = this.readEntry(full, name, ext, images, hints, dirOrder);
      if (entry !== null) {
        // 不同文件夹里的同名文件：id 追加路径哈希，避免列表 key/播放缓存互串
        if (usedIds.has(entry.info.id)) {
          const uid: string = entry.info.id + '_' + pathHash(full);
          entry.info.id = uid;
          (entry.info.meta as MusicInfoMetaLocal).songId = uid;
        }
        usedIds.add(entry.info.id);
        entries.push(entry);
      }
    }
    this.fixSwappedInDir(entries);
    for (const e of entries) {
      out.push(e.info);
    }
  }

  /** 目录级兜底：同目录「歌名恒定、歌手各异」→ 判定为填反，整批换回来 */
  private fixSwappedInDir(entries: ScanEntry[]): void {
    const names: NameEntry[] = [];
    for (const e of entries) {
      names.push({ name: e.info.name, singer: e.info.singer, verified: e.verified });
    }
    if (!fixSwappedBatch(names)) {
      return;
    }
    for (let i = 0; i < entries.length; i++) {
      entries[i].info.name = names[i].name;
      entries[i].info.singer = names[i].singer;
      entries[i].verified = names[i].verified;
    }
  }


  /**
   * 读取单个文件的 MusicInfo：
   * 侧车 meta.json → 内嵌标签 → 文件名，并做歌名/歌手填反纠正。
   */
  private readEntry(filePath: string, fileName: string, ext: string, images: string[],
    hints: NameHints, dirOrder: string): ScanEntry | null {
    const metaPath: string = filePath + '.meta.json';
    const overridePath: string = filePath + '.override.json';
    const baseName: string = baseOf(fileName);
    const fn: FileNameParts = parseLocalFileName(baseName);
    let base: MusicInfo | null = null;
    let verified: boolean = false;

    if (fs.accessSync(metaPath)) {
      // 下载时写入的侧车是权威数据，不再套用文件名/标签推断
      base = this.readJsonMusic(metaPath);
      verified = base !== null;
    }
    if (base === null) {
      const tags: LocalTags | null = readLocalTags(filePath, ext);
      const title: string = tags !== null ? tags.title : '';
      const artist: string = tags !== null ? tags.artist : '';
      // 判定文件名左右两段谁是歌手：优先同目录同名歌词的 [ar:]/[ti:]，其次歌单已知歌手。
      // 这一步不能省——写死「左歌名右歌手」会把「歌手 - 歌名」命名里正确的标签翻反。
      const slash: number = filePath.lastIndexOf('/');
      const lrcPath: string = (slash >= 0 ? filePath.substring(0, slash + 1) : '') + baseName + '.lrc';
      const lrc: LrcMeta = readLrcMeta(lrcPath);
      let order: string = orderFromLrc(fn.name, fn.singer, lrc);
      if (order.length === 0) {
        order = orderFromHints(fn.name, fn.singer, hints);
      }
      // 逐首证据都没有时，用目录统计（弱证据：只在标签字段为空时生效）
      let weak: boolean = false;
      if (order.length === 0 && dirOrder.length > 0) {
        order = dirOrder;
        weak = true;
      }
      let hintSinger: string = '';
      let hintName: string = '';
      if (order === 'left') {
        hintSinger = fn.name;
      } else if (order === 'right') {
        hintSinger = fn.singer;
      } else {
        // 文件名无分隔时仍可用歌词/歌单直接判断标签本身是否填反
        hintSinger = lrc.artist;
        hintName = lrc.title;
      }
      const pair: NamePair = resolveNameAndSinger(title, artist, fn, hintSinger, hintName, weak);
      verified = pair.verified;
      const meta: MusicInfoMetaLocal = {
        songId: 'local_' + baseName,
        albumName: tags !== null ? tags.album : '',
        picUrl: null,
        filePath,
        ext,
      };
      base = {
        id: 'local_' + baseName,
        name: pair.name,
        singer: pair.singer,
        source: 'local',
        interval: null,
        meta,
      };
      // 不再自动写 override：自动判断（尤其目录统计）只是猜测，一旦写进侧车就会
      // 永久压过后续更准的结果 —— 之前「一大批歌名歌手反了」就是这么被固化的。
      // 用户手动编辑仍会写 override（LocalMusicEdit），那种才视为已确认。
    }
    // 合并用户覆盖元数据
    let userPic: string = '';
    if (fs.accessSync(overridePath)) {
      const ov = this.readJsonObject(overridePath);
      if (ov !== null) {
        const rec: Record<string, Object> = ov as Record<string, Object>;
        if (typeof rec['name'] === 'string') { base.name = rec['name'] as string; }
        if (typeof rec['singer'] === 'string') { base.singer = rec['singer'] as string; }
        const meta = base.meta as MusicInfoMetaLocal;
        if (typeof rec['albumName'] === 'string') { meta.albumName = rec['albumName'] as string; }
        if (typeof rec['picUrl'] === 'string') {
          userPic = rec['picUrl'] as string;
          meta.picUrl = userPic;
        }
        // 用户手工改过的，一律视为已确认，不参与目录级猜测
        verified = true;
      }
    }
    /**
     * 封面优先级：用户手工指定 > 同目录同名图片 > 侧车里的在线地址。
     *
     * 以前是侧车 picUrl 优先，于是「下载时记下的在线封面地址」即使已经失效
     * （CDN 换域名 / 需要 referer），也会把同目录那张好图挡在外面 —— 表现就是
     * 歌明明已经有同名 jpg，列表和播放页却一直是占位图。本地图不会失效，必须优先。
     */
    const lm = base.meta as MusicInfoMetaLocal;
    // 路径以本次扫描到的真实位置为准：旧侧车 / 用户覆盖里可能存着文件被挪走前的路径，
    // 那样「文件夹」分组会一直显示旧目录（用户报的问题），播放也会指到不存在的文件。
    lm.filePath = filePath;
    lm.ext = ext;
    if (userPic.length === 0) {
      const p: string = this.pickCover(filePath, baseName, images);
      if (p.length > 0) {
        lm.picUrl = p;
      } else {
        // 同目录没有图时看封面缓存（内嵌封面导出 / 在线匹配过的图都在这里，
        // 统一由缓存系统管理，不再往音乐文件夹写 jpg）
        const cached: string = CoverCache.getInstance().peekLocal(filePath);
        if (cached.length > 0) {
          lm.picUrl = cached;
        }
      }
    }
    return { info: base, verified: verified };
  }

  /**
   * 同目录封面探测：优先「与歌曲同名」的图片，其次 cover / folder / albumart 等约定名。
   * 返回 file:// URI（本地图直接给 Image 用，不走网络封面缓存）。
   */
  private pickCover(filePath: string, baseName: string, images: string[]): string {
    if (images.length === 0) {
      return '';
    }
    const slash: number = filePath.lastIndexOf('/');
    if (slash < 0) {
      return '';
    }
    const dir: string = filePath.substring(0, slash);
    const target: string = baseName.toLowerCase();
    const stem = (n: string): string => {
      const dot: number = n.lastIndexOf('.');
      return (dot > 0 ? n.substring(0, dot) : n).toLowerCase();
    };
    for (const img of images) {
      if (stem(img) === target) {
        return 'file://' + dir + '/' + img;
      }
    }
    const fixed: string[] = ['cover', 'folder', 'album', 'albumart', 'front', 'artwork'];
    for (const f of fixed) {
      for (const img of images) {
        if (stem(img) === f) {
          return 'file://' + dir + '/' + img;
        }
      }
    }
    return '';
  }

  private readJsonMusic(path: string): MusicInfo | null {
    try {
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(f.fd, buf, { offset: 0, length: stat.size });
      fs.closeSync(f);
      const text: string = new util.TextDecoder().decodeToString(new Uint8Array(buf));
      const obj = JSON.parse(text) as Object;
      const rec: Record<string, Object> = obj as Record<string, Object>;
      if (typeof rec['id'] !== 'string' || typeof rec['name'] !== 'string') {
        return null;
      }
      const metaObj: Record<string, Object> = (rec['meta'] as Record<string, Object>) ?? {};
      const meta: MusicInfoMetaLocal = {
        songId: typeof metaObj['songId'] === 'string' ? metaObj['songId'] as string : rec['id'] as string,
        albumName: typeof metaObj['albumName'] === 'string' ? metaObj['albumName'] as string : '',
        picUrl: typeof metaObj['picUrl'] === 'string' ? metaObj['picUrl'] as string : null,
        filePath: typeof metaObj['filePath'] === 'string' ? metaObj['filePath'] as string : '',
        ext: typeof metaObj['ext'] === 'string' ? metaObj['ext'] as string : 'mp3',
      };
      return {
        id: rec['id'] as string,
        name: rec['name'] as string,
        singer: typeof rec['singer'] === 'string' ? rec['singer'] as string : '未知歌手',
        source: 'local',
        interval: typeof rec['interval'] === 'string' ? rec['interval'] as string : null,
        meta,
      };
    } catch (e) {
      return null;
    }
  }

  private readJsonObject(path: string): Object | null {
    try {
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(f.fd, buf, { offset: 0, length: stat.size });
      fs.closeSync(f);
      const text: string = new util.TextDecoder().decodeToString(new Uint8Array(buf));
      return JSON.parse(text) as Object;
    } catch (e) {
      return null;
    }
  }

  /** 写入用户元数据覆盖（不改动音频文件本体） */
  async saveEdit(info: MusicInfo, edit: LocalMusicEdit): Promise<void> {
    if (info.source !== 'local') {
      return;
    }
    const meta = info.meta as MusicInfoMetaLocal;
    if (edit.name !== undefined) { info.name = edit.name; }
    if (edit.singer !== undefined) { info.singer = edit.singer; }
    if (edit.albumName !== undefined) { meta.albumName = edit.albumName; }
    if (edit.picUrl !== undefined) { meta.picUrl = edit.picUrl; }
    try {
      const override: MetaOverride = {
        name: info.name,
        singer: info.singer,
        albumName: meta.albumName,
        picUrl: meta.picUrl !== undefined ? meta.picUrl : null,
      };
      const text: string = JSON.stringify(override);
      const p: string = meta.filePath + '.override.json';
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      // SDK: writeSync(fd, buffer: ArrayBuffer | string)，传 Uint8Array 会抛 Invalid argument
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'save edit failed: %{public}s', (e as Error).message);
    }
  }

  /** 删除本地文件（含侧车） */
  async deleteFile(info: MusicInfo): Promise<void> {
    if (info.source !== 'local') {
      return;
    }
    const meta = info.meta as MusicInfoMetaLocal;
    try {
      if (fs.accessSync(meta.filePath)) {
        fs.unlinkSync(meta.filePath);
      }
      const metaP: string = meta.filePath + '.meta.json';
      if (fs.accessSync(metaP)) {
        fs.unlinkSync(metaP);
      }
      const ovP: string = meta.filePath + '.override.json';
      if (fs.accessSync(ovP)) {
        fs.unlinkSync(ovP);
      }
      // 文件真的删掉了，隐藏清单里也清掉，避免清单无限增长
      const hid: Set<string> = this.loadHidden();
      if (hid.has(meta.filePath)) {
        hid.delete(meta.filePath);
        this.saveHidden();
      }
    } catch (e) {
      void e;
    }
  }
}
