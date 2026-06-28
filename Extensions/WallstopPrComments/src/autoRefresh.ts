export interface AutoRefreshConfig {
  enabled: boolean;
  intervalMinutes: number;
}

type IntervalHandle = ReturnType<typeof setInterval>;

export interface AutoRefreshSchedulerDeps {
  /** Invoked on each tick; typically refreshes the tree's pull-request caches. */
  refresh: () => void;
  /** Reads the current configuration (enabled flag + interval). */
  getConfig: () => AutoRefreshConfig;
  setInterval: (handler: () => void, ms: number) => IntervalHandle;
  clearInterval: (handle: IntervalHandle) => void;
}

const MILLISECONDS_PER_MINUTE = 60_000;

/**
 * Drives the opt-out background auto-refresh. {@link reconfigure} is idempotent: it always tears
 * down any running timer first, then arms a new one only when the config is enabled. The interval
 * is floored to whole minutes and clamped to a 1-minute floor so a misconfigured value can never
 * schedule a tight, API-hammering loop. Timers are injected so the behaviour is unit-testable
 * without real clocks.
 */
export class AutoRefreshScheduler {
  private handle: IntervalHandle | undefined;

  constructor(private readonly deps: AutoRefreshSchedulerDeps) {}

  reconfigure(): void {
    this.stop();

    const config = this.deps.getConfig();
    if (!config.enabled) {
      return;
    }

    const minutes = Number.isFinite(config.intervalMinutes) ? Math.max(1, Math.floor(config.intervalMinutes)) : 1;
    this.handle = this.deps.setInterval(() => this.deps.refresh(), minutes * MILLISECONDS_PER_MINUTE);
  }

  stop(): void {
    if (this.handle !== undefined) {
      this.deps.clearInterval(this.handle);
      this.handle = undefined;
    }
  }

  dispose(): void {
    this.stop();
  }
}
