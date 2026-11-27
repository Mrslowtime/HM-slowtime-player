/**
 * 音源解析层 —— 按本项目的模块划分（分派 online/local/download）
 * + online.ts（URL/歌词缓存、音质降级、换源重试）。
 *
 * M2-D：resolvePlaySource / getLyricInfo / preload / getPicUrl 已接入真实在线实现
 * （MusicUrlResolver + MusicApi）。已移除内置的三首试听曲目与示例歌词；
 * 取链失败时先在其它平台找「歌名+歌手」一致的同曲换源；全部失败才返回空源，由上层清空播放器并暂停。
 * （软件内已删除全部兜底音频文件，不内置任何歌曲）
 * 上层 PlayController 无需感知这些变化。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MusicInfo, LyricInfo, SavedPlayInfo, MusicInfoMetaOnline, MusicInfoMetaLocal } from '../model/MusicTypes';
import { PlaySource, makeOnlineSource, makeEmptySource } from '../common/PlaySource';
import { Quality, OnlineSource, StorageKeys, ONLINE_SOURCES } from '../config/AppConstants';
import { getPlayQuality } from './PlayQueue';
import { MusicUrlResolver, UrlResolveResult } from './net/MusicUrlResolver';
import { CacheStore } from './CacheStore';
import { SourceConfig } from './net/SourceConfig';
import { MusicApi } from './api/MusicApi';
import { SearchResult } from './api/ApiTypes';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { getAppContext } from '../common/AppContext';
import { CustomScriptStore } from './net/CustomScriptStore';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ensureTimedLyric } from './LyricParser';
import {
  LyricResolver, LyricTarget, LyricCandidate, pickBestCandidate, splitSingerNames, parseIntervalMs,
} from './LyricResolver';

const PREF_NAME: string = 'slowtime_data';
/** 所有平台都取不到链接后的冷却：期间不再重复搜索/取链，避免持续向服务端发请求 */
const ALT_FAIL_COOLDOWN_MS: number = 300000;
/** 跨平台换源时每个平台搜索的候选条数（放大，给「歌名+歌手」双重过滤留足命中空间） */
const ALT_SEARCH_LIMIT: number = 20;
/** 跨平台换源时长严格要求：原歌与候选秒数必须完全一致（容差 0 秒），不一致即视为同曲不同版本跳过不换 */
const ALT_INTERVAL_TOLERANCE_SEC: number = 0;

let sInstance: MusicSource | null = null;

/** 歌词彻底取不到后的失败冷却（10 分钟）：期间同一首歌不再重打 5 个兜底请求 */
const LYRIC_FAIL_COOLDOWN_MS: number = 10 * 60 * 1000;

export class MusicSource {
  private urlCache: Map<string, string> = new Map();
  private lyricCache: Map<string, LyricInfo> = new Map();
  /** 已尝试过读取同目录 .lrc 的本地歌 id（找不到也只是本地 IO 三次，不必反复试） */
  private localLrcTried: Set<string> = new Set();
  /** 本地歌的在线匹配结果（含未命中），避免每次播放都重复搜索 */
  private localMatch: Map<string, MusicInfo | null> = new Map();
  private localPic: Map<string, string> = new Map();
  /** 歌词取不到时的失败冷却（歌 id → 下次可再查的时间戳），避免冷门曲每次播放都重跑 5 个请求 */
  private lyricFailUntil: Map<string, number> = new Map();
  /** 跨平台同曲映射表：歌名+歌手（归一化）→ 各平台对应的 MusicInfo（含该平台 songId）。
   *  按「同一首歌跨平台匹配」策略：不同平台的同一首歌通过元数据匹配关联，
   *  命中后直接拿目标平台 musicId 取链，不必每次重新模糊搜索，既快又不会串歌。 */
  private songMap: Map<string, Map<OnlineSource, MusicInfo>> = new Map();
  /** 跨平台换源全失败的冷却截止时间戳（原歌 id → ms） */
  private altFailUntil: Map<string, number> = new Map();
  /** 最近一次在线取链失败原因（空串 = 上次成功）；供上层提示具体是限流还是配置问题 */
  private lastResolveError: string = '';
  private store: preferences.Preferences | null = null;

  static getInstance(): MusicSource {
    if (sInstance === null) {
      sInstance = new MusicSource();
    }
    return sInstance;
  }

  private async ensureStore(): Promise<preferences.Preferences | null> {
    if (this.store !== null) {
      return this.store;
    }
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx === null) {
      return null;
    }
    try {
      this.store = await preferences.getPreferences(ctx, PREF_NAME);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'MusicSource getPreferences failed');
    }
    return this.store;
  }

  /** 解析播放源（走用户配置的音源服务；失败返回空源，不再用内置音频兜底） */
  async resolvePlaySource(info: MusicInfo, quality: Quality): Promise<PlaySource> {
    // 1) 本地文件（下载/本地音乐均落在沙箱 downloads，用 file:// 直读）
    if (info.source === 'local') {
      const metaLocal = info.meta as MusicInfoMetaLocal;
      if (metaLocal !== undefined && metaLocal !== null && metaLocal.filePath !== undefined &&
        metaLocal.filePath.length > 0) {
        return makeOnlineSource('file://' + metaLocal.filePath);
      }
      // 无有效路径时返回空源：软件不内置任何音频，不再冒充某首内置曲目
      return makeEmptySource();
    }
    // 1.5) 磁盘音频缓存命中（收藏歌单的智能缓存）：本地文件直读，零请求秒开
    const cachedAudio: string = CacheStore.getInstance().hitAudio(info.id, quality);
    if (cachedAudio.length > 0) {
      this.lastResolveError = '';
      return makeOnlineSource('file://' + cachedAudio);
    }
    // 未命中：若后台正在为这首下缓存，先取消，避免同一首歌被请求两次
    CacheStore.getInstance().cancelAudio(info.id);
    // 2) 真实在线歌曲：音源服务取链（含音质降级 / 错误码映射）
    const r: UrlResolveResult = await MusicUrlResolver.getInstance().resolve(info, quality);
    if (r.ok && r.url.length > 0) {
      this.lastResolveError = '';
      return makeOnlineSource(r.url);
    }
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'resolve url failed: %{public}s -> %{public}s', info.id, r.error);
    // 记下具体原因（限流 / 拒绝取链 / 请求失败），上层提示比统一文案更有指导性
    this.lastResolveError = r.error;
    // 3) 旧直链缓存（同一首歌上次成功过的地址，命中即不发任何请求）
    const cached = this.urlCache.get(info.id + '_' + quality);
    if (cached !== undefined && cached.length > 0) {
      this.lastResolveError = '';
      return makeOnlineSource(cached);
    }
    // 4) 跨平台换源：原平台取不到就依次在其它平台找同名歌曲重新取链。
    //    限流也要换（换的是平台标识，不是继续轰炸同一接口），换源内部有冷却与预算控制。
    const other: PlaySource | null = await this.tryOtherSource(info, quality);
    if (other !== null) {
      this.lastResolveError = '';
      return other;
    }
    // 5) 所有平台都失败：返回空源，由上层清空播放器并暂停；不自动重试、不自动切歌。
    //    用户提示统一由 PlayController 发，避免重复弹窗。
    if (this.lastResolveError.length === 0) {
      this.lastResolveError = '所有平台都没有找到可播放的链接';
    }
    return makeEmptySource();
  }

  /** 去掉空格 / 大小写 / 括号后缀，用于跨源同名匹配 */
  private normalizeName(s: string): string {
    return s.replace(/[（(【\[].*?[)）】\]]/g, '')
      .replace(/\s+/g, '').toLowerCase();
  }

  /** 歌手归一化：去括号 / feat / 分隔符，用于跨源「同歌手」严格校验，避免换到翻唱或同名不同曲 */
  private normalizeSinger(s: string): string {
    return s.replace(/[（(【\[].*?[)）】\]]/g, '')
      .replace(/\s*feat\.?\s*/gi, ' ')
      .replace(/\s*\(\s*featuring[^)]*\)\s*/gi, ' ')
      .replace(/[\/、,，&]/g, ' ')
      .replace(/\s+/g, ' ').trim().toLowerCase();
  }

  /** 把 "03:43" / "3:43" 格式时长解析为秒；无效返回 -1 */
  private parseInterval(s: string | null | undefined): number {
    if (s === undefined || s === null || s.length === 0) {
      return -1;
    }
    const parts: string[] = s.split(':');
    if (parts.length === 2) {
      const m: number = parseInt(parts[0], 10);
      const sec: number = parseInt(parts[1], 10);
      if (!isNaN(m) && !isNaN(sec)) {
        return m * 60 + sec;
      }
    }
    const n: number = parseInt(s, 10);
    return isNaN(n) ? -1 : n;
  }

  /** 时长是否可视为同一首歌：任一方未知则放行（退回歌名+歌手判定）；否则两首歌的秒数必须完全一致，杜绝换到同曲不同版本 */
  private intervalMatch(a: string | null | undefined, b: string | null | undefined): boolean {
    const sa: number = this.parseInterval(a);
    const sb: number = this.parseInterval(b);
    if (sa < 0 || sb < 0) {
      return true;
    }
    return Math.abs(sa - sb) <= ALT_INTERVAL_TOLERANCE_SEC;
  }

  /** 映射表 key：同一首歌（歌名 + 歌手）归一化后的唯一标识 */
  private mapKey(name: string, singer: string): string {
    return this.normalizeName(name) + '|' + this.normalizeSinger(singer);
  }

  /** 把一首歌写入跨平台映射表：记录它在所属平台的 musicId（songId），供其它平台直接查表取链 */
  private putSongMap(info: MusicInfo): void {
    if (info.source === 'local') {
      return;
    }
    const key: string = this.mapKey(info.name, info.singer);
    let m: Map<OnlineSource, MusicInfo> | undefined = this.songMap.get(key);
    if (m === undefined) {
      m = new Map<OnlineSource, MusicInfo>();
      this.songMap.set(key, m);
    }
    m.set(info.source as OnlineSource, info);
  }

  /** 从映射表取某平台对应的同曲 MusicInfo（无则 undefined） */
  private getSongMap(source: OnlineSource, name: string, singer: string): MusicInfo | undefined {
    const m: Map<OnlineSource, MusicInfo> | undefined = this.songMap.get(this.mapKey(name, singer));
    if (m === undefined) {
      return undefined;
    }
    return m.get(source);
  }

  /**
   * 跨平台换源（按「同一首歌跨平台匹配」策略）：原平台取链失败时，在**其余平台**找
   * 「歌名 + 歌手」都严格一致的同一首歌重新取链，绝不换一首同名不同曲的歌。
   *
   * 三道约束（防持续打服务端）：
   *   - 未配置任何音源（自定义 .js 脚本 / HTTP 服务）时直接跳过；
   *   - 维护一张「歌名+歌手 → 各平台 musicId」映射表：命中过就直接查表取链，不重复搜索；
   *   - 一轮全平台都找不到严格同曲时，5 分钟内不再为这首歌做跨平台搜索/取链。
   *
   * 命中规则：候选的歌名与歌手归一化后必须**同时**与原歌一致，任一不同都视为串歌并跳过。
   */
  private async tryOtherSource(info: MusicInfo, quality: Quality): Promise<PlaySource | null> {
    const resolver: MusicUrlResolver = MusicUrlResolver.getInstance();
    // CustomScriptStore 已在上面的 resolve() 里 init 过，此处 getActive() 可直接读
    if (!SourceConfig.getInstance().isConfigured() &&
        CustomScriptStore.getInstance().getActive() === null) {
      return null;
    }
    const targetName: string = this.normalizeName(info.name);
    const targetSinger: string = this.normalizeSinger(info.singer);
    if (targetName.length === 0) {
      return null;
    }
    const cooldownKey: string = this.mapKey(info.name, info.singer);
    const now: number = Date.now();
    const until: number | undefined = this.altFailUntil.get(cooldownKey);
    if (until !== undefined && until > now) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'other-source cooldown: %{public}s', cooldownKey);
      return null;
    }
    // 1) 先把原歌写进映射表（记录它在本平台的 musicId），供其它平台直接查表取链
    this.putSongMap(info);
    // 2) 映射表命中：其它平台已有这首歌的记录，直接用该平台的 musicId 取链（免搜索，最稳）
    for (const s of ONLINE_SOURCES) {
      if (s === info.source) {
        continue;
      }
      const mapped: MusicInfo | undefined = this.getSongMap(s, info.name, info.singer);
      if (mapped === undefined) {
        continue;
      }
      const hit: UrlResolveResult = await resolver.resolve(mapped, quality);
      if (hit.ok && hit.url.length > 0) {
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'other-source via map: %{public}s -> %{public}s', info.id, s);
        return makeOnlineSource(hit.url);
      }
    }
    // 3) 映射表未命中：到其余平台按「歌名 + 歌手」严格匹配搜索
    const api: MusicApi = MusicApi.getInstance();
    for (const s of ONLINE_SOURCES) {
      if (s === info.source) {
        continue;
      }
      let sr: SearchResult;
      try {
        sr = await api.search(s, info.name, 1, ALT_SEARCH_LIMIT);
      } catch (e) {
        continue;
      }
      for (const cand of sr.list) {
        // 歌名 + 歌手双重校验：任一不一致就跳过，避免换到同名不同曲的歌
        if (this.normalizeName(cand.name) !== targetName) {
          continue;
        }
        if (this.normalizeSinger(cand.singer) !== targetSinger) {
          continue;
        }
        // 时长（版本）校验：歌名歌手都对但时长差太多，是同曲的不同版本，跳过避免换到错误版本
        if (!this.intervalMatch(cand.interval, info.interval)) {
          continue;
        }
        this.putSongMap(cand); // 命中即沉淀进映射表
        const rr: UrlResolveResult = await resolver.resolve(cand, quality);
        if (rr.ok && rr.url.length > 0) {
          this.altFailUntil.delete(cooldownKey);
          hilog.info(LOG_DOMAIN, LOG_TAG,
            'other-source resolved: %{public}s -> %{public}s', info.id, s);
          return makeOnlineSource(rr.url);
        }
      }
    }
    this.altFailUntil.set(cooldownKey, now + ALT_FAIL_COOLDOWN_MS);
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'all platforms no strict match for %{public}s, cooldown 5min', cooldownKey);
    return null;
  }

  /** 音质降级（按音质选择逻辑） */
  resolveQuality(prefer: Quality, info: MusicInfo): Quality {
    if (info.source === 'local') {
      return prefer;
    }
    return getPlayQuality(prefer, info.meta as MusicInfoMetaOnline);
  }

  /** 最近一次在线取链失败原因（空串 = 上次成功）；供播放器生成精确提示 */
  getLastResolveError(): string {
    return this.lastResolveError;
  }

  /** 取链全局冷却剩余毫秒（0 = 未冷却）；播放器据此安排「冷却到期自动恢复」 */
  getResolveCooldownRemainMs(): number {
    return MusicUrlResolver.getInstance().getCooldownRemainMs();
  }

  /** 缓存失效（切音质 / URL 过期，按缓存失效判定） */
  invalidate(id: string): void {
    MusicUrlResolver.getInstance().invalidate(id);
    const keys: string[] = [];
    this.urlCache.forEach((_v: string, k: string): void => {
      if (k.startsWith(id + '_')) {
        keys.push(k);
      }
    });
    for (const k of keys) {
      this.urlCache.delete(k);
    }
    // 切音质/换源时歌词缓存也一并失效，避免旧歌词跟着新歌一起显示
    this.lyricCache.delete(id);
  }

  /**
   * 手动「自动匹配」前清掉这首歌的匹配缓存：
   * 歌词内存 + 磁盘、失败冷却、本地歌的在线匹配结果、封面匹配结果都清掉，
   * 之后再走 getLyricInfo 才是真正重新联网匹配，而不是拿上次的旧结果。
   */
  resetMatchCache(id: string): void {
    if (id.length === 0) {
      return;
    }
    this.lyricCache.delete(id);
    this.lyricFailUntil.delete(id);
    this.localMatch.delete(id);
    this.localPic.delete(id);
    this.localLrcTried.delete(id);
    CacheStore.getInstance().deleteLyric(id);
  }

  /** 外部（自动匹配）拿到歌词后直接入库：内存 + 磁盘双写，播放器重新 loadLyric 即命中 */
  putLyric(id: string, lyr: LyricInfo): void {
    if (id.length === 0 || lyr.lyric.length === 0) {
      return;
    }
    this.rememberLyric(id, lyr);
  }

  /** 剩余 <10s 预取下一首播放链接 */
  preload(info: MusicInfo, quality: Quality): void {
    MusicUrlResolver.getInstance().preload(info, quality);
  }
  /**
   * 本地歌曲没有封面/歌词时，按「歌名 + 歌手」在线找一条同名记录。
   * 只试两个源、命中即停，避免像取链那样把服务端打到限流。
   */
  private async matchOnline(info: MusicInfo): Promise<MusicInfo | null> {
    if (this.localMatch.has(info.id)) {
      return this.localMatch.get(info.id) ?? null;
    }
    const keyword: string = info.singer.length > 0 && info.singer !== '未知歌手'
      ? info.name + ' ' + info.singer
      : info.name;
    const sources: OnlineSource[] = ['kw', 'tx'];
    let found: MusicInfo | null = null;
    for (const s of sources) {
      try {
        const r: SearchResult = await MusicApi.getInstance().search(s, keyword, 1, 5);
        for (const m of r.list) {
          const hit: boolean = m.name === info.name ||
            m.name.indexOf(info.name) >= 0 || info.name.indexOf(m.name) >= 0;
          if (hit) {
            found = m;
            break;
          }
        }
      } catch (e) {
        continue;
      }
      if (found !== null) {
        break;
      }
    }
    this.localMatch.set(info.id, found);
    return found;
  }

  /** 封面（M2-D：在线取链；UI 直接用网络图片，卡片用 PixelMap） */
  async getPicUrl(info: MusicInfo): Promise<string> {
    // 任何异常都只能降级成「没有封面」，绝不能把异常抛回播放链路
    try {
      if (info.source === 'local') {
        // 本地文件自带封面：直接用
        const metaLocal = info.meta as MusicInfoMetaLocal;
        if (metaLocal !== undefined && metaLocal !== null && metaLocal.picUrl !== undefined &&
          metaLocal.picUrl !== null && metaLocal.picUrl.length > 0) {
          return metaLocal.picUrl;
        }
        // 本地文件没有封面：按歌名+歌手在线取一张
        const cachedPic: string | undefined = this.localPic.get(info.id);
        if (cachedPic !== undefined) {
          return cachedPic;
        }
        const matched: MusicInfo | null = await this.matchOnline(info);
        const pic: string = matched === null ? '' : (matched.meta.picUrl ?? '');
        this.localPic.set(info.id, pic);
        return pic;
      }
      const meta = info.meta as MusicInfoMetaOnline;
      if (meta !== undefined && meta !== null && meta.picUrl !== undefined &&
        meta.picUrl !== null && meta.picUrl.length > 0) {
        return meta.picUrl;
      }
      const url: string = await MusicApi.getInstance().getPic(info);
      if (url.length > 0 && meta !== undefined && meta !== null) {
        meta.picUrl = url;
      }
      return url;
    } catch (e) {
      return '';
    }
  }

  /** 最近一次取链失败原因（UI 可提示用户去配置音源） */
  async getSourceStatus(): Promise<string> {
    await SourceConfig.getInstance().init();
    return SourceConfig.getInstance().isConfigured()
      ? '' : '尚未配置音源服务，在线歌曲暂时无法取到播放链接';
  }

  /** 歌词：本平台 → 本地 .lrc → 跨平台兜底（网易明文 / QQ），任一命中即缓存 */
  async getLyricInfo(info: MusicInfo): Promise<LyricInfo | null> {
    const cached = this.lyricCache.get(info.id);
    if (cached !== undefined) {
      return cached;
    }
    // 取不到歌词的失败冷却：短时间内不重复打那 5 个请求（正常歌不受影响，只在彻底查不到时生效）
    const failUntil: number | undefined = this.lyricFailUntil.get(info.id);
    if (failUntil !== undefined && failUntil > Date.now()) {
      return null;
    }
    const durationMs: number = parseIntervalMs(info.interval);
    const target: LyricTarget = { name: info.name, singer: info.singer, durationMs };

    // 1) 本地音乐：同目录同名 .lrc 最准，优先用
    if (info.source === 'local' && !this.localLrcTried.has(info.id)) {
      const sidecar: LyricInfo | null = this.readLocalLyricFile(info);
      this.localLrcTried.add(info.id);
      const fixedSidecar: LyricInfo | null = this.normalizeLyric(sidecar, durationMs);
      if (fixedSidecar !== null) {
        return this.rememberLyric(info.id, fixedSidecar);
      }
    }

    // 1.5) 磁盘歌词缓存：上次已经匹配到过的歌词直接复用，重启后不再重新匹配（零请求）
    const onDisk: LyricInfo | null = CacheStore.getInstance().readLyric(info.id);
    if (onDisk !== null) {
      const fixedDisk: LyricInfo | null = this.normalizeLyric(onDisk, durationMs);
      if (fixedDisk !== null) {
        this.lyricCache.set(info.id, fixedDisk);
        return fixedDisk;
      }
    }

    // 2) 平台自身歌词（本地歌按歌名+歌手在线匹配后取歌词）
    let platform: LyricInfo | null = null;
    try {
      if (info.source === 'local') {
        const matched: MusicInfo | null = await this.matchOnline(info);
        if (matched !== null) {
          platform = await MusicApi.getInstance().getLyric(matched);
        }
      } else {
        platform = await MusicApi.getInstance().getLyric(info);
      }
    } catch (e) {
      platform = null;
    }
    const fixedPlatform: LyricInfo | null = this.normalizeLyric(platform, durationMs);
    if (fixedPlatform !== null) {
      return this.rememberLyric(info.id, fixedPlatform);
    }

    // 3) 跨平台兜底一：网易明文接口（不需要签名，覆盖最广）
    let fb: LyricInfo | null = null;
    try {
      fb = await LyricResolver.getInstance().resolve(target);
    } catch (e) {
      fb = null;
    }
    const fixedFb: LyricInfo | null = this.normalizeLyric(fb, durationMs);
    if (fixedFb !== null) {
      return this.rememberLyric(info.id, fixedFb);
    }

    // 4) 跨平台兜底二：QQ（zzcSign 已实现），网易也缺时再试一次
    const qq: LyricInfo | null = await this.fallbackViaQq(target);
    const fixedQq: LyricInfo | null = this.normalizeLyric(qq, durationMs);
    if (fixedQq !== null) {
      return this.rememberLyric(info.id, fixedQq);
    }
    // 彻底取不到：记失败冷却 10 分钟，期间不再重打（避免纯音乐/冷门曲每次播放都重跑一遍）
    this.lyricFailUntil.set(info.id, Date.now() + LYRIC_FAIL_COOLDOWN_MS);
    return null; // 取不到歌词时显示「暂无歌词」
  }

  /** 歌词入库：内存 + 磁盘双写（磁盘让重启后不用重新匹配） */
  private rememberLyric(id: string, lyr: LyricInfo): LyricInfo {
    this.lyricCache.set(id, lyr);
    this.lyricFailUntil.delete(id);
    CacheStore.getInstance().writeLyric(id, lyr);
    return lyr;
  }

  /**
   * 歌词规整：纯文本（无时间标签 / 时间标签全为 00:00）按总时长均分铺开，
   * 避免明明有歌词却因为解析不出行而显示「暂无歌词」。
   */
  private normalizeLyric(lyr: LyricInfo | null, durationMs: number): LyricInfo | null {
    if (lyr === null) {
      return null;
    }
    const fixed: string = ensureTimedLyric(lyr.lyric, durationMs);
    if (fixed.length === 0) {
      return null;
    }
    return {
      lyric: fixed,
      tlyric: lyr.tlyric ?? null,
      rlyric: lyr.rlyric ?? null,
      lxlyric: lyr.lxlyric ?? null,
    };
  }

  /** 兜底二：QQ 搜索（同名同歌手+时长校验）后取其歌词 */
  private async fallbackViaQq(target: LyricTarget): Promise<LyricInfo | null> {
    const kw: string = target.singer.length > 0 && target.singer !== '未知歌手'
      ? target.name + ' ' + target.singer : target.name;
    try {
      const r: SearchResult = await MusicApi.getInstance().search('tx', kw, 1, 10);
      if (r.list.length === 0) {
        return null;
      }
      const cands: LyricCandidate[] = [];
      for (const m of r.list) {
        cands.push({
          id: m.id, name: m.name, singers: splitSingerNames(m.singer),
          durationMs: parseIntervalMs(m.interval),
        });
      }
      const best: LyricCandidate | null = pickBestCandidate(cands, target);
      if (best === null) {
        return null;
      }
      for (const m of r.list) {
        if (m.id === best.id) {
          return await MusicApi.getInstance().getLyric(m);
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  /** 本地音乐同目录同名 .lrc（用户自己放的歌词最准，支持 utf-8 / gb18030） */
  private readLocalLyricFile(info: MusicInfo): LyricInfo | null {
    const meta: MusicInfoMetaLocal = info.meta as MusicInfoMetaLocal;
    if (meta === undefined || meta === null) {
      return null;
    }
    const path: string = meta.filePath ?? '';
    if (path.length === 0) {
      return null;
    }
    const dot: number = path.lastIndexOf('.');
    const slashA: number = path.lastIndexOf('/');
    const slashB: number = path.lastIndexOf('\\');
    const slash: number = slashA > slashB ? slashA : slashB;
    const base: string = dot > slash ? path.substring(0, dot) : path;
    const exts: string[] = ['.lrc', '.LRC', '.Lrc'];
    for (const ext of exts) {
      const p: string = base + ext;
      try {
        if (!fs.accessSync(p)) {
          continue;
        }
        const st = fs.statSync(p);
        if (st.size <= 0 || st.size > 1024 * 1024) {
          continue;
        }
        const file = fs.openSync(p, fs.OpenMode.READ_ONLY);
        const buf: ArrayBuffer = new ArrayBuffer(st.size);
        const n: number = fs.readSync(file.fd, buf, { offset: 0, length: st.size });
        fs.closeSync(file);
        const text: string = decodeLyricFile(new Uint8Array(buf.slice(0, n)));
        if (text.length === 0) {
          continue;
        }
        return { lyric: text, tlyric: null, rlyric: null, lxlyric: null };
      } catch (e) {
        continue;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------- 恢复播放
  async savePlayInfo(info: SavedPlayInfo): Promise<void> {
    const store = await this.ensureStore();
    if (store === null) {
      return;
    }
    try {
      await store.put(StorageKeys.PLAY_INFO, JSON.stringify(info));
      await store.flush();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'savePlayInfo failed');
    }
  }

  async loadSavedPlayInfo(): Promise<SavedPlayInfo | null> {
    const store = await this.ensureStore();
    if (store === null) {
      return null;
    }
    try {
      const raw = await store.get(StorageKeys.PLAY_INFO, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return null;
      }
      return JSON.parse(raw) as SavedPlayInfo;
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------- 搜索历史
  async saveSearchHistory(list: string[]): Promise<void> {
    const store = await this.ensureStore();
    if (store === null) {
      return;
    }
    try {
      await store.put(StorageKeys.SEARCH_HISTORY, JSON.stringify(list));
      await store.flush();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'saveSearchHistory failed');
    }
  }

  async loadSearchHistory(): Promise<string[]> {
    const store = await this.ensureStore();
    if (store === null) {
      return [];
    }
    try {
      const raw = await store.get(StorageKeys.SEARCH_HISTORY, '[]');
      if (typeof raw !== 'string') {
        return [];
      }
      return JSON.parse(raw) as string[];
    } catch (e) {
      return [];
    }
  }
}

/** 歌词文件解码：优先 utf-8，出现替换字符（乱码）时改按 gb18030 解 */
function decodeLyricFile(bytes: Uint8Array): string {
  let text: string = '';
  try {
    text = util.TextDecoder.create('utf-8').decodeToString(bytes);
  } catch (e) {
    text = '';
  }
  if (text.length === 0 || text.indexOf('\uFFFD') >= 0) {
    try {
      const gb: string = util.TextDecoder.create('gb18030').decodeToString(bytes);
      if (gb.length > 0) {
        text = gb;
      }
    } catch (e) {
      // 保留 utf-8 结果
    }
  }
  return text.replace(/\r/g, '').trim();
}

export { OnlineSource };
