/**
 * 自定义音源脚本运行时：在隔离的 Web 沙箱中执行用户导入的音源脚本。
 *
 * 运行环境：ArkTS 不能执行动态 JS，改用系统 Web 组件（ArkWeb）作隔离沙箱，
 *   rawfile/lx_prelude.js 注入 globalThis.lx，javaScriptProxy 提供 __lxHost，
 *   WebviewController.runJavaScript 把请求 / HTTP 响应送回脚本。
 *
 * 消息协议（与两端完全一致）：
 *   脚本→宿主  inited{sources} / updateAlert{log,updateUrl} / response{requestKey,status,result|errorMessage}
 *              / httpRequest{requestKey,url,options} / httpCancel{requestKey}
 *   宿主→脚本  request{requestKey,data:{source,action,info:{type,musicInfo}}} / httpResponse{requestKey,error,response}
 *   单次取链 20s 看门狗；inited 10s 超时；url 必须是 http(s) 且 ≤2048 字符。
 *
 * 安全：脚本在独立 Web 页面里，拿不到 ArkTS 侧任何对象，唯一出口是 __lxHost.post；
 * prelude 禁用了 fetch / XHR / WebSocket / Worker，网络一律经宿主代发。
 */
import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HttpClient, HttpOptions, HttpResult, Json, makeHttpOptions } from './HttpClient';
import { CustomScriptStore, CustomScriptMeta } from './CustomScriptStore';
import { MusicInfo, MusicInfoMetaOnline, MusicQualityType } from '../../model/MusicTypes';
import { Quality, OnlineSource, TRY_QUALITYS_LIST, ONLINE_SOURCES } from '../../config/AppConstants';
import { getAppContext } from '../../common/AppContext';
import { stateEvent, StateEvents } from '../../store/EventBus';
import { AppState } from '../../store/AppState';
import { LOG_DOMAIN, LOG_TAG } from '../../common/Constants';

const SUPPORTED_QUALITYS: string[] = ['128k', '320k', 'flac', 'flac24bit'];
const INIT_TIMEOUT_MS: number = 7000;
const REQUEST_TIMEOUT_MS: number = 20000;
const PAGE_TIMEOUT_MS: number = 4000;
/** 冷启动时等待隐藏 Web 组件上屏（attach 之前）的最长时间 */
const CONTROLLER_WAIT_MS: number = 3000;
/** 沙箱重建的最小间隔：避免某首歌取链失败就反复重载页面 */
const REBUILD_COOLDOWN_MS: number = 20000;
/**
 * 取链路径上等锁的最长时间：有人在初始化（尤其启动预热刚触发）时最多等这么久，
 * 超过就先走 HTTP 兜底。整体仍受 6s 取链预算约束，不会让播放无限等。
 */
const LOCK_WAIT_MS: number = 5000;
/**
 * 单首歌「初始化 + 取链」的总预算（2026-11-16 用户要求由 12s 收紧到 6s）。
 * 启动预热 + 20s 心跳探活已经让沙箱基本常驻，取链路径上很少需要现场重建；
 * 真需要重建时也不再让播放干等——超过 6s 立刻回落 HTTP 音源，
 * 重建继续在后台跑完，下一首就能重新用上自定义源。
 */
const RESOLVE_BUDGET_MS: number = 6000;
/**
 * 沙箱心跳间隔：播放期间定期探活，发现页面被系统回收就在后台悄悄重建，
 * 这样切歌时环境已经好了，不会出现「播一会就停、得点一下重新初始化」。
 */
const HEARTBEAT_MS: number = 20000;
/** 单次 runJavaScript 的最长等待（渲染进程冻结时不能无限等） */
const JS_TIMEOUT_MS: number = 8000;
/** 沙箱环境失效（页面被系统回收 / 重载）时的统一错误文案 */
const ENV_ERROR: string = '脚本环境无响应';

/**
 * 脚本代发 HTTP 的速率护栏。正常音源一首歌约 1~5 个请求，12 个突发令牌 + 每秒补 2 个
 * （长期约 120 次/分钟）完全够用；失控脚本写 setInterval 高频轮询时会被拦下，
 * 避免本机公网 IP 被目标平台当成爬虫风控封禁。
 */
const SCRIPT_HTTP_BURST: number = 12;
const SCRIPT_HTTP_REFILL_PER_SEC: number = 2;
const SCRIPT_HTTP_MAX_CONCURRENT: number = 6;
/** 目标站返回 429/403 后该域名短暂冷却，不继续打（避免加剧封禁） */
const SCRIPT_HTTP_HOST_COOLDOWN_MS: number = 30000;

/**
 * 健康探针：一次 runJavaScript 同时校验「宿主代理 / 分发函数 / 健康函数」是否还在。
 * 页面被系统回收后这些全局全都没了；脚本自身状态异常则 __lxHealth 返回非 '11'。
 */
const PROBE_JS: string = '(function(){try{'
  + 'if(typeof window.__lxHost!=="object")return "nohost";'
  + 'if(typeof window.__lxDispatch!=="function")return "nodispatch";'
  + 'if(typeof window.__lxHealth!=="function")return "nohealth";'
  + 'return String(window.__lxHealth());}catch(e){return "err";}})()';

export interface ScriptUrlResult {
  ok: boolean;
  url: string;
  quality: Quality;
  error: string;
}

export interface ScriptUpdateAlert {
  name: string;
  log: string;
  updateUrl: string;
}

interface PendingRequest {
  finish: (r: ScriptUrlResult) => void;
  timer: number;
  quality: Quality;
}

interface QualityHash {
  hash: string;
  size: number | null;
}

interface ScriptMusicMeta {
  songId: string;
  albumName: string;
  picUrl: string;
  hash: string;
  strMediaMid: string;
  copyrightId: string;
  qualitys: MusicQualityType[];
  _qualitys: Record<string, QualityHash>;
}

interface ScriptMusicInfo {
  id: string;
  name: string;
  singer: string;
  source: string;
  interval: string;
  /** 顶层 songmid / hash：真实音源脚本用 musicInfo.hash ?? musicInfo.songmid 取标识 */
  songmid: string;
  hash: string;
  strMediaMid: string;
  copyrightId: string;
  qualitys: MusicQualityType[];
  _qualitys: Record<string, QualityHash>;
  meta: ScriptMusicMeta;
}

export interface InitState {
  ok: boolean;
  error: string;
}

/** __lxSetup 注入给脚本的元信息（对象字面量必须有显式类型，ArkTS 严格模式） */
interface ScriptSetupInfo {
  name: string;
  description: string;
  version: string;
  author: string;
  homepage: string;
  rawScript: string;
}

/** 宿主回给脚本的 HTTP 响应 */
interface ScriptHttpResponse {
  statusCode: number;
  statusMessage: string;
  headers: Record<string, string>;
  body: string;
}

interface HttpEventPayload {
  requestKey: string;
  error: string;
  response: ScriptHttpResponse;
}

interface RequestInfoPayload {
  type: string;
  musicInfo: ScriptMusicInfo;
}

interface RequestDataPayload {
  source: OnlineSource;
  action: string;
  info: RequestInfoPayload;
}

interface RequestEventPayload {
  requestKey: string;
  data: RequestDataPayload;
}

let sInstance: CustomScriptRunner | null = null;

export class CustomScriptRunner {
  private controller: webview.WebviewController | null = null;
  private prelude: string = '';
  private pageReady: Promise<void> | null = null;
  private pageReadyResolve: (() => void) | null = null;
  private initResolve: ((ok: boolean) => void) | null = null;
  private initTimer: number = 0;
  private requests: Map<string, PendingRequest> = new Map();
  private sources: Map<string, string[]> = new Map();
  private currentScriptId: string = '';
  private currentMeta: CustomScriptMeta | null = null;
  private inited: boolean = false;
  private allowUpdateAlert: boolean = true;
  private lastError: string = '';
  private lastInitOk: boolean = false;
  private updateAlertShown: boolean = false;
  private pendingUpdate: ScriptUpdateAlert | null = null;
  /**
   * 初始化失败后的软冷却（原来这里记成一个「永久拉黑」的 id，
   * 失败一次之后所有取链都直接返回 null，必须重启应用才恢复——用户反馈的就是这个）。
   * 现在只冷却一小段时间，到期自动重试，连续失败才逐步拉长（5s → 10s → 15s → 20s 封顶）。
   */
  private failId: string = '';
  private failAt: number = 0;
  private failCount: number = 0;
  /** 是否已经尝试过初始化（设置页据此区分「待使用」与「上次失败」） */
  private attempted: boolean = false;
  /** 上次自动重建沙箱的时间（冷却用） */
  private lastRebuildAt: number = 0;
  /** 上次「等不到沙箱上屏」的时间：30s 内不再重复空等，避免每首歌都卡 8s */
  private envWaitFailAt: number = 0;
  /** 串行锁（支持等待超时，避免一个卡住的初始化把后续取链全堵死） */
  private lockBusy: boolean = false;
  private lockWaiters: (() => void)[] = [];
  /** 预热/补初始化是否在进行中（避免启动预热与心跳重复重建同一个页面） */
  private warming: boolean = false;
  /** 沙箱心跳定时器句柄（-1 表示未启动） */
  private beatTimer: number = -1;
  /** 心跳本轮是否还在跑：上一轮重建没结束时不再叠加 */
  private beatBusy: boolean = false;
  /** 脚本代发请求的令牌桶 / 在途计数 / 域名冷却（防失控脚本打爆 IP） */
  private httpTokens: number = SCRIPT_HTTP_BURST;
  private httpTokenAt: number = Date.now();
  private httpInFlight: number = 0;
  private httpHostCooldown: Map<string, number> = new Map();

  static getInstance(): CustomScriptRunner {
    if (sInstance === null) {
      sInstance = new CustomScriptRunner();
    }
    return sInstance;
  }

  /** 隐藏 Web 组件在页面上屏后把控制器交给运行时 */
  attach(controller: webview.WebviewController): void {
    if (this.controller !== null && this.controller !== controller) {
      // 页面被重建：旧控制器里的沙箱环境已经作废，下次取链必须重新初始化
      this.resetRuntime();
      this.currentScriptId = '';
      this.lastInitOk = false;
      this.attempted = false;
    }
    this.controller = controller;
  }

  /** Web.onPageEnd：每次 loadData 都会走到这里，代表脚本环境已重建 */
  onPageEnd(): void {
    if (this.pageReadyResolve !== null) {
      const fn: () => void = this.pageReadyResolve;
      this.pageReadyResolve = null;
      fn();
    }
  }

  /** 供 javaScriptProxy 注册的宿主对象调用 */
  onHostMessage(action: string, payload: string): void {
    const o: Object | null = Json.parse(payload);
    if (o === null) {
      return;
    }
    switch (action) {
      case 'inited':
        this.handleInited(o);
        break;
      case 'updateAlert':
        this.handleUpdateAlert(o);
        break;
      case 'response':
        this.handleResponse(o);
        break;
      case 'httpRequest':
        void this.handleHttpRequest(o);
        break;
      case 'httpCancel':
        // @ohos.net.http 无中途 abort 接口；请求结束后响应会被丢弃，不影响正确性
        hilog.info(LOG_DOMAIN, LOG_TAG, 'custom source httpCancel ignored');
        break;
      default:
        break;
    }
  }

  onHostLog(text: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'lx script: %{public}s', text.substring(0, 300));
  }

  getInitState(): InitState {
    return { ok: this.lastInitOk, error: this.lastError };
  }

  takeUpdate(): ScriptUpdateAlert | null {
    const u: ScriptUpdateAlert | null = this.pendingUpdate;
    this.pendingUpdate = null;
    return u;
  }

  /** 切换 / 删除 / 更新脚本时清空运行时，下次取链会重新加载 */
  invalidate(): void {
    this.resetRuntime();
    this.currentScriptId = '';
    this.currentMeta = null;
    this.lastInitOk = false;
    this.lastError = '';
    this.failId = '';
    this.failAt = 0;
    this.failCount = 0;
    this.attempted = false;
  }

  /**
   * 播放链路入口：优先用当前启用的自定义音源脚本取链。
   * 返回 null 表示「脚本不可用或未取到」，调用方应继续走原有 HTTP 音源服务兜底。
   */
  async tryResolve(info: MusicInfo, prefer: Quality, forDownload: boolean = false): Promise<ScriptUrlResult | null> {
    if (info.source === 'local') {
      return null;
    }
    await CustomScriptStore.getInstance().init();
    const meta: CustomScriptMeta | null = CustomScriptStore.getInstance().getActive();
    if (meta === null) {
      return null;
    }
    // 冷却期内直接放过（走 HTTP 兜底），不拖住播放；到期会自动再试。
    // 注意这里只冷却，不再「永久拉黑」——旧实现失败一次就再也不尝试，必须重启应用才恢复。
    if (this.inCooldown(meta.id)) {
      return null;
    }
    if (this.controller === null) {
      // 页面还没上屏：30s 内只等一次，避免每首歌都白白等 3s
      if (Date.now() - this.envWaitFailAt < 30000) {
        return null;
      }
      await this.waitForController(CONTROLLER_WAIT_MS);
      if (this.controller === null) {
        this.envWaitFailAt = Date.now();
        this.lastInitOk = false;
        this.lastError = '脚本运行环境尚未就绪';
        return null;
      }
    }
    // 后台（锁屏 / 切走）时不重建沙箱：隐藏 Web 的渲染进程此时多半被冻结，
    // 重建只会白等十几秒，而且会把失败次数堆高、冷却越来越长
    // （表现就是「锁屏听一阵，回到应用后自定义源一直不可用」）。
    const bg: boolean = AppState.getInstance().appInBackground;
    if (bg && !this.inited) {
      return null;
    }
    // 有人在初始化（例如刚打开设置页）时最多等 LOCK_WAIT_MS：
    // 超过就先返回 null 走 HTTP 兜底，让播放马上有声音，而不是转圈等十几秒。
    const work: Promise<ScriptUrlResult | null> = this.withLock(LOCK_WAIT_MS,
      async (): Promise<ScriptUrlResult | null> => {
        return await this.resolveLocked(meta, info, prefer, bg, forDownload);
      });
    // 总预算兜底：极端情况下（重建页面 + 脚本迟迟不 inited）不能让播放一直挂着
    return await Promise.race([
      work,
      this.delay(RESOLVE_BUDGET_MS).then((): ScriptUrlResult | null => {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'custom source budget exceeded, fallback to http source');
        return null;
      }),
    ]);
  }

  /** 持锁执行：初始化 → 取链 → 失败时重建一次再试 */
  private async resolveLocked(meta: CustomScriptMeta, info: MusicInfo,
    prefer: Quality, bg: boolean, forDownload: boolean): Promise<ScriptUrlResult | null> {
    // 后台已初始化过的环境直接用（不探针，避免冻结造成的超时误判）
    const ready: boolean = bg ? this.inited : await this.prepareLocked(meta, true);
    if (!ready) {
      // 所有初始化失败（含「超时未上报 inited」「环境无响应」）统一进软冷却，到期自动重试。
      // 后台失败不计入：那多半只是渲染进程被冻结，不是脚本真有问题。
      if (!bg && !forDownload) {
        this.markFail(meta.id);
      }
      return null;
    }
    if (!bg) {
      this.clearFail();
    }
    const source: OnlineSource = info.source as OnlineSource;
    const supported: string[] | undefined = this.sources.get(source);
    if (supported === undefined || supported.length === 0) {
      return null;
    }
    const start: number = TRY_QUALITYS_LIST.indexOf(prefer);
    const order: Quality[] = start >= 0 ? TRY_QUALITYS_LIST.slice(start) : [prefer];
    let r: ScriptUrlResult | null = await this.resolveOrder(source, order, supported, info);
    if (r !== null) {
      return r;
    }
    // 下载链路失败后不再重建沙箱重试：下载失败可以换源，但不该额外付一次重建请求
    if (bg || forDownload) {
      return null;
    }
    // 整首取链失败：脚本内的登录态 / token 可能过期，或沙箱页面已被系统回收。
    // 这里自动重建一次沙箱再试（等价于用户手动重选音源），仍失败才交给上层兜底。
    if (Date.now() - this.lastRebuildAt < REBUILD_COOLDOWN_MS) {
      return null;
    }
    this.lastRebuildAt = Date.now();
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'custom source failed, rebuild sandbox and retry once');
    this.currentScriptId = '';
    this.inited = false;
    if (!await this.prepareLocked(meta, true)) {
      this.markFail(meta.id);
      return null;
    }
    this.clearFail();
    const again: string[] | undefined = this.sources.get(source);
    if (again === undefined || again.length === 0) {
      return null;
    }
    r = await this.resolveOrder(source, order, again, info);
    return r;
  }

  /** 按音质顺序逐个向脚本要链接；全部失败返回 null */
  private async resolveOrder(source: OnlineSource, order: Quality[],
    supported: string[], info: MusicInfo): Promise<ScriptUrlResult | null> {
    let lastError: string = '';
    for (const q of order) {
      if (supported.indexOf(q) < 0) {
        continue;
      }
      const r: ScriptUrlResult = await this.requestMusicUrl(source, q, info);
      if (r.ok && r.url.length > 0) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'custom source resolved: %{public}s @%{public}s', info.name, q);
        return r;
      }
      lastError = r.error;
    }
    if (lastError.length > 0) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'custom source failed, fallback to endpoints: %{public}s', lastError);
    }
    return null;
  }

  /**
   * 下载专用取链（独立实现）：用「指定的脚本」直接要链接，谁拿到就用谁。
   *
   * 与播放链路 tryResolve 的区别（刻意隔离，避免下载拖累听歌）：
   * - 不套 6s 播放预算：下载可以耐心等脚本走完，上限由 REQUEST_TIMEOUT_MS 兜底；
   * - 不写初始化冷却 / 不 markFail：失败只是这个脚本不适合，不影响播放的软冷却；
   * - 不做「整首失败后重建沙箱重试」：下载失败可换下一个脚本，不必额外付一次重建请求；
   * - 不判断后台：下载是用户主动点的行为，即使锁屏也要在持锁下完成。
   *
   * 全程在串行锁内执行（一个 WebView 同时只能跑一个脚本），prepareLocked 会
   * resetRuntime 清掉上一个脚本的 sources，因此串行切换不同 meta 不会串味。
   * 调用方负责在取链结束后把沙箱恢复成用户当前启用的脚本（restoreActiveScript）。
   */
  async tryResolveForDownload(meta: CustomScriptMeta, info: MusicInfo,
    prefer: Quality): Promise<ScriptUrlResult | null> {
    if (info.source === 'local') {
      return null;
    }
    if (!await this.acquire(LOCK_WAIT_MS * 3)) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'download resolve: sandbox busy, skip this script');
      return null;
    }
    try {
      if (!await this.prepareLocked(meta, true)) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'download resolve: init failed for %{public}s', meta.name);
        return null;
      }
      const source: OnlineSource = info.source as OnlineSource;
      const supported: string[] | undefined = this.sources.get(source);
      if (supported === undefined || supported.length === 0) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'download resolve: %{public}s not supported by %{public}s',
          source, meta.name);
        return null;
      }
      const start: number = TRY_QUALITYS_LIST.indexOf(prefer);
      const order: Quality[] = start >= 0 ? TRY_QUALITYS_LIST.slice(start) : [prefer];
      const r: ScriptUrlResult | null = await this.resolveOrder(source, order, supported, info);
      if (r !== null) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'download resolved by %{public}s: %{public}s @%{public}s',
          meta.name, info.name, r.quality);
      }
      return r;
    } finally {
      this.release();
    }
  }

  /**
   * 下载结束后把沙箱恢复成用户当前启用的脚本。
   * 不恢复的话，下一次播放取链会发现 currentScriptId 不匹配而自动重建，
   * 虽然结果正确但会多付一次重建请求；这里主动切回，省掉那次重建。
   */
  async restoreActiveScript(): Promise<void> {
    const active: CustomScriptMeta | null = CustomScriptStore.getInstance().getActive();
    if (active === null) {
      return;
    }
    if (this.inited && this.currentScriptId === active.id && await this.envAlive()) {
      return;
    }
    if (!await this.acquire(LOCK_WAIT_MS * 3)) {
      return;
    }
    try {
      await this.prepareLocked(active, true);
    } finally {
      this.release();
    }
  }

  /**
   * 初始化（设置页/导入脚本后主动调用）。
   * allowRebuild=false 时只做状态确认，不重建沙箱——设置页只是看一眼，
   * 没必要为了显示一行状态去重载整个 Web 页面（那正是「一直卡在初始化中」的来源）。
   */
  async prepare(meta: CustomScriptMeta, allowRebuild: boolean = true): Promise<boolean> {
    if (!await this.acquire(allowRebuild ? LOCK_WAIT_MS * 2 : LOCK_WAIT_MS)) {
      return false;
    }
    try {
      return await this.prepareLocked(meta, allowRebuild);
    } finally {
      this.release();
    }
  }

  /**
   * 启动预热（2026-11-16 用户要求）：应用启动后主动把沙箱页面拉起来并执行脚本，
   * 等用户点播放时环境已经就绪，不用在取链路径上现等初始化。
   *
   * 与早期「预热」的区别：那次只跑一次、失败了也没人管，页面上留着一个
   * 「看起来初始化过、其实已经死了」的状态；现在预热之外还有心跳探活 + 软冷却重试，
   * 失败了会自己再补上，不会再出现「必须重启应用才恢复」。
   */
  async warmUp(): Promise<void> {
    this.startHeartbeat();
    if (this.warming) {
      return;
    }
    this.warming = true;
    try {
      await this.ensureInited();
    } finally {
      this.warming = false;
    }
  }

  /** 回到前台：恢复心跳；环境在后台被冻结/回收过就顺手补一次初始化 */
  onForeground(): void {
    this.startHeartbeat();
    if (this.inited) {
      return;
    }
    // 冷启动时 onForeground 会早于界面上屏，等控制器挂上再预热，避免白记一次失败
    setTimeout((): void => { void this.warmUp(); }, 800);
  }

  /** 启动 20s 心跳（重复调用无副作用） */
  startHeartbeat(): void {
    if (this.beatTimer !== -1) {
      return;
    }
    this.beatTimer = setInterval((): void => { void this.heartbeat(); }, HEARTBEAT_MS);
  }

  /**
   * 心跳：已初始化就探一次活，探不到就地后台重建；没初始化就补一次预热。
   * 后台 / 有人正持锁取链时整轮跳过——后台渲染进程被冻结，探测只会误判，
   * 把失败次数堆高还会让冷却变长。
   */
  private async heartbeat(): Promise<void> {
    // 有取链请求在飞（或有人持锁初始化）时整轮跳过：这时渲染进程本来就忙，
    // 探针很容易超时，误判成「环境已死」去重建反而会把正在进行的取链打断。
    if (this.beatBusy || this.lockBusy || this.requests.size > 0) {
      return;
    }
    if (AppState.getInstance().appInBackground) {
      return;
    }
    const meta: CustomScriptMeta | null = CustomScriptStore.getInstance().getActive();
    if (meta === null) {
      return;
    }
    this.beatBusy = true;
    try {
      if (this.inited && this.currentScriptId === meta.id && await this.envAlive()) {
        return;
      }
      if (this.inCooldown(meta.id)) {
        return;
      }
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'sandbox heartbeat: env lost, rebuild in background');
      this.inited = false;
      this.currentScriptId = '';
      this.lastRebuildAt = Date.now();
      if (await this.prepare(meta, true)) {
        this.clearFail();
      } else {
        this.markFail(meta.id);
      }
    } finally {
      this.beatBusy = false;
    }
  }

  /** 确保「当前启用的脚本」已经在沙箱里跑起来（预热 / 心跳 / 回前台共用） */
  private async ensureInited(): Promise<void> {
    await CustomScriptStore.getInstance().init();
    const meta: CustomScriptMeta | null = CustomScriptStore.getInstance().getActive();
    if (meta === null) {
      return;
    }
    if (this.currentScriptId === meta.id && this.inited) {
      return;
    }
    if (this.inCooldown(meta.id)) {
      return;
    }
    // 冷启动时界面可能还没上屏：先等控制器；等不到是「还没准备好」，不是脚本失败，
    // 不计冷却，交给 20s 后的心跳再来一次
    if (this.controller === null) {
      await this.waitForController(CONTROLLER_WAIT_MS * 2);
      if (this.controller === null) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'warm up skipped: sandbox not attached yet');
        return;
      }
    }
    if (await this.prepare(meta, true)) {
      this.clearFail();
    } else {
      this.markFail(meta.id);
    }
  }

  /**
   * 当前是否有生效的自定义源脚本。
   * 供「下一首预取」判断用：只用自定义源、没配 HTTP 音源服务时，
   * 预取是沙箱唯一的提前自愈窗口，不能被 isConfigured() 一刀砍掉。
   */
  hasActiveScript(): boolean {
    return CustomScriptStore.getInstance().getActive() !== null;
  }

  /** 是否已经初始化过（任意结果），供设置页区分「待使用」与「上次失败」 */
  wasAttempted(): boolean {
    return this.attempted;
  }

  /** 已在串行锁内时使用的初始化实现 */
  private async prepareLocked(meta: CustomScriptMeta, allowRebuild: boolean): Promise<boolean> {
    this.attempted = true;
    // 冷启动时设置页可能比隐藏 Web 组件先上屏：等一会儿而不是直接判失败，
    // 否则用户会看到「初始化失败：脚本运行环境尚未就绪」，必须手动重选才能恢复。
    // 只查状态时不等（设置页要秒开）。
    if (this.controller === null && !allowRebuild) {
      this.lastInitOk = false;
      return false;
    }
    if (this.controller === null) {
      await this.waitForController(CONTROLLER_WAIT_MS);
    }
    if (this.controller === null) {
      this.envWaitFailAt = Date.now();
      this.lastInitOk = false;
      this.lastError = '脚本运行环境尚未就绪';
      return false;
    }
    if (this.currentScriptId === meta.id && this.inited) {
      // 已经初始化过：先探一次，页面被系统回收 / 重载后要重新来一遍
      if (await this.envAlive()) {
        return true;
      }
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'sandbox env lost, re-init custom source');
      this.inited = false;
      this.currentScriptId = '';
      if (!allowRebuild) {
        // 只是查状态：把「需要重连」如实告诉调用方，重建留给真正要取链的时候
        this.lastInitOk = false;
        this.lastError = '脚本环境已断开（播放时会自动重连）';
        return false;
      }
    } else if (!allowRebuild && this.currentScriptId !== meta.id) {
      // 从未初始化 / 上次失败：本次只查状态。
      // 保留 lastError 让用户能看到上次为什么失败（首次运行时它就是空的 → 显示「待使用」）
      this.lastInitOk = false;
      return false;
    }
    const text: string = CustomScriptStore.getInstance().readScript(meta.id);
    if (text.length === 0) {
      this.lastInitOk = false;
      this.lastError = '脚本正文读取失败';
      return false;
    }
    this.ensurePrelude();
    if (this.prelude.length === 0) {
      this.lastInitOk = false;
      this.lastError = '沙箱注入层读取失败';
      return false;
    }

    this.resetRuntime();
    this.currentMeta = meta;
    this.allowUpdateAlert = meta.allowShowUpdateAlert;
    this.currentScriptId = meta.id;

    // 重新加载 rawfile 沙箱页 = 全新的 JS 全局环境，避免 const 重复声明。
    // 这里刻意不用 loadData：data: 页面是不透明源，javaScriptProxy 未必注入；
    // refresh() 重载的是同一个 resource://rawfile 页面，声明式代理每次加载都会重新注入。
    this.pageReady = new Promise<void>((res: () => void): void => {
      this.pageReadyResolve = res;
    });
    const pageGate: Promise<void> = this.pageReady;
    try {
      this.controller.refresh();
    } catch (e) {
      this.lastError = '沙箱页面加载失败：' + this.errText(e);
      this.lastInitOk = false;
      return false;
    }
    const pageOk: boolean = await Promise.race([
      pageGate.then((): boolean => true),
      this.delay(PAGE_TIMEOUT_MS).then((): boolean => false),
    ]);
    if (!pageOk) {
      // refresh 未触发页面事件时仍可继续：下面用 __lxReset + IIFE 保证环境干净，
      // proxyAvailable 会再确认当前页面确实可用。
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'sandbox reload not confirmed, reuse current page');
    }
    if (!await this.proxyAvailable()) {
      this.lastError = '沙箱原生代理未注入（__lxHost 不可用）';
      this.lastInitOk = false;
      return false;
    }

    if (!await this.runJs(this.prelude)) {
      this.finishInit(false, this.lastError);
      return false;
    }
    if (!await this.runJs('__lxReset()')) {
      this.finishInit(false, this.lastError);
      return false;
    }
    const scriptInfo: ScriptSetupInfo = {
      name: meta.name, description: meta.description, version: meta.version,
      author: meta.author, homepage: meta.homepage, rawScript: text,
    };
    if (!await this.runJs('__lxSetup(' + JSON.stringify(scriptInfo) + ')')) {
      this.finishInit(false, this.lastError);
      return false;
    }

    const initGate: Promise<boolean> = new Promise<boolean>((res: (ok: boolean) => void): void => {
      this.initResolve = res;
      this.initTimer = setTimeout((): void => {
        this.initResolve = null;
        res(false);
      }, INIT_TIMEOUT_MS);
    });
    // IIFE 包裹：页面未真正重载时避免上一个脚本的顶层 const/function 重复声明
    const wrapped: string = '(function(){\n' + text + '\n})();';
    if (!await this.runJs(wrapped)) {
      this.finishInit(false, '脚本执行出错：' + this.lastError);
      return false;
    }
    const ok: boolean = await initGate;
    this.finishInit(ok, ok ? '' : '初始化超时或脚本未上报 inited');
    return ok;
  }

  // ------------------------------------------------------------------ 内部

  private ensurePrelude(): void {
    if (this.prelude.length > 0) {
      return;
    }
    const ctx = getAppContext();
    if (ctx === null) {
      return;
    }
    try {
      const bytes: Uint8Array = ctx.resourceManager.getRawFileContentSync('lx_prelude.js');
      this.prelude = new util.TextDecoder().decodeToString(bytes);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'read lx_prelude.js failed');
      this.lastError = '读取沙箱注入层失败';
    }
  }

  private finishInit(ok: boolean, error: string): void {
    if (this.initTimer !== 0) {
      clearTimeout(this.initTimer);
      this.initTimer = 0;
    }
    const fn: ((ok: boolean) => void) | null = this.initResolve;
    this.initResolve = null;
    this.inited = ok;
    this.lastInitOk = ok;
    this.lastError = error;
    if (!ok) {
      this.currentScriptId = '';
      this.sources.clear();
    }
    if (fn !== null) {
      fn(ok);
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'custom source init: %{public}s %{public}s',
      ok ? 'OK' : 'FAILED', error);
  }

  private handleInited(o: Object): void {
    const srcObj: Object | null = Json.obj(o, 'sources');
    const map: Map<string, string[]> = new Map();
    if (srcObj !== null) {
      const rec: Record<string, Object> = srcObj as Record<string, Object>;
      for (const key of Object.keys(rec)) {
        if (ONLINE_SOURCES.indexOf(key as OnlineSource) < 0) {
          continue;
        }
        const item: Object = rec[key];
        const arr: Object[] = Json.arr(item, 'qualitys');
        const list: string[] = [];
        for (const v of arr) {
          const q: string = Json.toStr(v, '');
          if (SUPPORTED_QUALITYS.indexOf(q) >= 0 && list.indexOf(q) < 0) {
            list.push(q);
          }
        }
        map.set(key, list);
      }
    }
    this.sources = map;
    this.finishInit(map.size > 0, map.size > 0 ? '' : '脚本未上报支持的音源');
  }

  private handleUpdateAlert(o: Object): void {
    if (!this.allowUpdateAlert || this.updateAlertShown) {
      return;
    }
    this.updateAlertShown = true;
    const log: string = Json.str(o, 'log', '');
    if (log.length === 0) {
      return;
    }
    this.pendingUpdate = {
      name: this.currentMeta === null ? '自定义音源' : this.currentMeta.name,
      log,
      updateUrl: Json.str(o, 'updateUrl', ''),
    };
    stateEvent().emit(StateEvents.CUSTOM_SOURCE_UPDATE);
  }

  private handleResponse(o: Object): void {
    const key: string = Json.str(o, 'requestKey', '');
    const p: PendingRequest | undefined = this.requests.get(key);
    if (p === undefined) {
      return;
    }
    this.requests.delete(key);
    clearTimeout(p.timer);
    const rec: Record<string, Object> = o as Record<string, Object>;
    const success: boolean = Json.toStr(rec['status'], '') === 'true';
    if (!success) {
      p.finish({ ok: false, url: '', quality: p.quality, error: Json.str(o, 'errorMessage', '脚本取链失败') });
      return;
    }
    const result: Object | null = Json.obj(o, 'result');
    const data: Object | null = Json.obj(result, 'data');
    const url: string = Json.str(data, 'url', '');
    if (!url.startsWith('http') || url.length > 2048) {
      p.finish({ ok: false, url: '', quality: p.quality, error: '脚本返回的播放链接无效' });
      return;
    }
    p.finish({ ok: true, url, quality: p.quality, error: '' });
  }

  /** 从脚本给的 URL 里取主机名，用于按域名冷却；不用 URL 类以免兼容问题 */
  private hostOf(url: string): string {
    const m: RegExpMatchArray | null = url.match(/^https?:\/\/([^\/:?#]+)/i);
    return m !== null ? m[1].toLowerCase() : '';
  }

  /** 令牌桶取一个令牌：每秒补 2 个，最多攒 12 个；false = 当前太频繁 */
  private takeHttpToken(): boolean {
    const now: number = Date.now();
    const elapsed: number = Math.max(0, now - this.httpTokenAt);
    this.httpTokens = Math.min(SCRIPT_HTTP_BURST,
      this.httpTokens + elapsed * SCRIPT_HTTP_REFILL_PER_SEC / 1000);
    this.httpTokenAt = now;
    if (this.httpTokens < 1) {
      return false;
    }
    this.httpTokens -= 1;
    return true;
  }

  /** 限流/冷却时也要回一个 httpResponse，否则脚本的 callback 永远不触发 */
  private async rejectHttp(key: string, reason: string): Promise<void> {
    const payload: HttpEventPayload = {
      requestKey: key,
      error: reason,
      response: { statusCode: 0, statusMessage: '', headers: {}, body: '' },
    };
    await this.dispatch('httpResponse', payload);
  }

  private async handleHttpRequest(o: Object): Promise<void> {
    const key: string = Json.str(o, 'requestKey', '');
    const url: string = Json.str(o, 'url', '');
    const host: string = this.hostOf(url);
    const coolUntil: number = this.httpHostCooldown.get(host) ?? 0;
    if (coolUntil > Date.now()) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'script http cooldown: %{public}s', host);
      await this.rejectHttp(key, '目标站点暂时限流，30 秒后自动恢复');
      return;
    }
    if (this.httpInFlight >= SCRIPT_HTTP_MAX_CONCURRENT || !this.takeHttpToken()) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'script http throttled');
      await this.rejectHttp(key, '音源请求过于频繁，已临时限速');
      return;
    }
    this.httpInFlight++;
    const optsObj: Object | null = Json.obj(o, 'options');
    const method: string = Json.str(optsObj, 'method', 'GET').toUpperCase();
    const timeoutRaw: number = Json.num(optsObj, 'timeout', 60000);
    const timeoutMs: number = Math.max(1000, Math.min(timeoutRaw > 0 ? timeoutRaw : 60000, 60000));

    const headers: Record<string, string> = {};
    const headersObj: Object | null = Json.obj(optsObj, 'headers');
    if (headersObj !== null) {
      const hr: Record<string, Object> = headersObj as Record<string, Object>;
      for (const k of Object.keys(hr)) {
        headers[k] = Json.toStr(hr[k], '');
      }
    }

    let body: string = '';
    if (optsObj !== null) {
      const oRec: Record<string, Object> = optsObj as Record<string, Object>;
      const bodyVal: Object = oRec['body'];
      if (typeof bodyVal === 'string') {
        body = bodyVal as string;
      } else if (bodyVal !== undefined && bodyVal !== null && typeof bodyVal === 'object') {
        body = JSON.stringify(bodyVal);
      }
    }
    const formObj: Object | null = Json.obj(optsObj, 'form');
    if (body.length === 0 && formObj !== null) {
      const fr: Record<string, Object> = formObj as Record<string, Object>;
      const parts: string[] = [];
      for (const k of Object.keys(fr)) {
        parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(Json.toStr(fr[k], '')));
      }
      body = parts.join('&');
      if (headers['Content-Type'] === undefined) {
        headers['Content-Type'] = 'application/x-www-form-urlencoded';
      }
    }

    try {
      const httpOpts: HttpOptions = makeHttpOptions();
      httpOpts.method = method === 'POST' ? 'POST' : 'GET';
      httpOpts.headers = headers;
      httpOpts.body = body;
      httpOpts.timeoutMs = timeoutMs;
      // 音源脚本可能请求 http:// 明文端点；这里保留原样（secureUrl 会强制升级，可能连不上）
      httpOpts.allowHttp = true;
      const r: HttpResult = await HttpClient.request(url, httpOpts);
      // 被目标站点明确限流/拒绝时给该域名短暂冷却，不继续追加请求
      if (r.statusCode === 429 || r.statusCode === 403) {
        this.httpHostCooldown.set(host, Date.now() + SCRIPT_HTTP_HOST_COOLDOWN_MS);
      }
      const emptyResponse: ScriptHttpResponse = {
        statusCode: r.statusCode, statusMessage: '', headers: {}, body: '',
      };
      const payload: HttpEventPayload = r.ok ? {
        requestKey: key,
        error: '',
        response: {
          statusCode: r.statusCode,
          statusMessage: '',
          headers: {},
          body: r.text,
        },
      } : {
        requestKey: key,
        error: r.error.length > 0 ? r.error : 'request failed',
        response: emptyResponse,
      };
      await this.dispatch('httpResponse', payload);
    } finally {
      this.httpInFlight--;
    }
  }

  private async requestMusicUrl(source: OnlineSource, quality: Quality,
    info: MusicInfo): Promise<ScriptUrlResult> {
    const key: string = 'url__' + Date.now().toString() + '__' + Math.random().toString().substring(2, 10);
    const gate: Promise<ScriptUrlResult> = new Promise<ScriptUrlResult>((res: (r: ScriptUrlResult) => void): void => {
      const timer: number = setTimeout((): void => {
        this.requests.delete(key);
        res({ ok: false, url: '', quality, error: '自定义音源取链超时（20s）' });
      }, REQUEST_TIMEOUT_MS);
      const pending: PendingRequest = { finish: res, timer, quality };
      this.requests.set(key, pending);
    });
    const musicInfo: ScriptMusicInfo = this.buildMusicInfo(info, quality);
    const reqInfo: RequestInfoPayload = { type: quality, musicInfo };
    const reqData: RequestDataPayload = { source, action: 'musicUrl', info: reqInfo };
    const reqPayload: RequestEventPayload = { requestKey: key, data: reqData };
    try {
      const sent: boolean = await this.dispatch('request', reqPayload);
      if (!sent) {
        // runJavaScript 抛错 = 沙箱页面已经不可用，立刻按环境故障返回，
        // 由 tryResolve 重建沙箱重试，而不是干等 20s 看门狗超时。
        const p0: PendingRequest | undefined = this.requests.get(key);
        if (p0 !== undefined) {
          this.requests.delete(key);
          clearTimeout(p0.timer);
          p0.finish({ ok: false, url: '', quality, error: ENV_ERROR });
        }
      }
    } catch (e) {
      const p: PendingRequest | undefined = this.requests.get(key);
      if (p !== undefined) {
        this.requests.delete(key);
        clearTimeout(p.timer);
        p.finish({ ok: false, url: '', quality, error: ENV_ERROR });
      }
    }
    return await gate;
  }

  /** 构造脚本侧 musicInfo：顶层补齐 songmid/hash 等字段（真实脚本只读顶层），meta 保留完整结构 */
  /** 构造脚本侧 musicInfo：顶层补齐 songmid/hash 等字段（真实脚本只读顶层），meta 保留完整结构 */
  private buildMusicInfo(info: MusicInfo, quality: Quality): ScriptMusicInfo {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    const hash: string = meta.hash ?? '';
    const strMediaMid: string = meta.strMediaMid ?? '';
    const copyrightId: string = meta.copyrightId ?? '';
    const picUrl: string = meta.picUrl ?? '';
    const qhash: string | null | undefined = meta._qualitys.get(quality);
    let songId: string = meta.songId;
    if (qhash !== undefined && qhash !== null && qhash.length > 0) {
      songId = qhash;
    } else if (info.source === 'kg' && hash.length > 0) {
      songId = hash;
    }
    // _qualitys 是「音质 → {hash,size}」结构，脚本常读 _qualitys[type].hash 取换链标识。
    // 搜索结果通常不携带各音质真哈希，缺失处用主标识(songmid)兜底，保证非空、可被脚本拿去换链。
    const qmap: Record<string, QualityHash> = {};
    meta._qualitys.forEach((v: string | null, k: string): void => {
      const h: string = (v !== null && v.length > 0) ? v : songId;
      qmap[k] = { hash: h, size: null };
    });
    if (meta.qualitys !== undefined) {
      for (const q of meta.qualitys) {
        const t: string = q.type;
        if (qmap[t] === undefined) {
          qmap[t] = { hash: songId, size: null };
        }
      }
    }
    const m: ScriptMusicInfo = {
      id: info.id,
      name: info.name,
      singer: info.singer,
      source: info.source,
      interval: info.interval ?? '',
      songmid: songId,
      hash,
      strMediaMid,
      copyrightId,
      qualitys: meta.qualitys,
      _qualitys: qmap,
      meta: {
        songId: meta.songId,
        albumName: meta.albumName,
        picUrl,
        hash,
        strMediaMid,
        copyrightId,
        qualitys: meta.qualitys,
        _qualitys: qmap,
      },
    };
    return m;
  }

  /** 轮询等待隐藏 Web 组件上屏（attach），超时返回 */
  private async waitForController(ms: number): Promise<void> {
    const step: number = 120;
    let waited: number = 0;
    while (this.controller === null && waited < ms) {
      await this.delay(step);
      waited += step;
    }
  }

  /**
   * 沙箱环境是否还活着（页面在 + 脚本已 inited + request 处理器已注册）。
   * 探针超时不再一次判死：切前后台 / 刚执行完脚本时渲染进程只是"忙"，
   * 直接重建整个 Web 页面反而会把播放卡十几秒。这里给两次机会。
   */
  private async envAlive(): Promise<boolean> {
    for (let i = 0; i < 2; i++) {
      const r: string = await this.probeEnv();
      if (r.length > 0) {
        return r.indexOf('11') >= 0;
      }
      if (i === 0) {
        await this.delay(250);
      }
    }
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'probe env timeout twice, treat as lost');
    return false;
  }

  /** 单次探针（1.8s 超时，超时返回空串） */
  private async probeEnv(): Promise<string> {
    const c: webview.WebviewController | null = this.controller;
    if (c === null) {
      return '';
    }
    const probe: Promise<string> = c.runJavaScript(PROBE_JS)
      .then((v: string): string => v)
      .catch((): string => '');
    return await Promise.race([
      probe,
      this.delay(1800).then((): string => ''),
    ]);
  }

  /** 探测声明式代理是否注入成功；失败时快速给出明确原因，避免静默等 10s 初始化超时 */
  private async proxyAvailable(): Promise<boolean> {
    if (this.controller === null) {
      return false;
    }
    try {
      // 渲染进程冻结时 runJavaScript 可能永不 settle，必须和 probeEnv 一样加超时，
      // 否则这里会永久挂起并占住串行锁。超时按「探测失败」处理，返回空串。
      const probe: Promise<string> = this.controller.runJavaScript('typeof window.__lxHost')
        .then((v: string): string => v)
        .catch((): string => '');
      const r: string = await Promise.race([
        probe,
        this.delay(1800).then((): string => ''),
      ]);
      return r.indexOf('object') >= 0;
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'probe __lxHost failed: %{public}s', this.errText(e));
      return false;
    }
  }

  private async runJs(script: string): Promise<boolean> {
    const c: webview.WebviewController | null = this.controller;
    if (c === null) {
      return false;
    }
    try {
      const run: Promise<string> = c.runJavaScript(script)
        .then((): string => 'ok')
        .catch((e: Object): string => this.errText(e));
      const r: string = await Promise.race([
        run,
        this.delay(JS_TIMEOUT_MS).then((): string => 'timeout'),
      ]);
      if (r === 'ok') {
        return true;
      }
      // 渲染进程冻结 / 页面已销毁：统一按「环境无响应」上报，让上层去重建沙箱
      this.lastError = r === 'timeout' ? ENV_ERROR : r;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'runJavaScript failed: %{public}s', this.lastError);
      return false;
    } catch (e) {
      this.lastError = this.errText(e);
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'runJavaScript failed: %{public}s', this.lastError);
      return false;
    }
  }

  private async dispatch(action: string, data: Object): Promise<boolean> {
    const code: string = '__lxDispatch(' + JSON.stringify(action) + ',' + JSON.stringify(data) + ')';
    return await this.runJs(code);
  }

  private resetRuntime(): void {
    this.requests.forEach((p: PendingRequest): void => {
      clearTimeout(p.timer);
      p.finish({ ok: false, url: '', quality: p.quality, error: '音源脚本已切换' });
    });
    this.requests.clear();
    if (this.initTimer !== 0) {
      clearTimeout(this.initTimer);
      this.initTimer = 0;
    }
    const fn: ((ok: boolean) => void) | null = this.initResolve;
    this.initResolve = null;
    if (fn !== null) {
      fn(false);
    }
    this.sources.clear();
    this.inited = false;
    this.updateAlertShown = false;
    this.lastError = '';
  }

  /**
   * 串行锁（一个 WebView 同时只能跑一个脚本）。
   * 与旧实现的区别：等待有上限。取链前等不到锁就直接放弃、走 HTTP 兜底，
   * 避免「有人正在初始化」把后续每一首的取链都排队堵死（表现为播放一直转圈）。
   */
  private acquire(waitMs: number): Promise<boolean> {
    if (!this.lockBusy) {
      this.lockBusy = true;
      return Promise.resolve(true);
    }
    return new Promise<boolean>((res: (ok: boolean) => void): void => {
      let settled: boolean = false;
      const wake: () => void = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        res(true);
      };
      this.lockWaiters.push(wake);
      setTimeout((): void => {
        if (settled) {
          return;
        }
        settled = true;
        const i: number = this.lockWaiters.indexOf(wake);
        if (i >= 0) {
          this.lockWaiters.splice(i, 1);
        }
        res(false);
      }, waitMs);
    });
  }

  private release(): void {
    const next: (() => void) | undefined = this.lockWaiters.shift();
    if (next !== undefined) {
      next();
      return;
    }
    this.lockBusy = false;
  }

  private async withLock(waitMs: number,
    fn: () => Promise<ScriptUrlResult | null>): Promise<ScriptUrlResult | null> {
    if (!await this.acquire(waitMs)) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'custom source busy, skip and fallback');
      return null;
    }
    try {
      return await fn();
    } finally {
      this.release();
    }
  }

  /**
   * 初始化失败冷却：首次只歇 5s（用户要求，失败后很快就能再试），
   * 连续失败逐级拉长到 20s 封顶（5s → 10s → 15s → 20s），避免一直重试白耗电。
   */
  private inCooldown(id: string): boolean {
    if (this.failId !== id || this.failAt === 0) {
      return false;
    }
    return Date.now() - this.failAt < this.cooldownMs();
  }

  private cooldownMs(): number {
    const steps: number[] = [5000, 10000, 15000, 20000];
    const i: number = this.failCount > 0 ? this.failCount - 1 : 0;
    return steps[i < steps.length ? i : steps.length - 1];
  }

  private markFail(id: string): void {
    this.failId = id;
    this.failAt = Date.now();
    this.failCount++;
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'custom source cooldown %{public}d ms after failure #%{public}d',
      this.cooldownMs(), this.failCount);
  }

  private clearFail(): void {
    this.failId = '';
    this.failAt = 0;
    this.failCount = 0;
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((res: () => void): void => {
      setTimeout((): void => { res(); }, ms);
    });
  }

  private errText(e: Object): string {
    const err = e as Error;
    return err.message !== undefined ? err.message : 'unknown error';
  }
}
