// Command outline-proxy runs a local HTTP proxy that tunnels connections
// through an Outline / Shadowsocks transport, including the Outline-specific
// "prefix" disguise (which xray-core and sing-box do not support).
//
// Usage:
//
//	outline-proxy -transport "ss://<userinfo>@host:port?prefix=..." -localAddr 127.0.0.1:1081
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"golang.getoutline.org/sdk/x/configurl"
	"golang.getoutline.org/sdk/x/httpproxy"
)

func main() {
	transportConfig := flag.String("transport", "", "Transport config, e.g. ss://<userinfo>@host:port?prefix=...")
	localAddr := flag.String("localAddr", "127.0.0.1:1081", "Local address for the HTTP proxy to listen on")
	flag.Parse()

	if *transportConfig == "" {
		log.Fatal("outline-proxy: missing required -transport flag")
	}

	dialer, err := configurl.NewDefaultProviders().NewStreamDialer(context.Background(), *transportConfig)
	if err != nil {
		log.Fatalf("outline-proxy: failed to build transport: %v", err)
	}

	listener, err := net.Listen("tcp", *localAddr)
	if err != nil {
		log.Fatalf("outline-proxy: failed to listen on %s: %v", *localAddr, err)
	}

	server := &http.Server{Handler: httpproxy.NewProxyHandler(dialer)}

	// Shut down cleanly when the parent script sends SIGTERM/SIGINT.
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		<-sigCh
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()

	log.Printf("outline-proxy: HTTP proxy listening on %s", *localAddr)
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		log.Fatalf("outline-proxy: server error: %v", err)
	}
}
