package hid

import (
	log "github.com/sirupsen/logrus"
)

func (h *Hid) writeRelativeChunks(btn byte, dx, dy, wheel int) {
	if dx == 0 && dy == 0 && wheel == 0 {
		h.WriteHid1([]byte{btn, 0, 0, 0})
		return
	}
	for dx != 0 || dy != 0 || wheel != 0 {
		cx := clampInt8(dx)
		cy := clampInt8(dy)
		cw := clampInt8(wheel)
		h.WriteHid1([]byte{btn, byte(cx), byte(cy), byte(cw)})
		dx -= int(cx)
		dy -= int(cy)
		wheel -= int(cw)
	}
}

func (h *Hid) Mouse(queue <-chan []byte) {
	for event := range queue {
		switch len(event) {
		case 4:
			btn := event[0]
			dx := int(int8(event[1]))
			dy := int(int8(event[2]))
			wheel := int(int8(event[3]))
			pending := true

		coalesceRel:
			for {
				select {
				case nextEvent, ok := <-queue:
					if !ok {
						break coalesceRel
					}
					if len(nextEvent) == 4 && nextEvent[0] == btn {
						dx += int(int8(nextEvent[1]))
						dy += int(int8(nextEvent[2]))
						wheel += int(int8(nextEvent[3]))
					} else {
						h.writeRelativeChunks(btn, dx, dy, wheel)
						pending = false

						if len(nextEvent) == 4 {
							btn = nextEvent[0]
							dx = int(int8(nextEvent[1]))
							dy = int(int8(nextEvent[2]))
							wheel = int(int8(nextEvent[3]))
							pending = true
						} else if len(nextEvent) == 6 {
							h.WriteHid2(nextEvent)
							break coalesceRel
						} else {
							log.Debugf("invalid mouse event: %v", nextEvent)
							break coalesceRel
						}
					}
				default:
					break coalesceRel
				}
			}

			if pending {
				h.writeRelativeChunks(btn, dx, dy, wheel)
			}

		case 6:
			latestAbs := event
			pending := true

		coalesceAbs:
			for {
				select {
				case nextEvent, ok := <-queue:
					if !ok {
						break coalesceAbs
					}
					if len(nextEvent) == 6 && nextEvent[0] == latestAbs[0] && nextEvent[5] == 0 && latestAbs[5] == 0 {
						latestAbs = nextEvent
					} else {
						h.WriteHid2(latestAbs)
						pending = false

						if len(nextEvent) == 6 {
							latestAbs = nextEvent
							pending = true
						} else if len(nextEvent) == 4 {
							h.writeRelativeChunks(nextEvent[0], int(int8(nextEvent[1])), int(int8(nextEvent[2])), int(int8(nextEvent[3])))
							break coalesceAbs
						} else {
							log.Debugf("invalid mouse event: %v", nextEvent)
							break coalesceAbs
						}
					}
				default:
					break coalesceAbs
				}
			}

			if pending {
				h.WriteHid2(latestAbs)
			}

		default:
			log.Debugf("invalid mouse event: %v", event)
		}
	}
}

func clampInt8(v int) int8 {
	if v > 127 {
		return 127
	}
	if v < -127 {
		return -127
	}
	return int8(v)
}
