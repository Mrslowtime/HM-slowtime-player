/**
 * 设备标识（持久化）——避免所有安装本应用的用户在平台侧被识别成「同一个设备」。
 *
 * 老版本把从协议逆向出来的咪咕 deviceId 写死在 Signatures 里，
 * 所有用户共用同一个值，请求量一大就极易被平台聚合成异常指纹而封禁。
 * 现在首次启动生成一次随机 32 位十六进制 ID，写入独立 preferences 文件，
 * 之后每次启动复用；拿不到上下文时才退回旧值，保证签名链路不会断。
 */
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { getAppContext } from '../common/AppContext';

const PREF_NAME: string = 'slowtime_device_ids';
const KEY_MG: string = 'mg_device_id';
/** 协议原值，仅作拿不到上下文时的兜底 */
const MG_FALLBACK_ID: string = '963B7AA0D21511ED807EE5846EC87D20';

let cachedMgId: string = '';

/** 咪咕搜索签名用的 deviceId（32 位大写十六进制，每台设备首次运行生成一次） */
export async function getMgDeviceId(): Promise<string> {
  if (cachedMgId.length > 0) {
    return cachedMgId;
  }
  const ctx = getAppContext();
  if (ctx === null) {
    cachedMgId = MG_FALLBACK_ID;
    return cachedMgId;
  }
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    const raw = await store.get(KEY_MG, '');
    let id: string = typeof raw === 'string' ? raw as string : '';
    if (id.length === 0) {
      id = util.generateRandomUUID(true).replace(/-/g, '').toUpperCase();
      await store.put(KEY_MG, id);
      await store.flush();
    }
    cachedMgId = id;
  } catch (e) {
    cachedMgId = MG_FALLBACK_ID;
  }
  return cachedMgId;
}
