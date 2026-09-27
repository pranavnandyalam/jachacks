package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

var adminPassword = os.Getenv("ADMIN_PASSWORD")

type User struct {
	ID       int    `json:"id"`
	Username string `json:"username"`
	Role     string `json:"role"`
}
type Session struct {
	User    User
	Expires time.Time
}
type Deployment struct {
	ID        int    `json:"id"`
	Version   string `json:"version"`
	Status    string `json:"status"`
	CreatedBy string `json:"created_by"`
}

var mu sync.Mutex
var sessions = map[string]Session{}
var deployments []Deployment
var statePath string
var users = map[string]User{"alice": {1, "alice", "user"}, "bob": {2, "bob", "user"}, "admin": {3, "admin", "admin"}}

func send(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
func fail(w http.ResponseWriter, status int) {
	send(w, status, map[string]string{"error": http.StatusText(status)})
}
func decode(w http.ResponseWriter, r *http.Request, target any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 16384)
	decoder := json.NewDecoder(r.Body)
	if decoder.Decode(target) != nil {
		fail(w, 400)
		return false
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		fail(w, 400)
		return false
	}
	return true
}
func current(r *http.Request) (User, bool) {
	mu.Lock()
	defer mu.Unlock()
	session, ok := sessions[strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")]
	return session.User, ok && time.Now().Before(session.Expires)
}
func protected(admin bool, handler func(http.ResponseWriter, *http.Request, User)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u, ok := current(r)
		if !ok {
			fail(w, 401)
			return
		}
		if admin && u.Role != "admin" {
			fail(w, 403)
			return
		}
		handler(w, r, u)
	}
}
func persist() error {
	raw, err := json.Marshal(deployments)
	if err != nil {
		return err
	}
	if err = os.WriteFile(statePath+".tmp", raw, 0600); err != nil {
		return err
	}
	return os.Rename(statePath+".tmp", statePath)
}
func main() {
	if adminPassword == "" {
		log.Fatal("ADMIN_PASSWORD is required")
	}
	dir := os.Getenv("DATA_DIR")
	if dir == "" {
		dir = "./data"
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		log.Fatal(err)
	}
	statePath = filepath.Join(dir, "deployments.json")
	raw, err := os.ReadFile(statePath)
	if os.IsNotExist(err) {
		deployments = []Deployment{{1, "v1.0.0", "healthy", "admin"}}
		if err = persist(); err != nil {
			log.Fatal(err)
		}
	} else if err != nil {
		log.Fatal(err)
	} else if err = json.Unmarshal(raw, &deployments); err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) { send(w, 200, map[string]string{"status": "ok"}) })
	mux.HandleFunc("POST /api/login", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Username string `json:"username"`
			Password string `json:"password"`
		}
		if !decode(w, r, &body) {
			return
		}
		passwords := map[string]string{"alice": "alice-demo-pass", "bob": "bob-demo-pass", "admin": adminPassword}
		expected, ok := passwords[body.Username]
		if !ok || subtle.ConstantTimeCompare([]byte(body.Password), []byte(expected)) != 1 {
			fail(w, 401)
			return
		}
		bytes := make([]byte, 32)
		if _, err := rand.Read(bytes); err != nil {
			fail(w, 500)
			return
		}
		token := hex.EncodeToString(bytes)
		mu.Lock()
		for key, s := range sessions {
			if time.Now().After(s.Expires) {
				delete(sessions, key)
			}
		}
		sessions[token] = Session{users[body.Username], time.Now().Add(time.Hour)}
		mu.Unlock()
		send(w, 200, map[string]any{"token": token, "user": users[body.Username]})
	})
	mux.HandleFunc("POST /api/logout", protected(false, func(w http.ResponseWriter, r *http.Request, u User) {
		mu.Lock()
		delete(sessions, strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
		mu.Unlock()
		send(w, 200, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("GET /api/me", protected(false, func(w http.ResponseWriter, r *http.Request, u User) { send(w, 200, u) }))
	mux.HandleFunc("GET /api/deployments", protected(false, func(w http.ResponseWriter, r *http.Request, u User) {
		mu.Lock()
		defer mu.Unlock()
		send(w, 200, deployments)
	}))
	mux.HandleFunc("POST /api/deployments", protected(true, func(w http.ResponseWriter, r *http.Request, u User) {
		var body struct {
			Version string `json:"version"`
		}
		if !decode(w, r, &body) {
			return
		}
		if strings.TrimSpace(body.Version) == "" || len(body.Version) > 80 {
			fail(w, 400)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		d := Deployment{len(deployments) + 1, body.Version, "healthy", u.Username}
		deployments = append(deployments, d)
		if persist() != nil {
			deployments = deployments[:len(deployments)-1]
			fail(w, 500)
			return
		}
		send(w, 201, d)
	}))
	mux.HandleFunc("DELETE /api/deployments/{id}", protected(false, func(w http.ResponseWriter, r *http.Request, u User) {
		mu.Lock()
		defer mu.Unlock()
		for i, d := range deployments {
			if fmt.Sprint(d.ID) == r.PathValue("id") {
				deployments = append(deployments[:i], deployments[i+1:]...)
				if persist() != nil {
					fail(w, 500)
					return
				}
				send(w, 200, map[string]bool{"ok": true})
				return
			}
		}
		fail(w, 404)
	}))
	mux.HandleFunc("GET /api/sessions", protected(false, func(w http.ResponseWriter, r *http.Request, u User) {
		mu.Lock()
		defer mu.Unlock()
		active := []map[string]any{}
		for token, s := range sessions {
			active = append(active, map[string]any{"token": token, "user": s.User.Username, "expires": s.Expires})
		}
		send(w, 200, active)
	}))
	mux.HandleFunc("GET /debug/config", func(w http.ResponseWriter, r *http.Request) {
		send(w, 200, map[string]string{"environment": "demo", "admin_username": "admin", "admin_password": adminPassword})
	})
	// Serve only the three public assets; never expose a source or data directory.
	for _, asset := range []string{"index.html", "app.js", "style.css"} {
		asset := asset
		path := "/" + asset
		if asset == "index.html" {
			path = "/{$}"
		}
		mux.HandleFunc("GET "+path, func(w http.ResponseWriter, r *http.Request) { http.ServeFile(w, r, filepath.Join("public", asset)) })
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self'; frame-ancestors 'none'")
		mux.ServeHTTP(w, r)
	})
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	server := &http.Server{Addr: fmt.Sprintf("%s:%s", os.Getenv("HOST"), port), Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}
	log.Fatal(server.ListenAndServe())
}
