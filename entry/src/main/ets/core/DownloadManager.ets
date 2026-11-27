/**
 * 下载管理 —— M2-E③ 核心服务（单例）。
 *
 * 设计要点：
 * - 文件落在应用沙箱 filesDir/downloads/，不请求系统媒体库权限，避免权限弹窗。
 * - 取链复用 MusicUrlResolver，但下载失败走 DownloadSourceFallback 的低风控换源，不写播放熔断。
 * - 进度：@ohos.net.http 的 dataReceiveProgress / dataReceive 事件，边下边写文件。
 * - 断点续传：暂停后保留未下完的文件，恢复时带 Range 头从断点续写。
 * - 每首下完写一个 <file>.meta.json 侧车，保存 MusicInfo（source=local），
 *   既供本地音乐扫描还原，也自动进「下载列表」可播放。
 * - 任务清单持久化到 downloads/_tasks.json，重启后未完成任务转「已暂停」待手动恢复。
 */
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { MusicInfo, MusicInfoMetaOnline, MusicInfoMetaLocal, DownloadListItem } from '../model/MusicTypes';
import { Quality, ListIds } from '../config/AppConstants';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { getAppContext } from '../common/AppContext';
import { resolveDownloadUrl } from './DownloadSourceFallback';
import { ListManager } from './ListManager';
import { SettingStore } from '../store/SettingStore';
import { userNotice } from './UserNotice';
import { I18n } from './I18n';
import { CoverCache } from './ImageCache';
import { publicDownloadBase, usePublicStorage, markPublicUnavailable, isPublicStored } from './DownloadStorage';

export type DownloadStatus = 'waiting' | 'downloading' | 'paused' | 'completed' | 'error' | 'canceled';

const ALLOWED_EXT: string[] = ['mp3', 'flac', 'wav', 'm4a', 'ape', 'ogg', 'aac'];
const TASKS_FILE: string = '_tasks.json';

/** http dataReceiveProgress 事件回调参数 */
interface ProgressInfo {
  receiveSize: number;
  totalSize: number;
}

/** 任务的持久化快照（规避 MusicInfo 内 Map 不可 JSON 化） */
interface TaskSnapshot {
  id: string;
  status: string;
  statusText: string;
  downloaded: number;
  total: number;
  progress: number;
  quality: Quality;
  fileName: string;
  filePath: string;
  ext: string;
  musicInfo: MusicInfo;
}

function filesDir(): string {
  const ctx = getAppContext();
  if (ctx === null) {
    return '';
  }
  return ctx.filesDir;
}

/** 下载根目录（固定不变；任务清单 _tasks.json 恒在此，不受「保存位置」设置影响） */
function rootDir(): string {
  return filesDir() + '/downloads';
}

/**
 * 净化用户填写的相对子目录。
 * 只保留安全的相对层级（最多 3 层），剔除 .. / 绝对路径 / 非法字符，
 * 防止把文件写到沙箱外或覆盖任务清单。
 */
export function sanitizeSubDir(raw: string): string {
  if (raw === undefined || raw === null || raw.length === 0) {
    return '';
  }
  const norm: string = raw.replace(/\\/g, '/').trim();
  const parts: string[] = norm.split('/');
  const kept: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    let seg: string = parts[i].trim();
    if (seg.length === 0 || seg === '.' || seg === '..') {
      continue;
    }
    seg = seg.replace(/[\/\\:*?"<>|\r\n\t]/g, '_').replace(/\s+/g, ' ');
    if (seg.length === 0) {
      continue;
    }
    kept.push(seg);
    if (kept.length >= 3) {
      break;
    }
  }
  return kept.join('/');
}

/** 逐层创建目录（子目录可能有多级），已存在则跳过 */
function ensureDir(path: string): void {
  if (path.length === 0) {
    return;
  }
  const segs: string[] = path.split('/');
  let cur: string = '';
  for (let i = 0; i < segs.length; i++) {
    const s: string = segs[i];
    if (s.length === 0) {
      cur = '/';
      continue;
    }
    cur = cur === '/' || cur.length === 0 ? cur + s : cur + '/' + s;
    try {
      if (!fs.accessSync(cur)) {
        fs.mkdirSync(cur);
      }
    } catch (e) {
      void e;
    }
  }
}

/** 下载文件落盘目录 = 根目录 + 用户设置的子目录 */
function downloadDir(): string {
  const base: string = rootDir();
  const sub: string = sanitizeSubDir(SettingStore.getInstance().getString('download.savePath', 'HM慢时光'));
  return sub.length > 0 ? base + '/' + sub : base;
}

function safeName(s: string): string {
  let out: string = s.replace(/[\/\\:*?"<>|\r\n\t]/g, '_').replace(/\s+/g, ' ').trim();
  if (out.length === 0) {
    out = 'untitled';
  }
  return out;
}

function extFromUrl(url: string): string {
  try {
    const path: string = url.split('?')[0];
    const idx: number = path.lastIndexOf('.');
    if (idx >= 0) {
      const e: string = path.substring(idx + 1).toLowerCase();
      if (ALLOWED_EXT.indexOf(e) >= 0) {
        return e;
      }
    }
  } catch (e) {
    void e;
  }
  return 'mp3';
}

/** 旧版本下拉选项里的中文值 → 等价的模板，保证老设置不失效 */
const LEGACY_NAME_RULES: Record<string, string> = {
  '歌名 - 歌手': '{name} - {singer}',
  '歌手 - 歌名': '{singer} - {name}',
  '歌名': '{name}',
};

/**
 * 按模板生成下载文件名。
 * 模板支持占位符 {name}/{singer}/{quality}/{album}；
 * 不含占位符时按字面量处理（旧中文规则先映射成模板）。
 */
export function buildFileName(info: MusicInfo, quality: Quality, ext: string, template: string): string {
  const name: string = safeName(info.name);
  const singer: string = safeName(info.singer);
  const album: string = safeName(info.meta.albumName !== undefined && info.meta.albumName !== null ? info.meta.albumName : '');
  let tpl: string = template !== undefined && template !== null ? template.trim() : '';
  const legacy: string | undefined = LEGACY_NAME_RULES[tpl];
  if (legacy !== undefined) {
    tpl = legacy;
  }
  let base: string = '';
  if (tpl.length === 0) {
    base = name + ' - ' + singer;
  } else if (tpl.indexOf('{') >= 0) {
    base = tpl.split('{name}').join(name)
      .split('{singer}').join(singer)
      .split('{album}').join(album)
      .split('{quality}').join(quality);
  } else {
    base = tpl;
  }
  base = safeName(base);
  if (base.length === 0 || base === 'untitled') {
    base = name + ' - ' + singer;
  }
  return base + '.' + ext;
}

function defaultFileName(info: MusicInfo, quality: Quality, ext: string): string {
  const tpl: string = SettingStore.getInstance().getString('download.fileName', '{singer} - {name}');
  return buildFileName(info, quality, ext, tpl);
}

/** 构造下载完成后的本地 MusicInfo（source=local，meta 带 filePath） */
function toLocalMusicInfo(info: MusicInfo, quality: Quality, filePath: string, ext: string): MusicInfo {
  const online: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
  const meta: MusicInfoMetaLocal = {
    songId: info.id,
    albumName: online.albumName ?? '',
    picUrl: online.picUrl !== undefined ? online.picUrl : null,
    filePath,
    ext,
  };
  return {
    id: 'dl_' + info.id + '_' + quality,
    name: info.name,
    singer: info.singer,
    source: 'local',
    interval: info.interval,
    meta,
  };
}

/** 任务序列化为可持久化的纯对象（规避 Map 不可 JSON 化） */
function serializeTask(t: DownloadListItem): TaskSnapshot {
  return {
    id: t.id,
    status: t.status,
    statusText: t.statusText,
    downloaded: t.downloaded,
    total: t.total,
    progress: t.progress,
    quality: t.quality,
    fileName: t.fileName,
    filePath: t.filePath,
    ext: t.ext,
    musicInfo: t.musicInfo,
  };
}

let sInstance: DownloadManager | null = null;

/** 同时下载的最大任务数：削峰值，其余排队（避免连点下载打成并发风暴） */
const MAX_CONCURRENT: number = 2;

export class DownloadManager {
  /** 内存中的任务列表（含进行中/已完成/失败） */
  private tasks: DownloadListItem[] = [];
  private listeners: Array<() => void> = [];
  private running: Set<string> = new Set<string>();
  /** 排队中等待开始的任务 id（按入队顺序，最多 MAX_CONCURRENT 个同时在跑） */
  private waitingQueue: string[] = [];
  private aborted: Set<string> = new Set<string>();
  private reqs: Map<string, http.HttpRequest> = new Map();
  /** 速度计算：上一次采样的字节与时间 */
  private speedLastBytes: Map<string, number> = new Map();
  private speedLastTime: Map<string, number> = new Map();
  /** 防止重复初始化导致任务/列表重复 */
  private initialized: boolean = false;

  static getInstance(): DownloadManager {
    if (sInstance === null) {
      sInstance = new DownloadManager();
    }
    return sInstance;
  }

  /** 订阅变更（UI 刷新） */
  subscribe(cb: () => void): void {
    this.listeners.push(cb);
  }

  unsubscribe(cb: () => void): void {
    const idx = this.listeners.indexOf(cb);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private notify(): void {
    for (const cb of this.listeners.slice()) {
      cb();
    }
  }

  /** 返回可触发 ArkUI 重渲染的快照副本 */
  getSnapshot(): DownloadListItem[] {
    const out: DownloadListItem[] = [];
    for (const t of this.tasks) {
      out.push({
        id: t.id,
        isComplate: t.isComplate,
        status: t.status,
        statusText: t.statusText,
        downloaded: t.downloaded,
        total: t.total,
        progress: t.progress,
        speed: t.speed,
        musicInfo: t.musicInfo,
        quality: t.quality,
        fileName: t.fileName,
        filePath: t.filePath,
        ext: t.ext,
      });
    }
    return out;
  }

  /** 启动时加载持久化任务；未完成的转「已暂停」待手动恢复。幂等：重复调用不会重复载入 */
  init(): void {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    const dir: string = rootDir();
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      const p: string = dir + '/' + TASKS_FILE;
      if (!fs.accessSync(p)) {
        return;
      }
      const f = fs.openSync(p, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(p);
      const buf = new ArrayBuffer(stat.size);
      fs.readSync(f.fd, buf, { offset: 0, length: stat.size });
      fs.closeSync(f);
      const text: string = new util.TextDecoder().decodeToString(new Uint8Array(buf));
      // 空文件（首次安装 / 上次写入中断）会让 JSON.parse 抛错，按空任务表处理
      const arr: Object[] = text.trim().length === 0 ? [] : JSON.parse(text) as Object[];
      for (const o of arr) {
        const rec: Record<string, Object> = o as Record<string, Object>;
        const t: DownloadListItem = {
          id: rec['id'] as string,
          isComplate: (rec['status'] as string) === 'completed',
          status: rec['status'] as string,
          statusText: rec['statusText'] as string,
          downloaded: rec['downloaded'] as number,
          total: rec['total'] as number,
          progress: rec['progress'] as number,
          speed: '',
          musicInfo: rec['musicInfo'] as MusicInfo,
          quality: rec['quality'] as Quality,
          fileName: rec['fileName'] as string,
          filePath: rec['filePath'] as string,
          ext: rec['ext'] as string,
        };
        // 旧版本完成的任务可能把进度记成 0（CDN 不给 content-length 的老问题），
        // 按真实文件大小回填，避免下载页一直显示 0B/0B。
        if (t.status === 'completed' && (t.downloaded <= 0 || t.total <= 0)) {
          try {
            const sz: number = fs.statSync(t.filePath).size;
            if (sz > 0) {
              t.downloaded = sz;
              t.total = sz;
            }
          } catch (e) {
            void e;
          }
        }
        // 重启恢复：completed/canceled/error 原样保留（error 的 statusText 已带真实失败原因，
        // 绝不能覆盖成「已暂停」，否则用户看不出到底成功还是失败）。
        // downloading/waiting 是进程被杀时的中断态：从未传过字节的说明卡在取链/连接阶段，
        // 标为失败并给明确指引；已经传了一部分的转「已暂停」待手动继续。
        if (t.status === 'downloading' || t.status === 'waiting') {
          if (t.downloaded <= 0 && t.total <= 0) {
            t.status = 'error';
            t.statusText = '未开始下载（可能取链失败），点「重试」重新尝试';
          } else {
            t.status = 'paused';
            t.statusText = '已暂停（未完成）';
          }
          t.speed = '';
        }
        this.tasks.push(t);
      }
      this.persist();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'download init failed: %{public}s', (e as Error).message);
    }
    this.rebuildDownloadList();
    this.notify();
  }

  /** 把已完成的下载还原进「下载列表」 */
  private rebuildDownloadList(): void {
    const completed = this.tasks.filter((t: DownloadListItem): boolean => t.status === 'completed');
    const infos: MusicInfo[] = [];
    for (const t of completed) {
      infos.push(toLocalMusicInfo(t.musicInfo, t.quality, t.filePath, t.ext));
    }
    if (infos.length > 0) {
      ListManager.getInstance().addListMusics(ListIds.DOWNLOAD, infos, false);
    }
  }

  /** 发起下载（播放详情/歌单页调用） */
  enqueue(info: MusicInfo, quality: Quality, fileName?: string): void {
    const dir: string = downloadDir();
    if (dir.length === 0) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'download: no app context');
      return;
    }
    ensureDir(rootDir());
    ensureDir(dir);
    const ext: string = extFromUrl('.'); // 占位，真正 ext 在拿到 URL 后修正
    const fname: string = fileName !== undefined && fileName.length > 0
      ? safeName(fileName)
      : defaultFileName(info, quality, 'mp3');
    const id: string = 'dl_' + info.id + '_' + quality;
    // 同一首同音质只保留一个任务
    const exist = this.tasks.find((t: DownloadListItem): boolean => t.id === id);
    if (exist !== undefined) {
      if (exist.status === 'downloading') {
        return;
      }
      exist.status = 'waiting';
      exist.statusText = '排队中';
      this.enqueueTask(exist.id);
      return;
    }
    const task: DownloadListItem = {
      id,
      isComplate: false,
      status: 'waiting',
      statusText: '排队中',
      downloaded: 0,
      total: 0,
      progress: 0,
      speed: '',
      musicInfo: info,
      quality,
      fileName: fname,
      filePath: dir + '/' + fname,
      ext: 'mp3',
    };
    this.tasks.unshift(task);
    this.persist();
    this.notify();
    this.enqueueTask(task.id);
  }

  /** 把任务排进等待队列并尝试启动（受 MAX_CONCURRENT 限制） */
  private enqueueTask(id: string): void {
    if (this.running.has(id) || this.waitingQueue.indexOf(id) >= 0) {
      return;
    }
    this.waitingQueue.push(id);
    this.pump();
  }

  /** 并发闸门：running < MAX_CONCURRENT 时按队列顺序启动下一个 */
  private pump(): void {
    while (this.running.size < MAX_CONCURRENT && this.waitingQueue.length > 0) {
      const id: string = this.waitingQueue.shift() as string;
      const t: DownloadListItem | undefined = this.find(id);
      if (t === undefined) {
        continue;
      }
      this.start(t);
    }
  }

  /** 开始/恢复下载 */
  private async start(task: DownloadListItem): Promise<void> {
    if (this.running.has(task.id)) {
      return;
    }
    // 并发闸门：已满则退回等待队列（由 pump 在有空位时再启动）
    if (this.running.size >= MAX_CONCURRENT) {
      if (this.waitingQueue.indexOf(task.id) < 0) {
        this.waitingQueue.unshift(task.id);
      }
      return;
    }
    this.running.add(task.id);
    this.aborted.delete(task.id);
    task.status = 'downloading';
    task.statusText = '下载中';
    task.speed = '';
    this.notify();

    // 0) 落盘目录：默认直接写手机「下载」公共目录（无界面、不占双份磁盘）。
    //    设备不支持或授权失败时静默回落沙箱，保证下载永远可用。
    let targetDir: string = downloadDir();
    if (usePublicStorage()) {
      const pub: string = await publicDownloadBase();
      if (pub.length > 0) {
        const sub: string = sanitizeSubDir(SettingStore.getInstance().getString('download.savePath', 'HM慢时光'));
        const dir: string = sub.length > 0 ? pub + '/' + sub : pub;
        ensureDir(dir);
        targetDir = dir;
      }
    }

    // 1) 取链（下载专用：失败时按低风控上限换源，不影响播放与全局熔断）
    const outcome = await resolveDownloadUrl(task.musicInfo, task.quality, (text: string): void => {
      // 取消/暂停后不再覆盖状态文案，避免「已暂停」被取链进度文案刷回去
      if (this.aborted.has(task.id)) {
        return;
      }
      task.statusText = text;
      this.notify();
    }, (): boolean => this.aborted.has(task.id));
    // 取链期间用户点了暂停/取消：立刻收尾，绝不能继续创建文件、发下载请求
    if (outcome.cancelled || this.aborted.has(task.id)) {
      this.running.delete(task.id);
      this.speedLastBytes.delete(task.id);
      this.speedLastTime.delete(task.id);
      this.aborted.delete(task.id);
      const t: DownloadListItem | undefined = this.find(task.id);
      let wantRestart: boolean = false;
      if (t !== undefined && t.status !== 'canceled') {
        // 用户在这段取链期间又点了「继续」：别把它压回暂停，待会儿重新入队
        wantRestart = t.status === 'waiting';
        if (!wantRestart) {
          t.status = 'paused';
          t.statusText = '已暂停';
          t.speed = '';
        }
      }
      this.persist();
      this.notify();
      this.pump();
      if (wantRestart) {
        this.enqueueTask(task.id);
      }
      return;
    }
    const r = outcome.result;
    if (!r.ok || r.url.length === 0) {
      task.status = 'error';
      task.statusText = '取链失败：' + r.error;
      task.speed = '';
      this.running.delete(task.id);
      this.pump();
      this.persist();
      this.notify();
      return;
    }
    // 拿到真实 URL 后修正扩展名。
    // 已有断点文件的任务沿用原目录（否则续传会丢进度）；新文件用本次解析出的落盘目录。
    const ext: string = extFromUrl(r.url);
    const baseName: string = task.fileName.replace(/\.[^.]+$/, '');
    const slash: number = task.filePath.lastIndexOf('/');
    let hasPartial: boolean = false;
    try {
      if (fs.accessSync(task.filePath)) {
        hasPartial = fs.statSync(task.filePath).size > 0;
      }
    } catch (e) {
      void e;
    }
    const keepDir: string = hasPartial && slash > 0
      ? task.filePath.substring(0, slash)
      : targetDir;
    task.ext = ext;
    task.fileName = baseName + '.' + ext;
    task.filePath = keepDir + '/' + task.fileName;

    // 2) 断点：已有文件则续传，否则从头
    let start: number = 0;
    try {
      if (fs.accessSync(task.filePath)) {
        const st = fs.statSync(task.filePath);
        start = st.size;
      }
    } catch (e) {
      void e;
    }

    const req: http.HttpRequest = http.createHttp();
    this.reqs.set(task.id, req);

    let openMode: number = start > 0
      ? (fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND)
      : (fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    let file: fs.File | null = null;
    try {
      file = fs.openSync(task.filePath, openMode);
    } catch (e) {
      // 公共目录可能在个别设备上被系统拒绝写入：自动回落沙箱重建文件，
      // 下载本身不中断（只是回到「需要导出」的旧行为），并记下降级状态供 UI 显示真实位置。
      if (usePublicStorage() && keepDir !== downloadDir()) {
        const fallbackDir: string = downloadDir();
        ensureDir(fallbackDir);
        task.filePath = fallbackDir + '/' + task.fileName;
        start = 0;
        openMode = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC;
        try {
          file = fs.openSync(task.filePath, openMode);
          markPublicUnavailable();
        } catch (e2) {
          void e2;
        }
      }
    }
    if (file === null) {
      task.status = 'error';
      task.statusText = '无法创建文件';
      this.running.delete(task.id);
      this.pump();
      this.reqs.delete(task.id);
      req.destroy();
      this.persist();
      this.notify();
      return;
    }

    let total: number = start;
    let receivedAny: boolean = false;
    let lastSampleBytes: number = start;
    let lastSampleTime: number = Date.now();
    this.speedLastBytes.set(task.id, start);
    this.speedLastTime.set(task.id, lastSampleTime);

    req.on('headerReceive', (header: Object): void => {
      // 有的响应这个回调的结构不是 Record<string,string>（可能是 {header:{...}} 或数组），
      // 直接索引再当字符串用会抛 TypeError。这里只做「尽力解析总大小」，任何异常都不该
      // 影响下载本身（进度回调 dataReceiveProgress 仍会给出 totalSize 兜底）。
      try {
        let rec: Record<string, Object> = header as Record<string, Object>;
        // 兼容 { header: {...} } 包装
        const nested: Object | undefined = rec['header'] as Object | undefined;
        if (nested !== undefined && nested !== null) {
          rec = nested as Record<string, Object>;
        }
        const rawCl: Object | undefined = rec['content-length'] as Object | undefined;
        let rawCr: Object | undefined = rec['content-range'] as Object | undefined;
        // 不同设备/响应头结构里 content-range 的大小写可能不统一；
        // 漏判会把正常的 206 续传误当 200，反而把半段文件清空。这里做一次大小写不敏感兜底。
        if (rawCr === undefined || rawCr === null) {
          for (const k of Object.keys(rec)) {
            if (k.toLowerCase() === 'content-range') {
              rawCr = rec[k];
              break;
            }
          }
        }
        const cl: string = typeof rawCl === 'string' ? rawCl : '';
        const cr: string = typeof rawCr === 'string' ? rawCr : '';

        // 续传(start>0)时文件以 APPEND 打开；但服务端可能忽略 Range 直接回 200 完整文件。
        // 若不加处理，dataReceive 会把整段追加到半段后面，生成损坏音频。
        // headerReceive 先于 dataReceive 触发，这里抢先识别：带 Range 请求却没有 content-range，
        // 说明 Range 未被采纳 —— 关闭 APPEND 句柄、以 TRUNC 重开并把 start 归零；
        // 下面 dataReceive 写的是被重新赋值的 file 变量，因此会写入新的 fd。
        if (start > 0 && cr.length === 0) {
          try {
            if (file !== null) {
              fs.closeSync(file);
            }
            start = 0;
            file = fs.openSync(task.filePath,
              fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
            total = 0;
            lastSampleBytes = 0;
            this.speedLastBytes.set(task.id, 0);
          } catch (e2) {
            void e2;
          }
        }

        if (cr.length > 0) {
          // 形如 bytes 1234-9999/10000
          const slash: number = cr.lastIndexOf('/');
          if (slash >= 0) {
            const full: number = Number(cr.substring(slash + 1));
            if (Number.isFinite(full) && full > 0) {
              total = full;
            }
          }
        } else if (cl.length > 0) {
          const n: number = Number(cl);
          if (Number.isFinite(n) && n > 0) {
            // 尊重 Range 时这是剩余大小；被忽略时 start 已归零，这里就是完整大小
            total = start + n;
          }
        }
      } catch (e) {
        void e;
      }
    });

    req.on('dataReceiveProgress', (info: ProgressInfo): void => {
      task.downloaded = start + info.receiveSize;
      if (total === start && info.totalSize > 0) {
        total = start + info.totalSize;
      }
      task.total = total;
      task.progress = total > 0 ? Math.min(1, task.downloaded / total) : 0;
      const now: number = Date.now();
      const deltaT: number = now - lastSampleTime;
      if (deltaT >= 500) {
        const deltaB: number = task.downloaded - lastSampleBytes;
        const spd: number = deltaB / (deltaT / 1000);
        task.speed = formatSpeed(spd);
        lastSampleBytes = task.downloaded;
        lastSampleTime = now;
      }
      this.notify();
    });

    req.on('dataReceive', (data: ArrayBuffer): void => {
      if (this.aborted.has(task.id)) {
        return;
      }
      receivedAny = true;
      try {
        // data 本身是 ArrayBuffer，直接传；SDK 不接受 Uint8Array
        // 注意：file 是外层变量，headerReceive 若判定 Range 被忽略会把它换成 TRUNC 新句柄，
        // 这里读到的就是新 fd，从而避免把完整文件追加到半段之后。
        fs.writeSync(file!.fd, data);
      } catch (e) {
        void e;
      }
    });

    const headers: Record<string, string> = {};
    if (start > 0) {
      headers['Range'] = 'bytes=' + start.toString() + '-';
    }

    let finishOk: boolean = false;
    try {
      const resp: http.HttpResponse = await req.request(r.url, {
        method: http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 60000,
        readTimeout: 60000,
        usingCache: false,
      });
      const code: number = Number(resp.responseCode);
      // 兜底：headerReceive 可能因响应头结构异常没能识别「Range 被忽略」，
      // 这里凭真实响应码再判一次：200 + start>0 必须以 TRUNC 重写，绝不能追加。
      // 若 headerReceive 已处理过，start 此时已归零，不会重复重开。
      if (code === 200 && start > 0) {
        try {
          if (file !== null) {
            fs.closeSync(file);
          }
          start = 0;
          file = fs.openSync(task.filePath,
            fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        } catch (e2) {
          void e2;
        }
      }
      finishOk = code >= 200 && code < 300;
      if (finishOk) {
        // 仅在 dataReceive 未触发（极小文件）时，才兜底写入 result
        if (!receivedAny && resp.result instanceof ArrayBuffer) {
          try {
            fs.writeSync(file!.fd, resp.result as ArrayBuffer);
          } catch (e) {
            void e;
          }
        }
      }
    } catch (e) {
      if (this.aborted.has(task.id)) {
        // 用户暂停/取消，正常结束
        finishOk = false;
      } else {
        const err = e as Error;
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'download error: %{public}s', err.message);
        task.status = 'error';
        task.statusText = '下载失败：' + err.message;
        userNotice().error('「' + task.musicInfo.name + '」下载失败：' + err.message);
      }
    } finally {
      try {
        if (file !== null) {
          fs.closeSync(file);
        }
      } catch (e) {
        void e;
      }
      req.destroy();
      this.reqs.delete(task.id);
    }

    this.running.delete(task.id);
    this.speedLastBytes.delete(task.id);
    this.speedLastTime.delete(task.id);

    if (this.aborted.has(task.id)) {
      this.aborted.delete(task.id);
      if (task.status !== 'canceled') {
        task.status = 'paused';
        task.statusText = '已暂停';
      }
      task.speed = '';
      // 暂停时还没写进任何数据（取链阶段就停了）：删掉空文件，别在公共目录留残骸
      this.dropIfEmpty(task.filePath);
      this.persist();
      this.notify();
      this.pump();
      return;
    }

    if (finishOk) {
      task.status = 'completed';
      task.statusText = '已完成';
      task.isComplate = true;
      // 有的 CDN 响应不带 content-length、dataReceiveProgress 也不给 totalSize，
      // 导致进度全程 0（UI 显示 0B/0B）。下载完成后按真实文件大小回填，保证显示正确。
      try {
        const realSize: number = fs.statSync(task.filePath).size;
        if (realSize > 0) {
          task.downloaded = realSize;
          task.total = realSize;
        }
      } catch (e) {
        void e;
      }
      if (task.total <= 0) {
        task.total = task.downloaded;
      }
      task.progress = 1;
      task.speed = '';
      // 写侧车元数据 + 进下载列表
      writeMeta(task);
      const local: MusicInfo = toLocalMusicInfo(task.musicInfo, task.quality, task.filePath, task.ext);
      ListManager.getInstance().addListMusics(ListIds.DOWNLOAD, [local], false);
      // 封面写到音频旁边（与音频同名 jpg）：本地音乐扫描时就能直接当封面用，
      // 不阻塞完成提示，失败也不影响下载
      // 下载完成给一条明确提示（此前只有界面状态变化，用户察觉不到）
      userNotice().info('「' + task.musicInfo.name + '」' + I18n().t('download_done'));
      hilog.info(LOG_DOMAIN, LOG_TAG, 'download done: %{public}s', task.fileName);
    } else if (task.status !== 'error') {
      task.status = 'error';
      task.statusText = task.statusText.length > 0 ? task.statusText : '下载失败';
    }
    if (task.status === 'error') {
      // 一个字节都没写进去（403 / 取链直链失效 / 连接中断）：删掉空文件，
      // 避免公共目录里堆空 mp3、本地音乐识别不出这些「歌」
      this.dropIfEmpty(task.filePath);
    }
    task.speed = '';
    this.persist();
    this.notify();
    this.pump();
  }

  /**
   * 下载失败/暂停后若文件仍是 0 字节，直接删掉。
   * 否则公共目录里会堆一堆空 mp3：本地音乐按「0 字节=坏文件」跳过它们，
   * 用户看到的就是「下载过的歌识别不出来」；留 0 字节也没有任何断点续传价值。
   */
  private dropIfEmpty(path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      if (fs.accessSync(path) && fs.statSync(path).size === 0) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      void e;
    }
  }


  pause(id: string): void {
    const t = this.find(id);
    if (t === undefined || t.status !== 'downloading') {
      return;
    }
    this.aborted.add(id);
    const req = this.reqs.get(id);
    if (req !== undefined) {
      try {
        req.destroy();
      } catch (e) {
        void e;
      }
    }
    // 取链阶段没有 HTTP 请求可 destroy：必须立刻把状态改成 paused 并刷新 UI，
    // 否则点「暂停」毫无反应（按钮也不切换成「继续」）。
    t.status = 'paused';
    t.statusText = '已暂停';
    t.speed = '';
    this.persist();
    this.notify();
  }

  resume(id: string): void {
    const t = this.find(id);
    if (t === undefined) {
      return;
    }
    if (t.status === 'completed' || t.status === 'downloading') {
      return;
    }
    t.status = 'waiting';
    t.statusText = '排队中';
    this.notify();
    this.enqueueTask(t.id);
  }

  retry(id: string): void {
    // 失败重试：删除旧文件从头来
    const t = this.find(id);
    if (t === undefined) {
      return;
    }
    try {
      if (fs.accessSync(t.filePath)) {
        fs.unlinkSync(t.filePath);
      }
    } catch (e) {
      void e;
    }
    t.downloaded = 0;
    t.total = 0;
    t.progress = 0;
    this.resume(id);
  }

  cancel(id: string): void {
    const t = this.find(id);
    if (t === undefined) {
      return;
    }
    this.aborted.add(id);
    const req = this.reqs.get(id);
    if (req !== undefined) {
      try {
        req.destroy();
      } catch (e) {
        void e;
      }
    }
    this.deleteTaskFile(t);
    this.tasks = this.tasks.filter((x: DownloadListItem): boolean => x.id !== id);
    // 取消取链中的任务时没有 HTTP 请求会自然收尾，必须主动释放并发闸门，
    // 否则 running 一直占着 MAX_CONCURRENT 名额，后面排队的任务全部卡死。
    this.running.delete(id);
    this.speedLastBytes.delete(id);
    this.speedLastTime.delete(id);
    this.persist();
    this.notify();
    this.pump();
  }

  remove(id: string): void {
    // 仅从列表移除任务记录，保留已下载文件
    this.tasks = this.tasks.filter((x: DownloadListItem): boolean => x.id !== id);
    this.persist();
    this.notify();
  }

/** 删掉任务对应的音频文件与元数据侧车（公共目录 / 沙箱都适用） */
  private deleteTaskFile(t: DownloadListItem): void {
    try {
      if (fs.accessSync(t.filePath)) {
        fs.unlinkSync(t.filePath);
      }
    } catch (e) {
      void e;
    }
    // 本地封面存在封面缓存里（按文件路径索引），歌删了要一起删，
    // 否则以后同名文件重新下载会直接命中旧歌的封面
    CoverCache.getInstance().dropLocal(t.filePath);
    try {
      const meta: string = t.filePath + '.meta.json';
      if (fs.accessSync(meta)) {
        fs.unlinkSync(meta);
      }
      const alt: string = rootDir() + '/meta/' + safeName(t.id) + '.json';
      if (fs.accessSync(alt)) {
        fs.unlinkSync(alt);
      }
    } catch (e) {
      void e;
    }
  }

  /**
   * 批量移除：withFile=false 只删任务记录（保留文件），true 连文件一起删。
   * 供下载管理页「多选 → 更多」使用，一次落盘一次刷新，避免逐条闪屏。
   */
  batchRemove(ids: string[], withFile: boolean): void {
    const set: Set<string> = new Set<string>(ids);
    if (withFile) {
      for (const t of this.tasks.slice()) {
        if (set.has(t.id)) {
          this.deleteTaskFile(t);
        }
      }
    }
    this.tasks = this.tasks.filter((t: DownloadListItem): boolean => !set.has(t.id));
    this.persist();
    this.notify();
    this.pump();
  }

  /** 批量取消：中断进行中的请求、清半成品文件、释放并发名额，并移除任务 */
  batchCancel(ids: string[]): void {
    const set: Set<string> = new Set<string>(ids);
    for (const t of this.tasks.slice()) {
      if (!set.has(t.id)) {
        continue;
      }
      this.aborted.add(t.id);
      const req = this.reqs.get(t.id);
      if (req !== undefined) {
        try {
          req.destroy();
        } catch (e) {
          void e;
        }
        this.reqs.delete(t.id);
      }
      this.deleteTaskFile(t);
      this.running.delete(t.id);
      this.speedLastBytes.delete(t.id);
      this.speedLastTime.delete(t.id);
      this.aborted.delete(t.id);
    }
    this.waitingQueue = this.waitingQueue.filter((x: string): boolean => !set.has(x));
    this.tasks = this.tasks.filter((t: DownloadListItem): boolean => !set.has(t.id));
    this.persist();
    this.notify();
    this.pump();
  }

  clearCompleted(): void {
    this.tasks = this.tasks.filter((t: DownloadListItem): boolean => t.status !== 'completed');
    this.persist();
    this.notify();
  }

  private find(id: string): DownloadListItem | undefined {
    return this.tasks.find((t: DownloadListItem): boolean => t.id === id);
  }

  /** 持久化任务清单（恒在根目录，不受「保存位置」设置影响） */
  private persist(): void {
    const dir: string = rootDir();
    if (dir.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      const arr: Object[] = this.tasks.map((t: DownloadListItem): Object => serializeTask(t));
      const text: string = JSON.stringify(arr);
      const p: string = dir + '/' + TASKS_FILE;
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      // SDK: writeSync(fd, buffer: ArrayBuffer | string)，传 Uint8Array 会抛 Invalid argument
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'download persist failed: %{public}s', (e as Error).message);
    }
  }
}

function formatSpeed(bytesPerSec: number): string {
  if (bytesPerSec >= 1024 * 1024) {
    return (bytesPerSec / (1024 * 1024)).toFixed(1) + ' MB/s';
  }
  if (bytesPerSec >= 1024) {
    return (bytesPerSec / 1024).toFixed(0) + ' KB/s';
  }
  return bytesPerSec.toFixed(0) + ' B/s';
}

/** 写侧车：<file>.meta.json 保存本地 MusicInfo，供本地扫描与下载列表还原 */
function writeMeta(task: DownloadListItem): void {
    try {
      const local: MusicInfo = toLocalMusicInfo(task.musicInfo, task.quality, task.filePath, task.ext);
      const text: string = JSON.stringify(local);
      // 公共「下载」目录是用户可见的，别在里面留 .meta.json 垃圾：侧车统一放沙箱 meta/
      let p: string = task.filePath + '.meta.json';
      if (isPublicStored(task.filePath)) {
        const dir: string = rootDir() + '/meta';
        ensureDir(dir);
        p = dir + '/' + safeName(task.id) + '.json';
      }
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(f.fd, new Uint8Array(new util.TextEncoder().encodeInto(text)));
    fs.closeSync(f);
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'writeMeta failed: %{public}s', (e as Error).message);
  }
}

/** 供 UI 复用：把字节数格式化为 MB */
export function formatBytes(n: number): string {
  if (n >= 1024 * 1024) {
    return (n / (1024 * 1024)).toFixed(1) + ' MB';
  }
  if (n >= 1024) {
    return (n / 1024).toFixed(0) + ' KB';
  }
  return n.toString() + ' B';
}
