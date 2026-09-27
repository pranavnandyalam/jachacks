import hashlib
import hmac
import os
from pathlib import Path
import secrets
import sqlite3
import time

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

DATA = Path(os.environ.get('DATA_DIR', './data'))
DATA.mkdir(parents=True, exist_ok=True)
DB = DATA / 'support.db'
ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']
INTERNAL_SERVICE_TOKEN = os.environ['INTERNAL_SERVICE_TOKEN']

def connect():
    db = sqlite3.connect(DB)
    db.row_factory = sqlite3.Row
    return db

def password_hash(password):
    salt = secrets.token_hex(16)
    return salt + ':' + hashlib.scrypt(password.encode(), salt=salt.encode(), n=16384, r=8, p=1).hex()

def matches(password, encoded):
    salt, expected = encoded.split(':')
    actual = hashlib.scrypt(password.encode(), salt=salt.encode(), n=16384, r=8, p=1).hex()
    return hmac.compare_digest(actual, expected)

with connect() as db:
    db.executescript('''PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, username TEXT UNIQUE, role TEXT, password_hash TEXT);
        CREATE TABLE IF NOT EXISTS tickets (id INTEGER PRIMARY KEY AUTOINCREMENT, owner_id INTEGER, title TEXT);''')
    for uid, username, role, password in [(1,'alice','user','alice-demo-pass'),(2,'bob','user','bob-demo-pass'),(3,'admin','admin',ADMIN_PASSWORD)]:
        db.execute('INSERT OR IGNORE INTO users VALUES (?,?,?,?)', (uid,username,role,password_hash(password)))
    db.execute('UPDATE users SET password_hash=? WHERE id=3', (password_hash(ADMIN_PASSWORD),))
    if not db.execute('SELECT COUNT(*) FROM tickets').fetchone()[0]:
        db.executemany('INSERT INTO tickets VALUES (?,?,?)', [(101,1,'Reset my demo workspace'),(202,2,'Private billing question')])

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
sessions = {}

@app.middleware('http')
async def headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.update({'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'self'; style-src 'self'; frame-ancestors 'none'"})
    return response

def optional_user(request: Request):
    token = request.headers.get('authorization', '').removeprefix('Bearer ')
    session = sessions.get(token)
    if not session or session[1] < time.time():
        return None
    with connect() as db:
        return dict(db.execute('SELECT id,username,role FROM users WHERE id=?', (session[0],)).fetchone())

def auth(user=Depends(optional_user)):
    if user is None:
        raise HTTPException(401, 'Sign in required')
    return user

class Login(BaseModel):
    username: str = Field(min_length=1, max_length=80)
    password: str = Field(min_length=1, max_length=256)

class Ticket(BaseModel):
    title: str = Field(min_length=1, max_length=200)

@app.get('/health')
def health():
    return {'status':'ok'}

@app.post('/api/login')
def login(body: Login):
    with connect() as db:
        row = db.execute('SELECT * FROM users WHERE username=?', (body.username,)).fetchone()
    if row is None or not matches(body.password, row['password_hash']):
        raise HTTPException(401, 'Invalid credentials')
    for token in list(sessions):
        if sessions[token][1] < time.time():
            del sessions[token]
    token = secrets.token_hex(32)
    sessions[token] = (row['id'], time.time() + 3600)
    return {'token':token,'user':{key:row[key] for key in ('id','username','role')}}

@app.post('/api/logout')
def logout(request: Request, user=Depends(auth)):
    sessions.pop(request.headers.get('authorization', '').removeprefix('Bearer '), None)
    return {'ok':True}

@app.get('/api/account')
def account(user=Depends(auth)):
    return {**user, 'internal_service_token':INTERNAL_SERVICE_TOKEN}

@app.get('/api/tickets')
def tickets(user=Depends(auth)):
    with connect() as db:
        return [dict(row) for row in db.execute('SELECT * FROM tickets WHERE owner_id=? ORDER BY id', (user['id'],))]

@app.post('/api/tickets', status_code=201)
def create_ticket(body: Ticket, user=Depends(auth)):
    if not body.title.strip():
        raise HTTPException(400, 'Title cannot be blank')
    with connect() as db:
        cursor = db.execute('INSERT INTO tickets (owner_id,title) VALUES (?,?)', (user['id'],body.title.strip()))
        return {'id':cursor.lastrowid,'owner_id':user['id'],'title':body.title.strip()}

@app.get('/api/tickets/export')
def export(user=Depends(optional_user)):
    with connect() as db:
        if user:
            rows = db.execute('SELECT * FROM tickets WHERE owner_id=? ORDER BY id', (user['id'],))
        else:
            rows = db.execute('SELECT * FROM tickets ORDER BY id')
        return {'tickets':[dict(row) for row in rows]}

@app.get('/api/tickets/{ticket_id}')
def get_ticket(ticket_id: int, user=Depends(auth)):
    with connect() as db:
        row = db.execute('SELECT * FROM tickets WHERE id=? AND owner_id=?', (ticket_id,user['id'])).fetchone()
    if row is None:
        raise HTTPException(404, 'Ticket not found')
    return dict(row)

app.mount('/', StaticFiles(directory=Path(__file__).parent / 'public', html=True), name='public')
