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
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http2/transport.dart';

import 'client_transport_connector.dart';

/// A transport connector that uses WebRTC DataChannel as the underlying
/// transport for HTTP/2 connections.
/// 
/// This allows gRPC to run over WebRTC by using the existing HTTP/2
/// infrastructure but routing the bytes through a WebRTC DataChannel
/// instead of a TCP socket.
class WebRTCTransportConnector implements ClientTransportConnector {
  final RTCDataChannel _dataChannel;
  final String _authority;
  final Completer<void> _doneCompleter = Completer<void>();
  bool _isShutdown = false;

  /// Creates a WebRTC transport connector.
  /// 
  /// [dataChannel] - The WebRTC DataChannel to use as transport
  /// [authority] - The authority string for the gRPC service
  WebRTCTransportConnector(this._dataChannel, this._authority) {
    // Listen for DataChannel closure
    _dataChannel.onDataChannelState = (RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed && !_doneCompleter.isCompleted) {
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
    final outgoingSink = _WebRTCStreamSink(_dataChannel);

    // Set up incoming data forwarding
    _dataChannel.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary && !incomingController.isClosed) {
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
      settings: const ClientSettings(
        concurrentStreamLimit: 100,
      ),
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

/// A StreamSink that forwards data to a WebRTC DataChannel.
class _WebRTCStreamSink implements StreamSink<List<int>> {
  final RTCDataChannel _dataChannel;
  final Completer<void> _doneCompleter = Completer<void>();
  bool _isClosed = false;

  _WebRTCStreamSink(this._dataChannel);

  @override
  void add(List<int> data) {
    if (_isClosed) {
      throw StateError('StreamSink is closed');
    }
    
    if (_dataChannel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dataChannel.send(RTCDataChannelMessage.fromBinary(Uint8List.fromList(data)));
    } else {
      throw StateError('WebRTC DataChannel is not open');
    }
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
    
    _doneCompleter.complete();
    return _doneCompleter.future;
  }

  @override
  Future get done => _doneCompleter.future;
}
