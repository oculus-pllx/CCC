package system

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNotesPersistUnderCCCUserHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	initial, err := ListNotes()
	if err != nil {
		t.Fatalf("list initial notes: %v", err)
	}
	if len(initial) != 0 {
		t.Fatalf("expected no initial notes, got %#v", initial)
	}

	created, err := SaveNote(Note{Title: "Scratch", Content: "first draft"})
	if err != nil {
		t.Fatalf("save new note: %v", err)
	}
	if created.ID == "" {
		t.Fatal("expected new note id")
	}
	if created.UpdatedAt == "" {
		t.Fatal("expected updated timestamp")
	}

	notesPath := filepath.Join(home, ".ccc", "notes.json")
	if _, err := os.Stat(notesPath); err != nil {
		t.Fatalf("expected notes file at %s: %v", notesPath, err)
	}

	updated, err := SaveNote(Note{ID: created.ID, Title: "Renamed", Content: "saved content"})
	if err != nil {
		t.Fatalf("update note: %v", err)
	}
	if updated.ID != created.ID {
		t.Fatalf("expected same id after update, got %q", updated.ID)
	}

	reloaded, err := ListNotes()
	if err != nil {
		t.Fatalf("reload notes: %v", err)
	}
	if len(reloaded) != 1 || reloaded[0].Title != "Renamed" || reloaded[0].Content != "saved content" {
		t.Fatalf("expected reloaded updated note, got %#v", reloaded)
	}

	if err := DeleteNote(created.ID); err != nil {
		t.Fatalf("delete note: %v", err)
	}
	afterDelete, err := ListNotes()
	if err != nil {
		t.Fatalf("list after delete: %v", err)
	}
	if len(afterDelete) != 0 {
		t.Fatalf("expected notes to be deleted, got %#v", afterDelete)
	}
}
