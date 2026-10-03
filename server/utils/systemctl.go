package utils

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-systemd/v22/dbus"
	log "github.com/sirupsen/logrus"
)

var (
	systemctlClientMu sync.Mutex
	systemctlClient   *dbus.Conn
)

func init() {
	_, _ = getSystemctlClient()
}

func getSystemctlClient() (*dbus.Conn, error) {
	systemctlClientMu.Lock()
	defer systemctlClientMu.Unlock()

	if systemctlClient != nil {
		return systemctlClient, nil
	}

	conn, err := dbus.NewSystemConnectionContext(context.Background())
	if err != nil {
		log.Errorf("connect systemctl failed error=%s", err)
		return nil, fmt.Errorf("failed to connect to systemd bus: %w", err)
	}
	systemctlClient = conn
	return systemctlClient, nil
}

func resetSystemctlClient() {
	systemctlClientMu.Lock()
	defer systemctlClientMu.Unlock()

	if systemctlClient != nil {
		systemctlClient.Close()
		systemctlClient = nil
	}
}

func isConnectionError(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "closed") || strings.Contains(msg, "broken pipe") || strings.Contains(msg, "EOF")
}

func IsServiceRunning(servicename string) (bool, error) {
	client, err := getSystemctlClient()
	if err != nil {
		return false, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	properties, err := client.GetUnitPropertiesContext(ctx, servicename)
	if err != nil {
		if isConnectionError(err) {
			resetSystemctlClient()
		}
		return false, err
	}

	loadState, exists := properties["LoadState"]
	if !exists {
		return false, fmt.Errorf("LoadState property not found")
	}

	if loadStateStr, ok := loadState.(string); ok && loadStateStr == "not-found" {
		return false, fmt.Errorf("service not found")
	}

	activeState, exists := properties["ActiveState"]
	if !exists {
		return false, fmt.Errorf("ActiveState property not found")
	}

	activeStateStr, ok := activeState.(string)
	if !ok {
		return false, fmt.Errorf("ActiveState is not a string")
	}

	subState, exists := properties["SubState"]
	if !exists {
		return false, fmt.Errorf("SubState property not found")
	}

	subStateStr, ok := subState.(string)
	if !ok {
		return false, fmt.Errorf("SubState is not a string")
	}

	subStateActive := subStateStr == "listening" || subStateStr == "running"
	// is running
	return activeStateStr == "active" && subStateActive, nil
}

func DaemonReload() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := dbus.NewSystemdConnectionContext(ctx)
	if err != nil {
		log.Errorf("Failed to connect systemd D-Bus: %v", err)
		return err
	}
	defer conn.Close()

	if err := conn.ReloadContext(ctx); err != nil {
		log.Errorf("Failed to execute daemon-reload: %v", err)
		return err
	}

	log.Debugf("Systemd daemon-reload completed successfully.")
	return nil
}

func StartService(name string, enable bool) error {
	client, err := getSystemctlClient()
	if err != nil {
		return err
	}

	if enable {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()

		_, _, err := client.EnableUnitFilesContext(ctx, []string{name}, false, true)
		if err != nil {
			if isConnectionError(err) {
				resetSystemctlClient()
			}
			return fmt.Errorf("failed to enable service: %v", err)
		}

		if err := RestartService(name); err != nil {
			log.Debugf("restart service failed %v", err)
			return err
		}

		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	ch := make(chan string, 1)

	if _, err := client.StartUnitContext(ctx, name, "replace", ch); err != nil {
		if isConnectionError(err) {
			resetSystemctlClient()
		}
		return fmt.Errorf("failed to start service: %v", err)
	}

	select {
	case result := <-ch:
		if result != "done" {
			return fmt.Errorf("service start failed: %s", result)
		}
	case <-ctx.Done():
		return fmt.Errorf("service start timed out")
	}

	if err := RestartService(name); err != nil {
		log.Debugf("restart service failed %v", err)
		return err
	}

	return nil
}

func RestartService(serviceName string) error {
	client, err := getSystemctlClient()
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	ch := make(chan string, 1)

	if _, err := client.RestartUnitContext(ctx, serviceName, "replace", ch); err != nil {
		if isConnectionError(err) {
			resetSystemctlClient()
		}
		return fmt.Errorf("failed to restart service: %v", err)
	}

	select {
	case result := <-ch:
		if result != "done" {
			return fmt.Errorf("service restart failed: %s", result)
		}
	case <-ctx.Done():
		return fmt.Errorf("service restart timed out")
	}

	return nil
}

func StopService(name string, disable bool) error {
	if _, err := execute("systemctl stop " + name); err != nil {
		return err
	}

	if disable {
		if _, err := execute("systemctl disable " + name); err != nil {
			return err
		}
	}

	return nil
}

func execute(command string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "sh", "-c", command)
	cmd.WaitDelay = 2 * time.Second // force-close pipes if children outlive sh after timeout

	output, err := cmd.CombinedOutput()
	if err != nil {
		log.Errorf("failed to execute %s: %s", command, err)
		return output, err
	}

	return output, err
}
