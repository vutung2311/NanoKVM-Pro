package config

import (
	"os"
	"regexp"
	"strings"
)

type HWVersion int

const (
	HWVersionUnknown = iota
	HWVersionDesk
	HWVersionATX

	HWVersionFile = "/proc/lt6911_info/version"

	DefaultDeskDeviceNumber = "NebE20020"
	DefaultATXDeviceNumber  = "NxaL020020"
)

var DeviceNumberFiles = []string{
	"/etc/kvm/device_number",
	"/kvmapp/device_number",
	"/boot/device_number",
}

var HWModelFiles = []string{
	"/etc/kvm/model",
	"/kvmapp/model",
	"/boot/model",
}

var HWPro = Hardware{
	Version:      HWVersionDesk,
	GPIOReset:    "/sys/class/gpio/gpio35/value",
	GPIOPower:    "/sys/class/gpio/gpio7/value",
	GPIOPowerLED: "/sys/class/gpio/gpio75/value",
	GPIOHDDLed:   "/sys/class/gpio/gpio74/value",
}

func (h HWVersion) String() string {
	switch h {
	case HWVersionDesk, HWVersionATX:
		return "Pro"
	default:
		return "Unknown"
	}
}

func DeviceNumber() string {
	// 1. Try reading the hardware proc file (/proc/lt6911_info/version)
	content, err := os.ReadFile(HWVersionFile)
	if err == nil {
		parts := strings.Fields(strings.TrimSpace(string(content)))
		if len(parts) > 0 {
			pn := strings.TrimSpace(parts[len(parts)-1])
			if pn != "" && !strings.EqualFold(pn, "unknown") {
				return pn
			}
		}
	}

	// 2. Check for configured/override device number files
	for _, file := range DeviceNumberFiles {
		if data, err := os.ReadFile(file); err == nil {
			pn := strings.TrimSpace(string(data))
			if pn != "" && !strings.EqualFold(pn, "unknown") {
				return pn
			}
		}
	}

	// 3. Fallback to model-appropriate product identity
	if GetHwVersion() == HWVersionATX {
		return DefaultATXDeviceNumber
	}
	return DefaultDeskDeviceNumber
}

func GetHwVersion() HWVersion {
	var atx = regexp.MustCompile(`(?i)atx`)
	var desk = regexp.MustCompile(`(?i)(desk)`)

	content, err := os.ReadFile(HWVersionFile)
	if err == nil {
		version := strings.ToLower(string(content))
		switch {
		case desk.MatchString(version):
			return HWVersionDesk
		case atx.MatchString(version):
			return HWVersionATX
		}
	}

	// Fallback to configured model files
	for _, file := range HWModelFiles {
		if data, err := os.ReadFile(file); err == nil {
			m := strings.ToLower(string(data))
			switch {
			case desk.MatchString(m):
				return HWVersionDesk
			case atx.MatchString(m):
				return HWVersionATX
			}
		}
	}

	// Default for NanoKVM-Pro is Desk
	return HWVersionDesk
}

func getHardware() (h Hardware) {
	h = HWPro
	h.Version = GetHwVersion()
	return h
}
