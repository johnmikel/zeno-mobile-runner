package zmr

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func fakeServerPath(t *testing.T) string {
	t.Helper()
	root := filepath.Clean(filepath.Join("..", "..", ".."))
	return filepath.Join(root, "tests", "fake-json-rpc-server.mjs")
}

func TestClientDrivesFakeSession(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	client, err := Start(ctx, "node", fakeServerPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	capabilities, err := client.Capabilities(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if capabilities.ProtocolVersion != "2026-04-28" {
		t.Fatalf("protocol version = %q", capabilities.ProtocolVersion)
	}
	if capabilities.IosPreview {
		t.Fatal("iOS should be reported as supported, not preview")
	}
	iosSupport := capabilities.PlatformSupport["ios"]
	if iosSupport.Status != "supported" || len(iosSupport.DeviceTypes) != 2 || iosSupport.DeviceTypes[0] != "simulator" || iosSupport.DeviceTypes[1] != "physical" || !iosSupport.PhysicalDevices {
		t.Fatalf("unexpected iOS platform support: %+v", iosSupport)
	}
	foundAssertHealthy := false
	foundTraceExplain := false
	for _, method := range capabilities.Methods {
		if method == "assert.healthy" {
			foundAssertHealthy = true
		}
		if method == "trace.explain" {
			foundTraceExplain = true
		}
	}
	if !foundAssertHealthy {
		t.Fatalf("capabilities missing assert.healthy: %+v", capabilities.Methods)
	}
	if !foundTraceExplain {
		t.Fatalf("capabilities missing trace.explain: %+v", capabilities.Methods)
	}

	session, err := client.CreateSession(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if session.SessionID != "default" {
		t.Fatalf("session id = %q", session.SessionID)
	}
	if ok, err := client.CloseSession(ctx); err != nil || !ok {
		t.Fatalf("close session ok=%v err=%v", ok, err)
	}

	devices, err := client.Devices(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(devices) != 2 || devices[0].Serial != "fake-device-1" || devices[0].State != "device" || !devices[0].Ready || devices[1].Serial != "fake-ios-disconnected" || devices[1].State != "disconnected" || devices[1].Ready {
		t.Fatalf("unexpected devices: %+v", devices)
	}

	ok, err := client.OpenLink(ctx, "exampleapp://go-client")
	if err != nil || !ok {
		t.Fatalf("open link ok=%v err=%v", ok, err)
	}
	for name, call := range map[string]func(context.Context) (bool, error){
		"launch":      client.Launch,
		"stop":        client.Stop,
		"clear_state": client.ClearState,
		"hide":        client.HideKeyboard,
		"back":        client.PressBack,
	} {
		ok, err := call(ctx)
		if err != nil || !ok {
			t.Fatalf("%s ok=%v err=%v", name, ok, err)
		}
	}
	ok, err = client.Tap(ctx, map[string]interface{}{"text": "Home"})
	if err != nil || !ok {
		t.Fatalf("tap ok=%v err=%v", ok, err)
	}
	ok, err = client.TypeText(ctx, "agent@example.com", map[string]interface{}{"resourceId": "email"})
	if err != nil || !ok {
		t.Fatalf("type text ok=%v err=%v", ok, err)
	}
	ok, err = client.EraseText(ctx, map[string]interface{}{"resourceId": "email"}, 32)
	if err != nil || !ok {
		t.Fatalf("erase text ok=%v err=%v", ok, err)
	}
	ok, err = client.Swipe(ctx, 10, 100, 10, 20, 250)
	if err != nil || !ok {
		t.Fatalf("swipe ok=%v err=%v", ok, err)
	}
	ok, err = client.ScrollUntilVisible(ctx, map[string]interface{}{"text": "Settings"}, "down", 1000)
	if err != nil || !ok {
		t.Fatalf("scroll ok=%v err=%v", ok, err)
	}

	ok, err = client.WaitUntil(ctx, map[string]interface{}{"text": "Home"}, 1000)
	if err != nil || !ok {
		t.Fatalf("wait ok=%v err=%v", ok, err)
	}
	ok, err = client.WaitAny(ctx, []map[string]interface{}{{"text": "Home"}, {"text": "Dashboard"}}, 1000)
	if err != nil || !ok {
		t.Fatalf("wait any ok=%v err=%v", ok, err)
	}
	ok, err = client.WaitGone(ctx, map[string]interface{}{"text": "Loading"}, 1000)
	if err != nil || !ok {
		t.Fatalf("wait gone ok=%v err=%v", ok, err)
	}
	ok, err = client.AssertVisible(ctx, map[string]interface{}{"text": "Home"}, 1000)
	if err != nil || !ok {
		t.Fatalf("assert visible ok=%v err=%v", ok, err)
	}
	ok, err = client.AssertNotVisible(ctx, map[string]interface{}{"text": "Application has crashed"}, 1000)
	if err != nil || !ok {
		t.Fatalf("assert not visible ok=%v err=%v", ok, err)
	}
	ok, err = client.AssertHealthy(ctx, 1000)
	if err != nil || !ok {
		t.Fatalf("assert healthy ok=%v err=%v", ok, err)
	}

	snapshot, err := client.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.ActivePackage != "com.example.mobiletest" {
		t.Fatalf("active package = %q", snapshot.ActivePackage)
	}
	if len(snapshot.Nodes) == 0 || snapshot.Nodes[0].Text == nil || *snapshot.Nodes[0].Text != "Home" {
		t.Fatalf("unexpected first node: %+v", snapshot.Nodes)
	}

	semanticSnapshot, err := client.SemanticSnapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(semanticSnapshot.Nodes) == 0 || semanticSnapshot.Nodes[0].Role != "button" || semanticSnapshot.Nodes[0].RecommendedAction == nil || *semanticSnapshot.Nodes[0].RecommendedAction != "tap" {
		t.Fatalf("unexpected semantic first node: %+v", semanticSnapshot.Nodes)
	}

	exported, err := client.ExportTrace(ctx, filepath.Join(os.TempDir(), "go-client.zmrtrace"), true, true)
	if err != nil {
		t.Fatal(err)
	}
	if !exported.Redacted || !exported.OmitScreenshots {
		t.Fatalf("unexpected export: %+v", exported)
	}

	events, err := client.TraceEvents(ctx, 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if events.NextSeq != 2 || len(events.Events) == 0 || events.Events[0]["kind"] != "rpc.request" {
		t.Fatalf("unexpected events: %+v", events)
	}

	explanation, err := client.ExplainTrace(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if explanation.TraceDir != "traces/client" || explanation.Scenario != "client session" || explanation.Status != "failed" || explanation.Error != "WaitTimeout" || explanation.Diagnostic == nil || explanation.Diagnostic.Kind != "wait.visible" || len(explanation.Diagnostic.VisibleTexts) != 2 || explanation.Diagnostic.VisibleTexts[0] != "Home" || len(explanation.NextCommands) == 0 {
		t.Fatalf("unexpected explanation: %+v", explanation)
	}

	discovered, err := client.DiscoverTrace(ctx, ".zmr/discovered/go-client.json", TraceDiscoverOptions{
		IncludeActions: true,
		Validate:       true,
		Force:          true,
		Name:           "go client discovery",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !discovered.OK || discovered.Mode != "discover" || discovered.Out != ".zmr/discovered/go-client.json" || discovered.Replay.StepCount == 0 || !discovered.Validated || discovered.Validation == nil || !discovered.Validation.OK {
		t.Fatalf("unexpected discovery result: %+v", discovered)
	}

	validation, err := client.ValidateScenario(ctx, ".zmr/discovered/go-client.json")
	if err != nil {
		t.Fatal(err)
	}
	if !validation.OK || validation.StepCount == 0 {
		t.Fatalf("unexpected validation result: %+v", validation)
	}
}

func TestClientReturnsRPCError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	client, err := Start(ctx, "node", fakeServerPath(t))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	var rpcErr *RPCError
	err = client.Request(ctx, "missing.method", map[string]interface{}{}, nil)
	if !errors.As(err, &rpcErr) {
		t.Fatalf("expected RPCError, got %T %v", err, err)
	}
	if rpcErr.Code != -32601 || rpcErr.Message != "method not found" {
		t.Fatalf("unexpected rpc error: %+v", rpcErr)
	}
}
