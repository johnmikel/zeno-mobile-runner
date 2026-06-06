export interface ZmrClientOptions {
  command: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string | undefined>;
  stderr?: "inherit" | "ignore" | "pipe";
}

export interface Selector {
  id?: string;
  resourceId?: string;
  text?: string;
  textContains?: string;
  contentDesc?: string;
  contentDescContains?: string;
  className?: string;
}

export interface Viewport {
  width: number;
  height: number;
}

export interface UiNode {
  stableId: string;
  className: string;
  resourceId?: string | null;
  text?: string | null;
  contentDesc?: string | null;
  bounds: { x: number; y: number; width: number; height: number };
  enabled: boolean;
  visible: boolean;
  selected: boolean;
}

export interface ObservationSnapshot {
  id: string;
  timestampMs: number;
  viewport: Viewport;
  displayDensityDpi?: number | null;
  activePackage?: string | null;
  activeActivity?: string | null;
  screenshotArtifact?: string | null;
  treeArtifact?: string | null;
  focusedNodeId?: string | null;
  logDelta?: string | null;
  nodes: UiNode[];
}

export interface SemanticNode {
  id: string;
  role: "button" | "textbox" | "switch" | "checkbox" | "radio" | "image" | "text" | "node" | string;
  name: string;
  selector: Record<string, string>;
  source: {
    className: string;
    resourceId?: string | null;
    text?: string | null;
    contentDesc?: string | null;
  };
  bounds: { x: number; y: number; width: number; height: number; centerX: number; centerY: number };
  enabled: boolean;
  visible: boolean;
  selected: boolean;
  interactive: boolean;
  recommendedAction?: "tap" | "type" | null | string;
}

export interface SemanticSnapshot {
  id: string;
  timestampMs: number;
  viewport: Viewport;
  activePackage?: string | null;
  activeActivity?: string | null;
  focusedNodeId?: string | null;
  nodes: SemanticNode[];
  summary: {
    nodeCount: number;
    interactiveCount: number;
    visibleText: string[];
  };
}

export interface PlatformSupport {
  status: "supported" | "preview" | "unsupported" | string;
  deviceTypes: string[];
  automation: string[];
  physicalDevices?: boolean;
}

export interface Capabilities {
  name: string;
  version: string;
  protocolVersion: string;
  platforms: string[];
  platformSupport?: Record<string, PlatformSupport>;
  iosPreview?: boolean;
  transports: string[];
  methods: string[];
}

export interface TraceDiscoverOptions {
  includeActions?: boolean;
  validate?: boolean;
  force?: boolean;
  name?: string;
  appId?: string;
}

export interface DeviceInfo {
  serial: string;
  state: string;
  ready: boolean;
}

export interface ZmrClient {
  request<T = unknown>(method: string, params?: Record<string, unknown>): Promise<T>;
  capabilities(): Promise<Capabilities>;
  createSession(): Promise<{ sessionId: string }>;
  closeSession(): Promise<boolean>;
  devices(): Promise<DeviceInfo[]>;
  launch(): Promise<boolean>;
  stop(): Promise<boolean>;
  clearState(): Promise<boolean>;
  openLink(url: string): Promise<boolean>;
  snapshot(): Promise<ObservationSnapshot>;
  semanticSnapshot(): Promise<SemanticSnapshot>;
  tap(selector: Selector): Promise<boolean>;
  typeText(text: string, options?: { selector?: Selector }): Promise<boolean>;
  eraseText(options?: { selector?: Selector; maxChars?: number }): Promise<boolean>;
  hideKeyboard(): Promise<boolean>;
  swipe(input: { x1: number; y1: number; x2: number; y2: number; durationMs?: number }): Promise<boolean>;
  pressBack(): Promise<boolean>;
  scrollUntilVisible(selector: Selector, options?: { direction?: "up" | "down"; timeoutMs?: number }): Promise<boolean>;
  waitUntil(selector: Selector, options?: { timeoutMs?: number }): Promise<boolean>;
  waitAny(selectors: Selector[], options?: { timeoutMs?: number }): Promise<{ matchedIndex: number } | false>;
  waitGone(selector: Selector, options?: { timeoutMs?: number }): Promise<boolean>;
  assertVisible(selector: Selector, options?: { timeoutMs?: number }): Promise<boolean>;
  assertNotVisible(selector: Selector, options?: { timeoutMs?: number }): Promise<boolean>;
  assertHealthy(options?: { timeoutMs?: number }): Promise<boolean>;
  validateScenario(path: string): Promise<Record<string, unknown>>;
  exportTrace(out: string, options?: { redact?: boolean; omitScreenshots?: boolean }): Promise<Record<string, unknown>>;
  traceEvents(afterSeq?: number, options?: { limit?: number }): Promise<Record<string, unknown>>;
  explainTrace(): Promise<Record<string, unknown>>;
  discoverTrace(out: string, options?: TraceDiscoverOptions): Promise<Record<string, unknown>>;
  exploreTrace(out: string, goal: string, options?: TraceDiscoverOptions): Promise<Record<string, unknown>>;
  close(): Promise<void>;
}

export class ZmrRpcError extends Error {
  code?: number;
  publicCode?: string;
  data?: unknown;
}

export function createZmrClient(options: ZmrClientOptions): ZmrClient;
