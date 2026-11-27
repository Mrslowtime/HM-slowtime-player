/**
 * 国际化（i18n）—— 接入 rawfile/lang 下的三语言表（zh_cn/zh_tw/en_us，共 528 条）。
 *
 * 设计：
 *  - 运行期从 rawfile 懒加载对应语言的 JSON（首次用到才读，读后缓存）；
 *  - t(key, params?) 查找顺序：当前语言表 → 鸿蒙版专属外壳表(SHELL) → SHELL 中文兜底 → key 本身；
 *  - 支持 {name} 占位插值；
 *  - 语言选择持久化到 common.langId（auto 跟随系统），切换时广播 LANGUAGE_CHANGED；
 *  - 原有 528 条文案 key 直接沿用；鸿蒙版新增的外壳串走 SHELL 表，与生成资产解耦。
 */
import { i18n } from '@kit.LocalizationKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getAppContext } from '../common/AppContext';
import { SettingStore } from '../store/SettingStore';
import { stateEvent, StateEvents } from '../store/EventBus';
import { LOG_DOMAIN, LOG_TAG } from '../common/Constants';

export type LangId = 'auto' | 'zh-cn' | 'zh-tw' | 'en-us';

const RAWFILE_NAME: Record<string, string> = {
  'zh-cn': 'zh_cn',
  'zh-tw': 'zh_tw',
  'en-us': 'en_us',
};

const ALL_LANGS: LangId[] = ['auto', 'zh-cn', 'zh-tw', 'en-us'];

/** 鸿蒙版专属外壳字符串（安卓 JSON 未覆盖），三语言兜底 */
const SHELL: Record<string, Record<string, string>> = {
  'zh-cn': {
    'nav_my_list': '我的列表', 'nav_songlist': '在线歌单', 'nav_top': '排行榜',
    'nav_search': '搜索', 'nav_download': '下载管理', 'nav_local': '本地音乐', 'nav_setting': '设置',
    'g_basic': '基本设置', 'g_player': '播放设置', 'g_playDetail': '播放页',
    'g_desktopLyric': '桌面歌词（系统播控）', 'g_search': '搜索设置', 'g_list': '列表设置',
    'g_download': '下载设置', 'g_sync': '数据同步', 'g_cache': '缓存设置',
    'g_theme': '主题设置', 'g_tool': '工具', 'g_source': '音源服务',
    'tool_about': '关于', 'tool_log': '运行日志', 'tool_dislike': '不喜欢列表', 'tool_backup': '数据备份与恢复',
    'g_dislike': '不喜欢列表', 'g_backup': '数据备份与恢复', 'g_log': '运行日志', 'g_about': '关于·慢时光音乐（鸿蒙原生版）',
    // 设置项下拉选项文案（跟随界面语言）
    'opt_alias': '简称', 'opt_real': '全名',
    'opt_lossless': '无损', 'opt_hires': 'Hi-Res',
    'opt_align_left': '左对齐', 'opt_align_center': '居中', 'opt_align_right': '右对齐',
    'opt_cache_unlimited': '不限（缓存整首）',
    'opt_top': '顶部', 'opt_bottom': '底部',
    'log_view': '查看日志', 'log_hide': '收起日志', 'log_clear': '清空日志',
    'dislike_clear': '清空不喜欢',
    'backup_export': '导出备份', 'backup_import_recent': '导入最近备份', 'backup_none': '没有可用的备份文件',
    'backup_existing': '已有备份（点击导入）：',
    'backup_desc': '把设置与"我的列表"（含歌曲）导出到手机「下载/com.slowtime.hmplayer/备份」，卸载应用不会丢失；导入可恢复。仅本机存储，无云端。',
    'backup_pick_file': '从文件中选择备份…',
    'about_desc': '数据全部保存在本机沙箱，不与任何服务器同步；在线播放依赖你自行配置、且已获授权的音源服务。App 不内置任何音源、脚本或音乐内容。',
    'lang_auto': '跟随系统', 'lang_zh_cn': '简体中文', 'lang_zh_tw': '繁體中文', 'lang_en_us': 'English',
    'source_save': '保存', 'source_test': '测试连通', 'source_testing': '测试中…',
    'processing': '处理中…',
    'more_title': '更多', 'timer_title': '定时停止', 'timer_off': '关闭',
    'min_unit': '分钟', 'timer_prefix': '定时',
    'timer_desc': '到点后自动停止播放；最后 15 秒音量渐弱到静音。定时器仅在本次运行内有效。',
    'vol_prefix': '音量', 'vol_mute': '静音', 'fading': '渐弱中',
    'gesture_hint': '封面上下滑动调音量，双击播放 / 暂停',
    'tip_playing': '继续播放', 'tip_paused': '已暂停',
    'lyric_float': '系统歌词', 'lyric_float_hint': '显示在通知栏 / 锁屏 / 控制中心的播控卡片上',
    'lyric_float_on': '系统歌词已开启', 'lyric_float_off': '系统歌词已关闭',
    'edit_mode': '编辑', 'edit_done': '完成', 'select_all': '全选', 'delete_selected': '删除选中',
    'sel_prefix': '已选', 'drag_hint': '拖动 ≡ 可排序',
    'unit_song': '首',
    'new_list': '新建', 'create': '创建', 'cancel': '取消', 'confirm': '确定',
    'new_list_title': '新建我的列表', 'list_name_ph': '列表名称',
    'search_in_list': '搜索列表内歌曲', 'tap_to_play': '点歌曲即可播放',
    'play_all': '播放全部', 'collect': '收藏', 'loading': '加载中…', 'retry': '重试',
    'empty_list': '暂无内容', 'no_lyric': '暂无歌词', 'song_info': '歌曲信息',
    'field_name': '歌名', 'field_singer': '歌手', 'field_album': '专辑', 'field_source': '来源',
    'field_duration': '时长', 'field_quality': '音质', 'field_format': '格式', 'field_rate': '采样率',
    'field_depth': '位深', 'field_bitrate': '比特率', 'field_channel': '声道', 'unknown': '未知',
    'download_queued': '已加入下载队列',
    'download_done': '下载完成',
    'search_ph': '搜索歌曲 / 歌手', 'search_btn': '搜索', 'all': '全部',
    'hot_search': '热门搜索', 'history_search': '历史搜索', 'clear': '清空',
    'load_more': '加载更多', 'searching': '搜索中…',
    'no_more': '没有更多了', 'search_total': '共 ',
    'search_tab_song': '歌曲', 'search_tab_list': '歌单',
    'search_list_none': '没有找到相关歌单', 'unit_playlist': '个歌单',
    'search_try_other': '换个关键词，或点上方的音源再试一次',
    'not_found': '未找到相关歌曲', 'empty_songlist': '暂无歌单，试试其他音源',
    'search_hint': '输入关键词，搜索全网歌曲', 'sort_new': '最新 ↓', 'sort_hot': '最热 ↓',
    'recommend': '推荐', 'downloading': '下载中', 'paused': '已暂停', 'done': '已完成',
    'failed': '失败', 'waiting': '等待中', 'pause': '暂停', 'resume': '继续',
    'delete': '删除', 'play': '播放', 'scan': '重新扫描', 'scanning': '扫描中…',
    'local_empty': '本地还没有歌曲。\n先到在线页下载，或把音频文件放进沙箱下载目录。',
    'clear_done': '清空已完成', 'dl_dir_hint': '下载文件保存在应用沙箱 downloads 目录，点「导出」可另存到「文件」App 后复制移动',
    'dl_dir_hint_public': '下载文件直接存到手机「下载」目录（「文件」App 可见），无需导出，不占双份空间',
    'opt_dl_public': '手机「下载」目录（直接可见，无需导出）', 'opt_dl_sandbox': '应用内（需导出）',
    'opt_dl_public_short': '手机下载',
    'dl_multi': '多选', 'dl_select_all': '全选', 'dl_more': '更多', 'dl_selected': '已选',
    'dl_filter_all': '全部', 'dl_filter_active': '进行中', 'dl_filter_done': '已完成', 'dl_filter_error': '失败',
    'dl_batch_delete': '删除选中（含文件）', 'dl_batch_delete_confirm': '再点一次确认删除',
    'dl_batch_remove': '移除选中记录', 'dl_batch_cancel': '取消选中任务', 'dl_batch_play': '播放选中',
    'dl_batch_done': '已完成批量操作', 'dl_no_selection': '先长按或点击选中任务',
    'dl_empty': '暂无下载任务', 'dl_empty_hint': '在播放详情页或歌单页点「下载」即可加入',
    'queuing': '排队中', 'remove_record': '移除记录',
    'export': '导出', 'export_done': '已导出到「文件」App', 'export_fail': '导出失败',
    'export_to': '导出到...', 'export_to_done': '已导出到指定文件夹',
    'dl_delete_file': '删除（含文件）', 'dl_delete_confirm': '再点一次确认删除',
    'no_playing': '暂无播放',
    'mode_random': '随机', 'mode_list': '顺序', 'mode_single': '单曲', 'mode_none': '禁用', 'mode_loop': '列表循环',
    'playlist_detail': '歌单详情', 'board_detail': '榜单详情', 'songs_n': '{n} 首',
    'refresh': '刷新', 'local_source_hint': '来自手机本地文件',
    'local_empty_title': '暂无本地音乐', 'edit_meta': '编辑元数据',
    'cover_url': '封面URL', 'delete_file': '删除文件',
    'back': '返回', 'play_count_unit': '次播放', 'collected': '已收藏', 'download_all': '下载全部',
    'app_name': '慢时光音乐', 'app_subtitle': '鸿蒙原生版',
    'desk_lyric_note': '系统级桌面悬浮窗需系统签名权限，三方应用无法申请。鸿蒙版的「桌面歌词」由系统媒体播控卡片承载：开启 desktopLyric.enable 后，当前歌词实时同步到通知栏、锁屏与控制中心；App 退到后台或锁屏也能看到。歌词为系统限制的单行呈现，不支持自定义字体、颜色与位置。',
    'cache_note': '整曲音频缓存已启用：仅在「收藏歌单」播放时，提前把下一首整曲存到本地，下一首直接从本地起播（0 请求）；用的是音源返回的直链，不增加对音源接口的请求。缓存受下方「缓存上限」管理，占用达 99% 时自动清理。歌词缓存让同一首歌不再重新匹配，封面图下载后存本地并按需压缩，滚动列表不重复请求；两者都不额外增加网络请求。下面的占用统计包含全部三类，点「立即清理」会一并清空。',
    'items': '项', 'rule': '规则', 'import': '导入',
    'source_url': '服务地址', 'source_key': '请求 Key（可留空）',
    'source_note': '在线歌曲的播放链接由音源服务提供。请填写兼容 LX 音源协议的服务地址；不填则无法播放在线歌曲（软件不内置任何音频）。',
    'source_disclaimer': '说明：App 不内置任何音源脚本、密钥或音乐内容；请只接入你已获授权、且使用方式合规的音源服务。',
  },
  'zh-tw': {
    'nav_my_list': '我的列表', 'nav_songlist': '在線歌單', 'nav_top': '排行榜',
    'nav_search': '搜尋', 'nav_download': '下載管理', 'nav_local': '本地音樂', 'nav_setting': '設定',
    'g_basic': '基本設定', 'g_player': '播放設定', 'g_playDetail': '播放頁',
    'g_desktopLyric': '桌面歌詞（系統播控）', 'g_search': '搜尋設定', 'g_list': '列表設定',
    'g_download': '下載設定', 'g_sync': '資料同步', 'g_cache': '快取設定',
    'g_theme': '主題設定', 'g_tool': '工具', 'g_source': '音源服務',
    'tool_about': '關於', 'tool_log': '運行日誌', 'tool_dislike': '不喜歡列表', 'tool_backup': '資料備份與還原',
    'g_dislike': '不喜歡列表', 'g_backup': '資料備份與還原', 'g_log': '運行日誌', 'g_about': '關於·慢時光音樂（鴻蒙原生版）',
    'opt_alias': '簡稱', 'opt_real': '全名',
    'opt_lossless': '無損', 'opt_hires': 'Hi-Res',
    'opt_align_left': '左對齊', 'opt_align_center': '置中', 'opt_align_right': '右對齊',
    'opt_cache_unlimited': '不限（快取整首）',
    'opt_top': '頂部', 'opt_bottom': '底部',
    'log_view': '檢視日誌', 'log_hide': '收起日誌', 'log_clear': '清空日誌',
    'dislike_clear': '清空不喜歡',
    'backup_export': '匯出備份', 'backup_import_recent': '匯入最近備份', 'backup_none': '沒有可用的備份檔案',
    'backup_existing': '已有備份（點擊匯入）：',
    'backup_desc': '把設定與「我的列表」（含歌曲）匯出到手機「下載/com.slowtime.hmplayer/備份」，解除安裝不會遺失；匯入可還原。僅本機儲存，無雲端。',
    'backup_pick_file': '從檔案中選擇備份…',
    'about_desc': '資料全部儲存於本機沙箱，不與任何伺服器同步；線上播放依賴你自行設定、且已獲授權的音源服務。App 不內建任何音源、腳本或音樂內容。',
    'lang_auto': '跟隨系統', 'lang_zh_cn': '簡體中文', 'lang_zh_tw': '繁體中文', 'lang_en_us': 'English',
    'source_save': '儲存', 'source_test': '測試連通', 'source_testing': '測試中…',
    'processing': '處理中…',
    'more_title': '更多', 'timer_title': '定時停止', 'timer_off': '關閉',
    'min_unit': '分鐘', 'timer_prefix': '定時',
    'timer_desc': '到點後自動停止播放；最後 15 秒音量漸弱至靜音。計時器僅在本次執行內有效。',
    'vol_prefix': '音量', 'vol_mute': '靜音', 'fading': '漸弱中',
    'gesture_hint': '封面上下滑動調音量，雙擊播放 / 暫停',
    'tip_playing': '繼續播放', 'tip_paused': '已暫停',
    'lyric_float': '系統歌詞', 'lyric_float_hint': '顯示在通知列 / 鎖屏 / 控制中心的播控卡片上',
    'lyric_float_on': '系統歌詞已開啟', 'lyric_float_off': '系統歌詞已關閉',
    'edit_mode': '編輯', 'edit_done': '完成', 'select_all': '全選', 'delete_selected': '刪除選中',
    'sel_prefix': '已選', 'drag_hint': '拖動 ≡ 可排序',
    'unit_song': '首',
    'new_list': '新增', 'create': '建立', 'cancel': '取消', 'confirm': '確定',
    'new_list_title': '新增我的列表', 'list_name_ph': '列表名稱',
    'search_in_list': '搜尋列表內歌曲', 'tap_to_play': '點歌曲即可播放',
    'play_all': '播放全部', 'collect': '收藏', 'loading': '載入中…', 'retry': '重試',
    'empty_list': '暫無內容', 'no_lyric': '暫無歌詞', 'song_info': '歌曲資訊',
    'field_name': '歌名', 'field_singer': '歌手', 'field_album': '專輯', 'field_source': '來源',
    'field_duration': '時長', 'field_quality': '音質', 'field_format': '格式', 'field_rate': '取樣率',
    'field_depth': '位深', 'field_bitrate': '位元率', 'field_channel': '聲道', 'unknown': '未知',
    'download_queued': '已加入下載佇列',
    'download_done': '下載完成',
    'search_ph': '搜尋歌曲 / 歌手', 'search_btn': '搜尋', 'all': '全部',
    'hot_search': '熱門搜尋', 'history_search': '歷史搜尋', 'clear': '清空',
    'load_more': '載入更多', 'searching': '搜尋中…',
    'no_more': '沒有更多了', 'search_total': '共 ',
    'search_tab_song': '歌曲', 'search_tab_list': '歌單',
    'search_list_none': '找不到相關歌單', 'unit_playlist': '個歌單',
    'search_try_other': '換個關鍵字，或點上方的音源再試一次',
    'not_found': '未找到相關歌曲', 'empty_songlist': '暫無歌單，試試其他音源',
    'search_hint': '輸入關鍵字，搜尋全網歌曲', 'sort_new': '最新 ↓', 'sort_hot': '最熱 ↓',
    'recommend': '推薦', 'downloading': '下載中', 'paused': '已暫停', 'done': '已完成',
    'failed': '失敗', 'waiting': '等待中', 'pause': '暫停', 'resume': '繼續',
    'delete': '刪除', 'play': '播放', 'scan': '重新掃描', 'scanning': '掃描中…',
    'local_empty': '本地還沒有歌曲。\n先到線上頁下載，或把音訊檔放進沙箱下載目錄。',
    'clear_done': '清空已完成', 'dl_dir_hint': '下載檔案儲存在應用沙箱 downloads 目錄，點「匯出」可另存到「檔案」App 後複製移動',
    'dl_dir_hint_public': '下載檔案直接存到手機「下載」目錄（「檔案」App 可見），無需匯出，不佔雙份空間',
    'opt_dl_public': '手機「下載」目錄（直接可見，無需匯出）', 'opt_dl_sandbox': '應用內（需匯出）',
    'opt_dl_public_short': '手機下載',
    'dl_multi': '多選', 'dl_select_all': '全選', 'dl_more': '更多', 'dl_selected': '已選',
    'dl_filter_all': '全部', 'dl_filter_active': '進行中', 'dl_filter_done': '已完成', 'dl_filter_error': '失敗',
    'dl_batch_delete': '刪除選中（含檔案）', 'dl_batch_delete_confirm': '再點一次確認刪除',
    'dl_batch_remove': '移除選中記錄', 'dl_batch_cancel': '取消選中任務', 'dl_batch_play': '播放選中',
    'dl_batch_done': '已完成批量操作', 'dl_no_selection': '先長按或點擊選中任務',
    'dl_empty': '暫無下載任務', 'dl_empty_hint': '在播放詳情頁或歌單頁點「下載」即可加入',
    'queuing': '排隊中', 'remove_record': '移除記錄',
    'export': '匯出', 'export_done': '已匯出到「檔案」App', 'export_fail': '匯出失敗',
    'export_to': '匯出到...', 'export_to_done': '已匯出到指定資料夾',
    'dl_delete_file': '刪除（含檔案）', 'dl_delete_confirm': '再點一次確認刪除',
    'no_playing': '暫無播放',
    'mode_random': '隨機', 'mode_list': '順序', 'mode_single': '單曲', 'mode_none': '禁用', 'mode_loop': '列表循環',
    'playlist_detail': '歌單詳情', 'board_detail': '榜單詳情', 'songs_n': '{n} 首',
    'refresh': '重新整理', 'local_source_hint': '來自手機本機檔案',
    'local_empty_title': '暫無本地音樂', 'edit_meta': '編輯中繼資料',
    'cover_url': '封面URL', 'delete_file': '刪除檔案',
    'back': '返回', 'play_count_unit': '次播放', 'collected': '已收藏', 'download_all': '下載全部',
    'app_name': '慢時光音樂', 'app_subtitle': '鴻蒙原生版',
    'desk_lyric_note': '系統級桌面懸浮窗需系統簽名權限，第三方應用無法申請。鴻蒙版的「桌面歌詞」由系統媒體播控卡片承載：開啟 desktopLyric.enable 後，目前歌詞即時同步到通知列、鎖屏與控制中心；App 退到背景或鎖屏也能看到。歌詞為系統限制的單行呈現，不支援自訂字體、顏色與位置。',
    'cache_note': '整曲音頻快取已啟用：僅在「收藏歌單」播放時，提前把下一首整曲存到本地，下一首直接從本地起播（0 請求）；用的是音源返回的直鏈，不增加對音源介面的請求。快取受下方「快取上限」管理，佔用達 99% 時自動清理。歌詞快取讓同一首歌不再重新配對，封面圖下載後存本地並按需壓縮，捲動列表不重複請求；兩者都不額外增加網路請求。下面的佔用統計包含全部三類，點「立即清理」會一併清空。',
    'items': '項', 'rule': '規則', 'import': '匯入',
    'source_url': '服務位址', 'source_key': '請求 Key（可留空）',
    'source_note': '線上歌曲的播放連結由音源服務提供。請填寫相容 LX 音源協定的服務位址；未填則無法播放在線歌曲（軟體內不建任何音訊）。',
    'source_disclaimer': '說明：App 不內建任何音源腳本、金鑰或音樂內容；請只接入你已獲授權、且使用方式合規的音源服務。',
  },
  'en-us': {
    'nav_my_list': 'My Lists', 'nav_songlist': 'Online Songlists', 'nav_top': 'Charts',
    'nav_search': 'Search', 'nav_download': 'Downloads', 'nav_local': 'Local Music', 'nav_setting': 'Settings',
    'g_basic': 'General', 'g_player': 'Playback', 'g_playDetail': 'Player Page',
    'g_desktopLyric': 'Desktop Lyric (System)', 'g_search': 'Search', 'g_list': 'List',
    'g_download': 'Download', 'g_sync': 'Data Sync', 'g_cache': 'Cache',
    'g_theme': 'Theme', 'g_tool': 'Tools', 'g_source': 'Source Service',
    'tool_about': 'About', 'tool_log': 'Run Log', 'tool_dislike': 'Disliked', 'tool_backup': 'Backup & Restore',
    'g_dislike': 'Disliked', 'g_backup': 'Backup & Restore', 'g_log': 'Run Log', 'g_about': 'About · Slow Time Music (HarmonyOS Native)',
    'opt_alias': 'Short', 'opt_real': 'Full',
    'opt_lossless': 'Lossless', 'opt_hires': 'Hi-Res',
    'opt_align_left': 'Left', 'opt_align_center': 'Center', 'opt_align_right': 'Right',
    'opt_cache_unlimited': 'Unlimited (whole track)',
    'opt_top': 'Top', 'opt_bottom': 'Bottom',
    'log_view': 'View Log', 'log_hide': 'Hide Log', 'log_clear': 'Clear Log',
    'dislike_clear': 'Clear Disliked',
    'backup_export': 'Export Backup', 'backup_import_recent': 'Import Latest', 'backup_none': 'No backup available',
    'backup_existing': 'Existing backups (tap to import):',
    'backup_desc': 'Export settings and "My Lists" (with songs) to Download/com.slowtime.hmplayer/备份 on your phone — it survives uninstalling the app. Import to restore. Local only, no cloud.',
    'backup_pick_file': 'Choose backup file…',
    'about_desc': 'All data stays in the local sandbox and is never synced to any server. Online playback depends on a source service you configure and are authorized to use. The app ships no audio sources, scripts, or music content.',
    'lang_auto': 'Follow System', 'lang_zh_cn': 'Simplified Chinese', 'lang_zh_tw': 'Traditional Chinese', 'lang_en_us': 'English',
    'source_save': 'Save', 'source_test': 'Test Connection', 'source_testing': 'Testing…',
    'processing': 'Processing…',
    'more_title': 'More', 'timer_title': 'Sleep Timer', 'timer_off': 'Off',
    'min_unit': 'min', 'timer_prefix': 'Timer',
    'timer_desc': 'Playback stops when time is up, fading out over the last 15 seconds. The timer lives only in this run.',
    'vol_prefix': 'Volume', 'vol_mute': 'Muted', 'fading': 'Fading out',
    'gesture_hint': 'Swipe up/down on the cover to change volume, double-tap to play/pause',
    'tip_playing': 'Playing', 'tip_paused': 'Paused',
    'lyric_float': 'System Lyrics', 'lyric_float_hint': 'Shown on the media card in the notification shade, lock screen and Control Center',
    'lyric_float_on': 'System lyrics on', 'lyric_float_off': 'System lyrics off',
    'edit_mode': 'Edit', 'edit_done': 'Done', 'select_all': 'Select All', 'delete_selected': 'Delete',
    'sel_prefix': 'Selected', 'drag_hint': 'Drag ≡ to reorder',
    'unit_song': 'tracks',
    'new_list': 'New', 'create': 'Create', 'cancel': 'Cancel', 'confirm': 'OK',
    'new_list_title': 'New List', 'list_name_ph': 'List name',
    'search_in_list': 'Search in this list', 'tap_to_play': 'Tap a track to play',
    'play_all': 'Play All', 'collect': 'Favorite', 'loading': 'Loading…', 'retry': 'Retry',
    'empty_list': 'Nothing here', 'no_lyric': 'No lyrics', 'song_info': 'Track Info',
    'field_name': 'Title', 'field_singer': 'Artist', 'field_album': 'Album', 'field_source': 'Source',
    'field_duration': 'Duration', 'field_quality': 'Quality', 'field_format': 'Format', 'field_rate': 'Sample rate',
    'field_depth': 'Bit depth', 'field_bitrate': 'Bitrate', 'field_channel': 'Channels', 'unknown': 'Unknown',
    'download_queued': 'Added to download queue',
    'download_done': 'Downloaded',
    'search_ph': 'Search songs / artists', 'search_btn': 'Search', 'all': 'All',
    'hot_search': 'Trending', 'history_search': 'Recent', 'clear': 'Clear',
    'load_more': 'Load More', 'searching': 'Searching…',
    'no_more': 'No more results', 'search_total': 'Total ',
    'search_tab_song': 'Songs', 'search_tab_list': 'Playlists',
    'search_list_none': 'No playlists found', 'unit_playlist': 'playlists',
    'search_try_other': 'Try another keyword, or pick a different source above',
    'not_found': 'No matching songs', 'empty_songlist': 'No songlists — try another source',
    'search_hint': 'Type a keyword to search all sources', 'sort_new': 'Newest ↓', 'sort_hot': 'Hottest ↓',
    'recommend': 'Recommended', 'downloading': 'Downloading', 'paused': 'Paused', 'done': 'Done',
    'failed': 'Failed', 'waiting': 'Queued', 'pause': 'Pause', 'resume': 'Resume',
    'delete': 'Delete', 'play': 'Play', 'scan': 'Rescan', 'scanning': 'Scanning…',
    'local_empty': 'No local songs yet.\nDownload from the online pages, or drop audio files into the sandbox download folder.',
    'clear_done': 'Clear Done', 'dl_dir_hint': 'Downloads are stored in the app sandbox; tap "Export" to save them to the Files app',
    'dl_dir_hint_public': 'Downloads go straight to the phone Downloads folder (visible in Files); no export needed, no duplicate disk usage',
    'opt_dl_public': 'Phone Downloads (visible, no export)', 'opt_dl_sandbox': 'In-app (export required)',
    'opt_dl_public_short': 'Downloads',
    'dl_multi': 'Select', 'dl_select_all': 'All', 'dl_more': 'More', 'dl_selected': 'Selected',
    'dl_filter_all': 'All', 'dl_filter_active': 'Active', 'dl_filter_done': 'Done', 'dl_filter_error': 'Failed',
    'dl_batch_delete': 'Delete selected (with files)', 'dl_batch_delete_confirm': 'Tap again to confirm deletion',
    'dl_batch_remove': 'Remove selected records', 'dl_batch_cancel': 'Cancel selected tasks', 'dl_batch_play': 'Play selected',
    'dl_batch_done': 'Batch action completed', 'dl_no_selection': 'Long-press or tap to select tasks first',
    'dl_empty': 'No download tasks', 'dl_empty_hint': 'Tap "Download" on a song or playlist to queue it',
    'queuing': 'Queued', 'remove_record': 'Remove',
    'export': 'Export', 'export_done': 'Saved to the Files app', 'export_fail': 'Export failed',
    'export_to': 'Export to...', 'export_to_done': 'Exported to chosen folder',
    'dl_delete_file': 'Delete (with file)', 'dl_delete_confirm': 'Tap again to confirm',
    'no_playing': 'Nothing playing',
    'mode_random': 'Shuffle', 'mode_list': 'In Order', 'mode_single': 'Single', 'mode_none': 'Off', 'mode_loop': 'Loop List',
    'playlist_detail': 'Playlist', 'board_detail': 'Chart', 'songs_n': '{n} tracks',
    'refresh': 'Refresh', 'local_source_hint': 'From local files',
    'local_empty_title': 'No local music', 'edit_meta': 'Edit Metadata',
    'cover_url': 'Cover URL', 'delete_file': 'Delete File',
    'back': 'Back', 'play_count_unit': 'plays', 'collected': 'Favorited', 'download_all': 'Download All',
    'app_name': 'Slow Time Music', 'app_subtitle': 'HarmonyOS Native',
    'desk_lyric_note': 'A system-level floating window needs system-signature privileges that third-party apps cannot obtain. This port renders desktop lyrics through the system media card instead: with desktopLyric.enable on, the current line is pushed live to the notification shade, lock screen and Control Center, and stays visible in background. The system only supports a single line, so custom font, colour and position are not applicable.',
    'cache_note': 'Full-track audio caching is on: while playing a favorited playlist, the next track is stored locally in advance so it starts from disk with zero requests. It uses the direct CDN link returned by the source, so no extra request hits the source API. The cache is bounded by the limit below and purged automatically at 99% usage. Lyrics are stored so the same song is never matched twice, and cover images are cached and compressed so scrolling never re-requests them. The usage below covers all three, and "Clear now" removes them together.',
    'items': 'items', 'rule': 'rules', 'import': 'Import',
    'source_url': 'Service URL', 'source_key': 'API Key (optional)',
    'source_note': 'Online playback URLs come from your source service. Enter an LX-compatible endpoint; if left empty, online songs cannot be played (the app bundles no audio files).',
    'source_disclaimer': 'The app ships no source scripts, keys, or music content. Only connect services you are authorized to use and that you operate compliantly.',
  },
};

function resolveAuto(): LangId {
  try {
    const sys = i18n.System.getSystemLanguage();
    if (sys.startsWith('zh')) {
      if (sys.includes('TW') || sys.includes('HK') || sys.includes('MO')) {
        return 'zh-tw';
      }
      return 'zh-cn';
    }
    if (sys.startsWith('en')) {
      return 'en-us';
    }
    return 'zh-cn';
  } catch (e) {
    return 'zh-cn';
  }
}

function resolveLang(id: LangId): LangId {
  return id === 'auto' ? resolveAuto() : id;
}

class I18nImpl {
  private current: LangId = 'auto';
  private tables: Map<string, Record<string, string>> = new Map();
  private readonly settingKey: string = 'common.langId';

  async init(): Promise<void> {
    const s = SettingStore.getInstance();
    await s.init();
    const saved = s.getString(this.settingKey, 'auto');
    this.current = ALL_LANGS.indexOf(saved as LangId) >= 0 ? (saved as LangId) : 'auto';
    await this.ensureLoaded(resolveLang(this.current));
  }

  private async ensureLoaded(lang: LangId): Promise<Record<string, string>> {
    const cached = this.tables.get(lang);
    if (cached !== undefined) {
      return cached;
    }
    const tbl = await this.loadRaw(lang);
    this.tables.set(lang, tbl);
    return tbl;
  }

  private async loadRaw(lang: LangId): Promise<Record<string, string>> {
    const name = RAWFILE_NAME[lang] ?? 'zh_cn';
    const ctx = getAppContext();
    if (ctx === null) {
      return {};
    }
    try {
      const data: Uint8Array = await ctx.resourceManager.getRawFileContent('lang/' + name + '.json');
      const text = new util.TextDecoder().decodeToString(data);
      return JSON.parse(text) as Record<string, string>;
    } catch (e) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'I18n loadRaw failed: %{public}s', (e as Error).message ?? '');
      return {};
    }
  }

  /** 取翻译文本；params 用于 {name} 占位插值 */
  t(key: string, params?: Record<string, string>): string {
    const lang = resolveLang(this.current);
    let s: string | undefined = this.tables.get(lang)?.[key];
    if (s === undefined) {
      s = SHELL[lang]?.[key];
    }
    if (s === undefined) {
      s = SHELL['zh-cn']?.[key];
    }
    let out: string = s === undefined ? key : s;
    if (params !== undefined) {
      Object.keys(params).forEach((k: string): void => {
        const re = new RegExp('\\{' + k + '\\}', 'g');
        out = out.replace(re, params[k]);
      });
    }
    return out;
  }

  async setLang(id: LangId): Promise<void> {
    this.current = id;
    await SettingStore.getInstance().set(this.settingKey, id);
    await this.ensureLoaded(resolveLang(id));
    stateEvent().emit(StateEvents.LANGUAGE_CHANGED);
  }

  getLang(): LangId {
    return this.current;
  }
}

let sI18n: I18nImpl | null = null;

export function I18n(): I18nImpl {
  if (sI18n === null) {
    sI18n = new I18nImpl();
  }
  return sI18n;
}
