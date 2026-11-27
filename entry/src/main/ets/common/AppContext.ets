import { common } from '@kit.AbilityKit';

/**
 * 保存 UIAbilityContext，供 AVPlayer / AVSession / 后台任务使用。
 * 避免在页面里使用已废弃的 getContext()。
 */
let appAbilityContext: common.UIAbilityContext | null = null;

export function setAppContext(ctx: common.UIAbilityContext): void {
  appAbilityContext = ctx;
}

export function getAppContext(): common.UIAbilityContext | null {
  return appAbilityContext;
}
