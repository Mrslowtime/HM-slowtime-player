/**
 * 歌单歌曲数缓存（内存，进程内有效）。
 *
 * 各平台歌单广场接口给的字段并不一致：酷我 `total`、酷狗 `song_count`、QQ `song_cnt`、
 * 网易 `trackCount` 都有，咪咕（米咕 pc 广场 page-data）**完全不返回歌曲数**。
 * 咪咕想要数字只能按歌单 id 单独查详情（每首 93KB），一个网络页 125 个歌单不可能逐个查。
 *
 * 这里做一层「拿到就记住」：用户点进任意歌单，详情接口返回 total 后回填，
 * 返回列表时该卡片就能显示「N 首」。代价为零，且滑到第二页也不会重复请求。
 */
export class PlaylistCountCache {
  private static map: Map<string, number> = new Map<string, number>();

  private static key(source: string, id: string): string {
    return source + ':' + id;
  }

  /** 记录歌单歌曲数（<=0 视为未知，不写） */
  static put(source: string, id: string, total: number): void {
    if (id.length === 0 || total <= 0) {
      return;
    }
    PlaylistCountCache.map.set(PlaylistCountCache.key(source, id), total);
  }

  /** 取歌单歌曲数；未知返回 0 */
  static get(source: string, id: string): number {
    const v: number | undefined = PlaylistCountCache.map.get(PlaylistCountCache.key(source, id));
    return v === undefined ? 0 : v;
  }
}
