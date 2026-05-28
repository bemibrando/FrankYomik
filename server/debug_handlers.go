package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const maxDebugJSONBytes = 1 << 20

var debugIDRe = regexp.MustCompile(`^[0-9]{13}-[a-f0-9]{12}-[a-f0-9]{12}$`)

type DebugPageManifest struct {
	SchemaVersion          int             `json:"schema_version"`
	ID                     string          `json:"id"`
	Site                   string          `json:"site"`
	PageID                 string          `json:"page_id"`
	SourceURL              string          `json:"source_url"`
	OriginalObjectSHA256   string          `json:"original_object_sha256"`
	TranslatedObjectSHA256 string          `json:"translated_object_sha256"`
	OriginalBytes          int             `json:"original_bytes"`
	TranslatedBytes        int             `json:"translated_bytes"`
	CreatedAtUnixMs        int64           `json:"created_at_unix_ms"`
	OriginalURL            string          `json:"original_url"`
	TranslatedURL          string          `json:"translated_url"`
	CaptureJSON            json.RawMessage `json:"capture_json,omitempty"`
	MetadataJSON           json.RawMessage `json:"metadata_json,omitempty"`
}

func (s *Server) handleCreateDebugPage(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, s.maxDebugUploadSize)
	if err := r.ParseMultipartForm(s.maxDebugUploadSize); err != nil {
		jsonError(w, "invalid multipart form", http.StatusBadRequest)
		return
	}

	site := strings.TrimSpace(r.FormValue("site"))
	if site != "kindle" && site != "webtoon" {
		jsonError(w, "invalid site: must be kindle or webtoon", http.StatusBadRequest)
		return
	}
	original, err := readDebugImagePart(r.MultipartForm, "original")
	if err != nil {
		jsonError(w, err.Error(), http.StatusBadRequest)
		return
	}
	translated, err := readDebugImagePart(r.MultipartForm, "translated")
	if err != nil {
		jsonError(w, err.Error(), http.StatusBadRequest)
		return
	}
	captureJSON, err := parseOptionalDebugJSON(r.FormValue("capture_json"))
	if err != nil {
		jsonError(w, "invalid capture_json", http.StatusBadRequest)
		return
	}
	metadataJSON, err := parseOptionalDebugJSON(r.FormValue("metadata_json"))
	if err != nil {
		jsonError(w, "invalid metadata_json", http.StatusBadRequest)
		return
	}

	origSHA, origSize, err := s.cache.StoreObject(original)
	if err != nil {
		jsonError(w, "storing original image", http.StatusInternalServerError)
		return
	}
	transSHA, transSize, err := s.cache.StoreObject(translated)
	if err != nil {
		jsonError(w, "storing translated image", http.StatusInternalServerError)
		return
	}

	now := time.Now().UnixMilli()
	id := fmt.Sprintf("%d-%s-%s", now, origSHA[:12], transSHA[:12])
	manifest := DebugPageManifest{
		SchemaVersion:          1,
		ID:                     id,
		Site:                   site,
		PageID:                 trimDebugField(r.FormValue("page_id"), 200),
		SourceURL:              trimDebugField(r.FormValue("source_url"), 2048),
		OriginalObjectSHA256:   origSHA,
		TranslatedObjectSHA256: transSHA,
		OriginalBytes:          origSize,
		TranslatedBytes:        transSize,
		CreatedAtUnixMs:        now,
		OriginalURL:            fmt.Sprintf("/api/v1/debug/pages/%s/original", id),
		TranslatedURL:          fmt.Sprintf("/api/v1/debug/pages/%s/translated", id),
		CaptureJSON:            captureJSON,
		MetadataJSON:           metadataJSON,
	}
	if err := s.writeDebugManifest(&manifest); err != nil {
		jsonError(w, "storing debug manifest", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(manifest)
}

func (s *Server) handleListDebugPages(w http.ResponseWriter, r *http.Request) {
	limit := 20
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 {
			jsonError(w, "invalid limit", http.StatusBadRequest)
			return
		}
		limit = parsed
	}
	if limit > 100 {
		limit = 100
	}
	manifests, err := s.listDebugManifests()
	if err != nil {
		jsonError(w, "listing debug pages", http.StatusInternalServerError)
		return
	}
	if len(manifests) > limit {
		manifests = manifests[:limit]
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{"pages": manifests})
}

func (s *Server) handleGetDebugPage(w http.ResponseWriter, r *http.Request) {
	manifest, ok := s.loadDebugManifestForRequest(w, r)
	if !ok {
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(manifest)
}

func (s *Server) handleGetDebugPageImage(w http.ResponseWriter, r *http.Request) {
	manifest, ok := s.loadDebugManifestForRequest(w, r)
	if !ok {
		return
	}
	kind := r.PathValue("kind")
	sha := ""
	switch kind {
	case "original":
		sha = manifest.OriginalObjectSHA256
	case "translated":
		sha = manifest.TranslatedObjectSHA256
	default:
		jsonError(w, "invalid debug image kind", http.StatusBadRequest)
		return
	}
	data, err := s.cache.readObjectVerified(sha)
	if err != nil {
		jsonError(w, "debug image not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", http.DetectContentType(data))
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (s *Server) loadDebugManifestForRequest(w http.ResponseWriter, r *http.Request) (*DebugPageManifest, bool) {
	id := r.PathValue("id")
	if !debugIDRe.MatchString(id) {
		jsonError(w, "invalid debug id", http.StatusBadRequest)
		return nil, false
	}
	manifest, err := s.readDebugManifest(id)
	if errors.Is(err, os.ErrNotExist) {
		jsonError(w, "debug page not found", http.StatusNotFound)
		return nil, false
	}
	if err != nil {
		jsonError(w, "reading debug manifest", http.StatusInternalServerError)
		return nil, false
	}
	return manifest, true
}

func readDebugImagePart(form *multipart.Form, field string) ([]byte, error) {
	files := form.File[field]
	if len(files) == 0 {
		return nil, fmt.Errorf("missing '%s' field", field)
	}
	file, err := files[0].Open()
	if err != nil {
		return nil, fmt.Errorf("reading %s image", field)
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil {
		return nil, fmt.Errorf("reading %s image", field)
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("empty %s image", field)
	}
	if !strings.HasPrefix(http.DetectContentType(data), "image/") {
		return nil, fmt.Errorf("%s must be an image", field)
	}
	return data, nil
}

func parseOptionalDebugJSON(raw string) (json.RawMessage, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	if len(raw) > maxDebugJSONBytes {
		return nil, fmt.Errorf("debug json too large")
	}
	canonical, err := canonicalJSON([]byte(raw))
	if err != nil {
		return nil, err
	}
	return json.RawMessage(canonical), nil
}

func trimDebugField(value string, maxLen int) string {
	value = strings.TrimSpace(value)
	if len(value) <= maxLen {
		return value
	}
	return value[:maxLen]
}

func (s *Server) debugManifestPath(id string) string {
	if !debugIDRe.MatchString(id) {
		return ""
	}
	return filepath.Join(s.cache.v2Root(), "debug", "pages", id, "manifest.json")
}

func (s *Server) writeDebugManifest(manifest *DebugPageManifest) error {
	if manifest == nil || !debugIDRe.MatchString(manifest.ID) {
		return fmt.Errorf("invalid debug manifest")
	}
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	path := s.debugManifestPath(manifest.ID)
	if path == "" {
		return fmt.Errorf("invalid debug manifest path")
	}
	return writeFileAtomic(path, data, 0o644)
}

func (s *Server) readDebugManifest(id string) (*DebugPageManifest, error) {
	path := s.debugManifestPath(id)
	if path == "" {
		return nil, os.ErrNotExist
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var manifest DebugPageManifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return nil, err
	}
	if manifest.ID != id {
		return nil, fmt.Errorf("debug manifest id mismatch")
	}
	return &manifest, nil
}

func (s *Server) listDebugManifests() ([]DebugPageManifest, error) {
	root := filepath.Join(s.cache.v2Root(), "debug", "pages")
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return []DebugPageManifest{}, nil
	}
	if err != nil {
		return nil, err
	}
	items := make([]DebugPageManifest, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() || !debugIDRe.MatchString(entry.Name()) {
			continue
		}
		manifest, err := s.readDebugManifest(entry.Name())
		if err == nil {
			items = append(items, *manifest)
		}
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].CreatedAtUnixMs == items[j].CreatedAtUnixMs {
			return items[i].ID > items[j].ID
		}
		return items[i].CreatedAtUnixMs > items[j].CreatedAtUnixMs
	})
	return items, nil
}
