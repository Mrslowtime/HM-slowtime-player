// 由 tools/gen_assets.py 自动生成，请勿手工编辑。
// 数据来源：协议 协议 src/theme/themes/createThemes.js

export interface ThemeInfo {
  id: string
  name: string
  isDark: boolean
  /** 主色（ArkUI #RRGGBB） */
  primary: string
  /** 正文色 */
  font: string
  /** 卡片/主背景 */
  mainBackground: string
}

/** 16 套内置主题，顺序与协议一致 */
export const THEMES: ThemeInfo[] = [
  {
    id: 'green', name: '绿意盎然',
    isDark: false,
    primary: '#4DAF7C',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'blue', name: '蓝田生玉',
    isDark: false,
    primary: '#3498DB',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'blue_plus', name: '蛋雅深蓝',
    isDark: false,
    primary: '#4D83AF',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'orange', name: '橙黄橘绿',
    isDark: false,
    primary: '#F5AB35',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'brown', name: '泥牛入海',
    isDark: false,
    primary: '#BC8044',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'red', name: '热情似火',
    isDark: false,
    primary: '#D64541',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'pink', name: '粉装玉琢',
    isDark: false,
    primary: '#F1828D',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'purple', name: '重斤球紫',
    isDark: false,
    primary: '#9B59B6',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'grey', name: '灰常美丽',
    isDark: false,
    primary: '#6C7A89',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'ming', name: '青出于黑',
    isDark: false,
    primary: '#336E7B',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'blue2', name: '清热板蓝',
    isDark: false,
    primary: '#4F62D0',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'black', name: '黑灯瞎火',
    isDark: true,
    primary: '#BEBEBE',
    font: '#FFFFFF',
    mainBackground: '#212530',
  },
  {
    id: 'mid_autumn', name: '月里嫦娥',
    isDark: false,
    primary: '#4A3752',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'naruto', name: '木叶之村',
    isDark: false,
    primary: '#5790A7',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'china_ink', name: '近墨者黑',
    isDark: false,
    primary: '#2F2F2F',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
  {
    id: 'happy_new_year', name: '新年快乐',
    isDark: false,
    primary: '#C0392B',
    font: '#212121',
    mainBackground: '#F7F7F5',
  },
]

export function getTheme(id: string): ThemeInfo {
  for (const t of THEMES) {
    if (t.id === id) {
      return t
    }
  }
  return THEMES[0]
}

/**
 * 派生语义色板 —— 从基础 3 色（主色/正文/背景）派生出一整套可复用的中性色，
 * 让 16 套主题都有完整色阶，而非只有主色。组件按需 buildPalette(theme) 取用，
 * 不修改 ThemeInfo，避免波及所有 @Prop 初始化（严模式不支持批量改默认字面量）。
 */
export interface ThemePalette {
  /** 卡片 / 输入框 / 面板表面 */
  card: string
  /** 次级文字（说明、占位） */
  subText: string
  /** 分割线 */
  divider: string
  /** 未选中胶囊背景（如设置分组 tab、抽屉选中项） */
  pillBg: string
  /** 未选中胶囊文字 */
  pillText: string
  /** 当前播放行的浅色底纹 */
  activeTint: string
}

function clampChannel(v: number): number {
  if (!Number.isFinite(v)) { return 0 }
  if (v < 0) { return 0 }
  if (v > 255) { return 255 }
  return Math.round(v)
}

function hexToRgb(hex: string): [number, number, number] {
  let h: string = hex.startsWith('#') ? hex.substring(1) : hex
  if (h.length === 3) {
    h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
  }
  if (h.length < 6) {
    return [0, 0, 0]
  }
  const r = parseInt(h.substring(0, 2), 16)
  const g = parseInt(h.substring(2, 4), 16)
  const b = parseInt(h.substring(4, 6), 16)
  return [Number.isNaN(r) ? 0 : r, Number.isNaN(g) ? 0 : g, Number.isNaN(b) ? 0 : b]
}

function rgbToHex(r: number, g: number, b: number): string {
  const h = (n: number): string => (clampChannel(n) < 16 ? '0' : '') + clampChannel(n).toString(16)
  return '#' + h(r) + h(g) + h(b)
}

/** 两色按 t∈[0,1] 线性混合（t=0 取 a，t=1 取 b） */
function mix(a: string, b: string, t: number): string {
  const ca = hexToRgb(a)
  const cb = hexToRgb(b)
  return rgbToHex(ca[0] + (cb[0] - ca[0]) * t, ca[1] + (cb[1] - ca[1]) * t, ca[2] + (cb[2] - ca[2]) * t)
}

/** 主题调色板缓存：buildPalette 在大量 build() 中被调用，结果只取决于主题，
 *  缓存后避免每次重绘做数十次 parseInt + 字符串拼接（审查 P-07）。 */
const paletteCache: Map<string, ThemePalette> = new Map<string, ThemePalette>();

export function buildPalette(t: ThemeInfo): ThemePalette {
  const cacheKey: string = t.id + '|' + (t.isDark ? 'd' : 'l');
  const cached: ThemePalette | undefined = paletteCache.get(cacheKey);
  if (cached !== undefined) {
    return cached;
  }
  let palette: ThemePalette;
  if (t.isDark) {
    palette = {
      card: mix(t.mainBackground, '#FFFFFF', 0.12),
      subText: mix(t.font, t.mainBackground, 0.45),
      divider: mix(t.mainBackground, '#FFFFFF', 0.18),
      pillBg: mix(t.mainBackground, t.primary, 0.16),
      pillText: t.primary,
      activeTint: mix(t.mainBackground, t.primary, 0.3),
    };
  } else {
    palette = {
      card: '#FFFFFF',
      subText: mix(t.font, '#FFFFFF', 0.55),
      divider: '#E8E6E0',
      pillBg: mix('#FFFFFF', t.primary, 0.14),
      pillText: mix(t.primary, '#000000', 0.25),
      activeTint: mix('#FFFFFF', t.primary, 0.14),
    };
  }
  paletteCache.set(cacheKey, palette);
  return palette;
}

