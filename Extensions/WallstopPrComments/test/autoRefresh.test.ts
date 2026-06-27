import assert from 'node:assert/strict';
import test from 'node:test';

import { AutoRefreshScheduler } from '../src/autoRefresh';
import type { AutoRefreshConfig } from '../src/autoRefresh';

type IntervalHandle = ReturnType<typeof setInterval>;

function fakeTimers() {
  let nextId = 1;
  const scheduled: Array<{ id: number; handler: () => void; ms: number }> = [];
  const cleared: number[] = [];
  return {
    scheduled,
    cleared,
    setInterval: (handler: () => void, ms: number): IntervalHandle => {
      const id = nextId++;
      scheduled.push({ id, handler, ms });
      return id as unknown as IntervalHandle;
    },
    clearInterval: (handle: IntervalHandle): void => {
      cleared.push(handle as unknown as number);
    },
  };
}

function scheduler(config: AutoRefreshConfig, timers = fakeTimers(), refresh: () => void = () => {}) {
  return {
    timers,
    instance: new AutoRefreshScheduler({
      refresh,
      getConfig: () => config,
      setInterval: timers.setInterval,
      clearInterval: timers.clearInterval,
    }),
  };
}

test('schedules a background refresh at the configured interval when enabled', () => {
  let refreshes = 0;
  const { instance, timers } = scheduler({ enabled: true, intervalMinutes: 5 }, fakeTimers(), () => {
    refreshes += 1;
  });

  instance.reconfigure();

  assert.equal(timers.scheduled.length, 1);
  assert.equal(timers.scheduled[0].ms, 5 * 60_000);
  timers.scheduled[0].handler();
  assert.equal(refreshes, 1, 'the scheduled callback must invoke refresh');
});

test('does not schedule anything when auto-refresh is disabled', () => {
  const { instance, timers } = scheduler({ enabled: false, intervalMinutes: 10 });

  instance.reconfigure();

  assert.equal(timers.scheduled.length, 0);
  assert.equal(timers.cleared.length, 0);
});

test('stops a running timer when reconfigured into the disabled state', () => {
  const config: AutoRefreshConfig = { enabled: true, intervalMinutes: 10 };
  const { instance, timers } = scheduler(config);

  instance.reconfigure();
  config.enabled = false;
  instance.reconfigure();

  assert.deepEqual(timers.cleared, [1], 'the previously running timer must be cleared');
  assert.equal(timers.scheduled.length, 1, 'no new timer is scheduled while disabled');
});

test('clamps sub-minute or invalid intervals to one minute', () => {
  for (const intervalMinutes of [0, -5, Number.NaN]) {
    const { instance, timers } = scheduler({ enabled: true, intervalMinutes });
    instance.reconfigure();
    assert.equal(timers.scheduled[0].ms, 60_000, `interval ${intervalMinutes} must clamp to 60000ms`);
  }
});

test('floors fractional intervals to whole minutes', () => {
  const { instance, timers } = scheduler({ enabled: true, intervalMinutes: 2.9 });

  instance.reconfigure();

  assert.equal(timers.scheduled[0].ms, 2 * 60_000);
});

test('reconfigure replaces the previous timer and dispose stops it', () => {
  const { instance, timers } = scheduler({ enabled: true, intervalMinutes: 3 });

  instance.reconfigure();
  instance.reconfigure();
  instance.dispose();

  assert.deepEqual(timers.cleared, [1, 2], 'each reconfigure/dispose clears the prior timer');
  assert.equal(timers.scheduled.length, 2);
});
