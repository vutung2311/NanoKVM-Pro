//go:build !cgo

package opus

type Decoder struct {
	inited bool
}

func NewDecoder() *Decoder {
	return &Decoder{}
}

func (d *Decoder) Init() error {
	d.inited = true
	return nil
}

func (d *Decoder) Decode(opusData []byte) ([]byte, error) {
	return nil, nil
}

func (d *Decoder) Cleanup() {
	d.inited = false
}

func (d *Decoder) IsInited() bool {
	return d.inited
}
