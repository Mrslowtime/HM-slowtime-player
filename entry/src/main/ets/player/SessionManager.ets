import { avSession } from '@kit.AVSessionKit';
import { common, Want, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { MusicInfo, LyricLine } from '../model/MusicTypes';
import { APP_BUNDLE_NAME, APP_ABILITY_NAME, SESSION_TAG, LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { PlayMode, normalizePlayMode } from '../config/AppConstants';
import { SettingStore } from '../store/SettingStore';
import { s2t } from '../common/S2tConverter';
import { resolveCoverUrlHd } from '../common/CoverUrl';
import { CoverCache } from '../core/ImageCache';
import { fileIo as fs } from '@kit.CoreFileKit';

/** 系统播控命令回调 */
export type OnSessionPlay = () => void;
export type OnSessionPause = () => void;
export type OnSessionStop = () => void;
export type OnSessionNext = () => void;
export type OnSessionPrevious = () => void;
export type OnSessionSeek = (timeMs: number) => void;

let sInstance: SessionManager | null = null;

/**
 * AVSession 封装（单例）—— 鸿蒙状态栏 / 锁屏媒体卡片的唯一来源。
 *
 * 与协议通过 MediaSession 由"卓易通兼容层"桥接不同，鸿蒙原生 App 直接
 * 向系统注册 AVSession，系统会 100% 生成媒体播控卡片，不依赖任何兼容层。
 *
 * 这里承接协议
 * src/plugins/player/notificationControls.ts 的全部职责（封面、歌词、
 * 收藏、循环模式、进度、自定义 action、歌单列表等）。
 */
export class SessionManager {
  private session: avSession.AVSession | null = null;
  private context: common.UIAbilityContext | null = null;
  private backgroundRunning: boolean = false;
  /** 本地缓存最近的元数据/播放态（AVSession 只提供 setter，getter 在 Controller 侧） */
  private lastMetadata: avSession.AVMetadata | null = null;
  private lastPlaybackState: avSession.AVPlaybackState | null = null;
  /** 当前已知总时长，用于填充 AVPlaybackState.bufferedTime（系统卡片据此判定进度可用） */
  private knownDurationMs: number = 0;
  /** 最近一次推给系统的单行歌词，用于去重与开关切换后重推 */
  private lastLyricText: string = '';
  /** 最近一次推给系统的完整 LRC（含时间标签），供锁屏播控与桌面歌词组件使用 */
  private lastFullLrc: string = '';
  /** 桌面歌词组件能力探测结果（null = 未探测；API 23+ 才可用） */
  private desktopLyricSupported: boolean | null = null;
  /** 桌面歌词组件是否已 enable（enable 一次即可，之后只切 visible） */
  private desktopLyricEnabled: boolean = false;
  /** 当前定时分钟数（0 = 未启用），用于把定时状态同步进卡片副标题 */
  private timeoutBadgeMin: number = 0;

  onPlay: OnSessionPlay | null = null;
  onPause: OnSessionPause | null = null;
  onStop: OnSessionStop | null = null;
  onNext: OnSessionNext | null = null;
  onPrevious: OnSessionPrevious | null = null;
  onSeek: OnSessionSeek | null = null;
  /** 系统卡片固定按钮的命令回调（注册后按钮才会亮起） */
  /** 系统卡片循环按钮：上报归一化后的 'list' | 'single' | 'sequence' */
  onSetLoopMode: ((loop: string) => void) | null = null;
  onFastForward: (() => void) | null = null;
  onRewind: (() => void) | null = null;
  onToggleFavorite: (() => void) | null = null;

  static getInstance(): SessionManager {
    if (sInstance === null) {
      sInstance = new SessionManager();
    }
    return sInstance;
  }

  isActive(): boolean {
    return this.session !== null;
  }

  /** 创建并激活媒体会话，注册系统播控命令，设置点击卡片拉起 App */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.session !== null) {
      return;
    }
    this.context = context;

    const session: avSession.AVSession = await avSession.createAVSession(context, SESSION_TAG, 'audio');
    this.session = session;

    // 系统播控命令（锁屏卡片 / 状态栏卡片 / 蓝牙耳机 / 车机 都会走这里）
    session.on('play', (): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: play');
      if (this.onPlay !== null) {
        this.onPlay();
      }
    });
    session.on('pause', (): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: pause');
      if (this.onPause !== null) {
        this.onPause();
      }
    });
    session.on('stop', (): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: stop');
      if (this.onStop !== null) {
        this.onStop();
      }
    });
    session.on('playNext', (): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: playNext');
      if (this.onNext !== null) {
        this.onNext();
      }
    });
    session.on('playPrevious', (): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: playPrevious');
      if (this.onPrevious !== null) {
        this.onPrevious();
      }
    });
    session.on('seek', (time: number): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: seek %{public}d', time);
      if (this.onSeek !== null) {
        this.onSeek(time);
      }
    });

    // 系统卡片按钮是固定模板：只有注册了对应命令，按钮才会亮起并可点击。
    // 左侧「播放模式」走 setLoopMode；右侧系统快进/快退按钮（图标自带 15）
    // 在本应用里复用为「定时 +15 分钟 / 关闭定时」，图标本身不能换成定时 SVG。
    //
    // 重要：这几个命令不是所有系统版本都支持，不支持时 session.on() 会抛错。
    // 它们必须在 activate() 之前且各自 try/catch —— 一旦抛到外层，
    // activate() 不执行 → 会话未激活、PlayController 后续回调也全部不绑 →
    // 表现就是「锁屏卡片按钮全都不能用」。
    try {
      session.on('setLoopMode', (mode: avSession.LoopMode): void => {
        let key: string = 'list';
        if (mode === avSession.LoopMode.LOOP_MODE_SINGLE) {
          key = 'single';
        } else if (mode === avSession.LoopMode.LOOP_MODE_SEQUENCE) {
          key = 'sequence';
        }
        hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: setLoopMode %{public}s', key);
        if (this.onSetLoopMode !== null) {
          this.onSetLoopMode(key);
        }
      });
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setLoopMode 命令不可用，已跳过');
    }
    try {
      session.on('fastForward', (_time?: number): void => {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: fastForward -> timeout +15min');
        if (this.onFastForward !== null) {
          this.onFastForward();
        }
      });
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'fastForward 命令不可用，已跳过');
    }
    try {
      session.on('rewind', (_time?: number): void => {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: rewind -> timeout off');
        if (this.onRewind !== null) {
          this.onRewind();
        }
      });
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'rewind 命令不可用，已跳过');
    }
    try {
      session.on('toggleFavorite', (_assetId: string): void => {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'session command: toggleFavorite');
        if (this.onToggleFavorite !== null) {
          this.onToggleFavorite();
        }
      });
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'toggleFavorite 命令不可用，已跳过');
    }

    // 点击卡片拉起应用
    try {
      const want: Want = {
        bundleName: APP_BUNDLE_NAME,
        abilityName: APP_ABILITY_NAME
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await session.setLaunchAbility(agent);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setLaunchAbility 未成功，不影响卡片显示');
    }

    try {
      await session.activate();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'AVSession activated');
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'AVSession activate 失败: %{public}s', (e as Error).message);
    }

    // 桌面歌词组件（API 23+）：必须 activate 之后再 enable。
    // 能力探测与低版本降级都在内部处理，不阻塞会话初始化。
    void this.enableDesktopLyric();

    // 会话激活后立刻把当前播放模式推一次：系统卡片初始默认是「顺序播放」，
    // 不主动回推的话，锁屏 / 状态栏 / 大卡片一开机就和应用内对不上。
    try {
      const mode: PlayMode =
        normalizePlayMode(SettingStore.getInstance().getString('player.togglePlayMethod', 'listLoop'));
      const initial: avSession.AVPlaybackState = {
        state: avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: SettingStore.getInstance().getNumber('player.playbackRate', 1),
        position: { elapsedTime: 0, updateTime: Date.now() },
        loopMode: SessionManager.toSystemLoopMode(mode),
      };
      this.lastPlaybackState = initial;
      await session.setAVPlaybackState(initial);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'initial loop mode pushed: %{public}s', mode);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'initial loop mode push skipped');
    }
  }

  /** 同步播放状态与进度到系统卡片 */
  async setPlaybackState(playing: boolean, currentMs: number): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    // loopMode 兜底按当前设置计算：进度每秒重推一次，若这里给 undefined，
    // 系统会把卡片循环按钮重置成默认顺序态，看起来就像「不同步」。
    const prevLoop: avSession.LoopMode | undefined = this.lastPlaybackState?.loopMode;
    const loopMode: avSession.LoopMode = prevLoop !== undefined && prevLoop !== null
      ? prevLoop
      : SessionManager.toSystemLoopMode(
        normalizePlayMode(SettingStore.getInstance().getString('player.togglePlayMethod', 'listLoop')));
    const state: avSession.AVPlaybackState = {
      state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: SettingStore.getInstance().getNumber('player.playbackRate', 1),
      position: {
        elapsedTime: currentMs,
        updateTime: Date.now()
      },
      bufferedTime: this.knownDurationMs,
      isFavorite: this.lastPlaybackState?.isFavorite ?? false,
      loopMode: loopMode,
    };
    this.lastPlaybackState = state;
    try {
      await session.setAVPlaybackState(state);
    } catch (e) {
      this.logBusinessError('setAVPlaybackState', e);
    }
  }

  /**
   * 补推真实时长到系统卡片。
   * 切歌瞬间 AVPlayer 尚未 prepare 完，getDuration() 常返回 0；若只在
   * setMetadataFromMusicInfo 推一次，锁屏 / 播控卡片的进度条会一直没有总时长。
   * 这里复用 lastMetadata（含已解码封面），只改 duration，避免重新拉封面。
   */
  async setDuration(durationMs: number): Promise<void> {
    const session = this.session;
    if (session === null || durationMs <= 0) {
      return;
    }
    if (this.lastMetadata !== null && this.lastMetadata.duration === durationMs) {
      return;
    }
    const metadata: avSession.AVMetadata = this.lastMetadata ?? { assetId: 'duration' };
    metadata.duration = durationMs;
    this.lastMetadata = metadata;
    this.knownDurationMs = durationMs;
    try {
      await session.setAVMetadata(metadata);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session duration updated: %{public}d', durationMs);
    } catch (e) {
      this.logBusinessError('setAVMetadata(duration)', e);
    }
  }

  /**
   * 原样重推一次元数据。
   * 屏幕变暗接近息屏时，系统会冻结媒体卡片并切换到紧凑/胶囊布局；周期性
   * 重发 AVMetadata 能让系统重新读取 duration，避免暗屏卡片时间停在 --:--。
   */
  async refreshMetadata(): Promise<void> {
    const session = this.session;
    if (session === null || this.lastMetadata === null) {
      return;
    }
    try {
      await session.setAVMetadata(this.lastMetadata);
    } catch (e) {
      this.logBusinessError('setAVMetadata(refresh)', e);
    }
  }

  /** 申请音频播放长时任务，保证退到后台 / 锁屏后仍持续播放 */
  async startBackgroundTask(): Promise<void> {
    if (this.backgroundRunning || this.context === null) {
      return;
    }
    try {
      const want: Want = {
        bundleName: APP_BUNDLE_NAME,
        abilityName: APP_ABILITY_NAME
      };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent
      );
      this.backgroundRunning = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'background audio task started');
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '后台长时任务申请失败，卡片仍会显示');
    }
  }

  // ================================================================
  // 扩展：锁屏三页 / 通知播控的全部能力
  // 鸿蒙把这些做成 AVSession 系统级能力，无需自绘 Activity。
  // ================================================================

  /** 元数据序号：封面是异步下载的，切歌快时旧请求后返回会把新封面覆盖回旧歌 */
  private metaSeq: number = 0;
  /** 当前推给系统的封面 PixelMap，必须持有强引用，否则被回收后卡片封面变空白 */
  private lastCoverPixelMap: image.PixelMap | null = null;

  /**
   * 从 MusicInfo 设置完整元数据。
   *
   * 分两步推送：
   *  1) 先推纯文字（标题 / 歌手 / 专辑 / 时长）—— 立即生效，切歌时卡片不会
   *     还挂着上一首的标题；
   *  2) 再异步下载封面，解码成功后补推一次带封面的元数据。
   * 原来是一步「等封面下完才推」，网络慢时（单次超时 6s、两个协议各试一次）
   * 卡片会长时间停在上一首，看起来就是「封面不同步 / 显示不出来」。
   */
  async setMetadataFromMusicInfo(info: MusicInfo, durationMs: number): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const seq: number = ++this.metaSeq;
    const sameAsset: boolean = this.lastMetadata !== null && this.lastMetadata.assetId === info.id;
    const metadata: avSession.AVMetadata = {
      assetId: info.id,
      title: info.name,
      artist: info.singer,
      album: info.meta.albumName,
      duration: durationMs,
      avQueueName: '慢时光音乐',
    };
    // 定时启用时把分钟数写进副标题：系统卡片不允许新增自定义按钮/图标数字，
    // 副标题是唯一能随点按同步显示定时状态的文本位置。
    if (this.timeoutBadgeMin > 0) {
      metadata.subtitle = info.singer + ' · 定时 ' + this.timeoutBadgeMin.toString() + ' 分';
    }
    // 仅当同一首歌时保留已同步的单行歌词 / 完整 LRC / 队列，避免切歌串台（旧歌词残留）
    if (sameAsset && this.lastMetadata !== null) {
      metadata.singleLyricText = this.lastMetadata.singleLyricText;
      metadata.lyric = this.lastMetadata.lyric;
      metadata.avQueueName = this.lastMetadata.avQueueName;
      metadata.avQueueId = this.lastMetadata.avQueueId;
    } else {
      // 换歌：系统卡片上的旧歌词（单行 + 完整）必须清空，
      // 缓存同步复位以允许新歌词写入，桌面歌词组件也要跟着收起
      this.lastLyricText = '';
      this.lastFullLrc = '';
      this.hideDesktopLyricOnTrackChange();
    }
    this.lastMetadata = metadata;
    // 切歌时 source.durationMs 可能为 0，此时先沿用上一首时长会串台，需清零
    // 再由 durationUpdate 补推真实值。
    this.knownDurationMs = durationMs > 0 ? durationMs : 0;
    // 第一步：纯文字，先让卡片跟上当前歌曲
    try {
      await session.setAVMetadata(metadata);
    } catch (e) {
      this.logBusinessError('setAVMetadata(text)', e);
    }
    // 第二步：补封面。`player.isShowNotificationImage` 关闭时不推。
    //
    // 必须用 resolveCoverUrl 而不是原始 picUrl：各音源给回来的封面地址有三种形态
    // （完整 https / 协议相对 `//p1.music.126.net/...` / 站内相对 `/star/migu/...`），
    // 播放界面用的是补全后的地址所以显示正常，卡片直接拿原始值就既下载不了、
    // 系统也解析不了，表现就是「软件里有封面、锁屏卡片全白」。
    // 用高清版（resolveCoverUrlHd）：各音源默认给的是 130~300px 小图，直接解码到
    // 卡片尺寸等于把 130px 放大，锁屏大图会糊；换成 800px 源图后是真正的下采样。
    const showImage: boolean = SettingStore.getInstance().getBoolean('player.isShowNotificationImage', true);
    const pic: string = resolveCoverUrlHd(info);
    if (!showImage || pic.length === 0) {
      // 没有可用封面：系统媒体服务会沿用上一次推送的图，必须单独推一次空图清掉。
      // 放在独立 try 里，万一系统不接受空串，也不影响上面已经推成功的文字。
      if (seq === this.metaSeq) {
        const blank: avSession.AVMetadata = {
          assetId: info.id,
          title: info.name,
          artist: info.singer,
          album: info.meta.albumName,
          duration: durationMs,
          avQueueName: '慢时光音乐',
          mediaImage: '',
        };
        try {
          await session.setAVMetadata(blank);
          // await 期间若已切歌，丢弃本次结果，避免旧歌元数据覆盖新歌（审查 B-10）
          if (seq === this.metaSeq) {
            this.lastMetadata = blank;
          }
        } catch (e) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'clear session cover failed');
        }
      }
      return;
    }
    const pm: image.PixelMap | null = await this.fetchCover(pic);
    // 下载期间已经切到别的歌：丢弃本次结果，否则卡片封面会回退到上一首
    if (seq !== this.metaSeq) {
      return;
    }
    if (pm !== null) {
      // 强引用持有：PixelMap 被 GC 回收后系统卡片封面会变成空白
      this.lastCoverPixelMap = pm;
      metadata.mediaImage = pm;
    } else {
      // 自己解码失败：在线地址交给系统去拉；本地路径系统无权限读，
      // 设空串让卡片明确无图，避免继续钉着上一首的旧封面。
      metadata.mediaImage = pic.indexOf('file://') === 0 ? '' : pic;
    }
    this.lastMetadata = metadata;
    try {
      await session.setAVMetadata(metadata);
    } catch (e) {
      this.logBusinessError('setAVMetadata(cover)', e);
      // 带 PixelMap 的元数据可能超出 Binder 事务上限，整条推送被系统丢弃 ——
      // 表现就是「切歌后标题、封面全都不刷新」。降级成纯文字 + URL 再推一次。
      try {
        const light: avSession.AVMetadata = {
          assetId: info.id,
          title: info.name,
          artist: info.singer,
          album: info.meta.albumName,
          duration: durationMs,
          avQueueName: '慢时光音乐',
          mediaImage: pic.indexOf('file://') === 0 ? '' : pic,
        };
        this.lastMetadata = light;
        await session.setAVMetadata(light);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'setAVMetadata 降级为 URL 封面重推成功');
      } catch (e2) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'setAVMetadata 降级重推仍失败');
      }
    }
  }

  /**
   * 播放链路补到真实封面后再给系统卡片补推一次。
   *
   * 这是「软件内有封面、状态栏 / 锁屏 / 通知栏全都没有」的真正原因：
   * kw 搜索与歌单接口、kg 榜单接口返回的 MusicInfo 里 picUrl 是空的，
   * 封面要等 PlayController 调 MusicSource.getPicUrl() 按 songId 现查。
   * 而元数据在 getPicUrl 之前就推过了 —— 那一刻 resolveCoverUrl 拿到空串，
   * 直接 return，之后没有任何人再补推，系统卡片就永远没有图。
   * （日志可证：fetchCover 从未被调用过。）
   */
  async setCoverFromMusicInfo(info: MusicInfo): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    // 异步查封面期间可能已经切歌：只给当前正在播的这首补图，避免串台
    if (this.lastMetadata === null || this.lastMetadata.assetId !== info.id) {
      return;
    }
    const showImage: boolean = SettingStore.getInstance().getBoolean('player.isShowNotificationImage', true);
    if (!showImage) {
      return;
    }
    // 同样走高清单张（与播控栏 / 播放页共用同一个 URL 与同一份磁盘缓存）
    const pic: string = resolveCoverUrlHd(info);
    if (pic.length === 0) {
      return;
    }
    const pm: image.PixelMap | null = await this.fetchCover(pic);
    // 下载耗时可能跨过切歌点，再确认一次
    if (this.lastMetadata === null || this.lastMetadata.assetId !== info.id) {
      return;
    }
    const metadata: avSession.AVMetadata = this.lastMetadata;
    if (pm !== null) {
      this.lastCoverPixelMap = pm;
      metadata.mediaImage = pm;
    } else {
      metadata.mediaImage = pic.indexOf('file://') === 0 ? '' : pic;
    }
    this.lastMetadata = metadata;
    try {
      await session.setAVMetadata(metadata);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session cover updated: %{public}s', info.name);
    } catch (e) {
      this.logBusinessError('setAVMetadata(coverFallback)', e);
      // PixelMap 跨进程传输超出 Binder 上限时整条元数据会被丢弃，
      // 降级成 URL 字符串再推一次：标题不会丢，系统愿意自己拉图也有图可用。
      metadata.mediaImage = pic.indexOf('file://') === 0 ? '' : pic;
      this.lastMetadata = metadata;
      try {
        await session.setAVMetadata(metadata);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'session cover fallback to url: %{public}s', info.name);
      } catch (e2) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'session cover 推 URL 仍失败');
      }
    }
  }

  /**
   * 同步定时状态到系统媒体卡片副标题。
   * 系统卡片不允许新增自定义按钮、也不允许在按钮图标里画数字，
   * 因此把「定时 N 分」拼进副标题（关闭时恢复成歌手名）。
   */
  async setTimeoutBadge(minutes: number): Promise<void> {
    this.timeoutBadgeMin = minutes;
    const session = this.session;
    if (session === null || this.lastMetadata === null) {
      return;
    }
    const m: avSession.AVMetadata = this.lastMetadata;
    const artist: string = m.artist ?? '';
    m.subtitle = minutes > 0
      ? (artist.length > 0 ? artist + ' · 定时 ' + minutes.toString() + ' 分' : '定时 ' + minutes.toString() + ' 分')
      : artist;
    this.lastMetadata = m;
    try {
      await session.setAVMetadata(m);
    } catch (e) {
      this.logBusinessError('setAVMetadata(timeoutBadge)', e);
    }
  }

  /**
   * 拉取封面并解码为 PixelMap（锁屏 / 状态栏 / 大卡片的真实封面）。
   *
   * 几个踩过的坑：
   *  - 部分音源图床对无 UA 的请求直接 403，必须带浏览器 UA；
   *  - 少数地址只通 http，少数只通 https，这里按原协议先试、失败再换协议；
   *  - `desiredPixelFormat` 不指定时解码器可能给 RGB_565，系统卡片只认 RGBA_8888，
   *    表现是「解码成功但卡片仍无封面」；
   *  - 尺寸过大会撑爆 Binder 事务把整条元数据搞丢，384 是清晰度与事务上限的折中
   *    （384×384 RGBA_8888 约 590KB，仍在 1MB 事务内）。
   *
   * 优先复用 CoverCache 已下载的本地文件：UI 的封面与锁屏封面是同一张 800px 图，
   * 共用一份磁盘缓存后同首歌只下载一次（并行时由 CoverCache 的 inflight 去重），
   * 这里直接读文件解码，不再自己发一次 HTTP。
   */
  private async fetchCover(picUrl: string): Promise<image.PixelMap | null> {
    if (picUrl.length < 8) {
      return null;
    }
    // 0) 本地文件（封面缓存 / 歌曲同目录图）：系统媒体服务读不了应用沙箱里的
    //    file://，必须自己读出来解码成 PixelMap 再推，否则卡片会一直沿用旧封面。
    if (picUrl.indexOf('file://') === 0) {
      const p: string = picUrl.substring('file://'.length);
      let fd: fs.File | null = null;
      try {
        fd = fs.openSync(p, fs.OpenMode.READ_ONLY);
        const st = fs.statSync(p);
        if (st.size < 128) {
          return null;
        }
        const buf: ArrayBuffer = new ArrayBuffer(st.size);
        fs.readSync(fd.fd, buf, { offset: 0, length: st.size });
        return await this.decodeCover(buf);
      } catch (e) {
        return null;
      } finally {
        if (fd !== null) {
          try {
            fs.closeSync(fd);
          } catch (e) {
            // ignore
          }
        }
      }
    }
    if (picUrl.indexOf('http://') !== 0 && picUrl.indexOf('https://') !== 0) {
      return null;
    }
    // 1) 先走缓存：命中就直接解码本地文件（零额外请求）
    try {
      const local: string = await CoverCache.getInstance().get(picUrl);
      if (local.length > 0) {
        const path: string = local.indexOf('file://') === 0 ? local.substring('file://'.length) : local;
        try {
          const fd: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
          try {
            const st = fs.statSync(path);
            const buf: ArrayBuffer = new ArrayBuffer(st.size);
            fs.readSync(fd.fd, buf, { offset: 0, length: st.size });
            const pm: image.PixelMap | null = await this.decodeCover(buf);
            if (pm !== null) {
              return pm;
            }
          } finally {
            fs.closeSync(fd);
          }
        } catch (e) {
          // 读文件失败（被系统清理等）→ 落到下面的直连兜底
        }
      }
    } catch (e) {
      // 缓存层异常不影响封面功能，继续走直连
    }
    // 2) 缓存不可用：自己直连（保留协议互换容错）
    const candidates: string[] = [picUrl];
    if (picUrl.indexOf('http://') === 0) {
      candidates.push('https://' + picUrl.substring(7));
    } else if (picUrl.indexOf('https://') === 0) {
      candidates.push('http://' + picUrl.substring(8));
    }
    for (let i = 0; i < candidates.length; i++) {
      const url: string = candidates[i];
      let req: http.HttpRequest | null = null;
      try {
        req = http.createHttp();
        const resp = await req.request(url, {
          method: http.RequestMethod.GET,
          connectTimeout: 6000,
          readTimeout: 6000,
          header: {
            'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 Chrome/114.0 Safari/537.36',
            'Accept': 'image/*,*/*;q=0.8',
          },
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingCache: true,
        });
        if (resp.responseCode !== 200 || resp.result === null) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'fetchCover http %{public}d: %{public}s',
            resp.responseCode, url.substring(0, 40));
          continue;
        }
        const buf: ArrayBuffer = resp.result as ArrayBuffer;
        if (buf.byteLength < 128) {
          continue;
        }
        const pm: image.PixelMap | null = await this.decodeCover(buf);
        if (pm !== null) {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'fetchCover ok(%{public}d bytes): %{public}s',
            buf.byteLength, url.substring(0, 40));
          return pm;
        }
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'fetchCover 失败：%{public}s', (e as Error).message);
      } finally {
        if (req !== null) {
          req.destroy();
        }
      }
    }
    return null;
  }

  /** 把图片字节解码成卡片用的 384×384 RGBA_8888 PixelMap */
  private async decodeCover(buf: ArrayBuffer): Promise<image.PixelMap | null> {
    if (buf.byteLength < 128) {
      return null;
    }
    let src: image.ImageSource | null = null;
    try {
      src = image.createImageSource(buf);
      const pm: image.PixelMap = await src.createPixelMap({
        desiredSize: { width: 384, height: 384 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      });
      return pm;
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'decodeCover 失败：%{public}s', (e as Error).message);
      return null;
    } finally {
      if (src !== null) {
        try {
          await src.release();
        } catch (e) {
          // 释放失败不影响封面使用
        }
      }
    }
  }

  /**
   * 设置当前播放列表（按锁屏第三页 buildLockScreenList）。
   * 鸿蒙用 setAVQueueItems + setAVQueueTitle，系统媒体卡片会自动展示队列。
   */
  async setQueue(name: string, songs: string[][], activeIndex: number): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const items: avSession.AVQueueItem[] = [];
    // 按锁屏列表上限 = 2000，避免 Binder 事务超限
    const limit = Math.min(songs.length, 2000);
    for (let i = 0; i < limit; i++) {
      const desc: avSession.AVMediaDescription = {
        assetId: 'queue_' + i.toString(),
        title: songs[i][0],
        subtitle: songs[i].length > 1 ? songs[i][1] : '',
      };
      items.push({ itemId: i, description: desc });
    }
    try {
      await session.setAVQueueTitle(name + ' · ' + limit.toString() + ' 首');
      await session.setAVQueueItems(items);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'AVQueue set: %{public}d items', limit);
    } catch (e) {
      this.logBusinessError('setAVQueueItems', e);
    }
  }

  /**
   * 同步当前歌词行到系统媒体播控（通知栏 / 锁屏 / 控制中心）。
   *
   * 三方应用不绘制系统 UI：锁屏 / 状态栏歌词全部交给 AVSession 的
   * AVMetadata 字段渲染，App 退到后台、锁屏时依然可见。
   *  - singleLyricText：单行歌词（状态栏胶囊、紧凑卡片、蓝牙）
   *  - lyric：完整 LRC（播控中心 / 锁屏逐行滚动，桌面歌词组件的数据源）
   *
   * 开关为 desktopLyric.enable：关闭时写空串清掉残留，避免串台。
   */
  async setLyric(lines: LyricLine[], activeIndex: number): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const enabled: boolean = SettingStore.getInstance().getBoolean('desktopLyric.enable', false);
    const hasLine: boolean = activeIndex >= 0 && activeIndex < lines.length;
    // 即使关闭/切歌重置（activeIndex<0）也写入空串，清掉上一首残留歌词。
    const raw: string = enabled && hasLine ? lines[activeIndex].text : '';
    // 与播放页保持一致：开启简繁转换时系统卡片歌词同步转繁体
    const text: string = raw.length > 0
      ? s2t(raw, SettingStore.getInstance().getBoolean('player.isS2t', false))
      : raw;
    if (this.lastLyricText === text) {
      return;
    }
    this.lastLyricText = text;
    await this.pushLyricsMetadata(text);
  }

  /**
   * 推送完整 LRC 到 AVMetadata.lyric —— 锁屏播控逐行滚动 + 桌面歌词组件的数据源。
   *
   * 由 PlayController.loadLyric 在拿到 LyricInfo 后调用一次；只推一次完整歌词，
   * 之后系统按 AVPlaybackState.position 自行定位当前行，无需每行重推。
   * 系统限制 lyric ≤ 40960 字节，超出按完整行截断（不切断时间标签）。
   */
  async setFullLyric(lrcText: string): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const enabled: boolean = SettingStore.getInstance().getBoolean('desktopLyric.enable', false);
    let lrc: string = enabled && lrcText.length > 0
      ? s2t(lrcText, SettingStore.getInstance().getBoolean('player.isS2t', false))
      : '';
    lrc = SessionManager.truncateUtf8ByLines(lrc, 40960);
    if (this.lastFullLrc === lrc) {
      return;
    }
    this.lastFullLrc = lrc;
    await this.pushLyricsMetadata(this.lastLyricText);
    await this.syncDesktopLyricVisibility();
  }

  /**
   * 把单行歌词 + 完整 LRC 一起推给系统。
   * 沿用 lastMetadata（含封面 PixelMap），带 PixelMap 超 Binder 时降级成纯文本重试。
   */
  private async pushLyricsMetadata(singleText: string): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const base: avSession.AVMetadata = this.lastMetadata ?? { assetId: 'lyric' };
    base.singleLyricText = singleText;
    base.lyric = this.lastFullLrc;
    this.lastMetadata = base;
    try {
      await session.setAVMetadata(base);
    } catch (e) {
      // 带 PixelMap 的元数据可能超出 Binder 限制，降级成纯文本重试一次
      try {
        const light: avSession.AVMetadata = {
          assetId: base.assetId,
          title: base.title,
          artist: base.artist,
          album: base.album,
          duration: base.duration,
          singleLyricText: singleText,
          lyric: this.lastFullLrc,
        };
        await session.setAVMetadata(light);
      } catch (e2) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, '歌词推送未生效（系统版本可能不支持）');
      }
    }
  }

  /** 按 UTF-8 字节数截断 LRC，按行切断以免破坏时间标签 */
  private static truncateUtf8ByLines(text: string, maxBytes: number): string {
    if (text.length === 0 || SessionManager.utf8Bytes(text) <= maxBytes) {
      return text;
    }
    const lines: string[] = text.split('\n');
    let out: string = '';
    for (let i = 0; i < lines.length; i++) {
      const candidate: string = out.length === 0 ? lines[i] : out + '\n' + lines[i];
      if (SessionManager.utf8Bytes(candidate) > maxBytes) {
        break;
      }
      out = candidate;
    }
    return out;
  }

  /** 计算字符串的 UTF-8 字节数（含代理对） */
  private static utf8Bytes(s: string): number {
    let n: number = 0;
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c < 0x80) {
        n += 1;
      } else if (c < 0x800) {
        n += 2;
      } else if (c >= 0xd800 && c <= 0xdbff) {
        n += 4;
        i++;
      } else {
        n += 3;
      }
    }
    return n;
  }

  // ---------------------------------------------------------------- 桌面歌词组件

  /** 探测设备是否支持系统桌面歌词组件（API 23+），结果缓存 */
  async isDesktopLyricSupported(): Promise<boolean> {
    if (this.desktopLyricSupported !== null) {
      return this.desktopLyricSupported;
    }
    try {
      this.desktopLyricSupported = await avSession.isDesktopLyricSupported();
    } catch (e) {
      // 系统版本低于 API 23：接口不存在，静默降级为媒体卡片歌词
      this.desktopLyricSupported = false;
    }
    return this.desktopLyricSupported;
  }

  /** 会话激活后启用桌面歌词组件；不支持的设备静默跳过 */
  async enableDesktopLyric(): Promise<void> {
    const session = this.session;
    if (session === null || this.desktopLyricEnabled) {
      return;
    }
    if (!(await this.isDesktopLyricSupported())) {
      return;
    }
    try {
      await session.enableDesktopLyric(true);
      this.desktopLyricEnabled = true;
      // 监听系统侧变化：用户从桌面歌词窗手动关闭后，回调里不做强制反推
      try {
        session.onDesktopLyricVisibilityChanged((visible: boolean): void => {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'desktop lyric visible: %{public}s', visible ? 'true' : 'false');
        });
        session.onDesktopLyricStateChanged((state): void => {
          hilog.info(LOG_DOMAIN, LOG_TAG, 'desktop lyric locked: %{public}s', state.isLocked ? 'true' : 'false');
        });
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'desktop lyric 监听注册失败，不影响显示');
      }
      await this.syncDesktopLyricVisibility();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'DesktopLyric enabled');
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'enableDesktopLyric 失败，已降级为媒体卡片歌词');
    }
  }

  /** 按设置开关 + 当前是否有歌词，同步桌面歌词组件显隐与锁定态 */
  async syncDesktopLyricVisibility(): Promise<void> {
    const session = this.session;
    if (session === null || !this.desktopLyricEnabled) {
      return;
    }
    const settings: SettingStore = SettingStore.getInstance();
    const shouldShow: boolean = settings.getBoolean('desktopLyric.enable', false)
      && settings.getBoolean('desktopLyric.floatEnable', true)
      && this.lastFullLrc.length > 0;
    try {
      await session.setDesktopLyricVisible(shouldShow);
      await session.setDesktopLyricState({ isLocked: settings.getBoolean('desktopLyric.isLock', false) });
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setDesktopLyricVisible 未生效');
    }
  }

  /** 换歌时立即收起桌面歌词，等新歌词到位再按设置显示 */
  hideDesktopLyricOnTrackChange(): void {
    if (this.session === null || !this.desktopLyricEnabled) {
      return;
    }
    void this.setFloatVisibleOnly(false);
  }

  private async setFloatVisibleOnly(visible: boolean): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    try {
      await session.setDesktopLyricVisible(visible);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setDesktopLyricVisible 未生效');
    }
  }

  /** 收藏态（按 slowtime_favorite extra + toggleFavorite 命令） */
  async setFavorite(favorite: boolean): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    try {
      const state: avSession.AVPlaybackState = this.lastPlaybackState ?? {};
      state.isFavorite = favorite;
      this.lastPlaybackState = state;
      await session.setAVPlaybackState(state);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setFavorite 未生效');
    }
  }

  /**
   * 应用内 4 态播放模式 → 系统 LoopMode（一一对应，不再有「同一图标两种模式」）。
   *
   *   listLoop   → LIST（列表循环）
   *   singleLoop → SINGLE（单曲循环）
   *   random     → SHUFFLE（随机播放）
   *   list       → SEQUENCE（顺序播放）
   */
  static toSystemLoopMode(mode: PlayMode): avSession.LoopMode {
    if (mode === 'singleLoop') {
      return avSession.LoopMode.LOOP_MODE_SINGLE;
    }
    if (mode === 'random') {
      return avSession.LoopMode.LOOP_MODE_SHUFFLE;
    }
    if (mode === 'list') {
      return avSession.LoopMode.LOOP_MODE_SEQUENCE;
    }
    return avSession.LoopMode.LOOP_MODE_LIST;
  }

  /**
   * 循环模式同步到系统卡片。
   *
   * 必须带上完整的播放态（state / position / speed），只发 { loopMode }
   * 这种残缺对象时部分系统版本会整帧丢弃，表现就是「应用内已经切了、
   * 卡片图标纹丝不动」。
   */
  async setPlayMode(mode: PlayMode): Promise<void> {
    const session = this.session;
    if (session === null) {
      return;
    }
    const loop: avSession.LoopMode = SessionManager.toSystemLoopMode(mode);
    try {
      const state: avSession.AVPlaybackState = this.lastPlaybackState ?? {
        state: avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        speed: 1,
        position: { elapsedTime: 0, updateTime: Date.now() },
      };
      state.loopMode = loop;
      this.lastPlaybackState = state;
      await session.setAVPlaybackState(state);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session loop mode set: %{public}s -> %{public}d', mode, loop);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setPlayMode 未生效');
    }
  }

  async stopBackgroundTask(): Promise<void> {
    if (!this.backgroundRunning || this.context === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.backgroundRunning = false;
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, '停止后台长时任务失败');
    }
  }

  async destroy(): Promise<void> {
    await this.stopBackgroundTask();
    const session = this.session;
    if (session === null) {
      return;
    }
    try {
      await session.deactivate();
      await session.destroy();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'destroy session 异常，已忽略');
    }
    this.session = null;
  }

  private logBusinessError(api: string, e: Object): void {
    const err = e as BusinessError;
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s failed: %{public}s', api, err.message);
  }
}
