/**
 * 版本号与更新日志（全应用唯一来源）。
 *
 * 【版本规则 · 用户约定 2026-11-14，2026-11-14 三次修订】
 *  - 形如 1.0.1.xxxx：前三段是 大.中.小 版本号，由 tools/version_base 维护。
 *  - xxxx 是 4 位测试号：**开源版首个版本为 1.9.23.9527**；此后每个新版本在上一版基础上
 *    随机 +1~200（约束：相邻两版的 4 位测试号差值不超过 200）；
 *    4 位数累加到 9999 到顶后，升一位小版本并从低位重新开始。
 *    当前达到的数值持久化在 tools/build_number，交付时由 tools/bump_version.py 递增。
 *  - 主版本段默认不动；只有用户明确说「升级大/中/小版本号」时才在下一版把对应段 +1，
 *    低位段保持已达到的值（用户约定：1.0.0 → 升小版本 1.0.1 → 升中版本 1.1.1 → 升大版本 2.1.1）。
 *  - 发版由 tools/bump_version.py 统一同步 AppScope/app.json5 的 versionName / versionCode，
 *    并往 CHANGELOG 头部插入一条新版本记录；旧记录写死版本号、自动变为折叠的历史版本。
 *
 * 注意：APP_VERSION_NAME 在构建前由交付流程写入真实测试号，
 * Index.ets 的抽屉与设置页都直接引用本常量，避免多处硬编码不一致。
 */
export const APP_VERSION_NAME: string = '1.9.23.9527';

export interface VersionLog {
  version: string;
  date: string;
  items: string[];
}

/**
 * 按时间倒序：第 0 条永远是当前版本（设置页默认展开），
 * 其余为历史版本（收进设置页「历史版本」弹窗，点标题展开）。
 */
export const CHANGELOG: VersionLog[] = [
  {
    version: APP_VERSION_NAME,
    date: '2026-11-27',
    items: [
      '送你的礼物！',
    ],
  },
];
