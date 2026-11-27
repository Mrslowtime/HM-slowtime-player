/**
 * 歌曲信息自动匹配（封面 + 歌词）—— 按协议的取图逻辑。
 *
 * 本协议的做法：每首歌的封面不是一个「固定字段」，而是「用这首歌的身份（歌名 / 歌手 / 时长）
 * 去各音源找同一首歌，找到后取那个源给的封面地址」。所以只要真的发起搜索、且歌名歌手对得上，
 * 封面基本一定拿得到；顺带还能拿到那个源的歌词（同一次匹配结果复用，不额外请求）。
 *
 * 本模块就是这套逻辑：
 *   1) 按「歌名 + 歌手」逐个音源搜索，候选统一交给 LyricResolver.pickBestCandidate 严格打分
 *      （标题必须像、时长偏差过大直接淘汰、Live / 伴奏 / DJ 版本扣分）；
 *   2) 一旦某个源给出「标题全等 + 歌手命中」的高置信结果就停止，不再问下一家（省请求）；
 *   3) 命中后封面写到本地同名 jpg（本地歌）或写回 meta.picUrl（在线歌），
 *      歌词用同一个候选去取，命中就写进 MusicSource 的歌词缓存，播放器直接换词。
 *
 * 只在用户手动点「自动匹配歌词和封面」时调用，不参与自动流程。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MusicInfo, MusicInfoMetaLocal, MusicInfoMetaOnline, LyricInfo } from '../model/MusicTypes';
import { OnlineSource, SOURCE_NAMES } from '../config/AppConstants';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { MusicApi } from './api/MusicApi';
import { SearchResult } from './api/ApiTypes';
import {
  LyricCandidate, LyricTarget, normalizeLyricTitle, parseIntervalMs, pickBestCandidate,
  singerMatched, splitSingerNames,
} from './LyricResolver';
import { MusicSource } from './MusicSource';
import { saveDownloadCover, fixCoverUrl } from './LocalCover';

/** 匹配结果：给播放页按钮提示用 */
export interface SongMatchResult {
  matched: boolean;
  picOk: boolean;
  lyricOk: boolean;
  /** 命中的「歌名」「歌手」「音源名」，没匹配到时为空 */
  name: string;
  singer: string;
  sourceLabel: string;
}

/** 一次搜索的候选，保留原 MusicInfo 以便取图 / 取词 */
interface MatchCand {
  song: MusicInfo;
  lyric: LyricCandidate;
  source: OnlineSource;
}

/** 本地歌没有自己的音源信息，按「覆盖广度 + 搜索质量」排序：酷我 → QQ → 酷狗 → 网易 */
const LOCAL_SOURCE_ORDER: OnlineSource[] = ['kw', 'tx', 'kg', 'wy'];
/** 每个源只取前 10 条，够挑出同名同歌手的那一首 */
const SEARCH_LIMIT: number = 10;
/** 源与源之间停一下，避免一次点按把几个平台同时打 */
const GAP_MS: number = 200;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

function emptyResult(): SongMatchResult {
  return { matched: false, picOk: false, lyricOk: false, name: '', singer: '', sourceLabel: '' };
}

export class SongMatcher {
  private static sInstance: SongMatcher | null = null;
  /** 同一时刻只允许一次匹配（连点不会叠加请求） */
  private busy: boolean = false;

  static getInstance(): SongMatcher {
    if (SongMatcher.sInstance === null) {
      SongMatcher.sInstance = new SongMatcher();
    }
    return SongMatcher.sInstance;
  }

  isBusy(): boolean {
    return this.busy;
  }

  /**
   * 给一首歌重新匹配封面与歌词。
   * @param info 目标歌曲（本地歌或在线歌都行）
   */
  async match(info: MusicInfo): Promise<SongMatchResult> {
    if (this.busy) {
      return emptyResult();
    }
    const name: string = info.name.trim();
    if (name.length === 0) {
      return emptyResult();
    }
    this.busy = true;
    try {
      return await this.doMatch(info);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'song match failed: %{public}s', (e as Error).message);
      return emptyResult();
    } finally {
      this.busy = false;
    }
  }

  private async doMatch(info: MusicInfo): Promise<SongMatchResult> {
    const target: LyricTarget = {
      name: info.name,
      singer: info.singer,
      durationMs: parseIntervalMs(info.interval),
    };
    const keyword: string = info.singer.length > 0 && info.singer !== '未知歌手'
      ? info.name + ' ' + info.singer
      : info.name;

    // 顺序：在线的先用它自己的源（同源最准），再补通用源；本地直接用通用源顺序
    const order: OnlineSource[] = [];
    if (info.source !== 'local' && LOCAL_SOURCE_ORDER.indexOf(info.source) >= 0) {
      order.push(info.source);
    }
    for (const s of LOCAL_SOURCE_ORDER) {
      if (order.indexOf(s) < 0) {
        order.push(s);
      }
    }

    const pool: MatchCand[] = [];
    let best: MatchCand | null = null;
    for (const src of order) {
      const got: MatchCand[] = await this.searchOne(src, keyword);
      for (const c of got) {
        pool.push(c);
      }
      if (got.length === 0) {
        await sleep(GAP_MS);
        continue;
      }
      const picked: LyricCandidate | null = pickBestCandidate(pool.map((c: MatchCand): LyricCandidate => c.lyric), target);
      if (picked !== null) {
        best = this.findByCandidate(pool, picked);
      }
      // 高置信（标题归一化全等 + 歌手命中）就够可信，不再问下一家
      if (best !== null && this.isConfident(best, target)) {
        break;
      }
      await sleep(GAP_MS);
    }
    if (best === null) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'song match miss: %{public}s - %{public}s', info.name, info.singer);
      return emptyResult();
    }

    const result: SongMatchResult = emptyResult();
    result.matched = true;
    result.name = best.song.name;
    result.singer = best.song.singer;
    result.sourceLabel = SOURCE_NAMES[best.source] ?? best.source;

    // 封面：优先用搜索结果自带的图，没有再问该源的取图接口
    let url: string = best.song.meta.picUrl !== undefined && best.song.meta.picUrl !== null
      ? best.song.meta.picUrl : '';
    if (url.length === 0) {
      try {
        url = await MusicApi.getInstance().getPic(best.song);
      } catch (e) {
        url = '';
      }
    }
    // 网易/酷狗给协议相对地址、咪咕给站内相对路径，落地前统一补齐
    url = fixCoverUrl(url);
    if (url.length > 0) {
      result.picOk = await this.applyPic(info, url);
    }

    // 歌词：同一个候选（同一个源同一首）去取，命中就写进歌词缓存，播放器直接换词
    try {
      const lyr: LyricInfo | null = await MusicApi.getInstance().getLyric(best.song);
      if (lyr !== null && lyr.lyric.length > 0 && lyr.lyric.indexOf('[') >= 0) {
        MusicSource.getInstance().putLyric(info.id, lyr);
        result.lyricOk = true;
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'song match lyric failed');
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'song match hit: %{public}s -> %{public}s-%{public}s (%{public}s) pic=%{public}s lyric=%{public}s',
      info.name, best.song.name, best.song.singer, best.source,
      result.picOk ? 'y' : 'n', result.lyricOk ? 'y' : 'n');
    return result;
  }

  /** 单个源搜索并按「歌名 + 歌手」粗筛（真正的严格打分交给 pickBestCandidate） */
  private async searchOne(src: OnlineSource, keyword: string): Promise<MatchCand[]> {
    const out: MatchCand[] = [];
    try {
      const r: SearchResult = await MusicApi.getInstance().search(src, keyword, 1, SEARCH_LIMIT);
      for (const m of r.list) {
        const singers: string[] = splitSingerNames(m.singer);
        out.push({
          song: m,
          source: src,
          lyric: {
            id: m.id,
            name: m.name,
            singers: singers,
            durationMs: parseIntervalMs(m.interval),
          },
        });
      }
    } catch (e) {
      // 单个源出错不影响其它源
    }
    return out;
  }

  /** pickBestCandidate 返回的是池里同一个对象引用，按引用反查即可 */
  private findByCandidate(pool: MatchCand[], picked: LyricCandidate): MatchCand | null {
    for (const c of pool) {
      if (c.lyric === picked) {
        return c;
      }
    }
    for (const c of pool) {
      if (c.lyric.id === picked.id) {
        return c;
      }
    }
    return null;
  }

  /** 标题归一化全等 + 歌手命中 → 高置信，可以停止继续搜 */
  private isConfident(cand: MatchCand, target: LyricTarget): boolean {
    const a: string = normalizeLyricTitle(target.name);
    const b: string = normalizeLyricTitle(cand.song.name);
    if (a.length === 0 || a !== b) {
      return false;
    }
    const ts: string[] = splitSingerNames(target.singer);
    if (ts.length === 0) {
      return true;
    }
    return singerMatched(ts, cand.lyric.singers);
  }

  /**
   * 写封面：本地歌把图落到**封面缓存目录**（不写进歌曲所在文件夹），
   * 拿不到缓存文件时退回原始在线地址；在线歌直接改 meta。
   */
  private async applyPic(info: MusicInfo, url: string): Promise<boolean> {
    if (info.source === 'local') {
      const lm = info.meta as MusicInfoMetaLocal;
      if (lm === undefined || lm === null || lm.filePath.length === 0) {
        return false;
      }
      lm.picUrl = url;
      const jpg: string = await saveDownloadCover(lm.filePath, url);
      if (jpg.length > 0) {
        lm.picUrl = 'file://' + jpg;
        return true;
      }
      // 缓存没写成功也已经有可用的在线地址：本次播放照样能显示
      return url.length > 0;
    }
    const meta = info.meta as MusicInfoMetaOnline;
    if (meta === undefined || meta === null) {
      return false;
    }
    meta.picUrl = url;
    return true;
  }
}
