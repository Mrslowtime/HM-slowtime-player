import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { setAppContext } from '../common/AppContext';
import { setWindowSizePx } from '../config/ScreenMetrics';
import { setTopInsetPx } from '../core/Popup';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { PlayerManager } from '../player/PlayerManager';
import { SessionManager } from '../player/SessionManager';
import { PlayController } from '../player/PlayController';
import { SettingStore } from '../store/SettingStore';
import { AppState } from '../store/AppState';
import { CrashGuard } from '../core/CrashGuard';
import { CustomScriptRunner } from '../core/net/CustomScriptRunner';
import { MusicUrlResolver } from '../core/net/MusicUrlResolver';
import { CacheStore } from '../core/CacheStore';
import { consumeChangeLogSecret } from '../core/ChangeLogSecret';
import { initBirthdaySecret } from '../core/BirthdaySecret';
import { applyDownloadFeature } from '../config/AppConstants';
import { stateEvent, StateEvents } from '../store/EventBus';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    setAppContext(this.context);
    // 崩溃兜底：越早注册越好，保证 UIAbility 之后的异常也能被记录
    CrashGuard.install(this.context);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'EntryAbility onCreate');
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    // 下载功能总闸必须在加载首页之前定好：ACTIVE_NAV_MENUS、ListManager 默认列表、
    // 各处下载按钮都在首帧读它。设置里切换开关后「重启应用」即按新值重建。
    const settings: SettingStore = SettingStore.getInstance();
    await settings.init();
    // 下载功能默认关闭（2026-11-21 用户要求）：新装/无历史设置的设备走 false，
    // 需在「设置 → 下载设置」打开总闸并重启才显示下载入口。老用户已存 true 的不受影响。
    applyDownloadFeature(settings.getBoolean('download.enable', false));
    // 隐藏入口：密点达标后 1 分钟内重启才解锁完整更新日志；读完即消费计数
    await consumeChangeLogSecret();
    // 生日彩蛋的隐藏关闭开关；纯本地读取，不联网
    await initBirthdaySecret();
    windowStage.loadContent('pages/Index', (err): void => {
      if (err.code) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        CrashGuard.record('界面加载失败', JSON.stringify(err));
        return;
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'loadContent succeeded');
    });
    // 平板竖屏先按物理屏尺寸放开窗口上限再请求铺满，否则兼容模式会把窗口
    // 缩成手机大小、两侧留黑边；尺寸变化同步给断点服务供列数/弹窗使用。
    await this.applyWindowSize(windowStage);
    this.applyOrientation(windowStage);
  }

  /**
   * 让主窗口占满物理屏：先放开尺寸上限（平板上系统兼容模式的根因），
   * 再 resize 到整屏。手机端这些值就等于原尺寸，没有副作用。
   * 全部包在 try 里：某些设备/模式不允许 resize，失败就保持系统默认窗口。
   */
  private async applyWindowSize(windowStage: window.WindowStage): Promise<void> {
    try {
      const win = await windowStage.getMainWindow();
      try {
        const d = display.getDefaultDisplaySync();
        const limits: window.WindowLimits = {
          minWidth: 320, minHeight: 480, maxWidth: d.width, maxHeight: d.height,
        };
        await win.setWindowLimits(limits);
        try {
          await win.moveWindowTo(0, 0);
        } catch (e) {
          // 全屏窗口本来就固定在 (0,0)，忽略
        }
        await win.resize(d.width, d.height);
        setWindowSizePx(d.width, d.height);
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'resize to display failed');
      }
      try {
        win.on('windowSizeChange', (size: window.Size): void => {
          setWindowSizePx(size.width, size.height);
        });
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'windowSizeChange register failed');
      }
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'applyWindowSize failed');
    }
  }

  /**
   * 方向策略：默认锁定竖屏（不随手机旋转自动横屏）；
   * 开启「强制横屏」后用 AUTO_ROTATION_LANDSCAPE —— 跟随传感器只在水平方向旋转
   *（左横 / 右横都认），但手机竖起或倒立时不会切成竖屏，始终保持横屏。
   */
  private async applyOrientation(windowStage: window.WindowStage): Promise<void> {
    try {
      const win = await windowStage.getMainWindow();
      // 记录状态栏高度（px）：浮窗定位时用它把 window 坐标换算成页面坐标
      try {
        const avoid = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        setTopInsetPx(avoid.topRect.height);
      } catch (e) {
        // 取不到时保持 0，浮窗仍会被夹紧在屏幕内
      }
      const settings = SettingStore.getInstance();
      await settings.init();
      const forceLandscape = settings.getBoolean('common.forceLandscape', false);
      // 横屏开关：AUTO_ROTATION_LANDSCAPE 随左右横屏翻转，竖起/倒立不动
      const target = forceLandscape
        ? window.Orientation.AUTO_ROTATION_LANDSCAPE : window.Orientation.PORTRAIT;
      await win.setPreferredOrientation(target);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'orientation applied: %{public}s', forceLandscape ? 'landscape' : 'portrait');
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'applyOrientation failed: %{public}s', (e as Error).message ?? '');
    }
  }

  /** 系统配置变化：开启「跟随系统明暗」时，按新的色彩模式切换 lightId / darkId 主题 */
  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onConfigurationUpdate colorMode: %{public}d', newConfig.colorMode);
    const settings = SettingStore.getInstance();
    if (!settings.getBoolean('common.isAutoTheme', false)) {
      return;
    }
    AppState.getInstance().refreshTheme();
  }

  onWindowStageDestroy(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    CrashGuard.markForeground();
    AppState.getInstance().appInBackground = false;
    // 回前台恢复自定义源：心跳重新启动，环境若在后台被回收会立刻补一次初始化，
    // 这样用户不用手动去设置里重新勾选音源、也不用重启应用。
    CustomScriptRunner.getInstance().onForeground();
    // 回前台补一次缓存水位检查（后台不打扰用户，这里才有机会问「是否调高上限」）
    CacheStore.getInstance().enforce();
    // 用户可能在系统「文件」里把歌挪进了公共目录（或挪了文件夹）：回前台让本地音乐
    // 静默重扫一次，不需要手动点刷新。事件只触发本地文件扫描，零网络请求。
    stateEvent().emit(StateEvents.LOCAL_FILES_CHANGED);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onForeground');
  }

  onBackground(): void {
    CrashGuard.markBackground();
    AppState.getInstance().appInBackground = true;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onBackground');
    // 切后台立刻落盘「最后播放的歌曲 + 列表 + 进度」：
    // 鸿蒙侧滑杀进程不一定回调 onDestroy，只靠退出时保存会丢记录。
    PlayController.getInstance().savePlayInfo(true).catch((): void => {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'savePlayInfo on background failed');
    });
    // 缓存索引（访问时间 / 关联封面歌词）在切后台时强制落盘，避免进程被杀后丢失
    CacheStore.getInstance().flushNow();
    // 播放链接缓存同样强制落盘：重启后已取过链的歌直接命中，不再重新请求音源
    MusicUrlResolver.getInstance().flushNow();
  }

  async onDestroy(): Promise<void> {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'onDestroy: release player & session');
    CrashGuard.markCleanExit();
    // 统一走 PlayController.destroy()：它内部先读进度再释放 session/player，
    // 并清理全部定时器（含 failSkipTimer）。单独分步调用曾导致异常中断释放链、
    // 且 PlayController 的定时器（秒级 snapshot / 失败补播）在退出后继续跑。
    // 每步独立 try/catch：任一步失败都不能阻断后续资源释放。
    try {
      await PlayController.getInstance().destroy();
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'PlayController destroy failed, force release');
      try {
        await SessionManager.getInstance().destroy();
      } catch (e2) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'session destroy failed on fallback');
      }
      try {
        await PlayerManager.getInstance().release();
      } catch (e3) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'player release failed on fallback');
      }
    }
  }
}
