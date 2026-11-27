/**
 * 音源元数据层统一契约 —— 各平台音源模块暴露的能力集合。
 * 各源实现同一组方法，MusicApi 按 source 分派，上层 UI 不感知各家差异。
 */
import {
  MusicInfo, ListInfoItem, BoardItem, TagInfoItem, SortInfo, LyricInfo,
  MusicInfoMetaOnline, MusicQualityType,
} from '../../model/MusicTypes';
import { OnlineSource, Quality } from '../../config/AppConstants';

export interface SearchResult {
  list: MusicInfo[];
  total: number;
  page: number;
  limit: number;
  source: OnlineSource;
  error: string;
}

export interface SonglistResult {
  list: ListInfoItem[];
  total: number;
  page: number;
  limit: number;
  source: OnlineSource;
  error: string;
}

export interface MusicListResult {
  list: MusicInfo[];
  total: number;
  page: number;
  source: OnlineSource;
  name: string;
  desc: string;
  img: string;
  error: string;
}

export interface TagResult {
  tags: TagInfoItem[];
  sorts: SortInfo[];
  source: OnlineSource;
  error: string;
}

export function emptySearchResult(source: OnlineSource, page: number, limit: number,
  error: string = ''): SearchResult {
  return { list: [], total: 0, page, limit, source, error };
}

export function emptySonglistResult(source: OnlineSource, page: number, limit: number,
  error: string = ''): SonglistResult {
  return { list: [], total: 0, page, limit, source, error };
}

export function emptyMusicListResult(source: OnlineSource, page: number,
  error: string = ''): MusicListResult {
  return { list: [], total: 0, page, source, name: '', desc: '', img: '', error };
}

export function emptyTagResult(source: OnlineSource, error: string = ''): TagResult {
  return { tags: [], sorts: [], source, error };
}

/** 单个音源需要实现的能力 */
export interface SourceApi {
  readonly source: OnlineSource;
  search(keyword: string, page: number, limit: number): Promise<SearchResult>;
  tipSearch(keyword: string): Promise<string[]>;
  hotSearch(): Promise<string[]>;
  songListTags(): Promise<TagResult>;
  songList(tagId: string, sortId: string, page: number, limit: number): Promise<SonglistResult>;
  /**
   * 按关键词搜歌单（搜索结果页「歌单」分栏用）。
   * 各源能力不同：kw/kg/wy 支持；tx/mg 的搜索签名只覆盖单曲，这里返回空 + 说明。
   */
  searchPlaylists(keyword: string, page: number, limit: number): Promise<SonglistResult>;
  songListDetail(id: string, page: number): Promise<MusicListResult>;
  leaderboardCategories(): BoardItem[];
  leaderboardDetail(bangid: string, page: number): Promise<MusicListResult>;
  getLyric(info: MusicInfo): Promise<LyricInfo | null>;
  getPic(info: MusicInfo): Promise<string>;
}

/** 构造 MusicInfo（统一填充默认字段，避免各源遗漏） */
export function makeMusicInfo(
  source: OnlineSource,
  songId: string,
  name: string,
  singer: string,
  interval: string | null,
  albumName: string,
  picUrl: string | null,
  qualitys: string[],
  extras?: MusicInfoExtra,
): MusicInfo {
  const qs: MusicQualityType[] = [];
    const qmap: Map<string, string | null> = new Map();
    for (const q of qualitys) {
      qs.push({ type: q as Quality, size: null });
      qmap.set(q, null);
    }
    // 各音质对应的 hash（kg 高音质必须用专属 hash 换链）
    if (extras !== undefined && extras.qualityHashes !== undefined) {
      extras.qualityHashes.forEach((v: string, k: string): void => {
        qmap.set(k, v);
      });
    }
  if (qs.length === 0) {
    qs.push({ type: '128k' as Quality, size: null });
    qmap.set('128k', null);
  }
  const meta: MusicInfoMetaOnline = {
    songId,
    albumName,
    picUrl,
    qualitys: qs,
    _qualitys: qmap,
  };
  if (extras !== undefined) {
    if (extras.hash !== undefined) { meta.hash = extras.hash; }
    if (extras.strMediaMid !== undefined) { meta.strMediaMid = extras.strMediaMid; }
    if (extras.numericId !== undefined) { meta.numericId = extras.numericId; }
    if (extras.copyrightId !== undefined) { meta.copyrightId = extras.copyrightId; }
    if (extras.albumId !== undefined) { meta.albumId = extras.albumId; }
    if (extras.lrcUrl !== undefined) { meta.lrcUrl = extras.lrcUrl; }
    if (extras.mrcUrl !== undefined) { meta.mrcUrl = extras.mrcUrl; }
    if (extras.trcUrl !== undefined) { meta.trcUrl = extras.trcUrl; }
  }
  return {
    id: source + '_' + songId,
    name,
    singer,
    source,
    interval,
    meta,
  };
}

export interface MusicInfoExtra {
  hash?: string;
  qualityHashes?: Map<string, string>;
  strMediaMid?: string;
  numericId?: string;
  copyrightId?: string;
  albumId?: string;
  lrcUrl?: string;
  mrcUrl?: string;
  trcUrl?: string;
}
