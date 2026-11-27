/**
 * 「关于」分组标题里「慢时光音乐」五字的隐藏入口。
 *
 * 规则（用户指定，2026-11-20）：
 * - 连点 6 次以上后**必须手动重启应用**才生效；本次会话内历史版本弹窗显示完整日志（解锁）。
 * - 连点 2 次后重启 → 重新隐藏，只显示首版 9527（本次会话立即生效的是重启后的新会话）。
 * - 两种手势都以「最后一次达标点击」起 1 分钟内重启才有效；超时清零，需重新点击。
 *   连点到 6 次时以 unlock 为准（覆盖中途经过的 2 次 hide），以最终达标手势为准。
 * - 全程无 toast、无高亮、无「继续点击 / 已解锁 / 已隐藏」提示；点这五个字本身也没有任何动作。
 * - 不写进更新日志。
 *
 * 计数在内存里同步累加（快速连点不丢），偏好只做跨重启持久化：独立 preferences 文件，
 * 串行落盘。不联网、不改任何播放链路。
 */
import { preferences } from '@kit.ArkData';
import { getAppContext } from '../common/AppContext';

const PREF_NAME: string = 'slowtime_changelog_secret';
const KEY_TAPS: string = 'taps';
const KEY_LAST_TAP: string = 'last_tap';
const KEY_ARMED_AT: string = 'armed_at';
const KEY_ARMED_MODE: string = 'armed_mode';
/** 点击窗口 & 重启期限：60 秒 */
const WINDOW_MS: number = 60 * 1000;
/** 解锁（显示完整日志）所需连点次数 */
const REQUIRED_TAPS: number = 6;
/** 重新隐藏（只显首版）所需连点次数 */
const HIDE_TAPS: number = 2;
/** 达标手势：解锁 / 隐藏 */
const MODE_UNLOCK: string = 'unlock';
const MODE_HIDE: string = 'hide';

/** 本次会话是否已解锁完整更新日志（仅内存，重启重新判定） */
let sessionUnlocked: boolean = false;
/** 内存镜像：连点计数 / 上次点击时间 / 达标时间 / 达标手势 */
let memTaps: number = 0;
let memLast: number = 0;
let memArmed: number = 0;
let memMode: string = '';
/** 串行落盘链，避免快速连点的并发写互相覆盖 */
let writeChain: Promise<void> = Promise.resolve();

export function isFullChangelogUnlocked(): boolean {
  return sessionUnlocked;
}

/** 点标题里的「慢时光音乐」：静默计数，没有任何 UI 反馈 */
export function recordAboutTitleTap(): void {
  const now: number = Date.now();
  if (memLast <= 0 || now - memLast > WINDOW_MS) {
    // 与上次点击间隔超过 1 分钟：从 1 重新计（必须连续），并清掉旧的达标时间/手势
    memTaps = 0;
    memArmed = 0;
    memMode = '';
  }
  memTaps += 1;
  memLast = now;
  if (memTaps >= REQUIRED_TAPS) {
    // 达 6 次：解锁手势（覆盖中途经过的 hide），以最后一次达标点击的时间为准
    memArmed = now;
    memMode = MODE_UNLOCK;
  } else if (memTaps >= HIDE_TAPS) {
    // 达 2~5 次：重新隐藏手势，同样以最后一次点击为准（继续点到 6 次会被上面覆盖成解锁）
    memArmed = now;
    memMode = MODE_HIDE;
  }
  writeChain = writeChain.then((): Promise<void> => persistTaps());
}

/** 把内存镜像串行写入偏好 */
async function persistTaps(): Promise<void> {
  const ctx = getAppContext();
  if (ctx === null) {
    return;
  }
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    await store.put(KEY_TAPS, memTaps);
    await store.put(KEY_LAST_TAP, memLast);
    await store.put(KEY_ARMED_AT, memArmed);
    await store.put(KEY_ARMED_MODE, memMode);
    await store.flush();
  } catch (e) {
    // 偏好读写失败：静默忽略，绝不影响设置页
  }
}

/**
 * 应用启动时调用（在加载首页之前）：
 * - 1 分钟内达标且手势为 unlock（连点 ≥6）→ 本次会话解锁，显示完整日志；
 * - 手势为 hide（连点 2~5）或超时 → 保持隐藏，只显示首版。
 * 无论成功与否都消费计数，下次启动必须重新点击。
 */
export async function consumeChangeLogSecret(): Promise<void> {
  sessionUnlocked = false;
  memTaps = 0;
  memLast = 0;
  memArmed = 0;
  memMode = '';
  const ctx = getAppContext();
  if (ctx === null) {
    return;
  }
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    const armedRaw = await store.get(KEY_ARMED_AT, 0);
    const armed: number = typeof armedRaw === 'number' ? armedRaw as number : 0;
    const modeRaw = await store.get(KEY_ARMED_MODE, '');
    const mode: string = typeof modeRaw === 'string' ? modeRaw as string : '';
    const now: number = Date.now();
    if (armed > 0 && now - armed <= WINDOW_MS) {
      // 1 分钟内达标：只有 unlock 手势才解锁；hide 手势（或旧版本无 mode 的兼容）保持隐藏
      sessionUnlocked = mode === MODE_UNLOCK;
    }
    await store.put(KEY_TAPS, 0);
    await store.put(KEY_LAST_TAP, 0);
    await store.put(KEY_ARMED_AT, 0);
    await store.put(KEY_ARMED_MODE, '');
    await store.flush();
  } catch (e) {
    sessionUnlocked = false;
  }
}
