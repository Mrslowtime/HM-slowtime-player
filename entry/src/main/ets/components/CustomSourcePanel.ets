/**
 * 设置页「自定义源」分组内容 —— 按「基本设置 → 音乐来源 → 自定义源」。
 *
 * 展示已导入的 .js 音源，单选勾选后即加载该脚本（显示初始化状态），
 * 底部「自定义源管理」按钮打开全屏管理弹窗（由 Index 根 Stack 承载）。
 */
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { CustomScriptStore, CustomScriptMeta } from '../core/net/CustomScriptStore';
import { CustomScriptRunner, InitState } from '../core/net/CustomScriptRunner';
import { MusicUrlResolver } from '../core/net/MusicUrlResolver';
import { stateEvent, StateEvents, EmptyCallback } from '../store/EventBus';

@Component
export struct CustomSourcePanel {
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  @State private scripts: CustomScriptMeta[] = [];
  @State private initText: string = '';

  private store: CustomScriptStore = CustomScriptStore.getInstance();
  private runner: CustomScriptRunner = CustomScriptRunner.getInstance();
  /** 自定义源变更：显式引用，卸载时反订阅，避免匿名监听泄漏 */
  private onSourceChanged: EmptyCallback = (): void => { this.reload(); };

  async aboutToAppear(): Promise<void> {
    stateEvent().on(StateEvents.CUSTOM_SOURCE_CHANGED, this.onSourceChanged);
    await this.reload();
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.CUSTOM_SOURCE_CHANGED, this.onSourceChanged);
  }

  private async reload(): Promise<void> {
    await this.store.init();
    this.scripts = this.store.list();
    const active: CustomScriptMeta | null = this.store.getActive();
    if (active === null) {
      this.initText = '';
      return;
    }
    // 先用现有状态立刻渲染（不阻塞），再在后台确认一次。
    // 这里绝不重建沙箱：重建一个 Web 页面要好几秒，仅仅为了显示一行文字就重载，
    // 正是之前一直卡在「初始化中」的原因；真正需要时会话在播放取链时自动建立。
    const st: InitState = this.runner.getInitState();
    if (st.ok) {
      this.initText = '已就绪';
    } else if (st.error.length > 0) {
      this.initText = st.error;
    } else {
      this.initText = '播放时加载';
    }
    this.confirmState(active);
  }

  /** 后台探针确认沙箱是否还在，完成后再更新那一行文案 */
  private async confirmState(active: CustomScriptMeta): Promise<void> {
    const ok: boolean = await this.runner.prepare(active, false);
    const s: InitState = this.runner.getInitState();
    if (ok) {
      this.initText = '已就绪';
    } else if (s.error.length > 0) {
      this.initText = s.error;
    } else if (this.initText.length === 0) {
      this.initText = '播放时加载';
    }
  }

  private async toggle(id: string, on: boolean): Promise<void> {
    await this.store.setEnabled(id, on);
    this.runner.invalidate();
    MusicUrlResolver.getInstance().clearCache();
    this.scripts = this.store.list();
    const active: CustomScriptMeta | null = this.store.getActive();
    if (active === null) {
      this.initText = '';
      return;
    }
    // 用户主动勾选：给一次明确的初始化（这时重建是应该的），先出「初始化中」再更新结果
    this.initText = '初始化中…';
    const ok: boolean = await this.runner.prepare(active, true);
    const s: InitState = this.runner.getInitState();
    if (ok) {
      this.initText = '已就绪';
    } else if (s.error.length > 0) {
      this.initText = s.error;
    } else {
      this.initText = '待使用';
    }
    stateEvent().emit(StateEvents.CUSTOM_SOURCE_CHANGED);
  }

  build() {
    Column() {
      Text('导入通用 JS 音源脚本格式的 .js 音源脚本后，播放与下载会优先使用自定义源；失败时自动回落到下方「音源服务」里填写的 HTTP 端点。')
        .fontSize(12)
        .fontColor(buildPalette(this.theme).subText)
        .width('100%')
        .margin({ top: 4, bottom: 12 })

      if (this.scripts.length === 0) {
        Text('尚未添加自定义源。点下方「自定义源管理」→「在线导入」或「本地导入」添加即可。')
          .fontSize(12)
          .lineHeight(16)
          .fontColor(buildPalette(this.theme).subText)
          .width('100%')
          .margin({ bottom: 12 })
      }

      ForEach(this.scripts, (s: CustomScriptMeta): void => {
        Row() {
          Text(s.enabled ? '☑' : '☐')
            .fontSize(17)
            .fontColor(s.enabled ? this.theme.primary : buildPalette(this.theme).subText)
            .margin({ right: 9 })
          Column() {
            Text(s.name + '  ' + s.version)
              .fontSize(14)
              .lineHeight(18)
              .fontColor(this.theme.font)
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Start)
            if (s.description.length > 0) {
              Text(s.description)
                .fontSize(11)
                .lineHeight(14)
                .fontColor(buildPalette(this.theme).subText)
                .width('100%')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Start)
                .margin({ top: 1 })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (s.enabled) {
            Text('[' + (this.initText.length > 0 ? this.initText : '检查中') + ']')
              .fontSize(11)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(this.initText === '已就绪' ? this.theme.primary : '#B4694A')
          }
        }
        .width('100%')
        .padding({ left: 11, right: 11, top: 8, bottom: 8 })
        .backgroundColor(s.enabled ? this.theme.primary + '1A' : buildPalette(this.theme).card)
        .borderRadius(10)
        .margin({ bottom: 8 })
        .onClick((): void => { this.toggle(s.id, !s.enabled); })
      }, (s: CustomScriptMeta): string => s.id + '|' + s.enabled.toString() + '|' + s.version)

      Button('自定义源管理')
        .fontSize(13)
        .backgroundColor(buildPalette(this.theme).pillBg)
        .fontColor(buildPalette(this.theme).subText)
        .stateEffect(false)
        .width('100%')
        .margin({ top: 6 })
        .onClick((): void => { stateEvent().emit(StateEvents.CUSTOM_SOURCE_MANAGE); })

      // 音源服务（HTTP 端点兜底配置）：原来是设置页里独立的一整组，2026-11-17 收进弹窗，
      // 入口就放在「自定义源管理」下面，两个音源相关配置集中在一处。
      Button('音源服务')
        .fontSize(13)
        .backgroundColor(buildPalette(this.theme).pillBg)
        .fontColor(buildPalette(this.theme).subText)
        .stateEffect(false)
        .width('100%')
        .margin({ top: 8 })
        .onClick((): void => { stateEvent().emit(StateEvents.SOURCE_SERVICE_OPEN); })

      Text('提示：自定义音源脚本由第三方维护，请自行确认来源可靠；导入包含恶意行为的脚本可能影响应用运行。')
        .fontSize(11)
        .fontColor(buildPalette(this.theme).subText)
        .width('100%')
        .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }
}
