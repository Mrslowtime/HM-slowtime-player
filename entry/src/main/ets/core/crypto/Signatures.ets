/**
 * 三家在线音乐服务的请求签名生成器。
 *
 * 这些签名是各服务私有协议的公开可互操作实现：
 * - mg：MD5(关键词 + 固定盐 + 设备号 + 毫秒时间戳)
 * - tx：SHA1 摘要 → 定长索引抽字符 → 扰乱表逐字节 XOR → base64 → 拼接小写
 * - wy eapi：MD5 摘要 + 分隔符拼装 → AES-128-ECB-PKCS7 → 大写 hex
 * - wy weapi：AES-CBC 双层加密 → base64 → URL 编码，附固定 encSecKey
 * - wy linuxapi：AES-128-ECB → 大写 hex
 *
 * 盐值、索引表、扰乱表与固定密钥均属于协议事实数据，不是可替换的实现细节。
 * 本文件把它们集中为常量表，签名流程按"摘要 → 变换 → 编码"三步组织。
 */
import {
  md5Hex, sha1Hex, aesEcbPkcs7HexUpper, bytesToBase64, utf8ToBytes,
  aes128CbcEncrypt, aes128EcbEncrypt, bytesToHexUpper,
} from './Crypto';
import { getMgDeviceId } from '../DeviceId';

// ---------------- 协议常量（事实数据）----------------

/** 咪咕签名盐 */
const MG_SALT: string = '6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50';

/** QQ 签名摘要字符抽取位置 */
const TX_HEAD_PICK: readonly number[] = [23, 14, 6, 36, 16, 40, 7, 19];
const TX_TAIL_PICK: readonly number[] = [16, 1, 32, 12, 19, 27, 8, 5];
/** QQ 签名字节扰乱掩码 */
const TX_MASK: readonly number[] = [
  89, 39, 179, 150, 218, 82, 58, 252, 177, 52,
  186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
];

/** 网易 eapi 摘要前后缀与分隔串 */
const WY_DIGEST_PREFIX: string = 'nobody';
const WY_DIGEST_SUFFIX: string = 'use';
const WY_DIGEST_TAIL: string = 'md5forencrypt';
const WY_SEPARATOR: string = '-36cd479b6b5-';
const WY_EAPI_KEY: string = 'e82ckenh8dichen8';

/** 网易 weapi / linuxapi 固定密钥材料 */
const WY_CBC_IV: Uint8Array = utf8ToBytes('0102030405060708');
const WY_CBC_KEY: Uint8Array = utf8ToBytes('0CoJUm6Qyw8W8jud');
const WY_SESSION_KEY: Uint8Array = utf8ToBytes('1234567890abcdef');
const WY_LINUX_KEY: Uint8Array = utf8ToBytes('rFgB&h#%2?^eDg:Q');
/** 与 WY_SESSION_KEY 配套的预生成 RSA 密文（协议固定值） */
const WY_ENC_SEC_KEY: string =
  'bc05a756cb87b1a2674efda9e90a27d641dcbbe2e6b7be3b61193e47315c298183d409' +
  '578ac80502bd441d82bf1611d6d9238bcaf64794d096417b726373fdd8cf4a9e9d31d198' +
  'd6d785ffa3d0a2e8c621b4d6c019fabe0ca6f3a815d9f2a4875a0bcab968f331f394566' +
  'e1162603ed1dd002aa89b47fd8dcbc77d2c6976efed';

// ---------------- 抽取 / 变换辅助 ----------------

/** 从摘要按给定位置抽字符；越界位置按协议输出空串（跳过） */
function pickDigestChars(digest: string, positions: readonly number[]): string {
  let picked: string = '';
  for (const pos of positions) {
    if (pos < digest.length) {
      picked += digest.charAt(pos);
    }
  }
  return picked;
}

/** 用扰乱掩码逐字节异或摘要前 40 个十六进制字符对应的字节 */
function maskDigestBytes(digest: string): Uint8Array {
  const masked: Uint8Array = new Uint8Array(TX_MASK.length);
  for (let i: number = 0; i < TX_MASK.length; i++) {
    const digestByte: number = parseInt(digest.substring(i * 2, i * 2 + 2), 16);
    masked[i] = (TX_MASK[i] ^ digestByte) & 0xff;
  }
  return masked;
}

/** base64 后去掉 URL 敏感字符与填充符 */
function urlSafeB64(data: Uint8Array): string {
  return bytesToBase64(data).replace(/[\/+=]/g, '');
}

// ---------------- 对外签名入口 ----------------

/** 咪咕搜索签名 */
export async function mgSignature(keyword: string, timeMs: string): Promise<string> {
  const deviceId: string = await getMgDeviceId();
  const payload: string = keyword + MG_SALT + deviceId + timeMs;
  return await md5Hex(payload);
}

/** QQ 音乐搜索签名 */
export async function txZzcSign(text: string): Promise<string> {
  const digest: string = await sha1Hex(text);
  const head: string = pickDigestChars(digest, TX_HEAD_PICK);
  const tail: string = pickDigestChars(digest, TX_TAIL_PICK);
  const middle: string = urlSafeB64(maskDigestBytes(digest));
  return ('zzc' + head + middle + tail).toLowerCase();
}

/** 网易 eapi 参数加密（返回大写 hex） */
export async function wyEapiParams(url: string, text: string): Promise<string> {
  const digestInput: string = WY_DIGEST_PREFIX + url + WY_DIGEST_SUFFIX + text + WY_DIGEST_TAIL;
  const digest: string = await md5Hex(digestInput);
  const plain: string = url + WY_SEPARATOR + text + WY_SEPARATOR + digest;
  return await aesEcbPkcs7HexUpper(plain, WY_EAPI_KEY);
}

/** 网易 weapi 表单（params + encSecKey） */
export async function wyWeapiForm(text: string): Promise<string> {
  const inner: Uint8Array = await aes128CbcEncrypt(utf8ToBytes(text), WY_CBC_KEY, WY_CBC_IV);
  const outer: Uint8Array = await aes128CbcEncrypt(
    utf8ToBytes(bytesToBase64(inner)), WY_SESSION_KEY, WY_CBC_IV);
  return 'params=' + encodeURIComponent(bytesToBase64(outer)) + '&encSecKey=' + WY_ENC_SEC_KEY;
}

/** 网易 linuxapi 表单（eparams） */
export async function wyLinuxapiForm(text: string): Promise<string> {
  const encrypted: Uint8Array = await aes128EcbEncrypt(
    utf8ToBytes(text), WY_LINUX_KEY, 'AES128|ECB|PKCS7');
  return 'eparams=' + bytesToHexUpper(encrypted);
}
