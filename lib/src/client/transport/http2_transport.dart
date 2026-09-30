// Copyright (c) 2018, the gRPC project authors. Please see the AUTHORS file
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

import 'package:http2/transport.dart';

import '../../shared/codec.dart';
import '../../shared/codec_registry.dart';
import '../../shared/message.dart';
import '../../shared/streams.dart';
import '../options.dart';
import 'transport.dart';

class Http2TransportStream extends GrpcTransportStream {
  final TransportStream _transportStream;
  final Stream<GrpcMessage> _decodedMessages;
  final StreamController<GrpcMessage> _incomingMessages = StreamController();
  final StreamController<List<int>> _outgoingMessages = StreamController();
  final ErrorHandler _onError;

  /// See [ChannelOptions.resetStreamGrace].
  final Duration _resetGrace;

  /// See [ChannelOptions.cancelStreamGrace].
  final Duration _cancelGrace;

  StreamSubscription<GrpcMessage>? _incomingSubscription;
  bool _incomingDone = false;
  bool _reset = false;
  Future<void>? _terminated;
  Timer? _resetTimer;
  final _done = Completer<void>();

  @override
  Stream<GrpcMessage> get incomingMessages => _incomingMessages.stream;

  @override
  StreamSink<List<int>> get outgoingMessages => _outgoingMessages.sink;

  /// Completes once the server has ended the stream or it has been reset.
  Future<void> get done => _done.future;

  /// Whether [terminate] or [cancel] has been called.
  bool get isTerminated => _terminated != null;

  Http2TransportStream(
    this._transportStream,
    this._onError,
    CodecRegistry? codecRegistry,
    Codec? compression, {
    Duration resetGrace = Duration.zero,
    Duration cancelGrace = Duration.zero,
  }) : _resetGrace = resetGrace,
       _cancelGrace = cancelGrace,
       _decodedMessages = _transportStream.incomingMessages
           .transform(GrpcHttpDecoder(forResponse: true))
           .transform(grpcDecompressor(codecRegistry: codecRegistry)) {
    // The underlying subscription is owned here rather than handed to the
    // caller: cancelling it makes package:http2 reset a half-closed stream.
    _incomingMessages.onListen = _listenIncoming;
    _incomingMessages.onPause = () => _incomingSubscription?.pause();
    _incomingMessages.onResume = () => _incomingSubscription?.resume();
    // package:http2 closes its sink on reset, so nothing may reach it after.
    final sink = _transportStream.outgoingMessages;
    _outgoingMessages.stream
        .map((payload) => frame(payload, compression))
        .map<StreamMessage>((bytes) => DataStreamMessage(bytes))
        .handleError(_onError)
        .listen(
          (message) {
            if (!_reset) sink.add(message);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!_reset) sink.addError(error, stackTrace);
          },
          onDone: () {
            if (!_reset) sink.close();
          },
          cancelOnError: true,
        );
  }

  void _listenIncoming() {
    // Not cancelOnError: a decoder error is handled by resetting the stream,
    // and cancelling first would make package:http2 send a second RST_STREAM.
    _incomingSubscription ??= _decodedMessages.listen(
      _onIncomingData,
      onError: _onIncomingError,
      onDone: _onIncomingDone,
    );
  }

  void _onIncomingData(GrpcMessage message) {
    if (_incomingDone || isTerminated) return; // Draining: the caller is gone.
    _incomingMessages.add(message);
  }

  void _onIncomingError(Object error, StackTrace stackTrace) {
    if (_incomingDone) return;
    if (!isTerminated) _incomingMessages.addError(error, stackTrace);
    _onIncomingDone();
    // A decoder error leaves the HTTP/2 stream open, so reset it. A stream
    // package:http2 failed itself is already terminated and this is a no-op.
    _transportStream.terminate();
  }

  void _onIncomingDone() {
    if (_incomingDone) return;
    _incomingDone = true;
    _resetTimer?.cancel();
    _resetTimer = null;
    _incomingMessages.close();
    _done.complete();
  }

  /// Ends this stream without racing the server's final frames.
  ///
  /// Closes the request side and leaves the stream open for the server to end
  /// it. A server that received `grpc-timeout` ends a timed-out stream itself,
  /// so no RST_STREAM is sent in the common case. The stream is only reset if
  /// the server has not ended it within [ChannelOptions.resetStreamGrace].
  ///
  /// Resetting right away instead races the server's trailers: package:http2
  /// treats a HEADERS frame for a stream it has already reset as a connection
  /// error and fails every call sharing the connection.
  ///
  /// Frames that arrive while draining are discarded. Calling this or [cancel]
  /// more than once has no further effect.
  @override
  Future<void> terminate() => _terminated ??= _drain(_resetGrace);

  /// [terminate] with [ChannelOptions.cancelStreamGrace].
  ///
  /// The server does not learn of a cancellation until the reset, so the
  /// stream is reset sooner. The grace still covers trailers already in flight.
  @override
  Future<void> cancel() => _terminated ??= _drain(_cancelGrace);

  Future<void> _drain(Duration grace) async {
    if (!_incomingDone) {
      // The server's END_STREAM has to be observed even if the caller paused
      // or never listened.
      _listenIncoming();
      _incomingMessages.onPause = null;
      _incomingMessages.onResume = null;
      while (_incomingSubscription!.isPaused) {
        _incomingSubscription!.resume();
      }
      if (grace <= Duration.zero) {
        reset(); // Synchronous, so a zero grace is truly immediate.
      } else {
        _resetTimer = Timer(grace, reset);
      }
    }
    await _outgoingMessages.close();
  }

  /// Resets the stream now, skipping any remaining grace.
  void reset() {
    _resetTimer?.cancel();
    _resetTimer = null;
    if (_incomingDone) return;
    _reset = true;
    _listenIncoming(); // Observe the reset so [done] completes.
    _transportStream.terminate();
  }
}
