package common

import "sync/atomic"

var inputHook atomic.Pointer[func()]

// SetInputHook registers fn to run on every keyboard or mouse report the
// server is about to send to the host. The stream's frame-rate governor uses
// it to restore the full rate before the picture changes.
func SetInputHook(fn func()) { inputHook.Store(&fn) }

// NoteInput runs the registered input hook, if any.
func NoteInput() {
	if fn := inputHook.Load(); fn != nil {
		(*fn)()
	}
}
