/**
 * 本地音频「内嵌标签」读取 + 歌名/歌手互换识别。
 *
 * 扫描本地文件时（LocalMusicScanner）按下面的顺序取元数据：
 *   1) 同名 `.meta.json` 侧车（本应用下载时写入，最准）
 *   2) 音频文件内嵌标签（本模块）：MP3 的 ID3v2.2/2.3/2.4 与 ID3v1、
 *      FLAC 的 VORBIS_COMMENT、M4A/MP4 的 ilst（©nam / ©ART / ©alb）
 *   3) 文件名「歌名 - 歌手」
 *
 * 另外解决「标签里歌名和歌手填反」的问题（用户 2026-11-16 反馈）：
 *   · 强判据：文件名写了「歌名 - 歌手」，而标签里 TIT2=文件名里的歌手、TPE1=文件名里的歌名
 *     → 明确填反，直接换回来（verified=true，后续不再参与猜测）；
 *   · 弱判据（同目录统计）：同一目录里 ≥3 首歌的「歌名」完全相同、而「歌手」各不相同，
 *     说明该字段其实是歌手 → 整批换回来（只在没有强判据时使用，避免误伤）。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/** 内嵌标签（缺失项为空字符串） */
export interface LocalTags {
  title: string;
  artist: string;
  album: string;
}

/** 文件名解析结果 */
export interface FileNameParts {
  name: string;
  singer: string;
  hasSeparator: boolean;
}

/** 歌名/歌手最终结果 */
export interface NamePair {
  name: string;
  singer: string;
  /** true 表示已用本地证据（歌词/歌单/文件名）交叉校验过，不再参与目录级猜测 */
  verified: boolean;
  /** true 表示内嵌标签的歌名/歌手填反，已纠正；调用方应写入 override 侧车持久化 */
  corrected: boolean;
}

const UNKNOWN_SINGER: string = '未知歌手';
/** 目录级判断的最小样本量 */
const SWAP_MIN_SONGS: number = 3;
const UNKNOWN_SONG: string = '未知歌曲';

/** 这些是「格式噪声」，逐个剥掉后再比较，避免全角空格/引号导致判不出来 */
function stripDecor(raw: string): string {
  let s: string = raw;
  s = s.split('\u0000').join('');
  s = s.trim();
  // 去掉首部音轨号：01. / 01 - / 01_ （≤3 位数字）
  const m = s.match(/^\d{1,3}[.\-_）)\s]+/);
  if (m !== null && m[0].length < s.length) {
    s = s.substring(m[0].length).trim();
  }
  // 去掉首尾引号
  while (s.length > 1 && (s.startsWith('"') || s.startsWith('“') || s.startsWith('「'))) {
    s = s.substring(1).trim();
  }
  while (s.length > 1 && (s.endsWith('"') || s.endsWith('”') || s.endsWith('」'))) {
    s = s.substring(0, s.length - 1).trim();
  }
  return s;
}

/** 归一化比较键：忽略大小写、空白、常见标点差异 */
export function normalizeKey(raw: string): string {
  let s: string = stripDecor(raw).toLowerCase();
  const junk: string[] = [' ', '\u3000', '\t', '·', '・', '.', '。', '，', ',', '、', '(', ')', '（', '）',
    '[', ']', '【', '】', '-', '－', '_', '《', '》', '〈', '〉', '\'', '’'];
  for (const j of junk) {
    s = s.split(j).join('');
  }
  return s;
}

/**
 * 文件名 → 左段 + 右段（字段名沿用 name/singer，但**不代表语义**）。
 *
 * 哪一侧是歌名、哪一侧是歌手，由调用方根据证据决定（歌词头 / 歌单 / 目录统计），
 * 都没有证据时才按「左歌手、右歌名」兜底。
 * 只认明确的分隔形式（「 - 」「_」「－」等），不会把 "A-Lin" 这类名字从连字符处劈开。
 */
export function parseLocalFileName(base: string): FileNameParts {
  const s: string = stripDecor(base);
  // 带空格的破折号最可靠，优先
  const spaced: string[] = [' - ', ' – ', ' — ', '  -  '];
  for (const sep of spaced) {
    const idx: number = s.indexOf(sep);
    if (idx > 0) {
      const left: string = s.substring(0, idx).trim();
      const right: string = s.substring(idx + sep.length).trim();
      if (left.length > 0 && right.length > 0) {
        return { name: left, singer: right, hasSeparator: true };
      }
    }
  }
  const single: string[] = ['－', '_'];
  for (const sep of single) {
    const idx: number = s.indexOf(sep);
    if (idx > 0) {
      const left: string = s.substring(0, idx).trim();
      const right: string = s.substring(idx + sep.length).trim();
      if (left.length > 0 && right.length > 0) {
        return { name: left, singer: right, hasSeparator: true };
      }
    }
  }
  // 裸连字符：取最后一个，且两侧都要 ≥2 字符（保护 "A-Lin"、"C-BLOCK" 这类名字）
  const dash: number = s.lastIndexOf('-');
  if (dash > 0 && dash < s.length - 1) {
    const left: string = s.substring(0, dash).trim();
    const right: string = s.substring(dash + 1).trim();
    if (left.length >= 2 && right.length >= 2) {
      return { name: left, singer: right, hasSeparator: true };
    }
  }
  return { name: s, singer: '', hasSeparator: false };
}

/**
 * 合并「标签字段」与「文件名」，并在发现填反时换回来。
 * title/artist 为内嵌标签值（可为空），fn 为文件名解析结果。
 */
export function resolveNameAndSinger(title: string, artist: string, fn: FileNameParts,
  hintSinger: string = '', hintName: string = '', weakHint: boolean = false): NamePair {
  let name: string = stripDecor(title);
  let singer: string = stripDecor(artist);
  let verified: boolean = false;
  let corrected: boolean = false;
  // 文件名只提供左右两段，绝不预设「左歌名右歌手」——用户曲库里两种顺序都有，
  // 写死顺序会把本来就正确的内嵌标签翻反（2026-11-21 反馈的根因）。
  const left: string = stripDecor(fn.name);
  const right: string = stripDecor(fn.singer);
  const hasFn: boolean = fn.hasSeparator && left.length > 0 && right.length > 0;

  // 哪一段是歌手，只能由本地证据决定：同目录歌词 [ar:]/[ti:] 或歌单里已知歌手。
  let order: string = '';
  const hs: string = normalizeKey(hintSinger);
  if (hs.length > 0) {
    if (hs === normalizeKey(left)) {
      order = 'left';
    } else if (hs === normalizeKey(right)) {
      order = 'right';
    }
  }
  if (order.length === 0 && hintName.length > 0) {
    const hn: string = normalizeKey(hintName);
    if (hn === normalizeKey(left)) {
      order = 'right';
    } else if (hn === normalizeKey(right)) {
      order = 'left';
    }
  }

  if (hasFn && order.length > 0) {
    const fnName: string = order === 'left' ? right : left;
    const fnSinger: string = order === 'left' ? left : right;
    if (weakHint) {
      /**
       * 目录统计只是「猜测」（歌手名重复度），不是逐首确认过的证据。
       * 标签里已经有的字段一律不动 —— 猜错了会把本来正确的歌翻反；
       * 只在某一侧为空（大量无标签文件就是这样）时用它补上。
       */
      if (normalizeKey(name).length === 0) {
        name = fnName;
      }
      if (normalizeKey(singer).length === 0) {
        singer = fnSinger;
      }
      verified = false;
    } else {
    const tn: string = normalizeKey(name);
    const an: string = normalizeKey(singer);
    const fnN: string = normalizeKey(fnName);
    const fnS: string = normalizeKey(fnSinger);
    const titleIsName: boolean = tn.length > 0 && tn === fnN;
    const titleIsSinger: boolean = tn.length > 0 && tn === fnS;
    const artistIsSinger: boolean = an.length > 0 && an === fnS;
    const artistIsName: boolean = an.length > 0 && an === fnN;
    if (titleIsName && artistIsSinger) {
      // 标签与证据一致：保留标签原文（可能带 Live / 版本后缀）
    } else if (titleIsSinger && artistIsName) {
      // 明确填反：交换两字段
      const tmp: string = name;
      name = singer;
      singer = tmp;
      corrected = true;
    } else {
      // 标签与证据冲突或只有一侧匹配：以被证据确认的文件名为准
      name = fnName;
      singer = fnSinger;
      corrected = tn.length > 0 || an.length > 0;
    }
    verified = true;
    }
  } else if (!hasFn && hs.length > 0) {
    // 文件名没有分隔时：靠歌词/歌单直接判断标签本身是否填反
    const hn: string = normalizeKey(hintName);
    const tn: string = normalizeKey(name);
    const an: string = normalizeKey(singer);
    const titleIsSinger: boolean = hs === tn;
    const artistIsName: boolean = hn.length > 0 && hn === an;
    if (titleIsSinger && (hn.length === 0 || artistIsName)) {
      const tmp: string = name;
      name = singer;
      singer = tmp;
      corrected = true;
      verified = true;
    }
  }

  // 空项用文件名兜底。没有任何证据时默认 **左段是歌手、右段是歌名**
  // （本应用下载命名与用户曲库的主格式；2026-11-22 用户明确要求按此兜底）。
  // 文件名没有分隔符时只有歌名可用，歌手留空。
  if (name.length === 0) {
    name = hasFn ? right : left;
  }
  if (singer.length === 0 && hasFn) {
    singer = left;
  }

  if (name.length === 0) {
    name = UNKNOWN_SONG;
  }
  if (singer.length === 0) {
    singer = UNKNOWN_SINGER;
  }
  // 两边完全一样（标签只填了同一个值）：歌名保留，歌手位空着没意义，等同于未填
  if (singer !== UNKNOWN_SINGER && normalizeKey(name) === normalizeKey(singer)) {
    singer = UNKNOWN_SINGER;
  }
  return { name: name, singer: singer, verified: verified, corrected: corrected };
}

/** 目录级判断用的一行数据（就地改写） */
export interface NameEntry {
  name: string;
  singer: string;
  verified: boolean;
}

/**
 * 目录级兜底：同一文件夹里 ≥3 首歌的「歌名」完全相同、而「歌手」各不相同，
 * 说明标签把歌手写进了歌名位（正常曲库只会「歌手恒定、歌名各异」）。
 * 只改动没被文件名交叉校验过的项。返回是否有改动。
 */
export function fixSwappedBatch(entries: NameEntry[]): boolean {
  if (entries.length < SWAP_MIN_SONGS) {
    return false;
  }
  const groups: Map<string, NameEntry[]> = new Map();
  for (const e of entries) {
    const k: string = normalizeKey(e.name);
    if (k.length === 0) {
      continue;
    }
    const arr: NameEntry[] | undefined = groups.get(k);
    if (arr === undefined) {
      groups.set(k, [e]);
    } else {
      arr.push(e);
    }
  }
  let changed: boolean = false;
  groups.forEach((arr: NameEntry[], _k: string): void => {
    if (arr.length < SWAP_MIN_SONGS) {
      return;
    }
    const singers: Set<string> = new Set<string>();
    for (const e of arr) {
      singers.add(normalizeKey(e.singer));
    }
    // 歌名相同但歌手必须互不相同，才认为是填反（否则就是同一歌手的多版本）
    if (singers.size < Math.max(2, Math.ceil(arr.length * 0.8))) {
      return;
    }
    for (const e of arr) {
      if (e.verified) {
        continue;
      }
      const t: string = e.name;
      e.name = e.singer;
      e.singer = t;
      e.verified = true;
      changed = true;
    }
  });
  return changed;
}

/* ------------------------------ 字节工具 ------------------------------ */

function u32be(b: Uint8Array, i: number): number {
  return ((b[i] & 0xFF) * 16777216) + ((b[i + 1] & 0xFF) << 16) + ((b[i + 2] & 0xFF) << 8) + (b[i + 3] & 0xFF);
}

function u32le(b: Uint8Array, i: number): number {
  return (b[i] & 0xFF) + ((b[i + 1] & 0xFF) << 8) + ((b[i + 2] & 0xFF) << 16) + ((b[i + 3] & 0xFF) * 16777216);
}

/** ID3v2 的「synchsafe」长度（每字节只用低 7 位） */
function synchsafe(b: Uint8Array, i: number): number {
  return ((b[i] & 0x7F) << 21) | ((b[i + 1] & 0x7F) << 14) | ((b[i + 2] & 0x7F) << 7) | (b[i + 3] & 0x7F);
}

function decodeLatin1(b: Uint8Array, s: number, e: number): string {
  let out: string = '';
  for (let i = s; i < e; i++) {
    const c: number = b[i];
    if (c === 0) {
      break;
    }
    out += String.fromCharCode(c);
  }
  return out;
}

function decodeUtf16(b: Uint8Array, s: number, e: number, bigEndian: boolean): string {
  let out: string = '';
  for (let i = s; i + 1 < e; i += 2) {
    const code: number = bigEndian
      ? ((b[i] & 0xFF) << 8) | (b[i + 1] & 0xFF)
      : (b[i] & 0xFF) | ((b[i + 1] & 0xFF) << 8);
    if (code === 0) {
      break;
    }
    out += String.fromCharCode(code);
  }
  return out;
}

function decodeUtf8(b: Uint8Array, s: number, e: number): string {
  let end: number = e;
  while (end > s && b[end - 1] === 0) {
    end--;
  }
  if (end <= s) {
    return '';
  }
  try {
    return new util.TextDecoder('utf-8').decodeToString(b.subarray(s, end));
  } catch (err) {
    return decodeLatin1(b, s, end);
  }
}

/** ID3 文本帧编码字节 → 字符串（0=Latin1 1=UTF16+BOM 2=UTF16BE 3=UTF8） */
function decodeTextFrame(enc: number, b: Uint8Array, s: number, e: number): string {
  if (enc === 1) {
    if (s + 1 < e && b[s] === 0xFF && b[s + 1] === 0xFE) {
      return decodeUtf16(b, s + 2, e, false);
    }
    if (s + 1 < e && b[s] === 0xFE && b[s + 1] === 0xFF) {
      return decodeUtf16(b, s + 2, e, true);
    }
    return decodeUtf16(b, s, e, false);
  }
  if (enc === 2) {
    return decodeUtf16(b, s, e, true);
  }
  if (enc === 3) {
    return decodeUtf8(b, s, e);
  }
  return decodeLatin1(b, s, e);
}

/* ------------------------------ 文件读取 ------------------------------ */

function readHead(path: string, maxLen: number): Uint8Array | null {
  try {
    const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const st = fs.statSync(path);
    const len: number = Math.min(st.size, maxLen);
    const buf = new ArrayBuffer(len);
    const n: number = fs.readSync(f.fd, buf, { offset: 0, length: len });
    fs.closeSync(f);
    return new Uint8Array(buf, 0, n);
  } catch (e) {
    return null;
  }
}

function readTail(path: string, maxLen: number): Uint8Array | null {
  try {
    const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const st = fs.statSync(path);
    const len: number = Math.min(st.size, maxLen);
    const start: number = st.size - len;
    const buf = new ArrayBuffer(len);
    const n: number = fs.readSync(f.fd, buf, { offset: start, length: len });
    fs.closeSync(f);
    return new Uint8Array(buf, 0, n);
  } catch (e) {
    return null;
  }
}

/* ------------------------------ ID3 ------------------------------ */

interface TagBuffer {
  title: string;
  artist: string;
  album: string;
}

function emptyTags(): TagBuffer {
  return { title: '', artist: '', album: '' };
}

function hasAny(t: TagBuffer): boolean {
  return t.title.length > 0 || t.artist.length > 0 || t.album.length > 0;
}

/** 解析 ID3v2 标签（b 从文件第 0 字节开始） */
function parseId3v2(b: Uint8Array): TagBuffer {
  const out: TagBuffer = emptyTags();
  if (b.length < 10 || b[0] !== 0x49 || b[1] !== 0x44 || b[2] !== 0x33) {
    return out;
  }
  const major: number = b[3];
  const flags: number = b[5];
  const tagEnd: number = Math.min(b.length, 10 + synchsafe(b, 6));
  let pos: number = 10;
  // 扩展头
  if ((flags & 0x40) !== 0 && pos + 4 <= tagEnd) {
    if (major === 4) {
      pos += synchsafe(b, pos);
    } else {
      pos += u32be(b, pos) + 4;
    }
  }
  const idLen: number = major === 2 ? 3 : 4;
  const headLen: number = major === 2 ? 6 : 10;
  while (pos + headLen <= tagEnd) {
    const id: string = decodeLatin1(b, pos, pos + idLen);
    if (id.length === 0 || id.charAt(0) === '\u0000') {
      break;
    }
    let frameSize: number = 0;
    if (major === 2) {
      frameSize = ((b[pos + 3] & 0xFF) << 16) | ((b[pos + 4] & 0xFF) << 8) | (b[pos + 5] & 0xFF);
    } else if (major === 4) {
      frameSize = synchsafe(b, pos + 4);
    } else {
      frameSize = u32be(b, pos + 4);
    }
    const dataStart: number = pos + headLen;
    const dataEnd: number = Math.min(tagEnd, dataStart + frameSize);
    if (frameSize <= 0 || dataEnd <= dataStart) {
      break;
    }
    const enc: number = b[dataStart];
    const text: string = decodeTextFrame(enc, b, dataStart + 1, dataEnd);
    if (id === 'TIT2' || id === 'TT2') {
      out.title = text;
    } else if (id === 'TPE1' || id === 'TP1') {
      out.artist = text;
    } else if (id === 'TALB' || id === 'TAL') {
      out.album = text;
    }
    // v2.3/2.4 帧头后可能带 4 字节 footer/附加信息，按 size 前进即可
    pos = dataEnd;
  }
  return out;
}

/** 解析文件末尾 128 字节的 ID3v1 */
function parseId3v1(b: Uint8Array): TagBuffer {
  const out: TagBuffer = emptyTags();
  if (b.length < 128) {
    return out;
  }
  const s: number = b.length - 128;
  if (b[s] !== 0x54 || b[s + 1] !== 0x41 || b[s + 2] !== 0x47) {
    return out;
  }
  out.title = decodeLatin1(b, s + 3, s + 33);
  out.artist = decodeLatin1(b, s + 33, s + 63);
  out.album = decodeLatin1(b, s + 63, s + 93);
  return out;
}

/* ------------------------------ FLAC ------------------------------ */

function parseFlac(b: Uint8Array): TagBuffer {
  const out: TagBuffer = emptyTags();
  if (b.length < 8 || b[0] !== 0x66 || b[1] !== 0x4C || b[2] !== 0x61 || b[3] !== 0x43) {
    return out;
  }
  let pos: number = 4;
  while (pos + 4 <= b.length) {
    const head: number = b[pos];
    const last: boolean = (head & 0x80) !== 0;
    const type: number = head & 0x7F;
    const len: number = ((b[pos + 1] & 0xFF) << 16) | ((b[pos + 2] & 0xFF) << 8) | (b[pos + 3] & 0xFF);
    const dataStart: number = pos + 4;
    const dataEnd: number = Math.min(b.length, dataStart + len);
    if (type === 4 && dataEnd > dataStart) {
      readVorbisComment(b, dataStart, dataEnd, out);
    }
    if (last || dataEnd <= dataStart) {
      break;
    }
    pos = dataEnd;
  }
  return out;
}

function readVorbisComment(b: Uint8Array, s: number, e: number, out: TagBuffer): void {
  let pos: number = s;
  if (pos + 4 > e) {
    return;
  }
  const vendorLen: number = u32le(b, pos);
  pos += 4 + vendorLen;
  if (pos + 4 > e) {
    return;
  }
  const count: number = u32le(b, pos);
  pos += 4;
  for (let i = 0; i < count && pos + 4 <= e; i++) {
    const len: number = u32le(b, pos);
    pos += 4;
    if (len <= 0 || pos + len > e) {
      break;
    }
    const line: string = decodeUtf8(b, pos, pos + len);
    pos += len;
    const eq: number = line.indexOf('=');
    if (eq <= 0) {
      continue;
    }
    const key: string = line.substring(0, eq).toUpperCase();
    const val: string = line.substring(eq + 1);
    if (key === 'TITLE') {
      out.title = val;
    } else if (key === 'ARTIST') {
      out.artist = val;
    } else if (key === 'ALBUM') {
      out.album = val;
    }
  }
}

/* ------------------------------ M4A / MP4 ------------------------------ */

/** 在缓冲区里找 ilst 的文本项（©nam / ©ART / ©alb），命中就解出字符串 */
function findIlstText(b: Uint8Array, name: string): string {
  const want: number[] = [];
  for (let i = 0; i < name.length; i++) {
    want.push(name.charCodeAt(i) & 0xFF);
  }
  for (let i = 4; i + 16 < b.length; i++) {
    let hit: boolean = true;
    for (let k = 0; k < want.length; k++) {
      if (b[i + k] !== want[k]) {
        hit = false;
        break;
      }
    }
    if (!hit) {
      continue;
    }
    // i 指向 ©nam 的类型字节：[size][©nam][size][data][ver+flags][locale][payload]
    if (decodeLatin1(b, i + 8, i + 12) !== 'data') {
      continue;
    }
    const atomSize: number = u32be(b, i + 4);
    const payloadStart: number = i + 20;
    const payloadLen: number = atomSize - 16;
    if (payloadLen <= 0 || payloadStart + payloadLen > b.length) {
      continue;
    }
    const kind: number = b[i + 15]; // data 原子的 flags 低 8 位：1=UTF-8 2=UTF-16
    if (kind === 2) {
      return decodeUtf16(b, payloadStart, payloadStart + payloadLen, true);
    }
    return decodeUtf8(b, payloadStart, payloadStart + payloadLen);
  }
  return '';
}

function parseM4a(head: Uint8Array | null, tail: Uint8Array | null): TagBuffer {
  const out: TagBuffer = emptyTags();
  const keys: string[] = ['\u00A9nam', '\u00A9ART', '\u00A9alb'];
  for (const k of keys) {
    let v: string = '';
    if (head !== null) {
      v = findIlstText(head, k);
    }
    if (v.length === 0 && tail !== null) {
      v = findIlstText(tail, k);
    }
    if (k === '\u00A9nam') {
      out.title = v;
    } else if (k === '\u00A9ART') {
      out.artist = v;
    } else {
      out.album = v;
    }
  }
  return out;
}

/* ------------------------------ 对外入口 ------------------------------ */

/** 标签结果缓存：key = 路径|大小|修改时间，文件没变就不重复解析（列表反复扫描时开销很小） */
const TAG_CACHE: Map<string, LocalTags | null> = new Map();
const TAG_CACHE_LIMIT: number = 800;

/**
 * 读取音频文件内嵌标签（带缓存）。读不到（无标签 / 纯 WAV / 解析失败）返回 null，
 * 调用方回落到文件名解析。
 */
export function readLocalTags(path: string, ext: string): LocalTags | null {
  let key: string = '';
  try {
    const st = fs.statSync(path);
    key = path + '|' + st.size.toString() + '|' + st.mtime.toString();
  } catch (e) {
    return null;
  }
  const hit: LocalTags | null | undefined = TAG_CACHE.get(key);
  if (hit !== undefined) {
    return hit;
  }
  const tags: LocalTags | null = readLocalTagsRaw(path, ext);
  if (TAG_CACHE.size > TAG_CACHE_LIMIT) {
    TAG_CACHE.clear();
  }
  TAG_CACHE.set(key, tags);
  return tags;
}

function readLocalTagsRaw(path: string, ext: string): LocalTags | null {
  const e: string = ext.toLowerCase();
  try {
    if (e === 'flac') {
      const head: Uint8Array | null = readHead(path, 96 * 1024);
      if (head === null) {
        return null;
      }
      const t: TagBuffer = parseFlac(head);
      return hasAny(t) ? { title: t.title, artist: t.artist, album: t.album } : null;
    }
    if (e === 'm4a' || e === 'mp4' || e === 'm4b') {
      const t: TagBuffer = parseM4a(readHead(path, 384 * 1024), readTail(path, 384 * 1024));
      return hasAny(t) ? { title: t.title, artist: t.artist, album: t.album } : null;
    }
    // 其余按 ID3 处理：先看前 10 字节有没有 "ID3" 头，避免整文件读进来
    const head10: Uint8Array | null = readHead(path, 10);
    if (head10 !== null && head10.length === 10
      && head10[0] === 0x49 && head10[1] === 0x44 && head10[2] === 0x33) {
      const tagSize: number = synchsafe(head10, 6) + 10;
      const buf: Uint8Array | null = readHead(path, Math.min(tagSize, 512 * 1024));
      if (buf === null) {
        return null;
      }
      const t: TagBuffer = parseId3v2(buf);
      if (hasAny(t)) {
        return { title: t.title, artist: t.artist, album: t.album };
      }
    }
    const v1: TagBuffer = parseId3v1(readTail(path, 128) ?? new Uint8Array(0));
    return hasAny(v1) ? { title: v1.title, artist: v1.artist, album: v1.album } : null;
  } catch (err) {
    return null;
  }
}
