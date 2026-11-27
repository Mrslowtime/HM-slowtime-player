/**
 * 下载取链（独立实现重做，2026-11-21）。
 *
 * 本协议的做法：下载就是「拿当前音源脚本调 getMusicUrl，拿到直链就流式下载」，
 * 没有播放那套 6s 预算、失败冷却、强制重建、播放中不许动的限制。本项目照此重做：
 *
 * - 取链候选 = 当前启用脚本 + 已导入的其它脚本，逐个独立试，谁先返回直链用谁；
 * - 全程不切换「用户启用的音源」（不写 enabled/偏好），不碰播放的熔断/负缓存/冷却；
 * - 单个脚本失败不重建沙箱、不 markFail，只是换下一个脚本再试；
 * - 取链结束后把沙箱恢复成用户当前启用的脚本，避免下次播放多付一次重建请求；
 * - 只有当所有本地脚本都拿不到链时，才回落到 HTTP 音源服务（用户配了才有）；
 * - 每任务最多试 MAX_SCRIPTS 个脚本，防止失控脚本把下载变成请求风暴。
 *
 * 请求数说明：相比旧实现（切全局 + 逐个重建沙箱 + 冷却），新实现每个脚本只走
 * prepare + getMusicUrl，不额外重建、不重复请求，整体请求数只会更少。
 */
import { MusicInfo } from '../model/MusicTypes';
import { Quality, OnlineSource } from '../config/AppConstants';
import { UrlResolveResult, MusicUrlResolver } from './net/MusicUrlResolver';
import { CustomScriptStore, CustomScriptMeta } from './net/CustomScriptStore';
import { CustomScriptRunner, ScriptUrlResult } from './net/CustomScriptRunner';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

const REASON: string = '当前音源不支持该平台或未返回链接';
/** 每次下载最多尝试的脚本数量（含当前启用脚本），防止失控脚本打成请求风暴 */
const MAX_SCRIPTS: number = 4;

export interface DownloadResolveOutcome {
  result: UrlResolveResult;
  /** 实际尝试了几个脚本 */
  switched: number;
  /** 命中结果的脚本名（成功时非空），供状态文案显示 */
  usedScript: string;
  /** 取链过程中用户点了暂停/取消 */
  cancelled: boolean;
}

/** 串行闸门句柄（ArkTS 不允许 definite assignment，用对象包一层） */
interface SerialGate {
  release: () => void;
}

/**
 * 下载取链串行锁：整个应用只有一个 WebView 沙箱，两个下载任务并发取链会互相
 * controller.refresh() 打断对方的 inited/取链响应，表现为两首都卡在 (1/4)、
 * 播放链路同时爆一串 budget exceeded。这里把「取链」串行化；拿到直链后的
 * HTTP 文件传输不占沙箱，仍可并发。
 */
let sResolveChain: Promise<void> = Promise.resolve();

async function withResolveSerial<T>(fn: () => Promise<T>): Promise<T> {
  const holder: SerialGate = { release: (): void => {} };
  const gate: Promise<void> = new Promise<void>((res: () => void): void => {
    holder.release = res;
  });
  const prev: Promise<void> = sResolveChain;
  sResolveChain = prev.then((): Promise<void> => gate);
  await prev;
  try {
    return await fn();
  } finally {
    holder.release();
  }
}

function withError(r: UrlResolveResult, error: string): UrlResolveResult {
  return {
    ok: r.ok, url: r.url, quality: r.quality, source: r.source,
    error: error, tooManyRequests: r.tooManyRequests,
  };
}

function toUrlResult(s: ScriptUrlResult, info: MusicInfo): UrlResolveResult {
  return {
    ok: s.ok, url: s.url, quality: s.quality, source: info.source as OnlineSource,
    error: s.error, tooManyRequests: false,
  };
}

/**
 * 组装下载取链候选脚本：当前启用的排第一，其后是用户已导入的其它脚本。
 * 去重、跳过无正文的脚本，最多返回 MAX_SCRIPTS 个。
 */
async function candidateScripts(store: CustomScriptStore): Promise<CustomScriptMeta[]> {
  const out: CustomScriptMeta[] = [];
  const seen: Set<string> = new Set<string>();
  const active: CustomScriptMeta | null = store.getActive();
  if (active !== null) {
    out.push(active);
    seen.add(active.id);
  }
  // 用户已导入的其它脚本，按导入顺序补齐候选
  const all: CustomScriptMeta[] = store.list();
  for (const m of all) {
    if (out.length >= MAX_SCRIPTS) {
      break;
    }
    if (seen.has(m.id)) {
      continue;
    }
    if (store.readScript(m.id).length === 0) {
      continue;
    }
    out.push(m);
    seen.add(m.id);
  }
  return out;
}

/**
 * 下载取链入口（独立实现）：先试本地脚本逐个取链，全失败再回落 HTTP 音源服务。
 * onProgress 用来把「正在尝试某个音源」实时写到下载项状态文案上。
 */
export async function resolveDownloadUrl(info: MusicInfo, prefer: Quality,
  onProgress: (text: string) => void,
  isCancelled: () => boolean): Promise<DownloadResolveOutcome> {
  return await withResolveSerial(async (): Promise<DownloadResolveOutcome> => {
    const store: CustomScriptStore = CustomScriptStore.getInstance();
    await store.init();
    const runner: CustomScriptRunner = CustomScriptRunner.getInstance();
    const resolver: MusicUrlResolver = MusicUrlResolver.getInstance();

    const empty: UrlResolveResult = {
      ok: false, url: '', quality: prefer, source: info.source as OnlineSource,
      error: '已取消', tooManyRequests: false,
    };
    const cancelled = (): DownloadResolveOutcome =>
      ({ result: empty, switched: 0, usedScript: '', cancelled: true });

    if (isCancelled()) {
      return cancelled();
    }
    const scripts: CustomScriptMeta[] = await candidateScripts(store);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'download: %{public}s, %{public}d scripts to try',
      info.name, scripts.length);
    let tried: number = 0;
    for (const meta of scripts) {
      // 每个脚本之前都检查一次：用户点暂停/取消后不再继续打请求
      if (isCancelled()) {
        return cancelled();
      }
      tried++;
      onProgress('正在通过「' + meta.name + '」获取下载链接（' + tried.toString() + '/' +
        scripts.length.toString() + '）…');
      const s = await runner.tryResolveForDownload(meta, info, prefer);
      if (isCancelled()) {
        return cancelled();
      }
      if (s !== null && s.ok && s.url.length > 0) {
        // 恢复沙箱不阻塞下载：交给后台执行，下载立即用这条直链开始传输
        void runner.restoreActiveScript();
        return { result: toUrlResult(s, info), switched: tried, usedScript: meta.name, cancelled: false };
      }
    }

    if (isCancelled()) {
      return cancelled();
    }
    // 所有本地脚本都没拿到：非阻塞恢复沙箱，再回落 HTTP 音源服务
    void runner.restoreActiveScript();
    const last: UrlResolveResult = await resolver.resolve(info, prefer, true, true);
    if (last.ok && last.url.length > 0) {
      return { result: last, switched: tried, usedScript: '音源服务', cancelled: false };
    }
    return {
      result: withError(last, REASON + '，已尝试 ' + tried.toString() + ' 个音源仍失败'),
      switched: tried, usedScript: '', cancelled: false,
    };
  });
}
