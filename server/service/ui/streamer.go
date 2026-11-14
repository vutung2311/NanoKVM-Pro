package ui

import (
	"fmt"
	"net/http"

	"NanoKVM-Server/common"

	"github.com/gin-gonic/gin"
)

func GetStreamer(c *gin.Context) {
	screen := common.GetScreen()
	params := screen.Check()

	resolution := Resolution{
		Width:  int(params.Width),
		Height: int(params.Height),
	}
	clients := 0
	if params.StreamType == 0 {
		clients = 1
	}

	rsp := &Response{
		Ok: true,
		Result: Result{
			Delay: 130,
			Params: Params{
				Resolution: fmt.Sprintf("%dx%d", params.Width, params.Height),
			},
			Streamer: Streamer{
				H264: H264{
					Bitrate:     int(params.BitRate),
					Fps:         int(params.FPS),
					Gop:         int(params.GOP),
					RealBitrate: int(params.BitRate),
				},
				Source: Source{
					CapturedFps: params.RealFPS,
					Resolution:  resolution,
					Online:      false,
				},
				Stream: Stream{
					Clients:   clients,
					QueuedFps: params.RealFPS,
				},
			},
		},
	}

	c.JSON(http.StatusOK, rsp)
}
