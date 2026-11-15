import 'dart:async';
import 'dart:collection';

import 'errors.dart';

enum CmdPriority { high, normal, low }

class _Job {
  _Job(this.body, this.priority, this.idempotent, this.dedupeKey, this.timeout, this.retries, this.expiresAt, this.epoch);
  final Map<String, dynamic> body;
  final CmdPriority priority;
  final bool idempotent;
  final String? dedupeKey;
  final Duration timeout;
  final int retries;
  final DateTime expiresAt;
  final int epoch;
  final Completer<Map<String, dynamic>> done = Completer();
  bool cancelled = false;
}

typedef CommandExec = Future<Map<String, dynamic>> Function(Map<String, dynamic> body, Duration timeout);

/// Runs commands one at a time, in priority order, with these rules:
///  - every command gets a request id (the board de-duplicates by it, so a retry after a lost reply never runs twice)
///  - a retry happens only when it is safe: the command is idempotent, or it provably never reached the board (connection refused / unreachable)
///  - a newer command with the same [dedupeKey] replaces a still-waiting older one (slider drags, "next" taps)
///  - commands wait at most [maxWait]; after that they fail as stale instead of firing late
///  - [bumpEpoch] (new connection / device switched) discards everything that was waiting for the old one
///  - responses are validated: the board must answer with ok:true, else the board's own error is raised
class CommandQueue {
  CommandQueue(this._exec, {this.maxWait = const Duration(seconds: 12), this.onResult, this.boardDedupes});
  final CommandExec _exec;
  final Duration maxWait;

  /// Called with the outcome of every command (feeds the connection health).
  final void Function(bool ok, Object? error)? onResult;

  /// True when the board remembers request ids (API v1): then even a command whose reply was lost can be retried safely.
  final bool Function()? boardDedupes;

  final Queue<_Job> _pending = Queue();
  bool _running = false;
  int _epoch = 0;
  int get epoch => _epoch;
  int get length => _pending.length;

  Future<Map<String, dynamic>> submit(
    Map<String, dynamic> body, {
    CmdPriority priority = CmdPriority.normal,
    bool idempotent = false,
    String? dedupeKey,
    Duration timeout = const Duration(seconds: 8),
    int retries = 1,
    Duration? maxWaitOverride,
  }) {
    final job = _Job({...body}, priority, idempotent, dedupeKey, timeout, retries, DateTime.now().add(maxWaitOverride ?? maxWait), _epoch);
    if (dedupeKey != null) {
      for (final j in _pending.where((j) => j.dedupeKey == dedupeKey && !j.cancelled)) {
        j.cancelled = true;
        // the replaced caller gets the newer command's result
        job.done.future.then((v) => j.done.isCompleted ? null : j.done.complete(v), onError: (Object e) => j.done.isCompleted ? null : j.done.completeError(e));
      }
    }
    // insert by priority, FIFO inside one priority
    final list = _pending.toList();
    var idx = list.length;
    for (var i = 0; i < list.length; i++) {
      if (list[i].priority.index > priority.index) {
        idx = i;
        break;
      }
    }
    list.insert(idx, job);
    _pending
      ..clear()
      ..addAll(list);
    _pump();
    return job.done.future;
  }

  /// Fails everything that is waiting. Used when the connection is replaced.
  void bumpEpoch([HubError why = HubError.cancelled]) {
    _epoch++;
    for (final j in _pending) {
      if (!j.done.isCompleted) j.done.completeError(HubException(why));
    }
    _pending.clear();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final job = _pending.removeFirst();
        if (job.cancelled || job.done.isCompleted) continue;
        if (job.epoch != _epoch) {
          job.done.completeError(HubException(HubError.cancelled));
          continue;
        }
        if (DateTime.now().isAfter(job.expiresAt)) {
          job.done.completeError(HubException(HubError.stale));
          continue;
        }
        await _run(job);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _run(_Job job) async {
    var attempt = 0;
    while (true) {
      try {
        final r = await _exec(job.body, job.timeout);
        if (r['ok'] != true && r['success'] != true) {
          // the board answered, so the link is fine: this is a refusal, not a connection problem
          onResult?.call(true, null);
          job.done.completeError(HubException(HubError.deviceError, '${r['error'] ?? 'device error'}', '${r['errorCode'] ?? ''}'));
        } else {
          onResult?.call(true, null);
          job.done.complete(r);
        }
        return;
      } catch (e) {
        final h = toHubException(e);
        final neverSent = h.kind == HubError.refused || h.kind == HubError.unreachable;
        final lost = h.kind == HubError.timeout;
        final canRetry = attempt < job.retries && job.epoch == _epoch && !job.cancelled && DateTime.now().isBefore(job.expiresAt) && (neverSent || (lost && (job.idempotent || (boardDedupes?.call() ?? false))));
        if (h.kind != HubError.auth && h.kind != HubError.rateLimited && h.kind != HubError.wrongDevice) onResult?.call(false, h);
        if (!canRetry) {
          job.done.completeError(h);
          return;
        }
        attempt++;
        await Future.delayed(Duration(milliseconds: 250 * attempt));
      }
    }
  }
}
