/**
 * 设置页 —— 按设置页布局（10 个分组、76 项设置）。
 * 用 DefaultSetting.ets 的数据表驱动生成控件，避免手写 76 个，
 * 也保证以后协议升级重跑 gen_assets.py 就能自动同步。
 */
import { SettingValue } from '../../config/DefaultSetting';
import { window } from '@kit.ArkUI';
import { SettingStore } from '../../store/SettingStore';
import { AppState } from '../../store/AppState';
import { ThemeInfo, THEMES, buildPalette, ThemePalette } from '../../theme/Themes';
import { MUSIC_TOGGLE_MODE_LIST, QUALITY_LIST, isDownloadEnabled } from '../../config/AppConstants';
import { ToolPanel } from './ToolPanel';
import { I18n } from '../../core/I18n';
import { PlayController } from '../../player/PlayController';
import { stateEvent, StateEvents } from '../../store/EventBus';
import { VersionLogPanel } from '../../components/VersionLogPanel';
import { CustomSourcePanel } from '../../components/CustomSourcePanel';
import { CachePanel } from '../../components/CachePanel';
import { CACHE_LIMIT_STEPS, AUDIO_CACHE_ENABLED, CacheStore } from '../../core/CacheStore';
import {
  computePopupPos, setPopupContainer, setPopupAnchor, popupMaxHeightVp, popupMaxWidthVp, popupWidthForTexts, PopupPoint,
} from '../../core/Popup';
import { recordAboutTitleTap } from '../../core/ChangeLogSecret';
import { recordChangelogTap } from '../../core/BirthdaySecret';
import { sanitizeSubDir } from '../../core/DownloadManager';

interface SettingGroup { id: string; name: string; prefix: string }

/** 设置项中文标题：未命中的项仍回退显示原始 key，保证不丢项 */
interface SettingLabel { key: string; label: string }

const SETTING_LABELS: SettingLabel[] = [
  // 基本
  { key: 'common.langId', label: '界面语言' },
  { key: 'common.sourceNameType', label: '歌曲来源显示（简称 / 全名）' },
  { key: 'common.isAutoTheme', label: '跟随系统明暗' },
  { key: 'common.allowProgressBarSeek', label: '允许拖动底栏进度条' },
  { key: 'common.showExitBtn', label: '在工具面板显示「退出应用」' },
  { key: 'common.forceLandscape', label: '强制横屏' },
  // 播放
  { key: 'player.startupAutoPlay', label: '启动后自动播放' },
  { key: 'player.startupPushPlayDetailScreen', label: '启动后打开播放详情页' },
  { key: 'player.togglePlayMethod', label: '切歌方式' },
  { key: 'player.playQuality', label: '默认音质' },
  { key: 'player.isSavePlayTime', label: '记住上次播放进度' },
  { key: 'player.volume', label: '播放音量（封面手势调音会同步保存）' },
  { key: 'player.playbackRate', label: '播放速度' },
  { key: 'player.cacheSize', label: '在线播放缓存上限（GB）' },
  { key: 'player.timeoutExit', label: '定时停止（分钟）' },
  { key: 'player.timeoutExitPlayed', label: '播完当前歌曲后停止' },
  { key: 'player.isAutoCleanPlayedList', label: '自动清理已播放列表' },
  { key: 'player.isHandleAudioFocus', label: '抢占音频焦点' },
  // 以下安卓专属项在鸿蒙端无处接线，不再展示（声明保留，兼容安卓设置文件的导入）：
  //   player.isEnableAudioOffload        低功耗播放由系统统一调度，AVPlayer 无 offload 开关
  //   player.isShowBluetoothLyric        蓝牙媒体信息走 AVRCP，系统不允许三方塞歌词
  //   player.isShowBluetoothFullLyric    同上
  //   player.lockScreenTransparency      三方应用无法自定义系统锁屏
  { key: 'player.isShowLyricTranslation', label: '显示歌词翻译' },
  { key: 'player.isShowLyricRoma', label: '显示歌词音译' },
  { key: 'player.isShowNotificationImage', label: '通知栏显示封面' },
  { key: 'player.isS2t', label: '歌词简体转繁体' },
  { key: 'player.lockScreenBlur', label: '锁屏封面模糊' },
  // 播放页
  { key: 'playDetail.style.align', label: '歌词对齐方式' },
  { key: 'playDetail.vertical.style.lrcFontSize', label: '竖屏歌词字号' },
  { key: 'playDetail.horizontal.style.lrcFontSize', label: '横屏歌词字号' },
  { key: 'playDetail.isShowLyricProgressSetting', label: '显示歌词进度设置' },
  // 歌词：锁屏逐行歌词 + 桌面悬浮歌词（系统媒体卡片 / 桌面歌词组件）
  { key: 'desktopLyric.enable', label: '歌词同步到状态栏 / 锁屏' },
  { key: 'desktopLyric.floatEnable', label: '桌面悬浮歌词（需 HarmonyOS 6.1+）' },
  { key: 'desktopLyric.isLock', label: '锁定桌面歌词窗（禁止拖动）' },
  // 搜索
  { key: 'search.isShowHotSearch', label: '显示热搜榜' },
  { key: 'search.isShowHistorySearch', label: '显示搜索历史' },
  // 列表
  { key: 'list.isClickPlayList', label: '点按即播（点击列表项直接播放该曲）' },
  { key: 'list.isShowSource', label: '显示歌曲来源' },
  { key: 'list.isShowAlbumName', label: '显示专辑名' },
  { key: 'list.isShowInterval', label: '显示时长' },
  { key: 'list.isSaveScrollLocation', label: '记住列表滚动位置' },
  { key: 'list.addMusicLocationType', label: '新歌添加位置' },
  // 下载
  { key: 'download.enable', label: '启用下载功能（切换后需重启应用）' },
  { key: 'download.storage', label: '下载保存位置（手机「下载」目录 / 应用内）' },
  { key: 'download.fileName', label: '下载文件名格式（右侧为效果预览）' },
  { key: 'download.savePath', label: '下载保存子目录（仅对新的下载生效）' },
  // 缓存
  { key: 'cache.limitMb', label: '缓存上限（500 MiB 一档，最高 6 GiB）' },
  { key: 'cache.autoClean', label: '占用达 99% 时自动清理' },
  { key: 'cache.coverLimit', label: '封面缓存上限（超出按最久未用淘汰）' },
  // 主题
  { key: 'theme.id', label: '主题（手动选择）' },
  { key: 'theme.lightId', label: '浅色模式主题（需开启「跟随系统明暗」）' },
  { key: 'theme.darkId', label: '深色模式主题（需开启「跟随系统明暗」）' },
  { key: 'theme.hideBgDark', label: '深色下隐藏背景图' },
  { key: 'theme.dynamicBg', label: '动态背景（封面模糊铺底）' },
  { key: 'theme.fontShadow', label: '歌词字体阴影' },
];

/** 分组前缀 → 多语言分组名（按 rawfile/lang 的 setting_<group>_<snake> 命名） */
const GROUP_I18N: Record<string, string> = {
  'common.': 'basic',
  'player.': 'player',
  'playDetail.': 'play_detail',
  'desktopLyric.': 'desktop_lyric',
  'search.': 'search',
  'list.': 'list',
  'download.': 'download',
  'sync.': 'sync',
  'cache.': 'cache',
  'theme.': 'theme',
}

/** camelCase → snake_case（isShowHotSearch → is_show_hot_search；style.align → style_align） */
function camelToSnake(s: string): string {
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (c === '.' || c === '-') {
      out += '_';
      continue;
    }
    const lower: string = c.toLowerCase();
    if (c !== lower && i > 0) {
      out += '_';
    }
    out += lower;
  }
  return out;
}

/** 设置 key → 多语言 key：common.showExitBtn → setting_basic_show_exit_btn */
function settingI18nKey(key: string): string {
  const dot: number = key.indexOf('.');
  if (dot < 0) {
    return key;
  }
  const prefix: string = key.substring(0, dot + 1);
  const suffix: string = key.substring(dot + 1);
  const group: string = GROUP_I18N[prefix] ?? prefix.substring(0, prefix.length - 1);
  let snake: string = camelToSnake(suffix);
  if (snake.startsWith('is_')) {
    snake = snake.substring(3);
  }
  // 语言项：配置键是 langId，语言表里对应词条是 setting_basic_lang（无 _id 后缀）
  if (key === 'common.langId') {
    return 'setting_basic_lang';
  }
  return 'setting_' + group + '_' + snake;
}

/**
 * 设置项标题：三级回退
 *  1) 多语言资源（170 条 setting_* 已覆盖大部分项，自动跟随语言）
 *  2) 手工中文映射（补齐资源里缺失的项）
 *  3) 原始 key（保证任何情况下不丢项、可排查）
 */
function settingTitle(key: string): string {
  const ik: string = settingI18nKey(key);
  const s: string = I18n().t(ik);
  if (s !== ik) {
    return s;
  }
  for (let i = 0; i < SETTING_LABELS.length; i++) {
    if (SETTING_LABELS[i].key === key) {
      return SETTING_LABELS[i].label;
    }
  }
  return key;
}

const GROUPS: SettingGroup[] = [
  { id: 'basic', name: '基本设置', prefix: 'common.' },
  { id: 'player', name: '播放设置', prefix: 'player.' },
  { id: 'playDetail', name: '播放页', prefix: 'playDetail.' },
  // 鸿蒙不允许三方应用在状态栏自绘，这里对应「系统媒体卡片 / 控制中心 / 锁屏」的单行歌词
  { id: 'desktopLyric', name: '状态栏歌词', prefix: 'desktopLyric.' },
  { id: 'search', name: '搜索设置', prefix: 'search.' },
  { id: 'list', name: '列表设置', prefix: 'list.' },
  { id: 'download', name: '下载设置', prefix: 'download.' },
  // 缓存设置：2026-11-17 晚上真正接上（音频智能缓存 + 歌词磁盘缓存 + 封面缓存统一管理）
  { id: 'cache', name: '缓存设置', prefix: 'cache.' },
  { id: 'theme', name: '主题设置', prefix: 'theme.' },
  // 音源服务（HTTP 端点兜底）不再单独占一组：2026-11-17 起收进「自定义源」分组里的
  // 「音源服务」按钮弹窗（components/SourceServiceDialog），两个音源相关配置集中在一处。
  // 自定义源：导入本协议格式 .js 脚本，播放时优先使用（按桌面/移动版自定义源管理）
  { id: 'customSource', name: '自定义源', prefix: '__custom_src__' },
  // 以下四项原先合并在「工具」分组里，现各自独立成组（2026-11-17 用户要求）
  { id: 'dislike', name: '不喜欢列表', prefix: '__dislike__' },
  { id: 'backup', name: '数据备份与恢复', prefix: '__backup__' },
  { id: 'log', name: '运行日志', prefix: '__log__' },
  // 更新日志：当前版本展开、历史版本收进弹窗
  { id: 'changelog', name: '更新日志', prefix: '__changelog__' },
  { id: 'about', name: '关于', prefix: '__about__' },
];

/**
 * 缓存设置组始终显示：整曲音频缓存 / 歌词磁盘缓存 / 封面缓存统一管理。
 * 「整曲缓存上限 / 超限自动清理」只对整曲音频缓存有意义，因此在
 * AUDIO_CACHE_ENABLED 关闭时隐藏，避免「选了不生效」；启用后自动显示。
 */
const CACHE_SETTINGS_VISIBLE: boolean = true;

/** 只在整曲音频缓存启用时才有意义的设置项 */
const AUDIO_CACHE_ONLY_KEYS: string[] = ['cache.limitMb', 'cache.autoClean'];

/**
 * 当前实际显示的设置分组。
 * 「下载设置」组始终显示：里面必须留着「启用下载功能」这个总闸，
 * 否则一旦关闭就再也找不到地方重新打开；其余下载项由 entriesFor 按开关过滤。
 */
const ACTIVE_GROUPS: SettingGroup[] = GROUPS.filter((g: SettingGroup): boolean => {
  if (g.id === 'cache') {
    return CACHE_SETTINGS_VISIBLE;
  }
  return true;
});

/** 下载功能关闭时，下载分组只保留这一个总闸（其余设置项与所有下载入口一起隐藏） */
const DOWNLOAD_MASTER_KEY: string = 'download.enable';

/** 语言选项（auto 跟随系统） */
const LANG_OPTIONS: string[] = ['auto', 'zh-cn', 'zh-tw', 'en-us'];

/** 定时停止分钟选项，0 = 关闭 */
const TIMER_MINUTE_OPTIONS: string[] = ['0', '15', '30', '45', '60', '75', '90', '105', '120'];

/** 需要改成下拉选择的枚举型 key */
const SELECT_KEYS: Record<string, string[]> = {
  'common.sourceNameType': ['alias', 'real'],
  'common.shareType': ['system', 'clipboard'],
  'common.drawerLayoutPosition': ['left', 'right'],
  'common.langId': LANG_OPTIONS,
  'player.togglePlayMethod': MUSIC_TOGGLE_MODE_LIST.slice(),
  'player.playQuality': QUALITY_LIST.slice(),
  'player.timeoutExit': TIMER_MINUTE_OPTIONS,
  'playDetail.style.align': ['left', 'center', 'right'],
  'cache.limitMb': CACHE_LIMIT_STEPS.slice(),
  'cache.coverLimit': ['200', '400', '600', '1000', '1500', '2000', '3000', '4000'],
  'player.cacheSize': ['2048', '100', '50', '20', '10'],
  'list.addMusicLocationType': ['top', 'bottom'],
  'download.fileName': ['{singer} - {name}', '{name} - {singer}', '{name}', '{name}_{singer}_{quality}'],
  'download.storage': ['public', 'sandbox'],
  'download.savePath': ['HM慢时光', '', 'music', 'lossless', 'music/lossless', '__custom__'],
  'theme.id': THEMES.map((t: ThemeInfo): string => t.id),
  'theme.lightId': THEMES.map((t: ThemeInfo): string => t.id),
  'theme.darkId': THEMES.map((t: ThemeInfo): string => t.id),
};

/**
 * 滑块型 key 的取值范围。
 * `smooth: true` 表示连续平滑拖动（只有音量、锁屏封面模糊两项），其余一律按 step 一档一档走。
 */
interface SliderRange { min: number; max: number; step: number; smooth?: boolean }

const SLIDER_KEYS: Record<string, SliderRange> = {
  // 连续平滑：音量按 0~100% 无级调节，模糊强度也允许细腻过渡
  'player.volume': { min: 0, max: 1, step: 0, smooth: true },
  'player.lockScreenBlur': { min: 0, max: 100, step: 0, smooth: true },
  // 分级：倍速 0.5 / 0.75 / 1 / 1.25 / 1.5 / 1.75 / 2 七档
  'player.playbackRate': { min: 0.5, max: 2, step: 0.25 },
  // 分级：歌词字号 120% ~ 320%，每级 20%，共 11 档
  'playDetail.vertical.style.lrcFontSize': { min: 120, max: 320, step: 20 },
  'playDetail.horizontal.style.lrcFontSize': { min: 120, max: 320, step: 20 },
  // 以下键已隐藏（见 HIDDEN_SETTING_KEYS），保留范围以便恢复展示
  'player.lockScreenTransparency': { min: 0, max: 100, step: 10 },
  'desktopLyric.width': { min: 50, max: 100, step: 10 },
  'desktopLyric.maxLineNum': { min: 1, max: 10, step: 1 },
  'desktopLyric.style.fontSize': { min: 100, max: 300, step: 20 },
  'desktopLyric.style.opacity': { min: 0, max: 100, step: 10 },
};

/** 滑块圆点直径（vp）与可拖动命中区（略大于圆点，方便手指按准） */
const SLIDER_BLOCK_VP: number = 16;
const SLIDER_HIT_VP: number = 34;
/** 滑动条容器高度（与系统 Slider 默认高度一致，保证圆点与轨道垂直居中） */
const SLIDER_ROW_VP: number = 40;

/**
 * 下载文件名模板 → 预览文案。
 * 用固定示例（晴天 / 周杰伦 / 320k）渲染，让用户一眼看出规则效果。
 */
function fileNamePreview(tpl: string): string {
  const name: string = '晴天';
  const singer: string = '周杰伦';
  const quality: string = '320k';
  let t: string = tpl.trim();
  if (t.length === 0) {
    return name + ' - ' + singer;
  }
  // 兼容旧版中文下拉值
  if (t === '歌名 - 歌手') {
    t = '{name} - {singer}';
  } else if (t === '歌手 - 歌名') {
    t = '{singer} - {name}';
  } else if (t === '歌名') {
    t = '{name}';
  }
  if (t.indexOf('{') < 0) {
    return t;
  }
  return t.split('{name}').join(name)
    .split('{singer}').join(singer)
    .split('{quality}').join(quality);
}

/**
 * 不展示的设置项。
 *
 * 「桌面歌词」由系统歌词组件（API 23+）承载，歌词内容取自 AVMetadata.lyric，
 * 样式由系统统一渲染、三方不可自定义，因此协议里的自绘参数
 * （字体、颜色、位置、行数、切换动画）在本版不生效。
 * 这些键仍保留在数据层：与安卓设置项一一对应，备份/恢复可跨版本兼容，
 * 但不进入 UI，避免用户改了没反应。
 */
const HIDDEN_SETTING_KEYS: string[] = [
  // 桌面歌词自绘参数：系统组件统一渲染，仅保留 enable / floatEnable / isLock
  'desktopLyric.width',
  'desktopLyric.maxLineNum',
  'desktopLyric.isSingleLine',
  'desktopLyric.showToggleAnima',
  'desktopLyric.position.x',
  'desktopLyric.position.y',
  'desktopLyric.textPosition.x',
  'desktopLyric.textPosition.y',
  'desktopLyric.style.fontSize',
  'desktopLyric.style.opacity',
  'desktopLyric.style.lyricUnplayColor',
  'desktopLyric.style.lyricPlayedColor',
  'desktopLyric.style.lyricShadowColor',
  // 鸿蒙端无对应形态：系统文件选择器 / 抽屉位置 / 返回按钮 / 首页滚动 / 状态栏占位
  'common.useSystemFileSelector',
  'common.drawerLayoutPosition',
  'common.showBackBtn',
  'common.homePageScroll',
  'common.alwaysKeepStatusbarHeight',
  // 播放条常驻（自动隐藏会让播控消失），故不提供该开关
  'common.autoHidePlayBar',
  // 「退出应用」入口已从工具分组移除（抽屉底部保留），该开关不再对应任何界面
  'common.showExitBtn',
  // 以下四项待对应功能上线后再恢复展示：分享 / 隐私协议页 / 音源切换入口 / 源配置更新
  'common.shareType',
  'common.isAgreePact',
  'common.apiSource',
  'common.autoUpdateSource',
  // 账号与云同步暂缓（上架做出量后再做），整组无功能先不展示
  'sync.enable',
  // 鸿蒙三方应用不可控 / 无接口：音频卸载、蓝牙歌词（需设备协议）、启动直进播放页（观感突兀）、
  // 锁屏卡片透明度（系统媒体卡片无透明度接口，无法生效）
  'player.isEnableAudioOffload',
  'player.isShowBluetoothLyric',
  'player.isShowBluetoothFullLyric',
  'player.startupPushPlayDetailScreen',
  'player.lockScreenTransparency',
  // 单曲缓存上限（MB）不再单独暴露：整曲缓存统一由「缓存上限」与 99%/49% 水位管理
  'player.cacheSize',
  // 旧键：历史上是「上限 GB」滑块，现改用 cache.limitMb（500MiB 一档），只做备份兼容
  'cache.maxSize',
  // 内部标记：自动旋转由「播放页」内的按钮控制，设置页不重复暴露（否则显示原始 key）
  'player.autoRotate',
  // 内部标记：状态栏歌词「首次自动开启」的一次性迁移标记，无对应 UI
  'lyricBar.defaultOn',
];

@Component
export struct SettingView {
  @State private version: number = 0;
  @State private langTick: number = 0;
  /** 滑动条状态：正在拖的 key、拖动起点值、当前拖动值、轨道可用宽度（vp，各行等宽） */
  @State private dragKey: string = '';
  @State private dragStartVal: number = 0;
  @State private dragVal: number = 0;
  @State private trackW: number = 0;
  /** 下拉选择：当前展开的设置项 key（空串 = 关闭） */
  @State private pickerKey: string = '';
  /** 自定义路径输入：当前设置的 key（空串 = 关闭）与文本框内容 */
  @State private customKey: string = '';
  @State private customText: string = '';
  /** 下拉浮窗在页面内的落点（由 core/Popup 按点击位置换算） */
  @State private pickerPos: PopupPoint = { x: 0, y: 0 };
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  /** 当前是否为激活标签：设置页无头部操作，激活时清空全局头部操作区 */
  @Prop @Watch('syncHeader') active: boolean = false;
  onThemeChange: (id: string) => void = () => {};

  private store: SettingStore = SettingStore.getInstance();
  private state: AppState = AppState.getInstance();
  /** 语言变化回调做成类字段，便于 aboutToDisappear 精确反订阅，避免重复进出累积监听 */
  private langChangedHandler: () => void = (): void => {
    this.langTick = this.langTick + 1;
  };

  aboutToAppear(): void {
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.langChangedHandler);
    this.syncHeader();
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.langChangedHandler);
  }

  /** 设置页没有需要放到全局头部的操作 */
  private syncHeader(): void {
    if (!this.active) {
      return;
    }
    this.state.setHeaderActions([]);
  }

  /** 分组中文/翻译名（读取 langTick 以便语言切换时刷新） */
  private groupName(g: SettingGroup): string {
    const _tick = this.langTick;
    // 新增分组没有历史 i18n 词条，直接用中文名，避免显示成 key
    if (g.id === 'changelog' || g.id === 'customSource') {
      return g.name;
    }
    return I18n().t('g_' + g.id) + (_tick >= 0 ? '' : '');
  }

  /** 当前主题派生色板（按需计算，跟随 @Prop theme 变化） */
  private pal(): ThemePalette {
    return buildPalette(this.theme);
  }

  private tx(key: string): string {
    return I18n().t(key) + (this.langTick >= 0 ? '' : '');
  }

  /** 取某分组前缀下的所有可见设置项（过滤隐藏项并按 key 排序） */
  private entriesFor(prefix: string): string[] {
    const all = this.store.exportAll();
    const keys: string[] = [];
    all.forEach((_v: SettingValue, k: string): void => {
      if (!k.startsWith(prefix) || HIDDEN_SETTING_KEYS.indexOf(k) >= 0) {
        return;
      }
      // 下载功能关闭时，下载分组只显示「启用下载功能」总闸，其余设置项一并隐藏
      if (prefix === 'download.' && !isDownloadEnabled() && k !== DOWNLOAD_MASTER_KEY) {
        return;
      }
      // 整曲缓存未启用时，不显示只对音频缓存有意义的两项
      if (!AUDIO_CACHE_ENABLED && AUDIO_CACHE_ONLY_KEYS.indexOf(k) >= 0) {
        return;
      }
      keys.push(k);
    });
    keys.sort();
    return keys;
  }

  build() {
    // 单页瀑布式：所有子模块（分组）纵向堆叠，全部直接展开，不做折叠交互
    // 外层 Stack 只为「点击数值就地弹出下拉列表」提供定位容器（浮窗 position 相对它计算）
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column() {
          ForEach(ACTIVE_GROUPS, (g: SettingGroup): void => {
            this.GroupCard(g)
          }, (g: SettingGroup): string => g.id)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)

      if (this.pickerKey.length > 0) {
        this.OptionPicker()
      }
      if (this.customKey.length > 0) {
        this.CustomPathDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.mainBackground)
    .onAreaChange((_old: Area, area: Area): void => {
      // 记录容器窗口坐标：下拉浮窗需要它把「点击位置」换算成容器内坐标
      setPopupContainer(Number(area.globalPosition.x), Number(area.globalPosition.y));
      if (this.pickerKey.length > 0) {
        this.pickerPos = computePopupPos(this.pickerWidth(), this.pickerHeight());
      }
    })
  }

  /** 「关于」标题是否含可密点的「慢时光音乐」五字 */
  private isAboutWithSecret(g: SettingGroup): boolean {
    return g.id === 'about' && this.groupName(g).indexOf('慢时光音乐') >= 0;
  }

  /** 「慢时光音乐」之前的标题片段 */
  private aboutPrefix(g: SettingGroup): string {
    const full: string = this.groupName(g);
    const idx: number = full.indexOf('慢时光音乐');
    return idx < 0 ? full : full.slice(0, idx);
  }

  /** 「慢时光音乐」之后的标题片段 */
  private aboutSuffix(g: SettingGroup): string {
    const full: string = this.groupName(g);
    const idx: number = full.indexOf('慢时光音乐');
    return idx < 0 ? '' : full.slice(idx + 5);
  }

  /** 单个分组卡片：标题 + 该组全部设置项；分组标题本身不可折叠（折叠在各内容内部） */
  @Builder
  private GroupCard(g: SettingGroup) {
    Column() {
      Row() {
        if (this.isAboutWithSecret(g)) {
          Text(this.aboutPrefix(g))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.font)
          Text('慢时光音乐')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.font)
            .onClick((): void => { recordAboutTitleTap(); })
          Text(this.aboutSuffix(g))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.font)
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
        } else if (g.id === 'changelog') {
          // 「更新日志」标题是生日彩蛋关闭手势的第 2 段，点击本身没有任何界面反馈
          Text(this.groupName(g))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.font)
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
            .onClick((): void => { recordChangelogTap(); })
        } else {
          Text(this.groupName(g))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.font)
            .layoutWeight(1)
            .textAlign(TextAlign.Start)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(this.pal().card)
      .borderRadius(12)

      Column() {
        if (g.id === 'customSource') {
          CustomSourcePanel({ theme: this.theme })
        } else if (g.id === 'dislike' || g.id === 'backup' || g.id === 'log' || g.id === 'about') {
          ToolPanel({ theme: this.theme, part: g.id })
        } else if (g.id === 'changelog') {
          VersionLogPanel({ theme: this.theme })
        } else {
          // 桌面歌词分组：说明鸿蒙版的落地方式（系统悬浮窗不可用 → 系统播控单行歌词）
          if (g.id === 'desktopLyric') {
            Text(this.tx('desk_lyric_note'))
              .fontSize(11)
              .fontColor(this.pal().subText)
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({ left: 16, right: 16, top: 10, bottom: 4 })
          }
          // 缓存分组：说明三层缓存（整曲 / 封面 / 歌词）各自的行为
          if (g.id === 'cache') {
            Text(this.tx('cache_note'))
              .fontSize(11)
              .fontColor(this.pal().subText)
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({ left: 16, right: 16, top: 10, bottom: 6 })
          }
          // 下载分组：总闸说明「切换后需重启」+「关闭时隐藏所有下载入口」
          if (g.id === 'download') {
            Text(isDownloadEnabled()
              ? '下载功能已开启。关闭下面的开关并重启应用后，将隐藏下载管理页、各处下载按钮与其余下载设置项。'
              : '下载功能已关闭。打开下面的开关并重启应用后，将恢复下载管理页与各处下载按钮；关闭期间所有下载入口保持隐藏。')
              .fontSize(11)
              .fontColor(this.pal().subText)
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({ left: 16, right: 16, top: 10, bottom: 6 })
          }
          ForEach(this.entriesFor(g.prefix), (key: string): void => {
            Column() {
              this.SettingRow(key)
              Divider()
                .width('100%')
                .color(this.pal().divider)
                .strokeWidth(0.5)
                .margin({ left: 16, right: 16 })
            }
            .width('100%')
          }, (key: string): string => key + '_' + this.version.toString())
          // 缓存分组：末尾附「当前占用（音频/封面/歌词）+ 立即清理」
          if (g.id === 'cache') {
            CachePanel({ theme: this.theme, version: this.version })
          }
        }
      }
      .width('100%')
      .padding({ top: 4, bottom: 10 })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  @Builder
  SettingRow(key: string) {
    Column() {
      Row() {
        Column() {
          Text(settingTitle(key))
            .fontSize(13)
            .fontColor(this.theme.font)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        if (this.isBool(key)) {
          Toggle({ type: ToggleType.Switch, isOn: this.store.getBoolean(key) })
            .selectedColor(this.theme.primary)
            .onChange((on: boolean): void => { this.update(key, on); })
        } else if (this.isSelect(key)) {
          // 点击数值就地展开下拉列表（不再循环切换，选项文案跟随界面语言）
          Row() {
            Text(this.displayValue(key))
              .fontSize(12)
              .fontColor(this.theme.primary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: Math.max(popupMaxWidthVp() - 160, 80) })
            Text('▾')
              .fontSize(10)
              .fontColor(this.theme.primary)
              .margin({ left: 3 })
          }
          .onClick((e: ClickEvent): void => { this.openPicker(key, e.windowX, e.windowY); })
        } else {
          Text(this.displayValue(key))
            .fontSize(12)
            .fontColor(this.pal().subText)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')

      if (this.isSlider(key)) {
        this.SettingSlider(key)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 设置项滑动条。
   *
   * 两个定制点（2026-11-16 用户要求）：
   * ① 长度缩到原来的 80%，左侧与文字对齐；
   * ② 只能按住圆点拖动——系统 Slider 默认点击轨道任意处会跳值，这里把 Slider 设为
   *    `HitTestMode.None`（自己不接收触摸，仅作展示），再在圆点位置叠一个透明把手接手势。
   */
  @Builder
  SettingSlider(key: string) {
    Stack({ alignContent: Alignment.Start }) {
      Slider({
        value: this.sliderValueOf(key),
        min: this.sliderRange(key).min,
        max: this.sliderRange(key).max,
        step: this.sliderRange(key).step,
        style: SliderStyle.OutSet,
      })
        .width('100%')
        .blockSize({ width: SLIDER_BLOCK_VP, height: SLIDER_BLOCK_VP })
        .trackThickness(4)
        .selectedColor(this.theme.primary)
        .trackColor(this.pal().divider)
        .showSteps(this.sliderRange(key).smooth !== true)
        .hitTestBehavior(HitTestMode.None)

      Row()
        .width(SLIDER_HIT_VP)
        .height(SLIDER_HIT_VP)
        .borderRadius(SLIDER_HIT_VP / 2)
        .backgroundColor(Color.Transparent)
        .offset({ x: this.sliderBlockX(key) })
        .hitTestBehavior(HitTestMode.Block)
        .gesture(
          PanGesture({ distance: 0 })
            .onActionStart((): void => {
              this.dragKey = key;
              this.dragStartVal = this.store.getNumber(key);
              this.dragVal = this.dragStartVal;
            })
            .onActionUpdate((e: GestureEvent): void => {
              const usable: number = this.trackW - SLIDER_BLOCK_VP;
              if (usable <= 0) {
                return;
              }
              const r: SliderRange = this.sliderRange(key);
              const delta: number = (e.offsetX / usable) * (r.max - r.min);
              let v: number = this.dragStartVal + delta;
              if (v < r.min) {
                v = r.min;
              }
              if (v > r.max) {
                v = r.max;
              }
              this.dragVal = this.snapSliderValue(key, v);
            })
            .onActionEnd((): void => {
              const v: number = this.snapSliderValue(key, this.dragVal);
              this.dragVal = v;
              void this.update(key, v).then((): void => {
                if (this.dragKey === key) {
                  this.dragKey = '';
                }
              });
            })
            .onActionCancel((): void => {
              this.dragKey = '';
            })
        )
    }
    .width('80%')
    .height(SLIDER_ROW_VP)
    .onAreaChange((_old: Area, now: Area): void => {
      const w: number = Number(now.width);
      if (w > 0 && Math.abs(w - this.trackW) > 0.5) {
        this.trackW = w;
      }
    })
  }

  private isBool(key: string): boolean {
    return typeof this.store.get(key) === 'boolean' && !this.isSlider(key);
  }

  private isSelect(key: string): boolean {
    return SELECT_KEYS[key] !== undefined;
  }

  private isSlider(key: string): boolean {
    return SLIDER_KEYS[key] !== undefined;
  }

  private sliderRange(key: string): SliderRange {
    return SLIDER_KEYS[key] ?? { min: 0, max: 100, step: 1 };
  }

  /** 滑动条当前显示值：拖动中跟手，否则读设置值 */
  private sliderValueOf(key: string): number {
    if (this.dragKey === key) {
      return this.dragVal;
    }
    return this.store.getNumber(key);
  }

  /** 按 step 吸附到最近档位；step<=0 表示连续平滑（音量 / 锁屏模糊） */
  private snapSliderValue(key: string, v: number): number {
    const r: SliderRange = this.sliderRange(key);
    if (r.step <= 0) {
      return Math.round(v * 1000) / 1000;
    }
    const n: number = Math.round((v - r.min) / r.step);
    return Math.round((r.min + n * r.step) * 1000) / 1000;
  }

  /** 圆点左边缘相对轨道左端的偏移（命中区比圆点大，居中后可能略微左右溢出） */
  private sliderBlockX(key: string): number {
    const r: SliderRange = this.sliderRange(key);
    const span: number = r.max - r.min;
    const usable: number = this.trackW - SLIDER_BLOCK_VP;
    if (span <= 0 || usable <= 0) {
      return -((SLIDER_HIT_VP - SLIDER_BLOCK_VP) / 2);
    }
    const v: number = this.sliderValueOf(key);
    let pct: number = (v - r.min) / span;
    if (pct < 0) {
      pct = 0;
    }
    if (pct > 1) {
      pct = 1;
    }
    return pct * usable - (SLIDER_HIT_VP - SLIDER_BLOCK_VP) / 2;
  }

  /** 滑动条的数值文案：音量 / 模糊 / 字号按百分比，倍速带 x，缓存带 GB */
  private sliderText(key: string): string {
    const v: number = this.sliderValueOf(key);
    if (key === 'player.volume' || key === 'player.lockScreenBlur' ||
      key === 'desktopLyric.style.opacity' || key === 'player.lockScreenTransparency') {
      return Math.round(v * (key === 'player.volume' ? 100 : 1)).toString() + '%';
    }
    if (key === 'player.playbackRate') {
      return v.toString() + 'x';
    }
    if (key === 'playDetail.vertical.style.lrcFontSize' ||
      key === 'playDetail.horizontal.style.lrcFontSize' ||
      key === 'desktopLyric.style.fontSize') {
      return Math.round(v).toString() + '%';
    }
    if (key === 'cache.maxSize') {
      return Math.round(v).toString() + ' GB';
    }
    return v.toString();
  }

  private displayValue(key: string): string {
    // 读一次 langTick，确保语言切换后这一行的显示值参与依赖收集并重算
    const langTick: number = this.langTick;
    const tickSuffix: string = langTick >= 0 ? '' : '';
    if (this.isSlider(key)) {
      return this.sliderText(key) + tickSuffix;
    }
    const v = this.store.get(key);
    // 枚举型统一走 optionLabel：显示与下拉选项完全一致，且跟随界面语言
    if (this.isSelect(key)) {
      return this.optionLabel(key, typeof v === 'string' ? v : '') + tickSuffix;
    }
    if (v === null) {
      return '未设置' + tickSuffix;
    }
    return v.toString() + tickSuffix;
  }

  /** 下拉列表：半透明遮罩 + 贴点击位置的白色卡片，当前值高亮 */
  @Builder
  OptionPicker() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.pickerKey = ''; })

      Column() {
        Scroll() {
          Column() {
            ForEach(this.pickerOptions(this.pickerKey), (opt: string): void => {
              Row() {
                Text(this.optionLabel(this.pickerKey, opt))
                  .fontSize(14)
                  .fontColor(this.pickerCurrent(this.pickerKey, opt) ? this.theme.primary : this.theme.font)
                  .fontWeight(this.pickerCurrent(this.pickerKey, opt) ? FontWeight.Bold : FontWeight.Normal)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.pickerCurrent(this.pickerKey, opt)) {
                  Image($r('app.media.ic_check'))
                    .width(16).height(16)
                    .fillColor(this.theme.primary)
                }
              }
              .width('100%').height(42).padding({ left: 16, right: 14 })
              .onClick((): void => { this.chooseOption(this.pickerKey, opt); })
            }, (opt: string): string => this.pickerKey + '|' + opt)
          }
          .width('100%')
        }
        .height('100%')
        .scrollBar(BarState.Off)
      }
      .width(this.pickerWidth())
      .height(this.pickerHeight())
      .constraintSize({ maxHeight: popupMaxHeightVp() })
      .backgroundColor(this.pal().card)
      .borderRadius(12)
      .border({ width: 1, color: this.pal().divider })
      .position({ x: this.pickerPos.x, y: this.pickerPos.y })
      .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 6 })
    }
    .width('100%').height('100%')
  }

  /** 自定义保存子目录输入弹窗（应用内浮层，配色跟随主题） */
  @Builder
  CustomPathDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('#66000000')

      Column() {
        Text('自定义保存子目录')
          .fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.theme.font)
          .width('100%')
        Text('只填相对子目录，支持 a/b 两级；留空表示直接放在下载根目录')
          .fontSize(11).fontColor(buildPalette(this.theme).subText)
          .width('100%').margin({ top: 6, bottom: 10 })
        TextInput({ text: this.customText, placeholder: '例如：我的音乐/周杰伦' })
          .fontSize(14).fontColor(this.theme.font)
          .backgroundColor(buildPalette(this.theme).pillBg)
          .width('100%').height(40)
          .onChange((v: string): void => { this.customText = v; })
        Row() {
          Text('取消').fontSize(14).fontColor(buildPalette(this.theme).subText)
            .layoutWeight(1).textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 })
            .onClick((): void => { this.customKey = ''; })
          Text('确定').fontSize(14).fontColor(this.theme.primary)
            .layoutWeight(1).textAlign(TextAlign.Center).padding({ top: 12, bottom: 12 })
            .onClick((): void => {
              void this.update(this.customKey, sanitizeSubDir(this.customText));
              this.customKey = '';
            })
        }
        .width('100%').margin({ top: 10 })
      }
      .width('78%').padding(18)
      .backgroundColor(this.pal().card).borderRadius(16)
    }
    .width('100%').height('100%')
  }

  private pickerOptions(key: string): string[] {
    const base: string[] = SELECT_KEYS[key] ?? [];
    if (key === 'download.savePath') {
      // 自定义路径不在预设列表里：把它补进下拉，保证当前值始终可见可选
      const cur: string = this.store.getString(key, '');
      if (cur.length > 0 && base.indexOf(cur) < 0) {
        return base.concat([cur]);
      }
    }
    return base;
  }

  private pickerCurrent(key: string, opt: string): boolean {
    return this.store.getString(key) === opt;
  }

  /** 下拉卡片高度：标题留白 + 每项 42vp + 底部留白（超高时由父级 maxHeight 夹紧并内部滚动） */
  private pickerHeight(): number {
    return 36 + 42 * this.pickerOptions(this.pickerKey).length + 8;
  }

  /** 下拉卡片宽度：按最长选项文案测量，右侧给对勾留 26vp */
  private pickerWidth(): number {
    const labels: string[] = this.pickerOptions(this.pickerKey)
      .map((o: string): string => this.optionLabel(this.pickerKey, o));
    const base: number = popupWidthForTexts(labels, 14, 16) + 26;
    const cap: number = popupMaxWidthVp();
    return base > cap ? cap : base;
  }

  /** 点击数值：记录点击位置并展开下拉（浮窗落在所点位置附近，不越过头部/播控栏） */
  private openPicker(key: string, windowX: number, windowY: number): void {
    setPopupAnchor(windowX, windowY);
    this.pickerKey = key;
    this.pickerPos = computePopupPos(this.pickerWidth(), this.pickerHeight());
  }

  private chooseOption(key: string, opt: string): void {
    this.pickerKey = '';
    if (key === 'download.savePath' && opt === '__custom__') {
      const cur: string = this.store.getString(key, '');
      this.customText = cur === '__custom__' ? '' : cur;
      this.customKey = key;
      return;
    }
    if (key === 'common.langId') {
      void I18n().setLang(opt as 'auto' | 'zh-cn' | 'zh-tw' | 'en-us');
      // 设置页各行的 ForEach key 只拼了 version；语言分支不走 update()，
      // 必须在这里手动 +1 才能让「界面语言」这一行重建、右侧文案立即刷新。
      this.version = this.version + 1;
      return;
    }
    void this.update(key, opt);
    if (key === 'player.timeoutExit') {
      // 设置页改定时停止，立刻作用到播放控制器
      const n = parseInt(opt);
      PlayController.getInstance().setTimeoutExit(isNaN(n) ? 0 : n);
    }
  }

  /**
   * 选项文案（全部走多语言，跟随界面语言）：
   * 值本身是枚举 id，直接显示会露出 alias / top / 2048 这类内部值，所以逐项映射。
   */
  private optionLabel(key: string, opt: string): string {
    if (key === 'common.langId') {
      return I18n().t('lang_' + opt.split('-').join('_'));
    }
    if (key === 'common.sourceNameType') {
      return opt === 'real' ? I18n().t('opt_real') : I18n().t('opt_alias');
    }
    if (key === 'player.togglePlayMethod') {
      if (opt === 'random') {
        return I18n().t('mode_random');
      }
      if (opt === 'list') {
        return I18n().t('mode_list');
      }
      if (opt === 'singleLoop') {
        return I18n().t('mode_single');
      }
      return I18n().t('mode_loop');
    }
    if (key === 'player.playQuality') {
      if (opt === 'flac') {
        return I18n().t('opt_lossless');
      }
      if (opt === 'flac24bit') {
        return I18n().t('opt_hires');
      }
      return opt;
    }
    if (key === 'player.timeoutExit') {
      const n: number = parseInt(opt);
      if (isNaN(n) || n <= 0) {
        return I18n().t('timer_off');
      }
      return n.toString() + ' ' + I18n().t('min_unit');
    }
    if (key === 'playDetail.style.align') {
      if (opt === 'left') {
        return I18n().t('opt_align_left');
      }
      if (opt === 'right') {
        return I18n().t('opt_align_right');
      }
      return I18n().t('opt_align_center');
    }
    if (key === 'cache.limitMb') {
      const mb: number = parseInt(opt);
      if (isNaN(mb) || mb <= 0) {
        return opt;
      }
      // 档位单位 MiB，按 1000 进到 GiB 显示：500/1000…6000 → 500 MiB … 6 GiB
      return mb >= 1000 ? ((Math.round(mb / 1000 * 100) / 100).toString() + ' GiB') : (mb.toString() + ' MiB');
    }
    if (key === 'cache.coverLimit') {
      const n: number = parseInt(opt);
      if (isNaN(n) || n <= 0) {
        return opt;
      }
      return n.toString() + ' ' + I18n().t('items');
    }
    if (key === 'player.cacheSize') {
      const mb: number = parseInt(opt);
      if (isNaN(mb) || mb >= 2048) {
        return I18n().t('opt_cache_unlimited');
      }
      return mb.toString() + ' MB / ' + I18n().t('unit_song');
    }
    if (key === 'list.addMusicLocationType') {
      return opt === 'bottom' ? I18n().t('opt_bottom') : I18n().t('opt_top');
    }
    if (key === 'download.fileName') {
      return fileNamePreview(opt);
    }
    if (key === 'download.storage') {
      return opt === 'sandbox' ? I18n().t('opt_dl_sandbox') : I18n().t('opt_dl_public');
    }
    if (key === 'download.savePath') {
      if (opt === '__custom__') {
        return '自定义…';
      }
      const sub: string = opt.trim();
      const base: string = this.store.getString('download.storage', 'public') === 'sandbox'
        ? 'downloads' : I18n().t('opt_dl_public_short');
      return sub.length > 0 ? base + '/' + sub : base;
    }
    if (key === 'theme.id' || key === 'theme.lightId' || key === 'theme.darkId') {
      for (const t of THEMES) {
        if (t.id === opt) {
          return t.name;
        }
      }
    }
    return opt;
  }

  /** 立即切换窗口方向（设置页开关专用；失败只忽略，下次启动仍按设置生效） */
  private async applyOrientationNow(landscape: boolean): Promise<void> {
    try {
      const win = await window.getLastWindow(getContext(this));
      // 横屏开关：AUTO_ROTATION_LANDSCAPE 随左右横屏翻转，竖起/倒立不动
      const target = landscape
        ? window.Orientation.AUTO_ROTATION_LANDSCAPE : window.Orientation.PORTRAIT;
      await win.setPreferredOrientation(target);
    } catch (e) {
      // 拿不到窗口时忽略：EntryAbility 启动时也会按设置重新应用
    }
  }

  private async update(key: string, value: SettingValue): Promise<void> {
    await this.store.set(key, value);
    // 主题四项（手选主题 / 明暗各自主题 / 跟随系统）改完立刻重新解析并广播
    if (key === 'theme.id' || key === 'theme.lightId' || key === 'theme.darkId' || key === 'common.isAutoTheme') {
      this.state.refreshTheme();
      this.onThemeChange(this.state.theme.id);
    }
    // 歌词开关直连系统播控：改完立即重推（关闭则清空），并同步桌面歌词窗显隐
    if (key === 'desktopLyric.enable' || key === 'player.isS2t') {
      PlayController.getInstance().refreshSystemLyric();
    }
    if (key === 'desktopLyric.floatEnable' || key === 'desktopLyric.isLock') {
      PlayController.getInstance().refreshDesktopLyric();
    }
    // 歌词翻译 / 音译：原来只在切歌那一刻读，改了当首不生效 —— 就地重建歌词行
    if (key === 'player.isShowLyricTranslation' || key === 'player.isShowLyricRoma') {
      PlayController.getInstance().refreshLyricOptions();
    }
    // 通知栏封面：同样只在推元数据时读，改完重推一次系统卡片
    if (key === 'player.isShowNotificationImage') {
      PlayController.getInstance().refreshSessionMetadata();
    }
    // 方向开关立即生效：默认竖屏，开了「强制横屏」才转横屏，不用重启应用
    if (key === 'common.forceLandscape') {
      this.applyOrientationNow(value === true);
    }
    // 封面缓存上限：改完立刻按新上限裁剪，超出的当场淘汰
    if (key === 'cache.coverLimit') {
      CacheStore.getInstance().applyCoverLimit();
    }
    this.version = this.version + 1;
  }

}
