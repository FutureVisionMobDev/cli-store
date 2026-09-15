import express from "express";
import Database from "better-sqlite3";
import multer from "multer";
import crypto from "crypto";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT) || 3000;
const ADMIN_USER = process.env.ADMIN_USER || "admin";
const ADMIN_PASS = process.env.ADMIN_PASS || "changeme";

const uploadsDir = path.join(__dirname, "uploads");
const dataDir = path.join(__dirname, "data");
const publicDir = path.join(__dirname, "public");

fs.mkdirSync(uploadsDir, { recursive: true });
fs.mkdirSync(dataDir, { recursive: true });
const tmpUploadDir = path.join(dataDir, "tmp-uploads");
fs.mkdirSync(tmpUploadDir, { recursive: true });

const MAX_UPLOAD_BYTES = 8 * 1024 * 1024 * 1024; // 8 GB
const CHUNK_SIZE = 8 * 1024 * 1024; // 8 MB — under Cloudflare free ~100MB limit
const pendingUploads = new Map();

const db = new Database(path.join(dataDir, "store.db"));
db.pragma("journal_mode = WAL");
db.pragma("foreign_keys = ON");

db.exec(`
  CREATE TABLE IF NOT EXISTS apps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    slug TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    description TEXT DEFAULT ''
  );

  CREATE TABLE IF NOT EXISTS versions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id INTEGER NOT NULL,
    os TEXT NOT NULL,
    arch TEXT DEFAULT 'x64',
    version TEXT NOT NULL,
    filename TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    args TEXT DEFAULT '',
    size INTEGER DEFAULT 0,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (app_id) REFERENCES apps(id) ON DELETE CASCADE
  );
`);

{
  const cols = db.prepare("PRAGMA table_info(versions)").all().map((c) => c.name);
  if (!cols.includes("source_url")) {
    db.exec("ALTER TABLE versions ADD COLUMN source_url TEXT DEFAULT ''");
  }
}

const app = express();
app.set("trust proxy", true);
app.use(express.json({ limit: "2mb" }));

function basicAuth(req, res, next) {
  const header = req.headers.authorization || "";
  if (!header.startsWith("Basic ")) {
    res.set("WWW-Authenticate", 'Basic realm="App Store Admin"');
    return res.status(401).json({ error: "authentication required" });
  }
  let decoded;
  try {
    decoded = Buffer.from(header.slice(6), "base64").toString("utf8");
  } catch {
    res.set("WWW-Authenticate", 'Basic realm="App Store Admin"');
    return res.status(401).json({ error: "invalid authorization header" });
  }
  const sep = decoded.indexOf(":");
  const user = sep >= 0 ? decoded.slice(0, sep) : "";
  const pass = sep >= 0 ? decoded.slice(sep + 1) : "";
  if (user !== ADMIN_USER || pass !== ADMIN_PASS) {
    res.set("WWW-Authenticate", 'Basic realm="App Store Admin"');
    return res.status(401).json({ error: "invalid credentials" });
  }
  next();
}

function baseUrl(req) {
  const fromEnv = String(process.env.PUBLIC_BASE_URL || "")
    .trim()
    .replace(/\/$/, "");
  if (fromEnv) return fromEnv;
  const xfProto = String(req.get("x-forwarded-proto") || "")
    .split(",")[0]
    .trim();
  const proto = xfProto || req.protocol || "https";
  const host = req.get("x-forwarded-host") || req.get("host");
  return `${proto}://${host}`;
}

function sendError(res, status, message) {
  return res.status(status).json({ error: message });
}

const upload = multer({
  dest: uploadsDir,
  limits: { fileSize: MAX_UPLOAD_BYTES },
});

const chunkUpload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => {
      const id = String(req.body?.uploadId || "").trim();
      if (!id || !pendingUploads.has(id)) {
        return cb(new Error("invalid uploadId"));
      }
      const dir = path.join(tmpUploadDir, id);
      fs.mkdirSync(dir, { recursive: true });
      cb(null, dir);
    },
    filename: (req, file, cb) => {
      const index = String(req.body?.index ?? "");
      cb(null, `${index}.part`);
    },
  }),
  limits: { fileSize: CHUNK_SIZE + 1024 * 1024 },
});

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash("sha256");
    const stream = fs.createReadStream(filePath);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

function ensureAppRow({ slug, name, description }) {
  let appRow = db.prepare("SELECT id, name FROM apps WHERE slug = ?").get(slug);
  if (!appRow) {
    if (!name) throw Object.assign(new Error("name is required when creating a new app via upload"), { status: 400 });
    const info = db
      .prepare("INSERT INTO apps (slug, name, description) VALUES (?, ?, ?)")
      .run(slug, name, description || "");
    appRow = { id: Number(info.lastInsertRowid), name };
  } else if (name) {
    db.prepare("UPDATE apps SET name = ?, description = ? WHERE id = ?").run(
      name,
      description || "",
      appRow.id
    );
  }
  return appRow;
}

function finalizeVersion({
  appRow,
  os,
  arch,
  version,
  args,
  size,
  sha256,
  filename,
  sourceUrl = "",
}) {
  db.prepare(
    `INSERT INTO versions (app_id, os, arch, version, filename, sha256, args, size, source_url)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    appRow.id,
    os,
    arch,
    version,
    filename,
    sha256,
    args || "",
    size || 0,
    sourceUrl || ""
  );
  return { ok: true, sha256, filename, size: size || 0, source_url: sourceUrl || "" };
}

app.get("/apps.json", (req, res) => {
  try {
    const apps = db.prepare("SELECT id, slug, name, description FROM apps ORDER BY name").all();
    const latestStmt = db.prepare(`
      SELECT os, arch, version, filename, sha256, args, size, created_at, COALESCE(source_url, '') AS source_url
      FROM versions
      WHERE app_id = ?
      ORDER BY datetime(created_at) DESC, id DESC
    `);
    const out = {};
    const origin = baseUrl(req);
    for (const a of apps) {
      const versions = latestStmt.all(a.id);
      const entry = { name: a.name, description: a.description || "" };
      const seen = new Set();
      for (const v of versions) {
        if (seen.has(v.os)) continue;
        seen.add(v.os);
        let fileUrl = v.source_url
          ? v.source_url
          : `${origin}/files/${encodeURIComponent(v.filename)}`;
        // Prefer https for same-host file URLs (Coolify/Traefik often report http)
        try {
          const u = new URL(fileUrl);
          if (u.hostname === new URL(origin).hostname && u.protocol === "http:") {
            u.protocol = "https:";
            fileUrl = u.toString();
          }
        } catch {
          /* keep fileUrl */
        }
        entry[v.os] = {
          version: v.version,
          arch: v.arch || "x64",
          url: fileUrl,
          sha256: v.sha256,
          args: v.args || "",
          size: Number(v.size) || 0,
          source: v.source_url ? "remote" : "local",
        };
      }
      if (seen.size === 0) continue;
      out[a.slug] = entry;
    }
    res.json(out);
  } catch (err) {
    console.error(err);
    sendError(res, 500, "failed to build manifest");
  }
});

// Explicit file route: Content-Length + Range so big downloads can resume past Cloudflare cuts
app.get("/files/:filename", (req, res) => {
  const raw = path.basename(String(req.params.filename || ""));
  if (!raw || raw !== req.params.filename) {
    return sendError(res, 400, "invalid filename");
  }
  const filePath = path.join(uploadsDir, raw);
  if (!filePath.startsWith(uploadsDir) || !fs.existsSync(filePath)) {
    return sendError(res, 404, "file not found");
  }
  const stat = fs.statSync(filePath);
  const total = stat.size;
  res.setHeader("Accept-Ranges", "bytes");
  res.setHeader("Cache-Control", "public, max-age=14400");
  const range = req.headers.range;
  if (range) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (!m) {
      res.setHeader("Content-Range", `bytes */${total}`);
      return res.status(416).end();
    }
    const start = m[1] ? Number(m[1]) : 0;
    const end = m[2] ? Number(m[2]) : total - 1;
    if (
      !Number.isFinite(start) ||
      !Number.isFinite(end) ||
      start < 0 ||
      end >= total ||
      start > end
    ) {
      res.setHeader("Content-Range", `bytes */${total}`);
      return res.status(416).end();
    }
    const chunk = end - start + 1;
    res.status(206);
    res.setHeader("Content-Range", `bytes ${start}-${end}/${total}`);
    res.setHeader("Content-Length", String(chunk));
    res.type(path.extname(raw) || "application/octet-stream");
    fs.createReadStream(filePath, { start, end }).pipe(res);
    return;
  }
  res.setHeader("Content-Length", String(total));
  res.type(path.extname(raw) || "application/octet-stream");
  fs.createReadStream(filePath).pipe(res);
});

function serveInstallScript(filename) {
  return (req, res) => {
    const filePath = path.join(publicDir, filename);
    if (!fs.existsSync(filePath)) return sendError(res, 404, "script not found");
    res.type("text/plain");
    res.sendFile(filePath);
  };
}

app.get("/install.ps1", serveInstallScript("install.ps1"));
app.get("/install.sh", serveInstallScript("install.sh"));

app.get("/", (req, res) => {
  const ua = String(req.get("user-agent") || "").toLowerCase();
  // irm https://appstore… | iex
  if (ua.includes("powershell") || ua.includes("pwsh")) {
    res.type("text/plain; charset=utf-8");
    return res.sendFile(path.join(publicDir, "install.ps1"));
  }
  // curl -fsSL https://appstore… | bash
  if (ua.includes("curl/") || ua.includes("wget") || ua.includes("httpie")) {
    res.type("text/plain; charset=utf-8");
    return res.sendFile(path.join(publicDir, "install.sh"));
  }
  res.sendFile(path.join(publicDir, "index.html"));
});

app.get("/admin", basicAuth, (req, res) => {
  res.sendFile(path.join(publicDir, "admin.html"));
});

app.get("/admin/api/apps", basicAuth, (req, res) => {
  try {
    const apps = db.prepare("SELECT id, slug, name, description FROM apps ORDER BY name").all();
    const verStmt = db.prepare(`
      SELECT id, os, arch, version, filename, sha256, args, size, created_at,
             COALESCE(source_url, '') AS source_url
      FROM versions WHERE app_id = ? ORDER BY datetime(created_at) DESC, id DESC
    `);
    const result = apps.map((a) => ({
      ...a,
      versions: verStmt.all(a.id),
    }));
    res.json(result);
  } catch (err) {
    console.error(err);
    sendError(res, 500, "failed to list apps");
  }
});

app.post("/admin/api/apps", basicAuth, (req, res) => {
  return sendError(
    res,
    400,
    "create app only by uploading an installer — use POST /admin/api/upload with slug, name, file"
  );
});

app.delete("/admin/api/apps/:slug", basicAuth, (req, res) => {
  try {
    const slug = String(req.params.slug || "").toLowerCase();
    const row = db.prepare("SELECT id FROM apps WHERE slug = ?").get(slug);
    if (!row) return sendError(res, 404, "app not found");
    const versions = db
      .prepare(
        "SELECT filename, COALESCE(source_url, '') AS source_url FROM versions WHERE app_id = ?"
      )
      .all(row.id);
    for (const v of versions) {
      if (v.source_url) continue;
      const fp = path.join(uploadsDir, v.filename);
      try {
        if (fs.existsSync(fp)) fs.unlinkSync(fp);
      } catch (err) {
        console.error("unlink failed", fp, err);
      }
    }
    db.prepare("DELETE FROM apps WHERE id = ?").run(row.id);
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    sendError(res, 500, "failed to delete app");
  }
});

app.post("/admin/api/upload/init", basicAuth, (req, res) => {
  try {
    const slug = String(req.body?.slug || "").trim().toLowerCase();
    const name = String(req.body?.name || "").trim();
    const description = String(req.body?.description || "").trim();
    const os = String(req.body?.os || "").trim();
    const arch = String(req.body?.arch || "x64").trim() || "x64";
    const version = String(req.body?.version || "").trim();
    const args = String(req.body?.args || "");
    const originalName = String(req.body?.filename || "").trim();
    const size = Number(req.body?.size || 0);

    if (!slug || !os || !version || !originalName || !Number.isFinite(size) || size <= 0) {
      return sendError(res, 400, "slug, os, version, filename, and size are required");
    }
    if (os !== "win" && os !== "mac") return sendError(res, 400, "os must be win or mac");
    if (size > MAX_UPLOAD_BYTES) return sendError(res, 400, "file too large (max 8GB)");
    if (!name) {
      const exists = db.prepare("SELECT id FROM apps WHERE slug = ?").get(slug);
      if (!exists) return sendError(res, 400, "name is required when creating a new app via upload");
    }

    const ext = path.extname(originalName) || "";
    const filename = `${slug}-${os}-${version}${ext}`;
    const uploadId = crypto.randomBytes(16).toString("hex");
    const totalChunks = Math.ceil(size / CHUNK_SIZE);
    const dir = path.join(tmpUploadDir, uploadId);
    fs.mkdirSync(dir, { recursive: true });

    pendingUploads.set(uploadId, {
      slug,
      name,
      description,
      os,
      arch,
      version,
      args,
      filename,
      size,
      totalChunks,
      received: new Set(),
      createdAt: Date.now(),
    });

    res.json({ ok: true, uploadId, chunkSize: CHUNK_SIZE, totalChunks });
  } catch (err) {
    console.error(err);
    sendError(res, 500, "failed to init upload");
  }
});

app.post("/admin/api/upload/chunk", basicAuth, (req, res) => {
  chunkUpload.single("chunk")(req, res, (err) => {
    if (err) {
      console.error(err);
      return sendError(res, 400, err.message || "chunk upload failed");
    }
    try {
      const uploadId = String(req.body?.uploadId || "").trim();
      const index = Number(req.body?.index);
      const meta = pendingUploads.get(uploadId);
      if (!meta) return sendError(res, 404, "upload session not found");
      if (!Number.isInteger(index) || index < 0 || index >= meta.totalChunks) {
        return sendError(res, 400, "invalid chunk index");
      }
      if (!req.file) return sendError(res, 400, "chunk file required");
      meta.received.add(index);
      res.json({
        ok: true,
        index,
        received: meta.received.size,
        totalChunks: meta.totalChunks,
      });
    } catch (e) {
      console.error(e);
      sendError(res, 500, "chunk save failed");
    }
  });
});

app.post("/admin/api/upload/complete", basicAuth, async (req, res) => {
  const uploadId = String(req.body?.uploadId || "").trim();
  const meta = pendingUploads.get(uploadId);
  const dir = path.join(tmpUploadDir, uploadId);
  try {
    if (!meta) return sendError(res, 404, "upload session not found");
    if (meta.received.size !== meta.totalChunks) {
      return sendError(
        res,
        400,
        `missing chunks: got ${meta.received.size}/${meta.totalChunks}`
      );
    }

    const dest = path.join(uploadsDir, meta.filename);
    if (fs.existsSync(dest)) fs.unlinkSync(dest);
    for (let i = 0; i < meta.totalChunks; i++) {
      const part = path.join(dir, `${i}.part`);
      if (!fs.existsSync(part)) throw new Error(`missing part ${i}`);
      fs.appendFileSync(dest, fs.readFileSync(part));
    }

    const size = fs.statSync(dest).size;
    if (size !== meta.size) {
      try { fs.unlinkSync(dest); } catch { /* ignore */ }
      return sendError(res, 400, `size mismatch: expected ${meta.size} got ${size}`);
    }

    const sha256 = await sha256File(dest);
    const appRow = ensureAppRow(meta);
    const result = finalizeVersion({
      appRow,
      os: meta.os,
      arch: meta.arch,
      version: meta.version,
      args: meta.args,
      size,
      sha256,
      filename: meta.filename,
    });

    pendingUploads.delete(uploadId);
    fs.rmSync(dir, { recursive: true, force: true });
    res.json(result);
  } catch (err) {
    console.error(err);
    sendError(res, err.status || 500, err.message || "complete upload failed");
  }
});

app.post("/admin/api/upload", basicAuth, upload.single("file"), async (req, res) => {
  try {
    const slug = String(req.body?.slug || "").trim().toLowerCase();
    const name = String(req.body?.name || "").trim();
    const description = String(req.body?.description || "").trim();
    const os = String(req.body?.os || "").trim();
    const arch = String(req.body?.arch || "x64").trim() || "x64";
    const version = String(req.body?.version || "").trim();
    const args = String(req.body?.args || "");
    const file = req.file;

    if (!slug || !os || !version || !file) {
      if (file?.path && fs.existsSync(file.path)) fs.unlinkSync(file.path);
      return sendError(res, 400, "slug, os, version, and file are required");
    }
    if (os !== "win" && os !== "mac") {
      if (file.path && fs.existsSync(file.path)) fs.unlinkSync(file.path);
      return sendError(res, 400, "os must be win or mac");
    }

    // Prefer chunked upload for anything over ~80MB (Cloudflare free limit ~100MB)
    if (file.size > 80 * 1024 * 1024) {
      fs.unlinkSync(file.path);
      return sendError(
        res,
        413,
        "file too large for single request — admin UI uses chunked upload automatically"
      );
    }

    const appRow = ensureAppRow({ slug, name, description });
    const ext = path.extname(file.originalname || "") || "";
    const filename = `${slug}-${os}-${version}${ext}`;
    const dest = path.join(uploadsDir, filename);
    if (fs.existsSync(dest)) fs.unlinkSync(dest);
    fs.renameSync(file.path, dest);

    const sha256 = await sha256File(dest);
    const size = fs.statSync(dest).size;
    const result = finalizeVersion({
      appRow,
      os,
      arch,
      version,
      args,
      size,
      sha256,
      filename,
    });
    res.json({ ...result, created: true });
  } catch (err) {
    console.error(err);
    if (req.file?.path && fs.existsSync(req.file.path)) {
      try { fs.unlinkSync(req.file.path); } catch { /* ignore */ }
    }
    sendError(res, err.status || 500, err.message || "upload failed");
  }
});

app.post("/admin/api/remote", basicAuth, (req, res) => {
  try {
    const slug = String(req.body?.slug || "").trim().toLowerCase();
    const name = String(req.body?.name || "").trim();
    const description = String(req.body?.description || "").trim();
    const os = String(req.body?.os || "").trim();
    const arch = String(req.body?.arch || "x64").trim() || "x64";
    const version = String(req.body?.version || "").trim();
    const args = String(req.body?.args || "");
    const sourceUrl = String(req.body?.url || "").trim();
    const sha256 = String(req.body?.sha256 || "").trim().toLowerCase();
    const size = Number(req.body?.size || 0) || 0;

    if (!slug || !os || !version || !sourceUrl || !sha256) {
      return sendError(res, 400, "slug, os, version, url, and sha256 are required");
    }
    if (os !== "win" && os !== "mac") return sendError(res, 400, "os must be win or mac");
    if (!/^https?:\/\//i.test(sourceUrl)) {
      return sendError(res, 400, "url must start with http:// or https://");
    }
    if (!/^[a-f0-9]{64}$/.test(sha256)) {
      return sendError(res, 400, "sha256 must be a 64-char hex digest");
    }

    let urlObj;
    try {
      urlObj = new URL(sourceUrl);
    } catch {
      return sendError(res, 400, "invalid url");
    }

    const baseName = path.basename(urlObj.pathname) || `${slug}-${os}-${version}`;
    const ext = path.extname(baseName) || "";
    const filename = `remote-${slug}-${os}-${version}${ext || ".bin"}`;

    const appRow = ensureAppRow({ slug, name, description });
    const result = finalizeVersion({
      appRow,
      os,
      arch,
      version,
      args,
      size,
      sha256,
      filename,
      sourceUrl,
    });
    res.json({ ...result, created: true, source: "remote" });
  } catch (err) {
    console.error(err);
    sendError(res, err.status || 500, err.message || "failed to register remote package");
  }
});

app.delete("/admin/api/versions/:id", basicAuth, (req, res) => {
  try {
    const id = Number(req.params.id);
    if (!Number.isFinite(id)) return sendError(res, 400, "invalid version id");
    const row = db
      .prepare(
        "SELECT id, filename, app_id, COALESCE(source_url, '') AS source_url FROM versions WHERE id = ?"
      )
      .get(id);
    if (!row) return sendError(res, 404, "version not found");
    if (!row.source_url) {
      const fp = path.join(uploadsDir, row.filename);
      try {
        if (fs.existsSync(fp)) fs.unlinkSync(fp);
      } catch (err) {
        console.error("unlink failed", fp, err);
      }
    }
    db.prepare("DELETE FROM versions WHERE id = ?").run(id);
    const left = db.prepare("SELECT COUNT(*) AS c FROM versions WHERE app_id = ?").get(row.app_id);
    if (left && left.c === 0) {
      db.prepare("DELETE FROM apps WHERE id = ?").run(row.app_id);
    }
    res.json({ ok: true });
  } catch (err) {
    console.error(err);
    sendError(res, 500, "failed to delete version");
  }
});

app.use((err, req, res, next) => {
  console.error(err);
  if (res.headersSent) return next(err);
  sendError(res, 500, "internal server error");
});

const server = app.listen(PORT, () => {
  console.log(`appstore listening on :${PORT}`);
});
server.setTimeout(0);
server.requestTimeout = 0;
server.headersTimeout = 65 * 60 * 1000;
