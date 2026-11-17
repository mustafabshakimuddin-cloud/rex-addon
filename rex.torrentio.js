/**
 * Torrentio 播放资源模块
 *
 * Torrentio 是一个 Stremio 插件，HTTP 接口为：
 *   {server}/manifest.json
 *   {server}/{config}/stream/{movie|series}/{imdbId[:season:episode]}.json
 * 其中 {config} 是以 "|" 分隔的 key=value 列表，例如：
 *   providers=yts,eztv|sort=seeders|qualityfilter=cam,scr|realdebrid=APIKEY
 *
 * 本模块声明 type 为 stream 的 loadResource，客户端起播时会携带：
 *   tmdbId / imdbId / id / type(tv|movie) / season / episode / link / videoUrl
 *
 * 播放说明：
 *   - 配置了网盘(Debrid)服务时，Torrentio 返回 HTTP 直链(/resolve/...)，可直接播放。
 *   - 未配置 Debrid 时，Torrentio 只返回种子 infoHash。播放器无法直接播放 BT，
 *     因此默认隐藏这些结果；可在「磁力链接」中选择显示，返回 magnet: 链接。
 */
WidgetMetadata = {
  id: "community.torrentio",
  title: "Torrentio",
  version: "1.2.2",
  // 详情页（loadDetail）缓存时长，秒。
  detailCacheDuration: 3600,
  requiredVersion: "0.0.2",
  description: "Torrentio 种子资源，支持 Real-Debrid、AllDebrid、Premiumize、TorBox 等网盘直链播放",
  author: "Community",
  site: "https://torrentio.strem.fun",
  iconurl: "https://torrentio.strem.fun/images/logo_v1.png",
  i18n: {
    "en": {
      "Torrentio 种子资源，支持 Real-Debrid、AllDebrid、Premiumize、TorBox 等网盘直链播放": "Torrent streams from Torrentio, playable through Real-Debrid, AllDebrid, Premiumize, TorBox and other debrid services",
      "服务器": "Server",
      "网盘服务": "Debrid Service",
      "无（仅种子）": "None (torrents only)",
      "网盘 API Key": "Debrid API Key",
      "仅显示已缓存": "Cached Only",
      "是": "Yes",
      "否": "No",
      "磁力链接": "Magnet Links",
      "隐藏": "Hide",
      "显示": "Show",
      "种子站点": "Providers",
      "全部（默认）": "All (default)",
      "常用站点": "Popular",
      "动漫站点": "Anime",
      "排除画质": "Exclude Qualities",
      "排除枪版/未知": "Exclude CAM / screener / unknown",
      "排除枪版和 480p": "Exclude CAM / screener / 480p",
      "排序": "Sort",
      "画质优先，再按做种数": "By quality, then seeders",
      "画质优先，再按大小": "By quality, then size",
      "按做种数": "By seeders",
      "按大小": "By size",
      "每种画质数量": "Results per Quality",
      "不限": "Unlimited",
      "优先语言": "Priority Language",
      "体积上限": "Max Size",
      "最少做种数": "Minimum Seeders",
      "TMDB API Key（可选）": "TMDB API Key (optional)",
      "加载资源": "Load Streams",
      "热门影视": "Popular",
      "来自 Cinemeta 的热门电影与剧集": "Popular movies and series from Cinemeta",
      "类型": "Type",
      "电影": "Movies",
      "剧集": "Series",
      "榜单": "Chart",
      "热门": "Popular",
      "高分": "Top Rated",
      "分类": "Genre",
      "全部": "All",
      "页码": "Page"
    },
    "zh-Hant": {
      "Torrentio 种子资源，支持 Real-Debrid、AllDebrid、Premiumize、TorBox 等网盘直链播放": "Torrentio 種子資源，支援 Real-Debrid、AllDebrid、Premiumize、TorBox 等網盤直連播放",
      "服务器": "伺服器",
      "网盘服务": "網盤服務",
      "无（仅种子）": "無（僅種子）",
      "网盘 API Key": "網盤 API Key",
      "仅显示已缓存": "僅顯示已快取",
      "是": "是",
      "否": "否",
      "磁力链接": "磁力連結",
      "隐藏": "隱藏",
      "显示": "顯示",
      "种子站点": "種子站點",
      "全部（默认）": "全部（預設）",
      "常用站点": "常用站點",
      "动漫站点": "動漫站點",
      "排除画质": "排除畫質",
      "排除枪版/未知": "排除槍版/未知",
      "排除枪版和 480p": "排除槍版和 480p",
      "排序": "排序",
      "画质优先，再按做种数": "畫質優先，再按做種數",
      "画质优先，再按大小": "畫質優先，再按大小",
      "按做种数": "按做種數",
      "按大小": "按大小",
      "每种画质数量": "每種畫質數量",
      "不限": "不限",
      "优先语言": "優先語言",
      "体积上限": "體積上限",
      "最少做种数": "最少做種數",
      "TMDB API Key（可选）": "TMDB API Key（選填）",
      "加载资源": "載入資源",
      "热门影视": "熱門影視",
      "来自 Cinemeta 的热门电影与剧集": "來自 Cinemeta 的熱門電影與劇集",
      "类型": "類型",
      "电影": "電影",
      "剧集": "劇集",
      "榜单": "榜單",
      "热门": "熱門",
      "高分": "高分",
      "分类": "分類",
      "全部": "全部",
      "页码": "頁碼"
    }
  },
  globalParams: [
    {
      name: "server",
      title: "服务器",
      type: "input",
      value: "https://torrentio.strem.fun",
      placeholders: [
        { title: "Torrentio", value: "https://torrentio.strem.fun" },
      ],
    },
    {
      name: "debridService",
      title: "网盘服务",
      type: "enumeration",
      value: "none",
      enumOptions: [
        { title: "无（仅种子）", value: "none" },
        { title: "Real-Debrid", value: "realdebrid" },
        { title: "AllDebrid", value: "alldebrid" },
        { title: "Premiumize", value: "premiumize" },
        { title: "TorBox", value: "torbox" },
        { title: "Debrid-Link", value: "debridlink" },
        { title: "EasyDebrid", value: "easydebrid" },
        { title: "Offcloud", value: "offcloud" },
        { title: "Put.io", value: "putio" },
      ],
    },
    {
      name: "debridKey",
      title: "网盘 API Key",
      type: "input",
      value: "",
    },
    {
      name: "cachedOnly",
      title: "仅显示已缓存",
      type: "enumeration",
      value: "true",
      enumOptions: [
        { title: "是", value: "true" },
        { title: "否", value: "false" },
      ],
    },
    {
      name: "showMagnets",
      title: "磁力链接",
      type: "enumeration",
      value: "false",
      enumOptions: [
        { title: "隐藏", value: "false" },
        { title: "显示", value: "true" },
      ],
    },
    {
      name: "providers",
      title: "种子站点",
      type: "input",
      value: "",
      placeholders: [
        { title: "全部（默认）", value: "" },
        { title: "常用站点", value: "yts,eztv,rarbg,1337x,thepiratebay,kickasstorrents,torrentgalaxy,magnetdl" },
        { title: "动漫站点", value: "horriblesubs,nyaasi,animetosho,tokyotosho,anidex,nekobt" },
      ],
    },
    {
      name: "qualityFilter",
      title: "排除画质",
      type: "input",
      value: "",
      placeholders: [
        { title: "排除枪版/未知", value: "scr,cam,unknown" },
        { title: "排除枪版和 480p", value: "scr,cam,480p" },
      ],
    },
    {
      name: "sort",
      title: "排序",
      type: "enumeration",
      value: "quality",
      enumOptions: [
        { title: "画质优先，再按做种数", value: "quality" },
        { title: "画质优先，再按大小", value: "qualitysize" },
        { title: "按做种数", value: "seeders" },
        { title: "按大小", value: "size" },
      ],
    },
    {
      name: "limit",
      title: "每种画质数量",
      type: "enumeration",
      value: "",
      enumOptions: [
        { title: "不限", value: "" },
        { title: "1", value: "1" },
        { title: "3", value: "3" },
        { title: "5", value: "5" },
        { title: "10", value: "10" },
      ],
    },
    {
      name: "language",
      title: "优先语言",
      type: "input",
      value: "",
      placeholders: [
        { title: "English", value: "english" },
        { title: "Chinese", value: "chinese" },
        { title: "Japanese", value: "japanese" },
      ],
    },
    {
      name: "sizeFilter",
      title: "体积上限",
      type: "input",
      value: "",
      placeholders: [
        { title: "5GB", value: "5GB" },
        { title: "10GB", value: "10GB" },
        { title: "20GB", value: "20GB" },
      ],
    },
    {
      name: "minSeeders",
      title: "最少做种数",
      type: "input",
      value: "",
      placeholders: [
        { title: "1", value: "1" },
        { title: "5", value: "5" },
        { title: "20", value: "20" },
      ],
    },
    {
      name: "tmdbApiKey",
      title: "TMDB API Key（可选）",
      type: "input",
      value: "",
    },
  ],
  modules: [
    {
      // Rex 不在模块列表中显示只有播放资源的模块，因此提供一个列表：
      // Cinemeta（Stremio 官方目录）的热门影视，条目即可直接用 Torrentio 播放。
      id: "popular",
      title: "热门影视",
      description: "来自 Cinemeta 的热门电影与剧集",
      functionName: "popular",
      cacheDuration: 3600,
      params: [
        {
          name: "mediaType",
          title: "类型",
          type: "enumeration",
          value: "movie",
          enumOptions: [
            { title: "电影", value: "movie" },
            { title: "剧集", value: "tv" },
          ],
        },
        {
          name: "catalog",
          title: "榜单",
          type: "enumeration",
          value: "top",
          enumOptions: [
            { title: "热门", value: "top" },
            { title: "高分", value: "imdbRating" },
          ],
        },
        {
          name: "genre",
          title: "分类",
          type: "enumeration",
          value: "",
          enumOptions: [
            { title: "全部", value: "" },
            { title: "Action", value: "Action" },
            { title: "Adventure", value: "Adventure" },
            { title: "Animation", value: "Animation" },
            { title: "Biography", value: "Biography" },
            { title: "Comedy", value: "Comedy" },
            { title: "Crime", value: "Crime" },
            { title: "Documentary", value: "Documentary" },
            { title: "Drama", value: "Drama" },
            { title: "Family", value: "Family" },
            { title: "Fantasy", value: "Fantasy" },
            { title: "History", value: "History" },
            { title: "Horror", value: "Horror" },
            { title: "Mystery", value: "Mystery" },
            { title: "Romance", value: "Romance" },
            { title: "Sci-Fi", value: "Sci-Fi" },
            { title: "Sport", value: "Sport" },
            { title: "Thriller", value: "Thriller" },
            { title: "War", value: "War" },
            { title: "Western", value: "Western" },
            { title: "Reality-TV", value: "Reality-TV" },
            { title: "Talk-Show", value: "Talk-Show" },
            { title: "Game-Show", value: "Game-Show" },
          ],
        },
        {
          name: "page",
          title: "页码",
          type: "page",
        },
      ],
    },
    {
      // id 需固定为 loadResource
      id: "loadResource",
      title: "加载资源",
      functionName: "loadResource",
      type: "stream",
      cacheDuration: 600,
      params: [],
    },
  ],
};

const DEFAULT_TORRENTIO_SERVER = "https://torrentio.strem.fun";
const CINEMETA_BASE = "https://cinemeta-catalogs.strem.io";
const CINEMETA_PAGE_SIZE = 50;
const CINEMETA_META = "https://v3-cinemeta.strem.io/meta";
const TORRENTIO_DEBRID_SERVICES = {
  realdebrid: "RD",
  alldebrid: "AD",
  premiumize: "PM",
  torbox: "TB",
  debridlink: "DL",
  easydebrid: "ED",
  offcloud: "OC",
  putio: "Putio",
};
const TORRENTIO_SORTS = ["quality", "qualitysize", "seeders", "size"];

function torrentioHeaders() {
  return {
    "Accept": "application/json",
    "User-Agent": "RexWidgets/1.0.0",
  };
}

function cleanParam(value) {
  return String(value === undefined || value === null ? "" : value).trim();
}

// 逗号列表：去空格、去空项、统一小写；"|" 和 "=" 会破坏 Torrentio 配置格式，直接剔除。
function cleanList(value) {
  return cleanParam(value)
    .split(/[，,]/)
    .map((item) => item.trim().toLowerCase().replace(/[|=\s]/g, ""))
    .filter(Boolean)
    .join(",");
}

function torrentioServer(params) {
  const server = cleanParam(params.server).replace(/\/+$/, "");
  return /^https?:\/\//i.test(server) ? server : DEFAULT_TORRENTIO_SERVER;
}

function debridService(params) {
  const service = cleanParam(params.debridService).toLowerCase();
  const key = cleanParam(params.debridKey);
  if (!TORRENTIO_DEBRID_SERVICES[service] || !key) return null;
  return { service, key };
}

// 生成 Torrentio 的配置段（URL 路径中的第一段）。为空时走 Torrentio 默认配置。
function buildTorrentioConfig(params) {
  const pairs = [];
  const add = (key, value) => {
    if (value) pairs.push(`${key}=${value}`);
  };

  add("providers", cleanList(params.providers));
  const sort = cleanParam(params.sort).toLowerCase();
  if (TORRENTIO_SORTS.includes(sort) && sort !== "quality") add("sort", sort);
  add("language", cleanList(params.language));
  add("qualityfilter", cleanList(params.qualityFilter));
  add("sizefilter", cleanList(params.sizeFilter));

  const limit = parseInt(cleanParam(params.limit), 10);
  if (limit > 0) add("limit", String(limit));
  const minSeeders = parseInt(cleanParam(params.minSeeders), 10);
  if (minSeeders > 0) add("minseeders", String(minSeeders));

  const debrid = debridService(params);
  if (debrid) {
    if (cleanParam(params.cachedOnly) !== "false") add("debridoptions", "nodownloadlinks");
    // API Key 原样传递（Put.io 等可能包含 "@"），只剔除会破坏配置分隔的字符。
    add(debrid.service, debrid.key.replace(/[|=\s]/g, ""));
  }

  return pairs.join("|");
}

function normalizeImdbId(value) {
  const raw = cleanParam(value);
  const match = raw.match(/tt\d+/i);
  if (match) return match[0].toLowerCase();
  return /^\d+$/.test(raw) ? `tt${raw}` : null;
}

function normalizeTmdbId(value) {
  const match = cleanParam(value).match(/(\d+)\s*$/);
  return match ? match[1] : null;
}

function isTvType(type) {
  const value = cleanParam(type).toLowerCase();
  return value === "tv" || value === "series" || value === "show" || value === "episode";
}

// 写入 Rex「JS 日志」/ 模块调试的运行日志。密钥一律打码，日志可以直接复制分享。
function torrentioLog(message, params) {
  let text = String(message);
  for (const secret of [cleanParam(params && params.debridKey), cleanParam(params && params.tmdbApiKey)]) {
    if (secret.length >= 4) text = text.split(secret).join("***").split(encodeURIComponent(secret)).join("***");
  }
  console.log(`[Torrentio] ${text}`);
}

function describeParams(params) {
  const shown = {};
  for (const [key, value] of Object.entries(params || {})) {
    if (key === "debridKey" || key === "tmdbApiKey") shown[key] = cleanParam(value) ? "(set)" : "(empty)";
    else if (typeof value !== "function") shown[key] = value;
  }
  return JSON.stringify(shown);
}

async function imdbIdFromTmdb(tmdbId, isTv, apiKey) {
  const path = `${isTv ? "tv" : "movie"}/${tmdbId}/external_ids`;

  // 宿主若内置 TMDB 访问（Forward 系客户端提供 Widget.tmdb），优先使用，不需要用户填 Key。
  if (typeof Widget !== "undefined" && Widget.tmdb && typeof Widget.tmdb.get === "function") {
    try {
      const data = await Widget.tmdb.get(path, { params: {} });
      const body = data && data.data ? data.data : data;
      const id = normalizeImdbId(body && body.imdb_id);
      if (id) return id;
    } catch (error) {
      console.error("Widget.tmdb external_ids 失败:", error);
    }
  }

  if (!apiKey) return null;
  try {
    const response = await Widget.http.get(
      `https://api.themoviedb.org/3/${path}?api_key=${encodeURIComponent(apiKey)}`,
      { headers: { "Accept": "application/json" } }
    );
    const body = parseBody(response);
    return normalizeImdbId(body && body.imdb_id);
  } catch (error) {
    console.error("TMDB external_ids 失败:", error);
    return null;
  }
}

async function resolveImdbId(params) {
  const direct = normalizeImdbId(params.imdbId)
    || (/^tt\d+/i.test(cleanParam(params.id)) ? normalizeImdbId(params.id) : null)
    || (/^tt\d+/i.test(cleanParam(params.link)) ? normalizeImdbId(params.link) : null);
  if (direct) return direct;

  const tmdbId = normalizeTmdbId(params.tmdbId);
  if (!tmdbId) return null;
  return imdbIdFromTmdb(tmdbId, isTvType(params.type), cleanParam(params.tmdbApiKey));
}

function parseBody(response) {
  if (!response) throw new Error("获取数据失败");
  const status = Number(response.statusCode || response.status || 200);
  if (status < 200 || status >= 300) throw new Error(`HTTP ${status}`);
  const body = response.data;
  if (typeof body === "string") {
    try {
      return JSON.parse(body);
    } catch (error) {
      throw new Error("Torrentio 返回了无效数据");
    }
  }
  return body;
}

function buildMagnet(stream) {
  const hash = cleanParam(stream.infoHash).toLowerCase();
  if (!/^[0-9a-f]{40}$/.test(hash)) return null;
  const parts = [`xt=urn:btih:${hash}`];
  const filename = stream.behaviorHints && stream.behaviorHints.filename;
  if (filename) parts.push(`dn=${encodeURIComponent(filename)}`);
  for (const source of stream.sources || []) {
    if (typeof source === "string" && source.startsWith("tracker:")) {
      parts.push(`tr=${encodeURIComponent(source.slice("tracker:".length))}`);
    }
  }
  return `magnet:?${parts.join("&")}`;
}

// Torrentio 的 name 形如 "Torrentio\n4k DV | HDR" 或 "[RD+] Torrentio\n1080p"；
// 去掉重复的插件名，只留调试标记和画质，作为线路名称。
function streamName(stream) {
  const lines = cleanParam(stream.name)
    .split("\n")
    .map((line) => line.replace(/\bTorrentio\b/g, "").trim())
    .filter(Boolean);
  return lines.join(" ") || "Torrentio";
}

function streamDescription(stream) {
  const title = cleanParam(stream.title || stream.description);
  return title || cleanParam(stream.behaviorHints && stream.behaviorHints.filename);
}

function toVideoResources(streams, showMagnets) {
  const resources = [];
  for (const stream of streams) {
    if (!stream) continue;
    if (stream.url && /^https?:\/\//i.test(stream.url)) {
      const resource = {
        name: streamName(stream),
        description: streamDescription(stream),
        url: stream.url,
      };
      const headers = stream.behaviorHints
        && stream.behaviorHints.proxyHeaders
        && stream.behaviorHints.proxyHeaders.request;
      if (headers && typeof headers === "object") resource.customHeaders = headers;
      resources.push(resource);
      continue;
    }
    if (showMagnets && stream.infoHash) {
      const magnet = buildMagnet(stream);
      if (magnet) {
        resources.push({
          name: `🧲 ${streamName(stream)}`,
          description: streamDescription(stream),
          url: magnet,
        });
      }
    }
  }
  return resources;
}

// Rex 只对「属于模块自己的条目」调用 loadResource：条目带 link，详情页先调用顶层
// loadDetail(link)，播放时再调用 loadResource（参数里带同一个 link）。tmdb/imdb 类型
// 会进入 Rex 内置详情页，与本模块脱钩，因此列表条目一律使用 url 类型 + torrentio: 链接。
const TORRENTIO_LINK = /^torrentio:(movie|series):(tt\d+)(?::(\d+):(\d+))?$/i;

function makeTorrentioLink(kind, imdbId, season, episode) {
  const base = `torrentio:${kind}:${imdbId}`;
  return season === undefined || season === null ? base : `${base}:${season}:${episode}`;
}

function parseTorrentioLink(value) {
  const match = cleanParam(value).match(TORRENTIO_LINK);
  if (!match) return null;
  return {
    kind: match[1].toLowerCase(),
    imdbId: match[2].toLowerCase(),
    season: match[3] === undefined ? null : Number(match[3]),
    episode: match[4] === undefined ? null : Number(match[4]),
  };
}

function metahubImage(url, size) {
  return cleanParam(url).replace(/\/(poster|background)\/(small|medium|large)\//, `/$1/${size}/`);
}

function cinemetaCommon(meta, mediaType) {
  const rating = Number(meta.imdbRating);
  const item = {
    title: cleanParam(meta.name),
    description: cleanParam(meta.description),
    releaseDate: cleanParam(meta.released).slice(0, 10) || cleanParam(meta.releaseInfo),
    mediaType,
    genreTitle: Array.isArray(meta.genres) ? meta.genres.slice(0, 3).join(" / ") : "",
  };
  if (Number.isFinite(rating) && rating > 0) item.rating = rating;
  if (meta.poster) item.posterPath = metahubImage(meta.poster, "medium");
  if (meta.background) item.backdropPath = meta.background;
  return item;
}

function cinemetaItem(meta, mediaType) {
  const imdbId = normalizeImdbId(meta.imdb_id || meta.id);
  if (!imdbId) return null;
  const link = makeTorrentioLink(mediaType === "tv" ? "series" : "movie", imdbId);
  return { id: link, type: "url", link, ...cinemetaCommon(meta, mediaType) };
}

async function popular(params) {
  recordCall("list", params);
  rememberSettings(params);
  const mediaType = isTvType(params.mediaType) ? "tv" : "movie";
  const catalog = cleanParam(params.catalog) === "imdbRating" ? "imdbRating" : "top";
  const page = Math.max(1, parseInt(cleanParam(params.page), 10) || 1);
  const extras = [];
  const genre = cleanParam(params.genre);
  if (genre) extras.push(`genre=${encodeURIComponent(genre)}`);
  if (page > 1) extras.push(`skip=${(page - 1) * CINEMETA_PAGE_SIZE}`);

  const stremioType = mediaType === "tv" ? "series" : "movie";
  const path = `${stremioType}/${catalog}${extras.length ? `/${extras.join("&")}` : ""}.json`;
  const response = await Widget.http.get(`${CINEMETA_BASE}/${catalog}/catalog/${path}`, { headers: torrentioHeaders() });
  const body = parseBody(response);
  const metas = body && Array.isArray(body.metas) ? body.metas : [];
  return metas.map((meta) => cinemetaItem(meta, mediaType)).filter(Boolean);
}

// 详情页：顶层函数，不写进 modules。剧集返回 episodeItems，每集带自己的 link。
async function loadDetail(input, ...rest) {
  const link = typeof input === "object" && input !== null ? (input.link || input.id) : input;
  const parsed = parseTorrentioLink(link);
  // Rex 若随 link 传入设置（对象参数或第二个参数），优先使用。
  for (const extra of [input, ...rest]) {
    if (extra && typeof extra === "object") rememberSettings(extra);
  }
  const settings = withSettings({});
  const settingsKnown = Boolean(loadRememberedSettings());
  const argShape = [input, ...rest].map((arg) => (arg && typeof arg === "object" ? `{${Object.keys(arg).join(",")}}` : typeof arg)).join(", ");
  torrentioLog(`loadDetail link=${cleanParam(link)} args=${1 + rest.length} settingsKnown=${settingsKnown}`, settings);
  if (!parsed) throw new Error("无效的 Torrentio 链接");

  const mediaType = parsed.kind === "series" ? "tv" : "movie";
  const response = await Widget.http.get(
    `${CINEMETA_META}/${parsed.kind}/${parsed.imdbId}.json`,
    { headers: torrentioHeaders() }
  );
  const body = parseBody(response);
  const meta = body && body.meta;
  if (!meta) throw new Error("Cinemeta 没有这部作品的信息");

  const detail = {
    id: makeTorrentioLink(parsed.kind, parsed.imdbId),
    type: "url",
    link: makeTorrentioLink(parsed.kind, parsed.imdbId),
    ...cinemetaCommon(meta, mediaType),
  };
  if (meta.runtime) detail.durationText = cleanParam(meta.runtime);

  // 诊断状态行（临时）：放在简介最前面，用户在详情页就能看到。
  const status = [`Torrentio ${WidgetMetadata.version}`];
  if (settingsKnown) {
    const minutes = Math.max(0, Math.round((Date.now() - (loadRememberedSettings().savedAt || Date.now())) / 60000));
    status.push(`settings: ${debridService(settings) ? debridService(settings).service : "no debrid key"} (saved ${minutes} min ago)`);
  } else {
    status.push("settings: not received yet");
  }
  status.push(lastCallText("list"));
  status.push(`detail args: ${argShape}`);
  status.push(`storage: ${typeof Widget !== "undefined" && Widget.storage ? "yes" : "no"}`);
  const playable = mediaType === "movie" || parsed.episode !== null;
  if (playable) {
    try {
      const target = { isTv: mediaType === "tv", season: parsed.season, episode: parsed.episode };
      const result = await fetchTorrentioResources(settings, parsed.imdbId, target);
      status.push(`${result.resources.length} sources found`);
      // 直接给出播放地址：即使 Rex 不调用 loadResource，详情页也有可播放的资源。
      const best = result.resources[0];
      if (best) {
        detail.videoUrl = best.url;
        if (best.customHeaders) detail.customHeaders = best.customHeaders;
      }
    } catch (error) {
      status.push(`error: ${String(error && error.message || error).slice(0, 160)}`);
    }
  }
  status.push(lastLoadResourceText());
  const statusText = status.join(" · ");

  if (parsed.episode !== null) {
    const video = (Array.isArray(meta.videos) ? meta.videos : []).find((item) =>
      Number(item.season) === parsed.season && Number(item.episode || item.number) === parsed.episode);
    const episodeLink = makeTorrentioLink("series", parsed.imdbId, parsed.season, parsed.episode);
    detail.id = episodeLink;
    detail.link = episodeLink;
    detail.season = parsed.season;
    detail.episode = parsed.episode;
    if (video) {
      detail.title = cleanParam(video.name || video.title) || `S${parsed.season}E${parsed.episode}`;
      detail.description = cleanParam(video.overview || video.description);
      if (video.thumbnail) detail.backdropPath = video.thumbnail;
    }
  }
  detail.description = `[${statusText}]\n\n${detail.description || ""}`.trim();
  if (playable) return detail;

  const episodes = (Array.isArray(meta.videos) ? meta.videos : [])
    .map((video) => ({ video, season: Number(video.season), episode: Number(video.episode || video.number) }))
    .filter(({ season, episode }) => Number.isInteger(season) && season >= 0 && Number.isInteger(episode) && episode > 0)
    // 正片按季集排序，第 0 季（特别篇）放最后。
    .sort((a, b) => ((a.season || 1e6) - (b.season || 1e6)) || (a.episode - b.episode));
  detail.episodeItems = episodes.map(({ video, season, episode }) => {
    const episodeLink = makeTorrentioLink("series", parsed.imdbId, season, episode);
    const item = {
      id: episodeLink,
      type: "url",
      link: episodeLink,
      title: cleanParam(video.name || video.title) || `S${season}E${episode}`,
      description: cleanParam(video.overview || video.description),
      releaseDate: cleanParam(video.released || video.firstAired).slice(0, 10),
      mediaType: "tv",
      season,
      episode,
    };
    if (video.thumbnail) item.coverUrl = video.thumbnail;
    return item;
  });
  return detail;
}

// ---- 设置记忆与诊断 ----
// loadDetail(link) 拿不到全局设置（网盘 Key 等），且与列表不在同一个 JS 引擎里，内存不共享。
// 因此把最近一次调用里出现的设置写入本模块自己的 Widget.storage（仅本机、仅本模块），
// 详情页从那里读取。诊断信息只记录参数名，不记录任何值。
const SETTING_NAMES = WidgetMetadata.globalParams.map((param) => param.name);
let rememberedSettings = null;

function rememberSettings(params) {
  if (!params || typeof params !== "object") return;
  if (!SETTING_NAMES.some((name) => params[name] !== undefined)) return;
  rememberedSettings = { savedAt: Date.now() };
  for (const name of SETTING_NAMES) {
    if (params[name] !== undefined) rememberedSettings[name] = params[name];
  }
  storageSet("torrentio.settings", JSON.stringify(rememberedSettings));
}

function loadRememberedSettings() {
  if (rememberedSettings) return rememberedSettings;
  try {
    rememberedSettings = JSON.parse(storageGet("torrentio.settings") || "null");
  } catch (error) {
    rememberedSettings = null;
  }
  return rememberedSettings;
}

// 只记参数名：用来判断 Rex 有没有把全局设置传给列表函数。
function recordCall(name, params) {
  const keys = params && typeof params === "object" ? Object.keys(params).sort() : [typeof params];
  storageSet(`torrentio.call.${name}`, JSON.stringify({ at: Date.now(), keys }));
}

function lastCallText(name) {
  let last = null;
  try {
    last = JSON.parse(storageGet(`torrentio.call.${name}`) || "null");
  } catch (error) {
    last = null;
  }
  if (!last || !last.at) return `${name}: never called`;
  const minutes = Math.max(0, Math.round((Date.now() - last.at) / 60000));
  return `${name} ${minutes} min ago got [${last.keys.join(", ")}]`;
}

function withSettings(params) {
  const merged = { ...(loadRememberedSettings() || {}) };
  delete merged.savedAt;
  for (const [key, value] of Object.entries(params || {})) {
    if (value !== undefined && value !== null && value !== "") merged[key] = value;
  }
  return merged;
}

function storageGet(key) {
  try {
    return typeof Widget !== "undefined" && Widget.storage ? Widget.storage.get(key) : null;
  } catch (error) {
    return null;
  }
}

function storageSet(key, value) {
  try {
    if (typeof Widget !== "undefined" && Widget.storage) Widget.storage.set(key, value);
  } catch (error) {
    // 诊断信息写不进去不影响播放。
  }
}

function recordLoadResource(summary) {
  storageSet("torrentio.lastLoadResource", JSON.stringify({ at: Date.now(), ...summary }));
}

function lastLoadResourceText() {
  let last = null;
  try {
    last = JSON.parse(storageGet("torrentio.lastLoadResource") || "null");
  } catch (error) {
    last = null;
  }
  if (!last || !last.at) return "Rex has never called loadResource";
  const minutes = Math.max(0, Math.round((Date.now() - last.at) / 60000));
  const outcome = last.error ? `error: ${last.error}` : `${last.count} sources`;
  return `Rex last called loadResource ${minutes} min ago for ${last.target || "?"} (${outcome})`;
}

function torrentioTarget(params, linked) {
  const hasEpisode = cleanParam(params.season) !== "" && cleanParam(params.episode) !== "";
  const isTv = linked ? linked.kind === "series"
    : isTvType(params.type) || (hasEpisode && cleanParam(params.type).toLowerCase() !== "movie");
  return {
    isTv,
    season: linked && linked.season !== null ? linked.season : parseInt(cleanParam(params.season), 10),
    episode: linked && linked.episode !== null ? linked.episode : parseInt(cleanParam(params.episode), 10),
  };
}

// 查询 Torrentio 并转换为 Rex 资源；loadResource 与 loadDetail 共用。
async function fetchTorrentioResources(params, imdbId, target) {
  let videoId = imdbId;
  if (target.isTv) {
    if (!(target.season >= 0) || !(target.episode > 0)) {
      throw new Error("缺少季/集信息");
    }
    videoId = `${imdbId}:${target.season}:${target.episode}`;
  }

  const config = buildTorrentioConfig(params);
  const configSegment = config ? `/${encodeURIComponent(config)}` : "";
  const url = `${torrentioServer(params)}${configSegment}/stream/${target.isTv ? "series" : "movie"}/${encodeURIComponent(videoId)}.json`;

  torrentioLog(`GET ${url}`, params);
  const response = await Widget.http.get(url, { headers: torrentioHeaders() });
  const body = parseBody(response);
  const streams = body && Array.isArray(body.streams) ? body.streams : [];

  const debrid = debridService(params);
  const showMagnets = cleanParam(params.showMagnets) === "true";
  const resources = toVideoResources(streams, showMagnets);
  torrentioLog(`torrentio streams=${streams.length} playable=${resources.length} debrid=${debrid ? debrid.service : "none"}`, params);

  if (resources.length === 0 && streams.length > 0 && !debrid && !showMagnets) {
    throw new Error(`找到 ${streams.length} 个种子，但未配置网盘服务，无法直接播放。请在设置中填写网盘服务和 API Key，或开启「磁力链接」。`);
  }
  return { videoId, streams, resources, debrid };
}

async function loadResource(rawParams) {
  recordCall("loadResource", rawParams);
  rememberSettings(rawParams);
  const params = withSettings(rawParams);
  torrentioLog(`loadResource params ${describeParams(rawParams)}`, params);
  let targetText = "?";
  try {
    // 来自本模块列表/详情的条目带 torrentio: 链接，直接给出 IMDb ID 与季集。
    const linked = parseTorrentioLink(params.link) || parseTorrentioLink(params.id) || parseTorrentioLink(params.videoUrl);
    const target = torrentioTarget(params, linked);
    const imdbId = linked ? linked.imdbId : await resolveImdbId(params);
    targetText = imdbId || cleanParam(params.tmdbId) || "?";
    torrentioLog(`resolved imdbId=${imdbId || "none"} isTv=${target.isTv} fromLink=${Boolean(linked)}`, params);
    if (!imdbId) {
      throw new Error("缺少 IMDb ID：Torrentio 只能按 IMDb ID 查询。可在设置中填写 TMDB API Key 以自动转换。");
    }
    const result = await fetchTorrentioResources(params, imdbId, target);
    recordLoadResource({ target: result.videoId, count: result.resources.length });
    return result.resources;
  } catch (error) {
    recordLoadResource({ target: targetText, error: String(error && error.message || error).slice(0, 120) });
    throw error;
  }
}
