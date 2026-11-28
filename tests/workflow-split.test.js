#!/usr/bin/env node
// Copyright (C) 2026 ZIT STUDIO
// SPDX-License-Identifier: AGPL-3.0-only
//
// Offline guard for the build/release split in build-iso.yml. No network.
//
// The split only pays off if its load-bearing parts stay in place: the ISO is
// handed over as an artifact, the release job verifies what it is about to
// ship, and a second dispatch does not cancel an in-flight release. Merge the
// jobs back and everything still "works" - it just rebuilds for fifteen
// minutes to retry a failed upload - so the structure is asserted here rather
// than left to whoever reads the diff next.

'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const WORKFLOW = path.join(__dirname, '..', '.github', 'workflows', 'build-iso.yml');
const text = fs.readFileSync(WORKFLOW, 'utf8');

// Minimal indentation-aware shim: enough to ask "which job does this line
// belong to" without pulling a YAML parser into the PR gate.
const lines = text.split('\n');

function jobBlock(name) {
  const start = lines.findIndex((l) => l === `  ${name}:`);
  assert.notEqual(start, -1, `workflow has no job "${name}"`);
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    // Next job starts at the same indentation as this one's key.
    if (/^ {2}[a-zA-Z0-9_-]+:$/.test(lines[i])) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join('\n');
}

function stepBlock(job, name) {
  const block = jobBlock(job);
  const start = block.indexOf(`      - name: ${name}`);
  assert.notEqual(start, -1, `job "${job}" has no step "${name}"`);
  const rest = block.slice(start + 1);
  const next = rest.search(/\n {6}- name: /);
  return next === -1 ? rest : rest.slice(0, next);
}

const jobsKeyword = lines.findIndex((l) => l === 'jobs:');
assert.notEqual(jobsKeyword, -1, 'workflow has no jobs: section');

const jobs = lines
  .slice(jobsKeyword + 1)
  .filter((l) => /^ {2}[a-zA-Z0-9_-]+:$/.test(l))
  .map((l) => l.trim().replace(/:$/, ''));

test('build-iso is split into build and release jobs', () => {
  // No separate `meta` job: a retried job does not receive another job's
  // outputs, so each job resolves the version itself (scripts/resolve-meta.sh).
  assert.deepEqual(jobs, ['build', 'release']);
});

test('release depends on build and re-checks the shipped image', () => {
  const release = jobBlock('release');
  assert.match(release, /needs: build/);

  // The gate that used to sit inside the build job has to run where the file
  // actually is now, or split volumes ship unverified.
  assert.match(stepBlock('release', 'Verify artifact'), /verify-artifact\.sh/);
  assert.match(stepBlock('release', 'Split into compressed volumes'), /zip -0 -s/);
  assert.match(stepBlock('release', 'Create draft release'), /draft: true/);
});

test('release does not rebuild the image', () => {
  const release = jobBlock('release');
  assert.doesNotMatch(release, /\.\/build\.sh/);
});

test('no job pays for a disk-cleanup step', () => {
  // free-disk-space reclaimed 33G in 4 minutes on 2026-11-27, but the runner
  // starts with ~85G free and the build peaks around 35G: the space was never
  // needed. Both jobs now just assert the threshold and fail fast instead.
  assert.doesNotMatch(text, /uses: jlumbroso\/free-disk-space@/);

  for (const job of ['build', 'release']) {
    assert.match(jobBlock(job), /Check available disk space/, `${job} has no disk check`);
  }
});

test('build hands the ISO over as an uncompressed artifact', () => {
  const upload = stepBlock('build', 'Upload ISO artifact');
  assert.match(upload, /actions\/upload-artifact@[0-9a-f]{40}/);
  // Re-running the same version must replace the artifact, not fail on a name
  // clash; and re-compressing an already-compressed ISO only burns CPU.
  assert.match(upload, /compression-level: 0/);
  assert.match(upload, /overwrite: true/);

  const download = stepBlock('release', 'Download ISO artifact');
  assert.match(download, /actions\/download-artifact@[0-9a-f]{40}/);
});

test('checksums are generated in the release job, before verification', () => {
  // Two separate bugs live here.
  //
  // 1. Ordering: verify-artifact.sh only checks ${ISO}.sha256 when that file
  //    exists, so a checksum written after verification silently disables the
  //    check (every run logged "skipping external checksum").
  //
  // 2. Ownership: build.sh runs under sudo and creates OUT_DIR itself, so the
  //    directory is root-owned. Generating the checksum in the build job as the
  //    runner user failed with "Permission denied" on 2026-11-27, after a
  //    16-minute build, and the ISO was thrown away. The artifact therefore
  //    carries the ISO alone and the release job - which owns everything it
  //    writes into dist/ - computes both checksums next to it.
  assert.doesNotMatch(jobBlock('build'), /name: Generate checksums/);
  assert.doesNotMatch(stepBlock('build', 'Upload ISO artifact'), /\.sha256/);

  const release = jobBlock('release');
  const checksumAt = release.indexOf('name: Generate checksums');
  const verifyAt = release.indexOf('name: Verify artifact');
  assert.notEqual(checksumAt, -1, 'release job has no checksum step');
  assert.notEqual(verifyAt, -1, 'release job has no verification step');
  assert.ok(checksumAt < verifyAt, 'checksums must be written before verification');

  const checksums = stepBlock('release', 'Generate checksums');
  assert.match(checksums, /sha256sum "\$\{ISO_NAME\}" >"\$\{ISO_NAME\}\.sha256"/);
  // The release body still advertises the md5 as an asset.
  assert.match(checksums, /md5sum "\$\{ISO_NAME\}" >"kzhento-\$\{VERSION\}-amd64\.md5"/);
});

test('the build job hands OUT_DIR back to the runner user', () => {
  // Without this, any later step running as the runner user cannot create a
  // file next to the ISO - including the artifact upload's staging and any
  // check that the build needs to write afterwards.
  const build = stepBlock('build', 'Build ISO');
  assert.match(build, /sudo chown -R "\$\(id -u\):\$\(id -g\)" "\$\{OUT_DIR\}"/);
});

test('a second dispatch queues instead of cancelling a release in flight', () => {
  assert.match(text, /cancel-in-progress: false/);
});

test('no job reads another job\'s outputs', () => {
  // "Re-run failed jobs" re-runs only the failed job and does not inject the
  // outputs of jobs that already succeeded. A release job that took its
  // version from needs.build.outputs would come back with an empty version and
  // build an ISO called "kzhento--amd64.iso". Each job resolves it itself.
  assert.doesNotMatch(text, /needs\.[a-zA-Z0-9_-]+\.outputs/);

  // ...which means both jobs must run the shared resolver.
  for (const job of ['build', 'release']) {
    assert.match(jobBlock(job), /\.\/scripts\/resolve-meta\.sh/, `${job} does not resolve its own meta`);
  }
});

test('SHA256SUMS does not list the zip volume twice', () => {
  // "${ISO_NAME}.z*" also matches ".zip": the glob form used to emit the same
  // zip checksum twice. Only the command matters, not the comment above it.
  const split = stepBlock('release', 'Split into compressed volumes');
  const command = split.split('\n').find((l) => l.includes('sha256sum ') && l.includes('SHA256SUMS'));
  assert.ok(command, 'no sha256sum command writes SHA256SUMS');
  assert.match(command, /"\$\{ISO_NAME\}"\.z0\* "\$\{ISO_NAME\}\.zip"/);
  assert.doesNotMatch(command, /"\$\{ISO_NAME\}"\.z\*/);
});
