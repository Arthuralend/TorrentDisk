package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
	"golang.org/x/text/encoding/charmap"
)

const pieceLen = 16 << 10

// makeLibrary создаёт раздачу «Библиотека»: большой ZIP с книгами и ещё один файл.
func makeLibrary(t *testing.T, dir string) (book []byte) {
	t.Helper()
	root := filepath.Join(dir, "Библиотека")
	os.MkdirAll(root, 0o755)

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	book = []byte(strings.Repeat("<p>Глава первая. Жили-были…</p>\n", 200))
	// Несжимаемый «балласт», чтобы архив занимал много кусков.
	addFiller := func(from, to int) {
		for i := from; i < to; i++ {
			w, _ := zw.CreateHeader(&zip.FileHeader{Name: fmt.Sprintf("filler/%02d.bin", i), Method: zip.Store})
			filler := make([]byte, 50<<10)
			rand.Read(filler)
			w.Write(filler)
		}
	}
	// Книга — в середине архива, далеко и от начала, и от оглавления в конце.
	addFiller(0, 20)
	w, _ := zw.Create("12345.fb2")
	w.Write(book)
	addFiller(20, 40)
	// Имя в CP866, как у архивов из Windows (без флага UTF-8).
	cp866, _ := charmap.CodePage866.NewEncoder().String("Война и мир.txt")
	w, _ = zw.CreateHeader(&zip.FileHeader{Name: cp866, Method: zip.Deflate, NonUTF8: true})
	w.Write([]byte("том 1"))
	zw.Close()
	os.WriteFile(filepath.Join(root, "fb2-000001-100000.zip"), buf.Bytes(), 0o644)

	other := make([]byte, 1<<20)
	rand.Read(other)
	os.WriteFile(filepath.Join(root, "other.bin"), other, 0o644)
	return book
}

func makeTorrent(t *testing.T, contentDir, out string) *metainfo.MetaInfo {
	t.Helper()
	info := metainfo.Info{PieceLength: pieceLen}
	if err := info.BuildFromFilePath(contentDir); err != nil {
		t.Fatal(err)
	}
	mi := &metainfo.MetaInfo{}
	var err error
	mi.InfoBytes, err = bencode.Marshal(info)
	if err != nil {
		t.Fatal(err)
	}
	f, _ := os.Create(out)
	defer f.Close()
	if err := mi.Write(f); err != nil {
		t.Fatal(err)
	}
	return mi
}

func startSeeder(t *testing.T, dataDir string, mi *metainfo.MetaInfo) *torrent.Client {
	t.Helper()
	cfg := torrent.NewDefaultClientConfig()
	cfg.DataDir = dataDir
	cfg.DefaultStorage = storage.NewFile(dataDir)
	cfg.Seed = true
	cfg.NoDHT = true
	cfg.ListenPort = 0
	cfg.DisableIPv6 = os.Getenv("TD_NO_IPV6") != ""
	cl, err := torrent.NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	tor, err := cl.AddTorrent(mi)
	if err != nil {
		t.Fatal(err)
	}
	<-tor.GotInfo()
	if err := tor.VerifyData(); err != nil {
		t.Fatal(err)
	}
	if !tor.Seeding() {
		t.Fatal("seeder is not seeding")
	}
	return cl
}

func propfind(t *testing.T, srv *httptest.Server, p string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest("PROPFIND", srv.URL+p, nil)
	req.Header.Set("Depth", "1")
	req.SetBasicAuth("admin", "secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(body)
}

func TestEndToEnd(t *testing.T) {
	tmp := t.TempDir()
	seedDir := filepath.Join(tmp, "seed")
	book := makeLibrary(t, seedDir)
	torrentFile := filepath.Join(tmp, "lib.torrent")
	mi := makeTorrent(t, filepath.Join(seedDir, "Библиотека"), torrentFile)

	seeder := startSeeder(t, seedDir, mi)
	defer seeder.Close()
	peer := torrent.PeerInfo{Addr: &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: seeder.LocalPort()}, Trusted: true}

	e, err := NewEngine(filepath.Join(tmp, "engine"), []torrent.PeerInfo{peer}, true, -1)
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()

	api := httptest.NewServer(e.apiHandler())
	defer api.Close()
	resp, err := http.Post(api.URL+"/api/torrents", "application/json",
		strings.NewReader(`{"path":"`+torrentFile+`"}`))
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("add: %v %v", err, resp.Status)
	}
	resp.Body.Close()

	dav := httptest.NewServer(e.webdavHandler("admin", "secret"))
	defer dav.Close()
	tor := e.reg.ByDir("Библиотека")
	if tor == nil {
		t.Fatal("torrent dir not found")
	}
	total := tor.t.Info().TotalLength()

	// Просмотр папок не должен ничего скачивать.
	code, body := propfind(t, dav, "/")
	if code != 207 || !strings.Contains(body, "%D0%91%D0%B8%D0%B1") && !strings.Contains(body, "Библиотека") {
		t.Fatalf("root: %d %s", code, body)
	}
	code, body = propfind(t, dav, "/Библиотека/")
	if code != 207 || !strings.Contains(body, "fb2-000001-100000.zip") || !strings.Contains(body, "other.bin") {
		t.Fatalf("torrent dir: %d %s", code, body)
	}
	if done := tor.t.BytesCompleted(); done != 0 {
		t.Fatalf("listing downloaded %d bytes", done)
	}

	// Оглавление архива: скачивается только его конец.
	code, body = propfind(t, dav, "/Библиотека/fb2-000001-100000.zip/")
	if code != 207 || !strings.Contains(body, "12345.fb2") {
		t.Fatalf("zip dir: %d %s", code, body)
	}
	if !strings.Contains(body, "Война") && !strings.Contains(body, "%D0%92%D0%BE%D0%B9%D0%BD%D0%B0") {
		t.Fatalf("cp866 name not decoded: %s", body)
	}
	afterList := tor.t.BytesCompleted()
	t.Logf("after reading zip directory: %d of %d bytes", afterList, total)

	// Сама книга.
	req, _ := http.NewRequest("GET", dav.URL+"/Библиотека/fb2-000001-100000.zip/12345.fb2", nil)
	req.SetBasicAuth("admin", "secret")
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	resp, err = http.DefaultClient.Do(req.WithContext(ctx))
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !bytes.Equal(got, book) {
		t.Fatalf("book: %d, %d bytes", resp.StatusCode, len(got))
	}
	done := tor.t.BytesCompleted()
	t.Logf("after reading the book: %d of %d bytes (%.1f%%)", done, total, 100*float64(done)/float64(total))
	if done > 8*pieceLen {
		t.Fatalf("downloaded too much: %d of %d", done, total)
	}

	// После очистки кеша книга скачивается заново.
	e.ClearCache()
	// Недокачанные фрагменты и упреждающее чтение могут оставить кусок-другой.
	if used := e.CacheStatus().Used; used > 3*pieceLen {
		t.Fatalf("cache not cleared: %d", used)
	}
	if again := getBook(t, dav, "/Библиотека/fb2-000001-100000.zip/12345.fb2"); !bytes.Equal(again, book) {
		t.Fatalf("book after clear: %d bytes", len(again))
	}

	// Запись запрещена.
	req, _ = http.NewRequest("PUT", dav.URL+"/Библиотека/new.txt", strings.NewReader("x"))
	req.SetBasicAuth("admin", "secret")
	resp, _ = http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode < 400 {
		t.Fatalf("PUT allowed: %d", resp.StatusCode)
	}

	// Без пароля — 401.
	resp, _ = http.Get(dav.URL + "/")
	resp.Body.Close()
	if resp.StatusCode != 401 {
		t.Fatalf("no auth: %d", resp.StatusCode)
	}

	// Удаление через API.
	req, _ = http.NewRequest("DELETE", api.URL+"/api/torrents/"+tor.t.InfoHash().HexString(), nil)
	resp, _ = http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != 204 || e.reg.ByDir("Библиотека") != nil {
		t.Fatalf("delete: %d", resp.StatusCode)
	}
}

func TestSingleFileTorrentDir(t *testing.T) {
	tmp := t.TempDir()
	os.WriteFile(filepath.Join(tmp, "books.zip"), []byte("not really a zip"), 0o644)
	torrentFile := filepath.Join(tmp, "one.torrent")
	makeTorrent(t, filepath.Join(tmp, "books.zip"), torrentFile)

	e, err := NewEngine(filepath.Join(tmp, "engine"), nil, true, -1)
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	tor, err := e.reg.AddFile(torrentFile)
	if err != nil {
		t.Fatal(err)
	}
	if tor.Dir != "books" {
		t.Fatalf("dir = %q", tor.Dir)
	}
	dav := httptest.NewServer(e.webdavHandler("admin", "secret"))
	defer dav.Close()
	code, body := propfind(t, dav, "/books/")
	if code != 207 || !strings.Contains(body, "books.zip") {
		t.Fatalf("%d %s", code, body)
	}
}

func TestToUTF8(t *testing.T) {
	cp1251, _ := charmap.Windows1251.NewEncoder().String("Библиотека")
	if got := sanitize(cp1251); got != "Библиотека" {
		t.Fatalf("got %q", got)
	}
	if got := sanitize("a/b"); got != "a_b" {
		t.Fatalf("got %q", got)
	}
}

func getBook(t *testing.T, dav *httptest.Server, p string) []byte {
	t.Helper()
	req, _ := http.NewRequest("GET", dav.URL+p, nil)
	req.SetBasicAuth("admin", "secret")
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	resp, err := http.DefaultClient.Do(req.WithContext(ctx))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		t.Fatalf("GET %s: %d", p, resp.StatusCode)
	}
	return body
}

// Кеш не растёт больше заданного размера: старые куски вытесняются.
func TestCacheLimit(t *testing.T) {
	tmp := t.TempDir()
	seedDir := filepath.Join(tmp, "seed")
	makeLibrary(t, seedDir)
	torrentFile := filepath.Join(tmp, "lib.torrent")
	mi := makeTorrent(t, filepath.Join(seedDir, "Библиотека"), torrentFile)
	seeder := startSeeder(t, seedDir, mi)
	defer seeder.Close()
	peer := torrent.PeerInfo{Addr: &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: seeder.LocalPort()}, Trusted: true}

	const limit = 256 << 10
	e, err := NewEngine(filepath.Join(tmp, "engine"), []torrent.PeerInfo{peer}, true, limit)
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	if _, err := e.reg.AddFile(torrentFile); err != nil {
		t.Fatal(err)
	}
	dav := httptest.NewServer(e.webdavHandler("admin", "secret"))
	defer dav.Close()

	other, _ := os.ReadFile(filepath.Join(seedDir, "Библиотека", "other.bin"))
	if got := getBook(t, dav, "/Библиотека/other.bin"); !bytes.Equal(got, other) {
		t.Fatalf("other.bin: %d bytes", len(got))
	}
	// Лишнее удаляется в фоне раз в секунду.
	deadline := time.Now().Add(10 * time.Second)
	for e.CacheStatus().Used > limit && time.Now().Before(deadline) {
		time.Sleep(200 * time.Millisecond)
	}
	st := e.CacheStatus()
	t.Logf("cache after reading 1 MiB with %d KiB limit: %d bytes", limit>>10, st.Used)
	if st.Used > limit {
		t.Fatalf("cache %d exceeds limit %d", st.Used, limit)
	}

	// Вытесненные куски скачиваются заново.
	if got := getBook(t, dav, "/Библиотека/other.bin"); !bytes.Equal(got, other) {
		t.Fatalf("other.bin after eviction: %d bytes", len(got))
	}
}
