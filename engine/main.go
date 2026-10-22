// torrentdisk-engine — торрент-клиент для Torrent Disk. Отдаёт раздачи по WebDAV
// (ZIP-архивы — как папки) и принимает команды приложения по HTTP API.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
	"golang.org/x/net/webdav"
)

type peerList []torrent.PeerInfo

func (p *peerList) String() string { return fmt.Sprint(len(*p)) }
func (p *peerList) Set(s string) error {
	addr, err := net.ResolveTCPAddr("tcp", s)
	if err != nil {
		return err
	}
	*p = append(*p, torrent.PeerInfo{Addr: addr, Trusted: true})
	return nil
}

type Engine struct {
	cl    *torrent.Client
	reg   *Registry
	cache *pieceCache
	stop  chan struct{}
}

// NewEngine запускает торрент-клиент. Скачанные куски хранятся в кеше ограниченного
// размера: когда он заполнен, давно не читавшиеся куски удаляются (и при необходимости
// скачиваются снова). cacheBytes < 0 — без ограничения.
func NewEngine(dataDir string, peers []torrent.PeerInfo, disableDHT bool, cacheBytes int64) (*Engine, error) {
	// Кеш версии 3.0.0 (файлы целиком, без ограничения размера) больше не нужен.
	os.RemoveAll(filepath.Join(dataDir, "cache"))

	cache, err := newPieceCache(filepath.Join(dataDir, "pieces"), cacheBytes)
	if err != nil {
		return nil, err
	}

	cfg := torrent.NewDefaultClientConfig()
	cfg.DataDir = filepath.Join(dataDir, "pieces")
	cfg.DefaultStorage = storage.NewResourcePieces(cache.fc.AsResourceProvider())
	cfg.ListenPort = 0
	cfg.Seed = true
	cfg.NoDHT = disableDHT
	cl, err := torrent.NewClient(cfg)
	if err != nil && !cfg.DisableIPv6 {
		// Без IPv6 в системе клиент не может открыть порт — пробуем только IPv4.
		cfg.DisableIPv6 = true
		cl, err = torrent.NewClient(cfg)
	}
	if err != nil {
		return nil, err
	}
	e := &Engine{cl: cl, reg: NewRegistry(cl, peers, cache), cache: cache, stop: make(chan struct{})}
	go cache.run(e.stop)
	return e, nil
}

func (e *Engine) Close() {
	close(e.stop)
	e.cl.Close()
}

// Куски из кеша вытесняются по мере заполнения, поэтому при удалении торрента
// его данные отдельно не чистим.
func (e *Engine) Remove(ih metainfo.Hash) bool { return e.reg.Remove(ih) }

type CacheStatus struct {
	Used     int64 `json:"used"`
	Capacity int64 `json:"capacity"`
}

func (e *Engine) CacheStatus() CacheStatus { return e.cache.status() }

// ClearCache удаляет все скачанные куски. Торренты остаются: при следующем чтении
// нужные куски скачаются заново.
func (e *Engine) ClearCache() { e.cache.clear() }

func (e *Engine) SetCacheCapacity(bytes int64) { e.cache.setCapacity(bytes) }

func (e *Engine) apiHandler() http.Handler {
	mux := http.NewServeMux()
	writeJSON := func(w http.ResponseWriter, v any) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(v)
	}
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /api/torrents", func(w http.ResponseWriter, r *http.Request) {
		out := []TorrentStatus{}
		for _, t := range e.reg.All() {
			out = append(out, t.Status())
		}
		writeJSON(w, out)
	})
	mux.HandleFunc("POST /api/torrents", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Path string `json:"path"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Path == "" {
			http.Error(w, "нужен path", http.StatusBadRequest)
			return
		}
		t, err := e.reg.AddFile(req.Path)
		if err != nil {
			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			return
		}
		writeJSON(w, t.Status())
	})
	mux.HandleFunc("GET /api/cache", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, e.CacheStatus())
	})
	mux.HandleFunc("POST /api/cache/clear", func(w http.ResponseWriter, r *http.Request) {
		e.ClearCache()
		writeJSON(w, e.CacheStatus())
	})
	mux.HandleFunc("POST /api/cache/capacity", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Capacity int64 `json:"capacity"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Capacity == 0 {
			http.Error(w, "нужен capacity", http.StatusBadRequest)
			return
		}
		e.SetCacheCapacity(req.Capacity)
		writeJSON(w, e.CacheStatus())
	})
	mux.HandleFunc("DELETE /api/torrents/{hash}", func(w http.ResponseWriter, r *http.Request) {
		var ih metainfo.Hash
		if err := ih.FromHexString(r.PathValue("hash")); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if !e.Remove(ih) {
			http.NotFound(w, r)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	return mux
}

func (e *Engine) webdavHandler(user, pass string) http.Handler {
	h := &webdav.Handler{
		FileSystem: NewFS(e.reg),
		LockSystem: webdav.NewMemLS(),
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || subtle.ConstantTimeCompare([]byte(u), []byte(user)) != 1 ||
			subtle.ConstantTimeCompare([]byte(p), []byte(pass)) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="Torrent Disk"`)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		h.ServeHTTP(w, r)
	})
}

// loadLibrary добавляет все .torrent из папки библиотеки.
func (e *Engine) loadLibrary(dir string) {
	files, _ := filepath.Glob(filepath.Join(dir, "*.torrent"))
	for _, f := range files {
		if _, err := e.reg.AddFile(f); err != nil {
			log.Printf("skip %s: %v", f, err)
		}
	}
}

func main() {
	dataDir := flag.String("data", ".", "папка данных (library/ и cache/)")
	davAddr := flag.String("webdav", "127.0.0.1:36911", "адрес WebDAV")
	apiAddr := flag.String("api", "127.0.0.1:36912", "адрес HTTP API")
	user := flag.String("user", "admin", "логин WebDAV")
	noDHT := flag.Bool("no-dht", false, "отключить DHT")
	cacheMB := flag.Int64("cache-mb", 2048, "размер кеша скачанных кусков, МБ (-1 — без ограничения)")
	var peers peerList
	flag.Var(&peers, "peer", "дополнительный пир host:port (для проверки)")
	flag.Parse()

	pass := os.Getenv("TD_PASS")
	if pass == "" {
		log.Fatal("TD_PASS не задан")
	}

	cacheBytes := *cacheMB
	if cacheBytes > 0 {
		cacheBytes <<= 20
	}
	e, err := NewEngine(*dataDir, peers, *noDHT, cacheBytes)
	if err != nil {
		log.Fatal(err)
	}
	e.loadLibrary(filepath.Join(*dataDir, "library"))

	go func() { log.Fatal(http.ListenAndServe(*apiAddr, e.apiHandler())) }()
	go func() { log.Fatal(http.ListenAndServe(*davAddr, e.webdavHandler(*user, pass))) }()
	log.Printf("ready: webdav %s, api %s", *davAddr, *apiAddr)

	// Завершаемся по сигналу или если приложение, запустившее движок, пропало.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	parent := os.Getppid()
	ticker := time.NewTicker(2 * time.Second)
	for {
		select {
		case <-stop:
			e.Close()
			return
		case <-ticker.C:
			if os.Getppid() != parent {
				e.Close()
				return
			}
		}
	}
}
