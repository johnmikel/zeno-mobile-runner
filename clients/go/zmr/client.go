package zmr

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"sync"
)

type Client struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	lines  *bufio.Scanner
	nextID int64
	mu     sync.Mutex
	closed bool
}

type RPCError struct {
	Code       int             `json:"code"`
	Message    string          `json:"message"`
	PublicCode string          `json:"publicCode,omitempty"`
	Data       json.RawMessage `json:"data,omitempty"`
}

func (e *RPCError) Error() string {
	if e.Message == "" {
		return "ZMR JSON-RPC error"
	}
	return e.Message
}

type rpcRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      int64       `json:"id"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      int64           `json:"id"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

type Capabilities struct {
	Name            string                     `json:"name"`
	Version         string                     `json:"version"`
	ProtocolVersion string                     `json:"protocolVersion"`
	Platforms       []string                   `json:"platforms"`
	PlatformSupport map[string]PlatformSupport `json:"platformSupport"`
	IosPreview      bool                       `json:"iosPreview"`
	Transports      []string                   `json:"transports"`
	Methods         []string                   `json:"methods"`
}

type PlatformSupport struct {
	Status          string   `json:"status"`
	DeviceTypes     []string `json:"deviceTypes"`
	Automation      []string `json:"automation"`
	PhysicalDevices bool     `json:"physicalDevices,omitempty"`
}

type Session struct {
	SessionID string `json:"sessionId"`
}

type DeviceInfo struct {
	Serial string `json:"serial"`
	State  string `json:"state"`
	Ready  bool   `json:"ready"`
}

type Snapshot struct {
	ID             string                 `json:"id"`
	TimestampMS    int64                  `json:"timestampMs"`
	Viewport       map[string]interface{} `json:"viewport"`
	ActivePackage  string                 `json:"activePackage"`
	ActiveActivity string                 `json:"activeActivity"`
	Nodes          []Node                 `json:"nodes"`
}

type Node struct {
	StableID    string                 `json:"stableId"`
	ClassName   string                 `json:"className"`
	ResourceID  string                 `json:"resourceId,omitempty"`
	Text        *string                `json:"text"`
	ContentDesc *string                `json:"contentDesc"`
	Bounds      map[string]interface{} `json:"bounds"`
	Enabled     bool                   `json:"enabled"`
	Visible     bool                   `json:"visible"`
	Selected    bool                   `json:"selected"`
}

type SemanticSnapshot struct {
	ID             string         `json:"id"`
	TimestampMS    int64          `json:"timestampMs"`
	Viewport       map[string]any `json:"viewport"`
	ActivePackage  string         `json:"activePackage"`
	ActiveActivity string         `json:"activeActivity"`
	FocusedNodeID  *string        `json:"focusedNodeId"`
	Nodes          []SemanticNode `json:"nodes"`
	Summary        struct {
		NodeCount        int      `json:"nodeCount"`
		InteractiveCount int      `json:"interactiveCount"`
		VisibleText      []string `json:"visibleText"`
	} `json:"summary"`
}

type SemanticNode struct {
	ID                string                 `json:"id"`
	Role              string                 `json:"role"`
	Name              string                 `json:"name"`
	Selector          map[string]string      `json:"selector"`
	Source            map[string]interface{} `json:"source"`
	Bounds            map[string]interface{} `json:"bounds"`
	Enabled           bool                   `json:"enabled"`
	Visible           bool                   `json:"visible"`
	Selected          bool                   `json:"selected"`
	Interactive       bool                   `json:"interactive"`
	RecommendedAction *string                `json:"recommendedAction"`
}

type TraceEvents struct {
	TraceDir  string                   `json:"traceDir"`
	AfterSeq  int64                    `json:"afterSeq"`
	NextSeq   int64                    `json:"nextSeq"`
	LatestSeq int64                    `json:"latestSeq"`
	Events    []map[string]interface{} `json:"events"`
}

type TraceDiagnostic struct {
	Kind               string   `json:"kind"`
	Status             string   `json:"status,omitempty"`
	SnapshotID         string   `json:"snapshotId,omitempty"`
	ArtifactStatus     string   `json:"artifactStatus,omitempty"`
	SemanticStatus     string   `json:"semanticStatus,omitempty"`
	Error              string   `json:"error,omitempty"`
	ScreenshotArtifact string   `json:"screenshotArtifact,omitempty"`
	Source             string   `json:"source,omitempty"`
	ActivePackage      string   `json:"activePackage,omitempty"`
	ActiveActivity     string   `json:"activeActivity,omitempty"`
	VisibleTexts       []string `json:"visibleTexts,omitempty"`
	NearestTextMatches []string `json:"nearestTextMatches,omitempty"`
}

type TraceExplain struct {
	OK                  bool             `json:"ok"`
	TraceDir            string           `json:"traceDir"`
	Scenario            string           `json:"scenario"`
	Status              string           `json:"status"`
	AppID               string           `json:"appId,omitempty"`
	DurationMS          int64            `json:"durationMs,omitempty"`
	EventCount          int64            `json:"eventCount,omitempty"`
	SnapshotCount       int64            `json:"snapshotCount,omitempty"`
	PartialFailureCount int64            `json:"partialFailureCount,omitempty"`
	FailedStepIndex     int64            `json:"failedStepIndex,omitempty"`
	Error               string           `json:"error,omitempty"`
	Diagnostic          *TraceDiagnostic `json:"diagnostic,omitempty"`
	PartialFailure      *TraceDiagnostic `json:"partialFailure,omitempty"`
	LastEvent           string           `json:"lastEvent,omitempty"`
	NextCommands        []string         `json:"nextCommands"`
}

type TraceExport struct {
	TraceDir        string `json:"traceDir"`
	Out             string `json:"out"`
	Redacted        bool   `json:"redacted"`
	OmitScreenshots bool   `json:"omitScreenshots"`
}

type ValidationResult struct {
	OK           bool     `json:"ok"`
	Path         string   `json:"path"`
	Name         string   `json:"name,omitempty"`
	AppID        string   `json:"appId,omitempty"`
	StepCount    int      `json:"stepCount,omitempty"`
	ErrorCode    string   `json:"errorCode,omitempty"`
	Message      string   `json:"message,omitempty"`
	FieldPath    string   `json:"fieldPath,omitempty"`
	Line         int      `json:"line,omitempty"`
	Column       int      `json:"column,omitempty"`
	NextCommands []string `json:"nextCommands,omitempty"`
}

type ReplaySummary struct {
	Enabled           bool `json:"enabled"`
	EventCount        int  `json:"eventCount"`
	StepCount         int  `json:"stepCount"`
	SkippedEventCount int  `json:"skippedEventCount"`
}

type TraceDiscoverOptions struct {
	IncludeActions bool
	Validate       bool
	Force          bool
	Name           string
	AppID          string
}

type TraceDiscover struct {
	OK              bool              `json:"ok"`
	Mode            string            `json:"mode"`
	SchemaVersion   int               `json:"schemaVersion"`
	RunnerVersion   string            `json:"runnerVersion"`
	ProtocolVersion string            `json:"protocolVersion"`
	Out             string            `json:"out"`
	TraceDir        string            `json:"traceDir"`
	SourceSnapshot  string            `json:"sourceSnapshot"`
	Name            string            `json:"name"`
	AppID           string            `json:"appId,omitempty"`
	SelectorCount   int               `json:"selectorCount"`
	StepCount       int               `json:"stepCount"`
	Replay          ReplaySummary     `json:"replay"`
	Warnings        []string          `json:"warnings"`
	Validated       bool              `json:"validated"`
	Validation      *ValidationResult `json:"validation"`
	NextCommands    []string          `json:"nextCommands"`
}

func Start(ctx context.Context, command string, args ...string) (*Client, error) {
	cmd := exec.CommandContext(ctx, command, args...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	return &Client{cmd: cmd, stdin: stdin, lines: scanner, nextID: 1}, nil
}

func (c *Client) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	stdin := c.stdin
	cmd := c.cmd
	c.mu.Unlock()

	_ = stdin.Close()
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
	return cmd.Wait()
}

func (c *Client) Request(ctx context.Context, method string, params interface{}, out interface{}) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return errors.New("zmr client is closed")
	}
	id := c.nextID
	c.nextID++
	request := rpcRequest{JSONRPC: "2.0", ID: id, Method: method, Params: params}
	line, err := json.Marshal(request)
	if err != nil {
		return err
	}
	if _, err := c.stdin.Write(append(line, '\n')); err != nil {
		return err
	}

	type responseResult struct {
		line string
		ok   bool
	}
	responseCh := make(chan responseResult, 1)
	go func() {
		ok := c.lines.Scan()
		responseCh <- responseResult{line: c.lines.Text(), ok: ok}
	}()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case response := <-responseCh:
		if !response.ok {
			if err := c.lines.Err(); err != nil {
				return err
			}
			return io.EOF
		}
		var decoded rpcResponse
		if err := json.Unmarshal([]byte(response.line), &decoded); err != nil {
			return err
		}
		if decoded.ID != id {
			return fmt.Errorf("unexpected JSON-RPC response id %d", decoded.ID)
		}
		if decoded.Error != nil {
			return decoded.Error
		}
		if out == nil {
			return nil
		}
		return json.Unmarshal(decoded.Result, out)
	}
}

func (c *Client) Capabilities(ctx context.Context) (Capabilities, error) {
	var out Capabilities
	err := c.Request(ctx, "runner.capabilities", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) CreateSession(ctx context.Context) (Session, error) {
	var out Session
	err := c.Request(ctx, "session.create", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) CloseSession(ctx context.Context) (bool, error) {
	var out bool
	err := c.Request(ctx, "session.close", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) Devices(ctx context.Context) ([]DeviceInfo, error) {
	var out []DeviceInfo
	err := c.Request(ctx, "device.list", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) Launch(ctx context.Context) (bool, error) {
	var out bool
	err := c.Request(ctx, "app.launch", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) Stop(ctx context.Context) (bool, error) {
	var out bool
	err := c.Request(ctx, "app.stop", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) ClearState(ctx context.Context) (bool, error) {
	var out bool
	err := c.Request(ctx, "app.clearState", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) OpenLink(ctx context.Context, url string) (bool, error) {
	var out bool
	err := c.Request(ctx, "app.openLink", map[string]interface{}{"url": url}, &out)
	return out, err
}

func (c *Client) Snapshot(ctx context.Context) (Snapshot, error) {
	var out Snapshot
	err := c.Request(ctx, "observe.snapshot", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) SemanticSnapshot(ctx context.Context) (SemanticSnapshot, error) {
	var out SemanticSnapshot
	err := c.Request(ctx, "observe.semanticSnapshot", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) Tap(ctx context.Context, selector map[string]interface{}) (bool, error) {
	var out bool
	err := c.Request(ctx, "ui.tap", map[string]interface{}{"selector": selector}, &out)
	return out, err
}

func (c *Client) TypeText(ctx context.Context, text string, selector map[string]interface{}) (bool, error) {
	var out bool
	params := map[string]interface{}{"text": text}
	if selector != nil {
		params["selector"] = selector
	}
	err := c.Request(ctx, "ui.type", params, &out)
	return out, err
}

func (c *Client) EraseText(ctx context.Context, selector map[string]interface{}, maxChars int64) (bool, error) {
	var out bool
	params := map[string]interface{}{}
	if selector != nil {
		params["selector"] = selector
	}
	if maxChars > 0 {
		params["maxChars"] = maxChars
	}
	err := c.Request(ctx, "ui.eraseText", params, &out)
	return out, err
}

func (c *Client) HideKeyboard(ctx context.Context) (bool, error) {
	var out bool
	err := c.Request(ctx, "ui.hideKeyboard", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) Swipe(ctx context.Context, x1 int64, y1 int64, x2 int64, y2 int64, durationMS int64) (bool, error) {
	var out bool
	params := map[string]interface{}{"x1": x1, "y1": y1, "x2": x2, "y2": y2}
	if durationMS > 0 {
		params["durationMs"] = durationMS
	}
	err := c.Request(ctx, "ui.swipe", params, &out)
	return out, err
}

func (c *Client) PressBack(ctx context.Context) (bool, error) {
	var out bool
	err := c.Request(ctx, "ui.pressBack", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) ScrollUntilVisible(ctx context.Context, selector map[string]interface{}, direction string, timeoutMS int64) (bool, error) {
	var out bool
	params := map[string]interface{}{"selector": selector}
	if direction != "" {
		params["direction"] = direction
	}
	if timeoutMS > 0 {
		params["timeoutMs"] = timeoutMS
	}
	err := c.Request(ctx, "ui.scrollUntilVisible", params, &out)
	return out, err
}

func (c *Client) WaitUntil(ctx context.Context, selector map[string]interface{}, timeoutMS int64) (bool, error) {
	var out bool
	params := map[string]interface{}{"visible": selector}
	if timeoutMS > 0 {
		params["timeoutMs"] = timeoutMS
	}
	err := c.Request(ctx, "wait.until", params, &out)
	return out, err
}

func (c *Client) WaitAny(ctx context.Context, selectors []map[string]interface{}, timeoutMS int64) (bool, error) {
	var out bool
	params := map[string]interface{}{"selectors": selectors}
	if timeoutMS > 0 {
		params["timeoutMs"] = timeoutMS
	}
	err := c.Request(ctx, "wait.any", params, &out)
	return out, err
}

func (c *Client) WaitGone(ctx context.Context, selector map[string]interface{}, timeoutMS int64) (bool, error) {
	var out bool
	params := map[string]interface{}{"selector": selector}
	if timeoutMS > 0 {
		params["timeoutMs"] = timeoutMS
	}
	err := c.Request(ctx, "wait.gone", params, &out)
	return out, err
}

func (c *Client) AssertVisible(ctx context.Context, selector map[string]interface{}, timeoutMS int64) (bool, error) {
	var out bool
	params := map[string]interface{}{"selector": selector}
	if timeoutMS > 0 {
		params["timeoutMs"] = timeoutMS
	}
	err := c.Request(ctx, "assert.visible", params, &out)
	return out, err
}

func (c *Client) AssertNotVisible(ctx context.Context, selector map[string]interface{}, timeoutMS int64) (bool, error) {
	var out bool
	params := map[string]interface{}{"selector": selector}
	if timeoutMS > 0 {
		params["timeoutMs"] = timeoutMS
	}
	err := c.Request(ctx, "assert.notVisible", params, &out)
	return out, err
}

func (c *Client) AssertHealthy(ctx context.Context, timeoutMS int64) (bool, error) {
	var out bool
	params := map[string]interface{}{}
	if timeoutMS > 0 {
		params["timeoutMs"] = timeoutMS
	}
	err := c.Request(ctx, "assert.healthy", params, &out)
	return out, err
}

func (c *Client) ValidateScenario(ctx context.Context, path string) (ValidationResult, error) {
	var out ValidationResult
	err := c.Request(ctx, "scenario.validate", map[string]interface{}{"path": path}, &out)
	return out, err
}

func (c *Client) ExportTrace(ctx context.Context, outPath string, redact bool, omitScreenshots bool) (TraceExport, error) {
	var out TraceExport
	err := c.Request(ctx, "trace.export", map[string]interface{}{"out": outPath, "redact": redact, "omitScreenshots": omitScreenshots}, &out)
	return out, err
}

func (c *Client) TraceEvents(ctx context.Context, afterSeq int64, limit int64) (TraceEvents, error) {
	var out TraceEvents
	params := map[string]interface{}{"afterSeq": afterSeq}
	if limit > 0 {
		params["limit"] = limit
	}
	err := c.Request(ctx, "trace.events", params, &out)
	return out, err
}

func (c *Client) ExplainTrace(ctx context.Context) (TraceExplain, error) {
	var out TraceExplain
	err := c.Request(ctx, "trace.explain", map[string]interface{}{}, &out)
	return out, err
}

func (c *Client) DiscoverTrace(ctx context.Context, outPath string, options TraceDiscoverOptions) (TraceDiscover, error) {
	var out TraceDiscover
	params := map[string]interface{}{"out": outPath}
	if options.IncludeActions {
		params["includeActions"] = true
	}
	if options.Validate {
		params["validate"] = true
	}
	if options.Force {
		params["force"] = true
	}
	if options.Name != "" {
		params["name"] = options.Name
	}
	if options.AppID != "" {
		params["appId"] = options.AppID
	}
	err := c.Request(ctx, "trace.discover", params, &out)
	return out, err
}
