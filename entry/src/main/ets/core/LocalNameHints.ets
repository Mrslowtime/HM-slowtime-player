/**
 * 本地音乐「歌名 / 歌手」判定提示 —— 全部来自本地数据，零网络请求。
 *
 * 背景：文件名既可能是「歌名 - 歌手」（本应用下载格式），也可能是「歌手 - 歌名」
 * （用户从别处导入的曲库）。只靠文件名顺序猜测会把本来就正确的内嵌标签翻反。
 * 这里提供两类可靠的本地证据：
 *   1) 同目录同名 .lrc 歌词头部的 [ti:] / [ar:]；
 *   2) 歌单 / 下载列表里已知歌手与歌名（这些是联网搜索时已确认过的信息）。
 *
 * 证据只在能明确指向文件名某一段时才生效；模棱两可时返回空串，由调用方保守处理。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { normalizeKey } from './LocalTags';
import { ListManager } from './ListManager';
import { MusicInfo } from '../model/MusicTypes';

/** 歌单里已知的歌手 / 歌名集合（已归一化比较键） */
export interface NameHints {
  singers: Set<string>;
  names: Set<string>;
}

/** 文件名两段样本（仅用于目录级顺序统计） */
export interface DirNameSample {
  left: string;
  right: string;
}

/**
 * 目录级顺序统计 —— 纯本地、零网络请求。
 *
 * 为什么需要：用户曲库里大量文件**没有内嵌标签**，文件名既可能是「歌名 - 歌手」
 * 也可能是「歌手 - 歌名」。没有任何证据时只能猜，猜错就是整批显示反了。
 *
 * 但同一文件夹里有个稳定规律：
 *   - 歌手会重复（同一歌手 / 同一张专辑的多首歌），不同歌手数远少于不同歌名数；
 *   - 歌名几乎不重复。
 * 所以比较「左段不同值数量」与「右段不同值数量」，差异足够大时就能确定哪边是歌手。
 *
 * 混合命名的目录两边数量接近 → 返回空串，不猜（交给标签 / 单曲证据）。
 */
export function detectDirOrder(samples: DirNameSample[]): string {
  if (samples.length < 4) {
    return '';
  }
  const lefts: Set<string> = new Set<string>();
  const rights: Set<string> = new Set<string>();
  for (const s of samples) {
    const l: string = normalizeKey(s.left);
    const r: string = normalizeKey(s.right);
    if (l.length === 0 || r.length === 0 || l === r) {
      continue;
    }
    lefts.add(l);
    rights.add(r);
  }
  const nl: number = lefts.size;
  const nr: number = rights.size;
  if (nl === 0 || nr === 0) {
    return '';
  }
  // 歌手数量明显少于歌名数量（同一歌手多首、歌名几乎一首一个）。
  // 只比比例与绝对差：混合命名的目录两边接近，会自然落到空串（不猜）。
  if (nl * 2 <= nr && nr - nl >= 4) {
    return 'left';
  }
  if (nr * 2 <= nl && nl - nr >= 4) {
    return 'right';
  }
  return '';
}

/** 歌词文件头部元数据 */
export interface LrcMeta {
  title: string;
  artist: string;
}

/** 从所有歌单 + 下载列表收集已知歌手/歌名，用于反推文件名字段顺序 */
export function collectNameHints(): NameHints {
  const singers: Set<string> = new Set<string>();
  const names: Set<string> = new Set<string>();
  try {
    const all: Map<string, MusicInfo[]> = ListManager.getInstance().exportAll();
    all.forEach((list: MusicInfo[]): void => {
      for (const m of list) {
        if (m.singer.length > 0) {
          singers.add(normalizeKey(m.singer));
        }
        if (m.name.length > 0) {
          names.add(normalizeKey(m.name));
        }
      }
    });
  } catch (e) {
    // 歌单尚未初始化：不影响扫描，交给歌词/目录统计
    void e;
  }
  return { singers: singers, names: names };
}

/** 歌词里哪一边的段是歌手：'left' / 'right' / ''（证据不足） */
export function orderFromLrc(left: string, right: string, meta: LrcMeta): string {
  const l: string = normalizeKey(left);
  const r: string = normalizeKey(right);
  if (l.length === 0 || r.length === 0 || l === r) {
    return '';
  }
  const ar: string = normalizeKey(meta.artist);
  if (ar.length > 0) {
    if (ar === l) {
      return 'left';
    }
    if (ar === r) {
      return 'right';
    }
  }
  const ti: string = normalizeKey(meta.title);
  if (ti.length > 0) {
    if (ti === l) {
      return 'right';
    }
    if (ti === r) {
      return 'left';
    }
  }
  return '';
}

/** 歌单已知信息判定：只有一段像歌手、另一段不像时才采信 */
export function orderFromHints(left: string, right: string, hints: NameHints): string {
  const l: string = normalizeKey(left);
  const r: string = normalizeKey(right);
  if (l.length === 0 || r.length === 0 || l === r) {
    return '';
  }
  const leftIsSinger: boolean = hints.singers.has(l);
  const rightIsSinger: boolean = hints.singers.has(r);
  if (leftIsSinger && !rightIsSinger) {
    return 'left';
  }
  if (rightIsSinger && !leftIsSinger) {
    return 'right';
  }
  return '';
}

/** 读同目录同名 .lrc 的头部元数据（只读前 4 KiB，不解析时间轴） */
export function readLrcMeta(path: string): LrcMeta {
  const out: LrcMeta = { title: '', artist: '' };
  try {
    if (!fs.accessSync(path)) {
      return out;
    }
    const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const size: number = fs.statSync(path).size;
    const len: number = Math.min(size, 4096);
    const buf = new ArrayBuffer(len);
    fs.readSync(f.fd, buf, { offset: 0, length: len });
    fs.closeSync(f);
    let text: string = new util.TextDecoder().decodeToString(new Uint8Array(buf));
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1);
    }
    const lines: string[] = text.split(/\r?\n/);
    for (const line of lines) {
      const s: string = line.trim();
      if (s.startsWith('[ti:') || s.startsWith('[TI:')) {
        const end: number = s.indexOf(']', 4);
        if (end > 4 && out.title.length === 0) {
          out.title = s.substring(4, end).trim();
        }
      } else if (s.startsWith('[ar:') || s.startsWith('[AR:')) {
        const end: number = s.indexOf(']', 4);
        if (end > 4 && out.artist.length === 0) {
          out.artist = s.substring(4, end).trim();
        }
      }
      if (out.title.length > 0 && out.artist.length > 0) {
        break;
      }
    }
  } catch (e) {
    void e;
  }
  return out;
}
