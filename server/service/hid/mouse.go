package hid

import (
	log "github.com/sirupsen/logrus"
)

func (h *Hid) writeRelativeChunks(btn byte, dx, dy, wheel, hwheel int) {
	var report [5]byte
	report[0] = btn
	if dx == 0 && dy == 0 && wheel == 0 && hwheel == 0 {
		h.WriteHid1(report[:])
		return
	}
	for dx != 0 || dy != 0 || wheel != 0 || hwheel != 0 {
		cx := clampInt8(dx)
		cy := clampInt8(dy)
		cw := clampInt8(wheel)
		ch := clampInt8(hwheel)
		report[1] = byte(cx)
		report[2] = byte(cy)
		report[3] = byte(cw)
		report[4] = byte(ch)
		h.WriteHid1(report[:])
		dx -= int(cx)
		dy -= int(cy)
		wheel -= int(cw)
		hwheel -= int(ch)
	}
}

func (h *Hid) Mouse(queue <-chan []byte) {
	for event := range queue {
		switch len(event) {
		case 4, 5:
			btn := event[0]
			dx := int(int8(event[1]))
			dy := int(int8(event[2]))
			wheel := int(int8(event[3]))
			hwheel := 0
			if len(event) >= 5 {
				hwheel = int(int8(event[4]))
			}
			pending := true

		coalesceRel:
			for {
				select {
				case nextEvent, ok := <-queue:
					if !ok {
						break coalesceRel
					}
					if (len(nextEvent) == 4 || len(nextEvent) == 5) && nextEvent[0] == btn {
						dx += int(int8(nextEvent[1]))
						dy += int(int8(nextEvent[2]))
						wheel += int(int8(nextEvent[3]))
						if len(nextEvent) >= 5 {
							hwheel += int(int8(nextEvent[4]))
						}
					} else {
						h.writeRelativeChunks(btn, dx, dy, wheel, hwheel)
						pending = false

						if len(nextEvent) == 4 || len(nextEvent) == 5 {
							btn = nextEvent[0]
							dx = int(int8(nextEvent[1]))
							dy = int(int8(nextEvent[2]))
							wheel = int(int8(nextEvent[3]))
							hwheel = 0
							if len(nextEvent) >= 5 {
								hwheel = int(int8(nextEvent[4]))
							}
							pending = true
						} else if len(nextEvent) == 6 || len(nextEvent) == 7 {
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
				h.writeRelativeChunks(btn, dx, dy, wheel, hwheel)
			}

		case 6, 7:
			latestAbs := event
			pending := true

		coalesceAbs:
			for {
				select {
				case nextEvent, ok := <-queue:
					if !ok {
						break coalesceAbs
					}
					hasWheel := (len(latestAbs) >= 6 && latestAbs[5] != 0) || (len(latestAbs) >= 7 && latestAbs[6] != 0)
					nextHasWheel := (len(nextEvent) >= 6 && nextEvent[5] != 0) || (len(nextEvent) >= 7 && nextEvent[6] != 0)
					if (len(nextEvent) == 6 || len(nextEvent) == 7) && nextEvent[0] == latestAbs[0] && !hasWheel && !nextHasWheel {
						latestAbs = nextEvent
					} else {
						h.WriteHid2(latestAbs)
						pending = false

						if len(nextEvent) == 6 || len(nextEvent) == 7 {
							latestAbs = nextEvent
							pending = true
						} else if len(nextEvent) == 4 || len(nextEvent) == 5 {
							hw := 0
							if len(nextEvent) >= 5 {
								hw = int(int8(nextEvent[4]))
							}
							h.writeRelativeChunks(nextEvent[0], int(int8(nextEvent[1])), int(int8(nextEvent[2])), int(int8(nextEvent[3])), hw)
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
