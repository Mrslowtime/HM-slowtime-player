/**
 * 本地音乐导入 —— 全应用唯一入口。
 *
 * 「本地」页的「导入」按钮、列表三点菜单里的「导入文件夹」、
 * 「本地音乐 / 文件夹」分类里的导入入口，全部复用这里的选择器流程：
 * 拉起系统文件选择器（可进入目标文件夹后多选音频）→ 复制进沙箱 downloads → 返回导入数。
 *
 * 说明：HarmonyOS 的 DocumentSelectMode.FOLDER 仅 2-in-1 设备支持，手机端无法直接选目录，
 * 因此「导入文件夹」仍走本地页这套文件选择 + 批量复制，用户进入文件夹全选音频即可。
 * 返回：>0 成功导入数量；0 用户取消或没选中文件；-1 选择器异常。
 */
import { picker } from '@kit.CoreFileKit';
import { getAppContext } from '../common/AppContext';
import { LocalMusicScanner } from './LocalMusicScanner';

export async function importLocalMusicFiles(): Promise<number> {
  const ctx = getAppContext();
  if (ctx === null) {
    return -1;
  }
  try {
    const p = new picker.DocumentViewPicker(ctx);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 100;
    options.fileSuffixFilters = ['音频|.mp3,.flac,.wav,.m4a,.aac,.ogg,.ape'];
    const uris: string[] = await p.select(options);
    if (uris.length === 0) {
      return 0;
    }
    return await LocalMusicScanner.getInstance().importFiles(uris);
  } catch (e) {
    // 用户取消选择也会走到这里
    return -1;
  }
}
