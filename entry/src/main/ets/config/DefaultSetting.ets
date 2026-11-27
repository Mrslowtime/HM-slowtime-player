// 由 tools/gen_assets.py 自动生成，请勿手工编辑。
// 数据来源：协议 协议 本协议（76 项）+ 鸿蒙端追加 7 项

export type SettingValue = string | number | boolean | null

export interface SettingEntry {
  key: string
  value: SettingValue
}

/** 与协议完全一致的默认设置表 */
export const DEFAULT_SETTING_ENTRIES: SettingEntry[] = [
  { key: 'version', value: '2.1' },
  { key: 'common.isAutoTheme', value: false },
  { key: 'common.langId', value: null },
  { key: 'common.apiSource', value: '' },
  { key: 'common.sourceNameType', value: 'alias' },
  { key: 'common.shareType', value: 'system' },
  { key: 'common.isAgreePact', value: false },
  { key: 'common.autoHidePlayBar', value: true },
  { key: 'common.drawerLayoutPosition', value: 'left' },
  { key: 'common.homePageScroll', value: true },
  { key: 'common.allowProgressBarSeek', value: true },
  { key: 'common.showBackBtn', value: false },
  { key: 'common.showExitBtn', value: true },
  { key: 'common.useSystemFileSelector', value: true },
  { key: 'common.alwaysKeepStatusbarHeight', value: false },
  { key: 'common.forceLandscape', value: false },
  { key: 'common.autoUpdateSource', value: true },
  { key: 'player.startupAutoPlay', value: false },
  { key: 'player.startupPushPlayDetailScreen', value: false },
  { key: 'player.togglePlayMethod', value: 'listLoop' },
  { key: 'player.playQuality', value: '128k' },
  { key: 'player.isSavePlayTime', value: false },
  { key: 'player.volume', value: 1 },
  { key: 'player.playbackRate', value: 1 },
  { key: 'player.cacheSize', value: '2048' },
  { key: 'player.timeoutExit', value: '' },
  { key: 'player.timeoutExitPlayed', value: true },
  { key: 'player.isAutoCleanPlayedList', value: false },
  { key: 'player.isHandleAudioFocus', value: true },
  { key: 'player.isEnableAudioOffload', value: false },
  { key: 'player.isShowLyricTranslation', value: false },
  { key: 'player.isShowLyricRoma', value: false },
  { key: 'player.isShowNotificationImage', value: true },
  { key: 'player.isS2t', value: false },
  { key: 'player.isShowBluetoothLyric', value: false },
  { key: 'player.isShowBluetoothFullLyric', value: false },
  { key: 'player.lockScreenBlur', value: 80 },
  { key: 'player.lockScreenTransparency', value: 50 },
  { key: 'playDetail.style.align', value: 'center' },
  { key: 'playDetail.vertical.style.lrcFontSize', value: 210 },
  { key: 'playDetail.horizontal.style.lrcFontSize', value: 220 },
  { key: 'playDetail.isShowLyricProgressSetting', value: false },
  { key: 'desktopLyric.enable', value: false },
  // 鸿蒙端新增：系统桌面歌词组件（API 23+）悬浮窗开关，开启后歌词以系统悬浮窗显示
  { key: 'desktopLyric.floatEnable', value: true },
  { key: 'desktopLyric.isLock', value: false },
  { key: 'desktopLyric.width', value: 100 },
  { key: 'desktopLyric.maxLineNum', value: 5 },
  { key: 'desktopLyric.isSingleLine', value: false },
  { key: 'desktopLyric.showToggleAnima', value: true },
  { key: 'desktopLyric.position.x', value: 0 },
  { key: 'desktopLyric.position.y', value: 0 },
  { key: 'desktopLyric.textPosition.x', value: 'left' },
  { key: 'desktopLyric.textPosition.y', value: 'top' },
  { key: 'desktopLyric.style.fontSize', value: 180 },
  { key: 'desktopLyric.style.opacity', value: 100 },
  { key: 'desktopLyric.style.lyricUnplayColor', value: 'rgba(255, 255, 255, 1)' },
  { key: 'desktopLyric.style.lyricPlayedColor', value: 'rgba(7, 197, 86, 1)' },
  { key: 'desktopLyric.style.lyricShadowColor', value: 'rgba(0, 0, 0, 0.6)' },
  { key: 'search.isShowHotSearch', value: true },
  { key: 'search.isShowHistorySearch', value: true },
  { key: 'list.isClickPlayList', value: true },
  { key: 'list.isShowSource', value: true },
  { key: 'list.isShowAlbumName', value: false },
  { key: 'list.isShowInterval', value: true },
  { key: 'list.isSaveScrollLocation', value: true },
  { key: 'list.addMusicLocationType', value: 'top' },
  // 鸿蒙端新增：下载功能总闸（默认关闭；打开并重启后才会显示下载入口）
  { key: 'download.enable', value: false },
  { key: 'download.storage', value: 'public' },
  { key: 'download.fileName', value: '{singer} - {name}' },
  { key: 'download.savePath', value: 'HM慢时光' },
  { key: 'sync.enable', value: false },
  { key: 'cache.maxSize', value: 2 },
  // 缓存上限（MiB）：500 起步、每级 +500，最高 6000（见 core/CacheStore 的 CACHE_LIMIT_STEPS）
  { key: 'cache.limitMb', value: '2000' },
  { key: 'cache.autoClean', value: true },
  // 封面缓存张数上限（core/ImageCache 的 CoverCache，超出按最久未用淘汰）
  { key: 'cache.coverLimit', value: '2000' },
  { key: 'theme.id', value: 'green' },
  { key: 'theme.lightId', value: 'green' },
  { key: 'theme.darkId', value: 'black' },
  { key: 'theme.hideBgDark', value: false },
  { key: 'theme.dynamicBg', value: false },
  { key: 'theme.fontShadow', value: false },
  // ---------------- 鸿蒙端追加：代码在用但默认表缺失，重启会丢失（审查 B-05 修复）
  // 自动旋转开关（PlayDetail.ets 读写）——原先是野生 key，重启后设置失效
  { key: 'player.autoRotate', value: false },
  // 状态栏歌词「首次自动开启」迁移标记（PlayController.migrateStatusBarLyric）——
  // 原先野生 key 导致每次重启重复自动打开桌面歌词，用户手动关闭也会被重置
  { key: 'lyricBar.defaultOn', value: false },
]

/** 构造默认设置 Map（ArkTS 严格模式不能用对象字面量做索引签名） */
export function createDefaultSetting(): Map<string, SettingValue> {
  const m = new Map<string, SettingValue>()
  for (const e of DEFAULT_SETTING_ENTRIES) {
    m.set(e.key, e.value)
  }
  return m
}
