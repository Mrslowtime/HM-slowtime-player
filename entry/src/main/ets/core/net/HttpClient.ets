/**
 * 通用 HTTP 客户端 —— 按协议 的 httpFetch。
 *
 * 差异（鸿蒙化）：
 * - 底层用 @ohos.net.http 而非 global.fetch（ArkTS 无 fetch 全局）。
 * - 统一把 http:// 端点升级为 https://，避免明文流量限制。
 * - 超时 15s、默认 UA / Accept、按源配置重试次数、自动 JSON 解析。
 *
 * 附带 Json 安全读取工具：ArkTS 是静态强类型，JSON.parse 结果不能直接点属性，
 * 各家音源响应结构又不一致，统一走这里避免大量类型断言散落业务代码里。
 */
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { LOG_DOMAIN, LOG_TAG } from '../../common/Constants';

/** 协议 request.js 的默认 UA */
export const DEFAULT_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/69.0.3497.100 Safari/537.36';

export interface HttpOptions {
  method: 'GET' | 'POST';
  headers: Record<string, string>;
  body: string;
  timeoutMs: number;
  retries: number;
  /** 保留原始 http://（部分第三方音源只监听明文端口，升级 https 会直接连不上） */
  allowHttp?: boolean;
}

export interface HttpResult {
  ok: boolean;
  statusCode: number;
  text: string;
  json: Object | null;
  error: string;
}

export function makeHttpOptions(): HttpOptions {
  return {
    method: 'GET',
    headers: {},
    body: '',
    timeoutMs: 15000,
    retries: 0,
  };
}

/** 安全读取 JSON 字段（不抛异常，缺失返回默认值） */
export class Json {
  static toStr(v: Object, def: string): string {
    if (v === undefined || v === null) {
      return def;
    }
    if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
      return v.toString();
    }
    return def;
  }

  static str(obj: Object | null, key: string, def: string = ''): string {
    if (obj === null) {
      return def;
    }
    const rec: Record<string, Object> = obj as Record<string, Object>;
    const v: Object = rec[key];
    if (v === undefined || v === null) {
      return def;
    }
    return Json.toStr(v, def);
  }

  static num(obj: Object | null, key: string, def: number = 0): number {
    if (obj === null) {
      return def;
    }
    const rec: Record<string, Object> = obj as Record<string, Object>;
    const v: Object = rec[key];
    if (v === undefined || v === null) {
      return def;
    }
    if (typeof v === 'number') {
      return Number(v);
    }
    if (typeof v === 'string') {
      const n: number = Number(v.toString());
      return isNaN(n) ? def : n;
    }
    return def;
  }

  static obj(obj: Object | null, key: string): Object | null {
    if (obj === null) {
      return null;
    }
    const rec: Record<string, Object> = obj as Record<string, Object>;
    const v: Object = rec[key];
    if (v === undefined || v === null || typeof v !== 'object') {
      return null;
    }
    return v as Object;
  }

  static arr(obj: Object | null, key: string): Object[] {
    if (obj === null) {
      return [];
    }
    const rec: Record<string, Object> = obj as Record<string, Object>;
    const v: Object = rec[key];
    if (v === undefined || v === null || !Array.isArray(v)) {
      return [];
    }
    return v as Object[];
  }

  /** 直接把数组自身当 Object[] 用（很多音源返回顶层数组） */
  static asArr(v: Object | null): Object[] {
    if (v === null || !Array.isArray(v)) {
      return [];
    }
    return v as Object[];
  }

  /** 解析文本，失败返回 null */
  static parse(text: string): Object | null {
    if (text.length === 0) {
      return null;
    }
    try {
      return JSON.parse(text) as Object;
    } catch (e) {
      return null;
    }
  }
}

/**
 * 把 http:// 统一升级为 https://。
 * 例外：酷狗官方歌单页 www2.kugou.kugou.com 的 https 证书不被信任
 * （PC curl 报 SSL certificate problem，http 端点实测 200 / 894KB 正常），
 * 该 host 保留明文 http，其余一律强制加密。
 */
export function secureUrl(url: string): string {
  if (url.startsWith('http://')) {
    if (url.startsWith('http://www2.kugou.kugou.com/')) {
      return url;
    }
    return 'https://' + url.substring(7);
  }
  return url;
}

export function encodeQuery(s: string): string {
  return encodeURIComponent(s);
}

export class HttpClient {
  /** 发一次请求（含重试）。返回 HttpResult，永不使用异常向外抛。 */
  static async request(rawUrl: string, opts: HttpOptions): Promise<HttpResult> {
    const url: string = opts.allowHttp === true ? rawUrl : secureUrl(rawUrl);
    let lastError: string = 'unknown error';
    let lastStatus: number = 0;
    const attempts: number = opts.retries + 1;

    for (let i = 0; i < attempts; i++) {
      const req: http.HttpRequest = http.createHttp();
      const headers: Record<string, string> = {
        'User-Agent': DEFAULT_UA,
        'Accept': 'application/json',
      };
      const extra: Record<string, string> = opts.headers;
      const keys: string[] = Object.keys(extra);
      for (const k of keys) {
        headers[k] = extra[k];
      }

      const options: http.HttpRequestOptions = {
        method: opts.method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: opts.timeoutMs,
        readTimeout: opts.timeoutMs,
        usingCache: false,
      };
      if (opts.method === 'POST' && opts.body.length > 0) {
        options.extraData = opts.body;
      }

      try {
        const resp: http.HttpResponse = await req.request(url, options);
        const text: string = typeof resp.result === 'string' ? resp.result : Json.toStr(resp.result as Object, '');
        const code: number = Number(resp.responseCode);
        req.destroy();
        if (code >= 200 && code < 300) {
          // 只在成功响应才解析 JSON：失败响应（如 HTML 错误页）不该白白 parse 再丢弃
          const parsed: Object | null = Json.parse(text);
          return { ok: true, statusCode: code, text, json: parsed, error: '' };
        }
        lastError = 'HTTP ' + code.toString();
        lastStatus = code;
        // 限流/服务端错误不要立刻重发，先退避+抖动，避免把轻度限流打成硬封禁
        if (i < attempts - 1) {
          const waitMs: number = (code === 429 || code === 503 ? 900 : 250) * (i + 1)
            + Math.floor(Math.random() * 200);
          await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, waitMs); });
        }
      } catch (e) {
        const err = e as Error;
        lastError = err.message !== undefined ? err.message : 'request failed';
        try {
          req.destroy();
        } catch (e2) {
          hilog.warn(LOG_DOMAIN, LOG_TAG, 'http destroy failed');
        }
        if (i < attempts - 1) {
          const waitMs: number = 300 * (i + 1) + Math.floor(Math.random() * 200);
          await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, waitMs); });
        }
      }
    }
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'http failed: %{public}s', lastError);
    return { ok: false, statusCode: lastStatus, text: '', json: null, error: lastError };
  }

  static async get(url: string, headers: Record<string, string> = {}, retries: number = 0,
    allowHttp: boolean = false): Promise<HttpResult> {
    const o: HttpOptions = makeHttpOptions();
    o.method = 'GET';
    o.headers = headers;
    o.retries = retries;
    o.allowHttp = allowHttp;
    return await HttpClient.request(url, o);
  }

  static async post(url: string, body: string, headers: Record<string, string> = {},
    retries: number = 0): Promise<HttpResult> {
    const o: HttpOptions = makeHttpOptions();
    o.method = 'POST';
    o.headers = headers;
    o.body = body;
    o.retries = retries;
    return await HttpClient.request(url, o);
  }

  static async getJson(url: string, headers: Record<string, string> = {},
    retries: number = 0): Promise<Object | null> {
    const r: HttpResult = await HttpClient.get(url, headers, retries);
    return r.ok ? r.json : null;
  }

  static async getText(url: string, headers: Record<string, string> = {},
    retries: number = 0): Promise<string> {
    const r: HttpResult = await HttpClient.get(url, headers, retries);
    return r.ok ? r.text : '';
  }
}

/** HTML 实体解码（常用 HTML 实体子集） */
export function decodeName(s: string): string {
  let out: string = s;
  out = out.replace(/&amp;/g, '&');
  out = out.replace(/&lt;/g, '<');
  out = out.replace(/&gt;/g, '>');
  out = out.replace(/&quot;/g, '"');
  out = out.replace(/&#39;/g, "'");
  out = out.replace(/&apos;/g, "'");
  out = out.replace(/&nbsp;/g, ' ');
  out = out.replace(/&#(\d+);/g, (_m: string, d: string): string => {
    return String.fromCharCode(Number(d));
  });
  return out;
}

/** 秒 → mm:ss（按秒数格式化约定） */
export function formatPlayTime(seconds: number): string {
  const s: number = Math.max(0, Math.floor(seconds));
  const m: number = Math.floor(s / 60);
  const ss: number = s % 60;
  return (m < 10 ? '0' : '') + m.toString() + ':' + (ss < 10 ? '0' : '') + ss.toString();
}

/** 歌手名分隔（协议 kw 用 & → 、） */
export function formatSinger(s: string): string {
  return s.replace(/&/g, '、').replace(/\s*,\s*/g, '、').trim();
}

/** base64 → UTF-8 文本 */
export function base64ToUtf8(b64: string): string {
  try {
    const helper = new util.Base64Helper();
    const bytes: Uint8Array = helper.decodeSync(b64);
    const decoder = new util.TextDecoder('utf-8');
    return decoder.decodeToString(bytes);
  } catch (e) {
    return '';
  }
}
