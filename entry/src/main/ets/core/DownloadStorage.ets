/**
 * 下载保存位置 —— 让下载文件直接落到手机「下载」公共目录，而不是应用沙箱。
 *
 * 依据 HarmonyOS Core File Kit 的 DOWNLOAD 模式（API 12+）：
 *   picker.DocumentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD
 *   → DocumentViewPicker.save() 不弹文件选择界面，直接返回 Download/<包名>/ 目录 URI；
 *   → 该 URI 已具备持久化读写权限，可用 new fileUri.FileUri(uri).path 转成真实路径；
 *   → 之后用 fileIo 在该目录下创建/续写/删除文件，与沙箱内的绝对路径用法完全一致。
 *
 * 好处：用户在「文件」App 里直接看到音频，不需要「导出」再复制一份，
 * 因此不会同时占用两份磁盘空间；播放/断点续传/本地扫描链路都无需改造。
 *
 * 纯本地文件操作，不涉及任何音源网络请求。
 */
import { picker, fileUri, fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getAppContext } from '../common/AppContext';
import { SettingStore } from '../store/SettingStore';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

/** download.storage: 'public'（默认，公共下载目录） / 'sandbox'（应用内，需导出） */
const STORAGE_KEY: string = 'download.storage';

/** 进程内缓存：DOWNLOAD 模式本身不弹界面，但也不必每首歌都走一次 IPC */
let cachedPublicDir: string = '';
/** 解析/写入公共目录失败过：UI 据此改回「沙箱 + 导出」的说明，避免误导 */
let publicFailed: boolean = false;

/** 是否使用公共下载目录（关闭则沿用原有沙箱 + 导出流程） */
export function usePublicStorage(): boolean {
  return SettingStore.getInstance().getString(STORAGE_KEY, 'public') !== 'sandbox';
}

/** 本机公共目录是否不可用（UI 用来显示真实落盘说明） */
export function publicStorageFailed(): boolean {
  return publicFailed;
}

/** 写公共目录失败时调用：标记降级，后续提示改回沙箱说明 */
export function markPublicUnavailable(): void {
  publicFailed = true;
  cachedPublicDir = '';
}

/** 目录是否存在且可写：只做一次极小的探针文件创建/删除 */
function dirWritable(dir: string): boolean {
  if (dir.length === 0) {
    return false;
  }
  try {
    if (!fs.accessSync(dir)) {
      return false;
    }
    const probe: string = dir + '/.slowtime_probe';
    const f: fs.File = fs.openSync(probe, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.closeSync(f.fd);
    try {
      fs.unlinkSync(probe);
    } catch (e) {
      void e;
    }
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * 取（并缓存）公共下载目录的真实路径。
 * 返回空串表示当前设备不支持 / 用户上下文未就绪 —— 调用方须自动回落沙箱，保证下载不中断。
 */
export async function publicDownloadBase(): Promise<string> {
  if (publicFailed) {
    // 本进程已确认不可用：稳定回落沙箱，不要每首歌都重试一次系统选择器
    return '';
  }
  if (cachedPublicDir.length > 0 && dirWritable(cachedPublicDir)) {
    return cachedPublicDir;
  }
  const ctx = getAppContext();
  if (ctx === null) {
    return '';
  }
  try {
    const opt = new picker.DocumentSaveOptions();
    opt.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
    const p = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await p.save(opt);
    if (uris.length === 0 || uris[0].length === 0) {
      return '';
    }
    const dir: string = new fileUri.FileUri(uris[0]).path.replace(/\/+$/, '');
    if (!dirWritable(dir)) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'download: public dir not writable, fallback to sandbox');
      publicFailed = true;
      return '';
    }
    cachedPublicDir = dir;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'download: public dir ready');
    return dir;
  } catch (e) {
    // 设备不支持 DOWNLOAD 模式 / 系统选择器异常：静默回落沙箱
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'download: public dir unavailable, fallback to sandbox');
    publicFailed = true;
    return '';
  }
}

/** 已下载文件是否位于公共目录（用于隐藏已经没必要的「导出」按钮） */
export function isPublicStored(path: string): boolean {
  if (path.length === 0) {
    return false;
  }
  if (cachedPublicDir.length > 0 && path.indexOf(cachedPublicDir + '/') === 0) {
    return true;
  }
  // 进程重启后缓存为空，用公共下载目录的路径特征兜底
  return path.indexOf('/Download/') >= 0;
}
