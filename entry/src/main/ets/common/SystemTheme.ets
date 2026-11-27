/**
 * 系统明暗模式检测。
 * 供「跟随系统明暗」使用：开启后按当前色彩模式在 theme.lightId / theme.darkId 之间切换。
 * 取不到 context 时按浅色处理，保证不会因异常导致主题丢失。
 */
import { ConfigurationConstant } from '@kit.AbilityKit';
import { getAppContext } from './AppContext';

/** 系统当前是否深色模式 */
export function isSystemDarkMode(): boolean {
  const ctx = getAppContext();
  if (ctx === null) {
    return false;
  }
  const mode: ConfigurationConstant.ColorMode | undefined = ctx.config.colorMode;
  if (mode === undefined) {
    return false;
  }
  return mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
}
