/**
 * 自定义源管理弹窗（按「自定义源管理」）+ 音源更新提示弹窗。
 *
 * 管理弹窗内容：
 *   - 已导入脚本列表：名称/版本/作者/描述、「允许显示更新弹窗」复选、右侧删除
 *   - 源编写说明与风险提示
 *   - 在线导入（用户自填 http(s) URL，响应体即 .js 文本）/ 本地导入（系统文件选择器，不限扩展名）
 * App 不预置任何公共音源地址或脚本，全部由用户自行导入。
 * 更新弹窗由脚本 send(EVENT_NAMES.updateAlert) 触发，受 allowShowUpdateAlert 开关控制。
 */
import { ThemeInfo, buildPalette } from '../theme/Themes';
import { CustomScriptStore, CustomScriptMeta, MAX_SCRIPT_CHARS,
  ImportPickResult,
  candidateScriptUrls, parseScriptHeader } from '../core/net/CustomScriptStore';
import { CustomScriptRunner } from '../core/net/CustomScriptRunner';
import { MusicUrlResolver } from '../core/net/MusicUrlResolver';
import { HttpClient, HttpOptions, HttpResult, makeHttpOptions } from '../core/net/HttpClient';
import { stateEvent, StateEvents } from '../store/EventBus';
import { pasteboard } from '@kit.BasicServicesKit';
import { userNotice } from '../core/UserNotice';
import { screenWidthVp } from '../config/ScreenMetrics';

function hostOf(url: string): string {
  const m: RegExpExecArray | null = /^https?:\/\/([^/]+)/.exec(url);
  return m !== null ? m[1] : url;
}

@Component
export struct CustomSourceManager {
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  onClose: () => void = () => {};

  @State private scripts: CustomScriptMeta[] = [];
  @State private showOnline: boolean = false;
  @State private onlineUrl: string = '';
  @State private busy: boolean = false;
  @State private message: string = '';

  private store: CustomScriptStore = CustomScriptStore.getInstance();

  async aboutToAppear(): Promise<void> {
    await this.reload();
  }

  private async reload(): Promise<void> {
    await this.store.init();
    this.scripts = this.store.list();
  }


  /** 在线导入：GitHub raw 直链在国内常不可达，自动逐个尝试已验证的镜像 */
  private async importOnline(url: string): Promise<void> {
    const u: string = url.trim();
    if (!/^https?:\/\//.test(u)) {
      this.message = '请填写 http(s):// 开头的脚本地址';
      return;
    }
    this.busy = true;
    const candidates: string[] = candidateScriptUrls(u);
    const errors: string[] = [];
    for (const c of candidates) {
      const opts: HttpOptions = makeHttpOptions();
      opts.method = 'GET';
      opts.headers = { 'Accept': '*/*' };
      opts.timeoutMs = 12000;
      opts.allowHttp = true;
      const r: HttpResult = await HttpClient.request(c, opts);
      if (!r.ok || r.text.length === 0) {
        errors.push(hostOf(c) + '：' + (r.error.length > 0 ? r.error : '响应为空'));
        continue;
      }
      if (r.text.length > MAX_SCRIPT_CHARS) {
        errors.push(hostOf(c) + '：脚本超过 9,000,000 字符');
        continue;
      }
      if (parseScriptHeader(r.text) === null) {
        errors.push(hostOf(c) + '：返回的不是有效音源脚本');
        continue;
      }
      this.busy = false;
      await this.finishImport(r.text, hostOf(c));
      return;
    }
    this.busy = false;
    this.message = '下载失败：' + errors.join('；');
  }

  private async importLocal(): Promise<void> {
    this.busy = true;
    const result: ImportPickResult = await this.store.importFromPicker();
    this.busy = false;
    if (result.status === 'cancel') {
      return;
    }
    if (result.status === 'invalid') {
      this.message = '导入失败：' + (result.detail.length > 0 ? result.detail : '内容不是通用 JS 音源脚本');
      return;
    }
    if (result.status === 'error') {
      this.message = '读取文件失败：' + result.detail;
      return;
    }
    // 可能覆盖了当前生效脚本，让沙箱与直链缓存一起失效
    CustomScriptRunner.getInstance().invalidate();
    MusicUrlResolver.getInstance().clearCache();
    this.message = '导入成功，请回到设置页勾选该音源以启用';
    await this.reload();
    stateEvent().emit(StateEvents.CUSTOM_SOURCE_CHANGED);
  }

  private async finishImport(text: string, from: string): Promise<void> {
    const activeBefore: CustomScriptMeta | null = this.store.getActive();
    const meta: CustomScriptMeta | null = await this.store.importScript(text, from);
    if (meta === null) {
      this.message = '导入失败：' + (this.store.getLastError().length > 0
        ? this.store.getLastError() : '内容不是通用 JS 音源脚本');
      return;
    }
    // 同名同版本会覆盖正文；若被覆盖的正是当前生效脚本，必须让沙箱重新加载
    if (activeBefore !== null && activeBefore.id === meta.id) {
      CustomScriptRunner.getInstance().invalidate();
      MusicUrlResolver.getInstance().clearCache();
    }
    this.message = '已导入：' + meta.name + ' ' + meta.version +
      '（来源：' + from + '），请回到设置页勾选启用';
    this.showOnline = false;
    await this.reload();
    stateEvent().emit(StateEvents.CUSTOM_SOURCE_CHANGED);
  }

  private async remove(id: string): Promise<void> {
    const active: CustomScriptMeta | null = this.store.getActive();
    const wasActive: boolean = active !== null && active.id === id;
    await this.store.remove(id);
    if (wasActive) {
      CustomScriptRunner.getInstance().invalidate();
      MusicUrlResolver.getInstance().clearCache();
    }
    this.message = '已删除该自定义源';
    await this.reload();
    stateEvent().emit(StateEvents.CUSTOM_SOURCE_CHANGED);
  }

  private async toggleAlert(id: string, on: boolean): Promise<void> {
    await this.store.setAllowUpdateAlert(id, on);
    this.scripts = this.store.list();
  }

  private copyUpdateUrl(url: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        userNotice().info('更新地址已复制');
      }).catch((): void => {
        userNotice().warn('复制失败');
      });
    } catch (e) {
      userNotice().warn('复制失败');
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onClose(); })

      Column() {
        // 标题栏
        Row() {
          Text('自定义源管理')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.font)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
          Text('✕')
            .fontSize(18)
            .fontColor(buildPalette(this.theme).subText)
            .width(32)
            .height(32)
            .textAlign(TextAlign.Center)
            .onClick((): void => { this.onClose(); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 14, bottom: 10 })

        // 列表
        Scroll() {
          Column() {
            if (this.scripts.length === 0) {
              Text('还没有音源。请用下方「在线导入」或「本地导入」添加兼容 JS 音源脚本。')
                .fontSize(12)
                .lineHeight(17)
                .fontColor(buildPalette(this.theme).subText)
                .width('100%')
                .padding({ left: 4, right: 4, top: 12, bottom: 12 })
            }
            ForEach(this.scripts, (s: CustomScriptMeta): void => {
              Column() {
                Row() {
                  Text(s.name)
                    .fontSize(14)
                    .lineHeight(18)
                    .fontColor(this.theme.font)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(s.version)
                    .fontSize(11)
                    .fontColor(buildPalette(this.theme).subText)
                    .margin({ left: 6 })
                  if (s.enabled) {
                    Text('启用中')
                      .fontSize(10)
                      .fontColor(this.theme.primary)
                      .margin({ left: 6 })
                  }
                  Text('✕')
                    .fontSize(16)
                    .fontColor(buildPalette(this.theme).subText)
                    .width(26)
                    .textAlign(TextAlign.Center)
                    .margin({ left: 2 })
                    .onClick((): void => { this.remove(s.id); })
                }
                .width('100%')

                if (s.description.length > 0) {
                  Text(s.description)
                    .fontSize(11)
                    .lineHeight(14)
                    .fontColor(buildPalette(this.theme).subText)
                    .width('100%')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                }

                Row() {
                  Text(s.allowShowUpdateAlert ? '☑' : '☐')
                    .fontSize(14)
                    .fontColor(s.allowShowUpdateAlert ? this.theme.primary : buildPalette(this.theme).subText)
                  Text('允许更新弹窗')
                    .fontSize(11)
                    .lineHeight(15)
                    .fontColor(buildPalette(this.theme).subText)
                    .margin({ left: 5 })
                }
                .width('100%')
                .margin({ top: 5 })
                .onClick((): void => { this.toggleAlert(s.id, !s.allowShowUpdateAlert); })
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 8 })
              .backgroundColor(buildPalette(this.theme).card)
              .borderRadius(9)
              .margin({ bottom: 6 })
            }, (s: CustomScriptMeta): string => s.id + '|' + s.allowShowUpdateAlert.toString() +
              '|' + s.enabled.toString())
          }
          .width('100%')
        }
        .height(252)
        .width('100%')

        // 源编写说明与风险提示
        Column() {
          Row() {
            Text('源编写说明：')
              .fontSize(11)
              .fontColor(buildPalette(this.theme).subText)
          }
          .width('100%')
          .margin({ bottom: 3 })

          Text('本地导入可选任意文本文件（含被改名成 .txt / .js.txt 的脚本），按文件开头的 @name 块注释识别。')
            .fontSize(10)
            .lineHeight(13)
            .fontColor(buildPalette(this.theme).subText)
            .width('100%')
            .margin({ bottom: 2 })
          Text('提示：脚本运行环境已尽量隔离，但导入含恶意行为的脚本仍可能影响系统，请谨慎导入。')
            .fontSize(11)
            .lineHeight(14)
            .fontColor(buildPalette(this.theme).subText)
            .width('100%')
        }
        .width('100%')
        .padding({ top: 8, bottom: 4 })

        // 在线导入展开区
        if (this.showOnline) {
          Column() {
            TextInput({ placeholder: 'https://.../latest.js', text: this.onlineUrl })
              .height(38)
              .fontSize(13)
              .backgroundColor(buildPalette(this.theme).pillBg)
              .borderRadius(8)
              .width('100%')
              .onChange((v: string): void => { this.onlineUrl = v; })

            Text('填入音源脚本的 http(s) 直链；GitHub raw 链接会自动尝试 fastly / gcore / ghproxy 镜像，都失败请把脚本存到手机后用「本地导入」。')
              .fontSize(11)
              .fontColor(buildPalette(this.theme).subText)
              .width('100%')
              .margin({ top: 8, bottom: 4 })

            Button(this.busy ? '导入中…' : '导入该地址')
              .fontSize(13)
              .backgroundColor(this.theme.primary)
              .fontColor('#FFFFFF')
              .stateEffect(false)
              .width('100%')
              .margin({ top: 4 })
              .onClick((): void => { this.importOnline(this.onlineUrl); })
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
        }

        Text(this.message)
          .fontSize(12)
          .fontColor('#B4694A')
          .width('100%')
          .margin({ top: 4, bottom: 4 })

        // 底部两个导入入口
        Row() {
          Button('在线导入')
            .fontSize(14)
            .backgroundColor(buildPalette(this.theme).pillBg)
            .fontColor(this.theme.font)
            .stateEffect(false)
            .layoutWeight(1)
            .onClick((): void => { this.showOnline = !this.showOnline; })
          Button('本地导入')
            .fontSize(14)
            .backgroundColor(buildPalette(this.theme).pillBg)
            .fontColor(this.theme.font)
            .stateEffect(false)
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick((): void => { this.importLocal(); })
        }
        .width('100%')
        .padding({ top: 6, bottom: 16 })
      }
      .width('90%')
      .constraintSize({ maxWidth: Math.min(640, screenWidthVp() * 0.9) })
      .padding({ left: 14, right: 14 })
      .backgroundColor(buildPalette(this.theme).card)
      .borderRadius(12)
      .clip(true)
      .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 6 })
    }
    .width('100%')
    .height('100%')
  }
}

/** 音源脚本 send(updateAlert) 时显示的更新提示 */
@Component
export struct CustomSourceUpdateAlert {
  @Prop theme: ThemeInfo = {
    id: 'green', name: '绿意盎然', isDark: false,
    primary: '#4DAF7C', font: '#212121', mainBackground: '#F7F7F5',
  };
  @Prop name: string = '';
  @Prop log: string = '';
  @Prop updateUrl: string = '';
  onClose: () => void = () => {};

  private copyUpdateUrl(url: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        userNotice().info('更新地址已复制');
      }).catch((): void => {
        userNotice().warn('复制失败');
      });
    } catch (e) {
      userNotice().warn('复制失败');
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick((): void => { this.onClose(); })
      Column() {
        Column().width('100%').height(5).backgroundColor(this.theme.primary)
        Text(this.name + ' · 音源更新提示')
          .fontSize(17)
          .fontColor(this.theme.font)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 18, bottom: 12 })
        Scroll() {
          Text(this.log)
            .fontSize(13)
            .fontColor(this.theme.font)
            .width('100%')
        }
        .height(160)
        .width('100%')
        if (this.updateUrl.length > 0) {
          Text('复制更新地址')
            .fontSize(13)
            .fontColor(this.theme.primary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(10)
            .onClick((): void => { this.copyUpdateUrl(this.updateUrl); })
        }
        Text('关闭')
          .fontSize(15)
          .fontColor(this.theme.primary)
          .width('100%')
          .height(44)
          .textAlign(TextAlign.Center)
          .backgroundColor(buildPalette(this.theme).pillBg)
          .borderRadius(8)
          .margin({ top: 6, bottom: 16 })
          .onClick((): void => { this.onClose(); })
      }
      .width('86%')
      .constraintSize({ maxWidth: Math.min(560, screenWidthVp() * 0.86) })
      .padding({ left: 16, right: 16 })
      .backgroundColor(buildPalette(this.theme).card)
      .borderRadius(12)
      .clip(true)
    }
    .width('100%')
    .height('100%')
  }
}
