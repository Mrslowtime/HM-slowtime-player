/**
 * 封面 URL 解析 —— 底部播控栏与播放详情页共用，避免两处各写一套判断而分叉。
 *
 * 各音源返回的字段形态不统一：
 *  - 大多数是完整 https URL；
 *  - 网易/酷狗可能给 `//p1.music.126.net/...`（协议相对）；
 *  - 咪咕可能给 `/star/migu/...`（站内相对路径）。
 * 这里统一补全，判断不了就返回空串，由 UI 显示占位图。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { MusicInfo, MusicInfoMetaLocal } from '../model/MusicTypes';
import { CoverCache } from '../core/ImageCache';

const MIGU_HOST: string = 'https://d.musicapp.migu.cn';
/** 封面尺寸段正则：提到模块级复用，避免每次 hdCoverUrl 都 new RegExp（审查 P-19） */
const QQ_SIZE_RE: RegExp = new RegExp('R\\d+x\\d+M0');
const KG_SIZE_RE: RegExp = new RegExp('/stdmusic/\\d+/');

/**
 * 本地歌「同目录同名 jpg」兜底。
 *
 * 为什么需要：本地歌曲有两份对象 —— 扫描出来的那份带 picUrl，
 * 而「下载列表 / 我的列表」里存的是下载那一刻的对象，picUrl 往往是空的。
 * 用那种对象播放时，播控栏和播放页就显示不出封面，可文件旁边其实早就有同名 jpg 了。
 * 这里在解析阶段直接查一次磁盘，有就用（零网络、零解码）。
 */
function localSidecarCover(info: MusicInfo): string {
  const lm = info.meta as MusicInfoMetaLocal;
  if (lm === undefined || lm === null) {
    return '';
  }
  const path: string = lm.filePath;
  if (path.length === 0) {
    return '';
  }
  const dot: number = path.lastIndexOf('.');
  const jpg: string = (dot > 0 ? path.substring(0, dot) : path) + '.jpg';
  try {
    if (fs.accessSync(jpg) && fs.statSync(jpg).size > 1024) {
      return 'file://' + jpg;
    }
  } catch (e) {
    void e;
  }
  return '';
}

/**
 * 本地歌在「封面缓存」里的那张图（A 方案后存 filesDir/local_covers，不在歌曲旁边）。
 *
 * 必须用 filePath 而不是 picUrl 查：同一首本地歌在应用里有多份 MusicInfo 对象
 * （本地音乐扫描出来的、下载列表 / 我的列表里持久化的、播放队列里的），
 * 只有「当时被匹配的那个对象」的 picUrl 被写上了缓存路径。
 * 用户从列表重新点选播放时拿到的是另一份对象，picUrl 是空的 ——
 * 表现就是「用上一首/下一首切歌有封面，重新点选就没有」。
 * 这里按文件路径直接查一次磁盘（零网络），所有对象一视同仁。
 */
function cachedLocalCover(info: MusicInfo): string {
  const lm = info.meta as MusicInfoMetaLocal;
  if (lm === undefined || lm === null) {
    return '';
  }
  const path: string = lm.filePath;
  if (path.length === 0) {
    return '';
  }
  return CoverCache.getInstance().peekLocal(path);
}

/** 本地文件是否还在且内容像一张图（≥1KB）—— 缓存被清、图片被删时不能继续当成有封面 */
function fileUsable(path: string): boolean {
  try {
    return fs.accessSync(path) && fs.statSync(path).size > 1024;
  } catch (e) {
    return false;
  }
}

export function resolveCoverUrl(info: MusicInfo | null): string {
  if (info === null || info === undefined) {
    return '';
  }
  // 本地歌：同目录同名图 → 封面缓存（都按文件路径查，与对象里有没有 picUrl 无关）
  if (info.source === 'local') {
    const side: string = localSidecarCover(info);
    if (side.length > 0) {
      return side;
    }
    const cached: string = cachedLocalCover(info);
    if (cached.length > 0) {
      return cached;
    }
  }
  const pic: string | null | undefined = info.meta.picUrl;
  if (pic === undefined || pic === null) {
    return '';
  }
  const raw: string = pic.trim();
  if (raw.length < 4) {
    return '';
  }
  if (raw.indexOf('https://') === 0 || raw.indexOf('http://') === 0) {
    return raw;
  }
  // 本地图片（同目录图 / 封面缓存）：path 还在才返回。
  // 否则封面缓存被清、图片被删之后，界面会一直拿着死链显示占位图，
  // 而且上层会误判成「这首歌已经有封面」而不再重新匹配。
  if (raw.indexOf('file://') === 0) {
    if (fileUsable(raw.substring('file://'.length))) {
      return raw;
    }
    return '';
  }
  if (raw.indexOf('//') === 0) {
    return 'https:' + raw;
  }
  if (raw.indexOf('/') === 0) {
    return MIGU_HOST + raw;
  }
  return '';
}

/**
 * 封面升级为「清晰」地址（歌曲封面与歌单封面共用）。
 *
 * 只做能确定生效的 CDN 改写，其它域名一律原样返回（改错了会 404 变裂图）：
 *  - 腾讯 CDN：`T002R300x300M000` 里的尺寸段 `R宽x高M0` → `R800x800M0`（任意原尺寸都换）；
 *  - 网易 `music.126.net`：`?param=WxH` → `?param=800y800`，没有参数就补一个；
 *  - 酷狗 `imge.kugou.com/stdmusic/{size}/` → `stdmusic/800/`（已实测 800 可用）。
 *
 * 同一张图只是取更大尺寸，仍然只下载一次、缓存一份（CoverCache 按 URL 落盘），
 * 不增加请求次数，只是单张体积从 ~20KB 变成 ~100KB（落盘前会压成 800px JPEG，约 60~90KB）。
 */
export function hdCoverUrl(raw: string): string {
  if (raw.length === 0) {
    return raw;
  }
  const u: string = raw.trim();
  if (u.indexOf('gtimg.cn') >= 0 || u.indexOf('music.qq.com') >= 0) {
    if (u.indexOf('R800x800') >= 0) {
      return u;
    }
    // QQ 封面文件名里的尺寸段是通用的 `R180x180M000` / `R300x300M000` …，直接换掉数字
    return u.replace(QQ_SIZE_RE, 'R800x800M0');
  }
  if (u.indexOf('music.126.net') >= 0) {
    if (u.indexOf('param=800y800') >= 0) {
      return u;
    }
    const q: number = u.indexOf('?');
    if (q >= 0) {
      return u.substring(0, q) + '?param=800y800';
    }
    return u + '?param=800y800';
  }
  if (u.indexOf('imge.kugou.com/stdmusic/') >= 0) {
    if (u.indexOf('/stdmusic/800/') >= 0) {
      return u;
    }
    return u.replace(KG_SIZE_RE, '/stdmusic/800/');
  }
  return u;
}

/**
 * 歌曲封面（播控栏 / 播放页大封面用）：先补全协议，再升级尺寸。
 *
 * 与 `resolveCoverUrl` 的唯一差别就是尺寸；列表里不直接显示在线歌曲封面，
 * 所以整首歌只会取一张 800px 的图，播控栏与播放页共用同一份缓存，请求数不变。
 */
export function resolveCoverUrlHd(info: MusicInfo | null): string {
  const base: string = resolveCoverUrl(info);
  if (base.length === 0 || base.indexOf('file://') === 0) {
    return base;
  }
  return hdCoverUrl(base);
}
