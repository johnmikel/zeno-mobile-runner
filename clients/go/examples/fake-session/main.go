package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/johnmikel/zeno-mobile-runner/clients/go/zmr"
)

func main() {
	zmrBin := flag.String("zmr", "zig-out/bin/zmr", "zmr executable")
	adb := flag.String("adb", "tests/fake-adb.sh", "adb executable or fake adb script")
	device := flag.String("device", "fake-android-1", "device serial")
	appID := flag.String("app-id", "com.example.mobiletest", "app id")
	traceDir := flag.String("trace-dir", "traces/demo-go-client", "trace directory")
	traceOut := flag.String("trace-out", "traces/demo-go-client-redacted.zmrtrace", "trace export path")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client, err := zmr.Start(ctx,
		*zmrBin,
		"serve",
		"--transport", "stdio",
		"--device", *device,
		"--app-id", *appID,
		"--adb", *adb,
		"--trace-dir", *traceDir,
	)
	if err != nil {
		fail(err)
	}
	defer client.Close()

	capabilities, err := client.Capabilities(ctx)
	if err != nil {
		fail(err)
	}
	if _, err := client.CreateSession(ctx); err != nil {
		fail(err)
	}
	if _, err := client.OpenLink(ctx, "exampleapp://go-client"); err != nil {
		fail(err)
	}
	if _, err := client.WaitUntil(ctx, map[string]interface{}{"text": "Dashboard"}, 1000); err != nil {
		fail(err)
	}
	if _, err := client.Tap(ctx, map[string]interface{}{"text": "Sign in"}); err != nil {
		fail(err)
	}
	if _, err := client.TypeText(ctx, "agent@example.com", map[string]interface{}{"resourceId": "email-login-email-input"}); err != nil {
		fail(err)
	}
	if _, err := client.AssertNotVisible(ctx, map[string]interface{}{"text": "Application has crashed"}, 100); err != nil {
		fail(err)
	}
	if _, err := client.AssertHealthy(ctx, 100); err != nil {
		fail(err)
	}
	snapshot, err := client.Snapshot(ctx)
	if err != nil {
		fail(err)
	}
	exported, err := client.ExportTrace(ctx, *traceOut, true, true)
	if err != nil {
		fail(err)
	}
	events, err := client.TraceEvents(ctx, 0, 10)
	if err != nil {
		fail(err)
	}

	summary := map[string]interface{}{
		"protocolVersion": capabilities.ProtocolVersion,
		"activePackage":   snapshot.ActivePackage,
		"nodes":           len(snapshot.Nodes),
		"events":          events.NextSeq,
		"traceDir":        *traceDir,
		"traceOut":        exported.Out,
	}
	encoded, _ := json.Marshal(summary)
	fmt.Println(string(encoded))
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
