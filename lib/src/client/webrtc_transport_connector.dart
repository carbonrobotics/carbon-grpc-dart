// Copyright (c) 2024, the gRPC project authors. Please see the AUTHORS file
// for details. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http2/transport.dart';
import 'package:meta/meta.dart';

import 'client_transport_connector.dart';
import 'webrtc_transport_stats.dart';

/// A transport connector that uses WebRTC DataChannel as the underlying
/// transport for HTTP/2 connections.
///
/// This allows gRPC to run over WebRTC by using the existing HTTP/2
/// infrastructure but routing the bytes through a WebRTC DataChannel
/// instead of a TCP socket.
class WebRTCTransportConnector implements ClientTransportConnector {
  final RTCDataChannel _dataChannel;
  final String _authority;
  final WebRTCTransportStats? _stats;
  final Completer<void> _doneCompleter = Completer<void>();
  bool _isShutdown = false;

  /// Creates a WebRTC transport connector.
  ///
  /// [dataChannel] - The WebRTC DataChannel to use as transport
  /// [authority] - The authority string for the gRPC service
  /// [stats] - Optional counters describing transport behaviour
  WebRTCTransportConnector(
    this._dataChannel,
    this._authority, {
    WebRTCTransportStats? stats,
  }) : _stats = stats {
    // Listen for DataChannel closure
    _dataChannel.onDataChannelState = (RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed &&
          !_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    };
  }

  @override
  String get authority => _authority;

  @override
  Future get done => _doneCompleter.future;

  @override
  Future<ClientTransportConnection> connect() async {
    if (_isShutdown) {
      throw StateError('Transport connector has been shut down');
    }

    if (_dataChannel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('WebRTC DataChannel is not open');
    }

    // Create streams that bridge WebRTC DataChannel to HTTP/2
    final incomingController = StreamController<List<int>>();
    final outgoingSink = WebRTCStreamSink(_dataChannel, stats: _stats);
    final sinceConnect = Stopwatch()..start();

    // Set up incoming data forwarding
    _dataChannel.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary && !incomingController.isClosed) {
        _stats?.timeToFirstMessage ??= sinceConnect.elapsed;
        _stats?.recordReceive(message.binary.length);
        incomingController.add(message.binary.toList());
      }
    };

    // Clean up when stream is closed
    incomingController.onCancel = () {
      // Close the outgoing sink when the incoming stream is cancelled
      outgoingSink.close();
    };

    // Create the HTTP/2 transport connection
    return ClientTransportConnection.viaStreams(
      incomingController.stream,
      outgoingSink,
      settings: const ClientSettings(concurrentStreamLimit: 100),
    );
  }

  @override
  void shutdown() {
    if (_isShutdown) return;
    _isShutdown = true;

    _dataChannel.close();

    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}

/// A StreamSink that forwards data to a WebRTC DataChannel, applying
/// backpressure against the channel's native send buffer.
///
/// SCTP data channels have a bounded send buffer (libwebrtc hard-closes the
/// channel if it ever exceeds ~16 MiB), and `bufferedAmount` is the only
/// signal of how full it is. Writes are therefore queued and pumped to the
/// channel one at a time, pausing whenever `bufferedAmount` exceeds
/// [highWaterMark] until the channel reports it drained below
/// [lowWaterMark] (or a poll interval elapses, for platforms where the
/// buffered-amount-low event is unreliable).
///
/// Note that `bufferedAmount` is only trustworthy on web. `flutter_webrtc`'s
/// native implementation caches it and refreshes the cache from an
/// asynchronous platform event, so on iOS/Android it lags reality — and
/// `send()` there cannot report failure at all, because the darwin plugin
/// discards `sendData:`'s return value. [WebRTCTransportStats] measures both
/// gaps; see [_sampleBufferedAmounts].
@visibleForTesting
class WebRTCStreamSink implements StreamSink<List<int>> {
  /// Pause the pump while the channel buffers more than this many bytes.
  @visibleForTesting
  static const highWaterMark = 1 << 20; // 1 MiB

  /// Resume the pump once the channel buffer drains below this.
  @visibleForTesting
  static const lowWaterMark = 256 << 10; // 256 KiB

  /// Fallback poll interval while waiting for the buffer to drain.
  static const _drainPollInterval = Duration(milliseconds: 100);

  /// How often the pump compares the cached buffered amount to the live one.
  /// Throttled because the comparison costs a platform round trip on native.
  static const _bufferedAmountSampleInterval = Duration(milliseconds: 500);

  final RTCDataChannel _dataChannel;
  final WebRTCTransportStats? _stats;
  final Queue<Uint8List> _queue = Queue<Uint8List>();
  final Completer<void> _doneCompleter = Completer<void>();
  final Stopwatch _sampleClock = Stopwatch();
  Completer<void>? _bufferedAmountLow;
  bool _isClosed = false;
  bool _pumping = false;

  WebRTCStreamSink(this._dataChannel, {WebRTCTransportStats? stats})
    : _stats = stats {
    _dataChannel.bufferedAmountLowThreshold = lowWaterMark;
    _dataChannel.onBufferedAmountLow = (_) {
      _bufferedAmountLow?.complete();
      _bufferedAmountLow = null;
    };
  }

  @override
  void add(List<int> data) {
    if (_isClosed) {
      throw StateError('StreamSink is closed');
    }
    if (_dataChannel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('WebRTC DataChannel is not open');
    }
    _queue.add(data is Uint8List ? data : Uint8List.fromList(data));
    _stats?.recordQueueDepth(_queue.length);
    _pump();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        if (_dataChannel.state != RTCDataChannelState.RTCDataChannelOpen) {
          // The channel died with data still queued; the transport connector's
          // state listener tears the connection down, so just stop writing.
          _dropQueue();
          break;
        }
        if (_stats != null &&
            (!_sampleClock.isRunning ||
                _sampleClock.elapsed >= _bufferedAmountSampleInterval)) {
          await _sampleBufferedAmounts();
        }
        if ((_dataChannel.bufferedAmount ?? 0) > highWaterMark) {
          await _waitForDrain();
          continue;
        }
        // Awaiting each send keeps sends ordered. Note this only confirms the
        // platform round trip on native, not that libwebrtc accepted the data.
        final message = _queue.removeFirst();
        await _dataChannel.send(RTCDataChannelMessage.fromBinary(message));
        _stats?.recordSend(message.length);
      }
    } catch (_) {
      // A failed send means the channel is gone; drop what's left and let the
      // connector's done future surface the disconnect. Native never gets here
      // — the darwin plugin swallows send failures.
      _stats?.sendErrors++;
      _dropQueue();
    } finally {
      _pumping = false;
      if (_isClosed && !_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    }
  }

  void _dropQueue() {
    if (_stats != null) {
      for (final chunk in _queue) {
        _stats.queuedBytesDroppedOnClose += chunk.length;
      }
    }
    _queue.clear();
  }

  /// Compares the cached [RTCDataChannel.bufferedAmount] against a live read.
  ///
  /// On web these always agree. On native the cache is refreshed by an async
  /// platform event, so a positive divergence is the amount of buffered data
  /// the pump is blind to. Note the read itself refreshes the native cache as a
  /// side effect, which is why it is throttled rather than run every send.
  Future<void> _sampleBufferedAmounts() async {
    final cached = _dataChannel.bufferedAmount ?? 0;
    try {
      final live = await _dataChannel.getBufferedAmount();
      _stats?.recordBufferedAmounts(cached: cached, live: live);
    } catch (_) {
      // Channel closed or the platform refused the query; not worth surfacing.
    }
    _sampleClock
      ..reset()
      ..start();
  }

  Future<void> _waitForDrain() async {
    _stats?.drainWaits++;
    final completer = _bufferedAmountLow ??= Completer<void>();
    final drainedViaPoll = await Future.any([
      completer.future.then((_) => false),
      Future.delayed(_drainPollInterval, () => true),
    ]);
    if (drainedViaPoll) _stats?.drainPollFallbacks++;
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_isClosed) {
      throw StateError('StreamSink is closed');
    }
    // WebRTC DataChannel doesn't have a direct way to send errors,
    // so we just close the connection
    close();
  }

  @override
  Future addStream(Stream<List<int>> stream) async {
    if (_isClosed) {
      throw StateError('StreamSink is closed');
    }

    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future close() async {
    if (_isClosed) return _doneCompleter.future;
    _isClosed = true;

    // Note: We don't close the DataChannel here because it might be used
    // for other purposes. The WebRTCTransportConnector will handle that.

    // If the pump is mid-drain it completes done when it finishes.
    if (!_pumping && !_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
    return _doneCompleter.future.whenComplete(() {
      _dataChannel.onBufferedAmountLow = null;
    });
  }

  @override
  Future get done => _doneCompleter.future;
}
