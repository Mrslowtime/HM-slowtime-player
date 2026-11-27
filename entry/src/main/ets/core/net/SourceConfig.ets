/**
 * 音源端点配置 —— 用户自行填写的兼容 HTTP 音源服务。
 *
 * 协议契约：
 *   GET {apiUrl}/url/{source}/{songId}/{quality}   （path 风格）
 *   GET {apiUrl}/url?source=&songId=&quality=      （query 风格）
 *   header: X-Request-Key: {apiKey}, User-Agent: slowtime-hm-mobile/2.6.0
 *   响应: { code: 0|200, url: "https://..." }，其余 code 为业务错误
 *
 * 用户约定（2026-11-15）：App 不内置任何公共音源服务。播放链接优先由「自定义源」里
 * 用户自行导入的 .js 脚本提供，未导入或取链失败时才回落到此处用户自己填写的服务地址。
 * App 本身不包含任何音源脚本、密钥或音乐内容。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { OnlineSource, ONLINE_SOURCES, Quality } from '../../config/AppConstants';
import { LOG_DOMAIN, LOG_TAG } from '../../common/Constants';
import { getAppContext } from '../../common/AppContext';

const PREF_NAME: string = 'slowtime_data';
const KEY_ENDPOINTS: string = 'source_endpoints_v1';
const KEY_ACTIVE: string = 'source_active_v1';

/** URL 路径风格：path = /url/kw/xxx/128k，query = /url?source=kw&songId=xxx&quality=128k */
export type UrlPathStyle = 'path' | 'query';

/**
 * 鉴权方式：
 *  - key    ：固定密钥，放 X-Request-Key 头（多数公共服务）
 *  - signed ：签名鉴权协议，无固定 key，请求头带 User-Agent: slowtime-hm/mobile、ver、tag 签名
 *             （tag 为单音质恒定的 hex 校验头，缺失会 404）
 *  - lx     ：旧版本对 signed 的叫法，仅作读取兼容，新配置一律写 signed
 */
export type SourceAuth = 'key' | 'signed' | 'lx';

/**
 * 旧版本曾内置过若干公共音源端点（flower / grass / ikun / huibq 及两个空模板）。
 * 现版本不再预置任何服务，升级时把用户偏好里残留的旧预设记录清掉。
 */
function isLegacyPreset(id: string): boolean {
  return id.startsWith('preset_');
}

export interface SourceEndpoint {
  id: string;
  name: string;
  apiUrl: string;
  apiKey: string;
  style: UrlPathStyle;
  /** 鉴权方式，缺省按 key 处理（兼容旧数据） */
  auth?: SourceAuth;
  /** 判定成功的 code（不同服务用 0 或 200） */
  successCodes: number[];
  /** 支持的音源列表 */
  sources: string[];
  /** 支持的音质（各源共用，按常见音源脚本的 MUSIC_QUALITY） */
  qualitys: string[];
  enabled: boolean;
}

let sInstance: SourceConfig | null = null;

export class SourceConfig {
  private endpoints: SourceEndpoint[] = [];
  private activeId: string = '';
  private store: preferences.Preferences | null = null;
  private loaded: boolean = false;

  static getInstance(): SourceConfig {
    if (sInstance === null) {
      sInstance = new SourceConfig();
    }
    return sInstance;
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
      hilog.error(LOG_DOMAIN, LOG_TAG, 'SourceConfig getPreferences failed');
    }
    return this.store;
  }

  async init(): Promise<void> {
    if (this.loaded) {
      return;
    }
    const store = await this.ensureStore();
    if (store !== null) {
      try {
        const raw = await store.get(KEY_ENDPOINTS, '');
        if (typeof raw === 'string' && raw.length > 0) {
          const arr: SourceEndpoint[] = JSON.parse(raw) as SourceEndpoint[];
          if (arr.length > 0) {
            this.endpoints = arr;
        // 兼容迁移：旧配置的 auth:'lx' 归一到 'signed'
        let migrated: boolean = false;
        for (const ep of this.endpoints) {
          if (ep.auth === 'lx') {
            ep.auth = 'signed';
            migrated = true;
          }
        }
        if (migrated) {
          await this.persist();
        }
          }
        }
        const active = await store.get(KEY_ACTIVE, '');
        this.activeId = typeof active === 'string' ? active : '';
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'SourceConfig load failed');
      }
    }
    // App 不再内置公共音源：升级时清掉旧版本写进偏好里的 preset_* 端点，
    // 用户自己填写的 custom_user / custom_* 一律保留。
    const kept: SourceEndpoint[] = [];
    for (const e of this.endpoints) {
      if (!isLegacyPreset(e.id)) {
        kept.push(e);
      }
    }
    let changed: boolean = kept.length !== this.endpoints.length;
    this.endpoints = kept;
    if (isLegacyPreset(this.activeId) ||
        (this.activeId.length > 0 && this.findEndpoint(this.activeId) === null)) {
      this.activeId = '';
      changed = true;
    }
    if (changed) {
      await this.persist();
    }
    this.loaded = true;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'SourceConfig loaded, %{public}d endpoints', this.endpoints.length);
  }

  findEndpoint(id: string): SourceEndpoint | null {
    for (const e of this.endpoints) {
      if (e.id === id) {
        return e;
      }
    }
    return null;
  }

  getEndpoints(): SourceEndpoint[] {
    return this.endpoints;
  }

  /** 当前启用的端点；未配置 apiUrl 返回 null（此时播放走离线兜底） */
  getActive(): SourceEndpoint | null {
    for (const e of this.endpoints) {
      if (e.id === this.activeId && e.enabled && e.apiUrl.length > 0) {
        return e;
      }
    }
    for (const e of this.endpoints) {
      if (e.enabled && e.apiUrl.length > 0) {
        return e;
      }
    }
    return null;
  }

  isConfigured(): boolean {
    return this.getActive() !== null;
  }

  /** 该端点是否支持某源某音质 */
  supports(e: SourceEndpoint, source: OnlineSource, quality: Quality): boolean {
    if (!e.sources.includes(source)) {
      return false;
    }
    return e.qualitys.includes(quality);
  }

  async setEndpoints(list: SourceEndpoint[]): Promise<void> {
    this.endpoints = list;
    await this.persist();
  }

  async setActive(id: string): Promise<void> {
    this.activeId = id;
    await this.persist();
  }

  /** 当前生效音源端点 id（公开只读，供 UI 跟随配置层回落） */
  getActiveId(): string {
    return this.activeId;
  }

  /** 快速配置：设置页填入地址/密钥后调用，落到独立「自定义音源」端点并设为当前 */
  async configure(apiUrl: string, apiKey: string, style: UrlPathStyle): Promise<void> {
    let url: string = apiUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    let custom: SourceEndpoint | null = this.findEndpoint('custom_user');
    if (custom === null) {
      custom = {
        id: 'custom_user',
        name: '自定义音源',
        apiUrl: '',
        apiKey: '',
        style: 'path',
        auth: 'key',
        successCodes: [0, 200],
        sources: ONLINE_SOURCES.slice(),
        qualitys: ['128k', '320k'],
        enabled: false,
      };
      this.endpoints.push(custom);
    }
    custom.apiUrl = url;
    custom.apiKey = apiKey.trim();
    custom.style = style;
    custom.auth = 'key';
    custom.enabled = url.length > 0;
    if (url.length > 0) {
      this.activeId = 'custom_user';
    }
    await this.persist();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'SourceConfig configured: %{public}s', url);
  }

  private async persist(): Promise<void> {
    const store = await this.ensureStore();
    if (store === null) {
      return;
    }
    try {
      await store.put(KEY_ENDPOINTS, JSON.stringify(this.endpoints));
      await store.put(KEY_ACTIVE, this.activeId);
      await store.flush();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'SourceConfig persist failed');
    }
  }
}
