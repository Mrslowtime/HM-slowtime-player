/**
 * 自定义音源脚本仓库：管理用户导入的脚本元数据与启用状态。
 *
 * 音源脚本协议格式：
 *   - 脚本是纯 JS 文本，文件开头第一个块注释用 @name/@description/@version/@author/@homepage 声明元数据
 *   - 本地导入不限扩展名，按文件开头的 @name 块注释识别；在线导入是普通 http(s) URL，
 *     响应体即脚本文本（无加密、无多脚本分隔符）
 *   - 每条记录带 enabled（同时只有一个生效）与 allowShowUpdateAlert（允许显示更新弹窗）
 *
 * App 不内置任何公共音源脚本或下载地址，全部由用户自行导入。
 *
 * 鸿蒙化的存储：脚本正文可达数百 KB，preferences 单条 value 装不下，因此
 *   元数据 → preferences('slowtime_data' / 'source_scripts_v1')
 *   正文   → 应用沙箱 filesDir/source_scripts/<id>.js（零系统权限）
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getAppContext } from '../../common/AppContext';
import { LOG_DOMAIN, LOG_TAG } from '../../common/Constants';

const PREF_NAME: string = 'slowtime_data';
const KEY_SCRIPTS: string = 'source_scripts_v1';
/** 与桌面版 / 移动版一致：在线导入脚本最大 9,000,000 字符 */
export const MAX_SCRIPT_CHARS: number = 9000000;


/**
 * 在线导入的候选地址：raw.githubusercontent.com 在国内多数网络直接不可达，
 * @ohos.net.http 会抛「Internal error」。因此对 GitHub raw 链接自动派生几个
 * 已实测可达的镜像并排在前面，原地址留作最后兜底；用户填的其它地址原样尊重。
 */
export function candidateScriptUrls(url: string): string[] {
  const u: string = url.trim();
  const list: string[] = [];
  const m: RegExpExecArray | null =
    /^https:\/\/raw\.githubusercontent\.com\/([^/]+)\/([^/]+)\/(main|master)\/(.+)$/.exec(u);
  if (m !== null) {
    const owner: string = m[1];
    const repo: string = m[2];
    const branch: string = m[3];
    const rest: string = m[4];
    list.push('https://fastly.jsdelivr.net/gh/' + owner + '/' + repo + '@' + branch + '/' + rest);
    list.push('https://gcore.jsdelivr.net/gh/' + owner + '/' + repo + '@' + branch + '/' + rest);
    list.push('https://ghproxy.net/' + u);
  }
  list.push(u);
  return list;
}

/** 本地文件选择导入的结果（detail 用于把系统异常原话显示给用户，便于定位） */
export interface ImportPickResult {
  status: string; // 'ok' | 'cancel' | 'invalid' | 'error'
  detail: string;
}

export interface CustomScriptMeta {
  id: string;
  name: string;
  description: string;
  version: string;
  author: string;
  homepage: string;
  /** 脚本正文在沙箱里的文件名 */
  fileName: string;
  /** 导入来源：在线 URL 或本地文件名，空表示来源不明 */
  from: string;
  importedAt: string;
  size: number;
  /** 同一时刻只有一个自定义源生效（单选） */
  enabled: boolean;
  /** 脚本 send(updateAlert) 时是否允许弹窗 */
  allowShowUpdateAlert: boolean;
}

export interface ScriptHeaderInfo {
  name: string;
  description: string;
  version: string;
  author: string;
  homepage: string;
}

/** 元数据字段长度上限 */
function buildInfoLimit(): Map<string, number> {
  const m: Map<string, number> = new Map<string, number>();
  m.set('name', 24);
  m.set('description', 36);
  m.set('author', 56);
  m.set('homepage', 1024);
  m.set('version', 36);
  return m;
}
const INFO_LIMIT: Map<string, number> = buildInfoLimit();

/**
 * 解析脚本开头第一个块注释里的 @xxx 元数据（不执行脚本）。
 * 头部注释缺失即视为无效自定义源文件。
 */
export function parseScriptHeader(script: string): ScriptHeaderInfo | null {
  // 微信/QQ 转存、Windows 记事本另存常带 UTF-8 BOM 或前导空行，先剥掉再找头部注释
  const cleaned: string = script.replace(/^\uFEFF/, '').replace(/^\s+/, '');
  const m: RegExpExecArray | null = /^\/\*[\s\S]+?\*\//.exec(cleaned);
  if (m === null) {
    return null;
  }
  const info: ScriptHeaderInfo = {
    name: '', description: '', version: '', author: '', homepage: '',
  };
  const lines: string[] = m[0].split(/\r?\n/);
  for (const line of lines) {
    const r: RegExpExecArray | null = /^\s?\*\s?@(\w+)\s(.+)$/.exec(line);
    if (r === null) {
      continue;
    }
    const key: string = r[1];
    const limit: number | undefined = INFO_LIMIT.get(key);
    if (limit === undefined) {
      continue;
    }
    let value: string = r[2].trim();
    if (value.length > limit) {
      value = value.substring(0, limit) + '...';
    }
    if (key === 'name') {
      info.name = value;
    } else if (key === 'description') {
      info.description = value;
    } else if (key === 'version') {
      info.version = value;
    } else if (key === 'author') {
      info.author = value;
    } else if (key === 'homepage') {
      info.homepage = value;
    }
  }
  if (info.name.length === 0) {
    info.name = 'user_api_' + new Date().toLocaleString();
  }
  return info;
}

function scriptDir(): string {
  const ctx: common.UIAbilityContext | null = getAppContext();
  if (ctx === null) {
    return '';
  }
  return ctx.filesDir + '/source_scripts';
}

function stripBom(text: string): string {
  return text.length > 0 && text.charCodeAt(0) === 0xFEFF ? text.substring(1) : text;
}

/**
 * 读文本文件。path 既可是沙箱绝对路径，也可是系统文件选择器返回的 uri。
 *
 * 踩坑：对 picker uri 打开的 fd 直接 statSync/readSync，在部分机型上会抛
 * 「Invalid argument」导致「读取文件失败」。项目里 LocalMusicScanner.importFiles
 * 已验证的稳妥路径是「先 copyFileSync 到沙箱，再按路径读」，这里作为主路径；
 * 直接按 fd 读作为快速路径，失败自动回落。
 */
function readTextFile(pathOrUri: string): string {
  const src = fs.openSync(pathOrUri, fs.OpenMode.READ_ONLY);
  try {
    // 快速路径只对沙箱绝对路径使用；uri 一律走复制路径，
    // 避免 statSync(uri) 在部分机型返回不真实的 size 导致正文被截断。
    const isUri: boolean = pathOrUri.indexOf('://') >= 0;
    if (!isUri) {
      try {
        const st = fs.statSync(pathOrUri);
        if (st.size > 0) {
          const buf = new ArrayBuffer(st.size);
          fs.readSync(src.fd, buf, { offset: 0, length: st.size });
          const text: string = stripBom(new util.TextDecoder().decodeToString(new Uint8Array(buf)));
          if (text.length > 0) {
            return text;
          }
        }
      } catch (e) {
        // 落到复制路径
      }
    }

    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx === null) {
      return '';
    }
    const tmp: string = ctx.filesDir + '/_lx_pick_' + Date.now().toString() + '.tmp';
    const dst = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.copyFileSync(src.fd, dst.fd);
    } finally {
      fs.closeSync(dst);
    }
    try {
      const f2 = fs.openSync(tmp, fs.OpenMode.READ_ONLY);
      try {
        const st2 = fs.statSync(tmp);
        if (st2.size === 0) {
          return '';
        }
        const buf2 = new ArrayBuffer(st2.size);
        fs.readSync(f2.fd, buf2, { offset: 0, length: st2.size });
        return stripBom(new util.TextDecoder().decodeToString(new Uint8Array(buf2)));
      } finally {
        fs.closeSync(f2);
      }
    } finally {
      try {
        fs.unlinkSync(tmp);
      } catch (e) {
        // 临时文件清理失败不影响导入
      }
    }
  } finally {
    fs.closeSync(src);
  }
}

/**
 * 写脚本正文。
 *
 * 关键：SDK 声明是 writeSync(fd, buffer: ArrayBuffer | string)，**不接受 Uint8Array**。
 * 之前传 new Uint8Array(...) 在真机上直接抛「Invalid argument」，导致在线/本地/内置
 * 示例三条导入路径全部在最后一步失败。这里显式构造 ArrayBuffer（UTF-8 编码），
 * 与 readTextFile 的 TextDecoder 对称。
 */
function writeTextFile(path: string, text: string): void {
  const f = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  try {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    const buf: ArrayBuffer = new ArrayBuffer(bytes.byteLength);
    new Uint8Array(buf).set(bytes);
    fs.writeSync(f.fd, buf);
  } finally {
    fs.closeSync(f);
  }
}

let sInstance: CustomScriptStore | null = null;

export class CustomScriptStore {
  private scripts: CustomScriptMeta[] = [];
  private store: preferences.Preferences | null = null;
  private loaded: boolean = false;
  /** 最近一次导入失败的具体原因，供设置弹窗显示（避免只给「无效文件」这种没法排查的提示） */
  private lastError: string = '';

  getLastError(): string {
    return this.lastError;
  }

  static getInstance(): CustomScriptStore {
    if (sInstance === null) {
      sInstance = new CustomScriptStore();
    }
    return sInstance;
  }

  async init(): Promise<void> {
    if (this.loaded) {
      return;
    }
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx !== null) {
      try {
        this.store = await preferences.getPreferences(ctx, PREF_NAME);
        const raw = await this.store.get(KEY_SCRIPTS, '');
        if (typeof raw === 'string' && raw.length > 0) {
          const arr: CustomScriptMeta[] = JSON.parse(raw) as CustomScriptMeta[];
          this.scripts = arr;
        }
      } catch (e) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'CustomScriptStore load failed');
      }
    }
    // 清理沙箱里已不存在正文的陈旧记录
    const valid: CustomScriptMeta[] = [];
    let changed: boolean = false;
    for (const s of this.scripts) {
      // 用 openSync 试探，比 accessSync 稳：部分机型 accessSync 对已存在文件也会抛
      let exists: boolean = false;
      try {
        const probe = fs.openSync(scriptDir() + '/' + s.fileName, fs.OpenMode.READ_ONLY);
        fs.closeSync(probe);
        exists = true;
      } catch (e) {
        exists = false;
      }
      if (exists) {
        valid.push(s);
      } else {
        changed = true;
      }
    }
    this.scripts = valid;
    // 保证至多一个生效
    let seen: boolean = false;
    for (const s of this.scripts) {
      if (s.enabled) {
        if (seen) {
          s.enabled = false;
          changed = true;
        }
        seen = true;
      }
    }
    if (changed) {
      await this.persist();
    }
    this.loaded = true;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'CustomScriptStore loaded, %{public}d scripts', this.scripts.length);
  }


  private async persist(): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.put(KEY_SCRIPTS, JSON.stringify(this.scripts));
      await this.store.flush();
    } catch (e) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'CustomScriptStore persist failed');
    }
  }

  list(): CustomScriptMeta[] {
    return this.scripts.slice();
  }

  get(id: string): CustomScriptMeta | null {
    for (const s of this.scripts) {
      if (s.id === id) {
        return s;
      }
    }
    return null;
  }

  getActive(): CustomScriptMeta | null {
    for (const s of this.scripts) {
      if (s.enabled) {
        return s;
      }
    }
    return null;
  }

  /** 读取脚本正文（失败返回空串，调用方据此回落到 HTTP 音源服务） */
  readScript(id: string): string {
    const meta: CustomScriptMeta | null = this.get(id);
    if (meta === null) {
      return '';
    }
    try {
      return readTextFile(scriptDir() + '/' + meta.fileName);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'read custom script failed: %{public}s', id);
      return '';
    }
  }

  /** 导入脚本正文：同名 + 同版本视为更新覆盖，避免重复导入堆积 */
  async importScript(text: string, from: string): Promise<CustomScriptMeta | null> {
    this.lastError = '';
    if (text.length === 0 || text.length > MAX_SCRIPT_CHARS) {
      this.lastError = '脚本为空或超过 9,000,000 字符';
      return null;
    }
    const info: ScriptHeaderInfo | null = parseScriptHeader(text);
    if (info === null) {
      this.lastError = '文件开头缺少 /* @name ... */ 块注释，不是通用 JS 音源脚本';
      return null;
    }
    const dir: string = scriptDir();
    if (dir.length === 0) {
      this.lastError = '应用上下文未就绪，请重启应用后重试';
      return null;
    }
    // 递归创建；目录已存在时 mkdirSync 会抛 EEXIST，忽略即可，
    // 真正的可写性由下面 writeTextFile 验证（accessSync 在部分机型返回值不可靠）。
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'source_scripts dir exists or mkdir skipped');
    }

    let meta: CustomScriptMeta | null = null;
    for (const s of this.scripts) {
      if (s.name === info.name && s.version === info.version) {
        meta = s;
        break;
      }
    }
    const id: string = meta === null
      ? 'src_' + Date.now().toString() + '_' + Math.random().toString().substring(2, 8)
      : meta.id;
    const fileName: string = id + '.js';
    try {
      writeTextFile(dir + '/' + fileName, text);
    } catch (e) {
      this.lastError = '写入脚本失败：' + errText(e);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'write custom script failed: %{public}s', this.lastError);
      return null;
    }

    if (meta === null) {
      meta = {
        id, name: info.name, description: info.description, version: info.version,
        author: info.author, homepage: info.homepage, fileName, from,
        importedAt: new Date().toLocaleString(), size: text.length,
        enabled: false, allowShowUpdateAlert: true,
      };
      this.scripts.push(meta);
    } else {
      meta.description = info.description;
      meta.author = info.author;
      meta.homepage = info.homepage;
      meta.from = from;
      meta.fileName = fileName;
      meta.size = text.length;
      meta.importedAt = new Date().toLocaleString();
    }
    await this.persist();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'custom script imported: %{public}s v%{public}s', meta.name, meta.version);
    return meta;
  }

  /** 单选启用：勾选一个即取消其它 */
  async setEnabled(id: string, on: boolean): Promise<void> {
    for (const s of this.scripts) {
      s.enabled = on && s.id === id;
    }
    await this.persist();
  }

  async setAllowUpdateAlert(id: string, on: boolean): Promise<void> {
    const m: CustomScriptMeta | null = this.get(id);
    if (m !== null) {
      m.allowShowUpdateAlert = on;
      await this.persist();
    }
  }

  async remove(id: string): Promise<void> {
    const m: CustomScriptMeta | null = this.get(id);
    if (m === null) {
      return;
    }
    try {
      fs.unlinkSync(scriptDir() + '/' + m.fileName);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'delete custom script file failed');
    }
    const next: CustomScriptMeta[] = [];
    for (const s of this.scripts) {
      if (s.id !== id) {
        next.push(s);
      }
    }
    this.scripts = next;
    await this.persist();
  }

  /**
   * 拉起系统文件选择器导入本地脚本。
   *
   * 刻意不设 fileSuffixFilters：部分机型的文档选择器不认识 .js 这个后缀/MIME，
   * 设置后 select() 会直接抛「Internal error」；而微信/QQ 转存的脚本常被改名成
   * .txt / .js.txt。是否合法改由 parseScriptHeader 检查内容开头有没有 @name 块注释。
   */
  async importFromPicker(): Promise<ImportPickResult> {
    const ctx: common.UIAbilityContext | null = getAppContext();
    if (ctx === null) {
      return { status: 'error', detail: '应用上下文未就绪，请重启应用后重试' };
    }
    let uris: string[] = [];
    try {
      const p = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      uris = await p.select(options);
    } catch (e) {
      const msg: string = errText(e);
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'custom source picker failed: %{public}s', msg);
      return { status: 'error', detail: '文件选择器异常：' + msg };
    }
    if (uris.length === 0) {
      return { status: 'cancel', detail: '' };
    }
    let text: string = '';
    try {
      text = readTextFile(uris[0]);
    } catch (e) {
      const msg: string = errText(e);
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'read custom script failed: %{public}s', msg);
      return { status: 'error', detail: '读取文件异常：' + msg };
    }
    if (text.length === 0) {
      return { status: 'error', detail: '文件内容为空或读取不到内容' };
    }
    const meta: CustomScriptMeta | null = await this.importScript(text, '本地导入');
    if (meta === null) {
      return { status: 'invalid', detail: this.lastError };
    }
    return { status: 'ok', detail: '' };
  }
}

/** 把系统异常转成可显示文字（ArkTS 严格模式下不能用 any） */
function errText(e: Object): string {
  const err = e as Error;
  const m: string = err.message !== undefined ? err.message : '';
  return m.length > 0 ? m : '未知错误';
}
