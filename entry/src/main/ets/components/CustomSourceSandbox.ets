/**
 * 自定义音源沙箱容器 —— 一个不可见的 Web 组件，专供音源脚本运行。
 *
 * 挂在 Index 的最外层 Stack 上（1x1 + 全透明），页面本身只有空 HTML：
 * 宿主先注入 rawfile/lx_prelude.js 构造 globalThis.lx，再注入用户脚本。
 * javaScriptProxy 把 __lxHost.post / __lxHost.log 暴露给脚本，脚本没有其它原生出口。
 */
import { webview } from '@kit.ArkWeb';
import { CustomScriptRunner } from '../core/net/CustomScriptRunner';

/** javaScriptProxy 要求对象是普通类实例、方法只接收基础类型 */
class LxHostProxy {
  post(action: string, payload: string): void {
    CustomScriptRunner.getInstance().onHostMessage(action, payload);
  }

  log(text: string): void {
    CustomScriptRunner.getInstance().onHostLog(text);
  }
}

@Component
export struct CustomSourceSandbox {
  private controller: webview.WebviewController = new webview.WebviewController();
  private host: LxHostProxy = new LxHostProxy();

  build() {
    Web({ src: $rawfile('lx_sandbox.html'), controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(false)
      .fileAccess(false)
      .javaScriptProxy({
        object: this.host,
        name: '__lxHost',
        methodList: ['post', 'log'],
        controller: this.controller,
      })
      .onPageEnd((): void => {
        const runner: CustomScriptRunner = CustomScriptRunner.getInstance();
        runner.attach(this.controller);
        runner.onPageEnd();
        // 启动预热不在这里做：Index 在播放核心就绪后会调用 runner.warmUp()，
        // 由运行时自己等控制器上屏、自己处理冷却与重试；组件只负责把控制器交出去。
      })
      .width(1)
      .height(1)
      .opacity(0)
  }
}
