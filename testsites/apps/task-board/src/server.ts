import express from 'express';
import type { Request, Response, NextFunction } from 'express';
import { DatabaseSync } from 'node:sqlite';
import { randomBytes, scryptSync, timingSafeEqual } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

type User = { id: number; username: string; role: string; password_hash: string; display_name: string };
const data = process.env.DATA_DIR || './data';
mkdirSync(data, { recursive: true });
const db = new DatabaseSync(resolve(data, 'tasks.db'));
db.exec(`PRAGMA journal_mode=WAL;
  CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, username TEXT UNIQUE NOT NULL, role TEXT NOT NULL, password_hash TEXT NOT NULL, display_name TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, owner_id INTEGER NOT NULL REFERENCES users(id), title TEXT NOT NULL);`);
function hash(password: string): string {
  const salt = randomBytes(16).toString('hex');
  return salt + ':' + scryptSync(password, salt, 32).toString('hex');
}
function matches(password: string, encoded: string): boolean {
  const [salt, expected] = encoded.split(':');
  return timingSafeEqual(scryptSync(password, salt, 32), Buffer.from(expected, 'hex'));
}
const adminPassword = process.env.ADMIN_PASSWORD;
if (!adminPassword) throw new Error('ADMIN_PASSWORD is required');
for (const [id, username, role, password] of [[1,'alice','user','alice-demo-pass'],[2,'bob','user','bob-demo-pass'],[3,'admin','admin',adminPassword]] as const) {
  db.prepare('INSERT OR IGNORE INTO users VALUES (?, ?, ?, ?, ?)').run(id, username, role, hash(password), username);
}
// Refresh runtime credentials across rebuilds without resetting business data.
db.prepare('UPDATE users SET password_hash=? WHERE id=3').run(hash(adminPassword));
if (!(db.prepare('SELECT COUNT(*) AS n FROM tasks').get() as { n: number }).n) {
  db.prepare('INSERT INTO tasks (id,owner_id,title) VALUES (101,1,?), (202,2,?)').run('Prepare the demo', 'Private launch checklist');
}
const sessions = new Map<string, { id: number; expires: number }>();
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '16kb' }));
app.use((_req, res, next) => {
  res.set({'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'self'; style-src 'self'; frame-ancestors 'none'"}); next();
});
app.get('/health', (_req, res) => res.json({status:'ok'}));
app.post('/api/login', (req, res) => {
  const {username, password} = req.body || {};
  if (typeof username !== 'string' || typeof password !== 'string' || password.length > 256) { res.status(400).json({error:'Invalid credentials format'}); return; }
  const user = db.prepare('SELECT * FROM users WHERE username=?').get(username) as User | undefined;
  if (!user || !matches(password, user.password_hash)) { res.status(401).json({error:'Invalid credentials'}); return; }
  for (const [key, value] of sessions) if (value.expires < Date.now()) sessions.delete(key);
  const token = randomBytes(32).toString('hex');
  sessions.set(token, {id:user.id, expires:Date.now() + 3600000});
  res.json({token, user:{id:user.id, username:user.username, role:user.role}});
});
function auth(req: Request, res: Response, next: NextFunction) {
  const session = sessions.get((req.get('Authorization') || '').replace(/^Bearer /, ''));
  if (!session || session.expires < Date.now()) { res.status(401).json({error:'Sign in required'}); return; }
  res.locals.user = db.prepare('SELECT * FROM users WHERE id=?').get(session.id) as User;
  next();
}
app.use('/api', auth);
app.post('/api/logout', (req, res) => { sessions.delete((req.get('Authorization') || '').replace(/^Bearer /, '')); res.json({ok:true}); });
app.get('/api/me', (_req, res) => { const u = res.locals.user as User; res.json({id:u.id,username:u.username,role:u.role,display_name:u.display_name}); });
app.get('/api/tasks', (_req, res) => res.json(db.prepare('SELECT * FROM tasks WHERE owner_id=? ORDER BY id').all(res.locals.user.id)));
app.post('/api/tasks', (req, res) => {
  const title = req.body?.title;
  if (typeof title !== 'string' || !title.trim() || title.length > 200) { res.status(400).json({error:'Title must be 1–200 characters'}); return; }
  const result = db.prepare('INSERT INTO tasks (owner_id,title) VALUES (?,?)').run(res.locals.user.id,title.trim());
  res.status(201).json(db.prepare('SELECT * FROM tasks WHERE id=?').get(result.lastInsertRowid));
});
app.get('/api/tasks/:id', (req, res) => {
  const task = db.prepare('SELECT * FROM tasks WHERE id=?').get(String(req.params.id));
  if (!task) { res.status(404).json({error:'Task not found'}); return; }
  res.json(task);
});
app.get('/api/admin/users', (_req, res) => {
  if (res.locals.user.role !== 'admin') { res.status(403).json({error:'Administrator required'}); return; }
  res.json(db.prepare('SELECT id,username,role,display_name FROM users ORDER BY id').all());
});
app.patch('/api/admin/users/:id', (req, res) => {
  const name = req.body?.display_name;
  if (typeof name !== 'string' || !name.trim() || name.length > 80) { res.status(400).json({error:'Display name must be 1–80 characters'}); return; }
  const result = db.prepare('UPDATE users SET display_name=? WHERE id=?').run(name.trim(),String(req.params.id));
  if (!result.changes) { res.status(404).json({error:'User not found'}); return; }
  res.json({ok:true});
});
app.use(express.static(resolve('public')));
app.use((_req, res) => res.status(404).json({error:'Not found'}));
app.use((_err: Error, _req: Request, res: Response, _next: NextFunction) => res.status(400).json({error:'Invalid request'}));
app.listen(Number(process.env.PORT || 8080), process.env.HOST || '0.0.0.0');
