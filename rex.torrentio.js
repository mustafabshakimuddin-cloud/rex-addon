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
  version: "1.1.0",
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
  return value === "tv" || value === "series" || value === "show";
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

// Cinemeta 条目带 TMDB ID（moviedb_id）时按 Rex 官方模块的方式返回 tmdb 条目，
// 进入内置详情页；没有时退回 imdb 条目。两者都能让 loadResource 拿到可查询的 ID。
function cinemetaItem(meta, mediaType) {
  const imdbId = normalizeImdbId(meta.imdb_id || meta.id);
  const tmdbId = normalizeTmdbId(meta.moviedb_id);
  if (!imdbId && !tmdbId) return null;
  const rating = Number(meta.imdbRating);
  const item = {
    id: tmdbId ? Number(tmdbId) : imdbId,
    type: tmdbId ? "tmdb" : "imdb",
    title: cleanParam(meta.name),
    description: cleanParam(meta.description),
    releaseDate: cleanParam(meta.released).slice(0, 10) || cleanParam(meta.releaseInfo),
    mediaType,
    genreTitle: Array.isArray(meta.genres) ? meta.genres.slice(0, 3).join(" / ") : "",
  };
  if (Number.isFinite(rating) && rating > 0) item.rating = rating;
  if (meta.poster) item.coverUrl = meta.poster;
  return item;
}

async function popular(params) {
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

async function loadResource(params) {
  const isTv = isTvType(params.type);
  const imdbId = await resolveImdbId(params);
  if (!imdbId) {
    throw new Error("缺少 IMDb ID：Torrentio 只能按 IMDb ID 查询。可在设置中填写 TMDB API Key 以自动转换。");
  }

  let videoId = imdbId;
  if (isTv) {
    const season = parseInt(cleanParam(params.season), 10);
    const episode = parseInt(cleanParam(params.episode), 10);
    if (!(season >= 0) || !(episode > 0)) {
      throw new Error("缺少季/集信息");
    }
    videoId = `${imdbId}:${season}:${episode}`;
  }

  const config = buildTorrentioConfig(params);
  const configSegment = config ? `/${encodeURIComponent(config)}` : "";
  const url = `${torrentioServer(params)}${configSegment}/stream/${isTv ? "series" : "movie"}/${encodeURIComponent(videoId)}.json`;

  const response = await Widget.http.get(url, { headers: torrentioHeaders() });
  const body = parseBody(response);
  const streams = body && Array.isArray(body.streams) ? body.streams : [];

  const hasDebrid = Boolean(debridService(params));
  const showMagnets = cleanParam(params.showMagnets) === "true";
  const resources = toVideoResources(streams, showMagnets);

  if (resources.length === 0 && streams.length > 0 && !hasDebrid && !showMagnets) {
    throw new Error(`找到 ${streams.length} 个种子，但未配置网盘服务，无法直接播放。请在设置中填写网盘服务和 API Key，或开启「磁力链接」。`);
  }
  return resources;
}
