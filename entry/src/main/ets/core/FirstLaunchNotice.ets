/**
 * 首次安装进入应用时的风控提示。
 *
 * 只写本地 preferences，不联网、不请求音源，不会增加任何 IP 封禁风险。
 * 标记一旦写入就只在卸载重装（或清除应用数据）后重新出现。
 */
import { preferences } from '@kit.ArkData';
import { getAppContext } from '../common/AppContext';

const PREF_NAME: string = 'slowtime_launch_notice';
const KEY_SHOWN: string = 'first_launch_shown_v1';

/**
 * 本次启动是否需要弹「首次使用提示」。
 * 读取后立刻写标记，避免重复弹窗；写失败时按「没看过」处理，下次仍会弹。
 */
export async function consumeFirstLaunchNotice(): Promise<boolean> {
  const ctx = getAppContext();
  if (ctx === null) {
    return false;
  }
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    const raw = await store.get(KEY_SHOWN, false);
    const shown: boolean = typeof raw === 'boolean' ? raw as boolean : false;
    if (shown) {
      return false;
    }
    await store.put(KEY_SHOWN, true);
    await store.flush();
    return true;
  } catch (e) {
    return false;
  }
}
