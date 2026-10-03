package hid

// clampInt8 limits v to the HID relative axis range (±127).
func clampInt8(v int) int8 {
	if v > 127 {
		return 127
	}
	if v < -127 {
		return -127
	}
	return int8(v)
}
