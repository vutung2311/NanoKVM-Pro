package auth

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"

	"NanoKVM-Server/proto"

	"github.com/gin-gonic/gin"
	log "github.com/sirupsen/logrus"
	"golang.org/x/crypto/bcrypt"
)

func (s *Service) ChangePassword(c *gin.Context) {
	var req proto.ChangePasswordReq
	var rsp proto.Response

	if err := proto.ParseFormRequest(c, &req); err != nil {
		rsp.ErrRsp(c, -1, "invalid parameters")
		return
	}

	hashedPassword, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		rsp.ErrRsp(c, -3, "failed to hash password")
		return
	}

	accountSnapshot, err := backupAccount()
	if err != nil {
		log.Errorf("failed to backup account: %s", err)
		rsp.ErrRsp(c, -4, "failed to save password")
		return
	}

	if err = SetAccount(req.Username, string(hashedPassword)); err != nil {
		if restoreErr := restoreAccount(accountSnapshot); restoreErr != nil {
			log.Errorf("failed to restore account after save failure: %s", restoreErr)
		}
		rsp.ErrRsp(c, -4, "failed to save password")
		return
	}

	// change root password
	err = changeRootPassword(req.Password)
	if err != nil {
		if restoreErr := restoreAccount(accountSnapshot); restoreErr != nil {
			log.Errorf("failed to restore account after root password change failure: %s", restoreErr)
		}
		rsp.ErrRsp(c, -5, "failed to change password")
		return
	}

	rsp.OkRsp(c)
	log.Debugf("change password success, username: %s", req.Username)
}

func (s *Service) IsPasswordUpdated(c *gin.Context) {
	var rsp proto.Response

	if _, err := os.Stat(AccountFile); err != nil {
		rsp.OkRspWithData(c, &proto.IsPasswordUpdatedRsp{
			IsUpdated: false,
		})
		return
	}

	account, err := GetAccount()
	if err != nil || account == nil {
		rsp.ErrRsp(c, -1, "failed to get password")
		return
	}

	rsp.OkRspWithData(c, &proto.IsPasswordUpdatedRsp{
		IsUpdated: passwordChangedFromDefault(account.Password),
	})
}

// defaultPasswordCheck remembers the answer for the last stored hash. The
// desktop asks on every page load, and a bcrypt comparison at the default
// cost takes hundreds of milliseconds of CPU on the A53, so it is computed once
// per hash: a new password brings a new hash, and with it a new comparison.
var defaultPasswordCheck struct {
	sync.Mutex
	hash    string
	changed bool
}

func passwordChangedFromDefault(hash string) bool {
	defaultPasswordCheck.Lock()
	defer defaultPasswordCheck.Unlock()

	if hash != "" && hash == defaultPasswordCheck.hash {
		return defaultPasswordCheck.changed
	}

	err := bcrypt.CompareHashAndPassword([]byte(hash), []byte("admin"))
	changed := errors.Is(err, bcrypt.ErrMismatchedHashAndPassword)
	defaultPasswordCheck.hash = hash
	defaultPasswordCheck.changed = changed
	return changed
}

func changeRootPassword(password string) error {
	err := passwd(password)
	if err != nil {
		log.Errorf("failed to change root password: %s", err)
		return err
	}

	log.Debugf("change root password successful.")
	return nil
}

func passwd(password string) error {
	cmd := exec.Command("passwd", "root")

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	defer func() {
		_ = stdin.Close()
	}()

	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err = cmd.Start(); err != nil {
		return err
	}

	if _, err = io.WriteString(stdin, password+"\n"); err != nil {
		return err
	}

	time.Sleep(100 * time.Millisecond)

	if _, err = io.WriteString(stdin, password+"\n"); err != nil {
		return err
	}

	if err = cmd.Wait(); err != nil {
		return err
	}

	return nil
}
