/**
 * 加密 / 编码工具层。
 *
 * 基于鸿蒙系统能力 @ohos.security.cryptoFramework 实现 MD5 / SHA1 / AES，
 * 均为异步 Promise 接口；另提供 base64 / hex / UTF-8 的字节转换。
 * 上层签名算法调用这些原语，输出与各服务协议要求的字节格式一致。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

const B64_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const HEX_CHARS: string = '0123456789abcdef';

export function utf8ToBytes(s: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(s);
}

export function bytesToUtf8(b: Uint8Array): string {
  const decoder = new util.TextDecoder('utf-8');
  return decoder.decodeToString(b);
}

export function bytesToHex(b: Uint8Array): string {
  let out: string = '';
  for (let i = 0; i < b.length; i++) {
    const v: number = b[i];
    out += HEX_CHARS.charAt((v >> 4) & 0x0f) + HEX_CHARS.charAt(v & 0x0f);
  }
  return out;
}

export function bytesToHexUpper(b: Uint8Array): string {
  return bytesToHex(b).toUpperCase();
}

export function hexToBytes(h: string): Uint8Array {
  const len: number = Math.floor(h.length / 2);
  const out: Uint8Array = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    out[i] = parseInt(h.substring(i * 2, i * 2 + 2), 16) & 0xff;
  }
  return out;
}

export function bytesToBase64(b: Uint8Array): string {
  let out: string = '';
  let i: number = 0;
  while (i + 2 < b.length) {
    const n: number = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63) +
      B64_CHARS.charAt((n >> 6) & 63) + B64_CHARS.charAt(n & 63);
    i += 3;
  }
  const rest: number = b.length - i;
  if (rest === 1) {
    const n: number = b[i] << 16;
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63) + '==';
  } else if (rest === 2) {
    const n: number = (b[i] << 16) | (b[i + 1] << 8);
    out += B64_CHARS.charAt((n >> 18) & 63) + B64_CHARS.charAt((n >> 12) & 63) +
      B64_CHARS.charAt((n >> 6) & 63) + '=';
  }
  return out;
}

export function base64ToBytes(s: string): Uint8Array {
  const clean: string = s.replace(/[^A-Za-z0-9+/=]/g, '');
  const len: number = Math.floor(clean.length * 3 / 4) - (clean.endsWith('==') ? 2 : (clean.endsWith('=') ? 1 : 0));
  const out: Uint8Array = new Uint8Array(len > 0 ? len : 0);
  let p: number = 0;
  for (let i = 0; i + 3 < clean.length; i += 4) {
    const a: number = B64_CHARS.indexOf(clean.charAt(i));
    const b: number = B64_CHARS.indexOf(clean.charAt(i + 1));
    const c: number = clean.charAt(i + 2) === '=' ? -1 : B64_CHARS.indexOf(clean.charAt(i + 2));
    const d: number = clean.charAt(i + 3) === '=' ? -1 : B64_CHARS.indexOf(clean.charAt(i + 3));
    if (a < 0 || b < 0) { continue; }
    const n: number = (a << 18) | (b << 12) | ((c < 0 ? 0 : c) << 6) | (d < 0 ? 0 : d);
    if (p < out.length) { out[p++] = (n >> 16) & 0xff; }
    if (c >= 0 && p < out.length) { out[p++] = (n >> 8) & 0xff; }
    if (d >= 0 && p < out.length) { out[p++] = n & 0xff; }
  }
  return out;
}

/** MD5（十六进制小写） */
export async function md5Hex(s: string): Promise<string> {
  return await md5HexBytes(utf8ToBytes(s));
}

export async function md5HexBytes(data: Uint8Array): Promise<string> {
  const md = cryptoFramework.createMd('MD5');
  const blob: cryptoFramework.DataBlob = { data };
  await md.update(blob);
  const out: cryptoFramework.DataBlob = await md.digest();
  return bytesToHex(out.data);
}

/** SHA1（十六进制小写，供 tx zzcSign 使用） */
export async function sha1Hex(s: string): Promise<string> {
  const md = cryptoFramework.createMd('SHA1');
  const blob: cryptoFramework.DataBlob = { data: utf8ToBytes(s) };
  await md.update(blob);
  const out: cryptoFramework.DataBlob = await md.digest();
  return bytesToHex(out.data);
}

/**
 * AES-128-ECB 加密。
 * transformation 传 'AES128|ECB|PKCS7'（wy eapi / linuxapi 等），
 * 或 'AES128|ECB|NoPadding'（需自行补齐 16 字节倍数）。
 */
export async function aes128EcbEncrypt(plain: Uint8Array, key: Uint8Array,
  transformation: string): Promise<Uint8Array> {
  const gen = cryptoFramework.createSymKeyGenerator('AES128');
  const keyBlob: cryptoFramework.DataBlob = { data: key };
  const symKey: cryptoFramework.SymKey = await gen.convertKey(keyBlob);
  const cipher = cryptoFramework.createCipher(transformation);
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, null);
  const inBlob: cryptoFramework.DataBlob = { data: plain };
  const out: cryptoFramework.DataBlob = await cipher.doFinal(inBlob);
  return out.data;
}

/** AES-128-ECB-PKCS7 → 大写 hex（wy eapi 的 params） */
export async function aesEcbPkcs7HexUpper(plain: string, key: string): Promise<string> {
  const out: Uint8Array = await aes128EcbEncrypt(utf8ToBytes(plain), utf8ToBytes(key), 'AES128|ECB|PKCS7');
  return bytesToHexUpper(out);
}

/** AES-128-ECB 解密 */
export async function aes128EcbDecrypt(cipher: Uint8Array, key: Uint8Array,
  transformation: string): Promise<Uint8Array> {
  const gen = cryptoFramework.createSymKeyGenerator('AES128');
  const keyBlob: cryptoFramework.DataBlob = { data: key };
  const symKey: cryptoFramework.SymKey = await gen.convertKey(keyBlob);
  const dec = cryptoFramework.createCipher(transformation);
  await dec.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);
  const inBlob: cryptoFramework.DataBlob = { data: cipher };
  const out: cryptoFramework.DataBlob = await dec.doFinal(inBlob);
  return out.data;
}

/** AES-128-ECB-PKCS7 加密 → base64（kw wbdCrypto.buildParam / wy linuxapi） */
export async function aesEcbPkcs7EncryptBase64(plain: string, key: Uint8Array): Promise<string> {
  const out: Uint8Array = await aes128EcbEncrypt(utf8ToBytes(plain), key, 'AES128|ECB|PKCS7');
  return bytesToBase64(out);
}

/** AES-128-ECB-PKCS7 解密 base64 密文 → UTF-8（kw wbdCrypto.decodeData） */
export async function aesEcbPkcs7DecryptUtf8(cipherBase64: string, key: Uint8Array): Promise<string> {
  const cipher: Uint8Array = base64ToBytes(cipherBase64);
  const out: Uint8Array = await aes128EcbDecrypt(cipher, key, 'AES128|ECB|PKCS7');
  return bytesToUtf8(out);
}

/**
 * AES-128-CBC-PKCS7 加密（wy weapi 第一/二层）。
 * key / iv 均为原始字节（16 字节）。
 */
export async function aes128CbcEncrypt(plain: Uint8Array, key: Uint8Array,
  iv: Uint8Array): Promise<Uint8Array> {
  const gen = cryptoFramework.createSymKeyGenerator('AES128');
  const symKey: cryptoFramework.SymKey = await gen.convertKey({ data: key });
  const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
  const ivParams: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: iv } };
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivParams);
  const out: cryptoFramework.DataBlob = await cipher.doFinal({ data: plain });
  return out.data;
}

