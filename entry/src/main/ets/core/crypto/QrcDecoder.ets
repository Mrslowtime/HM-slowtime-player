/**
 * QRC 逐字歌词解密。
 *
 * 密文是十六进制字符串，内容为固定密钥的 3DES-EDE（ECB、无填充）分组密文，
 * 解密后经 zlib inflate 还原成 UTF-8 歌词文本。
 *
 * 该 DES 变体沿用服务端的私有 S-box（两处相对标准 DES 有改动），
 * 因此下表与置换表是解密所必需的事实数据，必须逐项一致。
 * 代码结构按「位读取 → 置换 → 轮函数 → 密钥编排 → 三重分组」分层组织。
 */
import { inflateZlib } from './ZlibHelper';
import { hexToBytes, bytesToUtf8 } from './Crypto';

const MODE_ENCRYPT: number = 1;
const MODE_DECRYPT: number = 0;

// ---------------- 事实数据表 ----------------

/** 服务端私有 S-box（8 组 × 64 项） */
const S_BOXES: readonly (readonly number[])[] = [
  [
    14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
    4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
  ],
  [
    15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
    0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
  ],
  [
    10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
    13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
  ],
  [
    7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
    10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
  ],
  [
    2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
    4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
  ],
  [
    12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
    9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
  ],
  [
    4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
    1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
  ],
  [
    13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
    7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
  ],
];

/** 每轮密钥左移位数 */
const SHIFT_SCHEDULE: readonly number[] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
/** 密钥 C / D 半边的选取位置 */
const PERM_C: readonly number[] = [
  56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
];
const PERM_D: readonly number[] = [
  62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3,
];
/** 压缩置换（PC-2） */
const COMPRESSION: readonly number[] = [
  13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46,
  54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
];

/** QRC 固定 24 字节密钥 */
const QRC_SECRET: Uint8Array = new Uint8Array([
  0x21, 0x40, 0x23, 0x29, 0x28, 0x2a, 0x24, 0x25, 0x31, 0x32, 0x33, 0x5a,
  0x58, 0x43, 0x21, 0x40, 0x21, 0x40, 0x23, 0x29, 0x28, 0x4e, 0x48, 0x4c,
]);

// ---------------- 位读取原语 ----------------
// 以无符号 32 位运算，>>> 0 保证溢出行为与 C++ uint32_t 一致。

/** 从字节数组第 bit 位取 1 位，移到结果第 offset 位 */
function takeBit(src: Uint8Array, bit: number, offset: number): number {
  const word: number = ((bit / 32) | 0) * 4 + 3 - (((bit % 32) / 8) | 0);
  return (((src[word] >>> (7 - (bit % 8))) & 1) << offset) >>> 0;
}

/** 从 32 位数第 bit 位取 1 位，移到结果第 offset 位 */
function takeBitFromWord(src: number, bit: number, offset: number): number {
  return (((src >>> (31 - bit)) & 1) << offset) >>> 0;
}

/** 从 32 位数第 bit 位取 1 位，移到结果低位侧（左移后取符号再右移） */
function takeBitLow(src: number, bit: number, offset: number): number {
  return (((((src << bit) >>> 0) & 0x80000000) >>> 0) >>> offset) >>> 0;
}

/** S-box 六位输入折叠：合并首尾位，压缩成 0..63 索引 */
function foldSBoxIndex(value: number): number {
  return (value & 32) | ((value & 31) >>> 1) | ((value & 1) << 4);
}

// ---------------- 初始 / 末置换 ----------------

/** 初始置换：把 8 字节输入拆成两个 32 位半字 */
function permuteInitial(input: Uint8Array): number[] {
  const left: number = (
    takeBit(input, 57, 31) | takeBit(input, 49, 30) | takeBit(input, 41, 29) | takeBit(input, 33, 28) |
    takeBit(input, 25, 27) | takeBit(input, 17, 26) | takeBit(input, 9, 25) | takeBit(input, 1, 24) |
    takeBit(input, 59, 23) | takeBit(input, 51, 22) | takeBit(input, 43, 21) | takeBit(input, 35, 20) |
    takeBit(input, 27, 19) | takeBit(input, 19, 18) | takeBit(input, 11, 17) | takeBit(input, 3, 16) |
    takeBit(input, 61, 15) | takeBit(input, 53, 14) | takeBit(input, 45, 13) | takeBit(input, 37, 12) |
    takeBit(input, 29, 11) | takeBit(input, 21, 10) | takeBit(input, 13, 9) | takeBit(input, 5, 8) |
    takeBit(input, 63, 7) | takeBit(input, 55, 6) | takeBit(input, 47, 5) | takeBit(input, 39, 4) |
    takeBit(input, 31, 3) | takeBit(input, 23, 2) | takeBit(input, 15, 1) | takeBit(input, 7, 0)
  ) >>> 0;
  const right: number = (
    takeBit(input, 56, 31) | takeBit(input, 48, 30) | takeBit(input, 40, 29) | takeBit(input, 32, 28) |
    takeBit(input, 24, 27) | takeBit(input, 16, 26) | takeBit(input, 8, 25) | takeBit(input, 0, 24) |
    takeBit(input, 58, 23) | takeBit(input, 50, 22) | takeBit(input, 42, 21) | takeBit(input, 34, 20) |
    takeBit(input, 26, 19) | takeBit(input, 18, 18) | takeBit(input, 10, 17) | takeBit(input, 2, 16) |
    takeBit(input, 60, 15) | takeBit(input, 52, 14) | takeBit(input, 44, 13) | takeBit(input, 36, 12) |
    takeBit(input, 28, 11) | takeBit(input, 20, 10) | takeBit(input, 12, 9) | takeBit(input, 4, 8) |
    takeBit(input, 62, 7) | takeBit(input, 54, 6) | takeBit(input, 46, 5) | takeBit(input, 38, 4) |
    takeBit(input, 30, 3) | takeBit(input, 22, 2) | takeBit(input, 14, 1) | takeBit(input, 6, 0)
  ) >>> 0;
  return [left, right];
}

/** 末置换：两个 32 位半字写回 8 字节 */
function permuteFinal(left: number, right: number, out: Uint8Array): void {
  out[3] = (takeBitFromWord(right, 7, 7) | takeBitFromWord(left, 7, 6) | takeBitFromWord(right, 15, 5) | takeBitFromWord(left, 15, 4) | takeBitFromWord(right, 23, 3) | takeBitFromWord(left, 23, 2) | takeBitFromWord(right, 31, 1) | takeBitFromWord(left, 31, 0)) & 0xff;
  out[2] = (takeBitFromWord(right, 6, 7) | takeBitFromWord(left, 6, 6) | takeBitFromWord(right, 14, 5) | takeBitFromWord(left, 14, 4) | takeBitFromWord(right, 22, 3) | takeBitFromWord(left, 22, 2) | takeBitFromWord(right, 30, 1) | takeBitFromWord(left, 30, 0)) & 0xff;
  out[1] = (takeBitFromWord(right, 5, 7) | takeBitFromWord(left, 5, 6) | takeBitFromWord(right, 13, 5) | takeBitFromWord(left, 13, 4) | takeBitFromWord(right, 21, 3) | takeBitFromWord(left, 21, 2) | takeBitFromWord(right, 29, 1) | takeBitFromWord(left, 29, 0)) & 0xff;
  out[0] = (takeBitFromWord(right, 4, 7) | takeBitFromWord(left, 4, 6) | takeBitFromWord(right, 12, 5) | takeBitFromWord(left, 12, 4) | takeBitFromWord(right, 20, 3) | takeBitFromWord(left, 20, 2) | takeBitFromWord(right, 28, 1) | takeBitFromWord(left, 28, 0)) & 0xff;
  out[7] = (takeBitFromWord(right, 3, 7) | takeBitFromWord(left, 3, 6) | takeBitFromWord(right, 11, 5) | takeBitFromWord(left, 11, 4) | takeBitFromWord(right, 19, 3) | takeBitFromWord(left, 19, 2) | takeBitFromWord(right, 27, 1) | takeBitFromWord(left, 27, 0)) & 0xff;
  out[6] = (takeBitFromWord(right, 2, 7) | takeBitFromWord(left, 2, 6) | takeBitFromWord(right, 10, 5) | takeBitFromWord(left, 10, 4) | takeBitFromWord(right, 18, 3) | takeBitFromWord(left, 18, 2) | takeBitFromWord(right, 26, 1) | takeBitFromWord(left, 26, 0)) & 0xff;
  out[5] = (takeBitFromWord(right, 1, 7) | takeBitFromWord(left, 1, 6) | takeBitFromWord(right, 9, 5) | takeBitFromWord(left, 9, 4) | takeBitFromWord(right, 17, 3) | takeBitFromWord(left, 17, 2) | takeBitFromWord(right, 25, 1) | takeBitFromWord(left, 25, 0)) & 0xff;
  out[4] = (takeBitFromWord(right, 0, 7) | takeBitFromWord(left, 0, 6) | takeBitFromWord(right, 8, 5) | takeBitFromWord(left, 8, 4) | takeBitFromWord(right, 16, 3) | takeBitFromWord(left, 16, 2) | takeBitFromWord(right, 24, 1) | takeBitFromWord(left, 24, 0)) & 0xff;
}

// ---------------- Feistel 轮函数 ----------------

/** 轮函数 f：扩展置换 → 与子密钥异或 → S-box 替换 → P 置换 */
function feistel(state: number, roundKey: Uint8Array): number {
  const upper: number = (
    takeBitLow(state, 31, 0) | (((state & 0xF0000000) >>> 0) >>> 1) | takeBitLow(state, 4, 5) |
    takeBitLow(state, 3, 6) | (((state & 0x0F000000) >>> 0) >>> 3) | takeBitLow(state, 8, 11) |
    takeBitLow(state, 7, 12) | (((state & 0x00F00000) >>> 0) >>> 5) | takeBitLow(state, 12, 17) |
    takeBitLow(state, 11, 18) | (((state & 0x000F0000) >>> 0) >>> 7) | takeBitLow(state, 16, 23)
  ) >>> 0;
  const lower: number = (
    takeBitLow(state, 15, 0) | (((state & 0x0000F000) << 15) >>> 0) | takeBitLow(state, 20, 5) |
    takeBitLow(state, 19, 6) | (((state & 0x00000F00) << 13) >>> 0) | takeBitLow(state, 24, 11) |
    takeBitLow(state, 23, 12) | (((state & 0x000000F0) << 11) >>> 0) | takeBitLow(state, 28, 17) |
    takeBitLow(state, 27, 18) | (((state & 0x0000000F) << 9) >>> 0) | takeBitLow(state, 0, 23)
  ) >>> 0;

  const mixed: number[] = [
    (upper >>> 24) & 0xFF, (upper >>> 16) & 0xFF, (upper >>> 8) & 0xFF,
    (lower >>> 24) & 0xFF, (lower >>> 16) & 0xFF, (lower >>> 8) & 0xFF,
  ];
  for (let i: number = 0; i < 6; i++) {
    mixed[i] ^= roundKey[i];
  }

  const substituted: number = (
    (S_BOXES[0][foldSBoxIndex(mixed[0] >>> 2)] << 28) |
    (S_BOXES[1][foldSBoxIndex(((mixed[0] & 0x03) << 4) | (mixed[1] >>> 4))] << 24) |
    (S_BOXES[2][foldSBoxIndex(((mixed[1] & 0x0F) << 2) | (mixed[2] >>> 6))] << 20) |
    (S_BOXES[3][foldSBoxIndex(mixed[2] & 0x3F)] << 16) |
    (S_BOXES[4][foldSBoxIndex(mixed[3] >>> 2)] << 12) |
    (S_BOXES[5][foldSBoxIndex(((mixed[3] & 0x03) << 4) | (mixed[4] >>> 4))] << 8) |
    (S_BOXES[6][foldSBoxIndex(((mixed[4] & 0x0F) << 2) | (mixed[5] >>> 6))] << 4) |
    S_BOXES[7][foldSBoxIndex(mixed[5] & 0x3F)]
  ) >>> 0;

  return (
    takeBitLow(substituted, 15, 0) | takeBitLow(substituted, 6, 1) | takeBitLow(substituted, 19, 2) | takeBitLow(substituted, 20, 3) |
    takeBitLow(substituted, 28, 4) | takeBitLow(substituted, 11, 5) | takeBitLow(substituted, 27, 6) | takeBitLow(substituted, 16, 7) |
    takeBitLow(substituted, 0, 8) | takeBitLow(substituted, 14, 9) | takeBitLow(substituted, 22, 10) | takeBitLow(substituted, 25, 11) |
    takeBitLow(substituted, 4, 12) | takeBitLow(substituted, 17, 13) | takeBitLow(substituted, 30, 14) | takeBitLow(substituted, 9, 15) |
    takeBitLow(substituted, 1, 16) | takeBitLow(substituted, 7, 17) | takeBitLow(substituted, 23, 18) | takeBitLow(substituted, 13, 19) |
    takeBitLow(substituted, 31, 20) | takeBitLow(substituted, 26, 21) | takeBitLow(substituted, 2, 22) | takeBitLow(substituted, 8, 23) |
    takeBitLow(substituted, 18, 24) | takeBitLow(substituted, 12, 25) | takeBitLow(substituted, 29, 26) | takeBitLow(substituted, 5, 27) |
    takeBitLow(substituted, 21, 28) | takeBitLow(substituted, 10, 29) | takeBitLow(substituted, 3, 30) | takeBitLow(substituted, 24, 31)
  ) >>> 0;
}

// ---------------- 分组加解密 ----------------

/** 单次 DES 处理一个 8 字节分组（16 轮 Feistel） */
function desBlock(input: Uint8Array, keys: Uint8Array[], output: Uint8Array): void {
  const halves: number[] = permuteInitial(input);
  let left: number = halves[0];
  let right: number = halves[1];
  for (let round: number = 0; round < 15; round++) {
    const previousRight: number = right;
    right = (feistel(right, keys[round]) ^ left) >>> 0;
    left = previousRight;
  }
  left = (feistel(right, keys[15]) ^ left) >>> 0;
  permuteFinal(left, right, output);
}

/** 由 8 字节密钥生成 16 轮子密钥 */
function expandKey(key: Uint8Array, mode: number): Uint8Array[] {
  const keys: Uint8Array[] = [];
  for (let i: number = 0; i < 16; i++) {
    keys.push(new Uint8Array(6));
  }
  let c: number = 0;
  let d: number = 0;
  for (let i: number = 0; i < 28; i++) {
    c = (c | takeBit(key, PERM_C[i], 31 - i)) >>> 0;
    d = (d | takeBit(key, PERM_D[i], 31 - i)) >>> 0;
  }
  for (let round: number = 0; round < 16; round++) {
    const shift: number = SHIFT_SCHEDULE[round];
    c = ((((c << shift) >>> 0) | (c >>> (28 - shift))) & 0xFFFFFFF0) >>> 0;
    d = ((((d << shift) >>> 0) | (d >>> (28 - shift))) & 0xFFFFFFF0) >>> 0;
    const slot: number = mode === MODE_DECRYPT ? 15 - round : round;
    for (let j: number = 0; j < 24; j++) {
      keys[slot][(j / 8) | 0] |= takeBitFromWord(c, COMPRESSION[j], 7 - (j % 8));
    }
    for (let j: number = 24; j < 48; j++) {
      keys[slot][(j / 8) | 0] |= takeBitFromWord(d, COMPRESSION[j] - 27, 7 - (j % 8));
    }
  }
  return keys;
}

/** 三重 DES 的密钥编排（EDE：加密-解密-加密；解密时反向） */
function tripleKeySchedule(key: Uint8Array, mode: number): Uint8Array[][] {
  if (mode === MODE_ENCRYPT) {
    return [
      expandKey(key.subarray(0, 8), MODE_ENCRYPT),
      expandKey(key.subarray(8, 16), MODE_DECRYPT),
      expandKey(key.subarray(16, 24), MODE_ENCRYPT),
    ];
  }
  return [
    expandKey(key.subarray(16, 24), MODE_DECRYPT),
    expandKey(key.subarray(8, 16), MODE_ENCRYPT),
    expandKey(key.subarray(0, 8), MODE_DECRYPT),
  ];
}

/** 三重 DES 处理一个分组 */
function tripleBlock(input: Uint8Array, rounds: Uint8Array[][], output: Uint8Array): void {
  const first: Uint8Array = new Uint8Array(8);
  const last: Uint8Array = new Uint8Array(8);
  desBlock(input, rounds[0], first);
  desBlock(first, rounds[1], last);
  desBlock(last, rounds[2], first);
  output.set(first);
}

// ---------------- 对外入口 ----------------

/** 解密 QRC 十六进制密文为歌词文本（失败返回空串） */
export async function decodeQrc(hexData: string): Promise<string> {
  if (hexData.length === 0 || hexData.length % 2 !== 0) {
    return '';
  }
  try {
    const encrypted: Uint8Array = hexToBytes(hexData);
    if (encrypted.length === 0) {
      return '';
    }
    const rounds: Uint8Array[][] = tripleKeySchedule(QRC_SECRET, MODE_DECRYPT);
    const block: Uint8Array = new Uint8Array(8);
    for (let at: number = 0; at + 8 <= encrypted.length; at += 8) {
      tripleBlock(encrypted.subarray(at, at + 8), rounds, block);
      encrypted.set(block, at);
    }
    return bytesToUtf8(await inflateZlib(encrypted, 0));
  } catch (e) {
    console.warn('QrcDecoder: decrypt or inflate failed: ' + String(e));
    return '';
  }
}
