package hid

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"

	"NanoKVM-Server/proto"
)

type Char struct {
	Modifiers int
	Code      int
}

type PasteReq struct {
	Content string `form:"content" validate:"required"`
}

func (s *Service) Paste(c *gin.Context) {
	var req PasteReq
	var rsp proto.Response

	if err := proto.ParseFormRequest(c, &req); err != nil {
		rsp.ErrRsp(c, -1, "invalid arguments")
		return
	}

	content := strings.ReplaceAll(req.Content, "\r\n", "\n")
	content = strings.ReplaceAll(content, "\r", "\n")

	if len(content) > 1024 {
		rsp.ErrRsp(c, -2, "content too long")
		return
	}

	// One paste at a time: two interleaved pastes would type garbage.
	if !pasteMu.TryLock() {
		rsp.ErrRsp(c, -4, "another paste is in progress")
		return
	}
	defer pasteMu.Unlock()

	// The request context ends when the client goes away (tab closed,
	// navigation), so a long paste stops instead of typing on unattended.
	n, err := typeText(c.Request.Context(), GetHid(), content)
	switch {
	case err == nil:
		rsp.OkRsp(c)
		log.Debugf("hid paste success, total %d characters processed", n)
	case errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded):
		log.Infof("hid paste cancelled by client after %d characters", n)
	default:
		log.Warnf("hid paste aborted after %d characters: %s", n, err)
		rsp.ErrRsp(c, -3, "host is not accepting keyboard input")
	}
}

var pasteMu sync.Mutex

// pasteKeyboard is the part of Hid that typeText uses.
type pasteKeyboard interface {
	SubmitKeyboard(report []byte)
	SubmitKeyboardWait(report []byte, timeout time.Duration) error
}

// sleepCtx waits for d or until ctx ends.
func sleepCtx(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// typeText types content as HID key presses. It stops at the first rejected
// report or when ctx ends, and always leaves every key released. It returns
// the number of characters typed.
func typeText(ctx context.Context, kb pasteKeyboard, content string) (int, error) {
	keyUp := []byte{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
	typed := 0
	released := true
	defer func() {
		if !released {
			kb.SubmitKeyboard(keyUp)
		}
	}()

	send := func(report []byte) error {
		released = report[0] == 0 && report[2] == 0
		return kb.SubmitKeyboardWait(report, pasteReportTimeout)
	}

	for _, char := range content {
		if err := ctx.Err(); err != nil {
			return typed, err
		}
		key, ok := CharMap[char]
		if !ok {
			log.Debugf("unknown key '%c' (rune: %d)", char, char)
			continue
		}

		mod := byte(key.Modifiers)
		code := byte(key.Code)

		if mod != 0 {
			// Discrete modifier sequence: hold modifier before and through the key press
			// so the target host OS and browser event loop reliably recognize the modifier state.
			modDown := []byte{mod, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
			keyDown := []byte{mod, 0x00, code, 0x00, 0x00, 0x00, 0x00, 0x00}
			steps := []struct {
				report []byte
				wait   time.Duration
			}{
				{modDown, 15 * time.Millisecond},
				{keyDown, 25 * time.Millisecond},
				{modDown, 15 * time.Millisecond}, // release the key, keep the modifier
				{keyUp, 0},
			}
			for _, st := range steps {
				if err := send(st.report); err != nil {
					return typed, err
				}
				if st.wait > 0 {
					if err := sleepCtx(ctx, st.wait); err != nil {
						return typed, err
					}
				}
			}
		} else {
			keyDown := []byte{0x00, 0x00, code, 0x00, 0x00, 0x00, 0x00, 0x00}
			if err := send(keyDown); err != nil {
				return typed, err
			}
			if err := sleepCtx(ctx, 20*time.Millisecond); err != nil {
				return typed, err
			}
			if err := send(keyUp); err != nil {
				return typed, err
			}
		}
		typed++

		gap := 20 * time.Millisecond
		if char == '\n' {
			gap = 100 * time.Millisecond
		}
		if err := sleepCtx(ctx, gap); err != nil {
			return typed, err
		}
	}
	return typed, nil
}

// pasteReportTimeout bounds how long Paste waits for the host to accept a
// single report before aborting.
const pasteReportTimeout = time.Second

var CharMap = map[rune]Char{
	// Lowercase letters
	'a': {0, 4}, 'b': {0, 5}, 'c': {0, 6}, 'd': {0, 7}, 'e': {0, 8},
	'f': {0, 9}, 'g': {0, 10}, 'h': {0, 11}, 'i': {0, 12}, 'j': {0, 13},
	'k': {0, 14}, 'l': {0, 15}, 'm': {0, 16}, 'n': {0, 17}, 'o': {0, 18},
	'p': {0, 19}, 'q': {0, 20}, 'r': {0, 21}, 's': {0, 22}, 't': {0, 23},
	'u': {0, 24}, 'v': {0, 25}, 'w': {0, 26}, 'x': {0, 27}, 'y': {0, 28},
	'z': {0, 29},

	// Uppercase letters (Modifier 2 typically means Left Shift)
	'A': {2, 4}, 'B': {2, 5}, 'C': {2, 6}, 'D': {2, 7}, 'E': {2, 8},
	'F': {2, 9}, 'G': {2, 10}, 'H': {2, 11}, 'I': {2, 12}, 'J': {2, 13},
	'K': {2, 14}, 'L': {2, 15}, 'M': {2, 16}, 'N': {2, 17}, 'O': {2, 18},
	'P': {2, 19}, 'Q': {2, 20}, 'R': {2, 21}, 'S': {2, 22}, 'T': {2, 23},
	'U': {2, 24}, 'V': {2, 25}, 'W': {2, 26}, 'X': {2, 27}, 'Y': {2, 28},
	'Z': {2, 29},

	// Numbers
	'1': {0, 30}, '2': {0, 31}, '3': {0, 32}, '4': {0, 33}, '5': {0, 34},
	'6': {0, 35}, '7': {0, 36}, '8': {0, 37}, '9': {0, 38}, '0': {0, 39},

	// Shifted numbers / Symbols
	'!': {2, 30}, // Shift + 1
	'@': {2, 31}, // Shift + 2
	'#': {2, 32}, // Shift + 3
	'$': {2, 33}, // Shift + 4
	'%': {2, 34}, // Shift + 5
	'^': {2, 35}, // Shift + 6
	'&': {2, 36}, // Shift + 7
	'*': {2, 37}, // Shift + 8
	'(': {2, 38}, // Shift + 9
	')': {2, 39}, // Shift + 0

	// Other common characters
	'\n': {2, 40}, // Shift + Enter
	'\t': {0, 43}, // Tab
	' ':  {0, 44}, // Space
	'-':  {0, 45}, // Hyphen / Minus
	'=':  {0, 46}, // Equals
	'[':  {0, 47}, // Left Square Bracket
	']':  {0, 48}, // Right Square Bracket
	'\\': {0, 49}, // Backslash

	';':  {0, 51}, // Semicolon
	'\'': {0, 52}, // Apostrophe / Single Quote
	'`':  {0, 53}, // Grave Accent / Backtick
	',':  {0, 54}, // Comma
	'.':  {0, 55}, // Period / Dot
	'/':  {0, 56}, // Slash

	// Shifted symbols
	'_': {2, 45}, // Underscore (Shift + Hyphen)
	'+': {2, 46}, // Plus (Shift + Equals)
	'{': {2, 47}, // Left Curly Brace (Shift + Left Square Bracket)
	'}': {2, 48}, // Right Curly Brace (Shift + Right Square Bracket)
	'|': {2, 49}, // Pipe (Shift + Backslash)

	':': {2, 51}, // Colon (Shift + Semicolon)
	'"': {2, 52}, // Double Quote (Shift + Apostrophe)
	'~': {2, 53}, // Tilde (Shift + Grave Accent)
	'<': {2, 54}, // Less Than (Shift + Comma)
	'>': {2, 55}, // Greater Than (Shift + Period)
	'?': {2, 56}, // Question Mark (Shift + Slash)
}
