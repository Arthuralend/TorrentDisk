package main

import (
	"archive/zip"
	"context"
	"errors"
	"io"
	"io/fs"
	"mime"
	"os"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/anacrolix/torrent"
	"golang.org/x/net/webdav"
)

// FS — файловая система WebDAV только для чтения: в корне папки торрентов,
// внутри — файлы раздачи, ZIP-архивы показываются как папки.
type FS struct {
	reg     *Registry
	started time.Time
}

func NewFS(reg *Registry) *FS { return &FS{reg: reg, started: time.Now()} }

// target — то, на что указывает путь.
type target struct {
	name    string
	root    bool
	dir     *dirNode
	file    *torrent.File
	archive *Archive
	inZip   []string // путь внутри архива
}

func (fsys *FS) resolve(name string) (*target, error) {
	clean := strings.Trim(path.Clean("/"+name), "/")
	if clean == "" {
		return &target{name: "/", root: true}, nil
	}
	parts := strings.Split(clean, "/")
	tor := fsys.reg.ByDir(parts[0])
	if tor == nil {
		return nil, os.ErrNotExist
	}
	cur := tor.root
	for i, p := range parts[1:] {
		n := cur.children[p]
		switch {
		case n == nil:
			return nil, os.ErrNotExist
		case n.dir != nil:
			cur = n.dir
		case n.archive != nil:
			return &target{name: parts[len(parts)-1], archive: n.archive, inZip: parts[i+2:]}, nil
		default:
			if i != len(parts)-2 {
				return nil, os.ErrNotExist
			}
			return &target{name: p, file: n.file}, nil
		}
	}
	return &target{name: parts[len(parts)-1], dir: cur}, nil
}

// zipLookup находит узел внутри архива (nil-узел означает корень архива).
func zipLookup(a *Archive, parts []string) (*zipDir, *zip.File, error) {
	root, err := a.load()
	if err != nil {
		return nil, nil, err
	}
	cur := root
	for i, p := range parts {
		n := cur.children[p]
		switch {
		case n == nil:
			return nil, nil, os.ErrNotExist
		case n.dir != nil:
			cur = n.dir
		default:
			if i != len(parts)-1 {
				return nil, nil, os.ErrNotExist
			}
			return nil, n.file, nil
		}
	}
	return cur, nil, nil
}

func (fsys *FS) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	t, err := fsys.resolve(name)
	if err != nil {
		return nil, err
	}
	switch {
	case t.root, t.dir != nil:
		return dirInfo(t.name, fsys.started), nil
	case t.file != nil:
		return fileInfo(t.name, t.file.Length(), fsys.started), nil
	case len(t.inZip) == 0:
		// Сам архив — папка; оглавление пока не читаем.
		return dirInfo(t.name, fsys.started), nil
	}
	d, zf, err := zipLookup(t.archive, t.inZip)
	if err != nil {
		return nil, err
	}
	if d != nil {
		return dirInfo(t.name, fsys.started), nil
	}
	return fileInfo(t.name, int64(zf.UncompressedSize64), zf.Modified), nil
}

func (fsys *FS) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	if flag&(os.O_WRONLY|os.O_RDWR|os.O_CREATE|os.O_TRUNC|os.O_APPEND) != 0 {
		return nil, errPermission
	}
	t, err := fsys.resolve(name)
	if err != nil {
		return nil, err
	}
	switch {
	case t.root:
		return &dirHandle{info: dirInfo("/", fsys.started), list: fsys.listRoot}, nil
	case t.dir != nil:
		d := t.dir
		return &dirHandle{info: dirInfo(t.name, fsys.started), list: func() ([]os.FileInfo, error) {
			return fsys.listDir(d), nil
		}}, nil
	case t.file != nil:
		return &torrentFileHandle{ctx: ctx, f: t.file, info: fileInfo(t.name, t.file.Length(), fsys.started)}, nil
	}
	if len(t.inZip) == 0 {
		// Сам архив. webdav открывает каждый элемент папки при просмотре, поэтому
		// оглавление читаем только когда содержимое архива действительно запросят.
		a := t.archive
		return &dirHandle{info: dirInfo(t.name, fsys.started), list: func() ([]os.FileInfo, error) {
			d, _, err := zipLookup(a, nil)
			if err != nil {
				return nil, err
			}
			return fsys.listZipDir(d), nil
		}}, nil
	}
	d, zf, err := zipLookup(t.archive, t.inZip)
	if err != nil {
		return nil, err
	}
	if d != nil {
		return &dirHandle{info: dirInfo(t.name, fsys.started), list: func() ([]os.FileInfo, error) {
			return fsys.listZipDir(d), nil
		}}, nil
	}
	return &zipFileHandle{zf: zf, info: fileInfo(t.name, int64(zf.UncompressedSize64), zf.Modified)}, nil
}

func (fsys *FS) listRoot() ([]os.FileInfo, error) {
	var out []os.FileInfo
	for _, t := range fsys.reg.All() {
		out = append(out, dirInfo(t.Dir, fsys.started))
	}
	return out, nil
}

func (fsys *FS) listDir(d *dirNode) []os.FileInfo {
	out := make([]os.FileInfo, 0, len(d.children))
	for name, n := range d.children {
		if n.file != nil {
			out = append(out, fileInfo(name, n.file.Length(), fsys.started))
		} else {
			out = append(out, dirInfo(name, fsys.started))
		}
	}
	sortInfos(out)
	return out
}

func (fsys *FS) listZipDir(d *zipDir) []os.FileInfo {
	out := make([]os.FileInfo, 0, len(d.children))
	for name, n := range d.children {
		if n.file != nil {
			out = append(out, fileInfo(name, int64(n.file.UncompressedSize64), n.file.Modified))
		} else {
			out = append(out, dirInfo(name, fsys.started))
		}
	}
	sortInfos(out)
	return out
}

func sortInfos(infos []os.FileInfo) {
	sort.Slice(infos, func(i, j int) bool { return infos[i].Name() < infos[j].Name() })
}

func (fsys *FS) Mkdir(ctx context.Context, name string, perm os.FileMode) error { return errPermission }
func (fsys *FS) RemoveAll(ctx context.Context, name string) error               { return errPermission }
func (fsys *FS) Rename(ctx context.Context, oldName, newName string) error      { return errPermission }

// --- FileInfo ---

type info struct {
	name    string
	size    int64
	dir     bool
	modTime time.Time
}

func dirInfo(name string, mod time.Time) *info { return &info{name: name, dir: true, modTime: mod} }
func fileInfo(name string, size int64, mod time.Time) *info {
	return &info{name: name, size: size, modTime: mod}
}

func (i *info) Name() string       { return i.name }
func (i *info) Size() int64        { return i.size }
func (i *info) ModTime() time.Time { return i.modTime }
func (i *info) IsDir() bool        { return i.dir }
func (i *info) Sys() any           { return nil }
func (i *info) Mode() fs.FileMode {
	if i.dir {
		return fs.ModeDir | 0o555
	}
	return 0o444
}

// ContentType отдаёт тип по расширению. Без него webdav открывал бы каждый файл
// при просмотре папки, чтобы угадать тип, — и скачивал бы его начало.
func (i *info) ContentType(ctx context.Context) (string, error) {
	if i.dir {
		return "httpd/unix-directory", nil
	}
	if t := mime.TypeByExtension(path.Ext(i.name)); t != "" {
		return t, nil
	}
	return "application/octet-stream", nil
}

// --- Открытые файлы и папки ---

type dirHandle struct {
	info    *info
	list    func() ([]os.FileInfo, error)
	entries []os.FileInfo
	loaded  bool
	pos     int
}

func (d *dirHandle) Readdir(count int) ([]fs.FileInfo, error) {
	if !d.loaded {
		entries, err := d.list()
		if err != nil {
			return nil, err
		}
		d.entries, d.loaded = entries, true
	}
	rest := d.entries[d.pos:]
	if count <= 0 {
		d.pos = len(d.entries)
		return rest, nil
	}
	if len(rest) == 0 {
		return nil, io.EOF
	}
	if count > len(rest) {
		count = len(rest)
	}
	d.pos += count
	return rest[:count], nil
}

func (d *dirHandle) Stat() (fs.FileInfo, error)     { return d.info, nil }
func (d *dirHandle) Read([]byte) (int, error)       { return 0, errors.New("это папка") }
func (d *dirHandle) Seek(int64, int) (int64, error) { return 0, nil }
func (d *dirHandle) Write([]byte) (int, error)      { return 0, errPermission }
func (d *dirHandle) Close() error                   { return nil }

// torrentFileHandle читает файл раздачи; куски скачиваются по мере чтения.
type torrentFileHandle struct {
	ctx  context.Context
	f    *torrent.File
	info *info
	r    torrent.Reader
	pos  int64
}

func (h *torrentFileHandle) reader() (torrent.Reader, error) {
	if h.r == nil {
		h.r = h.f.NewReader()
		h.r.SetResponsive()
		h.r.SetReadahead(4 << 20)
	}
	return h.r, nil
}

func (h *torrentFileHandle) Read(p []byte) (int, error) {
	r, err := h.reader()
	if err != nil {
		return 0, err
	}
	ctx, cancel := context.WithTimeout(h.ctx, readTimeout)
	defer cancel()
	n, err := readRetry(ctx, r, h.pos, p, h.f.Length())
	h.pos += int64(n)
	return n, err
}

func (h *torrentFileHandle) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekStart:
		h.pos = offset
	case io.SeekCurrent:
		h.pos += offset
	case io.SeekEnd:
		h.pos = h.f.Length() + offset
	}
	if h.r != nil {
		return h.r.Seek(h.pos, io.SeekStart)
	}
	return h.pos, nil
}

func (h *torrentFileHandle) Close() error {
	if h.r != nil {
		return h.r.Close()
	}
	return nil
}

func (h *torrentFileHandle) Stat() (fs.FileInfo, error) { return h.info, nil }
func (h *torrentFileHandle) Readdir(int) ([]fs.FileInfo, error) {
	return nil, errors.New("это файл")
}
func (h *torrentFileHandle) Write([]byte) (int, error) { return 0, errPermission }

// zipFileHandle — файл внутри архива. Распаковывается целиком при первом чтении
// (книги небольшие), поэтому поддерживает Seek.
type zipFileHandle struct {
	zf   *zip.File
	info *info
	data []byte
	pos  int64
}

const maxZipEntry = 1 << 30

func (h *zipFileHandle) load() error {
	if h.data != nil {
		return nil
	}
	if h.zf.UncompressedSize64 > maxZipEntry {
		return errors.New("файл в архиве слишком большой")
	}
	rc, err := h.zf.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	data, err := io.ReadAll(rc)
	if err != nil {
		return err
	}
	h.data = data
	return nil
}

func (h *zipFileHandle) Read(p []byte) (int, error) {
	if err := h.load(); err != nil {
		return 0, err
	}
	if h.pos >= int64(len(h.data)) {
		return 0, io.EOF
	}
	n := copy(p, h.data[h.pos:])
	h.pos += int64(n)
	return n, nil
}

func (h *zipFileHandle) Seek(offset int64, whence int) (int64, error) {
	size := int64(h.zf.UncompressedSize64)
	switch whence {
	case io.SeekStart:
		h.pos = offset
	case io.SeekCurrent:
		h.pos += offset
	case io.SeekEnd:
		h.pos = size + offset
	}
	if h.pos < 0 {
		h.pos = 0
		return 0, errors.New("отрицательная позиция")
	}
	return h.pos, nil
}

func (h *zipFileHandle) Close() error               { return nil }
func (h *zipFileHandle) Stat() (fs.FileInfo, error) { return h.info, nil }
func (h *zipFileHandle) Readdir(int) ([]fs.FileInfo, error) {
	return nil, errors.New("это файл")
}
func (h *zipFileHandle) Write([]byte) (int, error) { return 0, errPermission }
