/**
 * 悬浮窗定位工具 —— 让「⋯ 菜单」在点击的三个点附近弹出，并夹紧在屏幕内。
 *
 * 坐标约定：
 *  - ClickEvent.windowX/windowY、FingerInfo.globalX/globalY 为「窗口像素坐标」
 *    （相对窗口左上角，含状态栏区域）；
 *  - 页面内容默认避让状态栏，所以换算成页面 vp 坐标时要减去状态栏高度；
 *  - position() 传入数字时单位为 vp。
 *
 * 锚点用全局单例记录：各 ⋮ 按钮在点击时写入，随后即时挂载的浮窗读取，
 * 读到的就是本次点击的位置，因此不需要把坐标逐层透传到每个菜单组件。
 *
 * 布局规则（按最新需求）：
 *  - 水平：直接贴右边缘（距屏幕右边固定 margin），不再按 ⋮ 位置推算；
 *  - 垂直：优先开在 ⋮ 下方，放不下改上方，钳制在「max(状态栏下沿, 容器顶部) ~ 底部播控栏上沿」之间；
 *  - 浮窗宽高随内容变化；内容过高时由调用方夹紧高度并在内部 Scroll 滚动。
 */
import { display } from '@kit.ArkUI';

export interface PopupSize {
  w: number;
  h: number;
}

export interface PopupPoint {
  x: number;
  y: number;
}

/** 浮窗距屏幕边缘的安全留白（vp） */
export const POPUP_MARGIN: number = 8;
/** ⋮ 与浮窗之间的纵向间隙（vp） */
export const POPUP_GAP: number = 6;
/** 底部迷你播控栏高度（vp），与 components/PlayerBar.ets 的 .height(62) 保持一致 */
export const PLAYER_BAR_VP: number = 62;

/** 状态栏高度（px），由 EntryAbility 启动时写入；未取到时为 0（浮窗整体略低，但仍会被夹紧在屏幕内） */
let sTopInsetPx: number = 0;
/** 底部播控栏高度（vp）；默认取 PlayerBar 高度，可被 setBottomInsetVp 覆盖 */
let sBottomInsetVp: number = PLAYER_BAR_VP;

export function setTopInsetPx(value: number): void {
  sTopInsetPx = value;
}

/** 覆盖底部播控栏高度（vp），例如播控栏高度调整时调用 */
export function setBottomInsetVp(value: number): void {
  sBottomInsetVp = value;
}

export function getTopInsetVp(): number {
  return px2vp(sTopInsetPx);
}

export function getBottomInsetVp(): number {
  return sBottomInsetVp;
}

/** 屏幕宽高（vp） */
export function screenSizeVp(): PopupSize {
  try {
    const d = display.getDefaultDisplaySync();
    return { w: px2vp(d.width), h: px2vp(d.height) };
  } catch (e) {
    return { w: 360, h: 780 };
  }
}

/** 页面内容区可用高度（vp）：整屏高度 - 状态栏 */
export function screenContentHeightVp(): number {
  return screenSizeVp().h - getTopInsetVp();
}

/** 浮窗可用最大宽度（vp）：整屏宽 - 两侧留白 */
export function popupMaxWidthVp(): number {
  return screenSizeVp().w - POPUP_MARGIN * 2;
}

/**
 * 浮窗垂直可用区间（窗口坐标 vp）：
 *  上沿 = max(状态栏下沿, 浮窗容器顶部) + margin
 *  下沿 = 屏幕高 - 底部播控栏 - margin
 *
 * 关键：容器顶部必须参与计算。各页面承载浮窗的 Stack 位于「状态栏 + 应用头部」之下，
 * 如果只按状态栏夹紧，算出的 top 会高于容器顶部 → position 得到负数 y，
 * 卡片第一行（标题）就被容器裁掉，表现为「浮窗顶部超出窗口、顶上信息被遮住」。
 */
function popupTopBoundVp(): number {
  const base: number = Math.max(getTopInsetVp(), sContainerY);
  return base + POPUP_MARGIN;
}

function popupBottomBoundVp(): number {
  return screenSizeVp().h - sBottomInsetVp - POPUP_MARGIN;
}

/**
 * 浮窗可用最大高度（vp）：状态栏下沿 ~ 底部播控栏上沿 之间的高度。
 * 内容高于此值时，调用方应夹紧高度并在内部 Scroll。
 */
export function popupMaxHeightVp(): number {
  const h: number = popupBottomBoundVp() - popupTopBoundVp();
  // 极端情况下（容器顶已接近播控栏）至少留一点高度，避免算出 0 或负数
  return h > 120 ? h : 120;
}

/**
 * 估算一段文字在指定字号下的显示宽度（vp）。
 * 中文/全角按 1.0×字号，ASCII 字母数字约 0.55×，空格约 0.3×，作为内容自适应的近似。
 */
export function estimateTextWidth(text: string, fontSize: number): number {
  let w: number = 0;
  for (const ch of text) {
    const code: number = ch.codePointAt(0) ?? 0;
    if (code === 32) {
      w += fontSize * 0.3;
    } else if (code < 128) {
      w += fontSize * 0.55;
    } else {
      w += fontSize * 1.0;
    }
  }
  return w;
}

/** 按一组文字的最大宽度估算浮窗宽度（含左右内边距），并夹紧到可用最大宽度 */
export function popupWidthForTexts(texts: string[], fontSize: number, paddingX: number = 16): number {
  let max: number = 0;
  for (const t of texts) {
    const w: number = estimateTextWidth(t, fontSize) + paddingX * 2;
    if (w > max) {
      max = w;
    }
  }
  const cap: number = popupMaxWidthVp();
  if (max > cap) {
    max = cap;
  }
  return max;
}

/** 全局浮窗锚点（窗口 px） */
class PopupAnchor {
  private static inst: PopupAnchor | null = null;
  x: number = 0;
  y: number = 0;

  static getInstance(): PopupAnchor {
    if (PopupAnchor.inst === null) {
      PopupAnchor.inst = new PopupAnchor();
    }
    return PopupAnchor.inst;
  }
}

/** 记录本次点击的 ⋮ 位置（窗口 px） */
export function setPopupAnchor(windowX: number, windowY: number): void {
  const a: PopupAnchor = PopupAnchor.getInstance();
  a.x = windowX;
  a.y = windowY;
}

/**
 * 浮窗容器（即各页面里承载浮窗的 Stack）在「窗口坐标」中的左上角（vp）。
 * 由于浮窗的 position() 是相对该容器左上角的，必须把「想落在窗口的哪个位置」
 * 减去容器本身的窗口坐标，才不会出现「浮窗整体偏移（被头部/父容器顶下去）」的问题。
 */
let sContainerX: number = 0;
let sContainerY: number = 0;

/** 由各浮窗的根 Stack 在 onAreaChange 里写入：它的窗口坐标 globalPosition（vp，含状态栏区域） */
export function setPopupContainer(globalX: number, globalY: number): void {
  sContainerX = globalX;
  sContainerY = globalY;
}

/**
 * 计算浮窗左上角位置（vp，**容器相对坐标**）：
 *  内部先按窗口坐标算出浮窗应落在「贴右边缘 + 状态栏下沿 ~ 底部播控栏上沿」区间内的目标点，
 *  再减去浮窗容器自身的窗口坐标，得到相对该容器的 position 偏移，从而忽略一切嵌套/头部偏移。
 * @param popupW 浮窗宽度（vp）
 * @param popupH 浮窗高度（vp，调用方应已夹紧到 popupMaxHeightVp）
 */
export function computePopupPos(popupW: number, popupH: number): PopupPoint {
  const a: PopupAnchor = PopupAnchor.getInstance();
  // ⋮ 的窗口坐标（px→vp，含状态栏区域），与 globalPosition 同一坐标系（水平恒贴右边缘，只用纵坐标）
  const ay: number = px2vp(a.y);
  const size: PopupSize = screenSizeVp();
  const margin: number = POPUP_MARGIN;
  const gap: number = POPUP_GAP;

  // 水平：直接贴右边缘（距屏幕右边 margin）
  let left: number = size.w - margin - popupW;
  if (left < margin) {
    left = margin;
  }

  // 垂直可用区间（窗口坐标，含状态栏）：上不越过「状态栏下沿 / 容器顶部」，下不压到底部播控栏
  const topBound: number = popupTopBoundVp();
  const bottomBound: number = popupBottomBoundVp();
  let top: number;
  // 优先开在 ⋮ 下方；放不下则开在上方；都放不下则夹在区间顶部
  if (ay + gap + popupH <= bottomBound) {
    top = ay + gap;
  } else if (ay - gap - popupH >= topBound) {
    top = ay - gap - popupH;
  } else {
    top = topBound;
  }
  if (top < topBound) {
    top = topBound;
  }
  if (top > bottomBound - popupH) {
    top = bottomBound - popupH;
  }
  if (top < topBound) {
    top = topBound;
  }

  // 换算成浮窗容器（Stack）相对坐标：容器 globalPosition 也是窗口坐标（含状态栏），
  // 因此直接相减即可得到正确的 position 偏移，父级有没有头部、有没有嵌套都不影响。
  return { x: left - sContainerX, y: top - sContainerY };
}
