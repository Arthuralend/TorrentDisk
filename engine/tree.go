package main

import (
	"archive/zip"
	"context"
	"errors"
	"io"
	"os"
	"path"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/anacrolix/torrent"
	"golang.org/x/text/encoding/charmap"
)

// readTimeout — сколько ждать нужные куски от пиров, прежде чем вернуть ошибку.
const readTimeout = 3 * time.Minute

type dirNode struct {
	children map[string]*node
}

type node struct {
	dir     *dirNode
	file    *torrent.File
	archive *Archive
}

func newDir() *dirNode { return &dirNode{children: map[string]*node{}} }

// buildTree строит дерево папок торрента по его метаданным — без скачивания данных.
// ZIP-архивы становятся узлами-архивами, их содержимое читается лениво.
func buildTree(t *torrent.Torrent) *dirNode {
	root := newDir()
	for _, f := range t.Files() {
		parts := strings.Split(f.DisplayPath(), "/")
		cur := root
		for i, p := range parts {
			p = sanitize(p)
			if i == len(parts)-1 {
				if strings.EqualFold(path.Ext(p), ".zip") {
					cur.children[p] = &node{archive: &Archive{f: f}}
				} else {
					cur.children[p] = &node{file: f}
				}
				break
			}
			n := cur.children[p]
			if n == nil || n.dir == nil {
				n = &node{dir: newDir()}
				cur.children[p] = n
			}
			cur = n.dir
		}
	}
	return root
}

// Archive — ZIP-файл внутри торрента. Оглавление читается при первом обращении:
// для этого скачиваются только куски с концом архива.
type Archive struct {
	f *torrent.File

	mu   sync.Mutex
	root *zipDir
	ra   *torrentReaderAt
}

type zipDir struct {
	children map[string]*zipNode
}

type zipNode struct {
	dir  *zipDir
	file *zip.File
}

func (a *Archive) load() (*zipDir, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.root != nil {
		return a.root, nil
	}
	if a.ra == nil {
		r := a.f.NewReader()
		r.SetResponsive()
		r.SetReadahead(64 << 10)
		a.ra = &torrentReaderAt{r: r}
	}
	zr, err := zip.NewReader(a.ra, a.f.Length())
	if err != nil {
		// Не кешируем ошибку: возможно, пиры просто ещё не найдены.
		return nil, err
	}
	root := &zipDir{children: map[string]*zipNode{}}
	for _, zf := range zr.File {
		name := zf.Name
		if zf.NonUTF8 || !utf8.ValidString(name) {
			// Русские ZIP-архивы из Windows обычно хранят имена в CP866.
			if decoded, err := charmap.CodePage866.NewDecoder().String(name); err == nil {
				name = decoded
			}
		}
		parts := strings.Split(strings.Trim(name, "/"), "/")
		cur := root
		for i, p := range parts {
			p = sanitize(p)
			if p == "" {
				continue
			}
			last := i == len(parts)-1
			if last && !strings.HasSuffix(zf.Name, "/") {
				cur.children[p] = &zipNode{file: zf}
				break
			}
			n := cur.children[p]
			if n == nil || n.dir == nil {
				n = &zipNode{dir: &zipDir{children: map[string]*zipNode{}}}
				cur.children[p] = n
			}
			cur = n.dir
		}
	}
	a.root = root
	return root, nil
}

// torrentReaderAt даёт произвольный доступ к файлу торрента — нужен для archive/zip.
type torrentReaderAt struct {
	mu sync.Mutex
	r  torrent.Reader
}

func (t *torrentReaderAt) ReadAt(p []byte, off int64) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), readTimeout)
	defer cancel()
	t.r.SetContext(ctx)
	if _, err := t.r.Seek(off, io.SeekStart); err != nil {
		return 0, err
	}
	n, err := io.ReadFull(t.r, p)
	if errors.Is(err, io.ErrUnexpectedEOF) {
		err = io.EOF
	}
	if errors.Is(err, context.DeadlineExceeded) {
		err = errNoPeers
	}
	return n, err
}

var errNoPeers = errors.New("нужные куски не скачались: нет раздающих или они слишком медленные")

// errPermission — WebDAV-диск только для чтения.
var errPermission = os.ErrPermission
