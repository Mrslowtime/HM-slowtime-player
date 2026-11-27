import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UserListInfo } from '../model/MusicTypes';
import { getAppContext } from '../common/AppContext';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

const PREF_NAME: string = 'slowtime_data';
const KEY_LIST_ORDER: string = 'my_list_order_v1';

/**
 * 「我的列表」显示顺序的持久化（只存 id 顺序，不存列表内容）。
 * 列表数据本身目前仍是内存态（由 initDefaultLists 重建 4 个默认列表），
 * 因此这里只负责「哪些列表排前面」：重启后对默认列表依旧生效，
 * 已经不存在的自建列表 id 会被自动忽略，不会产生幽灵列表。
 */
export class ListOrderStore {
  private static _inst: ListOrderStore | null = null;
  private store: preferences.Preferences | null = null;
  private loaded: boolean = false;
  private ids: string[] = [];

  static getInstance(): ListOrderStore {
    if (ListOrderStore._inst === null) {
      ListOrderStore._inst = new ListOrderStore();
    }
    return ListOrderStore._inst;
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
      hilog.error(LOG_DOMAIN, LOG_TAG, 'ListOrderStore: getPreferences failed');
    }
    return this.store;
  }

  /** 启动时异步载入（必须在 ListManager.initDefaultLists 之前 await） */
  async ensure(): Promise<void> {
    if (this.loaded) {
      return;
    }
    const store = await this.ensureStore();
    if (store !== null) {
      try {
        const raw = await store.get(KEY_LIST_ORDER, '') as string;
        if (typeof raw === 'string' && raw.length > 0) {
          const arr = JSON.parse(raw) as string[];
          const out: string[] = [];
          for (const id of arr) {
            if (typeof id === 'string' && !out.includes(id)) {
              out.push(id);
            }
          }
          this.ids = out;
        }
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'ListOrderStore: load failed, use default');
      }
    }
    this.loaded = true;
  }

  /** 同步应用已保存顺序：保存过的按序排前，新增列表按原顺序追加 */
  applyOrder(lists: UserListInfo[]): UserListInfo[] {
    if (this.ids.length === 0) {
      return lists;
    }
    const rank: Map<string, number> = new Map();
    for (let i = 0; i < this.ids.length; i++) {
      rank.set(this.ids[i], i);
    }
    const known: UserListInfo[] = [];
    const rest: UserListInfo[] = [];
    for (const u of lists) {
      if (rank.has(u.id)) {
        known.push(u);
      } else {
        rest.push(u);
      }
    }
    known.sort((a: UserListInfo, b: UserListInfo): number =>
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
      await store.put(KEY_LIST_ORDER, JSON.stringify(ids));
      await store.flush();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'ListOrderStore: persist failed');
    }
  }
}
