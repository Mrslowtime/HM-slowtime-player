/**
 * 导出已下载音频到系统「文件」App 可见目录。
 *
 * 背景：下载文件默认落在应用沙箱 filesDir/downloads，HarmonyOS 上用户不可见，
 * 无法直接复制/移动。这里用系统文档选择器（保存模式）让用户选目标位置，
 * 拿到 URI 后把沙箱源文件复制过去，之后用户即可在「文件」App 里自由复制移动。
 *
 * 纯本地文件操作，不涉及任何音源网络请求。
 */
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { getAppContext } from '../common/AppContext';
import { stateEvent, StateEvents } from '../store/EventBus';

/**
 * 把沙箱里的已下载文件导出到用户选定位置。
 * @param srcPath 沙箱源文件绝对路径（DownloadListItem.filePath）
 * @param displayName 建议文件名（不含扩展名）
 * @param ext 扩展名（mp3/flac/...，不含点）
 * @returns true 成功导出；false 用户取消或失败
 */
export async function exportDownloadedFile(srcPath: string, displayName: string, ext: string): Promise<boolean> {
  return await exportDownloadedFiles([{ srcPath: srcPath, displayName: displayName, ext: ext }]);
}

/** 一个待导出的文件：源沙箱路径 + 目标显示名（不含扩展名）+ 扩展名 */
export interface ExportFileItem {
  srcPath: string;
  displayName: string;
  ext: string;
}

/**
 * 把沙箱里的一批已下载文件导出到用户在「文件」面板里选定的文件夹。
 *
 * 手机端 DocumentSelectMode.FOLDER 仅 2-in-1 设备支持，无法直接选目录；
 * 因此走 save() + newFileNames：面板里进入目标文件夹后保存，即「导出到指定文件夹」。
 * 多个文件一次 newFileNames 批量给出，用户只进一次目录、一次确认，避免逐首弹面板。
 * @returns true 成功导出（全部可写源都复制完成）；false 用户取消或失败
 */
export async function exportDownloadedFiles(items: ExportFileItem[]): Promise<boolean> {
  const ctx = getAppContext();
  if (ctx === null) {
    return false;
  }
  // 过滤掉已被清理 / 异常的源文件，避免 save 面板给出空文件名
  const valid: ExportFileItem[] = [];
  for (const it of items) {
    try {
      if (fs.accessSync(it.srcPath) && it.srcPath.length > 0) {
        valid.push(it);
      }
    } catch (e) {
      void e;
    }
  }
  if (valid.length === 0) {
    return false;
  }
  try {
    const p = new picker.DocumentViewPicker(ctx);
    const opt = new picker.DocumentSaveOptions();
    const names: string[] = [];
    for (const it of valid) {
      names.push(it.displayName + '.' + it.ext);
    }
    opt.newFileNames = names;
    const uris: string[] = await p.save(opt);
    if (uris.length === 0) {
      return false;
    }
    // save 返回的 URI 顺序与 newFileNames 一一对应
    const count: number = Math.min(uris.length, valid.length);
    let copied: number = 0;
    for (let i = 0; i < count; i++) {
      try {
        await fs.copyFile(valid[i].srcPath, uris[i]);
        copied++;
      } catch (e) {
        void e;
      }
    }
    if (copied > 0) {
      // 目标文件夹里多出了音频：通知本地音乐页静默重扫，用户不用手动点「刷新」也能看到新分组
      stateEvent().emit(StateEvents.LOCAL_FILES_CHANGED);
    }
    return copied > 0;
  } catch (e) {
    // 用户取消保存面板也会走到这里
    return false;
  }
}
