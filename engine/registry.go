package main

import (
	"fmt"
	"path"
	"sort"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
	"golang.org/x/text/encoding/charmap"
)

// Torrent — добавленная раздача и её дерево файлов.
type Torrent struct {
	t    *torrent.Torrent
	Dir  string // имя папки торрента в корне WebDAV
	root *dirNode
}

// Registry хранит добавленные торренты.
type Registry struct {
	cl         *torrent.Client
	extraPeers []torrent.PeerInfo

	mu    sync.RWMutex
	byDir map[string]*Torrent
	byIH  map[metainfo.Hash]*Torrent
}

func NewRegistry(cl *torrent.Client, extraPeers []torrent.PeerInfo) *Registry {
	return &Registry{
		cl:         cl,
		extraPeers: extraPeers,
		byDir:      map[string]*Torrent{},
		byIH:       map[metainfo.Hash]*Torrent{},
	}
}

// AddFile добавляет .torrent-файл. Повторное добавление возвращает уже существующий торрент.
func (r *Registry) AddFile(file string) (*Torrent, error) {
	mi, err := metainfo.LoadFromFile(file)
	if err != nil {
		return nil, fmt.Errorf("не удалось прочитать %s: %w", path.Base(file), err)
	}
	ih := mi.HashInfoBytes()

	r.mu.Lock()
	defer r.mu.Unlock()
	if existing := r.byIH[ih]; existing != nil {
		return existing, nil
	}

	spec, err := torrent.TorrentSpecFromMetaInfoErr(mi)
	if err != nil {
		return nil, err
	}
	t, _, err := r.cl.AddTorrentSpec(spec)
	if err != nil {
		return nil, err
	}
	<-t.GotInfo() // информация уже есть в .torrent, ждать не придётся
	if len(r.extraPeers) > 0 {
		t.AddPeers(r.extraPeers)
	}

	tor := &Torrent{t: t, root: buildTree(t)}
	tor.Dir = r.uniqueDir(dirName(t))
	r.byDir[tor.Dir] = tor
	r.byIH[ih] = tor
	return tor, nil
}

func (r *Registry) Remove(ih metainfo.Hash) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	tor := r.byIH[ih]
	if tor == nil {
		return false
	}
	tor.t.Drop()
	delete(r.byIH, ih)
	delete(r.byDir, tor.Dir)
	return true
}

func (r *Registry) ByDir(dir string) *Torrent {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.byDir[dir]
}

func (r *Registry) All() []*Torrent {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]*Torrent, 0, len(r.byDir))
	for _, t := range r.byDir {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Dir < out[j].Dir })
	return out
}

// dirName — имя папки торрента: название раздачи; у однофайловой раздачи — без расширения,
// чтобы внутри папки лежал сам файл (архив при этом раскрывается как подпапка).
func dirName(t *torrent.Torrent) string {
	name := sanitize(t.Info().BestName())
	if !t.Info().IsDir() {
		if ext := path.Ext(name); ext != "" && len(ext) < len(name) {
			name = strings.TrimSuffix(name, ext)
		}
	}
	if name == "" {
		name = t.InfoHash().HexString()
	}
	return name
}

func (r *Registry) uniqueDir(name string) string {
	candidate := name
	for i := 2; r.byDir[candidate] != nil; i++ {
		candidate = fmt.Sprintf("%s (%d)", name, i)
	}
	return candidate
}

// sanitize делает имя пригодным для пути: валидный UTF-8, без слэшей и служебных имён.
func sanitize(name string) string {
	name = toUTF8(name)
	name = strings.NewReplacer("/", "_", "\\", "_", "\x00", "").Replace(name)
	name = strings.TrimSpace(name)
	if name == "." || name == ".." {
		return "_"
	}
	return name
}

// TorrentStatus — то, что отдаёт API приложению.
type TorrentStatus struct {
	Hash      string `json:"hash"`
	Name      string `json:"name"`
	Dir       string `json:"dir"`
	Size      int64  `json:"size"`
	Completed int64  `json:"completed"`
	Peers     int    `json:"peers"`
	Seeders   int    `json:"seeders"`
}

func (t *Torrent) Status() TorrentStatus {
	stats := t.t.Stats()
	return TorrentStatus{
		Hash:      t.t.InfoHash().HexString(),
		Name:      toUTF8(t.t.Info().BestName()),
		Dir:       t.Dir,
		Size:      t.t.Info().TotalLength(),
		Completed: t.t.BytesCompleted(),
		Peers:     stats.ActivePeers,
		Seeders:   stats.ConnectedSeeders,
	}
}

// toUTF8 переводит в UTF-8 имена из старых торрентов, созданных в Windows (CP1251).
func toUTF8(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	if decoded, err := charmap.Windows1251.NewDecoder().String(s); err == nil {
		return decoded
	}
	return strings.ToValidUTF8(s, "_")
}
