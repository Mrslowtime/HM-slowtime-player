/**
 * 设置持久化 —— 按协议 + plugins/storage.ts。
 * 鸿蒙侧用 @kit.ArkData 的 preferences（对应 AsyncStorage），
 * 同样只接受 string / number / boolean / null 原始类型。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SettingValue, createDefaultSetting } from '../config/DefaultSetting';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';
import { stateEvent, StateEvents } from './EventBus';
import { getAppContext } from '../common/AppContext';

const PREF_NAME: string = 'slowtime_setting';
/** 备份恢复进来的「默认表之外」key 列表：init 时随白名单一并载入，避免重启丢失（审查 B-06） */
const EXTRA_KEYS_KEY: string = '__extra_keys__';

let sInstance: SettingStore | null = null;

export class SettingStore {
  private settings: Map<string, SettingValue> = createDefaultSetting();
  private store: preferences.Preferences | null = null;
  private initialized: boolean = false;

  static getInstance(): SettingStore {
    if (sInstance === null) {
      sInstance = new SettingStore();
    }
    return sInstance;
  }

  /** 从 preferences 载入，缺失项用协议默认值补齐（按 mergeSetting） */
  async init(): Promise<void> {
    if (this.initialized) {
      return;
    }
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx === null) {
      // context 未就绪时不锁死 initialized，否则设置永久停留在默认值、此后
      // set() 只改内存不落盘（审查 B-12）。保留未初始化状态，等后续调用重试。
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'SettingStore: context 未就绪，稍后重试');
      return;
    }
    try {
      this.store = await preferences.getPreferences(ctx, PREF_NAME);
      const keys: string[] = [];
      this.settings.forEach((_v: SettingValue, k: string): void => {
        keys.push(k);
      });
      for (const key of keys) {
        const raw = await this.store.get(key, undefined);
        if (raw === undefined || raw === null) {
          continue;
        }
        if (typeof raw === 'string' || typeof raw === 'number' || typeof raw === 'boolean') {
          this.settings.set(key, raw as SettingValue);
        }
      }
      // 载入备份恢复写入的额外 key（默认表之外），否则这些 key 重启后读不回来
      const extraVal = await this.store.get(EXTRA_KEYS_KEY, '');
      const rawExtra: string = typeof extraVal === 'string' ? extraVal : '';
      if (rawExtra.length > 0) {
        const extraKeys: string[] = rawExtra.split('|');
        for (const key of extraKeys) {
          if (key.length === 0 || this.settings.has(key)) {
            continue;
          }
          const raw = await this.store.get(key, undefined);
          if (typeof raw === 'string' || typeof raw === 'number' || typeof raw === 'boolean') {
            this.settings.set(key, raw as SettingValue);
          }
        }
      }
      hilog.info(LOG_DOMAIN, LOG_TAG, 'SettingStore loaded, %{public}d keys', keys.length);
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'SettingStore init failed, use defaults');
    }
    this.initialized = true;
  }

  get(key: string): SettingValue {
    const v = this.settings.get(key);
    return v === undefined ? null : v;
  }

  getString(key: string, def: string = ''): string {
    const v = this.settings.get(key);
    return typeof v === 'string' ? v : def;
  }

  getNumber(key: string, def: number = 0): number {
    const v = this.settings.get(key);
    return typeof v === 'number' ? v : def;
  }

  getBoolean(key: string, def: boolean = false): boolean {
    const v = this.settings.get(key);
    return typeof v === 'boolean' ? v : def;
  }

  /** 更新设置并广播 configUpdated（按 updateSetting） */
  async set(key: string, value: SettingValue): Promise<void> {
    this.settings.set(key, value);
    if (this.store !== null) {
      try {
        if (value === null) {
          await this.store.delete(key);
        } else {
          await this.store.put(key, value);
        }
        await this.store.flush();
      } catch (e) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'SettingStore set failed: %{public}s', key);
      }
    }
    stateEvent().emit(StateEvents.CONFIG_UPDATED);
  }

  /**
   * 批量写入（备份恢复用）：一次 flush + 一次广播，避免 81 项逐个 put/flush
   * 造成密集磁盘 I/O 与 UI 反复刷新（审查 P-04）。默认表之外的 key 记入
   * extra_keys 列表，保证重启后仍能载入（审查 B-06）。
   */
  async setMany(items: Map<string, SettingValue>): Promise<void> {
    const keys: string[] = [];
    items.forEach((_v: SettingValue, k: string): void => {
      keys.push(k);
    });
    for (const key of keys) {
      const value = items.get(key);
      if (value !== undefined) {
        this.settings.set(key, value);
      }
    }
    if (this.store !== null) {
      try {
        // 收集默认表之外的 key 并持久化列表
        const defaults: Map<string, SettingValue> = createDefaultSetting();
        const extras: string[] = [];
        for (const key of keys) {
          if (!defaults.has(key)) {
            extras.push(key);
          }
        }
        // 合并之前已有的 extra keys
        const extraVal = await this.store.get(EXTRA_KEYS_KEY, '');
        const rawExtra: string = typeof extraVal === 'string' ? extraVal : '';
        if (rawExtra.length > 0) {
          for (const k of rawExtra.split('|')) {
            if (k.length > 0 && extras.indexOf(k) < 0) {
              extras.push(k);
            }
          }
        }
        for (const key of keys) {
          const value = items.get(key);
          if (value === undefined) {
            continue;
          }
          if (value === null) {
            await this.store.delete(key);
          } else {
            await this.store.put(key, value);
          }
        }
        await this.store.put(EXTRA_KEYS_KEY, extras.join('|'));
        await this.store.flush();
      } catch (e) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'SettingStore setMany failed');
      }
    }
    stateEvent().emit(StateEvents.CONFIG_UPDATED);
  }

  /** 全部重置为协议默认值 */
  async reset(): Promise<void> {
    this.settings = createDefaultSetting();
    if (this.store !== null) {
      try {
        await this.store.clear();
        await this.store.flush();
      } catch (e) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'SettingStore reset failed');
      }
    }
    stateEvent().emit(StateEvents.CONFIG_UPDATED);
  }

  /** 导出所有设置（备份/同步用） */
  exportAll(): Map<string, SettingValue> {
    const m = new Map<string, SettingValue>();
    this.settings.forEach((v: SettingValue, k: string): void => {
      m.set(k, v);
    });
    return m;
  }
}
