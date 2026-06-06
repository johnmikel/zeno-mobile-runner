use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fmt;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    Json(serde_json::Error),
    Rpc(RpcError),
    UnexpectedResponseId(i64),
    MissingPipe(&'static str),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Io(err) => write!(f, "{err}"),
            Error::Json(err) => write!(f, "{err}"),
            Error::Rpc(err) => write!(f, "{err}"),
            Error::UnexpectedResponseId(id) => write!(f, "unexpected JSON-RPC response id {id}"),
            Error::MissingPipe(name) => write!(f, "missing child process {name} pipe"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(value: std::io::Error) -> Self {
        Error::Io(value)
    }
}

impl From<serde_json::Error> for Error {
    fn from(value: serde_json::Error) -> Self {
        Error::Json(value)
    }
}

#[derive(Debug, Deserialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    #[serde(rename = "publicCode")]
    pub public_code: Option<String>,
    pub data: Option<Value>,
}

impl fmt::Display for RpcError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for RpcError {}

#[derive(Debug, Deserialize)]
struct RpcResponse {
    id: i64,
    result: Option<Value>,
    error: Option<RpcError>,
}

pub struct Client {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    next_id: i64,
}

#[derive(Debug, Deserialize)]
pub struct Capabilities {
    pub name: String,
    pub version: String,
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    pub platforms: Vec<String>,
    #[serde(rename = "platformSupport", default)]
    pub platform_support: HashMap<String, PlatformSupport>,
    #[serde(rename = "iosPreview", default)]
    pub ios_preview: bool,
    pub transports: Vec<String>,
    pub methods: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct PlatformSupport {
    pub status: String,
    #[serde(rename = "deviceTypes")]
    pub device_types: Vec<String>,
    pub automation: Vec<String>,
    #[serde(rename = "physicalDevices", default)]
    pub physical_devices: bool,
}

#[derive(Debug, Deserialize)]
pub struct Session {
    #[serde(rename = "sessionId")]
    pub session_id: String,
}

#[derive(Debug, Deserialize)]
pub struct DeviceInfo {
    pub serial: String,
    pub state: String,
    pub ready: bool,
}

#[derive(Debug, Deserialize)]
pub struct Snapshot {
    pub id: String,
    #[serde(rename = "timestampMs")]
    pub timestamp_ms: i64,
    pub viewport: Value,
    #[serde(rename = "activePackage")]
    pub active_package: String,
    #[serde(rename = "activeActivity")]
    pub active_activity: Option<String>,
    pub nodes: Vec<Node>,
}

#[derive(Debug, Deserialize)]
pub struct Node {
    #[serde(rename = "stableId")]
    pub stable_id: String,
    #[serde(rename = "className")]
    pub class_name: String,
    #[serde(default, rename = "resourceId")]
    pub resource_id: Option<String>,
    pub text: Option<String>,
    #[serde(rename = "contentDesc")]
    pub content_desc: Option<String>,
    pub bounds: Value,
    pub enabled: bool,
    pub visible: bool,
    pub selected: bool,
}

#[derive(Debug, Deserialize)]
pub struct SemanticSnapshot {
    pub id: String,
    #[serde(rename = "timestampMs")]
    pub timestamp_ms: i64,
    pub viewport: Value,
    #[serde(rename = "activePackage")]
    pub active_package: Option<String>,
    #[serde(rename = "activeActivity")]
    pub active_activity: Option<String>,
    #[serde(rename = "focusedNodeId")]
    pub focused_node_id: Option<String>,
    pub nodes: Vec<SemanticNode>,
    pub summary: SemanticSummary,
}

#[derive(Debug, Deserialize)]
pub struct SemanticSummary {
    #[serde(rename = "nodeCount")]
    pub node_count: usize,
    #[serde(rename = "interactiveCount")]
    pub interactive_count: usize,
    #[serde(rename = "visibleText")]
    pub visible_text: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct SemanticNode {
    pub id: String,
    pub role: String,
    pub name: String,
    pub selector: Value,
    pub source: Value,
    pub bounds: Value,
    pub enabled: bool,
    pub visible: bool,
    pub selected: bool,
    pub interactive: bool,
    #[serde(rename = "recommendedAction")]
    pub recommended_action: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TraceExport {
    #[serde(rename = "traceDir")]
    pub trace_dir: String,
    pub out: String,
    pub redacted: bool,
    #[serde(rename = "omitScreenshots")]
    pub omit_screenshots: bool,
}

#[derive(Debug, Deserialize)]
pub struct TraceEvents {
    #[serde(rename = "traceDir")]
    pub trace_dir: String,
    #[serde(rename = "afterSeq")]
    pub after_seq: i64,
    #[serde(rename = "nextSeq")]
    pub next_seq: i64,
    #[serde(rename = "latestSeq")]
    pub latest_seq: i64,
    pub events: Vec<Value>,
}

#[derive(Debug, Deserialize)]
pub struct TraceDiagnostic {
    pub kind: String,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default, rename = "snapshotId")]
    pub snapshot_id: Option<String>,
    #[serde(default, rename = "artifactStatus")]
    pub artifact_status: Option<String>,
    #[serde(default, rename = "semanticStatus")]
    pub semantic_status: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default, rename = "screenshotArtifact")]
    pub screenshot_artifact: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default, rename = "activePackage")]
    pub active_package: Option<String>,
    #[serde(default, rename = "activeActivity")]
    pub active_activity: Option<String>,
    #[serde(default, rename = "visibleTexts")]
    pub visible_texts: Vec<String>,
    #[serde(default, rename = "nearestTextMatches")]
    pub nearest_text_matches: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct TraceExplain {
    pub ok: bool,
    #[serde(rename = "traceDir")]
    pub trace_dir: String,
    pub scenario: String,
    pub status: String,
    #[serde(default, rename = "appId")]
    pub app_id: Option<String>,
    #[serde(default, rename = "durationMs")]
    pub duration_ms: Option<i64>,
    #[serde(default, rename = "eventCount")]
    pub event_count: Option<i64>,
    #[serde(default, rename = "snapshotCount")]
    pub snapshot_count: Option<i64>,
    #[serde(default, rename = "partialFailureCount")]
    pub partial_failure_count: Option<i64>,
    #[serde(default, rename = "failedStepIndex")]
    pub failed_step_index: Option<i64>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub diagnostic: Option<TraceDiagnostic>,
    #[serde(default, rename = "partialFailure")]
    pub partial_failure: Option<TraceDiagnostic>,
    #[serde(default, rename = "lastEvent")]
    pub last_event: Option<String>,
    #[serde(default, rename = "nextCommands")]
    pub next_commands: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct ValidationResult {
    pub ok: bool,
    pub path: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default, rename = "appId")]
    pub app_id: Option<String>,
    #[serde(default, rename = "stepCount")]
    pub step_count: i64,
    #[serde(default, rename = "errorCode")]
    pub error_code: Option<String>,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default, rename = "fieldPath")]
    pub field_path: Option<String>,
    #[serde(default)]
    pub line: Option<i64>,
    #[serde(default)]
    pub column: Option<i64>,
    #[serde(default, rename = "nextCommands")]
    pub next_commands: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct ReplaySummary {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default, rename = "eventCount")]
    pub event_count: i64,
    #[serde(default, rename = "stepCount")]
    pub step_count: i64,
    #[serde(default, rename = "skippedEventCount")]
    pub skipped_event_count: i64,
}

#[derive(Debug, Default)]
pub struct TraceDiscoverOptions {
    pub include_actions: bool,
    pub validate: bool,
    pub force: bool,
    pub name: Option<String>,
    pub app_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TraceDiscover {
    pub ok: bool,
    pub mode: String,
    #[serde(rename = "schemaVersion")]
    pub schema_version: i64,
    #[serde(rename = "runnerVersion")]
    pub runner_version: String,
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    pub out: String,
    #[serde(rename = "traceDir")]
    pub trace_dir: String,
    #[serde(rename = "sourceSnapshot")]
    pub source_snapshot: String,
    pub name: String,
    #[serde(default, rename = "appId")]
    pub app_id: Option<String>,
    #[serde(rename = "selectorCount")]
    pub selector_count: i64,
    #[serde(rename = "stepCount")]
    pub step_count: i64,
    pub replay: ReplaySummary,
    #[serde(default)]
    pub warnings: Vec<String>,
    #[serde(default)]
    pub validated: bool,
    #[serde(default)]
    pub validation: Option<ValidationResult>,
    #[serde(default, rename = "nextCommands")]
    pub next_commands: Vec<String>,
}

impl Client {
    pub fn start<I, S>(command: &str, args: I) -> Result<Self, Error>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        let mut child = Command::new(command)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()?;
        let stdin = child.stdin.take().ok_or(Error::MissingPipe("stdin"))?;
        let stdout = child.stdout.take().ok_or(Error::MissingPipe("stdout"))?;
        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
            next_id: 1,
        })
    }

    pub fn request<T: for<'de> Deserialize<'de>>(
        &mut self,
        method: &str,
        params: Value,
    ) -> Result<T, Error> {
        let id = self.next_id;
        self.next_id += 1;
        let request = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        writeln!(self.stdin, "{}", serde_json::to_string(&request)?)?;
        self.stdin.flush()?;

        let mut line = String::new();
        self.stdout.read_line(&mut line)?;
        let response: RpcResponse = serde_json::from_str(&line)?;
        if response.id != id {
            return Err(Error::UnexpectedResponseId(response.id));
        }
        if let Some(error) = response.error {
            return Err(Error::Rpc(error));
        }
        let result = response.result.unwrap_or(Value::Null);
        Ok(serde_json::from_value(result)?)
    }

    pub fn capabilities(&mut self) -> Result<Capabilities, Error> {
        self.request("runner.capabilities", json!({}))
    }

    pub fn create_session(&mut self) -> Result<Session, Error> {
        self.request("session.create", json!({}))
    }

    pub fn close_session(&mut self) -> Result<bool, Error> {
        self.request("session.close", json!({}))
    }

    pub fn devices(&mut self) -> Result<Vec<DeviceInfo>, Error> {
        self.request("device.list", json!({}))
    }

    pub fn launch(&mut self) -> Result<bool, Error> {
        self.request("app.launch", json!({}))
    }

    pub fn stop(&mut self) -> Result<bool, Error> {
        self.request("app.stop", json!({}))
    }

    pub fn clear_state(&mut self) -> Result<bool, Error> {
        self.request("app.clearState", json!({}))
    }

    pub fn open_link(&mut self, url: &str) -> Result<bool, Error> {
        self.request("app.openLink", json!({ "url": url }))
    }

    pub fn snapshot(&mut self) -> Result<Snapshot, Error> {
        self.request("observe.snapshot", json!({}))
    }

    pub fn semantic_snapshot(&mut self) -> Result<SemanticSnapshot, Error> {
        self.request("observe.semanticSnapshot", json!({}))
    }

    pub fn tap(&mut self, selector: Value) -> Result<bool, Error> {
        self.request("ui.tap", json!({ "selector": selector }))
    }

    pub fn type_text(&mut self, text: &str, selector: Option<Value>) -> Result<bool, Error> {
        let mut params = json!({ "text": text });
        if let Some(selector) = selector {
            params["selector"] = selector;
        }
        self.request("ui.type", params)
    }

    pub fn erase_text(
        &mut self,
        selector: Option<Value>,
        max_chars: Option<i64>,
    ) -> Result<bool, Error> {
        let mut params = json!({});
        if let Some(selector) = selector {
            params["selector"] = selector;
        }
        if let Some(max_chars) = max_chars {
            params["maxChars"] = json!(max_chars);
        }
        self.request("ui.eraseText", params)
    }

    pub fn hide_keyboard(&mut self) -> Result<bool, Error> {
        self.request("ui.hideKeyboard", json!({}))
    }

    pub fn swipe(
        &mut self,
        x1: i64,
        y1: i64,
        x2: i64,
        y2: i64,
        duration_ms: Option<i64>,
    ) -> Result<bool, Error> {
        let mut params = json!({ "x1": x1, "y1": y1, "x2": x2, "y2": y2 });
        if let Some(duration_ms) = duration_ms {
            params["durationMs"] = json!(duration_ms);
        }
        self.request("ui.swipe", params)
    }

    pub fn press_back(&mut self) -> Result<bool, Error> {
        self.request("ui.pressBack", json!({}))
    }

    pub fn scroll_until_visible(
        &mut self,
        selector: Value,
        direction: Option<&str>,
        timeout_ms: Option<i64>,
    ) -> Result<bool, Error> {
        let mut params = json!({ "selector": selector });
        if let Some(direction) = direction {
            params["direction"] = json!(direction);
        }
        if let Some(timeout_ms) = timeout_ms {
            params["timeoutMs"] = json!(timeout_ms);
        }
        self.request("ui.scrollUntilVisible", params)
    }

    pub fn wait_until(&mut self, selector: Value, timeout_ms: Option<i64>) -> Result<bool, Error> {
        let mut params = json!({ "visible": selector });
        if let Some(timeout_ms) = timeout_ms {
            params["timeoutMs"] = json!(timeout_ms);
        }
        self.request("wait.until", params)
    }

    pub fn wait_any(
        &mut self,
        selectors: Vec<Value>,
        timeout_ms: Option<i64>,
    ) -> Result<bool, Error> {
        let mut params = json!({ "selectors": selectors });
        if let Some(timeout_ms) = timeout_ms {
            params["timeoutMs"] = json!(timeout_ms);
        }
        self.request("wait.any", params)
    }

    pub fn wait_gone(&mut self, selector: Value, timeout_ms: Option<i64>) -> Result<bool, Error> {
        let mut params = json!({ "selector": selector });
        if let Some(timeout_ms) = timeout_ms {
            params["timeoutMs"] = json!(timeout_ms);
        }
        self.request("wait.gone", params)
    }

    pub fn assert_visible(
        &mut self,
        selector: Value,
        timeout_ms: Option<i64>,
    ) -> Result<bool, Error> {
        let mut params = json!({ "selector": selector });
        if let Some(timeout_ms) = timeout_ms {
            params["timeoutMs"] = json!(timeout_ms);
        }
        self.request("assert.visible", params)
    }

    pub fn assert_not_visible(
        &mut self,
        selector: Value,
        timeout_ms: Option<i64>,
    ) -> Result<bool, Error> {
        let mut params = json!({ "selector": selector });
        if let Some(timeout_ms) = timeout_ms {
            params["timeoutMs"] = json!(timeout_ms);
        }
        self.request("assert.notVisible", params)
    }

    pub fn assert_healthy(&mut self, timeout_ms: Option<i64>) -> Result<bool, Error> {
        let mut params = json!({});
        if let Some(timeout_ms) = timeout_ms {
            params["timeoutMs"] = json!(timeout_ms);
        }
        self.request("assert.healthy", params)
    }

    pub fn validate_scenario(&mut self, path: &str) -> Result<ValidationResult, Error> {
        self.request("scenario.validate", json!({ "path": path }))
    }

    pub fn export_trace(
        &mut self,
        out: &str,
        redact: bool,
        omit_screenshots: bool,
    ) -> Result<TraceExport, Error> {
        self.request(
            "trace.export",
            json!({ "out": out, "redact": redact, "omitScreenshots": omit_screenshots }),
        )
    }

    pub fn trace_events(
        &mut self,
        after_seq: i64,
        limit: Option<i64>,
    ) -> Result<TraceEvents, Error> {
        let mut params = json!({ "afterSeq": after_seq });
        if let Some(limit) = limit {
            params["limit"] = json!(limit);
        }
        self.request("trace.events", params)
    }

    pub fn explain_trace(&mut self) -> Result<TraceExplain, Error> {
        self.request("trace.explain", json!({}))
    }

    pub fn discover_trace(
        &mut self,
        out: &str,
        options: TraceDiscoverOptions,
    ) -> Result<TraceDiscover, Error> {
        let mut params = json!({ "out": out });
        if options.include_actions {
            params["includeActions"] = json!(true);
        }
        if options.validate {
            params["validate"] = json!(true);
        }
        if options.force {
            params["force"] = json!(true);
        }
        if let Some(name) = options.name {
            params["name"] = json!(name);
        }
        if let Some(app_id) = options.app_id {
            params["appId"] = json!(app_id);
        }
        self.request("trace.discover", params)
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[derive(Debug, Serialize)]
pub struct Selector {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "resourceId")]
    pub resource_id: Option<String>,
}
