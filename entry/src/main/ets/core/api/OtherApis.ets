/**
 * QQ音乐(tx) / 咪咕(mg) / 网易云(wy) 的静态元数据实现。
 *
 * 本轮覆盖「纯 HTTP、无需签名」的接口：联想词、热搜、榜单分类、歌单详情、
 * 歌词(base64 LRC / 纯文本)、封面拼接。
 * 明确后置（见 M2-D 进度文档）：
 *  - tx 搜索需 zzcSign(SHA1 扰乱)、QRC 歌词需非标准 3DES
 *  - mg 搜索需 MD5 签名、MRC 歌词需 TEA BigInt
 *  - wy 全部接口需 weapi/eapi/linuxapi 完整 AES+RSA 密码学栈
 *  - tx 榜单/歌单列表走 musicu.fcg 模板，可后续统一补上
 */
import {
  HttpClient, HttpResult, Json, decodeName, formatPlayTime,
  encodeQuery, base64ToUtf8, secureUrl,
} from '../net/HttpClient';
import {
  MusicInfo, ListInfoItem, BoardItem, LyricInfo, MusicInfoMetaOnline, TagInfoItem, SortInfo,
} from '../../model/MusicTypes';
import { OnlineSource } from '../../config/AppConstants';
import {
  SourceApi, SearchResult, SonglistResult, MusicListResult, TagResult,
  emptySearchResult, emptySonglistResult, emptyMusicListResult, emptyTagResult, makeMusicInfo,
} from './ApiTypes';
import {
  mgSignature, txZzcSign, wyEapiParams, wyWeapiForm,
} from '../crypto/Signatures';
import { getMgDeviceId } from '../DeviceId';
import { decodeQrcToLyric, parseEnhancedLyric } from '../crypto/LyricDecoders';
import { decryptMrc } from '../crypto/MrcDecoder';

const TX_HEADERS: Record<string, string> = {
  'Referer': 'https://y.qq.com/portal/player.html',
};

const MG_HEADERS: Record<string, string> = {
  'channel': '0146921',
  'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) ' +
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1',
  'Referer': 'https://m.music.migu.cn/',
};

/** 咪咕图片字段常为相对路径（/data/oss/...），统一补成 https 绝对地址 */
function mgPicUrl(p: string): string {
  if (p.length === 0) {
    return '';
  }
  if (p.startsWith('http://')) {
    return 'https://' + p.substring(7);
  }
  if (p.startsWith('http')) {
    return p;
  }
  return 'https://d.musicapp.migu.cn' + p;
}

/** 咪咕 resourceinfo.do 返回的歌曲资源信息（按该服务协议） */
export interface MgResourceInfo {
  songId: string;
  copyrightId: string;
  lrcUrl: string;
  mrcUrl: string;
  trcUrl: string;
}

/**
 * 咪咕歌词元数据缓存：同一 songId 的 resourceinfo.do 结果复用，
 * 避免每次 getLyric 都重复 POST（仅为元数据缓存，不涉及音源请求风控）。
 * 只缓存成功结果，失败留给下次重试；上限到顶就清空，防止长期运行无限增长。
 */
const MG_RESOURCE_CACHE: Map<string, MgResourceInfo> = new Map();
const MG_RESOURCE_CACHE_MAX: number = 1000;

/**
 * 按该服务协议 createGetMusicInfosTask：
 * POST resourceinfo.do 用版权 id 换真实 songId 与三类歌词 URL。
 */
export async function fetchMgResource(resourceId: string): Promise<MgResourceInfo | null> {
  if (resourceId.length === 0) {
    return null;
  }
  const cached: MgResourceInfo | undefined = MG_RESOURCE_CACHE.get(resourceId);
  if (cached !== undefined) {
    return cached;
  }
  const r: HttpResult = await HttpClient.post(
    'https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2',
    'resourceId=' + encodeQuery(resourceId), {
      'Content-Type': 'application/x-www-form-urlencoded',
      'channel': '0146921',
      'User-Agent': MG_HEADERS['User-Agent'],
      'Referer': MG_HEADERS['Referer'],
    });
  if (!r.ok || r.json === null) {
    return null;
  }
  const arr: Object[] = Json.arr(r.json, 'resource');
  if (arr.length === 0) {
    return null;
  }
  const it: Object = arr[0];
  const out: MgResourceInfo = {
    songId: Json.str(it, 'songId', ''),
    copyrightId: Json.str(it, 'copyrightId', ''),
    lrcUrl: Json.str(it, 'lrcUrl', ''),
    mrcUrl: Json.str(it, 'mrcUrl', ''),
    trcUrl: Json.str(it, 'trcUrl', ''),
  };
  if (out.songId.length === 0) {
    return null;
  }
  if (MG_RESOURCE_CACHE.size >= MG_RESOURCE_CACHE_MAX) {
    MG_RESOURCE_CACHE.clear();
  }
  MG_RESOURCE_CACHE.set(resourceId, out);
  return out;
}

/** 把字符串安全地嵌进手写 JSON（ArkTS 不允许 untyped 对象字面量，所以请求体用字符串拼接） */
function jsonStr(s: string): string {
  let out: string = '"';
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (c === '"') { out += '\\"'; }
    else if (c === '\\') { out += '\\\\'; }
    else if (c === '\n') { out += '\\n'; }
    else if (c === '\r') { out += '\\r'; }
    else if (c === '\t') { out += '\\t'; }
    else { out += c; }
  }
  return out + '"';
}

/** 按该服务协议：32 位大写 hex + 5 位补零随机数 */
function makeSearchId(): string {
  const hex: string = '0123456789ABCDEF';
  let guid: string = '';
  for (let i = 0; i < 32; i++) {
    guid += hex.charAt(Math.floor(Math.random() * 16));
  }
  let tail: string = Math.floor(Math.random() * 100000).toString();
  while (tail.length < 5) {
    tail = '0' + tail;
  }
  return guid + tail;
}

/** 咪咕搜索固定 searchSwitch（必须与协议字节一致，否则返回空） */
const MG_SEARCH_SWITCH: string =
  '%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1' +
  '%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D';

const MG_SEARCH_UA: string = 'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; ' +
  'MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) ' +
  'Version/4.0 Mobile Safari/534.30';

const WY_UA: string = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36';

// ============================================================ QQ音乐
export class TxApi implements SourceApi {
  readonly source: OnlineSource = 'tx';

  async search(keyword: string, page: number, limit: number): Promise<SearchResult> {
    // 按该服务协议：comm + music.search.SearchCgiService，签名走 zzcSign
    const body: string = '{"comm":{"_channelid":"0","_os_version":"6.2.9200-2","ct":"19",' +
      '"cv":"2151","guid":"1F70E520B2EAA7D25E11760783C53CA9","patch":"118",' +
      '"psrf_access_token_expiresAt":0,"psrf_qqaccess_token":"","psrf_qqopenid":"",' +
      '"psrf_qqunionid":"","tmeAppID":"qqmusic","tmeLoginType":0,"uin":"0",' +
      '"wid":"7223299733393904640"},' +
      '"music.search.SearchCgiService":{"module":"music.search.SearchCgiService",' +
      '"method":"DoSearchForQQMusicDesktop","param":{"grp":1,"num_per_page":' +
      limit.toString() + ',"page_num":' + page.toString() + ',"query":' + jsonStr(keyword) +
      ',"remoteplace":"txt.newclient.top","search_type":0,"searchid":"' + makeSearchId() + '"}}}';
    let sign: string = '';
    try {
      sign = await txZzcSign(body);
    } catch (e) {
      return emptySearchResult('tx', page, limit, 'QQ音乐签名失败');
    }
    const url: string = 'https://u.y.qq.com/cgi-bin/musics.fcg?sign=' + sign;
    const r: HttpResult = await HttpClient.post(url, body, {
      'Content-Type': 'application/json',
      'User-Agent': 'QQMusic 14090508(android 12)',
    }, 1);
    if (!r.ok || r.json === null) {
      return emptySearchResult('tx', page, limit, 'QQ音乐搜索失败：' + r.error);
    }
    const svc: Object | null = Json.obj(r.json, 'music.search.SearchCgiService');
    const data: Object | null = Json.obj(svc, 'data');
    const bodyObj: Object | null = Json.obj(data, 'body');
    const song: Object | null = Json.obj(bodyObj, 'song');
    const items: Object[] = Json.arr(song, 'list');
    const list: MusicInfo[] = [];
    for (const it of items) {
      const mid: string = Json.str(it, 'mid', '');
      const name: string = decodeName(Json.str(it, 'name', ''));
      if (mid.length === 0 || name.length === 0) { continue; }
      const singers: Object[] = Json.arr(it, 'singer');
      const names: string[] = [];
      for (const g of singers) {
        const n: string = Json.str(g, 'name', '');
        if (n.length > 0) { names.push(n); }
      }
      const file: Object | null = Json.obj(it, 'file');
      const album: Object | null = Json.obj(it, 'album');
      const dur: number = Json.num(it, 'interval', 0);
      const qs: string[] = ['128k'];
      if (Json.num(file, 'size_320mp3', 0) > 0) { qs.push('320k'); }
      if (Json.num(file, 'size_flac', 0) > 0) { qs.push('flac'); }
      if (Json.num(file, 'size_hires', 0) > 0) { qs.push('flac24bit'); }
      const albumMid: string = Json.str(album, 'mid', '');
      list.push(makeMusicInfo('tx', mid, name,
        names.length > 0 ? names.join('、') : '',
        dur > 0 ? formatPlayTime(dur) : null,
        decodeName(Json.str(album, 'name', '')),
        albumMid.length > 0
          ? 'https://y.gtimg.cn/music/photo_new/T002R500x500M000' + albumMid + '.jpg'
          : null,
        qs, {
          strMediaMid: Json.str(file, 'media_mid', ''),
          numericId: Json.str(it, 'id', ''),
        }));
    }
    return { list, total: Json.num(song, 'totalnum', list.length), page, limit, source: 'tx', error: '' };
  }

  async tipSearch(keyword: string): Promise<string[]> {
    const url: string = 'https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg?is_xml=0&format=json' +
      '&key=' + encodeQuery(keyword) + '&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8' +
      '&notice=0&platform=yqq&needNewCode=0';
    const j: Object | null = await HttpClient.getJson(url, TX_HEADERS);
    const data: Object | null = Json.obj(j, 'data');
    const song: Object | null = Json.obj(data, 'song');
    const items: Object[] = Json.arr(song, 'itemlist');
    const out: string[] = [];
    for (const it of items) {
      const n: string = decodeName(Json.str(it, 'name', ''));
      const s: string = Json.str(it, 'singer', '');
      if (n.length > 0) {
        out.push(s.length > 0 ? n + ' - ' + s : n);
      }
    }
    return out;
  }

  async hotSearch(): Promise<string[]> {
    // 固定请求体（按该服务协议 musicu.fcg 模板），写成字符串以符合 ArkTS 严格对象字面量约束
    const body: string = '{"comm":{"ct":"19","cv":"1803","guid":"0","uin":0},' +
      '"hotkey":{"method":"GetHotkeyForQQMusicPC",' +
      '"module":"tencent_musicsoso_hotkey.HotkeyService",' +
      '"param":{"search_id":"","uin":0}}}';
    const r: HttpResult = await HttpClient.post('https://u.y.qq.com/cgi-bin/musicu.fcg', body, {
      'Content-Type': 'application/json',
      'Referer': 'https://y.qq.com/portal/player.html',
    });
    const hk: Object | null = Json.obj(r.json, 'hotkey');
    const data: Object | null = Json.obj(hk, 'data');
    const items: Object[] = Json.arr(data, 'vec_hotkey');
    const out: string[] = [];
    for (const it of items) {
      const q: string = decodeName(Json.str(it, 'query', ''));
      if (q.length > 0) { out.push(q); }
    }
    return out;
  }

  async songListTags(): Promise<TagResult> {
    // QQ 音乐歌单分类：音乐库 playlist.PlaylistAllCategoriesServer.get_all_categories，
    // 返回 v_group（热门/主题/场景/心情/年代/流派/语种），零签名。
    // 旧实现只给「推荐」一项，等于歌单页没有分类可点。
    const tags: TagInfoItem[] = [{ id: '', name: '推荐' }];
    const data: string = '{"tags":{"method":"get_all_categories","param":{"qq":""},' +
      '"module":"playlist.PlaylistAllCategoriesServer"}}';
    const url: string = 'https://u.y.qq.com/cgi-bin/musicu.fcg?loginUin=0&hostUin=0' +
      '&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json' +
      '&needNewCode=0&data=' + encodeURIComponent(data);
    const r: HttpResult = await HttpClient.get(url, TX_HEADERS, 1);
    const groups: Object[] = Json.arr(Json.obj(Json.obj(r.json, 'tags'), 'data'), 'v_group');
    for (const g of groups) {
      const items: Object[] = Json.arr(g, 'v_item');
      for (const it of items) {
        const id: string = Json.str(it, 'id', '');
        const name: string = decodeName(Json.str(it, 'name', ''));
        if (id.length === 0 || name.length === 0) {
          continue;
        }
        tags.push({ id, name });
      }
    }
    return {
      tags,
      sorts: [{ tid: 'hot', id: 'hot' }, { tid: 'new', id: 'new' }],
      source: 'tx', error: '',
    };
  }

  async songList(tagId: string, sortId: string, page: number, limit: number): Promise<SonglistResult> {
    // 按该服务协议：musicu.fcg GET + data 参数（推荐 / 分类两套模板，均零签名）
    let data: string = '';
    if (tagId.length === 0) {
      data = '{"comm":{"cv":1602,"ct":20},"playlist":' +
        '{"module":"music.playlist.PlaylistSquare","method":"GetRecommendWhole",' +
        '"param":{"IsReqFeed":true,"FeedReq":{"From":' + ((page - 1) * limit).toString() +
        ',"Size":' + limit.toString() + '}}}}';
    } else {
      data = '{"comm":{"cv":1602,"ct":20},"playlist":' +
        '{"module":"playlist.PlayListCategoryServer","method":"get_category_content",' +
        '"param":{"titleid":' + tagId + ',"caller":"0","category_id":' + tagId +
        ',"size":' + limit.toString() + ',"page":' + (page - 1).toString() +
        ',"use_page":1}}}';
    }
    const url: string = 'https://u.y.qq.com/cgi-bin/musicu.fcg?loginUin=0&hostUin=0' +
      '&format=json&inCharset=utf-8&outCharset=utf-8&notice=0&platform=wk_v15.json' +
      '&needNewCode=0&data=' + encodeURIComponent(data);
    const r: HttpResult = await HttpClient.get(url, TX_HEADERS, 1);
    if (!r.ok || r.json === null) {
      return emptySonglistResult('tx', page, limit, 'QQ音乐歌单加载失败：' + r.error);
    }
    const pl: Object | null = Json.obj(r.json, 'playlist');
    const pdata: Object | null = Json.obj(pl, 'data');
    let raws: Object[] = [];
    let total: number = 0;
    if (tagId.length === 0) {
      const feed: Object | null = Json.obj(pdata, 'FeedRsp');
      const items: Object[] = Json.arr(feed, 'List');
      for (const it of items) {
        const basic: Object | null = Json.obj(Json.obj(it, 'Playlist'), 'basic');
        if (basic !== null) { raws.push(basic); }
      }
      total = Json.num(feed, 'FromLimit', raws.length + limit);
    } else {
      const content: Object | null = Json.obj(pdata, 'content');
      const items: Object[] = Json.arr(content, 'v_item');
      for (const it of items) {
        const basic: Object | null = Json.obj(it, 'basic');
        if (basic !== null) { raws.push(basic); }
      }
      total = Json.num(content, 'total_cnt', raws.length);
    }
    const list: ListInfoItem[] = [];
    for (const b of raws) {
      const id: string = Json.str(b, 'tid', '');
      if (id.length === 0) { continue; }
      const cover: Object | null = Json.obj(b, 'cover');
      const creator: Object | null = Json.obj(b, 'creator');
      list.push({
        id, name: decodeName(Json.str(b, 'title', '')),
        author: decodeName(Json.str(creator, 'nick', '')),
        play_count: Json.num(b, 'play_cnt', 0).toString(),
        time: '', img: Json.str(cover, 'medium_url', Json.str(cover, 'default_url', '')),
        desc: decodeName(Json.str(b, 'desc', '')),
        source: 'tx', total: Json.num(b, 'song_cnt', 0),
      });
    }
    return { list, total, page, limit, source: 'tx', error: '' };
  }

  async searchPlaylists(keyword: string, page: number, limit: number): Promise<SonglistResult> {
    // QQ 的搜索走 zzcSign 签名、只覆盖单曲；歌单搜索还要额外的 fcg 签名，
    // 这里明确回一句提示，比给个空白页更容易理解。
    return emptySonglistResult('tx', page, limit, 'QQ 音乐暂不支持搜歌单，可切到酷我 / 酷狗 / 网易');
  }

  async songListDetail(id: string, page: number): Promise<MusicListResult> {
    const url: string = 'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1' +
      '&json=1&utf8=1&onlysong=0&new_format=1&disstid=' + encodeQuery(id) +
      '&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0' +
      '&platform=yqq.json&needNewCode=0';
    const r: HttpResult = await HttpClient.get(url, {
      'Origin': 'https://y.qq.com',
      'Referer': 'https://y.qq.com/',
    });
    const cdlist: Object[] = Json.arr(r.json, 'cdlist');
    if (cdlist.length === 0) {
      return emptyMusicListResult('tx', page, 'QQ音乐歌单详情加载失败：' + r.error);
    }
    const songs: Object[] = Json.arr(cdlist[0], 'songlist');
    const list: MusicInfo[] = [];
    for (const s of songs) {
      const mid: string = Json.str(s, 'songmid', Json.str(s, 'mid', ''));
      const name: string = decodeName(Json.str(s, 'name', Json.str(s, 'title', '')));
      if (mid.length === 0 || name.length === 0) { continue; }
      const singers: Object[] = Json.arr(s, 'singer');
      const names: string[] = [];
      for (const g of singers) {
        const n: string = Json.str(g, 'name', '');
        if (n.length > 0) { names.push(n); }
      }
      const file: Object | null = Json.obj(s, 'file');
      const album: Object | null = Json.obj(s, 'album');
      const dur: number = Json.num(s, 'interval', 0);
      const qs: string[] = ['128k'];
      if (Json.num(file, 'size_320mp3', 0) > 0) { qs.push('320k'); }
      if (Json.num(file, 'size_flac', 0) > 0) { qs.push('flac'); }
      if (Json.num(file, 'size_hires', 0) > 0) { qs.push('flac24bit'); }
      list.push(makeMusicInfo('tx', mid, name,
        names.length > 0 ? names.join('、') : '',
        dur > 0 ? formatPlayTime(dur) : null,
        decodeName(Json.str(album, 'name', '')),
        Json.str(album, 'mid', '').length > 0
          ? 'https://y.gtimg.cn/music/photo_new/T002R500x500M000' + Json.str(album, 'mid', '') + '.jpg'
          : null,
        qs,
        { strMediaMid: Json.str(file, 'media_mid', '') }));
    }
    return {
      list, total: list.length, page, source: 'tx',
      name: decodeName(Json.str(cdlist[0], 'dissname', '')),
      desc: decodeName(Json.str(cdlist[0], 'desc', '')),
      img: Json.str(cdlist[0], 'logo', ''),
      error: '',
    };
  }

  leaderboardCategories(): BoardItem[] {
    // 封面取自官方 ToplistInfoServer.GetAll 的 frontPicUrl，静态内置零额外请求。
    // 注：topId=16 官方是「韩国榜」，旧代码误标「内地榜」（内地榜实为 5），已改正。
    return [
      { id: 'tx_26', name: '热歌榜', bangid: '26',
        img: 'https://y.gtimg.cn/music/photo_new/T003R300x300M000004auBs90LzKJ7.jpg' },
      { id: 'tx_27', name: '新歌榜', bangid: '27',
        img: 'https://y.gtimg.cn/music/photo_new/T003R300x300M0000043JzVA3y8jHZ.jpg' },
      { id: 'tx_62', name: '飙升榜', bangid: '62',
        img: 'https://y.gtimg.cn/music/photo_new/T003R300x300M0000041kZlA3lg9f8.jpg' },
      { id: 'tx_4', name: '流行指数榜', bangid: '4',
        img: 'https://y.gtimg.cn/music/photo_new/T003R300x300M0000010xI2r4Gopn5.jpg' },
      { id: 'tx_16', name: '韩国榜', bangid: '16',
        img: 'https://y.gtimg.cn/music/photo_new/T003R300x300M000002fIady3gQ1Bv.jpg' },
      { id: 'tx_3', name: '欧美榜', bangid: '3',
        img: 'https://y.gtimg.cn/music/photo_new/T003R300x300M000000KzDfO4Ny9Mw.jpg' },
    ];
  }

  async leaderboardDetail(bangid: string, page: number): Promise<MusicListResult> {
    // 按该服务协议：musicu.fcg 统一模板，无签名
    const body: string = '{"toplist":{"module":"musicToplist.ToplistInfoServer",' +
      '"method":"GetDetail","param":{"topid":' + bangid + ',"num":100,"period":""}},' +
      '"comm":{"uin":0,"format":"json","ct":20,"cv":1859}}';
    const r: HttpResult = await HttpClient.post('https://u.y.qq.com/cgi-bin/musicu.fcg', body, {
      'Content-Type': 'application/json',
      'User-Agent': 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)',
    });
    const top: Object | null = Json.obj(r.json, 'toplist');
    const data: Object | null = Json.obj(top, 'data');
    const inner: Object | null = Json.obj(data, 'data');
    const songs: Object[] = Json.arr(inner, 'song');
    const list: MusicInfo[] = [];
    for (const s of songs) {
      const songId: string = Json.str(s, 'songId', '');
      const title: string = decodeName(Json.str(s, 'title', ''));
      if (songId.length === 0 || title.length === 0) { continue; }
      const albumMid: string = Json.str(s, 'albumMid', '');
      list.push(makeMusicInfo('tx', songId, title,
        decodeName(Json.str(s, 'singerName', '')), null, '',
        albumMid.length > 0
          ? 'https://y.gtimg.cn/music/photo_new/T002R500x500M000' + albumMid + '.jpg'
          : '', ['128k', '320k']));
    }
    return {
      list, total: Json.num(inner, 'totalNum', list.length), page, source: 'tx',
      name: decodeName(Json.str(inner, 'title', '')),
      desc: decodeName(Json.str(inner, 'intro', '')),
      img: Json.str(inner, 'frontPicUrl', ''),
      error: list.length === 0 ? 'QQ音乐榜单暂无数据' : '',
    };
  }

  async getLyric(info: MusicInfo): Promise<LyricInfo | null> {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    // 优先新版 musicu.fcg：返回加密 QRC（逐字歌词），需数字 songID
    const numericId: string = meta.numericId ?? '';
    if (numericId.length > 0) {
      const body: string = '{"comm":{"ct":"19","cv":"1859","uin":"0"},' +
        '"req":{"method":"GetPlayLyricInfo","module":"music.musichallSong.PlayLyricInfo",' +
        '"param":{"format":"json","crypt":1,"ct":19,"cv":1873,"interval":0,' +
        '"lrc_t":0,"qrc":1,"qrc_t":0,"roma":1,"roma_t":0,"songID":' + numericId +
        ',"trans":1,"trans_t":0,"type":-1}}}';
      const r: HttpResult = await HttpClient.post('https://u.y.qq.com/cgi-bin/musicu.fcg', body, {
        'Content-Type': 'application/json',
        'Referer': 'https://y.qq.com',
      }, 1);
      if (r.ok && r.json !== null) {
        const req: Object | null = Json.obj(r.json, 'req');
        const data: Object | null = Json.obj(req, 'data');
        const hex: string = Json.str(data, 'lyric', '');
        if (hex.length > 0) {
          const qrc: LyricInfo | null = await decodeQrcToLyric(hex);
          if (qrc !== null && qrc.lyric.length > 0) {
            return qrc;
          }
        }
      }
    }
    // 回退：老接口返回 base64 标准 LRC
    const url: string = 'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=' +
      encodeQuery(meta.songId) + '&g_tk=5381&loginUin=0&hostUin=0&format=json' +
      '&inCharset=utf8&outCharset=utf-8&platform=yqq&nobase64=1';
    const j: Object | null = await HttpClient.getJson(url, TX_HEADERS);
    const b: Object | null = Json.obj(j, 'body');
    // nobase64=1 时接口直接返回明文；少数情况下仍返回 base64（不含 [），就地解码兜底
    let lrc: string = Json.str(b, 'lyric', '');
    if (lrc.length > 0 && !lrc.includes('[')) {
      lrc = base64ToUtf8(lrc);
    }
    if (lrc.length === 0) { return null; }
    let trans: string = Json.str(b, 'trans', '');
    if (trans.length > 0 && !trans.includes('[')) {
      trans = base64ToUtf8(trans);
    }
    return { lyric: lrc, tlyric: trans.length > 0 ? trans : null, rlyric: null, lxlyric: null };
  }

  async getPic(info: MusicInfo): Promise<string> {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    if (meta.picUrl !== undefined && meta.picUrl !== null && meta.picUrl.length > 0) {
      return meta.picUrl;
    }
    if (meta.albumId !== undefined && meta.albumId.length > 0) {
      return 'https://y.gtimg.cn/music/photo_new/T002R500x500M000' + meta.albumId + '.jpg';
    }
    return '';
  }
}

// ============================================================ 咪咕
export class MgApi implements SourceApi {
  readonly source: OnlineSource = 'mg';

  async search(keyword: string, page: number, limit: number): Promise<SearchResult> {
    // 按该服务协议：MD5 签名 + 固定 searchSwitch
    const timeMs: string = Date.now().toString();
    let sign: string = '';
    try {
      sign = await mgSignature(keyword, timeMs);
    } catch (e) {
      return emptySearchResult('mg', page, limit, '咪咕签名失败');
    }
    const url: string = 'https://jadeite.migu.cn/music_search/v3/search/searchAll' +
      '?isCorrect=0&isCopyright=1&searchSwitch=' + MG_SEARCH_SWITCH +
      '&pageSize=' + limit.toString() + '&text=' + encodeQuery(keyword) +
      '&pageNo=' + page.toString() + '&sort=0&sid=USS';
    const headers: Record<string, string> = {
      'uiVersion': 'A_music_3.6.1',
      'deviceId': await getMgDeviceId(),
      'timestamp': timeMs,
      'sign': sign,
      'channel': '0146921',
      'User-Agent': MG_SEARCH_UA,
    };
    const r: HttpResult = await HttpClient.get(url, headers, 1);
    if (!r.ok || r.json === null) {
      return emptySearchResult('mg', page, limit, '咪咕搜索失败：' + r.error);
    }
    const songData: Object | null = Json.obj(r.json, 'songResultData');
    const groups: Object[] = Json.arr(songData, 'resultList');
    const list: MusicInfo[] = [];
    for (const g of groups) {
      // resultList 有的响应是二维数组（同一首歌的多个版本），两种都兼容
      const entries: Object[] = Array.isArray(g) ? Json.asArr(g as Object) : [g];
      for (const it of entries) {
        const songId: string = Json.str(it, 'songId', Json.str(it, 'id', ''));
        const name: string = decodeName(Json.str(it, 'name', Json.str(it, 'songName', '')));
        if (songId.length === 0 || name.length === 0) { continue; }
        const artists: Object[] = Json.arr(it, 'singerList');
        const names: string[] = [];
        for (const a of artists) {
          const n: string = Json.str(a, 'name', '');
          if (n.length > 0) { names.push(n); }
        }
        const rates: Object[] = Json.arr(it, 'audioFormats');
        const qs: string[] = ['128k'];
        for (const rt of rates) {
          const t: string = Json.str(rt, 'formatType', '');
          if (t === 'HQ') { qs.push('320k'); }
          else if (t === 'SQ') { qs.push('flac'); }
          else if (t === 'ZQ' || t === 'ZQ24') { qs.push('flac24bit'); }
        }
        const pic: string = Json.str(it, 'img3', Json.str(it, 'img2', Json.str(it, 'img1', '')));
        list.push(makeMusicInfo('mg', songId, name,
          names.length > 0 ? names.join('、') : decodeName(Json.str(it, 'singer', '')),
          null,
          decodeName(Json.str(it, 'album', '')),
          pic.startsWith('http') ? pic : '', qs,
          {
            copyrightId: Json.str(it, 'copyrightId', ''),
            lrcUrl: Json.str(it, 'lrcUrl', Json.str(it, 'lrcurl', Json.str(it, 'lyricUrl', ''))),
            // 部分服务端返回小写 data.mrcurl，新版返回大写 mrcUrl，两者兼容
            mrcUrl: Json.str(it, 'mrcUrl', Json.str(it, 'mrcurl', '')),
            trcUrl: Json.str(it, 'trcUrl', Json.str(it, 'trcurl', '')),
            albumId: Json.str(it, 'albumId', ''),
          }));
      }
    }
    const totalStr: string = Json.str(songData, 'totalCount', '0');
    const total: number = isNaN(Number(totalStr)) ? list.length : Number(totalStr);
    return { list, total, page, limit, source: 'mg', error: '' };
  }

  async tipSearch(keyword: string): Promise<string[]> {
    const url: string = 'https://music.migu.cn/v3/api/search/suggest?keyword=' + encodeQuery(keyword);
    const j: Object | null = await HttpClient.getJson(url, {
      'referer': 'https://music.migu.cn/v3',
    });
    const songs: Object[] = Json.arr(j, 'songs');
    const out: string[] = [];
    for (const s of songs) {
      const n: string = decodeName(Json.str(s, 'name', ''));
      if (n.length > 0) {
        const singer: string = Json.str(s, 'singerName', '');
        out.push(singer.length > 0 ? n + ' - ' + singer : n);
      }
    }
    return out;
  }

  async hotSearch(): Promise<string[]> {
    const j: Object | null = await HttpClient.getJson(
      'https://jadeite.migu.cn:7090/music_search/v3/search/hotword', MG_HEADERS);
    const data: Object | null = Json.obj(j, 'data');
    const groups: Object[] = Json.arr(data, 'hotwords');
    const out: string[] = [];
    if (groups.length > 0) {
      const words: Object[] = Json.arr(groups[0], 'hotwordList');
      for (const w of words) {
        if (Json.str(w, 'resourceType', '') !== 'song') { continue; }
        const word: string = decodeName(Json.str(w, 'word', ''));
        if (word.length > 0) { out.push(word); }
      }
    }
    return out;
  }

  async songListTags(): Promise<TagResult> {
    return {
      tags: [{ id: '', name: '推荐' }],
      sorts: [{ tid: 'hot', id: 'hot' }, { tid: 'new', id: 'new' }],
      source: 'mg', error: '',
    };
  }

  async songList(tagId: string, sortId: string, page: number, limit: number): Promise<SonglistResult> {
    // 咪咕「歌单广场」推荐页：data.contents 是多层嵌套的栏目结构，
    // 叶子节点带 action="mgmusic://song-list-info?id=..."、txt=标题、img/img2=封面。
    // 旧代码只找 data.contentItemList（该字段根本不存在），导致列表恒为空。
    // 这里递归遍历 contents，按 action 前缀筛出歌单，并对 id 去重。
    const url: string = 'https://app.c.nf.migu.cn/pc/bmw/page-data/playlist-square-recommend/v1.0' +
      '?templateVersion=2&pageNo=' + page.toString();
    const j: Object | null = await HttpClient.getJson(url, MG_HEADERS);
    const data: Object | null = Json.obj(j, 'data');
    const list: ListInfoItem[] = [];
    const seen: string[] = [];
    this.collectMgPlaylists(data, list, seen);
    return { list, total: list.length, page, limit, source: 'mg', error: '' };
  }

  /** 递归遍历咪咕歌单广场的嵌套 contents，收集歌单项（action 含 song-list-info） */
  private collectMgPlaylists(node: Object | null, out: ListInfoItem[], seen: string[]): void {
    if (node === null) {
      return;
    }
    const action: string = Json.str(node, 'action', '');
    if (action.length > 0 && action.indexOf('song-list-info') >= 0) {
      let id: string = action.substring(action.indexOf('id=') + 3);
      const amp: number = id.indexOf('&');
      if (amp >= 0) {
        id = id.substring(0, amp);
      }
      const name: string = decodeName(Json.str(node, 'txt', ''));
      if (id.length === 0 || name.length === 0 || seen.indexOf(id) >= 0) {
        return;
      }
      seen.push(id);
      let img: string = Json.str(node, 'img', Json.str(node, 'img2', ''));
      if (img.startsWith('http://')) {
        img = 'https://' + img.substring(7);
      }
      out.push({
        id, name,
        play_count: '0',
        author: decodeName(Json.str(node, 'createName', '')),
        time: Json.str(node, 'createTime', ''),
        img,
        desc: decodeName(Json.str(node, 'summary', '')),
        source: 'mg',
        total: 0,
      });
      return;
    }
    const children: Object[] = Json.arr(node, 'contents');
    for (const c of children) {
      this.collectMgPlaylists(c, out, seen);
    }
  }

  async searchPlaylists(keyword: string, page: number, limit: number): Promise<SonglistResult> {
    // 咪咕搜索要 MD5 签名（只接了单曲），歌单搜索暂不接入
    return emptySonglistResult('mg', page, limit, '咪咕暂不支持搜歌单，可切到酷我 / 酷狗 / 网易');
  }

  async songListDetail(id: string, page: number): Promise<MusicListResult> {
    // 服务端把 pageSize 截到 50（传 1000 也只返 50 首）。旧实现按「一页拿全」处理，
    // 结果：歌单只显示前 50 首、total 被写成本页条数、永远没有下一页。
    // 现在按真实分页取：totalCount 作总数，每页 50，详情页滚到底继续取。
    const url: string = 'https://app.c.nf.migu.cn/MIGUM3.0/resource/playlist/song/v2.0?pageNo=' +
      page.toString() + '&pageSize=50&playlistId=' + encodeQuery(id);
    const j: Object | null = await HttpClient.getJson(url, MG_HEADERS);
    const data: Object | null = Json.obj(j, 'data');
    const songs: Object[] = Json.arr(data, 'songList');
    const list: MusicInfo[] = [];
    for (const s of songs) {
      const songId: string = Json.str(s, 'songId', '');
      const name: string = decodeName(Json.str(s, 'songName', Json.str(s, 'name', '')));
      if (songId.length === 0 || name.length === 0) { continue; }
      // 这份接口的歌手字段是 singerList（旧代码读 artists，一直取不到 → 歌手空白）
      const artists: Object[] = Json.arr(s, 'artists');
      const singerList: Object[] = artists.length > 0 ? artists : Json.arr(s, 'singerList');
      const names: string[] = [];
      for (const a of singerList) {
        const n: string = Json.str(a, 'name', '');
        if (n.length > 0) { names.push(n); }
      }
      // 音质字段同理：实际是 audioFormats（PQ/HQ/SQ/Z3D），旧代码读 newRateFormats → 只剩 128k
      const rates: Object[] = Json.arr(s, 'newRateFormats');
      const formats: Object[] = rates.length > 0 ? rates : Json.arr(s, 'audioFormats');
      const qs: string[] = ['128k'];
      for (const r of formats) {
        const t: string = Json.str(r, 'formatType', '');
        if (t === 'HQ' && qs.indexOf('320k') < 0) { qs.push('320k'); }
        if (t === 'SQ' && qs.indexOf('flac') < 0) { qs.push('flac'); }
        if ((t === 'ZQ' || t === 'ZQ24' || t === 'ZQ32') && qs.indexOf('flac24bit') < 0) {
          qs.push('flac24bit');
        }
      }
      // 时长：duration 是秒（旧代码传 null，所以歌单里全是「--:--」）
      const dur: number = Json.num(s, 'duration', 0);
      // 封面临时路径（/data/oss/...webp）→ 绝对地址；img3 最大，用于播放详情大图
      const pic: string = mgPicUrl(Json.str(s, 'img3',
        Json.str(s, 'img2', Json.str(s, 'img1', ''))));
      list.push(makeMusicInfo('mg', songId, name,
        names.length > 0 ? names.join('、') : decodeName(Json.str(s, 'singer', '')),
        dur > 0 ? formatPlayTime(dur) : null,
        decodeName(Json.str(s, 'album', '')), pic.length > 0 ? pic : null, qs,
        {
          copyrightId: Json.str(s, 'copyrightId', ''),
          lrcUrl: Json.str(s, 'lrcUrl', Json.str(s, 'lrcurl', '')),
          mrcUrl: Json.str(s, 'mrcUrl', Json.str(s, 'mrcurl', '')),
          trcUrl: Json.str(s, 'trcUrl', Json.str(s, 'trcurl', '')),
        }));
    }
    return {
      list, total: Json.num(data, 'totalCount', list.length), page, source: 'mg',
      name: '', desc: '', img: '', error: '',
    };
  }

  leaderboardCategories(): BoardItem[] {
    // 旧 columnId（22162511 等）对应的 querycontentbyId.do 接口已失效（返回 columnInfo 为空）。
    // 换成当前 rank-index/rank-info 明文接口的真实 rankId，静态列表零额外请求。
    // 封面取自咪咕官方 rank-index 的 imageUrl，静态内置不额外打接口，走 CoverImage 缓存。
    return [
      { id: 'mg_83048887', name: '全网热歌榜', bangid: '83048887',
        img: 'https://d.musicapp.migu.cn/data/oss/column/00/1w/yi/2981744541a345958d285c75e8fa907c.webp' },
      { id: 'mg_83049014', name: '抖音热歌榜', bangid: '83049014',
        img: 'https://d.musicapp.migu.cn/data/oss/column/00/1w/yi/6b3b5e0429954c19ad8d667e6eb9b681.webp' },
      { id: 'mg_83048867', name: '免费热歌榜', bangid: '83048867',
        img: 'https://d.musicapp.migu.cn/data/oss/column/00/1w/yi/b3ce6d0d06b743f397d6b6ed860d90d7.webp' },
      { id: 'mg_83176390', name: '国风热歌榜', bangid: '83176390',
        img: 'https://d.musicapp.migu.cn/data/oss/resource/00/63/au/4cc20fefdbc84e1181e915cfc46bfe39.webp' },
      { id: 'mg_27553319', name: '新歌榜', bangid: '27553319',
        img: 'https://d.musicapp.migu.cn/data/oss/resource/00/62/2w/5eb38a5bd7b24483bdd97886dd53c78f.webp' },
      { id: 'mg_27186466', name: '热歌榜', bangid: '27186466',
        img: 'https://d.musicapp.migu.cn/data/oss/resource/00/4t/9y/a64e69c4d8c54f59b580b1a25ae5ceb3.webp' },
      { id: 'mg_27553408', name: '原创榜', bangid: '27553408',
        img: 'https://d.musicapp.migu.cn/data/oss/resource/00/5y/qo/a3fd1c82871b4161a31daba36aa6cc50.webp' },
    ];
  }

  async leaderboardDetail(bangid: string, page: number): Promise<MusicListResult> {
    // 新榜单接口：明文、无签名，和歌单广场同一域名/请求头，请求次数与旧实现一致。
    const url: string = 'https://app.c.nf.migu.cn/bmw/rank/rank-info/v1.0?pageNo=' +
      page.toString() + '&rankId=' + encodeQuery(bangid);
    const j: Object | null = await HttpClient.getJson(url, MG_HEADERS);
    const data: Object | null = Json.obj(j, 'data');
    const contents: Object[] = Json.arr(data, 'contents');
    const list: MusicInfo[] = [];
    for (const c of contents) {
      // 详情里歌名/歌手/时长/音质/封面都在 songData（JSON 字符串）中，外层只有 songId 等。
      const songDataObj: Object | null = Json.obj(c, 'songData');
      let sd: Object | null = songDataObj;
      if (sd === null) {
        const raw: string = Json.str(c, 'songData', '');
        if (raw.length > 0) {
          try {
            sd = JSON.parse(raw) as Object;
          } catch (e) {
            sd = null;
          }
        }
      }
      const songId: string = Json.str(c, 'songId', '');
      const name: string = decodeName(Json.str(sd, 'songName', Json.str(c, 'txt', '')));
      if (songId.length === 0 || name.length === 0) { continue; }
      // 歌手：songData.singerList（对象数组，name 字段），兜底外层 txt2
      const singers: Object[] = Json.arr(sd, 'singerList');
      const names: string[] = [];
      for (const a of singers) {
        const n: string = Json.str(a, 'name', '');
        if (n.length > 0) { names.push(n); }
      }
      // 音质：songData.audioFormats 的 formatType（PQ/HQ/SQ/ZQ24）
      const rates: Object[] = Json.arr(sd, 'audioFormats');
      const qs: string[] = ['128k'];
      for (const r of rates) {
        const t: string = Json.str(r, 'formatType', '');
        if (t === 'HQ' && qs.indexOf('320k') < 0) { qs.push('320k'); }
        if ((t === 'SQ' || t === 'ZQ24' || t === 'ZQ32') && qs.indexOf('flac') < 0) { qs.push('flac'); }
      }
      // 时长：songData.duration 是秒
      const dur: number = Json.num(sd, 'duration', 0);
      // 封面：songData.img3 > img2 > img1（绝对地址），兜底外层 img
      const pic: string = mgPicUrl(Json.str(sd, 'img3',
        Json.str(sd, 'img2', Json.str(sd, 'img1', Json.str(c, 'img', '')))));
      list.push(makeMusicInfo('mg', songId, name,
        names.length > 0 ? names.join('、') : decodeName(Json.str(c, 'txt2', '')),
        dur > 0 ? formatPlayTime(dur) : null,
        decodeName(Json.str(sd, 'album', Json.str(c, 'txt3', ''))), pic.length > 0 ? pic : null, qs,
        { copyrightId: Json.str(c, 'copyrightId', '') }));
    }
    return {
      list, total: Json.num(data, 'totalCount', list.length), page, source: 'mg',
      name: '', desc: '', img: '', error: '',
    };
  }

  async getLyric(info: MusicInfo): Promise<LyricInfo | null> {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    let mrcUrl: string = meta.mrcUrl ?? '';
    let lrcUrl: string = meta.lrcUrl ?? '';
    let trcUrl: string = meta.trcUrl ?? '';
    // 按该服务协议：搜索结果常见只给 lrcUrl、缺 mrcUrl，
    // 此时按 songId 查 resourceinfo.do 拿到逐字歌词 URL（实测返回 mrcUrl）。
    // 仅在 mrcUrl 缺失时查询，已有逐字 URL 不额外发请求。
    if (mrcUrl.length === 0) {
      const res: MgResourceInfo | null = await fetchMgResource(meta.songId);
      if (res !== null) {
        mrcUrl = res.mrcUrl;
        if (lrcUrl.length === 0) { lrcUrl = res.lrcUrl; }
        if (trcUrl.length === 0) { trcUrl = res.trcUrl; }
      }
    }
    let trans: string = '';
    if (trcUrl.length > 0) {
      trans = await HttpClient.getText(trcUrl, MG_HEADERS);
    }
    // 优先 MRC 逐字（按该服务协议：mrcUrl > lrcUrl）；
    // MRC 用 (绝对start,dur) 标签，与 QRC 同构，复用 parseEnhancedLyric(text, false)。
    if (mrcUrl.length > 0) {
      const raw: string = await HttpClient.getText(mrcUrl, MG_HEADERS);
      const plain: string = decryptMrc(raw);
      if (plain.length > 0 && plain.indexOf('[') >= 0) {
        const parsed: LyricInfo = parseEnhancedLyric(plain, false);
        if (parsed.lyric.length > 0) {
          parsed.tlyric = trans.length > 0 ? trans : null;
          return parsed;
        }
      }
    }
    if (lrcUrl.length === 0) { return null; }
    const lrc: string = await HttpClient.getText(lrcUrl, MG_HEADERS);
    if (lrc.length === 0) { return null; }
    return { lyric: lrc, tlyric: trans.length > 0 ? trans : null, rlyric: null, lxlyric: null };
  }

  async getPic(info: MusicInfo): Promise<string> {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    const pic: string = meta.picUrl ?? '';
    if (pic.startsWith('http')) { return pic; }
    if (pic.length > 0) { return 'https://d.musicapp.migu.cn' + pic; }
    return '';
  }
}

// ============================================================ 网易云
/** 按该服务协议 43 个榜单 */
const WY_BOARDS: string[][] = [
  ['19723756', '飙升榜'], ['3779629', '新歌榜'], ['2884035', '原创榜'],
  ['3778678', '热歌榜'], ['991319590', '说唱榜'], ['71384707', '古典榜'],
  ['1978921795', '电音榜'], ['5453912201', '黑胶VIP爱听榜'], ['71385702', 'ACG榜'],
  ['745956260', '韩语榜'], ['10520166', '国电榜'], ['180106', 'UK排行榜周榜'],
  ['60198', '美国Billboard榜'], ['3812895', 'Beatport全球电子舞曲榜'],
  ['21845217', 'KTV唛榜'], ['60131', '日本Oricon榜'], ['2809513713', '欧美热歌榜'],
  ['2809577409', '欧美新歌榜'], ['27135204', '法国 NRJ Vos Hits 周榜'],
  ['3001835560', 'ACG动画榜'], ['3001795926', 'ACG游戏榜'],
  ['3001890046', 'ACG VOCALOID榜'], ['3112516681', '中国新乡村音乐排行榜'],
  ['5059644681', '日语榜'], ['5059633707', '摇滚榜'], ['5059642708', '国风榜'],
  ['5338990334', '潜力爆款榜'], ['5059661515', '民谣榜'],
  ['6688069460', '听歌识曲榜'], ['6723173524', '网络热歌榜'],
  ['6732051320', '俄语榜'], ['6732014811', '越南语榜'], ['6886768100', '中文DJ榜'],
  ['6939992364', '俄罗斯top hit流行音乐榜'], ['7095271308', '泰语榜'],
  ['7356827205', 'BEAT排行榜'], ['7325478166', '编辑推荐榜'],
  ['7603212484', 'LOOK直播歌曲榜'], ['7775163417', '赏音榜'],
  ['7785123708', '黑胶VIP新歌榜'], ['7785066739', '黑胶VIP热歌榜'],
  ['7785091694', '黑胶VIP爱搜榜'],
];

/** 网易榜单封面（取自官方明文 toplist/detail 的 coverImgUrl，静态内置零额外请求） */
const WY_BOARD_IMGS: Record<string, string> = {
  '19723756': 'https://p2.music.126.net/rIi7Qzy2i2Y_1QD7cd0MYA==/109951170048506929.jpg',
  '3779629': 'https://p2.music.126.net/5guhqPBTcIrrhLBotgaT6w==/109951170048511751.jpg',
  '2884035': 'https://p2.music.126.net/BaP9nrocNTL3gGThysv4eQ==/109951170091896587.jpg',
  '3778678': 'https://p2.music.126.net/0SUEG8yDACfx0Bw2MYFv4Q==/109951170048519512.jpg',
  '991319590': 'https://p2.music.126.net/GgHbgDfGXHpE2YTchU7IvA==/109951171510498108.jpg',
  '71384707': 'https://p2.music.126.net/urByD_AmfBDBrs7fA9-O8A==/109951167976973225.jpg',
  '1978921795': 'https://p2.music.126.net/hXGObvXfsGtFjFvRhOYAkA==/109951170091888741.jpg',
  '5453912201': 'https://p1.music.126.net/qo6-o9n5AhMjNyejev38-A==/109951169743111905.jpg',
  '71385702': 'https://p1.music.126.net/na1kEeCS1iZEkzOrs9r_9g==/109951167976973667.jpg',
  '745956260': 'https://p1.music.126.net/5oN9YaFznwNGXkmi8i2Ytw==/109951167430864741.jpg',
  '180106': 'https://p1.music.126.net/fhAqiflLy3eU-ldmBQByrg==/109951165613082765.jpg',
  '60198': 'https://p1.music.126.net/rwRsVIJHQ68gglhA6TNEYA==/109951165611413732.jpg',
  '3812895': 'https://p1.music.126.net/oT-RHuPBJiD7WMoU7WG5Rw==/109951166093489621.jpg',
  '21845217': 'https://p1.music.126.net/5wDP78s43ydVTKt62C8OjQ==/109951165613100063.jpg',
  '60131': 'https://p1.music.126.net/aXUPgImt8hhf4cMUZEjP4g==/109951165611417794.jpg',
  '2809513713': 'https://p1.music.126.net/70_EO_Dc7NT_hhfvsapzcQ==/109951167430862162.jpg',
  '2809577409': 'https://p1.music.126.net/0lPWpI9Ejn1OiW2LSbg-qw==/109951167430863224.jpg',
  '27135204': 'https://p1.music.126.net/-fyzrPWd06FfWl_0JDAxMQ==/109951165613108584.jpg',
  '3001835560': 'https://p1.music.126.net/SkGlKQ6acixthb77VlD9eQ==/109951164432300406.jpg',
  '3001795926': 'https://p1.music.126.net/hivOOHMwEmnn9s_6rgZwEQ==/109951164432303700.jpg',
  '3001890046': 'https://p1.music.126.net/Ag7RyRCYiINcd9EtRXf6xA==/109951164432303690.jpg',
  '5059644681': 'https://p1.music.126.net/YFBFNI2F-4BveUpv6FKFuw==/109951167430864069.jpg',
  '5059633707': 'https://p1.music.126.net/LjkX2hktgFD1NXc3W6w0sA==/109951170048522513.jpg',
  '5059642708': 'https://p1.music.126.net/kTJC5OBhg8I477X_ZmXyDQ==/109951168539740982.jpg',
  '5338990334': 'https://p1.music.126.net/Mi4QPklg1mtbWAfq74tEqQ==/109951165498334721.jpg',
  '5059661515': 'https://p1.music.126.net/Xe9qLTAqtBAWX_hPgFHMyw==/109951170048510929.jpg',
  '6688069460': 'https://p1.music.126.net/wJVUAiUuykKk7yGbQxDBug==/109951167430857712.jpg',
  '6723173524': 'https://p1.music.126.net/_kSxOPqQ5J5etC5DKTFwNA==/109951170048519530.jpg',
  '6732051320': 'https://p1.music.126.net/HbJ0BK5doY4I4pEMY6-FQw==/109951167430852698.jpg',
  '6732014811': 'https://p1.music.126.net/N-Y5maLGWgrowt3TE6RtSg==/109951167430857045.jpg',
  '6886768100': 'https://p1.music.126.net/w_01BfDU012ojxnzLO6tYw==/109951167977358686.jpg',
  '6939992364': 'https://p1.music.126.net/KLVO8PxVZzOoLdWQQNyprA==/109951166327316568.jpg',
  '7095271308': 'https://p1.music.126.net/4W0WBHBgwYlYfRniuyL47A==/109951167430843284.jpg',
  '7356827205': 'https://p1.music.126.net/yhzlQJCJ9NcT4MvJBG_HgQ==/109951167977014958.jpg',
  '7325478166': 'https://p1.music.126.net/m9HWYdcz9xH-7SSito3-3A==/109951172864859483.jpg',
  '7603212484': 'https://p1.music.126.net/u-RQC-LyY0aoeseRumJ14A==/109951167977730469.jpg',
  '7775163417': 'https://p1.music.126.net/m9hQzC-d5wefBipedNPaHg==/109951168178601971.jpg',
  '7785123708': 'https://p1.music.126.net/vjitpkT9nXBCth6tvdDMWg==/109951169743115266.jpg',
  '7785066739': 'https://p1.music.126.net/Ay3mLgQ9weG_c8JjYrD-Bw==/109951169743106495.jpg',
  '7785091694': 'https://p1.music.126.net/R7DtZqNraesnsiaIKvzTHA==/109951169743112799.jpg',
};

const WY_TAGS: string[] = [
  '全部', '华语', '流行', '摇滚', '民谣', '电子', '说唱', '轻音乐',
  '影视原声', 'ACG', '怀旧', '治愈', '旅行', '运动', '学习', '夜晚',
  '开车', '日语', '韩语', '欧美',
];

/** 网易云歌曲对象 → MusicInfo（搜索 / 歌单详情 / 榜单详情共用） */
function wyTrackFrom(s: Object): MusicInfo | null {
  const id: string = Json.str(s, 'id', '');
  const name: string = decodeName(Json.str(s, 'name', ''));
  if (id.length === 0 || name.length === 0) {
    return null;
  }
  const ar: Object[] = Json.arr(s, 'ar');
  const names: string[] = [];
  for (const a of ar) {
    const n: string = Json.str(a, 'name', '');
    if (n.length > 0) { names.push(n); }
  }
  const al: Object | null = Json.obj(s, 'al');
  const dtMs: number = Json.num(s, 'dt', 0);
  const qs: string[] = ['128k'];
  if (Json.obj(s, 'h') !== null) { qs.push('320k'); }
  if (Json.obj(s, 'sq') !== null) { qs.push('flac'); }
  if (Json.obj(s, 'hr') !== null) { qs.push('flac24bit'); }
  return makeMusicInfo('wy', id, name, names.length > 0 ? names.join('、') : '',
    dtMs > 0 ? formatPlayTime(Math.floor(dtMs / 1000)) : null,
    decodeName(Json.str(al, 'name', '')), Json.str(al, 'picUrl', ''), qs);
}

/** 解析 /weapi/v3/playlist/detail 的 playlist.tracks */
function wyPlaylistToResult(j: Object | null, page: number): MusicListResult {
  const pl: Object | null = Json.obj(j, 'playlist');
  const tracks: Object[] = Json.arr(pl, 'tracks');
  const list: MusicInfo[] = [];
  for (const t of tracks) {
    const m: MusicInfo | null = wyTrackFrom(t);
    if (m !== null) { list.push(m); }
  }
  return {
    list, total: Json.num(pl, 'trackCount', list.length), page, source: 'wy',
    name: decodeName(Json.str(pl, 'name', '')),
    desc: decodeName(Json.str(pl, 'description', '')),
    img: Json.str(pl, 'coverImgUrl', ''), error: '',
  };
}

export class WyApi implements SourceApi {
  readonly source: OnlineSource = 'wy';

  private async wyPost(url: string, text: string): Promise<HttpResult> {
    let form: string = '';
    try {
      form = await wyWeapiForm(text);
    } catch (e) {
      return { ok: false, statusCode: 0, text: '', json: null, error: 'weapi 加密失败' };
    }
    return await HttpClient.post(url, form, {
      'Content-Type': 'application/x-www-form-urlencoded',
      'User-Agent': WY_UA,
      'Referer': 'https://music.163.com',
    }, 1);
  }

  async search(keyword: string, page: number, limit: number): Promise<SearchResult> {
    // 按该服务协议 + wy/utils/crypto.js 的 eapi
    const apiPath: string = '/api/search/song/list/page';
    const text: string = '{"keyword":' + jsonStr(keyword) + ',"needCorrect":"1",' +
      '"channel":"typing","offset":' + (limit * (page - 1)).toString() +
      ',"scene":"normal","total":' + (page === 1 ? 'true' : 'false') +
      ',"limit":' + limit.toString() + '}';
    let params: string = '';
    try {
      params = await wyEapiParams(apiPath, text);
    } catch (e) {
      return emptySearchResult('wy', page, limit, '网易云 eapi 签名失败');
    }
    const r: HttpResult = await HttpClient.post('https://interface.music.163.com/eapi/batch',
      'params=' + params, {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': WY_UA,
        'origin': 'https://music.163.com',
      }, 1);
    if (!r.ok || r.json === null) {
      return emptySearchResult('wy', page, limit, '网易云搜索失败：' + r.error);
    }
    const data: Object | null = Json.obj(r.json, 'data');
    const resources: Object[] = Json.arr(data, 'resources');
    const list: MusicInfo[] = [];
    for (const res of resources) {
      const base: Object | null = Json.obj(res, 'baseInfo');
      const s: Object | null = Json.obj(base, 'simpleSongData');
      const id: string = Json.str(s, 'id', '');
      const name: string = decodeName(Json.str(s, 'name', ''));
      if (id.length === 0 || name.length === 0) { continue; }
      const ar: Object[] = Json.arr(s, 'ar');
      const names: string[] = [];
      for (const a of ar) {
        const n: string = Json.str(a, 'name', '');
        if (n.length > 0) { names.push(n); }
      }
      const al: Object | null = Json.obj(s, 'al');
      const dtMs: number = Json.num(s, 'dt', 0);
      const qs: string[] = ['128k'];
      if (Json.obj(s, 'h') !== null) { qs.push('320k'); }
      if (Json.obj(s, 'sq') !== null) { qs.push('flac'); }
      if (Json.obj(s, 'hr') !== null) { qs.push('flac24bit'); }
      list.push(makeMusicInfo('wy', id, name,
        names.length > 0 ? names.join('、') : '',
        dtMs > 0 ? formatPlayTime(Math.floor(dtMs / 1000)) : null,
        decodeName(Json.str(al, 'name', '')),
        Json.str(al, 'picUrl', ''), qs));
    }
    return { list, total: Json.num(data, 'totalCount', list.length), page, limit, source: 'wy', error: '' };
  }

  async tipSearch(keyword: string): Promise<string[]> {
    // 按该服务协议：weapi /weapi/search/suggest/keyword
    const r: HttpResult = await this.wyPost('https://music.163.com/weapi/search/suggest/keyword',
      '{"s":' + jsonStr(keyword) + '}');
    const result: Object | null = Json.obj(r.json, 'result');
    const items: Object[] = Json.arr(result, 'allMatch');
    const out: string[] = [];
    for (const it of items) {
      const w: string = decodeName(Json.str(it, 'keyword', ''));
      if (w.length > 0) { out.push(w); }
    }
    return out;
  }

  async hotSearch(): Promise<string[]> {
    // 按该服务协议：eapi /api/search/chart/detail
    const path: string = '/api/search/chart/detail';
    const text: string = '{"id":"HOT_SEARCH_SONG#@#"}';
    let params: string = '';
    try {
      params = await wyEapiParams(path, text);
    } catch (e) {
      return [];
    }
    const r: HttpResult = await HttpClient.post('https://interface.music.163.com/eapi/batch',
      'params=' + params, {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': WY_UA,
        'origin': 'https://music.163.com',
      });
    const data: Object | null = Json.obj(r.json, 'data');
    const items: Object[] = Json.arr(data, 'itemList');
    const out: string[] = [];
    for (const it of items) {
      const w: string = decodeName(Json.str(it, 'searchWord', ''));
      if (w.length > 0) { out.push(w); }
    }
    return out;
  }

  async songListTags(): Promise<TagResult> {
    // /weapi/playlist/category/get 已下线（404），沿用协议内置分类
    const tags: TagInfoItem[] = [];
    for (let i = 0; i < WY_TAGS.length; i++) {
      tags.push({ id: WY_TAGS[i], name: WY_TAGS[i] });
    }
    const sorts: SortInfo[] = [
      { tid: 'hot', id: 'hot' },
      { tid: 'new', id: 'new' },
      { tid: 'recommend', id: 'recommend' },
    ];
    return { tags, sorts, source: 'wy', error: '' };
  }

  async songList(tagId: string, sortId: string, page: number, limit: number): Promise<SonglistResult> {
    // 歌单广场：https://music.163.com/api/playlist/list 实测无需任何签名（cat + order + offset 分页），
    // 比走 linuxapi 加密稳得多（旧实现每次都要先做一遍 RSA/AES，失败就整页空）。
    const cat: string = tagId === '全部' ? '全部' : (tagId.length > 0 ? tagId : '全部');
    const offset: number = (page - 1) * limit;
    const list: ListInfoItem[] = [];
    let total: number = 0;
    // order=new 在部分 cat 下会被服务端判成空结果，空了就退回 hot 再取一次
    const orders: string[] = sortId === 'new' ? ['new', 'hot'] : ['hot'];
    for (const order of orders) {
      const url: string = 'https://music.163.com/api/playlist/list?cat=' + encodeQuery(cat) +
        '&order=' + order + '&offset=' + offset.toString() +
        '&limit=' + limit.toString() + '&total=true';
      const r: HttpResult = await HttpClient.get(url, {
        'User-Agent': WY_UA,
        'Referer': 'https://music.163.com',
      }, 1);
      if (!r.ok || r.json === null) {
        return emptySonglistResult('wy', page, limit, '网易云歌单失败：' + r.error);
      }
      const items: Object[] = Json.arr(r.json, 'playlists');
      total = Json.num(r.json, 'total', items.length);
      for (const it of items) {
        const id: string = Json.str(it, 'id', '');
        if (id.length === 0) { continue; }
        const creator: Object | null = Json.obj(it, 'creator');
        list.push({
          play_count: Json.num(it, 'playCount', 0).toString(),
          id, author: decodeName(Json.str(creator, 'nickname', '')),
          name: decodeName(Json.str(it, 'name', '')),
          time: '', img: secureUrl(Json.str(it, 'coverImgUrl', '')),
          desc: decodeName(Json.str(it, 'description', '')),
          source: 'wy', total: Json.num(it, 'trackCount', 0),
        });
      }
      if (list.length > 0) {
        break;
      }
    }
    return { list, total, page, limit, source: 'wy', error: '' };
  }

  /**
   * 按关键词搜歌单：用网易明文接口 /api/search/get（type=1000），零签名。
   * 与歌词链路用的是同一个明文域名，不需要 eapi/weapi 加密。
   */
  async searchPlaylists(keyword: string, page: number, limit: number): Promise<SonglistResult> {
    const url: string = 'https://music.163.com/api/search/get?s=' + encodeQuery(keyword) +
      '&type=1000&limit=' + limit.toString() + '&offset=' + ((page - 1) * limit).toString();
    const r: HttpResult = await HttpClient.get(url, {
      'Referer': 'https://music.163.com',
      'User-Agent': WY_UA,
    }, 1);
    if (!r.ok || r.json === null) {
      return emptySonglistResult('wy', page, limit, '网易云歌单搜索失败：' + r.error);
    }
    const result: Object | null = Json.obj(r.json, 'result');
    const items: Object[] = Json.arr(result, 'playlists');
    const list: ListInfoItem[] = [];
    for (const it of items) {
      const id: string = Json.str(it, 'id', '');
      const name: string = decodeName(Json.str(it, 'name', ''));
      if (id.length === 0 || name.length === 0) {
        continue;
      }
      const creator: Object | null = Json.obj(it, 'creator');
      list.push({
        id, name,
        play_count: Json.num(it, 'playCount', 0).toString(),
        author: decodeName(Json.str(creator, 'nickname', '')),
        time: '',
        img: Json.str(it, 'coverImgUrl', ''),
        desc: decodeName(Json.str(it, 'description', '')),
        source: 'wy',
        total: Json.num(it, 'trackCount', 0),
      });
    }
    return {
      list, total: Json.num(result, 'playlistCount', list.length),
      page, limit, source: 'wy', error: '',
    };
  }

  async songListDetail(id: string, page: number): Promise<MusicListResult> {
    const r: HttpResult = await this.wyPost('https://music.163.com/weapi/v3/playlist/detail',
      '{"id":' + jsonStr(id) + ',"n":1000,"s":0}');
    if (!r.ok || r.json === null) {
      return emptyMusicListResult('wy', page, '网易云歌单详情失败：' + r.error);
    }
    return wyPlaylistToResult(r.json, page);
  }

  leaderboardCategories(): BoardItem[] {
    const out: BoardItem[] = [];
    for (const b of WY_BOARDS) {
      out.push({ id: 'wy__' + b[0], name: b[1], bangid: b[0], img: WY_BOARD_IMGS[b[0]] ?? '' });
    }
    return out;
  }

  async leaderboardDetail(bangid: string, page: number): Promise<MusicListResult> {
    return await this.songListDetail(bangid, page);
  }

  async getLyric(info: MusicInfo): Promise<LyricInfo | null> {
    // 优先**明文**接口（2026-11-16 实测稳定）：无需 eapi 签名，返回标准 LRC + 翻译
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    const plain: LyricInfo | null = await this.lyricPlain(meta.songId);
    if (plain !== null) {
      return plain;
    }
    // 回退：eapi /api/song/lyric/v1
    const path: string = '/api/song/lyric/v1';
    const text: string = '{"id":' + meta.songId + ',"cp":false,"tv":0,"lv":0,"rv":0,' +
      '"kv":0,"yv":0,"ytv":0,"yrv":0}';
    let params: string = '';
    try {
      params = await wyEapiParams(path, text);
    } catch (e) {
      return null;
    }
    const r: HttpResult = await HttpClient.post(
      'https://interface3.music.163.com/eapi/song/lyric/v1', 'params=' + params, {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': WY_UA,
        'origin': 'https://music.163.com',
      });
    if (!r.ok || r.json === null) { return null; }
    const lrcObj: Object | null = Json.obj(r.json, 'lrc');
    const tObj: Object | null = Json.obj(r.json, 'tlyric');
    const rObj: Object | null = Json.obj(r.json, 'romalrc');
    let lrc: string = Json.str(lrcObj, 'lyric', '');
    // 新版接口偶尔返回逐字歌词 JSON（以 { 开头），非标准 LRC 时退回翻译/音译
    if (lrc.length > 0 && !lrc.includes('[')) {
      lrc = Json.str(tObj, 'lyric', '');
    }
    if (lrc.length === 0 || !lrc.includes('[')) {
      return null;
    }
    const trans: string = Json.str(tObj, 'lyric', '');
    const roma: string = Json.str(rObj, 'lyric', '');
    return {
      lyric: lrc,
      tlyric: trans.includes('[') ? trans : null,
      rlyric: roma.includes('[') ? roma : null,
      lxlyric: null,
    };
  }

  async getPic(info: MusicInfo): Promise<string> {
    const meta: MusicInfoMetaOnline = info.meta as MusicInfoMetaOnline;
    return meta.picUrl ?? '';
  }

  /** 网易明文歌词接口（无需签名）：返回标准 LRC + 翻译；实测比 eapi 稳定得多 */
  private async lyricPlain(songId: string): Promise<LyricInfo | null> {
    if (songId.length === 0) {
      return null;
    }
    const url: string = 'https://music.163.com/api/song/lyric?id=' + encodeQuery(songId) +
      '&lv=-1&kv=-1&tv=-1';
    const j: Object | null = await HttpClient.getJson(url, {
      'User-Agent': WY_UA,
      'Referer': 'https://music.163.com/',
    });
    if (j === null) {
      return null;
    }
    const lrc: string = Json.str(Json.obj(j, 'lrc'), 'lyric', '');
    if (lrc.length === 0 || lrc.indexOf('[') < 0) {
      return null;
    }
    const trans: string = Json.str(Json.obj(j, 'tlyric'), 'lyric', '');
    const roma: string = Json.str(Json.obj(j, 'romalrc'), 'lyric', '');
    return {
      lyric: lrc,
      tlyric: trans.includes('[') ? trans : null,
      rlyric: roma.includes('[') ? roma : null,
      lxlyric: null,
    };
  }
}
