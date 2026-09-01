//go:build linux
// +build linux

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Импортируем Libs
import "lalune-desktop/Libs"

// App - основное приложение для Linux
type App struct {
	core      *libs.AppCore
	bridge    *libs.Bridge
	tun       *LinuxTun
	runner    *LinuxRunner
	isRoot
