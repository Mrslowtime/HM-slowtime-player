/**
 * 屏幕 / 窗口尺寸断点 —— 平板适配的统一入口。
 *
 * 窗口层的真实宽度由 EntryAbility 在 onWindowStageCreate / windowSizeChange 写进来；
 * 拿不到时回落到 display 的物理屏宽。所有「手机 2 列、平板多列」「弹窗最大宽度」
 * 都读这里，避免各处直接写死数字。
 *
 * 注意单位：写进来的是 px（窗口 API 给的都是 px），读出来统一是 vp。
 */
import { display, mediaquery } from '@kit.ArkUI';

let sWindowWidthPx: number = 0;
let sWindowHeightPx: number = 0;
/** 方向监听只注册一次（首次进入首页时初始化） */
let sOrientationInited: boolean = false;

/** AppStorage 里保存「当前是否横屏」的 key */
export const STORAGE_LANDSCAPE: string = 'screenLandscape';
/**
 * AppStorage 里保存「是否用紧凑布局」的 key —— 组件统一订阅这个。
 *
 * 判据是**窗口实际高度**而不是方向：
 *  - 高度 < 480vp：手机横屏 / 分屏小窗，必须紧凑；
 *  - 横屏且高度 < 620vp：平板横屏，也偏矮，同样紧凑；
 *  - 其余（手机竖屏约 780vp、平板竖屏 800vp+）：一律原尺寸。
 *
 * 这样手机竖屏**永远不可能**走进紧凑分支，不会出现「竖屏行距莫名变紧」。
 */
export const STORAGE_COMPACT: string = 'screenCompact';
/** 矮屏阈值（vp）：低于此高度视为纵向空间不足 */
const COMPACT_SHORT_VP: number = 480;
/** 横屏时的矮屏阈值（vp）：平板横屏常见 600~700，仍算偏矮 */
const COMPACT_LANDSCAPE_VP: number = 620;

/** 按窗口 px 尺寸同时刷新「方向」与「紧凑」两个状态 */
function applyWindowMetrics(widthPx: number, heightPx: number): void {
  if (widthPx <= 0 || heightPx <= 0) {
    return;
  }
  sWindowWidthPx = widthPx;
  sWindowHeightPx = heightPx;
  const w: number = px2vp(widthPx);
  const h: number = px2vp(heightPx);
  const landscape: boolean = w > h;
  AppStorage.setOrCreate<boolean>(STORAGE_LANDSCAPE, landscape);
  AppStorage.setOrCreate<boolean>(STORAGE_COMPACT,
    h < COMPACT_SHORT_VP || (landscape && h < COMPACT_LANDSCAPE_VP));
}

/**
 * 初始化尺寸 / 方向监听：结果写进 AppStorage，组件侧用 @StorageProp 订阅，
 * 旋转、切「强制横屏」、进分屏都会立即生效。
 */
export function initScreenMetrics(): void {
  if (sOrientationInited) {
    return;
  }
  sOrientationInited = true;
  // 先用物理屏估一次，真正的窗口尺寸到达后会被 applyWindowMetrics 覆盖
  try {
    const d = display.getDefaultDisplaySync();
    applyWindowMetrics(d.width, d.height);
  } catch (e) {
    AppStorage.setOrCreate<boolean>(STORAGE_LANDSCAPE, false);
    AppStorage.setOrCreate<boolean>(STORAGE_COMPACT, false);
  }
  try {
    const mq = mediaquery.matchMediaSync('(orientation: landscape)');
    mq.on('change', (r: mediaquery.MediaQueryResult): void => {
      AppStorage.setOrCreate<boolean>(STORAGE_LANDSCAPE, r.matches);
      // 方向变了但窗口回调还没到时，用物理屏宽高补一次紧凑判定
      try {
        const d = display.getDefaultDisplaySync();
        applyWindowMetrics(d.width, d.height);
      } catch (e2) {
        // 取不到就沿用上一次的值
      }
    });
  } catch (e) {
    // mediaquery 不可用：只靠 EntryAbility 的窗口回调
  }
}

export function setWindowSizePx(widthPx: number, heightPx: number): void {
  if (widthPx > 0 && heightPx > 0) {
    applyWindowMetrics(widthPx, heightPx);
    return;
  }
  if (widthPx > 0) {
    sWindowWidthPx = widthPx;
  }
  if (heightPx > 0) {
    sWindowHeightPx = heightPx;
  }
}

export function screenWidthVp(): number {
  if (sWindowWidthPx > 0) {
    return px2vp(sWindowWidthPx);
  }
  try {
    return px2vp(display.getDefaultDisplaySync().width);
  } catch (e) {
    return 360;
  }
}

export function screenHeightVp(): number {
  if (sWindowHeightPx > 0) {
    return px2vp(sWindowHeightPx);
  }
  try {
    return px2vp(display.getDefaultDisplaySync().height);
  } catch (e) {
    return 780;
  }
}

/**
 * 按目标列宽从容器实测宽度算列数，夹在 [min, max] 内。
 * 手机端因为宽度不够，结果恒等于 min，原有观感不变。
 */
export function columnCount(viewportWidthVp: number, targetCellVp: number,
  min: number, max: number): number {
  if (viewportWidthVp <= 0 || targetCellVp <= 0) {
    return min;
  }
  const n: number = Math.floor(viewportWidthVp / targetCellVp);
  return Math.max(min, Math.min(max, n));
}
