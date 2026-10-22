package main

import (
	"encoding/hex"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/anacrolix/missinggo/v2/filecache"
	"github.com/anacrolix/torrent"
)

// pieceCache следит за размером кеша скачанных кусков. Встроенное вытеснение filecache
// не годится: оно удаляет куски молча, и клиент продолжает считать их скачанными.
// Здесь после удаления куска клиенту сообщается, что его нужно скачать заново.
type pieceCache struct {
	fc *filecache.Cache

	mu       sync.Mutex
	capacity int64 // < 0 — без ограничения
	pieces   map[string][]pieceRef
}

type pieceRef struct {
	t     *torrent.Torrent
	index int
}

const completedPrefix = "completed/"

func newPieceCache(dir string, capacity int64) (*pieceCache, error) {
	fc, err := filecache.NewCache(dir)
	if err != nil {
		return nil, err
	}
	fc.SetCapacity(-1)
	return &pieceCache{fc: fc, capacity: capacity, pieces: map[string][]pieceRef{}}, nil
}

// track запоминает, каким кускам каких торрентов соответствуют хеши в кеше.
func (c *pieceCache) track(t *torrent.Torrent) {
	c.mu.Lock()
	defer c.mu.Unlock()
	info := t.Info()
	for i := 0; i < info.NumPieces(); i++ {
		h := info.Piece(i).V1Hash()
		if !h.Ok {
			continue
		}
		key := hex.EncodeToString(h.Value[:])
		c.pieces[key] = append(c.pieces[key], pieceRef{t, i})
	}
}

func (c *pieceCache) untrack(t *torrent.Torrent) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for key, refs := range c.pieces {
		kept := refs[:0]
		for _, r := range refs {
			if r.t != t {
				kept = append(kept, r)
			}
		}
		if len(kept) == 0 {
			delete(c.pieces, key)
		} else {
			c.pieces[key] = kept
		}
	}
}

func (c *pieceCache) status() CacheStatus {
	c.mu.Lock()
	capacity := c.capacity
	c.mu.Unlock()
	return CacheStatus{Used: c.fc.Info().Filled, Capacity: capacity}
}

func (c *pieceCache) setCapacity(capacity int64) {
	c.mu.Lock()
	c.capacity = capacity
	c.mu.Unlock()
	c.trim()
}

// trim удаляет давно не читавшиеся куски, пока кеш не станет на 10% меньше лимита.
func (c *pieceCache) trim() {
	c.mu.Lock()
	capacity := c.capacity
	c.mu.Unlock()
	if capacity < 0 || c.fc.Info().Filled <= capacity {
		return
	}
	c.evict(func(items []filecache.ItemInfo, filled int64) int {
		target := capacity - capacity/10
		n := 0
		for n < len(items) && filled > target {
			filled -= items[n].Size
			n++
		}
		return n
	})
}

// clear удаляет все скачанные куски.
func (c *pieceCache) clear() {
	c.evict(func(items []filecache.ItemInfo, _ int64) int { return len(items) })
}

// evict удаляет первые pick(...) скачанных кусков (от давно не читавшихся к недавним).
// Недокачанные куски не трогаем: их сейчас скачивают, и они занимают немного.
func (c *pieceCache) evict(pick func(items []filecache.ItemInfo, filled int64) int) {
	var items []filecache.ItemInfo
	c.fc.WalkItems(func(it filecache.ItemInfo) {
		if strings.HasPrefix(string(it.Path), completedPrefix) {
			items = append(items, it)
		}
	})
	sort.Slice(items, func(i, j int) bool { return items[i].Accessed.Before(items[j].Accessed) })
	n := pick(items, c.fc.Info().Filled)

	var stale []pieceRef
	for _, it := range items[:n] {
		key := strings.TrimPrefix(string(it.Path), completedPrefix)
		if c.fc.Remove(string(it.Path)) != nil {
			continue
		}
		c.mu.Lock()
		stale = append(stale, c.pieces[key]...)
		c.mu.Unlock()
	}
	for _, r := range stale {
		r.t.Piece(r.index).UpdateCompletion()
	}
}

func (c *pieceCache) run(stop <-chan struct{}) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			c.trim()
		}
	}
}
