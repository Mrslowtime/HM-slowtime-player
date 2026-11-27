/**
 * 数据模型层 —— 字段严格按协议 的 LX 命名空间类型。
 * 来源：src/types/music.d.ts、list.d.ts、player.d.ts、store/*\/state.ts
 * M2 全量独立实现时，所有模块都用这里的结构，避免各写一套。
 */
import { Quality, OnlineSource, PlayMode } from '../config/AppConstants';

/** 音质项 {"type":"128k", size:"3.56M"} */
export interface MusicQualityType {
  type: Quality;
  size: string | null;
}

/** 在线歌曲元数据 */
export interface MusicInfoMetaOnline {
  songId: string;
  albumName: string;
  picUrl?: string | null;
  qualitys: MusicQualityType[];
  _qualitys: Map<string, string | null>;
  albumId?: string;
  toggleMusicInfo?: MusicInfo | null;
  /** 源特有字段（kg hash / tx strMediaMid / mg copyrightId） */
  hash?: string;
  strMediaMid?: string;
  /** 数字歌曲 ID（tx QRC 歌词需要，搜索结果的 id 字段） */
  numericId?: string;
  copyrightId?: string;
  lrcUrl?: string;
  mrcUrl?: string;
  trcUrl?: string;
}

/** 本地歌曲元数据 */
export interface MusicInfoMetaLocal {
  songId: string;
  albumName: string;
  picUrl?: string | null;
  filePath: string;
  ext: string;
}

/** 歌曲 —— 与协议 MusicInfo 对齐 */
export interface MusicInfo {
  id: string;
  name: string;
  singer: string;
  source: OnlineSource | 'local';
  /** 格式化时长，例 "03:55" */
  interval: string | null;
  meta: MusicInfoMetaOnline | MusicInfoMetaLocal;
}

/** 歌词 */
export interface LyricInfo {
  lyric: string;
  tlyric?: string | null;
  rlyric?: string | null;
  lxlyric?: string | null;
}

/** 解析后的一行歌词 */
export interface LyricLine {
  time: number;
  text: string;
  translation?: string;
  roma?: string;
}

/** 逐字歌词中的一个字/词（时间相对行首，单位 ms） */
export interface LyricWord {
  text: string;
  /** 相对行首起始时间（ms） */
  start: number;
  /** 时长（ms） */
  dur: number;
}

/** 在线歌单卡片 */
export interface ListInfoItem {
  play_count: string;
  id: string;
  author: string;
  name: string;
  time: string;
  img: string;
  desc: string;
  source: OnlineSource;
  total: number;
}

/** 歌单分页 */
export interface ListInfo {
  list: ListInfoItem[];
  total: number;
  page: number;
  limit: number;
  maxPage: number;
  key: string;
  source: OnlineSource;
  tagId: string;
  sortId: string;
}

/** 榜单项 */
export interface BoardItem {
  id: string;
  name: string;
  bangid: string;
  /** 榜单封面（可选，走 CoverImage 缓存） */
  img?: string;
}

/** 我的列表 */
export interface UserListInfo {
  id: string;
  name: string;
  source?: string;
  sourceListId?: string;
  locationUpdateTime: number;
}

/**
 * 收藏的歌单（「我的歌单」分类）—— 与「我的收藏」的歌曲收藏完全独立。
 * 需要存完整元数据，否则无法在列表里渲染歌单卡片。
 */
export interface FavoritePlaylistInfo {
  source: string;
  sourceListId: string;
  name: string;
  author: string;
  img: string;
  playCount: string;
  total: number;
  /** playlist=歌单 / leaderboard=排行榜，决定点击后走哪个详情接口 */
  type: string;
  updateTime: number;
}

/** 当前播放信息（按 LX.Player.PlayMusicInfo） */
export interface PlayMusicInfo {
  musicInfo: MusicInfo;
  listId: string | null;
  isTempPlay: boolean;
}

/** 播放索引状态（按 LX.Player.PlayInfo） */
export interface PlayInfoState {
  playIndex: number;
  playerListId: string | null;
  playerPlayIndex: number;
}

/** 稍后播放项 */
export interface TempPlayListItem {
  listId: string | null;
  musicInfo: MusicInfo;
  isTop?: boolean;
}

/** 恢复播放信息 */
export interface SavedPlayInfo {
  time: number;
  maxTime: number;
  listId: string | null;
  index: number;
  /**
   * 最后播放的歌曲快照。重启后即使所在列表被清空/改名，也能把这首歌
   * 还原到播放栏与播放页（旧版本记录没有该字段，读到 undefined 时回落列表定位）。
   */
  musicInfo?: MusicInfo | null;
  /** 记录写入时间（毫秒），用于判断记录是否过旧 */
  savedAt?: number;
}

/** 下载任务 */
export interface DownloadListItem {
  id: string;
  isComplate: boolean;
  status: string;
  statusText: string;
  downloaded: number;
  total: number;
  progress: number;
  speed: string;
  musicInfo: MusicInfo;
  quality: Quality;
  fileName: string;
  filePath: string;
  ext: string;
}

/** 不喜欢规则 */
export interface DislikeInfo {
  names: string[];
  musicNames: string[];
  singerNames: string[];
  rules: string[];
}

/** 播放进度状态 */
export interface ProgressState {
  nowPlayTime: number;
  maxPlayTime: number;
  progress: number;
  nowPlayTimeStr: string;
  maxPlayTimeStr: string;
}

/** 标签 */
export interface TagInfoItem {
  id: string;
  name: string;
}

/** 排序 */
export interface SortInfo {
  tid: 'recommend' | 'hot' | 'new' | 'hot_collect' | 'rise';
  id: string;
}

export { Quality, OnlineSource, PlayMode };
