import assert from 'node:assert/strict';
import test from 'node:test';

import { extractExternalFixUrl } from '../src/markdownSuggestions';

test('extracts a Cursor open fix URL from a comment body', () => {
  const body = 'Suggested changeset is available through <a href="https://cursor.com/open?link=abc123">Fix in Cursor</a>.';

  assert.equal(extractExternalFixUrl(body), 'https://cursor.com/open?link=abc123');
});

test('extracts a Cursor agents fix URL', () => {
  const body = 'Apply via https://cursor.com/agents?prompt=fix and review.';

  assert.equal(extractExternalFixUrl(body), 'https://cursor.com/agents?prompt=fix');
});

test('falls back to a GitHub comment permalink when no Cursor link is present', () => {
  const body = 'See the review at https://github.com/org/repo/pull/30#discussion_r12345 for details.';

  assert.equal(extractExternalFixUrl(body), 'https://github.com/org/repo/pull/30#discussion_r12345');
});

test('falls back to a GitHub issuecomment permalink', () => {
  const body = 'See https://github.com/org/repo/pull/30#issuecomment-99887766 for context.';

  assert.equal(extractExternalFixUrl(body), 'https://github.com/org/repo/pull/30#issuecomment-99887766');
});

test('falls back to a GitHub pullrequestreview permalink', () => {
  const body = 'Reviewed at https://github.com/org/repo/pull/30#pullrequestreview-5550042 already.';

  assert.equal(extractExternalFixUrl(body), 'https://github.com/org/repo/pull/30#pullrequestreview-5550042');
});

test('trims trailing sentence punctuation from a fix URL', () => {
  assert.equal(extractExternalFixUrl('Fix: https://cursor.com/open?link=abc.'), 'https://cursor.com/open?link=abc');
  assert.equal(extractExternalFixUrl('Fix at https://cursor.com/open?link=abc, then run.'), 'https://cursor.com/open?link=abc');
  assert.equal(extractExternalFixUrl('Fix at https://cursor.com/open?link=abc; done.'), 'https://cursor.com/open?link=abc');
  assert.equal(
    extractExternalFixUrl('See https://github.com/org/repo/pull/30#discussion_r12345.'),
    'https://github.com/org/repo/pull/30#discussion_r12345',
  );
});

test('strips trailing sentence punctuation but never the slash or alphanumeric tail it follows', () => {
  // The trailing-punctuation trim must be conservative AND active at the same
  // boundary: a slash terminates a legitimate Cursor path and an alphanumeric is
  // part of the link token, so neither may be eaten, yet a sentence period glued
  // *after* a path slash must still be removed. This case pins the trim's
  // character class to sentence punctuation only — the `.` is dropped while the
  // preceding `/` survives. A no-op trim leaves the dangling `.`; a broader trim
  // would corrupt the slash. Only the [.,;:!?]-anchored, end-of-URL trim is correct.
  assert.equal(
    extractExternalFixUrl('Open https://cursor.com/open?link=abc/.'),
    'https://cursor.com/open?link=abc/',
  );
  assert.equal(
    extractExternalFixUrl('Open https://cursor.com/open?link=abc/'),
    'https://cursor.com/open?link=abc/',
  );
  assert.equal(
    extractExternalFixUrl('Apply https://cursor.com/open?link=abc123 now'),
    'https://cursor.com/open?link=abc123',
  );
});

test('keeps dots inside a fix URL and only strips the trailing punctuation run', () => {
  // Interior dots (e.g. a dotted link token) belong to the URL; only a run of
  // sentence punctuation anchored at the very end is removed.
  assert.equal(
    extractExternalFixUrl('Open https://cursor.com/open?link=a.b.c and go'),
    'https://cursor.com/open?link=a.b.c',
  );
  assert.equal(
    extractExternalFixUrl('Really?? https://cursor.com/open?link=abc?!.'),
    'https://cursor.com/open?link=abc',
  );
});

test('prefers the Cursor link over a GitHub permalink when both are present', () => {
  const body = [
    'https://github.com/org/repo/pull/30#discussion_r12345',
    'https://cursor.com/open?link=xyz',
  ].join(' ');

  assert.equal(extractExternalFixUrl(body), 'https://cursor.com/open?link=xyz');
});

test('returns undefined for an undefined, empty, or link-free body', () => {
  assert.equal(extractExternalFixUrl(undefined), undefined);
  assert.equal(extractExternalFixUrl(''), undefined);
  assert.equal(extractExternalFixUrl('Just prose with no actionable URL.'), undefined);
});
