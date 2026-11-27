/**
 * 歌词简体 → 繁体转换（对应协议 `player.isS2t`）。
 *
 * 实现：使用系统 ICU 的转写器 `i18n.Transliterator`（Hans → Hant）。
 * - 转写器实例较重，首次使用时创建并缓存；创建失败置 `unsupported` 永久跳过。
 * - 设备/系统若不支持该 ID，`convert()` 原样返回，歌词不会变成空白。
 */
import { i18n } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN, LOG_TAG } from './Constants';

const ID_HANS_TO_HANT: string = 'Hans-Hant';

let sInstance: S2tConverter | null = null;

export class S2tConverter {
  private trans: i18n.Transliterator | null = null;
  private unsupported: boolean = false;
  /** 同一句歌词会被反复转换（逐字高亮每帧），命中缓存直接返回 */
  private memo: Map<string, string> = new Map<string, string>();

  static getInstance(): S2tConverter {
    if (sInstance === null) {
      sInstance = new S2tConverter();
    }
    return sInstance;
  }

  /** 懒加载转写器；不支持时返回 null 并打一次日志 */
  private ensure(): i18n.Transliterator | null {
    if (this.trans !== null) {
      return this.trans;
    }
    if (this.unsupported) {
      return null;
    }
    try {
      this.trans = i18n.Transliterator.getInstance(ID_HANS_TO_HANT);
      return this.trans;
    } catch (e) {
      this.unsupported = true;
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'S2T unavailable: %{public}s', (e as Error).message);
      return null;
    }
  }

  /** 简体 → 繁体；空串与失败情况原样返回 */
  convert(text: string): string {
    if (text.length === 0) {
      return text;
    }
    const hit: string | undefined = this.memo.get(text);
    if (hit !== undefined) {
      return hit;
    }
    const t: i18n.Transliterator | null = this.ensure();
    if (t === null) {
      return text;
    }
    let out: string = text;
    try {
      out = t.transform(text);
    } catch (e) {
      out = text;
    }
    // 歌词行数有限，缓存上限 800 条足够，超出直接清空重建，避免无限增长
    if (this.memo.size > 800) {
      this.memo.clear();
    }
    this.memo.set(text, out);
    return out;
  }
}

/** 便捷入口：无论开关状态都安全调用 */
export function s2t(text: string, enabled: boolean): string {
  if (!enabled) {
    return text;
  }
  return S2tConverter.getInstance().convert(text);
}
