/**
 * 播放控制器（编排层）：
 * src/core/player/player.ts + core/init/player/* + plugins/player/service.ts。
 *
 * 把 AppState / PlayQueue / ListManager / PlayerManager / SessionManager 串成一条链路：
 *   播放请求 → 队列算下一首 → 解析音源 → AVPlayer → 状态/进度/歌词 → AVSession 卡片
 */
import { media } from '@kit.MediaKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MusicInfo, MusicInfoMetaLocal, PlayMusicInfo, SavedPlayInfo, LyricInfo, LyricLine, LyricWord } from '../model/MusicTypes';
import { PlaySource } from '../common/PlaySource';
import { SongMatcher, SongMatchResult } from '../core/SongMatch';
import { LyricResolver, LyricTarget, parseIntervalMs } from '../core/LyricResolver';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { Quality, ListIds, PlayMode, normalizePlayMode } from '../config/AppConstants';
import { AppState, formatTime } from '../store/AppState';
import { SettingStore } from '../store/SettingStore';
import { PlaylistStore } from '../store/PlaylistStore';
import { appEvent, AppEvents, stateEvent, StateEvents, listEvent, ListEvents } from '../store/EventBus';
import { PlayQueue, NextMusicResult, nextPlayMode } from '../core/PlayQueue';
import { ListManager } from '../core/ListManager';
import { ListOrderStore } from '../core/ListOrderStore';
import { ListDataStore } from '../core/ListDataStore';
import { buildLyricLines, findActiveLineIndex, parseLxLyric } from '../core/LyricParser';
import { PlayerManager } from './PlayerManager';
import { SessionManager } from './SessionManager';
import { MusicSource } from '../core/MusicSource';
import { CacheStore } from '../core/CacheStore';
import { FavSongIndex } from '../core/FavSongIndex';
import { resolveCoverUrl } from '../common/CoverUrl';
import { CoverCache } from '../core/ImageCache';
import { MusicUrlResolver, UrlResolveResult } from '../core/net/MusicUrlResolver';
import { SourceConfig } from '../core/net/SourceConfig';
import { MusicApi } from '../core/api/MusicApi';
import { DownloadManager } from '../core/DownloadManager';
import { getAppContext } from '../common/AppContext';
import { userNotice } from '../core/UserNotice';

/** 对外暴露的可观察状态（UI 层订阅） */
export interface ControllerSnapshot {
  musicInfo: MusicInfo | null;
  isPlay: boolean;
  nowPlayTime: number;
  maxPlayTime: number;
  playMode: string;
  statusText: string;
  lyricLines: LyricLine[];
  activeLyricIndex: number;
  lyricWords: LyricWord[];
  activeWordIndex: number;
  listName: string;
  listCount: number;
  isFavorite: boolean;
  /** 唱片按钮自动获取封面/歌词进行中（按钮位置转圈） */
  mediaMatching: boolean;
}

let sInstance: PlayController | null = null;

/** 定时停止到点前的渐弱时长：最后 15 秒线性降到静音，避免半夜被"啪"地掐断 */
const TIMEOUT_FADE_MS: number = 15000;
/** 渐弱期间的重算间隔（越小越平滑，250ms 足够且不费电） */
const TIMEOUT_TICK_MS: number = 250;
/** 取链彻底失败后的停留超时：超过这个「风险评估时长」仍停在这首歌就自动切下一首。
 *  取值需足够长，避免与「冷却到期补播」（60s 级）抢跑，又不会让用户干等太久。 */
const FAIL_SKIP_MS: number = 8000;
/** 连续取链失败（自动跳歌）的上限：连续这么多次都无法播放就暂停，防止整张列表被反复打向服务端 */
const MAX_CONSECUTIVE_FAIL: number = 3;

export class PlayController {
  private state: AppState = AppState.getInstance();
  private settings: SettingStore = SettingStore.getInstance();
  private queue: PlayQueue = PlayQueue.getInstance();
  private listManager: ListManager = ListManager.getInstance();
  private player: PlayerManager = PlayerManager.getInstance();
  private session: SessionManager = SessionManager.getInstance();
  private musicSource: MusicSource = MusicSource.getInstance();

  private initialized: boolean = false;
  private progressTimer: number = -1;
  /** 当前进度定时器按哪个倍速建立（-1 表示未启动），倍速变化时据此重建 */
  private progressRate: number = -1;
  private preloadDone: boolean = false;
  /** 同一首歌的取链/播放错误重试次数：只在非重试的播放请求上清零，防止无限重试打服务端 */
  private retryCount: number = 0;
  private lyricLines: LyricLine[] = [];
  private activeLyricIndex: number = -1;
  private activeWordIndex: number = -1;
  private lyricWordLines: (LyricWord[] | null)[] = [];
  private activeWords: LyricWord[] = [];
  private timeoutExitTimer: number = -1;
  private timeoutExitTime: number = 0;
  /** 渐弱进行中：此时禁止设置变更把音量顶回原值，否则渐弱会被打断 */
  private fading: boolean = false;
  /** 用户设定的基础音量（player.volume），渐弱结束后恢复到这个值 */
  private baseVolume: number = -1;
  /** 已推给系统卡片的总时长（切歌重置，避免每帧重推 metadata） */
  private sessionDurationMs: number = 0;
  /** 歌词请求序号：快速切歌时丢弃晚到的旧请求，避免「新歌 + 旧歌词」 */
  private lyricReqSeq: number = 0;
  private lyricReqId: string = '';
  /** progressTimer 低频刷新计数：每 5 秒重推一次 metadata / playbackState */
  private sessionRefreshTicks: number = 0;
  /** onTime 高频快照节流时间戳：≥200ms 才推一次，避免 timeUpdate 200ms 级回调造成整页重绘 */
  private lastSnapshotTickMs: number = 0;
  /** 上次写入「恢复播放信息」的时间：播放中每 10 秒写一次，切歌/暂停强制写 */
  private lastSavePlayAt: number = 0;
  /** 恢复出来的播放位置（毫秒）：等真正载入音源时再定位，避免空播时 seek 无效 */
  private pendingSeekMs: number = 0;
  /** 冷却到期自动补播的定时器（-1 = 无） */
  private autoRecoverTimer: number = -1;
  /** 排队的自动补播目标歌曲 id */
  private autoRecoverId: string = '';
  /** 已经自动补播过的歌曲 id：同一首只补一次，避免「失败→冷却→补播→再失败」形成定时轮询 */
  private autoRecoveredId: string = '';
  /** 取链彻底失败后的「停留超时」定时器：超过风险评估时长仍停在这首歌就自动切下一首 */
  private failSkipTimer: number = -1;
  /** 已经自动跳过过的歌曲 id：同一首只跳一次，避免失败曲目连成轮询 */
  private autoSkippedId: string = '';
  /** 连续取链失败（自动跳歌）的计数：达到上限就暂停，避免整张列表被反复打向服务端 */
  private consecutiveFailCount: number = 0;

  /** UI 刷新回调（由页面注入） */
  onSnapshot: ((s: ControllerSnapshot) => void) | null = null;

  static getInstance(): PlayController {
    if (sInstance === null) {
      sInstance = new PlayController();
    }
    return sInstance;
  }

  /** 初始化：设置 → 状态 → 默认列表 → 播放器回调 → 会话命令 → 恢复播放 */
  async init(): Promise<void> {
    if (this.initialized) {
      return;
    }
    await this.settings.init();
    await this.migrateStatusBarLyric();
    await SourceConfig.getInstance().init();
    // 先异步载入持久化的「我的列表」显示顺序与完整列表数据，再同步重建默认列表时套用
    await ListOrderStore.getInstance().ensure();
    await ListDataStore.getInstance().ensure();
    this.state.applySettings();
    this.listManager.initDefaultLists();
    // 订阅所有列表变更事件统一落盘，覆盖 ListManager / BackupManager 等全部写入点
    this.bindListPersistence();
    // 收藏歌单独立持久化：**异步加载，绝不能 await**。
    // preferences 首次打开失败/卡住时，若阻塞在这里，后面的 AVSession、播放器回调、
    // 会话命令、恢复播放全都不会执行，表现就是「所有按钮都没反应、什么歌都放不了」。
    PlaylistStore.getInstance().init().catch((): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'PlaylistStore init failed, 不影响播放');
    });
    // 不再往默认列表里写入三首内置试听曲：首启列表为空，由用户自行搜索/添加。
    // AVSession 必须在页面之前创建并激活（M1 由页面负责，M2 统一收归控制器）
    const ctx = getAppContext();
    if (ctx !== null) {
      // 会话初始化失败（系统不支持某些命令等）不能拖垮播放器：
      // 否则 bindPlayerCallbacks / bindSessionCommands 都不会执行，应用内也放不了歌。
      try {
        await this.session.init(ctx);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'AVSession activated by PlayController');
      } catch (e) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'AVSession 初始化失败，锁屏卡片不可用: %{public}s',
          (e as Error).message);
      }
    }
    this.bindPlayerCallbacks();
    this.applyPlaybackRate();
    this.applyVolume();
    // 任意设置变更（含倍速 / 音量滑块）后，把最新值实时同步到播放器
    stateEvent().on(StateEvents.CONFIG_UPDATED, (): void => {
      this.applyPlaybackRate();
      this.applyVolume();
      // 倍速变了要重建进度定时器：定时器间隔在启动时按倍速算一次，
      // 不重建会让 2× 播放时歌词/进度滞后、0.5× 时无谓高频空转（费电）。
      if (this.settings.getNumber('player.playbackRate', 1) !== this.progressRate) {
        this.rebuildProgressTimer();
      }
      // 设置页也能改播放模式，改完必须回推系统卡片，否则锁屏循环图标与应用内不一致
      this.syncPlayModeToSession();
    });
    this.bindSessionCommands();
    // 下载服务初始化：加载持久化任务，并把已完成下载灌入「下载列表」
    DownloadManager.getInstance().init();
    this.startProgressTimer();
    await this.restorePlayInfo();
    this.initialized = true;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'PlayController initialized');
    // 预热热搜词（搜索页首屏更快）兼真机网络链路自检；异步执行不阻塞启动
    MusicApi.getInstance().warmUp().catch((): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'warmUp failed');
    });
  }

  /**
   * 列表数据持久化：所有 ListEvents 都触发一次完整快照写入。
   * 之所以订阅事件而不是在每个写入方法里补一行，是因为除 ListManager 外
   * BackupManager（导入备份）、DownloadManager（灌入下载列表）也会改列表数据。
   * 写入本身在 ListDataStore 内部做了串行合并，连续多次事件不会互相覆盖。
   */
  private bindListPersistence(): void {
    const save = (): void => {
      ListDataStore.getInstance().saveFromState().catch((): void => {});
    };
    const events: string[] = [
      ListEvents.LIST_DATA_OVERWRITE,
      ListEvents.LIST_CREATE,
      ListEvents.LIST_REMOVE,
      ListEvents.LIST_UPDATE,
      ListEvents.LIST_MUSIC_ADD,
      ListEvents.LIST_MUSIC_REMOVE,
      ListEvents.LIST_MUSIC_UPDATE,
      ListEvents.LIST_MUSIC_CLEAR,
    ];
    for (const e of events) {
      listEvent().on(e, save);
    }
    // 首启也固化一次，保证默认列表与恢复出来的数据立刻有一份快照
    save();
  }

  /**
   * 一次性迁移：状态栏 / 锁屏媒体卡片的单行歌词默认开启。
   *
   * 鸿蒙不允许三方应用在状态栏常驻区自绘内容（灵动岛/实况窗需要 AGC 权益），
   * 系统媒体卡片（状态栏音乐胶囊展开、控制中心、锁屏）的 singleLyricText
   * 才是唯一可用的「状态栏歌词」通道。早期版本该项默认关闭，老用户升级后
   * 完全看不到歌词，所以这里强制打开一次；之后仍尊重用户在设置里的开关。
   */
  private async migrateStatusBarLyric(): Promise<void> {
    if (this.settings.getBoolean('lyricBar.defaultOn', false)) {
      return;
    }
    await this.settings.set('desktopLyric.enable', true);
    await this.settings.set('lyricBar.defaultOn', true);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'status bar lyric enabled by default (one-time migration)');
  }

  /** 读取设置里的播放倍速并下发给播放器（初始加载与设置变更时调用） */
  private applyPlaybackRate(): void {    const rate = this.settings.getNumber('player.playbackRate', 1);
    this.player.setRate(rate);
  }

  /** 把设置里的基础音量同步到播放器；渐弱进行中不动，避免把音量顶回去 */
  private applyVolume(): void {
    const v = this.settings.getNumber('player.volume', 1);
    this.baseVolume = v;
    if (this.fading) {
      return;
    }
    this.player.setVolume(v);
  }

  /** 当前应用级音量 0–1（供手势读取起点） */
  getVolume(): number {
    if (this.baseVolume < 0) {
      this.baseVolume = this.settings.getNumber('player.volume', 1);
    }
    return this.baseVolume;
  }

  /**
   * 手势调音量。persist=false 用于滑动过程中的高频调用（只作用于播放器，不落盘）；
   * persist=true 时写入设置并广播，保证下次启动仍是这个音量。
   */
  setVolume(v: number, persist: boolean = false): void {
    let n = v;
    if (isNaN(n)) {
      return;
    }
    if (n < 0) {
      n = 0;
    }
    if (n > 1) {
      n = 1;
    }
    // 手势视为用户意图，取消渐弱状态
    this.fading = false;
    this.baseVolume = n;
    this.player.setVolume(n);
    if (persist) {
      this.settings.set('player.volume', Math.round(n * 100) / 100);
    }
  }

  private bindPlayerCallbacks(): void {
    this.player.onState = (s: media.AVPlayerState): void => {
      if (s === 'playing') {
        this.state.setIsPlay(true);
        this.session.setPlaybackState(true, this.player.getCurrentTime());
        this.session.startBackgroundTask();
        // 暂停时被停掉的进度定时器在这里恢复（幂等：已在跑则直接返回）。
        this.startProgressTimer();
        this.pushSnapshot();
      } else if (s === 'paused' || s === 'stopped' || s === 'completed') {
        this.state.setIsPlay(false);
        this.session.setPlaybackState(false, this.player.getCurrentTime());
        // 非播放态立即释放后台音频长时任务（唤醒锁）：暂停后系统才能冻结/回收，
        // 否则一次播放后唤醒锁常驻，锁屏息屏期间持续耗电。恢复播放时 playing
        // 分支会重新申请（startBackgroundTask 有幂等保护），不影响续播。
        this.session.stopBackgroundTask();
        // 暂停/停止时停掉秒级进度定时器，避免空转唤醒 CPU；播放时再按需重启。
        this.stopProgressTimer();
        this.pushSnapshot();
      }
      if (s === 'completed') {
        this.handleCompleted();
      }
    };
    this.player.onTime = (currentMs: number, durationMs: number): void => {
      this.state.setProgress(currentMs, durationMs);
      this.updateLyric(currentMs);
      // 切歌瞬间拿不到时长，prepared / durationUpdate 到值后补推一次 duration。
      // position 由系统按 elapsedTime + updateTime + speed 自行推算，应用只在
      // 播放/暂停/seek/倍速/切歌这些真实变化点上报（华为 AVSession 规范），
      // 每秒重复上报反而会让系统进度计算出错。
      if (durationMs > 0 && durationMs !== this.sessionDurationMs) {
        this.sessionDurationMs = durationMs;
        this.session.setDuration(durationMs);
      }
      // 剩余 <30s 预加载下一首（按 preloadNextMusic.ts）。
      // 收藏歌单要把下一首整曲下完才会命中缓存，窗口太短会来不及下载 → 提前到 30s。
      if (!this.preloadDone && durationMs > 0 && durationMs - currentMs < 30000) {
        this.preloadDone = true;
        this.preloadNext();
      }
      // timeUpdate 在部分系统上是 200ms 级高频回调：节流到 ≥200ms 一次，
      // 降低对象分配与整页重绘频率；播放态切换等低频点仍走即时 pushSnapshot。
      const now: number = Date.now();
      if (now - this.lastSnapshotTickMs >= 200) {
        this.lastSnapshotTickMs = now;
        this.pushSnapshot();
      }
    };
    this.player.onDuration = (d: number): void => {
      // 网络流常在 prepared 之后才由 durationUpdate 给出真实时长。立即补推，
      // 否则 timeUpdate 一旦被系统停发，锁屏卡片会一直停在 --:--。
      if (d > 0 && d !== this.sessionDurationMs) {
        this.sessionDurationMs = d;
        this.session.setDuration(d);
        this.session.setPlaybackState(this.state.isPlay, this.player.getCurrentTime());
      }
    };
    this.player.onError = (msg: string): void => {
      this.handlePlayError(msg);
    };
  }

  private bindSessionCommands(): void {
    // 系统锁屏/状态栏卡片的播控命令（按 plugins/player/service.ts）
    this.session.onPlay = (): void => { this.play(); };
    this.session.onPause = (): void => { this.pause(); };
    this.session.onStop = (): void => { this.stop(); };
    this.session.onNext = (): void => { this.playNext(false); };
    this.session.onPrevious = (): void => { this.playPrev(); };
    this.session.onSeek = (timeMs: number): void => { this.seek(timeMs); };
    // 系统锁屏/播控卡片固定按钮：播放模式（左）切换 5 态循环；
    // 快进/快退（右，图标自带 15）复用为「定时 +15 分钟 / 关闭定时」。
    // 系统卡片只上报 3 态（list / single / sequence），按它回落到应用内模式，
    // 而不是盲目 +1 循环：否则点一次系统按钮，应用内图标会跑两格、两边不一致。
    this.session.onSetLoopMode = (loop: string): void => { this.applySessionLoopMode(loop); };
    this.session.onFastForward = (): void => { this.cycleTimeoutExit(); };
    this.session.onRewind = (): void => { this.setTimeoutExit(0); };
    this.session.onToggleFavorite = (): void => { this.toggleFavorite(); };
  }

  // ---------------------------------------------------------------- 播放控制
  /**
   * 播放指定列表的第 index 首。
   * deriveKey=true（默认，供「播放列表 / 播放历史 / 我的收藏」等列表页点歌）表示
   * 队列来源歌单不明确，按当前歌曲去收藏歌单索引里反查一次；
   * playMusicList 内部调用时传 false，因为来源已经由调用方显式指定。
   */
  async playList(listId: string, index: number, deriveKey: boolean = true): Promise<void> {
    const info = this.queue.playList(listId, index);
    if (info === null) {
      return;
    }
    if (deriveKey) {
      // 从「我的列表」页主动点歌 = 离开收藏歌单上下文，必须关掉整曲智能缓存。
      // 否则上一次收藏歌单留下的 smartCacheOn=true 会让任何队列都开始预取整曲，
      // 突破「仅收藏歌单下一首」的边界。playMusicList 内部传 deriveKey=false，不受影响。
      CacheStore.getInstance().setSmartCacheOn(false);
      // 从某个列表页点歌：记下来源列表（标签行据此把正在播放的自建列表临时置顶）
      this.state.playSourceListId = listId;
      this.state.setPlayListKey(FavSongIndex.getInstance().lookup(info.source, info.id), false);
    }
    await this.playMusicInfo(info, true);
  }

  async playListById(listId: string, id: string): Promise<void> {
    const info = this.queue.playListById(listId, id);
    if (info === null) {
      return;
    }
    // 按歌曲 id 从某个列表点歌同样是主动切上下文，关掉收藏歌单的整曲智能缓存
    CacheStore.getInstance().setSmartCacheOn(false);
    this.state.playSourceListId = listId;
    this.state.setPlayListKey(FavSongIndex.getInstance().lookup(info.source, info.id), false);
    await this.playMusicInfo(info, true);
  }

  /**
   * 播放一组「不在我的列表里」的在线歌曲（搜索结果 / 榜单 / 歌单详情）。
   * 按临时列表 + 播放约定：先写入播放列表再播放，
   * 这样上一首/下一首、循环、锁屏队列都沿用同一套队列逻辑。
   */
  async playMusicList(list: MusicInfo[], index: number, smartCache: boolean = false,
    listKey: string = ''): Promise<void> {
    if (list.length === 0) {
      return;
    }
    // 记录队列来源歌单：只有从收藏歌单进来才带上 key，
    // 「我的歌单」据此在对应卡片上显示旋转黑胶；其它入口默认空串，会自动熄掉。
    // explicit=true：来源由本方法明确决定（含「明确为空」），后续切歌不再反查。
    this.state.setPlayListKey(listKey, true);
    // 搜索 / 榜单 / 歌单详情等入口不属于任何「我的列表」页，标签行不置顶任何自建列表
    this.state.playSourceListId = '';
    // 只有「收藏的歌单」开启智能缓存：当前歌播到剩 10s 时把下一首整曲落盘，
    // 下一首直接从本地起播（请求数与流播持平，命中后为 0）
    CacheStore.getInstance().setSmartCacheOn(smartCache);
    const listId: string = ListIds.TEMP;
    this.listManager.clearList(listId);
    this.listManager.addListMusics(listId, list, false);
    const safeIndex: number = index >= 0 && index < list.length ? index : 0;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'playMusicList: %{public}d songs, start %{public}d',
      list.length, safeIndex);
    await this.playList(listId, safeIndex, false);
  }

  /**
   * 把一组歌同步进播放列表但不播放。
   * 用在「点开歌单详情」这种场景：让「播放列表」立刻能看到这个歌单，
   * 又不打断当前正在播的歌（所以调用方要自己判断是否在播放）。
   */
  syncTempList(list: MusicInfo[]): void {
    if (list.length === 0) {
      return;
    }
    this.listManager.clearList(ListIds.TEMP);
    this.listManager.addListMusics(ListIds.TEMP, list, false);
  }

  /**
   * 载入并播放一首歌（解析音源 → AVPlayer → 元数据 → 歌词）。
   * isRetry=true 表示来自错误重试，此时不能清零 retryCount，否则会陷入无限重试。
   */
  private async playMusicInfo(info: MusicInfo, autoPlay: boolean, isRetry: boolean = false): Promise<void> {
    // 同一首本地歌有多份对象：从列表重新点选时拿到的这份 picUrl 往往是空的，
    // 但封面早就存进封面缓存了。起播前同步补回，播控栏第一帧就有图，
    // 锁屏 / 通知栏 / 播放队列也一起用同一份对象。
    this.restoreLocalPicUrl(info);
    // 队列来源歌单：从「播放列表 / 播放历史 / 我的收藏」点歌时没有明确来源，
    // 按当前这首歌反查它属于哪个收藏歌单，保证「我的歌单」卡片上的黑胶
    // 与歌单详情页的显示完全同步（切歌时也会重新算）。
    if (!this.state.playListKeyExplicit) {
      this.state.setPlayListKey(FavSongIndex.getInstance().lookup(info.source, info.id), false);
    }
    // 任何新的播放请求都作废上一次排队的「冷却到期补播」，避免用户切歌后旧定时器又插一脚
    this.cancelAutoRecover();
    this.preloadDone = false;
    if (!isRetry) {
      this.retryCount = 0;
    }
    this.sessionDurationMs = 0;
    // 切歌瞬间先清空上一首的歌词与进度并立即推一次快照：
    // musicInfo 由 PlayQueue 同步改写，而歌词是异步加载的，不清空会让
    // 「歌词 / 歌曲信息」两页在加载窗口里显示上一首的歌词与总时长。
    this.lyricLines = [];
    this.lyricWordLines = [];
    this.activeWords = [];
    this.activeLyricIndex = -1;
    this.activeWordIndex = -1;
    this.state.setProgress(0, 0);
    this.state.lyricInfo = null;
    this.state.lastLyric = '';
    this.session.setLyric([], -1);
    this.pushSnapshot();
    const quality = this.settings.getString('player.playQuality', '128k') as Quality;
    let source: PlaySource;
    try {
      source = await this.musicSource.resolvePlaySource(info, quality);
    } catch (e) {
      // 取链过程中网络/解析抛错时不能把播放器留在半初始化状态
      hilog.error(LOG_DOMAIN, LOG_TAG, 'resolvePlaySource throw: %{public}s', JSON.stringify(e));
      await this.haltOnSourceFailure(info, '取音源时出错，已暂停');
      return;
    }
    if (source.url.length === 0 && source.rawFile.length === 0) {
      // 所有平台都取不到链接：清空播放器并暂停，绝不继续播上一首，也不自动切歌重试。
      // 原因用音源层记录的真实错误（「请求过于频繁，请 X 秒后再试」等），
      // 比统一文案更能让用户知道是限流还是配置问题。
      const detail: string = this.musicSource.getLastResolveError();
      await this.haltOnSourceFailure(info,
        detail.length > 0 ? detail : '所有平台都无法获取播放链接');
      return;
    }
    await this.player.load(source, autoPlay);
    if (!this.player.hasSource()) {
      // load 内部失败（如 context 未就绪 / 本地文件被删）时 hasLoadedSource 保持 false，
      // 错误回调 handlePlayError 已在报表层触发；这里不能再记历史/推卡片，
      // 否则没播成的歌会污染「最近播放」和锁屏元数据（审查 B-09）。
      return;
    }
    // 真正起播成功：取消「停留超时切歌」的排队定时器（这已经不是失败停留状态），
    // 并清掉「已跳过」记录与连续失败计数，让同一首歌下次再失败时仍可自动跳、连续失败重新计数。
    this.cancelFailSkip();
    this.autoSkippedId = '';
    this.consecutiveFailCount = 0;
    // 真正起播成功后才记账：播放历史按「最近播放时间」倒序，
    // 同一首重复播放会挪到最前，满 500 首淘汰最旧的一首（见 ListManager.recordPlayHistory）
    this.listManager.recordPlayHistory(info);
    await this.session.setMetadataFromMusicInfo(info, this.player.getDuration());
    // 同步系统播放队列（按锁屏第三页 buildLockScreenList）
    const snap = this.queue.getCurrentListSnapshot();
    await this.session.setQueue(snap.name, snap.songs, snap.index);
    await this.session.setPlayMode(normalizePlayMode(this.settings.getString('player.togglePlayMethod', 'listLoop')));
    // 切歌时同步当前歌曲收藏态，避免锁屏爱心按钮沿用上一首的状态（漂移）
    await this.session.setFavorite(this.listManager.isFavorite(info.id));
    // 歌词可能要走跨平台兜底（多一次搜索），不 await，避免拖慢同一批的封面补取与后续状态推送；
    // loadLyric 内部有 lyricReqSeq/lyricReqId 双重校验，晚到的结果会被丢弃。
    void this.loadLyric(info).catch((e: Error): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'loadLyric failed: %{public}s', e?.message ?? '');
    });
    // 封面兜底：kw 搜索/歌单接口不带封面、kg 榜单也不带，播放时按 songId 补一次，
    // 补到后立刻推快照，底部播控栏与播放页一起换成真实封面。
    if (info.source !== 'local') {
      try {
        const pic: string = await this.musicSource.getPicUrl(info);
        if (pic.length > 0) {
          this.pushSnapshot();
          // 系统卡片补图：元数据在上面 setMetadataFromMusicInfo 时已经推过，
          // 那一刻 picUrl 还是空的，所以状态栏 / 锁屏 / 通知栏一直没有封面。
          // 这里拿到真实地址后再补推一次；不 await，避免网络请求拖慢起播。
          void this.session.setCoverFromMusicInfo(info);
        }
      } catch (e) {
        // 补封面失败不影响播放，绝不能让异常打断后面的状态推送
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'getPicUrl failed, 保留占位图');
      }
    }
    // 本地歌不在这里联网：没有封面时由用户在播放页点「唱片」图标主动匹配
    // （见 rematchCurrentMedia），避免切歌就自动发搜索请求。
    appEvent().emit(AppEvents.PLAYER_LOADSTART);
    // 切歌即记下「最后播放的歌曲 + 所在列表」，退出后重进能原样还原
    void this.savePlayInfo(true);
    this.pushSnapshot();
  }


  /**
   * 取链彻底失败（所有平台都播不了）：清空播放器 → 暂停 → 停止自动切歌与自动重试。
   * 关键：必须 player.clear() 把 AVPlayer reset 掉；只 setIsPlay(false) 时
   * AVPlayer 仍持有上一首的 url，会继续把上一首播出来。
   */
  private async haltOnSourceFailure(info: MusicInfo, reason: string): Promise<void> {
    // 置为已耗尽：clear() 触发的状态机回调若再上报 error，也不能再重试取链
    this.retryCount = 1;
    await this.player.clear();
    this.state.setIsPlay(false);
    this.state.setProgress(0, 0);
    this.sessionDurationMs = 0;
    this.session.setPlaybackState(false, 0);
    this.pushSnapshot();
    // 若是「取链限流冷却」导致的停播，等冷却到期自动补播一次：
    // 不增加任何额外请求（到期本来就允许重试），只是不再要求用户手动点播放/重启。
    const waitMs: number = this.musicSource.getResolveCooldownRemainMs();
    if (waitMs > 0) {
      this.scheduleAutoRecover(info, waitMs);
    }
    // 取链彻底失败：排一个「停留超时」，超过风险评估时长仍停在这首歌就自动切下一首，
    // 让用户不用干等太久；同一首只自动跳一次，不会形成连续轮询。
    this.scheduleFailSkip(info);
    userNotice().warn('「' + info.name + '」' + reason + '，可手动切歌或检查音源设置');
    appEvent().emit(AppEvents.PLAYER_ERROR);
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'halt on source failure: %{public}s (%{public}s)', info.id, reason);
  }

  /**
   * 冷却到期后自动补播一次当前歌曲。
   * 只在「用户还停在这首歌、而且没有在播」时执行；用户切歌/暂停/停止都会取消。
   * 同一首歌只自动补一次：补播后仍失败就不再排队，避免形成 60 秒一次的定时轮询。
   */
  private scheduleAutoRecover(info: MusicInfo, waitMs: number): void {
    if (this.autoRecoveredId === info.id) {
      return;
    }
    this.cancelAutoRecover();
    this.autoRecoveredId = info.id;
    this.autoRecoverId = info.id;
    // 冷却剩余 + 1.5s 余量，避开边界上刚好仍在冷却
    const delayMs: number = Math.min(waitMs + 1500, 65000);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'schedule auto recover in %{public}d ms: %{public}s',
      delayMs, info.name);
    this.autoRecoverTimer = setTimeout((): void => {
      this.autoRecoverTimer = -1;
      const cur = this.state.playMusicInfo;
      // 用户已经切歌 / 已经在播 / 当前曲已变 → 放弃自动补播
      if (cur === null || cur.musicInfo.id !== this.autoRecoverId || this.state.isPlay) {
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'auto recover after cooldown: %{public}s', this.autoRecoverId);
      this.playMusicInfo(cur.musicInfo, true).catch((): void => {});
    }, delayMs);
  }

  /** 取消排队的「冷却到期补播」；不影响已经自动补播过的记录 */
  private cancelAutoRecover(): void {
    if (this.autoRecoverTimer >= 0) {
      clearTimeout(this.autoRecoverTimer);
      this.autoRecoverTimer = -1;
    }
    this.autoRecoverId = '';
  }

  /**
   * 取链彻底失败后的「停留超时切歌」：超过 FAIL_SKIP_MS 仍停在这首歌（没在播、没被用户切走），
   * 就自动切到下一首，避免取不到链时干等。同一首只自动跳一次（autoSkippedId 去重），
   * 且两次失败之间隔着固定的超时时长，不会把整张列表在几秒内连续打向服务端。
   */
  private scheduleFailSkip(info: MusicInfo): void {
    if (this.autoSkippedId === info.id) {
      return;
    }
    this.cancelFailSkip();
    this.failSkipTimer = setTimeout((): void => {
      this.failSkipTimer = -1;
      const cur = this.state.playMusicInfo;
      // 用户已切歌 / 已经在播 / 当前曲已变 → 不再自动切
      if (cur === null || cur.musicInfo.id !== info.id || this.state.isPlay) {
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'fail skip to next: %{public}s', info.id);
      this.autoSkippedId = info.id;
      // 取消还在等的冷却补播，避免补播又把它播回来和这次切歌打架
      this.cancelAutoRecover();
      // 连续失败计数：达到上限就彻底暂停，不再继续切歌（避免整张列表被反复打向服务端）
      this.consecutiveFailCount++;
      if (this.consecutiveFailCount >= MAX_CONSECUTIVE_FAIL) {
        this.consecutiveFailCount = 0;
        hilog.warn(LOG_DOMAIN, LOG_TAG, '连续 %{public}d 首取不到链接，暂停播放', MAX_CONSECUTIVE_FAIL);
        userNotice().warn('连续多首歌曲都无法播放，已暂停，请检查网络或音源设置');
        return;
      }
      this.playNext(true).catch((): void => {});
    }, FAIL_SKIP_MS);
  }

  /** 取消「停留超时切歌」定时器 */
  private cancelFailSkip(): void {
    if (this.failSkipTimer >= 0) {
      clearTimeout(this.failSkipTimer);
      this.failSkipTimer = -1;
    }
  }

  play(): void {
    // 失败后播放器已被 clear()（idle），直接 play 只会报错或把旧链接放出来；
    // 用户主动点播放视为「重新尝试取链」，走完整解析链路（内部有冷却，不会持续打服务端）。
    if (!this.player.hasSource()) {
      const cur = this.state.playMusicInfo;
      if (cur !== null) {
        // 用户手动重试：重置「已自动补播」记录，允许这一轮冷却到期后再自动补一次
        this.autoRecoveredId = '';
        this.cancelFailSkip();
        void this.playMusicInfo(cur.musicInfo, true).catch((e: Error): void => {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'manual retry failed: %{public}s', e?.message ?? '');
        });
        return;
      }
    }
    this.player.play();
    appEvent().emit(AppEvents.PLAY);
  }

  pause(): void {
    // 用户主动暂停：取消还没到点的自动补播与停留超时切歌，避免暂停后又自己响起来/跳走
    this.cancelAutoRecover();
    this.cancelFailSkip();
    this.player.pause();
    this.state.setIsPlay(false);
    appEvent().emit(AppEvents.PAUSE);
    // 暂停点就是下次重进要续播的位置，立即落盘（不等节流）
    void this.savePlayInfo(true);
  }

  togglePlay(): void {
    if (this.state.isPlay) {
      this.pause();
    } else {
      this.play();
    }
  }

  stop(): void {
    this.cancelAutoRecover();
    this.cancelFailSkip();
    this.player.stop();
    this.state.setIsPlay(false);
    appEvent().emit(AppEvents.STOP);
  }

  seek(timeMs: number): void {
    if (!this.settings.getBoolean('common.allowProgressBarSeek', true)) {
      return;
    }
    if (!this.player.hasSource()) {
      // 恢复态（已显示上次歌曲但还没取链）：没有可 seek 的音源，
      // 只记住目标位置，等用户点播放时直接从这里起播。
      this.pendingSeekMs = timeMs;
      this.player.setPendingSeek(timeMs);
      this.state.setProgress(timeMs, this.state.progress.maxPlayTime);
      this.pushSnapshot();
      void this.savePlayInfo(false);
      return;
    }
    this.player.seek(timeMs);
    this.pendingSeekMs = 0;
    // seek 属于「播放位置发生变化」，必须立刻同步给系统卡片
    this.session.setPlaybackState(this.state.isPlay, timeMs);
    appEvent().emit(AppEvents.SET_PROGRESS);
    void this.savePlayInfo(true);
  }

  /** 下一首：isAutoToggle=true 表示播放完成自动切歌 */
  async playNext(isAutoToggle: boolean = false): Promise<void> {
    if (this.queue.shouldReplayCurrent() && isAutoToggle) {
      this.player.seek(0);
      this.player.play();
      return;
    }
    const result = this.queue.getNextPlayMusicInfo(isAutoToggle);
    if (result.musicInfo === null) {
      this.state.setIsPlay(false);
      this.pushSnapshot();
      return;
    }
    this.queue.commitNext(result);
    await this.playMusicInfo(result.musicInfo, true);
    appEvent().emit(AppEvents.MUSIC_TOGGLED);
  }

  async playPrev(): Promise<void> {
    const result = this.queue.getPrevPlayMusicInfo();
    if (result.musicInfo === null) {
      return;
    }
    this.queue.commitNext(result);
    await this.playMusicInfo(result.musicInfo, true);
  }

  /** 播放完成（按 playerEnded → playNext(true)）：只有正常播完才自动切歌，失败路径不切 */
  private handleCompleted(): void {
    if (this.settings.getBoolean('player.timeoutExitPlayed', true) && this.timeoutExitTime > 0) {
      this.stop();
      this.cancelTimeoutExit();
      return;
    }
    void this.playNext(true).catch((e: Error): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'auto next failed: %{public}s', e?.message ?? '');
    });
  }

  /**
   * 播放错误：只刷新 1 次 URL（链接可能过期），耗尽即暂停。
   * 不再「5 秒后自动跳下一首」——失败时自动切歌会让整张列表反复向音源服务端发请求。
   * 自动切歌只保留在 handleCompleted（歌曲正常播放完毕）里。
   */
  private handlePlayError(msg: string): void {
    hilog.error(LOG_DOMAIN, LOG_TAG, 'play error: %{public}s', msg);
    const cur = this.state.playMusicInfo;
    if (cur === null) {
      return;
    }
    if (this.retryCount < 1) {
      this.retryCount++;
      this.musicSource.invalidate(cur.musicInfo.id);
      void this.playMusicInfo(cur.musicInfo, true, true).catch((e: Error): void => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'url retry failed: %{public}s', e?.message ?? '');
      });
      return;
    }
    void this.haltOnSourceFailure(cur.musicInfo, '播放失败，已暂停');
  }

  private preloadNext(): void {
    const r = this.queue.getNextPlayMusicInfo(true);
    if (r.musicInfo !== null) {
      const quality = this.settings.getString('player.playQuality', '128k') as Quality;
      // 收藏歌单：把「取链 + 流播」换成「取链 + 整曲下载」，请求次数不变，
      // 但下一首起播时是本地文件（0 请求），并且进了缓存库受缓存上限管理。
      // 非收藏歌单 / 已关闭智能缓存时仍走原来的「只取链」预取，不下载整曲。
      if (CacheStore.getInstance().isAudioCacheEnabled() && CacheStore.getInstance().isSmartCacheOn()) {
        this.cacheNextSong(r.musicInfo, quality);
        return;
      }
      this.musicSource.preload(r.musicInfo, quality);
    }
  }

  /** 收藏歌单的下一首整曲缓存（失败静默，下一首仍可正常流播） */
  private async cacheNextSong(info: MusicInfo, quality: Quality): Promise<void> {
    if (info.source === 'local') {
      return;
    }
    const store: CacheStore = CacheStore.getInstance();
    if (store.hasAudio(info.id, quality)) {
      return;
    }
    try {
      // isPreload=true：预取失败不计熔断、不写负缓存（与 musicSource.preload 一致）
      const r: UrlResolveResult = await MusicUrlResolver.getInstance().resolve(info, quality, true);
      if (!r.ok || r.url.length === 0) {
        return;
      }
      await store.downloadAudio(info.id, quality, r.url, resolveCoverUrl(info), store.audioExtOf(r.url));
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'cache next song failed: %{public}s', (e as Error).message);
    }
  }

  // ---------------------------------------------------------------- 歌词
  private async loadLyric(info: MusicInfo): Promise<void> {
    const seq: number = ++this.lyricReqSeq;
    this.lyricReqId = info.id;
    const lyricInfo: LyricInfo | null = await this.musicSource.getLyricInfo(info);
    // A→B 快速切歌时，A 的歌词请求晚到必须丢弃，否则会覆盖 B 的歌词与系统卡片
    const cur = this.state.playMusicInfo;
    if (seq !== this.lyricReqSeq || this.lyricReqId !== info.id ||
      cur === null || cur.musicInfo.id !== info.id) {
      return;
    }
    this.state.lyricInfo = lyricInfo;
    if (lyricInfo === null) {
      this.lyricLines = [];
    } else {
      this.lyricLines = buildLyricLines(
        lyricInfo,
        this.settings.getBoolean('player.isShowLyricTranslation', false),
        this.settings.getBoolean('player.isShowLyricRoma', false),
      );
    }
    this.activeLyricIndex = -1;
    const lx: string | null | undefined = lyricInfo !== null ? lyricInfo.lxlyric : null;
    this.lyricWordLines = parseLxLyric(lx, this.lyricLines);
    this.activeWords = [];
    if (lx !== null && lx !== undefined && lx.length > 0) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'lxlyric parsed: %{public}d lines with words',
        this.lyricWordLines.filter((w: (LyricWord[] | null)): boolean => w !== null).length);
    }
    this.session.setLyric(this.lyricLines, this.activeLyricIndex);
    // 完整 LRC 推给系统：锁屏播控逐行滚动 + 桌面歌词组件共用这一份数据。
    // 无论有无歌词都要推（空串用于清掉上一首的残留）。
    void this.session.setFullLyric(lyricInfo !== null ? lyricInfo.lyric : '');
    appEvent().emit(AppEvents.LYRIC_UPDATED);
    // 切歌后自动跑一次「唱片按钮」那套匹配（缺封面或缺歌词才发请求），
    // 与歌词加载同时进行；同一首本次运行只跑一次。
    void this.autoMatchMedia(info);
  }

  /** 已经自动跑过「唱片按钮」那套匹配的歌曲 id：同一首本次运行只跑一次，避免反复发请求 */
  private autoMediaTried: Set<string> = new Set<string>();
  /** 唱片按钮自动获取进行中：播放页据此显示转圈 */
  private mediaMatching: boolean = false;

  /** 起播前把本地歌已有的封面地址写回当前对象（纯磁盘查询，零网络） */
  private restoreLocalPicUrl(info: MusicInfo): void {
    if (info.source !== 'local') {
      return;
    }
    const lm = info.meta as MusicInfoMetaLocal;
    if (lm === undefined || lm === null || lm.filePath.length === 0) {
      return;
    }
    const url: string = resolveCoverUrl(info);
    if (url.length > 0) {
      if (lm.picUrl !== url) {
        lm.picUrl = url;
      }
    } else if (lm.picUrl !== null && lm.picUrl !== undefined && lm.picUrl.indexOf('file://') === 0) {
      // 指向已失效的本地文件（缓存被手动清过）：清掉，用户点唱片图标即可重新匹配
      lm.picUrl = '';
    }
  }

  /**
   * 播放时「唱片按钮」自动跑一次：缺封面或缺歌词才真的联网，
   * 两样都齐直接返回（零请求）。封面/歌词都只走多源在线搜索
   * （SongMatcher：kw → tx → kg → wy，标题 + 歌手双命中即停），
   * 不再有任何本地兜底路径。同一首本次运行只跑一次。
   */
  private async autoMatchMedia(info: MusicInfo): Promise<void> {
    if (info.source !== 'local') {
      return;
    }
    // 已经切走了就别为上一首白跑一次匹配
    const cur = this.state.playMusicInfo;
    if (cur === null || cur.musicInfo.id !== info.id) {
      return;
    }
    // 先按文件路径从封面缓存恢复：重新点选歌曲拿到的是另一份对象，
    // 不能因为「这首以前匹配过」就跳过，否则缓存明明有图却仍显示占位。
    this.restoreLocalPicUrl(info);
    const coverReady: boolean = resolveCoverUrl(info).length > 0;
    const lyricReady: boolean = this.state.lyricInfo !== null;
    if (coverReady && lyricReady) {
      return;
    }
    if (this.autoMediaTried.has(info.id)) {
      return;
    }
    this.autoMediaTried.add(info.id);
    this.mediaMatching = true;
    this.pushSnapshot();
    try {
      const out: SongMatchResult = await SongMatcher.getInstance().match(info);
      const still = this.state.playMusicInfo;
      if (still === null || still.musicInfo.id !== info.id) {
        return;
      }
      if (out.picOk) {
        void this.session.setCoverFromMusicInfo(info);
        this.refreshSessionMetadata();
        stateEvent().emit(StateEvents.LOCAL_FILES_CHANGED);
      }
      if (out.lyricOk) {
        await this.loadLyric(info);
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'auto match media failed');
    } finally {
      // 结束后重推一次：有没有封面决定播放页唱片按钮的颜色（有封面 → 主题色）
      this.mediaMatching = false;
      this.pushSnapshot();
    }
  }

  private updateLyric(timeMs: number): void {
    // 新歌歌词还没加载完时不要用上一首的行号去推系统卡片歌词
    if (this.lyricLines.length === 0) {
      this.activeLyricIndex = -1;
      this.activeWordIndex = -1;
      this.activeWords = [];
      return;
    }
    const idx = findActiveLineIndex(this.lyricLines, timeMs);
    let wordIdx: number = -1;
    let words: LyricWord[] = [];
    if (idx >= 0 && idx < this.lyricWordLines.length) {
      const w = this.lyricWordLines[idx];
      if (w !== null && w !== undefined) {
        words = w;
        if (words.length > 0) {
          const pos = timeMs - this.lyricLines[idx].time;
          for (let k = 0; k < words.length; k++) {
            if (pos >= words[k].start && pos < words[k].start + words[k].dur) {
              wordIdx = k;
              break;
            }
          }
          // 本行已唱完：保持整行高亮（经典卡拉OK效果）
          if (wordIdx < 0) {
            const lastEnd = words[words.length - 1].start + words[words.length - 1].dur;
            if (pos >= lastEnd) {
              wordIdx = words.length - 1;
            }
          }
        }
      }
    }
    this.activeWords = words;
    if (idx !== this.activeLyricIndex || wordIdx !== this.activeWordIndex) {
      this.activeLyricIndex = idx;
      this.activeWordIndex = wordIdx;
      this.session.setLyric(this.lyricLines, idx);
      const text = idx >= 0 ? this.lyricLines[idx].text : '';
      this.state.lastLyric = text;
    }
  }

  /**
   * 重新推送当前歌词到系统媒体播控（切换歌词相关开关后调用）。
   * 关闭时 SessionManager 会写空串，把通知栏/锁屏/桌面歌词窗上的歌词一并清掉。
   */
  refreshSystemLyric(): void {
    this.session.setLyric(this.lyricLines, this.activeLyricIndex);
    const info: LyricInfo | null = this.state.lyricInfo;
    void this.session.setFullLyric(info !== null ? info.lyric : '');
  }

  /**
   * 桌面歌词窗开关 / 锁定状态变更后，按最新设置同步组件显隐与锁定态。
   * 不改变已推给系统的歌词内容，只切组件窗口。
   */
  refreshDesktopLyric(): void {
    void this.session.syncDesktopLyricVisibility();
  }

  /**
   * 歌词「显示翻译 / 显示音译」开关变更后立刻重建歌词行。
   *
   * 这两项原来只在 loadLyric（切歌那一刻）读一次，设置页改了要等下一首才看到变化，
   * 表现就是「选了没反应」。这里改用已缓存的 LyricInfo 就地重建，不发任何网络请求。
   */
  refreshLyricOptions(): void {
    const info: LyricInfo | null = this.state.lyricInfo;
    if (info === null) {
      return;
    }
    this.lyricLines = buildLyricLines(
      info,
      this.settings.getBoolean('player.isShowLyricTranslation', false),
      this.settings.getBoolean('player.isShowLyricRoma', false),
    );
    this.lyricWordLines = parseLxLyric(info.lxlyric, this.lyricLines);
    this.activeWords = [];
    if (this.activeLyricIndex >= this.lyricLines.length) {
      this.activeLyricIndex = this.lyricLines.length - 1;
    }
    this.session.setLyric(this.lyricLines, this.activeLyricIndex);
    appEvent().emit(AppEvents.LYRIC_UPDATED);
    this.pushSnapshot();
  }

  /**
   * 手动「自动匹配歌词和封面」（播放页唱片按钮）：
   * 按本协议的逻辑，用「歌名 + 歌手 + 时长」到各音源找同一首歌，命中后用那个源的封面和歌词。
   *
   * 动之前先把这首歌的歌词/封面匹配缓存全部清掉——否则重新匹配会直接命中上次的结果，
   * 表现成「点了没反应」。整个动作只由用户点击触发，一次最多 4 个源各 1 次搜索。
   */
  async rematchCurrentMedia(): Promise<SongMatchResult> {
    const cur = this.state.playMusicInfo;
    if (cur === null) {
      return { matched: false, picOk: false, lyricOk: false, name: '', singer: '', sourceLabel: '' };
    }
    const info: MusicInfo = cur.musicInfo;
    // 1) 清缓存，允许这次真正重新联网（歌词内存/磁盘/失败冷却 + 封面匹配结果）
    this.musicSource.resetMatchCache(info.id);
    // 本地歌：连已存的封面图一起丢掉，用户点按钮就是要「重新取一张」，
    // 否则命中旧文件会看起来像点了没反应。
    if (info.source === 'local') {
      const lm = info.meta as MusicInfoMetaLocal;
      if (lm !== undefined && lm !== null && lm.filePath.length > 0) {
        CoverCache.getInstance().dropLocal(lm.filePath);
        lm.picUrl = '';
      }
    }
    const target: LyricTarget = {
      name: info.name,
      singer: info.singer,
      durationMs: parseIntervalMs(info.interval),
    };
    LyricResolver.getInstance().forget(target);
    // 2) 多源匹配 + 同时取封面与歌词
    const out: SongMatchResult = await SongMatcher.getInstance().match(info);
    if (out.picOk) {
      this.pushSnapshot();
      void this.session.setCoverFromMusicInfo(info);
      // 播控栏 / 播放页封面是 URL 驱动，补到后必须重推一次元数据才会换图
      this.refreshSessionMetadata();
      // 本地歌封面存进了封面缓存，本地音乐列表重扫一次才会读到新图
      if (info.source === 'local') {
        stateEvent().emit(StateEvents.LOCAL_FILES_CHANGED);
      }
    }
    if (out.lyricOk) {
      // 歌词已经由匹配结果写进缓存，这里重新 loadLyric 是命中缓存（零请求）
      await this.loadLyric(info);
    }
    return out;
  }

  /**
   * 「通知栏显示封面」开关变更后重推一次系统卡片元数据。   *
   * 该开关原来只在推元数据那一刻读（切歌 / 补封面时），改了当首不生效。
   * 只在用户手动切换时调用，不会重复拉封面（封面走 CoverCache 命中即出）。
   */
  refreshSessionMetadata(): void {
    const cur = this.state.playMusicInfo;
    if (cur === null) {
      return;
    }
    void this.session.setMetadataFromMusicInfo(cur.musicInfo, this.player.getDuration());
  }

  // ---------------------------------------------------------------- 模式/收藏
  async togglePlayMode(): Promise<void> {
    const cur: PlayMode = normalizePlayMode(this.settings.getString('player.togglePlayMethod', 'listLoop'));
    const next: PlayMode = nextPlayMode(cur);
    await this.settings.set('player.togglePlayMethod', next);
    // 切到随机时把当前曲加入已播，并清空预选（按 configUpdated 监听）
    if (next === 'random') {
      const curInfo = this.state.playMusicInfo;
      if (curInfo !== null) {
        const played = this.state.playedList.slice();
        played.push(curInfo.musicInfo);
        this.state.setPlayedList(played);
      }
    } else {
      this.state.setPlayedList([]);
    }
    this.state.randomNextMusicInfo = null;
    // 系统卡片的循环模式按钮靠 AVPlaybackState.loopMode 回显，必须回推一次
    await this.session.setPlayMode(next);
    this.pushSnapshot();
  }

  /**
   * 系统卡片循环按钮回调。
   *
   * 应用内已收敛为 4 态（listLoop / random / list / singleLoop），与系统的
   * LIST / SHUFFLE / SEQUENCE / SINGLE 一一对应。这里不拿系统传值回写，
   * 而是直接复用应用内同一套切换逻辑（与播放界面按钮完全同源），
   * 切完再把新的 loopMode 回推给系统，两边永远一致、也不会丢格。
   */
  private async applySessionLoopMode(_loop: string): Promise<void> {
    await this.togglePlayMode();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'session loop mode -> %{public}s (toggled in app)',
      this.settings.getString('player.togglePlayMethod', 'listLoop'));
  }

  /** 把设置里的播放模式回推给系统卡片（任何入口改模式后调用） */
  private async syncPlayModeToSession(): Promise<void> {
    const mode: PlayMode = normalizePlayMode(this.settings.getString('player.togglePlayMethod', 'listLoop'));
    await this.session.setPlayMode(mode);
  }

  async toggleFavorite(): Promise<boolean> {
    const cur = this.state.playMusicInfo;
    if (cur === null) {
      return false;
    }
    const fav = this.listManager.toggleFavorite(cur.musicInfo);
    this.session.setFavorite(fav);
    this.pushSnapshot();
    return fav;
  }

  // ---------------------------------------------------------------- 定时停止

  /**
   * 设置定时停止（分钟）。minutes <= 0 表示关闭。
   * 定时器只在内存中存活，进程重启即失效；`player.timeoutExit` 仅记住上次选择供 UI 回显。
   *
   * 到点前 TIMEOUT_FADE_MS 内线性渐弱到静音，再停播并恢复音量——
   * 直接 stop 会有明显的"戛然而止"，渐弱更适合睡前场景。
   */
  async setTimeoutExit(minutes: number): Promise<void> {
    this.cancelTimeoutExit();
    // 允许小数分钟（调试与自动化验证用；UI 只传整数）
    const m = minutes;
    if (m <= 0) {
      await this.settings.set('player.timeoutExit', '0');
      this.session.setTimeoutBadge(0);
      this.pushSnapshot();
      return;
    }
    this.timeoutExitTime = Date.now() + m * 60 * 1000;
    const base = this.getVolume();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'timeoutExit set: %{public}s min, baseVolume=%{public}s',
      m.toString(), base.toString());
    this.timeoutExitTimer = setInterval((): void => {
      const left = this.timeoutExitTime - Date.now();
      if (left <= 0) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'timeoutExit reached, stop and restore volume');
        this.stop();
        // 复位音量，否则下次播放会静悄悄地开始
        this.fading = false;
        this.player.setVolume(base);
        this.cancelTimeoutExit();
        this.settings.set('player.timeoutExit', '0');
        this.session.setTimeoutBadge(0);
        this.pushSnapshot();
        return;
      }
      if (left <= TIMEOUT_FADE_MS) {
        if (!this.fading) {
          this.fading = true;
          hilog.info(LOG_DOMAIN, LOG_TAG, 'timeoutExit fade start, %{public}s ms left', left.toString());
        }
        this.player.setVolume(base * (left / TIMEOUT_FADE_MS));
      }
    }, TIMEOUT_TICK_MS);
    await this.settings.set('player.timeoutExit', Math.floor(m).toString());
    this.session.setTimeoutBadge(Math.floor(m));
    this.pushSnapshot();
  }

  /** 当前生效的定时分钟数；0 表示未启用（重启后定时器失效，不能只信设置回显） */
  getTimeoutExitMinutes(): number {
    if (!this.isTimeoutExitActive()) {
      return 0;
    }
    const v = parseInt(this.settings.getString('player.timeoutExit', '0'));
    return isNaN(v) ? 0 : v;
  }

  /**
   * 定时按钮点按循环：15 → 30 → … → 120 → 15。
   * 返回本次设定的分钟数，供 UI 立即更新图标里的数字。
   */
  cycleTimeoutExit(): number {
    const cur = this.getTimeoutExitMinutes();
    // 15 → 30 → … → 120 → 关闭（0），而不是到 120 又跳回 15
    let next: number = 15;
    if (cur >= 120) {
      next = 0;
    } else if (cur > 0) {
      next = cur + 15;
    }
    this.setTimeoutExit(next);
    return next;
  }

  /** 定时停止剩余毫秒；0 表示未启用 */
  getTimeoutExitRemainMs(): number {
    if (this.timeoutExitTime <= 0) {
      return 0;
    }
    const left = this.timeoutExitTime - Date.now();
    return left > 0 ? left : 0;
  }

  isTimeoutExitActive(): boolean {
    return this.timeoutExitTime > 0;
  }

  /** 渐弱是否正在进行（UI 可用来提示） */
  isFading(): boolean {
    return this.fading;
  }

  cancelTimeoutExit(): void {
    if (this.timeoutExitTimer >= 0) {
      clearInterval(this.timeoutExitTimer);
      this.timeoutExitTimer = -1;
    }
    // 手动取消定时：若正在渐弱，音量必须拉回原值
    if (this.fading) {
      this.fading = false;
      this.player.setVolume(this.getVolume());
    }
    this.timeoutExitTime = 0;
  }

  // ---------------------------------------------------------------- 进度轮询 / 恢复
  private startProgressTimer(): void {
    if (this.progressTimer >= 0) {
      return;
    }
    const rate = this.settings.getNumber('player.playbackRate', 1);
    this.progressRate = rate;
    const interval = rate > 0 ? Math.floor(1000 / rate) : 1000;
    this.progressTimer = setInterval((): void => {
      if (this.state.isPlay) {
        const t = this.player.getCurrentTime();
        const d = this.player.getDuration();
        this.state.setProgress(t, d);
        this.updateLyric(t);
        // 这条定时器是应用侧时钟，不依赖 AVPlayer 的 timeUpdate。锁屏后屏幕
        // 变暗 / 即将息屏时系统会停发 timeUpdate，但长时音频任务仍保活本进程，
        // 所以由它兜底补推 duration；并每 5 秒低频刷新一次 metadata + position，
        // 促使暗屏态卡片重新读取时长，同时避免每秒上报导致系统进度计算错误。
        if (d > 0 && d !== this.sessionDurationMs) {
          this.sessionDurationMs = d;
          this.session.setDuration(d);
        }
        this.sessionRefreshTicks++;
        if (this.sessionRefreshTicks >= 5) {
          this.sessionRefreshTicks = 0;
          this.session.refreshMetadata();
          this.session.setPlaybackState(true, t);
        }
        // 播放中每 10 秒记一次进度（内部节流），被系统杀进程也不会丢太多
        if (t > 0) {
          this.pendingSeekMs = 0;
        }
        void this.savePlayInfo(false);
        this.pushSnapshot();
      }
    }, interval);
  }

  /** 停掉进度定时器（暂停/停止/退出时用，避免空转唤醒 CPU） */
  private stopProgressTimer(): void {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
    this.progressRate = -1;
  }

  /** 倍速变化后重建进度定时器：按新倍速重算间隔，播放中才需要重启 */
  private rebuildProgressTimer(): void {
    const wasRunning: boolean = this.progressTimer >= 0;
    this.stopProgressTimer();
    if (wasRunning && this.state.isPlay) {
      this.startProgressTimer();
    }
  }

  /**
   * 恢复上次的播放信息（按 core/init/player/playInfo.ts + isSavePlayTime）。
   *
   * 只把「歌曲 / 所在列表 / 进度」还原到状态里（暂停态），**不解析音源、不发网络请求**：
   * 播放栏与播放页一进 App 就有内容，用户点播放时才真正取链并定位到上次进度。
   * 这样启动时即使没有可用音源，也不会一进来就弹「取链失败」。
   */
  private async restorePlayInfo(): Promise<void> {
    const saved = await this.musicSource.loadSavedPlayInfo();
    const autoPlay: boolean = this.settings.getBoolean('player.startupAutoPlay', false);

    if (saved === null) {
      // 无恢复信息：默认列表有歌则载入第 1 首但不自动播（首启列表为空时保持空态）
      const list = this.state.getList(ListIds.PLAYLIST);
      if (list.length > 0) {
        this.applyRestoredMusic(list[0], ListIds.PLAYLIST, 0, 0, 0, autoPlay);
      }
      return;
    }

    // 1) 定位列表与下标：列表可能被清空/改写，优先按歌曲 id 找，找不到再退回旧下标
    const listId: string = saved.listId === null || saved.listId === undefined
      ? ListIds.PLAYLIST : saved.listId;
    const list = this.state.getList(listId);
    const target: MusicInfo | null = saved.musicInfo === undefined ? null : saved.musicInfo;
    let index: number = -1;
    if (target !== null) {
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === target.id) {
          index = i;
          break;
        }
      }
    }
    if (index < 0 && saved.index >= 0 && saved.index < list.length) {
      index = saved.index;
    }
    // 2) 要显示的歌曲：列表里定位到就用列表对象（带最新元数据），否则用快照
    const info: MusicInfo | null = index >= 0 ? list[index] : target;
    if (info === null) {
      return;
    }
    this.applyRestoredMusic(info, listId, index, saved.time, saved.maxTime, autoPlay);
  }

  /**
   * 把一首歌还原成「当前播放曲」但不取链：播放栏、播放页、进度条立刻有内容。
   * autoPlay=true（设置里开了启动自动播放）时才走完整播放链路。
   */
  private applyRestoredMusic(info: MusicInfo, listId: string, index: number,
    timeMs: number, maxMs: number, autoPlay: boolean): void {
    if (index >= 0) {
      // 走队列，保证「下一首 / 上一首 / 锁屏队列」都从正确位置继续
      this.queue.playList(listId, index);
    } else {
      // 列表里已没有这首歌（列表被清空/删除）：仅还原展示，切歌会因列表为空自然停下
      this.state.setPlayMusicInfo({ musicInfo: info, listId, isTempPlay: false });
      this.state.setPlayInfo({ playIndex: 0, playerListId: listId, playerPlayIndex: 0 });
      appEvent().emit(AppEvents.MUSIC_TOGGLED);
    }
    // 上次所在列表直接作为「我的列表」当前分类，重进后不会总是跳回「我的歌单」
    if (listId.length > 0) {
      this.state.activeListId = listId;
    }
    // 只有开启「记忆播放进度」时才还原位置，否则一律从头开始（进度条显示 0）
    const keepTime: boolean = this.settings.getBoolean('player.isSavePlayTime', false);
    const fromMs: number = keepTime && timeMs > 0 ? timeMs : 0;
    this.state.setIsPlay(false);
    this.pendingSeekMs = fromMs;
    this.state.setProgress(fromMs, keepTime ? maxMs : 0);
    this.pushSnapshot();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'restore play info: %{public}s (list=%{public}s idx=%{public}d t=%{public}d)',
      info.name, listId, index, fromMs);
    if (fromMs > 0) {
      // 交回播放器：真正 prepared 之后先 seek 再播，避免「先从头响一声」
      this.player.setPendingSeek(fromMs);
    }
    if (autoPlay) {
      this.playMusicInfo(info, true).catch((): void => {});
    }
  }

  /**
   * 保存当前播放信息（歌曲 / 所在列表 / 下标 / 进度）。
   * force=true：切歌、暂停、切后台、退出时立即写盘；否则播放中按 10 秒节流。
   */
  async savePlayInfo(force: boolean = true): Promise<void> {
    const cur = this.state.playMusicInfo;
    if (cur === null) {
      // 没有当前曲（空态）时不覆盖历史记录，避免误清掉上次播放的歌
      return;
    }
    const now: number = Date.now();
    if (!force && now - this.lastSavePlayAt < 10000) {
      return;
    }
    this.lastSavePlayAt = now;
    const hasSource: boolean = this.player.hasSource();
    // 刚载入还没开始播（或恢复后未播）时，进度取上次位置，别把记录写成 0
    const played: number = hasSource ? this.player.getCurrentTime() : 0;
    const timeMs: number = Math.max(played, this.pendingSeekMs);
    const info: SavedPlayInfo = {
      time: timeMs,
      maxTime: hasSource ? this.player.getDuration() : this.state.progress.maxPlayTime,
      listId: cur.listId,
      index: this.state.playInfo.playIndex,
      musicInfo: cur.musicInfo,
      savedAt: now,
    };
    await this.musicSource.savePlayInfo(info);
  }

  // ---------------------------------------------------------------- 快照
  getSnapshot(): ControllerSnapshot {
    const cur = this.state.playMusicInfo;
    const snap = this.queue.getCurrentListSnapshot();
    return {
      musicInfo: cur === null ? null : cur.musicInfo,
      isPlay: this.state.isPlay,
      nowPlayTime: this.state.progress.nowPlayTime,
      maxPlayTime: this.state.progress.maxPlayTime,
      playMode: normalizePlayMode(this.settings.getString('player.togglePlayMethod', 'listLoop')),
      statusText: this.state.statusText,
      lyricLines: this.lyricLines,
      activeLyricIndex: this.activeLyricIndex,
      lyricWords: this.activeWords,
      activeWordIndex: this.activeWordIndex,
      listName: snap.name,
      listCount: snap.songs.length,
      isFavorite: cur === null ? false : this.listManager.isFavorite(cur.musicInfo.id),
      mediaMatching: this.mediaMatching,
    };
  }

  pushSnapshot(): void {
    if (this.onSnapshot !== null) {
      this.onSnapshot(this.getSnapshot());
    }
  }

  async destroy(): Promise<void> {
    this.cancelAutoRecover();
    this.cancelFailSkip();
    this.stopProgressTimer();
    this.cancelTimeoutExit();
    await this.savePlayInfo();
    await this.session.destroy();
    await this.player.release();
  }
}
