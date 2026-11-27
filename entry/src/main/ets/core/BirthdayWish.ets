/**
 * 农历九月二十三日生日彩蛋。
 *
 * - 当天第一次打开应用才弹，同一天重复启动不再弹；
 * - 从现在起下一次弹的是用户指定的固定祝福语；若当年一次都没打开，
 *   这条固定祝福语顺延到下一年，直到真的弹出过；
 * - 之后每年从祝福语池随机挑一条，尽量不重复（池用尽后只避开上一条）；
 * - 全部状态写本地 preferences，不联网、不请求音源，零 IP 风险；
 * - 被隐藏开关关闭后永久不再弹（见 core/BirthdaySecret.ets）。
 */
import { preferences } from '@kit.ArkData';
import { getAppContext } from '../common/AppContext';
import { lunar923Today } from './LunarCalendar';
import { isBirthdayEggDisabled } from './BirthdaySecret';

const PREF_NAME: string = 'slowtime_birthday_wish';
const KEY_PENDING_FIXED: string = 'pending_fixed';
const KEY_LAST_DAY: string = 'last_day';
const KEY_USED: string = 'used';
const KEY_LAST_INDEX: string = 'last_index';

const FIXED_WISH: string = '这是你的生日礼物！生日快乐，你一定要让自己开心喔！';

/** 固定祝福语之外的候选池；下标即偏好里记录的编号 */
const WISHES: string[] = [
  '生日快乐！愿你今天的每一分钟都被温柔以待。',
  '又到你的日子啦，愿你平安喜乐，万事顺意。',
  '生日快乐，愿你想要的都拥有，得不到的都释怀。',
  '祝生日快乐！愿你走过的路都有光，回头看全是温暖。',
  '今天是属于你的日子，愿好运与好心情一直陪着你。',
  '生日快乐！愿你保持热爱，奔赴下一场山海。',
  '愿你岁岁常欢愉，年年皆胜意。生日快乐！',
  '生日快乐，愿你所有的努力都有回响。',
  '新的一岁，愿你健康、自由，且被好好爱着。',
  '生日快乐！愿你的生活总有惊喜在排队。',
  '愿这一岁：日子有盼头，心里有底气。生日快乐！',
  '生日快乐，愿你笑里藏着的都是真的开心。',
  '愿时光对你温柔一点，再温柔一点。生日快乐！',
  '生日快乐！愿你不必完美，也能闪闪发光。',
  '新的一岁，愿你把烦恼清零，把快乐拉满。',
  '生日快乐，愿你的每一个小愿望都有人记得。',
  '愿你眼里长存笑意，心底常驻安宁。生日快乐！',
  '生日快乐！这一岁请继续做自己喜欢的事。',
  '愿你的生日像一首喜欢的歌，循环一整天。',
  '生日快乐，愿你所有的等待都值得。',
  '新的一岁，愿你手中有光，脚下有路。',
  '生日快乐！愿今天的快乐能存进往后每一天。',
  '愿你在新的一岁里，遇见更多可爱的自己。',
  '生日快乐，愿你被世界温柔拥抱。',
];

function parseUsed(raw: string): number[] {
  const result: number[] = [];
  if (raw.length === 0) {
    return result;
  }
  const parts: string[] = raw.split(',');
  for (const p of parts) {
    if (p.length > 0) {
      result.push(Number(p));
    }
  }
  return result;
}

function pickIndex(used: number[], lastIndex: number): number {
  const candidates: number[] = [];
  for (let i: number = 0; i < WISHES.length; i++) {
    if (i === lastIndex) {
      continue;
    }
    if (used.indexOf(i) < 0) {
      candidates.push(i);
    }
  }
  if (candidates.length === 0) {
    // 全部用过：只避开上一条，保证相邻两次不同
    let idx: number = Math.floor(Math.random() * WISHES.length);
    if (idx === lastIndex) {
      idx = (idx + 1) % WISHES.length;
    }
    return idx;
  }
  return candidates[Math.floor(Math.random() * candidates.length)];
}

/**
 * 若今天是农历九月二十三、彩蛋未被关闭、且今天还没弹过，返回本次祝福语；
 * 否则返回空串。调用即消费当天机会。
 */
export async function takeBirthdayWish(): Promise<string> {
  if (isBirthdayEggDisabled()) {
    return '';
  }
  const dayKey: string = lunar923Today();
  if (dayKey.length === 0) {
    return '';
  }
  const ctx = getAppContext();
  if (ctx === null) {
    return '';
  }
  try {
    const store: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
    const lastRaw = await store.get(KEY_LAST_DAY, '');
    const lastDay: string = typeof lastRaw === 'string' ? lastRaw as string : '';
    if (lastDay === dayKey) {
      return '';
    }

    const pendingRaw = await store.get(KEY_PENDING_FIXED, true);
    const pending: boolean = typeof pendingRaw === 'boolean' ? pendingRaw as boolean : true;
    let wish: string = '';
    let nextIndex: number = -1;

    const usedRaw = await store.get(KEY_USED, '');
    const used: number[] = parseUsed(typeof usedRaw === 'string' ? usedRaw as string : '');
    const lastIdxRaw = await store.get(KEY_LAST_INDEX, -1);
    const lastIndex: number = typeof lastIdxRaw === 'number' ? lastIdxRaw as number : -1;

    if (pending) {
      // 固定祝福语只在真的弹出来之后才「用掉」；错过生日则原样顺延
      wish = FIXED_WISH;
    } else {
      nextIndex = pickIndex(used, lastIndex);
      wish = WISHES[nextIndex];
      if (used.indexOf(nextIndex) < 0) {
        used.push(nextIndex);
      }
    }

    await store.put(KEY_LAST_DAY, dayKey);
    await store.put(KEY_PENDING_FIXED, false);
    await store.put(KEY_LAST_INDEX, nextIndex);
    await store.put(KEY_USED, used.join(','));
    await store.flush();
    return wish;
  } catch (e) {
    return '';
  }
}
