declare namespace ZenoPlaywrightReporter {
  interface ZenoPlaywrightReporterOptions {
    outputDir: string;
    projectId: string;
    submitterType: "user" | "automation";
    submitterId: string;
    releaseId: string;
    commitSha: string;
    deploymentId: string;
    environment: string;
    configDigest: string;
    buildManifestDigest?: string;
    buildManifestPath?: string;
    runId?: string;
    artifactRoot?: string;
    browserName?: string;
    browserVersion?: string;
    journeyAnnotation?: string;
    journeyMap?: Readonly<Record<string, string>>;
  }

  interface PlaywrightJourneyKeyInput {
    projectName: string;
    relativeFile: string;
    titlePath: readonly string[];
  }

  interface FullConfig {
    readonly rootDir: string;
    readonly version: string;
    readonly shard: { readonly current: number; readonly total: number } | null;
  }

  interface FullProject {
    readonly name: string;
    readonly metadata?: {
      readonly zenoEvidence?: {
        readonly browserName?: string;
        readonly browserVersion?: string;
      };
    };
  }

  interface Suite {
    project(): FullProject;
  }

  interface TestCase {
    readonly id: string;
    readonly title: string;
    readonly location: { readonly file: string; readonly line: number; readonly column: number };
    readonly expectedStatus: string;
    readonly annotations: readonly { readonly type: string; readonly description?: string }[];
    readonly parent: Suite;
    titlePath(): string[];
    outcome(): string;
  }

  interface TestError {
    readonly message?: string;
    readonly value?: string;
  }

  interface TestResult {
    readonly retry: number;
    readonly status: string;
    readonly startTime: Date;
    readonly duration: number;
    readonly error?: TestError;
    readonly attachments: readonly {
      readonly name: string;
      readonly contentType: string;
      readonly path?: string;
      readonly body?: Buffer;
    }[];
  }

  interface FullResult {
    readonly status: string;
    readonly startTime: Date;
    readonly duration: number;
  }

  function playwrightJourneyKey(input: PlaywrightJourneyKeyInput): string;
}

declare class ZenoPlaywrightReporter {
  constructor(options: ZenoPlaywrightReporter.ZenoPlaywrightReporterOptions);
  printsToStdio(): boolean;
  onBegin(config: ZenoPlaywrightReporter.FullConfig, suite: ZenoPlaywrightReporter.Suite): void;
  onTestEnd(
    test: ZenoPlaywrightReporter.TestCase,
    result: ZenoPlaywrightReporter.TestResult,
  ): void;
  onEnd(
    fullResult: ZenoPlaywrightReporter.FullResult,
  ): Promise<{ status: "failed" } | undefined>;
}

export = ZenoPlaywrightReporter;
