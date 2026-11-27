/**
 * 生日彩蛋的隐藏关闭开关（静默，无任何 UI 反馈，不写更新日志）。
 *
 * 规则（用户指定，2026-11-20）：
 * - 设置里先连续点「当前版本」≥9 次，再连续点「更新日志」≥23 次 → 永久关闭彩蛋；
 * - 顺序相反无效；从第一次有效点击起超过 1 分钟未完成则重新计数；
 * - 关闭状态写进 preferences，只有卸载重装（清除应用数据）才会恢复。
 *
 * 计数在内存同步累加（快速连点不丢），偏好只做串行落盘。
 */
import { preferences } from '@kit.ArkData';
import { getAppContext } from '../common/AppContext';

const PREF_NAME: string = 'slowtime_birthday_secret';
const KEY_DISABLED: string = 'disabled';
const KEY_STAGE: string = 'stage';
const KEY_VERSION_TAPS: string = 'version_taps';
const KEY_CHANGELOG_TAPS: string = 'changelog_taps';
const KEY_STARTED_AT: string = 'started_at';

const WINDOW_MS: number = 60 * 1000;
const VERSION_TAPS_REQUIRED: number = 9;
const CHANGELOG_TAPS_REQUIRED: number = 23;

let disabled: boolean = false;
let stage: number = 0;
let versionTaps: number = 0;
let changelogTaps: number = 0;
let startedAt: number = 0;
let writeChain: Promise<void> = Promise.resolve();

export function isBirthdayEggDisabled(): boolean {
  return disabled;
}

/** 启动时载入关闭状态与未完成的计数（在首页加载前调用） */
export async function initBirthdaySecret(): Promise<void> {
  disabled = false;
  stage = 0;
  versionTaps = 0;
  changelogTaps = 0;
  startedAt = 0;
  const ctx = getAppContext();
  if (ctx === null) {
    return;
  }
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    const d = await store.get(KEY_DISABLED, false);
    disabled = typeof d === 'boolean' ? d as boolean : false;
    if (disabled) {
      return;
    }
    const s = await store.get(KEY_STAGE, 0);
    const v = await store.get(KEY_VERSION_TAPS, 0);
    const c = await store.get(KEY_CHANGELOG_TAPS, 0);
    const t = await store.get(KEY_STARTED_AT, 0);
    stage = typeof s === 'number' ? s as number : 0;
    versionTaps = typeof v === 'number' ? v as number : 0;
    changelogTaps = typeof c === 'number' ? c as number : 0;
    startedAt = typeof t === 'number' ? t as number : 0;
    if (startedAt <= 0 || Date.now() - startedAt > WINDOW_MS) {
      reset();
    }
  } catch (e) {
    reset();
  }
}

function reset(): void {
  stage = 0;
  versionTaps = 0;
  changelogTaps = 0;
  startedAt = 0;
}

/** 点「当前版本」：第 1 阶段，静默计数 */
export function recordVersionTap(): void {
  if (disabled) {
    return;
  }
  const now: number = Date.now();
  if (stage === 1) {
    // 已进入第 2 阶段又回头点「当前版本」：顺序断掉，从 1 重新计
    reset();
    startedAt = now;
    versionTaps = 1;
  } else {
    if (startedAt <= 0 || now - startedAt > WINDOW_MS) {
      reset();
      startedAt = now;
    }
    versionTaps += 1;
    if (versionTaps >= VERSION_TAPS_REQUIRED) {
      stage = 1;
      changelogTaps = 0;
    }
  }
  schedulePersist();
}

/** 点「更新日志」：第 2 阶段，反序（还没点满当前版本）一律无效 */
export function recordChangelogTap(): void {
  if (disabled) {
    return;
  }
  const now: number = Date.now();
  if (stage !== 1 || startedAt <= 0 || now - startedAt > WINDOW_MS) {
    reset();
    schedulePersist();
    return;
  }
  changelogTaps += 1;
  if (changelogTaps >= CHANGELOG_TAPS_REQUIRED) {
    disabled = true;
    reset();
  }
  schedulePersist();
}

function schedulePersist(): void {
  writeChain = writeChain.then((): Promise<void> => persistNow());
}

async function persistNow(): Promise<void> {
  const ctx = getAppContext();
  if (ctx === null) {
    return;
  }
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    await store.put(KEY_DISABLED, disabled);
    await store.put(KEY_STAGE, stage);
    await store.put(KEY_VERSION_TAPS, versionTaps);
    await store.put(KEY_CHANGELOG_TAPS, changelogTaps);
    await store.put(KEY_STARTED_AT, startedAt);
    await store.flush();
  } catch (e) {
    // 静默：偏好失败不影响设置页
  }
}
