import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { audio } from '@kit.AudioKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaySource } from '../common/PlaySource';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { getAppContext } from '../common/AppContext';
import { SettingStore } from '../store/SettingStore';

/** 播放器状态变化回调 */
export type OnPlayerState = (state: media.AVPlayerState) => void;
/** 播放进度回调（毫秒） */
export type OnPlayerTime = (currentMs: number, durationMs: number) => void;
/** 播放错误回调 */
export type OnPlayerError = (message: string) => void;
/** 单曲播放完成回调 */
export type OnPlayerComplete = () => void;

/**
 * 把连续播放倍速（0.5–2.0）映射到系统 AVPlayer 支持的离散 PlaybackSpeed 档位。
 * AVPlayer 只接受固定档位（0.5/0.75/1.0/1.25/1.5/1.75/2.0），故取最近档。
 */
export function toPlaybackSpeed(rate: number): media.PlaybackSpeed {
  if (rate < 0.625) {
    return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
  }
  if (rate < 0.875) {
    return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
  }
  if (rate < 1.125) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  }
  if (rate < 1.375) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
  }
  if (rate < 1.625) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
  }
  if (rate < 1.875) {
    return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
  }
  return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
}

let sInstance: PlayerManager | null = null;

/**
 * AVPlayer 封装（单例）。
 *
 * 职责：真实播放一首音频，让系统有音轨可用于媒体卡片；
 * 并对外提供完整的播放队列 / 音质切换 / 缓存 / 断点续播能力。
 */
export class PlayerManager {
  private player: media.AVPlayer | null = null;
  /** init 并发保护：createAVPlayer 是 await，快速切歌时两次 init 可能同时通过判空，
   *  各自创建 AVPlayer 导致先建的泄漏。用 promise 缓存让并发调用共享同一次初始化。 */
  private initPromise: Promise<void> | null = null;
  private durationMs: number = 0;
  private currentMs: number = 0;
  private autoPlay: boolean = false;
  private openedRawFile: string = '';
  /** 本地音频文件打开的 fd（AVPlayer 只认 fd:// / 网络地址，file:// 会报 401） */
  private openedLocalFd: number = -1;
  /** 错误去重：同一错误 2 秒内只上报一次，避免状态机循环把日志刷爆 */
  private lastErrorMsg: string = '';
  private lastErrorAt: number = 0;
  /** 当前播放倍速（1.0 为原速）。切歌 reset() 会复位速度，故在 prepared 阶段重新应用 */
  private rate: number = 1.0;
  /** 应用级音量 0–1。切歌 reset() 会复位音量，故在 prepared 阶段重新应用 */
  private volume: number = 1.0;
  /** 当前是否已载入可用音源；取链失败 clear() 后为 false，防止 play() 又把上一首放出来 */
  private hasLoadedSource: boolean = false;
  /**
   * 待执行的定位（毫秒，-1 = 无）。
   * 恢复上次播放位置用：load() 之后 AVPlayer 还在 initialized/prepared 过程里，
   * 此时直接 seek 会被拒绝，所以在 prepared 回调里先 seek 再决定是否 play。
   */
  private pendingSeekMs: number = -1;

  onState: OnPlayerState | null = null;
  onTime: OnPlayerTime | null = null;
  /** 网络流常在 prepared 之后才由 durationUpdate 给出真实总时长 */
  onDuration: ((durationMs: number) => void) | null = null;
  onError: OnPlayerError | null = null;
  onComplete: OnPlayerComplete | null = null;

  static getInstance(): PlayerManager {
    if (sInstance === null) {
      sInstance = new PlayerManager();
    }
    return sInstance;
  }

  getDuration(): number {
    return this.durationMs;
  }

  getCurrentTime(): number {
    return this.currentMs;
  }

  /** 设置播放倍速（立即应用；播放器未就绪时暂存，待 prepared 阶段生效） */
  setRate(rate: number): void {
    if (rate <= 0) {
      return;
    }
    if (rate === this.rate) {
      return;
    }
    this.rate = rate;
    this.applySpeed();
  }

  /** 把当前倍速写入 AVPlayer；状态不允许时会抛异常，降级不影响正常播放 */
  private applySpeed(): void {
    const p = this.player;
    if (p === null) {
      return;
    }
    try {
      p.setSpeed(toPlaybackSpeed(this.rate));
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setSpeed 失败（忽略）: %{public}s', (e as Error).message);
    }
  }

  /**
   * 设置应用级音量（0–1，超出范围自动钳制）。
   * 播放器未就绪时只暂存，待 prepared 阶段统一写入，避免一上来就报状态错误。
   */
  setVolume(v: number): void {
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
    if (n === this.volume) {
      return;
    }
    this.volume = n;
    this.applyVolume();
  }

  getVolume(): number {
    return this.volume;
  }

  /** 把当前音量写入 AVPlayer；状态不合法时忽略（prepared 后会再写一次） */
  private applyVolume(): void {
    const p = this.player;
    if (p === null) {
      return;
    }
    try {
      p.setVolume(this.volume);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'setVolume 失败（忽略）: %{public}s', (e as Error).message);
    }
  }

  /** 创建 AVPlayer 并注册状态机回调（并发安全：多次调用共享同一次初始化） */
  async init(): Promise<void> {
    if (this.player !== null) {
      return;
    }
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    this.initPromise = this.doInit();
    try {
      await this.initPromise;
    } finally {
      this.initPromise = null;
    }
  }

  private async doInit(): Promise<void> {
    const p: media.AVPlayer = await media.createAVPlayer();
    this.player = p;

    // 音频焦点中断：来电/其他应用抢占时暂停（受 player.isHandleAudioFocus 控制）。
    // 系统只告知"可恢复"，不自动续播——避免用户没准备时突然出声。
    p.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      if (!SettingStore.getInstance().getBoolean('player.isHandleAudioFocus', true)) {
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'audioInterrupt hint=%{public}d force=%{public}d',
        event.hintType, event.forceType);
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        this.pause();
      }
    });

    p.on('stateChange', (state: media.AVPlayerState, reason: media.StateChangeReason): void => {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'AVPlayer state: %{public}s (reason %{public}d)', state, reason);
      if (this.onState !== null) {
        this.onState(state);
      }
      if (state === 'initialized') {
        // 设置 url / fdSrc 后进入 initialized，必须 prepare 才能播放
        p.prepare().catch((err: BusinessError): void => {
          this.reportError('prepare 失败: ' + err.message);
        });
      } else if (state === 'prepared') {
        this.durationMs = p.duration;
        // reset() 会把倍速复位为 1.0，故每次 prepared 后重新应用当前倍速
        this.applySpeed();
        // 音量同样会在 reset 后复位，这里再写一次（含渐弱过程中的中间值）
        this.applyVolume();
        if (this.onTime !== null) {
          this.onTime(0, this.durationMs);
        }
        // 恢复上次播放位置：先 seek 再播，避免「先从头响一声再跳」
        const seekTo: number = this.pendingSeekMs;
        this.pendingSeekMs = -1;
        if (seekTo > 0) {
          this.currentMs = seekTo;
          try {
            p.seek(seekTo);
          } catch (e) {
            hilog.warn(LOG_DOMAIN, LOG_TAG, '恢复播放位置失败: %{public}s', (e as Error).message);
          }
        }
        this.playIfAuto();
      } else if (state === 'completed') {
        if (this.onComplete !== null) {
          this.onComplete();
        }
      }
    });

    p.on('timeUpdate', (time: number): void => {
      this.currentMs = time;
      if (this.onTime !== null) {
        this.onTime(time, this.durationMs);
      }
    });

    p.on('durationUpdate', (duration: number): void => {
      this.durationMs = duration;
      if (duration > 0 && this.onDuration !== null) {
        this.onDuration(duration);
      }
    });

    p.on('error', (err: BusinessError): void => {
      this.reportError('AVPlayer error ' + err.code + ': ' + err.message);
    });
  }

  /** prepared 之后按 autoPlay 决定是否起播（seek 与不 seek 两条路径共用） */
  private playIfAuto(): void {
    const p = this.player;
    if (p === null || !this.autoPlay) {
      return;
    }
    p.play().catch((err: BusinessError): void => {
      this.reportError('play 失败: ' + err.message);
    });
  }

  /** 设置下次载入时的定位位置（毫秒）：恢复上次播放进度用，只在 prepared 时消费一次 */
  setPendingSeek(ms: number): void {
    this.pendingSeekMs = ms > 0 ? ms : -1;
  }

  /** 载入曲目并（可选）自动播放。切歌时复用同一个 AVPlayer 实例。 */
  async load(source: PlaySource, autoPlay: boolean): Promise<void> {
    await this.init();
    const p = this.player;
    if (p === null) {
      this.reportError('AVPlayer 未初始化');
      return;
    }
    this.autoPlay = autoPlay;
    this.durationMs = source.durationMs;
    this.currentMs = 0;
    this.hasLoadedSource = false;

    await p.reset();
    this.closeRawFd();

    if (source.rawFile.length > 0) {
      const ctx: common.UIAbilityContext | null = getAppContext();
      if (ctx === null) {
        this.reportError('UIAbilityContext 未就绪，无法读取内置音频');
        return;
      }
      const raw = ctx.resourceManager.getRawFdSync(source.rawFile);
      const fdSrc: media.AVFileDescriptor = {
        fd: raw.fd,
        offset: raw.offset,
        length: raw.length
      };
      this.openedRawFile = source.rawFile;
      p.fdSrc = fdSrc;
    } else if (source.url.indexOf('file://') === 0) {
      // 本地文件：AVPlayer.url 只接受 fd:// 或网络地址，直接给 file:// 会报
      // 401 Invalid Parameter（之前本地音乐播不了就是这个原因）。改成 fdSrc 直读。
      const path: string = source.url.substring('file://'.length);
      try {
        const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
        const stat = fs.statSync(path);
        this.openedLocalFd = f.fd;
        const fdSrc: media.AVFileDescriptor = {
          fd: f.fd,
          offset: 0,
          length: stat.size
        };
        p.fdSrc = fdSrc;
      } catch (e) {
        this.reportError('打开本地文件失败: ' + (e as Error).message);
        return;
      }
    } else {
      p.url = source.url;
    }
    this.hasLoadedSource = true;
  }

  /** 当前是否载入了可用音源（取链失败清空后为 false） */
  hasSource(): boolean {
    return this.hasLoadedSource;
  }

  /**
   * 清空当前音源：取链彻底失败 / 全平台都播不了时调用。
   * 只 stop() 会保留 url，用户点播放或状态机回调仍可能把上一首继续播出来，
   * 因此这里 reset() 回 idle，彻底断开旧链接。
   */
  async clear(): Promise<void> {
    const p = this.player;
    this.hasLoadedSource = false;
    this.autoPlay = false;
    this.durationMs = 0;
    this.currentMs = 0;
    if (p === null) {
      return;
    }
    try {
      await p.reset();
    } catch (e) {
      // 某些状态下 reset 不被允许，降级为 stop，至少先停止发声
      this.stop();
    }
    this.closeRawFd();
  }

  play(): void {
    const p = this.player;
    if (p === null) {
      return;
    }
    p.play().catch((err: BusinessError): void => {
      this.reportError('play 失败: ' + err.message);
    });
  }

  pause(): void {
    const p = this.player;
    if (p === null) {
      return;
    }
    p.pause().catch((err: BusinessError): void => {
      this.reportError('pause 失败: ' + err.message);
    });
  }

  stop(): void {
    const p = this.player;
    if (p === null) {
      return;
    }
    p.stop().catch((err: BusinessError): void => {
      this.reportError('stop 失败: ' + err.message);
    });
  }

  seek(timeMs: number): void {
    const p = this.player;
    if (p === null || !this.hasLoadedSource) {
      // idle / 已 clear 的状态下 seek 会抛状态错误，直接忽略
      return;
    }
    try {
      p.seek(timeMs);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'seek 失败（忽略）: %{public}s', (e as Error).message);
    }
  }

  async release(): Promise<void> {
    const p = this.player;
    if (p === null) {
      return;
    }
    try {
      await p.release();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'release 异常，已忽略');
    }
    this.closeRawFd();
    this.player = null;
  }

  private closeRawFd(): void {
    // 本地文件的 fd 也要关，否则反复导入/切歌会耗尽句柄
    if (this.openedLocalFd >= 0) {
      try {
        fs.closeSync(this.openedLocalFd);
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'closeLocalFd 异常，已忽略');
      }
      this.openedLocalFd = -1;
    }
    if (this.openedRawFile.length === 0) {
      return;
    }
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx !== null) {
      try {
        ctx.resourceManager.closeRawFdSync(this.openedRawFile);
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'closeRawFd 异常，已忽略');
      }
    }
    this.openedRawFile = '';
  }

  private reportError(message: string): void {
    const now: number = Date.now();
    if (message === this.lastErrorMsg && now - this.lastErrorAt < 2000) {
      return;
    }
    this.lastErrorMsg = message;
    this.lastErrorAt = now;
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
    if (this.onError !== null) {
      this.onError(message);
    }
  }
}
