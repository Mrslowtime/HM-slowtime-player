/**
 * 歌词解析 —— 按协议 + core/lyric.ts。
 * 支持 LRC 时间标签、翻译(tlyric)、罗马音(rlyric)、逐字(lxlyric)。
 */
import { LyricInfo, LyricLine, LyricWord } from '../model/MusicTypes';

interface TimeLabel {
  time: number;
  text: string;
}

/** 解析 [mm:ss.xx] 时间标签（支持一行多标签） */
export function parseLrcTimeLabel(lrc: string): TimeLabel[] {
  const result: TimeLabel[] = [];
  if (lrc.length === 0) {
    return result;
  }
  const lines = lrc.replace(/\r/g, '').split('\n');
  const re = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
  for (const line of lines) {
    const matches = line.match(re);
    if (matches === null) {
      continue;
    }
    const text = line.replace(re, '').trim();
    for (const tag of matches) {
      const m = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/.exec(tag);
      if (m === null) {
        continue;
      }
      const min = parseInt(m[1], 10);
      const sec = parseInt(m[2], 10);
      let frac = 0;
      if (m[3] !== undefined && m[3].length > 0) {
        const digits = m[3].length;
        frac = parseInt(m[3], 10) / (digits === 3 ? 1000 : Math.pow(10, digits));
      }
      result.push({ time: (min * 60 + sec + frac) * 1000, text });
    }
  }
  result.sort((a: TimeLabel, b: TimeLabel): number => a.time - b.time);
  return result;
}

/** 把翻译 / 罗马音按时间就近合并进主歌词 */
export function buildLyricLines(info: LyricInfo, showTranslation: boolean, showRoma: boolean): LyricLine[] {
  const main = parseLrcTimeLabel(info.lyric);
  const trans = showTranslation && info.tlyric ? parseLrcTimeLabel(info.tlyric) : [];
  const roma = showRoma && info.rlyric ? parseLrcTimeLabel(info.rlyric) : [];
  const lines: LyricLine[] = [];
  for (const item of main) {
    const line: LyricLine = { time: item.time, text: item.text };
    line.translation = findNearest(trans, item.time);
    line.roma = findNearest(roma, item.time);
    lines.push(line);
  }
  return lines;
}

function findNearest(list: TimeLabel[], time: number): string {
  let best = '';
  let bestDiff = Number.MAX_SAFE_INTEGER;
  for (const item of list) {
    const diff = Math.abs(item.time - time);
    // 允许 200ms 容差，超出认为无对应
    if (diff < bestDiff && diff < 200) {
      bestDiff = diff;
      best = item.text;
    }
  }
  return best;
}

/** 是否含可滚动的时间标签（[mm:ss] / [mm:ss.xx]） */
export function hasTimedLabel(lrc: string): boolean {
  return /\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]/.test(lrc);
}

/** 时间标签跨度（ms）；没有标签返回 -1，只有单一时间点返回 0 附近 */
function timedSpanMs(lrc: string): number {
  const re: RegExp = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
  let min: number = Number.MAX_SAFE_INTEGER;
  let max: number = -1;
  let m = re.exec(lrc);
  while (m !== null) {
    const minVal: number = parseInt(m[1], 10);
    const secVal: number = parseInt(m[2], 10);
    let frac: number = 0;
    if (m[3] !== undefined && m[3].length > 0) {
      const digits: number = m[3].length;
      frac = parseInt(m[3], 10) / (digits === 3 ? 1000 : Math.pow(10, digits));
    }
    const ms: number = Math.round((minVal * 60 + secVal + frac) * 1000);
    if (ms < min) {
      min = ms;
    }
    if (ms > max) {
      max = ms;
    }
    m = re.exec(lrc);
  }
  return max < 0 ? -1 : max - min;
}

function fmtLrcTime(ms: number): string {
  const total: number = ms < 0 ? 0 : ms;
  const m: number = Math.floor(total / 60000);
  const s: number = Math.floor((total % 60000) / 1000);
  const cs: number = Math.floor((total % 1000) / 10);
  const mm: string = (m < 10 ? '0' : '') + m.toString();
  const ss: string = (s < 10 ? '0' : '') + s.toString();
  const cc: string = (cs < 10 ? '0' : '') + cs.toString();
  return mm + ':' + ss + '.' + cc;
}

/**
 * 部分接口（如网易纯文本歌词、第三方音源）返回的是没有时间标签的纯文本，
 * 直接喂给解析器会得到 0 行 → UI 显示「暂无歌词」。
 * 这里按总时长把每行均分铺开，保证至少能按进度滚动显示。
 * 已带时间标签的歌词原样返回。
 */
export function ensureTimedLyric(lrc: string, durationMs: number): string {
  if (lrc.length === 0) {
    return lrc;
  }
  // 已有时间标签且时间确实在推进（跨度 > 1.5s）才原样返回；
  // 全部标成 [00:00.00] 的坏数据按纯文本重新铺时间。
  if (hasTimedLabel(lrc) && timedSpanMs(lrc) >= 1500) {
    return lrc;
  }
  const raw: string[] = lrc.replace(/\r/g, '').split('\n');
  const texts: string[] = [];
  for (const line of raw) {
    // 去掉 [ti:] [ar:] [by:] 元信息与时间标签，只留文本
    const t: string = line.replace(/^\[[a-zA-Z]+:[^\]]*\]\s*/, '')
      .replace(/\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]/g, '').trim();
    if (t.length > 0) {
      texts.push(t);
    }
  }
  if (texts.length === 0) {
    return '';
  }
  const total: number = durationMs > 0 ? durationMs : texts.length * 4000;
  let out: string = '';
  for (let i = 0; i < texts.length; i++) {
    const ms: number = Math.round(total * i / texts.length);
    out += '[' + fmtLrcTime(ms) + ']' + texts[i] + '\n';
  }
  return out;
}

/** 按播放进度找当前行下标 */
export function findActiveLineIndex(lines: LyricLine[], timeMs: number): number {
  let idx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].time <= timeMs) {
      idx = i;
    } else {
      break;
    }
  }
  return idx;
}

/**
 * 解析逐字歌词（lxlyric）为与 lyricLines 逐行对齐的字词数组。
 * lxlyric 格式（M2-D 已统一）：`[mm:ss.xxx]文本<relStart,dur>文本<relStart,dur>...`
 * 每行时间标签与 lyricLines 严格对应，按行起始时间（ms，取整容错）做参照。
 * 返回数组长度与 lines 一致；某行无逐字数据则为 null。
 */
export function parseLxLyric(lxlyric: string | null | undefined, lines: LyricLine[]): (LyricWord[] | null)[] {
  const result: (LyricWord[] | null)[] = [];
  for (let i = 0; i < lines.length; i++) {
    result.push(null);
  }
  if (lxlyric === null || lxlyric === undefined || lxlyric.length === 0) {
    return result;
  }
  const map: Map<number, LyricWord[]> = new Map<number, LyricWord[]>();
  const raw: string[] = lxlyric.replace(/\r/g, '').split('\n');
  const lineRe: RegExp = /^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\](.*)$/;
  for (const r of raw) {
    if (r.length === 0) {
      continue;
    }
    const m = lineRe.exec(r);
    if (m === null) {
      continue;
    }
    const min: number = parseInt(m[1], 10);
    const sec: number = parseInt(m[2], 10);
    let frac: number = 0;
    if (m[3] !== undefined && m[3].length > 0) {
      const digits: number = m[3].length;
      frac = parseInt(m[3], 10) / (digits === 3 ? 1000 : Math.pow(10, digits));
    }
    const lineTime: number = Math.round((min * 60 + sec + frac) * 1000);
    const words: LyricWord[] = parseWords(m[4]);
    if (words.length > 0) {
      map.set(lineTime, words);
    }
  }
  for (let i = 0; i < lines.length; i++) {
    const w: LyricWord[] | undefined = map.get(Math.round(lines[i].time));
    if (w !== undefined) {
      result[i] = w;
    }
  }
  return result;
}

/** 把一行逐字文本 `文本<start,dur>文本<start,dur>...` 切成「字词 + 相对行首时间」 */
function parseWords(body: string): LyricWord[] {
  const words: LyricWord[] = [];
  const re: RegExp = /<(\d+),(\d+)>/g;
  let last: number = 0;
  let m = re.exec(body);
  while (m !== null) {
    const text: string = body.substring(last, m.index);
    const start: number = parseInt(m[1], 10);
    const dur: number = parseInt(m[2], 10);
    if (text.length > 0) {
      // 标签 <start,dur> 标记其后文本（即本词）的起始时间
      words.push({ text, start, dur });
    } else if (words.length > 0) {
      // 连续标签无前置文本：时长并入上一词（异常数据兜底）
      words[words.length - 1].dur += dur;
    }
    last = re.lastIndex;
    m = re.exec(body);
  }
  // 行尾剩余文本（通常无跟随标签）并入最后一个词
  const tail: string = body.substring(last);
  if (tail.length > 0 && words.length > 0) {
    words[words.length - 1].text += tail;
  }
  return words;
}
