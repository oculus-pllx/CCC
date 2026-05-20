package system

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type Note struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Content   string `json:"content"`
	UpdatedAt string `json:"updatedAt"`
}

func ListNotes() ([]Note, error) {
	notes, err := readNotes()
	if err != nil {
		return nil, err
	}
	sort.SliceStable(notes, func(i, j int) bool {
		return notes[i].UpdatedAt > notes[j].UpdatedAt
	})
	return notes, nil
}

func SaveNote(note Note) (Note, error) {
	note.Title = strings.TrimSpace(note.Title)
	if note.Title == "" {
		return Note{}, fmt.Errorf("note title is required")
	}
	if note.ID == "" {
		note.ID = newNoteID()
	}
	note.UpdatedAt = time.Now().Format(time.RFC3339)

	notes, err := readNotes()
	if err != nil {
		return Note{}, err
	}
	updated := false
	for index := range notes {
		if notes[index].ID == note.ID {
			notes[index] = note
			updated = true
			break
		}
	}
	if !updated {
		notes = append(notes, note)
	}
	if err := writeNotes(notes); err != nil {
		return Note{}, err
	}
	return note, nil
}

func DeleteNote(id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return fmt.Errorf("note id is required")
	}
	notes, err := readNotes()
	if err != nil {
		return err
	}
	filtered := notes[:0]
	for _, note := range notes {
		if note.ID != id {
			filtered = append(filtered, note)
		}
	}
	return writeNotes(filtered)
}

func readNotes() ([]Note, error) {
	path := notesPath()
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return []Note{}, nil
	}
	if err != nil {
		return nil, err
	}
	if len(strings.TrimSpace(string(data))) == 0 {
		return []Note{}, nil
	}
	var notes []Note
	if err := json.Unmarshal(data, &notes); err != nil {
		return nil, fmt.Errorf("read notes: %w", err)
	}
	return notes, nil
}

func writeNotes(notes []Note) error {
	path := notesPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(notes, "", "  ")
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), ".notes-*.tmp")
	if err != nil {
		return err
	}
	tempName := temp.Name()
	defer os.Remove(tempName)
	if _, err := temp.Write(append(data, '\n')); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Chmod(0o600); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempName, path)
}

func notesPath() string {
	return filepath.Join(workstationHome(), ".ccc", "notes.json")
}

func newNoteID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err == nil {
		return "note-" + hex.EncodeToString(b[:])
	}
	return fmt.Sprintf("note-%d", time.Now().UnixNano())
}
