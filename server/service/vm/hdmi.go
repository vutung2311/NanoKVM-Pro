package vm

import (
	"os"
	"path/filepath"
	"strings"
	"time"

	"NanoKVM-Server/proto"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
)

var (
	LT6911Power               = "/proc/lt6911_info/power"
	LT6911HdmiPower           = "/proc/lt6911_info/hdmi_power"
	LT6911LoopoutPower        = "/proc/lt6911_info/loopout_power"
	HdmiPassthroughConfigFile = "/etc/kvm/hdmi_passthrough"
)

func (s *Service) GetHdmiCapture(c *gin.Context) {
	var rsp proto.Response

	enabled, err := isHdmiEnabled(LT6911Power)
	if err != nil {
		rsp.ErrRsp(c, -1, "failed to get HDMI capture status")
		return
	}

	rsp.OkRspWithData(c, &proto.GetHdmiCaptureRsp{
		Enabled: enabled,
	})
	log.Debugf("get HDMI capture status: %t", enabled)
}

func (s *Service) SetHdmiCapture(c *gin.Context) {
	var req proto.SetHdmiCaptureReq
	var rsp proto.Response

	if err := proto.ParseFormRequest(c, &req); err != nil {
		rsp.ErrRsp(c, -1, "invalid arguments")
		return
	}

	status := "off"
	if req.Enabled {
		status = "on"
	}

	if err := os.WriteFile(LT6911Power, []byte(status), 0644); err != nil {
		rsp.ErrRsp(c, -2, "failed to set HDMI capture status")
		return
	}

	rsp.OkRsp(c)
	log.Debugf("set HDMI capture status: %s", status)
}

func (s *Service) GetHdmiPassthrough(c *gin.Context) {
	var rsp proto.Response

	enabled, err := isHdmiEnabled(LT6911LoopoutPower)
	if err != nil {
		if content, readErr := os.ReadFile(HdmiPassthroughConfigFile); readErr == nil {
			trimmed := strings.TrimSpace(string(content))
			enabled = trimmed == "on" || trimmed == "1"
			rsp.OkRspWithData(c, &proto.GetHdmiPassthroughRsp{
				Enabled: enabled,
			})
			log.Debugf("get HDMI passthrough status from config fallback: %t", enabled)
			return
		}
		rsp.ErrRsp(c, -1, "failed to get HDMI passthrough status")
		return
	}

	rsp.OkRspWithData(c, &proto.GetHdmiPassthroughRsp{
		Enabled: enabled,
	})
	log.Debugf("get HDMI passthrough status: %t", enabled)
}

func (s *Service) SetHdmiPassthrough(c *gin.Context) {
	var req proto.SetHdmiPassthroughReq
	var rsp proto.Response

	if err := proto.ParseFormRequest(c, &req); err != nil {
		rsp.ErrRsp(c, -1, "invalid arguments")
		return
	}

	var err error
	var configVal string
	if req.Enabled {
		err = enableHdmiPassthrough()
		configVal = "on"
	} else {
		err = disableHdmiPassthrough()
		configVal = "off"
	}

	if err != nil {
		rsp.ErrRsp(c, -2, "failed to set HDMI passthrough status")
		return
	}

	if writeErr := saveHdmiPassthroughConfig(configVal); writeErr != nil {
		log.Errorf("failed to save HDMI passthrough config: %s", writeErr)
	}

	time.Sleep(10 * time.Millisecond)

	rsp.OkRsp(c)
	log.Debugf("set HDMI passthrough status: %t", req.Enabled)
}

func isHdmiEnabled(flag string) (bool, error) {
	content, err := os.ReadFile(flag)
	if err != nil {
		return false, err
	}

	trimmed := strings.TrimSpace(string(content))
	enabled := trimmed == "on" || trimmed == "1"
	return enabled, nil
}

func saveHdmiPassthroughConfig(val string) error {
	dir := filepath.Dir(HdmiPassthroughConfigFile)
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return err
		}
	}
	return os.WriteFile(HdmiPassthroughConfigFile, []byte(val+"\n"), 0644)
}

func InitHdmiPassthrough() {
	if _, err := os.Stat(LT6911LoopoutPower); os.IsNotExist(err) {
		return
	}

	content, err := os.ReadFile(HdmiPassthroughConfigFile)
	if err == nil {
		val := strings.TrimSpace(string(content))
		if val == "on" || val == "1" {
			log.Infof("restoring HDMI passthrough: enabled")
			if err := enableHdmiPassthrough(); err != nil {
				log.Errorf("failed to enable HDMI passthrough: %s", err)
			}
		} else if val == "off" || val == "0" {
			log.Infof("restoring HDMI passthrough: disabled")
			if err := disableHdmiPassthrough(); err != nil {
				log.Errorf("failed to disable HDMI passthrough: %s", err)
			}
		}
		return
	}

	// No config file yet. Check current hardware state
	if enabled, err := isHdmiEnabled(LT6911LoopoutPower); err == nil && enabled {
		log.Infof("initializing default HDMI passthrough: enabled")
		if err := enableHdmiPassthrough(); err != nil {
			log.Errorf("failed to initialize HDMI passthrough: %s", err)
		}
		_ = saveHdmiPassthroughConfig("on")
	}
}

func enableHdmiPassthrough() error {
	if err := os.WriteFile(LT6911HdmiPower, []byte("0"), 0644); err != nil {
		return err
	}
	time.Sleep(10 * time.Millisecond)
	if err := os.WriteFile(LT6911LoopoutPower, []byte("1"), 0644); err != nil {
		return err
	}
	if err := os.WriteFile(LT6911HdmiPower, []byte("1"), 0644); err != nil {
		return err
	}
	return nil
}

func disableHdmiPassthrough() error {
	if err := os.WriteFile(LT6911LoopoutPower, []byte("0"), 0644); err != nil {
		return err
	}
	if err := os.WriteFile(LT6911HdmiPower, []byte("0"), 0644); err != nil {
		return err
	}
	time.Sleep(10 * time.Millisecond)
	if err := os.WriteFile(LT6911HdmiPower, []byte("1"), 0644); err != nil {
		return err
	}
	return nil
}
