/**
 * zlib 内存解压 —— 参考 pako.inflate（KRC / QRC 逐字歌词解码用）。
 *
 * 鸿蒙 @ohos.zlib 提供 createZip().uncompress(dest, source)，但要求预先分配
 * 足够大的输出缓冲；歌词长度未知，所以按 4 倍递增重试。
 */
import { zlib } from '@kit.BasicServicesKit';

const MAX_TRY: number = 8;
const MAX_SIZE: number = 8 * 1024 * 1024;

/** 把 Uint8Array 拷成独立的 ArrayBuffer（避免 byteOffset 干扰） */
function toArrayBuffer(src: Uint8Array): ArrayBuffer {
  const buf: ArrayBuffer = new ArrayBuffer(src.length);
  new Uint8Array(buf).set(src);
  return buf;
}

/**
 * 解压 zlib（deflate with zlib header）数据流。
 * @param src 压缩数据
 * @param expectedSize 已知解压后大小；传 0 表示未知，由实现自行扩容重试
 * @returns 解压后的原始字节
 */
export async function inflateZlib(src: Uint8Array, expectedSize: number): Promise<Uint8Array> {
  if (src.length === 0) {
    return new Uint8Array(0);
  }
  const source: ArrayBuffer = toArrayBuffer(src);
  let size: number = expectedSize > 0 ? expectedSize : Math.max(src.length * 6, 64 * 1024);
  let lastErr: string = '';
  for (let attempt = 0; attempt < MAX_TRY && size <= MAX_SIZE; attempt++) {
    const dest: ArrayBuffer = new ArrayBuffer(size);
    try {
      const zip: zlib.Zip = await zlib.createZip();
      const info: zlib.ZipOutputInfo = await zip.uncompress(dest, source, src.length);
      const used: number = info.destLen > 0 ? Math.min(info.destLen, size) : size;
      return new Uint8Array(dest.slice(0, used));
    } catch (e) {
      lastErr = String(e);
      size *= 4;
    }
  }
  throw new Error('inflateZlib failed: ' + lastErr);
}
