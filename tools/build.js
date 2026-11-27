#!/usr/bin/env node
// Writes manifest.json from rex.torrentio.js, so the collection always offers the version the
// module file declares.
//
//   node tools/build.js
//
// Edit rex.torrentio.js, bump its `version`, then run this.
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const RAW = "https://raw.githubusercontent.com/mustafabshakimuddin-cloud/Reel-Media-Center/main";
const file = "rex.torrentio.js";
const meta = new Function(fs.readFileSync(path.join(root, file), "utf8") + "\nreturn WidgetMetadata;")();

const i18n = {};
for (const [lang, table] of Object.entries(meta.i18n || {})) {
  const picked = Object.fromEntries(Object.entries(table).filter(([key]) => key === meta.title || key === meta.description));
  if (Object.keys(picked).length) i18n[lang] = picked;
}
const manifest = {
  title: "Torrentio",
  description: "Torrentio torrent streams for playback through a debrid service",
  icon: meta.iconurl,
  widgets: [{
    id: meta.id, title: meta.title, version: meta.version, requiredVersion: meta.requiredVersion,
    description: meta.description, author: meta.author, url: `${RAW}/${file}`, i18n,
  }],
};
fs.writeFileSync(path.join(root, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log(`built manifest.json (version ${meta.version})`);
