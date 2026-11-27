import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { OnlineSource, ONLINE_SOURCES } from '../config/AppConstants';
import { getAppContext } from '../common/AppContext';

const PREF_NAME: string = 'slowtime_data';
const KEY_ORDER: string = 'source_order_v1';
const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'SourceOrder';

/**
 * 平台来源（酷我 / 酷狗 / QQ / 网易云 / 咪咕）在平台下拉里的展示顺序。
 * 只读取持久化顺序；平台下拉已恢复为纯选择器，不再提供编辑态/抖动态。
 */
export class SourceOrderManager {
  private static _inst: SourceOrderManager | null = null;
  private store: preferences.Preferences | null = null;
  private loaded: boolean = false;
  private order: OnlineSource[] = ONLINE_SOURCES.slice();

  static getInstance(): SourceOrderManager {
    if (SourceOrderManager._inst === null) {
      SourceOrderManager._inst = new SourceOrderManager();
    }
    return SourceOrderManager._inst;
  }

  private async ensureStore(): Promise<preferences.Preferences | null> {
    if (this.store !== null) {
      return this.store;
    }
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx === null) {
      return null;
    }
    try {
      this.store = await preferences.getPreferences(ctx, PREF_NAME);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'getPreferences failed');
    }
    return this.store;
  }

  /** 读取已持久化的顺序；首次或数据非法时回落到 ONLINE_SOURCES 默认排列，并补齐缺失的源 */
  async ensure(): Promise<void> {
    if (this.loaded) {
      return;
    }
    const store = await this.ensureStore();
    if (store !== null) {
      try {
        const raw = await store.get(KEY_ORDER, '') as string;
        if (typeof raw === 'string' && raw.length > 0) {
          const arr = JSON.parse(raw) as string[];
          const set: Set<string> = new Set<string>(ONLINE_SOURCES);
          const valid: OnlineSource[] = [];
          for (const s of arr) {
            if (set.has(s) && !valid.includes(s as OnlineSource)) {
              valid.push(s as OnlineSource);
            }
          }
          // 补齐新增/缺失的源，避免升级后顺序丢失
          for (const s of ONLINE_SOURCES) {
            if (!valid.includes(s)) {
              valid.push(s);
            }
          }
          this.order = valid;
        }
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'load failed, use default order');
      }
    }
    this.loaded = true;
  }

  getOrder(): OnlineSource[] {
    return this.order.slice();
  }

  async setOrder(arr: OnlineSource[]): Promise<void> {
    this.order = arr.slice();
    const store = await this.ensureStore();
    if (store === null) {
      return;
    }
    try {
      await store.put(KEY_ORDER, JSON.stringify(arr));
      await store.flush();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'persist failed');
    }
  }
}
