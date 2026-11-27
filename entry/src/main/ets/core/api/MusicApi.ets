/**
 * 音源聚合入口 —— 按 sources 聚合。
 * 上层（UI / PlayController）只依赖本模块，不感知 kw/kg/tx/wy/mg 各自差异。
 * searchAll 按「全部」音源约定 时的多源并发聚合。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MusicInfo, ListInfoItem, BoardItem, LyricInfo } from '../../model/MusicTypes';
import { OnlineSource, ONLINE_SOURCES } from '../../config/AppConstants';
import { LOG_DOMAIN, LOG_TAG } from '../../common/Constants';
import {
  SourceApi, SearchResult, SonglistResult, MusicListResult, TagResult,
  emptySearchResult, emptySonglistResult,
} from './ApiTypes';
import { KwApi } from './KwApi';
import { KgApi } from './KgApi';
import { TxApi, MgApi, WyApi } from './OtherApis';

export interface MultiSearchResult {
  list: MusicInfo[];
  total: number;
  errors: string[];
  /** 是否还有下一页：聚合后 list 长度是各家之和，不能用 `>= limit` 直接判断 */
  hasMore: boolean;
}

/** 「全部」音源下的歌单搜索结果（各源串行交错合并） */
export interface MultiSonglistResult {
  list: ListInfoItem[];
  errors: string[];
  hasMore: boolean;
}

let sInstance: MusicApi | null = null;

export class MusicApi {
  private apis: Map<string, SourceApi> = new Map();
  private hotCache: Map<string, string[]> = new Map();

  static getInstance(): MusicApi {
    if (sInstance === null) {
      sInstance = new MusicApi();
    }
    return sInstance;
  }

  private constructor() {
    this.apis.set('kw', new KwApi());
    this.apis.set('kg', new KgApi());
    this.apis.set('tx', new TxApi());
    this.apis.set('mg', new MgApi());
    this.apis.set('wy', new WyApi());
  }

  getApi(source: OnlineSource): SourceApi {
    const api: SourceApi | undefined = this.apis.get(source);
    return api !== undefined ? api : new KwApi();
  }

  /** 五家搜索已全部打通（kw/kg 直连，tx zzcSign、mg MD5、wy eapi 签名） */
  supportsSearch(source: OnlineSource): boolean {
    return ONLINE_SOURCES.includes(source);
  }

  /** 可搜索的源列表（供 UI 下拉使用，避免用户选到未实现的源） */
  searchableSources(): OnlineSource[] {
    const out: OnlineSource[] = [];
    for (const s of ONLINE_SOURCES) {
      if (this.supportsSearch(s)) {
        out.push(s);
      }
    }
    return out;
  }

  async search(source: OnlineSource, keyword: string, page: number, limit: number): Promise<SearchResult> {
    if (keyword.trim().length === 0) {
      return emptySearchResult(source, page, limit);
    }
    const r: SearchResult = await this.getApi(source).search(keyword.trim(), page, limit);
    if (r.error.length > 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'search %{public}s failed: %{public}s', source, r.error);
    }
    return r;
  }

  /**
   * 多源聚合（按多源并发聚合约定），按源轮流交错合并。
   *
   * 注意：这里是**串行**逐个 await，不是并发。5 个平台同时发会把瞬时请求数翻 5 倍，
   * 串行则是「一个回来再发下一个」，天然有节奏，对平台也更友好；代价是首屏稍慢一点。
   */
  async searchAll(keyword: string, page: number, limit: number): Promise<MultiSearchResult> {
    const sources: OnlineSource[] = this.searchableSources();
    const results: SearchResult[] = [];
    for (const s of sources) {
      results.push(await this.search(s, keyword, page, limit));
    }
    const list: MusicInfo[] = [];
    const errors: string[] = [];
    let total: number = 0;
    // 只要有一家返回满页，就说明还可能翻到下一页
    let hasMore: boolean = false;
    for (const r of results) {
      total += r.total;
      if (r.error.length > 0) {
        errors.push(r.error);
      }
      if (r.list.length >= limit) {
        hasMore = true;
      }
    }
    // 交错合并：kw[0], kg[0], kw[1], kg[1] ... 按源分组前的展示习惯
    const maxLen: number = results.reduce((m: number, r: SearchResult): number => {
      return r.list.length > m ? r.list.length : m;
    }, 0);
    for (let i = 0; i < maxLen; i++) {
      for (const r of results) {
        if (i < r.list.length) {
          list.push(r.list[i]);
        }
      }
    }
    return { list, total, errors, hasMore };
  }

  /** 支持「搜歌单」的音源：酷我 / 酷狗 / 网易（QQ、咪咕的签名只覆盖单曲） */
  playlistSearchSources(): OnlineSource[] {
    const out: OnlineSource[] = [];
    for (const s of ONLINE_SOURCES) {
      if (s === 'kw' || s === 'kg' || s === 'wy') {
        out.push(s);
      }
    }
    return out;
  }

  /** 单源搜歌单 */
  async searchPlaylists(source: OnlineSource, keyword: string, page: number, limit: number): Promise<SonglistResult> {
    const kw: string = keyword.trim();
    if (kw.length === 0) {
      return emptySonglistResult(source, page, limit);
    }
    const r: SonglistResult = await this.getApi(source).searchPlaylists(kw, page, limit);
    if (r.error.length > 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'searchPlaylists %{public}s failed: %{public}s', source, r.error);
    }
    return r;
  }

  /**
   * 「全部」音源下的歌单搜索：只串行问支持的三家（kw/kg/wy），再交错合并。
   * 与 searchAll 同理，串行是为了不把瞬时请求数翻倍。
   */
  async searchPlaylistsAll(keyword: string, page: number, limit: number): Promise<MultiSonglistResult> {
    const sources: OnlineSource[] = this.playlistSearchSources();
    const results: SonglistResult[] = [];
    for (const s of sources) {
      results.push(await this.searchPlaylists(s, keyword, page, limit));
    }
    const list: ListInfoItem[] = [];
    const errors: string[] = [];
    let hasMore: boolean = false;
    for (const r of results) {
      if (r.error.length > 0) {
        errors.push(r.error);
      }
      if (r.list.length >= limit) {
        hasMore = true;
      }
    }
    const maxLen: number = results.reduce((m: number, r: SonglistResult): number => {
      return r.list.length > m ? r.list.length : m;
    }, 0);
    for (let i = 0; i < maxLen; i++) {
      for (const r of results) {
        if (i < r.list.length) {
          list.push(r.list[i]);
        }
      }
    }
    return { list, errors, hasMore };
  }

  async tipSearch(source: OnlineSource, keyword: string): Promise<string[]> {
    return await this.getApi(source).tipSearch(keyword);
  }

  async hotSearch(source: OnlineSource): Promise<string[]> {
    const cached: string[] | undefined = this.hotCache.get(source);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    const words: string[] = await this.getApi(source).hotSearch();
    if (words.length > 0) {
      this.hotCache.set(source, words);
    }
    return words;
  }

  /**
   * 启动时预取热搜词：搜索页本来就要用，提前请求可让首屏更快；
   * 同时作为真机网络链路自检（HiLog 会打印条数），便于排查 @ohos.net.http / TLS / 权限问题。
   */
  async warmUp(): Promise<void> {
    const words: string[] = await this.hotSearch('kw');
    hilog.info(LOG_DOMAIN, LOG_TAG, 'network self-check: hotSearch %{public}d words', words.length);
    if (words.length === 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'network self-check: empty result, check INTERNET/TLS');
    }
    // 真机已验证（2026-11-10）：kw 热搜 20 词；五家搜索全部返回真实歌曲
    // （kw 晴天 / kg 发如雪 / tx 发如雪 / wy 想你就写信 / mg 圣诞星），
    // 证明 @ohos.net.http、cryptoFramework 签名与字段映射链路全通。
    // 此处不额外发搜索请求，避免每次启动多 5 次网络调用。
  }

  async songListTags(source: OnlineSource): Promise<TagResult> {
    return await this.getApi(source).songListTags();
  }

  async songList(source: OnlineSource, tagId: string, sortId: string, page: number,
    limit: number): Promise<SonglistResult> {
    return await this.getApi(source).songList(tagId, sortId, page, limit);
  }

  async songListDetail(source: OnlineSource, id: string, page: number): Promise<MusicListResult> {
    return await this.getApi(source).songListDetail(id, page);
  }

  leaderboardCategories(source: OnlineSource): BoardItem[] {
    return this.getApi(source).leaderboardCategories();
  }

  async leaderboardDetail(source: OnlineSource, bangid: string, page: number): Promise<MusicListResult> {
    return await this.getApi(source).leaderboardDetail(bangid, page);
  }

  async getLyric(info: MusicInfo): Promise<LyricInfo | null> {
    if (info.source === 'local') {
      return null;
    }
    return await this.getApi(info.source as OnlineSource).getLyric(info);
  }

  async getPic(info: MusicInfo): Promise<string> {
    if (info.source === 'local') {
      return '';
    }
    return await this.getApi(info.source as OnlineSource).getPic(info);
  }
}
