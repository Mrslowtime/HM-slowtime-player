/**
 * 「本地音乐」分类（歌曲 / 文件夹 / 歌手）的展示顺序持久化。
 * 交互与「我的列表」一致：前 4 个常驻标签栏，可长按进入管理态拖动调序，顺序重启后保留。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getAppContext } from '../common/AppContext';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

export interface LocalCategoryItem {
  id: string;
  name: string;
}

export const DEFAULT_LOCAL_CATEGORIES: LocalCategoryItem[] = [
  { id: 'songs', name: '歌曲' },
  { id: 'folders', name: '文件夹' },
  { id: 'artists', name: '歌手' },
];

const PREF_NAME: string = 'slowtime_data';
const KEY_CATEGORY_ORDER: string = 'local_category_order_v1';

export class LocalCategoryOrder {
  private static _inst: LocalCategoryOrder | null = null;
  private store: preferences.Preferences | null = null;
  private loaded: boolean = false;
  private ids: string[] = [];

  static getInstance(): LocalCategoryOrder {
    if (LocalCategoryOrder._inst === null) {
      LocalCategoryOrder._inst = new LocalCategoryOrder();
    }
    return LocalCategoryOrder._inst;
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
      hilog.error(LOG_DOMAIN, LOG_TAG, 'LocalCategoryOrder: getPreferences failed');
    }
    return this.store;
  }

  async ensure(): Promise<void> {
    if (this.loaded) {
      return;
    }
    const store = await this.ensureStore();
    if (store !== null) {
      try {
        const raw = await store.get(KEY_CATEGORY_ORDER, '') as string;
        if (typeof raw === 'string' && raw.length > 0) {
          const arr = JSON.parse(raw) as string[];
          const valid: string[] = [];
          const known: Set<string> = new Set(DEFAULT_LOCAL_CATEGORIES.map((c: LocalCategoryItem): string => c.id));
          for (const id of arr) {
            if (typeof id === 'string' && known.has(id) && !valid.includes(id)) {
              valid.push(id);
            }
          }
          // 补齐后续新增的分类，避免升级后分类消失
          for (const c of DEFAULT_LOCAL_CATEGORIES) {
            if (!valid.includes(c.id)) {
              valid.push(c.id);
            }
          }
          this.ids = valid;
        }
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'LocalCategoryOrder: load failed');
      }
    }
    this.loaded = true;
  }

  /** 保存过的按序排前，未保存过的按默认顺序追加 */
  applyOrder(items: LocalCategoryItem[]): LocalCategoryItem[] {
    if (this.ids.length === 0) {
      return items.slice();
    }
    const rank: Map<string, number> = new Map();
    for (let i = 0; i < this.ids.length; i++) {
      rank.set(this.ids[i], i);
    }
    const known: LocalCategoryItem[] = [];
    const rest: LocalCategoryItem[] = [];
    for (const c of items) {
      if (rank.has(c.id)) {
        known.push(c);
      } else {
        rest.push(c);
      }
    }
    known.sort((a: LocalCategoryItem, b: LocalCategoryItem): number =>
      (rank.get(a.id) ?? 0) - (rank.get(b.id) ?? 0));
    return known.concat(rest);
  }

  async save(ids: string[]): Promise<void> {
    this.ids = ids.slice();
    const store = await this.ensureStore();
    if (store === null) {
      return;
    }
    try {
      await store.put(KEY_CATEGORY_ORDER, JSON.stringify(ids));
      await store.flush();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'LocalCategoryOrder: persist failed');
    }
  }
}
