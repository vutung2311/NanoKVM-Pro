package vm

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"

	"NanoKVM-Server/proto"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
)

// socThermalZone is the AX630C die sensor (axera,ax620e-tsensor), the only
// thermal zone the board's device tree declares. It reports millidegrees
// Celsius.
const socThermalZone = "/sys/class/thermal/thermal_zone0/temp"

// readTemperature returns the reading at path in degrees Celsius, rounded to
// one decimal place: the sensor is a 10-bit ADC, so further digits are noise.
func readTemperature(path string) (float64, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}

	milli, err := strconv.Atoi(strings.TrimSpace(string(content)))
	if err != nil {
		return 0, fmt.Errorf("unexpected thermal reading %q", strings.TrimSpace(string(content)))
	}

	return math.Round(float64(milli)/100) / 10, nil
}

func (s *Service) GetTemperature(c *gin.Context) {
	var rsp proto.Response

	temperature, err := readTemperature(socThermalZone)
	if err != nil {
		log.Debugf("failed to read SoC temperature: %s", err)
		rsp.ErrRsp(c, -1, "temperature unavailable")
		return
	}

	rsp.OkRspWithData(c, &proto.GetTemperatureRsp{
		Temperature: temperature,
	})
}
