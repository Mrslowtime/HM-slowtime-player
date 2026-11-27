/**
 * 本地歌曲封面 —— 只保留一条路径：**在线多源搜索取图 → 存封面缓存**。
 *
 * 历史包袱说明（2026-11-21 用户明确要求简化）：
 *   以前为了「省请求」堆了四层兜底 —— 同目录同名图 / 内嵌封面导出 / 下载记录里的
 *   封面地址 / 列表里同一首歌的地址，再加上扫描后自动联网补。结果链路互相遮掩：
 *   封面拿到了又被淘汰、同一首歌不同对象显示不一致、失败记录误判……问题反复。
 *
 * 现在的规则只有一条：
 *   本地歌没有封面 → 用户在播放页点「唱片」图标 → SongMatcher 按「歌名 + 歌手 + 时长」
 *   到酷我 → QQ → 酷狗 → 网易 多源搜索，标题与歌手双命中即停 → 取那个源的封面
 *   下载下来存进封面缓存（filesDir/local_covers，独立目录，不被在线封面淘汰）。
 *
 * 播放、扫描、切歌都不会自己联网，也不会去猜本地文件里的图。
 * 同目录同名 jpg 属于「用户自己的文件」，仍由扫描器按原优先级读取（那是文件自带封面，
 * 不算应用去「取」封面）；除此之外不再有任何兜底。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { CoverCache } from './ImageCache';

const MIGU_HOST: string = 'https://d.musicapp.migu.cn';

/**
 * 封面地址规范化：网易/酷狗常给 `//host/...`（协议相对），咪咕给 `/star/...`（站内相对），
 * 直接丢给取图会失败 —— 统一补齐。已经是完整地址的原样返回。
 */
export function fixCoverUrl(raw: string): string {
  const u: string = raw.trim();
  if (u.length < 4) {
    return '';
  }
  if (u.indexOf('//') === 0) {
    return 'https:' + u;
  }
  if (u.indexOf('/') === 0) {
    return MIGU_HOST + u;
  }
  return u;
}

/**
 * 把在线封面下载后存进「本地封面缓存」（独立目录，不参与在线封面淘汰）。
 *
 * @param path 本地音频文件路径（作为缓存键，同一首歌永远命中同一张）
 * @param url  已匹配到的在线封面地址
 * @returns 缓存文件裸路径（不带 file://）；失败返回空串
 */
export async function saveDownloadCover(path: string, url: string): Promise<string> {
  if (path.length === 0 || url.length === 0) {
    return '';
  }
  const u: string = fixCoverUrl(url);
  if (u.length === 0) {
    return '';
  }
  try {
    const local: string = await CoverCache.getInstance().putUrl(path, u);
    if (local.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'local cover save failed: %{public}s', u.substring(0, 40));
      return '';
    }
    return local.indexOf('file://') === 0 ? local.substring('file://'.length) : local;
  } catch (e) {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'local cover save error');
    return '';
  }
}
