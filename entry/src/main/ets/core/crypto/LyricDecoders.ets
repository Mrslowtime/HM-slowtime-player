/**
 * 逐字歌词解码与解析。
 *
 * 处理两家服务的增强歌词格式：
 * - KRC（酷狗）：base64 → 去 4 字节头 → 循环 XOR → zlib inflate → 文本
 * - QRC（QQ）：hex → 3DES 解密 → zlib inflate → 文本（解密在 QrcDecoder.ets）
 *
 * 两者统一产出 LyricInfo，其中 lxlyric 字段保留逐字时间标签供高亮渲染：
 *   KRC: [mm:ss.xxx]文本<start,dur>...
 *   QRC: [mm:ss.xxx]文本(start,dur)...
 *
 * 管线分为两段：解密段（字节 → 文本）与解析段（文本 → LyricInfo）。
 * 解析段被 KRC / QRC 共用，仅在逐字括号与绝对/相对时间上分叉。
 */
import { LyricInfo } from '../../model/MusicTypes';
import { base64ToBytes, bytesToUtf8 } from './Crypto';
import { inflateZlib } from './ZlibHelper';
import { decodeQrc } from './QrcDecoder';
import { Json } from '../net/HttpClient';

/** KRC 内容流的循环异或掩码（16 字节，协议固定） */
const KRC_MASK: readonly number[] = [
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47,
  0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

// ---------------- 时间 / 文本基础工具 ----------------

/** 毫秒格式化为 [mm:ss.xxx] 歌词时间戳 */
export function formatLrcTime(ms: number): string {
  let total: number = ms < 0 ? 0 : ms;
  const millis: number = total % 1000;
  total = Math.floor(total / 1000);
  const seconds: number = total % 60;
  const minutes: number = Math.floor(total / 60);
  const mm: string = minutes < 10 ? '0' + minutes.toString() : minutes.toString();
  const ss: string = seconds < 10 ? '0' + seconds.toString() : seconds.toString();
  return '[' + mm + ':' + ss + '.' + millis.toString().padStart(3, '0') + ']';
}

/** 统一换行符并切行（KRC 常见单独 \r，QRC 用 \n） */
function toLines(text: string): string[] {
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
}

// ---------------- 逐字标签解析 ----------------

interface WordParts {
  plain: string;
  tagged: string;
}

/**
 * 把一行歌词正文拆成纯文本与逐字增强两路。
 * KRC 用 <start,dur>，start 相对行首；QRC/MRC 用 (start,dur)，start 为绝对时间需减去行起始。
 */
function expandWordTags(body: string, isKrc: boolean, lineStartMs: number): WordParts {
  let plain: string = '';
  let tagged: string = '';
  const open: string = isKrc ? '<' : '(';
  const close: string = isKrc ? '>' : ')';
  let cursor: number = 0;
  while (cursor < body.length) {
    const ch: string = body.charAt(cursor);
    if (ch === open) {
      const closeAt: number = body.indexOf(close, cursor);
      if (closeAt > cursor) {
        const fields: string[] = body.substring(cursor + 1, closeAt).split(',');
        if (fields.length >= 2) {
          let start: number = parseInt(fields[0], 10);
          if (!isKrc) {
            start = Math.max(start - lineStartMs, 0);
          }
          tagged += '<' + start.toString() + ',' + fields[1] + '>';
        }
        cursor = closeAt + 1;
        continue;
      }
    }
    plain += ch;
    tagged += ch;
    cursor++;
  }
  return { plain: plain, tagged: tagged };
}

// ---------------- KRC 扩展歌词（翻译 / 罗马音）----------------

interface ExtraLyrics {
  roman: string[];
  translate: string[];
}

/** 解析 [language:base64] 里的 content 数组，type=0 罗马音、type=1 翻译 */
function readExtraLyrics(b64: string): ExtraLyrics {
  const empty: ExtraLyrics = { roman: [], translate: [] };
  if (b64.length === 0) {
    return empty;
  }
  try {
    const decoded: string = bytesToUtf8(base64ToBytes(b64));
    const root: Object | null = JSON.parse(decoded) as Object;
    const result: ExtraLyrics = { roman: [], translate: [] };
    for (const item of Json.arr(root, 'content')) {
      const kind: number = Json.num(item, 'type', -1);
      const lines: string[] = [];
      for (const entry of Json.arr(item, 'lyricContent')) {
        if (typeof entry === 'string') {
          lines.push(entry as string);
        } else {
          const wrapped: Object[] = Json.asArr(entry);
          lines.push(wrapped.length > 0 && typeof wrapped[0] === 'string' ? wrapped[0] as string : '');
        }
      }
      if (kind === 0) {
        result.roman = lines;
      } else if (kind === 1) {
        result.translate = lines;
      }
    }
    return result;
  } catch (e) {
    return empty;
  }
}

// ---------------- 文本 → LyricInfo 主解析 ----------------

/** 把时间轴文本解析成 LyricInfo（KRC / QRC 共用） */
export function parseEnhancedLyric(text: string, isKrc: boolean): LyricInfo {
  const source: string = text.length > 0 && text.charCodeAt(0) === 0xfeff ? text.substring(1) : text;
  const lines: string[] = toLines(source);

  let extra: ExtraLyrics = { roman: [], translate: [] };
  if (isKrc) {
    for (const line of lines) {
      const found: RegExpMatchArray | null = line.match(/\[language:([\w=\\/+]+)\]/);
      if (found !== null && found.length > 1) {
        extra = readExtraLyrics(found[1]);
        break;
      }
    }
  }

  let lrc: string = '';
  let tagged: string = '';
  let romanLrc: string = '';
  let translateLrc: string = '';
  let row: number = 0;

  for (const rawLine of lines) {
    const line: string = rawLine.trim();
    const match: RegExpMatchArray | null = line.match(/^\[(\d+),\d+\](.*)$/);
    if (match === null) {
      continue;
    }
    const startMs: number = parseInt(match[1], 10);
    const stamp: string = formatLrcTime(startMs);
    const parts: WordParts = expandWordTags(match[2], isKrc, startMs);
    lrc += stamp + parts.plain.trimEnd() + '\n';
    tagged += stamp + parts.tagged.trimEnd() + '\n';
    if (row < extra.roman.length) {
      romanLrc += stamp + extra.roman[row] + '\n';
    }
    if (row < extra.translate.length) {
      translateLrc += stamp + extra.translate[row] + '\n';
    }
    row++;
  }

  const info: LyricInfo = { lyric: lrc };
  if (translateLrc.length > 0) { info.tlyric = translateLrc; }
  if (romanLrc.length > 0) { info.rlyric = romanLrc; }
  if (tagged.length > 0) { info.lxlyric = tagged; }
  return info;
}

// ---------------- 各加密格式 → 文本 ----------------

/** 去掉 KRC base64 流的 4 字节头，再按 16 字节掩码循环异或 */
function unmaskKrcStream(all: Uint8Array): Uint8Array {
  const body: Uint8Array = new Uint8Array(all.length - 4);
  for (let i: number = 0; i < body.length; i++) {
    body[i] = all[i + 4] ^ KRC_MASK[i % KRC_MASK.length];
  }
  return body;
}

/** 解密并解析酷狗 KRC 歌词 */
export async function decodeKrc(base64Content: string): Promise<LyricInfo | null> {
  if (base64Content.length === 0) {
    return null;
  }
  try {
    const stream: Uint8Array = base64ToBytes(base64Content);
    if (stream.length <= 4) {
      return null;
    }
    const inflateInput: Uint8Array = unmaskKrcStream(stream);
    const plain: string = bytesToUtf8(await inflateZlib(inflateInput, 0));
    return plain.length > 0 ? parseEnhancedLyric(plain, true) : null;
  } catch (e) {
    console.warn('KrcDecoder: ' + String(e));
    return null;
  }
}

/** 从 QQ musicu.fcg 的 XML 包裹中取出 LyricContent 并反转义实体 */
export function extractQrcContent(text: string): string {
  if (text.length === 0) {
    return '';
  }
  let value: string = text;
  const marker: string = 'LyricContent="';
  const at: number = value.indexOf(marker);
  if (at >= 0) {
    const from: number = at + marker.length;
    const to: number = value.indexOf('"/>', from);
    value = to > from ? value.substring(from, to) : value.substring(from);
  }
  return value.replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
}

/** 解密并解析 QQ 音乐 QRC 歌词（hex 输入） */
export async function decodeQrcToLyric(hexData: string): Promise<LyricInfo | null> {
  if (hexData.length === 0) {
    return null;
  }
  const text: string = extractQrcContent(await decodeQrc(hexData));
  return text.length > 0 ? parseEnhancedLyric(text, false) : null;
}

/** 普通 LRC 的 base64 包装 */
export function decodeBase64Lrc(b64: string): LyricInfo | null {
  if (b64.length === 0) {
    return null;
  }
  const text: string = bytesToUtf8(base64ToBytes(b64));
  return text.length > 0 ? { lyric: text, tlyric: null, rlyric: null, lxlyric: null } : null;
}
