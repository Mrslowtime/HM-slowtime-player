/**
 * 酷我榜单接口的请求签名与响应解密。
 *
 * 榜单请求体用固定密钥做 AES-128-ECB-PKCS7 加密后 base64，
 * 再与 appId、时间戳一起做 MD5 得到签名；响应体是 URL 编码的 base64 密文。
 * 协议里 ECB 的实际填充为 PKCS7（等价于 Java 'AES' 默认行为）。
 */
import {
  base64ToBytes, md5Hex, aesEcbPkcs7EncryptBase64, aesEcbPkcs7DecryptUtf8,
} from './Crypto';
import { Json } from '../net/HttpClient';

/** 榜单接口固定密钥与 appId（协议常量） */
const WBD_KEY: Uint8Array = base64ToBytes('cFcnPcf6Kb85RC1y3V6M5A==');
const WBD_APP_ID: string = 'y67sprxhhpws';

/** 由 appId、密文、时间戳拼出大写 MD5 签名 */
async function wbdSign(encrypted: string, time: string): Promise<string> {
  const raw: string = WBD_APP_ID + encrypted + time;
  return (await md5Hex(raw)).toUpperCase();
}

/** 构造榜单请求 query（data / time / appId / sign） */
export async function buildWbdParam(jsonBody: string): Promise<string> {
  const time: string = Date.now().toString();
  const encrypted: string = await aesEcbPkcs7EncryptBase64(jsonBody, WBD_KEY);
  const signature: string = await wbdSign(encrypted, time);
  return 'data=' + encodeURIComponent(encrypted) + '&time=' + time +
    '&appId=' + WBD_APP_ID + '&sign=' + signature;
}

/** 解密榜单响应（响应体是 URL 编码过的 base64 密文） */
export async function decodeWbdResponse(rawBody: string): Promise<Object | null> {
  let encoded: string = rawBody.trim();
  try {
    encoded = decodeURIComponent(encoded);
  } catch (e) {
    // 未编码时保持原样
  }
  if (encoded.length === 0) {
    return null;
  }
  try {
    const plain: string = await aesEcbPkcs7DecryptUtf8(encoded, WBD_KEY);
    return Json.parse(plain);
  } catch (e) {
    return null;
  }
}

/** 内置榜单列表（id + 名称，协议固定的目录数据） */
export const KW_BOARDS: string[][] = [
  ['93', '飙升榜'], ['17', '新歌榜'], ['16', '热歌榜'], ['158', '抖音热歌榜'],
  ['292', '铃声榜'], ['284', '热评榜'], ['290', 'ACG新歌榜'], ['286', '台湾KKBOX榜'],
  ['279', '冬日暖心榜'], ['281', '巴士随身听榜'], ['255', 'KTV点唱榜'],
  ['280', '家务进行曲榜'], ['282', '熬夜修仙榜'], ['283', '枕边轻音乐榜'],
  ['278', '古风音乐榜'], ['264', 'Vlog音乐榜'], ['242', '电音榜'],
  ['187', '流行趋势榜'], ['204', '现场音乐榜'], ['186', 'ACG神曲榜'],
  ['185', '最强翻唱榜'], ['26', '经典怀旧榜'], ['104', '华语榜'],
  ['182', '粤语榜'], ['22', '欧美榜'], ['184', '韩语榜'], ['183', '日语榜'],
  ['145', '会员畅听榜'], ['153', '网红新歌榜'], ['64', '影视金曲榜'],
  ['176', 'DJ嗨歌榜'], ['106', '真声音'], ['12', 'Billboard榜'],
  ['49', 'iTunes音乐榜'], ['180', 'beatport电音榜'], ['13', '英国UK榜'],
  ['164', '百大DJ榜'], ['246', 'YouTube音乐排行榜'], ['265', '韩国Genie榜'],
  ['14', '韩国M-net榜'], ['8', '香港电台榜'], ['15', '日本公信榜'],
  ['151', '腾讯音乐人原创榜'],
];

/** 各榜单封面地址（静态目录数据，运行时无需额外请求） */
export const KW_BOARD_IMGS: Record<string, string> = {
  '93': 'https://zimg.kuwo.cn/bang/4/3/1794880803899_489929.png',
  '17': 'https://zimg.kuwo.cn/bang/1/4/1794880802562_489928.png',
  '16': 'https://zimg.kuwo.cn/bang/1/4/1794880800962_489927.png',
  '158': 'https://zimg.kuwo.cn/bang/6/7/1794880809246_490022.png',
  '292': 'https://img1.kwcdn.kuwo.cn/star/upload/4/4/1602561265876_.png',
  '284': 'https://zimg.kuwo.cn/bang/1/5/1794880873176_532836.png',
  '290': 'https://img4.kuwo.cn/star/albumcover/120/s3s70/32/3981367179.jpg',
  '286': 'https://img4.kuwo.cn/star/albumcover/120/s4s39/21/806428016.jpg',
  '279': 'https://img4.kuwo.cn/star/albumcover/120/s4s6/93/1823888016.jpg',
  '281': 'https://img4.kuwo.cn/star/albumcover/120/s4s4/98/1020404523.jpg',
  '255': 'https://zimg.kuwo.cn/bang/0/3/1794880904470_532517.png',
  '280': 'https://img4.kuwo.cn/star/albumcover/120/s4s67/21/834133816.jpg',
  '282': 'https://img4.kuwo.cn/star/albumcover/120/s4s95/35/836441677.png',
  '283': 'https://img4.kuwo.cn/star/albumcover/120/s4s50/90/2227912404.jpg',
  '278': 'https://zimg.kuwo.cn/bang/4/3/1794880871928_532224.png',
  '264': 'https://img4.kuwo.cn/star/albumcover/120/s4s15/81/2985702596.jpg',
  '242': 'https://zimg.kuwo.cn/bang/9/6/1794880865750_531674.png',
  '187': 'https://zimg.kuwo.cn/bang/1/2/1794880859193_510021.png',
  '204': 'https://img4.kuwo.cn/star/albumcover/120/s4s26/85/2791637171.jpg',
  '186': 'https://img4.kuwo.cn/star/albumcover/120/65/1/1261222476.jpg',
  '185': 'https://img4.kuwo.cn/star/albumcover/120/s4s0/42/3070715981.jpg',
  '26': 'https://zimg.kuwo.cn/bang/0/2/1794880827906_490003.png',
  '104': 'https://zimg.kuwo.cn/bang/0/6/1794880892163_509833.png',
  '182': 'https://zimg.kuwo.cn/bang/1/3/1794880893603_509834.png',
  '22': 'https://zimg.kuwo.cn/bang/6/6/1794880894813_509835.png',
  '184': 'https://zimg.kuwo.cn/bang/6/2/1794880896122_509836.png',
  '183': 'https://zimg.kuwo.cn/bang/3/2/1794880897239_509837.png',
  '145': 'https://zimg.kuwo.cn/bang/5/1/1794880817439_507077.png',
  '153': 'https://zimg.kuwo.cn/bang/2/6/1794880833175_490015.png',
  '64': 'https://zimg.kuwo.cn/bang/2/6/1794880831788_490014.png',
  '176': 'https://zimg.kuwo.cn/bang/6/9/1794880826686_534778.png',
  '106': 'https://img4.kuwo.cn/star/albumcover/120/s4s34/2/3953688999.jpg',
  '12': 'https://img4.kwcdn.kuwo.cn/star/upload/10/10/1649672653402_.jpg',
  '49': 'https://img4.kuwo.cn/star/albumcover/120/s4s53/70/1562705460.jpg',
  '180': 'https://img1.kwcdn.kuwo.cn/star/upload/0/0/1649672695520_.jpg',
  '13': 'https://img3.kwcdn.kuwo.cn/star/upload/2/2/1649672715090_.jpg',
  '164': 'https://img3.kwcdn.kuwo.cn/star/upload/10/10/1649672739226_.jpg',
  '246': 'https://img3.kwcdn.kuwo.cn/star/upload/7/7/1649672755016_.jpg',
  '265': 'https://img4.kuwo.cn/star/albumcover/120/s4s75/20/2712362530.jpg',
  '14': 'https://img4.kuwo.cn/star/albumcover/120/s4s0/72/3386335573.jpg',
  '8': 'https://img1.kwcdn.kuwo.cn/star/upload/9/9/1543921202361_.png',
  '15': 'https://img1.kwcdn.kuwo.cn/star/upload/14/14/1649672798206_.jpg',
  '151': 'https://img4.kuwo.cn/star/albumcover/120/s3s84/40/1165702969.jpg',
};
