/**
 * 咪咕 MRC 逐字歌词解密。
 *
 * 密文为连续 hex 串：每 16 个 hex 字符视为一个 64 位字。
 * 解密后每个字按小端拆成 8 字节，再以 UTF-16LE 每两字节还原一个字符。
 * 核心是 XXTEA 变体：轮数由字数决定，每轮对字数组做一次混合变换。
 *
 * ArkTS 严格模式约定：全程 bigint 运算、不用 BigInt 字面量后缀、
 * 不用 Buffer、数组下标一律 number、所有变量显式类型。
 */

/** 黄金比例常数（XXTEA 使用） */
const DELTA: bigint = BigInt('2654435769');
/** 密文最短长度（hex 字符数） */
const MIN_LENGTH: number = 32;

/** int64 边界，用于把无符号结果折回有符号区间 */
const MAX_LONG: bigint = BigInt('9223372036854775807');
const MIN_LONG: bigint = BigInt('-9223372036854775808');
const TWO64: bigint = BigInt(1) << BigInt(64);

/** 9 个 64 位密钥字 */
const KEY_WORDS: bigint[] = [
  BigInt('27303562373562475'),
  BigInt('18014862372307051'),
  BigInt('22799692160172081'),
  BigInt('34058940340699235'),
  BigInt('30962724186095721'),
  BigInt('27303523720101991'),
  BigInt('27303523720101998'),
  BigInt('31244139033526382'),
  BigInt('28992395054481524'),
];

/** 超过 int64 范围时通过 ±2^64 折回有符号区间 */
function wrapLong(value: bigint): bigint {
  let v: bigint = value;
  while (v > MAX_LONG) {
    v = v - TWO64;
  }
  while (v < MIN_LONG) {
    v = v + TWO64;
  }
  return v;
}

/** 每 16 个 hex 字符解析为一个 64 位字 */
function hexToWords(hex: string): bigint[] {
  const count: number = Math.floor(hex.length / 16);
  const words: bigint[] = [];
  for (let i: number = 0; i < count; i++) {
    const chunk: string = hex.substring(i * 16, i * 16 + 16);
    words.push(wrapLong(BigInt('0x' + chunk)));
  }
  return words;
}

/**
 * 原地解密字数组。
 * carried 是跨元素累积的中间值：每轮从首字开始，先更新末尾到索引 1，
 * 再用更新后的 carried 处理首字；下一轮 carried 继续传递。
 */
function transform(words: bigint[]): void {
  const count: number = words.length;
  if (count < 1) {
    return;
  }
  const rounds: number = Number(BigInt(6) + (BigInt(52) / BigInt(count)));
  let sum: bigint = BigInt(rounds) * DELTA;
  let carried: bigint = words[0];

  for (let round: number = 0; round < rounds; round++) {
    const delta: bigint = wrapLong(sum);
    if (delta === BigInt(0)) {
      break;
    }
    const selector: number = Number((delta >> BigInt(2)) & BigInt(3));

    let cursor: number = count;
    while (cursor > 1) {
      cursor = cursor - 1;
      const neighbour: bigint = words[cursor - 1];
      const keyWord: bigint = KEY_WORDS[Number((BigInt(cursor) & BigInt(3)) ^ BigInt(selector))];

      const leftMix: bigint = wrapLong(
        wrapLong(neighbour >> BigInt(5)) ^ wrapLong(carried << BigInt(2)));
      const rightMix: bigint = wrapLong(
        wrapLong(carried >> BigInt(3)) ^ wrapLong(neighbour << BigInt(4)));
      const combined: bigint = wrapLong(
        wrapLong(carried ^ delta) + wrapLong(neighbour ^ keyWord));

      carried = wrapLong(words[cursor] - wrapLong(combined ^ wrapLong(leftMix + rightMix)));
      words[cursor] = carried;
    }

    // 内层循环退出时游标归零，首字使用的密钥索引固定为 selector
    const tail: bigint = words[count - 1];
    const tailKey: bigint = KEY_WORDS[selector];
    const tailLeft: bigint = wrapLong(
      wrapLong(tail >> BigInt(5)) ^ wrapLong(carried << BigInt(2)));
    const tailRight: bigint = wrapLong(
      wrapLong(carried >> BigInt(3)) ^ wrapLong(tail << BigInt(4)));
    const tailCombined: bigint = wrapLong(
      wrapLong(tailKey ^ tail) + wrapLong(carried ^ delta));

    carried = wrapLong(words[0] - wrapLong(tailCombined ^ wrapLong(tailLeft + tailRight)));
    words[0] = carried;

    sum = delta - DELTA;
  }
}

/** 每个 64 位字按小端取字节，两两组成 UTF-16 字符 */
function wordsToText(words: bigint[]): string {
  let text: string = '';
  for (const word of words) {
    let v: bigint = wrapLong(word);
    for (let b: number = 0; b < 8; b += 2) {
      const low: number = Number(v & BigInt(255));
      v = v >> BigInt(8);
      const high: number = Number(v & BigInt(255));
      v = v >> BigInt(8);
      text += String.fromCharCode(low | (high << 8));
    }
  }
  return text;
}

/** 主入口：非 hex 明文原样返回，hex 走解密；空值/短输入/异常返回空串 */
export function decryptMrc(hexOrText: string): string {
  try {
    if (typeof hexOrText !== 'string' || hexOrText.length === 0) {
      return '';
    }
    const clean: string = hexOrText.replace(/\s/g, '');
    if (clean.length === 0) {
      return '';
    }
    if (clean.match(/^[0-9a-fA-F]+$/) === null) {
      return hexOrText;
    }
    if (clean.length < MIN_LENGTH) {
      return '';
    }
    const words: bigint[] = hexToWords(clean);
    transform(words);
    return wordsToText(words);
  } catch (e) {
    return '';
  }
}
