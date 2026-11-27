/**
 * 本地歌曲时长 —— 给本地音乐列表补上「03:45」这种时长。
 *
 * 内嵌标签（ID3v1/v2、FLAC、M4A）里通常不带时长，只有码率/采样率；
 * 因此用系统 MediaKit 的 AVMetadataExtractor 读文件真实时长（毫秒），
 * 再格式化成列表用的 mm:ss。**纯本地文件读取，零网络请求。**
 *
 * 扫描一次要读几十个文件，重复扫描会很浪费，所以按「路径 + 文件大小」做磁盘缓存
 * （沙箱 filesDir/local_durations.json）：文件没变就直接用缓存，改了大小才重读。
 */
import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getAppContext } from '../common/AppContext';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { MusicInfo, MusicInfoMetaLocal } from '../model/MusicTypes';

const CACHE_FILE: string = '/local_durations.json';
/** 同时读取的提取器数量：太高会抢 IO，太低大目录会慢 */
const CONCURRENCY: number = 4;

interface DurationEntry {
  /** 文件大小，用来判断文件是否换了 */
  s: number;
  /** 已格式化好的时长文本，空串表示读不出来 */
  d: string;
}

let cacheLoaded: boolean = false;
let cacheDirty: boolean = false;
const durCache: Map<string, DurationEntry> = new Map<string, DurationEntry>();

function cachePath(): string {
  const ctx = getAppContext();
  if (ctx === null) {
    return '';
  }
  return ctx.filesDir + CACHE_FILE;
}

function loadCache(): void {
  if (cacheLoaded) {
    return;
  }
  cacheLoaded = true;
  const p: string = cachePath();
  if (p.length === 0 || !fs.accessSync(p)) {
    return;
  }
  try {
    const text: string = fs.readTextSync(p);
    const obj = JSON.parse(text) as Object;
    const rec: Record<string, Object> = obj as Record<string, Object>;
    Object.keys(rec).forEach((k: string): void => {
      const raw = rec[k] as Record<string, Object>;
      if (raw === undefined || raw === null) {
        return;
      }
      const s: Object = raw['s'];
      const d: Object = raw['d'];
      if (typeof s === 'number' && typeof d === 'string') {
        durCache.set(k, { s: s as number, d: d as string });
      }
    });
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'local duration cache read failed');
  }
}

function saveCache(): void {
  if (!cacheDirty) {
    return;
  }
  const p: string = cachePath();
  if (p.length === 0) {
    return;
  }
  try {
    const obj: Record<string, DurationEntry> = {};
    durCache.forEach((v: DurationEntry, k: string): void => {
      obj[k] = v;
    });
    const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      // SDK: writeSync 只接受 ArrayBuffer | string，传 Uint8Array 会抛 Invalid argument
      fs.writeSync(f.fd, JSON.stringify(obj));
    } finally {
      fs.closeSync(f);
    }
    cacheDirty = false;
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'local duration cache write failed');
  }
}

/** 毫秒 → 列表显示文本（3:07 / 12:45 / 1:02:03） */
export function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) {
    return '';
  }
  const total: number = Math.round(ms / 1000);
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: number = total % 60;
  const ss: string = s < 10 ? '0' + s.toString() : s.toString();
  if (h > 0) {
    const mm: string = m < 10 ? '0' + m.toString() : m.toString();
    return h.toString() + ':' + mm + ':' + ss;
  }
  return m.toString() + ':' + ss;
}

/** 用系统元数据提取器读单个文件的时长文本；失败返回空串 */
async function extractOne(path: string): Promise<string> {
  let file: fs.File | null = null;
  let extractor: media.AVMetadataExtractor | null = null;
  try {
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    extractor = await media.createAVMetadataExtractor();
    const fdSrc: media.AVFileDescriptor = { fd: file.fd };
    extractor.fdSrc = fdSrc;
    const meta: media.AVMetadata = await extractor.fetchMetadata();
    const raw: string = meta.duration !== undefined ? meta.duration : '';
    const ms: number = Number(raw);
    return formatDuration(ms);
  } catch (e) {
    // 个别容器系统解不出来：留空，列表继续显示 --:--
    return '';
  } finally {
    if (extractor !== null) {
      try {
        await extractor.release();
      } catch (e) {
        void e;
      }
    }
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (e) {
        void e;
      }
    }
  }
}

/**
 * 给一批本地歌曲补时长（原地写 info.interval）。
 * 命中缓存（路径存在且大小一致）直接填，没命中的并发读，读完落一次缓存。
 */
export async function fillLocalDurations(infos: MusicInfo[]): Promise<void> {
  loadCache();
  const todo: MusicInfo[] = [];
  for (const m of infos) {
    if (m.interval !== null && m.interval.length > 0) {
      continue;
    }
    const lm = m.meta as MusicInfoMetaLocal;
    const path: string = lm.filePath;
    if (path.length === 0) {
      continue;
    }
    let size: number = -1;
    try {
      size = fs.statSync(path).size;
    } catch (e) {
      continue;
    }
    const hit: DurationEntry | undefined = durCache.get(path);
    if (hit !== undefined && hit.s === size) {
      if (hit.d.length > 0) {
        m.interval = hit.d;
      }
      continue;
    }
    todo.push(m);
  }
  if (todo.length === 0) {
    saveCache();
    return;
  }
  // 简易并发池：4 个提取器同时读，读完一个补一个
  let next: number = 0;
  const worker = async (): Promise<void> => {
    while (next < todo.length) {
      const m: MusicInfo = todo[next];
      next++;
      const lm = m.meta as MusicInfoMetaLocal;
      const path: string = lm.filePath;
      const text: string = await extractOne(path);
      let size: number = -1;
      try {
        size = fs.statSync(path).size;
      } catch (e) {
        size = -1;
      }
      if (text.length > 0) {
        m.interval = text;
      }
      if (size >= 0) {
        durCache.set(path, { s: size, d: text });
        cacheDirty = true;
      }
    }
  };
  const workers: Promise<void>[] = [];
  const n: number = Math.min(CONCURRENCY, todo.length);
  for (let i = 0; i < n; i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  saveCache();
}

/** 清掉时长缓存（换文件 / 排查问题时用） */
export function clearDurationCache(): void {
  durCache.clear();
  cacheLoaded = true;
  cacheDirty = true;
  saveCache();
}
