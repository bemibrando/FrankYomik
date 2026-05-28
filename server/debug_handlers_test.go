package main

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func makeDebugPNG(c color.Color) []byte {
	img := image.NewRGBA(image.Rect(0, 0, 8, 8))
	for x := range 8 {
		for y := range 8 {
			img.Set(x, y, c)
		}
	}
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

func makeDebugRequest(t *testing.T, fields map[string]string, original, translated []byte) *http.Request {
	t.Helper()
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	for key, value := range fields {
		_ = writer.WriteField(key, value)
	}
	if original != nil {
		part, _ := writer.CreateFormFile("original", "original.png")
		_, _ = part.Write(original)
	}
	if translated != nil {
		part, _ := writer.CreateFormFile("translated", "translated.png")
		_, _ = part.Write(translated)
	}
	_ = writer.Close()
	req := httptest.NewRequest("POST", "/api/v1/debug/pages", body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	return req
}

func TestDebugPagesSuccessListAndDownload(t *testing.T) {
	srv := NewServer(nil, t.TempDir())
	mux := http.NewServeMux()
	srv.RegisterRoutes(mux)

	firstReq := makeDebugRequest(t, map[string]string{
		"site":         "kindle",
		"page_id":      "page-1",
		"source_url":   "https://read.amazon.co.jp/",
		"capture_json": `{"page":1}`,
	}, makeDebugPNG(color.RGBA{R: 255, A: 255}), makeDebugPNG(color.RGBA{G: 255, A: 255}))
	firstW := httptest.NewRecorder()
	mux.ServeHTTP(firstW, firstReq)
	if firstW.Code != http.StatusCreated {
		t.Fatalf("first create got %d: %s", firstW.Code, firstW.Body.String())
	}
	var first DebugPageManifest
	if err := json.NewDecoder(firstW.Body).Decode(&first); err != nil {
		t.Fatalf("decode first: %v", err)
	}
	if first.ID == "" || first.OriginalURL == "" || first.TranslatedURL == "" || len(first.CaptureJSON) == 0 {
		t.Fatalf("manifest missing expected fields: %+v", first)
	}

	for time.Now().UnixMilli() <= first.CreatedAtUnixMs {
		time.Sleep(time.Millisecond)
	}
	secondReq := makeDebugRequest(t, map[string]string{"site": "webtoon", "page_id": "page-2"}, makeDebugPNG(color.RGBA{B: 255, A: 255}), makeDebugPNG(color.RGBA{R: 255, G: 255, A: 255}))
	secondW := httptest.NewRecorder()
	mux.ServeHTTP(secondW, secondReq)
	if secondW.Code != http.StatusCreated {
		t.Fatalf("second create got %d: %s", secondW.Code, secondW.Body.String())
	}
	var second DebugPageManifest
	_ = json.NewDecoder(secondW.Body).Decode(&second)

	listReq := httptest.NewRequest("GET", "/api/v1/debug/pages", nil)
	listW := httptest.NewRecorder()
	mux.ServeHTTP(listW, listReq)
	if listW.Code != http.StatusOK {
		t.Fatalf("list got %d: %s", listW.Code, listW.Body.String())
	}
	var list struct {
		Pages []DebugPageManifest `json:"pages"`
	}
	if err := json.NewDecoder(listW.Body).Decode(&list); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(list.Pages) != 2 || list.Pages[0].ID != second.ID || list.Pages[1].ID != first.ID {
		t.Fatalf("unexpected list order: %+v", list.Pages)
	}

	getReq := httptest.NewRequest("GET", "/api/v1/debug/pages/"+first.ID, nil)
	getW := httptest.NewRecorder()
	mux.ServeHTTP(getW, getReq)
	if getW.Code != http.StatusOK {
		t.Fatalf("get manifest got %d", getW.Code)
	}

	imgReq := httptest.NewRequest("GET", "/api/v1/debug/pages/"+first.ID+"/original", nil)
	imgW := httptest.NewRecorder()
	mux.ServeHTTP(imgW, imgReq)
	if imgW.Code != http.StatusOK {
		t.Fatalf("image got %d: %s", imgW.Code, imgW.Body.String())
	}
	if !strings.HasPrefix(imgW.Header().Get("Content-Type"), "image/png") {
		t.Fatalf("unexpected content type %q", imgW.Header().Get("Content-Type"))
	}
	if imgW.Header().Get("Content-Length") == "" {
		t.Fatal("missing content length")
	}
}

func TestDebugPagesValidation(t *testing.T) {
	srv := NewServer(nil, t.TempDir())
	mux := http.NewServeMux()
	srv.RegisterRoutes(mux)
	orig := makeDebugPNG(color.White)
	trans := makeDebugPNG(color.Black)

	tests := []struct {
		name   string
		req    *http.Request
		status int
	}{
		{"missing original", makeDebugRequest(t, map[string]string{"site": "kindle"}, nil, trans), http.StatusBadRequest},
		{"missing translated", makeDebugRequest(t, map[string]string{"site": "kindle"}, orig, nil), http.StatusBadRequest},
		{"invalid site", makeDebugRequest(t, map[string]string{"site": "evil"}, orig, trans), http.StatusBadRequest},
		{"invalid json", makeDebugRequest(t, map[string]string{"site": "kindle", "capture_json": "{"}, orig, trans), http.StatusBadRequest},
		{"non image", makeDebugRequest(t, map[string]string{"site": "kindle"}, []byte("not image"), trans), http.StatusBadRequest},
		{"bad id", httptest.NewRequest("GET", "/api/v1/debug/pages/bad-id", nil), http.StatusBadRequest},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			mux.ServeHTTP(w, tt.req)
			if w.Code != tt.status {
				t.Fatalf("got %d want %d body=%s", w.Code, tt.status, w.Body.String())
			}
		})
	}
}
