/**
 * 音源服务设置 —— 按「基本设置 → 音源 / 自定义源管理」中的「音源服务」部分。
 *
 * 自定义 .js 音源脚本已由上方「自定义源」分组承接（ArkWeb 沙箱执行，协议与本协议一致）；
 * 本页配置的是兼容 HTTP 端点，作为自定义源未导入 / 取链失败时的兜底。
 * App 不内置任何音源实现、脚本或音乐内容，用户需自行确认所用服务的合法授权与条款。
 */
import { ThemeInfo, buildPalette } from '../../theme/Themes';
import { SourceConfig, SourceEndpoint, UrlPathStyle, SourceAuth } from '../../core/net/SourceConfig';
import { MusicUrlResolver, lxHeaders, keyHeaders } from '../../core/net/MusicUrlResolver';
import { HttpClient, HttpResult } from '../../core/net/HttpClient';
import { I18n } from '../../core/I18n';
import { stateEvent, StateEvents, EmptyCallback } from '../../store/EventBus';
import { userNotice } from '../../core/UserNotice';

@Component
export struct SourceSettingPanel {
  @State private apiUrl: string = '';
  @State private apiKey: string = '';
  @State private style: UrlPathStyle = 'path';
  @State private message: string = '';
  @State private testing: boolean = false;
  @State private langTick: number = 0;
  /** 当前生效端点 id */
  @State private activeId: string = '';
  /** 手动配置的自定义端点是否生效 */
  @State private customActive: boolean = false;
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };

  private config: SourceConfig = SourceConfig.getInstance();
  /** 语言切换：递增 langTick 触发 tx() 重新计算文案（显式引用便于卸载时反订阅） */
  private onLangChanged: EmptyCallback = (): void => { this.langTick = this.langTick + 1; };

  private tx(key: string): string {
    const _t = this.langTick;
    return I18n().t(key) + (_t >= 0 ? '' : '');
  }

  async aboutToAppear(): Promise<void> {
    stateEvent().on(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
    await this.config.init();
    const a: SourceEndpoint | null = this.config.getActive();
    this.activeId = a === null ? '' : a.id;
    this.customActive = a !== null && a.id === 'custom_user';
    const custom: SourceEndpoint | null = this.config.findEndpoint('custom_user');
    if (custom !== null && custom.apiUrl.length > 0) {
      this.apiUrl = custom.apiUrl;
      this.apiKey = custom.apiKey;
      this.style = custom.style;
    }
    this.message = a === null
      ? '未配置：请导入自定义音源脚本或填写音源服务地址'
      : ('当前使用：' + a.name);
  }

  aboutToDisappear(): void {
    stateEvent().off(StateEvents.LANGUAGE_CHANGED, this.onLangChanged);
  }

  /** 按真实鉴权协议测试某个端点的连通性 */
  private async testWith(baseUrl: string, apiKey: string, style: UrlPathStyle, auth: SourceAuth): Promise<void> {
    const base: string = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (base.length === 0) {
      this.message = '该音源地址为空';
      userNotice().warn(this.message);
      return;
    }
    this.testing = true;
    const probe: string = style === 'query'
      ? base + '/url?source=kw&songId=test&quality=128k'
      : base + '/url/kw/test/128k';
    const headers: Record<string, string> = (auth === 'signed' || auth === 'lx')
      ? lxHeaders('128k')
      : keyHeaders(apiKey);
    const allowHttp: boolean = base.startsWith('http://');
    const r: HttpResult = await HttpClient.get(probe, headers, 0, allowHttp);
    if (r.ok && r.json !== null) {
      this.message = '连通正常（返回了 JSON 响应）';
      userNotice().info('音源服务连通正常');
    } else if (r.ok) {
      this.message = '服务可达，但响应不是 JSON';
      userNotice().warn('音源服务可达，但响应不是 JSON');
    } else {
      this.message = '连接失败：' + r.error;
      userNotice().error('音源服务连接失败：' + r.error);
    }
    this.testing = false;
  }

  private async save(): Promise<void> {
    await this.config.configure(this.apiUrl, this.apiKey, this.style);
    MusicUrlResolver.getInstance().clearCache();
    this.activeId = 'custom_user';
    this.customActive = this.apiUrl.trim().length > 0;
    this.message = this.apiUrl.trim().length > 0
      ? '已保存自定义音源服务，重新播放在线歌曲即可生效'
      : '已清空，请导入自定义音源脚本以播放在线歌曲';
    userNotice().info(this.message);
  }

  private async test(): Promise<void> {
    const base: string = this.apiUrl.trim();
    if (base.length === 0) {
      this.message = '请先填写音源服务地址';
      userNotice().warn(this.message);
      return;
    }
    await this.testWith(base, this.apiKey.trim(), this.style, 'key');
  }

  build() {
    // 直接嵌在设置页的瀑布流里：不自己滚动，内容随页面一起上下滚（外层 SettingView 统一滚动）
    Column() {
      Column() {
        Text(this.tx('source_note'))
          .fontSize(12).fontColor(buildPalette(this.theme).subText)
          .width('100%').margin({ top: 4, bottom: 12 })

        // 用户自己的音源服务地址 + 密钥（App 不内置任何公共音源）
        Text('音源服务')
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor(this.theme.font)
          .width('100%').margin({ top: 6, bottom: 8 })

        Text(this.tx('source_url')).fontSize(12).fontColor(buildPalette(this.theme).subText).width('100%')
        TextInput({ placeholder: 'https://your-source.example.com', text: this.apiUrl })
          .height(38).fontSize(13).backgroundColor(buildPalette(this.theme).card).borderRadius(8)
          .width('100%').margin({ top: 4, bottom: 10 })
          .onChange((v: string): void => { this.apiUrl = v; })

        Text(this.tx('source_key')).fontSize(12).fontColor(buildPalette(this.theme).subText).width('100%')
        TextInput({ placeholder: 'X-Request-Key', text: this.apiKey })
          .height(38).fontSize(13).backgroundColor(buildPalette(this.theme).card).borderRadius(8)
          .type(InputType.Password)
          .width('100%').margin({ top: 4, bottom: 10 })
          .onChange((v: string): void => { this.apiKey = v; })

        Text('URL 风格').fontSize(12).fontColor(buildPalette(this.theme).subText).width('100%')
        Row() {
          Text('/url/源/ID/音质')
            .fontSize(12)
            .fontColor(this.style === 'path' ? '#FFFFFF' : buildPalette(this.theme).subText)
            .backgroundColor(this.style === 'path' ? this.theme.primary : buildPalette(this.theme).pillBg)
            .borderRadius(12).padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .margin({ right: 8 })
            .onClick((): void => { this.style = 'path'; })
          Text('/url?source=&songId=&quality=')
            .fontSize(12)
            .fontColor(this.style === 'query' ? '#FFFFFF' : buildPalette(this.theme).subText)
            .backgroundColor(this.style === 'query' ? this.theme.primary : buildPalette(this.theme).pillBg)
            .borderRadius(12).padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .onClick((): void => { this.style = 'query'; })
        }
        .width('100%').margin({ top: 6, bottom: 14 })

        Row() {
          Button(this.tx('source_save')).fontSize(13)
            .backgroundColor(this.theme.primary).fontColor('#FFFFFF').stateEffect(false)
            .layoutWeight(1)
            .onClick((): void => { this.save(); })
          Button(this.testing ? this.tx('source_testing') : this.tx('source_test')).fontSize(13)
            .backgroundColor(buildPalette(this.theme).pillBg).fontColor(buildPalette(this.theme).subText).stateEffect(false)
            .layoutWeight(1).margin({ left: 10 })
            .onClick((): void => { this.test(); })
        }
        .width('100%')

        Text(this.message)
          .fontSize(12).fontColor('#B4694A')
          .width('100%').margin({ top: 12 })

        Text(this.tx('source_disclaimer'))
          .fontSize(11).fontColor(buildPalette(this.theme).subText)
          .width('100%').margin({ top: 18 })
      }
      .width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // 不能在不定高的父容器里用 layoutWeight：会塌成 0 高度；这里随内容自然展开
    .alignItems(HorizontalAlign.Start)
  }
}
